import SwiftUI

@main
struct HDTVMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var tv = TVModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tv)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Playback") {
                Button("Next channel") { tv.step(1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous channel") { tv.step(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Stop") { tv.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(tv.playing == nil)
                Button(tv.recordingURL == nil ? "Record" : "Stop recording") { tv.toggleRecord() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(tv.playing == nil)
                Divider()
                Button(tv.timeshift?.paused == true ? "Play" : "Pause") { tv.togglePause() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!tv.canTimeshift)
                Button("Back 10 seconds") { tv.skip(-10) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!tv.canTimeshift)
                Button("Forward 30 seconds") { tv.skip(30) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!tv.canTimeshift || (tv.timeshift?.atLive ?? true))
                Button("Go to live") { tv.goLive() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!tv.canTimeshift || (tv.timeshift?.atLive ?? true))
                Divider()
                Toggle("Mute", isOn: $tv.muted)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Toggle("Captions", isOn: $tv.captionsOn)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environmentObject(tv)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Space = pause/play, ← / → = back 10 s / forward 30 s, like a DVR remote. Ignored while
        // typing (e.g. in channel search) or when a sheet or another window has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let tv = TVModel.shared
            guard tv.playing != nil,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let win = NSApp.keyWindow, win === NSApp.mainWindow, win.attachedSheet == nil,
                  !(win.firstResponder is NSText) else { return event }
            switch event.keyCode {
            case 49: tv.togglePause()                       // space
            case 123: tv.skip(-10)                          // ←
            case 124: tv.skip(30)                           // →
            default: return event
            }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        TVModel.shared.shutdown()
    }
}
