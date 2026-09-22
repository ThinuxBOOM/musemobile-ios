import Foundation
import MediaPlayer

/// CarPlay backend (Android Auto equivalent). Tabs Playlists/Albums/Artists/
/// Podcasts fed by page-side fetchMediaItems/searchMediaItems (AndroidAuto.js
/// persisted-query GraphQL). Enabled by `AndAuto` setting.
public final class CarPlayManager {
    public static let shared = CarPlayManager()
    private init() {}
    public var items: [String: [[String: Any]]] = [:]
    public var lastSearch: (query: String, results: [[String: Any]])?

    public func didLoadItems(parentId: String, json: String) {
        if let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items[parentId] = arr
            NotificationCenter.default.post(name: .carPlayItems, object: parentId)
        }
    }
    public func didCompleteSearch(query: String, json: String) {
        if let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            lastSearch = (query, arr)
            NotificationCenter.default.post(name: .carPlaySearch, object: query)
        }
    }
    public func play(uri: String, context: String? = nil) {
        let ctx = context.map { ",'\($0)'" } ?? ""
        WebViewBus.eval("playFromUri('\(uri)'\(ctx))")
    }
}

extension Notification.Name {
    static let carPlayItems = Notification.Name("carPlayItems")
    static let carPlaySearch = Notification.Name("carPlaySearch")
}
