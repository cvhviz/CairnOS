import Observation

/// Packets on the air, as counters the activity LEDs flash on: one for every packet the radio
/// hears (its RX log), one for every command that makes it transmit, as the session writes it
/// (`MeshCoreSessionProtocol.transmissions()`, `.written`).
@Observable
@MainActor
final class RadioActivity {
  private(set) var receivedCount = 0
  private(set) var sentCount = 0

  func recordReceived() {
    receivedCount &+= 1
  }

  func recordSent() {
    sentCount &+= 1
  }

  #if DEBUG
    private var isRunningDemo = false

    /// Screenshot runs (`-uiTestRadioActivityDemo YES`): a packet heard every 0.8 s and one sent
    /// every third, so the LED can be seen flashing without a radio on the air. Once per launch.
    func startDemo() {
      guard !isRunningDemo else { return }
      isRunningDemo = true
      Task { [weak self] in
        var tick = 0
        while let self {
          try? await Task.sleep(for: .milliseconds(800))
          tick += 1
          if tick % 3 == 0 { recordSent() } else { recordReceived() }
        }
      }
    }
  #endif
}
