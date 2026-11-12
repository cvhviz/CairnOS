import CairnServices
import SwiftUI

/// One radio config profile: what it holds, as Radio Settings shows the same settings, then
/// applying it, sharing it and managing it. Applying opens the config import on the profile
/// (`NodeConfigImportView(preloadedConfig:)`): the same section switches, current-versus-new diff,
/// confirmation, progress and radio-last write order as importing a file.
struct RadioProfileDetailView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: RadioProfilesModel
  let profileID: UUID
  /// In the iPad/Mac pane the Connections page keeps its own title, and a delete clears the
  /// selection rather than popping the page.
  var isEmbedded = false
  var onDeleted: (() -> Void)?

  @State private var isRenaming = false
  @State private var renameText = ""
  @State private var isConfirmingDelete = false
  @State private var showFileExporter = false
  /// The profile written out for Share, refreshed whenever the profile changes.
  @State private var shareURL: URL?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let profile = model.profile(id: profileID) {
        content(profile)
          .task(id: profile) { shareURL = writeShareFile(profile) }
          .fileExporter(
            isPresented: $showFileExporter,
            document: document(for: profile),
            contentType: .json,
            defaultFilename: NodeConfigExportViewModel.filename(for: profile.name)
          ) { result in
            if case let .failure(error) = result {
              errorMessage = error.userFacingMessage
            }
          }
      } else {
        // Deleted from under the page; it closes itself.
        Color.clear
      }
    }
    .flashingNavigationTitle(isEmbedded
      ? L10n.Settings.Connections.title
      : (model.profile(id: profileID)?.name ?? L10n.Settings.Connections.Profiles.header))
    .navigationBarTitleDisplayMode(.inline)
    .alert(L10n.Settings.Connections.Profile.Rename.title, isPresented: $isRenaming) {
      TextField(L10n.Settings.Connections.Profiles.NewProfile.placeholder, text: $renameText)
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Localizable.Common.save) {
        model.rename(profileID, to: renameText)
      }
      .disabled(RadioConfigProfile.normalizedName(renameText) == nil)
    }
    .confirmationDialog(
      L10n.Settings.Connections.Profile.Delete.title(model.profile(id: profileID)?.name ?? ""),
      isPresented: $isConfirmingDelete,
      titleVisibility: .visible
    ) {
      Button(L10n.Settings.Connections.Profile.delete, role: .destructive) {
        model.delete(profileID)
        if let onDeleted {
          onDeleted()
        } else {
          dismiss()
        }
      }
    } message: {
      Text(L10n.Settings.Connections.Profile.Delete.message)
    }
    .errorAlert($errorMessage)
  }

  private func content(_ profile: RadioConfigProfile) -> some View {
    CardForm {
      header(profile)

      CardFormSection(L10n.Settings.Connections.Profile.contents) {
        NodeDashboardCardGrid(items: cards(profile))
      }

      let channels = RadioProfileSummary.channelNames(profile.config)
      if !channels.isEmpty {
        CardFormSection(L10n.Settings.ConfigExport.channels) {
          ForEach(Array(channels.enumerated()), id: \.offset) { _, name in
            SettingCardLabel(name, systemImage: "number", color: .blue)
              .frame(maxWidth: .infinity, alignment: .leading)
              .cardSurface(padding: 12)
          }
        }
      }

      CardFormSection(footer: appState.isRadioReady ? nil : L10n.Settings.Connections.Profile.applyDisconnected) {
        NavigationLink {
          NodeConfigImportView(
            preloadedConfig: profile.config,
            title: L10n.Settings.Connections.Profile.applyTitle
          )
        } label: {
          NavigationTile(
            L10n.Settings.Connections.Profile.apply(appState.connectedDevice?.nodeName ?? L10n.Settings.ConfigImport.thisDevice),
            systemImage: "square.and.arrow.down",
            color: .green,
            wash: .prominent
          )
        }
        .buttonStyle(.plain)
        .disabled(!appState.isRadioReady)
        .dimmedWhenDisabled()
      }

      CardFormSection {
        if let shareURL {
          ShareLink(item: shareURL) {
            BusyActionCardLabel(
              title: L10n.Settings.Settings.DataExport.share,
              systemImage: "square.and.arrow.up",
              color: .blue,
              isBusy: false
            )
          }
          .buttonStyle(.plain)
        }
        ActionCard(L10n.Settings.Settings.DataExport.saveToFiles, systemImage: "folder", color: .blue) {
          showFileExporter = true
        }
        ActionCard(L10n.Settings.Connections.Action.rename, systemImage: "pencil", color: .orange) {
          renameText = profile.name
          isRenaming = true
        }
        ActionCard(L10n.Settings.Connections.Profile.delete, systemImage: "trash", role: .destructive) {
          isConfirmingDelete = true
        }
      }
    }
  }

  /// The profile's name, as Radio Settings heads its page with the radio's, and where it came from.
  private func header(_ profile: RadioConfigProfile) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        IconTile(systemImage: "slider.horizontal.below.rectangle", color: .purple)
          .accessibilityHidden(true)
        Text(profile.name)
          .font(.title3.weight(.bold))
          .lineLimit(2)
      }
      Text(savedFrom(profile))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private func savedFrom(_ profile: RadioConfigProfile) -> String {
    let date = profile.createdAt.formatted(date: .abbreviated, time: .shortened)
    guard let source = profile.sourceDeviceName, !source.isEmpty else {
      return L10n.Settings.Connections.Profile.savedOn(date)
    }
    return L10n.Settings.Connections.Profile.savedFrom(source, date)
  }

  /// Read-only cards in Radio Settings' figures: the preset, the parameters, the radio's name and
  /// the other settings, each only when the profile holds it.
  private func cards(_ profile: RadioConfigProfile) -> [NodeDashboardCardItem] {
    var items: [NodeDashboardCardItem] = []
    if let radio = profile.config.radioSettings {
      items.append(NodeDashboardCardItem(
        id: "preset",
        title: L10n.Settings.Radio.preset,
        systemImage: "dial.medium.fill",
        tint: .orange,
        value: RadioProfileSummary.presetName(radio),
        details: [RadioProfileSummary.frequency(radio)],
        destination: .none
      ))
      items.append(NodeDashboardCardItem(
        id: "parameters",
        title: L10n.Localizable.CarPlay.Home.modulation,
        systemImage: "waveform",
        tint: .orange,
        value: RadioProfileSummary.frequency(radio),
        details: [
          RadioProfileSummary.modulation(radio),
          L10n.Settings.Radio.TxPower.detailSetting(L10n.Settings.DeviceInfo.txPowerFormat(Int(radio.txPower).formatted())),
        ],
        destination: .none
      ))
    }
    if let name = profile.config.name, !name.isEmpty {
      items.append(NodeDashboardCardItem(
        id: "name",
        title: L10n.Settings.Node.name,
        systemImage: "person.text.rectangle",
        tint: .purple,
        value: name,
        destination: .none
      ))
    }
    items.append(NodeDashboardCardItem(
      id: "channels",
      title: L10n.Settings.ConfigExport.channels,
      systemImage: "number",
      tint: .blue,
      value: (profile.config.channels?.count ?? 0).formatted(),
      destination: .none
    ))
    if profile.config.otherSettings != nil {
      items.append(NodeDashboardCardItem(
        id: "other",
        title: L10n.Settings.ConfigExport.otherSettings,
        systemImage: "gearshape",
        tint: .gray,
        value: L10n.Settings.Connections.Profile.included,
        details: [L10n.Settings.ConfigExport.OtherSettings.description],
        destination: .none
      ))
    }
    return items
  }

  private func document(for profile: RadioConfigProfile) -> NodeConfigDocument? {
    guard let data = try? profile.exportData() else { return nil }
    return NodeConfigDocument(data: data, filename: NodeConfigExportViewModel.filename(for: profile.name))
  }

  /// Writes the profile to a temporary file named as Export names its files, for Share.
  private func writeShareFile(_ profile: RadioConfigProfile) -> URL? {
    do {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RadioProfiles", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(NodeConfigExportViewModel.filename(for: profile.name))
        .appendingPathExtension("json")
      try profile.exportData().write(to: url, options: [.atomic, .completeFileProtection])
      return url
    } catch {
      errorMessage = error.userFacingMessage
      return nil
    }
  }
}
