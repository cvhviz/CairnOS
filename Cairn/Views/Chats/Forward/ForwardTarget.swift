import Foundation
import CairnServices

/// A conversation a message can be forwarded into.
enum ForwardTarget: Identifiable, Equatable {
  case dm(ContactDTO)
  case channel(ChannelDTO)

  var id: UUID {
    switch self {
    case let .dm(contact): contact.id
    case let .channel(channel): channel.id
    }
  }

  var displayName: String {
    switch self {
    case let .dm(contact): contact.displayName
    case let .channel(channel): channel.displayName
    }
  }

  var conversationType: ChatConversationType {
    switch self {
    case let .dm(contact): .dm(contact)
    case let .channel(channel): .channel(channel)
    }
  }

  /// Conversations a message can be forwarded to: configured channels and
  /// unblocked chat contacts, minus the conversation the message came from,
  /// narrowed by `searchText`. Channels list first, each group alphabetical.
  static func eligible(
    contacts: [ContactDTO],
    channels: [ChannelDTO],
    excluding sourceID: UUID,
    searchText: String
  ) -> (channels: [ForwardTarget], contacts: [ForwardTarget]) {
    let channelTargets = channels
      .filter { !$0.name.isEmpty || $0.hasSecret }
      .map(ForwardTarget.channel)
    let contactTargets = contacts
      .filter { !$0.isBlocked && $0.type == .chat }
      .map(ForwardTarget.dm)

    func prepared(_ targets: [ForwardTarget]) -> [ForwardTarget] {
      targets
        .filter { $0.id != sourceID }
        .filter { searchText.isEmpty || $0.displayName.localizedStandardContains(searchText) }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    return (prepared(channelTargets), prepared(contactTargets))
  }
}
