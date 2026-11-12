import Foundation
import CryptoKit

/// HTTP Digest (RFC 2617, MD5, qop=auth) as the board's updater mode speaks it.
///
/// The firmware's server (arduino-esp32 WebServer) keeps one nonce and parses the Authorization header
/// by plain substring search, which sets a few rules for the header we send:
/// - `nonce` comes before `cnonce`: a search for `nonce="` would otherwise land inside `cnonce="`.
/// - `nc` is followed by a comma: it is read up to the next `,`.
/// - `opaque` must be sent back: the server refuses a header without it.
public struct DigestChallenge: Equatable, Sendable {
    public var realm: String
    public var nonce: String
    public var opaque: String
    public var qop: String?
    public var stale: Bool

    /// Parses a `WWW-Authenticate: Digest ...` value; nil when it is not a usable Digest challenge.
    public init?(header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest ") else { return nil }
        let params = DigestChallenge.parseParams(String(trimmed.dropFirst(7)))
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        self.realm = realm
        self.nonce = nonce
        self.opaque = params["opaque"] ?? ""
        self.qop = params["qop"]
        self.stale = (params["stale"] ?? "").lowercased() == "true"
    }

    public init(realm: String, nonce: String, opaque: String, qop: String? = "auth", stale: Bool = false) {
        self.realm = realm
        self.nonce = nonce
        self.opaque = opaque
        self.qop = qop
        self.stale = stale
    }

    /// `key=value` / `key="value"` pairs separated by commas (quoted values may hold commas).
    static func parseParams(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        func skipSpaceAndCommas() {
            while i < s.endIndex, s[i] == " " || s[i] == "," || s[i] == "\t" { i = s.index(after: i) }
        }
        while true {
            skipSpaceAndCommas()
            guard i < s.endIndex else { break }
            let keyStart = i
            while i < s.endIndex, s[i] != "=" { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let key = s[keyStart..<i].trimmingCharacters(in: .whitespaces).lowercased()
            i = s.index(after: i)   // '='
            var value = ""
            if i < s.endIndex, s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex, s[i] != "\"" {
                    if s[i] == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
                    value.append(s[i])
                    i = s.index(after: i)
                }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let vStart = i
                while i < s.endIndex, s[i] != "," { i = s.index(after: i) }
                value = s[vStart..<i].trimmingCharacters(in: .whitespaces)
            }
            out[key] = value
        }
        return out
    }
}

public enum Digest {
    public static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `Authorization` value for one request. `uri` is the request target exactly as sent
    /// (path and query, e.g. `/update?size=3365984`); `nc` counts the requests made with this nonce.
    public static func authorization(user: String, password: String, method: String, uri: String,
                                     challenge c: DigestChallenge, nc: Int, cnonce: String) -> String {
        let ha1 = md5Hex("\(user):\(c.realm):\(password)")
        let ha2 = md5Hex("\(method.uppercased()):\(uri)")
        let ncs = String(format: "%08x", nc)
        let useQop = c.qop.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("auth") } ?? false
        let response = useQop ? md5Hex("\(ha1):\(c.nonce):\(ncs):\(cnonce):auth:\(ha2)")
                              : md5Hex("\(ha1):\(c.nonce):\(ha2)")
        // order matters to the firmware's parser: see DigestChallenge
        var parts = [
            "username=\"\(user)\"",
            "realm=\"\(c.realm)\"",
            "nonce=\"\(c.nonce)\"",
            "uri=\"\(uri)\"",
        ]
        if useQop {
            parts.append("qop=auth")
            parts.append("nc=\(ncs)")
            parts.append("cnonce=\"\(cnonce)\"")
        }
        parts.append("response=\"\(response)\"")
        parts.append("opaque=\"\(c.opaque)\"")
        return "Digest " + parts.joined(separator: ", ")
    }

    public static func makeCnonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
