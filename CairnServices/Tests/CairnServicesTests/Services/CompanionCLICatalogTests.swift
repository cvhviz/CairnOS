import Foundation
@testable import CairnServices
import MeshCore
import Testing

/// Covers the pure half of another companion's command line against the Cairn firmware's
/// ui-l2 `CompanionCli.h` and `RemoteAdmin.cpp`: the command list, `cleanCommand`,
/// `restarts`, and the reply tags (`makeCliPrefix`, `cliPrefixMatches`, `cliBody`).
@Suite("Companion CLI catalog")
struct CompanionCLICatalogTests {
  // MARK: - Commands

  @Test
  func `commands match the firmware list in its order, with the parser's radio settings after each group's`() {
    let expected: [(CompanionCLICommand.Group, String, CompanionCLICommand.Kind)] = [
      (.read, "ver", .send),
      (.read, "board", .send),
      (.read, "get name", .send),
      (.read, "get tz.offset", .send),
      (.read, "get wifi.status", .send),
      (.read, "get wifi.enabled", .send),
      (.read, "get wifi.ssid", .send),
      (.read, "get wifi.ip", .send),
      (.read, "get radio", .send),
      (.read, "get tx", .send),
      (.read, "get mem", .send),
      (.change, "set name ", .edit),
      (.change, "set tz.offset ", .edit),
      (.change, "set wifi.enabled 1", .send),
      (.change, "set wifi.enabled 0", .send),
      (.change, "set wifi.ssid ", .edit),
      (.change, "set wifi.pwd ", .edit),
      (.change, "set pin ", .edit),
      (.change, "set wifi.clear", .send),
      (.change, "set radio ", .edit),
      (.change, "set tx ", .edit),
      (.power, "reboot", .confirm),
      (.power, "poweroff", .confirm),
    ]
    let commands = CompanionCLICatalog.commands
    #expect(commands.count == expected.count)
    for (command, entry) in zip(commands, expected) {
      #expect(command.group == entry.0)
      #expect(command.command == entry.1)
      #expect(command.kind == entry.2)
    }
  }

  @Test
  func `command ids are unique`() {
    let ids = CompanionCLICatalog.commands.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test
  func `the Wi-Fi password is never offered`() {
    #expect(!CompanionCLICatalog.commands.contains { $0.command.hasPrefix("get wifi.pwd") })
  }

  @Test
  func `quick commands match the firmware`() {
    #expect(CompanionCLICatalog.quick.map(\.command) == ["ver", "get wifi.status", "get wifi.ip", "board"])
  }

  @Test
  func `groups split the list in order`() {
    #expect(CompanionCLICatalog.commands(in: .read).count == 11)
    #expect(CompanionCLICatalog.commands(in: .change).count == 10)
    #expect(CompanionCLICatalog.commands(in: .power).map(\.command) == ["reboot", "poweroff"])
    #expect(CompanionCLICommand.Group.allCases == [.read, .change, .power])
  }

  @Test
  func `every command that is sent as it stands cleans to itself`() {
    for command in CompanionCLICatalog.commands where command.kind != .edit {
      #expect(CompanionCLICatalog.clean(command.command) == command.command)
    }
  }

  @Test
  func `an edit command cleans once a value follows`() {
    for command in CompanionCLICatalog.commands where command.kind == .edit {
      #expect(command.command.hasSuffix(" "))
      #expect(CompanionCLICatalog.clean(command.command + "1") == command.command + "1")
    }
  }

  // MARK: - Cleaning

  @Test
  func `surrounding spaces come off`() {
    #expect(CompanionCLICatalog.clean("  ver  ") == "ver")
    #expect(CompanionCLICatalog.clean("set name  Two  Words ") == "set name  Two  Words")
  }

  @Test(arguments: ["", " ", "     "])
  func `nothing left is refused`(input: String) {
    #expect(CompanionCLICatalog.clean(input) == nil)
  }

  @Test(arguments: ["ver\n", "\tver", "get\u{07}name", "set name a\u{7F}", "set name a\rb"])
  func `control characters and DEL are refused`(input: String) {
    #expect(CompanionCLICatalog.clean(input) == nil)
  }

  @Test(arguments: ["00|ver", "^4|ver", "ab|get name", "  7F|board"])
  func `a leading tag of its own is refused`(input: String) {
    #expect(CompanionCLICatalog.clean(input) == nil)
  }

  @Test
  func `a bar later in the command is fine`() {
    #expect(CompanionCLICatalog.clean("set name a|b") == "set name a|b")
    #expect(CompanionCLICatalog.clean("a|") == "a|", "the tag check needs 3 bytes, as the firmware's")
  }

  @Test
  func `length is capped at 63 bytes`() {
    let fits = "set name " + String(repeating: "x", count: 54)
    #expect(fits.utf8.count == 63)
    #expect(CompanionCLICatalog.clean(fits) == fits)
    #expect(CompanionCLICatalog.clean(fits + "x") == nil)
    #expect(CompanionCLICatalog.clean("  " + fits + "  ") == fits, "spaces off before the cap")
  }

  @Test
  func `the cap counts UTF-8 bytes`() {
    let name = "set name " + String(repeating: "é", count: 27) // 9 + 54 bytes
    #expect(name.utf8.count == 63)
    #expect(CompanionCLICatalog.clean(name) == name)
    #expect(CompanionCLICatalog.clean(name + "é") == nil)
  }

  @Test
  func `a 1-byte command is refused because it can't carry a tag`() {
    // Firmware strips a tag only from text longer than 4 bytes: "00|a" would come
    // back untagged as "Unknown command" and never match.
    #expect(CompanionCLICatalog.clean("a") == nil)
    #expect(CompanionCLICatalog.clean(" a ") == nil)
    #expect(CompanionCLICatalog.clean("ab") == "ab")
    #expect(("00|" + "ab").utf8.count > 4)
  }

  // MARK: - Restarts

  @Test(arguments: ["reboot", "poweroff", "shutdown"])
  func `restart commands are recognised`(command: String) {
    #expect(CompanionCLICatalog.restarts(command))
  }

  @Test(arguments: ["ver", "reboot now", "Reboot", "power", "set name reboot", ""])
  func `other commands do not restart`(command: String) {
    #expect(!CompanionCLICatalog.restarts(command))
  }

  // MARK: - Tags

  @Test
  func `tags are two hex digits and a bar`() {
    #expect(CompanionCLITag.make(sequence: 0) == "00|")
    #expect(CompanionCLITag.make(sequence: 0x0A) == "0A|")
    #expect(CompanionCLITag.make(sequence: 0xFF) == "FF|")
    for sequence in UInt8.min...UInt8.max {
      #expect(CompanionCLITag.make(sequence: sequence).utf8.count == CompanionCLITag.length)
    }
  }

  @Test
  func `no app tag is ever one a Cairn radio keeps for its own UI`() {
    for sequence in UInt8.min...UInt8.max {
      let tag = CompanionCLITag.make(sequence: sequence)
      #expect(!CompanionCLITag.isDeviceUITag(tag + "> 1"))
      #expect(!tag.hasPrefix("^"))
    }
  }

  @Test
  func `firmware UI tags are recognised as the radio's`() {
    // radmin::makeCliPrefix: '^' + "0-9A-Z"[seq % 36] + '|'
    let seqChars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    for seq in 0..<72 {
      let tag = "^\(seqChars[seq % 36])|"
      #expect(CompanionCLITag.isDeviceUITag(tag + "v1.18.0"))
      #expect(CompanionCLITag.isDeviceUITag(tag), "a bare tag is still the radio's")
    }
    #expect(!CompanionCLITag.isDeviceUITag("^4"))
    #expect(!CompanionCLITag.isDeviceUITag("> ^4|x"))
  }

  @Test
  func `a reply round-trips through the other device's tag echo`() {
    // MyMesh::handleCommand copies the 3-byte tag into the reply, then the handler appends.
    let tag = CompanionCLITag.make(sequence: 0x4F)
    let sent = tag + "get name"
    let echoed = String(sent.prefix(3)) + "> Field unit"

    #expect(CompanionCLITag.matches(echoed, tag: tag))
    #expect(CompanionCLITag.body(of: echoed) == "> Field unit")
    #expect(CompanionCLITag.displayText(CompanionCLITag.body(of: echoed)) == "Field unit")
  }

  @Test
  func `matching is the firmware's first three bytes`() {
    #expect(CompanionCLITag.matches("4F|OK", tag: "4F|"))
    #expect(CompanionCLITag.matches("4F|", tag: "4F|"), "an empty body still matches")
    #expect(!CompanionCLITag.matches("4E|OK", tag: "4F|"))
    #expect(!CompanionCLITag.matches("4f|OK", tag: "4F|"))
    #expect(!CompanionCLITag.matches("OK", tag: "4F|"))
    #expect(!CompanionCLITag.matches("4F", tag: "4F|"))
    #expect(!CompanionCLITag.matches("^4|OK", tag: "^4"), "a tag is exactly 3 bytes")
  }

  @Test
  func `the firmware matcher works for its own UI tags too`() {
    #expect(CompanionCLITag.matches("^4|OK - restarting", tag: "^4|"))
    #expect(CompanionCLITag.body(of: "^4|OK - restarting") == "OK - restarting")
  }

  @Test
  func `body leaves untagged text alone`() {
    // radmin::cliBody: strlen >= 3 && text[2] == '|'
    #expect(CompanionCLITag.body(of: "Unknown command") == "Unknown command")
    #expect(CompanionCLITag.body(of: "OK") == "OK")
    #expect(CompanionCLITag.body(of: "") == "")
    #expect(CompanionCLITag.body(of: "00|") == "")
    #expect(CompanionCLITag.body(of: "é|x") == "x", "two bytes then the bar is a tag, as in the firmware")
  }

  @Test
  func `display text drops the CLI's own lead`() {
    #expect(CompanionCLITag.displayText("> wifi.enabled is now 1") == "wifi.enabled is now 1")
    #expect(CompanionCLITag.displayText(">> x") == "x")
    #expect(CompanionCLITag.displayText("OK - restarting") == "OK - restarting")
    #expect(CompanionCLITag.displayText("a > b") == "a > b")
  }

  // MARK: - Timeout policy

  @Test
  func `companion deadline follows the firmware's formula`() {
    // radmin::deadlineMs(est, Kind::Cli) = est + est/4 + 600 + 1500, clamped to 3..40 s
    func deadline(_ estimateMs: UInt32, requested: Duration = .zero) -> Duration {
      RemoteOperationTimeoutPolicy.companionCLITimeout(
        for: MessageSentInfo(route: 0, expectedAck: Data(), suggestedTimeoutMs: estimateMs),
        requestedTimeout: requested
      )
    }
    #expect(deadline(0) == .seconds(3), "floor")
    #expect(deadline(4000) == .milliseconds(7100))
    #expect(deadline(20000) == .milliseconds(27100))
    #expect(deadline(60000) == .seconds(40), "ceiling")
    #expect(deadline(4000, requested: .seconds(10)) == .seconds(10), "a longer request wins")
    #expect(deadline(4000, requested: .seconds(90)) == .seconds(40), "but not past the ceiling")
  }

  // MARK: - Capability

  @Test
  func `companion CLI needs firmware version 14`() {
    #expect(!DeviceDTO.testDevice(firmwareVersion: 13).supportsCompanionRemoteCLI)
    #expect(DeviceDTO.testDevice(firmwareVersion: 14).supportsCompanionRemoteCLI)
    #expect(DeviceDTO.testDevice(firmwareVersion: 15).supportsCompanionRemoteCLI)
    #expect(
      DeviceDTO.testDevice(firmwareVersion: 13, firmwareVersionString: "v1.18.0").supportsCompanionRemoteCLI,
      "a fork on 1.18 that left the code unbumped"
    )
  }

  @Test
  func `unsupported-command device error is recognised`() {
    #expect(RemoteNodeError.sessionError(.deviceError(code: 1)).isUnsupportedByRadio)
    #expect(!RemoteNodeError.sessionError(.deviceError(code: 2)).isUnsupportedByRadio)
    #expect(!RemoteNodeError.timeout.isUnsupportedByRadio)
  }
}
