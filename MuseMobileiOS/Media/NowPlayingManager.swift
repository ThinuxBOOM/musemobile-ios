import Foundation
import MediaPlayer
import UIKit
import WebKit

/// Mirrors Android `MediaNotificationService`: lockscreen/BT/CarPlay metadata +
/// remote commands -> act* JS calls. Background audio mode required in Info.plist.
public final class NowPlayingManager {
    public static let shared = NowPlayingManager()
    private init() { setupCommands() }

    public func update(from json: String) {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = o["track"] as? String ?? ""
        info[MPMediaItemPropertyArtist] = o["artist"] as? String ?? ""
        info[MPMediaItemPropertyAlbumTitle] = "MuseMobile"
        if let dur = o["duration"] as? NSNumber { info[MPMediaItemPropertyPlaybackDuration] = dur.doubleValue / 1000 }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = ((o["position"] as? NSNumber)?.doubleValue ?? 0) / 1000
        info[MPNowPlayingInfoPropertyPlaybackRate] = ((o["playing"] as? Bool) ?? false) ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if let cover = o["cover"] as? String, let url = URL(string: cover) {
            Task { // <=512px cover fetch (PiP/lockscreen)
                if let (d, _) = try? await URLSession.shared.data(from: url),
                   let img = UIImage(data: d) {
                    let scaled = img.scaled(to: 512)
                    await MainActor.run {
                        var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        cur[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: scaled.size) { _ in scaled }
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
                    }
                }
            }
        }
    }

    public func updatePosition(_ ms: Int64) {
        var cur = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        cur[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(ms) / 1000
        MPNowPlayingInfoCenter.default().nowPlayingInfo = cur
    }

    private func js(_ s: String) {
        // Injected via MainView's WKWebView reference (set at appear).
        WebViewBus.eval(s)
    }

    private func setupCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { _ in self.js("actPlayPause(true)"); return .success }
        cc.pauseCommand.addTarget { _ in self.js("actPlayPause(false)"); return .success }
        cc.togglePlayPauseCommand.addTarget { _ in self.js("actPlayPause()"); return .success }
        cc.nextTrackCommand.addTarget { _ in self.js("actSkipForward()"); return .success }
        cc.previousTrackCommand.addTarget { _ in self.js("actSkipBack()"); return .success }
        cc.changePlaybackPositionCommand.addTarget { e in
            if let ev = e as? MPChangePlaybackPositionCommandEvent { self.js("actSeek(\(Int(ev.positionTime*1000)))") }
            return .success
        }
        cc.likeCommand.addTarget { _ in self.js("actAddToFav()"); return .success }
        cc.dislikeCommand.addTarget { _ in self.js("actAddToFav()"); return .success }
        cc.changeShuffleModeCommand.addTarget { _ in self.js("actToggleShuffle()"); return .success }
        // repeat mapped via custom handler (cycles JS actRepeat)
        cc.changeRepeatModeCommand.isEnabled = true
        cc.changeRepeatModeCommand.addTarget { _ in self.js("actRepeat()"); return .success }
    }
}

/// Minimal bus so singletons can eval JS without retaining the view.
public enum WebViewBus {
    public static var eval: (String) -> Void = { _ in }
}

public typealias WKWebViewStub = WKWebView

extension UIImage {
    func scaled(to max: CGFloat) -> UIImage {
        let s = min(1, max / max(size.width, size.height))
        if s >= 1 { return self }
        let sz = CGSize(width: size.width*s, height: size.height*s)
        return UIGraphicsImageRenderer(size: sz).image { _ in draw(in: CGRect(origin: .zero, size: sz)) }
    }
}
