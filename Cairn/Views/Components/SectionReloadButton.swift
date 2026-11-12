import SwiftUI

/// Trailing reload affordance for a collapsible status/settings section label.
/// Shows a spinner while the section is loading and a borderless reload button
/// once it has loaded, matching `ExpandableSettingsCard`'s reload idiom.
/// The button also appears when `hasError` is set so a first-load failure still
/// exposes a retry affordance instead of leaving only the inline error text.
struct SectionReloadButton: View {
  let isLoading: Bool
  let isLoaded: Bool
  let hasError: Bool
  let isDisabled: Bool
  let accessibilityLabel: String
  let onReload: () async -> Void

  private enum Layout {
    static let spinnerScale: CGFloat = 0.8
    /// Grows the caption-size reload icon's hit area to about 44 pt. The button is padded
    /// and then negatively padded, so it overflows its slot and the row keeps its layout.
    static let reloadHitSlop: CGFloat = 16
  }

  var body: some View {
    if isLoading {
      ProgressView()
        .scaleEffect(Layout.spinnerScale)
        .padding(.trailing)
    } else if isLoaded || hasError {
      Button {
        Task { await onReload() }
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.caption)
          .padding(Layout.reloadHitSlop)
          .contentShape(.rect)
      }
      .buttonStyle(.borderless)
      .padding(-Layout.reloadHitSlop)
      .padding(.trailing)
      .disabled(isDisabled)
      .accessibilityLabel(accessibilityLabel)
    }
  }
}
