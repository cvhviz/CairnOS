import Foundation
import MeshCore
import os

// MARK: - Settings Service

/// Service for managing device settings via MeshCore session.
/// Handles radio configuration, node settings, Bluetooth settings, and device info.
public actor SettingsService {
  private let session: any ConfigurationSessionOps
  let logger = PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "SettingsService")

  // Event stream subscriber. The subscription ID lets a replaced subscriber's
  // onTermination distinguish itself from the subscriber that replaced it.
  var eventContinuation: AsyncStream<SettingsEvent>.Continuation?
  private var eventSubscriptionID: UUID?

  public init(session: any ConfigurationSessionOps) {
    self.session = session
  }

  /// Stream of settings change events.
  /// Only one active subscriber is supported. Subsequent calls replace the previous subscriber.
  public func events() -> AsyncStream<SettingsEvent> {
    // Register synchronously so events yielded right after this call
    // returns are not dropped behind a registration Task.
    let (stream, continuation) = AsyncStream.makeStream(of: SettingsEvent.self)
    let subscriptionID = UUID()
    setContinuation(continuation, subscriptionID: subscriptionID)
    continuation.onTermination = { @Sendable _ in
      Task { await self.clearContinuation(subscriptionID: subscriptionID) }
    }
    return stream
  }

  private func setContinuation(
    _ continuation: AsyncStream<SettingsEvent>.Continuation,
    subscriptionID: UUID
  ) {
    if eventContinuation != nil {
      logger.warning("Replacing existing SettingsService event stream subscriber")
    }
    eventContinuation?.finish()
    eventContinuation = continuation
    eventSubscriptionID = subscriptionID
  }

  /// Clears the continuation only while the terminating subscription is still
  /// current, so a replaced subscriber cannot disconnect its replacement.
  private func clearContinuation(subscriptionID: UUID) {
    guard eventSubscriptionID == subscriptionID else { return }
    eventContinuation = nil
    eventSubscriptionID = nil
  }

  // MARK: - Receive Gain

  /// The two receive-gain switches a companion keeps on its own command line (firmware v14+,
  /// MeshCore 1.18): the SX126x boosted RX gain (`radio.rxgain`) and the LNA of an external front
  /// end (`radio.fem.rxgain`: the Heltec V4.3, V4-R8 and T096's KCT8103L). The FEM switch reads nil
  /// on a radio without a front end it can switch, and both read nil on older firmware. The boost
  /// switch reads on every v14 radio, also one whose chip has no boosted mode (an SX1276, an
  /// STM32WL): that shows only when it is set (``SettingsServiceError/unsupportedSetting``).
  public func readReceiveGain() async -> ReceiveGain {
    ReceiveGain(
      boostedRX: await readSwitch("radio.rxgain"),
      femLNA: await readSwitch("radio.fem.rxgain")
    )
  }

  /// Turns the radio's boosted RX gain on or off; it is applied at once and saved on the radio.
  public func setBoostedRX(_ isOn: Bool) async throws {
    try await setSwitch("radio.rxgain", isOn: isOn)
  }

  /// Turns the front end's LNA on or off; it is applied at once and saved on the radio.
  public func setFEMLNA(_ isOn: Bool) async throws {
    try await setSwitch("radio.fem.rxgain", isOn: isOn)
  }

  /// On, off, or nil when the reply says the radio has no such switch (or isn't one).
  static func switchState(fromReply reply: String) -> Bool? {
    switch CLIResponse.parse(reply) {
    case .ok, .error, .unknownCommand:
      return nil
    default:
      break
    }
    var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("> ") { text = String(text.dropFirst(2)) }
    switch text.lowercased() {
    case "on", "1": return true
    case "off", "0": return false
    default: return nil
    }
  }

  private func readSwitch(_ key: String) async -> Bool? {
    do {
      return Self.switchState(fromReply: try await session.runCLICommand("get \(key)"))
    } catch {
      logger.debug("Receive gain: 'get \(key)' not available: \(error.localizedDescription)")
      return nil
    }
  }

  /// - Throws: ``SettingsServiceError/unsupportedSetting`` when the radio's hardware can't do it.
  ///   The firmware saves the value before it asks the chip (CommonRadioPrefs), so the value is set
  ///   back first: the radio then keeps reading as it did.
  private func setSwitch(_ key: String, isOn: Bool) async throws {
    let reply: String
    do {
      reply = try await session.runCLICommand("set \(key) \(isOn ? "on" : "off")")
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
    switch CLIResponse.parse(reply) {
    case .ok:
      return
    case let .error(text) where text.lowercased().contains("unsupported"):
      logger.info("Receive gain: '\(key)' unsupported by this radio's hardware; setting it back")
      _ = try? await session.runCLICommand("set \(key) \(isOn ? "off" : "on")")
      throw SettingsServiceError.unsupportedSetting
    default:
      logger.warning("Receive gain: 'set \(key)' refused: \(reply)")
      throw SettingsServiceError.invalidResponse
    }
  }

  // MARK: - Radio Settings

  /// Apply a radio preset to the device
  public func applyRadioPreset(_ preset: RadioPreset) async throws {
    try await setRadioParams(
      frequencyKHz: preset.frequencyKHz,
      bandwidthKHz: preset.bandwidthHz,
      spreadingFactor: preset.spreadingFactor,
      codingRate: preset.codingRate
    )
    try await applyPresetPathHashIfNeeded(preset)
  }

  func applyPresetPathHashIfNeeded(_ preset: RadioPreset) async throws {
    guard let mode = preset.pathHashMode else { return }
    let capabilities = try await queryDevice()
    guard capabilities.supportsPathHashMode else { return }
    try await setPathHashMode(mode)
  }

  /// Set radio parameters manually.
  ///
  /// Both numeric parameters are integer values that get divided by 1000 before being
  /// forwarded to `session.setRadio`. Pass values in the same scaled-integer form that
  /// `RadioPreset.frequencyKHz` and `RadioPreset.bandwidthHz` use:
  /// - `frequencyKHz`: frequency expressed in kHz (e.g. `869618` → 869.618 MHz on the wire)
  /// - `bandwidthKHz`: bandwidth expressed in Hz (e.g. `62500` → 62.5 kHz on the wire)
  ///
  /// The `bandwidthKHz` name is preserved for source compatibility despite the value
  /// actually being in Hz; do not pass `Int(62.5)` here.
  public func setRadioParams(
    frequencyKHz: UInt32,
    bandwidthKHz: UInt32,
    spreadingFactor: UInt8,
    codingRate: UInt8,
    clientRepeat: Bool? = nil
  ) async throws {
    do {
      try await session.setRadio(
        frequency: Double(frequencyKHz) / 1000.0,
        bandwidth: Double(bandwidthKHz) / 1000.0,
        spreadingFactor: spreadingFactor,
        codingRate: codingRate,
        clientRepeat: clientRepeat
      )
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    } catch let error as MeshTransportError {
      throw SettingsServiceError(transportError: error)
    }
  }

  /// Set transmit power
  public func setTxPower(_ power: Int8) async throws {
    do {
      try await session.setTxPower(power)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    } catch let error as MeshTransportError {
      throw SettingsServiceError(transportError: error)
    }
  }

  /// Read the device clock.
  public func getTime() async throws -> Date {
    do {
      return try await session.getTime()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Set the device clock. The firmware rejects moving the clock backwards.
  public func setTime(_ date: Date) async throws {
    do {
      try await session.setTime(date)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// The radio clock's zone (its `tz.offset`), in minutes from UTC; nil when the firmware has no such
  /// setting or the link failed.
  public func getTimeZoneOffsetMinutes() async -> Int? {
    do {
      return DeviceTimeZone.parseReply(try await session.runCLICommand("get tz.offset"))
    } catch {
      logger.debug("Clock zone: 'get tz.offset' not available: \(error.localizedDescription)")
      return nil
    }
  }

  /// Set the radio clock's zone, in minutes from UTC (the firmware keeps quarter-hour steps from
  /// -12:00 to +14:00). Its screen shows the local time by it from the next repaint.
  public func setTimeZoneOffsetMinutes(_ minutes: Int) async throws {
    let reply: String
    do {
      reply = try await session.runCLICommand("set tz.offset \(DeviceTimeZone.commandArgument(minutes: minutes))")
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
    guard case .ok = CLIResponse.parse(reply) else {
      logger.warning("Clock zone: 'set tz.offset' refused: \(reply)")
      throw SettingsServiceError.invalidResponse
    }
  }

  // MARK: - Node Settings

  /// Set the publicly visible node name
  public func setNodeName(_ name: String) async throws {
    let truncated = name.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
    do {
      try await session.setName(truncated)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Set node location (latitude/longitude in degrees)
  public func setLocation(latitude: Double, longitude: Double) async throws {
    do {
      try await session.setCoordinates(latitude: latitude, longitude: longitude)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  // MARK: - Bluetooth Settings

  /// Set BLE PIN (0 = disabled/random, 100000-999999 = fixed PIN)
  public func setBlePin(_ pin: UInt32) async throws {
    do {
      try await session.setDevicePin(pin)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// The Bluetooth PIN the radio holds now, which its own settings can change as well.
  public func readBlePin() async throws -> UInt32 {
    do {
      return try await session.queryDevice().blePin
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  // MARK: - Other Settings

  /// Set other device parameters (contacts, telemetry, location policy)
  public func setOtherParams(
    autoAddContacts: Bool,
    telemetryModes: TelemetryModes,
    advertLocationPolicy: AdvertLocationPolicy,
    multiAcks: UInt8
  ) async throws {
    try await setOtherParams(
      autoAddContacts: autoAddContacts,
      telemetryModes: telemetryModes,
      advertLocationPolicyRaw: advertLocationPolicy.rawValue,
      multiAcks: multiAcks
    )
  }

  /// Set other device parameters, taking the advertisement location policy as a raw byte.
  ///
  /// Used by config import so a policy value not modeled by ``AdvertLocationPolicy`` (e.g. from
  /// newer firmware) is forwarded to the device verbatim instead of being coerced.
  public func setOtherParams(
    autoAddContacts: Bool,
    telemetryModes: TelemetryModes,
    advertLocationPolicyRaw: UInt8,
    multiAcks: UInt8
  ) async throws {
    do {
      try await session.setOtherParams(
        manualAddContacts: !autoAddContacts,
        telemetryModeEnvironment: telemetryModes.environment,
        telemetryModeLocation: telemetryModes.location,
        telemetryModeBase: telemetryModes.base,
        advertisementLocationPolicy: advertLocationPolicyRaw,
        multiAcks: multiAcks
      )
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  // MARK: - Factory Reset

  /// Perform factory reset on device
  public func factoryReset() async throws {
    do {
      try await session.factoryReset()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Reboot the device
  public func reboot() async throws {
    do {
      try await session.reboot()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  // MARK: - Device Info

  /// Fetch battery and storage information from device
  /// - Returns: BatteryInfo with current values
  /// - Throws: SettingsServiceError if not connected or communication fails
  public func getBattery() async throws -> BatteryInfo {
    do {
      return try await session.getBattery()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Query device capabilities
  public func queryDevice() async throws -> DeviceCapabilities {
    do {
      return try await session.queryDevice()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    } catch let error as MeshTransportError {
      throw SettingsServiceError(transportError: error)
    }
  }

  /// Get self info by sending appStart
  public func getSelfInfo() async throws -> MeshCore.SelfInfo {
    do {
      return try await session.sendAppStart()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    } catch let error as MeshTransportError {
      throw SettingsServiceError(transportError: error)
    }
  }

  // MARK: - Auto-Add Config

  /// Get auto-add configuration from device
  public func getAutoAddConfig() async throws -> MeshCore.AutoAddConfig {
    do {
      return try await session.getAutoAddConfig()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Refresh auto-add config from device (for initial load)
  /// Fetches current value and triggers callback to update connected device
  public func refreshAutoAddConfig() async throws {
    let config = try await getAutoAddConfig()
    eventContinuation?.yield(.autoAddConfigUpdated(config))
  }

  // MARK: - Repeat Frequency Ranges

  /// Get allowed repeat frequency ranges from device
  private func getRepeatFreq() async throws -> [MeshCore.FrequencyRange] {
    do {
      return try await session.getRepeatFreq()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Refresh repeat frequency ranges from device and notify observers
  public func refreshRepeatFreqRanges() async throws {
    let ranges = try await getRepeatFreq()
    eventContinuation?.yield(.allowedRepeatFreqUpdated(ranges))
  }

  /// Refresh device info from the device and notify observers.
  /// Use this instead of `setLocationVerified` when the device already has correct coordinates (e.g. from its own GPS).
  public func refreshDeviceInfo() async throws {
    let selfInfo = try await getSelfInfo()
    eventContinuation?.yield(.deviceUpdated(selfInfo, appliedRadioPresetID: nil))
  }

  /// Set auto-add configuration on device
  public func setAutoAddConfig(_ config: MeshCore.AutoAddConfig) async throws {
    do {
      try await session.setAutoAddConfig(config)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Set auto-add configuration with verification
  public func setAutoAddConfigVerified(_ config: MeshCore.AutoAddConfig) async throws -> MeshCore.AutoAddConfig {
    try await setAutoAddConfig(config)

    let actualConfig = try await getAutoAddConfig()

    guard actualConfig == config else {
      throw SettingsServiceError.verificationFailed(
        expected: "bitmask=\(config.bitmask), maxHops=\(config.maxHops)",
        actual: "bitmask=\(actualConfig.bitmask), maxHops=\(actualConfig.maxHops)"
      )
    }

    eventContinuation?.yield(.autoAddConfigUpdated(actualConfig))
    return actualConfig
  }

  // MARK: - Path Hash Mode

  /// Sets the path hash mode on the device.
  ///
  /// - Parameter mode: Hash mode (0=1-byte, 1=2-byte, 2=3-byte hashes).
  public func setPathHashMode(_ mode: UInt8) async throws {
    do {
      try await session.setPathHashMode(mode)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    } catch let error as MeshTransportError {
      throw SettingsServiceError(transportError: error)
    }
  }

  /// Sets the path hash mode with verification via queryDevice.
  ///
  /// - Parameter mode: Hash mode (0=1-byte, 1=2-byte, 2=3-byte hashes).
  /// - Returns: The verified mode value from the device.
  public func setPathHashModeVerified(_ mode: UInt8) async throws -> UInt8 {
    try await setPathHashMode(mode)

    let capabilities = try await queryDevice()
    guard capabilities.pathHashMode == mode else {
      throw SettingsServiceError.verificationFailed(
        expected: "pathHashMode=\(mode)",
        actual: "pathHashMode=\(capabilities.pathHashMode)"
      )
    }

    eventContinuation?.yield(.pathHashModeUpdated(mode))
    return mode
  }

  // MARK: - Tuning

  /// Reads the radio's tuning: its RX delay base and airtime factor.
  ///
  /// Older firmware rejects the read and surfaces ``SettingsServiceError/sessionError(_:)``
  /// with `MeshCoreError.deviceError`; ``RadioTuning/isUnsupported(_:)`` tells that apart.
  public func getRadioTuning() async throws -> RadioTuning {
    do {
      let params = try await session.getTuningParams()
      return RadioTuning(rxDelayBase: params.rxDelayBase, airtimeFactor: params.airtimeFactor)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Sets the radio's tuning, each value sent to a thousandth as the firmware keeps it.
  public func setRadioTuning(_ tuning: RadioTuning) async throws {
    do {
      try await session.setTuning(rxDelay: tuning.rxDelayWire, af: tuning.airtimeFactorWire)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Sets the radio's tuning and reads it back, so a value the firmware didn't keep is caught.
  public func setRadioTuningVerified(_ tuning: RadioTuning) async throws -> RadioTuning {
    try await setRadioTuning(tuning)
    let stored = try await getRadioTuning()
    guard stored.rxDelayWire == tuning.rxDelayWire, stored.airtimeFactorWire == tuning.airtimeFactorWire else {
      throw SettingsServiceError.verificationFailed(
        expected: "rxdelay=\(tuning.rxDelayBase), af=\(tuning.airtimeFactor)",
        actual: "rxdelay=\(stored.rxDelayBase), af=\(stored.airtimeFactor)"
      )
    }
    return stored
  }

  // MARK: - Default Flood Scope

  /// Fetches the device's persisted default flood scope.
  ///
  /// Requires firmware v11+; older firmware rejects the opcode and surfaces
  /// ``SettingsServiceError/sessionError(_:)`` with `MeshCoreError.deviceError`.
  ///
  /// - Returns: The persisted scope name, or `nil` when none is configured.
  public func getDefaultFloodScope() async throws -> String? {
    do {
      let scope = try await session.getDefaultFloodScope()
      let name = scope?.name
      eventContinuation?.yield(.defaultFloodScopeUpdated(name))
      return name
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Persists the device's default flood scope and verifies via a follow-up read.
  ///
  /// Passing `nil` for `name` clears the persisted scope. Non-nil names are sent as
  /// ``MeshCore/FloodScope/region(_:)`` — firmware derives the key and stores both.
  /// Names are truncated to ``ProtocolLimits/maxDefaultFloodScopeNameBytes`` UTF-8 bytes
  /// before both key derivation and send, so the stored display and derived scope key
  /// agree on the same byte sequence.
  ///
  /// - Parameter name: Region name to persist, or `nil` to clear.
  /// - Returns: The verified name read back from the device.
  public func setDefaultFloodScopeVerified(name: String?) async throws -> String? {
    let expected: String? = (name?.isEmpty == false)
      ? name?.utf8Prefix(maxBytes: ProtocolLimits.maxDefaultFloodScopeNameBytes)
      : nil
    do {
      if let expected {
        try await session.setDefaultFloodScope(name: expected, scope: .region(expected))
      } else {
        try await session.setDefaultFloodScope(name: "", scope: .disabled)
      }
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }

    let actual = try await getDefaultFloodScope()
    guard actual == expected else {
      throw SettingsServiceError.verificationFailed(
        expected: expected ?? "(cleared)",
        actual: actual ?? "(cleared)"
      )
    }
    return actual
  }

  // MARK: - Stats

  /// Get core statistics
  public func getStatsCore() async throws -> CoreStats {
    do {
      return try await session.getStatsCore()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Get radio statistics
  public func getStatsRadio() async throws -> RadioStats {
    do {
      return try await session.getStatsRadio()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Get packet statistics
  public func getStatsPackets() async throws -> PacketStats {
    do {
      return try await session.getStatsPackets()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  // MARK: - Custom Variables

  /// Get custom variables from device
  public func getCustomVars() async throws -> [String: String] {
    do {
      return try await session.getCustomVars()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  public func getDeviceGPSState() async throws -> DeviceGPSState {
    let vars = try await getCustomVars()
    return Self.deviceGPSState(from: vars)
  }

  /// Set a custom variable on device
  public func setCustomVar(key: String, value: String) async throws {
    do {
      try await session.setCustomVar(key: key, value: value)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  public func setDeviceGPSEnabledVerified(_ enabled: Bool) async throws -> DeviceGPSState {
    try await setCustomVar(key: "gps", value: enabled ? "1" : "0")

    let state = try await getDeviceGPSState()
    guard state.isSupported else {
      throw SettingsServiceError.deviceGPSVerificationFailed(
        expectedEnabled: enabled,
        actualEnabled: false
      )
    }
    guard state.isEnabled == enabled else {
      throw SettingsServiceError.deviceGPSVerificationFailed(
        expectedEnabled: enabled,
        actualEnabled: state.isEnabled
      )
    }

    try await refreshDeviceInfo()
    return state
  }

  /// Switches the receiver between Eco and always-on. Firmware without Eco (no `gps_mode` var)
  /// rejects the write.
  public func setDeviceGPSEcoVerified(_ eco: Bool) async throws -> DeviceGPSState {
    try await setCustomVar(key: "gps_mode", value: eco ? "2" : "1")

    let state = try await getDeviceGPSState()
    guard state.isEnabled, state.isEco == eco else {
      throw SettingsServiceError.deviceGPSVerificationFailed(
        expectedEnabled: true,
        actualEnabled: state.isEnabled
      )
    }

    try await refreshDeviceInfo()
    return state
  }

  // MARK: - Private Key Management

  /// Export private key from device
  public func exportPrivateKey() async throws -> Data {
    do {
      return try await session.exportPrivateKey()
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  /// Import private key to device
  public func importPrivateKey(_ key: Data) async throws {
    do {
      try await session.importPrivateKey(key)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  // MARK: - Signing

  /// Sign data using device's private key
  public func sign(_ data: Data) async throws -> Data {
    do {
      return try await session.sign(data)
    } catch let error as MeshCoreError {
      throw SettingsServiceError.sessionError(error)
    }
  }

  static func deviceGPSState(from vars: [String: String]) -> DeviceGPSState {
    guard let value = vars["gps"] else {
      return DeviceGPSState(isSupported: false, isEnabled: false)
    }
    // "gps" reads 1 in Eco too; "gps_mode" (0 off, 1 on, 2 Eco) only exists on firmware with Eco.
    let details = vars["gps_info"].flatMap(RadioGPSDetails.init(customVar:))
    if let mode = vars["gps_mode"] {
      return DeviceGPSState(isSupported: true, isEnabled: mode != "0", isEco: mode == "2", details: details)
    }
    return DeviceGPSState(isSupported: true, isEnabled: value == "1", details: details)
  }
}
