import Foundation

/// GitHub auto-updater. Mirrors Android GitHubApi/UpdateChecker:
/// GET api.github.com/repos/{owner}/{repo}/releases/latest
/// (Accept: application/vnd.github+json, 8s timeouts), compare tag-minus-v vs
/// CFBundleShortVersionString numerically per segment, 12h throttle
/// (LastUpdateCheck ms epoch), skip when expensive/constrained.
public enum Updater {
    public static var owner = "ThinuxBOOM"
    public static var repo = "musemobile"

    public struct Release: Decodable {
        public var tag_name: String; public var body: String?
        public var html_url: String?
    }

    public static func checkIfDue() async -> Release? {
        let last = UserDefaults.standard.double(forKey: AppSettings.Key.lastUpdateCheck.rawValue)
        if Date().timeIntervalSince1970*1000 - last < 12*3600*1000 { return nil }
        // Skip on expensive/constrained networks (checked by caller via NWPathMonitor)
        return await check()
    }

    public static func check() async -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let rel = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        UserDefaults.standard.set(Date().timeIntervalSince1970*1000, forKey: AppSettings.Key.lastUpdateCheck.rawValue)
        let tag = rel.tag_name.hasPrefix("v") ? String(rel.tag_name.dropFirst()) : rel.tag_name
        let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.4"
        return isNewer(tag, than: cur) ? rel : nil
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
