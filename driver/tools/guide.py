#!/usr/bin/env python3
"""
guide.py - keep the ATSC 1.0 program guide in channels.json fresh.

    # while watching: hdtvmate copies the TS to us (dropped, never blocking, if we lag)
    ./hdtvmate tune 27 -1 -o - -g >(python3 tools/guide.py live --rf 27 >/dev/null) | ffplay -

    # when the tuner is idle: visit each ATSC 1.0 frequency in channels.json for a few seconds
    python3 tools/guide.py refresh

Progress goes to stderr as "PROGRESS: ..." and every save as "GUIDE: ...", which the
app watches to reload the channel list. Guide data only replaces events in the time
range it covers, so older far-ahead data is kept until newer data arrives.
"""
import json, os, signal, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import psip

HERE = os.path.dirname(os.path.abspath(__file__))
DRIVER = os.path.dirname(HERE)
DATA = os.environ.get("HDTVMATE_DATA", DRIVER)
CHFILE = os.path.join(DATA, "channels.json")
KEEP_PAST = 3600            # keep events that ended in the last hour


def say(kind, text):
    print("%s: %s" % (kind, text), file=sys.stderr, flush=True)


def load_channels():
    try:
        with open(CHFILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def save_channels(chans):
    tmp = CHFILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(chans, f, indent=1)
    os.replace(tmp, CHFILE)


def merge(rf, vct, events, now=None):
    """Merge freshly read events for RF `rf` into channels.json. Returns (channels, events) updated."""
    now = now or time.time()
    src = {"%d.%d" % (v["major"], v["minor"]): v["source_id"] for v in vct}
    chans = load_channels()
    n_ch = n_ev = 0
    for c in chans:
        if c.get("std") != "1.0" or c.get("rf") != rf:
            continue
        sid = src.get(c.get("vchan"))
        new = [e for e in events.get(sid, []) if e["dur"] > 0] if sid is not None else []
        if not new:
            continue
        lo = min(e["start"] for e in new)
        hi = max(e["start"] + e["dur"] for e in new)
        old = [e for e in (c.get("epg") or []) if e["start"] + e["dur"] > now - KEEP_PAST]
        kept = [e for e in old if e["start"] + e["dur"] <= lo or e["start"] >= hi]
        merged = sorted(kept + new, key=lambda e: e["start"])
        if merged != c.get("epg"):
            c["epg"] = merged
            n_ch += 1
            n_ev += len(new)
    if n_ch:
        save_channels(chans)
    return n_ch, n_ev


class Reader:
    """Collects VCT + EIT sections from a TS, incrementally."""
    def __init__(self):
        self.secs = psip.Sections([0x1FFB])
        self.vct, self.gps_offset, self.events = [], 18, {}
        self.eit_pids = set()
        self.rest = b""

    def feed(self, data):
        data = self.rest + data
        cut = len(data) - len(data) % 188
        self.rest = data[cut:]
        for pid, s in self.secs.feed(data[:cut]):
            try:
                self._section(pid, s)
            except (IndexError, ValueError):
                pass                                # damaged section (dropped packets)

    def _section(self, pid, s):
        tid = s[0]
        if pid == 0x1FFB and tid in (0xC8, 0xC9):
            v = psip.parse_vct(s)
            if v:
                self.vct = v
        elif pid == 0x1FFB and tid == 0xC7:
            for ttype, p in psip.parse_mgt(s).items():
                if 0x0100 <= ttype <= 0x017F and p not in self.eit_pids:   # EIT-0 .. EIT-127
                    self.eit_pids.add(p)
                    self.secs.add_pid(p)
        elif pid == 0x1FFB and tid == 0xCD:
            self.gps_offset = s[13]
        elif tid == 0xCB and pid in self.eit_pids:
            sid, ev = psip.parse_eit(s, self.gps_offset)
            lst = self.events.setdefault(sid, [])
            for e in ev:
                if e not in lst:
                    lst.append(e)

    def result(self):
        ev = {sid: sorted(lst, key=lambda e: e["start"]) for sid, lst in self.events.items()}
        return self.vct, ev

    def count(self):
        return sum(len(v) for v in self.events.values())


def live(rf):
    """Read TS from stdin for as long as it flows; parse in windows, save after each."""
    first, every, length = 120, 900, 90      # parse the first 2 min, then 90 s every 15 min
    t0 = time.time()
    rd, window_end, next_window = Reader(), t0 + first, t0 + every
    saved_at = 0
    fd = sys.stdin.fileno()
    while True:
        try:
            data = os.read(fd, 1 << 17)
        except InterruptedError:
            continue
        if not data:
            break
        now = time.time()
        if rd is not None:
            rd.feed(data)
            # save partway through the window too, so the guide fills in quickly
            if now >= window_end or (now - saved_at > 30 and rd.count()):
                vct, ev = rd.result()
                if vct and ev:
                    n_ch, n_ev = merge(rf, vct, ev)
                    if n_ch:
                        say("GUIDE", "RF %d: %d events for %d channels" % (rf, n_ev, n_ch))
                saved_at = now
            if now >= window_end:
                rd = None
                next_window = now + every
        elif now >= next_window:
            rd, window_end = Reader(), now + length
            saved_at = now


def refresh(rfs=None, secs=8):
    """Tune each ATSC 1.0 frequency briefly and merge its guide. Stalest first."""
    chans = load_channels()
    now = time.time()
    horizon = {}
    for c in chans:
        if c.get("std") == "1.0" and c.get("rf"):
            end = max((e["start"] + e["dur"] for e in c.get("epg") or []), default=0)
            horizon[c["rf"]] = max(horizon.get(c["rf"], 0), end)
    todo = sorted(rfs or horizon, key=lambda rf: horizon.get(rf, 0))
    if not todo:
        say("DONE", "No ATSC 1.0 channels to update.")
        return
    hdtv = os.path.join(DRIVER, "hdtvmate")
    total = 0
    for i, rf in enumerate(todo, 1):
        say("PROGRESS", "Updating guide: RF %d (%d of %d)" % (rf, i, len(todo)))
        tmp = tempfile.NamedTemporaryFile(suffix=".ts", delete=False).name
        try:
            subprocess.run([hdtv, "tune", str(rf), "-1", "-o", tmp, "-t", str(secs)], cwd=DRIVER,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=secs + 30)
            rd = Reader()
            with open(tmp, "rb") as f:
                while True:
                    b = f.read(1 << 20)
                    if not b:
                        break
                    rd.feed(b)
        except subprocess.TimeoutExpired:
            continue
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        vct, ev = rd.result()
        if vct and ev:
            n_ch, n_ev = merge(rf, vct, ev, now)
            if n_ch:
                total += n_ch
                say("GUIDE", "RF %d: %d events for %d channels" % (rf, n_ev, n_ch))
    say("DONE", "Guide updated for %d channels." % total)


def main():
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    args = sys.argv[1:]
    if args[:1] == ["live"] and "--rf" in args:
        live(int(args[args.index("--rf") + 1]))
    elif args[:1] == ["refresh"]:
        refresh([int(a) for a in args[1:]] or None)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
