import SwiftUI

/// The one card look the whole app shares: reading tiles, navigation tiles, node cards, list rows
/// drawn as cards. Everything that reads as a card should get its fill, corner and selection
/// treatment from here so the family stays consistent across themes.
@MainActor
enum CardStyle {
  static let cornerRadius: CGFloat = 14
  /// Space between cards in a grid or a card list, and around them at the page edge.
  static let spacing: CGFloat = 10
  static let pageInset: CGFloat = 16
  /// `CardForm`'s padding above and below its sections; an empty state filling the page leaves
  /// both out (`emptyStateFrame(below: CardStyle.formVerticalInset * 2)`).
  static let formVerticalInset: CGFloat = 12
  /// A Settings row (`CardFormSection` within Settings), as the iPhone's own Settings draws one:
  /// its side inset, its top and bottom inset, and its least height.
  static let rowInset: CGFloat = 16
  static let rowVerticalInset: CGFloat = 10
  static let rowMinHeight: CGFloat = 44
  /// Where a Settings row's separator starts: under the title, past the icon tile.
  static let rowSeparatorInset: CGFloat = 56

  static var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }
}

extension View {
  /// Pads the content and paints it as a card (`CardBackground`): the grouped secondary color,
  /// or glass over the user's background, with an accent outline and wash when `isSelected`
  /// (the item open in the iPad detail column).
  func cardSurface(isSelected: Bool = false, padding: CGFloat = 12) -> some View {
    modifier(CardSurfaceModifier(isSelected: isSelected, padding: padding))
  }

  /// Taps, the pointer hover and the context-menu lift follow the card's rounded shape rather
  /// than a square around it. Apply to a tappable card (a link, a button, a context menu host).
  func cardInteractionShape() -> some View {
    contentShape(.interaction, CardStyle.shape)
      .contentShape(.contextMenuPreview, CardStyle.shape)
      .contentShape(.hoverEffect, CardStyle.shape)
      .hoverEffect(.highlight)
  }

  /// The page background cards sit on: the user's background (cards then draw as glass), or
  /// the grouped background. Cards are the grouped secondary color, so on a plain white page
  /// they would vanish. For `ScrollView` pages; a grouped `List` already paints this (use
  /// `themedCanvas` there).
  @ViewBuilder
  func cardCanvas(_ theme: Theme) -> some View {
    if let backdrop = theme.backdrop {
      appBackdrop(backdrop)
    } else {
      background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
  }

  /// An empty state in a scroll view, as tall as the visible height less `above` points (a filter
  /// header over it, or the page's own vertical padding), so it sits centred where the eye looks
  /// rather than a header's height lower. The scroll view's safe area (bars) is already left out.
  /// The width fills what the page leaves it.
  func emptyStateFrame(below above: CGFloat = 0) -> some View {
    frame(maxWidth: .infinity)
      .containerRelativeFrame(.vertical) { length, _ in max(0, length - above) }
  }

  /// Keeps `size` at what this scroll view shows of its content: its size less the bars over it
  /// (the navigation bar, the floating tab bar), which its safe area insets (`containerSize` leaves
  /// them out). For a page laid out to fill the screen above the tab bar (`fillingScrollHeight`).
  /// Apply to the `ScrollView`.
  func measuringVisibleScrollSize(_ size: Binding<CGSize>) -> some View {
    onScrollGeometryChange(for: CGSize.self) { geometry in
      geometry.containerSize
    } action: { _, newSize in
      size.wrappedValue = newSize
    }
  }

  /// At least `height` tall (the scroll view's visible height, `measuringVisibleScrollSize`) and
  /// offered exactly that, so cards that stretch reach the bottom of the screen; content that needs
  /// more (a short window) still grows past it and scrolls.
  func fillingScrollHeight(_ height: CGFloat) -> some View {
    frame(minHeight: height, idealHeight: height, alignment: .top)
  }

  /// Keeps `height` at this view's height, for `emptyStateFrame(below:)`.
  func measuringHeight(_ height: Binding<CGFloat>) -> some View {
    onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height.wrappedValue = $0 }
  }

  /// Cards in this subtree use `fill` instead of the grouped card color and never draw as
  /// glass: for tiles in a sheet that sits on the plain system background, where the grouped
  /// card color is the same white as the sheet.
  func cardFill(_ fill: Color) -> some View {
    environment(\.cardFillOverride, fill)
      .environment(\.isOnAppBackdrop, false)
  }
}

extension EnvironmentValues {
  /// Opaque card color override, set with `cardFill(_:)`.
  @Entry var cardFillOverride: Color?
}

/// The card fill every card shares, so tiles, card rows and headers stay one family:
/// - the grouped secondary color on the system background (or the `cardFill` override);
/// - Liquid Glass (iOS 26) or regular material (iOS 18–25) over the user's background, falling
///   back to the opaque card color with Reduce Transparency, and adding a hairline edge with
///   Increase Contrast so the card's bounds stay visible over a busy photo;
/// - plus an accent wash and outline when `isSelected`.
struct CardBackground<S: InsettableShape>: View {
  var isSelected = false
  var shape: S

  @Environment(\.appTheme) private var theme
  @Environment(\.isOnAppBackdrop) private var isOnAppBackdrop
  @Environment(\.cardFillOverride) private var fillOverride
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private static var selectedFillOpacity: Double { 0.12 }
  private static var selectedStrokeWidth: CGFloat { 2 }
  private static var contrastStrokeOpacity: Double { 0.35 }

  var body: some View {
    ZStack {
      if usesGlass {
        glass
      } else {
        shape.fill(fillOverride ?? Color(.secondarySystemGroupedBackground))
      }
      if isSelected {
        shape.fill(theme.accentColor.opacity(Self.selectedFillOpacity))
        shape.strokeBorder(theme.accentColor, lineWidth: Self.selectedStrokeWidth)
      } else if usesGlass, contrast == .increased {
        shape.strokeBorder(Color.primary.opacity(Self.contrastStrokeOpacity), lineWidth: 1)
      }
    }
  }

  private var usesGlass: Bool {
    theme.hasBackdrop && isOnAppBackdrop && !reduceTransparency
  }

  @ViewBuilder
  private var glass: some View {
    if #available(iOS 26.0, *) {
      Color.clear.glassEffect(.regular, in: shape)
    } else {
      shape.fill(.regularMaterial)
    }
  }
}

extension CardBackground where S == RoundedRectangle {
  init(isSelected: Bool = false) {
    self.init(isSelected: isSelected, shape: CardStyle.shape)
  }
}

private struct CardSurfaceModifier: ViewModifier {
  let isSelected: Bool
  let padding: CGFloat
  @Environment(\.isGroupedRow) private var isGroupedRow

  func body(content: Content) -> some View {
    if isGroupedRow {
      // One row of a Settings group (`CardFormSection`): the group draws the card behind all its
      // rows, so the row is only padded to the iPhone Settings row's insets and height.
      content
        .padding(.horizontal, CardStyle.rowInset)
        .padding(.vertical, CardStyle.rowVerticalInset)
        .frame(maxWidth: .infinity, minHeight: CardStyle.rowMinHeight, alignment: .leading)
        .background { if isSelected { CardBackground(isSelected: true, shape: Rectangle()) } }
    } else {
      content
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { CardBackground(isSelected: isSelected) }
    }
  }
}

extension EnvironmentValues {
  /// Inside a Settings group drawn as rows (`CardFormSection` within Settings): a card here is one
  /// row of the group, so `cardSurface()` draws no card of its own. Tile grids turn it off again
  /// for their tiles (`MetricTileGrid`), which stay cards.
  @Entry var isGroupedRow = false
}

extension ContainerValues {
  /// A child of a `CardFormSection` that keeps its own look in Settings rather than becoming a row
  /// of the section's group: a grid of tiles, a header card. Set with `settingsStandalone()`.
  @Entry var isSettingsStandalone = false
}

extension View {
  /// Keeps this child of a `CardFormSection` out of the section's grouped rows in Settings: it
  /// draws as it does everywhere else, above or below the group.
  func settingsStandalone() -> some View {
    environment(\.isGroupedRow, false)
      .containerValue(\.isSettingsStandalone, true)
  }
}
