import CairnServices
import Foundation
import OSLog

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "RepeaterControls")

/// One of the repeater's tunable settings on its Controls page: how to read it, how to set it, and
/// what it accepts. Read with `get <key>` and set with `set <key> <value>` unless it has its own
/// command (power saving and GPS do).
struct RepeaterTunable: Identifiable, Equatable {
  enum Kind: Equatable {
    /// A number stepped within `range` by `step`, shown with `digits` decimals.
    case number(range: ClosedRange<Double>, step: Double, digits: Int)
    /// On or off, sent as `on` / `off` (or the values given).
    case toggle(on: String, off: String)
    /// One of a few named values.
    case choice([String])
  }

  let key: String
  let title: String
  /// What it does, under its row.
  let detail: String
  let unit: String?
  let kind: Kind
  /// The read, if not `get <key>`.
  var query: String?
  /// The set, if not `set <key> <value>`.
  var command: ((String) -> String)?
  /// For a choice, what each value is called on the row; a value without one shows as itself.
  var choiceTitles: [String: String] = [:]
  /// For a choice the firmware reports in other words than it takes ("logRx" for `rx`): the
  /// value a reply stands for, or nil to read it the usual way.
  var readValue: ((String) -> String?)?

  var id: String { key }

  /// What a choice is called on the row.
  func title(of choice: String) -> String {
    choiceTitles[choice] ?? choice.capitalized
  }

  var readCommand: String { query ?? "get \(key)" }

  func writeCommand(_ value: String) -> String {
    command?(value) ?? "set \(key) \(value)"
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.key == rhs.key && lhs.kind == rhs.kind
  }
}

/// A one-tap command on the Controls page.
struct RepeaterCommand: Identifiable {
  let command: String
  let title: String
  let systemImage: String
  /// Asked about first, for commands that throw something away.
  var confirmation: String?
  var isDestructive = false
  /// Done only when the node answers OK: any other answer ("gps provider not found") says why not.
  var succeedsOnlyOnOK = false

  var id: String { command }
}

/// A few of the Controls page's settings that belong together, read from the repeater only when the
/// group is opened: every read is a request and a reply over the mesh, and the page has 24 of them.
struct RepeaterTuningGroup: Identifiable, Equatable {
  let id: String
  let title: String
  /// What's in it, under its title once read.
  let detail: String
  let systemImage: String
  /// Its settings, in the order the page shows them (numbers in one card, then the switches).
  let keys: [String]
}

/// The repeater's Controls page: its transmit power up front, the tuning the firmware exposes over
/// its CLI (airtime factor, delays, interference threshold and the like) and its switches in groups,
/// and its one-off commands. Opening the page reads only the transmit power; a group's settings are
/// read when it is opened (once a visit, again on a pull to refresh while it's open) and each is set
/// on its own, through the same remote CLI the settings sheets use.
@Observable
@MainActor
final class RepeaterControlsModel {
  enum ReadState: Equatable {
    case loading
    case value(String)
    /// The firmware answered "unknown command": an older build without the setting.
    case unsupported
    case failed
  }

  /// A finished command or set, shown in the page's banner for a moment.
  struct Outcome: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let reply: String?
    let succeeded: Bool
  }

  private(set) var states: [String: ReadState] = [:]
  /// Values edited on the page and not yet sent.
  var drafts: [String: String] = [:]
  private(set) var busyKeys: Set<String> = []
  private(set) var outcome: Outcome?

  private let settings: NodeSettingsViewModel

  init(settings: NodeSettingsViewModel) {
    self.settings = settings
  }

  // MARK: - Catalogue

  static let tuning: [RepeaterTunable] = [
    RepeaterTunable(
      key: "af",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Af.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Af.detail,
      unit: nil,
      kind: .number(range: 0...9, step: 0.5, digits: 1)
    ),
    RepeaterTunable(
      key: "rxdelay",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Rxdelay.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Rxdelay.detail,
      unit: nil,
      kind: .number(range: 0...20, step: 0.5, digits: 1)
    ),
    RepeaterTunable(
      key: "txdelay",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Txdelay.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Txdelay.detail,
      unit: nil,
      kind: .number(range: 0...2, step: 0.1, digits: 1)
    ),
    RepeaterTunable(
      key: "direct.txdelay",
      title: L10n.RemoteNodes.RemoteNodes.Controls.DirectTxdelay.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.DirectTxdelay.detail,
      unit: nil,
      kind: .number(range: 0...2, step: 0.1, digits: 1)
    ),
    RepeaterTunable(
      key: "int.thresh",
      title: L10n.RemoteNodes.RemoteNodes.Controls.IntThresh.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.IntThresh.detail,
      unit: "dB",
      kind: .number(range: 0...30, step: 1, digits: 0)
    ),
    RepeaterTunable(
      key: "agc.reset.interval",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Agc.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Agc.detail,
      unit: "s",
      kind: .number(range: 0...1020, step: 4, digits: 0)
    ),
    // The airtime factor's other face: the firmware keeps one value and answers both
    RepeaterTunable(
      key: "dutycycle",
      title: L10n.RemoteNodes.RemoteNodes.Controls.DutyCycle.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.DutyCycle.detail,
      unit: "%",
      kind: .number(range: 1...100, step: 1, digits: 0)
    ),
    RepeaterTunable(
      key: "flood.max.advert",
      title: L10n.RemoteNodes.RemoteNodes.Controls.FloodMaxAdvert.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.FloodMaxAdvert.detail,
      unit: nil,
      kind: .number(range: 0...64, step: 1, digits: 0)
    ),
    RepeaterTunable(
      key: "flood.max.unscoped",
      title: L10n.RemoteNodes.RemoteNodes.Controls.FloodMaxUnscoped.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.FloodMaxUnscoped.detail,
      unit: nil,
      kind: .number(range: 0...64, step: 1, digits: 0)
    ),
    // The bridge rows answer "??" on a board built without one, and are left off the page then
    RepeaterTunable(
      key: "bridge.delay",
      title: L10n.RemoteNodes.RemoteNodes.Controls.BridgeDelay.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.BridgeDelay.detail,
      unit: "ms",
      kind: .number(range: 0...10000, step: 50, digits: 0)
    ),
    RepeaterTunable(
      key: "bridge.baud",
      title: L10n.RemoteNodes.RemoteNodes.Controls.BridgeBaud.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.BridgeBaud.detail,
      unit: nil,
      kind: .number(range: 9600...921_600, step: 9600, digits: 0)
    ),
    RepeaterTunable(
      key: "bridge.channel",
      title: L10n.RemoteNodes.RemoteNodes.Controls.BridgeChannel.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.BridgeChannel.detail,
      unit: nil,
      kind: .number(range: 1...14, step: 1, digits: 0)
    ),
  ]

  static let switches: [RepeaterTunable] = [
    RepeaterTunable(
      key: "multi.acks",
      title: L10n.RemoteNodes.RemoteNodes.Controls.MultiAcks.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.MultiAcks.detail,
      unit: nil,
      kind: .toggle(on: "1", off: "0")
    ),
    RepeaterTunable(
      key: "allow.read.only",
      title: L10n.RemoteNodes.RemoteNodes.Controls.ReadOnly.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.ReadOnly.detail,
      unit: nil,
      kind: .toggle(on: "on", off: "off")
    ),
    RepeaterTunable(
      key: "radio.rxgain",
      title: L10n.RemoteNodes.RemoteNodes.Controls.RxGain.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.RxGain.detail,
      unit: nil,
      kind: .toggle(on: "on", off: "off")
    ),
    // a board with a switchable front end (Heltec V4.3 / V4-R8 / T096). Other boards answer
    // "??: radio.fem.rxgain" (and "unknown config: …" to a set); a Heltec V4.2 "Error: unsupported"
    RepeaterTunable(
      key: "radio.fem.rxgain",
      title: L10n.RemoteNodes.RemoteNodes.Controls.FemLna.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.FemLna.detail,
      unit: nil,
      kind: .toggle(on: "on", off: "off")
    ),
    RepeaterTunable(
      key: "powersaving",
      title: L10n.RemoteNodes.RemoteNodes.Controls.PowerSaving.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.PowerSaving.detail,
      unit: nil,
      kind: .toggle(on: "on", off: "off"),
      query: "powersaving",
      command: { "powersaving \($0)" }
    ),
    RepeaterTunable(
      key: "gps",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Gps.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Gps.detail,
      unit: nil,
      kind: .toggle(on: "on", off: "off"),
      query: "gps",
      command: { "gps \($0)" }
    ),
    RepeaterTunable(
      key: "loop.detect",
      title: L10n.RemoteNodes.RemoteNodes.Controls.LoopDetect.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.LoopDetect.detail,
      unit: nil,
      kind: .choice(["off", "minimal", "moderate", "strict"])
    ),
    RepeaterTunable(
      key: "cad",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Cad.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Cad.detail,
      unit: nil,
      kind: .toggle(on: "on", off: "off")
    ),
    RepeaterTunable(
      key: "path.hash.mode",
      title: L10n.RemoteNodes.RemoteNodes.Controls.PathHashMode.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.PathHashMode.detail,
      unit: nil,
      kind: .choice(["0", "1", "2"]),
      choiceTitles: [
        "0": L10n.RemoteNodes.RemoteNodes.Controls.PathHashMode.oneByte,
        "1": L10n.RemoteNodes.RemoteNodes.Controls.PathHashMode.twoBytes,
        "2": L10n.RemoteNodes.RemoteNodes.Controls.PathHashMode.threeBytes,
      ]
    ),
    RepeaterTunable(
      key: "gps.advert",
      title: L10n.RemoteNodes.RemoteNodes.Controls.GpsAdvert.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.GpsAdvert.detail,
      unit: nil,
      kind: .choice(["none", "share", "prefs"]),
      query: "gps advert",
      command: { "gps advert \($0)" },
      choiceTitles: [
        "none": L10n.RemoteNodes.RemoteNodes.Controls.GpsAdvert.none,
        "share": L10n.RemoteNodes.RemoteNodes.Controls.GpsAdvert.share,
        "prefs": L10n.RemoteNodes.RemoteNodes.Controls.GpsAdvert.prefs,
      ]
    ),
    RepeaterTunable(
      key: "bridge.enabled",
      title: L10n.RemoteNodes.RemoteNodes.Controls.BridgeEnabled.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.BridgeEnabled.detail,
      unit: nil,
      kind: .toggle(on: "on", off: "off")
    ),
    // Set with `rx` or `tx`; answered as "logRx" or "logTx"
    RepeaterTunable(
      key: "bridge.source",
      title: L10n.RemoteNodes.RemoteNodes.Controls.BridgeSource.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.BridgeSource.detail,
      unit: nil,
      kind: .choice(["rx", "tx"]),
      choiceTitles: [
        "rx": L10n.RemoteNodes.RemoteNodes.Controls.BridgeSource.received,
        "tx": L10n.RemoteNodes.RemoteNodes.Controls.BridgeSource.sent,
      ],
      readValue: { reply in
        let lowered = reply.lowercased()
        if lowered.contains("rx") { return "rx" }
        if lowered.contains("tx") { return "tx" }
        return nil
      }
    ),
  ]

  static let commands: [RepeaterCommand] = [
    RepeaterCommand(
      command: "advert.zerohop",
      title: L10n.Settings.BleStatus.sendZeroHopAdvert,
      systemImage: "dot.radiowaves.right"
    ),
    RepeaterCommand(
      command: "gps sync",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Command.gpsSync,
      systemImage: "clock.badge.checkmark",
      succeedsOnlyOnOK: true
    ),
    // Copies the GPS fix into the saved location (`set lat` / `set lon` from the fix)
    RepeaterCommand(
      command: "gps setloc",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Command.gpsSetLoc,
      systemImage: "location.square",
      succeedsOnlyOnOK: true
    ),
    RepeaterCommand(
      command: "log start",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Command.logStart,
      systemImage: "record.circle"
    ),
    RepeaterCommand(
      command: "log stop",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Command.logStop,
      systemImage: "stop.circle"
    ),
    RepeaterCommand(
      command: "clear stats",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Command.clearStats,
      systemImage: "chart.bar.xaxis",
      confirmation: L10n.RemoteNodes.RemoteNodes.Controls.Command.clearStatsConfirm,
      isDestructive: true
    ),
    RepeaterCommand(
      command: "log erase",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Command.logErase,
      systemImage: "trash",
      confirmation: L10n.RemoteNodes.RemoteNodes.Controls.Command.logEraseConfirm,
      isDestructive: true
    ),
    // The node answers nothing: it's off before a reply could go
    RepeaterCommand(
      command: "poweroff",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Command.powerOff,
      systemImage: "power",
      confirmation: L10n.RemoteNodes.RemoteNodes.Controls.Command.powerOffConfirm,
      isDestructive: true
    ),
  ]

  // MARK: - Groups

  /// Every tuning value and switch, in five groups (each key in exactly one: `RepeaterControlsModelTests`).
  static let groups: [RepeaterTuningGroup] = [
    RepeaterTuningGroup(
      id: "timing",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Group.Timing.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Group.Timing.detail,
      systemImage: "timer",
      keys: ["af", "rxdelay", "txdelay", "direct.txdelay", "dutycycle"]
    ),
    RepeaterTuningGroup(
      id: "receiver",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Group.Receiver.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Group.Receiver.detail,
      systemImage: "ear.badge.waveform",
      keys: ["int.thresh", "agc.reset.interval", "radio.rxgain", "radio.fem.rxgain", "cad"]
    ),
    RepeaterTuningGroup(
      id: "routing",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Group.Routing.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Group.Routing.detail,
      systemImage: "point.3.connected.trianglepath.dotted",
      keys: ["flood.max.advert", "flood.max.unscoped", "loop.detect", "path.hash.mode", "multi.acks"]
    ),
    RepeaterTuningGroup(
      id: "device",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Group.Device.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Group.Device.detail,
      systemImage: "gearshape",
      keys: ["allow.read.only", "gps", "gps.advert", "powersaving"]
    ),
    RepeaterTuningGroup(
      id: "bridge",
      title: L10n.RemoteNodes.RemoteNodes.Controls.Group.Bridge.title,
      detail: L10n.RemoteNodes.RemoteNodes.Controls.Group.Bridge.detail,
      systemImage: "arrow.left.arrow.right",
      keys: ["bridge.enabled", "bridge.source", "bridge.delay", "bridge.baud", "bridge.channel"]
    ),
  ]

  /// A group's settings, in its order.
  static func tunables(in group: RepeaterTuningGroup) -> [RepeaterTunable] {
    let all = tuning + switches
    return group.keys.compactMap { key in all.first { $0.key == key } }
  }

  /// Where a group's reads stand: not asked yet, being read (`done` of `total`), or read (whatever
  /// each answered: a value, unsupported, failed).
  enum GroupProgress: Equatable {
    case notRead
    case reading(done: Int, total: Int)
    case read
  }

  func progress(of group: RepeaterTuningGroup) -> GroupProgress {
    let tunables = Self.tunables(in: group)
    let reads = tunables.map { states[$0.key] }
    if reads.allSatisfy({ $0 == nil }) { return .notRead }
    if reads.contains(.loading) {
      return .reading(done: reads.count(where: { $0 != nil && $0 != .loading }), total: tunables.count)
    }
    return .read
  }

  // MARK: - Reading

  /// Reads a group's settings in turn, skipping what this visit already has (a failed one is tried
  /// again); `again` reads them all (a pull to refresh). Each row fills in as its answer arrives.
  func load(_ group: RepeaterTuningGroup, again: Bool = false) async {
    let tunables = Self.tunables(in: group)
    for tunable in tunables where again || states[tunable.key] == nil || states[tunable.key] == .failed {
      states[tunable.key] = .loading
    }
    for tunable in tunables where states[tunable.key] == .loading {
      // left (the page closed): not asked, so the group reads it when it's next opened
      if Task.isCancelled { states[tunable.key] = nil; continue }
      await read(tunable)
    }
  }

  func read(_ tunable: RepeaterTunable) async {
    states[tunable.key] = .loading
    do {
      let reply = try await settings.sendAndWait(tunable.readCommand)
      states[tunable.key] = Self.readState(reply, for: tunable)
    } catch is CancellationError {
      states[tunable.key] = .failed
    } catch {
      logger.info("Controls read '\(tunable.readCommand)' failed: \(error.localizedDescription)")
      states[tunable.key] = .failed
    }
  }

  /// A reply as the row shows it: the number, on or off, or the choice. "Unknown command", a
  /// repeater's "??: <key>" or "unknown config: …" (its CLI has no such setting) and "Error:
  /// unsupported" (it has the setting but not the hardware) all mean the node doesn't have it.
  static func readState(_ reply: String, for tunable: RepeaterTunable) -> ReadState {
    if isNoSuchSetting(reply) { return .unsupported }
    switch CLIResponse.parse(reply) {
    case .unknownCommand:
      return .unsupported
    case let .error(text) where text.lowercased().contains("unsupported"):
      // "Error: unsupported": the command exists but this board has no such hardware (a front end)
      return .unsupported
    case .error:
      return .failed
    default:
      break
    }
    let text = stripped(reply)
    if let readValue = tunable.readValue {
      return readValue(text).map { .value($0) } ?? .failed
    }
    switch tunable.kind {
    case .number:
      guard let number = leadingNumber(in: text) else { return .failed }
      return .value(String(number))
    case let .toggle(on, _):
      let lowered = text.lowercased()
      let isOn = lowered.hasPrefix(on) || lowered.hasPrefix("on") || lowered.hasPrefix("1")
        || lowered.hasPrefix("enabled") || lowered.hasPrefix("true")
      return .value(isOn ? "on" : "off")
    case let .choice(options):
      let lowered = text.lowercased()
      return .value(options.first { lowered.hasPrefix($0) } ?? lowered)
    }
  }

  /// The reply without the firmware's "> " prompt.
  static func stripped(_ reply: String) -> String {
    var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix(">") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
    return text
  }

  /// Whether a one-tap command's reply means it was done: anything but an error, or for a command
  /// that `succeedsOnlyOnOK`, only an OK (the firmware answers "ok" or "OK").
  static func succeeded(_ command: RepeaterCommand, reply: String) -> Bool {
    switch CLIResponse.parse(reply) {
    case .error, .unknownCommand:
      return false
    case .ok:
      return true
    default:
      return !command.succeedsOnlyOnOK || stripped(reply).lowercased() == "ok"
    }
  }

  /// The settings this node has: one it answered as unsupported (no such setting, or no such
  /// hardware) is left off the page rather than shown greyed out.
  func shown(_ tunables: [RepeaterTunable]) -> [RepeaterTunable] {
    tunables.filter { states[$0.key] != .unsupported }
  }

  /// A repeater CLI's answer for a setting it doesn't know: "??: radio.fem.rxgain" to a get,
  /// "unknown config: radio.fem.rxgain on" to a set (CommonCLI).
  static func isNoSuchSetting(_ reply: String) -> Bool {
    let text = stripped(reply).lowercased()
    return text.hasPrefix("??") || text.hasPrefix("unknown config")
  }

  /// The first number in `text` ("1.0", "-90", "14 dB").
  static func leadingNumber(in text: String) -> Double? {
    let scanner = Scanner(string: text)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: "-0123456789.").inverted
    return scanner.scanDouble()
  }

  // MARK: - Writing

  /// Sends a new value for a setting; on success it becomes the row's value.
  func write(_ tunable: RepeaterTunable, value: String) async {
    busyKeys.insert(tunable.key)
    defer { busyKeys.remove(tunable.key) }
    let sent: String = switch tunable.kind {
    case let .toggle(on, off): value == "on" ? on : off
    default: value
    }
    do {
      let reply = try await settings.sendAndWait(tunable.writeCommand(sent))
      if Self.isNoSuchSetting(reply) {
        states[tunable.key] = .unsupported
        report(tunable.title, reply: Self.stripped(reply), succeeded: false)
        return
      }
      switch CLIResponse.parse(reply) {
      case let .error(text) where text.lowercased().contains("unsupported"):
        states[tunable.key] = .unsupported
        report(tunable.title, reply: Self.stripped(reply), succeeded: false)
      case .error, .unknownCommand:
        report(tunable.title, reply: Self.stripped(reply), succeeded: false)
      default:
        states[tunable.key] = .value(value)
        drafts[tunable.key] = nil
        report(tunable.title, reply: nil, succeeded: true)
      }
    } catch {
      report(tunable.title, reply: error.userFacingMessage, succeeded: false)
    }
  }

  func run(_ command: RepeaterCommand) async {
    busyKeys.insert(command.id)
    defer { busyKeys.remove(command.id) }
    let powersOff = command.command == "poweroff"
    do {
      let reply = try await settings.sendAndWait(
        command.command,
        timeout: powersOff ? RemoteOperationTimeoutPolicy.fireAndForgetCLI : RemoteOperationTimeoutPolicy.defaultCLITimeout
      )
      let text = Self.stripped(reply)
      if Self.succeeded(command, reply: reply) {
        report(command.title, reply: text.isEmpty || text.lowercased() == "ok" ? nil : text, succeeded: true)
        if powersOff { settings.markPoweredOff() }
      } else {
        report(command.title, reply: text, succeeded: false)
      }
    } catch RemoteNodeError.timeout where powersOff {
      // The node answers nothing: it's off before a reply could go. The dashboard now knows.
      report(command.title, reply: nil, succeeded: true)
      settings.markPoweredOff()
    } catch {
      report(command.title, reply: error.userFacingMessage, succeeded: false)
    }
  }

  // MARK: - Transmit power

  /// Sets the transmit power alone (`set tx`), which applies at once with no radio restart, through
  /// the settings model so the Dashboard's Radio card follows.
  func applyTxPower(_ dbm: Int) async {
    busyKeys.insert("tx")
    defer { busyKeys.remove("tx") }
    settings.txPower = dbm
    settings.txPowerModified = dbm != settings.originalTxPower
    guard settings.txPowerModified else { return }
    await settings.applyRadioSettings()
    // The page reports it itself; the Dashboard's alert beneath would only repeat it.
    settings.showSuccessAlert = false
    let failure = settings.errorMessage
    settings.errorMessage = nil
    report(
      L10n.Settings.Dashboard.txPower,
      reply: failure ?? L10n.Settings.DeviceInfo.txPowerFormat(dbm.formatted()),
      succeeded: failure == nil && !settings.txPowerModified
    )
  }

  private func report(_ title: String, reply: String?, succeeded: Bool) {
    outcome = Outcome(title: title, reply: reply, succeeded: succeeded)
  }

  func clearOutcome(_ id: UUID) {
    if outcome?.id == id { outcome = nil }
  }
}
