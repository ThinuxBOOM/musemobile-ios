import Foundation
import Network

/// Loopback HTTP CONNECT forwarder (proxy "smoke" path).
///
/// WHAT WORKS (headless-testable, Simulator-safe):
/// - Ephemeral loopback NWListener; `start()` publishes `port`, `stop()` cancels.
/// - Inbound HTTP CONNECT parsing: request line + headers are read until
///   `\r\n\r\n` with a 32KB cap (larger -> `431` + close).
/// - CONNECT target validation: non-empty host, port 1...65535; loopback-range
///   targets (`127.*`, `localhost`, `::1`, `0.0.0.0`) are refused with `403`
///   to avoid proxy loops.
/// - On valid CONNECT: an outbound NWConnection is opened to host:port; on
///   upstream failure the client gets `502` + close; on success the client gets
///   `HTTP/1.1 200 Connection Established` and bytes are pumped bidirectionally
///   until either side closes/errors (both directions cancelled on error).
/// - Plain-HTTP (non-CONNECT, e.g. `GET http://...`) gets
///   `HTTP/1.1 501 Not Implemented` + close: HTTPS/CONNECT only for smoke.
///
/// WHAT IS STUBBED (documented, NOT implemented):
/// - TLS MITM / CA + per-host leaf issuance (Android: RSA-2048 10y
///   `CN=MuseMobile Proxy CA` in `proxy_ca.p12`, per-host 1y leaf, upstream
///   pooling, header spoofing). There is deliberately NO TLS interception here:
///   this forwarder is a blind TCP tunnel after the 200.
/// - Cert-install UX / trust plumbing (profile install + SecTrust anchor,
///   `MuseMobile_CA.pem` export, "Switch to Normal" escape hatch lives in UI).
/// - WebSocket passthrough beyond the blind tunnel (works only as opaque bytes
///   inside an established CONNECT tunnel; no 101 upgrade handling).
/// - Upstream connection pooling (one NWConnection per CONNECT).
///
/// WHY: CA issuance + profile trust + WebSocket upgrade handling need a real
/// device + user-trusted profile and cannot be tested headless; the blind
/// CONNECT tunnel is the most that is safe to run in the Simulator. Proxy and
/// CarPlay paths are runtime-gated and never crash at launch.
public final class LocalProxyManager {
    public static let shared = LocalProxyManager()

    /// Ephemeral loopback port (0 = not listening).
    public private(set) var port: UInt16 = 0

    private static let maxHeaderBytes = 32 * 1024

    private var listener: NWListener?
    private let stateLock = NSLock()

    private init() {}

    /// Starts the loopback listener. Throws (never crashes) if the listener
    /// cannot be created; a no-op if already started.
    public func start() throws {
        stateLock.lock()
        let alreadyRunning = listener != nil
        stateLock.unlock()
        if alreadyRunning { return }

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: .any) // ephemeral port
        l.stateUpdateHandler = { [weak self] state in
            // Refresh the published port once the listener is actually bound;
            // report failures without crashing (listener stays until stop()).
            if case .ready = state {
                self?.refreshPort()
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self = self else { conn.cancel(); return }
            self.accept(conn)
        }
        l.start(queue: .global(qos: .utility))

        stateLock.lock()
        listener = l
        if let raw = l.port?.rawValue {
            port = raw
        }
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        let l = listener
        listener = nil
        port = 0
        stateLock.unlock()
        l?.cancel()
    }

    public var proxyConfig: [AnyHashable: Any] {
        ["HTTPEnable": 1, "HTTPPort": port, "HTTPPProxy": "127.0.0.1"]
    }

    // MARK: - Private

    private func refreshPort() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let raw = listener?.port?.rawValue {
            port = raw
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readRequest(conn, buffer: Data())
            case .failed:
                conn.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    /// Accumulates inbound bytes until the end of the HTTP header block.
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        if buffer.count > Self.maxHeaderBytes {
            replyAndClose(conn, status: "431 Request Header Fields Too Large")
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self = self else { conn.cancel(); return }
            if error != nil {
                conn.cancel()
                return
            }
            var next = buffer
            if let data = data, !data.isEmpty {
                next.append(data)
            } else {
                // Clean EOF before a complete header block: nothing to do.
                conn.cancel()
                return
            }
            if next.count > Self.maxHeaderBytes {
                self.replyAndClose(conn, status: "431 Request Header Fields Too Large")
                return
            }
            if let range = next.range(of: Data("\r\n\r\n".utf8)) {
                let header = next.subdata(in: next.startIndex..<range.lowerBound)
                self.handleRequest(conn, headerData: header)
            } else {
                self.readRequest(conn, buffer: next)
            }
        }
    }

    private func handleRequest(_ conn: NWConnection, headerData: Data) {
        let headerText = String(data: headerData, encoding: .isoLatin1) ?? ""
        if headerText.isEmpty {
            replyAndClose(conn, status: "400 Bad Request")
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            replyAndClose(conn, status: "400 Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            replyAndClose(conn, status: "400 Bad Request")
            return
        }
        guard String(parts[0]).uppercased() == "CONNECT" else {
            // Documented: plain-HTTP is not forwarded (HTTPS/CONNECT only).
            replyAndClose(conn, status: "501 Not Implemented")
            return
        }
        guard let target = parseHostPort(String(parts[1])) else {
            replyAndClose(conn, status: "400 Bad Request")
            return
        }
        if isLoopbackHost(target.host) {
            // Refuse proxy-loop targets.
            replyAndClose(conn, status: "403 Forbidden")
            return
        }
        openTunnel(inbound: conn, host: target.host, port: target.port)
    }

    /// Parses `host:port` from a CONNECT target. Port must be 1...65535.
    private func parseHostPort(_ target: String) -> (host: String, port: UInt16)? {
        guard let colon = target.lastIndex(of: ":") else { return nil }
        var host = String(target[..<colon])
        let portString = String(target[target.index(after: colon)...])
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        guard let port = UInt16(portString), port >= 1 else { return nil }
        return (host, port)
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "localhost." || h == "::1" || h == "0.0.0.0" {
            return true
        }
        if h.hasPrefix("127.") {
            return true
        }
        return false
    }

    private func openTunnel(inbound: NWConnection, host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            replyAndClose(inbound, status: "502 Bad Gateway")
            return
        }
        let outbound = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        outbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                outbound.stateUpdateHandler = nil
                self?.relayReady(inbound: inbound, outbound: outbound)
            case .failed:
                self?.replyAndClose(inbound, status: "502 Bad Gateway")
                outbound.cancel()
            case .cancelled:
                inbound.cancel()
            default:
                break
            }
        }
        outbound.start(queue: .global(qos: .utility))
    }

    private func relayReady(inbound: NWConnection, outbound: NWConnection) {
        let relay = Relay(inbound, outbound)
        let ok = "HTTP/1.1 200 Connection Established\r\n\r\n"
        inbound.send(content: Data(ok.utf8), completion: .contentProcessed({ [weak relay] error in
            guard let relay = relay else { return }
            if error != nil {
                relay.stop()
                return
            }
            relay.start()
        }))
    }

    private func replyAndClose(_ conn: NWConnection, status: String) {
        let text = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(text.utf8), completion: .contentProcessed({ _ in
            conn.cancel()
        }))
    }

    /// Owns one CONNECT tunnel: holds both connections strongly and pumps
    /// bytes in both directions until either side closes or errors, at which
    /// point both directions are cancelled. Retained by its own in-flight
    /// receive/send completions (all captured weakly), so it lives exactly as
    /// long as the tunnel and cannot leak or retain LocalProxyManager.
    private final class Relay {
        private let inbound: NWConnection
        private let outbound: NWConnection
        private let lock = NSLock()
        private var stopped = false

        init(_ inbound: NWConnection, _ outbound: NWConnection) {
            self.inbound = inbound
            self.outbound = outbound
        }

        func start() {
            pump(from: inbound, to: outbound)
            pump(from: outbound, to: inbound)
        }

        func stop() {
            lock.lock()
            let already = stopped
            stopped = true
            lock.unlock()
            if !already {
                inbound.cancel()
                outbound.cancel()
            }
        }

        private func isStopped() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        private func pump(from src: NWConnection, to dst: NWConnection) {
            src.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if self.isStopped() { return }
                if error != nil {
                    self.stop()
                    return
                }
                guard let data = data, !data.isEmpty else {
                    // EOF (or empty read): NWConnection has no half-close, so
                    // a clean shutdown in one direction ends the whole tunnel.
                    self.stop()
                    return
                }
                dst.send(content: data, completion: .contentProcessed({ [weak self] sendError in
                    guard let self = self else { return }
                    if self.isStopped() { return }
                    if sendError != nil {
                        self.stop()
                        return
                    }
                    if isComplete {
                        self.stop()
                        return
                    }
                    self.pump(from: src, to: dst)
                }))
            }
        }
    }
}
