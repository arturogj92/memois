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
        // Append across sessions so support requests retain previous-launch context.
        // Cap at ~5MB by truncating only when the file exceeds that — keeps disk
        // bounded without losing the recent past.
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > 5 * 1024 * 1024 {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        } else if !fm.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        let stamp = formatter.string(from: Date())
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let banner = "\n\(stamp) ===== Memois session start v\(bundleVersion) (build \(buildVersion)) =====\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = banner.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
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
