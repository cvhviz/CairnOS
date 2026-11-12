import CairnServices
import SwiftUI

/// Analysis results with progressive disclosure: the verdict on its own card (tap to expand),
/// then the figures as tiles beside it on the canvas rather than tiles drawn inside a card.
struct ResultsCardView: View {
  let result: PathAnalysisResult
  @Binding var isExpanded: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      LOSSectionHeader(title: L10n.Tools.Tools.LineOfSight.results)

      // Collapsed summary (always visible)
      collapsedContent

      // Expanded details
      if isExpanded {
        expandedContent
      }
    }
  }

  // MARK: - Collapsed Content

  private var collapsedContent: some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            ClearanceStatusView(
              status: result.clearanceStatus,
              clearancePercent: result.worstClearancePercent
            )

            Spacer()

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          // Blocked subtitle
          if result.clearanceStatus == .blocked {
            Text(ClearanceStatus.blockedSubtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .cardSurface()
        .cardInteractionShape()
      }
      .buttonStyle(.plain)

      MetricTileGrid {
        MetricTile(
          L10n.Tools.Tools.LineOfSight.distance,
          systemImage: "ruler",
          value: LOSFormatters.formatDistance(result.distanceMeters)
        )
        MetricTile(
          L10n.Tools.Tools.LineOfSight.totalPathLoss,
          systemImage: "chart.line.downtrend.xyaxis",
          value: LOSFormatters.formatPathLoss(result.totalPathLoss)
        )
      }
    }
  }

  // MARK: - Expanded Content

  /// What makes up the loss and how close the terrain comes, then the assumptions behind it.
  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      MetricTileGrid {
        MetricTile(
          L10n.Tools.Tools.LineOfSight.freeSpaceLoss,
          systemImage: "dot.radiowaves.right",
          value: LOSFormatters.formatPathLoss(result.freeSpacePathLoss)
        )
        // Negligible diffraction stays off the grid, as it did in the breakdown it replaces.
        if let diffractionText = LOSFormatters.formatDiffractionLoss(result.peakDiffractionLoss) {
          MetricTile(
            L10n.Tools.Tools.LineOfSight.diffractionLoss,
            systemImage: "mountain.2",
            value: diffractionText
          )
        }
        MetricTile(
          L10n.Tools.Tools.LineOfSight.worstClearanceShort,
          systemImage: "arrow.up.and.down",
          value: clearanceText(result.worstClearancePercent)
        )
        MetricTile(
          L10n.Tools.Tools.LineOfSight.obstructionsFound,
          systemImage: "exclamationmark.triangle",
          value: result.obstructionPoints.count.formatted()
        )
      }
      assumptionsFootnote
    }
  }

  // MARK: - Assumptions Footnote

  private var assumptionsFootnote: some View {
    HStack(spacing: 6) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)

      Text(LOSFormatters.formatAssumptions(
        frequencyMHz: result.frequencyMHz,
        k: result.refractionK
      ))
      .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Preview

#Preview("Clear Path") {
  let result = PathAnalysisResult(
    distanceMeters: 12400,
    freeSpacePathLoss: 118.2,
    peakDiffractionLoss: 0,
    totalPathLoss: 118.2,
    clearanceStatus: .clear,
    worstClearancePercent: 92,
    obstructionPoints: [],
    frequencyMHz: 906,
    refractionK: 1.33
  )

  return ResultsCardView(result: result, isExpanded: .constant(false))
    .padding()
}

#Preview("Partial Obstruction - Expanded") {
  let result = PathAnalysisResult(
    distanceMeters: 12400,
    freeSpacePathLoss: 118.2,
    peakDiffractionLoss: 8.4,
    totalPathLoss: 126.6,
    clearanceStatus: .partialObstruction,
    worstClearancePercent: 47,
    obstructionPoints: [
      ObstructionPoint(distanceFromAMeters: 5000, obstructionHeightMeters: 12, fresnelClearancePercent: 47),
      ObstructionPoint(distanceFromAMeters: 7200, obstructionHeightMeters: 8, fresnelClearancePercent: 55)
    ],
    frequencyMHz: 906,
    refractionK: 1.33
  )

  return ResultsCardView(result: result, isExpanded: .constant(true))
    .padding()
}

#Preview("Blocked - Expanded") {
  let result = PathAnalysisResult(
    distanceMeters: 8500,
    freeSpacePathLoss: 112.5,
    peakDiffractionLoss: 22.3,
    totalPathLoss: 134.8,
    clearanceStatus: .blocked,
    worstClearancePercent: -15,
    obstructionPoints: [
      ObstructionPoint(distanceFromAMeters: 4200, obstructionHeightMeters: 35, fresnelClearancePercent: -15)
    ],
    frequencyMHz: 915,
    refractionK: 1.33
  )

  return ResultsCardView(result: result, isExpanded: .constant(true))
    .padding()
}

// MARK: - Relay Results Card View

/// Relay path analysis results: the overall verdict and its two segments on one card (tap to
/// expand), the figures as tiles, and when expanded each segment's detail on its own card.
struct RelayResultsCardView: View {
  let result: RelayPathAnalysisResult
  @Binding var isExpanded: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      LOSSectionHeader(title: L10n.Tools.Tools.LineOfSight.results)

      collapsedContent

      if isExpanded {
        expandedContent
      }
    }
  }

  // MARK: - Collapsed Content

  private var collapsedContent: some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            ClearanceStatusView(
              status: result.overallStatus,
              clearancePercent: min(
                result.segmentAR.worstClearancePercent,
                result.segmentRB.worstClearancePercent
              )
            )
            Spacer()
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Divider()

          // Segment summary
          VStack(alignment: .leading, spacing: 4) {
            segmentRow(segment: result.segmentAR)
            segmentRow(segment: result.segmentRB)
          }
        }
        .cardSurface()
        .cardInteractionShape()
      }
      .buttonStyle(.plain)

      MetricTileGrid {
        MetricTile(
          L10n.Tools.Tools.LineOfSight.distance,
          systemImage: "ruler",
          value: LOSFormatters.formatDistance(result.totalDistanceMeters),
          caption: L10n.Tools.Tools.LineOfSight.total
        )
        MetricTile(
          L10n.Tools.Tools.LineOfSight.worstClearanceShort,
          systemImage: "arrow.up.and.down",
          value: clearanceText(min(result.segmentAR.worstClearancePercent, result.segmentRB.worstClearancePercent))
        )
      }
    }
  }

  private func segmentRow(segment: SegmentAnalysisResult) -> some View {
    HStack {
      Circle()
        .fill(segment.clearanceStatus.color)
        .frame(width: 8, height: 8)

      Text("\(segment.startLabel) \u{2192} \(segment.endLabel)")
        .font(.caption)

      Text(segment.clearanceStatus.localizedName)
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()

      Text(LOSFormatters.formatDistance(segment.distanceMeters))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Expanded Content

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      segmentDetailView(segment: result.segmentAR)
      segmentDetailView(segment: result.segmentRB)
    }
  }

  private func segmentDetailView(segment: SegmentAnalysisResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(segment.startLabel) \u{2192} \(segment.endLabel)")
        .font(.subheadline)
        .bold()

      Grid(alignment: .leading, verticalSpacing: 4) {
        GridRow {
          Text(L10n.Tools.Tools.LineOfSight.status)
            .foregroundStyle(.secondary)
          Spacer()
          Text(segment.clearanceStatus.localizedName)
        }
        GridRow {
          Text(L10n.Tools.Tools.LineOfSight.distance)
            .foregroundStyle(.secondary)
          Spacer()
          Text(LOSFormatters.formatDistance(segment.distanceMeters))
        }
        GridRow {
          Text(L10n.Tools.Tools.LineOfSight.worstClearanceShort)
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(LOSFormatters.formatClearancePercent(segment.worstClearancePercent))%")
        }
      }
      .font(.caption)
    }
    .cardSurface()
  }
}

// MARK: - Relay Results Previews

#Preview("Relay - Clear Path") {
  let result = RelayPathAnalysisResult(
    segmentAR: SegmentAnalysisResult(
      startLabel: "A",
      endLabel: "R",
      clearanceStatus: .clear,
      distanceMeters: 5200,
      worstClearancePercent: 85
    ),
    segmentRB: SegmentAnalysisResult(
      startLabel: "R",
      endLabel: "B",
      clearanceStatus: .clear,
      distanceMeters: 7200,
      worstClearancePercent: 92
    )
  )

  return RelayResultsCardView(result: result, isExpanded: .constant(false))
    .padding()
}

#Preview("Relay - Mixed Clearance - Expanded") {
  let result = RelayPathAnalysisResult(
    segmentAR: SegmentAnalysisResult(
      startLabel: "A",
      endLabel: "R",
      clearanceStatus: .clear,
      distanceMeters: 5200,
      worstClearancePercent: 85
    ),
    segmentRB: SegmentAnalysisResult(
      startLabel: "R",
      endLabel: "B",
      clearanceStatus: .partialObstruction,
      distanceMeters: 7200,
      worstClearancePercent: 45
    )
  )

  return RelayResultsCardView(result: result, isExpanded: .constant(true))
    .padding()
}

// MARK: - Section Header

/// A section title in the analysis panel, above its cards: the card form's section title.
struct LOSSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Color.secondary)
      .padding(.horizontal, 4)
      .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Formatting

/// Clearance as a tile value, clamped to 0–100 like the rest of the results.
private func clearanceText(_ percent: Double) -> String {
  (Double(LOSFormatters.formatClearancePercent(percent)) / 100).formatted(.percent.precision(.fractionLength(0)))
}
