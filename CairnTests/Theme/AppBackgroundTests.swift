import Foundation
@testable import Cairn
import Testing

@Suite("AppBackground settings")
@MainActor
struct AppBackgroundTests {
  @Test
  func `defaults are the system background with a light dim and no blur`() {
    let background = AppBackground()
    #expect(background.kind == .system)
    #expect(background.dim == AppBackground.defaultDim)
    #expect(background.blur == 0)
    #expect(background.imageFileName == nil)
    #expect(AppBackground.gradientColorCount.contains(background.gradientColors.count))
  }

  @Test
  func `a fresh install starts on the Ocean mesh gradient, dimmed 65%`() {
    let background = AppBackground.decode(from: nil)
    #expect(background == .appDefault)
    #expect(background.kind == .gradient)
    #expect(background.gradientColors == GradientBackgroundPreset.ocean.colors)
    #expect(background.gradientStyle == .mesh)
    #expect(background.dim == 0.65)
  }

  @Test
  func `encodes and decodes every field`() {
    var background = AppBackground()
    background.kind = .gradient
    background.solidColor = BackgroundColor(hex: 0x123456)
    background.gradientColors = GradientBackgroundPreset.aurora.colors
    background.gradientStyle = .mesh
    background.gradientDirection = .leadingToTrailing
    background.dim = 0.45
    background.blur = 12
    let decoded = AppBackground.decode(from: background.encodedString)
    #expect(decoded == background)
  }

  @Test
  func `missing or unreadable stored value decodes as the app's default background`() {
    #expect(AppBackground.decode(from: nil) == .appDefault)
    #expect(AppBackground.decode(from: "") == .appDefault)
    #expect(AppBackground.decode(from: "not json") == .appDefault)
  }

  @Test
  func `partial JSON keeps defaults for absent fields`() {
    let decoded = AppBackground.decode(from: #"{"kind":"solid","dim":0.5}"#)
    #expect(decoded.kind == .solid)
    #expect(decoded.dim == 0.5)
    #expect(decoded.solidColor == AppBackground().solidColor)
  }

  @Test
  func `unknown enum values from a newer build fall back per field`() {
    let decoded = AppBackground.decode(from: #"{"kind":"video","gradientStyle":"conic","dim":0.3}"#)
    #expect(decoded.kind == .system)
    #expect(decoded.gradientStyle == AppBackground().gradientStyle)
    #expect(decoded.dim == 0.3)
  }

  @Test
  func `dim and blur clamp to their ranges`() {
    var background = AppBackground()
    background.dim = 2
    background.blur = -5
    var normalized = background.normalized()
    #expect(normalized.dim == AppBackground.dimRange.upperBound)
    #expect(normalized.blur == 0)

    background.dim = -1
    background.blur = 500
    normalized = background.normalized()
    #expect(normalized.dim == 0)
    #expect(normalized.blur == AppBackground.blurRange.upperBound)

    background.dim = .nan
    #expect(background.normalized().dim == AppBackground.defaultDim)
  }

  @Test
  func `decode clamps out-of-range values`() {
    let decoded = AppBackground.decode(from: #"{"dim":9,"blur":99}"#)
    #expect(decoded.dim == AppBackground.dimRange.upperBound)
    #expect(decoded.blur == AppBackground.blurRange.upperBound)
  }

  @Test
  func `gradient keeps two to three colors`() {
    var background = AppBackground()
    background.gradientColors = [BackgroundColor(hex: 0xFF0000)]
    #expect(background.normalized().gradientColors.count == 2)
    background.gradientColors = Array(repeating: BackgroundColor(hex: 0x00FF00), count: 5)
    #expect(background.normalized().gradientColors.count == 3)
  }

  @Test
  func `a photo background without a valid file name falls back to system`() {
    var background = AppBackground()
    background.kind = .image
    #expect(background.normalized().kind == .system)

    background.imageFileName = "../../etc/passwd"
    let normalized = background.normalized()
    #expect(normalized.imageFileName == nil)
    #expect(normalized.kind == .system)
  }

  @Test
  func `resolution falls back to system when the photo file is missing`() {
    var background = AppBackground()
    background.kind = .image
    background.imageFileName = "background-ABC.jpg"
    background.imageAverageColor = BackgroundColor(hex: 0x808080)

    let missing = ThemeService.resolvedBackground(background) { _ in false }
    #expect(missing.kind == .system)
    #expect(missing.imageFileName == nil)
    #expect(missing.imageAverageColor == nil)

    let present = ThemeService.resolvedBackground(background) { _ in true }
    #expect(present == background)
  }

  @Test
  func `color round-trips through SwiftUI Color`() {
    let original = BackgroundColor(hex: 0x3366CC)
    let roundTripped = BackgroundColor(original.color)
    #expect(abs(roundTripped.red - original.red) < 0.002)
    #expect(abs(roundTripped.green - original.green) < 0.002)
    #expect(abs(roundTripped.blue - original.blue) < 0.002)
  }

  @Test
  func `mesh colors spread two or three colors over the grid`() {
    let two = BackgroundGradientView.meshColors([.black, .white])
    #expect(two.count == 9)
    #expect(two.first == .black)
    #expect(two.last == .white)
    let three = BackgroundGradientView.meshColors([.black, BackgroundColor(hex: 0xFF0000), .white])
    #expect(three[4] == BackgroundColor(hex: 0xFF0000))
  }
}
