import CairnServices
import SwiftUI
import UIKit

/// Night mode: the whole interface in red on black, to keep eyes dark-adapted at night, the way a
/// red head torch does. The app goes dark, then a filter over everything in its window (pages,
/// sheets, alerts, the map) takes the colour out of each pixel and multiplies what's left by red:
/// white text becomes the brightest red, controls and secondary text dimmer reds, backgrounds near
/// black, and nothing is brighter than red. Nothing has to know
/// about it; it is one switch (`AppStorageKey.nightMode`).
enum NightMode {
  /// The red the interface is multiplied by: white becomes this, everything else a darker red.
  static let red = UIColor(red: 1, green: 0.08, blue: 0.04, alpha: 1)

  /// The tint while night mode is on. Colour is lost under the filter and only brightness is left,
  /// so a blue button or tab would go dim; white keeps them as bright as the readings.
  static let tint = Color.white
}

extension AppTab {
  /// The tab's colour, or `NightMode.tint` while night mode is on.
  func accentColor(nightMode: Bool) -> Color {
    nightMode ? NightMode.tint : accentColor
  }
}

/// The night mode switch as a settings card, for Appearance.
struct NightModeToggleCard: View {
  @AppStorage(AppStorageKey.nightMode.rawValue) private var nightMode = false

  var body: some View {
    ToggleCard(
      L10n.Settings.Appearance.nightMode,
      systemImage: "moon.fill",
      color: .red,
      subtitle: L10n.Settings.Appearance.nightModeSubtitle,
      isOn: $nightMode
    )
  }
}

/// The night mode switch as a toolbar button, for Home: one tap in the dark, no menus.
struct NightModeToolbarButton: View {
  @AppStorage(AppStorageKey.nightMode.rawValue) private var nightMode = false

  var body: some View {
    Button {
      nightMode.toggle()
    } label: {
      Label(L10n.Settings.Appearance.nightMode, systemImage: nightMode ? "moon.fill" : "moon")
        .labelStyle(.iconOnly)
    }
    .help(L10n.Settings.Appearance.nightMode)
    .accessibilityValue(nightMode ? L10n.Localizable.Accessibility.on : L10n.Localizable.Accessibility.off)
    .accessibilityIdentifier("home.nightMode")
    .sensoryFeedback(.selection, trigger: nightMode)
  }
}

/// Lays the night filter over this view's window while `isOn`.
private struct NightModeFilterModifier: ViewModifier {
  let isOn: Bool

  func body(content: Content) -> some View {
    content
      .background {
        NightModeSceneHook(isOn: isOn)
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
      }
  }
}

extension View {
  /// Applies night mode to this view's window; see `NightMode`.
  func nightModeFilter(_ isOn: Bool) -> some View {
    modifier(NightModeFilterModifier(isOn: isOn))
  }
}

/// Finds the window the view lives in and shows or hides that window's filter.
private struct NightModeSceneHook: UIViewRepresentable {
  let isOn: Bool

  func makeUIView(context _: Context) -> SceneProbeView {
    SceneProbeView()
  }

  func updateUIView(_ view: SceneProbeView, context _: Context) {
    view.isNightModeOn = isOn
  }
}

private final class SceneProbeView: UIView {
  var isNightModeOn = false {
    didSet { apply() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    apply()
  }

  private func apply() {
    guard let window else { return }
    NightModeFilter.set(isNightModeOn, in: window)
  }
}

/// The filter: two views laid over everything in the app's window: a grey in "saturation" mode
/// takes the colour out of whatever is beneath, then `NightMode.red` in "multiply" mode tints
/// that grey red at its own brightness. They sit directly in the window they filter (a blend
/// can't reach across windows, nor out of a container), and keep themselves its topmost views as
/// sheets and alerts are presented over them. Touches pass through.
@MainActor
private final class NightModeFilter: NSObject {
  private static var filters: [ObjectIdentifier: NightModeFilter] = [:]

  /// Bottom to top: colour out, then red in.
  private let layers: [UIView] = [
    PassthroughView(color: .gray, compositingFilter: "saturationBlendMode"),
    PassthroughView(color: NightMode.red, compositingFilter: "multiplyBlendMode"),
  ]
  private var keepOnTop: CADisplayLink?

  static func set(_ isOn: Bool, in window: UIWindow) {
    let key = ObjectIdentifier(window)
    if isOn {
      let filter = filters[key] ?? NightModeFilter()
      filters[key] = filter
      filter.attach(to: window)
    } else {
      filters[key]?.detach()
      filters[key] = nil
    }
  }

  private func attach(to window: UIWindow) {
    for layer in layers {
      layer.frame = window.bounds
      window.addSubview(layer)
    }
    // A presented sheet or alert is added to the window above these; a few checks a second lift
    // the filter back over it before it is noticed.
    if keepOnTop == nil {
      let link = CADisplayLink(target: self, selector: #selector(raise))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 8)
      link.add(to: .main, forMode: .common)
      keepOnTop = link
    }
  }

  private func detach() {
    keepOnTop?.invalidate()
    keepOnTop = nil
    layers.forEach { $0.removeFromSuperview() }
  }

  @objc private func raise() {
    guard let window = layers.last?.superview,
          window.subviews.suffix(layers.count).elementsEqual(layers, by: ===) == false else { return }
    layers.forEach { window.bringSubviewToFront($0) }
  }
}

/// One of the filter's layers: a flat colour blended with what's beneath, never taking a touch.
private final class PassthroughView: UIView {
  init(color: UIColor, compositingFilter: String) {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    backgroundColor = color
    layer.compositingFilter = compositingFilter
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    accessibilityElementsHidden = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func hitTest(_: CGPoint, with _: UIEvent?) -> UIView? {
    nil
  }
}
