import SwiftUI

/// The analysis didn't finish: why, as a card, with Retry.
struct AnalysisErrorView: View {
  let message: String
  let hasRepeater: Bool
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SettingCardLabel(
        L10n.Tools.Tools.LineOfSight.analysisFailed,
        systemImage: "exclamationmark.triangle.fill",
        color: .orange,
        subtitle: message
      )
      Button(L10n.Tools.Tools.LineOfSight.retry, systemImage: "arrow.clockwise", action: onRetry)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .cardSurface()
  }
}
