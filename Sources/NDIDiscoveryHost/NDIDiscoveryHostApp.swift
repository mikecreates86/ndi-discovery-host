import SwiftUI
import AppKit

@main
struct NDIDiscoveryHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        SingleInstance.exitIfAnotherIsRunning()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.iconName)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Covers logout and restart. The menu's Quit does its own stop first.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

enum SingleInstance {
    /// If two copies start at once, the one with the higher pid backs off.
    static func exitIfAnotherIsRunning() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let older = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier < me }
        if older { exit(0) }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusText)
        Divider()

        Text("Address for devices (click to copy)")
        if model.addresses.isEmpty {
            Text("No network connection")
        }
        ForEach(model.addresses, id: \.ip) { address in
            Button("\(address.ip):\(model.port)   (\(address.interface))") { model.copy(address) }
        }
        Divider()

        Button("Restart Server") { model.supervisor.restart() }
        if model.isStopped {
            Button("Start Server") { model.launchServer() }
        } else {
            Button("Stop Server") { model.supervisor.stop() }
        }
        Divider()

        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Toggle("Keep Mac Awake", isOn: Binding(get: { model.keepAwake }, set: { model.keepAwake = $0 }))
        Divider()

        Button("Open Log Folder") { model.openLogFolder() }
        Button("Choose NDI Server Location…") { model.chooseServerLocation() }
        Divider()

        Text("Version \(model.version)")
        Button("Quit") { model.confirmQuit() }
    }
}
