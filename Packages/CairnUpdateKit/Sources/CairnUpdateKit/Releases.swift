import Foundation
import CryptoKit

public struct ReleaseImage: Equatable, Sendable {
    public var tag: String           // cairn-v111
    public var title: String         // Cairn 111
    public var buildNumber: Int?
    public var assetName: String
    public var downloadURL: URL
    public var size: Int
    public var sumsURL: URL?         // SHA256SUMS.txt
    public var pageURL: URL?
    public var publishedAt: Date?
}

/// The latest published Cairn release on GitHub (cvhviz/Cairn), its update image for a board, and the
/// image itself, checked against the release's SHA256SUMS.txt before anything is sent to a board.
public struct Releases: Sendable {
    public var repo: String
    private let session: URLSession

    public init(repo: String = "cvhviz/Cairn", session: URLSession = .shared) {
        self.repo = repo
        self.session = session
    }

    struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let html_url: URL?
        let published_at: Date?
        let assets: [Asset]
    }

    /// `MeshCore-<assetKey>-Cairn<n>-<yyyy-mm-dd>-update.bin`, the touch build's app image (not the
    /// `-full.bin`, and not a repeater's `-repeater-update.bin`).
    public static func pickAsset(_ names: [String], for board: Board) -> String? {
        let pattern = "^MeshCore-\(board.assetKey)-Cairn[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-update\\.bin$"
        return names.first { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    /// `shasum -a 256` output: "<hex>  <name>" (or "<hex> *<name>") per line
    public static func parseSums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hex = parts[0].lowercased()
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if hex.count == 64, hex.allSatisfy(\.isHexDigit) { out[name] = hex }
        }
        return out
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func latest(for board: Board) async throws -> ReleaseImage {
        try await latest(boardName: board.displayName) { Self.pickAsset($0, for: board) }
    }

    /// The latest release's asset whose whole name matches `assetPattern` (a regular expression),
    /// for boards other than the touch boards (an nRF52 board's `.uf2`). `boardName` names the
    /// board in the error when the release has no such asset.
    public func latest(assetPattern: String, boardName: String) async throws -> ReleaseImage {
        try await latest(boardName: boardName) { names in
            names.first { $0.range(of: assetPattern, options: .regularExpression) != nil }
        }
    }

    private func latest(boardName: String, pick: ([String]) -> String?) async throws -> ReleaseImage {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CairnUpdater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw UpdateError.github("Can't reach GitHub to find the latest release: \(error.localizedDescription)")
        }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError.github(code == 403 || code == 429 ? "GitHub is limiting requests. Try again in a few minutes."
                                                                : "GitHub answered \(code) for the latest release.")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(APIRelease.self, from: data)
        guard let name = pick(r.assets.map(\.name)),
              let asset = r.assets.first(where: { $0.name == name }) else {
            throw UpdateError.noReleaseImage(board: boardName)
        }
        let title = r.name ?? r.tag_name
        return ReleaseImage(tag: r.tag_name, title: title,
                            buildNumber: cairnBuildNumber(title) ?? cairnBuildNumber(name),
                            assetName: name, downloadURL: asset.browser_download_url, size: asset.size,
                            sumsURL: r.assets.first(where: { $0.name == "SHA256SUMS.txt" })?.browser_download_url,
                            pageURL: r.html_url, publishedAt: r.published_at)
    }

    /// Downloads the image and its checksum list; returns the image only when the SHA-256 matches.
    public func download(_ img: ReleaseImage) async throws -> Data {
        guard let sumsURL = img.sumsURL else { throw UpdateError.checksumMissing }
        let sumsText: String
        do {
            let (d, r) = try await session.data(from: sumsURL)
            guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.checksumMissing }
            sumsText = String(decoding: d, as: UTF8.self)
        } catch let e as UpdateError { throw e } catch {
            throw UpdateError.github("Can't download the checksums: \(error.localizedDescription)")
        }
        guard let want = Self.parseSums(sumsText)[img.assetName] else { throw UpdateError.checksumMissing }
        let data: Data
        do {
            let (d, r) = try await session.data(from: img.downloadURL)
            guard (r as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.github("GitHub answered \((r as? HTTPURLResponse)?.statusCode ?? 0) for \(img.assetName).")
            }
            data = d
        } catch let e as UpdateError { throw e } catch {
            throw UpdateError.github("The download failed: \(error.localizedDescription)")
        }
        guard Self.sha256Hex(data) == want else { throw UpdateError.checksumMismatch }
        return data
    }
}
