import Foundation
@testable import MeshCore
import Testing

/// ``MeshCoreSession/start(reconnectingAttempt:disconnectTransportOnFailure:appStartTimeout:)``:
/// the opening APP_START waits the session's default unless told to wait longer, as a first WiFi
/// connect does while the radio asks its owner to allow the phone. Time is the session's test clock.
@Suite("APP_START wait")
struct AppStartWaitTests {
  private func makeSession() -> (MeshCoreSession, StockTestTransport, StockTestClock) {
    let transport = StockTestTransport()
    let clock = StockTestClock()
    let session = MeshCoreSession(
      transport: transport,
      configuration: SessionConfiguration(defaultTimeout: 5, clientIdentifier: "MeshCore-Tests"),
      clock: clock
    )
    return (session, transport, clock)
  }

  private func waitForAppStart(_ transport: StockTestTransport) async throws {
    try await waitUntil("APP_START should be sent") {
      await !transport.sent(code: CommandCode.appStart.rawValue).isEmpty
    }
  }

  @Test
  func `a longer wait outlasts the default and takes the radio's late answer`() async throws {
    let (session, transport, clock) = makeSession()
    let start = Task { try await session.start(appStartTimeout: 60) }
    try await waitForAppStart(transport)

    // Well past the 5 s default, as while the radio's owner reads its prompt.
    clock.advance(by: .seconds(30))
    try await Task.sleep(for: .milliseconds(50))
    await transport.receive(StockFirmwareFrames.selfInfo)

    try await start.value
    #expect(await session.currentSelfInfo != nil)
  }

  @Test
  func `without a longer wait the default still times out`() async throws {
    let (session, transport, clock) = makeSession()
    let start = Task { try await session.start() }
    try await waitForAppStart(transport)

    clock.advance(by: .seconds(6))

    await #expect(throws: MeshCoreError.self) { try await start.value }
  }
}
