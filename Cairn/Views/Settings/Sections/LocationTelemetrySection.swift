import CairnServices
import SwiftUI

/// Telemetry on GPS & Location: whether other nodes may ask, whether only trusted contacts may
/// (with who they are, one tap away), and whether a reply carries the position and the
/// environment sensors. Every switch is read from the radio, so a write that hasn't landed yet
/// doesn't show as done.
struct LocationTelemetrySection: View {
  let device: DeviceDTO

  @Environment(\.appState) private var appState
  @State private var trustedNames: [String] = []
  @State private var isSaving = false
  @State private var errorMessage: String?

  var body: some View {
    CardFormSection(
      L10n.Settings.Telemetry.header,
      info: L10n.Settings.Telemetry.footer + "\n\n" + L10n.Settings.Telemetry.allowRequestsDescription
    ) {
      ToggleCard(
        L10n.Settings.Telemetry.allowRequests,
        systemImage: "chart.bar.doc.horizontal.fill",
        color: .teal,
        subtitle: L10n.Settings.Telemetry.allowRequestsDescription,
        isOn: telemetryBinding(\.telemetryModeBase) { TelemetrySwitches.modes(device, base: $0) }
      )
      .radioDisabled(for: appState.connectionState, or: isSaving)

      if TelemetrySwitches.isOn(device.telemetryModeBase) {
        groupedCard {
          Toggle(isOn: Binding(
            get: { TelemetrySwitches.isTrustedOnly(device) },
            set: { saveTelemetry(TelemetrySwitches.modes(device, trustedOnly: $0)) }
          )) {
            SettingCardLabel(
              L10n.Settings.Telemetry.trustedOnly,
              systemImage: "person.badge.shield.checkmark.fill",
              color: .green,
              subtitle: L10n.Settings.Telemetry.trustedOnlyDescription
            )
          }
          .radioDisabled(for: appState.connectionState, or: isSaving)
          if TelemetrySwitches.isTrustedOnly(device) {
            rowDivider
            manageTrustedRow
          }
        }

        groupedCard {
          Toggle(isOn: telemetryBinding(\.telemetryModeLoc) { TelemetrySwitches.modes(device, location: $0) }) {
            SettingCardLabel(
              L10n.Settings.Telemetry.includeLocation,
              // Not the advert's location.fill: a different switch.
              systemImage: "mappin.circle.fill",
              color: .indigo,
              subtitle: L10n.Settings.Telemetry.includeLocationDescription
            )
          }
          .radioDisabled(for: appState.connectionState, or: isSaving)
          rowDivider
          Toggle(isOn: telemetryBinding(\.telemetryModeEnv) { TelemetrySwitches.modes(device, environment: $0) }) {
            SettingCardLabel(
              L10n.Settings.Telemetry.includeEnvironment,
              systemImage: "thermometer.medium",
              color: .orange,
              subtitle: L10n.Settings.Telemetry.includeEnvironmentDescription
            )
          }
          .radioDisabled(for: appState.connectionState, or: isSaving)
        }
      }
    }
    .task(id: device.radioID) { await loadTrustedNames() }
    .errorAlert($errorMessage)
  }

  /// Rows sharing one card, as a Settings group: the related switches read as one choice.
  private func groupedCard(@ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      content()
    }
    .cardSurface(padding: 12)
  }

  /// A hairline under the row's text, past its icon tile, as in a Settings group.
  private var rowDivider: some View {
    Divider()
      .padding(.leading, 44)
  }

  /// Who is trusted, inside the trusted switch's card: their names, and the list one tap away.
  private var manageTrustedRow: some View {
    NavigationLink {
      TrustedContactsPickerView()
        .onDisappear { Task { await loadTrustedNames() } }
    } label: {
      HStack(spacing: 8) {
        SettingCardLabel(
          L10n.Settings.Telemetry.manageTrusted,
          systemImage: "person.2.fill",
          color: .green,
          subtitle: trustedNames.isEmpty ? nil : trustedNames.joined(separator: ", ")
        )
        .lineLimit(2)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
          .accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityValue(trustedNames.formatted(.list(type: .and)))
  }

  /// The names of the contacts trusted to ask, most familiar first (favorites, then by name).
  private func loadTrustedNames() async {
    guard let contactService = appState.services?.contactService else { return }
    let contacts = (try? await contactService.getContacts(radioID: device.radioID)) ?? []
    trustedNames = contacts
      .filter { $0.type == .chat && ContactService.hasTelemetryPermissions(flags: $0.flags) }
      .sorted { lhs, rhs in
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
      }
      .map(\.displayName)
  }

  private func telemetryBinding(
    _ mode: KeyPath<DeviceDTO, UInt8>,
    modes: @escaping (Bool) -> TelemetryModes
  ) -> Binding<Bool> {
    Binding(
      get: { TelemetrySwitches.isOn(device[keyPath: mode]) },
      set: { saveTelemetry(modes($0)) }
    )
  }

  private func saveTelemetry(_ modes: TelemetryModes) {
    guard let settingsService = appState.services?.settingsService else { return }
    isSaving = true
    Task {
      do {
        _ = try await settingsService.setOtherParamsVerified(from: device, telemetryModes: modes)
      } catch {
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }
}
