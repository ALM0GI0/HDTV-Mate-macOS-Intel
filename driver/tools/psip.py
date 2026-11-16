#!/usr/bin/env python3
"""
psip.py - ATSC 1.0 PSIP decoder (A/65): channel table (TVCT/CVCT), master guide
table (MGT), program guide events (EIT) and system time (STT).

    python3 tools/psip.py capture.ts          # print channels + guide as JSON
"""
import json, struct, sys, time

GPS_EPOCH = 315964800          # 1980-01-06 00:00:00 UTC as Unix time


class Sections:
    """Reassemble MPEG-TS PSI sections for a set of PIDs."""
    def __init__(self, pids):
        self.pids = set(pids)
        self.buf = {}

    def add_pid(self, pid):
        self.pids.add(pid)

    def feed(self, ts):
        out = []
        for i in range(0, len(ts) - 187, 188):
            p = ts[i:i + 188]
            if p[0] != 0x47:
                continue
            pid = ((p[1] & 0x1F) << 8) | p[2]
            if pid not in self.pids or p[1] & 0x80:
                continue
            afc = (p[3] >> 4) & 3
            if not afc & 1:
                continue
            off = 4 + (1 + p[4] if afc & 2 else 0)
            pl = p[off:]
            if p[1] & 0x40:
                if not pl:
                    continue
                ptr = pl[0]
                prev = self.buf.get(pid, b"") + pl[1:1 + ptr]
                out += self._drain(pid, prev, final=True)
                self.buf[pid] = pl[1 + ptr:]
            elif pid in self.buf:
                self.buf[pid] += pl
            else:
                continue
            out += self._drain(pid, self.buf.get(pid, b""))
        return out

    def _drain(self, pid, b, final=False):
        out = []
        while len(b) >= 3 and b[0] != 0xFF:
            slen = ((b[1] & 0x0F) << 8) | b[2]
            if len(b) < 3 + slen:
                break
            out.append((pid, b[:3 + slen]))
            b = b[3 + slen:]
        if not final:
            self.buf[pid] = b if (b and b[0] != 0xFF) else b""
        return out


def mss(b):
    """multiple_string_structure -> first readable string (uncompressed only)."""
    try:
        n, o = b[0], 1
        for _ in range(n):
            nseg = b[o + 3]
            o += 4
            text = ""
            for _ in range(nseg):
                comp, mode, nb = b[o], b[o + 1], b[o + 2]
                data = b[o + 3:o + 3 + nb]
                o += 3 + nb
                if comp == 0 and mode == 0:
                    text += data.decode("latin-1")
                elif comp == 0 and mode == 0x3F:
                    text += data.decode("utf-16-be", "replace")
            if text.strip():
                return text.strip()
    except Exception:
        pass
    return ""


def parse_vct(s):
    out = []
    n, o = s[9], 10
    for _ in range(n):
        if o + 32 > len(s):
            break
        out.append({
            "name": s[o:o + 14].decode("utf-16-be", "replace").replace("\x00", "").strip(),
            "major": ((s[o + 14] & 0x0F) << 6) | (s[o + 15] >> 2),
            "minor": ((s[o + 15] & 0x03) << 8) | s[o + 16],
            "program": (s[o + 24] << 8) | s[o + 25],
            "hidden": bool(s[o + 26] & 0x10),
            "service_type": s[o + 27] & 0x3F,
            "source_id": (s[o + 28] << 8) | s[o + 29],
        })
        o += 32 + (((s[o + 30] & 0x03) << 8) | s[o + 31])
    return out


def parse_mgt(s):
    """-> {table_type: pid}"""
    out, n, o = {}, (s[9] << 8) | s[10], 11
    for _ in range(n):
        if o + 11 > len(s):
            break
        ttype = (s[o] << 8) | s[o + 1]
        pid = ((s[o + 2] & 0x1F) << 8) | s[o + 3]
        out[ttype] = pid
        o += 11 + (((s[o + 9] & 0x0F) << 8) | s[o + 10])
    return out


def parse_eit(s, gps_offset):
    source_id = (s[3] << 8) | s[4]
    n, o, ev = s[9], 10, []
    for _ in range(n):
        if o + 10 > len(s):
            break
        start = struct.unpack(">I", s[o + 2:o + 6])[0]
        length = ((s[o + 6] & 0x0F) << 16) | (s[o + 7] << 8) | s[o + 8]
        tlen = s[o + 9]
        title = mss(s[o + 10:o + 10 + tlen])
        o += 10 + tlen
        dlen = ((s[o] & 0x0F) << 8) | s[o + 1]
        o += 2 + dlen
        ev.append({"start": start + GPS_EPOCH - gps_offset, "dur": length, "title": title})
    return source_id, ev


def decode(ts):
    """Return (channels, events_by_source_id) from a TS capture."""
    secs = Sections([0x1FFB])
    vct, mgt, gps_offset, eit_raw = [], {}, 18, []
    pending = ts
    for _ in range(2):           # pass 1 finds MGT -> EIT PIDs; pass 2 reads EITs
        for pid, s in secs.feed(pending):
            tid = s[0]
            if pid == 0x1FFB and tid in (0xC8, 0xC9) and not vct:
                vct = parse_vct(s)
            elif pid == 0x1FFB and tid == 0xC7 and not mgt:
                mgt = parse_mgt(s)
            elif pid == 0x1FFB and tid == 0xCD:
                gps_offset = s[13]
            elif tid == 0xCB:
                eit_raw.append(s)
        eit_pids = [p for t, p in mgt.items() if 0x0100 <= t <= 0x0103]
        if not eit_pids or eit_raw:
            break
        secs = Sections(eit_pids)
    events = {}
    for s in eit_raw:
        sid, ev = parse_eit(s, gps_offset)
        lst = events.setdefault(sid, [])
        for e in ev:
            if e not in lst:
                lst.append(e)
    for lst in events.values():
        lst.sort(key=lambda e: e["start"])
    return vct, events


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    vct, events = decode(data)
    out = []
    for c in vct:
        out.append(dict(c, epg=events.get(c["source_id"], [])))
    json.dump(out, sys.stdout, indent=1)
    print()
