import Foundation
import CairnServices
import MeshCore

// MARK: - Service Wiring Helpers

extension AppState {
  /// Consume the sync coordinator's data event stream for SwiftUI observation
  /// (actors don't participate in SwiftUI's observation system).
  /// Message events are ignored here; `MessageEventDispatcher` owns them.
  /// Re-subscribes per connection because `ServiceContainer` is rebuilt.
  func wireSyncDataEvents(services: ServiceContainer) {
    syncDataEventsTask?.cancel()
    let events = services.syncCoordinator.dataEvents()
    syncDataEventsTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .contactsChanged:
          contactsBumpThrottle.request { [weak self] in self?.contactsVersion += 1 }
        case .conversationsChanged:
          conversationsBumpThrottle.request { [weak self] in self?.refreshConversations() }
        case let .radioSentMessage(message):
          // Sent from the radio's own UI: the Traffic maps start its repeats at this radio.
          TrafficSentLog.shared.record(radioSent: message)
        case .directMessageReceived, .channelMessageReceived, .roomMessageReceived, .reactionReceived:
          break
        }
      }
    }
  }

  /// Re-binds the neighbour directory and the probe coordinator to this connection's
  /// `NeighbourService` and session. Both outlive the container: the directory keeps its last
  /// snapshot until the new service has warmed up, and a probe in its window carries on as
  /// interrupted. Re-wiring the same container changes nothing.
  func wireNeighbours(services: ServiceContainer) {
    guard let device = connectedDevice else { return }
    let probeCoordinator = probeCoordinator
    neighbourDirectory.onSnapshot = { [weak probeCoordinator] snapshot in
      probeCoordinator?.noteSnapshot(snapshot)
    }
    neighbourDirectory.bind(to: services.neighbourService, radioID: device.radioID)
    probeCoordinator.bind(.live(services: services, device: device))
    // The Spectrum readings' minute averages are kept under this radio (SpectrumReadingsStore).
    spectrumFeed.model.readingsRadioID = device.radioID
  }

  /// Consume settings service event stream.
  /// Updates connectedDevice when settings are changed via SettingsService.
  func wireSettingsEventStream(services: ServiceContainer) async {
    settingsEventsTask?.cancel()
    let events = await services.settingsService.events()
    // A concurrent wiring may have installed its own task during the await;
    // cancel it too so only one consumer survives.
    settingsEventsTask?.cancel()
    settingsEventsTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case let .deviceUpdated(selfInfo, appliedRadioPresetID):
          await MainActor.run {
            self.connectionManager.updateDevice(from: selfInfo, appliedRadioPresetID: appliedRadioPresetID)
          }
        case let .autoAddConfigUpdated(config):
          await MainActor.run {
            self.connectionManager.updateAutoAddConfig(config)
            // Clear storage full flag when overwrite oldest is enabled
            if config.bitmask & AutoAddConfig.overwriteOldestBit != 0 {
              self.connectionUI.isNodeStorageFull = false
            }
          }
        case let .clientRepeatUpdated(enabled):
          await MainActor.run {
            self.connectionManager.updateClientRepeat(enabled)
          }
        case let .pathHashModeUpdated(mode):
          await MainActor.run {
            self.connectionManager.updatePathHashMode(mode)
          }
        case let .allowedRepeatFreqUpdated(ranges):
          await MainActor.run {
            self.connectionManager.allowedRepeatFreqRanges = ranges
          }
        case let .defaultFloodScopeUpdated(name):
          await MainActor.run {
            self.connectionManager.updateDefaultFloodScopeName(name)
          }
        }
      }
    }
  }

  /// Wire device update and contact change callbacks.
  /// Updates connectedDevice when local device settings (like OCV) are changed via DeviceService,
  /// and handles contact updates/deletions for real-time Discover page updates.
  func wireDeviceUpdateCallbacks(services: ServiceContainer) async {
    await services.deviceService.setDeviceUpdateCallback { [weak self] deviceDTO in
      await MainActor.run {
        self?.connectionManager.updateDevice(with: deviceDTO)
      }
    }

    // Contact updates bump contactsVersion for real-time Discover page
    // updates; contact-deleted cleanup removes notifications and refreshes
    // the badge when the device auto-deletes a contact via 0x8F.
    // Re-subscribes per connection because ServiceContainer is rebuilt.
    advertisementEventsTask?.cancel()
    let advertisementEvents = services.advertisementService.events()
    // ConnectionManager nils `services` before `tearDown` yields `.contactDeletedCleanup`.
    // Capture `notificationService` so `removeDeliveredNotifications` still runs.
    let notificationService = services.notificationService
    advertisementEventsTask = Task { [weak self] in
      for await event in advertisementEvents {
        guard let self else { return }
        switch event {
        case .contactUpdated:
          contactsBumpThrottle.request { [weak self] in
            guard let self else { return }
            contactsVersion += 1
            PersistentLogger(subsystem: "cvhvisuals.Cairn", category: "discover-trace")
              .debug("B4 contactUpdated bump contactsVersion=\(contactsVersion)")
          }
        case .conversationsChanged:
          conversationsBumpThrottle.request { [weak self] in self?.refreshConversations() }
        case let .contactDeletedCleanup(contactIDs):
          await notificationService.removeDeliveredNotifications(
            forContactIDs: Set(contactIDs)
          )
          if !contactIDs.isEmpty {
            await notificationService.updateBadgeCount()
          }
        case let .advertReceived(publicKey):
          // Counted until the Nodes tab is next opened, for its badge and Home's Nodes card.
          if navigation.selectedTab != AppTab.contacts.rawValue {
            unseenAdvertCount += 1
          }
          await liveActivityManager.handleAdvertReceived(publicKey: publicKey)
          noteWidgetNodeHeard(publicKey: publicKey)
        case .newContactDiscovered, .nodeStorageFullChanged,
             .pathDiscoveryResponse, .contactPathUpdated, .traceResponse, .traceSnrObserved, .traceProgress,
             .orphanDirectMessagesAdopted:
          // The paired .conversationsChanged already refreshes the list; the
          // banner and badge are handled by the SyncCoordinator consumer. A path
          // response that changed the stored contact or its heard time also yields
          // .contactUpdated, which bumps contactsVersion above.
          break
        }
      }
    }
  }

  /// Wire the message event streams. Delegates to `MessageEventDispatcher`,
  /// which subscribes to the service event streams and fans them out to
  /// `messageEventStream` and `sessionStateChangeCount`.
  func wireMessageEvents(services: ServiceContainer) {
    messageEventDispatcher.wire(services: services)
  }

  /// Wire Live Activity callbacks for RX freshness, battery, and connection lifecycle.
  func wireLiveActivityCallbacks(services: ServiceContainer) async {
    // Every received RF packet refreshes Live Activity freshness and may
    // trigger an overdue battery read. Re-subscribes per connection
    // because ServiceContainer is rebuilt.
    rxLogEventsTask?.cancel()
    let rxLogEntries = services.rxLogService.entryStream()
    rxLogEventsTask = Task { [weak self] in
      for await entry in rxLogEntries {
        guard let self else { return }
        radioActivity.recordReceived()
        await liveActivityManager.handlePacketReceived(rssi: entry.rssi, snr: entry.snr)
        if liveActivityManager.hasActiveActivity {
          await batteryMonitor.fetchBatteryIfOverdue(
            services: self.services, device: connectedDevice
          )
        }
      }
    }

    // Every command that makes the radio transmit (a direct or channel message, an advert, a
    // request and its retransmits, a trace, a login): the session reports each as it's written,
    // then the radio's answer to it. The activity LED flashes on each write.
    // The Traffic maps and the RX Log list mirror what `OwnTransmissionService` records of the
    // same writes and answers (the radio reports nothing it transmits), so a send pulses as it's
    // written and a repeater's echo of it starts at this radio; and a path discovery's answer,
    // for the routes out and back it reports.
    sentPacketEventsTask?.cancel()
    let transmissions = await services.session.transmissions()
    let routeEvents = services.advertisementService.events()
    TrafficSentLog.shared.bind(to: services.ownTransmissionService)
    let radioActivity = radioActivity
    sentPacketEventsTask = Task {
      let routeTask = Task { @MainActor in
        for await event in routeEvents {
          if case let .pathDiscoveryResponse(info) = event {
            TrafficSentLog.shared.recordDiscovery(OwnPathDiscovery(info, at: .now))
          }
        }
      }
      defer { routeTask.cancel() }
      for await event in transmissions {
        if case .written = event {
          radioActivity.recordSent()
        }
      }
    }

    // The noise floor and the radio's GPS fix ride on the battery poll, each on its own longer
    // interval, so the activity never asks the radio for more than the poll already does. They
    // are read first and staged, so the battery change sends all of it in one update.
    batteryMonitor.onBatteryChanged = { [weak self] battery in
      Task { @MainActor [weak self] in
        await self?.refreshLiveActivityRadioReadings()
        await self?.liveActivityManager.handleBatteryChanged(battery: battery)
        self?.publishWidgetSnapshot()
      }
    }

    let device = connectedDevice
    let ocvArray = batteryMonitor.activeBatteryOCVArray(for: device)
    let unreadCount = await totalUnreadCount(from: services)

    // The link may have dropped (or a newer container landed) during the await;
    // don't resurrect a "connected" activity for a dead container.
    if let device, self.services === services {
      await liveActivityManager.handleConnectionReady(
        device: device,
        ocvArray: ocvArray,
        unreadCount: unreadCount,
        battery: batteryMonitor.deviceBattery
      )
      widgetSnapshotPublisher.unreadCount = unreadCount
      publishWidgetSnapshot()
    }
  }

  /// Reads the noise floor and the radio's own telemetry for the Live Activity when each is due
  /// (see `LiveActivityManager.claimDueRadioReads`). A failed or unsupported read leaves what the
  /// activity shows; the noise floor isn't asked of firmware without the stats command (companion
  /// v1.11+). The reads wait for a quiet link first, so on official firmware they don't crowd
  /// pushed packets out of the radio's send queue.
  func refreshLiveActivityRadioReadings() async {
    guard let services else { return }
    let due = liveActivityManager.claimDueRadioReads()
    let readsStats = due.stats && (connectedDevice?.supportsStats ?? false)
    guard readsStats || due.telemetry else { return }

    await services.session.waitForQuietLink(maxWait: .seconds(2))
    var noiseFloor: Int?
    if readsStats, let stats = try? await services.settingsService.getStatsRadio() {
      noiseFloor = Int(stats.noiseFloor)
    }
    var telemetry: [LPPDataPoint]?
    if due.telemetry, let response = try? await services.binaryProtocolService.getSelfTelemetry() {
      telemetry = LPPDecoder.decode(response.rawData)
    }
    // The link may have dropped or moved to another container during the reads.
    guard self.services === services, noiseFloor != nil || telemetry != nil else { return }
    await liveActivityManager.handleRadioReadings(
      device: connectedDevice,
      noiseFloor: noiseFloor,
      telemetry: telemetry
    )
  }

  /// Shows a received direct message on the Live Activity, unless the contact is muted.
  func noteLiveActivityMessage(_ message: MessageDTO, contact: ContactDTO) async {
    guard !contact.isMuted else { return }
    await liveActivityManager.handleMessageReceived(MeshStatusAttributes.LastMessage(
      sender: contact.displayName,
      channelName: nil,
      preview: MeshStatusAttributes.LastMessage.preview(of: MessagePreviewFormatter.preview(message.text)),
      date: Self.liveActivityMessageDate(message)
    ))
  }

  /// Shows a received channel message on the Live Activity (and CarPlay's Dashboard), named by
  /// its channel, when it would notify: not on a muted channel, only mentions of you on a
  /// mentions-only one, and never on a slot the app has no channel for.
  func noteLiveActivityMessage(_ message: MessageDTO, channelIndex: UInt8) async {
    guard liveActivityManager.collectsReadings, let services else { return }
    let channel = await (try? services.dataStore.fetchChannel(radioID: message.radioID, index: channelIndex)) ?? nil
    guard let channel, !channel.isMuted else { return }
    if channel.notificationLevel == .mentionsOnly, !message.containsSelfMention { return }
    await liveActivityManager.handleMessageReceived(MeshStatusAttributes.LastMessage(
      // Named as the Chats list names a channel sender: the contact's nickname when one contact
      // has that name, else the name on air.
      sender: nodeAppearance.names.channelSenders.shortName(for: message.senderNodeName)
        ?? L10n.Chats.Chats.Message.Sender.unknown,
      channelName: channel.displayName,
      preview: MeshStatusAttributes.LastMessage.preview(of: MessagePreviewFormatter.preview(message.text)),
      date: Self.liveActivityMessageDate(message)
    ))
  }

  /// When the message was sent: the sender's clock-corrected time, so a backlog drained on
  /// reconnect doesn't read "now". Never later than its arrival, so a slightly fast sender
  /// clock can't make it read "in 1 min".
  static func liveActivityMessageDate(_ message: MessageDTO) -> Date {
    min(message.senderDate, message.createdAt)
  }

  /// `Activity.request` only succeeds in the foreground, so a `startActivity`
  /// triggered from background (e.g. BLE auto-reconnect after the disconnect
  /// grace timer fired) throws and leaves `currentActivity` nil. iOS may also
  /// end an activity from background — 8-hour active cap, 12-hour total, or
  /// memory pressure — in which case the `.dismissed` branch in
  /// `validateActivityState` clears the reference without restarting. Both
  /// leave the radio connected with no LA on screen.
  func restartLiveActivityIfMissing() async {
    guard connectionState.isConnected,
          liveActivityManager.isEnabled,
          !liveActivityManager.hasActiveActivity,
          let device = connectedDevice,
          let services else { return }

    let ocvArray = batteryMonitor.activeBatteryOCVArray(for: device)
    let unreadCount = await totalUnreadCount(from: services)
    await liveActivityManager.handleConnectionReady(
      device: device,
      ocvArray: ocvArray,
      unreadCount: unreadCount,
      battery: batteryMonitor.deviceBattery,
      isNewLink: false
    )
  }

  func totalUnreadCount(from services: ServiceContainer) async -> Int {
    guard let radioID = currentRadioID else { return 0 }
    let counts = await (try? services.dataStore.getTotalUnreadCounts(radioID: radioID))
      ?? (contacts: 0, channels: 0, rooms: 0)
    return counts.contacts + counts.channels + counts.rooms
  }
}

// MARK: - Version Bump Throttle

/// Paces a burst of change signals to at most one action per `interval`: the first runs at once,
/// later ones inside the interval fold into a single trailing run, so the newest state is always
/// delivered and a quiet change never waits.
@MainActor
final class VersionBumpThrottle {
  private let interval: Duration
  private var lastRun: ContinuousClock.Instant?
  private var trailing: Task<Void, Never>?

  init(interval: Duration) {
    self.interval = interval
  }

  func request(_ action: @escaping @MainActor () -> Void) {
    // A trailing run is already scheduled; it runs after this request, so it covers it.
    guard trailing == nil else { return }
    let now = ContinuousClock.now
    guard let lastRun, now - lastRun < interval else {
      lastRun = now
      action()
      return
    }
    let delay = interval - (now - lastRun)
    trailing = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self else { return }
      trailing = nil
      self.lastRun = .now
      action()
    }
  }
}
