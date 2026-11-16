import SwiftUI
import Charts

private func timeRange(_ e: EPGEvent) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return "\(f.string(from: Date(timeIntervalSince1970: e.start)))–\(f.string(from: Date(timeIntervalSince1970: e.end)))"
}

struct ContentView: View {
    @EnvironmentObject var tv: TVModel
    @AppStorage("showSignal") private var showSignal = true
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var theater = false
    @State private var signalBeforeTheater = true
    @State private var showGuide = false
    @State private var showLog = false
    @State private var controlsVisible = false
    @State private var hideControls: DispatchWorkItem?
    @State private var lastHover: CGPoint?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ChannelList()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    PlayerArea(onDoubleClick: toggleTheater)
                    if theater && controlsVisible {
                        ControlBar(showMeters: true)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
                            .frame(maxWidth: 1100)
                            .padding(.horizontal, 40)
                            .padding(.bottom, 28)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    if let note = tv.notice {
                        Text(note)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: tv.notice)
                .onContinuousHover { phase in
                    guard theater, case .active(let p) = phase else { return }
                    // ignore sub-pixel jitter so the controls only appear when you actually move the mouse
                    if let last = lastHover, abs(last.x - p.x) + abs(last.y - p.y) < 6 { return }
                    lastHover = p
                    pokeControls()
                }
                if !theater {
                    Divider()
                    ControlBar(showMeters: !showSignal)
                }
            }
            .onExitCommand { if theater { toggleTheater() } }
            // side panel (works on macOS 13; .inspector needs 14)
            if showSignal && !theater {
                Divider()
                SignalPanel()
                    .frame(width: 300)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing))
            }
            }
        }
        .navigationTitle(tv.playing.map { "\($0.label)  \($0.name)" } ?? "HDTV Mate")
        .navigationSubtitle(tv.playing.flatMap { $0.nowAndNext(tv.now).0?.title } ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(tv.tunerConnected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(tv.tunerConnected ? "Tuner connected" : "No tuner")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .help(tv.tunerConnected ? "The HDTV Mate is plugged in" : "Plug in the HDTV Mate USB tuner")
                Menu {
                    Button("Scan UHF 14–36") { tv.scan(14, 36) }
                    Button("Scan all channels 2–36") { tv.scan(2, 36) }
                } label: {
                    Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(tv.scanning)
                .help("Scan for channels")
                Button { showGuide = true } label: { Label("Guide", systemImage: "list.bullet.rectangle") }
                    .help("Program guide")
                Button { showLog = true } label: { Label("Log", systemImage: "terminal") }
                    .help("Tuner and player log")
                Button { showSignal.toggle() } label: { Label("Signal", systemImage: "waveform.path.ecg") }
                    .help("Show or hide signal details")
            }
        }
        .toolbar(theater ? .hidden : .visible, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            guard theater, let w = n.object as? NSWindow else { return }
            w.toolbar?.isVisible = false
            w.titlebarAppearsTransparent = true
            NSApp.presentationOptions = [.fullScreen, .autoHideToolbar, .autoHideMenuBar, .autoHideDock]
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { n in
            if let w = n.object as? NSWindow {
                w.toolbar?.isVisible = true
                w.titlebarAppearsTransparent = false
            }
            if theater { leaveTheater() }
        }
        .sheet(isPresented: $showGuide) { GuideView().environmentObject(tv) }
        .sheet(isPresented: $showLog) { LogView().environmentObject(tv) }
        .onAppear { tv.resumeIfNeeded() }
    }

    /// Double-click the video (or press Esc to leave): full screen with nothing but the picture.
    private func toggleTheater() {
        let window = NSApp.keyWindow ?? NSApp.windows.first
        let isFull = window?.styleMask.contains(.fullScreen) ?? false
        if theater {
            leaveTheater()
            if isFull { window?.toggleFullScreen(nil) }
        } else {
            signalBeforeTheater = showSignal
            withAnimation(.easeInOut(duration: 0.2)) {
                theater = true
                columns = .detailOnly
                showSignal = false
            }
            if !isFull { window?.toggleFullScreen(nil) }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func leaveTheater() {
        hideControls?.cancel()
        lastHover = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            theater = false
            controlsVisible = false
            columns = .all
            showSignal = signalBeforeTheater
        }
    }

    /// In full screen the control bar appears when the mouse moves and fades after a moment.
    private func pokeControls() {
        if !controlsVisible { withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true } }
        hideControls?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.3)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideControls = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

// MARK: - Channels

struct ChannelList: View {
    @EnvironmentObject var tv: TVModel
    @State private var query = ""

    private func matches(_ c: Channel) -> Bool {
        query.isEmpty || c.name.localizedCaseInsensitiveContains(query) || c.label.hasPrefix(query)
    }

    var body: some View {
        let all = tv.visibleChannels.filter(matches)
        let favs = all.filter { tv.favorites.contains($0.id) }
        List(selection: Binding<String?>(
            get: { tv.playing?.id },
            set: { id in
                if let id = id, let ch = tv.channels.first(where: { $0.id == id }) { tv.play(ch) }
            })) {
            if !favs.isEmpty {
                Section("Favorites") {
                    ForEach(favs) { ch in row(ch) }
                }
            }
            ForEach(["3.0", "1.0"], id: \.self) { std in
                let list = all.filter { $0.std == std && !tv.favorites.contains($0.id) }
                if !list.isEmpty {
                    Section("ATSC \(std)") {
                        ForEach(list) { ch in row(ch) }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search channels")
        .overlay {
            if tv.scanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(tv.scanMessage).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            } else if tv.channels.isEmpty {
                EmptyState(title: "No channels yet", systemImage: "antenna.radiowaves.left.and.right",
                           message: tv.driverOK ? "Plug in the HDTV Mate and antenna, then click Scan." :
                                "Can't find the hdtvmate driver. Set the driver folder in Settings.") {
                    Button("Scan UHF 14–36") { tv.scan(14, 36) }.disabled(!tv.driverOK)
                }
            } else if all.isEmpty {
                EmptyState(title: "No results", systemImage: "magnifyingglass",
                           message: "No channel matches “\(query)”.") { EmptyView() }
            }
        }
    }

    @ViewBuilder
    private func row(_ ch: Channel) -> some View {
        let fav = tv.favorites.contains(ch.id)
        ChannelRow(ch: ch, now: tv.now, favorite: fav, playing: tv.playing?.id == ch.id)
            .tag(ch.id)
            .contextMenu {
                Button(fav ? "Remove from favorites" : "Add to favorites") { tv.toggleFavorite(ch) }
            }
    }
}

struct ChannelRow: View {
    let ch: Channel
    let now: Date
    let favorite: Bool
    let playing: Bool

    var body: some View {
        let event = ch.nowAndNext(now).0
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(ch.label)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ch.name).fontWeight(.medium).lineLimit(1)
                    if ch.isDRM {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    if favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                Text(event?.title ?? "RF \(ch.rf)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if playing {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(ch.isDRM ? 0.45 : 1)
        .help(ch.isDRM ? "This channel is DRM-protected and can't be played." : "ATSC \(ch.std), RF \(ch.rf)")
    }
}

// MARK: - Player

struct MPVViewRep: NSViewRepresentable {
    let player: MPVPlayer
    func makeNSView(context: Context) -> NSView { player.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PlayerArea: View {
    @EnvironmentObject var tv: TVModel
    let onDoubleClick: () -> Void

    var body: some View {
        ZStack {
            Color.black
            MPVViewRep(player: tv.player)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onDoubleClick() }
                .help("Double-click for full screen")
            if tv.playing == nil {
                VStack(spacing: 8) {
                    Image(systemName: "tv").font(.system(size: 42, weight: .light))
                    Text(tv.channels.isEmpty ? "Scan to find channels" : tv.status)
                        .font(.title3)
                }
                .foregroundStyle(.white.opacity(0.6))
                .allowsHitTesting(false)
            } else if !tv.videoStarted {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(tv.status).foregroundStyle(.white.opacity(0.75))
                }
                .allowsHitTesting(false)
            }
            VStack {
                HStack(spacing: 8) {
                    if tv.videoStarted && tv.weakSignal {
                        Label("Weak signal", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.orange, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Spacer()
                    if let start = tv.recordingStart {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Label("REC " + elapsed(from: start, to: ctx.date), systemImage: "record.circle.fill")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.red, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(12)
                Spacer()
            }
            .allowsHitTesting(false)
        }
        .frame(minHeight: 300)
    }

    private func elapsed(from: Date, to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ControlBar: View {
    @EnvironmentObject var tv: TVModel
    let showMeters: Bool

    private var subtitle: String {
        if tv.videoStarted, let ch = tv.playing, let e = ch.nowAndNext(tv.now).0 {
            return "\(e.title) · \(timeRange(e))"
        }
        return tv.status
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(tv.playing == nil ? Color.secondary.opacity(0.5)
                      : (tv.weakSignal ? Color.orange : (tv.stats.locked ? Color.green : Color.secondary.opacity(0.5))))
                .frame(width: 9, height: 9)
                .help(tv.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(tv.playing.map { "\($0.label)  \($0.name)" } ?? "Nothing playing")
                    .font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 140, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 8)
            if showMeters {
                Meter(label: "Signal", value: tv.stats.rf.map { String(format: "%.1f dBm", $0) } ?? "–",
                      fraction: tv.stats.rf.map { ($0 + 95) / 65 } ?? 0, color: .green)
                Meter(label: "SNR", value: tv.stats.snr.map { String(format: "%.1f dB", $0) } ?? "–",
                      fraction: tv.stats.snr.map { ($0 + 3) / 33 } ?? 0,
                      color: (tv.stats.snr ?? 99) < 8 ? Color.red : ((tv.stats.snr ?? 99) < 15 ? Color.orange : Color.green))
            }
            if tv.playing?.isATSC3 == true {
                Picker("Audio", selection: $tv.audioLang) {
                    Text("Main audio").tag("")
                    Text("English").tag("eng")
                    Text("Español").tag("spa")
                    Text("Français").tag("fra")
                }
                .labelsHidden()
                .frame(width: 120)
                .help("Audio language")
            }
            Button { tv.step(-1) } label: { Image(systemName: "chevron.up") }
                .help("Previous channel (⌘↑)")
                .disabled(tv.channels.isEmpty)
            Button { tv.step(1) } label: { Image(systemName: "chevron.down") }
                .help("Next channel (⌘↓)")
                .disabled(tv.channels.isEmpty)
            Toggle(isOn: $tv.captionsOn) {
                Label("Captions", systemImage: "captions.bubble")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Closed captions (ATSC 1.0 for now)")
            Button {
                tv.toggleRecord()
            } label: {
                Label(tv.recordingURL == nil ? "Record" : "Stop recording",
                      systemImage: tv.recordingURL == nil ? "record.circle" : "stop.circle.fill")
            }
            .labelStyle(.iconOnly)
            .tint(tv.recordingURL == nil ? nil : Color.red)
            .help(tv.recordingURL == nil ? "Record (⌘R)" : "Stop recording (⌘R)")
            .disabled(tv.playing == nil)
            if let last = tv.lastRecording, tv.recordingURL == nil {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([last])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show the last recording in Finder")
            }
            Button { tv.muted.toggle() } label: {
                Image(systemName: tv.muted || tv.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(tv.muted ? "Unmute (⇧⌘M)" : "Mute (⇧⌘M)")
            Slider(value: $tv.volume, in: 0...100)
                .controlSize(.small)
                .frame(width: 80)
                .help("Volume")
            Button("Stop") { tv.stop() }
                .disabled(tv.playing == nil)
                .help("Stop (⌘.)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct Meter: View {
    let label: String
    let value: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.caption2)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color)
                        .frame(width: g.size.width * max(0, min(1, fraction)))
                }
            }
            .frame(height: 5)
        }
        .frame(width: 110)
    }
}

// MARK: - Signal details

struct SignalPanel: View {
    @EnvironmentObject var tv: TVModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signal").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Status", tv.playing == nil ? "–" : (tv.stats.locked ? "Locked (\(tv.stats.flags))" : "Searching (\(tv.stats.flags))"))
                row("RF level", tv.stats.rf.map { String(format: "%.2f dBm", $0) } ?? "–")
                row("SNR", tv.stats.snr.map { String(format: "%.2f dB", $0) } ?? "–")
                if tv.playing?.isATSC3 == true {
                    row("BER (pre-BCH)", tv.stats.ber.map { String(format: "%.2e", $0) } ?? "–")
                } else {
                    row("TEI errors", tv.stats.tei.map { String($0) } ?? "–")
                    row("Continuity errors", tv.stats.ccErr.map { String($0) } ?? "–")
                }
                row("Bitrate", tv.stats.mbps.map { String(format: "%.2f Mbps", $0) } ?? "–")
                row("Channel", tv.playing.map { "RF \($0.rf) · \(TVModel.mhz($0.rf)) MHz · ATSC \($0.std)" } ?? "–")
                row("Tuned for", tv.playing == nil ? "–" : "\(tv.stats.t) s")
            }
            chart("SNR (dB)", \.snr, .green)
            chart("RF level (dBm)", \.rf, .blue)
            chart("Bitrate (Mbps)", \.mbps, .orange)
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private func chart(_ title: String, _ kp: KeyPath<StatPoint, Double>, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Chart(tv.history) { p in
                LineMark(x: .value("Time", p.time), y: .value(title, p[keyPath: kp]))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .frame(height: 72)
        }
    }
}

// MARK: - Guide

struct GuideView: View {
    @EnvironmentObject var tv: TVModel
    @Environment(\.dismiss) private var dismiss

    private var guideChannels: [Channel] { tv.visibleChannels.filter { !upcoming($0).isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Program guide").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            List {
                ForEach(guideChannels) { ch in
                    Section("\(ch.label)  \(ch.name)") {
                        ForEach(upcoming(ch), id: \.self) { e in
                            HStack {
                                Text(timeRange(e)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 140, alignment: .leading)
                                Text(e.title.isEmpty ? "Untitled" : e.title)
                                Spacer()
                                if isNow(e) {
                                    Button("Watch") { tv.play(ch); dismiss() }
                                        .controlSize(.small)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { tv.play(ch); dismiss() }
                        }
                    }
                }
            }
            .overlay {
                if guideChannels.isEmpty {
                    EmptyState(title: "No guide data", systemImage: "calendar",
                               message: "Guide data is read from ATSC 1.0 stations during a scan. Scan again to refresh it.") { EmptyView() }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 520)
    }

    private func upcoming(_ ch: Channel) -> [EPGEvent] {
        let t = tv.now.timeIntervalSince1970
        return Array((ch.epg ?? []).filter { $0.end > t }.sorted { $0.start < $1.start }.prefix(8))
    }

    private func isNow(_ e: EPGEvent) -> Bool {
        let t = tv.now.timeIntervalSince1970
        return e.start <= t && t < e.end
    }
}

// MARK: - Log and settings

struct LogView: View {
    @EnvironmentObject var tv: TVModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.title2.weight(.semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tv.log.joined(separator: "\n"), forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(tv.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("end")
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(minWidth: 700, minHeight: 420)
    }
}

struct SettingsView: View {
    @EnvironmentObject var tv: TVModel

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Resume the last channel when the app opens", isOn: $tv.resumeOnLaunch)
                Toggle("Show DRM-protected channels in the list", isOn: $tv.showDRM)
            }
            Section("Tuner firmware") {
                LabeledContent("In use") {
                    Text(tv.hasStockFirmware ? "Stock HDTV Mate firmware (imported)"
                         : (TVModel.bundledStockFirmware ? "Stock HDTV Mate firmware (built in)" : "Generic IT9303 firmware"))
                }
                Text("The stock firmware from GTMEDIA's Android app gives slightly better ATSC 3.0 reception. Pick the HDTVPlayer .apk (or liba3_phy_sony.so) to import it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Import firmware from APK…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.message = "Choose the HDTVPlayer .apk or liba3_phy_sony.so"
                    if panel.runModal() == .OK, let url = panel.url { tv.importFirmware(from: url) }
                }
                .disabled(tv.setupBusy || !tv.driverOK)
            }
            Section("ATSC 3.0 audio") {
                LabeledContent("AC-4 decoder") {
                    Text(tv.ac4BuiltIn ? "Built in" : (tv.hasAC4 ? "Installed" : "Not installed"))
                        .foregroundStyle(tv.hasAC4 ? Color.green : Color.secondary)
                }
                Text("ATSC 3.0 stations use Dolby AC-4 audio, which macOS can't decode. This builds the open-source decoder on this Mac (needs the Xcode command line tools and a few minutes).")
                    .font(.caption).foregroundStyle(.secondary)
                if !tv.ac4BuiltIn {
                    Button(tv.hasAC4 ? "Rebuild AC-4 decoder" : "Install AC-4 decoder") { tv.installAC4() }
                        .disabled(tv.setupBusy || !tv.driverOK)
                }
            }
            if tv.setupBusy || !tv.setupMessage.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        if tv.setupBusy { ProgressView().controlSize(.small) }
                        Text(tv.setupMessage).font(.callout)
                    }
                }
            }
            if !tv.isBundled {
                Section("Developer") {
                    TextField("Driver folder", text: $tv.driverPath)
                    Text(tv.driverOK ? "Found hdtvmate in this folder." : "hdtvmate wasn't found here. Build it with make -f Makefile.in.")
                        .font(.caption)
                        .foregroundStyle(tv.driverOK ? Color.secondary : Color.red)
                    Button("Reload channels") { tv.loadChannels() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Empty state (ContentUnavailableView needs macOS 14)

struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            actions()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
