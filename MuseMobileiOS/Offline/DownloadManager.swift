import Foundation

/// Download pipeline. Mirrors Android DownloadService/DownloadManager:
/// resolve via YouTube @ HIGH (validation skipped) -> 8 MiB ranged chunks
/// (Range: bytes=a-b, accept 200/206, 4 retries/chunk, mobile UA) ->
/// temp <trackId>.part -> final file. Progress callback into page:
/// window.__splDlBatch=<bool>;window.splDownloadProgress(pct,'escaped label')
/// (escape \, ', newlines).
public final class DownloadManager {
    public static let shared = DownloadManager()
    private var cancelled = false
    private var skip = false
    private init() {}

    public func skipCurrent() { skip = true }
    public func cancelAll() { cancelled = true }

    public struct SinglePayload: Decodable { var trackId, title, artist, album: String; var cover: String? }
    public struct CollectionPayload: Decodable {
        var type: String; var name: String; var cover: String?
        var tracks: [SinglePayload]
    }

    public func downloadTrack(json: String) {
        guard let data = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(SinglePayload.self, from: data) else { return }
        Task { await self.run(tracks: [p], batch: false) }
    }
    public func downloadCollection(json: String) {
        guard let data = json.data(using: .utf8),
              let c = try? JSONDecoder().decode(CollectionPayload.self, from: data) else { return }
        Task { await self.run(tracks: c.tracks, batch: true) }
    }

    private func run(tracks: [SinglePayload], batch: Bool) async {
        cancelled = false
        await report(batch: batch, pct: 0, label: "Starting…")
        for (i, t) in tracks.enumerated() {
            if cancelled { break }; skip = false
            await report(batch: batch, pct: Int(Double(i)/Double(max(1,tracks.count))*100), label: "\(t.artist) - \(t.title)")
            // 1. Resolve YouTube audio at HIGH (validation skipped for downloads)
            guard let res = try? await InnerTube.shared.resolveAudio(
                title: t.title, artist: t.artist, album: t.album, quality: .high, validate: false) else { continue }
            // 2. Ranged download 8 MiB chunks
            let store = OfflineStore.shared
            let track = OfflineTrack(trackId: t.trackId, title: t.title, artist: t.artist, album: t.album,
                                     coverUrl: t.cover, videoId: res.videoId, ytTitle: res.title,
                                     durationSec: res.lengthSec, explicit: nil, shareLink: nil)
            let tmp = store.dir.appendingPathComponent("\(t.trackId).part")
            let ok = await self.fetchRanged(url: res.audioURL, to: tmp) { [t] pct in
                Task { await self.report(batch: batch, pct: pct, label: "\(t.artist) - \(t.title)") }
            }
            if ok && !cancelled && !skip {
                try? FileManager.default.moveItem(at: tmp, to: store.fileURL(for: track))
                store.save(track)
            } else { try? FileManager.default.removeItem(at: tmp) }
        }
        await report(batch: batch, pct: 100, label: "Done")
    }

    private func fetchRanged(url: URL, to dest: URL, progress: @escaping (Int) -> Void) async -> Bool {
        let chunk = 8 * 1024 * 1024
        // HEAD for length
        var head = URLRequest(url: url); head.httpMethod = "HEAD"
        head.setValue(Constants.desktopUA, forHTTPHeaderField: "User-Agent")
        let total: Int = (try? await URLSession.shared.data(for: head)).flatMap {
            (($0.1 as? HTTPURLResponse)?.expectedContentLength).map { Int($0) } } ?? -1
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: dest) else { return false }
        defer { try? fh.close() }
        var offset = 0, done = 0
        while true {
            if cancelled || skip { return false }
            let end = total > 0 ? min(offset + chunk - 1, total - 1) : offset + chunk - 1
            var ok = false
            for _ in 0..<4 {
                var req = URLRequest(url: url)
                req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                req.setValue(Constants.desktopUA, forHTTPHeaderField: "User-Agent")
                if let (d, r) = try? await URLSession.shared.data(for: req),
                   let code = (r as? HTTPURLResponse)?.statusCode, [200, 206].contains(code) {
                    try? fh.write(contentsOf: d); offset += d.count; done += d.count; ok = true; break
                }
            }
            if !ok { return false }
            if total > 0 {
                progress(Int(Double(done)/Double(total)*100))
                if done >= total { return true }
            } else { return true } // unknown length: single chunk
        }
    }

    private func report(batch: Bool, pct: Int, label: String) async {
        let esc = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: " ")
        WebViewBus.eval("window.__splDlBatch=\(batch ? "true" : "false");window.splDownloadProgress(\(pct),'\(esc)')")
    }
}
