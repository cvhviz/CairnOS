import Foundation

/// The Cairn touch boards that have a Wi-Fi updater mode. The board names itself in its Digest realm
/// ("MeshCore L2", L2_BOARD_TINY in the firmware); the release names its images by `assetKey`.
public enum Board: String, CaseIterable, Sendable, Identifiable {
    case wioL2Pro, heltecV4Touch, thinkNodeM9, tDeckPlus

    public var id: String { rawValue }

    /// L2_BOARD_TINY, as the realm carries it
    public var realmTag: String {
        switch self {
        case .wioL2Pro: return "L2"
        case .heltecV4Touch: return "Heltec"
        case .thinkNodeM9: return "M9"
        case .tDeckPlus: return "TDeck"
        }
    }

    /// The board part of a release image's name: MeshCore-<assetKey>-Cairn111-2026-10-08-update.bin
    public var assetKey: String {
        switch self {
        case .wioL2Pro: return "WioL2Pro"
        case .heltecV4Touch: return "HeltecV4Touch"
        case .thinkNodeM9: return "ThinkNodeM9"
        case .tDeckPlus: return "TDeckPlus"
        }
    }

    public var displayName: String {
        switch self {
        case .wioL2Pro: return "Wio Tracker L2 Pro"
        case .heltecV4Touch: return "Heltec V4 touch"
        case .thinkNodeM9: return "ThinkNode M9"
        case .tDeckPlus: return "T-Deck Plus"
        }
    }

    /// From a realm such as "MeshCore L2"; nil for anything else (not a Cairn board in updater mode).
    public init?(realm: String) {
        let parts = realm.split(separator: " ")
        guard parts.count == 2, parts[0] == "MeshCore" else { return nil }
        guard let b = Board.allCases.first(where: { $0.realmTag == String(parts[1]) }) else { return nil }
        self = b
    }
}

/// "Cairn 111" (CVH_BUILD_NAME) -> 111. Development builds ("Cairn dev") have no number.
public func cairnBuildNumber(_ s: String) -> Int? {
    guard let r = s.range(of: #"Cairn\s*(\d+)"#, options: .regularExpression) else { return nil }
    let digits = s[r].filter(\.isNumber)
    return Int(digits)
}

/// The board's update-mode password: 12 characters of "abcdefghjkmnpqrstuvwxyz023456789" (no i, l, o, 1;
/// OtaService.cpp genPassword). Typed input is lowercased, spaces and dashes dropped, and an "o" read as
/// zero; anything that still can't be a board password is caught here, before it costs one of the
/// board's ten tries. Returns nil for such input.
public enum BoardPassword {
    public static let alphabet = Set("abcdefghjkmnpqrstuvwxyz023456789")
    public static let length = 12

    public static func normalize(_ typed: String) -> String? {
        var s = typed.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        s = String(s.map { $0 == "o" ? "0" : $0 })
        guard s.count == length, s.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return s
    }
}
