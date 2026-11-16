#!/usr/bin/env python3
"""
atsc3play.py - ATSC 3.0 ROUTE/DASH receiver for hdtvmate (pure Python, no deps).

Reads the decapsulated IP stream as pcap (from `hdtvmate tune <rf> -w -` or a
saved .pcap), finds services in the LLS SLT, parses the ROUTE SLS (USBD /
S-TSID / MPD), reassembles ALC/LCT objects and rebuilds the DASH init + media
segments as fragmented MP4.

  # list services (live or from a file)
  ./hdtvmate tune 32 -w - | python3 tools/atsc3play.py --list
  python3 tools/atsc3play.py --list a3.pcap

  # watch live (video + selected audio muxed by ffmpeg, shown by ffplay)
  ./hdtvmate tune 32 -w - | python3 tools/atsc3play.py --service 13.1 --play

  # save tracks to files (from live or a pcap)
  python3 tools/atsc3play.py a3.pcap --service 13.1 --out wnet

Only clear (non-DRM) services can be played.
"""
import argparse, gzip, os, queue, re, shutil, struct, subprocess, sys, tempfile, threading, time, zlib

LLS_ADDR, LLS_PORT = "224.0.23.60", 4937
INIT_TOI = 0xFFFFFFFF


def log(*a):
    print("[atsc3]", *a, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ pcap input
def pcap_packets(f):
    hdr = f.read(24)
    if len(hdr) < 24:
        return
    magic = struct.unpack("<I", hdr[:4])[0]
    endian = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
    link = struct.unpack(endian + "I", hdr[20:24])[0]
    while True:
        h = f.read(16)
        if len(h) < 16:
            return
        _, _, incl, _ = struct.unpack(endian + "IIII", h)
        d = f.read(incl)
        if len(d) < incl:
            return
        if link == 1:          # ethernet (e.g. a Wireshark capture)
            if d[12:14] != b"\x08\x00":
                continue
            d = d[14:]
        if not d or d[0] >> 4 != 4 or d[9] != 17:
            continue
        ihl = (d[0] & 15) * 4
        ip = "%d.%d.%d.%d" % tuple(d[16:20])
        port = (d[ihl + 2] << 8) | d[ihl + 3]
        yield ip, port, d[ihl + 8:]


# ------------------------------------------------------------------ ALC / LCT
def parse_lct(p):
    if len(p) < 12:
        return None
    C = (p[0] >> 2) & 3
    S, O, H = (p[1] >> 7) & 1, (p[1] >> 5) & 3, (p[1] >> 4) & 1
    hdr_len, cp = p[2] * 4, p[3]
    off = 4 + 4 * (C + 1)
    tl, ol = 4 * S + 2 * H, 4 * O + 2 * H
    tsi = int.from_bytes(p[off:off + tl], "big"); off += tl
    toi = int.from_bytes(p[off:off + ol], "big"); off += ol
    length = None
    while off < hdr_len:
        het = p[off]
        if het < 128:
            hel = p[off + 1] * 4
            if het == 64:    # EXT_FTI
                length = int.from_bytes(p[off + 2:off + 8], "big")
            elif het == 67:  # EXT_TOL48
                length = int.from_bytes(p[off + 2:off + 8], "big")
            off += max(hel, 4)
        else:
            if het == 194:   # EXT_TOL24
                length = int.from_bytes(p[off + 1:off + 4], "big")
            off += 4
    if hdr_len + 4 > len(p):
        return None
    start = struct.unpack(">I", p[hdr_len:hdr_len + 4])[0]
    return tsi, toi, cp, length, start, p[hdr_len + 4:]


class Objects:
    """Reassemble ROUTE objects keyed by (session, tsi, toi)."""
    def __init__(self):
        self.o = {}

    def feed(self, key, length, start, data):
        ob = self.o.get(key)
        if ob is None:
            if len(self.o) > 400:            # drop stale partials
                for k in list(self.o)[:100]:
                    del self.o[k]
            ob = self.o[key] = {"len": None, "chunks": {}, "got": 0}
        if length is not None:
            ob["len"] = length
        if start not in ob["chunks"]:
            ob["chunks"][start] = data
            ob["got"] += len(data)
        if ob["len"] is not None and ob["got"] >= ob["len"]:
            buf = bytearray(ob["len"])
            for s, c in ob["chunks"].items():
                buf[s:s + len(c)] = c[:max(0, ob["len"] - s)]
            del self.o[key]
            return bytes(buf)
        return None


# ------------------------------------------------------------------ signalling
def attr(el, name):
    m = re.search(r'\b%s="([^"]*)"' % name, el)
    return m.group(1) if m else None


def parse_lls(p):
    """Return SLT XML string if this LLS packet carries one."""
    if len(p) < 5:
        return None
    tid = p[0]
    try:
        if tid == 0x01:
            return zlib.decompress(p[4:], 16 + 15).decode("utf-8", "replace")
        if tid == 0xFE:
            n, o = p[4], 5
            for _ in range(n):
                pid, plen = p[o], struct.unpack(">H", p[o + 2:o + 4])[0]
                o += 4
                if pid == 0x01:
                    return zlib.decompress(p[o:o + plen], 16 + 15).decode("utf-8", "replace")
                o += plen
    except Exception:
        return None
    return None


def parse_slt(xml):
    out = []
    for m in re.finditer(r"<Service\b(.*?)(?:/>|</Service>)", xml, re.S):
        body = m.group(0)
        head = body[:body.index(">")]
        bss = re.search(r"<BroadcastSvcSignaling\b[^>]*>", body)
        out.append({
            "id": attr(head, "serviceId"),
            "chan": "%s.%s" % (attr(head, "majorChannelNo") or "", attr(head, "minorChannelNo") or ""),
            "name": attr(head, "shortServiceName") or "",
            "cat": attr(head, "serviceCategory"),
            "drm": attr(head, "protected") == "true",
            "proto": attr(bss.group(0), "slsProtocol") if bss else None,
            "ip": attr(bss.group(0), "slsDestinationIpAddress") if bss else None,
            "port": int(attr(bss.group(0), "slsDestinationUdpPort") or 0) if bss else None,
        })
    return out


def parse_sls(blob):
    """Split the multipart SLS into {content-location: xml}."""
    try:
        blob = zlib.decompress(blob, 16 + 15)
    except Exception:
        pass
    text = blob.decode("utf-8", "replace")
    parts = {}
    for m in re.finditer(r"Content-Location:\s*(\S+)\s*\r?\n\r?\n(.*?)(?=\r?\n--)", text, re.S):
        parts[m.group(1)] = m.group(2)
    if not parts and "<S-TSID" in text:
        parts["stsid"] = text
    return parts


def build_tracks(parts):
    """From S-TSID + MPD -> {tsi: {repId, type, lang, codecs, role}}."""
    stsid = next((v for k, v in parts.items() if "S-TSID" in v), "")
    mpd = next((v for k, v in parts.items() if "<MPD" in v), "")
    reps = {}
    for a in re.finditer(r"<AdaptationSet\b(.*?)</AdaptationSet>", mpd, re.S):
        aset = a.group(0)
        head = aset[:aset.index(">")]
        role = re.search(r'<Role[^>]*value="([^"]+)"', aset)
        for r in re.finditer(r"<Representation\b[^>]*>", aset):
            reps[attr(r.group(0), "id")] = {
                "mime": attr(head, "mimeType") or attr(r.group(0), "mimeType") or "",
                "lang": attr(head, "lang") or "",
                "codecs": attr(r.group(0), "codecs") or attr(head, "codecs") or "",
                "role": role.group(1) if role else "",
            }
    tracks = {}
    for ls in re.finditer(r"<LS\b(.*?)</LS>", stsid, re.S):
        tsi = int(attr(ls.group(0), "tsi"))
        mi = re.search(r"<MediaInfo\b[^>]*>", ls.group(0))
        rep = attr(mi.group(0), "repId") if mi else None
        ctype = attr(mi.group(0), "contentType") if mi else None
        info = dict(reps.get(rep, {}))
        info.update({"rep": rep, "type": ctype or info.get("mime", "").split("/")[0]})
        tracks[tsi] = info
    return tracks


# ------------------------------------------------------------------ outputs
class Sink:
    """Writes init + media segments in order to a file or FIFO (in a thread)."""
    def __init__(self, path, name):
        self.path, self.name = path, name
        self.q = queue.Queue()
        self.started = False
        self.t = threading.Thread(target=self.run, daemon=True)
        self.t.start()

    def run(self):
        try:
            with open(self.path, "wb") as f:
                while True:
                    b = self.q.get()
                    if b is None:
                        return
                    f.write(b)
                    f.flush()
        except (BrokenPipeError, OSError):
            pass

    def put(self, b):
        self.q.put(b)

    def close(self):
        self.q.put(None)


class StartGate:
    """All tracks begin at the same DASH segment number so audio and video line up."""
    def __init__(self):
        self.tracks, self.first, self.start = [], {}, None

    def seen(self, track, toi):
        if self.start is None:
            self.first.setdefault(track, toi)
            if len(self.first) == len(self.tracks):
                self.start = max(self.first.values())
                log("starting all tracks at segment %d" % self.start)
        return self.start


class Track:
    def __init__(self, tsi, info, sink, gate=None):
        self.gate = gate
        if gate is not None:
            gate.tracks.append(self)
        self.tsi, self.info, self.sink = tsi, info, sink
        self.init = None
        self.started = False
        self.last = -1
        self.pending = {}
        self.segs = 0

    def on_object(self, toi, data):
        if toi == INIT_TOI:
            if self.init is None:
                self.init = data
            return
        if self.init is None:
            return
        if self.gate is not None:
            start = self.gate.seen(self, toi)
            if start is None:
                self.pending[toi] = data       # hold until every track has a segment
                return
            if not self.started:
                for k in [k for k in self.pending if k < start]:
                    del self.pending[k]
                if toi < start:
                    return
                self.sink.put(self.init)
                self.started = True
                self.last = start - 1
        if not self.started:
            self.sink.put(self.init)
            self.started = True
            self.last = toi - 1
        if toi <= self.last:
            return
        self.pending[toi] = data
        # emit in order; tolerate a lost segment after it is 2 behind
        while self.pending:
            nxt = min(self.pending)
            if nxt == self.last + 1 or len(self.pending) > 2:
                if nxt != self.last + 1:
                    log("track %s: segment(s) %d..%d lost" % (self.info.get("type"), self.last + 1, nxt - 1))
                self.sink.put(self.pending.pop(nxt))
                self.last = nxt
                self.segs += 1
            else:
                break


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap", nargs="?", default="-", help="pcap file or - for stdin (default)")
    ap.add_argument("--list", action="store_true", help="print services and tracks, then exit")
    ap.add_argument("--service", help="virtual channel (13.1), serviceId, or name")
    ap.add_argument("--lang", default=None, help="audio language (eng, spa, ...); default: main role")
    ap.add_argument("--out", help="write <out>_video.mp4 / <out>_audio.mp4")
    ap.add_argument("--play", action="store_true", help="play with ffmpeg + ffplay")
    ap.add_argument("--no-audio", action="store_true", help="video only")
    ap.add_argument("--mux-out", help="with --play: write the muxed stream to this path (e.g. a FIFO) instead of ffplay")
    ap.add_argument("--ac4-ffmpeg", default=os.environ.get("HDTVMATE_AC4") or os.path.expanduser("~/hdtvmate/ffmpeg-ac4/ffmpeg"),
                    help="ffmpeg build with an AC-4 decoder (default: ~/hdtvmate/ffmpeg-ac4/ffmpeg)")
    args = ap.parse_args()

    src = sys.stdin.buffer if args.pcap == "-" else open(args.pcap, "rb")
    services, target, sls_seen, tracks = None, None, False, {}
    objs = Objects()
    sinks, ff = [], None
    t0 = time.time()

    for ip, port, payload in pcap_packets(src):
        # 1) LLS -> SLT
        if services is None and ip == LLS_ADDR and port == LLS_PORT:
            xml = parse_lls(payload)
            if xml:
                services = parse_slt(xml)
                log("SLT: %d services" % len(services))
                for s in services:
                    log("  %-6s %-10s id=%-6s %s%s" % (s["chan"], s["name"], s["id"],
                        {"1": "ROUTE", "2": "MMTP"}.get(s["proto"], "?"), "  [DRM]" if s["drm"] else ""))
                if args.service:
                    for s in services:
                        if args.service in (s["chan"], s["id"], s["name"]):
                            target = s
                    if not target:
                        sys.exit("service %r not found" % args.service)
                    if target["drm"]:
                        sys.exit("%s is DRM-protected; pick a clear service" % target["name"])
                    if target["proto"] != "1":
                        sys.exit("%s uses MMTP (not supported yet)" % target["name"])
                    log("selected %s %s, SLS at %s:%d" % (target["chan"], target["name"], target["ip"], target["port"]))
                elif not args.list:
                    sys.exit("give --service (or --list)")
            continue
        if args.list and services is not None and not args.service:
            # also show tracks of every clear service? keep it short: done
            return
        if target is None or ip != target["ip"] or port != target["port"]:
            continue

        lct = parse_lct(payload)
        if not lct:
            continue
        tsi, toi, cp, length, start, data = lct

        # 2) SLS on TSI 0
        if tsi == 0:
            if sls_seen:
                continue
            obj = objs.feed((0, toi), length, start, data)
            if obj is None or b"S-TSID" not in obj and b"multipart" not in obj[:400]:
                continue
            parts = parse_sls(obj)
            tr = build_tracks(parts)
            if not tr:
                continue
            sls_seen = True
            log("tracks:")
            for k, v in sorted(tr.items()):
                log("  tsi %-3d %-9s %-5s %-18s %s" % (k, v.get("type"), v.get("lang", ""), v.get("codecs", ""), v.get("role", "")))
            if args.list:
                return
            video = next((k for k, v in sorted(tr.items()) if v.get("type") == "video"), None)
            auds = [k for k, v in sorted(tr.items()) if v.get("type") == "audio"]
            audio = None
            if auds and not args.no_audio:
                if args.lang:
                    audio = next((k for k in auds if tr[k].get("lang") == args.lang), None)
                audio = audio or next((k for k in auds if tr[k].get("role") == "main"), auds[0])

            ac4_dec = None
            if args.play and audio is not None and tr[audio].get("codecs", "").startswith("ac-4"):
                try:
                    dec = subprocess.run(["ffmpeg", "-hide_banner", "-decoders"], capture_output=True, text=True).stdout
                except FileNotFoundError:
                    dec = ""
                if re.search(r"\bac4\b", dec):
                    ac4_dec = "ffmpeg"                       # system ffmpeg can do it
                elif os.access(args.ac4_ffmpeg, os.X_OK):
                    ac4_dec = args.ac4_ffmpeg                # side-built AC-4 ffmpeg
                    log("AC-4 audio via " + ac4_dec)
                else:
                    log("no AC-4 decoder found (system ffmpeg or %s) -> video only" % args.ac4_ffmpeg)
                    audio = None

            if args.play:
                tmp = tempfile.mkdtemp(prefix="atsc3")
                vpath, apath = os.path.join(tmp, "v.mp4"), os.path.join(tmp, "a.mp4")
                os.mkfifo(vpath)
                cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-copyts", "-i", vpath]
                if audio is not None and ac4_dec and ac4_dec != "ffmpeg":
                    # AC-4 -> PCM (timestamps kept) in the side build, then muxed with the video
                    os.mkfifo(apath)
                    ppath = os.path.join(tmp, "pcm.nut")
                    os.mkfifo(ppath)
                    acmd = [ac4_dec, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-copyts", "-i", apath,
                            "-vn", "-af", "aresample=48000", "-c:a", "pcm_s16le", "-f", "nut", ppath]
                    subprocess.Popen(acmd, stdin=subprocess.DEVNULL)
                    cmd += ["-i", ppath, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "pcm_s16le"]
                elif audio is not None:
                    os.mkfifo(apath)
                    cmd += ["-copyts", "-i", apath, "-map", "0:v", "-map", "1:a", "-c:v", "copy",
                            "-af", "aresample=48000", "-c:a", "pcm_s16le"]
                else:
                    cmd += ["-c", "copy"]
                if args.mux_out:
                    cmd += ["-f", "nut", "-y", args.mux_out]
                    log("starting muxer: " + " ".join(cmd))
                    ff = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
                else:
                    cmd += ["-f", "nut", "-"]
                    log("starting player: " + " ".join(cmd))
                    ff = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
                    subprocess.Popen(["ffplay", "-hide_banner", "-loglevel", "warning",
                                      "-window_title", "%s %s" % (target["chan"], target["name"]), "-"],
                                     stdin=ff.stdout)
                    ff.stdout.close()
            else:
                base = args.out or ("atsc3_" + target["chan"].replace(".", "_"))
                vpath, apath = base + "_video.mp4", base + "_audio.mp4"
                log("writing %s%s" % (vpath, (" and " + apath) if audio is not None else ""))
            gate = StartGate()
            if video is not None:
                tracks[video] = Track(video, tr[video], Sink(vpath, "video"), gate)
                sinks.append(tracks[video].sink)
            if audio is not None:
                tracks[audio] = Track(audio, tr[audio], Sink(apath, "audio"), gate)
                sinks.append(tracks[audio].sink)
            continue

        # 3) media
        t = tracks.get(tsi)
        if t is None:
            continue
        obj = objs.feed((tsi, toi), length, start, data)
        if obj is not None:
            before = t.segs
            t.on_object(toi, obj)
            if before == 0 and t.segs == 1:
                log("first %s segment delivered (%d bytes)" % (t.info.get("type"), len(obj)))
            if t.info.get("type") == "video" and t.segs and t.segs % 5 == 0 and t.segs != getattr(t, "_rep", 0):
                t._rep = t.segs
                log("%d video segments (%.0f s of video) after %.0f s" % (t.segs, t.segs * 2.002, time.time() - t0))
        if ff is not None and ff.poll() is not None:
            log("player exited")
            break

    for s in sinks:
        s.close()
    for s in sinks:
        s.t.join(timeout=5)
    if services is None:
        log("no SLT seen (is this an ATSC 3.0 capture?)")
    elif target and not sls_seen:
        log("no SLS seen for the service")
    for t in tracks.values():
        log("%s: %d segments" % (t.info.get("type"), t.segs))


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
