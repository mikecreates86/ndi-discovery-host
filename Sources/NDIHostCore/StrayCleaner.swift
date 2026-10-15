import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Finds leftover copies of the server (for example after the app crashed) so
/// the port is free. Matches the exact executable path only, never by name.
public enum StrayCleaner {
    @discardableResult
    public static func terminateStrays(path: String, killAfter: TimeInterval = 3,
                                       log: (String) -> Void) -> [pid_t] {
        let pids = findPids(path: path)
        for pid in pids {
            log("Stray server found (pid \(pid)); sending SIGTERM")
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(killAfter)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in pids where kill(pid, 0) == 0 {
            log("Stray server (pid \(pid)) ignored SIGTERM; sending SIGKILL")
            kill(pid, SIGKILL)
        }
        return pids
    }

    static func findPids(path: String) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        let me = getpid()
        var found: [pid_t] = []
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " })
            guard let space = line.firstIndex(of: " "), let pid = pid_t(line[..<space]), pid != me else { continue }
            let command = line[line.index(after: space)...].drop(while: { $0 == " " })
            if command == path || command.hasPrefix(path + " ") { found.append(pid) }
        }
        return found
    }
}
