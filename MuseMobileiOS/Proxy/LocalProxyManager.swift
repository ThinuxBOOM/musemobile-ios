import Foundation
import Network

/// MITM proxy mode (optional). Android: loopback proxy + local CA (RSA-2048,
/// 10y CN=MuseMobile Proxy CA, PKCS12 proxy_ca.p12, per-host leaf 1y).
/// iOS: WKWebView ignores per-view proxies — route API traffic through native
/// URLSession with proxy config (mngFetch pattern); leaf-cert issuance via
/// Network.framework listener / NETransparentProxy; trust via profile install +
/// SecTrust anchor (no plist user-CA equivalent). Splash blocks until CA
/// installed; export MuseMobile_CA.pem via share sheet; "Switch to Normal"
/// escape hatch always available.
public final class LocalProxyManager {
    public static let shared = LocalProxyManager()
    public private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private init() {}

    public func start() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: .loopback)
        listener?.newConnectionHandler = { conn in conn.start(queue: .global()) }
        listener?.start(queue: .global())
        port = 8080 // ephemeral in production: read back actual port
    }
    public func stop() { listener?.cancel(); listener = nil }
    public var proxyConfig: [AnyHashable: Any] {
        ["HTTPEnable": 1, "HTTPPort": port, "HTTPPProxy": "127.0.0.1"]
    }
}
