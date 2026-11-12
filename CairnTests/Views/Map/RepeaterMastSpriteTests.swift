import CoreLocation
@testable import Cairn
import Foundation
import SwiftUI
import Testing
import UIKit

@Suite("Repeater mast sprites", .enabled(if: RepeaterMastSprite.isEnabled, "masts are switched off"))
@MainActor
struct RepeaterMastSpriteTests {
  private let light = MapAvatarAppearance.standard(isDark: false)
  private let dark = MapAvatarAppearance.standard(isDark: true)

  private func point(_ style: MapPoint.PinStyle, hop: Int? = nil, avatar: MapPinAvatar? = nil) -> MapPoint {
    MapPoint(
      id: UUID(),
      coordinate: CLLocationCoordinate2D(latitude: 45, longitude: -122),
      pinStyle: style,
      label: nil,
      isClusterable: false,
      hopIndex: hop,
      badgeText: nil,
      avatar: avatar
    )
  }

  private func mast(
    _ style: MapPoint.PinStyle,
    hop: Int? = nil,
    avatar: MapPinAvatar? = nil,
    selected: Bool = false,
    appearance: MapAvatarAppearance? = nil
  ) -> RepeaterMastSprite? {
    RepeaterMastSprite(point: point(style, hop: hop, avatar: avatar), appearance: appearance ?? light, isSelected: selected)
  }

  // MARK: - State

  @Test
  func `every repeater style stands as a mast and nothing else does`() {
    let repeaters: [MapPoint.PinStyle] = [
      .contactRepeater, .repeater, .repeaterRingBlue, .repeaterRingGreen, .repeaterRingWhite, .repeaterHop,
      .discoveredRepeater,
    ]
    for style in repeaters {
      #expect(mast(style) != nil, "\(style) should be a mast")
    }
    let others: [MapPoint.PinStyle] = [
      .contactChat, .contactRoom, .discoveredChat, .discoveredRoom, .pointA, .pointB, .crosshair,
      .obstruction, .badge, .droppedPin, .locationFix, .locationFixLatest,
    ]
    for style in others {
      #expect(mast(style) == nil, "\(style) should keep its own pin")
    }
  }

  @Test
  func `rings light the beacon in their colour and plain repeaters stay dark`() {
    #expect(mast(.repeater)?.beacon == .idle)
    #expect(mast(.contactRepeater)?.beacon == .idle)
    #expect(mast(.discoveredRepeater)?.beacon == .idle)
    // The Traffic map's active repeaters, and LOS point B.
    #expect(mast(.repeaterRingGreen)?.beacon == .green)
    #expect(mast(.repeaterRingBlue)?.beacon == .blue)
    // In a traced path, the inspected repeater, a message's hops.
    #expect(mast(.repeaterRingWhite)?.beacon == .accent)
    #expect(mast(.repeaterHop)?.beacon == .accent)
  }

  @Test
  func `only heard repeaters are outlined, and they never take a picked colour`() {
    #expect(mast(.discoveredRepeater)?.isOutlined == true)
    #expect(mast(.contactRepeater)?.isOutlined == false)
    #expect(mast(.repeater)?.isOutlined == false)
    #expect(mast(.discoveredRepeater, avatar: MapPinAvatar(name: "Hill", color: .red))?.color == nil)
    #expect(mast(.contactRepeater, avatar: MapPinAvatar(name: "Hill", color: .red))?.color == .red)
  }

  @Test
  func `hop badges ride only on path masts and clamp`() {
    #expect(mast(.repeaterHop, hop: 3)?.hopIndex == 3)
    #expect(mast(.repeaterRingWhite, hop: 2)?.hopIndex == 2)
    #expect(mast(.repeaterHop, hop: 500)?.hopIndex == PinSpriteRenderer.maxHopBadge)
    #expect(mast(.repeaterHop, hop: 0)?.hopIndex == 1)
    #expect(mast(.repeater, hop: 4)?.hopIndex == nil)
    #expect(mast(.repeaterRingGreen, hop: 4)?.hopIndex == nil)
  }

  // MARK: - Sprite names

  @Test
  func `sprite names key every look and nothing else`() throws {
    let quiet = try #require(mast(.repeater)).spriteName
    #expect(quiet.hasPrefix(RepeaterMastSprite.namePrefix))
    // Names and photos don't change a mast, so a busy map shares one sprite.
    #expect(quiet == mast(.repeater, avatar: MapPinAvatar(name: "Hilltop"))?.spriteName)
    #expect(quiet == mast(.contactRepeater, avatar: MapPinAvatar(name: "Valley", photo: Data("jpeg".utf8)))?.spriteName)
    let looks = [
      quiet,
      mast(.repeaterRingGreen)?.spriteName,
      mast(.repeaterRingBlue)?.spriteName,
      mast(.repeaterRingWhite)?.spriteName,
      mast(.discoveredRepeater)?.spriteName,
      mast(.repeaterHop, hop: 2)?.spriteName,
      mast(.repeaterHop, hop: 3)?.spriteName,
      mast(.repeater, selected: true)?.spriteName,
      mast(.repeater, appearance: dark)?.spriteName,
      mast(.contactRepeater, avatar: MapPinAvatar(name: "Hill", color: .teal))?.spriteName,
    ]
    #expect(Set(looks).count == looks.count)
  }

  @Test
  func `unselected masts share one ground shadow, the selected one takes the accent`() throws {
    let quiet = try #require(mast(.repeater))
    #expect(quiet.groundSpriteName == RepeaterMastSprite.groundPrefix)
    #expect(mast(.repeaterRingGreen, appearance: dark)?.groundSpriteName == quiet.groundSpriteName)
    let selected = try #require(mast(.repeater, selected: true))
    #expect(selected.groundSpriteName != quiet.groundSpriteName)
    #expect(selected.groundSpriteName.hasPrefix(RepeaterMastSprite.groundPrefix))
    #expect(mast(.repeater, selected: true, appearance: dark)?.groundSpriteName != selected.groundSpriteName)
  }

  @Test
  func `the renderer routes repeaters to masts and their shadows`() {
    let repeater = point(.repeaterRingGreen)
    let name = PinSpriteRenderer.spriteName(for: repeater, appearance: light)
    #expect(name.hasPrefix(RepeaterMastSprite.namePrefix))
    #expect(PinSpriteRenderer.spriteName(for: repeater, appearance: light, isSelected: true) != name)
    #expect(PinSpriteRenderer.groundSpriteName(for: repeater, appearance: light) == RepeaterMastSprite.groundPrefix)
    #expect(PinSpriteRenderer.groundSpriteName(for: point(.contactChat), appearance: light) == nil)
    #expect(PinSpriteRenderer.groundSpriteName(for: point(.pointA), appearance: light) == nil)
    // A companion keeps its avatar pin.
    #expect(PinSpriteRenderer.spriteName(for: point(.contactChat), appearance: light).hasPrefix(PinAvatarSprite.namePrefix))
  }

  @Test
  func `mast and ground sprites resolve by name and are retained and prunable`() throws {
    let repeater = point(.repeaterHop, hop: 4)
    let name = PinSpriteRenderer.spriteName(for: repeater, appearance: light, isSelected: true)
    let ground = try #require(PinSpriteRenderer.groundSpriteName(for: repeater, appearance: light, isSelected: true))
    let image = try #require(PinSpriteRenderer.image(named: name))
    // The renderer rounds to whole pixels.
    #expect(abs(image.size.width - RepeaterMastSprite.hopWidth * RepeaterMastSprite.displayScale * RepeaterMastSprite.selectedScale) < 0.5)
    #expect(abs(image.size.height - RepeaterMastSprite.height * RepeaterMastSprite.displayScale * RepeaterMastSprite.selectedScale) < 0.5)
    let groundImage = try #require(PinSpriteRenderer.image(named: ground))
    let groundSide = RepeaterMastSprite.groundSize * RepeaterMastSprite.displayScale
    #expect(abs(groundImage.size.width - groundSide) < 0.5 && abs(groundImage.size.height - groundSide) < 0.5)
    for sprite in [name, ground] {
      #expect(PinSpriteRenderer.shouldRetainStyleImage(sprite))
      #expect(PinSpriteRenderer.isPerPinSprite(sprite))
    }
    #expect(!PinSpriteRenderer.isPerPinSprite("pin-dropped"))
    #expect(PinSpriteRenderer.image(named: RepeaterMastSprite.namePrefix + "unknown") == nil)
  }

  // MARK: - Geometry

  @Test
  func `sizes grow for a hop badge and for selection`() throws {
    let plain = try #require(mast(.repeater))
    let shown = RepeaterMastSprite.displayScale
    #expect(plain.size == CGSize(width: RepeaterMastSprite.width * shown, height: RepeaterMastSprite.height * shown))
    #expect(try #require(mast(.repeaterHop, hop: 2)).size.width > plain.size.width)
    #expect(try #require(mast(.repeaterHop, hop: 2)).size.height == plain.size.height)
    let selected = try #require(mast(.repeater, selected: true))
    #expect(selected.size.height == RepeaterMastSprite.height * shown * RepeaterMastSprite.selectedScale)
  }

  @Test
  func `callouts over a repeater point at the top of its selected mast`() {
    for style: MapPoint.PinStyle in [.repeater, .contactRepeater, .discoveredRepeater, .repeaterRingGreen, .repeaterHop] {
      #expect(PinSpriteRenderer.calloutLift(for: style) == RepeaterMastSprite.calloutLift)
    }
    #expect(RepeaterMastSprite.calloutLift == RepeaterMastSprite.height * RepeaterMastSprite.displayScale * RepeaterMastSprite.selectedScale)
    #expect(PinSpriteRenderer.calloutLift(for: .contactChat) == PinSpriteRenderer.standardHeight)
  }

  @Test
  func `only quiet saved repeaters carry the flashing red light`() {
    #expect(mast(.repeater)?.warningLightSpriteName == RepeaterMastSprite.warningLightName(selected: false))
    #expect(mast(.contactRepeater)?.warningLightSpriteName == RepeaterMastSprite.warningLightName(selected: false))
    #expect(mast(.repeater, selected: true)?.warningLightSpriteName == RepeaterMastSprite.warningLightName(selected: true))
    #expect(mast(.discoveredRepeater)?.warningLightSpriteName == nil)
    for style: MapPoint.PinStyle in [.repeaterRingGreen, .repeaterRingBlue, .repeaterRingWhite, .repeaterHop] {
      #expect(mast(style, hop: 1)?.warningLightSpriteName == nil, "\(style) has its own lit beacon")
    }
    #expect(PinSpriteRenderer.warningLightSpriteName(for: point(.contactChat), appearance: light) == nil)
    #expect(!PinSpriteRenderer.isPerPinSprite(RepeaterMastSprite.warningLightName(selected: false)))
  }

  @Test
  func `the red light lines up with its mast`() {
    for selected in [false, true] {
      let light = RepeaterMastSprite.renderWarningLight(selected: selected)
      let mastSize = mast(.repeater, selected: selected)?.size ?? .zero
      #expect(abs(light.size.width - mastSize.width) < 0.5 && abs(light.size.height - mastSize.height) < 0.5)
    }
  }

  // MARK: - Visual check

  /// Writes each state, light and dark, over map-like grounds (flat and as if tilted) to the
  /// directory in `CAIRN_PIN_SHOTS_DIR` for a look. Skipped when it isn't set.
  @Test
  func `renders a contact sheet of every mast state`() throws {
    guard let directory = ProcessInfo.processInfo.environment["CAIRN_PIN_SHOTS_DIR"] else { return }
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let states: [(String, MapPoint.PinStyle, Int?, Bool, MapPinAvatar?)] = [
      ("active", .repeaterRingGreen, nil, false, nil),
      ("quiet", .repeater, nil, false, nil),
      ("selected", .repeaterRingGreen, nil, true, nil),
      ("saved", .contactRepeater, nil, false, nil),
      ("heard", .discoveredRepeater, nil, false, nil),
      ("los-a", .repeaterRingBlue, nil, false, nil),
      ("path-hop", .repeaterHop, 3, false, nil),
      ("picked-colour", .contactRepeater, nil, false, MapPinAvatar(name: "Hill", color: .orange)),
    ]
    let grounds: [(String, MapAvatarAppearance, UIColor)] = [
      ("light", light, UIColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1)),
      ("dark", dark, UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)),
      ("satellite", light, UIColor(red: 0.33, green: 0.38, blue: 0.27, alpha: 1)),
    ]
    let cell = CGSize(width: 88, height: 96)
    for (groundName, appearance, background) in grounds {
      for tilted in [false, true] {
        let sheetSize = CGSize(width: cell.width * CGFloat(states.count), height: cell.height)
        let sheet = UIGraphicsImageRenderer(size: sheetSize, format: Self.format).image { ctx in
          background.setFill()
          ctx.fill(CGRect(origin: .zero, size: sheetSize))
          Self.drawMapTexture(in: ctx.cgContext, size: sheetSize, isDark: appearance.colorScheme == .dark)
          for (index, state) in states.enumerated() {
            let point = point(state.1, hop: state.2, avatar: state.4)
            let base = CGPoint(x: (CGFloat(index) + 0.5) * cell.width, y: cell.height - 22)
            Self.drawPin(point, at: base, appearance: appearance, selected: state.3, tilted: tilted, opacity: state.0 == "quiet" ? 0.55 : 1)
          }
        }
        let name = "masts-\(groundName)\(tilted ? "-tilted" : "").png"
        try sheet.pngData()?.write(to: folder.appendingPathComponent(name))
      }
      // One file per state, at 3x, for showing around.
      for state in states {
        let size = CGSize(width: 72, height: 80)
        let image = UIGraphicsImageRenderer(size: size, format: Self.format).image { ctx in
          background.setFill()
          ctx.fill(CGRect(origin: .zero, size: size))
          Self.drawPin(
            point(state.1, hop: state.2, avatar: state.4),
            at: CGPoint(x: size.width / 2, y: size.height - 20),
            appearance: appearance,
            selected: state.3,
            tilted: true,
            opacity: state.0 == "quiet" ? 0.55 : 1
          )
        }
        try image.pngData()?.write(to: folder.appendingPathComponent("mast-\(state.0)-\(groundName).png"))
      }
    }
  }

  private static let format: UIGraphicsImageRendererFormat = {
    let format = UIGraphicsImageRendererFormat.preferred()
    format.scale = 3
    return format
  }()

  /// The ground shadow then the mast, as the map layers stack them. `tilted` squashes the ground
  /// as a map pitched 55 degrees does, while the mast stays upright.
  private static func drawPin(
    _ point: MapPoint,
    at base: CGPoint,
    appearance: MapAvatarAppearance,
    selected: Bool,
    tilted: Bool,
    opacity: CGFloat
  ) {
    let mastName = PinSpriteRenderer.spriteName(for: point, appearance: appearance, isSelected: selected)
    guard let groundName = PinSpriteRenderer.groundSpriteName(for: point, appearance: appearance, isSelected: selected),
          let ground = PinSpriteRenderer.image(named: groundName),
          let mast = PinSpriteRenderer.image(named: mastName) else { return }
    let squash: CGFloat = tilted ? cos(55 * .pi / 180) : 1
    ground.draw(
      in: CGRect(
        x: base.x - ground.size.width / 2,
        y: base.y - ground.size.height * squash / 2,
        width: ground.size.width,
        height: ground.size.height * squash
      ),
      blendMode: .normal,
      alpha: opacity
    )
    mast.draw(
      in: CGRect(x: base.x - mast.size.width / 2, y: base.y - mast.size.height, width: mast.size.width, height: mast.size.height),
      blendMode: .normal,
      alpha: opacity
    )
  }

  /// A few road-like strokes, so the casing and shadow are judged against something busier than
  /// a flat fill.
  private static func drawMapTexture(in cg: CGContext, size: CGSize, isDark: Bool) {
    cg.setStrokeColor((isDark ? UIColor(white: 0.24, alpha: 1) : UIColor.white).cgColor)
    cg.setLineWidth(5)
    cg.move(to: CGPoint(x: 0, y: size.height * 0.62))
    cg.addLine(to: CGPoint(x: size.width, y: size.height * 0.38))
    cg.strokePath()
    cg.setStrokeColor((isDark ? UIColor(white: 0.2, alpha: 1) : UIColor(red: 0.98, green: 0.85, blue: 0.55, alpha: 1)).cgColor)
    cg.setLineWidth(3)
    stride(from: CGFloat(30), to: size.width, by: 150).forEach { x in
      cg.move(to: CGPoint(x: x, y: 0))
      cg.addLine(to: CGPoint(x: x + 40, y: size.height))
    }
    cg.strokePath()
  }
}
