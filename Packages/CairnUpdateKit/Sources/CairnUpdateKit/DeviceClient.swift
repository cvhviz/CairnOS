import Foundation

public struct DeviceInfo: Equatable, Sendable {
    public var host: String
    public var realm: String
    public var board: Board?
    public var nodeName: String?
    public var buildName: String?
    public var buildNumber: Int? { buildName.flatMap(cairnBuildNumber) }
}

public enum UpdateError: LocalizedError, Equatable {
    case badAddress
    case notInUpdateMode
    case wrongPassword
    case device(status: Int, message: String)
    case network(String)
    case noReleaseImage(board: String)
    case checksumMismatch
    case checksumMissing
    case github(String)

    public var errorDescription: String? {
        switch self {
        case .badAddress: return "That isn't a board address. Use the address shown in updater mode, such as 10.0.1.140."
        case .notInUpdateMode: return "No board in updater mode answered there. On the board: Settings › System › Firmware update › Start updater mode."
        case .wrongPassword: return "Wrong password. Use the one on the board's screen. After 10 wrong tries the board stops updater mode."
        case .device(_, let m): return m
        case .network(let m): return m
        case .noReleaseImage(let b): return "The latest Cairn release has no update file for the \(b)."
        case .checksumMismatch: return "The download doesn't match the release's SHA256SUMS. Nothing was sent to the board."
        case .checksumMissing: return "The release has no checksum for this file. Nothing was sent to the board."
        case .github(let m): return m
        }
    }
}

/// Talks to one board's updater mode (Settings › System › Firmware update on the board): user `meshcore`,
/// HTTP Digest with the password the board shows, `GET /` for its name and build, and
/// `POST /update?size=<bytes>` with the image as the multipart field `firmware`.
public final class DeviceClient: @unchecked Sendable {
    public static let user = "meshcore"
    public let host: String
    private let http: MiniHTTP

    /// `address`: an IP or hostname, optionally with `:port`, optionally with `http://`.
    public init(address: String) throws {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.lowercased().hasPrefix("http://") { a = String(a.dropFirst(7)) }
        while a.hasSuffix("/") { a.removeLast() }
        guard !a.isEmpty, !a.contains("/"), !a.contains(" "), !a.contains("@"),
              URL(string: "http://\(a)/")?.host != nil, let h = MiniHTTP(authority: a) else { throw UpdateError.badAddress }
        host = a
        http = h
    }

    /// An unauthenticated `GET /`: the board answers 401 with a fresh Digest challenge naming the board.
    /// A request without credentials never counts as a wrong password.
    public func challenge() async throws -> DigestChallenge {
        let r = try await get(authorization: nil)
        guard r.status == 401, let h = r.header("WWW-Authenticate"), let c = DigestChallenge(header: h) else {
            throw UpdateError.notInUpdateMode
        }
        return c
    }

    /// Checks the password and reads the board's name and build. A wrong password costs one of the
    /// board's ten tries (each request goes out once); a stale nonce (another browser on the board
    /// replaced ours) is retried once with the new one, which costs nothing.
    public func connect(password: String) async throws -> DeviceInfo {
        try await login(password: password).info
    }

    /// connect(), keeping the challenge the password was proven with (install() goes on with it)
    private func login(password: String) async throws -> (info: DeviceInfo, challenge: DigestChallenge) {
        var c = try await challenge()
        for attempt in 0..<2 {
            let auth = Digest.authorization(user: Self.user, password: password, method: "GET", uri: "/",
                                            challenge: c, nc: 1, cnonce: Digest.makeCnonce())
            let r = try await get(authorization: auth)
            if r.status == 200 {
                let (name, build) = Self.parseIdentity(String(decoding: r.body, as: UTF8.self))
                return (DeviceInfo(host: host, realm: c.realm, board: Board(realm: c.realm), nodeName: name, buildName: build), c)
            }
            if r.status == 401, let h = r.header("WWW-Authenticate"), let next = DigestChallenge(header: h) {
                if next.stale && attempt == 0 { c = next; continue }
                throw UpdateError.wrongPassword
            }
            throw UpdateError.device(status: r.status, message: Self.message(r.body, r.status))
        }
        throw UpdateError.wrongPassword
    }

    /// Sends the image. `progress` gets 0...1 as the bytes go out (the board writes them to flash as
    /// they arrive). Returns once the board has accepted the whole image; it then restarts by itself.
    public func install(image: Data, fileName: String, password: String,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        let target = "/update?size=\(image.count)"
        let boundary = "CairnUpdater-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        let safeName = fileName.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "")
                               .replacingOccurrences(of: "\n", with: "")
        body.append(Data("Content-Disposition: form-data; name=\"firmware\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(image)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        // Prove the password (and that updater mode is still on) with a small GET first: a password that
        // changed since connecting (updater mode restarted, New password) then costs one try and no 3 MB
        // upload. The POST goes on with the same nonce (nc 2), so nothing can have replaced it in between
        // short of another browser on the board.
        let c = try await login(password: password).challenge
        let auth = Digest.authorization(user: Self.user, password: password, method: "POST", uri: target,
                                        challenge: c, nc: 2, cnonce: Digest.makeCnonce())
        let r: HTTPResponse
        do {
            // the board writes flash as the bytes arrive; 30 s without progress is a stalled board
            r = try await http.send(method: "POST", target: target, hostHeader: host,
                                    headers: [("Authorization", auth),
                                              ("Content-Type", "multipart/form-data; boundary=\(boundary)")],
                                    body: body, idleTimeout: 30) { p in progress(min(0.99, p)) }
        } catch {
            throw Self.mapError(error, uploading: true)
        }
        if r.status == 200 { progress(1); return }
        // the upload's own 401 ("Password expired, reload") means the nonce was replaced mid-way
        // (another browser on the board); the password was right a moment ago, so say what happened
        if r.status == 401 {
            throw UpdateError.device(status: 401, message: "The board's login changed during the upload (another browser open on it?). Try again.")
        }
        throw UpdateError.device(status: r.status, message: Self.message(r.body, r.status))
    }

    // MARK: - helpers

    private func get(authorization: String?) async throws -> HTTPResponse {
        do {
            return try await http.send(method: "GET", target: "/", hostHeader: host,
                                       headers: authorization.map { [("Authorization", $0)] } ?? [], idleTimeout: 10)
        } catch {
            throw Self.mapError(error, uploading: false)
        }
    }

    static func mapError(_ error: Error, uploading: Bool) -> Error {
        if error is CancellationError { return error }
        switch error as? MiniHTTPError {
        case .cannotConnect?:
            return UpdateError.network("Can't reach the board there. Check the address, that updater mode is on, and that this device is on the same Wi-Fi.")
        case .timedOut?:
            return UpdateError.network(uploading ? "The board stopped answering during the upload. Check its screen; if it is still in updater mode, try again."
                                                 : "No answer from that address. Check the board is in updater mode.")
        case .connectionLost?:
            return UpdateError.network(uploading ? "The connection to the board dropped during the upload. Check its screen, then try again."
                                                 : "The board closed the connection. Check it is in updater mode.")
        case .badResponse?:
            return UpdateError.notInUpdateMode
        case nil:
            return UpdateError.network(error.localizedDescription)
        }
    }

    static func message(_ data: Data, _ status: Int) -> String {
        let t = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") { return "The board answered \(status)." }
        return t
    }

    /// The page's subtitle: `<p class="s">Node name &middot; Cairn 111</p>`
    static func parseIdentity(_ html: String) -> (String?, String?) {
        guard let start = html.range(of: "<p class=\"s\">"),
              let end = html.range(of: "</p>", range: start.upperBound..<html.endIndex) else { return (nil, nil) }
        let mid = String(html[start.upperBound..<end.lowerBound])
        let parts = mid.components(separatedBy: " &middot; ")
        guard parts.count >= 2 else { return (unescape(mid), nil) }
        return (unescape(parts.dropLast().joined(separator: " · ")), unescape(parts.last!))
    }

    static func unescape(_ s: String) -> String {
        var t = s
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}
