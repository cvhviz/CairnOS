import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "NodeSettingsViewModel")

/// Shared logic for repeater and room settings view models.
/// Owns CLI transport, device info, radio, identity, contact info,
/// security, and device action methods.
@Observable
@MainActor
final class NodeSettingsViewModel {
  // MARK: - Session

  var session: RemoteNodeSessionDTO?

  // MARK: - Device Info

  var firmwareVersion: String?
  /// The board's bootloader (`get bootloader.ver`), nRF52 nodes only: "0.9.2-OTAFIX2.3-BP1.4".
  /// Nil until read, and for boards that don't have one to report (ESP32).
  var bootloaderVersion: String?
  private var bootloaderVersionRead = false
  /// The board's own name (`board`: "Heltec T096"), read with an nRF52 bootloader, for the
  /// Bluetooth firmware update.
  var boardName: String?

  /// The Bluetooth update a logged-in admin can start on this repeater: an nRF52 board whose
  /// release image the app can pick.
  var nordicUpdateTarget: NordicFirmwareTarget? {
    guard bootloaderVersion != nil, let boardName, session?.role == .repeater,
          session?.permissionLevel == .admin else { return nil }
    return NordicFirmwareTarget(boardName: boardName, role: .repeater)
  }

  /// The bootloader starts new firmware without resetting the chip (stock, or OTAFIX before 2.0),
  /// so after an over-the-air update the node may need its reset button pressed.
  var bootloaderNeedsManualRestart: Bool {
    bootloaderVersion.map(Self.bootloaderNeedsManualRestart) ?? false
  }

  /// "0.9.0-2-g836c8dc-dirty" (stock) or "0.9.2-OTAFIX1.1" need a reset after an update;
  /// "0.9.2-OTAFIX2.3-BP1.4" doesn't.
  nonisolated static func bootloaderNeedsManualRestart(_ version: String) -> Bool {
    guard let range = version.range(of: "OTAFIX", options: .caseInsensitive) else { return true }
    let major = version[range.upperBound...].prefix { $0.isNumber }
    guard let number = Int(major) else { return true }
    return number < 2
  }

  /// The version in a `get bootloader.ver` reply ("> 0.9.0-2-g836c8dc-dirty"); nil for "unknown"
  /// and for a board or firmware that has no answer ("Error: unsupported", an unknown command).
  nonisolated static func bootloaderVersion(fromReply reply: String) -> String? {
    var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix(">") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
    guard let first = text.first, first.isNumber else { return nil }
    return text.split(whereSeparator: \.isNewline).first.map(String.init)
  }

  private var deviceTimeUTC: String?
  /// Positive means the node's clock is ahead of `now`.
  var clockDrift: TimeInterval?
  /// Reference clock used when measuring `clockDrift`.
  var now: () -> Date = Date.init
  var isLoadingDeviceInfo = false
  var deviceInfoError = false
  var deviceInfoLoaded: Bool {
    deviceTimeUTC != nil
  }

  var deviceTime: String? {
    guard let utcString = deviceTimeUTC else { return nil }
    return Self.convertUTCToLocal(utcString)
  }

  static func convertUTCToLocal(_ utcString: String) -> String {
    guard let date = NodeSettingsResponseParser.utcDate(fromClockResponse: utcString) else {
      return utcString
    }

    let timeString = date.formatted(date: .omitted, time: .shortened)
    let dateString = date.formatted(.dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits))
    return "\(timeString) - \(dateString)"
  }

  func applyDeviceTime(_ raw: String) {
    if let text = NodeSettingsResponseParser.clockResponseText(in: raw) {
      deviceTimeUTC = text
      clockDrift = NodeSettingsResponseParser.clockDrift(fromClockResponse: text, relativeTo: now())
    }
  }

  // MARK: - Identity

  var name: String?
  var latitude: Double?
  var longitude: Double?
  private(set) var originalName: String?
  private(set) var originalLatitude: Double?
  private(set) var originalLongitude: Double?
  var isLoadingIdentity = false
  var identityError = false
  /// Latest GPS fix from this node's telemetry. When it differs from the configured location the
  /// identity section offers to apply it, since telemetry reports live GPS while `get lat`/`get lon`
  /// return the saved setting (#386).
  var telemetryFix: NodeLocationFix?

  /// Whether the telemetry fix is worth offering: present and more than about a metre away.
  var telemetryFixDiffersFromSettings: Bool {
    guard let fix = telemetryFix else { return false }
    guard let latitude, let longitude else { return true }
    return abs(fix.latitude - latitude) > 0.00001 || abs(fix.longitude - longitude) > 0.00001
  }

  var identityLoaded: Bool {
    originalLatitude != nil || originalLongitude != nil
  }

  var identitySettingsModified: Bool {
    (name != nil && name != originalName) ||
      (latitude != nil && latitude != originalLatitude) ||
      (longitude != nil && longitude != originalLongitude)
  }

  var nameError: String?
  var latitudeError: String?
  var longitudeError: String?

  // MARK: - Radio

  var frequency: Double?
  var bandwidth: Double?
  var spreadingFactor: Int?
  var codingRate: Int?
  /// Transmit power in dBm; read and set on its own (`get tx` / `set tx`), apart from `set radio`.
  /// The radio chip's setting: a board with a PA radiates more (``txAntennaPower``).
  var txPower: Int?
  private(set) var originalTxPower: Int?
  /// The highest setting the node takes (`txm=` in `get cairn.cfg`); nil from stock or older firmware.
  private(set) var txPowerMax: Int?
  /// The power at the antenna for ``originalTxPower`` (`txa=`); nil when unknown, and while a newly
  /// applied setting's figure is being read back.
  private(set) var txAntennaPower: Int?
  /// The power at the antenna at ``txPowerMax`` (`txa=`); nil when unknown.
  private(set) var txAntennaMax: Int?

  /// The settings the TX controls offer: -9 up to the node's maximum (22 when it reports none, or
  /// what a refused `set tx` named). Never stretched to a stored value outside it (an older
  /// firmware's unchecked `set tx 30`, which its radio never applied): the controls show that value
  /// on its own, so the app can't store it again.
  var txPowerRange: ClosedRange<Int> {
    CairnNodeConfig.txPowerRange(maximum: txPowerMax)
  }

  /// The node reported a PA after its radio (its antenna figures differ from its settings).
  var txIsAmplified: Bool {
    if let txAntennaMax, let txPowerMax, txAntennaMax != txPowerMax { return true }
    if let txAntennaPower, let originalTxPower, txAntennaPower != originalTxPower { return true }
    return false
  }

  /// The node's antenna figures match its settings (a board without a PA), so the setting can be
  /// shown as plain TX power. False when it reports none (stock or older firmware) or has a PA.
  var txSettingIsAntennaPower: Bool {
    (txAntennaPower != nil || txAntennaMax != nil) && !txIsAmplified
  }
  /// The node's current radio parameters, for the "old → new" confirmation and Revert.
  private(set) var originalFrequency: Double?
  private(set) var originalBandwidth: Double?
  private(set) var originalSpreadingFactor: Int?
  private(set) var originalCodingRate: Int?
  var isLoadingRadio = false
  var radioError = false
  var radioLoaded: Bool {
    frequency != nil
  }

  /// What `set radio` would carry that the node can't take (`RadioSettingsValidator`); shown under
  /// the fields, and nothing is sent while there is any.
  var radioValidation = RadioSettingsValidator.Errors()

  /// A radio change waiting for the user's confirmation: the lines of what changes, and whether
  /// the node is rebooted after. The view shows it as a destructive dialog.
  struct PendingRadioChange: Identifiable, Equatable {
    let id = UUID()
    let lines: [String]
    let rebootAfter: Bool
  }

  var pendingRadioChange: PendingRadioChange?

  /// The last success was a radio change, which takes effect on restart: the alert offers Reboot Now.
  var successOffersReboot = false

  /// The node's radio settings as they stand, for the confirmation's "old" column and Revert.
  var originalRadioValues: RadioSettingsValues {
    RadioSettingsValues(
      frequency: originalFrequency, bandwidth: originalBandwidth,
      spreadingFactor: originalSpreadingFactor, codingRate: originalCodingRate, txPower: originalTxPower
    )
  }

  var editedRadioValues: RadioSettingsValues {
    RadioSettingsValues(
      frequency: frequency, bandwidth: bandwidth,
      spreadingFactor: spreadingFactor, codingRate: codingRate, txPower: txPower
    )
  }

  var radioSettingsModified = false
  /// TX power changed: applied with `set tx` alone, without the radio restart `set radio` needs.
  var txPowerModified = false

  // MARK: - Contact Info

  /// Firmware limit on the `set owner.info` value length.
  static let ownerInfoMaxLength = 119

  var ownerInfo: String?
  private(set) var originalOwnerInfo: String?
  var isLoadingContactInfo = false
  var contactInfoError = false
  var contactInfoLoaded: Bool {
    originalOwnerInfo != nil
  }

  /// Gated on `contactInfoLoaded` so the text field's empty pre-fetch value can't
  /// enable Apply and wipe the node's owner info before the current value arrives.
  var contactInfoSettingsModified: Bool {
    contactInfoLoaded && ownerInfo != originalOwnerInfo
  }

  var ownerInfoCharCount: Int {
    (ownerInfo ?? "").count
  }

  // MARK: - Field Results

  /// How each field fared in the last multi-field Apply, by the setting's CLI key ("name", "lat",
  /// "lon", "repeat", "advert.interval"…): a failure names the field under it, a success ticks it.
  var fieldResults: [String: NodeFieldResult] = [:]

  /// Records a `set` reply for `key`: OK applies, anything else is the node's refusal in its words.
  @discardableResult
  func recordFieldResult(_ key: String, response: String) -> Bool {
    if case .ok = CLIResponse.parse(response) {
      fieldResults[key] = .applied
      return true
    }
    let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
    fieldResults[key] = .failed(text.isEmpty ? L10n.RemoteNodes.RemoteNodes.Settings.someSettingsFailedToApply : text)
    return false
  }

  func clearFieldResults(_ keys: [String]) {
    for key in keys { fieldResults[key] = nil }
  }

  // MARK: - Quiet Node

  /// Live, or sent a reboot or power-off and quiet since (`NodeQuietState`): the dashboard holds
  /// its request tiles and offers a reconnect.
  var quietState: NodeQuietState = .live

  /// Marks the session disconnected in the store when the node goes quiet; the host wires it to
  /// `RemoteNodeService.disconnect(sessionID:)`.
  var onSessionQuiet: ((UUID) async -> Void)?

  /// The node was told to power off (the Controls page): quiet until someone turns it on.
  func markPoweredOff() {
    quietState = .poweredOff(since: now())
    if let session { Task { await onSessionQuiet?(session.id) } }
  }

  /// A fresh login got through: the node is live again.
  func markLive() {
    quietState = .live
  }

  var isOwnerInfoTooLong: Bool {
    ownerInfoCharCount > Self.ownerInfoMaxLength
  }

  // MARK: - Security

  var newPassword: String = ""
  var confirmPassword: String = ""

  // MARK: - Expansion State

  var isDeviceInfoExpanded = false
  var isRadioExpanded = false
  var isIdentityExpanded = false
  var isContactInfoExpanded = false
  var isSecurityExpanded = false

  // MARK: - Global State

  var isApplying = false
  var isRebooting = false
  var errorMessage: String?
  var successMessage: String?
  var showSuccessAlert = false
  var identityApplySuccess = false
  var contactInfoApplySuccess = false
  var changePasswordSuccess = false
  var isSendingAdvert = false

  // MARK: - Service Closures

  private var sendCommandClosure: ((UUID, String, Duration) async throws -> String)?
  private var sendRawCommandClosure: ((UUID, String, Duration) async throws -> String)?

  /// Called when firmware version or node info needs pre-fetching.
  /// Repeater sets this to binary requestOwnerInfo; Room sets this to CLI `ver`.
  var onPreFetchNodeInfo: (() async -> Void)?

  // MARK: - Configuration

  func configure(
    session: RemoteNodeSessionDTO,
    sendCommand: @escaping (UUID, String, Duration) async throws -> String,
    sendRawCommand: @escaping (UUID, String, Duration) async throws -> String
  ) {
    self.session = session
    sendCommandClosure = sendCommand
    sendRawCommandClosure = sendRawCommand
    registerSharedLateRecovery()
  }

  /// Set name and owner info from an external source (e.g., binary protocol pre-fetch)
  func setNodeInfo(firmwareVersion: String?, name: String?, ownerInfo: String?) {
    if let firmwareVersion { self.firmwareVersion = firmwareVersion }
    if let name {
      self.name = name
      originalName = name
    }
    if let ownerInfo {
      self.ownerInfo = ownerInfo
      originalOwnerInfo = ownerInfo
    }
  }

  func cleanup() {
    sendCommandClosure = nil
    sendRawCommandClosure = nil
    onPreFetchNodeInfo = nil
    onSessionQuiet = nil
    unansweredQueries.removeAll()
    recentResponses.removeAll()
    lateRecoveryAppliers.removeAll()
  }

  // MARK: - CLI Transport

  func sendAndWait(
    _ command: String,
    timeout: Duration = RemoteOperationTimeoutPolicy.defaultCLITimeout,
    rawMatching: Bool = false
  ) async throws -> String {
    guard let session, let sendCmd = rawMatching ? sendRawCommandClosure : sendCommandClosure else {
      throw NodeSettingsError.noService
    }

    do {
      let response = try await sendCmd(session.id, command, timeout)
      logger.debug("Command '\(command)' response: \(response.prefix(50))")
      rememberSeenResponse(response)
      unansweredQueries.remove(command)
      return response
    } catch RemoteNodeError.timeout {
      if CLIResponse.isStructuredQuery(command) {
        unansweredQueries.insert(command)
      }
      throw RemoteNodeError.timeout
    }
  }

  // MARK: - Fetch Methods

  /// The node answered `get cairn.cfg` as something else (stock MeshCore): the single gets from now on.
  private(set) var cairnConfigUnsupported = false

  /// Where a node's unknown-setting answer to `get cairn.cfg` is kept between visits (`CairnNodeConfigSupport`).
  var cairnConfigSupportDefaults: UserDefaults = .standard

  /// A Cairn repeater's radio, TX power, name and location in one request (`CairnNodeConfig`) instead of
  /// five; nil from any other node or on a timeout, and the caller then reads them one by one. Filled in as
  /// `fetchRadioSettings` / `fetchIdentity` do, so a field being edited keeps its edit. A node that
  /// answered as stock MeshCore on an earlier visit isn't asked again until its firmware changes or a
  /// week has passed.
  func fetchCairnConfig() async -> CairnNodeConfig? {
    guard !cairnConfigUnsupported else { return nil }
    if let session, CairnNodeConfigSupport.isKnownUnsupported(
      publicKey: session.publicKey,
      firmwareVersion: firmwareVersion,
      defaults: cairnConfigSupportDefaults
    ) {
      cairnConfigUnsupported = true
      return nil
    }
    let response: String
    do {
      response = try await sendAndWait(CairnNodeConfig.query)
    } catch {
      logger.warning("Failed to get the combined settings: \(error)")
      return nil
    }
    guard let config = CairnNodeConfig.parse(response) else {
      cairnConfigUnsupported = true
      // Kept only for a clear "no such setting": a garbled or misattributed reply is asked again next visit.
      if let session, CairnNodeConfig.isUnsupportedReply(response) {
        CairnNodeConfigSupport.markUnsupported(
          publicKey: session.publicKey,
          firmwareVersion: firmwareVersion,
          defaults: cairnConfigSupportDefaults
        )
      }
      return nil
    }
    if let session {
      CairnNodeConfigSupport.markSupported(publicKey: session.publicKey, defaults: cairnConfigSupportDefaults)
    }
    applyCairnConfig(config)
    return config
  }

  func applyCairnConfig(_ c: CairnNodeConfig) {
    frequency = c.frequency
    bandwidth = c.bandwidth
    spreadingFactor = c.spreadingFactor
    codingRate = c.codingRate
    rememberRadioOriginals()
    radioSettingsModified = false
    txPower = c.txPower
    originalTxPower = c.txPower
    applyTxLimits(c)
    if originalName == nil || name == originalName { name = c.name }
    originalName = c.name
    if latitude == originalLatitude { latitude = c.latitude }
    originalLatitude = c.latitude
    if longitude == originalLongitude { longitude = c.longitude }
    originalLongitude = c.longitude
  }

  /// The radio parameters on screen become the node's known ones (after a read, or an applied set).
  private func rememberRadioOriginals() {
    originalFrequency = frequency
    originalBandwidth = bandwidth
    originalSpreadingFactor = spreadingFactor
    originalCodingRate = codingRate
  }

  /// Puts the radio fields back to the node's values, dropping unsent edits.
  func revertRadioSettings() {
    frequency = originalFrequency ?? frequency
    bandwidth = originalBandwidth ?? bandwidth
    spreadingFactor = originalSpreadingFactor ?? spreadingFactor
    codingRate = originalCodingRate ?? codingRate
    txPower = originalTxPower ?? txPower
    radioSettingsModified = false
    txPowerModified = false
    radioValidation = RadioSettingsValidator.Errors()
    pendingRadioChange = nil
  }

  /// Puts the name and location back to the node's values, dropping unsent edits.
  func revertIdentitySettings() {
    if let originalName { name = originalName }
    if let originalLatitude { latitude = originalLatitude }
    if let originalLongitude { longitude = originalLongitude }
    nameError = nil
    latitudeError = nil
    longitudeError = nil
    clearFieldResults(["name", "lat", "lon"])
  }

  func revertContactInfo() {
    if let originalOwnerInfo { ownerInfo = originalOwnerInfo }
  }

  private func applyTxLimits(_ c: CairnNodeConfig) {
    txPowerMax = c.txPowerMax
    txAntennaPower = c.txAntennaPower
    txAntennaMax = c.txAntennaMax
  }

  /// A setting just applied on a node that reports antenna figures: the old figure is dropped (the
  /// card reads "setting" meanwhile) and `get cairn.cfg` is asked again for the new one. Only the TX
  /// fields are taken from the reply, so nothing being edited is touched.
  private func refreshTxAntenna() {
    guard txAntennaPower != nil || txAntennaMax != nil else { return }
    txAntennaPower = nil
    Task { [weak self] in
      guard let self, let response = try? await self.sendAndWait(CairnNodeConfig.query),
            let config = CairnNodeConfig.parse(response), config.txPower == self.originalTxPower else { return }
      self.applyTxLimits(config)
    }
  }

  func fetchDeviceInfo() async {
    isLoadingDeviceInfo = true
    deviceInfoError = false

    if firmwareVersion == nil {
      await onPreFetchNodeInfo?()
    }

    if firmwareVersion == nil {
      do {
        let response = try await sendAndWait("ver")
        if case let .version(version) = CLIResponse.parse(response, forQuery: "ver") {
          firmwareVersion = version
        }
      } catch {
        if case RemoteNodeError.timeout = error {
          deviceInfoError = true
        }
        logger.warning("Failed to get firmware version: \(error)")
      }
    }

    // The bootloader, once a visit: only nRF52 boards answer with one, and it never changes while
    // the node runs. Not worth an error on the card when it doesn't come.
    if !bootloaderVersionRead {
      if let response = try? await sendAndWait("get bootloader.ver") {
        bootloaderVersionRead = true
        bootloaderVersion = Self.bootloaderVersion(fromReply: response)
      }
      // The board, only for an nRF52 board: the Bluetooth update picks its image by it.
      if bootloaderVersion != nil, boardName == nil, let reply = try? await sendAndWait("board") {
        let name = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        boardName = name.hasPrefix(">") ? String(name.dropFirst()).trimmingCharacters(in: .whitespaces) : name
      }
    }

    do {
      let response = try await sendAndWait("clock")
      if case let .deviceTime(time) = CLIResponse.parse(response, forQuery: "clock") {
        applyDeviceTime(time)
      }
    } catch {
      if case RemoteNodeError.timeout = error {
        deviceInfoError = true
      }
      logger.warning("Failed to get device time: \(error)")
    }

    isLoadingDeviceInfo = false
  }

  func fetchIdentity() async {
    isLoadingIdentity = true
    identityError = false
    var hadTimeout = false
    // A re-fetch can overlap typing. The node's value always becomes the new baseline, but a
    // field only shows it while it still holds the baseline from when the fetch began, so an
    // edit survives and stays pending. The name has no baseline until it loads (the field is
    // seeded from the session), so it is compared with what it showed at the start instead.
    let nameAtStart = name
    let baselineLatitude = originalLatitude
    let baselineLongitude = originalLongitude

    if originalName == nil {
      await onPreFetchNodeInfo?()
    }

    if originalName == nil {
      do {
        let response = try await sendAndWait("get name")
        if case let .name(n) = CLIResponse.parse(response, forQuery: "get name") {
          if name == nameAtStart { name = n }
          originalName = n
        }
      } catch {
        if case RemoteNodeError.timeout = error { hadTimeout = true }
        logger.warning("Failed to get name: \(error)")
      }
    }

    do {
      let response = try await sendAndWait("get lat")
      if case let .latitude(lat) = CLIResponse.parse(response, forQuery: "get lat") {
        if latitude == baselineLatitude { latitude = lat }
        originalLatitude = lat
      }
    } catch {
      if case RemoteNodeError.timeout = error { hadTimeout = true }
      logger.warning("Failed to get latitude: \(error)")
    }

    do {
      let response = try await sendAndWait("get lon")
      if case let .longitude(lon) = CLIResponse.parse(response, forQuery: "get lon") {
        if longitude == baselineLongitude { longitude = lon }
        originalLongitude = lon
      }
    } catch {
      if case RemoteNodeError.timeout = error { hadTimeout = true }
      logger.warning("Failed to get longitude: \(error)")
    }

    if hadTimeout {
      identityError = true
    }

    isLoadingIdentity = false
  }

  func fetchRadioSettings() async {
    isLoadingRadio = true
    radioError = false
    var hadTimeout = false

    do {
      let response = try await sendAndWait("get radio")
      if case let .radio(freq, bw, sf, cr) = CLIResponse.parse(response, forQuery: "get radio") {
        frequency = freq
        bandwidth = bw
        spreadingFactor = sf
        codingRate = cr
        rememberRadioOriginals()
        radioSettingsModified = false
      }
    } catch {
      if case RemoteNodeError.timeout = error { hadTimeout = true }
      logger.warning("Failed to get radio settings: \(error)")
    }

    do {
      let response = try await sendAndWait("get tx")
      if case let .txPower(power) = CLIResponse.parse(response, forQuery: "get tx") {
        txPower = power
        originalTxPower = power
      }
    } catch {
      // Older firmware may not answer; the row then stays unloaded and the rest still applies.
      logger.warning("Failed to get TX power: \(error)")
    }

    if hadTimeout {
      radioError = true
    }

    isLoadingRadio = false
  }

  func fetchContactInfo() async {
    if originalOwnerInfo == nil {
      await onPreFetchNodeInfo?()
    }
    if originalOwnerInfo != nil { return }

    isLoadingContactInfo = true
    contactInfoError = false

    do {
      let response = try await sendAndWait("get owner.info")
      if case let .ownerInfo(info) = CLIResponse.parse(response, forQuery: "get owner.info") {
        let displayText = NodeSettingsResponseParser.displayOwnerInfo(fromWire: info)
        ownerInfo = displayText
        originalOwnerInfo = displayText
      }
    } catch {
      if case RemoteNodeError.timeout = error {
        contactInfoError = true
      }
      logger.warning("Failed to get owner info: \(error)")
    }

    isLoadingContactInfo = false
  }

  // MARK: - Success Flash

  /// How long an Apply button shows its success state before returning to idle.
  static let successFlashDuration: Duration = .seconds(1.5)

  /// Drop the section's applying flag and flash its success indicator for
  /// `successFlashDuration`. The closures target the section's own state, which
  /// may live on this shared view model or on the owning view model.
  func flashSuccess(setApplying: (Bool) -> Void, setSuccess: (Bool) -> Void) async {
    withAnimation {
      setApplying(false)
      setSuccess(true)
    }
    try? await Task.sleep(for: Self.successFlashDuration)
    withAnimation { setSuccess(false) }
  }

  // MARK: - Apply Methods

  /// Apply from the Radio card: checks the values against what the node and the mesh can take, and
  /// a change to the radio parameters (not TX power alone) is confirmed first, since a wrong one
  /// strands the node. The confirmation then calls `applyRadioSettings(rebootAfter:)`.
  func requestApplyRadioSettings(rebootAfter: Bool = false) {
    guard txPowerModified || radioSettingsModified else { return }
    if !radioSettingsModified, txPowerModified {
      Task { await applyRadioSettings() }
      return
    }
    radioValidation = RadioSettingsValidator.validate(
      frequency: frequency, bandwidth: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate
    )
    guard !radioValidation.hasErrors else { return }
    pendingRadioChange = PendingRadioChange(
      lines: originalRadioValues.changeLines(to: editedRadioValues),
      rebootAfter: rebootAfter
    )
  }

  func applyRadioSettings(rebootAfter: Bool = false) async {
    pendingRadioChange = nil
    guard txPowerModified || radioSettingsModified else { return }
    // A TX power change alone doesn't need the other radio parameters read.
    if !radioSettingsModified, txPowerModified {
      await applyTxPowerOnly()
      return
    }
    guard let frequency, let bandwidth, let spreadingFactor, let codingRate else {
      errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.radioNotLoaded
      return
    }
    // Never sent unchecked, whichever path led here.
    radioValidation = RadioSettingsValidator.validate(
      frequency: frequency, bandwidth: bandwidth, spreadingFactor: spreadingFactor, codingRate: codingRate
    )
    guard !radioValidation.hasErrors else { return }

    isApplying = true
    errorMessage = nil

    do {
      // TX power first: it applies at once, while `set radio` restarts the radio.
      if txPowerModified, let txPower, txPower != originalTxPower {
        let txResponse = try await sendAndWait("set tx \(txPower)")
        guard case .ok = CLIResponse.parse(txResponse) else {
          handleRefusedTx(txResponse)
          isApplying = false
          return
        }
        originalTxPower = txPower
        txPowerModified = false
        refreshTxAntenna()
        if !radioSettingsModified {
          successMessage = L10n.RemoteNodes.RemoteNodes.Settings.radioAppliedSuccess
          showSuccessAlert = true
          isApplying = false
          return
        }
      }
      let radioCommand = "set radio \(frequency),\(bandwidth),\(spreadingFactor),\(codingRate)"
      let radioResponse = try await sendAndWait(radioCommand)
      if case .ok = CLIResponse.parse(radioResponse) {
        radioSettingsModified = false
        rememberRadioOriginals()
        if rebootAfter {
          isApplying = false
          await reboot()
          return
        }
        successOffersReboot = true
        successMessage = L10n.RemoteNodes.RemoteNodes.Settings.radioAppliedSuccess
        showSuccessAlert = true
      } else {
        errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.radioApplyFailed
      }
    } catch {
      errorMessage = error.userFacingMessage
    }

    isApplying = false
  }

  /// `set tx` on its own: applies at once, no radio restart.
  private func applyTxPowerOnly() async {
    guard let txPower else { return }
    isApplying = true
    errorMessage = nil
    do {
      let response = try await sendAndWait("set tx \(txPower)")
      if case .ok = CLIResponse.parse(response) {
        originalTxPower = txPower
        txPowerModified = false
        refreshTxAntenna()
        successMessage = L10n.RemoteNodes.RemoteNodes.Settings.radioAppliedSuccess
        showSuccessAlert = true
      } else {
        handleRefusedTx(response)
      }
    } catch {
      errorMessage = error.userFacingMessage
    }
    isApplying = false
  }

  /// A `set tx` the node refused. Cairn firmware names its range ("Error: range -9..16"): the
  /// controls narrow to it (a node whose `get cairn.cfg` was lost offered the chip's 22), the pick
  /// comes into it, and the error says what the node takes. Any other reply gets the generic failure.
  private func handleRefusedTx(_ reply: String) {
    guard let range = CairnNodeConfig.txPowerRange(fromRefusal: reply) else {
      errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.radioApplyFailed
      return
    }
    txPowerMax = range.upperBound
    if let txPower {
      self.txPower = min(max(txPower, range.lowerBound), range.upperBound)
    }
    txPowerModified = txPower != originalTxPower
    errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.txPowerOutOfRange(range.lowerBound, range.upperBound)
  }

  func applyIdentitySettings() async {
    let validation = Self.validateIdentityFields(name: name, latitude: latitude, longitude: longitude)
    nameError = validation.name
    latitudeError = validation.latitude
    longitudeError = validation.longitude
    if validation.hasErrors { return }

    isApplying = true
    errorMessage = nil
    clearFieldResults(["name", "lat", "lon"])

    do {
      var allSucceeded = true

      if let name, name != originalName {
        let response = try await sendAndWait("set name \(name)")
        if recordFieldResult("name", response: response) {
          originalName = name
        } else {
          allSucceeded = false
        }
      }

      if let latitude, latitude != originalLatitude {
        let response = try await sendAndWait("set lat \(latitude)")
        if recordFieldResult("lat", response: response) {
          originalLatitude = latitude
        } else {
          allSucceeded = false
        }
      }

      if let longitude, longitude != originalLongitude {
        let response = try await sendAndWait("set lon \(longitude)")
        if recordFieldResult("lon", response: response) {
          originalLongitude = longitude
        } else {
          allSucceeded = false
        }
      }

      if allSucceeded {
        await flashSuccess(
          setApplying: { isApplying = $0 },
          setSuccess: { identityApplySuccess = $0 }
        )
        return
      } else {
        errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.someSettingsFailedToApply
      }
    } catch {
      errorMessage = error.userFacingMessage
    }

    isApplying = false
  }

  func applyContactInfoSettings() async {
    isApplying = true
    errorMessage = nil

    do {
      let pipeText = NodeSettingsResponseParser.wireOwnerInfo(fromDisplay: ownerInfo ?? "")
      let response = try await sendAndWait("set owner.info \(pipeText)")
      if case .ok = CLIResponse.parse(response) {
        originalOwnerInfo = ownerInfo
        await flashSuccess(
          setApplying: { isApplying = $0 },
          setSuccess: { contactInfoApplySuccess = $0 }
        )
        return
      } else {
        errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.someSettingsFailedToApply
      }
    } catch {
      errorMessage = error.userFacingMessage
    }

    isApplying = false
  }

  // MARK: - Location Picker

  func setLocationFromPicker(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }

  // MARK: - Security

  func changePassword() async {
    guard !newPassword.isEmpty else {
      errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.passwordEmpty
      return
    }
    guard newPassword == confirmPassword else {
      errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.passwordMismatch
      return
    }

    isApplying = true
    errorMessage = nil

    do {
      let response = try await sendAndWait("password \(newPassword)", rawMatching: true)
      if NodeSettingsResponseParser.isPasswordChangeSuccessful(response) {
        newPassword = ""
        confirmPassword = ""
        await flashSuccess(
          setApplying: { isApplying = $0 },
          setSuccess: { changePasswordSuccess = $0 }
        )
        return
      } else {
        errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.passwordChangeFailed
      }
    } catch {
      errorMessage = error.userFacingMessage
    }

    isApplying = false
  }

  // MARK: - Device Actions

  func reboot() async {
    guard session != nil else { return }

    isRebooting = true
    errorMessage = nil

    // Firmware reboots without replying, so a timeout is the expected outcome.
    do {
      _ = try await sendAndWait("reboot", timeout: RemoteOperationTimeoutPolicy.fireAndForgetCLI)
      markRebooting()
    } catch RemoteNodeError.timeout {
      markRebooting()
    } catch {
      errorMessage = error.userFacingMessage
    }

    isRebooting = false
  }

  /// The reboot went out: the node's sessions are gone with it, so the dashboard shows the
  /// rebooting banner (with its reconnect) rather than an alert over a page that can't ask anything.
  private func markRebooting() {
    successOffersReboot = false
    quietState = .rebooting(since: now())
    if let session { Task { await onSessionQuiet?(session.id) } }
  }

  /// The board has no bootloader to report (ESP32), on a Cairn build: updates go through the web
  /// flasher rather than over Bluetooth.
  var isESP32CairnBoard: Bool {
    bootloaderVersionRead && bootloaderVersion == nil && FirmwareUpdateCheck.isCairnBuild(firmwareVersion)
  }

  func forceAdvert() async {
    isSendingAdvert = true
    defer { isSendingAdvert = false }
    do {
      _ = try await sendAndWait("advert")
      successMessage = L10n.RemoteNodes.RemoteNodes.Settings.advertSent
      showSuccessAlert = true
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  /// The last clock sync got no reply. It most likely reached the node and set its clock, so the
  /// next one being refused as going backwards means the clock is right.
  private(set) var lastClockSyncUnanswered = false

  func syncTime() async {
    isApplying = true
    errorMessage = nil
    // how far off it was, for the alert once it's set
    let driftBefore = clockDrift

    do {
      // Sent as `clock sync`; the service stamps the time as it goes out, ahead by the route's
      // delay, so a wait in the queue can't leave it stale.
      let response = try await sendAndWait(RemoteCLICommandRewriter.clockSyncCommand)
      switch NodeSettingsResponseParser.classifyClockSyncResponse(response) {
      case .synced:
        if NodeSettingsResponseParser.clockResponseText(in: response) != nil {
          applyDeviceTime(response)
        } else {
          clockDrift = nil
        }
        reportTimeSynced(driftBefore: driftBefore)
      case .clockAhead:
        if await refusedSyncMeansInSync() {
          reportTimeSynced(driftBefore: 0)
        } else {
          errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.clockAheadError
        }
      case let .failed(message):
        errorMessage = message.isEmpty ? L10n.RemoteNodes.RemoteNodes.Settings.syncTimeFailed : message
      case .unexpected:
        errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.unexpectedResponse(response)
      }
      lastClockSyncUnanswered = false
    } catch RemoteNodeError.timeout {
      lastClockSyncUnanswered = true
      errorMessage = RemoteNodeError.timeout.userFacingMessage
    } catch {
      errorMessage = error.userFacingMessage
    }

    isApplying = false
  }

  /// "Time synced: set to 2:14 PM from this phone. Before, it was 3m behind this phone." (the user,
  /// 2026-11-09: the alert states what happened; the header shows only the time).
  private func reportTimeSynced(driftBefore: TimeInterval?) {
    let strings = L10n.RemoteNodes.RemoteNodes.Settings.self
    let time = now().formatted(date: .omitted, time: .shortened)
    let detail: String = if let driftBefore {
      if abs(driftBefore) <= Self.automaticSyncTolerance {
        strings.timeSyncedAlready(time)
      } else {
        strings.timeSyncedWas(time, Self.driftText(driftBefore))
      }
    } else {
      strings.timeSyncedTo(time)
    }
    successMessage = "\(strings.timeSynced). \(detail)"
    showSuccessAlert = true
  }

  /// "3m behind this phone", as the Clock reading words it.
  static func driftText(_ drift: TimeInterval) -> String {
    let amount = Duration.seconds(abs(drift).rounded())
      .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    return drift > 0 ? L10n.Settings.Clock.Drift.ahead(amount) : L10n.Settings.Clock.Drift.behind(amount)
  }

  /// A node's clock is let drift this far before the dashboard sets it on its own after login.
  static let automaticSyncTolerance: TimeInterval = 30

  /// The automatic sync after login: reads the node's clock when it isn't known yet, and sets it
  /// from the phone when it is off by more than `automaticSyncTolerance`, saying nothing either
  /// way (the Sync Time tile is the one that reports). A node that refuses (a sync going
  /// backwards it won't take) is left as it is.
  func syncTimeIfDrifted() async {
    if clockDrift == nil {
      guard let response = try? await sendAndWait("clock"),
            case let .deviceTime(time) = CLIResponse.parse(response, forQuery: "clock") else { return }
      applyDeviceTime(time)
    }
    guard let clockDrift, abs(clockDrift) > Self.automaticSyncTolerance else { return }
    guard let response = try? await sendAndWait(RemoteCLICommandRewriter.clockSyncCommand) else { return }
    switch NodeSettingsResponseParser.classifyClockSyncResponse(response) {
    case .synced:
      if NodeSettingsResponseParser.clockResponseText(in: response) != nil {
        applyDeviceTime(response)
      } else {
        self.clockDrift = nil
      }
    case .clockAhead:
      _ = await refusedSyncMeansInSync()
    case .failed, .unexpected:
      break
    }
  }

  /// A sync refused as going backwards: whether the node's clock is in fact already right (a `time`
  /// stamped ahead of the phone landed just behind it), from the last reading and whether an earlier
  /// sync went unanswered, or failing those by reading the clock. False keeps the clock-ahead warning.
  private func refusedSyncMeansInSync() async -> Bool {
    if let known = NodeSettingsResponseParser.refusedSyncMeansInSync(
      drift: clockDrift,
      earlierAttemptUnanswered: lastClockSyncUnanswered
    ) {
      // A reading from before the clock was set no longer holds; the next one shows it.
      if known { clockDrift = nil }
      return known
    }
    do {
      let response = try await sendAndWait("clock")
      guard case let .deviceTime(time) = CLIResponse.parse(response, forQuery: "clock") else { return false }
      applyDeviceTime(time)
    } catch {
      logger.warning("Failed to read the clock after a refused sync: \(error)")
      return false
    }
    return NodeSettingsResponseParser.refusedSyncMeansInSync(drift: clockDrift, earlierAttemptUnanswered: false) == true
  }

  // MARK: - Shared Validation

  /// Firmware-accepted ranges for the behavior fields; 0 means disabled for
  /// the two intervals and is validated separately.
  static let advertIntervalMinutesRange = 60...240
  static let floodIntervalHoursRange = 3...168
  static let floodMaxHopsRange = 0...64

  struct BehaviorValidationErrors {
    var advertInterval: String?
    var floodInterval: String?
    var floodMaxHops: String?
    var hasErrors: Bool {
      advertInterval != nil || floodInterval != nil || floodMaxHops != nil
    }
  }

  static func validateBehaviorFields(
    advertInterval: Int?,
    floodInterval: Int?,
    floodMaxHops: Int?
  ) -> BehaviorValidationErrors {
    var errors = BehaviorValidationErrors()
    if let interval = advertInterval, interval != 0, !advertIntervalMinutesRange.contains(interval) {
      errors.advertInterval = L10n.RemoteNodes.RemoteNodes.Settings.advertIntervalValidation
    }
    if let interval = floodInterval, interval != 0, !floodIntervalHoursRange.contains(interval) {
      errors.floodInterval = L10n.RemoteNodes.RemoteNodes.Settings.floodIntervalValidation
    }
    if let hops = floodMaxHops, !floodMaxHopsRange.contains(hops) {
      errors.floodMaxHops = L10n.RemoteNodes.RemoteNodes.Settings.floodMaxValidation
    }
    return errors
  }

  struct IdentityValidationErrors {
    var name: String?
    var latitude: String?
    var longitude: String?
    var hasErrors: Bool {
      name != nil || latitude != nil || longitude != nil
    }
  }

  /// Rejects out-of-range coordinates rather than clamping, so a mistyped value surfaces to the
  /// user instead of firmware silently normalizing it. Ranges and the name byte cap come from
  /// `PacketBuilder` and `ProtocolLimits`, matching the binary write path.
  static func validateIdentityFields(
    name: String?,
    latitude: Double?,
    longitude: Double?
  ) -> IdentityValidationErrors {
    var errors = IdentityValidationErrors()
    if let name, name.utf8.count > ProtocolLimits.maxUsableNameBytes {
      errors.name = L10n.RemoteNodes.RemoteNodes.Settings.nameValidation(ProtocolLimits.maxUsableNameBytes)
    }
    if let latitude, !latitude.isFinite || !PacketBuilder.latitudeRange.contains(latitude) {
      errors.latitude = L10n.RemoteNodes.RemoteNodes.Settings.latitudeValidation
    }
    if let longitude, !longitude.isFinite || !PacketBuilder.longitudeRange.contains(longitude) {
      errors.longitude = L10n.RemoteNodes.RemoteNodes.Settings.longitudeValidation
    }
    return errors
  }

  // MARK: - Late Reply Recovery

  /// Structured queries this screen sent that timed out unanswered.
  private var unansweredQueries: Set<String> = []

  /// Recently observed reply texts; a mesh duplicate of an already-answered
  /// command must not be recovered for a different query.
  private var recentResponses: [String] = []
  private static let recentResponsesLimit = 16

  /// Appliers for recovered late replies, keyed by query.
  private var lateRecoveryAppliers: [String: (CLIResponse) -> Void] = [:]

  /// Registers a field applier for a recoverable query. Repeater and room
  /// view models add their own section fields on top of the shared ones.
  func registerLateRecovery(query: String, apply: @escaping (CLIResponse) -> Void) {
    lateRecoveryAppliers[query] = apply
  }

  private func rememberSeenResponse(_ response: String) {
    recentResponses.append(response)
    if recentResponses.count > Self.recentResponsesLimit {
      recentResponses.removeFirst()
    }
  }

  /// Adopt an out-of-band CLI reply for the one unanswered query it can only
  /// belong to. The reply already spent its airtime, so recovering it beats
  /// refetching; ambiguous or duplicate replies are ignored.
  func handleCommonLateResponse(_ response: String) {
    guard !recentResponses.contains(response) else { return }
    guard let recovered = NodeSettingsResponseParser.recoveredResponse(
      response,
      unansweredQueries: unansweredQueries
    ), let apply = lateRecoveryAppliers[recovered.query] else { return }

    unansweredQueries.remove(recovered.query)
    rememberSeenResponse(response)
    apply(recovered.value)
    logger.info("Recovered late response for '\(recovered.query)'")
  }

  private var identitySectionComplete: Bool {
    originalName != nil && originalLatitude != nil && originalLongitude != nil
  }

  private func registerSharedLateRecovery() {
    registerLateRecovery(query: "get radio") { [weak self] value in
      guard let self, case let .radio(frequency, bandwidth, spreadingFactor, codingRate) = value else { return }
      self.frequency = frequency
      self.bandwidth = bandwidth
      self.spreadingFactor = spreadingFactor
      self.codingRate = codingRate
      rememberRadioOriginals()
      radioSettingsModified = false
      radioError = false
    }
    registerLateRecovery(query: "get lat") { [weak self] value in
      guard let self, case let .latitude(latitude) = value else { return }
      // As in `fetchIdentity`, an unsaved edit outranks the node's belated answer.
      if self.latitude == originalLatitude { self.latitude = latitude }
      originalLatitude = latitude
      identityError = !identitySectionComplete
    }
    registerLateRecovery(query: "get lon") { [weak self] value in
      guard let self, case let .longitude(longitude) = value else { return }
      if self.longitude == originalLongitude { self.longitude = longitude }
      originalLongitude = longitude
      identityError = !identitySectionComplete
    }
    registerLateRecovery(query: "clock") { [weak self] value in
      guard let self, case let .deviceTime(time) = value else { return }
      applyDeviceTime(time)
      deviceInfoError = firmwareVersion == nil
    }
  }
}
