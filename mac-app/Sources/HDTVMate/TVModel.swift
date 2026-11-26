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

/// What mpv is actually playing, formatted for the side panel.
struct VideoInfo: Equatable {
    var resolution: String?
    var fps: String?
    var codec: String?
    var decoding: String?
    var dynamicRange: String?
    var dropped: String?
    var audio: String?

    init() {}

    init(_ v: [String: String]) {
        if let w = v["video-params/w"].flatMap({ Int($0) }), let h = v["video-params/h"].flatMap({ Int($0) }), w > 0, h > 0 {
            let scan: String = v["video-frame-info/interlaced"] == "yes" ? "i" : "p"
            resolution = "\(w)×\(h) (\(h)\(scan))"
        }
        let shown: Double? = v["estimated-vf-fps"].flatMap { Double($0) }
        let stream: Double? = v["container-fps"].flatMap { Double($0) }
        if let a = shown, a > 0 {
            if let b = stream, b > 0, abs(a - b) > 0.5 {
                fps = String(format: "%.2f (stream %.2f)", a, b)
            } else {
                fps = String(format: "%.2f", a)
            }
        } else if let b = stream, b > 0 {
            fps = String(format: "%.2f", b)
        }
        if let c = v["video-format"], !c.isEmpty {
            let names: [String: String] = ["hevc": "HEVC (H.265)", "h264": "H.264", "mpeg2video": "MPEG-2", "vvc": "VVC (H.266)"]
            codec = names[c] ?? c.uppercased()
        }
        if let hw = v["hwdec-current"] {
            if hw.isEmpty || hw == "no" { decoding = "Software" }
            else if hw.hasPrefix("videotoolbox") { decoding = "Hardware (VideoToolbox)" }
            else { decoding = "Hardware (\(hw))" }
        }
        if let g = v["video-params/gamma"], !g.isEmpty {
            dynamicRange = g == "pq" ? "HDR10 (PQ)" : g == "hlg" ? "HDR (HLG)" : "SDR"
        }
        let vo: Int? = v["frame-drop-count"].flatMap { Int($0) }
        let dec: Int? = v["decoder-frame-drop-count"].flatMap { Int($0) }
        if vo != nil || dec != nil { dropped = String((vo ?? 0) + (dec ?? 0)) }
        if let a = v["audio-codec-name"], !a.isEmpty {
            var parts: [String] = [a.hasPrefix("pcm") ? "PCM" : a.uppercased().replacingOccurrences(of: "_", with: "-")]
            if let ch = v["audio-params/channel-count"].flatMap({ Int($0) }) {
                parts.append(ch == 6 ? "5.1" : ch == 2 ? "stereo" : ch == 1 ? "mono" : "\(ch) ch")
            }
            if let sr = v["audio-params/samplerate"].flatMap({ Double($0) }) {
                parts.append(String(format: "%g kHz", sr / 1000))
            }
            audio = parts.joined(separator: " · ")
        }
    }
}

/// Where new recordings are saved.
enum RecordPlace: String, CaseIterable {
    case movies, tunerCard, folder
}

/// Free space where the current recording is going, for the REC badge.
struct RecordSpace: Equatable {
    let place: String
    let freeBytes: Int64
    let secondsLeft: Double?

    var text: String {
        var s = "\(place) · \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free"
        if let left = secondsLeft {
            let m = Int(left / 60)
            s += m >= 120 ? " · ~\(m / 60) h left" : " · ~\(m) min left"
        }
        return s
    }
}

/// Where playback sits in the pause & rewind buffer (all in mpv playback seconds).
struct Timeshift: Equatable {
    var start: Double
    var end: Double
    var pos: Double
    var paused: Bool
    var behind: Double { max(0, end - pos) }
    var atLive: Bool { !paused && behind < 4 }
    var length: Double { max(0, end - start) }
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
    @Published var video = VideoInfo()
    private var infoTimer: Timer?
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
    @Published var recordPlace: RecordPlace {
        didSet { UserDefaults.standard.set(recordPlace.rawValue, forKey: "recordPlace") }
    }
    @Published var recordFolder: String {
        didSet { UserDefaults.standard.set(recordFolder, forKey: "recordFolder") }
    }
    /// Mounted SD card in the HDTV Mate's own slot, if any.
    @Published var tunerCardURL: URL?
    @Published var recordSpace: RecordSpace?
    private var recordTimer: Timer?
    private var recordingPartStart: Date?
    private var recordingIsHEVC = false
    private var recordingIsMPEG2 = false
    /// MPEG-2 (most ATSC 1.0 stations): macOS can't decode it, so re-encode the video to H.264.
    @Published var convertMPEG2: Bool {
        didSet { UserDefaults.standard.set(convertMPEG2, forKey: "convertMPEG2") }
    }
    @Published var recordFormat: String {
        didSet { UserDefaults.standard.set(recordFormat, forKey: "recordFormat") }
    }
    @Published var convertingCount = 0
    private var warnedLowSpace = false
    @Published var driverPath: String {
        didSet { UserDefaults.standard.set(driverPath, forKey: "driverPath"); loadChannels() }
    }

    private var logFile: FileHandle?
    private let tunerMonitor = TunerMonitor()
    private var noticeHide: DispatchWorkItem?
    private var job: Job?
    private var tap: StreamTap?
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
        recordPlace = RecordPlace(rawValue: ud.string(forKey: "recordPlace") ?? "") ?? .movies
        recordFolder = ud.string(forKey: "recordFolder") ?? ""
        recordFormat = ud.string(forKey: "recordFormat") == "ts" ? "ts" : "mp4"
        convertMPEG2 = ud.object(forKey: "convertMPEG2") as? Bool ?? true
        timeshiftMinutes = ud.object(forKey: "timeshiftMinutes") as? Int ?? 30
        player.configureTimeshift(minutes: timeshiftMinutes, dir: TVModel.timeshiftDir)
        player.set("volume", String(Int(volume)))
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.now = Date()
            self?.maybeRefreshGuide()
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
        watchVolumes()
        refreshTunerCard()
        infoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshPlayerState()
        }
    }

    // MARK: pause & rewind

    static let timeshiftDir: String = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HDTV Mate/Timeshift", isDirectory: true).path
    }()

    @Published var timeshift: Timeshift?
    @Published var timeshiftMinutes: Int {
        didSet {
            UserDefaults.standard.set(timeshiftMinutes, forKey: "timeshiftMinutes")
            player.configureTimeshift(minutes: timeshiftMinutes, dir: TVModel.timeshiftDir)
            if playing != nil { showNotice("The new pause buffer takes effect when you change channels.") }
        }
    }

    private func refreshPlayerState() {
        let snap: [String: String] = playing == nil ? [:] : player.infoSnapshot()
        let info: VideoInfo = playing == nil ? VideoInfo() : VideoInfo(snap)
        if info != video { video = info }
        var ts: Timeshift? = nil
        if videoStarted, let pos = snap["time-pos"].flatMap(Double.init),
           let start = snap["buffer-start"].flatMap(Double.init), let end = snap["buffer-end"].flatMap(Double.init) {
            ts = Timeshift(start: min(start, pos), end: max(end, pos), pos: pos, paused: snap["pause"] == "yes")
        }
        if ts != timeshift { timeshift = ts }
    }

    var canTimeshift: Bool { playing != nil && videoStarted && timeshiftMinutes > 0 }

    func togglePause() {
        guard playing != nil, videoStarted else { return }
        let paused = timeshift?.paused ?? false
        if !paused && timeshiftMinutes == 0 {
            showNotice("Turn on Pause & rewind in Settings to pause live TV.")
            return
        }
        player.set("pause", paused ? "no" : "yes")
        soonRefresh()
    }

    /// Jump `seconds` back (negative) or forward within the buffer.
    func skip(_ seconds: Double) {
        guard canTimeshift, let t = timeshift else { return }
        if seconds > 0 && t.behind < 2 { return }
        seek(to: t.pos + seconds)
    }

    /// Seek to a playback time, clamped to what's buffered (1 s short of live).
    func seek(to time: Double) {
        guard canTimeshift, let t = timeshift else { return }
        let target = min(t.end - 1, max(t.start, time))
        player.command(["seek", String(format: "%.3f", target), "absolute"])
        soonRefresh()
    }

    func goLive() {
        guard canTimeshift, let t = timeshift else { return }
        player.command(["seek", String(format: "%.3f", t.end - 1), "absolute"])
        player.set("pause", "no")
        soonRefresh()
    }

    private func soonRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refreshPlayerState() }
    }

    // MARK: tuner plugged in / unplugged

    private func tunerChanged(_ connected: Bool, initial: Bool) {
        tunerConnected = connected
        refreshTunerCard()
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

    /// Reload channels.json (e.g. after a guide update) without disturbing playback.
    func reloadChannels() {
        loadChannels()
        if let p = playing, let fresh = channels.first(where: { $0.id == p.id }), fresh != p { playing = fresh }
    }

    // MARK: guide refresh

    @Published var guideRefreshing = false
    @Published var guideMessage = ""
    private var idleSince = Date()
    private static let guideInterval: TimeInterval = 2 * 3600

    var lastGuideRefresh: Date? {
        get { UserDefaults.standard.object(forKey: "lastGuideRefresh") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastGuideRefresh") }
    }

    /// Hours of guide data left for the 1.0 channel that runs out soonest (among those that have any).
    private var guideHoursLeft: Double? {
        let t = Date().timeIntervalSince1970
        let ends: [Double] = channels.filter { !$0.isATSC3 }.compactMap { ch in
            (ch.epg ?? []).map { $0.end }.max()
        }
        return ends.min().map { ($0 - t) / 3600 }
    }

    /// Called every 30 s: refresh the whole guide when the tuner has been idle for a bit
    /// and the guide is old or about to run out.
    private func maybeRefreshGuide() {
        guard job == nil, playing == nil, !scanning, tunerConnected, driverOK,
              Date().timeIntervalSince(idleSince) > 90,
              channels.contains(where: { !$0.isATSC3 }) else { return }
        let age: TimeInterval = lastGuideRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
        let runningOut: Bool = (guideHoursLeft ?? 0) < 4 && age > 20 * 60
        if age > TVModel.guideInterval || runningOut { refreshGuide() }
    }

    /// Visit every ATSC 1.0 frequency for a few seconds and update the guide. Picking a
    /// channel cancels it (the tuner is needed for playback).
    func refreshGuide() {
        guard job == nil, !scanning, driverOK else { return }
        lastGuideRefresh = Date()
        guideRefreshing = true
        guideMessage = "Updating guide…"
        let cmd = "cd \(shq(effectiveDriver)) && python3 tools/guide.py refresh"
        resetLog("$ " + cmd)
        job = Job.spawn(cmd, env: env,
                        onLine: { [weak self] l in
                            guard let self = self else { return }
                            self.appendLog(l)
                            if l.hasPrefix("PROGRESS: ") { self.guideMessage = String(l.dropFirst(10)) }
                            else if l.hasPrefix("GUIDE: ") { self.reloadChannels() }
                            else if l.hasPrefix("DONE: ") { self.guideMessage = String(l.dropFirst(6)) }
                        },
                        onExit: { [weak self] s in self?.jobExited(s) })
        if job == nil { guideRefreshing = false; guideMessage = "Couldn't start the guide update." }
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

    /// The same station on the other broadcast standard (ATSC 3.0 <-> 1.0), if the scan found it.
    /// Matched by virtual channel number (e.g. 13.1), else by station name.
    var counterpart: Channel? {
        guard let ch = playing else { return nil }
        let others: [Channel] = channels.filter { $0.std != ch.std && !$0.isDRM }
        if let same = others.first(where: { $0.vchan == ch.vchan }) { return same }
        let name: String = ch.name.trimmingCharacters(in: .whitespaces).lowercased()
        if name.isEmpty { return nil }
        return others.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }
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
            cmd = "cd \(d) && ./hdtvmate tune \(ch.rf) -w - | python3 tools/atsc3play.py --service \(shq(ch.vchan)) --rf \(ch.rf) --play --mux-out /dev/stdout"
                + (audioLang.isEmpty ? "" : " --lang \(shq(audioLang))")
        } else {
            let map = ch.program.map { "-map 0:p:\($0)" } ?? "-map 0"
            // -g hands a copy of the stream to the guide reader (dropped, never blocking, if it lags)
            cmd = "cd \(d) && ./hdtvmate tune \(ch.rf) -1 -o - -g >(exec python3 tools/guide.py live --rf \(ch.rf) >/dev/null) | ffmpeg -nostdin -hide_banner -loglevel error -i - \(map) -c copy -f mpegts -"
        }
        resetLog("$ " + cmd)
        appendLog("[app] streaming to mpv through pipe fd \(fds[0])")
        player.set("deinterlace", ch.isATSC3 ? "no" : "yes")
        player.set("sub-visibility", captionsOn ? "yes" : "no")
        player.set("pause", "no")
        timeshift = nil
        job = Job.spawn(cmd, env: env, stdoutFD: fds[1],
                        onLine: { [weak self] l in self?.handleLine(l) },
                        onExit: { [weak self] s in self?.jobExited(s) })
        close(fds[1])
        if job == nil {
            close(fds[0])
            status = "Couldn't start the tuner."
            return
        }
        // The tap forwards the stream to mpv and copies it to a file while recording.
        guard let t = StreamTap(input: fds[0]) else {
            close(fds[0])
            status = "Couldn't create a pipe for the video."
            job?.terminate()
            return
        }
        tap = t
        player.load("fdclose://\(t.playerFD)")
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
        idleSince = Date()
        if guideRefreshing {
            guideRefreshing = false
            reloadChannels()
        }
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
        if line.hasPrefix("GUIDE: ") {
            reloadChannels()
            return
        }
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

    static let moviesFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/HDTV Mate", isDirectory: true)

    /// Folder recordings go to right now, and whether that's a fallback from the chosen place.
    func recordingFolder() -> (url: URL, fellBack: Bool) {
        switch recordPlace {
        case .tunerCard:
            if let v = tunerCardURL { return (v.appendingPathComponent("HDTV Mate", isDirectory: true), false) }
            return (TVModel.moviesFolder, true)
        case .folder:
            var isDir: ObjCBool = false
            if !recordFolder.isEmpty, FileManager.default.fileExists(atPath: recordFolder, isDirectory: &isDir), isDir.boolValue {
                return (URL(fileURLWithPath: recordFolder, isDirectory: true), false)
            }
            return (TVModel.moviesFolder, true)
        case .movies:
            return (TVModel.moviesFolder, false)
        }
    }

    func toggleRecord() {
        if recordingURL != nil { stopRecording(); return }
        guard playing != nil else { return }
        let (dir, fellBack) = recordingFolder()
        if fellBack {
            showNotice(recordPlace == .tunerCard ? "No SD card in the HDTV Mate. Recording to Movies instead."
                                                 : "Recording folder not found. Recording to Movies instead.")
        }
        guard startRecording(in: dir, suffix: "") else { return }
        recordingStart = Date()
        warnedLowSpace = false
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkRecordingSpace() }
        checkRecordingSpace()
    }

    @discardableResult
    private func startRecording(in dir: URL, suffix: String) -> Bool {
        guard let ch = playing else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            showNotice("Can't write to \(dir.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeName = ch.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        // Written as MPEG-TS while recording (survives a crash or a pulled card),
        // converted to MP4 when the recording stops if that's the chosen format.
        let url = dir.appendingPathComponent("\(ch.label) \(safeName) \(df.string(from: Date()))\(suffix).ts")
        guard let tap = tap else {
            showNotice("Recording needs the stream to be running. Try again in a moment.")
            return false
        }
        do {
            try tap.startRecording(to: url.path)
        } catch {
            showNotice("Can't record to \(dir.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        appendLog("[app] recording to \(url.path)")
        recordingURL = url
        recordingIsHEVC = ch.isATSC3
        recordingIsMPEG2 = !ch.isATSC3 && player.infoSnapshot()["video-format"] == "mpeg2video"
        recordingPartStart = Date()
        return true
    }

    func stopRecording() {
        guard let url = recordingURL else { return }
        finishPart(url)
        recordTimer?.invalidate()
        recordTimer = nil
        recordingURL = nil
        recordingStart = nil
        recordSpace = nil
    }

    /// Close the current file and, for MP4, convert it once everything is on disk.
    private func finishPart(_ url: URL) {
        let hevc = recordingIsHEVC
        let reencode = recordingIsMPEG2 && convertMPEG2
        let format = recordFormat
        lastRecording = url
        let after: () -> Void = { [weak self] in
            guard let self = self else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size == 0 {
                if self.lastRecording == url { self.lastRecording = nil }
                try? FileManager.default.removeItem(at: url)
                return
            }
            if format == "mp4" { self.convertToMP4(url, hevc: hevc, reencode: reencode) }
        }
        if let tap = tap { tap.stopRecording(done: after) } else { after() }
    }

    /// Turn the .ts into an .mp4 next to it, then delete the .ts. The video is copied as is,
    /// except MPEG-2 (when `reencode`), which becomes H.264 from the Mac's hardware encoder:
    /// deinterlaced (1080i -> 1080p at the same frame rate), captions carried over, audio copied.
    /// If the hardware encoder isn't available it falls back to a plain copy.
    private func convertToMP4(_ ts: URL, hevc: Bool, reencode: Bool = false) {
        let mp4 = ts.deletingPathExtension().appendingPathExtension("mp4")
        let part = ts.deletingPathExtension().appendingPathExtension("converting.mp4")
        let input = "ffmpeg -nostdin -hide_banner -loglevel error -y -i \(shq(ts.path))"
        let copy = "\(input) -map 0:v? -map 0:a? -c copy" + (hevc ? " -tag:v hvc1" : "") + " -f mp4 \(shq(part.path))"
        let h264 = "\(input) -map 0:v:0 -map 0:a? -vf bwdif=mode=send_frame:deint=interlaced -c:v h264_videotoolbox"
            + " -profile:v high -b:v 8M -maxrate 12M -bufsize 16M -c:a copy -f mp4 \(shq(part.path))"
        let cmd = (reencode ? "{ \(h264) || \(copy); }" : copy) + " && mv -f \(shq(part.path)) \(shq(mp4.path))"
        if reencode { showNotice("Converting the recording so it plays in QuickTime…") }
        convertingCount += 1
        var errors: [String] = []
        let started = Job.spawn(cmd, env: env,
                                onLine: { line in errors.append(line) },
                                onExit: { [weak self] status in
                                    guard let self = self else { return }
                                    self.convertingCount -= 1
                                    if status == 0, FileManager.default.fileExists(atPath: mp4.path) {
                                        try? FileManager.default.removeItem(at: ts)
                                        if self.lastRecording == ts { self.lastRecording = mp4 }
                                        self.showNotice("Recording saved: \(mp4.lastPathComponent)")
                                    } else {
                                        try? FileManager.default.removeItem(at: part)
                                        self.appendLog("[app] MP4 conversion failed: " + errors.suffix(3).joined(separator: " | "))
                                        self.showNotice("Couldn't convert to MP4, so the recording was kept as .ts.")
                                    }
                                })
        if started == nil {
            convertingCount -= 1
            showNotice("Couldn't convert to MP4, so the recording was kept as .ts.")
        }
    }

    /// Keep recording in the Movies folder when the SD card disappears or fills up.
    private func continueInMovies(_ why: String) {
        guard let current = recordingURL else { return }
        finishPart(current)
        if startRecording(in: TVModel.moviesFolder, suffix: " (continued)") {
            showNotice(why + " Recording continues in Movies.")
        }
        checkRecordingSpace()
    }

    private func checkRecordingSpace() {
        guard let url = recordingURL else { recordSpace = nil; return }
        let dir = url.deletingLastPathComponent()
        guard let free = TunerCard.freeBytes(at: dir) else { recordSpace = nil; return }
        let (size, failure) = tap?.status ?? (0, "the stream stopped")
        let secs = Date().timeIntervalSince(recordingPartStart ?? Date())
        let onSDOrDrive = !dir.path.hasPrefix(TVModel.moviesFolder.path)
        if let failure = failure {
            if onSDOrDrive {
                continueInMovies("Can't write to \(dir.lastPathComponent) (\(failure)).")
            } else {
                stopRecording()
                showNotice("Recording stopped: \(failure).")
            }
            return
        }
        if size == 0 && secs > 10 {
            stopRecording()
            showNotice("Recording stopped: no video was received.")
            return
        }
        let rate: Double? = secs > 8 && size > 0 ? Double(size) / secs : nil
        let onCard = tunerCardURL.map { url.path.hasPrefix($0.path + "/") } ?? false
        recordSpace = RecordSpace(place: onCard ? "SD card" : dir.lastPathComponent, freeBytes: free,
                                  secondsLeft: rate.map { Double(free) / $0 })
        let moviesPath = TVModel.moviesFolder.path
        if free < 300_000_000 && !dir.path.hasPrefix(moviesPath) {
            continueInMovies(onCard ? "The SD card is full." : "The recording drive is full.")
        } else if let left = recordSpace?.secondsLeft, left < 600, !warnedLowSpace, !dir.path.hasPrefix(moviesPath) {
            warnedLowSpace = true
            showNotice("\(onCard ? "SD card" : "Drive") almost full: about \(Int(left / 60)) min of recording left.")
        }
    }

    // MARK: the tuner's SD card

    func refreshTunerCard() {
        let found: URL? = tunerConnected ? TunerCard.mountedVolume() : nil
        if found != tunerCardURL { tunerCardURL = found }
        if found != nil, recordPlace == .movies, !UserDefaults.standard.bool(forKey: "askedTunerCard") {
            UserDefaults.standard.set(true, forKey: "askedTunerCard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.offerTunerCard() }
        }
    }

    private func offerTunerCard() {
        guard let card = tunerCardURL else { return }
        let alert = NSAlert()
        alert.messageText = "Save recordings to the HDTV Mate's SD card?"
        let free = TunerCard.freeBytes(at: card).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        alert.informativeText = "There's a card in the tuner's slot (\(card.lastPathComponent)\(free.map { ", \($0) free" } ?? "")). "
            + "You can change this any time in Settings."
        alert.addButton(withTitle: "Use SD Card")
        alert.addButton(withTitle: "Keep Using Movies")
        if alert.runModal() == .alertFirstButtonReturn { recordPlace = .tunerCard }
    }

    private func watchVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshTunerCard()
        }
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self = self else { return }
                if let vol = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                   let rec = self.recordingURL, rec.path.hasPrefix(vol.path + "/") {
                    self.continueInMovies(self.tunerCardURL?.path == vol.path ? "The SD card was removed." : "The recording drive was removed.")
                }
                if name == NSWorkspace.didUnmountNotification { self.refreshTunerCard() }
            }
        }
    }

    private func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
