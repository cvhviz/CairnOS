import SwiftUI

/// The radio assumptions behind the analysis, as setting cards: the frequency (typed) and the
/// refraction (picked), like any settings page.
struct RFSettingsSectionView: View {
  @Bindable var viewModel: LineOfSightViewModel

  var body: some View {
    CardFormSection(L10n.Tools.Tools.LineOfSight.rfSettings) {
      // Its own view, so its @FocusState works inside the sheet.
      FrequencyInputRow(viewModel: viewModel)
        .cardSurface()

      PickerCard(
        L10n.Tools.Tools.LineOfSight.refraction,
        systemImage: "globe.americas.fill",
        color: .teal,
        selection: Binding(
          get: { viewModel.refractionK },
          set: { viewModel.refractionK = $0 }
        )
      ) {
        Text(L10n.Tools.Tools.LineOfSight.Refraction.none).tag(1.0)
        Text(L10n.Tools.Tools.LineOfSight.Refraction.standard).tag(4.0 / 3.0)
        Text(L10n.Tools.Tools.LineOfSight.Refraction.ducting).tag(4.0)
      }
    }
  }
}
