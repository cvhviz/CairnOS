import CoreLocation
@testable import Cairn
import SwiftUI
import Testing
import UIKit

@Suite("PinSpriteRenderer snapshot sprites")
@MainActor
struct PinSpriteRendererSnapshotTests {
  private let light = MapAvatarAppearance.standard(isDark: false)

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

  private func name(_ point: MapPoint, _ appearance: MapAvatarAppearance? = nil) -> String {
    PinSpriteRenderer.spriteName(for: point, appearance: appearance ?? light)
  }

  @Test
  func `hop-badged repeater snapshot is larger than the base repeater pin`() {
    let hop = PinSpriteRenderer.snapshotSprite(for: point(.repeaterHop, hop: 3), appearance: light, fallbackName: "")
    let base = PinSpriteRenderer.snapshotSprite(for: point(.repeater), appearance: light, fallbackName: "")
    #expect(hop.size.width > 1)
    #expect(hop.size.height > 1)
    #expect(hop.size != base.size)
  }

  @Test
  func `node pins keep the standard pin footprint`() {
    let pin = PinSpriteRenderer.snapshotSprite(
      for: point(.contactChat, avatar: MapPinAvatar(name: "Alice")),
      appearance: light,
      fallbackName: ""
    )
    #expect(pin.size == CGSize(width: 36, height: PinSpriteRenderer.standardHeight))
  }

  @Test
  func `a companion pin is keyed by its name and photo`() {
    let alice = name(point(.contactChat, avatar: MapPinAvatar(name: "Alice")))
    #expect(alice.hasPrefix(PinAvatarSprite.namePrefix))
    #expect(alice == name(point(.contactChat, avatar: MapPinAvatar(name: "Alice"))))
    #expect(alice != name(point(.contactChat, avatar: MapPinAvatar(name: "Bob"))))
    let photo = name(point(.contactChat, avatar: MapPinAvatar(name: "Alice", photo: Data("jpeg-1".utf8))))
    let newPhoto = name(point(.contactChat, avatar: MapPinAvatar(name: "Alice", photo: Data("jpeg-2".utf8))))
    #expect(photo != alice)
    #expect(photo != newPhoto)
  }

  @Test
  func `repeaters and rooms share their category avatar whatever the name`() {
    let mast = name(point(.repeater, avatar: MapPinAvatar(name: "Hilltop")))
    #expect(mast == name(point(.repeater, avatar: MapPinAvatar(name: "Valley"))))
    #expect(mast == name(point(.contactRepeater)))
    #expect(name(point(.contactRoom)) != mast)
  }

  @Test
  func `a companion with an empty name keeps its own avatar, as ContactAvatar does`() {
    // ContactAvatar(name: "") colours by the empty name's identity, so its pin does too rather
    // than taking the shared companion colour a pin with no avatar at all falls back to.
    let empty = name(point(.contactChat, avatar: MapPinAvatar(name: "")))
    #expect(empty == name(point(.contactChat, avatar: MapPinAvatar(name: ""))))
    #expect(empty != name(point(.contactChat)))
    #expect(empty != name(point(.contactChat, avatar: MapPinAvatar(name: "Alice"))))
  }

  @Test
  func `appearance changes give new sprite names`() {
    let alice = point(.contactChat, avatar: MapPinAvatar(name: "Alice"))
    let dark = MapAvatarAppearance.standard(isDark: true)
    let contrast = MapAvatarAppearance(theme: .default, colorScheme: .light, contrast: .increased)
    #expect(name(alice) != name(alice, dark))
    #expect(name(alice) != name(alice, contrast))
    #expect(name(point(.repeater)) != name(point(.repeater), dark))
  }

  @Test
  func `discovered pins are outlined and never show a photo`() {
    let photo = MapPinAvatar(name: "Alice", photo: Data("jpeg".utf8))
    let discovered = name(point(.discoveredChat, avatar: photo))
    #expect(discovered.contains("-outlined-"))
    #expect(discovered == name(point(.discoveredChat, avatar: MapPinAvatar(name: "Alice"))))
    #expect(discovered != name(point(.contactChat, avatar: MapPinAvatar(name: "Alice"))))
  }

  @Test
  func `repeater rings and hop badges keep their own sprites, hops clamped`() {
    if RepeaterMastSprite.isEnabled {
      #expect(name(point(.repeaterRingBlue)).hasPrefix(RepeaterMastSprite.namePrefix + "blue-"))
      #expect(name(point(.repeaterRingGreen)).hasPrefix(RepeaterMastSprite.namePrefix + "green-"))
      #expect(name(point(.repeaterRingWhite, hop: 2)).hasPrefix(RepeaterMastSprite.namePrefix + "accent-hop-2-"))
    } else {
      // Masts off: repeaters are avatar pins, rings drawn round the head.
      #expect(name(point(.repeaterRingBlue)).hasPrefix(PinAvatarSprite.namePrefix + "repeater-ring-blue-"))
      #expect(name(point(.repeaterRingGreen)).hasPrefix(PinAvatarSprite.namePrefix + "repeater-ring-green-"))
      #expect(name(point(.repeaterRingWhite, hop: 2)).contains("-ring-white-hop-2-"))
    }
    #expect(name(point(.repeaterHop, hop: 500)).contains("-hop-\(PinSpriteRenderer.maxHopBadge)-"))
    if RepeaterMastSprite.isEnabled {
      // A hop's mast is lit even without a number; an avatar pin without one is a plain repeater.
      #expect(name(point(.repeaterHop)) != name(point(.repeater)))
    }
  }

  @Test
  func `non-node pins keep their base sprites`() {
    #expect(name(point(.pointA)) == "pin-point-a")
    #expect(name(point(.pointB)) == "pin-point-b")
    #expect(name(point(.droppedPin)) == "pin-dropped")
    #expect(name(point(.locationFixLatest)) == "pin-location-latest")
    #expect(name(point(.crosshair)) == "pin-crosshair")
  }

  @Test
  func `avatar sprites resolve by name and are retained across source replaces`() throws {
    let photo = try #require(UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { ctx in
      UIColor.systemOrange.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    }.jpegData(compressionQuality: 0.8))
    let spriteName = name(point(.contactChat, avatar: MapPinAvatar(name: "Alice", photo: photo)))
    let image = try #require(PinSpriteRenderer.image(named: spriteName))
    #expect(image.size == CGSize(width: 36, height: PinSpriteRenderer.standardHeight))
    #expect(PinSpriteRenderer.shouldRetainStyleImage(spriteName))
    #expect(PinSpriteRenderer.image(named: PinAvatarSprite.namePrefix + "chat-unknown") == nil)
  }
}
