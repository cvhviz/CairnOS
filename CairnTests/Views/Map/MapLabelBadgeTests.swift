import Foundation
import MapLibre
@testable import Cairn
import Testing
import UIKit

@Suite("MapLabelBadge")
struct MapLabelBadgeTests {
  private let posix = Locale(identifier: "en_US_POSIX")

  private func point(
    _ style: MapPoint.PinStyle,
    label: String? = "Node",
    detail: String? = nil
  ) -> MapPoint {
    MapPoint(
      id: UUID(),
      coordinate: CLLocationCoordinate2D(latitude: 21.3, longitude: -157.8),
      pinStyle: style,
      label: label,
      isClusterable: true,
      hopIndex: nil,
      badgeText: nil,
      detail: detail
    )
  }

  // MARK: - Composition

  @Test
  func `a pin without a name has no badge`() {
    #expect(MapLabelBadge(point: point(.repeater, label: nil), isDark: false, fontSize: 12) == nil)
    #expect(MapLabelBadge(point: point(.repeater, label: "   "), isDark: false, fontSize: 12) == nil)
  }

  @Test
  func `badge carries the name, detail and type tint`() throws {
    let badge = try #require(MapLabelBadge(point: point(.contactRoom, label: " Hall ", detail: "5m"), isDark: true, fontSize: 13))
    #expect(badge.title == "Hall")
    #expect(badge.detail == "5m")
    #expect(badge.tint == .room)
    #expect(badge.isDark)
  }

  @Test
  func `blank detail is dropped`() {
    let badge = MapLabelBadge(title: "A", detail: "  ", tint: .chat, isDark: false, fontSize: 12)
    #expect(badge.detail == nil)
  }

  @Test
  func `long names are cut with an ellipsis`() {
    let long = String(repeating: "x", count: 40)
    let title = MapLabelBadge.truncated(long)
    #expect(title.count == MapLabelBadge.maxTitleLength)
    #expect(title.hasSuffix("…"))
    #expect(MapLabelBadge.truncated("Short") == "Short")
  }

  @Test
  func `tints follow the pin's node type`() {
    #expect(MapLabelBadge.tint(for: .contactChat) == .chat)
    #expect(MapLabelBadge.tint(for: .discoveredChat) == .chat)
    #expect(MapLabelBadge.tint(for: .repeaterRingGreen) == .repeater)
    #expect(MapLabelBadge.tint(for: .discoveredRoom) == .room)
    #expect(MapLabelBadge.tint(for: .pointA) == .none)
    #expect(MapLabelBadge.Tint.none.color == nil)
  }

  // MARK: - Sprite name

  @Test
  func `sprite name round-trips every field`() throws {
    let badge = MapLabelBadge(title: "Ridge | North", detail: "+7.5 dB", tint: .repeater, isDark: true, fontSize: 15)
    #expect(badge.spriteName.hasPrefix(PinSpriteRenderer.labelSpritePrefix))
    let decoded = try #require(MapLabelBadge(spriteName: badge.spriteName))
    #expect(decoded == badge)
  }

  @Test
  func `sprite names differ by theme, size, tint and detail`() {
    let base = MapLabelBadge(title: "A", detail: nil, tint: .chat, isDark: false, fontSize: 12)
    var dark = base
    dark.isDark = true
    var larger = base
    larger.fontSize = 14
    var tinted = base
    tinted.tint = .room
    var detailed = base
    detailed.detail = "3h"
    let names = Set([base, dark, larger, tinted, detailed].map(\.spriteName))
    #expect(names.count == 5)
  }

  @Test
  func `an avatar dot colour round-trips and replaces the type tint`() throws {
    let badge = MapLabelBadge(title: "Bob", detail: "5m", tint: .chat, isDark: false, fontSize: 12, dotRGB: 0x14B5A6)
    let decoded = try #require(MapLabelBadge(spriteName: badge.spriteName))
    #expect(decoded == badge)
    #expect(decoded.dotRGB == 0x14B5A6)
    var plain = badge
    plain.dotRGB = nil
    #expect(plain.spriteName != badge.spriteName)
  }

  @Test
  func `names outside the current format do not decode`() throws {
    #expect(MapLabelBadge(spriteName: "label-Alice") == nil)
    #expect(MapLabelBadge(spriteName: "label-") == nil)
    #expect(MapLabelBadge(spriteName: "pin-repeater") == nil)
  }

  // MARK: - Priority

  private func key(
    _ style: MapPoint.PinStyle,
    favorite: Bool = false,
    hop: Int? = nil,
    opacity: Double = 1,
    selected: Bool = false
  ) -> Double {
    MapLabelBadge.sortKey(pinStyle: style, isFavorite: favorite, hopIndex: hop, opacity: opacity, isSelected: selected)
  }

  @Test
  func `selected beats favorite beats heard beats contact beats discovered`() {
    let selected = key(.discoveredRepeater, selected: true)
    let favorite = key(.contactRepeater, favorite: true)
    let heard = key(.repeaterRingGreen)
    let contact = key(.contactChat)
    let discovered = key(.discoveredChat)
    #expect(selected < favorite)
    #expect(favorite < heard)
    #expect(heard < contact)
    #expect(contact < discovered)
  }

  @Test
  func `this radio's name beats every node's but not the selected pin or a tool anchor`() {
    let radio = MapLabelBadge.sortKey(
      pinStyle: .contactChat, isFavorite: true, hopIndex: nil, opacity: 1, isSelected: false, isThisRadio: true
    )
    #expect(radio < key(.contactChat, favorite: true))
    #expect(radio < key(.repeaterRingGreen, favorite: true))
    #expect(radio < key(.contactChat))
    #expect(key(.pointA) < radio)
    #expect(key(.droppedPin) < radio)
    #expect(key(.contactChat, selected: true) < radio)
  }

  @Test
  func `this radio's pin gets its name as a badge like any node's`() throws {
    let radio = MapPoint(
      id: MapCalloutSelection.thisRadioID,
      coordinate: CLLocationCoordinate2D(latitude: 21.3, longitude: -157.8),
      pinStyle: .contactChat,
      label: "CVH M9",
      isClusterable: false,
      hopIndex: nil,
      badgeText: nil,
      isFavorite: true,
      avatar: MapPinAvatar(name: "CVH M9", isRadio: true)
    )
    let badge = try #require(MapLabelBadge(point: radio, isDark: false, fontSize: 12))
    #expect(badge.title == "CVH M9")
    #expect(badge.tint == MapLabelBadge.tint(for: .contactChat))
  }

  @Test
  func `path hops keep their order and faded pins drop back`() {
    #expect(key(.repeaterHop, hop: 1) < key(.repeaterHop, hop: 2))
    #expect(key(.discoveredRepeater, opacity: 1) < key(.discoveredRepeater, opacity: 0.4))
    #expect(key(.contactChat, opacity: 0.2) < key(.discoveredChat))
  }

  @Test
  func `a pin's rank holds still while its age creeps, and equals split the same way every time`() {
    // a reload a minute later: the fade moved a little, the rank did not
    #expect(key(.discoveredChat, opacity: 0.93) == key(.discoveredChat, opacity: 0.91))
    let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-0000FFFFFFFF")!
    #expect(MapLabelBadge.tieBreak(for: a) == MapLabelBadge.tieBreak(for: a))
    #expect((0..<1).contains(MapLabelBadge.tieBreak(for: b)))
    let keyA = MapLabelBadge.sortKey(pinStyle: .contactRepeater, isFavorite: false, hopIndex: nil, opacity: 1,
                                     isSelected: false, tieBreak: MapLabelBadge.tieBreak(for: a))
    let keyB = MapLabelBadge.sortKey(pinStyle: .contactRepeater, isFavorite: false, hopIndex: nil, opacity: 1,
                                     isSelected: false, tieBreak: MapLabelBadge.tieBreak(for: b))
    #expect(keyA < keyB)
    // the split never reaches the next rank: a hop's order, or a contact over a discovered node
    #expect(keyB < key(.discoveredRepeater))
    #expect(MapLabelBadge.sortKey(pinStyle: .repeaterHop, isFavorite: false, hopIndex: 1, opacity: 1,
                                  isSelected: false, tieBreak: 0.999) < key(.repeaterHop, hop: 2))
  }

  // MARK: - Dynamic Type

  @Test
  func `badge text grows with Dynamic Type up to a cap`() {
    let small = MapLabelBadge.fontSize(for: .small)
    let large = MapLabelBadge.fontSize(for: .large)
    let huge = MapLabelBadge.fontSize(for: .accessibilityExtraExtraExtraLarge)
    #expect(large == MapLabelBadge.baseFontSize)
    #expect(small <= large)
    #expect(large < huge)
    #expect(huge == MapLabelBadge.maxFontSize)
  }

  // MARK: - Detail text

  @Test
  func `age detail uses the largest unit`() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(MapLabelBadge.ageDetail(lastHeard: nil, now: now) == nil)
    #expect(MapLabelBadge.ageDetail(lastHeard: now.addingTimeInterval(-5 * 60), now: now, locale: posix) == "5m")
    #expect(MapLabelBadge.ageDetail(lastHeard: now.addingTimeInterval(-3 * 3600 - 120), now: now, locale: posix) == "3h")
    #expect(MapLabelBadge.ageDetail(lastHeard: now.addingTimeInterval(-10), now: now, locale: posix) == "1m")
  }

  @Test
  func `snr detail is signed with one decimal`() {
    #expect(MapLabelBadge.snrDetail(7.5, locale: posix) == "+7.5 dB")
    #expect(MapLabelBadge.snrDetail(-12.25, locale: posix).hasPrefix("-12."))
  }

  // MARK: - Stats badges

  @Test
  func `stats badge of the selected trace outranks dimmed ones whatever their signal`() {
    let selectedWeak = MapLabelBadge.statsSortKey(opacity: 1, snr: -15)
    let dimmedStrong = MapLabelBadge.statsSortKey(opacity: 0.3, snr: 12)
    #expect(selectedWeak < dimmedStrong)
  }

  @Test
  func `among equal stats badges the stronger link wins`() {
    #expect(MapLabelBadge.statsSortKey(opacity: 1, snr: 10.5) < MapLabelBadge.statsSortKey(opacity: 1, snr: 4))
    #expect(MapLabelBadge.statsSortKey(opacity: 1, snr: -5) < MapLabelBadge.statsSortKey(opacity: 1, snr: nil))
    // Out-of-range readings still rank inside one opacity band.
    #expect(MapLabelBadge.statsSortKey(opacity: 1, snr: -500) < MapLabelBadge.statsSortKey(opacity: 0.9, snr: 500))
    #expect(MapLabelBadge.statsSortKey(opacity: 1, snr: .nan) == MapLabelBadge.statsSortKey(opacity: 1, snr: nil))
  }

  @Test
  func `snr badge carries its reading for ranking`() {
    let badge = MapLine.snrBadge(
      id: UUID(),
      from: CLLocationCoordinate2D(latitude: 21.3, longitude: -157.8),
      to: CLLocationCoordinate2D(latitude: 21.4, longitude: -157.9),
      snr: 6.25
    )
    #expect(badge.badgeSNR == 6.25)
    #expect(badge.badgeText != nil)
  }

  // MARK: - Rendering

  @Test
  @MainActor
  func `a detailed badge renders wider than a plain one`() {
    let plain = PinSpriteRenderer.renderBadgeCard(
      MapLabelBadge(title: "Ridge", detail: nil, tint: .repeater, isDark: false, fontSize: 12)
    )
    let detailed = PinSpriteRenderer.renderBadgeCard(
      MapLabelBadge(title: "Ridge", detail: "+7.5 dB", tint: .repeater, isDark: true, fontSize: 12)
    )
    #expect(plain.size.height > 12)
    #expect(detailed.size.width > plain.size.width)
  }
}

@Suite("MapBasemapLabels")
struct MapBasemapLabelsTests {
  @Test
  func `points of interest are faded, names are kept, our layers untouched`() {
    #expect(MapBasemapLabels.treatment(layerID: "poi_r1", sourceLayerID: "poi") == .pointOfInterest)
    #expect(MapBasemapLabels.treatment(layerID: "label_city", sourceLayerID: "place") == .name)
    #expect(MapBasemapLabels.treatment(layerID: "highway-name-major", sourceLayerID: "transportation_name") == .name)
    #expect(MapBasemapLabels.treatment(layerID: MapLayerID.nameLabels, sourceLayerID: nil) == .untouched)
    #expect(MapBasemapLabels.treatment(layerID: MapLayerID.fixedIcons, sourceLayerID: nil) == .untouched)
  }
}
