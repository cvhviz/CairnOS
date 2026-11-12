import CairnServices
import CairnUpdateKit
import MeshCore
import SwiftUI
import UniformTypeIdentifiers

/// Firmware Update, from Device Info's firmware card on Cairn touch firmware: the build on the
/// board and the latest release up top, then the latest release or a file to install. The board
/// asks its person to allow the update, its Bluetooth goes off while the image goes over WiFi, and
/// the page stays through the drop until the radio is back on the new build.
struct FirmwareUpdateView: View {
  @Environment(\.appState) private var appState
  @State private var viewModel = FirmwareUpdateViewModel()
  /// An nRF52 companion (Heltec T096) linked over Bluetooth: updated with Nordic DFU from the
  /// release's `.uf2` instead of the touch boards' WiFi upload. Made once, as the page opens, so
  /// the update outlives the link dropping for it.
  @State private var nordic: NordicFirmwareUpdateModel?
  @State private var checkedNordic = false

  private var isReady: Bool { appState.connectionState == .ready }

  var body: some View {
    CardForm {
      if let nordic {
        NordicFirmwareUpdateContent(model: nordic)
      } else {
        touchBoardContent
      }
    }
    .flashingNavigationTitle(L10n.Settings.FirmwareUpdate.title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(viewModel.phase.holdsScreen || nordic?.phase.holdsScreen == true)
    .errorAlert($viewModel.errorMessage)
    // Read on open once the radio is ready, and notice it coming back after the update.
    .task(id: isReady) {
      if !checkedNordic {
        checkedNordic = true
        nordic = Self.nordicModel(appState: appState)
      }
      guard nordic == nil else { return }
      viewModel.configure(dependencies: .live(appState: appState))
      if isReady {
        await viewModel.radioBecameReady()
      }
    }
    .modifier(TouchBoardUpdateHandlers(viewModel: viewModel))
  }

  /// The Nordic update for the connected radio, when it's an nRF52 companion this app can update
  /// over its Bluetooth link.
  private static func nordicModel(appState: AppState) -> NordicFirmwareUpdateModel? {
    guard let device = appState.connectedDevice,
          appState.connectionManager.currentTransportType == .bluetooth,
          let target = NordicFirmwareTarget(boardName: device.manufacturerName, role: .companion) else { return nil }
    let peripheralID = device.primaryConnectionMethod?.bluetoothPeripheralID ?? device.id
    let installed = device.cairnFirmwareName ?? device.firmwareVersionString
    return NordicFirmwareUpdateModel(
      target: target,
      installed: installed.isEmpty ? nil : installed,
      mode: .companion(peripheralID: peripheralID),
      link: .init(
        release: { [appState] in
          // The radio's pages stay while the link is down on purpose, as for the WiFi update.
          appState.navigation.holdsDevicePagesForUpdate = true
          await appState.disconnect(reason: .firmwareUpdate)
        },
        restore: { [appState] in
          defer { appState.navigation.holdsDevicePagesForUpdate = false }
          // The board restarts on the new firmware (twice with the clean-entry firmware): give it
          // a moment, then try for about a minute.
          for attempt in 0..<12 {
            try? await Task.sleep(for: .seconds(attempt == 0 ? 4 : 5))
            do {
              try await appState.connectionManager.connect(to: peripheralID, forceFullSync: true, forceReconnect: true)
              await appState.wireServicesIfConnected()
              return true
            } catch is CancellationError {
              return false
            } catch {
              continue
            }
          }
          return false
        }
      ),
      deviceID: device.id
    )
  }

  @ViewBuilder
  private var touchBoardContent: some View {
      switch viewModel.phase {
      case .unsupported:
        ContentUnavailableView(
          L10n.Settings.FirmwareUpdate.Unsupported.title,
          systemImage: "memorychip",
          description: Text(L10n.Settings.FirmwareUpdate.Unsupported.message)
        )
        .emptyStateFrame(below: CardStyle.formVerticalInset * 2)
      case .checking where appState.connectedDevice == nil:
        ContentUnavailableView(
          L10n.Settings.DeviceInfo.NoDevice.title,
          systemImage: "antenna.radiowaves.left.and.right.slash",
          description: Text(L10n.Settings.DeviceInfo.NoDevice.description)
        )
        .emptyStateFrame(below: CardStyle.formVerticalInset * 2)
      default:
        CardFormSection {
          tiles
        }
        progressSection
      }
  }

  // MARK: - Tiles

  /// The build on the board, the latest release, and the board's WiFi, which the update needs.
  @ViewBuilder
  private var tiles: some View {
    MetricTileGrid {
      MetricTile(
        L10n.Settings.FirmwareUpdate.installed,
        systemImage: "memorychip",
        value: viewModel.status?.build ?? L10n.Settings.FirmwareUpdate.checking,
        caption: viewModel.board?.displayName
      )
      MetricTile(
        L10n.Settings.FirmwareUpdate.latest,
        systemImage: "shippingbox",
        value: latestValue,
        caption: latestCaption,
        valueTint: viewModel.updateAvailable == true ? .green : nil
      )
      MetricTile(
        L10n.Settings.Wifi.header,
        systemImage: wifiSymbol,
        value: wifiValue,
        caption: viewModel.status?.ipAddress
      )
    }
    // What changed in the latest release, on its GitHub page.
    if let latest = viewModel.latest, let pageURL = latest.pageURL {
      ExternalLinkTile(
        L10n.Settings.FirmwareUpdate.releaseNotes,
        accessibilityLabel: L10n.Settings.FirmwareUpdate.ReleaseNotes.accessibility(latest.title),
        systemImage: "doc.text",
        color: .blue,
        url: pageURL
      )
    }
  }

  private var latestValue: String {
    if let latest = viewModel.latest { return latest.title }
    if viewModel.latestFailed { return L10n.Settings.FirmwareUpdate.latestUnavailable }
    return viewModel.isCheckingLatest || viewModel.status == nil ? L10n.Settings.FirmwareUpdate.checking : "–"
  }

  /// When the release was published; before that is known, whether it is newer than the board's.
  private var latestCaption: String? {
    FirmwareReleaseCaption.caption(publishedAt: viewModel.latest?.publishedAt, updateAvailable: viewModel.updateAvailable)
  }

  private var wifiValue: String {
    switch viewModel.status?.wifi {
    case .connected?: L10n.Settings.FirmwareUpdate.wifiConnected
    case .notConnected?: L10n.Settings.FirmwareUpdate.wifiNotConnected
    case .off?, .notInBuild?: L10n.Settings.FirmwareUpdate.wifiOff
    case nil: viewModel.status == nil ? L10n.Settings.FirmwareUpdate.checking : "–"
    }
  }

  private var wifiSymbol: String {
    viewModel.status?.wifi == .connected ? "wifi" : "wifi.slash"
  }

  // MARK: - Progress

  @ViewBuilder
  private var progressSection: some View {
    switch viewModel.phase {
    case .checking, .unsupported:
      EmptyView()
    case .noAnswer:
      CardFormSection(footer: L10n.Settings.FirmwareUpdate.Error.noAnswer) {
        checkAgainCard
      }
    case .ready, .preparing, .reaching:
      sourceSection
    case .asking:
      CardFormSection {
        ContentCard(L10n.Settings.FirmwareUpdate.Asking.title, systemImage: "hand.tap", color: .orange) {
          HStack(spacing: 10) {
            ProgressView()
            Text(L10n.Settings.FirmwareUpdate.Asking.message)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        ActionCard(L10n.Localizable.Common.cancel, systemImage: "xmark.circle", role: .destructive) {
          viewModel.cancelAsking()
        }
      }
    case .connecting:
      sendingCard(progress: nil)
    case let .sending(progress):
      sendingCard(progress: progress)
    case .restarting:
      CardFormSection {
        ContentCard(L10n.Settings.FirmwareUpdate.Restarting.title, systemImage: "arrow.triangle.2.circlepath", color: .blue) {
          HStack(spacing: 10) {
            ProgressView()
            Text(L10n.Settings.FirmwareUpdate.Restarting.message)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    case let .finished(build, changed):
      CardFormSection {
        SettingCardLabel(
          changed
            ? L10n.Settings.FirmwareUpdate.Done.updated(build)
            : L10n.Settings.FirmwareUpdate.Done.installed(build),
          systemImage: "checkmark.seal.fill",
          color: .green
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)
      }
    case let .unchanged(build):
      CardFormSection {
        SettingCardLabel(
          L10n.Settings.FirmwareUpdate.Interrupted.title,
          systemImage: "exclamationmark.triangle.fill",
          color: .orange,
          subtitle: L10n.Settings.FirmwareUpdate.Done.unchanged(build)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)
      }
    case .notBack:
      CardFormSection {
        SettingCardLabel(
          L10n.Settings.FirmwareUpdate.Restarting.title,
          systemImage: "clock",
          color: .orange,
          subtitle: L10n.Settings.FirmwareUpdate.Done.notBack
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)
      }
    case .interrupted:
      CardFormSection {
        SettingCardLabel(
          L10n.Settings.FirmwareUpdate.Interrupted.title,
          systemImage: "exclamationmark.triangle.fill",
          color: .orange,
          subtitle: L10n.Settings.FirmwareUpdate.Interrupted.message
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)
        ActionCard(L10n.Localizable.Common.tryAgain, systemImage: "arrow.clockwise", color: .blue) {
          viewModel.retrySend()
        }
      }
    }
  }

  /// The two ways to install, once the board is on WiFi; otherwise what it needs first.
  @ViewBuilder
  private var sourceSection: some View {
    if viewModel.status?.wifi == .connected {
      CardFormSection(
        L10n.Settings.FirmwareUpdate.Install.header,
        footer: L10n.Settings.FirmwareUpdate.Install.footer
      ) {
        if let latest = viewModel.latest {
          Button {
            viewModel.prepareLatest()
          } label: {
            BusyActionCardLabel(
              title: L10n.Settings.FirmwareUpdate.Install.latest(latest.title),
              subtitle: L10n.Settings.FirmwareUpdate.Install.latestSubtitle,
              systemImage: "arrow.down.circle",
              color: .green,
              isBusy: viewModel.isBusyWithRelease
            )
          }
          .buttonStyle(.plain)
          .disabled(!viewModel.canStart)
        }

        Button {
          viewModel.showingFileImporter = true
        } label: {
          BusyActionCardLabel(
            title: L10n.Settings.FirmwareUpdate.Install.file,
            subtitle: viewModel.board.map { L10n.Settings.FirmwareUpdate.Install.fileSubtitle($0.displayName) },
            systemImage: "doc.badge.arrow.up",
            color: .blue,
            isBusy: viewModel.phase == .reaching && !viewModel.isBusyWithRelease
          )
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canStart)
      }
    } else {
      CardFormSection(
        footer: viewModel.status?.wifi == .notInBuild
          ? L10n.Settings.FirmwareUpdate.noWifi
          : L10n.Settings.FirmwareUpdate.needsWifi
      ) {
        if viewModel.status?.wifi != .notInBuild {
          checkAgainCard
        }
      }
    }
  }

  private var checkAgainCard: some View {
    ActionCard(L10n.Settings.FirmwareUpdate.checkAgain, systemImage: "arrow.clockwise", color: .blue) {
      Task { await viewModel.load() }
    }
    .radioDisabled(for: appState.connectionState)
  }

  /// Connecting, then the bytes going out. The bar stays indeterminate until the first bytes leave.
  private func sendingCard(progress: Double?) -> some View {
    CardFormSection(footer: L10n.Settings.FirmwareUpdate.sendingFooter) {
      ContentCard(
        progress == nil ? L10n.Settings.FirmwareUpdate.connecting : L10n.Settings.FirmwareUpdate.sending,
        systemImage: "arrow.up.circle",
        color: .blue
      ) {
        if let progress {
          ProgressView(value: progress)
            .accessibilityLabel(L10n.Settings.FirmwareUpdate.sending)
            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
          Text(progress.formatted(.percent.precision(.fractionLength(0))))
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        } else {
          ProgressView()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}

#Preview {
  NavigationStack {
    FirmwareUpdateView()
      .environment(\.appState, AppState())
  }
}

/// The touch boards' WiFi update's page handlers: the screen kept on while the board waits on the
/// page, the update ended as the page leaves Settings, the file picker and the confirmation.
private struct TouchBoardUpdateHandlers: ViewModifier {
  @Environment(\.appState) private var appState
  @Bindable var viewModel: FirmwareUpdateViewModel

  func body(content: Content) -> some View {
    content
    .onAppear {
      if viewModel.phase.holdsScreen { UIApplication.shared.isIdleTimerDisabled = true }
    }
    // Another tab, or another Settings page in the iPad's pane, hides the page without closing it:
    // the board keeps waiting on it, so only the page leaving Settings' path ends the update's wait.
    // (Settings can't close while an update holds the page: `MainTabView`.)
    .onDisappear {
      guard !appState.navigation.settingsPath.contains(.firmwareUpdate) else { return }
      viewModel.leave()
      UIApplication.shared.isIdleTimerDisabled = false
    }
    // The upload stops if the phone locks; keep the screen on while the board waits on it.
    .onChange(of: viewModel.phase.holdsScreen) { _, holds in
      UIApplication.shared.isIdleTimerDisabled = holds
    }
    .fileImporter(isPresented: $viewModel.showingFileImporter, allowedContentTypes: [.data]) { result in
      switch result {
      case let .success(url):
        viewModel.useFile(at: url)
      case let .failure(error):
        viewModel.errorMessage = error.userFacingMessage
      }
    }
    .alert(
      L10n.Settings.FirmwareUpdate.Confirm.title(viewModel.image?.name ?? ""),
      isPresented: $viewModel.showingConfirmation
    ) {
      Button(L10n.Settings.FirmwareUpdate.Confirm.install) {
        viewModel.startUpdate()
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {
        viewModel.discardImage()
      }
    } message: {
      Text(L10n.Settings.FirmwareUpdate.Confirm.message)
    }
  }
}
