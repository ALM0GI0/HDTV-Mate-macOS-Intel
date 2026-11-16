import Foundation
import SwiftUI

struct EPGEvent: Codable, Hashable {
    let start: Double
    let dur: Double
    let title: String
    var end: Double { start + dur }
}

struct Channel: Codable, Identifiable, Hashable {
    var std: String
    var rf: Int
    var vchan: String
    var name: String
    var program: Int?
    var drm: Bool?
    var audio_only: Bool?
    var epg: [EPGEvent]?

    var id: String { "\(std):\(rf):\(vchan)" }
    var label: String { vchan.hasPrefix("RF") ? "RF \(rf)" : vchan }
    var isATSC3: Bool { std == "3.0" }
    var isDRM: Bool { drm ?? false }

    func nowAndNext(_ date: Date = Date()) -> (EPGEvent?, EPGEvent?) {
        let t = date.timeIntervalSince1970
        let ev = (epg ?? []).sorted { $0.start < $1.start }
        return (ev.first { $0.start <= t && t < $0.end }, ev.first { $0.start > t })
    }
}

struct Stats {
    var t = 0
    var flags = "-----"
    var rf: Double?
    var snr: Double?
    var ber: Double?
    var mbps: Double?
    var tei: Int?
    var ccErr: Int?
    var locked: Bool { flags.hasSuffix("L") }
}

struct StatPoint: Identifiable {
    let id = UUID()
    let time: Date
    let rf: Double
    let snr: Double
    let mbps: Double
}

final class TVModel: ObservableObject {
    static let shared = TVModel()

    let player = MPVPlayer()

    @Published var channels: [Channel] = []
    @Published var playing: Channel?
    @Published var stats = Stats()
    @Published var history: [StatPoint] = []
    @Published var log: [String] = []
    @Published var status = "Pick a channel"
    @Published var videoStarted = false
    @Published var scanning = false
    @Published var scanMessage = ""
    @Published var tunerConnected = false
    @Published var notice: String?
    @Published var recordingURL: URL?
    @Published var lastRecording: URL?
    @Published var captionsOn = true {
        didSet { player.set("sub-visibility", captionsOn ? "yes" : "no") }
    }
    @Published var audioLang = "" {
        didSet { if oldValue != audioLang, let ch = playing, ch.isATSC3 { play(ch, force: true) } }
    }
    @Published var volume: Double {
        didSet {
            player.set("volume", String(Int(volume)))
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    @Published var muted = false {
        didSet { player.set("mute", muted ? "yes" : "no") }
    }
    @Published var now = Date()
    @Published var recordingStart: Date?
    @Published var showDRM: Bool {
        didSet { UserDefaults.standard.set(showDRM, forKey: "showDRM") }
    }
    @Published var resumeOnLaunch: Bool {
        didSet { UserDefaults.standard.set(resumeOnLaunch, forKey: "resumeOnLaunch") }
    }
    @Published var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    }
    @Published var driverPath: String {
        didSet { UserDefaults.standard.set(driverPath, forKey: "driverPath"); loadChannels() }
    }

    private var logFile: FileHandle?
    private let tunerMonitor = TunerMonitor()
    private var noticeHide: DispatchWorkItem?
    private var job: Job?
    private var queued: (() -> Void)?
    private var userStopped = false
    private var clock: Timer?
    private var didResume = false

    /// Driver folder inside the app bundle (shareable build), if present.
    static let bundledDriver: String? = {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("driver") else { return nil }
        return FileManager.default.isExecutableFile(atPath: r.appendingPathComponent("hdtvmate").path) ? r.path : nil
    }()
    var isBundled: Bool { TVModel.bundledDriver != nil }
    var effectiveDriver: String { TVModel.bundledDriver ?? driverPath }

    /// Where channels.json, app.log, imported firmware and the AC-4 decoder live.
    static let appSupport: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("HDTV Mate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()
    var dataPath: String { isBundled ? TVModel.appSupport : driverPath }
    var importedFirmware: String { (TVModel.appSupport as NSString).appendingPathComponent("dvb-usb-hdtvmate.fw") }
    /// AC-4 decoder and stock firmware packed into the app by package.sh (personal builds).
    static let bundledAC4: String? = {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("bin/ffmpeg-ac4") else { return nil }
        return FileManager.default.isExecutableFile(atPath: r.path) ? r.path : nil
    }()
    static let bundledStockFirmware: Bool = {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("driver/firmware-stock") else { return false }
        return FileManager.default.fileExists(atPath: r.path)
    }()
    var ac4BuiltIn: Bool { TVModel.bundledAC4 != nil }
    var ac4Decoder: String {
        if let b = TVModel.bundledAC4 { return b }
        let local = (TVModel.appSupport as NSString).appendingPathComponent("ffmpeg-ac4/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        return (NSHomeDirectory() as NSString).appendingPathComponent("hdtvmate/ffmpeg-ac4/ffmpeg")
    }
    var hasStockFirmware: Bool { FileManager.default.fileExists(atPath: importedFirmware) }
    var hasAC4: Bool { FileManager.default.isExecutableFile(atPath: ac4Decoder) }

    private var env: [String: String] {
        var path = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let r = Bundle.main.resourceURL, isBundled {
            path.insert(r.appendingPathComponent("python/bin").path, at: 0)
            path.insert(r.appendingPathComponent("bin").path, at: 0)
        }
        var e: [String: String] = [
            "PATH": path.joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
            "PYTHONDONTWRITEBYTECODE": "1",
            "HDTVMATE_DATA": dataPath,
            "HDTVMATE_AC4": ac4Decoder,
        ]
        if isBundled && hasStockFirmware { e["HDTVMATE_FW"] = importedFirmware }
        return e
    }

    @Published var setupBusy = false
    @Published var setupMessage = ""
    private var setupJob: Job?
    private var lastError: String?

    private static let statRe = try! NSRegularExpression(pattern: #"\[\s*(\d+)s\]\s+(\S+)\s+RF\s+(-?[\d.]+) dBm\s+SNR\s+(-?[\d.]+) dB"#)
    private static let berRe = try! NSRegularExpression(pattern: #"BER\(preBCH\)\s+([0-9.eE+-]+)"#)
    private static let mbpsRe = try! NSRegularExpression(pattern: #"TS\s+([\d.]+) Mbps"#)
    private static let teiRe = try! NSRegularExpression(pattern: #"TEI (\d+)\s+CC-err (\d+)"#)

    init() {
        driverPath = UserDefaults.standard.string(forKey: "driverPath")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("hdtvmate/driver")
        let ud = UserDefaults.standard
        volume = ud.object(forKey: "volume") as? Double ?? 100
        showDRM = ud.bool(forKey: "showDRM")
        resumeOnLaunch = ud.object(forKey: "resumeOnLaunch") as? Bool ?? true
        favorites = Set(ud.stringArray(forKey: "favorites") ?? [])
        player.set("volume", String(Int(volume)))
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        player.onPlaybackStart = { [weak self] in self?.videoStarted = true }
        player.onLog = { [weak self] line in
            guard let self = self, self.playing != nil else { return }
            self.appendLog(line)
        }
        loadChannels()
        tunerMonitor.onChange = { [weak self] (connected: Bool, initial: Bool) in
            self?.tunerChanged(connected, initial: initial)
        }
        tunerMonitor.start()
    }

    // MARK: tuner plugged in / unplugged

    private func tunerChanged(_ connected: Bool, initial: Bool) {
        tunerConnected = connected
        if initial { return }
        if connected {
            showNotice("HDTV Mate detected")
        } else {
            showNotice("HDTV Mate disconnected")
            if playing != nil {
                lastError = "The HDTV Mate was unplugged. Plug it back in and pick a channel."
                job?.terminate()
            }
        }
    }

    func showNotice(_ text: String) {
        noticeHide?.cancel()
        notice = text
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    static func mhz(_ rf: Int) -> Int {
        switch rf {
        case 2...4: return 57 + (rf - 2) * 6
        case 5...6: return 79 + (rf - 5) * 6
        case 7...13: return 177 + (rf - 7) * 6
        default: return 473 + (rf - 14) * 6
        }
    }

    var driverOK: Bool {
        FileManager.default.isExecutableFile(atPath: (effectiveDriver as NSString).appendingPathComponent("hdtvmate"))
    }

    func loadChannels() {
        let url = URL(fileURLWithPath: dataPath).appendingPathComponent("channels.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Channel].self, from: data) else {
            channels = []
            return
        }
        channels = list
    }

    // MARK: channel list helpers

    /// Channels in sidebar order: ATSC 3.0 first, then ATSC 1.0; DRM ones only if enabled.
    var visibleChannels: [Channel] {
        let vis = channels.filter { showDRM || !$0.isDRM }
        return ["3.0", "1.0"].flatMap { std in vis.filter { $0.std == std } }
    }

    var weakSignal: Bool {
        guard playing != nil, stats.t > 2 else { return false }
        if !stats.locked { return true }
        return playing?.isATSC3 == false && (stats.snr ?? 99) < 15.5
    }

    func step(_ delta: Int) {
        let list = visibleChannels.filter { !$0.isDRM }
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == playing?.id } ?? (delta > 0 ? -1 : 0)
        let n = ((i + delta) % list.count + list.count) % list.count
        play(list[n])
    }

    func toggleFavorite(_ ch: Channel) {
        if favorites.contains(ch.id) { favorites.remove(ch.id) } else { favorites.insert(ch.id) }
    }

    func resumeIfNeeded() {
        guard !didResume else { return }
        didResume = true
        guard resumeOnLaunch, driverOK,
              let id = UserDefaults.standard.string(forKey: "lastChannel"),
              let ch = channels.first(where: { $0.id == id }) else { return }
        play(ch)
    }

    // MARK: playback

    func play(_ ch: Channel, force: Bool = false) {
        if ch.isDRM || scanning { return }
        if !force, playing?.id == ch.id { return }
        stopRecording()
        UserDefaults.standard.set(ch.id, forKey: "lastChannel")
        playing = ch
        videoStarted = false
        stats = Stats()
        history = []
        status = "Tuning RF \(ch.rf) (\(TVModel.mhz(ch.rf)) MHz)…"
        player.stop()
        if let job = job {
            queued = { [weak self] in self?.start(ch) }
            job.terminate()
        } else {
            start(ch)
        }
    }

    private func start(_ ch: Channel) {
        guard playing?.id == ch.id else { return }
        userStopped = false
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { status = "Couldn't create a pipe for the video."; return }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        let d = shq(effectiveDriver)
        lastError = nil
        let cmd: String
        if ch.isATSC3 {
            cmd = "cd \(d) && ./hdtvmate tune \(ch.rf) -w - | python3 tools/atsc3play.py --service \(shq(ch.vchan)) --play --mux-out /dev/stdout"
                + (audioLang.isEmpty ? "" : " --lang \(shq(audioLang))")
        } else {
            let map = ch.program.map { "-map 0:p:\($0)" } ?? "-map 0"
            cmd = "cd \(d) && ./hdtvmate tune \(ch.rf) -1 -o - | ffmpeg -nostdin -hide_banner -loglevel error -i - \(map) -c copy -f mpegts -"
        }
        resetLog("$ " + cmd)
        appendLog("[app] streaming to mpv through pipe fd \(fds[0])")
        player.set("deinterlace", ch.isATSC3 ? "no" : "yes")
        player.set("sub-visibility", captionsOn ? "yes" : "no")
        job = Job.spawn(cmd, env: env, stdoutFD: fds[1],
                        onLine: { [weak self] l in self?.handleLine(l) },
                        onExit: { [weak self] s in self?.jobExited(s) })
        close(fds[1])
        if job == nil {
            close(fds[0])
            status = "Couldn't start the tuner."
            return
        }
        player.load("fdclose://\(fds[0])")
    }

    func stop() {
        userStopped = true
        stopRecording()
        player.stop()
        job?.terminate()
        playing = nil
        videoStarted = false
        status = "Pick a channel"
    }

    func shutdown() {
        stopRecording()
        job?.terminateNow()
        player.shutdown()
    }

    private func jobExited(_ code: Int32) {
        job = nil
        if let q = queued { queued = nil; q(); return }
        if scanning {
            scanning = false
            loadChannels()
            return
        }
        if playing != nil && !userStopped {
            stopRecording()
            player.stop()
            playing = nil
            status = lastError ?? "The tuner stopped. Check the log for details."
        }
        userStopped = false
    }

    // MARK: log (also mirrored to <driver>/app.log for debugging)

    // The on-screen log is published at most a few times a second: publishing every
    // line re-renders the whole window, which starves video drawing on slower Macs.
    private var logBuf: [String] = []
    private var logFlushPending = false
    private static let logTimeFormat: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private func resetLog(_ first: String) {
        logBuf = [first]
        log = logBuf
        let path = (dataPath as NSString).appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: path, contents: nil)
        logFile = FileHandle(forWritingAtPath: path)
        writeLog(first)
    }

    private func appendLog(_ line: String) {
        logBuf.append(line)
        if logBuf.count > 400 { logBuf.removeFirst(logBuf.count - 400) }
        writeLog(line)
        if !logFlushPending {
            logFlushPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.logFlushPending = false
                self.log = self.logBuf
            }
        }
    }

    private func writeLog(_ line: String) {
        let stamp: String = TVModel.logTimeFormat.string(from: Date())
        if let d = (stamp + " " + line + "\n").data(using: .utf8) {
            logFile?.write(d)
        }
    }

    // MARK: tuner output

    private func handleLine(_ line: String) {
        appendLog(line)
        if line.contains("not found. Is the stick plugged in") {
            lastError = "HDTV Mate not found. Plug in the stick and try again."
        } else if line.contains("cannot open firmware") {
            lastError = "Tuner firmware is missing."
        }
        let ns = line as NSString
        let r = NSRange(location: 0, length: ns.length)
        guard let m = TVModel.statRe.firstMatch(in: line, range: r) else { return }
        var s = stats
        s.t = Int(ns.substring(with: m.range(at: 1))) ?? 0
        s.flags = ns.substring(with: m.range(at: 2))
        s.rf = Double(ns.substring(with: m.range(at: 3)))
        s.snr = Double(ns.substring(with: m.range(at: 4)))
        if let b = TVModel.berRe.firstMatch(in: line, range: r) { s.ber = Double(ns.substring(with: b.range(at: 1))) }
        if let b = TVModel.mbpsRe.firstMatch(in: line, range: r) { s.mbps = Double(ns.substring(with: b.range(at: 1))) }
        if let b = TVModel.teiRe.firstMatch(in: line, range: r) {
            s.tei = Int(ns.substring(with: b.range(at: 1)))
            s.ccErr = Int(ns.substring(with: b.range(at: 2)))
        }
        stats = s
        history.append(StatPoint(time: Date(), rf: s.rf ?? 0, snr: s.snr ?? 0, mbps: s.mbps ?? 0))
        if history.count > 300 { history.removeFirst(history.count - 300) }
        if let ch = playing {
            status = "ATSC \(ch.std) · RF \(ch.rf) (\(TVModel.mhz(ch.rf)) MHz) · \(s.locked ? "locked" : "searching") · \(s.t) s"
        }
    }

    // MARK: scan

    func scan(_ first: Int, _ last: Int) {
        guard !scanning else { return }
        let begin = { [weak self] in
            guard let self = self else { return }
            self.scanning = true
            self.scanMessage = "Starting scan…"
            let cmd = "cd \(self.shq(self.effectiveDriver)) && python3 tools/tvui.py --scan \(first) \(last)"
            self.resetLog("$ " + cmd)
            self.job = Job.spawn(cmd, env: self.env,
                                 onLine: { [weak self] l in self?.handleScanLine(l) },
                                 onExit: { [weak self] s in self?.jobExited(s) })
            if self.job == nil { self.scanning = false; self.scanMessage = "Couldn't start the scan." }
        }
        if job != nil {
            stop()
            queued = begin
        } else {
            begin()
        }
    }

    private func handleScanLine(_ line: String) {
        appendLog(line)
        if line.contains("not found. Is the stick plugged in") {
            scanMessage = "HDTV Mate not found. Plug in the stick and scan again."
        }
        if line.hasPrefix("PROGRESS: ") && !scanMessage.hasPrefix("HDTV Mate not found") { scanMessage = String(line.dropFirst(10)) }
        else if line.hasPrefix("DONE: ") { scanMessage = String(line.dropFirst(6)) }
    }

    // MARK: setup (firmware import, AC-4 decoder)

    func importFirmware(from url: URL) {
        runSetup("Importing firmware…",
                 "python3 tools/extract_fw.py \(shq(url.path)) \(shq(importedFirmware)) 1>&2") { [weak self] ok in
            self?.setupMessage = ok ? "Stock firmware imported. Unplug the stick and plug it back in to load it."
                                    : "Couldn't extract firmware from that file. Pick the HDTVPlayer .apk or liba3_phy_sony.so."
        }
    }

    func installAC4() {
        runSetup("Building the AC-4 audio decoder. This takes a few minutes…",
                 "bash tools/install_ac4.sh \(shq(TVModel.appSupport)) 1>&2") { [weak self] ok in
            self?.setupMessage = ok ? "AC-4 decoder installed. ATSC 3.0 channels now play with sound."
                                    : "The AC-4 build failed. Open the log for details."
        }
    }

    private func runSetup(_ message: String, _ command: String, done: @escaping (Bool) -> Void) {
        guard !setupBusy else { return }
        setupBusy = true
        setupMessage = message
        resetLog("$ " + command)
        setupJob = Job.spawn("cd \(shq(effectiveDriver)) && " + command, env: env,
                             onLine: { [weak self] l in
                                 self?.appendLog(l)
                                 if l.hasPrefix("STEP: ") { self?.setupMessage = String(l.dropFirst(6)) }
                             },
                             onExit: { [weak self] status in
                                 self?.setupBusy = false
                                 self?.setupJob = nil
                                 done(status == 0)
                                 self?.objectWillChange.send()
                             })
        if setupJob == nil { setupBusy = false; done(false) }
    }

    // MARK: recording

    func toggleRecord() {
        if recordingURL != nil { stopRecording(); return }
        guard let ch = playing else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/HDTV Mate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeName = ch.name.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(ch.label) \(safeName) \(df.string(from: Date())).mkv")
        player.set("stream-record", url.path)
        recordingURL = url
        recordingStart = Date()
    }

    func stopRecording() {
        guard let url = recordingURL else { return }
        player.set("stream-record", "")
        recordingURL = nil
        recordingStart = nil
        lastRecording = url
    }

    private func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
