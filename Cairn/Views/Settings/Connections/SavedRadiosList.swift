import CairnServices
import SwiftUI

/// The Radios segment's list: the connected radio pinned on top with its quick actions, then the
/// radios heard nearby and the rest, each section foldable, as card rows in a lazy `List` so
/// hundreds of saved radios scroll like the Nodes list. On a phone a tap connects and the chevron
/// opens the radio's page; beside a detail pane (iPad, Mac) a tap selects.
struct SavedRadiosList: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  let model: ConnectionsModel
  let sections: SavedRadioSections
  let isSearching: Bool
  /// The radio shown in the detail pane; nil on a phone, where rows connect.
  @Binding var selection: String?
  let showsDetailPane: Bool
  let onOpenDetail: (String) -> Void
  let onAddBluetooth: () -> Void
  let onAddWiFi: () -> Void

  @State private var collapsed: Set<Section> = []
  @AppStorage(AppStorageKey.connectOnLaunch.rawValue)
  private var connectOnLaunch = AppStorageKey.defaultConnectOnLaunch

  enum Section: Hashable {
    case nearby
    case saved
  }

  var body: some View {
    List {
      // The switch first, so the list under it is only radios.
      if !isSearching, !sections.isEmpty {
        connectOnLaunchRow
      }
      if let connected = sections.connected {
        header(L10n.Settings.Connections.Section.connected, section: nil, count: nil)
        connectedRow(connected)
      }
      group(.nearby, title: L10n.Settings.Connections.Section.nearby, rows: sections.nearby)
      group(.saved, title: L10n.Settings.Connections.Section.saved, rows: sections.saved)
      if !isSearching, !model.loaded.list.needsSetup.isEmpty {
        header(L10n.Settings.Connections.Section.pairedElsewhere, section: nil, count: nil)
        ForEach(model.loaded.list.needsSetup) { accessory in
          setUpRow(accessory)
        }
      }
      if !isSearching, !sections.isEmpty {
        footer(
          connectOnLaunch
            ? L10n.Settings.Connections.SavedRadios.footer
            : L10n.Settings.Connections.SavedRadios.footerManual
        )
        if showsWiFiBackgroundNote {
          footer(L10n.Settings.Connections.WifiBackground.footer)
          if BackgroundRefreshNotice.isShowing {
            BackgroundRefreshNotice()
              .cardListRow(theme)
          }
        }
      }
    }
    .cardListCanvas(theme)
    .overlay {
      if model.hasLoaded, sections.isEmpty, model.loaded.list.needsSetup.isEmpty {
        if isSearching {
          ContentUnavailableView.search
        } else {
          emptyState
        }
      }
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private func group(_ section: Section, title: String, rows: [SavedRadioRow]) -> some View {
    if !rows.isEmpty {
      header(title, section: section, count: rows.count)
      if !collapsed.contains(section) {
        ForEach(rows) { row in
          radioRow(row)
        }
      }
    }
  }

  /// A section title in the card form's header style, on the canvas rather than a card; a
  /// foldable one shows its count and a chevron.
  private func header(_ title: String, section: Section?, count: Int?) -> some View {
    HStack(spacing: 6) {
      Text(title)
      if let count {
        Text(count.formatted())
          .monospacedDigit()
      }
      Spacer(minLength: 0)
      if let section {
        Image(systemName: "chevron.down")
          .rotationEffect(.degrees(collapsed.contains(section) ? -90 : 0))
          .accessibilityHidden(true)
      }
    }
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(Color.secondary)
    .contentShape(.rect)
    .onTapGesture {
      guard let section else { return }
      if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
    }
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets(top: 14, leading: CardStyle.pageInset + 4, bottom: 2, trailing: CardStyle.pageInset + 4))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(section == nil ? .isHeader : [.isHeader, .isButton])
    .accessibilityValue(section.map { collapsed.contains($0) ? L10n.Settings.Connections.Accessibility.collapsed : L10n.Settings.Connections.Accessibility.expanded } ?? "")
  }

  /// Whether opening Cairn reconnects to the default radio (the one connected last), above the
  /// radios it applies to.
  private var connectOnLaunchRow: some View {
    Toggle(isOn: $connectOnLaunch) {
      // One line: the footer under the list says what it does (the two-line card was too big, 2026-11-07).
      SettingCardLabel(
        L10n.Settings.Connections.ConnectOnLaunch.title,
        systemImage: "bolt.horizontal.circle.fill",
        color: .green
      )
    }
    .accessibilityIdentifier("connections.connectOnLaunch")
    .cardListRow(theme)
  }

  /// Over WiFi the radio reaches a closed app only through Background App Refresh, unlike
  /// Bluetooth; said while the radio in use is on WiFi. Not on a Mac, where the app keeps running.
  private var showsWiFiBackgroundNote: Bool {
    appState.connectionManager.currentTransportType == .wifi
      && appState.connectionState != .disconnected
      && !ProcessInfo.processInfo.isiOSAppOnMac
  }

  /// A note under the list, in the card form's footer style.
  private func footer(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(Color.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 8, leading: CardStyle.pageInset + 4, bottom: 16, trailing: CardStyle.pageInset + 4))
  }

  // MARK: - Rows

  private func radioRow(_ row: SavedRadioRow) -> some View {
    let status = model.status(for: row, appState: appState)
    let view = SavedRadioRowView(
      row: row,
      status: status,
      activeTransport: nil,
      signalTier: model.signalTier(row),
      onOpenDetail: showsDetailPane ? nil : { onOpenDetail(row.id) }
    )
    return Button {
      if showsDetailPane {
        selection = row.id
      } else if !model.isOutOfRange(row) {
        model.requestConnect(row, appState: appState)
      }
    } label: {
      view
    }
    .buttonStyle(.plain)
    .cardListRow(theme, isSelected: showsDetailPane && selection == row.id)
    .contextMenu { SavedRadioMenuItems(model: model, row: row) }
    .swipeActions(edge: .trailing) {
      Button(L10n.Settings.Connections.Action.forget, systemImage: "trash", role: .destructive) {
        model.forgetting = row
      }
      Button(L10n.Settings.Connections.Action.rename, systemImage: "pencil") {
        model.beginRename(row)
      }
      .tint(.orange)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(row.displayName)
    .accessibilityValue(view.accessibilityValue)
    .accessibilityHint(showsDetailPane
      ? L10n.Settings.Connections.Accessibility.selectHint
      : (model.isOutOfRange(row)
        ? L10n.Settings.DeviceSelection.Accessibility.outOfRangeHint
        : L10n.Settings.DeviceSelection.Accessibility.selectHint))
    .accessibilityActions {
      SavedRadioMenuItems(model: model, row: row)
      if !showsDetailPane {
        Button(L10n.Settings.Connections.Accessibility.details(row.displayName)) { onOpenDetail(row.id) }
      }
    }
  }

  /// The radio in use, pinned on top: its row, then Device Info and Disconnect a tap away.
  private func connectedRow(_ row: SavedRadioRow) -> some View {
    let status = model.status(for: row, appState: appState)
    let view = SavedRadioRowView(
      row: row,
      status: status,
      activeTransport: appState.connectionManager.currentTransportType,
      signalTier: nil,
      onOpenDetail: showsDetailPane ? nil : { onOpenDetail(row.id) }
    )
    return VStack(alignment: .leading, spacing: 10) {
      Button {
        if showsDetailPane {
          selection = row.id
        } else {
          appState.navigation.settingsPath.append(.deviceInfo)
        }
      } label: {
        view
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(row.displayName)
      .accessibilityValue(view.accessibilityValue)
      .accessibilityHint(showsDetailPane
        ? L10n.Settings.Connections.Accessibility.selectHint
        : L10n.Settings.Connections.Accessibility.openDeviceInfoHint)

      // Two equal buttons at full size: Device Info in the theme's accent, Disconnect in the red every
      // other Disconnect in the app uses (ActionCard's destructive role). Glass styles ignore a
      // button's role, so the tint carries it. Styled buttons, so a tap on one isn't a tap on the row.
      HStack(spacing: 8) {
        Button {
          appState.navigation.settingsPath.append(.deviceInfo)
        } label: {
          Label(L10n.Settings.DeviceInfo.title, systemImage: "info.circle")
            .frame(maxWidth: .infinity)
        }
        .tint(theme.accentColor)
        Button(role: .destructive) {
          model.disconnect(appState)
        } label: {
          Label(L10n.Settings.BleStatus.disconnect, systemImage: "eject")
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
        }
        .tint(.red)
      }
      .liquidGlassSecondaryButtonStyle()
      .controlSize(.regular)
    }
    .cardListRow(theme, isSelected: showsDetailPane && selection == row.id)
    .contextMenu { SavedRadioMenuItems(model: model, row: row) }
  }

  /// A radio iOS still holds a pairing for that Cairn has no record of: the picker's Set Up row.
  private func setUpRow(_ accessory: SystemPairedAccessory) -> some View {
    let presentation = DeviceSelectionListBuilder.needsSetupPresentation(name: accessory.name)
    return Button {
      model.setUp(accessory, appState: appState)
    } label: {
      HStack(spacing: 12) {
        IconTile(systemImage: "antenna.radiowaves.left.and.right", color: .green)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(accessory.name)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.primary)
          Text(L10n.Settings.DeviceSelection.setupFooter)
            .font(.caption)
            .foregroundStyle(Color.secondary)
        }
        Spacer(minLength: 8)
        Text(presentation.trailingTitle)
          .foregroundStyle(Color.accentColor)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .cardListRow(theme)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(presentation.accessibilityLabel)
    .accessibilityHint(presentation.accessibilityHint)
  }

  /// No saved radio yet: the picker's empty state, its two ways in.
  private var emptyState: some View {
    ContentUnavailableView {
      Label(L10n.Settings.DeviceSelection.noPairedDevices, systemImage: "antenna.radiowaves.left.and.right.slash")
    } description: {
      Text(L10n.Settings.Connections.SavedRadios.empty)
    } actions: {
      Button(L10n.Settings.DeviceSelection.scanForDevices, systemImage: "antenna.radiowaves.left.and.right", action: onAddBluetooth)
        .liquidGlassProminentButtonStyle()
      Button(L10n.Settings.DeviceSelection.connectViaWifi, systemImage: "wifi.circle", action: onAddWiFi)
        .liquidGlassProminentButtonStyle()
    }
  }
}
