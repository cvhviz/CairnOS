import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("Chat info display")
@MainActor
struct ChatInfoDisplayTests {
  // MARK: - Bubble route chip

  @Test
  func `route chip reads Direct, N hops, or nothing on a stored route`() {
    #expect(MessageRouteSummary.hopText(footer(hopCount: 0)) == L10n.Chats.Chats.Message.Hops.direct)
    #expect(MessageRouteSummary.hopText(footer(hopCount: 1)) == L10n.Chats.Chats.Repeats.Hop.singular)
    #expect(MessageRouteSummary.hopText(footer(hopCount: 3)) == L10n.Chats.Chats.Repeats.Hop.plural(3))
    #expect(MessageRouteSummary.hopText(footer(showHop: false, hopCount: 3)) == nil)
    #expect(MessageRouteSummary.hopText(footer(hopCount: 0, isDirectRoute: true)) == nil)
  }

  @Test
  func `route chip VoiceOver names the hops and the signal`() {
    let label = MessageRouteSummary.accessibilityLabel(footer(hopCount: 2, snr: 7.25))
    #expect(label.contains(L10n.Chats.Chats.Repeats.Hop.plural(2)))
    #expect(label.contains(L10n.Chats.Chats.Signal.excellent))
    let direct = MessageRouteSummary.accessibilityLabel(footer(showHop: false, hopCount: 0, snr: -2, isDirectRoute: true))
    #expect(direct.hasPrefix(L10n.Chats.Chats.Path.DirectRoute.title))
  }

  @Test
  func `footer flags an unheard channel message only while it is sent with no echo`() {
    #expect(footer(outgoing: true, channel: true, status: .sent).isAwaitingEcho)
    #expect(!footer(outgoing: true, channel: true, status: .sent, heardRepeats: 1).isAwaitingEcho)
    #expect(!footer(outgoing: true, channel: false, status: .sent).isAwaitingEcho)
    #expect(!footer(outgoing: true, channel: true, status: .failed).isAwaitingEcho)
  }

  @Test
  func `builder puts the first copy's SNR on incoming footers only when hops are shown`() {
    let incoming = makeMessage(snr: 5.5)
    let shown = MessageFragmentBuilder.makeItem(for: incoming, inputs: inputs(for: incoming), envInputs: .default)
    #expect(shown.footer.signalSNR == 5.5)
    #expect(shown.footer.showsRouteChip)

    let outgoing = makeMessage(direction: .outgoing, snr: 5.5)
    let mine = MessageFragmentBuilder.makeItem(for: outgoing, inputs: inputs(for: outgoing), envInputs: .default)
    #expect(mine.footer.signalSNR == nil)
  }

  @Test
  func `builder carries a parsed reply onto the text payload`() {
    let message = makeMessage(text: "@[Alice]\n>hello wor..\nhi")
    let quote = ReplyQuote.parse(message.text)
    let item = MessageFragmentBuilder.makeItem(
      for: message,
      inputs: inputs(for: message, replyQuote: quote),
      envInputs: .default
    )
    guard case let .text(payload) = item.content.first else {
      Issue.record("Expected a text fragment")
      return
    }
    #expect(payload.replyQuote?.mentionName == "Alice")
    #expect(payload.hasVisibleBody)
  }

  // MARK: - Details

  @Test
  func `heard-by tiles name unknown hops by hex and format signal and offsets`() {
    #expect(HeardByFormatting.displayName(
      resolution: NodeNameResolution(displayName: "<unknown>", matchKind: .unresolved), hex: "A3"
    ) == "A3")
    #expect(HeardByFormatting.displayName(
      resolution: NodeNameResolution(displayName: "Hilltop", matchKind: .exact), hex: "A3"
    ) == "Hilltop")
    #expect(HeardByFormatting.signal(snr: nil, rssi: nil) == nil)
    #expect(HeardByFormatting.signal(snr: 8.5, rssi: -95)?.contains("-95 dBm") == true)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(HeardByFormatting.offset(from: start, to: start.addingTimeInterval(-2)).contains("0"))
  }

  @Test
  func `clock tile captions say transit or which way the sender's clock is off`() {
    #expect(MessageClockText(reading: .inTransit(3)).caption == L10n.Chats.Chats.Message.Info.Clock.inTransit)
    #expect(MessageClockText(reading: .senderAhead(400)).caption == L10n.Chats.Chats.Message.Info.Clock.senderAhead)
    #expect(MessageClockText(reading: .senderBehind(400)).caption == L10n.Chats.Chats.Message.Info.Clock.senderBehind)
  }

  @Test
  func `the first copy carries the RX log's RSSI`() {
    let message = makeMessage()
    let arrivals = MessagePathArrivals.assemble(message: message, repeats: [], canonicalRSSI: -101)
    #expect(arrivals.first?.rssi == -101)
  }

  // MARK: - Sender lookup

  @Test
  func `a heard-but-not-saved node with the name opens its own page`() {
    let radio = UUID()
    let node = makeNode(name: "carol", radioID: radio)
    let outcome = MentionTapEvaluator.evaluate(
      rawName: "Carol",
      contacts: [],
      discoveredNodes: [node],
      connectedDeviceName: "Me",
      radioID: radio
    )
    if case let .navigateDiscovered(found) = outcome {
      #expect(found.id == node.id)
    } else {
      Issue.record("Expected .navigateDiscovered, got \(outcome)")
    }
  }

  @Test
  func `a contact and a different heard node with one name offer a chooser`() {
    let radio = UUID()
    let outcome = MentionTapEvaluator.evaluate(
      rawName: "Carol",
      contacts: [makeContact(name: "Carol", key: 1)],
      discoveredNodes: [makeNode(name: "Carol", radioID: radio, key: 2)],
      connectedDeviceName: "Me",
      radioID: radio
    )
    if case let .picker(context) = outcome {
      #expect(context.matches.count == 1)
      #expect(context.discoveredMatches.count == 1)
      #expect(!context.isUnknownSender)
    } else {
      Issue.record("Expected .picker, got \(outcome)")
    }
  }

  @Test
  func `a heard node already saved shows once, as the contact`() {
    let matches = SenderNodeMatcher.matches(
      name: "carol",
      contacts: [makeContact(name: "Carol", key: 7)],
      discoveredNodes: [makeNode(name: "Carol", radioID: UUID(), key: 7)]
    )
    #expect(matches.contacts.count == 1)
    #expect(matches.discovered.isEmpty)
  }

  @Test
  func `heard nodes sort companions first, then most recently heard`() {
    let old = makeNode(name: "Dan", radioID: UUID(), key: 1, lastHeard: Date(timeIntervalSince1970: 100))
    let recent = makeNode(name: "Dan", radioID: UUID(), key: 2, lastHeard: Date(timeIntervalSince1970: 200))
    let repeater = makeNode(name: "Dan", radioID: UUID(), key: 3, type: .repeater, lastHeard: Date(timeIntervalSince1970: 300))
    let matches = SenderNodeMatcher.matches(name: "dan", contacts: [], discoveredNodes: [repeater, old, recent])
    #expect(matches.discovered.map(\.id) == [recent.id, old.id, repeater.id])
  }

  @Test
  func `nothing heard by the name is an unknown sender`() {
    let outcome = MentionTapEvaluator.evaluate(
      rawName: "Ghost",
      contacts: [],
      discoveredNodes: [],
      connectedDeviceName: "Me",
      radioID: UUID()
    )
    if case let .picker(context) = outcome {
      #expect(context.isUnknownSender)
    } else {
      Issue.record("Expected .picker, got \(outcome)")
    }
  }

  @Test
  func `sender activity counts their messages and describes the latest`() {
    let older = makeMessage(text: "a", senderName: "ghost", createdAt: Date(timeIntervalSince1970: 100), pathLength: 1, pathNodes: Data([0xA3]))
    let latest = makeMessage(text: "b", senderName: "Ghost", createdAt: Date(timeIntervalSince1970: 200), snr: -3.5, pathLength: 2, pathNodes: Data([0xA3, 0x7F]))
    let other = makeMessage(text: "c", senderName: "Someone", createdAt: Date(timeIntervalSince1970: 300))
    let activity = SenderChatActivity.make(name: "GHOST", messages: [older, latest, other])
    #expect(activity?.messageCount == 2)
    #expect(activity?.lastHopCount == 2)
    #expect(activity?.lastSNR == -3.5)
    #expect(activity?.lastPathHex == ["A3", "7F"])
    #expect(activity.map(SenderActivityText.route) == L10n.Chats.Chats.Repeats.Hop.plural(2))
    #expect(SenderChatActivity.make(name: "Nobody", messages: [older]) == nil)
  }

  // MARK: - Fixtures

  private func footer(
    showHop: Bool = true,
    hopCount: Int = 0,
    snr: Double? = nil,
    isDirectRoute: Bool = false,
    outgoing: Bool = false,
    channel: Bool = true,
    status: MessageStatus = .delivered,
    heardRepeats: Int = 0
  ) -> MessageFooter {
    MessageFooter(
      showHop: showHop,
      hopCount: hopCount,
      formattedPath: nil,
      regionToShow: nil,
      sendTimeToShow: Date(),
      sendTimeWasCorrected: false,
      showStatusRow: outgoing,
      status: status,
      isChannelMessage: channel,
      heardRepeats: heardRepeats,
      retryAttempt: 0,
      maxRetryAttempts: 0,
      sendCount: 1,
      signalSNR: snr,
      isDirectRoute: isDirectRoute
    )
  }

  private func inputs(for message: MessageDTO, replyQuote: ReplyQuote? = nil) -> MessageBuildInputs {
    MessageBuildInputs(
      messageID: message.id,
      previewState: .idle,
      loadedPreview: nil,
      cachedURL: nil,
      isInlineImageURL: false,
      hasInlineImageRef: false,
      hasPreviewImageRef: false,
      hasPreviewIconRef: false,
      imageIsGIF: false,
      formattedText: AttributedString(replyQuote?.body ?? message.text),
      baseColor: message.isOutgoing ? .outgoing : .incoming,
      formattedPath: nil,
      senderResolution: NodeNameResolution(displayName: "x", matchKind: .exact),
      showTimestamp: false,
      showDirectionGap: false,
      showSenderName: false,
      showNewMessagesDivider: false,
      replyQuote: replyQuote,
      replyHeaderText: replyQuote.map { AttributedString("@" + $0.mentionName) }
    )
  }

  private func makeMessage(
    text: String = "Test",
    direction: MessageDirection = .incoming,
    senderName: String? = "Ghost",
    createdAt: Date = Date(),
    snr: Double? = nil,
    pathLength: UInt8 = 0x01,
    pathNodes: Data? = Data([0xA3])
  ) -> MessageDTO {
    MessageDTO(
      id: UUID(),
      radioID: UUID(),
      contactID: nil,
      channelIndex: 0,
      text: text,
      timestamp: UInt32(createdAt.timeIntervalSince1970),
      createdAt: createdAt,
      direction: direction,
      status: .delivered,
      textType: .plain,
      ackCode: nil,
      pathLength: pathLength,
      snr: snr,
      pathNodes: pathNodes,
      senderKeyPrefix: nil,
      senderNodeName: senderName,
      isRead: true,
      replyToID: nil,
      roundTripTime: nil,
      heardRepeats: 0,
      retryAttempt: 0,
      maxRetryAttempts: 0
    )
  }

  private func makeContact(name: String, key: UInt8) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: key, count: 32),
      name: name,
      typeRawValue: ContactType.chat.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0
    )
  }

  private func makeNode(
    name: String,
    radioID: UUID,
    key: UInt8 = 9,
    type: ContactType = .chat,
    lastHeard: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> DiscoveredNodeDTO {
    DiscoveredNodeDTO(
      id: UUID(),
      radioID: radioID,
      publicKey: Data(repeating: key, count: 32),
      name: name,
      typeRawValue: type.rawValue,
      lastHeard: lastHeard,
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      outPathLength: 0,
      outPath: Data(),
      inboundHopCount: nil,
      inboundHopAdvertTimestamp: nil
    )
  }
}
