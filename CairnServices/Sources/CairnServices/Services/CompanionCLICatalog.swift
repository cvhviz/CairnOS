import Foundation

// MARK: - Companion CLI Command

/// One entry of another companion's command line (MeshCore 1.18), as the Cairn firmware's
/// touch UI offers it (ui-l2 `CompanionCli.h`, `COMMANDS`). Titles live in the app,
/// keyed by ``id``.
public struct CompanionCLICommand: Sendable, Hashable, Identifiable {
  /// The picker section a command belongs to.
  public enum Group: String, Sendable, CaseIterable {
    /// Questions that change nothing.
    case read
    /// Settings on the other device.
    case change
    /// Restart or power off the other device.
    case power
  }

  /// What picking a command does.
  public enum Kind: Sendable {
    /// Sends at once.
    case send
    /// Starts the command ("set name ") for the value to be typed after it.
    case edit
    /// Asks first, then sends (it restarts the other device).
    case confirm
  }

  /// Stable key for the app's title and symbol.
  public let id: String
  public let group: Group
  public let kind: Kind
  /// The command text, or its start for ``Kind/edit`` (trailing space included).
  public let command: String

  public init(id: String, group: Group, kind: Kind, command: String) {
    self.id = id
    self.group = group
    self.kind = kind
    self.command = command
  }
}

// MARK: - Companion CLI Catalog

/// The pure half of another companion's command line, mirroring the Cairn firmware's
/// ui-l2 `CompanionCli.h`: the command list, the rules that make a typed command
/// sendable, and which commands restart the other device.
///
/// A command goes as `TXT_TYPE_CLI_COMMAND` with a tag in front (``CompanionCLITag``).
/// The other device runs it only when its contact for this radio allows remote commands
/// (contact flag 0x10) and answers as CLI data with the tag in front. There is no login:
/// the permission is the other side's, so silence (not allowed, out of range, older
/// firmware there) is a timeout.
public enum CompanionCLICatalog {
  /// Most bytes a typed command may have (firmware `CMD_MAX` 64, less the terminator).
  public static let commandMaxBytes = 63

  /// Fewest bytes a typed command may have. Firmware strips the tag only from a command
  /// longer than 4 bytes with it, so a 1-byte command would come back untagged and
  /// could never be matched to its reply.
  public static let commandMinBytes = 2

  /// The commands that restart the other device (firmware `ccli::restarts`).
  public static let restartCommands: Set<String> = ["reboot", "poweroff", "shutdown"]

  /// What MeshCore 1.18's companion CLI takes, plus what a Cairn device answers itself,
  /// in the firmware's order, with the radio settings its parser also takes. `get wifi.pwd`
  /// is left out on purpose: a password over the mesh.
  public static let commands: [CompanionCLICommand] = [
    CompanionCLICommand(id: "version", group: .read, kind: .send, command: "ver"),
    CompanionCLICommand(id: "board", group: .read, kind: .send, command: "board"),
    CompanionCLICommand(id: "name", group: .read, kind: .send, command: "get name"),
    CompanionCLICommand(id: "timeZone", group: .read, kind: .send, command: "get tz.offset"),
    CompanionCLICommand(id: "wifiState", group: .read, kind: .send, command: "get wifi.status"),
    CompanionCLICommand(id: "wifiEnabled", group: .read, kind: .send, command: "get wifi.enabled"),
    CompanionCLICommand(id: "wifiNetwork", group: .read, kind: .send, command: "get wifi.ssid"),
    CompanionCLICommand(id: "ipAddress", group: .read, kind: .send, command: "get wifi.ip"),
    // What the firmware's parser takes beyond its touch list: the radio's settings
    // (`CommonRadioPrefs`), its free memory (nRF52) and forgetting the Wi-Fi network.
    CompanionCLICommand(id: "radio", group: .read, kind: .send, command: "get radio"),
    CompanionCLICommand(id: "txPower", group: .read, kind: .send, command: "get tx"),
    CompanionCLICommand(id: "memory", group: .read, kind: .send, command: "get mem"),
    CompanionCLICommand(id: "rename", group: .change, kind: .edit, command: "set name "),
    CompanionCLICommand(id: "setTimeZone", group: .change, kind: .edit, command: "set tz.offset "),
    CompanionCLICommand(id: "wifiOn", group: .change, kind: .send, command: "set wifi.enabled 1"),
    CompanionCLICommand(id: "wifiOff", group: .change, kind: .send, command: "set wifi.enabled 0"),
    CompanionCLICommand(id: "setWifiNetwork", group: .change, kind: .edit, command: "set wifi.ssid "),
    CompanionCLICommand(id: "wifiKey", group: .change, kind: .edit, command: "set wifi.pwd "),
    CompanionCLICommand(id: "bluetoothPIN", group: .change, kind: .edit, command: "set pin "),
    CompanionCLICommand(id: "wifiClear", group: .change, kind: .send, command: "set wifi.clear"),
    CompanionCLICommand(id: "setRadio", group: .change, kind: .edit, command: "set radio "),
    CompanionCLICommand(id: "setTxPower", group: .change, kind: .edit, command: "set tx "),
    CompanionCLICommand(id: "restart", group: .power, kind: .confirm, command: "reboot"),
    CompanionCLICommand(id: "powerOff", group: .power, kind: .confirm, command: "poweroff"),
  ]

  /// The quick commands (firmware `QUICK`): version, Wi-Fi state, IP address, board.
  public static let quick: [CompanionCLICommand] = ["version", "wifiState", "ipAddress", "board"]
    .compactMap { id in commands.first { $0.id == id } }

  /// The commands of one picker section, in order.
  public static func commands(in group: CompanionCLICommand.Group) -> [CompanionCLICommand] {
    commands.filter { $0.group == group }
  }

  /// A typed command made sendable (firmware `ccli::cleanCommand`): surrounding spaces
  /// off, at most ``commandMaxBytes`` UTF-8 bytes. Nil for nothing left, a control
  /// character or DEL, or a leading tag of its own (`x?|...`: the tag is the app's to add).
  /// Also nil below ``commandMinBytes``, which the firmware lets through but can't tag.
  public static func clean(_ input: String) -> String? {
    var bytes = Array(input.utf8)
    while bytes.first == 0x20 { bytes.removeFirst() }
    while bytes.last == 0x20 { bytes.removeLast() }
    guard bytes.count >= commandMinBytes, bytes.count <= commandMaxBytes else { return nil }
    guard !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) else { return nil }
    guard !(bytes.count >= 3 && bytes[2] == CompanionCLITag.separator) else { return nil }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Whether a (cleaned) command restarts the other device. Stock firmware restarts
  /// before it answers; a Cairn device answers "OK - restarting" first.
  public static func restarts(_ command: String) -> Bool {
    restartCommands.contains(command)
  }
}

// MARK: - Companion CLI Tag

/// The 3-byte tag in front of a companion command and its reply. The other device
/// reflects any `x?|` from the command back at the start of the reply (MyMesh
/// `handleCommand`), which is how a reply finds its command.
///
/// The app's tags are two hex digits ("00|" to "FF|"), the same as its repeater wire
/// prefixes. A Cairn radio keeps every reply tagged `^x|` for its own touch UI
/// (firmware `radmin::makeCliPrefix`, `UIModel::onRemoteCliReply`), so an app tag must
/// never start with `^`.
public enum CompanionCLITag {
  /// Byte that ends a tag.
  static let separator = UInt8(ascii: "|")

  /// Bytes in a tag, separator included.
  public static let length = 3

  /// The tag for a sequence number: "00|" through "FF|".
  public static func make(sequence: UInt8) -> String {
    String(format: "%02X|", sequence)
  }

  /// Whether a reply starts with the tag (firmware `radmin::cliPrefixMatches`).
  public static func matches(_ text: String, tag: String) -> Bool {
    let tagBytes = Array(tag.utf8)
    guard tagBytes.count == length else { return false }
    return Array(text.utf8.prefix(length)) == tagBytes
  }

  /// A reply without its tag (firmware `radmin::cliBody`); text without one is unchanged.
  /// An empty body is possible: a command whose handler printed nothing.
  public static func body(of text: String) -> String {
    let bytes = Array(text.utf8)
    guard bytes.count >= length, bytes[length - 1] == separator else { return text }
    return String(decoding: bytes.dropFirst(length), as: UTF8.self)
  }

  /// A reply body as the firmware's page shows it: the CLI's own lead ("> ") off.
  public static func displayText(_ body: String) -> String {
    String(body.drop { $0 == ">" || $0 == " " })
  }

  /// Whether a reply carries a tag a Cairn radio's touch UI sent (`^x|`). Such a reply
  /// is never the app's, even when it reaches the app after the radio's claim window.
  public static func isDeviceUITag(_ text: String) -> Bool {
    let bytes = Array(text.utf8.prefix(length))
    return bytes.count == length && bytes[0] == UInt8(ascii: "^") && bytes[2] == separator
  }
}

// MARK: - Late replies

/// A companion's reply that came after its command had timed out
/// (``RemoteNodeService/companionCLILateReplies()``): the firmware's LATE line
/// (ui-l2 `UIModel::onRemoteCliReply`, `ccli::LATE`).
public struct CompanionCLILateReply: Sendable, Equatable {
  /// The ID the command was sent with.
  public let requestID: UUID
  /// The first 6 bytes of the companion's public key.
  public let publicKeyPrefix: Data
  /// The command as it went, cleaned and without its tag.
  public let command: String
  /// The reply without its tag, as ``RemoteNodeService/sendCompanionCLICommand(publicKey:command:timeout:requestID:)``
  /// returns one: the CLI's own "> " lead is kept, and it may be empty.
  public let text: String

  public init(requestID: UUID, publicKeyPrefix: Data, command: String, text: String) {
    self.requestID = requestID
    self.publicKeyPrefix = publicKeyPrefix
    self.command = command
    self.text = text
  }
}
