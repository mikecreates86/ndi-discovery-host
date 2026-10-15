import Foundation

public enum ServerState: Equatable {
    /// `reason == nil` means the user stopped it on purpose.
    case stopped(reason: String?)
    /// attempt 0 is the first start; above 0 is a restart after a failure.
    case starting(attempt: Int)
    case running(since: Date)

    public func statusText(now: Date = Date()) -> String {
        switch self {
        case .stopped(let reason): return "Not running: " + (reason ?? "stopped by you")
        case .starting(let n): return n == 0 ? "Starting…" : "Restarting (attempt \(n))"
        case .running(let since): return "Running for " + Self.uptimeText(now.timeIntervalSince(since))
        }
    }

    public static func uptimeText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds)) / 60
        if minutes < 1 { return "less than a minute" }
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return "\(d) day\(d == 1 ? "" : "s") \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }
}
