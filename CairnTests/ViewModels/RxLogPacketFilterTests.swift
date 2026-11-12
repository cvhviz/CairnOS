import Foundation
@testable import Cairn
import CairnServices
import MeshCore
import Testing

/// The packet list's type and sender filters and its search, and the list held still while
/// scrolled away from its top.
@Suite("RX log packet filters")
@MainActor
struct RxLogPacketFilterTests {
  typealias World = TrafficClaremontFixtures

  private func model() -> RxLogViewModel {
    RxLogViewModel(sentLog: TrafficSentLog(), observations: World.observationDirectory())
  }

  /// A direct message from Alex (5A…, heard on this channel) to this radio.
  private func message(text: String? = nil, at seconds: TimeInterval = 0) -> RxLogEntryDTO {
    let frame = World.frame(.textMessage, route: .direct, pathLength: 0, path: [], payload: World.peerPayload(destination: 0xAA, source: 0x5A))
    return World.entry(frame, firmware: .stock, receivedAt: World.receivedAt.addingTimeInterval(seconds), decryptStatus: text == nil ? .dmNoMatchingKey : .success, decodedText: text)
  }

  private func packet(_ type: PayloadType, at seconds: TimeInterval = 0) -> RxLogEntryDTO {
    let frame = World.frame(type, route: .flood, pathLength: 0, path: [], payload: [UInt8](repeating: 0x42, count: 12))
    return World.entry(frame, firmware: .stock, receivedAt: World.receivedAt.addingTimeInterval(seconds))
  }

  @Test
  func `every payload type falls under one type filter`() {
    for type in PayloadType.allCases {
      let filter = RxLogViewModel.TypeFilter.matching(type)
      #expect(filter != .all)
      #expect(filter.includes(type))
      #expect(RxLogViewModel.TypeFilter.all.includes(type))
    }
    #expect(RxLogViewModel.TypeFilter.matching(.textMessage) == .messages)
    #expect(RxLogViewModel.TypeFilter.matching(.groupText) == .messages)
    #expect(RxLogViewModel.TypeFilter.matching(.advert) == .adverts)
    #expect(RxLogViewModel.TypeFilter.matching(.trace) == .traces)
    #expect(RxLogViewModel.TypeFilter.matching(.ack) == .acks)
    #expect(RxLogViewModel.TypeFilter.matching(.path) == .paths)
    #expect(RxLogViewModel.TypeFilter.matching(.anonRequest) == .requests)
    #expect(RxLogViewModel.TypeFilter.matching(.multipart) == .other)
  }

  @Test
  func `the type filter keeps only its kind, live and on a rebuild`() {
    let model = model()
    model.load([packet(.advert), message(text: "hello"), packet(.trace, at: 2)])
    #expect(model.filteredEntries.count == 3)

    model.setTypeFilter(.messages)
    #expect(model.filteredEntries.map(\.payloadType) == [.textMessage])
    #expect(model.mapEntries.count == 3, "the map follows the route filter alone")
    #expect(model.activeFilterCount == 1)

    model.appendEntry(packet(.ack, at: 3))
    model.appendEntry(message(text: "again", at: 4))
    #expect(model.filteredEntries.map(\.decodedText) == ["hello", "again"])

    model.setTypeFilter(.all)
    #expect(model.filteredEntries.count == 5)
    #expect(model.activeFilterCount == 0)
  }

  @Test
  func `the search finds a sender's name, a message's text and a hash`() {
    let model = model()
    let hello = message(text: "Meet at the ridge", at: 1)
    model.load([packet(.advert), hello, packet(.trace, at: 2)])

    model.searchText = "ridge"
    #expect(model.filteredEntries.map(\.id) == [hello.id])

    model.searchText = "alex"
    #expect(model.filteredEntries.map(\.id) == [hello.id], "the sender is named from what this radio observed")

    model.searchText = String(hello.packetHash.prefix(8))
    #expect(model.filteredEntries.map(\.id) == [hello.id])

    model.searchText = "TRACE"
    #expect(model.filteredEntries.map(\.payloadType) == [.trace], "a type's name is searchable too")

    model.searchText = "  "
    #expect(model.filteredEntries.count == 3, "blank searches nothing")
    #expect(model.activeFilterCount == 0, "the search isn't counted as a filter")
  }

  @Test
  func `the sender filter lists the nodes packets came from and keeps theirs`() throws {
    let model = model()
    model.load([message(text: "one"), message(text: "two", at: 1), packet(.advert, at: 2)])
    let senders = model.senderOptions
    let alex = try #require(senders.first { $0.name == "Alex" })
    #expect(alex.count == 2)

    model.setSenderFilter(alex.key)
    #expect(model.filteredEntries.map(\.decodedText) == ["one", "two"])
    #expect(model.activeFilterCount == 1)

    model.setSenderFilter(nil)
    #expect(model.filteredEntries.count == 3)
  }

  // MARK: - Held list

  private struct Row: Identifiable, Equatable {
    let id: Int
  }

  @Test
  func `a held list stays as it was and counts what landed since`() {
    var freeze = PacketListFreeze<Row>()
    let live = [Row(id: 3), Row(id: 2), Row(id: 1)]
    #expect(freeze.entries(live: live) == live)
    #expect(freeze.newCount(live: live) == 0)

    freeze.freeze(live)
    #expect(freeze.isFrozen)
    let later = [Row(id: 5), Row(id: 4)] + live
    #expect(freeze.entries(live: later) == live, "rows don't move under the finger")
    #expect(freeze.newCount(live: later) == 2)

    freeze.freeze(later)
    #expect(freeze.entries(live: later) == live, "freezing again keeps the list already held")

    // The oldest row pruned from the live list changes nothing about what's new
    let pruned = Array(later.dropLast())
    #expect(freeze.newCount(live: pruned) == 2)

    freeze.release()
    #expect(!freeze.isFrozen)
    #expect(freeze.entries(live: later) == later)
    #expect(freeze.newCount(live: later) == 0)
  }
}
