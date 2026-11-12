import CairnServices
import SwiftUI

struct NodeConfigImportView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  @State private var viewModel = NodeConfigImportViewModel()

  /// A config to apply without a file: a radio config profile (Connections). The page then opens
  /// on its preview and closes once the import has finished, rather than offering a file.
  var preloadedConfig: MeshCoreNodeConfig?
  var title: String = L10n.Settings.ConfigImport.title

  var body: some View {
    Group {
      if let config = viewModel.importedConfig {
        ImportPreviewList(viewModel: viewModel, config: config)
      } else if preloadedConfig == nil {
        SelectFileList(viewModel: viewModel)
      } else {
        // Between appearing and the preview loading, or after the import while the page closes.
        Color.clear.cardCanvas(theme)
      }
    }
    .flashingNavigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      // Each appearance starts fresh (the dismissal resets the preview), unless an import still
      // runs from before.
      guard let preloadedConfig, viewModel.importedConfig == nil, !viewModel.isApplying else { return }
      viewModel.load(preloadedConfig)
      await viewModel.loadCurrentDeviceState(settingsService: appState.services?.settingsService)
    }
    .onDisappear { viewModel.handleDismissal() }
    .fileImporter(
      isPresented: $viewModel.showFilePicker,
      allowedContentTypes: [.json]
    ) { result in
      switch result {
      case let .success(url):
        viewModel.parseFile(at: url)
        Task { await viewModel.loadCurrentDeviceState(settingsService: appState.services?.settingsService) }
      case let .failure(error):
        viewModel.errorMessage = error.userFacingMessage
      }
    }
    // Mac / iPad: a config file dragged in takes the same path as the file picker.
    .dropDestination(for: URL.self) { urls, _ in
      // Busy: a drop mid-import would swap the preview under a write that is still running,
      // and the post-success reset would then discard the dropped file.
      guard !viewModel.isApplying, !viewModel.isParsing, !viewModel.isPreparingConfirmation,
            let url = urls.first(where: \.isFileURL) else { return false }
      viewModel.parseFile(at: url)
      Task { await viewModel.loadCurrentDeviceState(settingsService: appState.services?.settingsService) }
      return true
    }
    .alert(
      viewModel.confirmTitle,
      isPresented: $viewModel.showConfirmation
    ) {
      Button(viewModel.applyButtonLabel) {
        viewModel.applyConfig(
          nodeConfigService: appState.services?.nodeConfigService,
          settingsService: appState.services?.settingsService,
          radioID: appState.connectedDevice?.radioID
        )
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(viewModel.confirmMessage(deviceName: appState.connectedDevice?.nodeName ?? L10n.Settings.ConfigImport.thisDevice))
    }
    // The success card only shows until the view model resets to file selection, so say it too.
    .onChange(of: viewModel.importComplete) { wasComplete, isComplete in
      if isComplete {
        AccessibilityNotification.Announcement(L10n.Settings.ConfigImport.importSuccess).post()
      } else if wasComplete, preloadedConfig != nil {
        // The success card has had its moment; a profile has no next file to pick.
        dismiss()
      }
    }
  }
}

// MARK: - Select File

private struct SelectFileList: View {
  @Bindable var viewModel: NodeConfigImportViewModel

  var body: some View {
    CardForm {
      Button {
        viewModel.showFilePicker = true
      } label: {
        BusyActionCardLabel(
          title: L10n.Settings.ConfigImport.selectFile,
          systemImage: "doc.badge.plus",
          color: .green,
          isBusy: viewModel.isParsing
        )
      }
      .buttonStyle(.plain)
      .disabled(viewModel.isParsing)

      if let error = viewModel.errorMessage {
        ImportStatusCard(error, systemImage: "exclamationmark.triangle", tint: .red)
      }
    }
  }
}

// MARK: - Import Preview

private struct ImportPreviewList: View {
  @Bindable var viewModel: NodeConfigImportViewModel
  let config: MeshCoreNodeConfig

  var body: some View {
    CardForm {
      CardFormSection(footer: L10n.Settings.ConfigImport.proximityWarning) {
        if config.name != nil || config.privateKey != nil {
          NodeIdentitySection(viewModel: viewModel, config: config)
        }

        if let radio = config.radioSettings {
          RadioSettingsSection(viewModel: viewModel, radio: radio, currentRadio: viewModel.currentRadio)
        }

        if let position = config.positionSettings {
          PositionSection(viewModel: viewModel, position: position, currentPosition: viewModel.currentPosition)
        }

        if config.otherSettings != nil {
          ToggleCard(
            L10n.Settings.ConfigExport.otherSettings,
            systemImage: "gearshape",
            color: .gray,
            isOn: $viewModel.sections.otherSettings
          )
        }

        if let channels = config.channels {
          ChannelsSection(viewModel: viewModel, channels: channels)
        }

        if let contacts = config.contacts {
          ContactsSection(viewModel: viewModel, contacts: contacts)
        }
      }
      // Lock the section toggles while the preview round-trip is in flight, so the selection
      // the confirmation copy was computed from matches the selection the apply uses, and while
      // the import runs, since it already captured the selection.
      .disabled(viewModel.isPreparingConfirmation || viewModel.isApplying)

      ApplySection(viewModel: viewModel)

      if let error = viewModel.errorMessage {
        ImportStatusCard(error, systemImage: "exclamationmark.triangle", tint: .red)
      }

      if viewModel.importComplete, !viewModel.isApplying {
        ImportStatusCard(L10n.Settings.ConfigImport.importSuccess, systemImage: "checkmark.circle.fill", tint: .green)
      }
    }
  }
}

// MARK: - Cards

/// A section toggle whose card also shows what importing it would change (current vs new), or a
/// warning. The whole card is the switch, as with `ToggleCard`.
private struct ImportToggleCard<Detail: View>: View {
  let title: String
  let systemImage: String
  let color: Color
  @Binding var isOn: Bool
  @ViewBuilder let detail: () -> Detail

  init(
    _ title: String,
    systemImage: String,
    color: Color,
    isOn: Binding<Bool>,
    @ViewBuilder detail: @escaping () -> Detail
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    _isOn = isOn
    self.detail = detail
  }

  var body: some View {
    Toggle(isOn: $isOn) {
      HStack(alignment: .top, spacing: 12) {
        IconTile(systemImage: systemImage, color: color)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.body)
            .foregroundStyle(Color.primary)
          detail()
        }
      }
    }
    .cardSurface(padding: 12)
  }
}

/// A one-line outcome (an error, a success) as its own card.
private struct ImportStatusCard: View {
  let text: String
  let systemImage: String
  let tint: Color

  init(_ text: String, systemImage: String, tint: Color) {
    self.text = text
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    Label(text, systemImage: systemImage)
      .foregroundStyle(tint)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(padding: 12)
  }
}

private struct NodeIdentitySection: View {
  @Bindable var viewModel: NodeConfigImportViewModel
  let config: MeshCoreNodeConfig

  var body: some View {
    ImportToggleCard(
      L10n.Settings.ConfigExport.nodeIdentity,
      systemImage: "person.text.rectangle",
      color: .purple,
      isOn: $viewModel.sections.nodeIdentity
    ) {
      if let newName = config.name {
        DiffRow(
          current: viewModel.currentName ?? "\u{2014}",
          new: newName
        )
      }
      if config.privateKey != nil {
        Label(L10n.Settings.ConfigImport.privateKeyWarning, systemImage: "exclamationmark.shield")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct RadioSettingsSection: View {
  @Bindable var viewModel: NodeConfigImportViewModel
  let radio: MeshCoreNodeConfig.RadioSettings
  let currentRadio: MeshCoreNodeConfig.RadioSettings?

  var body: some View {
    ImportToggleCard(
      L10n.Settings.ConfigExport.radioSettings,
      systemImage: "antenna.radiowaves.left.and.right",
      color: .orange,
      isOn: $viewModel.sections.radioSettings
    ) {
      DiffRow(
        current: currentRadio.map { RadioFormatter.format($0) } ?? "\u{2014}",
        new: RadioFormatter.format(radio)
      )
      if let current = currentRadio, current != radio {
        Label(L10n.Settings.ConfigImport.radioWarning, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct PositionSection: View {
  @Bindable var viewModel: NodeConfigImportViewModel
  let position: MeshCoreNodeConfig.PositionSettings
  let currentPosition: MeshCoreNodeConfig.PositionSettings?

  var body: some View {
    ImportToggleCard(
      L10n.Settings.ConfigExport.positionSettings,
      systemImage: "location",
      color: .green,
      isOn: $viewModel.sections.positionSettings
    ) {
      DiffRow(
        current: currentPosition.map { "\($0.latitude), \($0.longitude)" } ?? "\u{2014}",
        new: "\(position.latitude), \(position.longitude)"
      )
    }
  }
}

private struct ChannelsSection: View {
  @Bindable var viewModel: NodeConfigImportViewModel
  let channels: [MeshCoreNodeConfig.ChannelConfig]

  var body: some View {
    ToggleCard(
      L10n.Settings.ConfigExport.channels,
      systemImage: "number",
      color: .blue,
      subtitle: L10n.Settings.ConfigImport.channelCount(channels.count),
      isOn: $viewModel.sections.channels
    )
  }
}

private struct ContactsSection: View {
  @Bindable var viewModel: NodeConfigImportViewModel
  let contacts: [MeshCoreNodeConfig.ContactConfig]

  var body: some View {
    ToggleCard(
      L10n.Settings.ConfigExport.contacts,
      systemImage: "person.2",
      color: .green,
      subtitle: L10n.Settings.ConfigImport.contactCount(contacts.count),
      isOn: $viewModel.sections.contacts
    )
  }
}

private struct ApplySection: View {
  @Environment(\.appState) private var appState
  @Bindable var viewModel: NodeConfigImportViewModel

  var body: some View {
    if viewModel.isApplying {
      ContentCard(L10n.Settings.ConfigImport.applying, systemImage: "square.and.arrow.down", color: .green) {
        ProgressView(value: viewModel.applyProgress)
          .accessibilityLabel(L10n.Settings.ConfigImport.applying)
          .accessibilityValue(progressAccessibilityValue)
        // The step text is empty until the first progress event; keep the line so the card
        // doesn't grow when it arrives.
        Text(viewModel.applyStepDescription.isEmpty ? " " : viewModel.applyStepDescription)
          .font(.footnote)
          .foregroundStyle(.secondary)
          // Read as part of the progress bar's value instead.
          .accessibilityHidden(true)
      }
      ActionCard(L10n.Localizable.Common.cancel, systemImage: "xmark.circle", role: .destructive) {
        viewModel.cancelImport()
      }
    } else if !viewModel.importComplete {
      ActionCard(viewModel.applyButtonLabel, systemImage: "square.and.arrow.down", color: .green) {
        viewModel.prepareConfirmation(nodeConfigService: appState.services?.nodeConfigService)
      }
      .disabled(viewModel.isPreparingConfirmation)
      .dimmedWhenDisabled()
    }
  }
}

extension ApplySection {
  private var progressAccessibilityValue: String {
    let percent = viewModel.applyProgress.formatted(.percent.precision(.fractionLength(0)))
    guard !viewModel.applyStepDescription.isEmpty else { return percent }
    return "\(percent), \(viewModel.applyStepDescription)"
  }
}

// MARK: - Diff Row

private struct DiffRow: View {
  let current: String
  let new: String

  private var hasChanged: Bool {
    current != new
  }

  var body: some View {
    VStack(alignment: .leading) {
      Text(L10n.Settings.ConfigImport.current(current))
        .font(.footnote)
        .foregroundStyle(.secondary)
      Text(L10n.Settings.ConfigImport.new(new))
        .font(.footnote)
        .foregroundStyle(hasChanged ? .primary : .secondary)
    }
  }
}

// MARK: - Radio Formatter

private enum RadioFormatter {
  static func format(_ radio: MeshCoreNodeConfig.RadioSettings) -> String {
    let freqMHz = (Double(radio.frequency) / 1000).formatted(.number.precision(.fractionLength(0...3)).locale(.posix))
    let bwKHz = (Double(radio.bandwidth) / 1000).formatted(.number.precision(.fractionLength(0...1)).locale(.posix))
    return "\(freqMHz) MHz, BW \(bwKHz) kHz, SF \(radio.spreadingFactor), CR \(radio.codingRate)"
  }
}
