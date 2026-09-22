import Foundation

/// Port of Android `AdBlocker.kt`.
/// NEVER add gew4-spclient / audio-fa / podz-content / generic scdn audio here.
public enum AdBlocker {
    static let analyticsDomains = [
        "doubleclick.net", "googlesyndication.com", "fastly-insights.com",
        "sentry.io", "t.6sc.co", "tracker.samplicio.us", "adsrvr.org",
        "aet.spotify.com", "retargeting-pixels",
        "spotify.com/gabo-receiver-service/public/v3/events",
        // NOTE: workbox-window intentionally NOT blocked — lazy webpack chunk
        // required for web-player init (ChunkLoadError -> error boundary).
    ]
    static let adAudioMarkers = [
        "akamaized.net/audio/", "scdn.co/audio/", "scdn.co/mp3-ad/",
        "spotifycdn.com/audio/", "amillionads.com", "2mdn.net",
        "adxcel.com", "adstudio-assets.scdn.co",
    ]
    static let adCdnPatterns = [
        "scdn.co/mp3-ad/", "mp3ad.scdn.co", "amillionads.com", "2mdn.net",
        "adxcel.com", "adstudio-assets.scdn.co", "audio-ads.spotify.com",
        "ads-akp.spotify.com", "ads-fa.spotify.com", "adeventtracker.spotify.com",
        "pixel-static.spotify.com", "pixel.spotify.com", "adstudio.spotify.com",
        "ads.spotify.com", "/vast/", "/ad-logic/",
    ]

    public static func isAnalytics(_ url: String) -> Bool {
        analyticsDomains.contains { url.contains($0) }
    }
    public static func isAdAudioURL(_ url: String) -> Bool {
        adAudioMarkers.contains { url.contains($0) }
    }
    public static func matchAdCdn(_ url: String) -> String? {
        adCdnPatterns.first { url.contains($0) }
    }
    /// Load-bearing never-block rule: music CDNs must pass through.
    public static func isProtectedMusicURL(_ url: String) -> Bool {
        url.contains("gew4-spclient") || url.contains("podz-content")
            || url.contains("audio-fa") && url.contains("scdn")
    }

    public static func isGoogleAuth(host: String) -> Bool {
        let h = host.lowercased()
        return h == "google.com" || h.hasSuffix(".google.com") || h.contains(".google.")
            || h.hasSuffix(".youtube.com") || h == "youtube.com"
    }
}
