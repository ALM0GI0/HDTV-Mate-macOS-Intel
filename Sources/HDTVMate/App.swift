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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        TVModel.shared.shutdown()
    }
}
