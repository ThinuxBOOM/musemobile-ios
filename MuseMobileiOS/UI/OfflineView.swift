import SwiftUI
import AVKit

/// Offline library + AVPlayer. Mirrors Android OfflineActivity/OfflineScreen/
/// OfflineMediaService: scans app-shared audio dir + same filename regex,
/// manifest offline_meta.json, covers/ dir, background audio mode.
struct OfflineView: View {
    @State private var tracks: [OfflineTrack] = []
    @State private var player: AVPlayer? = nil

    var body: some View {
        NavigationView {
            VStack {
                List(tracks, id: \.trackId) { t in
                    Button("\(t.artist) - \(t.title)") {
                        let url = OfflineStore.shared.fileURL(for: t)
                        player = AVPlayer(url: url); player?.play()
                    }
                }
                if let player {
                    VideoPlayer(player: player).frame(height: 200)
                }
            }
            .navigationTitle("Offline")
            .onAppear { tracks = OfflineStore.shared.allTracks() }
        }
    }
}
