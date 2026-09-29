import Foundation

/// Download pipeline. Mirrors Android DownloadService/DownloadManager:
/// resolve via YouTube @ HIGH (validation skipped) -> 8 MiB ranged chunks
/// (Range: bytes=a-b, accept 200/206, 4 retries/chunk, mobile UA) ->
/// temp <trackId>.part -> final file. Progress callback into page:
/// window.__splDlBatch=<bool>;window.splDownloadProgress(pct,'escaped label')
/// (escape \, ', newlines).
public final class DownloadManager {
    public static let shared = DownloadManager()

    /// Per-run cancellation state. Replaces the old shared plain-Bool
    /// `cancelled`/`skip` flags so queued jobs each carry their own token and
    /// skip/cancel only affect the intended run.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        private var _skip = false

        func requestCancel() {
            lock.lock()
            _cancelled = true
            lock.unlock()
        }

        func requestSkip() {
            lock.lock()
            _skip = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }

        var isSkipRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _skip
        }

        /// One-shot consume: returns true once per skip request.
        func consumeSkip() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let s = _skip
            _skip = false
            return s
        }
    }

    /// Single serial executor: one in-flight Task slot. New jobs chain onto
    /// `tail` so only one run() executes at a time. Guarded by `queueLock`.
    private let queueLock = NSLock()
    private var tail: Task<Void, Never>?
    private var activeState: RunState?
    private var pendingStates: [RunState] = []

    /// Serializes all OfflineStore.save() calls (manifest is read-modify-write).
    /// NOTE: save() itself lives in OfflineStore (not editable here) and uses a
    /// non-atomic write(to:) — serializing here closes the race between concurrent
    /// downloads, but a crash mid-write could still leave a torn manifest. True
    /// atomicity (write(to:atomically:true) to temp + rename) must land in
    /// OfflineStore.save() itself.
    private let saveQueue = DispatchQueue(label: "com.musemobile.download.save")

    private init() {}

    public func skipCurrent() {
        queueLock.lock()
        let s = activeState
        queueLock.unlock()
        s?.requestSkip()
    }

    public func cancelAll() {
        queueLock.lock()
        let active = activeState
        let pending = pendingStates
        queueLock.unlock()
        active?.requestCancel()
        for st in pending { st.requestCancel() }
    }

    public struct SinglePayload: Decodable { var trackId, title, artist, album: String; var cover: String? }
    public struct CollectionPayload: Decodable {
        var type: String; var name: String; var cover: String?
        var tracks: [SinglePayload]
    }

    public func downloadTrack(json: String) {
        guard let data = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(SinglePayload.self, from: data) else {
            Task { await self.report(batch: false, pct: -1, label: "Invalid download request") }
            return
        }
        // Validate before touching the filesystem with raw ids.
        guard OfflineStore.isValidTrackId(p.trackId) else {
            Task { await self.report(batch: false, pct: -1, label: "Invalid track id — skipped") }
            return
        }
        let state = RunState()
        enqueue(batch: false, state: state) { [state] in
            await self.run(tracks: [p], batch: false, state: state)
        }
    }

    public func downloadCollection(json: String) {
        guard let data = json.data(using: .utf8),
              let c = try? JSONDecoder().decode(CollectionPayload.self, from: data) else {
            Task { await self.report(batch: true, pct: -1, label: "Invalid download request") }
            return
        }
        // Filter raw ids up front; never touch the filesystem with invalid ones.
        // De-dupe by trackId like Android.
        var seen = Set<String>()
        var valid: [SinglePayload] = []
        var invalidCount = 0
        for t in c.tracks {
            guard OfflineStore.isValidTrackId(t.trackId), seen.insert(t.trackId).inserted else {
                invalidCount += 1
                continue
            }
            valid.append(t)
        }
        guard !valid.isEmpty else {
            Task { await self.report(batch: true, pct: -1, label: "No downloadable tracks found") }
            return
        }
        let state = RunState()
        let filtered = valid
        let skippedInvalid = invalidCount
        enqueue(batch: true, state: state) { [state] in
            if skippedInvalid > 0 {
                await self.report(batch: true, pct: 0,
                                  label: "Skipped \(skippedInvalid) invalid track id(s)…")
            }
            await self.run(tracks: filtered, batch: true, state: state)
        }
    }

    /// Chain `work` after the current tail so jobs serialize.
    private func enqueue(batch: Bool, state: RunState, work: @escaping () async -> Void) {
        queueLock.lock()
        pendingStates.append(state)
        let prev = tail
        queueLock.unlock()
        let task = Task { [weak self] in
            // Wait for predecessor (serial executor).
            if let prev = prev { await prev.value }
            guard let self = self else { return }
            // Cancelled while queued: report honestly, don't run.
            if state.isCancelled {
                self.queueLock.lock()
                if let idx = self.pendingStates.firstIndex(where: { $0 === state }) {
                    self.pendingStates.remove(at: idx)
                }
                self.queueLock.unlock()
                await self.report(batch: batch, pct: -1, label: "Cancelled")
                return
            }
            await work()
        }
        queueLock.lock()
        tail = task
        queueLock.unlock()
    }

    private func run(tracks: [SinglePayload], batch: Bool, state: RunState) async {
        queueLock.lock()
        activeState = state
        if let idx = pendingStates.firstIndex(where: { $0 === state }) {
            pendingStates.remove(at: idx)
        }
        queueLock.unlock()
        defer {
            queueLock.lock()
            if activeState === state { activeState = nil }
            queueLock.unlock()
        }

        await report(batch: batch, pct: 0, label: "Starting…")
        var saved = 0, failed = 0, skipped = 0
        var cancelled = false

        for (i, t) in tracks.enumerated() {
            // Between-track abort (e.g. tapped during inter-track gap).
            if state.isCancelled {
                cancelled = true
                break
            }
            if state.consumeSkip() {
                skipped += 1
                await report(batch: batch,
                             pct: batch ? overallPct(done: saved + failed + skipped,
                                                    total: tracks.count, trackPct: 100) : -1,
                             label: batch ? "\(i + 1)/\(tracks.count) · \(t.artist) - \(t.title) — Skipped"
                                          : "Skipped")
                continue
            }
            // Defensive re-validate (payload could be reordered); never use raw ids.
            guard OfflineStore.isValidTrackId(t.trackId) else {
                failed += 1
                await report(batch: batch, pct: -1,
                             label: "\(t.artist) - \(t.title) — Invalid id, skipped")
                continue
            }
            let basePct = batch ? Int(Double(i) / Double(max(1, tracks.count)) * 100) : 0
            await report(batch: batch, pct: basePct, label: "\(t.artist) - \(t.title)")
            // 1. Resolve YouTube audio at HIGH (validation skipped for downloads)
            guard let res = try? await InnerTube.shared.resolveAudio(
                title: t.title, artist: t.artist, album: t.album, quality: .high, validate: false) else {
                if state.isCancelled { cancelled = true; break }
                if state.consumeSkip() {
                    skipped += 1
                    await report(batch: batch, pct: batch ? 0 : -1,
                                 label: "\(t.artist) - \(t.title) — Skipped")
                    continue
                }
                failed += 1
                await report(batch: batch, pct: -1,
                             label: "\(t.artist) - \(t.title) — Resolve failed")
                continue
            }
            if state.isCancelled { cancelled = true; break }
            if state.consumeSkip() {
                skipped += 1
                await report(batch: batch, pct: batch ? 0 : -1,
                             label: "\(t.artist) - \(t.title) — Skipped")
                continue
            }
            // 2. Ranged download 8 MiB chunks
            let store = OfflineStore.shared
            let track = OfflineTrack(trackId: t.trackId, title: t.title, artist: t.artist, album: t.album,
                                     coverUrl: t.cover, videoId: res.videoId, ytTitle: res.title,
                                     durationSec: res.lengthSec, explicit: nil, shareLink: nil)
            // Safe: trackId validated above, fileURL sanitizes the display name.
            let tmp = store.dir.appendingPathComponent("\(t.trackId).part")
            let ok = await self.fetchRanged(url: res.audioURL, to: tmp, state: state) { pct in
                let overall = batch
                    ? self.overallPct(done: saved + failed + skipped, total: tracks.count, trackPct: pct)
                    : pct
                Task { await self.report(batch: batch, pct: overall, label: "\(t.artist) - \(t.title)") }
            }
            if state.isCancelled {
                try? FileManager.default.removeItem(at: tmp)
                cancelled = true
                break
            }
            if state.consumeSkip() {
                try? FileManager.default.removeItem(at: tmp)
                skipped += 1
                await report(batch: batch,
                             pct: batch ? overallPct(done: saved + failed + skipped,
                                                    total: tracks.count, trackPct: 100) : -1,
                             label: batch ? "\(i + 1)/\(tracks.count) · \(t.artist) - \(t.title) — Skipped"
                                          : "Skipped")
                continue
            }
            if ok {
                // Atomic final move: remove/replace destination before moveItem,
                // only save() after verified success.
                let dest = store.fileURL(for: track)
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    // Verified success: serialize manifest writes.
                    saveQueue.sync { store.save(track) }
                    saved += 1
                    await report(batch: batch,
                                 pct: batch ? overallPct(done: saved + failed + skipped,
                                                        total: tracks.count, trackPct: 100) : 100,
                                 label: batch ? "\(i + 1)/\(tracks.count) · \(t.artist) - \(t.title) — Saved"
                                              : "Saved to offline")
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    failed += 1
                    await report(batch: batch, pct: -1,
                                 label: "\(t.artist) - \(t.title) — Save failed")
                }
            } else {
                try? FileManager.default.removeItem(at: tmp)
                // Distinguish cancel (already handled) from genuine failure.
                failed += 1
                await report(batch: batch, pct: -1,
                             label: "\(t.artist) - \(t.title) — Download failed")
            }
        }

        // Honest final: batch-Done only when actually done.
        if !batch {
            if cancelled {
                await report(batch: false, pct: -1, label: "Cancelled")
            } else if skipped > 0 && saved == 0 && failed == 0 {
                await report(batch: false, pct: -1, label: "Skipped")
            } else if failed > 0 && saved == 0 {
                await report(batch: false, pct: -1, label: "Download failed")
            } else if saved > 0 {
                // Per-track "Saved" already reported; nothing extra needed.
            } else {
                await report(batch: false, pct: -1, label: "Download failed")
            }
            return
        }
        let total = tracks.count
        let processed = saved + failed + skipped
        var summary = "\(saved) track\(saved == 1 ? "" : "s") saved"
        if skipped > 0 { summary += ", \(skipped) skipped" }
        if failed > 0 { summary += ", \(failed) failed" }
        if cancelled { summary += " — cancelled at \(processed)/\(total)" }
        if cancelled {
            await report(batch: true, pct: -1, label: summary)
        } else if saved > 0 {
            await report(batch: true, pct: 100, label: "\(summary) — Done")
        } else if failed > 0 {
            await report(batch: true, pct: -1, label: summary)
        } else if skipped > 0 {
            await report(batch: true, pct: 100, label: "\(summary) — Done")
        } else {
            await report(batch: true, pct: -1, label: summary)
        }
    }

    private func overallPct(done: Int, total: Int, trackPct: Int) -> Int {
        guard total > 0 else { return min(max(trackPct, 0), 100) }
        let frac = (trackPct >= 0 && trackPct <= 100) ? Double(trackPct) / 100.0 : 0.0
        return min(max(Int((Double(done) + frac) * 100.0 / Double(total)), 0), 100)
    }

    private func fetchRanged(url: URL, to dest: URL, state: RunState,
                             progress: @escaping (Int) -> Void) async -> Bool {
        let chunk = 8 * 1024 * 1024
        // HEAD for length (Content-Length). Mirrors Android contentLengthLong.
        var total: Int = -1
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.setValue(Constants.desktopUA, forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await URLSession.shared.data(for: head),
           let http = resp as? HTTPURLResponse {
            if http.expectedContentLength > 0 {
                total = Int(http.expectedContentLength)
            } else if let cl = http.value(forHTTPHeaderField: "Content-Length"),
                      let n = Int(cl.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
                total = n
            }
        }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: dest) else { return false }
        defer { try? fh.close() }
        var offset = 0
        var done = 0
        while true {
            if state.isCancelled || state.isSkipRequested { return false }
            let end = total > 0 ? min(offset + chunk - 1, total - 1) : offset + chunk - 1
            var chunkOk = false
            var fullBody = false
            for _ in 0..<4 {
                if state.isCancelled || state.isSkipRequested { return false }
                var req = URLRequest(url: url)
                req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                req.setValue(Constants.desktopUA, forHTTPHeaderField: "User-Agent")
                do {
                    let (d, r) = try await URLSession.shared.data(for: req)
                    guard let http = r as? HTTPURLResponse else { continue }
                    let code = http.statusCode
                    guard code == 200 || code == 206 else {
                        // Non-2xx Range response (mirrors Android 200..299 guard):
                        // fail fast — retrying a 4xx will not help.
                        return false
                    }
                    // Learn total from each chunk response (Content-Range/total),
                    // mirroring Android's Content-Range '/'-suffix + contentLengthLong.
                    if total < 0 {
                        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                           let slash = cr.lastIndex(of: "/") {
                            let totalStr = String(cr[cr.index(after: slash)...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if let n = Int(totalStr), n > 0 { total = n }
                        }
                        if total < 0 {
                            if http.expectedContentLength > 0 {
                                total = Int(http.expectedContentLength)
                            } else if let cl = http.value(forHTTPHeaderField: "Content-Length"),
                                      let n = Int(cl.trimmingCharacters(in: .whitespacesAndNewlines)),
                                      n > 0 {
                                // For 206 this is the chunk length, not the total —
                                // only adopt it when the server ignored Range (200).
                                if code == 200 { total = n }
                            }
                        }
                    }
                    // HTTP 200 to a Range request = server ignored Range and sent the
                    // full body: treat as complete, don't append-loop.
                    fullBody = (code == 200)
                    try? fh.write(contentsOf: d)
                    offset += d.count
                    done += d.count
                    chunkOk = true
                    break
                } catch {
                    // Transport error: retry up to 4 (mirrors Android attempt>=4).
                    continue
                }
            }
            if !chunkOk { return false }
            if total > 0 {
                progress(min(max(Int(Double(done) / Double(total) * 100), 0), 100))
                if done >= total { return done > 0 }
            } else {
                // Unknown length stays unknown only if the chunk revealed nothing.
                // fall through to fullBody/loop-end handling below.
            }
            // Mirrors Android outer-loop exits (lines ~623-625):
            if fullBody { total = done; break }
            if total > 0 && done >= total { break }
            if total < 0 { break }
        }
        // Only report success when bytes actually complete and non-empty.
        if done <= 0 { return false }
        if total > 0 { return done >= total }
        return true
    }

    private func report(batch: Bool, pct: Int, label: String) async {
        let esc = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: " ")
        WebViewBus.eval("window.__splDlBatch=\(batch ? "true" : "false");window.splDownloadProgress(\(pct),'\(esc)')")
    }
}
