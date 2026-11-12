@testable import Cairn
import SwiftUI
import Testing

@Suite("Theme structure")
struct ThemeStructureTests {
  @Test
  func `Default theme paints no background`() {
    #expect(Theme.default.backdrop == nil)
    #expect(!Theme.default.hasBackdrop)
    #expect(Theme.default.canvasColor == nil)
  }

  @Test
  func `with(backdrop:) adds the background and keeps the palette`() {
    var settings = AppBackground()
    settings.kind = .solid
    let backdrop = ResolvedBackdrop(settings: settings, image: nil)
    let theme = Theme.default.with(backdrop: backdrop)
    #expect(theme.hasBackdrop)
    #expect(theme.canvasColor != nil)
    #expect(theme.id == Theme.default.id)
    #expect(theme.accentColor == Theme.default.accentColor)
    #expect(theme.with(backdrop: nil) == Theme.default)
  }

  @Test
  func `Default theme defines a usable identity gamut`() {
    let gamut = Theme.default.identityGamut
    #expect(gamut.saturation.lowerBound >= 0 && gamut.saturation.upperBound <= 1)
    #expect(gamut.saturation.lowerBound < gamut.saturation.upperBound)
  }
}
