import Foundation
import Network

/// GitHub auto-updater. Mirrors Android GitHubApi/UpdateChecker:
/// GET api.github.com/repos/{owner}/{repo}/releases/latest
/// (Accept: application/vnd.github+json, 8s timeouts), compare tag-minus-v vs
/// CFBundleShortVersionString numerically per segment, 12h throttle
/// (LastUpdateCheck ms epoch), skip when expensive/constrained.
public enum Updater {
    public static var owner = "ThinuxBOOM"
    public static var repo = "musemobile-ios"

    public struct Release: Decodable {
        public var tag_name: String; public var body: String?
        public var html_url: String?
    }

    public static func checkIfDue() async -> Release? {
        let last = UserDefaults.standard.double(forKey: AppSettings.Key.lastUpdateCheck.rawValue)
        if Date().timeIntervalSince1970*1000 - last < 12*3600*1000 { return nil }
        // Skip when offline or on an expensive network (metered/hotspot).
        // No stamp here so a skipped check retries on next launch (Android parity).
        if isOfflineOrExpensive() { return nil }
        return await check()
    }

    public static func check() async -> Release? {
        // Stamp BEFORE the network fetch (not only on success) so failures and
        // 404s still throttle for 12h instead of hammering the API.
        UserDefaults.standard.set(Date().timeIntervalSince1970*1000, forKey: AppSettings.Key.lastUpdateCheck.rawValue)
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let rel = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        let tag = rel.tag_name.hasPrefix("v") ? String(rel.tag_name.dropFirst()) : rel.tag_name
        let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.4"
        return isNewer(tag, than: cur) ? rel : nil
    }

    /// Synchronous NWPathMonitor probe (≤2s). Returns true when offline
    /// (status != .satisfied) or the path is expensive (metered/hotspot).
    private static func isOfflineOrExpensive() -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.musemobile.updater.path")
        let box = PathBox()
        monitor.pathUpdateHandler = { path in
            box.status = path.status
            box.isExpensive = path.isExpensive
            box.signal()
        }
        monitor.start(queue: queue)
        _ = box.wait(timeout: .now() + 2)
        monitor.cancel()
        if box.status != .satisfied { return true }
        return box.isExpensive
    }

    private final class PathBox: @unchecked Sendable {
        private let lock = NSLock()
        private let sem = DispatchSemaphore(value: 0)
        private var _status: NWPath.Status = .unsatisfied
        private var _isExpensive = true
        var status: NWPath.Status {
            get { lock.lock(); defer { lock.unlock() }; return _status }
            set { lock.lock(); _status = newValue; lock.unlock() }
        }
        var isExpensive: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _isExpensive }
            set { lock.lock(); _isExpensive = newValue; lock.unlock() }
        }
        func signal() { sem.signal() }
        func wait(timeout: DispatchTime) -> DispatchTimeoutResult { sem.wait(timeout: timeout) }
    }

    static func isNewer(_ tag: String, than cur: String) -> Bool {
        let a = tag.split(separator: ".").map { Int($0) ?? 0 }
        let b = cur.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
