import Foundation
import MediaPlayer

/// CarPlay backend (Android Auto equivalent). Tabs Playlists/Albums/Artists/
/// Podcasts fed by page-side fetchMediaItems/searchMediaItems (AndroidAuto.js
/// persisted-query GraphQL). Enabled by `AndAuto` setting.
///
/// WHAT WORKS (no entitlement needed at build/launch):
/// - Thread-safe `items`/`lastSearch` storage (NSLock) with `.carPlayItems` /
///   `.carPlaySearch` notifications posted on `.main`.
/// - `play(uri:context:)` forwards to the WebView with both strings escaped
///   via JSON encoding, so quotes/backslashes cannot break the JS call.
/// - `startCarPlay()` wires an MPPlayableContentDataSource (+ delegate
///   playback handler) serving the four tabs from the `items` dict; content
///   identifiers are the Spotify uris, and selecting a playable item calls
///   `play(uri:)`. Wiring is gated on the `AndAuto` UserDefaults flag and is a
///   no-op in the Simulator, so every code path no-ops safely when CarPlay is
///   absent (no entitlement required to compile or launch).
///
/// DEVICE-GATED / STUBBED:
/// - Actual CarPlay browsing + playback need a CarPlay-capable head unit (or
///   CarPlay simulator session) plus the `com.apple.developer.playable-content`
///   entitlement; without them the data source simply never gets queried.
/// - Artwork: leaf MPContentItems carry no artwork yet (page-side covers are
///   not pushed through didLoadItems); add MPMediaItemArtwork mapping when the
///   JS bridge supplies cover URLs per item.
public final class CarPlayManager {
    public static let shared = CarPlayManager()

    private let lock = NSLock()
    private var _items: [String: [[String: Any]]] = [:]
    private var _lastSearch: (query: String, results: [[String: Any]])?

    public var items: [String: [[String: Any]]] {
        get { lock.lock(); defer { lock.unlock() }; return _items }
        set { lock.lock(); defer { lock.unlock() }; _items = newValue }
    }

    public var lastSearch: (query: String, results: [[String: Any]])? {
        get { lock.lock(); defer { lock.unlock() }; return _lastSearch }
        set { lock.lock(); defer { lock.unlock() }; _lastSearch = newValue }
    }

    private lazy var contentDataSource: ContentDataSource = ContentDataSource(owner: self)

    private init() {}

    public func didLoadItems(parentId: String, json: String) {
        if let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            lock.lock()
            _items[parentId] = arr
            lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .carPlayItems, object: parentId)
            }
        }
    }

    public func didCompleteSearch(query: String, json: String) {
        if let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            lock.lock()
            _lastSearch = (query, arr)
            lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .carPlaySearch, object: query)
            }
        }
    }

    public func play(uri: String, context: String? = nil) {
        let escapedUri = Self.jsString(uri)
        if let context = context {
            WebViewBus.eval("playFromUri(\(escapedUri),\(Self.jsString(context)))")
        } else {
            WebViewBus.eval("playFromUri(\(escapedUri))")
        }
    }

    /// Wires MPPlayableContentManager to the tab data source. Safe to call at
    /// launch: no-ops in the Simulator and when the `AndAuto` setting is off.
    /// NOTE: reads `UserDefaults.standard.bool(forKey: "AndAuto")` directly;
    /// AppSettings.swift must not be referenced from this file.
    public func startCarPlay() {
#if targetEnvironment(simulator)
        return
#else
        guard UserDefaults.standard.bool(forKey: "AndAuto") else { return }
        let manager = MPPlayableContentManager.shared()
        manager.dataSource = contentDataSource
        manager.delegate = contentDataSource
#endif
    }

    // MARK: - Private helpers

    /// JSON-encodes a string so it is safe to interpolate as a JS literal.
    private static func jsString(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\"\""
    }

    fileprivate func snapshotItems(for parentId: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return _items[parentId] ?? []
    }

    // MARK: - MPPlayableContent backend

    /// Serves the four root tabs from the owner's `items` dict. Holds the
    /// owner weakly (the singleton outlives it anyway) so no retain cycle is
    /// possible; the manager keeps this object alive via `contentDataSource`.
    private final class ContentDataSource: NSObject, MPPlayableContentDataSource, MPPlayableContentDelegate {
        struct Tab {
            let id: String
            let title: String
        }

        static let tabs: [Tab] = [
            Tab(id: "playlists", title: "Playlists"),
            Tab(id: "albums", title: "Albums"),
            Tab(id: "artists", title: "Artists"),
            Tab(id: "podcasts", title: "Podcasts"),
        ]

        private weak var owner: CarPlayManager?

        init(owner: CarPlayManager) {
            self.owner = owner
        }

        // MARK: MPPlayableContentDataSource

        func numberOfChildItems(at indexPath: IndexPath) -> Int {
            if indexPath.count == 0 {
                return Self.tabs.count
            }
            if indexPath.count == 1 {
                guard indexPath[0] >= 0, indexPath[0] < Self.tabs.count else { return 0 }
                let tab = Self.tabs[indexPath[0]]
                return owner?.snapshotItems(for: tab.id).count ?? 0
            }
            return 0
        }

        func contentItem(at indexPath: IndexPath) -> MPContentItem? {
            if indexPath.count == 1 {
                guard indexPath[0] >= 0, indexPath[0] < Self.tabs.count else { return nil }
                let tab = Self.tabs[indexPath[0]]
                let item: MPContentItem? = MPContentItem(identifier: tab.id)
                guard let item = item else { return nil }
                item.title = tab.title
                item.isContainer = true
                item.isPlayable = false
                return item
            }
            if indexPath.count == 2 {
                guard indexPath[0] >= 0, indexPath[0] < Self.tabs.count else { return nil }
                let tab = Self.tabs[indexPath[0]]
                let rows = owner?.snapshotItems(for: tab.id) ?? []
                guard indexPath[1] >= 0, indexPath[1] < rows.count else { return nil }
                let row = rows[indexPath[1]]
                guard let uri = row["uri"] as? String, !uri.isEmpty else { return nil }
                let item: MPContentItem? = MPContentItem(identifier: uri)
                guard let item = item else { return nil }
                if let title = row["title"] as? String, !title.isEmpty {
                    item.title = title
                } else if let name = row["name"] as? String, !name.isEmpty {
                    item.title = name
                } else {
                    item.title = uri
                }
                if let artist = row["artist"] as? String {
                    item.subtitle = artist
                } else if let subtitle = row["subtitle"] as? String {
                    item.subtitle = subtitle
                }
                item.isContainer = false
                item.isPlayable = true
                return item
            }
            return nil
        }

        func beginLoadingChildItems(at indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void) {
            // Items are push-loaded via didLoadItems and already in memory.
            completionHandler(nil)
        }

        // MARK: MPPlayableContentDelegate

        func playableContentManager(
            _ contentManager: MPPlayableContentManager,
            initiatePlaybackOfContentItemAt indexPath: IndexPath,
            completionHandler: @escaping (Error?) -> Void
        ) {
            if let item = contentItem(at: indexPath), !item.identifier.isEmpty {
                owner?.play(uri: item.identifier)
            }
            completionHandler(nil)
        }
    }
}

extension Notification.Name {
    static let carPlayItems = Notification.Name("carPlayItems")
    static let carPlaySearch = Notification.Name("carPlaySearch")
}
