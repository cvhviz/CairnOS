import Foundation
import MeshCore
import UIKit
@testable import Cairn
import CairnServices
import SwiftUI
import Testing

@Suite("CarPlayCardBuilder")
struct CarPlayCardBuilderTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func readyInputs() -> CarPlayInputs {
    var inputs = CarPlayInputs()
    inputs.usesCards = true
    inputs.connectionState = .ready
    inputs.isRadioReady = true
    inputs.radio = .init(
      name: "Heltec",
      model: "Heltec V3 · v1.9.1",
      frequency: "910.525 MHz",
      presetName: "USA/Canada",
      txPower: "22 dBm",
      transportDetail: "Default PIN",
      gpsStatus: .fix,
      locationSharing: "Not sharing"
    )
    inputs.batteryPercent = 87
    inputs.batteryDetail = "4.01 V"
    inputs.contactCount = 42
    inputs.newNodeCount = 3
    inputs.unread = 5
    // The Nodes tab's Recently Heard group: the Dashboard's Heard count reads it.
    inputs.nodeCategories = [.init(
      list: .category(.recentlyHeard),
      title: L10n.Localizable.CarPlay.Nodes.recent,
      count: 8,
      symbol: CarPlayAvatar.recentSymbol,
      tint: CarPlayAvatar.tint(.recentlyHeard)
    )]
    inputs.live = .init(
      lastRSSI: -92,
      lastSNR: 7.5,
      noiseFloor: -110,
      packetsPerMinute: 12,
      positionText: "41.8823, -87.6232",
      altitudeText: "182 m",
      lastMessage: .init(sender: "Alice", channelName: "Public", preview: "On my way, see you at the trailhead", date: now.addingTimeInterval(-120))
    )
    return inputs
  }

  private func sections(_ inputs: CarPlayInputs) -> [CarPlaySnapshot.TileSection] {
    CarPlaySnapshotBuilder.make(from: inputs, now: now).dashboardTiles
  }

  private func row(_ id: String, in inputs: CarPlayInputs) -> CarPlaySnapshot.TileRow? {
    sections(inputs).flatMap(\.rows).first { $0.id == id }
  }

  private func tile(_ id: String, row rowID: String, in inputs: CarPlayInputs) -> CarPlaySnapshot.Tile? {
    row(rowID, in: inputs)?.tiles.first { $0.id == id }
  }

  // MARK: - Fallback

  @Test
  func `A car that draws rows gets no cards, and keeps its rows and information screens`() {
    var inputs = readyInputs()
    inputs.usesCards = false
    inputs.spectrum = .init()
    inputs.gps = .init(phoneStatus: "No fix", sharing: "")
    let snapshot = CarPlaySnapshotBuilder.make(from: inputs, now: now)
    #expect(snapshot.dashboardTiles.isEmpty)
    #expect(snapshot.spectrumTiles == nil)
    #expect(snapshot.gpsTiles == nil)
    #expect(snapshot.dashboard.cards.map(\.kind) == [.radio, .chats, .nodes, .mesh, .gps])
    #expect(snapshot.spectrum?.isEmpty == false)
    #expect(snapshot.gps?.isEmpty == false)
  }

  // MARK: - Dashboard

  private func card(_ id: String, in inputs: CarPlayInputs) -> CarPlaySnapshot.Tile? {
    tile(id, row: CarPlayCardBuilder.overviewRowID, in: inputs)
  }

  private func shortcut(_ id: String, in inputs: CarPlayInputs) -> CarPlaySnapshot.Tile? {
    tile(id, row: CarPlayCardBuilder.shortcutsRowID, in: inputs)
  }

  private func metric(_ id: String, of tile: CarPlaySnapshot.Tile?) -> CarPlaySnapshot.Metric? {
    tile?.panel?.metrics.first { $0.id == id }
  }

  @Test
  func `The Dashboard is one line of rich cards over condensed shortcuts and tools, paired two to a line`() {
    let sections = sections(readyInputs())
    #expect(sections.count == 1)
    #expect(sections[0].header == nil)
    #expect(sections[0].rows.map(\.id) == [CarPlayCardBuilder.overviewRowID, CarPlayCardBuilder.shortcutsRowID])
    #expect(sections[0].rows.map(\.style) == [.cards, .condensed])
    // No row titles: every line on the screen is cards.
    #expect(sections[0].rows.allSatisfy { $0.title == nil })
    #expect(sections[0].rows[0].tiles.map(\.id) == ["radio", "mesh", "messages", "location"])
    #expect(sections[0].rows[0].tiles.allSatisfy { $0.panel != nil })
    #expect(sections[0].rows[1].tiles.map(\.id) == ["traffic", "heard", "scan", "advert"])
  }

  @Test
  func `A starting app shows no cards; a radio never paired shows the radio and messages only`() {
    var starting = readyInputs()
    starting.isStarting = true
    #expect(sections(starting).isEmpty)

    var unpaired = CarPlayInputs()
    unpaired.usesCards = true
    unpaired.radioTools = false
    #expect(sections(unpaired).first?.rows.map(\.id) == [CarPlayCardBuilder.overviewRowID])
    #expect(sections(unpaired).first?.rows.first?.tiles.map(\.id) == ["radio", "messages"])
    #expect(card("radio", in: unpaired)?.subtitle == L10n.Localizable.CarPlay.Home.noRadioPaired)
    #expect(card("radio", in: unpaired)?.panel == nil)
  }

  @Test
  func `The radio card names the radio and its link, and pictures transport, battery and model`() {
    let radio = card("radio", in: readyInputs())
    #expect(radio?.title == "Heltec")
    #expect(radio?.subtitle == NodeRouteFormat.joined([L10n.Settings.BleStatus.Status.ready, BatteryLevel.formattedPercent(87)]))
    #expect(radio?.panel?.heading == L10n.Localizable.CarPlay.Cards.radio)
    #expect(radio?.panel?.status == .success)
    #expect(radio?.panel?.metrics.map(\.id) == ["transport", "battery", "model"])
    #expect(metric("transport", of: radio)?.value == HomeStatusLines.transportName(isWiFi: false))
    #expect(metric("model", of: radio)?.value == "Heltec V3 · v1.9.1")
    let battery = metric("battery", of: radio)
    #expect(battery?.value == BatteryLevel.formattedPercent(87))
    #expect(battery?.caption == "4.01 V")
    #expect(battery?.gauge == .meter(0.87, .success))
    if case let .info(title, rows) = radio?.action {
      #expect(title == "Heltec")
      #expect(rows.contains { $0.title == L10n.Settings.DeviceInfo.battery })
    } else {
      Issue.record("The radio card should open its lines")
    }
  }

  @Test
  func `The battery is green, orange or red by charge, with no bar without a reading`() {
    var inputs = readyInputs()
    #expect(metric("battery", of: card("radio", in: inputs))?.valueTint == .success)
    inputs.batteryPercent = 15
    #expect(metric("battery", of: card("radio", in: inputs))?.gauge == .meter(0.15, .warning))
    inputs.batteryPercent = 5
    #expect(metric("battery", of: card("radio", in: inputs))?.valueTint == .critical)
    inputs.batteryPercent = nil
    #expect(metric("battery", of: card("radio", in: inputs))?.gauge == nil)
    #expect(metric("battery", of: card("radio", in: inputs))?.valueTint == nil)
  }

  @Test
  func `A link that isn't up keeps the radio's colour and shows in the status dot`() {
    var inputs = readyInputs()
    inputs.connectionState = .syncing
    inputs.isRadioReady = false
    let radio = card("radio", in: inputs)
    #expect(radio?.tint == .avatar(.radio))
    #expect(radio?.panel?.status == .warning)
    #expect(radio?.subtitle?.hasPrefix(L10n.Settings.BleStatus.Status.syncing) == true)
  }

  @Test
  func `The mesh card pictures the Live Activity's readings, coloured by signal, and opens Spectrum`() {
    let mesh = card("mesh", in: readyInputs())
    #expect(mesh?.panel?.metrics.map(\.id) == ["signal", "noise", "traffic", "heard", "nodes"])
    #expect(mesh?.title == CarPlayCardBuilder.signalText(rssi: -92, snr: 7.5))
    #expect(mesh?.subtitle == NodeRouteFormat.joined([
      L10n.Localizable.CarPlay.Cards.perMinute(12),
      L10n.Localizable.CarPlay.Cards.heardCount(8),
    ]))
    #expect(mesh?.tint == .color(SNRQuality.excellent.color))
    let signal = metric("signal", of: mesh)
    #expect(signal?.value == L10n.Tools.Tools.Spectrum.Value.dbm("-92"))
    #expect(signal?.caption == L10n.Localizable.CarPlay.Cards.decibels(7.5.formatted(.number.precision(.fractionLength(1)))))
    #expect(signal?.gauge == .bars(SNRQuality.excellent.barLevel, .color(SNRQuality.excellent.color)))
    #expect(metric("noise", of: mesh)?.value == L10n.Tools.Tools.Spectrum.Value.dbm("-110"))
    #expect(metric("nodes", of: mesh)?.value == "42")
    #expect(metric("nodes", of: mesh)?.caption == L10n.Localizable.Home.Nodes.new(3))
    #expect(metric("heard", of: mesh)?.value == 8.formatted())
    #expect(mesh?.action == .openTab(.spectrum))
  }

  @Test
  func `Without the Spectrum tab the mesh card opens its readings, and the traffic shortcut goes`() {
    var inputs = readyInputs()
    // A card list with no Spectrum to open.
    inputs.tabs = [.dashboard, .nodes, .comm, .gps]
    let mesh = card("mesh", in: inputs)
    guard case let .info(title, rows)? = mesh?.action else {
      Issue.record("The mesh card should open its readings")
      return
    }
    #expect(title == L10n.Localizable.CarPlay.Cards.mesh)
    #expect(rows.map(\.title) == mesh?.panel?.metrics.map(\.label))
    #expect(rows.first?.detail == NodeRouteFormat.joined([
      L10n.Tools.Tools.Spectrum.Value.dbm("-92"),
      L10n.Localizable.CarPlay.Cards.decibels(7.5.formatted(.number.precision(.fractionLength(1)))),
    ]))
    #expect(mesh?.isEnabled == true)
    #expect(shortcut("traffic", in: inputs) == nil)
    #expect(row(CarPlayCardBuilder.shortcutsRowID, in: inputs)?.tiles.map(\.id) == ["heard", "scan", "advert"])
  }

  @Test
  func `The Heard count is the Recently Heard group it opens`() {
    var inputs = readyInputs()
    inputs.nodeCategories = []
    #expect(CarPlayCardBuilder.heardCount(inputs) == 0)
    #expect(shortcut("heard", in: inputs)?.subtitle == 0.formatted())
    #expect(metric("heard", of: card("mesh", in: inputs))?.value == 0.formatted())
  }

  @Test
  func `Each mesh reading opens its own page: traffic Spectrum, heard the Nodes tab`() {
    var inputs = readyInputs()
    #expect(shortcut("traffic", in: inputs)?.action == .openTab(.spectrum))
    #expect(shortcut("traffic", in: inputs)?.subtitle == L10n.Localizable.CarPlay.Cards.perMinute(12))
    #expect(shortcut("heard", in: inputs)?.action == .nodes(.recentlyHeard))
    #expect(shortcut("heard", in: inputs)?.subtitle == 8.formatted())
    // Nodes and Network Health stay off the Dashboard.
    #expect(shortcut("nodes", in: inputs) == nil)
    #expect(shortcut("health", in: inputs) == nil)

    // Without the Nodes tab, the heard count opens nothing.
    inputs.tabs = [.dashboard, .comm]
    #expect(shortcut("heard", in: inputs)?.action == nil)
  }

  @Test
  func `Readings not taken yet read as a dash, in grey`() {
    var inputs = readyInputs()
    inputs.live = .init()
    let mesh = card("mesh", in: inputs)
    #expect(metric("signal", of: mesh)?.value == "—")
    #expect(metric("noise", of: mesh)?.value == "—")
    #expect(mesh?.tint == .secondaryLabel)
    #expect(mesh?.title == L10n.Localizable.CarPlay.Cards.mesh)
    #expect(mesh?.panel?.status == nil)
  }

  @Test
  func `The messages card shows unread, the last sender, its age and channel, and opens Comm`() {
    let messages = card("messages", in: readyInputs())
    #expect(messages?.title == L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(5))
    #expect(messages?.subtitle == NodeRouteFormat.joined(["Alice", HomeFormat.age(120)]))
    #expect(messages?.action == .openTab(.comm))
    let ids = messages?.panel?.metrics.map(\.id) ?? []
    #expect(Array(ids.prefix(3)) == ["unread", "last", "place"])
    #expect(metric("unread", of: messages)?.value == 5.formatted())
    #expect(metric("last", of: messages)?.value == "Alice")
    #expect(metric("last", of: messages)?.caption == HomeFormat.age(120))
    #expect(metric("place", of: messages)?.value == "Public")
    #expect(metric("place", of: messages)?.label == L10n.Localizable.CarPlay.Chats.Kind.channel)

    // A direct message is not labelled a channel.
    var direct = readyInputs()
    direct.live.lastMessage?.channelName = nil
    let place = metric("place", of: card("messages", in: direct))
    #expect(place?.value == L10n.Localizable.CarPlay.Cards.direct)
    #expect(place?.label == L10n.Localizable.CarPlay.Cards.conversation)
  }

  @Test
  func `Only one short line of a message reaches the car`() {
    var inputs = readyInputs()
    inputs.live.lastMessage?.preview = "SECRET-LONG-BODY " + String(repeating: "word ", count: 30)
    let snapshot = CarPlaySnapshotBuilder.make(from: inputs, now: now)
    let messages = snapshot.dashboardTiles.flatMap(\.rows).flatMap(\.tiles).first { $0.id == "messages" }
    let preview = metric("preview", of: messages)
    #expect(CarPlayFeatures.messagePreview == (preview != nil))
    // Message text is Siri's: none on the car's screen.
    #expect(!CarPlayFeatures.messagePreview)
    #expect(!String(describing: snapshot).contains("SECRET-LONG-BODY"))
    if let preview {
      #expect(preview.value.count <= CarPlayCardBuilder.maxTextLength)
      #expect(preview.value.hasSuffix("…"))
    }
    #expect(!String(describing: snapshot).contains("word word word"))
  }

  @Test
  func `Without a message the card says so; without Comm it opens nothing`() {
    var inputs = readyInputs()
    inputs.live.lastMessage = nil
    inputs.tabs = [.dashboard, .nodes]
    let messages = card("messages", in: inputs)
    #expect(messages?.panel?.metrics.map(\.id) == ["unread", "last"])
    #expect(metric("last", of: messages)?.value == L10n.Localizable.CarPlay.Cards.noMessages)
    #expect(messages?.subtitle == L10n.Localizable.CarPlay.Cards.noMessages)
    #expect(messages?.action == nil)
  }

  @Test
  func `The messages card says Siri is off, or nothing unread, in a card's words`() {
    var inputs = readyInputs()
    inputs.isSiriAvailable = false
    #expect(card("messages", in: inputs)?.title == L10n.Localizable.CarPlay.Cards.siriOff)
    inputs.isSiriAvailable = true
    inputs.unread = 0
    #expect(card("messages", in: inputs)?.title == L10n.Localizable.CarPlay.Cards.noUnread)
    #expect(metric("unread", of: card("messages", in: inputs))?.valueTint == nil)
  }

  @Test
  func `Location pictures the GPS state, altitude and position as the Live Activity formats them`() {
    var inputs = readyInputs()
    let location = card("location", in: inputs)
    #expect(location?.panel?.metrics.map(\.id) == ["gps", "altitude", "position"])
    #expect(location?.title == GNSSStatus.fix.text)
    #expect(location?.subtitle == "Not sharing")
    #expect(metric("gps", of: location)?.value == GNSSStatus.fix.text)
    #expect(metric("position", of: location)?.value == "41.8823, -87.6232")
    #expect(metric("altitude", of: location)?.value == "182 m")
    #expect(location?.action == .openTab(.gps))

    inputs.live.altitudeText = nil
    inputs.live.positionText = nil
    let bare = card("location", in: inputs)
    #expect(bare?.panel?.metrics.map(\.id) == ["gps", "position"])
    #expect(metric("position", of: bare)?.value == L10n.Localizable.Home.Gps.noPosition)
    #expect(bare?.tint == .secondaryLabel)

    inputs.radio = nil
    inputs.lastRadioName = "Heltec"
    #expect(card("location", in: inputs) == nil)
  }

  @Test
  func `Send Advert is a condensed card that needs a ready radio`() {
    var inputs = readyInputs()
    inputs.isRadioReady = false
    let advert = shortcut("advert", in: inputs)
    #expect(advert?.action == .option(.advert))
    #expect(advert?.isEnabled == false)
  }

  @Test
  func `Every card's text is short, whatever the names`() {
    var inputs = readyInputs()
    inputs.radio?.name = "A very long radio name that goes on"
    inputs.radio?.model = "Some Manufacturer Model XYZ · v1.2.3-beta"
    inputs.live.lastMessage?.sender = "Somebody With A Very Long Mesh Name"
    inputs.live.lastMessage?.channelName = "An extremely long channel name"
    let tiles = sections(inputs).flatMap(\.rows).flatMap(\.tiles)
    for tile in tiles {
      #expect(tile.title.count <= CarPlayCardBuilder.maxTextLength, "\(tile.id): \(tile.title)")
      #expect((tile.subtitle?.count ?? 0) <= CarPlayCardBuilder.maxTextLength, "\(tile.id): \(tile.subtitle ?? "")")
      for metric in tile.panel?.metrics ?? [] {
        #expect(metric.value.count <= CarPlayCardBuilder.maxTextLength, "\(tile.id).\(metric.id): \(metric.value)")
      }
    }
  }

  @Test
  func `Node kinds wear the phone's avatars`() {
    #expect(CarPlayAvatar.symbol(ContactType.chat, name: "Alice") == AppTab.home.symbolName)
    #expect(CarPlayAvatar.symbol(ContactType.repeater, name: "Hill") == "cairn.repeater.fill")
    #expect(CarPlayAvatar.symbol(ContactType.room, name: "Room") == "door.left.hand.closed")
    #expect(CarPlayAvatar.tint(ContactType.chat, name: "Alice") == .avatar(.companion))
    #expect(CarPlayAvatar.tint(ContactType.repeater, name: "Hill") == .avatar(.repeater))
    #expect(CarPlayAvatar.tint(ContactType.room, name: "Room") == .avatar(.room))
    #expect(CarPlayAvatar.tint(HomeDashboardModel.ConversationLine.Kind.channel, name: "Public") == .avatar(.channel))
    #expect(CarPlayAvatar.symbol(.favorites) == "star.fill")
    #expect(CarPlayAvatar.symbol(.repeaters) == CarPlayAvatar.repeaterSymbol)
  }

  @Test
  func `A companion named with an emoji wears it, as on the phone; a repeater keeps its mast`() {
    #expect(CarPlayAvatar.symbol(ContactType.chat, name: "🚒 Engine 7") == CarPlayAvatar.emojiPrefix + "🚒")
    #expect(CarPlayAvatar.emoji(CarPlayAvatar.companion("Engine 🚒 7")) == "🚒")
    #expect(CarPlayAvatar.emoji(CarPlayAvatar.companionSymbol) == nil)
    #expect(CarPlayAvatar.symbol(ContactType.repeater, name: "🗻 Summit") == CarPlayAvatar.repeaterSymbol)
  }

  private func line(_ name: String, kind: HomeDashboardModel.ConversationLine.Kind, isPublic: Bool = false, isHashtag: Bool = false) -> HomeDashboardModel.ConversationLine {
    .init(id: UUID(), name: name, date: now, preview: nil, isUnread: false, kind: kind, isPublicChannel: isPublic, isHashtagChannel: isHashtag)
  }

  @Test
  func `Conversations wear ChannelAvatar's glyphs: globe, hash or lock`() {
    #expect(CarPlayAvatar.symbol(line("Public", kind: .channel, isPublic: true)) == "globe")
    #expect(CarPlayAvatar.symbol(line("#hiking", kind: .channel, isHashtag: true)) == "number")
    #expect(CarPlayAvatar.symbol(line("Family", kind: .channel)) == "lock")
    #expect(CarPlayAvatar.symbol(line("Alice", kind: .direct)) == CarPlayAvatar.companionSymbol)
    #expect(CarPlayAvatar.symbol(line("🚒 Crew", kind: .direct)) == CarPlayAvatar.emojiPrefix + "🚒")
    #expect(CarPlayAvatar.symbol(line("Lounge", kind: .room)) == CarPlayAvatar.roomSymbol)
  }

  @Test @MainActor
  func `Avatar colours are the phone's category colours, and a type pick wears one exactly`() {
    for category in AvatarCategory.allCases {
      #expect(hex(CarPlayTint.avatar(category).color(for: .dark)) == category.rgb)
      #expect(hex(CarPlayTint.swatch(.category(category)).color(for: .light)) == category.rgb)
    }
    #expect(hex(CarPlayTint.swatch(.custom(rgb: 0x336699)).color(for: .dark)) == 0x336699)
  }

  private func hex(_ color: UIColor) -> Int {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return Int((red * 255).rounded()) << 16 | Int((green * 255).rounded()) << 8 | Int((blue * 255).rounded())
  }

  @Test
  func `Short cuts with an ellipsis and keeps short text`() {
    #expect(CarPlayCardBuilder.short("Hello") == "Hello")
    #expect(CarPlayCardBuilder.short("one\ntwo   three") == "one two three")
    let cut = CarPlayCardBuilder.short(String(repeating: "x", count: 40))
    #expect(cut.count == CarPlayCardBuilder.maxTextLength)
    #expect(cut.hasSuffix("…"))
  }

  /// The card strings are written short, so `short` never has to cut one in any language.
  @Test
  func `Card strings fit a card in every locale`() throws {
    let locales = ["de", "en", "es", "fr", "it", "ko", "nl", "pl", "pt", "ru", "uk", "zh-Hans"]
    for locale in locales {
      let url = try #require(
        Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: locale),
        "Missing \(locale).lproj/Localizable.strings in the app bundle"
      )
      let strings = try #require(NSDictionary(contentsOf: url) as? [String: String])
      let cards = strings.filter { $0.key.hasPrefix("carPlay.cards.") && !$0.value.contains("%") }
      #expect(cards["carPlay.cards.siriOff"] != nil, "\(locale)")
      for (key, value) in cards {
        #expect(value.count <= CarPlayCardBuilder.maxTextLength, "\(locale) \(key): \(value)")
      }
    }
  }

  // MARK: - Spectrum

  private func spectrumState() -> CarPlayInputs.SpectrumState {
    var state = CarPlayInputs.SpectrumState()
    state.noiseFloor = -100
    state.trend = .rising
    state.lastRSSI = -80
    state.lastSNR = -8
    state.airtime = (rx: 0.3, tx: 0.05)
    state.channel = LoRaChannelMath(frequencyHz: 910_525_000, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)
    state.presetName = "USA/Canada"
    state.frequency = "910.525 MHz"
    state.modulation = "SF7 · 62.5 kHz · CR 4/5"
    state.txPower = "22 dBm"
    state.airtimePerPacket = "~98 ms/pkt"
    state.nowRSSI = -80
    state.history = [-101.4, -100.2, -99.6]
    state.packetsPerMinute = 12
    state.packetCount = 12
    state.peak = -71
    state.chartRevision = 3
    return state
  }

  @Test
  func `Spectrum is the phone's page on one line: header band, metric strip, chart and traffic`() throws {
    let rows = CarPlayCardBuilder.spectrum(spectrumState(), inputs: readyInputs())?.flatMap(\.rows) ?? []
    #expect(rows.map(\.id) == [CarPlayCardBuilder.spectrumRowID])
    #expect(rows[0].style == .cards)
    #expect(rows[0].title == nil)
    let tiles = rows[0].tiles
    #expect(tiles.map(\.id) == ["header", "readings", "chart", "traffic"])
    // Every card is a picture of the phone's own view.
    #expect(tiles.allSatisfy { $0.picture != nil })
    #expect(tiles[2].picture == .spectrumChart(revision: 3))
    #expect(tiles[3].picture == .spectrumTraffic(revision: 3))
    #expect(tiles[0].title == ChannelCondition.heavyInterference.title)
    #expect(tiles[0].tint == .color(ChannelCondition.heavyInterference.color))
    #expect(tiles[1].tint == .color(SNRQuality.poor.color))
    for tile in tiles {
      #expect(tile.title.count <= CarPlayCardBuilder.maxTextLength)
      #expect((tile.subtitle ?? "").count <= CarPlayCardBuilder.maxTextLength)
    }
  }

  @Test
  func `Spectrum header band reads the condition, preset, frequency, modulation, power and airtime`() {
    let header = CarPlayCardBuilder.spectrumHeader(spectrumState())
    #expect(header.condition == ChannelCondition.heavyInterference.title)
    #expect(header.conditionSymbol == ChannelCondition.heavyInterference.systemImage)
    #expect(header.preset == "USA/Canada")
    #expect(header.frequency == "910.525 MHz")
    // The full modulation: the picture has room the card's band doesn't.
    #expect(header.modulation == "SF7 · 62.5 kHz · CR 4/5")
    #expect(header.txPower == "22 dBm")
    #expect(header.airtime == "~98 ms/pkt")

    var measuring = CarPlayInputs.SpectrumState()
    measuring.isCalibrating = true
    let waiting = CarPlayCardBuilder.spectrumHeader(measuring)
    #expect(waiting.condition == L10n.Tools.Tools.Spectrum.Meter.calibrating)
    #expect(waiting.conditionSymbol == nil)
    #expect(waiting.conditionTint == .secondaryLabel)
  }

  @Test
  func `Spectrum metric strip reads NOW, FLOOR, AIR and PKT/MIN as the phone words them`() {
    let readings = CarPlayCardBuilder.spectrumReadings(spectrumState())
    #expect(readings.now == SpectrumFormat.dBm(-80))
    #expect(readings.margin == SpectrumFormat.signedDB(20))
    #expect(readings.isClear)
    #expect(readings.floor == SpectrumFormat.dBm(-100))
    #expect(readings.hasFloor)
    #expect(readings.trend == NoiseTrend.rising.title)
    #expect(readings.trendSymbol == "arrow.up.right")
    #expect(readings.history == [-101, -100, -100])
    let percent: (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(1))) }
    #expect(readings.air == percent(0.35))
    #expect(readings.split == L10n.Tools.Tools.Spectrum.Meter.airCaption(percent(0.3), percent(0.05)))
    #expect(readings.splitArrows == "↓" + percent(0.3) + " ↑" + percent(0.05))
    // 35 % of the time on air: heavy use, never "busy" (the radio's time-above-floor word).
    #expect(readings.load == L10n.Tools.Tools.Spectrum.Meter.heavyUse)
    #expect(readings.loadTint == .color(SpectrumPalette.warning))
    #expect(readings.rate == L10n.Tools.Tools.Spectrum.Figure.perMinute(12.0.formatted(.number.precision(.fractionLength(1)))))
    #expect(readings.count == L10n.Tools.Tools.RxLog.packetsCount(12))
    #expect(readings.peak == L10n.Tools.Tools.Spectrum.Meter.peakPacket(SpectrumFormat.dBm(-71)))
  }

  @Test
  func `Spectrum metric strip without readings says so, the floor an estimate while calibrating`() {
    var state = CarPlayInputs.SpectrumState()
    state.isCalibrating = true
    let readings = CarPlayCardBuilder.spectrumReadings(state)
    #expect(readings.now == "—")
    #expect(readings.margin == nil)
    #expect(readings.floor == "≈ " + SpectrumFormat.dBm(SpectrumStats.uncalibratedFloor))
    #expect(!readings.hasFloor)
    #expect(readings.trend == nil)
    #expect(readings.air == "—")
    #expect(readings.load == nil)
    #expect(readings.rate == "—")
    #expect(readings.count == L10n.Tools.Tools.Spectrum.Meter.calibrating)
  }

  @Test
  func `Spectrum history keeps the last ten minutes of readings`() {
    var state = spectrumState()
    state.history = (0..<100).map { -120 + Double($0) / 10 }
    let history = CarPlayCardBuilder.spectrumReadings(state).history
    #expect(history.count == CarPlayCardBuilder.historyLength)
    #expect(history.last == -110)
  }

  @Test
  func `Spectrum chart and traffic wait for their first readings`() {
    var state = spectrumState()
    state.chartRevision = nil
    let tiles = CarPlayCardBuilder.spectrum(state, inputs: readyInputs())?.flatMap(\.rows).flatMap(\.tiles)
    #expect(tiles?.map(\.id) == ["header", "readings"])
  }

  @Test
  func `Spectrum cards without a radio say why`() {
    var inputs = readyInputs()
    inputs.isRadioReady = false
    inputs.connectionState = .syncing
    let tiles = CarPlayCardBuilder.spectrum(.init(), inputs: inputs)?.flatMap(\.rows).flatMap(\.tiles)
    #expect(tiles?.map(\.subtitle) == [L10n.Settings.BleStatus.Status.syncing])
    #expect(tiles?.first?.picture == nil)
  }

  // MARK: - GPS

  private func gpsState() -> CarPlayInputs.GPSState {
    var state = CarPlayInputs.GPSState(phoneStatus: "Fix", phoneAccuracy: "Good", sharing: "Receiver On · Advert: Live GPS", phoneHasFix: true)
    state.radioStatus = .fix
    state.radioPosition = "41.8823, -87.6232"
    state.source = "Live GPS"
    state.readings = [
      GNSSReading(id: "radio.altitude", title: "Radio Altitude", systemImage: "mountain.2", value: "182 m"),
      GNSSReading(id: "phone.speed", title: "Speed", systemImage: "speedometer", value: "50 km/h"),
      GNSSReading(id: "phone.course", title: "Course", systemImage: "safari", value: "90°"),
    ]
    state.radioName = "Heltec"
    state.radioLatitude = 41.8823
    state.radioLongitude = -87.6232
    state.phoneGNSSStatus = .fix
    state.phoneLatitude = 41.8801
    state.phoneLongitude = -87.6301
    state.phoneAccuracyMeters = 5
    state.course = 92.4
    state.speed = "50 km/h"
    state.advert = "Live GPS"
    state.mapRevision = 2
    return state
  }

  @Test
  func `GPS is the phone's Position page: map, compass, radio and phone, then the readings`() {
    let rows = CarPlayCardBuilder.gps(gpsState(), inputs: readyInputs())?.flatMap(\.rows) ?? []
    #expect(rows.map(\.id) == [CarPlayCardBuilder.gpsRowID, CarPlayCardBuilder.gpsReadingsRowID])
    #expect(rows.map(\.style) == [.cards, .condensed])
    #expect(rows.allSatisfy { $0.title == nil })
    let cards = rows[0].tiles
    #expect(cards.map(\.id) == ["compass", "map", "radio", "phone"])
    #expect(cards.allSatisfy { $0.picture != nil })
    #expect(cards[1].picture == .gpsMap(revision: 2))
    // Coordinates are never cut.
    #expect(cards[1].subtitle == "41.8823, -87.6232")
    #expect(cards[2].picture == .gnssDevice(.init(
      side: .radio, detail: "Heltec", status: .fix, latitude: 41.8823, longitude: -87.6232, caption: "Live GPS"
    )))
    #expect(cards[3].picture == .gnssDevice(.init(
      side: .phone, status: .fix, latitude: 41.8801, longitude: -87.6301, accuracy: 5
    )))
    #expect(cards[3].tint == .feature(.gps))
    // The course is the compass's; the rest are readings, with how the location is shared.
    #expect(rows[1].tiles.map(\.id) == ["radio.altitude", "phone.speed", "sharing"])
    #expect(rows[1].tiles.last?.subtitle == "Live GPS")
  }

  @Test
  func `GPS compass follows the course in 5 degree steps, and has no heading standing still`() {
    var state = gpsState()
    let moving = CarPlayCardBuilder.compassPicture(state)
    #expect(moving.course == 90)
    #expect(moving.reading == GPSFormat.bearingText(90))
    #expect(moving.speed == "50 km/h")
    state.course = 358
    #expect(CarPlayCardBuilder.compassPicture(state).course == 0)
    state.course = nil
    let still = CarPlayCardBuilder.compassPicture(state)
    #expect(still.course == nil)
    #expect(still.reading == L10n.Map.Map.Gps.noHeading)
  }

  @Test
  func `GPS without a map or a radio still shows the compass and the phone`() {
    var state = CarPlayInputs.GPSState(phoneStatus: "No fix", sharing: "No radio")
    state.phoneNote = "Location is off"
    let rows = CarPlayCardBuilder.gps(state, inputs: readyInputs())?.flatMap(\.rows) ?? []
    #expect(rows.map(\.id) == [CarPlayCardBuilder.gpsRowID])
    let cards = rows[0].tiles
    #expect(cards.map(\.id) == ["compass", "radio", "phone"])
    #expect(cards[1].subtitle == GNSSStatus.noRadio.text)
    if case let .gnssDevice(radio) = cards[1].picture {
      #expect(radio.status == .noRadio)
      #expect(radio.note == L10n.Map.Map.Gps.notConnected)
    } else {
      Issue.record("The radio card should be a picture")
    }
    if case let .gnssDevice(phone) = cards[2].picture {
      #expect(phone.note == "Location is off")
    } else {
      Issue.record("The phone card should be a picture")
    }
    #expect(cards[2].tint == .secondaryLabel)
  }
}
