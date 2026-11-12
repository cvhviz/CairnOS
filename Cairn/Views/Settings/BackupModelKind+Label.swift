import CairnServices

extension BackupModelKind {
  /// Localized display label used by backup preview, import-success, and
  /// export-success rows. Lives in the Cairn target because `L10n` is
  /// generated here by SwiftGen and is not visible from CairnServices.
  var label: String {
    switch self {
    case .messages: L10n.Settings.Settings.Backup.Import.Preview.messages
    case .contacts: L10n.Settings.Settings.Backup.Import.Preview.contacts
    case .channels: L10n.Settings.Settings.Backup.Import.Preview.channels
    case .devices: L10n.Settings.Settings.Backup.Import.Preview.devices
    case .roomMessages: L10n.Settings.Settings.Backup.Import.Preview.roomMessages
    case .reactions: L10n.Settings.Settings.Backup.Import.Preview.reactions
    case .messageRepeats: L10n.Settings.Settings.Backup.Import.Preview.messageRepeats
    case .savedTracePaths: L10n.Settings.Settings.Backup.Import.Preview.savedPaths
    case .remoteNodeSessions: L10n.Settings.Settings.Backup.Import.Preview.remoteNodeSessions
    case .blockedChannelSenders: L10n.Settings.Settings.Backup.Import.Preview.blockedSenders
    case .nodeStatusSnapshots: L10n.Settings.Settings.Backup.Import.Preview.nodeStatusSnapshots
    case .discoveredNodes: L10n.Settings.Settings.Backup.Import.Preview.discoveredNodes
    }
  }
}

extension BackupModelKind {
  /// Glyph for the kind's count tile on the backup preview and result sheets.
  var systemImage: String {
    switch self {
    case .messages: "bubble.left.and.bubble.right"
    case .contacts: "person.2"
    case .channels: "number"
    case .devices: "antenna.radiowaves.left.and.right"
    case .roomMessages: "person.3"
    case .reactions: "face.smiling"
    case .messageRepeats: "arrow.triangle.2.circlepath"
    case .savedTracePaths: "point.topleft.down.to.point.bottomright.curvepath"
    case .remoteNodeSessions: "server.rack"
    case .blockedChannelSenders: "hand.raised"
    case .nodeStatusSnapshots: "chart.xyaxis.line"
    case .discoveredNodes: "dot.radiowaves.up.forward"
    }
  }
}
