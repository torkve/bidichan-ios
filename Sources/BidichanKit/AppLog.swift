import Foundation

/// A tiny on-device logger shared by the app and the tunnel extension. Lines are
/// appended (with timestamps) to a file in the App Group container so both
/// processes write to the same log and the app can display it — no Mac/Console
/// needed. The file is size-capped so it can't grow without bound.
public enum AppLog {
    private static let queue = DispatchQueue(label: "torkve.bidichan.applog")
    private static let maxBytes = 256 * 1024

    private static var fileURL: URL {
        AppGroup.containerURL.appendingPathComponent("bidichan.log")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Appends one line, tagged with the process (app vs tunnel) and a timestamp.
    public static func log(_ message: String) {
        let who = isExtension ? "ext" : "app"
        let line = "\(stamp.string(from: Date())) [\(who)] \(message)\n"
        queue.async {
            let url = fileURL
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
            trimIfNeeded(url)
        }
    }

    /// Returns the whole log (best-effort).
    public static func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    public static func clear() {
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    // Keep only the last ~half of the cap when the file grows past it, so the
    // most recent context survives.
    private static func trimIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(maxBytes / 2)
        // Drop a partial first line for cleanliness.
        let trimmed = keep.firstIndex(of: 0x0A).map { keep[keep.index(after: $0)...] } ?? keep
        try? Data(trimmed).write(to: url, options: .atomic)
    }

    private static var isExtension: Bool {
        Bundle.main.bundlePath.hasSuffix(".appex")
    }
}

/// Shared "last connection error" so the app can show why the extension failed
/// (the NEVPNManager doesn't surface the provider's Error to the app).
public extension AppGroup {
    private static let lastErrorKey = "lastConnectionError"

    static func setLastError(_ message: String?) {
        if let message {
            defaults.set(message, forKey: lastErrorKey)
        } else {
            defaults.removeObject(forKey: lastErrorKey)
        }
    }

    static func lastError() -> String? {
        defaults.string(forKey: lastErrorKey)
    }
}
