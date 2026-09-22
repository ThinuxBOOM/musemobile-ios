import Foundation

/// Offline manifest entry. Mirrors Android `offline_meta.json` keyed by trackId.
public struct OfflineTrack: Codable {
    public var trackId, title, artist, album: String
    public var coverUrl, videoId, ytTitle, ytArtist, ytAlbum, ytThumb, shareLink: String?
    public var durationSec: Int?
    public var explicit: Bool?

    public init(trackId: String, title: String, artist: String, album: String,
                coverUrl: String? = nil, videoId: String? = nil, ytTitle: String? = nil,
                ytArtist: String? = nil, ytAlbum: String? = nil, ytThumb: String? = nil,
                durationSec: Int? = nil, explicit: Bool? = nil, shareLink: String? = nil) {
        self.trackId = trackId; self.title = title; self.artist = artist; self.album = album
        self.coverUrl = coverUrl; self.videoId = videoId; self.ytTitle = ytTitle
        self.ytArtist = ytArtist; self.ytAlbum = ytAlbum; self.ytThumb = ytThumb
        self.durationSec = durationSec; self.explicit = explicit; self.shareLink = shareLink
    }
}

/// Scans app-shared audio dir + filename regex (Android: MediaStore RELATIVE_PATH).
/// Pattern: `<Artist> - <Title> [<SpotifyTrackId>].m4a`, illegal chars -> _, 200-char cap.
public final class OfflineStore {
    public static let shared = OfflineStore()
    public let dir: URL
    public let manifestURL: URL
    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("MuseMobile", isDirectory: true)
        manifestURL = dir.appendingPathComponent("offline_meta.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("covers"), withIntermediateDirectories: true)
    }
    public static let filePattern = #"^(.*) - (.*) \[([^\]]+)\]\.[^.]+$"#

    public func allTracks() -> [OfflineTrack] {
        (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: OfflineTrack].self, from: $0) }
            .map { Array($0.values) } ?? []
    }
    public func save(_ t: OfflineTrack) {
        var m = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: OfflineTrack].self, from: $0) } ?? [:]
        m[t.trackId] = t
        try? JSONEncoder().encode(m).write(to: manifestURL)
    }
    public func fileURL(for t: OfflineTrack) -> URL {
        dir.appendingPathComponent(Self.sanitize("\(t.artist) - \(t.title) [\(t.trackId)].m4a"))
    }
    public static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        var o = s.components(separatedBy: bad).joined(separator: "_")
        if o.count > 200 { o = String(o.prefix(200)) }
        return o
    }
}
