import CairnServices
import OSLog
import SwiftUI

@Observable
@MainActor
final class RepeaterSettingsViewModel {
  // MARK: - Shared Helper

  var helper = NodeSettingsViewModel()

  // MARK: - Repeater-Only: Behavior Settings

  var advertIntervalMinutes: Int?
  var floodAdvertIntervalHours: Int?
  var floodMaxHops: Int?
  var repeaterEnabled: Bool?
  private var originalAdvertIntervalMinutes: Int?
  private var originalFloodAdvertIntervalHours: Int?
  private var originalFloodMaxHops: Int?
  private var originalRepeaterEnabled: Bool?
  var isLoadingBehavior = false
  var behaviorError = false
  var behaviorLoaded: Bool {
    repeaterEnabled != nil || advertIntervalMinutes != nil
  }

  var advertIntervalError: String?
  var floodAdvertIntervalError: String?
  var floodMaxHopsError: String?

  var behaviorApplySuccess = false

  var behaviorSettingsModified: Bool {
    (repeaterEnabled != nil && repeaterEnabled != originalRepeaterEnabled) ||
      (advertIntervalMinutes != nil && advertIntervalMinutes != originalAdvertIntervalMinutes) ||
      (floodAdvertIntervalHours != nil && floodAdvertIntervalHours != originalFloodAdvertIntervalHours) ||
      (floodMaxHops != nil && floodMaxHops != originalFloodMaxHops)
  }

  /// The CLI keys the Behavior card's per-field results are kept under (`helper.fieldResults`).
  static let behaviorFieldKeys = ["repeat", "advert.interval", "flood.advert.interval", "flood.max"]

  /// Puts the Behavior fields back to the repeater's values, dropping unsent edits.
  func revertBehaviorSettings() {
    if let originalRepeaterEnabled { repeaterEnabled = originalRepeaterEnabled }
    if let originalAdvertIntervalMinutes { advertIntervalMinutes = originalAdvertIntervalMinutes }
    if let originalFloodAdvertIntervalHours { floodAdvertIntervalHours = originalFloodAdvertIntervalHours }
    if let originalFloodMaxHops { floodMaxHops = originalFloodMaxHops }
    advertIntervalError = nil
    floodAdvertIntervalError = nil
    floodMaxHopsError = nil
    helper.clearFieldResults(Self.behaviorFieldKeys)
  }

  // MARK: - Repeater-Only: Region Settings

  var regions: [RepeaterRegionEntry] = []
  var originalRegions: [RepeaterRegionEntry]?
  var isLoadingRegions = false
  var regionsError = false
  var regionsLoaded: Bool {
    originalRegions != nil
  }

  /// The repeater's table couldn't be read in full (`fetchRegions`): `regions` is the part that
  /// could, and each new name is checked with the repeater before it's put.
  var regionsListPartial = false
  /// Regions the repeater listed whose place in the tree couldn't be read, so they're not in
  /// `regions`. Kept so an add can't reuse one of their names.
  var unplacedRegionNames: [String] = []

  var hasUnsavedRegionChanges = false
  var regionsSaveSuccess = false
  /// Unset when nil. Scopes flood traffic this node originates, not which regions it repeats.
  var defaultScopeName: String?
  /// False until a `region default` reply parses. Distinct from `defaultScopeName == nil`.
  var defaultScopeLoaded = false
  var isLoadingDefaultScope = false
  /// `region default` exists on MeshCore repeater v1.15.0+. Unknown version is unsupported.
  var supportsRegionDefaultScope: Bool {
    helper.firmwareVersion?.isAtLeast(
      major: Firmware.regionDefaultScopeMinMajor,
      minor: Firmware.regionDefaultScopeMinMinor
    ) == true
  }

  /// `region put` creates a flood-allowed region from MeshCore repeater v1.15.0 and a
  /// flood-denied one before it. Unknown version is treated as the older behavior.
  var regionPutAllowsFlood: Bool {
    helper.firmwareVersion?.isAtLeast(
      major: Firmware.regionPutAllowsFloodMinMajor,
      minor: Firmware.regionPutAllowsFloodMinMinor
    ) == true
  }

  private enum Firmware {
    static let regionDefaultScopeMinMajor = 1
    static let regionDefaultScopeMinMinor = 15
    static let regionPutAllowsFloodMinMajor = 1
    static let regionPutAllowsFloodMinMinor = 15
  }

  // MARK: - Expansion State (repeater-only sections)

  var isBehaviorExpanded = false
  var isRegionsExpanded = false

  // MARK: - Dependencies

  private var repeaterAdminServiceProvider: @MainActor () -> RepeaterAdminService? = { nil }
  var repeaterAdminService: RepeaterAdminService? {
    repeaterAdminServiceProvider()
  }

  let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "RepeaterSettings")

  // MARK: - Cleanup

  func cleanup() async {
    await repeaterAdminService?.setCLIHandler { _, _ in }
    helper.cleanup()
  }

  // MARK: - Configuration

  /// Nil service mirrors a disconnected state; commands then no-op.
  func configure(repeaterAdminService: @escaping @MainActor () -> RepeaterAdminService?, session: RemoteNodeSessionDTO) async {
    repeaterAdminServiceProvider = repeaterAdminService

    guard repeaterAdminService() != nil else { return }

    // The service is resolved at each send, not captured: a reconnect builds a new service
    // container, and a captured instance would keep sending to the torn-down one.
    helper.configure(
      session: session,
      sendCommand: { [repeaterAdminService] id, cmd, timeout in
        guard let service = repeaterAdminService() else { throw RemoteNodeError.notConnected }
        return try await service.sendCommand(sessionID: id, command: cmd, timeout: timeout)
      },
      sendRawCommand: { [repeaterAdminService] id, cmd, timeout in
        guard let service = repeaterAdminService() else { throw RemoteNodeError.notConnected }
        return try await service.sendRawCommand(sessionID: id, command: cmd, timeout: timeout)
      }
    )

    helper.name = session.name

    helper.onPreFetchNodeInfo = { [weak self] in
      await self?.fetchNodeInfo()
    }

    registerBehaviorLateRecovery()

    await registerCLIHandler()

    // The owner info (firmware, name, contact text) is read after the status, as the Dashboard's
    // first step after it (`fetchNodeInfoIfNeeded`), or by a settings sheet that needs it first:
    // racing the status for the link only delayed the page's first reading.
  }

  /// Registers the CLI handler for late responses on the current admin service. The handler
  /// lives on the service, so the hosting view calls this again for each new service container.
  func registerCLIHandler() async {
    await repeaterAdminService?.setCLIHandler { [weak self] message, _ in
      await MainActor.run {
        self?.helper.handleCommonLateResponse(message.text)
      }
    }
  }

  /// Builds the node-CLI send closure, pre-binding this session's id and
  /// resolving the private admin service at each send (a thin pass-through to
  /// `RemoteNodeService.sendRawCLICommand`). Returns nil if not configured.
  func makeNodeCLISendClosure(
    session: RemoteNodeSessionDTO
  ) -> (@MainActor (_ command: String, _ timeout: Duration) async throws -> String)? {
    guard repeaterAdminService != nil else { return nil }
    return { [repeaterAdminServiceProvider, sessionID = session.id] command, timeout in
      guard let service = repeaterAdminServiceProvider() else { throw RemoteNodeError.notConnected }
      return try await service.sendRawCommand(
        sessionID: sessionID, command: command, timeout: timeout
      )
    }
  }

  private var isLoadingNodeInfo = false

  /// The owner info, unless it's in or on its way: the Dashboard's first read after the status.
  func fetchNodeInfoIfNeeded() async {
    guard !helper.contactInfoLoaded else { return }
    await fetchNodeInfo()
  }

  private func fetchNodeInfo() async {
    guard !isLoadingNodeInfo, let session = helper.session, let repeaterAdminService else { return }
    isLoadingNodeInfo = true
    defer { isLoadingNodeInfo = false }
    do {
      let response = try await repeaterAdminService.requestOwnerInfo(sessionID: session.id)
      helper.setNodeInfo(
        firmwareVersion: response.firmwareVersion,
        name: response.nodeName,
        ownerInfo: response.ownerInfo
      )
    } catch {
      logger.warning("Failed to fetch node info via binary: \(error)")
    }
  }

  // MARK: - Region Add

  enum RegionFloodDefaultError: Error, Equatable {
    /// The region was added but is still flood-denied.
    case stillDenied
  }

  /// Adds a region and leaves it flood-allowed, the default of the current repeater CLI.
  /// Older firmware needs a separate `region allowf`. It is sent once: when its reply is lost
  /// the region shows as off, and its toggle sends the same command again.
  func addFloodAllowedRegion(name: String, parent: RepeaterRegionEntry.Parent) async throws {
    try await addRegion(name: name, parent: parent)
    guard !regionPutAllowsFlood else { return }

    let cleaned = RegionNameValidator.cleanedName(name)
    helper.isApplying = true
    defer { helper.isApplying = false }

    do {
      let response = try await helper.sendAndWait("region allowf \(cleaned)")
      if case .ok = CLIResponse.parse(response) {
        hasUnsavedRegionChanges = true
        await autoSaveRegions()
        return
      }
      logger.warning("Unexpected region allowf reply: \(response)")
    } catch {
      logger.warning("Failed to allow flood for new region: \(error)")
    }

    if let index = regions.firstIndex(where: { $0.name == cleaned }) {
      regions[index].floodAllowed = false
    }
    helper.errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.Regions.addedFloodOff
    throw RegionFloodDefaultError.stillDenied
  }

  // MARK: - Late Reply Recovery

  private var behaviorSectionComplete: Bool {
    originalRepeaterEnabled != nil && originalAdvertIntervalMinutes != nil
      && originalFloodAdvertIntervalHours != nil && originalFloodMaxHops != nil
  }

  private func registerBehaviorLateRecovery() {
    helper.registerLateRecovery(query: "get repeat") { [weak self] value in
      guard let self, case let .repeatMode(enabled) = value else { return }
      repeaterEnabled = enabled
      originalRepeaterEnabled = enabled
      behaviorError = !behaviorSectionComplete
    }
    helper.registerLateRecovery(query: "get advert.interval") { [weak self] value in
      guard let self, case let .advertInterval(minutes) = value else { return }
      advertIntervalMinutes = minutes
      originalAdvertIntervalMinutes = minutes
      behaviorError = !behaviorSectionComplete
    }
    helper.registerLateRecovery(query: "get flood.advert.interval") { [weak self] value in
      guard let self, case let .floodAdvertInterval(hours) = value else { return }
      floodAdvertIntervalHours = hours
      originalFloodAdvertIntervalHours = hours
      behaviorError = !behaviorSectionComplete
    }
    helper.registerLateRecovery(query: "get flood.max") { [weak self] value in
      guard let self, case let .floodMax(hops) = value else { return }
      floodMaxHops = hops
      originalFloodMaxHops = hops
      behaviorError = !behaviorSectionComplete
    }
  }

  // MARK: - Behavior Fetch/Apply

  /// The Behavior card's settings from a Cairn repeater's combined reply (`get cairn.cfg`).
  func applyCairnConfig(_ c: CairnNodeConfig) {
    repeaterEnabled = c.repeatEnabled
    originalRepeaterEnabled = c.repeatEnabled
    advertIntervalMinutes = c.advertIntervalMinutes
    originalAdvertIntervalMinutes = c.advertIntervalMinutes
    floodAdvertIntervalHours = c.floodAdvertIntervalHours
    originalFloodAdvertIntervalHours = c.floodAdvertIntervalHours
    floodMaxHops = c.floodMaxHops
    originalFloodMaxHops = c.floodMaxHops
    behaviorError = false
  }

  func fetchBehaviorSettings() async {
    isLoadingBehavior = true
    behaviorError = false
    var hadTimeout = false

    do {
      let response = try await helper.sendAndWait("get repeat")
      if case let .repeatMode(enabled) = CLIResponse.parse(response, forQuery: "get repeat") {
        repeaterEnabled = enabled
        originalRepeaterEnabled = enabled
      }
    } catch {
      if case RemoteNodeError.timeout = error { hadTimeout = true }
      logger.warning("Failed to get repeat mode: \(error)")
    }

    do {
      let response = try await helper.sendAndWait("get advert.interval")
      if case let .advertInterval(minutes) = CLIResponse.parse(response, forQuery: "get advert.interval") {
        advertIntervalMinutes = minutes
        originalAdvertIntervalMinutes = minutes
      }
    } catch {
      if case RemoteNodeError.timeout = error { hadTimeout = true }
      logger.warning("Failed to get advert interval: \(error)")
    }

    do {
      let response = try await helper.sendAndWait("get flood.advert.interval")
      if case let .floodAdvertInterval(hours) = CLIResponse.parse(response, forQuery: "get flood.advert.interval") {
        floodAdvertIntervalHours = hours
        originalFloodAdvertIntervalHours = hours
      }
    } catch {
      if case RemoteNodeError.timeout = error { hadTimeout = true }
      logger.warning("Failed to get flood advert interval: \(error)")
    }

    do {
      let response = try await helper.sendAndWait("get flood.max")
      if case let .floodMax(hops) = CLIResponse.parse(response, forQuery: "get flood.max") {
        floodMaxHops = hops
        originalFloodMaxHops = hops
      }
    } catch {
      if case RemoteNodeError.timeout = error { hadTimeout = true }
      logger.warning("Failed to get flood max: \(error)")
    }

    if hadTimeout {
      behaviorError = true
    }

    isLoadingBehavior = false
  }

  func applyBehaviorSettings() async {
    let validation = NodeSettingsViewModel.validateBehaviorFields(
      advertInterval: advertIntervalMinutes,
      floodInterval: floodAdvertIntervalHours,
      floodMaxHops: floodMaxHops
    )
    advertIntervalError = validation.advertInterval
    floodAdvertIntervalError = validation.floodInterval
    floodMaxHopsError = validation.floodMaxHops

    if validation.hasErrors { return }

    helper.isApplying = true
    helper.errorMessage = nil
    helper.clearFieldResults(Self.behaviorFieldKeys)

    do {
      var allSucceeded = true

      if let repeaterEnabled, repeaterEnabled != originalRepeaterEnabled {
        let response = try await helper.sendAndWait("set repeat \(repeaterEnabled ? "on" : "off")")
        if helper.recordFieldResult("repeat", response: response) {
          originalRepeaterEnabled = repeaterEnabled
        } else {
          allSucceeded = false
        }
      }

      if let advertIntervalMinutes, advertIntervalMinutes != originalAdvertIntervalMinutes {
        let response = try await helper.sendAndWait("set advert.interval \(advertIntervalMinutes)")
        if helper.recordFieldResult("advert.interval", response: response) {
          originalAdvertIntervalMinutes = advertIntervalMinutes
        } else {
          allSucceeded = false
        }
      }

      if let floodAdvertIntervalHours, floodAdvertIntervalHours != originalFloodAdvertIntervalHours {
        let response = try await helper.sendAndWait("set flood.advert.interval \(floodAdvertIntervalHours)")
        if helper.recordFieldResult("flood.advert.interval", response: response) {
          originalFloodAdvertIntervalHours = floodAdvertIntervalHours
        } else {
          allSucceeded = false
        }
      }

      if let floodMaxHops, floodMaxHops != originalFloodMaxHops {
        let response = try await helper.sendAndWait("set flood.max \(floodMaxHops)")
        if helper.recordFieldResult("flood.max", response: response) {
          originalFloodMaxHops = floodMaxHops
        } else {
          allSucceeded = false
        }
      }

      if allSucceeded {
        await helper.flashSuccess(
          setApplying: { helper.isApplying = $0 },
          setSuccess: { behaviorApplySuccess = $0 }
        )
        return
      } else {
        helper.errorMessage = L10n.RemoteNodes.RemoteNodes.Settings.someSettingsFailedToApply
      }
    } catch {
      helper.errorMessage = error.userFacingMessage
    }

    helper.isApplying = false
  }
}
