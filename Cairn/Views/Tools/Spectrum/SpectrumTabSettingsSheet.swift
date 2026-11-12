import CairnServices
import SwiftUI

/// Settings › Spectrum (`SettingsDetail.spectrum`), also what the Spectrum tab's sliders open: the
/// window the chart starts with, how often the radio is read, and how long the traffic table runs. The radio's channel itself is
/// one tap away on the page, in its header, so it isn't repeated here. Device-local preferences,
/// not backed up. A Cairn radio that sends its own Channel view sets its own pace, so the update
/// rate gives way to a footnote saying so.
struct SpectrumTabSettingsSheet: View {
  @Environment(\.appState) private var appState
  /// The connected radio sends its own readings (its Spectrum feed answered this session).
  @State private var radioSendsReadings = false
  @AppStorage(AppStorageKey.spectrumChartStyle.rawValue)
  private var chartStyleRaw = 0
  @AppStorage(AppStorageKey.spectrumDefaultWindow.rawValue)
  private var defaultWindowRaw = AppStorageKey.defaultSpectrumWindow
  @AppStorage(AppStorageKey.spectrumUpdateRate.rawValue)
  private var rateRaw = AppStorageKey.defaultSpectrumUpdateRate
  @AppStorage(AppStorageKey.spectrumTrafficRows.rawValue)
  private var trafficRows = AppStorageKey.defaultSpectrumTrafficRows
  /// The noise-floor readings staged for the file exporter.
  @State private var readingsExport: ExportedFile?
  @State private var isPreparingExport = false

  private var viewModel: SpectrumViewModel { appState.spectrumFeed.model }

  var body: some View {
    CardForm {
      CardFormSection(L10n.Tools.Tools.Spectrum.Settings.readingsHeader, footer: L10n.Tools.Tools.Spectrum.Settings.readingsFooter) {
        ToggleCard(
          L10n.Tools.Tools.Spectrum.pause,
          systemImage: "pause.circle",
          color: .gray,
          isOn: Binding(get: { viewModel.isPaused }, set: { viewModel.setPaused($0) })
        )
        .accessibilityIdentifier("spectrum.settings.pause")
        Button {
          exportReadings()
        } label: {
          NavigationTile(
            L10n.Tools.Tools.Spectrum.Settings.exportReadings,
            systemImage: "square.and.arrow.up",
            color: .teal
          )
        }
        .buttonStyle(.plain)
        .disabled(appState.currentRadioID == nil || isPreparingExport)
        .accessibilityIdentifier("spectrum.settings.exportReadings")
      }

      CardFormSection(
        L10n.Tools.Tools.Spectrum.Figure.channel,
        info: L10n.Tools.Tools.Spectrum.Settings.channelOptionsInfo,
        footer: radioSendsReadings ? L10n.Tools.Tools.Spectrum.Device.settingsFootnote : nil
      ) {
        PickerCard(
          L10n.Tools.Tools.Spectrum.Settings.chartStyle,
          systemImage: "chart.bar.fill",
          color: .teal,
          selection: $chartStyleRaw
        ) {
          ForEach(SpectrumChartStyle.allCases) { style in
            Text(style.title).tag(style.rawValue)
          }
        }
        .accessibilityIdentifier("spectrum.chartStyle")

        PickerCard(
          L10n.Tools.Tools.Spectrum.Settings.defaultWindow,
          systemImage: "clock",
          color: .blue,
          selection: $defaultWindowRaw
        ) {
          ForEach(SpectrumWindow.allCases) { window in
            Text(window.shortTitle)
              .accessibilityLabel(window.spokenTitle)
              .tag(window.rawValue)
          }
        }

        if !radioSendsReadings {
          PickerCard(
            L10n.Tools.Tools.Spectrum.Settings.updateRate,
            systemImage: "gauge.with.dots.needle.67percent",
            color: .orange,
            selection: $rateRaw
          ) {
            ForEach(SpectrumUpdateRate.allCases) { rate in
              Text("\(rate.title) · \(Duration.seconds(rate.rawValue).formatted(.units(width: .abbreviated)))")
                .tag(rate.rawValue)
            }
          }
        }
      }

      CardFormSection(L10n.Tools.Tools.Spectrum.Traffic.title) {
        PickerCard(
          L10n.Tools.Tools.Spectrum.Settings.trafficRows,
          systemImage: "list.bullet",
          color: .purple,
          selection: $trafficRows
        ) {
          ForEach(SpectrumTrafficRows.options, id: \.self) { rows in
            Text(rows.formatted())
              .tag(rows)
          }
        }
      }
    }
    .flashingNavigationTitle(SettingsDetail.spectrum.title)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: appState.servicesVersion) {
      radioSendsReadings = await appState.services?.session.cairnSpectrumSupport == true
    }
    .fileExporter(
      isPresented: Binding(
        get: { readingsExport != nil },
        set: { if !$0 { discardExport() } }
      ),
      document: readingsExport?.document,
      contentType: .commaSeparatedText,
      defaultFilename: readingsExport?.filename
    ) { _ in
      discardExport()
    }
  }

  /// Stages the connected radio's minute readings (the last week's) as a CSV.
  private func exportReadings() {
    guard let radioID = appState.currentRadioID, !isPreparingExport else { return }
    isPreparingExport = true
    let store = viewModel.readingsStore
    Task {
      readingsExport = await store.csvExport(radioID: radioID)
      isPreparingExport = false
    }
  }

  /// The exporter saves from the document, so the staged temporary copy goes as soon as it closes.
  private func discardExport() {
    readingsExport?.removeTemporaryFile()
    readingsExport = nil
  }
}

#Preview {
  NavigationStack {
    SpectrumTabSettingsSheet()
  }
}
