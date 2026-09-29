import SwiftUI
import AVKit

/// Offline library + AVPlayer. Mirrors Android OfflineActivity/OfflineScreen/
/// OfflineMediaService: scans app-shared audio dir + same filename regex,
/// manifest offline_meta.json, covers/ dir, background audio mode.
struct OfflineView: View {
    @State private var tracks: [OfflineTrack] = []
    @State private var missingCount = 0
    // Single reused player: pause old item first, then replaceCurrentItem.
    @State private var player = AVPlayer()
    @State private var currentTrackId: String?
    @State private var isPlaying = false

    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Refresh") { reload() }
                }
                .padding(.horizontal)
                if missingCount > 0 {
                    Text("Skipped \(missingCount) missing file\(missingCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                List(tracks, id: \.trackId) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.title).font(.headline)
                            Text(t.artist).font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(currentTrackId == t.trackId && isPlaying ? "Pause" : "Play") {
                            toggle(t)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                // Audio-appropriate now-playing bar (no VideoPlayer frame for .m4a).
                if let current = tracks.first(where: { $0.trackId == currentTrackId }) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(current.title).font(.headline)
                            Text(current.artist).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(isPlaying ? "Pause" : "Play") {
                            if isPlaying {
                                player.pause()
                                isPlaying = false
                            } else {
                                player.play()
                                isPlaying = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle("Offline")
            .onAppear { reload() }
        }
    }

    /// Reload manifest and drop rows whose files are gone (count them in a label).
    private func reload() {
        let all = OfflineStore.shared.allTracks()
        var present: [OfflineTrack] = []
        var missing = 0
        for t in all {
            let url = OfflineStore.shared.fileURL(for: t)
            if FileManager.default.fileExists(atPath: url.path) {
                present.append(t)
            } else {
                missing += 1
            }
        }
        tracks = present
        missingCount = missing
        // If the playing track vanished, stop it.
        if let cur = currentTrackId, !present.contains(where: { $0.trackId == cur }) {
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentTrackId = nil
            isPlaying = false
        }
    }

    private func toggle(_ t: OfflineTrack) {
        let url = OfflineStore.shared.fileURL(for: t)
        // Skip missing files instead of crashing the player.
        guard FileManager.default.fileExists(atPath: url.path) else {
            reload()
            return
        }
        if currentTrackId == t.trackId {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }
        // Pause old item first, then reuse the single player.
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentTrackId = t.trackId
        player.play()
        isPlaying = true
    }
}
