import CairnServices
import SwiftUI

struct NodeConfigExportView: View {
  @Environment(\.appState) private var appState
  @State private var viewModel = NodeConfigExportViewModel()

  var body: some View {
    CardForm {
      CardFormSection {
        ToggleCard(
          L10n.Settings.ConfigExport.selectAll,
          systemImage: "checklist",
          color: .blue,
          isOn: Binding(
            get: { viewModel.sections.allSelected },
            set: { newValue in
              if newValue {
                viewModel.sections.selectAll()
              } else {
                viewModel.sections.deselectAll()
              }
            }
          )
        )
        .bold()

        ToggleCard(
          L10n.Settings.ConfigExport.nodeIdentity,
          systemImage: "person.text.rectangle",
          color: .purple,
          subtitle: L10n.Settings.ConfigExport.NodeIdentity.description,
          isOn: $viewModel.sections.nodeIdentity
        )
        ToggleCard(
          L10n.Settings.ConfigExport.radioSettings,
          systemImage: "antenna.radiowaves.left.and.right",
          color: .orange,
          subtitle: L10n.Settings.ConfigExport.RadioSettings.description,
          isOn: $viewModel.sections.radioSettings
        )
        ToggleCard(
          L10n.Settings.ConfigExport.positionSettings,
          systemImage: "location",
          color: .green,
          subtitle: L10n.Settings.ConfigExport.PositionSettings.description,
          isOn: $viewModel.sections.positionSettings
        )
        ToggleCard(
          L10n.Settings.ConfigExport.otherSettings,
          systemImage: "gearshape",
          color: .gray,
          subtitle: L10n.Settings.ConfigExport.OtherSettings.description,
          isOn: $viewModel.sections.otherSettings
        )
        ToggleCard(
          L10n.Settings.ConfigExport.channels,
          systemImage: "number",
          color: .blue,
          subtitle: L10n.Settings.ConfigExport.Channels.description,
          isOn: $viewModel.sections.channels
        )
        ToggleCard(
          L10n.Settings.ConfigExport.contacts,
          systemImage: "person.2",
          color: .green,
          subtitle: L10n.Settings.ConfigExport.Contacts.description,
          isOn: $viewModel.sections.contacts
        )
      }

      Button {
        Task {
          await viewModel.exportConfig(
            nodeConfigService: appState.services?.nodeConfigService,
            deviceNodeName: appState.connectedDevice?.nodeName
          )
        }
      } label: {
        BusyActionCardLabel(
          title: viewModel.sections.allSelected
            ? L10n.Settings.ConfigExport.exportFull
            : L10n.Settings.ConfigExport.exportSelected,
          systemImage: "square.and.arrow.up",
          color: .blue,
          isBusy: viewModel.isExporting
        )
      }
      .buttonStyle(.plain)
      .disabled(viewModel.isExporting || !viewModel.sections.anySectionSelected)

      if let error = viewModel.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .cardSurface(padding: 12)
      }
    }
    .flashingNavigationTitle(L10n.Settings.ConfigExport.title)
    .navigationBarTitleDisplayMode(.inline)
    .fileExporter(
      isPresented: $viewModel.showFileExporter,
      document: viewModel.exportedDocument,
      contentType: .json,
      defaultFilename: viewModel.exportedDocument?.filename
    ) { result in
      if case let .failure(error) = result {
        viewModel.errorMessage = error.userFacingMessage
      }
    }
  }
}
