import CairnServices
import SwiftUI

struct SavedPathRow: View {
  let path: SavedTracePathDTO

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(path.name)
        .font(.body)

      HStack(spacing: 8) {
        // Run count and recency
        Text(subtitleText)
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        // Health indicator
        healthDot

        // Mini sparkline
        if !path.recentRTTs.isEmpty {
          MiniSparkline(values: path.recentRTTs)
            .frame(width: 50, height: 16)
            .accessibilityLabel(sparklineAccessibilityLabel)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private var subtitleText: String {
    var parts: [String] = []

    // Run count
    let runText = path.runCount == 1
      ? L10n.Contacts.Contacts.SavedPaths.Runs.singular
      : L10n.Contacts.Contacts.SavedPaths.Runs.plural(path.runCount)
    parts.append(runText)

    // Last run
    if let lastDate = path.lastRunDate {
      parts.append(L10n.Contacts.Contacts.SavedPaths.lastRun(lastDate.relativeFormatted))
    }

    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private var healthDot: some View {
    let rate = path.successRate
    let healthDescription = rate >= 90
      ? L10n.Contacts.Contacts.SavedPaths.Health.healthy
      : rate >= 50
      ? L10n.Contacts.Contacts.SavedPaths.Health.degraded
      : L10n.Contacts.Contacts.SavedPaths.Health.poor
    // A different shape per state, so the health doesn't rest on telling the colors apart.
    Image(systemName: rate >= 90
      ? "checkmark.circle.fill"
      : rate >= 50 ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
      .font(.caption2)
      .foregroundStyle(rate >= 90 ? Color.green : rate >= 50 ? Color.yellow : Color.red)
      .accessibilityLabel(L10n.Contacts.Contacts.SavedPaths.healthLabel(healthDescription, rate))
  }

  private var sparklineAccessibilityLabel: String {
    let rtts = path.recentRTTs
    guard !rtts.isEmpty else { return L10n.Contacts.Contacts.SavedPaths.noResponseData }

    let avgRTT = rtts.reduce(0, +) / rtts.count
    let trend: String
    if rtts.count >= 2 {
      let firstHalf = rtts.prefix(rtts.count / 2).reduce(0, +) / max(1, rtts.count / 2)
      let secondHalf = rtts.suffix(rtts.count / 2).reduce(0, +) / max(1, rtts.count / 2)
      if secondHalf > firstHalf + 50 {
        trend = L10n.Contacts.Contacts.SavedPaths.Trend.increasing
      } else if secondHalf < firstHalf - 50 {
        trend = L10n.Contacts.Contacts.SavedPaths.Trend.decreasing
      } else {
        trend = L10n.Contacts.Contacts.SavedPaths.Trend.stable
      }
    } else {
      trend = L10n.Contacts.Contacts.SavedPaths.Trend.stable
    }
    return L10n.Contacts.Contacts.SavedPaths.responseTimes(avgRTT, trend)
  }
}
