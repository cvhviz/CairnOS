import Foundation
@testable import CairnServices
import Testing

@Suite("LogRedaction")
struct LogRedactionTests {
  private static let secret = "hunter2"

  // MARK: - Commands

  @Test
  func `admin password change never logs any word of the password`() {
    #expect(LogRedaction.cliCommand("password a b") == "password [REDACTED]")
    #expect(LogRedaction.cliCommand("password correct horse battery") == "password [REDACTED]")
    #expect(LogRedaction.cliCommand("PASSWORD \(Self.secret)") == "password [REDACTED]")
  }

  @Test
  func `keyed secrets keep the verb and key and drop the value`() {
    #expect(LogRedaction.cliCommand("set guest.password x") == "set guest.password [REDACTED]")
    #expect(LogRedaction.cliCommand("set prv.key abcd") == "set prv.key [REDACTED]")
    #expect(LogRedaction.cliCommand("set password \(Self.secret)") == "set password [REDACTED]")
    #expect(LogRedaction.cliCommand("set ble.pin 123456") == "set ble.pin [REDACTED]")
    #expect(LogRedaction.cliCommand("set mqtt.secret a b c") == "set mqtt.secret [REDACTED]")
    #expect(LogRedaction.cliCommand("set wifi.pwd \(Self.secret)") == "set wifi.pwd [REDACTED]")
    #expect(LogRedaction.cliCommand("SET Guest.Password \(Self.secret)") == "SET Guest.Password [REDACTED]")
    #expect(LogRedaction.cliCommand("  set   guest.password   \(Self.secret)  ") == "set guest.password [REDACTED]")
  }

  @Test
  func `a query for a secret has no value to redact`() {
    #expect(LogRedaction.cliCommand("get guest.password") == "get guest.password")
    #expect(LogRedaction.cliCommand("get prv.key") == "get prv.key")
  }

  @Test
  func `a value glued to the verb or key is not logged`() {
    #expect(LogRedaction.cliCommand("password=\(Self.secret)") == "password [REDACTED]")
    #expect(LogRedaction.cliCommand("set guest.password=\(Self.secret)") == "set guest.password [REDACTED]")
  }

  @Test(arguments: [
    "password a b",
    "set guest.password x",
    "set prv.key abcd",
    "password=hunter2",
    "set guest.password=hunter2",
    "set guest.password  hunter2 extra"
  ])
  func `no value token survives redaction`(command: String) {
    let redacted = LogRedaction.cliCommand(command)
    for value in ["hunter2", "abcd", " a", " b", " x", "extra"] {
      #expect(!redacted.contains(value))
    }
  }

  @Test(arguments: ["get tx", "set tx 22", "get radio", "reboot", "clock", "set name Hilltop", "ver"])
  func `ordinary commands are logged unchanged`(command: String) {
    #expect(LogRedaction.cliCommand(command) == command)
    #expect(!LogRedaction.isSensitiveCLICommand(command))
  }

  @Test
  func `long ordinary commands are truncated`() {
    let command = "set owner.info " + String(repeating: "x", count: 60)
    #expect(LogRedaction.cliCommand(command) == String(command.prefix(40)) + "...")
  }

  @Test(arguments: [
    "password x",
    "set guest.password x",
    "get guest.password",
    "set prv.key abcd",
    "get prv.key",
    "set guest.password [REDACTED]",
    "set wifi.pwd x",
    "get wifi.pwd"
  ])
  func `commands that carry or request a secret are sensitive`(command: String) {
    #expect(LogRedaction.isSensitiveCLICommand(command))
  }

  // MARK: - Responses

  @Test(arguments: ["password now: hunter2", "Password Now: hunter2", "> password now: hunter2"])
  func `the firmware password echo is logged by length only`(response: String) {
    let logged = LogRedaction.cliResponse(response)
    #expect(logged == "[REDACTED] len=\(response.count)")
    #expect(!logged.contains(Self.secret))
  }

  @Test
  func `password echo is redacted even when attributed to an ordinary command`() {
    let logged = LogRedaction.cliResponse("password now: x", forCommand: "get tx")
    #expect(logged == "[REDACTED] len=15")
  }

  @Test
  func `the reply to a sensitive command is logged by length only`() {
    let response = "> \(Self.secret)"
    #expect(LogRedaction.cliResponse(response, forCommand: "get guest.password") == "[REDACTED] len=\(response.count)")
    #expect(LogRedaction.cliResponse("OK", forCommand: "set guest.password [REDACTED]") == "[REDACTED] len=2")
    #expect(LogRedaction.cliResponse("> \(Self.secret)", forCommand: "get wifi.pwd") == "[REDACTED] len=9")
  }

  @Test
  func `ordinary replies are logged, truncated when long`() {
    #expect(LogRedaction.cliResponse("> 22", forCommand: "get tx") == "> 22")
    #expect(LogRedaction.cliResponse("> 22") == "> 22")
    let long = String(repeating: "y", count: 150)
    #expect(LogRedaction.cliResponse(long, forCommand: "neighbors") == String(long.prefix(100)) + "...")
  }
}
