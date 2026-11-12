import XCTest
@testable import CairnUpdateKit

final class DigestTests: XCTestCase {
    // RFC 2617 §3.5's worked example
    func testRFC2617Example() {
        let c = DigestChallenge(realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                opaque: "5ccc069c403ebaf9f0171e9517f40e41")
        let h = Digest.authorization(user: "Mufasa", password: "Circle Of Life", method: "GET", uri: "/dir/index.html",
                                     challenge: c, nc: 1, cnonce: "0a4f113b")
        XCTAssertTrue(h.contains("response=\"6629fae49393a05397450978507c4ef1\""), h)
        XCTAssertTrue(h.contains("nc=00000001,"), h)
    }

    // the firmware's parser finds `nonce="` by substring search: nonce must come before cnonce,
    // nc must be followed by a comma, and opaque must be there
    func testHeaderOrderForTheBoardsParser() {
        let c = DigestChallenge(realm: "MeshCore L2", nonce: "abc", opaque: "def")
        let h = Digest.authorization(user: "meshcore", password: "pw", method: "POST", uri: "/update?size=70000",
                                     challenge: c, nc: 1, cnonce: "xyz")
        let firstNonce = h.range(of: "nonce=\"")!
        XCTAssertEqual(String(h[firstNonce.upperBound...].prefix(3)), "abc")
        XCTAssertTrue(h.contains("nc=00000001,"))
        XCTAssertTrue(h.contains("opaque=\"def\""))
        XCTAssertTrue(h.contains("uri=\"/update?size=70000\""))
    }

    func testParseBoardChallenge() {
        let c = DigestChallenge(header: "Digest realm=\"MeshCore TDeck\", qop=\"auth\", nonce=\"n1\", opaque=\"o1\", stale=true")
        XCTAssertEqual(c?.realm, "MeshCore TDeck")
        XCTAssertEqual(c?.nonce, "n1")
        XCTAssertEqual(c?.opaque, "o1")
        XCTAssertEqual(c?.qop, "auth")
        XCTAssertEqual(c?.stale, true)
        XCTAssertNil(DigestChallenge(header: "Basic realm=\"x\""))
    }
}

final class BoardTests: XCTestCase {
    func testRealms() {
        XCTAssertEqual(Board(realm: "MeshCore L2"), .wioL2Pro)
        XCTAssertEqual(Board(realm: "MeshCore Heltec"), .heltecV4Touch)
        XCTAssertEqual(Board(realm: "MeshCore M9"), .thinkNodeM9)
        XCTAssertEqual(Board(realm: "MeshCore TDeck"), .tDeckPlus)
        XCTAssertNil(Board(realm: "MeshCore"))
        XCTAssertNil(Board(realm: "Other L2"))
    }

    func testBuildNumbers() {
        XCTAssertEqual(cairnBuildNumber("Cairn 111"), 111)
        XCTAssertEqual(cairnBuildNumber("MeshCore-WioL2Pro-Cairn111-2026-10-08-update.bin"), 111)
        XCTAssertNil(cairnBuildNumber("Cairn dev"))
    }

    func testIdentity() {
        let html = "<h1>Firmware update</h1><p class=\"s\">Hiker &amp; Dog &middot; Cairn 111</p><p>Choose"
        let (name, build) = DeviceClient.parseIdentity(html)
        XCTAssertEqual(name, "Hiker & Dog")
        XCTAssertEqual(build, "Cairn 111")
    }

    func testPasswords() {
        XCTAssertEqual(BoardPassword.normalize(" 73XP52G46SCQ "), "73xp52g46scq")
        XCTAssertEqual(BoardPassword.normalize("73xp-52g4-6scq"), "73xp52g46scq")
        XCTAssertEqual(BoardPassword.normalize("73xp52g46sco"), "73xp52g46sc0")   // o read as zero
        XCTAssertNil(BoardPassword.normalize("73xp52g46sc"))                      // 11
        XCTAssertNil(BoardPassword.normalize("73xp52g46scl"))                     // no l on the board
    }

    func testAddresses() throws {
        XCTAssertEqual(try DeviceClient(address: " http://10.0.1.140/ ").host, "10.0.1.140")
        XCTAssertEqual(try DeviceClient(address: "cairn-l2.local:8080").host, "cairn-l2.local:8080")
        XCTAssertThrowsError(try DeviceClient(address: ""))
        XCTAssertThrowsError(try DeviceClient(address: "10.0.1.140/update"))
    }
}

final class ReleaseTests: XCTestCase {
    let names = [
        "MeshCore-HeltecV4-Cairn111-2026-10-08-repeater-update.bin",
        "MeshCore-HeltecV4Touch-Cairn111-2026-10-08-full.bin",
        "MeshCore-HeltecV4Touch-Cairn111-2026-10-08-update.bin",
        "MeshCore-TDeckPlus-Cairn111-2026-10-08-update.bin",
        "MeshCore-WioL2Pro-Cairn111-2026-10-08-update.bin",
        "SHA256SUMS.txt",
    ]

    func testPickAsset() {
        XCTAssertEqual(Releases.pickAsset(names, for: .heltecV4Touch), "MeshCore-HeltecV4Touch-Cairn111-2026-10-08-update.bin")
        XCTAssertEqual(Releases.pickAsset(names, for: .wioL2Pro), "MeshCore-WioL2Pro-Cairn111-2026-10-08-update.bin")
        XCTAssertEqual(Releases.pickAsset(names, for: .tDeckPlus), "MeshCore-TDeckPlus-Cairn111-2026-10-08-update.bin")
        XCTAssertNil(Releases.pickAsset(names, for: .thinkNodeM9))
    }

    func testSums() {
        let hex = String(repeating: "ab", count: 32)
        let sums = Releases.parseSums("\(hex)  MeshCore-WioL2Pro-Cairn111-2026-10-08-update.bin\n\(hex) *other.bin\nbad line\n")
        XCTAssertEqual(sums["MeshCore-WioL2Pro-Cairn111-2026-10-08-update.bin"], hex)
        XCTAssertEqual(sums["other.bin"], hex)
        XCTAssertEqual(sums.count, 2)
        XCTAssertEqual(Releases.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
