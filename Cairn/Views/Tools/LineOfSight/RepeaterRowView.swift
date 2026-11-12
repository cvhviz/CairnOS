import SwiftUI

/// The relay between A and B as a card, like the point cards: its purple R, its heights, a tap
/// for the antenna height editor and the ••• menu for the rest.
struct RepeaterRowView: View {
  var viewModel: LineOfSightViewModel
  @Binding var copyHapticTrigger: Int
  @Binding var editingPoint: PointID?
  let onRelocate: () -> Void

  private var isEditing: Bool {
    editingPoint == .repeater
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Button {
          withAnimation { editingPoint = isEditing ? nil : .repeater }
        } label: {
          HStack(spacing: 12) {
            LOSPointBadge(letter: "R", color: .purple)
            VStack(alignment: .leading, spacing: 2) {
              Text(L10n.Tools.Tools.LineOfSight.repeater)
                .font(.body.weight(.semibold))
                .lineLimit(1)
              Text(LOSPointBadge.heightSummary(
                ground: viewModel.repeaterGroundElevation,
                antenna: viewModel.repeaterPoint?.additionalHeight ?? 0
              ))
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.Tools.Tools.LineOfSight.antennaHeight)

        PointRowButtonsView(
          viewModel: viewModel,
          pointID: .repeater,
          isEditing: isEditing,
          copyHapticTrigger: $copyHapticTrigger,
          editingPoint: $editingPoint,
          onRelocate: onRelocate,
          onClear: { viewModel.clearRepeater() }
        )
      }

      if isEditing, let repeaterPoint = viewModel.repeaterPoint {
        Divider()
        RepeaterHeightEditorView(viewModel: viewModel, repeaterPoint: repeaterPoint)
      }
    }
    .cardSurface(isSelected: viewModel.relocatingPoint == .repeater || isEditing)
    .animation(.easeInOut(duration: 0.2), value: isEditing)
  }
}
