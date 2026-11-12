import CairnServices
import SwiftUI

/// Long-press info and actions sheet for a room server message. Mirrors the
/// chat `MessageActionsSheet` layout but carries no reactions and only the
/// metadata a server-pushed room message actually has.
struct RoomMessageActionsSheet: View {
  let message: RoomMessageDTO
  /// Who wrote it, resolved from the key prefix ("You" for the user's own).
  let author: RoomAuthorIdentity
  let availability: RoomMessageActionAvailability
  let onAction: (RoomMessageAction) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @AppStorage(AppStorageKey.replyWithQuote.rawValue) private var replyWithQuote = AppStorageKey.defaultReplyWithQuote

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(spacing: 0) {
          MessageActionGrid(items: actionItems)
            .padding(.top, 12)
          details
            .padding(.bottom, 16)
        }
      }
    }
    .presentationDetents(
      (horizontalSizeClass == .regular || dynamicTypeSize.isAccessibilitySize)
        ? [.large] : [.medium, .large]
    )
    .presentationContentInteraction(.scrolls)
    .presentationDragIndicator(.visible)
    .presentationBackground(Color(.systemBackground))
  }

  private func performAction(_ action: RoomMessageAction) {
    onAction(action)
    dismiss()
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if author.isKeyOnly {
          Text(author.keyPrefixHex)
            .font(.subheadline.monospaced())
            .foregroundStyle(.secondary)
            .accessibilityLabel(RoomMessageBubble.accessibleAuthorName(author))
        } else {
          Text(author.displayName)
            .font(.subheadline)
            .bold()
        }
        Spacer()
        Text(message.postDate, format: .dateTime.hour().minute())
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Text(message.text)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 3)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  /// The actions as tiles, as the chat message sheet has them.
  private var actionItems: [MessageActionItem] {
    let strings = L10n.Chats.Chats.Message.Action.self
    var items: [MessageActionItem] = []
    func add(_ id: String, _ title: String, _ icon: String, _ action: RoomMessageAction) {
      items.append(MessageActionItem(id: id, title: title, icon: icon) { performAction(action) })
    }
    if availability.canReply {
      add("reply", replyWithQuote ? strings.reply : strings.mention, "arrowshape.turn.up.left", .reply)
    }
    if availability.canSendDM { add("sendDM", strings.sendDM, "bubble.left.and.bubble.right", .sendDM) }
    add("copy", strings.copy, "doc.on.doc", .copy)
    add("translate", strings.translate, "translate", .translate)
    if availability.canSendAgain { add("sendAgain", strings.sendAgain, "arrow.uturn.forward", .sendAgain) }
    return items
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(L10n.Chats.Chats.Message.Action.details)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)

      MetricTileGrid {
        MessageTimeTile(
          title: L10n.Chats.Chats.Message.Info.Title.sent,
          systemImage: "paperplane",
          date: message.postDate
        )
        if !message.isFromSelf {
          MessageTimeTile(
            title: L10n.Chats.Chats.Message.Info.Title.received,
            systemImage: "tray.and.arrow.down",
            date: message.createdAt
          )
        }
        MetricTile(
          L10n.RemoteNodes.RemoteNodes.Room.status,
          systemImage: statusSymbol,
          value: message.localizedStatusText,
          valueTint: message.status == .failed ? .red : nil
        )
        if message.isFromSelf, let roundTripTime = message.roundTripTime {
          MetricTile(
            L10n.Chats.Chats.Message.Info.Title.roundTrip,
            systemImage: "arrow.triangle.2.circlepath",
            value: Measurement(value: Double(roundTripTime), unit: UnitDuration.milliseconds)
              .formatted(.measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0))
              ))
          )
        }
      }
      .padding(.horizontal)
      .padding(.bottom, 8)
      // Same as the message details sheet: the plain sheet background matches the default card.
      .cardFill(Color(.secondarySystemBackground))
    }
  }

  /// A different glyph per state, so the state does not rest on the value's color.
  private var statusSymbol: String {
    switch message.status {
    case .pending, .sending, .retrying: "clock"
    case .sent: "checkmark"
    case .delivered: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
  }
}

#Preview("Incoming") {
  let message = RoomMessageDTO(
    sessionID: UUID(),
    authorKeyPrefix: Data(repeating: 0x55, count: 4),
    authorName: "Alice",
    text: "Anyone near the north trailhead? Roads are washed out past the bridge.",
    timestamp: UInt32(Date().timeIntervalSince1970)
  )
  let session = RemoteNodeSessionDTO(
    radioID: UUID(),
    publicKey: Data(repeating: 0x42, count: 32),
    name: "Test Room",
    role: .roomServer,
    isConnected: true,
    permissionLevel: .readWrite
  )
  let author = RoomAuthorResolver.empty.resolve(message, roomPublicKey: session.publicKey, roomName: session.name, selfName: "You")
  return Color.clear.sheet(isPresented: .constant(true)) {
    RoomMessageActionsSheet(
      message: message,
      author: author,
      availability: RoomMessageActionAvailability(message: message, session: session, author: author),
      onAction: { _ in }
    )
  }
}

#Preview("Outgoing") {
  let message = RoomMessageDTO(
    sessionID: UUID(),
    authorKeyPrefix: Data(repeating: 0x42, count: 4),
    text: "Copy that, heading your way.",
    timestamp: UInt32(Date().timeIntervalSince1970),
    isFromSelf: true,
    status: .delivered,
    roundTripTime: 842
  )
  let session = RemoteNodeSessionDTO(
    radioID: UUID(),
    publicKey: Data(repeating: 0x42, count: 32),
    name: "Test Room",
    role: .roomServer,
    isConnected: true,
    permissionLevel: .readWrite
  )
  let author = RoomAuthorResolver.empty.resolve(message, roomPublicKey: session.publicKey, roomName: session.name, selfName: "You")
  return Color.clear.sheet(isPresented: .constant(true)) {
    RoomMessageActionsSheet(
      message: message,
      author: author,
      availability: RoomMessageActionAvailability(message: message, session: session, author: author),
      onAction: { _ in }
    )
  }
}
