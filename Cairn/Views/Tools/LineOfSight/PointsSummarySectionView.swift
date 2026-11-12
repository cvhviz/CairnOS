import SwiftUI

/// The path as cards under "Points": A, the relay (or Add Repeater) and B, in path order. While a
/// point is being placed, a banner says to tap the map, with Cancel, in place of the cards.
struct PointsSummarySectionView: View {
  var viewModel: LineOfSightViewModel
  @Binding var copyHapticTrigger: Int
  @Binding var editingPoint: PointID?
  let onRelocate: () -> Void
  /// Sets A or B to where the phone is.
  let onUseMyLocation: (PointID) -> Void

  private var footer: String? {
    if viewModel.relocatingPoint != nil { return nil }
    return viewModel.pointA == nil || viewModel.pointB == nil
      ? L10n.Tools.Tools.LineOfSight.longPressPointsHint
      : nil
  }

  var body: some View {
    CardFormSection(L10n.Tools.Tools.LineOfSight.points, footer: footer) {
      if let relocatingPoint = viewModel.relocatingPoint {
        placingBanner(for: relocatingPoint)
      } else {
        PointRowView(
          viewModel: viewModel,
          label: "A",
          color: .blue,
          point: viewModel.pointA,
          pointID: .pointA,
          copyHapticTrigger: $copyHapticTrigger,
          editingPoint: $editingPoint,
          onRelocate: onRelocate,
          onUseMyLocation: { onUseMyLocation(.pointA) },
          onClear: { viewModel.clearPointA() }
        )

        // Inline check for repeaterPoint so SwiftUI tracks the dependency.
        if viewModel.repeaterPoint != nil {
          RepeaterRowView(
            viewModel: viewModel,
            copyHapticTrigger: $copyHapticTrigger,
            editingPoint: $editingPoint,
            onRelocate: onRelocate
          )
        } else if viewModel.shouldShowRepeaterPlaceholder {
          AddRepeaterRowView {
            viewModel.addRepeater()
            viewModel.analyzeWithRepeater()
          }
        }

        PointRowView(
          viewModel: viewModel,
          label: "B",
          color: .green,
          point: viewModel.pointB,
          pointID: .pointB,
          copyHapticTrigger: $copyHapticTrigger,
          editingPoint: $editingPoint,
          onRelocate: onRelocate,
          onUseMyLocation: { onUseMyLocation(.pointB) },
          onClear: { viewModel.clearPointB() }
        )

        if viewModel.elevationFetchFailed {
          Label(L10n.Tools.Tools.LineOfSight.elevationUnavailable, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
        }
      }
    }
  }

  /// "Placing Point A…": tap the map (or a repeater), or cancel.
  private func placingBanner(for pointID: PointID) -> some View {
    let (name, letter, color): (String, String, Color) = switch pointID {
    case .pointA: (L10n.Tools.Tools.LineOfSight.pointA, "A", .blue)
    case .pointB: (L10n.Tools.Tools.LineOfSight.pointB, "B", .green)
    case .repeater: (L10n.Tools.Tools.LineOfSight.repeater, "R", .purple)
    }
    return HStack(spacing: 12) {
      LOSPointBadge(letter: letter, color: color)
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.Tools.Tools.LineOfSight.relocating(name))
          .font(.body.weight(.semibold))
        Text(L10n.Tools.Tools.LineOfSight.tapMapInstruction)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Button(L10n.Tools.Tools.LineOfSight.cancel) {
        viewModel.relocatingPoint = nil
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .cardSurface(isSelected: true)
  }
}
