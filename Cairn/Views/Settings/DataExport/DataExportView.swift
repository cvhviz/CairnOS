import CairnServices
import SwiftUI

/// Settings > Backup & Restore > Export Data: CSV/GPX exports of locally stored data.
struct DataExportView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var viewModel = DataExportViewModel()
  @State private var showFileExporter = false

  var body: some View {
    Group {
      if appState.currentRadioID == nil {
        ContentUnavailableView {
          Label(L10n.Settings.Settings.DataExport.NoRadio.title, systemImage: "square.and.arrow.up")
        } description: {
          Text(L10n.Settings.Settings.DataExport.NoRadio.description)
        }
        // CardForm paints its own canvas; only this branch needs one.
        .cardCanvas(theme)
      } else {
        exportList
      }
    }
    .flashingNavigationTitle(L10n.Settings.Settings.DataExport.title)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: appState.currentRadioID) {
      // A file staged for the previous radio must not be offered as this one's.
      viewModel.discardExport()
      guard let radioID = appState.currentRadioID else { return }
      await viewModel.configure(
        store: appState.connectionManager.persistenceStore,
        radioID: radioID,
        ownName: appState.connectedDevice?.nodeName ?? appState.connectionManager.lastConnectedDeviceName,
        rxLogService: appState.services?.rxLogService,
        neighbourService: appState.services?.neighbourService
      )
    }
    .fileExporter(
      isPresented: $showFileExporter,
      document: viewModel.exportedFile?.document,
      contentType: viewModel.exportedFile?.contentType ?? .commaSeparatedText,
      defaultFilename: viewModel.exportedFile?.filename
    ) { result in
      viewModel.handleSaveResult(result)
    }
    .errorAlert($viewModel.errorMessage)
    .onDisappear {
      viewModel.discardExport()
    }
  }

  private var exportList: some View {
    CardForm {
      // The note covers every export on the page, so it sits on the first header.
      CardFormSection(L10n.Settings.Settings.DataExport.messages, info: L10n.Settings.Settings.DataExport.footer) {
        PickerCard(
          L10n.Settings.Settings.DataExport.conversation,
          systemImage: "bubble.left.and.bubble.right",
          color: .blue,
          selection: $viewModel.selectedScope
        ) {
          Text(L10n.Settings.Settings.DataExport.allConversations)
            .tag(DataExportService.MessageScope.all)
          ForEach(viewModel.conversations) { conversation in
            Text(conversation.title).tag(conversation.scope)
          }
        }
        exportButton(.messages, title: L10n.Settings.Settings.DataExport.exportMessages, systemImage: "text.bubble", color: .blue, format: "CSV")
      }

      CardFormSection(L10n.Settings.Settings.DataExport.network) {
        exportButton(.contacts, title: L10n.Settings.Settings.DataExport.contacts, systemImage: "person.2", color: .green, format: "CSV")
        exportButton(.nodeStatus, title: L10n.Settings.Settings.DataExport.nodeStatus, systemImage: "chart.line.uptrend.xyaxis", color: .purple, format: "CSV")
        exportButton(.rxLog, title: L10n.Settings.Settings.DataExport.rxLog, systemImage: "waveform.badge.magnifyingglass", color: .teal, format: "CSV")
        exportButton(.waypoints, title: L10n.Settings.Settings.DataExport.waypoints, systemImage: "mappin.and.ellipse", color: .red, format: "GPX")
      }

      if let file = viewModel.exportedFile {
        CardFormSection(L10n.Settings.Settings.DataExport.ready) {
          VStack(alignment: .leading, spacing: 2) {
            Text(file.filename)
              .font(.subheadline.monospaced())
              .lineLimit(2)
              .truncationMode(.middle)
            Text(L10n.Settings.Settings.DataExport.rowCount(file.recordCount))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .cardSurface(padding: 12)
          .accessibilityElement(children: .combine)

          ActionCard(L10n.Settings.Settings.DataExport.saveToFiles, systemImage: "folder", color: .blue) {
            showFileExporter = true
          }
          if let url = file.url {
            ShareLink(item: url) {
              BusyActionCardLabel(
                title: L10n.Settings.Settings.DataExport.share,
                systemImage: "square.and.arrow.up",
                color: .blue,
                isBusy: false
              )
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func exportButton(
    _ kind: DataExportViewModel.Kind,
    title: String,
    systemImage: String,
    color: Color,
    format: String
  ) -> some View {
    Button {
      viewModel.export(kind)
    } label: {
      BusyActionCardLabel(
        title: viewModel.exporting == kind ? L10n.Settings.Settings.DataExport.exporting : title,
        trailing: format,
        systemImage: systemImage,
        color: color,
        isBusy: viewModel.exporting == kind
      )
    }
    .buttonStyle(.plain)
    .disabled(viewModel.exporting != nil)
  }
}
