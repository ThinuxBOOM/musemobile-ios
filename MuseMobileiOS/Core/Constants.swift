import Foundation

public enum Constants {
    public static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    public static let chrome131UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    public static let secCHUA = "\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"150\", \"Google Chrome\";v=\"150\""
    public static let spotifyHome = URL(string: "https://open.spotify.com/")!
    public static let spotifyLogin = URL(string: "https://accounts.spotify.com/login")!
    public static let origin = "https://open.spotify.com"

    public static let nFetchConnectTimeout: TimeInterval = 10
    public static let nFetchBodyCap = 2 * 1024 * 1024
    public static let sharedRequestTimeout: TimeInterval = 15
    public static let sharedResourceTimeout: TimeInterval = 30
    public static let innerTubeBase = "https://music.youtube.com/youtubei/v1"
    public static let poTokenAPIKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"

    /// Transport-only retryable URLErrors (mirrors Android retry policy).
    public static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable, .httpTooManyRedirects,
             .redirectToNonExistentLocation:
            return true
        default: return false
        }
    }

    public static func retry<T>(attempts: Int = 3, op: @escaping () async throws -> T) async throws -> T {
        var delay: UInt64 = 500_000_000
        var last: Error = URLError(.unknown)
        for _ in 0..<attempts {
            do { return try await op() }
            catch let e as URLError where isRetryable(e) {
                last = e; try? await Task.sleep(nanoseconds: delay); delay *= 2
            }
            catch { throw error }
        }
        throw last
    }
}
