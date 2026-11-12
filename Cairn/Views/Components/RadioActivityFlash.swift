import SwiftUI

/// The radio's RX and TX LED, lit behind the bar's centre title: Dashboard's CAIRN
/// (`HomeAppTitle`), the connected radio's green name on the other tabs
/// (`DeviceNameTitleModifier`) and every other page's name (`FlashingPageTitle`). Green for each packet heard, red for each one sent, from
/// `RadioActivity`, fading back to nothing in about half a second. Only this view reads the
/// counters, so a busy mesh redraws the glow and never the title or the bar around it.
///
/// Always the same two layers, varied by value, so the hosted toolbar item keeps one identity (see
/// `DeviceInfoButton`).
private struct RadioActivityGlow: View {
  @Environment(\.appState) private var appState

  var body: some View {
    ZStack {
      ActivityFlash(color: .green, trigger: appState.radioActivity.receivedCount)
      ActivityFlash(color: .red, trigger: appState.radioActivity.sentCount)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    #if DEBUG
      // Screenshot runs make the LED flash: `-uiTestRadioActivityDemo YES`.
      .task {
        if UserDefaults.standard.bool(forKey: "uiTestRadioActivityDemo") {
          appState.radioActivity.startDemo()
        }
      }
    #endif
  }
}

/// One LED flash: invisible until `trigger` changes, then a capsule lit in `color` with a glow,
/// fading out in about half a second. Keyframes rather than a state flipped up and back, which
/// SwiftUI would merge into no change at all. A tint rather than a solid fill, so the title over it
/// (the radio's name is green itself) stays readable at the flash's peak. Only its opacity changes,
/// nothing moves, so Reduce Motion leaves it as it is.
private struct ActivityFlash: View {
  let color: Color
  let trigger: Int

  /// The flash's strength at its peak.
  static let peakOpacity = 0.4

  var body: some View {
    Capsule()
      .fill(color.opacity(Self.peakOpacity))
      .keyframeAnimator(initialValue: 0.0, trigger: trigger) { led, lit in
        led
          .opacity(lit)
          .shadow(color: color.opacity(0.9 * lit), radius: 6 * lit)
      } keyframes: { _ in
        LinearKeyframe(1, duration: 0.04)
        CubicKeyframe(1, duration: 0.1)
        CubicKeyframe(0, duration: 0.45)
      }
  }
}

extension View {
  /// Lights the radio's RX/TX LED behind this title (see `RadioActivityGlow`), reaching `outset`
  /// past its edges so bare text gets a capsule round it rather than a box cut to the glyphs.
  func radioActivityFlash(horizontalOutset: CGFloat = 0, verticalOutset: CGFloat = 0) -> some View {
    background {
      RadioActivityGlow()
        .padding(.horizontal, -horizontalOutset)
        .padding(.vertical, -verticalOutset)
    }
  }
}

/// A page's name as the bar's centre title, with the radio's RX/TX LED lit behind it like the tabs'
/// titles, on a capsule over a background image. Plain text otherwise, and hidden from VoiceOver:
/// the navigation title beside it names the page.
struct FlashingPageTitle: View {
  @Environment(\.appTheme) private var theme
  let title: String
  /// A small live dot after the name (Scan & Traffic): green while packets can arrive, grey
  /// otherwise; nil for none. Always there once asked for, so the title never shifts.
  var liveDot: Bool?

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.headline)
        .lineLimit(1)
      if let liveDot {
        Circle()
          .fill(liveDot ? Color.green : Color.gray)
          .frame(width: 7, height: 7)
      }
    }
    .padding(.horizontal, theme.hasBackdrop ? 12 : 0)
    .padding(.vertical, theme.hasBackdrop ? 4 : 0)
    .radioActivityFlash(horizontalOutset: theme.hasBackdrop ? 0 : 12, verticalOutset: theme.hasBackdrop ? 0 : 3)
    .background {
      Capsule()
        .fill(.regularMaterial)
        .opacity(theme.hasBackdrop ? 1 : 0)
    }
    .accessibilityHidden(true)
  }
}

extension View {
  /// This page's navigation title, shown with the radio's RX/TX LED behind it (`FlashingPageTitle`).
  func flashingNavigationTitle(_ title: some StringProtocol) -> some View {
    navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .principal) {
          FlashingPageTitle(title: String(title))
        }
      }
  }

  /// The same, with a live dot after the name (`FlashingPageTitle.liveDot`), which VoiceOver
  /// reads as Live or Offline.
  func flashingNavigationTitle(_ title: some StringProtocol, liveDot: Bool) -> some View {
    navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .principal) {
          FlashingPageTitle(title: String(title), liveDot: liveDot)
            .accessibilityHidden(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(liveDot ? L10n.Tools.Tools.RxLog.live : L10n.Tools.Tools.RxLog.offline)
            .accessibilityIdentifier("nodeDiscovery.live")
        }
      }
  }
}
