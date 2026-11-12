import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("PathManagementViewModel Discovery")
struct PathManagementViewModelDiscoveryTests {
  @Test
  @MainActor
  func `Response with hops presents a success result`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true

    vm.handleDiscoveryResponse(hopCount: 2)

    #expect(vm.discoveryResult == .success(hopCount: 2))
    #expect(vm.showDiscoveryResult == true)
    #expect(vm.isDiscovering == false)
  }

  @Test
  @MainActor
  func `Response without a decodable path presents no-path-found`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true

    vm.handleDiscoveryResponse(hopCount: nil)

    #expect(vm.discoveryResult == .noPathFound)
    #expect(vm.showDiscoveryResult == true)
    #expect(vm.isDiscovering == false)
  }

  @Test
  @MainActor
  func `Response signals contact refresh while discovering`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true
    var refreshed = false
    vm.onContactNeedsRefresh = { refreshed = true }

    vm.handleDiscoveryResponse(hopCount: 1)

    #expect(refreshed)
  }

  @Test
  @MainActor
  func `Late response after timeout is ignored and does not flip the failure`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    // Timeout already fired: the failure alert is on screen and discovery ended.
    vm.isDiscovering = false
    vm.discoveryResult = .noPathFound
    vm.showDiscoveryResult = true
    var refreshed = false
    vm.onContactNeedsRefresh = { refreshed = true }

    vm.handleDiscoveryResponse(hopCount: 3)

    #expect(vm.showDiscoveryResult == true)
    #expect(vm.discoveryResult == .noPathFound)
    #expect(vm.isDiscovering == false)
    #expect(!refreshed)
  }

  @Test
  @MainActor
  func `Late response after cancel is ignored`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true
    vm.cancelDiscovery()

    var refreshed = false
    vm.onContactNeedsRefresh = { refreshed = true }
    vm.handleDiscoveryResponse(hopCount: 3)

    #expect(vm.isDiscovering == false)
    #expect(vm.discoveryResult == nil)
    #expect(vm.showDiscoveryResult == false)
    #expect(!refreshed)
  }

  // MARK: - Path push during discovery

  @Test
  @MainActor
  func `Path push during discovery presents the stored route as success`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true

    // A reply to an earlier send reaches the app only as PATH_UPDATED; the radio now holds 3 hops.
    vm.handleDiscoveryPathUpdated(outPathLength: 0x03)

    #expect(vm.discoveryResult == .success(hopCount: 3))
    #expect(vm.showDiscoveryResult == true)
    #expect(vm.isDiscovering == false)
  }

  @Test
  @MainActor
  func `Path push decodes the hop count of a multibyte route`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true

    vm.handleDiscoveryPathUpdated(outPathLength: 0x42) // 2-byte hashes, 2 hops

    #expect(vm.discoveryResult == .success(hopCount: 2))
  }

  @Test
  @MainActor
  func `Path push leaving the route on flood keeps waiting`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true

    vm.handleDiscoveryPathUpdated(outPathLength: 0xFF)

    #expect(vm.isDiscovering == true)
    #expect(vm.discoveryResult == nil)
  }

  @Test
  @MainActor
  func `Path push after discovery ended is ignored`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = false
    vm.discoveryResult = .noPathFound

    vm.handleDiscoveryPathUpdated(outPathLength: 0x02)

    #expect(vm.discoveryResult == .noPathFound)
  }

  @Test
  @MainActor
  func `Discovery reply for another contact is ignored`() async {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true
    let contact = makeContact(publicKey: Data(repeating: 0xAA, count: 32))
    let reply = PathInfo(
      publicKeyPrefix: Data(repeating: 0xBB, count: 6),
      outPathLength: 0x01, outPath: Data([0x11]), inPathLength: 0x01, inPath: Data([0x11])
    )

    await vm.handleAdvertisementEvent(.pathDiscoveryResponse(reply), for: contact)

    #expect(vm.isDiscovering == true)
  }

  @Test
  @MainActor
  func `Discovery reply shows the route out and the way back`() {
    let vm = PathManagementViewModel(defaults: makeSuiteDefaults())
    vm.isDiscovering = true
    // Out through 11 → 22; the reply came back through 33 alone.
    let reply = PathInfo(
      publicKeyPrefix: Data(repeating: 0xAA, count: 6),
      outPathLength: 0x02, outPath: Data([0x11, 0x22]), inPathLength: 0x01, inPath: Data([0x33])
    )

    vm.handleDiscoveryResponse(reply)

    let back = PathDiscoveryResult.DiscoveredLeg(hopCount: 1, route: ["33"])
    #expect(vm.discoveryResult == .success(hopCount: 2, route: ["11", "22"], back: back))
    #expect(vm.discoveredReturnPath?.path == Data([0x33]))
    let text = vm.discoveryResult?.description ?? ""
    #expect(text.contains(L10n.Contacts.Contacts.PathDiscovery.outbound("")
      .trimmingCharacters(in: .whitespaces)))
    #expect(text.contains("11 \u{2192} 22"))
    #expect(text.contains(L10n.Contacts.Contacts.PathDiscovery.back("").trimmingCharacters(in: .whitespaces)))
  }

  // MARK: - Test helpers

  private func makeContact(publicKey: Data) -> ContactDTO {
    ContactDTO(from: Contact(
      id: UUID(), radioID: UUID(), publicKey: publicKey, name: "Node",
      typeRawValue: ContactType.chat.rawValue, flags: 0, outPathLength: 0xFF, outPath: Data(),
      lastAdvertTimestamp: 0, latitude: 0, longitude: 0, lastModified: 0, lastHeardTimestamp: 0
    ))
  }

  private func makeSuiteDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.\(UUID().uuidString)")!
  }
}
