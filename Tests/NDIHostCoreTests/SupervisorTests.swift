import XCTest
@testable import NDIHostCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Thread-safe collector for log lines and states.
final class Recorder {
    private let lock = NSLock()
    private var lines: [(time: Date, text: String)] = []
    private var states: [ServerState] = []

    func log(_ text: String) { lock.lock(); lines.append((Date(), text)); lock.unlock() }
    func state(_ s: ServerState) { lock.lock(); states.append(s); lock.unlock() }

    func times(startingWith prefix: String) -> [Date] {
        lock.lock(); defer { lock.unlock() }
        return lines.filter { $0.text.hasPrefix(prefix) }.map { $0.time }
    }
    func contains(_ fragment: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lines.contains { $0.text.contains(fragment) }
    }
    var startTimes: [Date] { times(startingWith: "Started server") }
    var sawStates: [ServerState] { lock.lock(); defer { lock.unlock() }; return states }
}

final class SupervisorTests: XCTestCase {
    var dir: URL!
    var script: String { dir.appendingPathComponent("fake-server.sh").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try installFakeServer(at: script)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func installFakeServer(at path: String) throws {
        let body = """
        #!/bin/sh
        # MODE: run (until SIGTERM) | crash (exit 3) | live N (run N seconds, exit 1) | stubborn (ignores SIGTERM)
        echo "fake server started pid $$"
        case "$1" in
          run)      trap 'exit 0' TERM; while :; do sleep 0.05; done ;;
          crash)    exit 3 ;;
          live)     sleep "$2"; exit 1 ;;
          stubborn) trap '' TERM; while :; do sleep 0.05; done ;;
        esac
        """
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func make(_ args: [String], timing: SupervisorTiming,
                      path: String? = nil,
                      health: @escaping (UInt16) -> Bool = { _ in true }) -> (Supervisor, Recorder) {
        let rec = Recorder()
        let sup = Supervisor(config: SupervisorConfig(executablePath: path ?? script, arguments: args, port: 1),
                             timing: timing, healthCheck: health, log: rec.log)
        sup.onState = rec.state
        return (sup, rec)
    }

    private func fastTiming() -> SupervisorTiming {
        var t = SupervisorTiming()
        t.backoff = [0.2, 0.4, 0.8]
        t.stableAfter = 100
        t.healthInterval = 0.1
        t.startupPoll = 0.05
        t.startupGrace = 0.3
        t.killAfter = 0.3
        return t
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private func gaps(_ times: [Date]) -> [TimeInterval] {
        zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
    }

    private func isRunning(_ state: ServerState) -> Bool { if case .running = state { return true } else { return false } }

    // MARK: Tests

    func testCleanStartThenStop() throws {
        let (sup, rec) = make(["run"], timing: fastTiming())
        sup.start()
        XCTAssertTrue(waitUntil { self.isRunning(sup.currentState) }, "should reach running")
        let pid = try XCTUnwrap(sup.currentPid)
        XCTAssertEqual(rec.startTimes.count, 1)

        XCTAssertTrue(sup.stopAndWait(timeout: 3))
        XCTAssertEqual(sup.currentState, .stopped(reason: nil))
        XCTAssertNotEqual(kill(pid, 0), 0, "child should be gone")
    }

    func testCrashRestartsWithGrowingBackoff() {
        let (sup, rec) = make(["crash"], timing: fastTiming())
        sup.start()
        XCTAssertTrue(waitUntil(8) { rec.startTimes.count >= 5 })
        sup.stopAndWait(timeout: 3)

        let g = gaps(rec.startTimes)   // expected delays: 0.2, 0.4, 0.8, then 0.8 again
        XCTAssertGreaterThanOrEqual(g[0], 0.2)
        XCTAssertGreaterThanOrEqual(g[1], 0.4)
        XCTAssertGreaterThanOrEqual(g[2], 0.8)
        XCTAssertGreaterThanOrEqual(g[3], 0.8)
        XCTAssertLessThan(g[0], 0.4, "first retry must use the shortest delay")
        XCTAssertLessThan(g[3], 1.2, "delay must stop growing at the last value")
        XCTAssertTrue(rec.sawStates.contains(.starting(attempt: 3)))
    }

    func testBackoffResetsAfterStableRun() {
        var t = fastTiming()
        t.backoff = [0.2, 0.6, 1.5]
        t.stableAfter = 0.3
        let (sup, rec) = make(["live", "0.6"], timing: t)   // runs 0.6s (stable), then crashes
        sup.start()
        XCTAssertTrue(waitUntil(10) { rec.startTimes.count >= 4 })
        sup.stopAndWait(timeout: 3)

        // Each gap is about 0.6 run + 0.2 first-step delay. Without the reset
        // the third gap would be 0.6 + 1.5.
        for g in gaps(rec.startTimes).prefix(3) { XCTAssertLessThan(g, 1.0) }
    }

    func testHungServerIsRestartedAfterGraceAndThreeFailures() {
        let (sup, rec) = make(["run"], timing: fastTiming(), health: { _ in false })
        sup.start()
        XCTAssertTrue(waitUntil(6) { rec.startTimes.count >= 2 }, "hung server should be restarted")
        sup.stopAndWait(timeout: 3)

        // grace 0.3s, then three checks 0.1s apart
        XCTAssertGreaterThanOrEqual(gaps(rec.startTimes)[0], 0.5)
        XCTAssertTrue(rec.contains("not answering"))
    }

    func testTwoFailedChecksAreForgiven() {
        let lock = NSLock()
        var calls = 0
        let (sup, rec) = make(["run"], timing: fastTiming(), health: { _ in
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return !(calls >= 8 && calls <= 9)   // pass, then two failures, then pass again
        })
        sup.start()
        XCTAssertTrue(waitUntil { lock.lock(); defer { lock.unlock() }; return calls >= 14 })
        sup.stopAndWait(timeout: 3)
        XCTAssertEqual(rec.startTimes.count, 1)
    }

    func testStubbornServerIsKilledAfterGracePeriod() throws {
        let (sup, rec) = make(["stubborn"], timing: fastTiming())
        sup.start()
        XCTAssertTrue(waitUntil { self.isRunning(sup.currentState) })
        let pid = try XCTUnwrap(sup.currentPid)
        XCTAssertTrue(sup.stopAndWait(timeout: 3))
        XCTAssertTrue(rec.contains("SIGKILL"))
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testManualRestartGivesNewProcess() throws {
        let (sup, rec) = make(["run"], timing: fastTiming())
        sup.start()
        XCTAssertTrue(waitUntil { self.isRunning(sup.currentState) })
        let first = try XCTUnwrap(sup.currentPid)
        sup.restart()
        XCTAssertTrue(waitUntil { rec.startTimes.count == 2 })
        XCTAssertTrue(waitUntil { self.isRunning(sup.currentState) && sup.currentPid != first })
        sup.stopAndWait(timeout: 3)
    }

    func testMissingBinaryRetriesAndRecoversWhenInstalled() throws {
        let missing = dir.appendingPathComponent("later-installed.sh").path
        let (sup, rec) = make(["run"], timing: fastTiming(), path: missing)
        sup.start()
        XCTAssertTrue(waitUntil {
            if case .stopped(let reason?) = sup.currentState { return reason.contains("not found") }
            return false
        })
        try installFakeServer(at: missing)
        XCTAssertTrue(waitUntil(5) { self.isRunning(sup.currentState) }, "should self-heal")
        XCTAssertGreaterThanOrEqual(rec.startTimes.count, 1)
        sup.stopAndWait(timeout: 3)
    }

    func testStopWhileWaitingToRetryStaysStopped() {
        let (sup, rec) = make(["crash"], timing: fastTiming())
        sup.start()
        XCTAssertTrue(waitUntil { rec.startTimes.count >= 1 })
        sup.stopAndWait(timeout: 3)
        let count = rec.startTimes.count
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(rec.startTimes.count, count, "no restarts after Stop")
        XCTAssertEqual(sup.currentState, .stopped(reason: nil))
    }

    // MARK: Supporting pieces

    func testStrayCleanerKillsOnlyExactPathIncludingSpaces() throws {
        let folder = dir.appendingPathComponent("dir with space")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let strayPath = folder.appendingPathComponent("fake ndi").path
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: strayPath)
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["30"]
        let stray = Process()
        stray.executableURL = URL(fileURLWithPath: strayPath)
        stray.arguments = ["30"]
        do { try stray.run() } catch { throw XCTSkip("cannot run a copied sleep binary here: \(error)") }
        try bystander.run()
        defer { bystander.terminate(); stray.terminate() }

        var lines: [String] = []
        let killed = StrayCleaner.terminateStrays(path: strayPath, killAfter: 2, log: { lines.append($0) })
        XCTAssertEqual(killed, [stray.processIdentifier])
        XCTAssertTrue(waitUntil { !stray.isRunning })
        XCTAssertTrue(bystander.isRunning, "other processes must be left alone")
        XCTAssertFalse(lines.isEmpty)
    }

    func testTcpHealthCheck() {
        let fd = socket(AF_INET, sockStream, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)
        XCTAssertTrue(Health.tcpConnect(port: port))

        close(fd)   // port now closed (the deferred close is a harmless second call)
        XCTAssertFalse(Health.tcpConnect(port: port))
    }

    func testLogRotationCapsTotalSize() throws {
        let log = RotatingLog(directory: dir, name: "t", maxBytes: 100_000, keep: 2)
        for _ in 0..<30 { log.write(Data(repeating: 65, count: 20_000)) }   // 600 KB
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("t.") || $0 == "t.log" }
        XCTAssertLessThanOrEqual(files.count, 3)
        let total = try files.reduce(0) {
            $0 + ((try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($1).path)[.size] as? Int) ?? 0)
        }
        XCTAssertLessThanOrEqual(total, 300_000)
    }

    func testStatusText() {
        let now = Date()
        XCTAssertEqual(ServerState.running(since: now.addingTimeInterval(-(3 * 86400 + 4 * 3600 + 120))).statusText(now: now), "Running for 3 days 4h")
        XCTAssertEqual(ServerState.running(since: now.addingTimeInterval(-(2 * 3600 + 5 * 60))).statusText(now: now), "Running for 2h 5m")
        XCTAssertEqual(ServerState.starting(attempt: 3).statusText(), "Restarting (attempt 3)")
        XCTAssertEqual(ServerState.stopped(reason: nil).statusText(), "Not running: stopped by you")
    }
}
