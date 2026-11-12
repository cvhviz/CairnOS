import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("NodeNameResolver")
struct NodeNameResolverTests {
  private let key = Data(repeating: 0x42, count: 32)

  /// Which dependencies a resolve call reached, in order.
  private actor Calls {
    private(set) var log: [String] = []
    func record(_ call: String) { log.append(call) }
  }

  private func radioContact(name: String, typeRawValue: UInt8 = 2) -> MeshContact {
    MeshContact(
      id: key.hexString,
      publicKey: key,
      type: ContactType(rawValue: typeRawValue) ?? .chat,
      typeRawValue: typeRawValue,
      flags: [],
      outPathLength: 0,
      outPath: Data(),
      advertisedName: name,
      lastAdvertisement: Date(timeIntervalSince1970: 0),
      latitude: 37.75,
      longitude: -122.45,
      lastModified: Date(timeIntervalSince1970: 0)
    )
  }

  /// - Parameters:
  ///   - addsPlaceholder: `nil` for a 1.16+ radio, which makes its own placeholder; otherwise
  ///     what the app's placeholder add reports (`false` when the radio turned out to hold the key).
  ///   - requestWaitsForCancel: The name request waits until its task is cancelled, then fails.
  private func resolver(
    calls: Calls,
    radioContact: MeshContact? = nil,
    radioLookupFails: Bool = false,
    addsPlaceholder: Bool? = nil,
    nodeName: String? = "Twin Peaks",
    requestWaitsForCancel: Bool = false
  ) -> NodeNameResolver {
    NodeNameResolver(dependencies: .init(
      radioContact: { _ in
        await calls.record("radioContact")
        if radioLookupFails { throw MeshCoreError.timeout }
        return radioContact
      },
      requestName: { _ in
        await calls.record("requestName")
        if requestWaitsForCancel {
          try await Task.sleep(for: .seconds(60))
        }
        guard let nodeName else { throw MeshCoreError.timeout }
        return NodeOwnerInfo(nodeName: nodeName, ownerInfo: "owner")
      },
      addTemporaryContact: addsPlaceholder.map { added -> @Sendable (Data) async throws -> Bool in
        { @Sendable _ in
          await calls.record("addTemporaryContact")
          return added
        }
      },
      removeTemporaryContact: { _ in
        await calls.record(Task.isCancelled ? "removeTemporaryContact (cancelled)" : "removeTemporaryContact")
      }
    ))
  }

  @Test
  func `a contact the radio holds names the node without going on air`() async {
    let calls = Calls()
    let resolved = await resolver(calls: calls, radioContact: radioContact(name: "North Ridge"))
      .resolve(publicKey: key, overTheAir: true)

    #expect(resolved == ResolvedNodeName(
      publicKey: key,
      name: "North Ridge",
      source: .radioContact,
      typeRawValue: 2,
      latitude: 37.75,
      longitude: -122.45
    ))
    #expect(await calls.log == ["radioContact"])
  }

  @Test
  func `nothing is sent over the air unless allowed`() async {
    let calls = Calls()
    let resolved = await resolver(calls: calls).resolve(publicKey: key, overTheAir: false)

    #expect(resolved == nil)
    #expect(await calls.log == ["radioContact"])
  }

  @Test
  func `a placeholder the radio made itself is left for the radio to recycle`() async {
    let calls = Calls()
    let resolved = await resolver(calls: calls).resolve(publicKey: key, overTheAir: true)

    #expect(resolved == ResolvedNodeName(publicKey: key, name: "Twin Peaks", source: .node))
    #expect(await calls.log == ["radioContact", "requestName"])
  }

  @Test
  func `on an older radio the added placeholder is removed after the answer`() async {
    let calls = Calls()
    let resolved = await resolver(calls: calls, addsPlaceholder: true).resolve(publicKey: key, overTheAir: true)

    #expect(resolved == ResolvedNodeName(publicKey: key, name: "Twin Peaks", source: .node))
    #expect(await calls.log == ["radioContact", "addTemporaryContact", "requestName", "removeTemporaryContact"])
  }

  @Test
  func `a silent node still has the added placeholder removed`() async {
    let calls = Calls()
    let resolved = await resolver(calls: calls, addsPlaceholder: true, nodeName: nil)
      .resolve(publicKey: key, overTheAir: true)

    #expect(resolved == nil)
    #expect(await calls.log == ["radioContact", "addTemporaryContact", "requestName", "removeTemporaryContact"])
  }

  @Test
  func `a placeholder the add found already present is not removed`() async {
    let calls = Calls()
    let resolved = await resolver(calls: calls, addsPlaceholder: false).resolve(publicKey: key, overTheAir: true)

    #expect(resolved?.name == "Twin Peaks")
    #expect(await calls.log == ["radioContact", "addTemporaryContact", "requestName"])
  }

  @Test
  func `a nameless radio entry does not count as a name`() async {
    let calls = Calls()
    let placeholder = radioContact(name: "", typeRawValue: 0)
    let resolved = await resolver(calls: calls, radioContact: placeholder)
      .resolve(publicKey: key, overTheAir: true)

    #expect(resolved?.source == .node)
    #expect(resolved?.name == "Twin Peaks")
  }

  @Test
  func `a nameless entry on an older radio is asked through without adding or removing`() async {
    let calls = Calls()
    let entry = radioContact(name: "", typeRawValue: 2)
    let resolved = await resolver(calls: calls, radioContact: entry, addsPlaceholder: true)
      .resolve(publicKey: key, overTheAir: true)

    #expect(resolved?.name == "Twin Peaks")
    #expect(await calls.log == ["radioContact", "requestName"])
  }

  @Test
  func `a failed radio lookup falls through to asking the node`() async {
    let calls = Calls()
    let resolved = await resolver(calls: calls, radioLookupFails: true)
      .resolve(publicKey: key, overTheAir: true)

    #expect(resolved?.source == .node)
    #expect(await calls.log == ["radioContact", "requestName"])
  }

  @Test
  func `a failed radio lookup on an older radio adds no placeholder that could overwrite a contact`() async {
    let calls = Calls()
    let resolved = await resolver(calls: calls, radioLookupFails: true, addsPlaceholder: true)
      .resolve(publicKey: key, overTheAir: true)

    #expect(resolved == nil)
    #expect(await calls.log == ["radioContact"])
  }

  @Test
  func `a cancelled request still removes the added placeholder`() async {
    let calls = Calls()
    let sut = resolver(calls: calls, addsPlaceholder: true, requestWaitsForCancel: true)
    let task = Task { await sut.resolve(publicKey: key, overTheAir: true) }
    while await !calls.log.contains("requestName") {
      await Task.yield()
    }
    task.cancel()

    #expect(await task.value == nil)
    #expect(await calls.log == ["radioContact", "addTemporaryContact", "requestName", "removeTemporaryContact"])
  }
}
