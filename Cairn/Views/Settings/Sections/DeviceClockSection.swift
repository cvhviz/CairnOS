import CairnServices
import SwiftUI

/// Device Info › Clock (its own page, `SettingsDetail.clock`): the radio's clock and the zone its own
/// screen shows the time in.
/// The app sets the clock on every connect, and by default the zone to the phone's; this section
/// shows what the radio has, sets both on demand, and lets a radio keep a zone of its own.
struct DeviceClockSection: View {
  @Environment(\.appState) private var appState
  @AppStorage(ConnectionManager.deviceTimeZoneFollowsPhoneKey) private var followsPhone = true
  /// The radio's time and how far it was from the phone's when read; nil until read.
  @State private var deviceTime: Date?
  @State private var driftSeconds: Int?
  @State private var readFailed = false
  /// The radio clock's zone, in minutes from UTC; nil until read, or when the firmware has none.
  @State private var zoneMinutes: Int?
  @State private var zoneSupported = true
  @State private var isSyncingClock = false
  @State private var isSettingZone = false
  @State private var errorMessage: String?

  private var phoneZoneMinutes: Int { DeviceTimeZone.phoneOffsetMinutes() }

  var body: some View {
    CardFormSection(L10n.Settings.Clock.header, info: L10n.Settings.Clock.info) {
      ValueCard(
        L10n.Settings.Clock.deviceTime,
        systemImage: "clock",
        color: .teal,
        value: deviceTimeText
      )

      ActionCard(
        isSyncingClock ? L10n.Settings.Clock.syncing : L10n.Settings.Clock.syncNow,
        systemImage: "clock.arrow.2.circlepath",
        color: .teal
      ) {
        syncClock()
      }
      .overlay(alignment: .trailing) {
        if isSyncingClock {
          ProgressView()
            .controlSize(.small)
            .padding(.trailing, 12)
        }
      }
      .dimmedWhenDisabled()
      .radioDisabled(for: appState.connectionState, or: isSyncingClock)

      if zoneSupported {
        ToggleCard(
          L10n.Settings.Clock.followPhone,
          systemImage: "iphone",
          color: .teal,
          subtitle: L10n.Settings.Clock.followPhoneSubtitle(DeviceTimeZone.label(minutes: phoneZoneMinutes)),
          isBusy: isSettingZone,
          isOn: $followsPhone
        )
        .onChange(of: followsPhone) { _, isOn in
          // turning it on sets the phone's zone at once; off keeps whatever the radio has
          if isOn, zoneMinutes != phoneZoneMinutes { setZone(phoneZoneMinutes) }
        }
        .dimmedWhenDisabled()
        .radioDisabled(for: appState.connectionState, or: isSettingZone)

        if !followsPhone {
          PickerCard(
            L10n.Settings.Clock.zone,
            systemImage: "globe",
            color: .teal,
            selection: zoneSelection
          ) {
            ForEach(DeviceTimeZone.pickerOffsets, id: \.self) { minutes in
              Text(DeviceTimeZone.label(minutes: minutes)).tag(minutes)
            }
          }
          .dimmedWhenDisabled()
          .radioDisabled(for: appState.connectionState, or: isSettingZone || zoneMinutes == nil)
        }
      } else {
        ValueCard(
          L10n.Settings.Clock.zone,
          systemImage: "globe",
          color: .gray,
          value: L10n.Settings.Clock.zoneUnsupported
        )
      }
    }
    .task(id: appState.connectionState) {
      guard appState.connectionState == .ready else { return }
      await readClock()
    }
    .errorAlert($errorMessage)
  }

  /// The picker's binding: a pick writes the radio, the read-back lands in `zoneMinutes`.
  private var zoneSelection: Binding<Int> {
    Binding(
      get: { zoneMinutes ?? phoneZoneMinutes },
      set: { minutes in
        guard minutes != zoneMinutes else { return }
        setZone(minutes)
      }
    )
  }

  private var deviceTimeText: String {
    if readFailed { return L10n.Settings.Clock.noAnswer }
    guard let deviceTime, let driftSeconds else { return L10n.Settings.Clock.reading }
    // a clock the firmware never set reads as 2024 or earlier
    guard deviceTime.timeIntervalSince1970 > 1_735_689_600 else { return L10n.Settings.Clock.notSet }
    let time = deviceTime.formatted(date: .omitted, time: .shortened)
    if abs(driftSeconds) <= 5 { return L10n.Settings.Clock.inSync(time) }
    let drift = Duration.seconds(abs(driftSeconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    return driftSeconds > 0 ? L10n.Settings.Clock.ahead(time, drift) : L10n.Settings.Clock.behind(time, drift)
  }

  @MainActor
  private func readClock() async {
    guard let settingsService = appState.services?.settingsService else { return }
    readFailed = false
    do {
      let time = try await settingsService.getTime()
      deviceTime = time
      driftSeconds = Int(time.timeIntervalSinceNow.rounded())
    } catch {
      readFailed = true
    }
    if let minutes = await settingsService.getTimeZoneOffsetMinutes() {
      zoneMinutes = minutes
      zoneSupported = true
    } else {
      zoneSupported = false
    }
  }

  private func syncClock() {
    guard let settingsService = appState.services?.settingsService else { return }
    isSyncingClock = true
    Task { @MainActor in
      defer { isSyncingClock = false }
      do {
        try await settingsService.setTime(Date())
        if followsPhone, zoneSupported, zoneMinutes != phoneZoneMinutes {
          try await settingsService.setTimeZoneOffsetMinutes(phoneZoneMinutes)
        }
      } catch {
        errorMessage = error.userFacingMessage
      }
      await readClock()
    }
  }

  private func setZone(_ minutes: Int) {
    guard let settingsService = appState.services?.settingsService else { return }
    isSettingZone = true
    Task { @MainActor in
      defer { isSettingZone = false }
      do {
        try await settingsService.setTimeZoneOffsetMinutes(minutes)
      } catch {
        errorMessage = error.userFacingMessage
      }
      if let read = await settingsService.getTimeZoneOffsetMinutes() { zoneMinutes = read }
    }
  }
}
