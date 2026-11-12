import SwiftUI

extension EnvironmentValues {
  /// True inside a page that paints the user's background (`themedCanvas`, `cardCanvas`,
  /// `cardListCanvas`). Cards and rows read it to draw as glass over the background; anywhere
  /// else they keep the opaque system card, so a card never turns see-through on a plain page.
  @Entry var isOnAppBackdrop = false
}

extension View {
  /// Paint the receiver's scroll/content background with the user's background, hiding the
  /// SwiftUI default. No-op with the system background — preserves system rendering, including
  /// iOS 26 Form Liquid Glass treatments that a manual `Color(.systemGroupedBackground)` would
  /// override.
  func themedCanvas(_ theme: Theme) -> some View {
    modifier(ThemedCanvasModifier(theme: theme))
  }

  /// Paint a `Section`'s rows as frosted material over the user's background. No-op with the
  /// system background — preserves system `.secondarySystemGroupedBackground` rendering.
  /// For a `.sidebar`-styled list (the iPad Settings split-view column) pass `flatten: true`,
  /// so rows stay transparent and the native sidebar selection highlight survives.
  func themedRowBackground(_ theme: Theme, flatten: Bool = false) -> some View {
    modifier(ThemedRowBackgroundModifier(theme: theme, flatten: flatten))
  }

  /// Navigation and tab bars stay the system bars (Liquid Glass on iOS 26) in every
  /// background: they float over the page, so they adapt to whatever is behind them.
  func themedChrome(_: Theme) -> some View {
    toolbarBackground(Material.bar, for: .navigationBar, .tabBar)
      .toolbarBackgroundVisibility(.automatic, for: .navigationBar, .tabBar)
  }

  /// Paints the user's background behind the receiver, edge to edge, and marks the subtree as
  /// sitting on it. Shared by every canvas modifier.
  func appBackdrop(_ backdrop: ResolvedBackdrop) -> some View {
    background { AppBackdropView(backdrop: backdrop).ignoresSafeArea() }
      .environment(\.isOnAppBackdrop, true)
  }
}

private struct ThemedCanvasModifier: ViewModifier {
  let theme: Theme

  func body(content: Content) -> some View {
    if let backdrop = theme.backdrop {
      content
        .scrollContentBackground(.hidden)
        .appBackdrop(backdrop)
    } else {
      content
    }
  }
}

private struct ThemedRowBackgroundModifier: ViewModifier {
  let theme: Theme
  let flatten: Bool

  @Environment(\.isOnAppBackdrop) private var isOnAppBackdrop

  func body(content: Content) -> some View {
    if theme.hasBackdrop, isOnAppBackdrop, !flatten {
      // Material, not per-row glass: grouped rows tile edge to edge inside one section card,
      // and glass draws a rim on every row, which would read as seams between them.
      content.listRowBackground(BackdropRowFill())
    } else {
      content
    }
  }
}

/// The fill for a grouped-list row over the user's background: regular material, or the opaque
/// grouped card color with Reduce Transparency on.
struct BackdropRowFill: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if reduceTransparency {
      Rectangle().fill(Color(.secondarySystemGroupedBackground))
    } else {
      Rectangle().fill(.regularMaterial)
    }
  }
}
