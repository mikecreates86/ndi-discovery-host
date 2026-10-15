import Foundation

/// Appends to NAME.log; past `maxBytes` it shifts to NAME.1.log, NAME.2.log and
/// deletes the oldest. Worst case on disk: maxBytes * (keep + 1).
public final class RotatingLog {
    private let dir: URL
    private let name: String
    private let maxBytes: Int
    private let keep: Int
    private let queue = DispatchQueue(label: "ndi.log")
    private var handle: FileHandle?
    private var size = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public init(directory: URL, name: String, maxBytes: Int = 800_000, keep: Int = 2) {
        self.dir = directory
        self.name = name
        self.maxBytes = maxBytes
        self.keep = keep
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.sync { open() }
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NDI Discovery Host")
    }

    public func line(_ text: String) {
        queue.async {
            self.append(Data("\(self.stamp.string(from: Date())) \(text)\n".utf8))
        }
    }

    /// Raw bytes, e.g. the server's own output.
    public func write(_ data: Data) {
        queue.async { self.append(data) }
    }

    public func flush() { queue.sync {} }

    private func url(_ index: Int?) -> URL {
        dir.appendingPathComponent(index.map { "\(name).\($0).log" } ?? "\(name).log")
    }

    private func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url(nil).path) { fm.createFile(atPath: url(nil).path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url(nil))
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func append(_ data: Data) {
        if size > 0 && size + data.count > maxBytes { rotate() }
        try? handle?.write(contentsOf: data)
        size += data.count
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: url(keep))
        for i in stride(from: keep - 1, through: 1, by: -1) {
            try? fm.moveItem(at: url(i), to: url(i + 1))
        }
        try? fm.moveItem(at: url(nil), to: url(1))
        open()
    }
}
