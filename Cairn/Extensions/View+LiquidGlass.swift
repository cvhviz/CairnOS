import SwiftUI

extension View {
  /// Applies liquid glass effect on iOS 26+, falls back to regularMaterial on earlier versions
  @ViewBuilder
  func liquidGlass(in shape: some Shape = .rect(cornerRadius: 12)) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(in: shape)
    } else {
      background(.regularMaterial, in: shape)
    }
  }

  /// Applies glass button style on iOS 26+, falls back to borderedProminent on earlier versions
  @ViewBuilder
  func liquidGlassButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.borderedProminent)
    }
  }

  /// Applies glass button style on iOS 26+, falls back to bordered (secondary weight) on earlier versions
  @ViewBuilder
  func liquidGlassSecondaryButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.bordered)
    }
  }

  /// Applies prominent glass button style with tint on iOS 26+, falls back to borderedProminent on earlier versions
  @ViewBuilder
  func liquidGlassProminentButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      buttonStyle(.glassProminent)
    } else {
      buttonStyle(.borderedProminent)
    }
  }

  /// Applies interactive liquid glass effect on iOS 26+, falls back to thinMaterial on earlier versions
  @ViewBuilder
  func liquidGlassInteractive(in shape: some Shape = .circle) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(.regular.interactive(), in: shape)
    } else {
      background(.thinMaterial, in: shape)
    }
  }

  #if os(iOS)
    /// Applies visible toolbar backgrounds for full-screen content views.
    /// On iOS 26+, explicitly sets visibility so system applies liquid glass.
    /// On iOS 18, uses regularMaterial background.
    @ViewBuilder
    func liquidGlassToolbarBackground() -> some View {
      if #available(iOS 26.0, *) {
        toolbarBackgroundVisibility(.visible, for: .navigationBar)
      } else {
        toolbarBackground(.regularMaterial, for: .navigationBar, .tabBar)
          .toolbarBackgroundVisibility(.visible, for: .navigationBar, .tabBar)
      }
    }
  #endif
}

extension View {
  /// Applies glassEffectID on iOS 26+ for smooth morphing transitions, no-op on earlier versions
  @ViewBuilder
  func liquidGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
    if #available(iOS 26.0, *) {
      glassEffectID(id, in: namespace)
    } else {
      self
    }
  }
}

/// Drop-in replacement for `Menu` that works around an iPadOS 26 Liquid Glass bug
/// where toolbar Menus leave a ghost box after dismissal.
///
/// On iOS 26+, renders the label as a plain view with an invisible interactive `Menu`
/// overlay, so the glass morph animation has nothing visible to ghost.
/// On earlier iOS versions, uses a standard `Menu`.
struct ToolbarMenu<Content: View, LabelView: View>: View {
  @ViewBuilder let content: Content
  @ViewBuilder let label: LabelView

  var body: some View {
    if #available(iOS 26, *) {
      // Sibling layout so a tint on the visible label does not flow into
      // menu rows (destructive, secondary, and default each keep their color).
      // An overlay, so the clear tap target takes the label's size: on its own it
      // fills the width the bar offers, stretching the button's glass into a long
      // capsule and squeezing the bar's centred title out.
      label
        .accessibilityHidden(true)
        .overlay {
          Menu {
            content
          } label: {
            Rectangle()
              .fill(.clear)
              .contentShape(Rectangle())
          }
          // On a Mac a menu is a pull-down button with a disclosure arrow and a minimum width of
          // its own, wider than the label, and the bar stretched the button's glass round it.
          .menuIndicator(.hidden)
          .colorMultiply(.clear)
        }
        // The label's size is the button's size, whatever the menu over it would like.
        .fixedSize()
    } else {
      Menu { content } label: { label }
    }
  }
}

/// A container that uses GlassEffectContainer on iOS 26+, passes through content on earlier versions
struct LiquidGlassContainer<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content

  init(spacing: CGFloat = 20, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      content
    }
  }
}

#if os(iOS)
  extension View {
    /// The tab pages' backdrop behind the navigation bar: a thin material from the top of the
    /// screen to the bar's bottom edge, always drawn, so every tab's top reads alike whether its
    /// content sits under the bar or not (the user, 2026-11-08: as the Nodes list showed it, by
    /// the scroll edge effect, while its search waits above the list). The system's own top edge
    /// effect is turned off so the two never stack. iOS 18 keeps the material bar.
    @ViewBuilder
    func tabTopBarBackdrop() -> some View {
      if #available(iOS 26.0, *) {
        scrollEdgeEffectHidden(true, for: .top)
          .overlay(alignment: .top) {
            GeometryReader { proxy in
              Rectangle()
                .fill(.ultraThinMaterial)
                // As light as the Nodes list's edge effect drew it.
                .opacity(0.4)
                .frame(height: proxy.safeAreaInsets.top)
                .offset(y: -proxy.safeAreaInsets.top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
          }
      } else {
        liquidGlassToolbarBackground()
      }
    }
  }
#endif
