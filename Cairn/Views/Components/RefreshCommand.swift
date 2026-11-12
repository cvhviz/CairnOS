import SwiftUI

/// Pairs a pull-to-refresh screen with ⌘R. On Mac, where a mouse can't pull to refresh, it also
/// adds a visible toolbar Refresh button (unless the screen keeps its bar for something else);
/// elsewhere the shortcut rides on an invisible button so the layout is unchanged (it still lists
/// in the iPad ⌘-hold overlay).
private struct RefreshCommand: ViewModifier {
  let showsMacToolbarButton: Bool
  let action: () async -> Void

  @State private var isRefreshing = false

  func body(content: Content) -> some View {
    if showsMacToolbarButton, ProcessInfo.processInfo.isiOSAppOnMac {
      content.toolbar {
        ToolbarItem(placement: .primaryAction) {
          refreshButton
            .labelStyle(.iconOnly)
            .help(L10n.Localizable.Commands.refresh)
        }
      }
    } else {
      content.background {
        refreshButton
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }

  private var refreshButton: some View {
    Button(L10n.Localizable.Commands.refresh, systemImage: "arrow.clockwise") {
      guard !isRefreshing else { return }
      isRefreshing = true
      Task {
        await action()
        isRefreshing = false
      }
    }
    .keyboardShortcut("r", modifiers: .command)
    .disabled(isRefreshing)
  }
}

extension View {
  /// Adds ⌘R (and a toolbar button on Mac) running the same work as the screen's `.refreshable`.
  /// `showsMacToolbarButton: false` leaves the Mac's bar alone, so there it is ⌘R only.
  func refreshCommand(showsMacToolbarButton: Bool = true, _ action: @escaping () async -> Void) -> some View {
    modifier(RefreshCommand(showsMacToolbarButton: showsMacToolbarButton, action: action))
  }
}
