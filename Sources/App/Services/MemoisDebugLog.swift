import Foundation

/// Lightweight thread-safe append-only logger that writes to
/// `/tmp/memois-aai.log`. Used to capture live-subtitle diagnostics that
/// are easier to read with `tail -f` than via `log stream`.
final class MemoisDebugLog {
    static let shared = MemoisDebugLog()

    private let url: URL
    private let queue = DispatchQueue(label: "memois.debug-log", qos: .utility)
    private let formatter: ISO8601DateFormatter

    private init() {
        self.url = URL(fileURLWithPath: "/tmp/memois-aai.log")
        self.formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Truncate at start so each app launch has a fresh log.
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    func write(_ line: String) {
        let stamp = formatter.string(from: Date())
        let formatted = "\(stamp) \(line)\n"
        queue.async { [url] in
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = formatted.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            } else {
                try? formatted.write(to: url, atomically: false, encoding: .utf8)
            }
        }
    }
}
