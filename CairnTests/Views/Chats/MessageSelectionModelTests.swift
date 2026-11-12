import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("MessageSelectionModel")
@MainActor
struct MessageSelectionModelTests {
  private func message(_ text: String, at timestamp: UInt32) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: UUID(),
      channelIndex: nil,
      text: text,
      timestamp: timestamp,
      createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp)),
      direction: .incoming,
      status: .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: 0,
      snr: nil,
      senderKeyPrefix: nil,
      senderNodeName: nil,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0
    )
  }

  @Test
  func `beginning selection selects the long-pressed message`() {
    let model = MessageSelectionModel()
    let id = UUID()
    model.begin(with: id)
    #expect(model.isSelecting)
    #expect(model.isSelected(id))
    #expect(model.count == 1)
  }

  @Test
  func `toggle adds then removes, and is ignored outside selection mode`() {
    let model = MessageSelectionModel()
    let first = UUID()
    let second = UUID()

    model.toggle(first)
    #expect(model.count == 0)

    model.begin(with: first)
    model.toggle(second)
    #expect(model.count == 2)
    model.toggle(first)
    #expect(!model.isSelected(first))
    #expect(model.isSelected(second))
  }

  @Test
  func `ending selection clears everything`() {
    let model = MessageSelectionModel()
    model.begin(with: UUID())
    model.end()
    #expect(!model.isSelecting)
    #expect(model.count == 0)
  }

  @Test
  func `pruning drops ids whose messages are gone`() {
    let model = MessageSelectionModel()
    let kept = UUID()
    let gone = UUID()
    model.begin(with: kept)
    model.toggle(gone)

    model.prune(keeping: [kept])

    #expect(model.isSelected(kept))
    #expect(!model.isSelected(gone))
  }

  @Test
  func `selected messages and copy text follow timeline order, not tap order`() {
    let model = MessageSelectionModel()
    let timeline = [message("first", at: 1), message("second", at: 2), message("third", at: 3)]
    model.begin(with: timeline[2].id)
    model.toggle(timeline[0].id)

    let selected = model.selectedMessages(in: timeline)
    #expect(selected.map(\.text) == ["first", "third"])
    #expect(MessageSelectionModel.copyText(for: selected, displayedText: \.text) == "first\nthird")
  }
}
