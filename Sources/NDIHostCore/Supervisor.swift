import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SupervisorTiming {
    public var backoff: [TimeInterval] = [1, 2, 5, 10, 30]   // last value repeats forever
    public var stableAfter: TimeInterval = 60                 // running this long resets the backoff
    public var healthInterval: TimeInterval = 10
    public var startupGrace: TimeInterval = 15                // failed checks don't count yet
    public var startupPoll: TimeInterval = 1                  // faster checks until first success
    public var failuresBeforeRestart = 3
    public var killAfter: TimeInterval = 3                    // SIGTERM, then SIGKILL
    public init() {}
}

public struct SupervisorConfig {
    public var executablePath: String
    public var arguments: [String]
    public var port: UInt16
    public init(executablePath: String, arguments: [String] = [], port: UInt16) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.port = port
    }
}

/// Runs the server as a child process and keeps it alive. All mutable state is
/// touched only on `queue`; the public methods are safe to call from any thread.
public final class Supervisor {
    public typealias HealthCheck = (UInt16) -> Bool

    /// Called on the supervisor's queue whenever the state changes.
    public var onState: ((ServerState) -> Void)?

    private final class Run {
        enum Ending { case stop, restart, hung }
        let process = Process()
        let started = Date()
        var failures = 0
        var healthy = false
        var ending: Ending?
    }

    private let queue = DispatchQueue(label: "ndi.supervisor")
    private let healthQueue = DispatchQueue(label: "ndi.health")
    private var config: SupervisorConfig
    private let timing: SupervisorTiming
    private let healthCheck: HealthCheck
    private let logger: (String) -> Void
    private let output: (Data) -> Void

    private var state = ServerState.stopped(reason: nil)
    private var current: Run?
    private var wantRunning = false
    private var failureCount = 0          // consecutive failures; drives the backoff
    private var retryWork: DispatchWorkItem?
    private var stopWaiters: [() -> Void] = []

    public init(config: SupervisorConfig,
                timing: SupervisorTiming = SupervisorTiming(),
                healthCheck: @escaping HealthCheck = { Health.tcpConnect(port: $0) },
                log: @escaping (String) -> Void,
                output: @escaping (Data) -> Void = { _ in }) {
        self.config = config
        self.timing = timing
        self.healthCheck = healthCheck
        self.logger = log
        self.output = output
    }

    // MARK: Public API

    public var currentState: ServerState { queue.sync { state } }
    public var currentPid: pid_t? { queue.sync { current?.process.processIdentifier } }

    public func start() {
        queue.async {
            self.wantRunning = true
            if let run = self.current {
                if run.ending == .stop { run.ending = .restart }
                return
            }
            self.retryWork?.cancel()
            self.failureCount = 0
            self.launch()
        }
    }

    public func restart() {
        queue.async {
            self.wantRunning = true
            if let run = self.current {
                if run.ending == nil { self.end(run, .restart) } else { run.ending = .restart }
            } else {
                self.retryWork?.cancel()
                self.failureCount = 0
                self.launch()
            }
        }
    }

    /// `completion` runs on the supervisor queue once the server is gone.
    public func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.wantRunning = false
            self.retryWork?.cancel()
            self.retryWork = nil
            guard let run = self.current else {
                self.set(.stopped(reason: nil))
                completion?()
                return
            }
            if let completion = completion { self.stopWaiters.append(completion) }
            if run.ending == nil { self.end(run, .stop) } else { run.ending = .stop }
        }
    }

    /// Blocking version for quitting. Returns false if it timed out.
    @discardableResult
    public func stopAndWait(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        stop { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    public func setExecutablePath(_ path: String) {
        queue.async { self.config.executablePath = path }
    }

    // MARK: Launching and ending

    private func launch() {
        guard wantRunning, current == nil else { return }
        retryWork = nil

        let path = config.executablePath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            let message = "NDI server not found at \(path). Install the NDI SDK or choose its location."
            scheduleRetry(reason: message, show: .stopped(reason: message))
            return
        }

        let run = Run()
        let process = run.process
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = config.arguments
        process.standardInput = FileHandle.nullDevice   // no terminal needed
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.output(data)
        }
        process.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.exited(run, status: proc.terminationStatus, reason: proc.terminationReason) }
        }

        do {
            try process.run()
        } catch {
            let message = "Could not start the NDI server (\(error.localizedDescription))."
            scheduleRetry(reason: message, show: .stopped(reason: message))
            return
        }

        current = run
        log("Started server (pid \(process.processIdentifier)) \(path) \(config.arguments.joined(separator: " "))")
        set(.starting(attempt: failureCount))
        scheduleHealthCheck(run, after: timing.startupPoll)
        queue.asyncAfter(deadline: .now() + timing.stableAfter) { [weak self] in
            guard let self = self, self.current === run else { return }
            self.failureCount = 0
        }
    }

    private func end(_ run: Run, _ ending: Run.Ending) {
        guard current === run, run.ending == nil else { return }
        run.ending = ending
        run.process.terminate()   // SIGTERM
        queue.asyncAfter(deadline: .now() + timing.killAfter) { [weak self] in
            guard let self = self, self.current === run else { return }   // still alive
            self.log("Server ignored SIGTERM; sending SIGKILL")
            kill(run.process.processIdentifier, SIGKILL)
        }
    }

    private func exited(_ run: Run, status: Int32, reason: Process.TerminationReason) {
        guard current === run else { return }
        current = nil
        let how = reason == .uncaughtSignal ? "signal \(status)" : "exit code \(status)"
        switch run.ending {
        case .stop?:
            log("Server stopped (\(how))")
            set(.stopped(reason: nil))
            let waiters = stopWaiters
            stopWaiters = []
            waiters.forEach { $0() }
        case .restart?:
            log("Server stopped for restart (\(how))")
            failureCount = 0
            launch()
        case .hung?:
            log("Hung server stopped (\(how))")
            scheduleRetry(reason: "server stopped answering")
        case nil:
            log("Server exited on its own (\(how))")
            scheduleRetry(reason: "server exited (\(how))")
        }
    }

    private func scheduleRetry(reason: String, show: ServerState? = nil) {
        guard wantRunning else { return }
        failureCount += 1
        let delay = timing.backoff[min(failureCount - 1, timing.backoff.count - 1)]
        log("Restart attempt \(failureCount) in \(delay)s. Reason: \(reason)")
        set(show ?? .starting(attempt: failureCount))
        let work = DispatchWorkItem { [weak self] in self?.launch() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Health checks

    private func scheduleHealthCheck(_ run: Run, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.current === run, run.ending == nil else { return }
            let port = self.config.port
            self.healthQueue.async {
                let ok = self.healthCheck(port)
                self.queue.async { self.healthResult(run, ok: ok) }
            }
        }
    }

    private func healthResult(_ run: Run, ok: Bool) {
        guard current === run, run.ending == nil else { return }
        var next = timing.healthInterval
        if ok {
            run.failures = 0
            if !run.healthy {
                run.healthy = true
                log("Health check passed; server is answering")
                set(.running(since: run.started))
            }
        } else if Date().timeIntervalSince(run.started) >= timing.startupGrace {
            run.failures += 1
            log("Health check failed (\(run.failures) of \(timing.failuresBeforeRestart))")
            if run.failures >= timing.failuresBeforeRestart {
                log("Server is running but not answering; restarting it")
                end(run, .hung)
                return
            }
        } else if !run.healthy {
            next = timing.startupPoll
        }
        scheduleHealthCheck(run, after: next)
    }

    // MARK: Helpers

    private func set(_ new: ServerState) {
        state = new
        onState?(new)
    }

    private func log(_ message: String) { logger(message) }
}
