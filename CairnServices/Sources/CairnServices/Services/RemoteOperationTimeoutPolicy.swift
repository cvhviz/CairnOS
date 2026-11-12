import Foundation
import MeshCore

public enum RemoteOperationTimeoutPolicy {
  static let firmwareRoundTripMultiplier = 2
  static let loginMaximum: Duration = .seconds(20)
  /// Floor for login retransmit spacing while waiting for `loginSuccess`.
  /// Raised to firmware `suggestedTimeoutMs` when larger.
  static let loginRetransmitInterval: Duration = .seconds(1)
  /// Outer cap for remote binary / status / telemetry waits: one
  /// `binaryRequestOverallTimeout` exchange plus a small BLE margin.
  public static let binaryMaximum: Duration = .seconds(45)
  static let cliMaximum: Duration = .seconds(15)
  /// Default wait for a CLI reply. Generous because LoRa replies routinely
  /// take several seconds and waiting costs no airtime, unlike a resend.
  public static let defaultCLITimeout: Duration = .seconds(10)
  /// Wait for commands that get no reply by design (`reboot`); long enough to
  /// catch an error reply, short enough not to read as a failure to the user.
  public static let fireAndForgetCLI: Duration = .seconds(2)
  static let pollInterval: Duration = .milliseconds(500)
  /// Floor of a companion CLI wait, the firmware's own (`radmin::deadlineMs`).
  public static let companionCLIMinimum: Duration = .seconds(3)
  /// Ceiling of a companion CLI wait, the firmware's own. Longer than ``cliMaximum``:
  /// a flood there and back can take it, and waiting costs no airtime.
  static let companionCLIMaximum: Duration = .seconds(40)
  /// The other companion's reply delay (firmware `CLI_REPLY_DELAY_MILLIS`).
  static let companionCLIReplyDelay: Duration = .milliseconds(600)
  /// Margin for the reply's own trip and the BLE fetch (firmware `deadlineMs`).
  static let companionCLIMargin: Duration = .milliseconds(1500)

  static func firmwareRoundTripTimeout(from sentInfo: MessageSentInfo) -> Duration {
    .milliseconds(Int(sentInfo.suggestedTimeoutMs) * firmwareRoundTripMultiplier)
  }

  static func loginTimeout(for sentInfo: MessageSentInfo, pathLength: UInt8) -> Duration {
    min(max(firmwareRoundTripTimeout(from: sentInfo), LoginTimeoutConfig.timeout(forPathLength: pathLength)), loginMaximum)
  }

  static func cliTimeout(for sentInfo: MessageSentInfo, requestedTimeout: Duration) -> Duration {
    min(max(requestedTimeout, firmwareRoundTripTimeout(from: sentInfo)), cliMaximum)
  }

  /// Wait for another companion's CLI reply, matching the firmware's page
  /// (`radmin::deadlineMs(est, Kind::Cli)`): the radio's estimate plus a quarter, the
  /// reply delay and a margin, clamped to 3 to 40 s. A longer requested timeout wins
  /// up to the ceiling.
  static func companionCLITimeout(for sentInfo: MessageSentInfo, requestedTimeout: Duration) -> Duration {
    let estimate = Int(sentInfo.suggestedTimeoutMs)
    let firmware = Duration.milliseconds(estimate + estimate / 4) + companionCLIReplyDelay + companionCLIMargin
    let clamped = min(max(firmware, companionCLIMinimum), companionCLIMaximum)
    return min(max(requestedTimeout, clamped), companionCLIMaximum)
  }
}
