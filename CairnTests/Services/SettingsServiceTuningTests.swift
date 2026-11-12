@testable import CairnServices
import Testing

@Suite("SettingsService radio tuning")
struct SettingsServiceTuningTests {
  @Test
  func `tuning is sent in thousandths and read back`() async throws {
    let mock = MockConfigurationSession()
    let service = SettingsService(session: mock)

    let stored = try await service.setRadioTuningVerified(RadioTuning(rxDelayBase: 2.5, airtimeFactor: 1.5))

    let wire = await mock.tuning
    #expect(wire.rxDelay == 2500)
    #expect(wire.af == 1500)
    #expect(stored == RadioTuning(rxDelayBase: 2.5, airtimeFactor: 1.5))
  }

  @Test
  func `the firmware defaults read back as RX delay 0 and airtime factor 1`() async throws {
    let service = SettingsService(session: MockConfigurationSession())
    #expect(try await service.getRadioTuning() == .firmwareDefault)
  }

  @Test
  func `a device error reads as unsupported, a timeout does not`() {
    #expect(RadioTuning.isUnsupported(SettingsServiceError.sessionError(.deviceError(code: 1))))
    #expect(!RadioTuning.isUnsupported(SettingsServiceError.sessionError(.timeout)))
  }
}
