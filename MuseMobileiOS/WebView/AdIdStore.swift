import Foundation

/// Bounded LRU store of ad audio content IDs harvested by AdStateHook.
/// Mirrors Android `AdIdStore`: <=32 IDs, regex ^[a-zA-Z0-9_-]{8,128}$,
/// lock-free reads via immutable snapshot, cleared on page navigation.
public final class AdIdStore: @unchecked Sendable {
    public static let shared = AdIdStore()
    private let lock = NSLock()
    private var ids = OrderedSet()
    private var published: [String] = []
    private static let maxIDs = 32

    public func addAll(_ candidates: [String]) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for raw in candidates {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValid(id) else { continue }
            if ids.remove(id) == nil { changed = true }
            ids.append(id)
        }
        while ids.count > Self.maxIDs { ids.removeFirst() }
        if changed { published = ids.items }
    }

    /// Hot path — lock-free snapshot scan.
    public func matches(_ url: String) -> Bool {
        if url.count < 8 { return false }
        let snap = published
        for id in snap { if url.contains(id) { return true } }
        return false
    }

    public func clear() { lock.lock(); ids.removeAll(); published = []; lock.unlock() }

    static func isValid(_ s: String) -> Bool {
        guard (8...128).contains(s.count) else { return false }
        for c in s.unicodeScalars {
            let v = c.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95 || v == 45
            if !ok { return false }
        }
        return true
    }
}

private struct OrderedSet {
    var items: [String] = []
    private var set = Set<String>()
    var count: Int { items.count }
    mutating func append(_ s: String) { if set.insert(s).inserted { items.append(s) } }
    @discardableResult mutating func remove(_ s: String) -> String? {
        guard set.remove(s) != nil else { return nil }
        items.removeAll { $0 == s }; return s
    }
    mutating func removeFirst() { if let f = items.first { _ = remove(f) } }
    mutating func removeAll() { items.removeAll(); set.removeAll() }
}
