import Accessibility
import SwiftUI

// MARK: - Offline Badge

/// "Offline" over the map while there is no network: a plain word when a downloaded pack covers
/// what's shown, "no map for this area" when none does, and a thin bar along its bottom while a
/// pack is still downloading. With an action it is a button to the offline maps settings.
struct OfflineBadge: View {
  /// Pins itself to the top-trailing corner of the space it is given. False for a caller that
  /// stacks it with its own corner controls (the GPS map's compass), so layout keeps them apart.
  var placesItself = true
  /// A completed pack covers the visible area; false reads "no map for this area".
  var hasCoverage = true
  /// How far along an unfinished pack is (0...1), shown as a bar; nil with none downloading.
  var downloadProgress: Double?
  /// Opens the offline maps settings; nil leaves the badge a plain label.
  var action: (() -> Void)?

  private var text: String {
    hasCoverage ? L10n.Map.Map.OfflineBadge.label : L10n.Map.Map.OfflineBadge.noCoverage
  }

  private var progressText: String? {
    downloadProgress.map { L10n.Map.Map.OfflineBadge.downloading($0.formatted(.percent.precision(.fractionLength(0)))) }
  }

  var body: some View {
    Group {
      if let action {
        Button(action: action) { label }
          .buttonStyle(.plain)
          .accessibilityHint(L10n.Settings.Maps.offlineHeader)
      } else {
        label
          .accessibilityAddTraits(.isStaticText)
      }
    }
    .accessibilityValue(progressText ?? "")
    .modifier(TopTrailingPlacement(isActive: placesItself))
    .onAppear {
      AccessibilityNotification.Announcement(text).post()
    }
    .onChange(of: hasCoverage) { _, _ in
      AccessibilityNotification.Announcement(text).post()
    }
  }

  private var label: some View {
    HStack(spacing: 6) {
      if !hasCoverage {
        Image(systemName: "wifi.slash")
          .accessibilityHidden(true)
      }
      Text(text)
    }
    .font(.caption)
    .bold()
    .lineLimit(1)
    .padding(.horizontal)
    .padding(.vertical, 6)
    .liquidGlass(in: .capsule)
    .overlay(alignment: .bottom) {
      if let downloadProgress {
        ProgressView(value: min(max(downloadProgress, 0), 1))
          .progressViewStyle(.linear)
          .tint(.teal)
          .frame(height: 3)
          .padding(.horizontal, 10)
          .padding(.bottom, 3)
          .accessibilityHidden(true)
      }
    }
    .contentShape(.capsule)
    .animation(.default, value: downloadProgress == nil)
  }
}

private struct TopTrailingPlacement: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    if isActive {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing)
        .padding(.top)
    } else {
      content
    }
  }
}
