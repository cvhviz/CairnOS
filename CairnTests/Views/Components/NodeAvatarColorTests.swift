import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import SwiftUI
import Testing
import UIKit

/// Picked avatar colours: every swatch stays legible, Automatic keeps today's colours, a photo
/// sends the colour to the name, names resolve to a contact's colour only when unambiguous, and
/// the chat bake and map pins carry the colour.
@Suite("Node avatar colours")
@MainActor
struct NodeAvatarColorTests {
  private static let traits: [(name: String, scheme: ColorScheme, contrast: ColorSchemeContrast, collection: UITraitCollection)] = [
    ("light", .light, .standard, Theme.traitCollection(colorScheme: .light, contrast: .standard)),
    ("dark", .dark, .standard, Theme.traitCollection(colorScheme: .dark, contrast: .standard)),
    ("light+highContrast", .light, .increased, Theme.traitCollection(colorScheme: .light, contrast: .increased)),
    ("dark+highContrast", .dark, .increased, Theme.traitCollection(colorScheme: .dark, contrast: .increased)),
  ]

  private static func luminance(of color: Color, _ collection: UITraitCollection) -> Double {
    WCAGContrast.relativeLuminance(of: UIColor(color).resolvedColor(with: collection))
  }

  /// Every pick that tints a name: the hue swatches, the type colours, and custom colours from
  /// very light to very dark.
  private static let namedPicks: [NodeAvatarColor] = NodeAvatarColor.hues
    + AvatarCategory.allCases.map(NodeAvatarColor.category)
    + [0xFFFFFF, 0xFFFF66, 0x777777, 0x1E3A8A, 0x000000].map { NodeAvatarColor.custom(rgb: $0) }

  private static func components(_ color: Color, _ collection: UITraitCollection) -> [CGFloat] {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    UIColor(color).resolvedColor(with: collection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue].map { ($0 * 1000).rounded() / 1000 }
  }

  private func contact(
    name: String,
    nickname: String? = nil,
    type: ContactType = .chat,
    key: UInt8,
    photo: Data? = nil,
    color: NodeAvatarColor? = nil
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(),
      radioID: UUID(),
      publicKey: Data(repeating: key, count: 32),
      name: name,
      typeRawValue: type.rawValue,
      flags: 0,
      outPathLength: 0,
      outPath: Data(),
      lastAdvertTimestamp: 0,
      latitude: 0,
      longitude: 0,
      lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nickname,
      isBlocked: false,
      isMuted: false,
      isFavorite: false,
      lastMessageDate: nil,
      unreadCount: 0,
      avatarImageData: photo,
      avatarColorRaw: color?.rawValue
    )
  }

  // MARK: - Legibility

  @Test
  func `every swatch clears AA against the canvas and the incoming bubble in every appearance`() {
    let theme = Theme.default
    for trait in Self.traits {
      let floor = trait.contrast == .increased ? WCAGContrast.increasedContrastFloor : WCAGContrast.aaFloor
      let surfaces = [Color(.systemBackground), theme.incomingBubbleColor].map { Self.luminance(of: $0, trait.collection) }
      for swatch in Self.namedPicks {
        let color = theme.swatchColor(swatch, colorScheme: trait.scheme, contrast: trait.contrast)
        let colorLuminance = Self.luminance(of: color, trait.collection)
        for surface in surfaces {
          let ratio = WCAGContrast.contrastRatio(colorLuminance, surface)
          #expect(ratio >= floor, "\(swatch) vs surface \(surface) in \(trait.name) is \(ratio)")
        }
      }
    }
  }

  @Test
  func `the glyph on a hue swatch clears AA, and on a custom fill the graphics floor`() {
    let theme = Theme.default
    for trait in Self.traits {
      for swatch in Self.namedPicks {
        // A type colour carries a white glyph, as on Automatic (covered below).
        if case .category = swatch { continue }
        let fill = theme.swatchFill(swatch, colorScheme: trait.scheme, contrast: trait.contrast)
        let fillLuminance = Self.luminance(of: fill, trait.collection)
        let glyph = IdentityGamut.glyphColor(forFillLuminance: fillLuminance)
        let ratio = WCAGContrast.contrastRatio(Self.luminance(of: glyph, trait.collection), fillLuminance)
        // A custom fill is any colour, and on a mid-tone neither glyph reaches AA; the glyph is a
        // graphic, so 3:1 is its floor there.
        let floor = swatch.hueDegrees == nil ? 3 : WCAGContrast.aaFloor
        #expect(ratio >= floor, "\(swatch) glyph in \(trait.name) is \(ratio)")
      }
    }
  }

  @Test
  func `swatches keep their own hue and stay distinct`() {
    #expect(Set(NodeAvatarColor.pickerSwatches).count == 12)
    let gamut = Theme.default.identityGamut
    var seen: [[CGFloat]] = []
    for swatch in NodeAvatarColor.hues {
      let resolved = gamut.resolve(swatch: swatch, backgroundLuminances: [1.0], highContrast: false)
      #expect(resolved.hue == swatch.hueDegrees)
      let rgb = Self.components(Theme.default.swatchColor(swatch, colorScheme: .light, contrast: .standard), Self.traits[0].collection)
      #expect(!seen.contains(rgb), "\(swatch) duplicates another swatch")
      seen.append(rgb)
    }
  }

  @Test
  func `raw values are stable`() {
    #expect(NodeAvatarColor(rawValue: "teal") == .teal)
    #expect(NodeAvatarColor.hues.map(\.rawValue) == ["red", "orange", "amber", "lime", "teal", "sky", "purple"])
    // Retired hues read back as the category colour that took their place.
    #expect(NodeAvatarColor(rawValue: "green") == .category(.companion))
    #expect(NodeAvatarColor(rawValue: "cyan") == .category(.channel))
    #expect(NodeAvatarColor(rawValue: "blue") == .category(.radio))
    #expect(NodeAvatarColor(rawValue: "indigo") == .category(.repeater))
    #expect(NodeAvatarColor(rawValue: "pink") == .category(.room))
    #expect(NodeAvatarColor.category(.repeater).rawValue == "type.repeater")
    #expect(NodeAvatarColor(rawValue: "type.room") == .category(.room))
    #expect(NodeAvatarColor.custom(rgb: 0x0A0B0C).rawValue == "rgb.0A0B0C")
    #expect(NodeAvatarColor(rawValue: "rgb.16a34a") == .custom(rgb: 0x16A34A))
    for bad in ["type.tower", "rgb.12345", "rgb.GGGGGG", "Teal", ""] {
      #expect(NodeAvatarColor(rawValue: bad) == nil, "\(bad)")
    }
  }

  @Test
  func `a colour survives a JSON round trip as its raw value`() throws {
    for color in [NodeAvatarColor.purple, .category(.channel), .custom(rgb: 0x123456)] {
      let data = try JSONEncoder().encode(color)
      #expect(String(decoding: data, as: UTF8.self) == "\"\(color.rawValue)\"")
      #expect(try JSONDecoder().decode(NodeAvatarColor.self, from: data) == color)
    }
  }

  // MARK: - Resolution

  @Test
  func `automatic fills every avatar with its category's colour`() {
    let theme = Theme.default
    let collection = Self.traits[0].collection
    for category in AvatarCategory.allCases {
      let fill = theme.avatarColor(nil, category: category, colorScheme: .light, contrast: .standard)
      #expect(Self.components(fill, collection) == Self.components(Color(hex: category.rgb), collection))
    }
  }

  @Test
  func `each category has its own colour, dark enough for a white glyph`() {
    #expect(Set(AvatarCategory.allCases.map(\.rgb)).count == AvatarCategory.allCases.count)
    #expect(AvatarCategory.companion.rgb == 0x16A34A)
    #expect(AvatarCategory.radio.rgb == 0x2463EB)
    let white = WCAGContrast.relativeLuminance(red: 1, green: 1, blue: 1)
    for category in AvatarCategory.allCases {
      let fill = Self.luminance(of: category.color, Self.traits[0].collection)
      // 3:1, the floor for graphics, which the glyph is.
      #expect(WCAGContrast.contrastRatio(white, fill) >= 3, "\(category)")
    }
  }

  @Test
  func `type and custom picks fill exactly, and a name moves only as far as it must`() {
    let theme = Theme.default
    let light = Self.traits[0]
    for swatch in [NodeAvatarColor.category(.room), .custom(rgb: 0xFFFF66)] {
      let fill = theme.swatchFill(swatch, colorScheme: .dark, contrast: .standard)
      #expect(Self.components(fill, light.collection) == Self.components(Color(hex: swatch.fixedRGB ?? -1), light.collection))
    }
    // Navy already reads on the light canvas, so the name keeps it; pale yellow does not, so the
    // name darkens it.
    let navy = theme.swatchColor(.custom(rgb: 0x1E3A8A), colorScheme: .light, contrast: .standard)
    #expect(Self.components(navy, light.collection) == Self.components(Color(hex: 0x1E3A8A), light.collection))
    let yellow = theme.swatchColor(.custom(rgb: 0xFFFF66), colorScheme: .light, contrast: .standard)
    #expect(Self.luminance(of: yellow, light.collection) < Self.luminance(of: Color(hex: 0xFFFF66), light.collection))
  }

  @Test
  func `a type colour's glyph is white, as on Automatic, and a custom one's adapts`() {
    let theme = Theme.default
    let room = theme.swatchFill(.category(.room), colorScheme: .light, contrast: .standard)
    #expect(theme.avatarGlyphColor(forFill: room, swatch: .category(.room), colorScheme: .light, contrast: .standard) == .white)
    let pale = theme.swatchFill(.custom(rgb: 0xFFFF66), colorScheme: .light, contrast: .standard)
    #expect(theme.avatarGlyphColor(forFill: pale, swatch: .custom(rgb: 0xFFFF66), colorScheme: .light, contrast: .standard) != .white)
  }

  @Test
  func `a picked swatch fills the avatar and tints the name, with or without a photo`() {
    let theme = Theme.default
    let collection = Self.traits[1].collection
    let swatch = theme.swatchColor(.purple, colorScheme: .dark, contrast: .standard)
    for category in [AvatarCategory.companion, .repeater, .room, .radio] {
      let fill = theme.avatarColor(.purple, category: category, colorScheme: .dark, contrast: .standard)
      #expect(Self.components(fill, collection) == Self.components(swatch, collection))
    }
    let name = theme.nameColor(.purple, colorScheme: .dark, contrast: .standard)
    #expect(Self.components(name, collection) == Self.components(swatch, collection))
  }

  @Test
  func `on Automatic a name wears its category's colour, as its avatar does`() {
    let theme = Theme.default
    let collection = Self.traits[0].collection
    for category in AvatarCategory.allCases {
      let name = theme.nameColor(nil, category: category, colorScheme: .light, contrast: .standard)
      let typeColor = theme.swatchColor(.category(category), colorScheme: .light, contrast: .standard)
      #expect(Self.components(name, collection) == Self.components(typeColor, collection))
    }
    // A sender name defaults to the companions' colour.
    let sender = theme.nameColor(nil, colorScheme: .light, contrast: .standard)
    let companion = theme.swatchColor(.category(.companion), colorScheme: .light, contrast: .standard)
    #expect(Self.components(sender, collection) == Self.components(companion, collection))
  }

  @Test
  func `names map to a contact's colour only when one contact holds them`() {
    let contacts = [
      contact(name: "Alice", key: 1, color: .teal),
      contact(name: "Bob", key: 2, color: .red),
      contact(name: "bob", key: 3),
      contact(name: "Carol", nickname: "Mum", key: 4, color: .purple),
      contact(name: "Hilltop", type: .repeater, key: 5, photo: Data("jpeg".utf8)),
      contact(name: "Dave", key: 6),
    ]
    let tables = NodeAppearanceIndex.tables(contacts: contacts, selfName: "My Radio", selfColor: .amber)
    #expect(tables.colorByLoweredName["alice"] == .teal)
    #expect(tables.colorByLoweredName["bob"] == nil, "two contacts share the name, so it stays Automatic")
    #expect(tables.colorByLoweredName["carol"] == .purple)
    #expect(tables.colorByLoweredName["mum"] == .purple)
    #expect(tables.colorByLoweredName["dave"] == nil)
    #expect(tables.colorByLoweredName["my radio"] == .amber)
    #expect(tables.colorByLoweredName["stranger"] == nil)

    #expect(tables.byPublicKey[Data(repeating: 1, count: 32)]?.color == .teal)
    #expect(tables.byPublicKey[Data(repeating: 5, count: 32)]?.photo == Data("jpeg".utf8))
    #expect(tables.byPublicKey[Data(repeating: 5, count: 32)]?.color == nil)
    #expect(tables.byPublicKey[Data(repeating: 6, count: 32)] == nil, "only picked avatars are indexed")
  }

  @Test
  func `this radio's name on Automatic wears the radio colour, as its avatar does`() {
    let tables = NodeAppearanceIndex.tables(contacts: [], selfName: "Basecamp", selfColor: nil)
    #expect(tables.colorByLoweredName["basecamp"] == .category(.radio))
  }

  @Test
  func `this radio's colour never overrides a contact with the same name`() {
    let tables = NodeAppearanceIndex.tables(
      contacts: [contact(name: "Base", key: 1)],
      selfName: "Base",
      selfColor: .sky
    )
    #expect(tables.colorByLoweredName["base"] == nil)
  }

  @Test
  func `a rebuild that changes nothing keeps the revision`() {
    let index = NodeAppearanceIndex()
    let contacts = [contact(name: "Alice", key: 1, color: .teal)]
    index.rebuild(contacts: contacts, selfName: nil, selfColor: nil)
    let revision = index.revision
    index.rebuild(contacts: contacts, selfName: nil, selfColor: nil)
    #expect(index.revision == revision)
    index.rebuild(contacts: [contact(name: "Alice", key: 1, color: .red)], selfName: nil, selfColor: nil)
    #expect(index.revision == revision + 1)
    #expect(index.color(forName: "ALICE") == .red)
  }

  @Test
  func `channel incoming avatars carry the sender's picked colour`() {
    let identities = MessageBubbleConfiguration.incomingAvatarIdentities(from: [
      contact(name: "Alice", key: 1, color: .lime),
      contact(name: "Bob", key: 2),
    ])
    #expect(identities["alice"]?.avatarColor == .lime)
    #expect(identities["bob"]?.avatarColor == nil)
    let tables = ChatSenderTables(contacts: [], nicknamesByLoweredName: [:], incomingAvatars: identities)
    #expect(tables.avatarColorsByLoweredName == ["alice": .lime])
  }

  @Test
  func `a picked colour tints mentions of that name`() {
    let theme = Theme.default
    let luminances = theme.avatarSurfaceLuminances(colorScheme: .light, contrast: .standard)
    let build = { (colors: [String: NodeAvatarColor]) in
      MessageText.buildFormattedText(
        text: "hi @[Alice]",
        isOutgoing: false,
        isHighContrast: false,
        outgoingTextColor: theme.outgoingTextColor,
        hashtagColor: theme.hashtagColor,
        identityGamut: theme.identityGamut,
        identityBackgroundLuminances: luminances,
        mentionColors: colors
      ).text
    }
    let automatic = build([:])
    let picked = build(["alice": .amber])
    #expect(automatic != picked)
    let expected = theme.identityGamut.color(for: .amber, backgroundLuminances: luminances, highContrast: false)
    let mentionRun = picked.runs.first { String(picked[$0.range].characters) == "@Alice" }
    #expect(mentionRun?.foregroundColor == expected)
  }

  // MARK: - Map pins

  private func point(_ style: MapPoint.PinStyle, avatar: MapPinAvatar?) -> MapPoint {
    MapPoint(
      id: UUID(),
      coordinate: CLLocationCoordinate2D(latitude: 45, longitude: -122),
      pinStyle: style,
      label: nil,
      isClusterable: false,
      hopIndex: nil,
      badgeText: nil,
      avatar: avatar
    )
  }

  @Test
  func `pin sprites change with a picked colour or photo for every node kind`() {
    let light = MapAvatarAppearance.standard(isDark: false)
    let name = { (point: MapPoint) in PinSpriteRenderer.spriteName(for: point, appearance: light) }
    for style in [MapPoint.PinStyle.contactChat, .contactRepeater, .contactRoom] {
      let automatic = name(point(style, avatar: MapPinAvatar(name: "Node")))
      let teal = name(point(style, avatar: MapPinAvatar(name: "Node", color: .teal)))
      let red = name(point(style, avatar: MapPinAvatar(name: "Node", color: .red)))
      let photo = name(point(style, avatar: MapPinAvatar(name: "Node", photo: Data("jpeg".utf8))))
      #expect(automatic != teal)
      #expect(teal != red)
      if style == .contactRepeater && RepeaterMastSprite.isEnabled {
        // A repeater stands as a mast, which takes the picked colour but has no head for a photo.
        // With masts off it falls back to the avatar pin, which shows the photo like any node.
        #expect(photo == automatic)
      } else {
        #expect(photo != automatic, "\(style) pin ignores its photo")
      }
    }
  }

  @Test
  func `a pin's label dot follows the picked colour even under a photo`() throws {
    let light = MapAvatarAppearance.standard(isDark: false)
    let avatar = MapPinAvatar(name: "Hilltop", photo: Data("jpeg".utf8), color: .orange)
    let sprite = try #require(PinAvatarSprite(point: point(.contactRepeater, avatar: avatar), appearance: light))
    let expected = UIColor(Theme.default.swatchColor(.orange, colorScheme: .light, contrast: .standard))
      .resolvedColor(with: Self.traits[0].collection)
    #expect(sprite.colors().fill == expected)
    #expect(sprite.photo != nil)
  }

  @Test
  func `map pin avatars compare by colour`() {
    #expect(MapPinAvatar(name: "A", color: .red) != MapPinAvatar(name: "A", color: .sky))
    #expect(MapPinAvatar(name: "A") == MapPinAvatar(name: "A", color: nil))
    let alice = contact(name: "Alice", key: 1, color: .sky)
    #expect(MapPinAvatar(contact: alice).color == .sky)
  }

  // MARK: - This radio

  @Test
  func `this radio's photo and colour persist per radio and survive a new store`() throws {
    let suite = "NodeAvatarColorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let radioA = UUID()
    let radioB = UUID()
    let store = RadioAvatarStore(defaults: defaults, directory: directory)
    store.setPhoto(Data("jpeg-a".utf8), for: radioA)
    store.setColor(.category(.repeater), for: radioA)
    store.setColor(.custom(rgb: 0x336699), for: radioB)

    let reopened = RadioAvatarStore(defaults: defaults, directory: directory)
    #expect(reopened.photo(for: radioA) == Data("jpeg-a".utf8))
    #expect(reopened.color(for: radioA) == .category(.repeater))
    #expect(reopened.photo(for: radioB) == nil)
    #expect(reopened.color(for: radioB) == .custom(rgb: 0x336699))

    reopened.setPhoto(nil, for: radioA)
    reopened.setColor(nil, for: radioA)
    let cleared = RadioAvatarStore(defaults: defaults, directory: directory)
    #expect(cleared.photo(for: radioA) == nil)
    #expect(cleared.color(for: radioA) == nil)
    #expect(cleared.color(for: radioB) == .custom(rgb: 0x336699))
  }
}
