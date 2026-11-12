import CairnServices
import SwiftUI

/// Point A or B as a card. Empty, the card is a button that starts placing the point (the sheet
/// drops and the next tap on the map, or on a repeater, sets it), with Use My Location beside it.
/// Placed, it shows the point's name and its ground and antenna heights; a tap opens the antenna
/// height editor in the card, and the ••• menu holds the rest (move, share, remove).
struct PointRowView: View {
  var viewModel: LineOfSightViewModel
  let label: String
  let color: Color
  let point: SelectedPoint?
  let pointID: PointID
  @Binding var copyHapticTrigger: Int
  @Binding var editingPoint: PointID?
  let onRelocate: () -> Void
  /// Sets the point to where the phone is; nil leaves the button out.
  let onUseMyLocation: (() -> Void)?
  let onClear: () -> Void

  private var isEditing: Bool {
    editingPoint == pointID
  }

  private var placeholderName: String {
    pointID == .pointA ? L10n.Tools.Tools.LineOfSight.pointA : L10n.Tools.Tools.LineOfSight.pointB
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Button {
          if point == nil {
            viewModel.relocatingPoint = pointID
            onRelocate()
          } else {
            withAnimation { editingPoint = isEditing ? nil : pointID }
          }
        } label: {
          HStack(spacing: 12) {
            LOSPointBadge(letter: label, color: color, isPlaced: point != nil)
            VStack(alignment: .leading, spacing: 2) {
              Text(point?.displayName ?? placeholderName)
                .font(.body.weight(point == nil ? .regular : .semibold))
                .foregroundStyle(point == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
              subtitle
            }
            Spacer(minLength: 0)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(point == nil ? L10n.Tools.Tools.LineOfSight.chooseOnMapHint : L10n.Tools.Tools.LineOfSight.antennaHeight)

        if point == nil {
          if let onUseMyLocation {
            Button(L10n.Tools.Tools.LineOfSight.useMyLocation, systemImage: "location.fill", action: onUseMyLocation)
              .labelStyle(.iconOnly)
              .font(.body.weight(.semibold))
              .foregroundStyle(color)
              .frame(width: 36, height: 36)
              .background(color.opacity(0.15), in: .circle)
              .buttonStyle(.plain)
          }
        } else {
          PointRowButtonsView(
            viewModel: viewModel,
            pointID: pointID,
            isEditing: isEditing,
            copyHapticTrigger: $copyHapticTrigger,
            editingPoint: $editingPoint,
            onRelocate: onRelocate,
            onClear: onClear
          )
        }
      }

      if isEditing, let point {
        Divider()
        PointHeightEditorView(viewModel: viewModel, point: point, pointID: pointID)
      }
    }
    .cardSurface(isSelected: viewModel.relocatingPoint == pointID || isEditing)
    .animation(.easeInOut(duration: 0.2), value: isEditing)
  }

  @ViewBuilder
  private var subtitle: some View {
    if let point {
      if point.isLoadingElevation {
        HStack(spacing: 4) {
          ProgressView()
            .controlSize(.mini)
          Text(L10n.Tools.Tools.LineOfSight.loadingElevation)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
      } else {
        Text([
          point.isDiscovered ? L10n.Map.Map.Callout.discovered : nil,
          LOSPointBadge.heightSummary(ground: point.groundElevation, antenna: point.additionalHeight),
        ].compactMap(\.self).joined(separator: " · "))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    } else {
      Text(L10n.Tools.Tools.LineOfSight.chooseOnMapHint)
        .font(.footnote)
        .foregroundStyle(color)
    }
  }
}

/// A point's letter on a tile in its colour (A blue, B green, R purple), the shape of the app's
/// icon tiles; grey while the point isn't placed.
struct LOSPointBadge: View {
  let letter: String
  let color: Color
  var isPlaced = true
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 32

  var body: some View {
    Text(letter)
      .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        (isPlaced ? color : Color.gray.opacity(0.45)).gradient,
        in: .rect(cornerRadius: size * 0.25, style: .continuous)
      )
      .accessibilityHidden(true)
  }

  /// "Ground 42 m · Antenna 7 m", or the antenna alone before the ground is known.
  static func heightSummary(ground: Double?, antenna: Double) -> String {
    let antennaText = LOSFormatters.formatElevation(antenna)
    guard let ground else { return "\(L10n.Tools.Tools.LineOfSight.antennaHeight) \(antennaText)" }
    return L10n.Tools.Tools.LineOfSight.heightSummary(LOSFormatters.formatElevation(ground), antennaText)
  }
}
