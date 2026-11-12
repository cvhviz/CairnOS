import CairnServices
import SwiftUI

/// Runs "Discover Nearby Regions" for Manage Regions, the one page that discovers, whether it was
/// opened from Settings → Radio or from a channel's info sheet. New regions aren't added straight
/// away: they're offered in `RegionDiscoveryResultsView`, so the user picks which to keep.
///
/// The probe goes through the process-wide `DiscoverRequestGate`, shared with Scan for Nodes,
/// CarPlay and Wardrive. When the gate is cooling down nothing is sent: the runner says so and asks
/// the repeaters already heard nearby instead. It does the same when the radio's firmware can't
/// send a scan (official companion firmware before v1.10). Regions are asked for with anonymous
/// requests, so a radio without them (before v1.12) sends nothing at all and says why.
@Observable
@MainActor
final class RegionDiscoveryRunner {
  private(set) var isDiscovering = false
  /// Why a run found nothing to offer, shown under the Discover button.
  private(set) var message: String?
  /// Regions the last run found that aren't known yet; non-nil pushes the results picker.
  var discoveredRegions: [String]?

  @ObservationIgnored private var task: Task<Void, Never>?

  /// What a finished discovery means for the page: regions to offer, or a message saying why
  /// there are none. A failed send stays silent, as it always has; the radio is likely gone.
  enum Result: Equatable {
    case found([String])
    case nothingFound(message: String?)
  }

  static func result(for outcome: RegionDiscoveryService.Outcome) -> Result {
    switch outcome {
    case .sendFailed:
      .nothingFound(message: nil)
    case .coolingDown:
      .nothingFound(message: L10n.Tools.Tools.RegionDiscovery.cooldown)
    case .discoverUnsupported:
      .nothingFound(message: L10n.Tools.Tools.RegionDiscovery.scanUnsupported)
    case .noRepeatersResponded:
      .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.noRepeatersResponded)
    case .errorLoadingRepeaters:
      .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.errLoadingRepeaters)
    case let .completed(newRegions, allRepeatersTableFull):
      if !newRegions.isEmpty {
        .found(newRegions)
      } else if allRepeatersTableFull {
        .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.errRadioContactsFull)
      } else {
        .nothingFound(message: L10n.Chats.Chats.ChannelInfo.Region.noNewRegions)
      }
    }
  }

  /// What the fallback run on already-heard repeaters means while the gate is cooling down. Finding
  /// nobody to ask keeps the cooldown message, so the page still says why no scan was sent.
  static func cooldownResult(for fallback: RegionDiscoveryService.Outcome) -> Result {
    fallbackResult(for: fallback, reason: L10n.Tools.Tools.RegionDiscovery.cooldown)
  }

  /// What the fallback run on already-heard repeaters means when the radio's firmware can't send a
  /// scan. Finding nobody to ask keeps that message, so the page still says why no scan was sent.
  static func unsupportedResult(for fallback: RegionDiscoveryService.Outcome) -> Result {
    fallbackResult(for: fallback, reason: L10n.Tools.Tools.RegionDiscovery.scanUnsupported)
  }

  /// Nothing is sent when the radio's firmware can't ask repeaters for their regions (no
  /// anonymous requests before companion v1.12): the run ends with this, before any scan or
  /// query. Nil when it can.
  static func preflightResult(device: DeviceDTO) -> Result? {
    device.supportsAnonymousRequests ? nil : .nothingFound(message: L10n.Tools.Tools.RegionDiscovery.needsFirmware)
  }

  private static func fallbackResult(for fallback: RegionDiscoveryService.Outcome, reason: String) -> Result {
    switch fallback {
    case .sendFailed, .coolingDown, .discoverUnsupported, .noRepeatersResponded:
      .nothingFound(message: reason)
    case .errorLoadingRepeaters, .completed:
      result(for: fallback)
    }
  }

  /// Starts a run, cancelling any run still in flight.
  ///
  /// - Parameter nearbyRepeaters: Full public keys of the repeaters already confirmed nearby,
  ///   asked instead when the gate refuses a probe or the firmware can't send one. Nil reads the
  ///   Neighbour directory's confirmed full-key repeaters at that moment.
  func run(appState: AppState, nearbyRepeaters: Set<Data>? = nil) {
    task?.cancel()
    task = Task {
      isDiscovering = true
      message = nil
      defer { isDiscovering = false }

      guard let session = appState.services?.session,
            let contactService = appState.services?.contactService,
            let device = appState.connectedDevice else {
        return
      }
      if case let .nothingFound(message) = Self.preflightResult(device: device) {
        self.message = message
        return
      }

      let neighbours = appState.services?.neighbourService
      let coordinator = appState.probeCoordinator
      let outcome = await RegionDiscoveryService.discover(
        session: session,
        contactService: contactService,
        dataStore: appState.offlineDataStore,
        radioID: device.radioID,
        knownRegions: device.knownRegions,
        supportsAdHocRequest: device.supportsAdHocRepeaterRequest,
        supportsDiscoverRequest: device.supportsNodeDiscover,
        gate: appState.discoverGate,
        // replies to this probe are answers to our own scan in Scan for Nodes and CarPlay
        noteProbe: { tag, filter, date in await neighbours?.noteProbe(tag: tag, filter: filter, at: date) },
        // an open scan screen shows the cooldown this probe started straight away
        recorded: { await coordinator.refreshCooldown() }
      )

      guard !Task.isCancelled else { return }

      // No scan went out: the repeaters already heard nearby are asked instead.
      let askNearby: () async -> RegionDiscoveryService.Outcome = {
        await RegionDiscoveryService.queryRegions(
          responders: nearbyRepeaters ?? appState.neighbourDirectory.nearbyRepeaterKeys(),
          session: session,
          contactService: contactService,
          dataStore: appState.offlineDataStore,
          radioID: device.radioID,
          knownRegions: device.knownRegions,
          supportsAdHocRequest: device.supportsAdHocRepeaterRequest
        )
      }
      var result = Self.result(for: outcome)
      switch outcome {
      case .coolingDown:
        message = L10n.Tools.Tools.RegionDiscovery.cooldown
        let fallback = await askNearby()
        guard !Task.isCancelled else { return }
        result = Self.cooldownResult(for: fallback)
      case .discoverUnsupported:
        message = L10n.Tools.Tools.RegionDiscovery.scanUnsupported
        let fallback = await askNearby()
        guard !Task.isCancelled else { return }
        result = Self.unsupportedResult(for: fallback)
      default:
        break
      }

      switch result {
      case let .found(regions):
        discoveredRegions = regions
      case let .nothingFound(message):
        self.message = message
      }
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}
