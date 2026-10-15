import AppKit
import ServiceManagement
import NDIHostCore

enum Settings {
    private static let defaults = UserDefaults.standard

    static var serverPath: String {
        get { defaults.string(forKey: "serverPath") ?? NDIServer.defaultPath }
        set { defaults.set(newValue, forKey: "serverPath") }
    }
    static var keepAwake: Bool {
        get { defaults.object(forKey: "keepAwake") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepAwake") }
    }
    static var didFirstRun: Bool {
        get { defaults.bool(forKey: "didFirstRun") }
        set { defaults.set(newValue, forKey: "didFirstRun") }
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var state: ServerState = .starting(attempt: 0)
    let supervisor: Supervisor
    let port = NDIServer.port
    private let supervisorLog: RotatingLog
    private let serverLog: RotatingLog
    private var appActivity: NSObjectProtocol?     // stops App Nap from throttling the supervisor
    private var sleepActivity: NSObjectProtocol?   // stops idle system sleep
    private var refreshTimer: Timer?

    private init() {
        let log = RotatingLog(directory: RotatingLog.defaultDirectory, name: "supervisor")
        let serverOut = RotatingLog(directory: RotatingLog.defaultDirectory, name: "server")
        supervisorLog = log
        serverLog = serverOut
        supervisor = Supervisor(
            config: SupervisorConfig(executablePath: Settings.serverPath, arguments: NDIServer.arguments, port: NDIServer.port),
            log: { log.line($0) },
            output: { serverOut.write($0) })
        supervisor.onState = { [weak self] new in
            DispatchQueue.main.async {
                self?.state = new
                self?.applySleepPolicy()
            }
        }

        supervisorLog.line("NDI Discovery Host \(version) started")
        appActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Supervising the NDI Discovery Server")

        if !Settings.didFirstRun {
            Settings.didFirstRun = true
            setLaunchAtLogin(true)
        }
        // Menu text like "Running for 3h" and the IP list refresh while the menu is closed.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
        }
        launchServer()
    }

    // MARK: Display

    /// True until the NDI SDK (or a chosen server program) is actually there.
    var serverMissing: Bool { !FileManager.default.isExecutableFile(atPath: Settings.serverPath) }

    func openSDKDownload() {
        if let url = URL(string: NDIServer.sdkDownloadURL) { NSWorkspace.shared.open(url) }
    }

    var statusText: String { state.statusText() }
    var isStopped: Bool { if case .stopped = state { return true } else { return false } }
    var addresses: [DeviceAddress] { NetworkInfo.ipv4Addresses() }
    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    // Different shapes per state, so it reads without color.
    var iconName: String {
        switch state {
        case .running: return "checkmark.circle.fill"
        case .starting: return "arrow.triangle.2.circlepath.circle"
        case .stopped: return "xmark.octagon.fill"
        }
    }

    // MARK: Actions

    /// Frees the port from any stray copy, then starts the server.
    func launchServer() {
        let path = Settings.serverPath, log = supervisorLog, supervisor = supervisor
        DispatchQueue.global().async {
            StrayCleaner.terminateStrays(path: path, log: { log.line($0) })
            supervisor.start()
        }
    }

    func copy(_ address: DeviceAddress) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(address.ip):\(port)", forType: .string)
    }

    func openLogFolder() {
        NSWorkspace.shared.open(RotatingLog.defaultDirectory)
    }

    func chooseServerLocation() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose the NDI Discovery Server program (Application.Mac.NDI.DirectoryService)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: Settings.serverPath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }

        guard FileManager.default.isExecutableFile(atPath: path) else {
            let alert = NSAlert()
            alert.messageText = "That file can't be run"
            alert.informativeText = "Choose the program named Application.Mac.NDI.DirectoryService."
            alert.runModal()
            return
        }
        supervisorLog.line("Server location changed to \(path)")
        supervisor.stop { [self] in
            Settings.serverPath = path
            supervisor.setExecutablePath(path)
            launchServer()
        }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            supervisorLog.line("Launch at Login change failed: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    var keepAwake: Bool {
        get { Settings.keepAwake }
        set {
            Settings.keepAwake = newValue
            applySleepPolicy()
            objectWillChange.send()
        }
    }

    /// Hold off idle sleep only while the server is meant to be running.
    private func applySleepPolicy() {
        let want = Settings.keepAwake && !isStopped
        if want, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled], reason: "NDI Discovery Server is running")
            supervisorLog.line("Keeping Mac awake")
        } else if !want, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
            supervisorLog.line("Mac may sleep again")
        }
    }

    func confirmQuit() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit NDI Discovery Host?"
        alert.informativeText = "Quitting stops NDI discovery for everyone. Devices on other networks will stop seeing NDI sources until this app is opened again."
        alert.addButton(withTitle: "Cancel")   // first button is the default
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        NSApp.terminate(nil)
    }

    func shutdown() {
        supervisor.stopAndWait(timeout: 5)
        supervisorLog.line("NDI Discovery Host quit")
        supervisorLog.flush()
    }
}
