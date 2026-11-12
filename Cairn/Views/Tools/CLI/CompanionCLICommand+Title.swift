import CairnServices
import SwiftUI

// The app's words and symbols for the companion command catalogue, the firmware's labels
// (ui-l2 `CompanionCli.h`) keyed by each command's stable `id`.

extension CompanionCLICommand {
  /// The picker title: the firmware's `COMMANDS` label.
  var title: String {
    switch id {
    case "version": L10n.Tools.Tools.Cli.Companion.Command.version
    case "board": L10n.Tools.Tools.Cli.Companion.Command.board
    case "name": L10n.Tools.Tools.Cli.Companion.Command.name
    case "timeZone": L10n.Tools.Tools.Cli.Companion.Command.timeZone
    case "wifiState": L10n.Tools.Tools.Cli.Companion.Command.wifiState
    case "wifiEnabled": L10n.Tools.Tools.Cli.Companion.Command.wifiEnabled
    case "wifiNetwork": L10n.Tools.Tools.Cli.Companion.Command.wifiNetwork
    case "ipAddress": L10n.Tools.Tools.Cli.Companion.Command.ipAddress
    case "rename": L10n.Tools.Tools.Cli.Companion.Command.rename
    case "setTimeZone": L10n.Tools.Tools.Cli.Companion.Command.setTimeZone
    case "wifiOn": L10n.Tools.Tools.Cli.Companion.Command.wifiOn
    case "wifiOff": L10n.Tools.Tools.Cli.Companion.Command.wifiOff
    case "setWifiNetwork": L10n.Tools.Tools.Cli.Companion.Command.setWifiNetwork
    case "wifiKey": L10n.Tools.Tools.Cli.Companion.Command.wifiKey
    case "bluetoothPIN": L10n.Tools.Tools.Cli.Companion.Command.bluetoothPIN
    case "restart": L10n.Tools.Tools.Cli.Companion.Command.restart
    case "powerOff": L10n.Tools.Tools.Cli.Companion.Command.powerOff
    case "radio": L10n.Tools.Tools.Cli.Companion.Command.radio
    case "txPower": L10n.Tools.Tools.Cli.Companion.Command.txPower
    case "memory": L10n.Tools.Tools.Cli.Companion.Command.memory
    case "wifiClear": L10n.Tools.Tools.Cli.Companion.Command.wifiClear
    case "setRadio": L10n.Tools.Tools.Cli.Companion.Command.setRadio
    case "setTxPower": L10n.Tools.Tools.Cli.Companion.Command.setTxPower
    default: command.trimmingCharacters(in: .whitespaces)
    }
  }

  /// The quick-command title: the firmware's `QUICK` label, shorter than the picker's for
  /// Wi-Fi state.
  var quickTitle: String {
    id == "wifiState" ? L10n.Tools.Tools.Cli.Companion.Quick.wifi : title
  }

  /// The firmware tile's icon by group: info for a question, a pencil for a change, power.
  var systemImage: String {
    switch group {
    case .read: "info.circle"
    case .change: "pencil"
    case .power: "power"
    }
  }

  /// A quick-command tile's icon: the firmware's QUICK tiles all show Send.
  static let quickSystemImage = "paperplane"

  /// A quick-command tile's tint: the firmware's QUICK tiles are all link blue (`col::LINK`).
  static let quickTint: Color = .blue

  /// The firmware tile's tint by group: link blue, the accent, danger red.
  var tint: Color {
    switch group {
    case .read: .blue
    case .change: .accentColor
    case .power: .red
    }
  }
}

extension CompanionCLICommand.Group {
  /// The picker section title (the firmware's `GROUP_NAMES`).
  var title: String {
    switch self {
    case .read: L10n.Tools.Tools.Cli.Companion.Group.read
    case .change: L10n.Tools.Tools.Cli.Companion.Group.change
    case .power: L10n.Tools.Tools.Cli.Companion.Group.power
    }
  }
}
