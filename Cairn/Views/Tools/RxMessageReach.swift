import CairnServices
import SwiftUI

/// Who a heard message was for, as far as this phone can tell: a channel you have (by name), a
/// channel you don't, a direct message to you, one to you that can't be read (its sender isn't in
/// your contacts), or one between two other nodes. Worked out from the RX log's decryption and
/// the packet's one-byte destination and source IDs.
enum RxMessageReach: Equatable {
  case channel(name: String)
  case channelNotJoined(hash: UInt8?)
  case toYou
  case toYouUnreadable
  case fromYou
  case betweenOthers

  init?(entry: RxLogEntryDTO, selfKey: Data?) {
    let payload = entry.packetPayload
    switch entry.payloadType {
    case .groupText, .groupData:
      if entry.decryptStatus == .success {
        self = .channel(name: entry.channelName ?? L10n.Tools.Tools.RxLog.Reach.unnamedChannel(Int(entry.channelIndex ?? 0)))
      } else {
        self = .channelNotJoined(hash: payload.first)
      }
    case .textMessage:
      let mine = selfKey?.first
      let destination = payload.first
      let source = payload.count > 1 ? payload[payload.startIndex + 1] : nil
      if entry.decryptStatus == .success {
        self = .toYou
      } else if let mine, source == mine {
        self = .fromYou
      } else if let mine, destination == mine {
        self = .toYouUnreadable
      } else {
        self = .betweenOthers
      }
    default:
      return nil
    }
  }

  /// Whether this packet's message should be in a chat (and so is worth looking for there).
  var expectsChatMessage: Bool {
    switch self {
    case .channel, .toYou: true
    case .channelNotJoined, .toYouUnreadable, .fromYou, .betweenOthers: false
    }
  }

  var title: String {
    let strings = L10n.Tools.Tools.RxLog.Reach.self
    return switch self {
    case let .channel(name): name
    case .channelNotJoined: strings.channelNotJoined
    case .toYou: strings.toYou
    case .toYouUnreadable: strings.toYouUnreadable
    case .fromYou: strings.fromYou
    case .betweenOthers: strings.betweenOthers
    }
  }

  var detail: String {
    let strings = L10n.Tools.Tools.RxLog.Reach.self
    return switch self {
    case .channel: strings.channelDetail
    case let .channelNotJoined(hash): hash.map { strings.channelNotJoinedDetail(String(format: "%02X", $0)) }
      ?? strings.channelNotJoinedDetailNoHash
    case .toYou: strings.toYouDetail
    case .toYouUnreadable: strings.toYouUnreadableDetail
    case .fromYou: strings.fromYouDetail
    case .betweenOthers: strings.betweenOthersDetail
    }
  }

  var systemImage: String {
    switch self {
    case .channel: "number"
    case .channelNotJoined: "lock"
    case .toYou: "person.crop.circle.badge.checkmark"
    case .toYouUnreadable: "exclamationmark.triangle.fill"
    case .fromYou: "paperplane"
    case .betweenOthers: "person.2"
    }
  }

  var tint: Color {
    switch self {
    case .channel, .toYou: .green
    case .toYouUnreadable: .orange
    case .channelNotJoined, .fromYou, .betweenOthers: .secondary
    }
  }
}

/// The packet sheet's card for a message: who it was for, and for one the app could read, whether
/// it is in your chats (a warning when it isn't: a message this radio heard and read but lost).
struct RxMessageReachCard: View {
  let entry: RxLogEntryDTO

  @Environment(\.appState) private var appState
  /// nil while looking, or when there is nothing to look for.
  @State private var inChats: Bool?

  private var reach: RxMessageReach? {
    RxMessageReach(entry: entry, selfKey: appState.connectedDevice?.publicKey)
  }

  var body: some View {
    if let reach {
      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.Tools.Tools.RxLog.Reach.header)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
          .accessibilityAddTraits(.isHeader)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: reach.systemImage)
            .foregroundStyle(reach.tint)
          VStack(alignment: .leading, spacing: 2) {
            Text(reach.title)
              .font(.subheadline.weight(.semibold))
            Text(reach.detail)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
        if reach.expectsChatMessage, entry.payloadType != .groupData {
          deliveryLine
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface()
      .task(id: entry.id) { await lookUp(reach) }
    }
  }

  @ViewBuilder
  private var deliveryLine: some View {
    let strings = L10n.Tools.Tools.RxLog.Reach.self
    Divider()
    switch inChats {
    case true?:
      Label(strings.inChats, systemImage: "checkmark.circle.fill")
        .font(.subheadline)
        .foregroundStyle(.green)
    case false?:
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(strings.notInChats)
            .font(.subheadline.weight(.semibold))
          Text(strings.notInChatsDetail)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    case nil:
      Label(strings.checkingChats, systemImage: "magnifyingglass")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private func lookUp(_ reach: RxMessageReach) async {
    guard reach.expectsChatMessage, entry.payloadType != .groupData,
          let stamp = entry.senderTimestamp,
          let store = appState.offlineDataStore else { return }
    let channel: UInt8? = entry.payloadType == .textMessage ? nil : entry.channelIndex
    inChats = (try? await store.hasMessage(radioID: entry.radioID, channelIndex: channel, senderTimestamp: stamp)) ?? false
  }
}
