#!/usr/bin/env python3
"""
tvui.py - tiny channel picker for hdtvmate (stdlib only).

    cd ~/hdtvmate/driver && python3 tools/tvui.py

Opens http://localhost:8765 . Click a channel to watch it in an ffplay window.
"Scan" finds ATSC 1.0 / 3.0 stations and reads their channel names
(ATSC 1.0: PSIP TVCT, ATSC 3.0: LLS SLT) into channels.json.
"""
import json, os, re, shlex, signal, subprocess, sys, tempfile, threading, time, webbrowser
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import psip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DRIVER = os.path.dirname(HERE)
HDTV = os.path.join(DRIVER, "hdtvmate")
DATA = os.environ.get("HDTVMATE_DATA", DRIVER)
CHFILE = os.path.join(DATA, "channels.json")
PORT = int(os.environ.get("TVUI_PORT", "8765"))

STAT_RE = re.compile(r"\[\s*(\d+)s\]\s+(\S+)\s+RF\s+(-?[\d.]+) dBm\s+SNR\s+(-?[\d.]+) dB")
LOCK_RE = re.compile(r"RF\s+(\d+)\s+\(\s*(\d+) MHz\)\s+ATSC (1\.0|3\.0)\s+LOCK\s+\S+\s+RF\s+(-?[\d.]+) dBm\s+SNR\s+(-?[\d.]+) dB")
SLT_RE = re.compile(r"^\s*(\d*)\.(\d*)\s+(\S+)\s+(Linear A/V|Linear audio|App-based|ESG|EAS|\?)\s+SLS\s+\S+\s+\((\w+)\)(\s+\[DRM\])?")

lock = threading.Lock()
HEADLESS = False
state = {"channels": [], "playing": None, "proc": None, "log": [], "stats": None,
         "scanning": False, "scan_msg": "", "lang": ""}


# ------------------------------------------------------------------ channels
def rf_mhz(rf):
    rf = int(rf)
    if 2 <= rf <= 4: return 57 + (rf - 2) * 6
    if 5 <= rf <= 6: return 79 + (rf - 5) * 6
    if 7 <= rf <= 13: return 177 + (rf - 7) * 6
    return 473 + (rf - 14) * 6


def load_channels():
    try:
        with open(CHFILE) as f:
            return json.load(f)
    except Exception:
        return []


def save_channels(ch):
    with open(CHFILE, "w") as f:
        json.dump(ch, f, indent=1)


def sort_key(c):
    try:
        maj, mnr = c["vchan"].split(".")
        return (int(maj or 999), int(mnr or 0), c["rf"])
    except Exception:
        return (999, 0, c["rf"])


# ------------------------------------------------------------------ ATSC 1.0 PSIP TVCT
def parse_tvct(ts_bytes):
    """Return [(major, minor, short_name, program_number, service_type, hidden)]."""
    sec, out, seen = b"", [], set()
    for i in range(0, len(ts_bytes) - 187, 188):
        p = ts_bytes[i:i + 188]
        if p[0] != 0x47 or ((p[1] & 0x1F) << 8 | p[2]) != 0x1FFB:
            continue
        afc = (p[3] >> 4) & 3
        if not afc & 1:
            continue
        off = 4 + (1 + p[4] if afc & 2 else 0)
        pl = p[off:]
        if p[1] & 0x40:
            ptr = pl[0]
            sec = pl[1 + ptr:]
        elif sec:
            sec += pl
        else:
            continue
        while len(sec) >= 3 and sec[0] != 0xFF:
            slen = ((sec[1] & 0x0F) << 8) | sec[2]
            if len(sec) < 3 + slen:
                break
            s, sec = sec[:3 + slen], sec[3 + slen:]
            if s[0] not in (0xC8, 0xC9):
                continue
            n, o = s[9], 10
            for _ in range(n):
                if o + 32 > len(s):
                    break
                name = s[o:o + 14].decode("utf-16-be", "replace").replace("\x00", "").strip()
                major = ((s[o + 14] & 0x0F) << 6) | (s[o + 15] >> 2)
                minor = ((s[o + 15] & 0x03) << 8) | s[o + 16]
                prog = (s[o + 24] << 8) | s[o + 25]
                hidden = bool(s[o + 26] & 0x10)
                stype = s[o + 27] & 0x3F
                dlen = ((s[o + 30] & 0x03) << 8) | s[o + 31]
                key = (major, minor, prog)
                if key not in seen:
                    seen.add(key)
                    out.append((major, minor, name, prog, stype, hidden))
                o += 32 + dlen
        if sec and sec[0] == 0xFF:
            sec = b""
    return out


# ------------------------------------------------------------------ process control
def logline(line):
    line = line.rstrip()
    if not line:
        return
    with lock:
        state["log"].append(line)
        del state["log"][:-300]
        m = STAT_RE.search(line)
        if m:
            state["stats"] = {"t": int(m.group(1)), "flags": m.group(2),
                              "rf": float(m.group(3)), "snr": float(m.group(4)), "line": line}


def reader(proc):
    buf = b""
    while True:
        b = proc.stderr.read(1)
        if not b:
            break
        if b in (b"\n", b"\r"):
            logline(buf.decode("utf-8", "replace"))
            buf = b""
        else:
            buf += b
    if buf:
        logline(buf.decode("utf-8", "replace"))


def stop_playback():
    with lock:
        p = state["proc"]
        state["proc"] = None
        state["playing"] = None
    if p and p.poll() is None:
        try:
            os.killpg(p.pid, signal.SIGINT)
            for _ in range(30):
                if p.poll() is not None:
                    break
                time.sleep(0.1)
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(timeout=3)
        except Exception:
            pass
    time.sleep(0.3)   # let the USB device be released


def play(ch, lang=""):
    stop_playback()
    hd = shlex.quote(HDTV)
    title = shlex.quote("%s %s" % (ch["vchan"], ch["name"]))
    if ch["std"] == "1.0":
        prog = ch.get("program")
        sel = "-map 0:p:%d" % prog if prog else "-map 0"
        cmd = ("%s tune %d -1 -o - | ffmpeg -nostdin -hide_banner -loglevel error -i - %s -c copy -f mpegts - "
               "| ffplay -hide_banner -loglevel error -window_title %s -" % (hd, ch["rf"], sel, title))
    else:
        langopt = (" --lang " + shlex.quote(lang)) if lang else ""
        cmd = ("%s tune %d -w - | %s %s --service %s --play%s" %
               (hd, ch["rf"], shlex.quote(sys.executable), shlex.quote(os.path.join(HERE, "atsc3play.py")),
                shlex.quote(ch["vchan"]), langopt))
    with lock:
        state["log"] = ["$ " + cmd]
        state["stats"] = None
    p = subprocess.Popen(["/bin/bash", "-c", cmd], cwd=DRIVER, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
    with lock:
        state["proc"] = p
        state["playing"] = ch
    threading.Thread(target=reader, args=(p,), daemon=True).start()


def run_capture(args, timeout=120):
    p = subprocess.run([HDTV] + args, cwd=DRIVER, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=timeout)
    return p.stderr.decode("utf-8", "replace")


def scan(first, last):
    stop_playback()
    with lock:
        state["scanning"] = True
        state["scan_msg"] = "Scanning RF %d-%d..." % (first, last)
        state["log"] = []
    try:
        p = subprocess.Popen([HDTV, "scan", str(first), str(last)], cwd=DRIVER, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        locks, buf = [], b""
        while True:
            b = p.stderr.read(1)
            if not b:
                break
            if b in (b"\n", b"\r"):
                line = buf.decode("utf-8", "replace"); buf = b""
                m = LOCK_RE.search(line)
                if m:
                    locks.append((int(m.group(1)), m.group(3), float(m.group(4)), float(m.group(5))))
                    logline(line)
                elif "trying" in line:
                    with lock:
                        state["scan_msg"] = line.strip()
                    if HEADLESS:
                        print("PROGRESS: " + line.strip(), file=sys.stderr, flush=True)
            else:
                buf += b
        p.wait()

        chans = []
        for rf, std, rfl, snr in locks:
            with lock:
                state["scan_msg"] = "Reading channel names on RF %d (ATSC %s)..." % (rf, std)
            if HEADLESS:
                print("PROGRESS: " + state["scan_msg"], file=sys.stderr, flush=True)
            if std == "1.0":
                tmp = tempfile.NamedTemporaryFile(suffix=".ts", delete=False).name
                run_capture(["tune", str(rf), "-1", "-o", tmp, "-t", "5"], timeout=40)
                try:
                    data = open(tmp, "rb").read()
                finally:
                    os.unlink(tmp)
                vct, events = psip.decode(data)
                vct = [v for v in vct if not v["hidden"] and v["service_type"] in (2, 3)]
                if vct:
                    for v in vct:
                        chans.append({"std": "1.0", "rf": rf, "vchan": "%d.%d" % (v["major"], v["minor"]),
                                      "name": v["name"], "program": v["program"], "drm": False,
                                      "audio_only": v["service_type"] == 3, "rf_dbm": rfl, "snr": snr,
                                      "epg": events.get(v["source_id"], [])})
                else:
                    chans.append({"std": "1.0", "rf": rf, "vchan": "RF%d" % rf, "name": "RF %d" % rf,
                                  "program": None, "drm": False, "rf_dbm": rfl, "snr": snr, "epg": []})
            else:
                err = run_capture(["tune", str(rf), "-t", "6"], timeout=40)
                for line in err.splitlines():
                    m = SLT_RE.match(line)
                    if m and m.group(4) in ("Linear A/V", "Linear audio"):
                        chans.append({"std": "3.0", "rf": rf, "vchan": "%s.%s" % (m.group(1), m.group(2)),
                                      "name": m.group(3), "drm": bool(m.group(6)),
                                      "proto": m.group(5), "audio_only": m.group(4) == "Linear audio",
                                      "rf_dbm": rfl, "snr": snr})
        chans.sort(key=sort_key)
        save_channels(chans)
        with lock:
            state["channels"] = chans
            state["scan_msg"] = "Found %d channels on %d frequencies." % (len(chans), len(locks))
    except Exception as e:
        with lock:
            state["scan_msg"] = "Scan failed: %s" % e
    finally:
        with lock:
            state["scanning"] = False


# ------------------------------------------------------------------ web
PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><title>HDTV Mate</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#0e1116;--card:#171b22;--line:#262c36;--fg:#e8ebf0;--mut:#8a93a3;--acc:#4f8cff;--ok:#3ecf8e;--warn:#f5b84b;--bad:#ef5b5b}
*{box-sizing:border-box}body{margin:0;font:15px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",Helvetica,sans-serif;background:var(--bg);color:var(--fg)}
header{display:flex;align-items:center;gap:12px;padding:16px 22px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}
h1{font-size:18px;margin:0;font-weight:650;letter-spacing:.2px}h1 small{color:var(--mut);font-weight:400;margin-left:6px}
.sp{flex:1}button,select{font:inherit;color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:8px;padding:7px 12px;cursor:pointer}
button:hover{border-color:var(--acc)}button.primary{background:var(--acc);border-color:var(--acc);color:#fff}button:disabled{opacity:.45;cursor:default}
main{padding:18px 22px 120px;max-width:1100px;margin:0 auto}
.sec{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.8px;margin:22px 0 10px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:10px}
.ch{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;cursor:pointer;transition:.12s;position:relative}
.ch:hover{border-color:var(--acc);transform:translateY(-1px)}.ch.on{border-color:var(--ok);box-shadow:0 0 0 1px var(--ok) inset}
.ch.dis{opacity:.4;cursor:not-allowed}.ch.dis:hover{transform:none;border-color:var(--line)}
.num{font-size:22px;font-weight:700;font-variant-numeric:tabular-nums}.nm{font-weight:550;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta{color:var(--mut);font-size:12px;margin-top:6px;display:flex;gap:6px;flex-wrap:wrap}
.tag{border:1px solid var(--line);border-radius:5px;padding:0 5px}.t3{color:var(--acc);border-color:#2b4a80}.drm{color:var(--bad);border-color:#5a2a2a}
.empty{color:var(--mut);padding:40px 0;text-align:center}
footer{position:fixed;bottom:0;left:0;right:0;background:#12161c;border-top:1px solid var(--line);padding:12px 22px;display:flex;gap:18px;align-items:center}
.now{min-width:0;flex:1}.now b{font-size:16px}.now .sub{color:var(--mut);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meter{width:120px}.meter .lbl{font-size:11px;color:var(--mut);display:flex;justify-content:space-between}.bar{height:6px;background:var(--line);border-radius:3px;overflow:hidden;margin-top:3px}.bar i{display:block;height:100%;background:var(--ok);width:0;transition:width .4s}
.dot{width:9px;height:9px;border-radius:50%;background:var(--mut);display:inline-block;margin-right:6px}.dot.l{background:var(--ok)}
details{margin-top:26px}summary{color:var(--mut);cursor:pointer}pre{background:#0a0c10;border:1px solid var(--line);border-radius:8px;padding:10px;max-height:260px;overflow:auto;font-size:11.5px;color:#b7c0cc;white-space:pre-wrap}
</style></head><body>
<header><h1>HDTV Mate<small>macOS</small></h1><div class="sp"></div>
<span id="scanmsg" style="color:var(--mut);font-size:13px"></span>
<select id="range"><option value="14,36">Scan UHF 14–36</option><option value="2,36">Scan all 2–36</option></select>
<button id="scan" class="primary">Scan</button></header>
<main><div id="list"></div>
<details><summary>Log</summary><pre id="log"></pre></details></main>
<footer><div class="now"><div><span class="dot" id="dot"></span><b id="nowt">Nothing playing</b></div><div class="sub" id="nows">Pick a channel</div></div>
<select id="lang" title="ATSC 3.0 audio language"><option value="">Audio: main</option><option value="eng">English</option><option value="spa">Español</option><option value="fra">Français</option></select>
<div class="meter"><div class="lbl"><span>Signal</span><span id="rfv">–</span></div><div class="bar"><i id="rfb"></i></div></div>
<div class="meter"><div class="lbl"><span>SNR</span><span id="snrv">–</span></div><div class="bar"><i id="snrb"></i></div></div>
<button id="stop">Stop</button></footer>
<script>
const $=id=>document.getElementById(id);let S={};
async function api(p,b){const r=await fetch(p,{method:b?'POST':'GET',headers:{'content-type':'application/json'},body:b?JSON.stringify(b):undefined});return r.json()}
function key(c){return c.std+':'+c.rf+':'+c.vchan}
function render(){
  const L=$('list');const ch=S.channels||[];
  if(!ch.length){L.innerHTML='<div class="empty">No channels yet. Plug in the antenna and press <b>Scan</b>.</div>';return}
  const groups={'ATSC 3.0':[],'ATSC 1.0':[]};ch.forEach(c=>groups['ATSC '+c.std].push(c));
  let h='';for(const g in groups){if(!groups[g].length)continue;h+='<div class="sec">'+g+'</div><div class="grid">';
    for(const c of groups[g]){const on=S.playing&&key(S.playing)==key(c);
      h+='<div class="ch'+(on?' on':'')+(c.drm?' dis':'')+'" data-k="'+key(c)+'"><div class="num">'+(c.vchan.startsWith('RF')?'RF '+c.rf:c.vchan)+'</div><div class="nm">'+(c.name||'')+'</div><div class="meta"><span class="tag'+(c.std=='3.0'?' t3':'')+'">'+c.std+'</span><span class="tag">RF '+c.rf+'</span>'+(c.drm?'<span class="tag drm">DRM</span>':'')+(c.audio_only?'<span class="tag">audio</span>':'')+'</div></div>'}
    h+='</div>'}
  L.innerHTML=h;
  L.querySelectorAll('.ch').forEach(e=>e.onclick=()=>{const c=ch.find(x=>key(x)==e.dataset.k);if(!c||c.drm)return;api('/api/play',{key:e.dataset.k,lang:$('lang').value}).then(set)})}
function set(s){const old=JSON.stringify([S.channels,S.playing&&key(S.playing)]);S=s;
  if(old!=JSON.stringify([S.channels,S.playing&&key(S.playing)]))render();
  const p=S.playing,st=S.stats;$('nowt').textContent=p?(p.vchan.startsWith('RF')?'RF '+p.rf:p.vchan)+'  '+p.name:'Nothing playing';
  $('nows').textContent=p?('ATSC '+p.std+' · RF '+p.rf+' ('+p.mhz+' MHz)'+(st?' · '+st.flags+' · '+st.t+' s':' · tuning…')):'Pick a channel';
  $('dot').className='dot'+(st&&st.flags.endsWith('L')?' l':'');
  if(st){$('rfv').textContent=st.rf.toFixed(1)+' dBm';$('rfb').style.width=Math.max(0,Math.min(100,(st.rf+95)/65*100))+'%';
    $('snrv').textContent=st.snr.toFixed(1)+' dB';const q=Math.max(0,Math.min(100,(st.snr+3)/33*100));$('snrb').style.width=q+'%';$('snrb').style.background=st.snr<8?'var(--bad)':st.snr<15?'var(--warn)':'var(--ok)'}
  else{$('rfv').textContent=$('snrv').textContent='–';$('rfb').style.width=$('snrb').style.width='0'}
  $('scan').disabled=S.scanning;$('scanmsg').textContent=S.scan_msg||'';$('log').textContent=(S.log||[]).join('\n')}
$('scan').onclick=()=>{const [a,b]=$('range').value.split(',');api('/api/scan',{first:+a,last:+b}).then(set)};
$('stop').onclick=()=>api('/api/stop',{}).then(set);
setInterval(()=>api('/api/state').then(set),1000);api('/api/state').then(set);
</script></body></html>"""


def snapshot():
    with lock:
        p = state["proc"]
        if p is not None and p.poll() is not None:
            state["proc"] = None
            state["playing"] = None
            state["stats"] = None
        playing = dict(state["playing"], mhz=rf_mhz(state["playing"]["rf"])) if state["playing"] else None
        return {"channels": state["channels"], "playing": playing, "stats": state["stats"],
                "scanning": state["scanning"], "scan_msg": state["scan_msg"], "log": state["log"][-120:]}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/":
            return self.send(200, PAGE, "text/html; charset=utf-8")
        if self.path == "/api/state":
            return self.send(200, json.dumps(snapshot()))
        self.send(404, "{}")

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            req = {}
        if self.path == "/api/play" and not state["scanning"]:
            ch = next((c for c in state["channels"] if "%s:%s:%s" % (c["std"], c["rf"], c["vchan"]) == req.get("key")), None)
            if ch and not ch.get("drm"):
                play(ch, req.get("lang", ""))
        elif self.path == "/api/stop":
            stop_playback()
        elif self.path == "/api/scan" and not state["scanning"]:
            threading.Thread(target=scan, args=(int(req.get("first", 14)), int(req.get("last", 36))), daemon=True).start()
            time.sleep(0.2)
        self.send(200, json.dumps(snapshot()))


def main():
    global HEADLESS
    if len(sys.argv) >= 2 and sys.argv[1] == "--scan":
        HEADLESS = True
        first = int(sys.argv[2]) if len(sys.argv) > 2 else 14
        last = int(sys.argv[3]) if len(sys.argv) > 3 else 36
        scan(first, last)
        print("DONE: " + state["scan_msg"], file=sys.stderr, flush=True)
        return
    if not os.access(HDTV, os.X_OK):
        sys.exit("build hdtvmate first (make -f Makefile.in) - expected %s" % HDTV)
    state["channels"] = load_channels()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    url = "http://localhost:%d" % PORT
    print("HDTV Mate UI on %s  (Ctrl-C to quit)" % url, file=sys.stderr)
    threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_playback()


if __name__ == "__main__":
    main()
