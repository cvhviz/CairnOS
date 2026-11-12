import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

@Suite("SyncProgressTracker")
@MainActor
struct SyncProgressTrackerTests {
  private func contact(_ byte: UInt8) -> MeshContact {
    let key = Data(repeating: byte, count: 32)
    return MeshContact(
      id: key.hexString,
      publicKey: key,
      type: .chat,
      flags: ContactFlags(rawValue: 0),
      outPathLength: 0,
      outPath: Data(),
      advertisedName: "Node",
      lastAdvertisement: Date(),
      latitude: 0,
      longitude: 0,
      lastModified: Date()
    )
  }

  @Test
  func `counts contacts against the reported total`() {
    let tracker = SyncProgressTracker()
    tracker.phaseChanged(.contacts)
    #expect(tracker.detailText(maxChannels: 8) == nil)
    tracker.handle(.contactsStart(count: 150))
    tracker.handle(.contact(contact(1)))
    tracker.handle(.contact(contact(2)))
    #expect(tracker.detailText(maxChannels: 8) == "Contacts 2/150")
  }

  @Test
  func `counts channel slots against the device total`() {
    let tracker = SyncProgressTracker()
    tracker.phaseChanged(.contacts)
    tracker.handle(.contactsStart(count: 3))
    tracker.phaseChanged(.channels)
    let secret = Data(repeating: 0, count: 16)
    for index in 0..<3 {
      tracker.handle(.channelInfo(ChannelInfo(index: UInt8(index), name: "C\(index)", secret: secret)))
    }
    #expect(tracker.detailText(maxChannels: 40) == "Channels 3/40")
    #expect(tracker.detailText(maxChannels: nil) == "Channels 3")
  }

  @Test
  func `ignores events outside their phase`() {
    let tracker = SyncProgressTracker()
    tracker.handle(.contact(contact(1)))
    #expect(tracker.received == 0)
    tracker.phaseChanged(.channels)
    tracker.handle(.contact(contact(1)))
    #expect(tracker.received == 0)
  }

  @Test
  func `clamps a count that overruns the total`() {
    let tracker = SyncProgressTracker()
    tracker.phaseChanged(.contacts)
    tracker.handle(.contactsStart(count: 1))
    tracker.handle(.contact(contact(1)))
    tracker.handle(.contact(contact(2)))
    #expect(tracker.detailText(maxChannels: nil) == "Contacts 1/1")
  }

  @Test
  func `reset and idle hide the detail`() {
    let tracker = SyncProgressTracker()
    tracker.phaseChanged(.contacts)
    tracker.handle(.contactsStart(count: 5))
    tracker.phaseChanged(nil)
    #expect(tracker.detailText(maxChannels: 8) == nil)
    tracker.phaseChanged(.contacts)
    tracker.handle(.contactsStart(count: 5))
    tracker.reset()
    #expect(tracker.detailText(maxChannels: 8) == nil)
  }

  @Test
  func `incremental contact fetch shows only the update count`() {
    let tracker = SyncProgressTracker()
    tracker.phaseChanged(.contacts)
    tracker.contactFetchModeChanged(isFullFetch: false)
    tracker.handle(.contactsStart(count: 150))
    #expect(tracker.detailText(maxChannels: 8) == nil)
    tracker.handle(.contact(contact(1)))
    #expect(tracker.detailText(maxChannels: 8) == "Contact updates 1")
  }
}
