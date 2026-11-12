import CairnServices
import SwiftUI

struct HeightEditorGrid: View {
  let groundElevation: Double?
  @Binding var additionalHeight: Double
  let range: ClosedRange<Double>
  var onHeightChanged: (() -> Void)?

  private var heightStep: Double {
    MeasurementPreference.usesImperialLengths() ? 0.3048 : 1.0
  }

  var body: some View {
    Grid(alignment: .leading, verticalSpacing: 8) {
      if let groundElevation {
        GridRow {
          Text(L10n.Tools.Tools.LineOfSight.groundElevation)
            .font(.subheadline)
            .foregroundStyle(.secondary)

          Spacer()

          Text(Measurement(value: groundElevation, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated).locale(MeasurementPreference.locale())))
            .font(.subheadline)
            .monospacedDigit()
        }
      } else {
        GridRow {
          Text(L10n.Tools.Tools.LineOfSight.groundElevation)
            .font(.subheadline)
            .foregroundStyle(.secondary)

          Spacer()

          ProgressView()
            .controlSize(.mini)
        }
      }

      GridRow {
        Text(L10n.Tools.Tools.LineOfSight.additionalHeight)
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Spacer()

        Stepper(value: $additionalHeight, in: range, step: heightStep) {
          Text(Measurement(value: additionalHeight, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated).locale(MeasurementPreference.locale())))
            .font(.subheadline)
            .monospacedDigit()
        }
        .controlSize(.small)
        .onChange(of: additionalHeight) {
          onHeightChanged?()
        }
      }

      if let groundElevation {
        Divider()
          .gridCellColumns(2)

        GridRow {
          Text(L10n.Tools.Tools.LineOfSight.totalHeight)
            .font(.subheadline)
            .bold()

          Spacer()

          Text(Measurement(value: groundElevation + additionalHeight, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated).locale(MeasurementPreference.locale())))
            .font(.subheadline)
            .monospacedDigit()
            .bold()
        }
      }
    }
  }
}
