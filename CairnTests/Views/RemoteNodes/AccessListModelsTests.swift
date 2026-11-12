import Foundation
@testable import Cairn
import MeshCore
import Testing

@Suite("AccessListModels")
struct AccessListModelsTests {
  private let fullKey = Data((0..<32).map { UInt8($0) })

  // MARK: - Role

  @Test
  func `Role reads the low two permission bits`() {
    #expect(AccessListRole(permissions: 0x00) == .guest)
    #expect(AccessListRole(permissions: 0x01) == .readOnly)
    #expect(AccessListRole(permissions: 0x02) == .readWrite)
    #expect(AccessListRole(permissions: 0x03) == .admin)
    #expect(AccessListRole(permissions: 0xF3) == .admin)
    #expect(AccessListRole(permissions: 0x84) == .guest)
  }

  // MARK: - Commands

  @Test
  func `Set role needs a complete public key`() {
    #expect(AccessListCommand.setRole(.admin, publicKey: fullKey) == "setperm \(fullKey.hexString) 3")
    #expect(AccessListCommand.setRole(.readOnly, publicKey: fullKey)?.hasSuffix(" 1") == true)
    #expect(AccessListCommand.setRole(.admin, publicKey: fullKey.prefix(6)) == nil)
  }

  @Test
  func `Set role refuses guest because guest removes the entry`() {
    #expect(AccessListCommand.setRole(.guest, publicKey: fullKey) == nil)
  }

  @Test
  func `Remove sends the prefix with zero permissions`() {
    let prefix = Data([0xAB, 0xCD, 0xEF, 0x01, 0x02, 0x03])
    #expect(AccessListCommand.remove(keyPrefix: prefix) == "setperm abcdef010203 0")
    #expect(AccessListCommand.remove(keyPrefix: Data()) == nil)
  }

  @Test
  func `Success detection accepts OK replies only`() {
    #expect(AccessListCommand.isSuccess("OK"))
    #expect(AccessListCommand.isSuccess("  ok\n"))
    #expect(AccessListCommand.isSuccess("> OK"))
    #expect(!AccessListCommand.isSuccess("Err - invalid params"))
    #expect(!AccessListCommand.isSuccess(""))
  }

  // MARK: - Resolver

  @Test
  func `Resolver names known prefixes, flags self, and sorts admins first`() {
    let alice = Data([0x11] + Array(repeating: 0xAA, count: 31))
    let me = Data([0x22] + Array(repeating: 0xBB, count: 31))
    let entries = [
      ACLEntry(keyPrefix: Data(repeating: 0x99, count: 6), permissions: 0x03),
      ACLEntry(keyPrefix: alice.prefix(6), permissions: 0x02),
      ACLEntry(keyPrefix: me.prefix(6), permissions: 0x03)
    ]
    let items = AccessListResolver.items(
      from: entries,
      candidates: [AccessListCandidate(publicKey: alice, name: "Alice", isChatContact: true)],
      selfPublicKey: me
    )

    #expect(items.map(\.role) == [.admin, .admin, .readWrite])
    // Among admins, the self entry has no contact name, so the unknown prefix sorts by hex.
    let selfItem = items.first { $0.isSelf }
    #expect(selfItem?.fullPublicKey == me)
    #expect(selfItem?.canRemove == false)
    #expect(selfItem?.canChangeRole == false)

    let aliceItem = items.last
    #expect(aliceItem?.name == "Alice")
    #expect(aliceItem?.fullPublicKey == alice)
    #expect(aliceItem?.canChangeRole == true)

    let unknown = items.first { $0.keyPrefix == Data(repeating: 0x99, count: 6) }
    #expect(unknown?.name == nil)
    #expect(unknown?.canChangeRole == false)
    #expect(unknown?.canRemove == true)
  }

  @Test
  func `Named entries sort before unnamed ones within a role`() {
    let bob = Data([0x33] + Array(repeating: 0, count: 31))
    let items = AccessListResolver.items(
      from: [
        ACLEntry(keyPrefix: Data([0x01, 1, 1, 1, 1, 1]), permissions: 0x02),
        ACLEntry(keyPrefix: bob.prefix(6), permissions: 0x02)
      ],
      candidates: [AccessListCandidate(publicKey: bob, name: "Bob")],
      selfPublicKey: nil
    )
    #expect(items.first?.name == "Bob")
  }
}
