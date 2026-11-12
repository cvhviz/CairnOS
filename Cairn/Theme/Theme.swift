import CairnServices
import SwiftUI

/// The app's cosmetic environment: the brand colors (accent, chat text, hashtags), the identity
/// color space for avatars and sender names, and the user's page background.
///
/// There is one color palette (`Theme.default`). What the user customizes is the background
/// behind every page (`backdrop`): a solid color, a gradient or a photo, with cards and rows
/// drawn as glass over it. `nil` keeps the system look untouched.
struct Theme: Identifiable, Equatable {
  let id: String
  let accentColor: Color
  let outgoingTextColor: Color
  let hashtagColor: Color
  /// The theme's solver that keeps name colors (sender names, mentions) legible.
  let identityGamut: IdentityGamut
  /// The user's page background, ready to paint. `nil` means the system background.
  var backdrop: ResolvedBackdrop?

  init(
    id: String,
    accentColor: Color,
    outgoingTextColor: Color,
    hashtagColor: Color,
    identityGamut: IdentityGamut,
    backdrop: ResolvedBackdrop? = nil
  ) {
    self.id = id
    self.accentColor = accentColor
    self.outgoingTextColor = outgoingTextColor
    self.hashtagColor = hashtagColor
    self.identityGamut = identityGamut
    self.backdrop = backdrop
  }
}

extension Theme {
  /// True when pages paint the user's background and cards draw as glass over it.
  var hasBackdrop: Bool {
    backdrop != nil
  }

  /// A flat color standing in for the painted background, for UI that has to blend into the
  /// page with a single color (the compose-bar fade, reaction badge rims, iOS 18 opaque plates).
  /// `nil` with the system background, so callers keep their system color.
  var canvasColor: Color? {
    backdrop?.approximateColor
  }

  /// Incoming message bubble fill. Bubbles stay the system gray in every background, so their
  /// text contrast never depends on the photo or colors behind them.
  var incomingBubbleColor: Color {
    AppColors.Message.incomingBubble
  }

  /// This theme with the given background.
  func with(backdrop: ResolvedBackdrop?) -> Theme {
    var copy = self
    copy.backdrop = backdrop
    return copy
  }
}

extension Theme {
  static let `default` = Theme(
    id: EnvInputs.defaultThemeID,
    accentColor: Color("AppAccentColor"),
    outgoingTextColor: .white,
    hashtagColor: Color("HashtagDefault"),
    identityGamut: IdentityGamut(saturation: 0.45...0.70)
  )
}
