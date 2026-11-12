import CoreLocation
import Foundation
import CairnServices

/// Everything the CarPlay screen shows, as plain values. The controller rebuilds it from the app's
/// state and only touches the CarPlay templates when it changed, so an unrelated observation
/// never redraws the car's screen. It carries no message text: there is no field for it.
struct CarPlaySnapshot: Equatable {
  /// One title/detail pair on an information screen.
  struct InfoRow: Equatable {
    let title: String
    let detail: String
  }

  /// What the Send Advert option says after a tap: sending, then sent or not sent for one data
  /// interval, as the app's advert tile does.
  enum AdvertNote: Hashable {
    case idle
    case sending
    case sent
    case failed
  }

  // MARK: Dashboard

  /// The app's tools that make sense at the wheel, in the app's Tools order. Everything else on
  /// the phone's grid (Location & Sharing, Trace Path, Line of Sight, RX Log, CLI) is setup or
  /// maintenance and stays there.
  enum OptionKind: String, CaseIterable {
    case advert
    case scan
    case health
  }

  /// One Dashboard option, drawn as the app's icon tile: a white glyph on the tool's colour.
  struct Option: Equatable {
    let kind: OptionKind
    let text: String
    let detail: String
    let symbol: String
    let tint: CarPlayTint
    let isEnabled: Bool
    /// Opens a screen of its own (shows the disclosure arrow).
    let pushes: Bool
  }

  /// The app's status cards, in the app's order.
  enum CardKind: String, CaseIterable {
    case radio
    case chats
    case nodes
    case battery
    case mesh
    case gps
  }

  /// One status card: the big value as the row's text, the card's title and detail lines below,
  /// and the card's glyph in its feature colour.
  struct Card: Equatable {
    let kind: CardKind
    let symbol: String
    let tint: CarPlayTint
    let text: String
    let detail: String
    /// The tab (or the pushed GPS or Spectrum screen) a tap opens, as the app's card does; nil
    /// for cards whose app page is settings, which open a read-only screen of `info` instead.
    let opensTab: CarPlayTab?
    /// The card's title ("Battery"), the read-only screen's title.
    var title = ""
    /// The card's detail lines, one per row, for the read-only screen a tap opens when the card
    /// has no tab.
    var info: [InfoRow] = []
  }

  /// The app's Home for the car: the header card's name and link over the status cards, then
  /// the options under Tools, as HomeView lays them out.
  struct Dashboard: Equatable {
    /// The radio's name, as on the app's header card.
    var header: String
    /// The link first, then the radio's model and firmware: truncation cuts the model, never
    /// the state.
    var subtitle: String?
    var options: [Option]
    var cards: [Card]
  }

  // MARK: Comm

  /// A conversation on the Comm tab. A tap opens its screen (`ConversationPage`).
  struct ChatRow: Equatable, Identifiable {
    let id: UUID
    let name: String
    /// "3 unread · Bob · 2m · ✓ 2 repeats" (`CarPlayChatsSource.chatDetail`): who wrote last and
    /// when, never what.
    let detail: String
    let kind: HomeDashboardModel.ConversationLine.Kind
    /// The avatar's glyph, as the phone's Chats list draws it (`CarPlayAvatar.symbol`).
    let symbol: String
    /// Muted conversations never show the unread flag, as in the Comm tab's badge.
    let showsUnread: Bool
    let isMuted: Bool
    let isFavorite: Bool
  }

  /// One message on a conversation's screen: who wrote it, how it came or how the user's own
  /// went, and when. There is no field for its text; a tap has Siri read it.
  struct MessageRow: Equatable, Identifiable {
    let id: UUID
    /// The identifier Siri reads this one message by (`SiriMessage.identifier`).
    let siriIdentifier: String
    /// The sender, or "You".
    let sender: String
    /// "3 hops · SNR 6.5 dB", or for the user's own "✓ Delivered".
    let detail: String
    /// "2m".
    let age: String
    let symbol: String
    let tint: CarPlayTint
    let isUnread: Bool
  }

  /// A conversation's screen, pushed from its Comm row: Read with Siri and Reply, then its
  /// recent messages, newest first.
  struct ConversationPage: Equatable {
    let id: UUID
    let title: String
    /// The conversation's avatar, on the Read with Siri row.
    let symbol: String
    let tint: CarPlayTint
    /// Siri reads and sends every message; without it the screen shows `empty` and no rows.
    let hasSiri: Bool
    let showsUnread: Bool
    /// "3 unread", or what Siri reads when nothing is.
    let readDetail: String
    /// Rooms are read-only for Siri, so they have no Reply row.
    let canReply: Bool
    let rows: [MessageRow]
    /// The messages' header ("Recent messages"); nil without messages.
    var note: String?
    var empty: EmptyState
  }

  /// What an empty list says instead of rows.
  struct EmptyState: Equatable {
    let title: String
    let subtitle: String?
  }

  struct Chats: Equatable {
    var rows: [ChatRow]
    /// Unread messages in conversations that notify, for the tab's badge.
    var unread: Int
    var empty: EmptyState
    /// The conversation open on the tab, if any.
    var page: ConversationPage?
  }

  // MARK: Nodes

  struct NodeRow: Equatable, Identifiable {
    var id: Data { publicKey }
    let publicKey: Data
    let name: String
    /// "2m · A3 · Direct · 3.4 mi NE", the app's row in one line. The tile already says the
    /// node's type.
    let detail: String
    let symbol: String
    /// The read-only detail screen a tap opens.
    let info: [InfoRow]
    /// The tile's colour: the node type's, as on the app's map.
    var tint: CarPlayTint = .feature(.nodes)
  }

  /// A list of nodes the Nodes tab opens: one of its groups, one of the user's own groups, Find's
  /// letter groups, or the nodes whose names start with one of `letters`.
  enum NodeList: Hashable {
    case category(NodeCategory)
    case group(UUID)
    case find
    /// The folded first letters the group holds ("ABC"); "#" for digits and symbols.
    case letters(String)

    /// A stable identity for the row that opens it.
    var id: String {
      switch self {
      case let .category(category): "cat:\(category.rawValue)"
      case let .group(id): "group:\(id.uuidString)"
      case .find: "find"
      case let .letters(letters): "letters:\(letters)"
      }
    }
  }

  /// A collapsed group on the Nodes tab (or a letter group under Find): its glyph and colour as
  /// the phone draws them, its name, and how many nodes it holds with the freshest one.
  struct NodeGroupRow: Equatable, Identifiable {
    var id: String { list.id }
    let list: NodeList
    let title: String
    let count: Int
    /// The node heard most recently, short enough for a line ("Hilltop").
    var latestName: String?
    /// "2m", when that node was heard.
    var latestAge: String?
    let symbol: String
    let tint: CarPlayTint

    /// "12 · Hilltop 2m": the count first, so a glance at the collapsed group gives it.
    var detail: String {
      let latest = [latestName, latestAge].compactMap(\.self).joined(separator: " ")
      return NodeRouteFormat.joined([count.formatted(), latest.isEmpty ? nil : latest])
    }

    /// "12 · 2m", for a condensed card's narrow subtitle.
    var shortDetail: String {
      NodeRouteFormat.joined([count.formatted(), latestAge])
    }
  }

  /// A pushed list of nodes: the rows the car can hold, and a note when more were cut.
  struct NodeListPage: Equatable {
    let list: NodeList
    let title: String
    /// "Showing 12 of 40" when the list was cut to the car's limit; nil otherwise.
    var note: String?
    let rows: [NodeRow]
    var emptyTitle: String
  }

  /// The Nodes tab: Find and the app's groups with their counts (all collapsed), then the user's
  /// own groups, and the lists opened from them.
  struct Nodes: Equatable {
    var categories: [NodeGroupRow]
    var groups: [NodeGroupRow]
    /// Find's letter groups, built while Find is open.
    var letterGroups: [NodeGroupRow] = []
    /// The lists open now.
    var pages: [NodeListPage] = []
    var emptyTitle: String

    var rows: [NodeRow] {
      pages.flatMap(\.rows)
    }
  }

  // MARK: Scan

  /// One "scan for this kind" row, the car's version of the scan card's kind picker and ring
  /// button in one: a tap picks the kind and scans, or stops the scan it is running.
  struct ScanControl: Equatable {
    let filter: NodeDiscoveryFilter
    let title: String
    let detail: String?
    let symbol: String
    let tint: CarPlayTint
    let isEnabled: Bool
    /// The row stops the running scan instead of starting one.
    let stops: Bool
  }

  struct ScanResultRow: Equatable, Identifiable {
    var id: Data { publicKey }
    let publicKey: Data
    let name: String
    /// "↓ 10.5 dB · ↑ 8.0 dB · 3.4 km · 47° NE", the app's row in one line.
    let detail: String
    /// The app's signal glyph: `cellularbars` filled to `SNRQuality.barLevel`.
    let barLevel: Double
    let tint: CarPlayTint
    /// The read-only detail screen a tap opens.
    let info: [InfoRow]
  }

  struct ScanSection: Equatable {
    let title: String
    let rows: [ScanResultRow]
  }

  struct Scan: Equatable {
    /// The scan card's headline: idle, listening, replied, no replies.
    var header: String
    /// Why the scan stopped or can't start, the best and farthest replies, or what no reply means.
    var subtitle: String?
    var controls: [ScanControl]
    var sections: [ScanSection]

    var results: [ScanResultRow] {
      sections.flatMap(\.rows)
    }
  }

  // MARK: Network Health

  struct HealthRow: Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let tint: CarPlayTint
    /// Its status, issues and when it was last heard, for the read-only screen a tap opens.
    var info: [InfoRow] = []
  }

  struct HealthSection: Equatable {
    let title: String
    let rows: [HealthRow]
  }

  struct Health: Equatable {
    /// "8 Repeaters" / "Need Attention · 2"; nil with no repeaters.
    var summary: InfoRow?
    var sections: [HealthSection]
    var emptyTitle: String
  }

  // MARK: Cards

  /// The Nodes tab's groups, which a Dashboard card can open: the app's Nodes groups (Favorites,
  /// then its Contacts, Repeaters and Rooms filters), the nodes heard in the last hour, and the
  /// phone's Heard list (heard by advert, not saved).
  enum NodeCategory: String, CaseIterable, Hashable {
    case recentlyHeard
    case favorites
    case contacts
    case repeaters
    case rooms
    case heard
    /// The nodes with a position, nearest first, when the phone or the radio knows where it is.
    case nearby
  }

  /// What a tapped card does.
  enum TileAction: Equatable {
    case openTab(CarPlayTab)
    case option(OptionKind)
    /// A read-only screen of these lines.
    case info(title: String, rows: [InfoRow])
    /// The Nodes tab, at one of its groups when there is one (`CarPlayController.showNodes`).
    case nodes(NodeCategory?)
    /// One of the Nodes tab's lists, from its own cards.
    case nodeList(NodeList)
  }

  /// How a rich card draws a reading under its value: a bar filled to a share (a battery), or
  /// the app's signal bars filled to a level.
  enum Gauge: Hashable {
    case meter(Double, CarPlayTint)
    case bars(Double, CarPlayTint)
  }

  /// One reading inside a rich card's picture, as the phone's `MetricTile`: a quiet label with
  /// its glyph, then the value, loud, with a short caption beside it and an optional gauge.
  struct Metric: Hashable {
    let id: String
    let symbol: String
    let label: String
    let value: String
    var caption: String?
    /// Colours the value for a state (a low battery, a weak signal); nil keeps the label colour.
    var valueTint: CarPlayTint?
    var gauge: Gauge?
    /// Takes a line of its own, as a line of text does; a long value does anyway.
    var isWide = false
  }

  /// A card drawn as a picture of several readings, the phone's dashboard card in small: the
  /// feature's icon tile and name over a grid of readings. The card's own title and subtitle sit
  /// under the picture as a one-line summary.
  struct Panel: Hashable {
    let symbol: String
    let tint: CarPlayTint
    let heading: String
    /// A dot after the heading, in a state colour (the link, the GPS fix); nil for none.
    var status: CarPlayTint?
    let metrics: [Metric]
  }

  /// A card drawn as a picture of one of the phone's own views (`CarPlayPictureImage`), filling
  /// the card: the Spectrum tab's header band, metric strip, Channel chart and traffic table, and
  /// the GPS tab's map preview, compass and device cards. Values only, so an unchanged picture is
  /// never drawn twice. The chart, the traffic and the map are too big to carry; they come from
  /// `CarPlayPictureSource` under a revision `CarPlayPictureThrottle` moves on only when their
  /// data changed, and not more often than every few seconds.
  enum Picture: Hashable {
    case spectrumHeader(SpectrumHeaderPicture)
    case spectrumReadings(SpectrumReadingsPicture)
    case spectrumChart(revision: Int)
    case spectrumTraffic(revision: Int)
    case gpsMap(revision: Int)
    case compass(CompassPicture)
    case gnssDevice(GNSSDevicePicture)
  }

  /// The Spectrum tab's header band (`SpectrumHeaderBand`): the channel's condition, the preset
  /// and frequency, then the modulation, transmit power and a packet's airtime.
  struct SpectrumHeaderPicture: Hashable {
    /// "Quiet", or "Measuring…" / "Calibrating…" while there is no floor yet.
    var condition: String
    /// The condition's glyph; nil while measuring, when a spinner stands in.
    var conditionSymbol: String?
    var conditionTint: CarPlayTint
    var preset: String
    var frequency: String
    /// "SF7 · 62.5 kHz · CR 4/5"
    var modulation: String
    /// "22 dBm"
    var txPower: String?
    /// "~214 ms/pkt"
    var airtime: String
  }

  /// The Spectrum tab's metric strip (`SpectrumMetricStrip`) two by two, as the phone lays it
  /// out at large text sizes: NOW with its margin, FLOOR with its trend and history line, AIR
  /// with its RX/TX split, and PKT/MIN with the count and peak behind it.
  struct SpectrumReadingsPicture: Hashable {
    var now: String
    /// "+14 dB" over the floor; nil without a reading.
    var margin: String?
    var isClear = false
    /// "SNR 7.5", the radio's last packet.
    var snr: String?
    var floor: String
    var hasFloor = false
    var trend: String?
    var trendSymbol: String?
    /// The floor's recent readings in whole dBm, oldest first, for the history line.
    var history: [Int] = []
    var air: String
    /// "RX 1.2% · TX 0.1%", and "↓1.2% ↑0.1%" where that doesn't fit.
    var split: String?
    var splitArrows: String?
    /// "Heavy use" or "Very heavy use", with its colour.
    var load: String?
    var loadTint: CarPlayTint?
    var rate: String
    /// "12 packets"
    var count: String
    /// "Peak −87 dBm"
    var peak: String?
  }

  /// The GPS tab's compass card (`GPSCompassCard`). In a car the way it faces is the way it
  /// travels, so the needle follows the course over ground; standing still, it has no heading.
  struct CompassPicture: Hashable {
    /// Degrees from north in 5° steps, nil when not moving.
    var course: Double?
    /// "47° NE", or "No heading".
    var reading: String
    /// "50 km/h", in the app's units.
    var speed: String?
  }

  /// One of the GPS tab's device cards (`GNSSRadioHero`, `GNSSPhoneHero`): the header with the
  /// state badge, the coordinate readout and its caption, and for the phone the accuracy ring.
  struct GNSSDevicePicture: Hashable {
    enum Side: Hashable {
      case radio
      case phone
    }

    var side: Side
    /// The radio's name.
    var detail: String?
    var status: GNSSStatus
    var latitude: Double?
    var longitude: Double?
    /// Where the radio's position comes from, or the phone's accessory.
    var caption: String?
    /// The phone's horizontal accuracy in metres.
    var accuracy: Double?
    var isApproximate = false
    /// Why the card has nothing to read (no radio, location refused), in place of the readout.
    var note: String?
  }

  /// One card in a card row (iOS 26): the reading's glyph on a tile of its colour, its name, and
  /// its value in a few characters (`CarPlayCardBuilder.maxTextLength`). A card with a `panel`
  /// or a `picture` is drawn as that picture instead of the glyph, filling the card.
  struct Tile: Equatable {
    let id: String
    let symbol: String
    let tint: CarPlayTint
    let title: String
    let subtitle: String?
    /// How full `cellularbars` is drawn, for a signal card.
    var level: Double?
    var action: TileAction?
    var isEnabled = true
    var panel: Panel?
    var picture: Picture?
    /// Drawn as the phone's avatar (the glyph on a pebble of the tint, dark or light as the
    /// fill needs) rather than an icon tile: the Nodes tab's groups.
    var isAvatar = false
  }

  /// How a row draws its cards: big cards (a picture with a title band), or condensed ones (a
  /// small tile beside a title and subtitle, several to a line).
  enum TileRowStyle: Equatable {
    case cards
    case condensed
  }

  /// One row of cards under a short title.
  struct TileRow: Equatable {
    let id: String
    let title: String?
    let tiles: [Tile]
    var style: TileRowStyle = .cards
  }

  struct TileSection: Equatable {
    let header: String?
    let rows: [TileRow]
  }

  var dashboard: Dashboard
  var chats: Chats
  var nodes: Nodes
  var scan: Scan
  /// Built only while its screen or tab is open.
  var health: Health?
  var spectrum: [InfoRow]?
  var gps: [InfoRow]?
  /// The Dashboard, Spectrum and GPS as cards, on a car that draws them (`CarPlayInputs.usesCards`);
  /// empty or nil otherwise, when the rows above are shown instead.
  var dashboardTiles: [TileSection] = []
  var spectrumTiles: [TileSection]?
  var gpsTiles: [TileSection]?
}

/// Plain values the snapshot is built from, read off `AppState` by the controller. Tests make
/// them directly, so the wording and the limits are checked without a radio or a car.
struct CarPlayInputs {
  /// The connected radio, already in Home's words.
  struct Radio {
    var name: String
    /// "Heltec V3 · v1.9.1".
    var model: String?
    /// "910.525 MHz".
    var frequency: String
    var presetName: String
    /// "22 dBm".
    var txPower: String?
    var clientRepeat = false
    var isWiFi = false
    var transportDetail: String?
    var gpsStatus: GNSSStatus = .checking
    var locationSharing: String
  }

  struct LastHeard {
    var name: String
    /// "2m · 3.4 mi NE".
    var line: String
  }

  struct ScanState {
    var filter: NodeDiscoveryFilter = .repeaters
    var isScanning = false
    var secondsLeft = 0
    /// Replies for `filter`, positioned and measured, strongest first.
    var entries: [NodeDiscoveryEntry] = []
    var scannedFilters: Set<NodeDiscoveryFilter> = []
    var resolvingNameKeys: Set<Data> = []
    var addedKeys: Set<Data> = []
    /// Text safe for the car: never a raw error that might mention the phone.
    var message: String?
    var hasNoReplies = false
    /// A scan owned by another screen is running.
    var isBusyElsewhere = false
    /// The radio's firmware can send a scan request (official MeshCore firmware 1.10+).
    var canScan = true
  }

  struct HealthNode {
    var id: String
    var name: String
    var issues: [NetworkHealthIssue]
    var lastHeard: Date?
    var isCritical = false
  }

  /// `NetworkHealthReport`'s groups, most severe first.
  struct HealthState {
    var repeaterCount = 0
    var attention: [HealthNode] = []
    var healthy: [HealthNode] = []
  }

  struct SpectrumState {
    var noiseFloor: Double?
    var isCalibrating = false
    /// The radio's firmware doesn't report its statistics (official MeshCore firmware before
    /// 1.11): no noise floor, airtime or condition will come. Packets from the RX log still do.
    var statsUnsupported = false
    var trend: NoiseTrend?
    /// The last packet's signal: from the radio's statistics, or the RX log's newest packet.
    var lastRSSI: Int?
    var lastSNR: Double?
    var airtime: (rx: Double, tx: Double)?
    var channel: LoRaChannelMath?
    var presetName: String?
    /// "910.525 MHz".
    var frequency: String?
    /// "SF7 · 62.5 kHz · CR 4/5".
    var modulation: String?
    /// "22 dBm", the transmit power after any amplifier.
    var txPower: String?
    /// "~214 ms/pkt", a 40-byte packet's airtime.
    var airtimePerPacket: String?

    // The rest are the phone's Spectrum pictures (iOS 26): the readings the car keeps in a
    // `SpectrumViewModel` while the tab is open, the RX log's packets among them.

    /// NOW: the newest packet's strength, or the radio's own last reading.
    var nowRSSI: Double?
    /// The floor's recent readings, oldest first.
    var history: [Double] = []
    var packetsPerMinute: Double?
    /// Packets heard over the window's span.
    var packetCount = 0
    /// The strongest packet in the window.
    var peak: Double?
    /// The Channel chart's and the traffic table's revision; nil before there is anything to draw.
    var chartRevision: Int?
  }

  struct GPSState {
    /// The radio's badge; nil without a radio.
    var radioStatus: GNSSStatus?
    var radioPosition: String?
    var source: String?
    var phoneStatus: String
    var phoneAccuracy: String?
    var readings: [GNSSReading] = []
    var sharing: String
    /// The phone has a current fix, for the Phone card's colour.
    var phoneHasFix = false

    // The rest are the phone's GPS pictures (iOS 26).

    var radioName: String?
    var radioLatitude: Double?
    var radioLongitude: Double?
    /// The phone's badge, as the phone's own card shows it.
    var phoneGNSSStatus: GNSSStatus = .checking
    var phoneLatitude: Double?
    var phoneLongitude: Double?
    var phoneAccuracyMeters: Double?
    var isApproximate = false
    /// Location is refused: the phone card says so instead of reading out.
    var phoneNote: String?
    /// The course over ground while moving, in degrees.
    var course: Double?
    /// The phone's speed, in the app's units.
    var speed: String?
    /// Which position the radio's adverts carry: "Saved Position".
    var advert: String?
    /// The map preview's revision; nil while there is no map to show.
    var mapRevision: Int?
  }

  /// A conversation's screen open on the Comm tab: its line and its newest messages, newest first.
  struct OpenConversation {
    var line: HomeDashboardModel.ConversationLine
    var messages: [CarPlayChatsSource.Message] = []
  }

  /// The Live Activity's readings (`LiveActivityManager`), for the Dashboard's cards.
  struct LiveReadings {
    var lastRSSI: Int?
    var lastSNR: Double?
    var noiseFloor: Int?
    var packetsPerMinute = 0
    /// "41.8823, -87.6232" and "182 m" / "597 ft", formatted as the Live Activity formats them.
    var positionText: String?
    var altitudeText: String?
    /// Already filtered: never from a muted or mentions-only conversation.
    var lastMessage: MeshStatusAttributes.LastMessage?
  }

  /// No `AppState` yet: the app is still launching or waiting for the first unlock.
  var isStarting = false
  var connectionState: DeviceConnectionState = .disconnected
  var isRadioReady = false
  /// Bluetooth off or not allowed explains a radio that will not reconnect.
  var bluetooth: BluetoothAvailability = .ready
  /// Siri reads and sends every message in the car; without it the Comm rows can do nothing.
  var isSiriAvailable = true
  var radio: Radio?
  /// The last radio's name, while it is not connected.
  var lastRadioName: String?
  var batteryPercent: Int?
  var batteryDetail = ""
  var contactCount: Int?
  var newNodeCount = 0
  var lastHeard: LastHeard?
  var unread = 0
  var conversations: [HomeDashboardModel.ConversationLine] = []
  /// What each listed conversation's row says about its latest messages (`CarPlayChatsSource`).
  var chatActivity: [UUID: CarPlayChatsSource.Activity] = [:]
  /// The conversation whose screen is open on the Comm tab, and its newest messages.
  var openConversation: OpenConversation?
  /// The Nodes tab, already grouped (`CarPlayNodesSource`): its groups with their counts, the
  /// user's own groups, Find's letter groups while Find is open, and the lists open now.
  var nodeCategories: [CarPlaySnapshot.NodeGroupRow] = []
  var nodeGroups: [CarPlaySnapshot.NodeGroupRow] = []
  var letterGroups: [CarPlaySnapshot.NodeGroupRow] = []
  var nodePages: [CarPlaySnapshot.NodeListPage] = []
  var scan = ScanState()
  var advertNote: CarPlaySnapshot.AdvertNote = .idle
  var radioTools = CarPlayFeatures.radioTools
  /// The tabs the car shows; a card only opens a tab that is there.
  var tabs: [CarPlayTab] = CarPlayTab.allCases
  var selectedTab: CarPlayTab = .dashboard
  var health: HealthState?
  var spectrum: SpectrumState?
  var gps: GPSState?
  /// Rows a list may hold now: the car's limit, never more than `maxListItems`.
  var listLimit = CarPlaySnapshotBuilder.maxListItems
  /// The car draws card rows (iOS 26), so the Dashboard, Spectrum and GPS are built as cards.
  var usesCards = false
  var live = LiveReadings()

  /// A radio is connected now or was before; without one, every list is empty for that reason.
  var hasAnyRadio: Bool {
    radio != nil || lastRadioName != nil
  }
}

/// The values whose change redraws the car promptly instead of waiting out the data interval:
/// the link, Bluetooth, Siri, launch finishing, a scan starting or ending, the driver changing
/// tab, and an advert's result.
struct CarPlayEdgeKey: Equatable {
  let isStarting: Bool
  let connectionState: DeviceConnectionState
  let bluetooth: BluetoothAvailability
  let isSiriAvailable: Bool
  let isScanning: Bool
  let selectedTab: CarPlayTab
  let advertNote: CarPlaySnapshot.AdvertNote
}

/// Builds `CarPlaySnapshot` from `CarPlayInputs`. Pure, so the tests pin every string and limit.
enum CarPlaySnapshotBuilder {
  /// Most rows any CarPlay list shows: some cars cut lists to 12 while driving, so every list
  /// stays within that whatever the template allows.
  static let maxListItems = 12
  /// Most items a CarPlay information template holds.
  static let maxInfoItems = 10
  /// Longest node name in a combined detail line. Mesh names run to 32 bytes; the narrow detail
  /// column would cut the status after them.
  static let maxGlanceNameLength = 16
  /// The app's name, the Dashboard's header while the app starts.
  static let appName = "CAIRN"

  static func make(from inputs: CarPlayInputs, now: Date) -> CarPlaySnapshot {
    CarPlaySnapshot(
      dashboard: dashboard(inputs),
      chats: chats(inputs, now: now),
      nodes: nodes(inputs),
      scan: CarPlayScanBuilder.scan(inputs),
      health: inputs.health.map { health($0, listLimit: inputs.listLimit, now: now) },
      spectrum: inputs.spectrum.map { spectrum($0, inputs: inputs) },
      gps: inputs.gps.map(gps),
      dashboardTiles: CarPlayCardBuilder.dashboard(inputs, now: now),
      spectrumTiles: inputs.spectrum.flatMap { CarPlayCardBuilder.spectrum($0, inputs: inputs) },
      gpsTiles: inputs.gps.flatMap { CarPlayCardBuilder.gps($0, inputs: inputs) }
    )
  }

  static func edgeKey(_ inputs: CarPlayInputs) -> CarPlayEdgeKey {
    CarPlayEdgeKey(
      isStarting: inputs.isStarting,
      connectionState: inputs.connectionState,
      bluetooth: inputs.bluetooth,
      isSiriAvailable: inputs.isSiriAvailable,
      isScanning: inputs.scan.isScanning,
      selectedTab: inputs.selectedTab,
      advertNote: inputs.advertNote
    )
  }

  /// A node name short enough to sit after a status in one line: trimmed, without leading
  /// symbols or emoji, and cut with "…". A name made only of symbols is kept as it is.
  static func glanceName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let lettersFirst = String(trimmed.drop { !$0.isLetter && !$0.isNumber })
      .trimmingCharacters(in: .whitespaces)
    let text = lettersFirst.isEmpty ? trimmed : lettersFirst
    guard text.count > maxGlanceNameLength else { return text }
    return String(text.prefix(maxGlanceNameLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// Why the radio cannot connect, when Bluetooth is the reason. Only while nothing is
  /// connected: a Wi-Fi radio does not care.
  static func bluetoothProblem(_ inputs: CarPlayInputs) -> String? {
    guard inputs.radio == nil else { return nil }
    return switch inputs.bluetooth {
    case .ready: nil
    case .poweredOff: L10n.Localizable.CarPlay.Home.bluetoothOff
    case .unauthorized: L10n.Localizable.CarPlay.Home.bluetoothNotAllowed
    }
  }

  /// The link in the status menu's words, or Bluetooth when that is why there is no link.
  static func linkStatus(_ inputs: CarPlayInputs) -> String {
    bluetoothProblem(inputs) ?? HomeStatusLines.linkTitle(inputs.connectionState)
  }

  // MARK: - Dashboard

  /// The app's Dashboard for the car: the status cards in the order a driver needs them, then the
  /// tools worth a tap while driving. The cards come first within the list limit and the options
  /// take the room left. The header and subtitle are the list's empty view while the app starts.
  static func dashboard(_ inputs: CarPlayInputs) -> CarPlaySnapshot.Dashboard {
    guard !inputs.isStarting else {
      return .init(header: appName, subtitle: L10n.Localizable.CarPlay.Home.starting, options: [], cards: [])
    }
    let header = (inputs.radio?.name ?? inputs.lastRadioName).map(glanceName) ?? L10n.Localizable.Home.noRadio
    let subtitle: String = if inputs.hasAnyRadio {
      NodeRouteFormat.joined([linkStatus(inputs), inputs.radio?.model])
    } else {
      L10n.Localizable.CarPlay.Home.noRadioPaired
    }
    let options = dashboardOptions(inputs)
    let cards = dashboardCards(inputs)
    return .init(
      header: header,
      subtitle: subtitle,
      options: Array(options.prefix(max(0, inputs.listLimit - cards.count))),
      cards: Array(cards.prefix(inputs.listLimit))
    )
  }

  /// Send Advert, Scan for Nodes and Network Health, all behind `CarPlayFeatures.radioTools`:
  /// with the switch off the Dashboard is the status cards alone.
  static func dashboardOptions(_ inputs: CarPlayInputs) -> [CarPlaySnapshot.Option] {
    guard inputs.radioTools else { return [] }
    let health = CarPlaySnapshot.Option(
      kind: .health,
      text: ToolSelection.networkHealth.title,
      detail: ToolSelection.networkHealth.subtitle,
      symbol: CarPlayFeature.health.symbol,
      tint: .feature(.health),
      isEnabled: true,
      pushes: true
    )
    let (advertSymbol, advertTint, advertDetail): (String, CarPlayTint, String) = switch inputs.advertNote {
    case .idle: (CarPlayFeature.advert.symbol, .feature(.advert), L10n.Tools.Tools.Subtitle.advert)
    case .sending: (CarPlayFeature.advert.symbol, .feature(.advert), L10n.Localizable.CarPlay.Advert.sending)
    case .sent: ("checkmark", .success, L10n.Localizable.CarPlay.Advert.sent)
    case .failed: ("exclamationmark.triangle.fill", .warning, L10n.Localizable.CarPlay.Advert.failed)
    }
    let advert = CarPlaySnapshot.Option(
      kind: .advert,
      text: L10n.Tools.Tools.advert,
      detail: advertDetail,
      symbol: advertSymbol,
      tint: advertTint,
      isEnabled: inputs.isRadioReady && inputs.advertNote != .sending,
      pushes: false
    )

    let scanState = inputs.scan
    let scan = CarPlaySnapshot.Option(
      kind: .scan,
      // CarPlay scans only: Scan for Nodes' name, not the phone's Scan & Traffic.
      text: L10n.Tools.Tools.nodeDiscovery,
      detail: scanState.isScanning
        ? L10n.Localizable.CarPlay.Scan.progress(scanState.entries.count, scanState.secondsLeft)
        : L10n.Tools.Tools.Subtitle.nodeDiscovery,
      symbol: CarPlayFeature.scan.symbol,
      tint: .feature(.scan),
      // Always open: the Scan screen says why a scan can't start.
      isEnabled: true,
      pushes: true
    )
    // Scan first, so a short list keeps it (the Dashboard shows it fourth,
    // `CarPlayTemplates.scanRowIndex`); then an advert; Network Health is a page to read.
    return [scan, advert, health]
  }

  /// The radio (with its battery) and its link first, then what a driver checks most: messages,
  /// then nodes, then what the radio hears, then GPS. A low battery gets a card of its own under
  /// the radio. Mesh and GPS push their screens (`CarPlayTabLayout.pushedScreens`).
  static func dashboardCards(_ inputs: CarPlayInputs) -> [CarPlaySnapshot.Card] {
    let radio = inputs.radio
    var cards: [CarPlaySnapshot.Card] = [radioCard(inputs)]
    let tabIfShown: (CarPlayTab) -> CarPlayTab? = { tab in
      inputs.tabs.contains(tab) || CarPlayTabLayout.pushedScreens(radioTools: inputs.radioTools).contains(tab) ? tab : nil
    }

    // The Radio card carries the level; a low battery also gets a card of its own, in the warning
    // colour, so it can't be missed.
    let percent = inputs.batteryPercent
    if radio != nil, let level = percent.map(BatteryLevel.init(percent:)), level == .low || level == .critical {
      let reading = NodeRouteFormat.joined([BatteryLevel.formattedPercent(percent), level.title])
      cards.append(.init(
        kind: .battery,
        symbol: BatteryLevel.symbol(for: percent),
        tint: level == .critical ? .critical : .warning,
        text: reading,
        detail: NodeRouteFormat.joined([L10n.Settings.DeviceInfo.battery, inputs.batteryDetail]),
        opensTab: nil,
        title: L10n.Settings.DeviceInfo.battery,
        info: [
          .init(title: L10n.Settings.DeviceInfo.battery, detail: reading),
          .init(title: L10n.Settings.Battery.voltage, detail: inputs.batteryDetail),
        ]
      ))
    }

    cards.append(.init(
      kind: .chats,
      symbol: CarPlayFeature.comm.symbol,
      tint: .feature(.comm),
      text: inputs.unread > 0
        ? L10n.Localizable.Tabs.chatsUnreadAccessibilityValue(inputs.unread)
        : L10n.Localizable.CarPlay.Home.Chats.none,
      detail: NodeRouteFormat.joined([
        L10n.Localizable.Tabs.chats,
        inputs.isSiriAvailable ? nil : L10n.Localizable.CarPlay.Chats.siriOff,
      ]),
      opensTab: tabIfShown(.comm)
    ))

    let count = inputs.contactCount.map { $0.formatted() } ?? "—"
    let lastHeard: [String?] = if let heard = inputs.lastHeard {
      // Status first, name last: tail truncation then cuts the name, never the age.
      [heard.line, glanceName(heard.name)]
    } else {
      [L10n.Localizable.Home.Nodes.noAdverts]
    }
    cards.append(.init(
      kind: .nodes,
      symbol: CarPlayFeature.nodes.symbol,
      tint: .feature(.nodes),
      text: NodeRouteFormat.joined([count, inputs.newNodeCount > 0 ? L10n.Localizable.Home.Nodes.new(inputs.newNodeCount) : nil]),
      detail: NodeRouteFormat.joined([L10n.Localizable.Tabs.nodes] + lastHeard),
      opensTab: tabIfShown(.nodes)
    ))

    if inputs.hasAnyRadio {
      cards.append(meshCard(inputs, opensTab: tabIfShown(.spectrum)))
    }

    if let radio {
      cards.append(.init(
        kind: .gps,
        symbol: CarPlayFeature.gps.symbol,
        tint: CarPlayTint.state(radio.gpsStatus.tint),
        text: radio.gpsStatus.text,
        detail: NodeRouteFormat.joined([L10n.Localizable.Tabs.gps, radio.locationSharing]),
        opensTab: tabIfShown(.gps)
      ))
    }
    return cards
  }

  /// What the radio hears, from the Live Activity's readings: the last packet's signal as the
  /// row's value, packets a minute and the nodes heard in the hour under it. A tap opens Spectrum;
  /// without the radio tools, the readings on a screen of their own.
  static func meshCard(_ inputs: CarPlayInputs, opensTab: CarPlayTab?) -> CarPlaySnapshot.Card {
    let live = inputs.live
    let heard = CarPlayCardBuilder.heardCount(inputs)
    let metrics = CarPlayCardBuilder.meshCard(inputs).panel?.metrics ?? []
    return .init(
      kind: .mesh,
      symbol: CarPlayFeature.spectrum.symbol,
      tint: live.lastSNR == nil ? .feature(.spectrum) : CarPlayCardBuilder.signalTint(snr: live.lastSNR),
      text: CarPlayCardBuilder.signalText(rssi: live.lastRSSI, snr: live.lastSNR) ?? L10n.Tools.Tools.Spectrum.waitingForPacket,
      detail: NodeRouteFormat.joined([
        L10n.Localizable.CarPlay.Cards.mesh,
        L10n.Localizable.CarPlay.Cards.perMinute(live.packetsPerMinute),
        L10n.Localizable.CarPlay.Cards.heardCount(heard),
      ]),
      opensTab: opensTab,
      title: L10n.Localizable.CarPlay.Cards.mesh,
      info: CarPlayCardBuilder.infoRows(metrics)
    )
  }

  /// The radio by name with its link and channel underneath, standing in for the app's header
  /// card and its Network, Radio and Battery cards, in the radio's own avatar colour as the phone
  /// draws it (the colour picked for it, else the radio colour). A link that isn't up (or
  /// Bluetooth stopping it) leads its line. A tap shows the link and radio settings.
  static func radioCard(_ inputs: CarPlayInputs) -> CarPlaySnapshot.Card {
    let name = (inputs.radio?.name ?? inputs.lastRadioName).map(glanceName) ?? L10n.Localizable.Home.noRadio
    guard let radio = inputs.radio else {
      return .init(
        kind: .radio,
        symbol: CarPlayFeature.network.symbol,
        tint: inputs.hasAnyRadio ? .warning : .secondaryLabel,
        text: name,
        detail: inputs.hasAnyRadio ? linkStatus(inputs) : L10n.Localizable.CarPlay.Home.noRadioPaired,
        opensTab: nil,
        title: name,
        info: networkInfo(inputs)
      )
    }
    // In pairs for the two-column screen: Transport | Link, Battery | Model, Frequency | Preset,
    // then TX power | the PIN or WiFi address.
    let network = networkInfo(inputs)
    var info = Array(network.prefix(2))
    let battery = inputs.batteryPercent.map(BatteryLevel.formattedPercent)
    if let battery {
      info.append(.init(
        title: L10n.Settings.DeviceInfo.battery,
        detail: NodeRouteFormat.joined([battery, inputs.batteryDetail])
      ))
    }
    if let model = radio.model {
      info.append(.init(title: L10n.Settings.DeviceInfo.model, detail: model))
    }
    info += [
      .init(title: L10n.Settings.Radio.Tile.frequency, detail: radio.frequency),
      .init(title: L10n.Settings.Radio.preset, detail: radio.presetName),
    ]
    if let txPower = radio.txPower {
      info.append(.init(title: L10n.Settings.Dashboard.txPower, detail: txPower))
    }
    info += network.dropFirst(2)
    return .init(
      kind: .radio,
      symbol: radio.isWiFi ? "wifi" : CarPlayFeature.radio.symbol,
      tint: radio.clientRepeat ? .feature(.radioRepeat) : CarPlayAvatar.radioTint(radio.name),
      // "Heltec · 87%": the battery beside the name, as a phone shows its own.
      text: NodeRouteFormat.joined([name, battery]),
      // The link first: tail truncation cuts the preset, never the state.
      detail: NodeRouteFormat.joined([linkStatus(inputs), radio.frequency, radio.presetName]),
      opensTab: nil,
      title: name,
      info: info
    )
  }

  /// The link's lines on the Radio card's screen: the transport, the link, and the WiFi address
  /// or the Bluetooth PIN kind.
  static func networkInfo(_ inputs: CarPlayInputs) -> [CarPlaySnapshot.InfoRow] {
    guard let radio = inputs.radio else {
      return [.init(title: L10n.Settings.Dashboard.link, detail: linkStatus(inputs))]
    }
    var rows: [CarPlaySnapshot.InfoRow] = [
      .init(title: L10n.Settings.Connection.transport, detail: HomeStatusLines.transportName(isWiFi: radio.isWiFi)),
      .init(title: L10n.Settings.Dashboard.link, detail: linkStatus(inputs)),
    ]
    if let detail = radio.transportDetail {
      rows.append(.init(title: radio.isWiFi ? L10n.Settings.Wifi.address : L10n.Localizable.CarPlay.Network.pin, detail: detail))
    }
    return rows
  }

  // MARK: - Comm

  static func chats(_ inputs: CarPlayInputs, now: Date) -> CarPlaySnapshot.Chats {
    let unread = inputs.isStarting ? 0 : inputs.unread
    let page = inputs.openConversation.map { CarPlayChatsSource.page($0, inputs: inputs, now: now) }
    guard inputs.hasAnyRadio || inputs.isStarting else {
      return .init(rows: [], unread: unread, empty: .init(title: L10n.Localizable.CarPlay.Home.noRadioPaired, subtitle: nil), page: page)
    }
    // Every conversation's screen reads and replies through Siri; without Siri it could do
    // nothing, so the list says why instead.
    guard inputs.isSiriAvailable else {
      return .init(rows: [], unread: unread, empty: .init(title: L10n.Localizable.CarPlay.Chats.siriOff, subtitle: nil), page: page)
    }
    let rows = inputs.conversations.prefix(maxListItems).map { line in
      CarPlaySnapshot.ChatRow(
        id: line.id,
        name: line.name,
        detail: CarPlayChatsSource.chatDetail(line, activity: inputs.chatActivity[line.id], now: now),
        kind: line.kind,
        symbol: CarPlayAvatar.symbol(line),
        showsUnread: line.unreadCount > 0 && !line.isMuted,
        isMuted: line.isMuted,
        isFavorite: line.isFavorite
      )
    }
    return .init(
      rows: Array(rows),
      unread: unread,
      empty: .init(title: L10n.Localizable.CarPlay.Chats.empty, subtitle: L10n.Localizable.CarPlay.Chats.siriHint),
      page: page
    )
  }

  static func kindName(_ kind: HomeDashboardModel.ConversationLine.Kind) -> String {
    switch kind {
    case .direct: L10n.Contacts.Contacts.NodeKind.contact
    case .channel: L10n.Localizable.CarPlay.Chats.Kind.channel
    case .room: L10n.Contacts.Contacts.NodeKind.room
    }
  }

  // MARK: - Nodes

  /// The Nodes tab as given, each list within `maxListItems` rows (the lists are cut, with their
  /// note, when they are built), and the tab's empty wording.
  static func nodes(_ inputs: CarPlayInputs) -> CarPlaySnapshot.Nodes {
    let emptyTitle = inputs.hasAnyRadio || inputs.isStarting
      ? L10n.Contacts.Contacts.List.Empty.Contacts.title
      : L10n.Localizable.CarPlay.Home.noRadioPaired
    let pages = inputs.nodePages.map { page in
      var page = page
      if page.rows.count > maxListItems {
        page = .init(list: page.list, title: page.title, note: page.note, rows: Array(page.rows.prefix(maxListItems)), emptyTitle: page.emptyTitle)
      }
      return page
    }
    return .init(
      categories: inputs.nodeCategories,
      groups: inputs.nodeGroups,
      letterGroups: inputs.letterGroups,
      pages: pages,
      emptyTitle: emptyTitle
    )
  }

  // MARK: - Network Health

  /// The Network Health page for the car: the fleet as the list's header, then the repeaters that
  /// need attention (most severe first) and the healthy ones, `listLimit` rows in all. A row
  /// opens a read-only screen of its status, issues and last advert.
  static func health(_ state: CarPlayInputs.HealthState, listLimit: Int, now: Date) -> CarPlaySnapshot.Health {
    let emptyTitle = L10n.Tools.Tools.NetworkHealth.Empty.title
    guard state.repeaterCount > 0 else {
      return .init(summary: nil, sections: [], emptyTitle: emptyTitle)
    }
    let summary = CarPlaySnapshot.InfoRow(
      title: "\(state.repeaterCount.formatted()) \(L10n.Tools.Tools.NetworkHealth.Summary.repeaters)",
      detail: NodeRouteFormat.joined([L10n.Tools.Tools.NetworkHealth.Summary.attention, state.attention.count.formatted()])
    )
    let heard: (CarPlayInputs.HealthNode) -> String? = { node in
      node.lastHeard.map { L10n.Tools.Tools.NetworkHealth.heard(HomeFormat.age(now.timeIntervalSince($0))) }
    }
    let info: (CarPlayInputs.HealthNode) -> [CarPlaySnapshot.InfoRow] = { node in
      let status = node.issues.isEmpty
        ? L10n.Tools.Tools.NetworkHealth.Section.healthy
        : NodeRouteFormat.joined(node.issues.map(\.title))
      var rows: [CarPlaySnapshot.InfoRow] = [.init(title: L10n.Contacts.Contacts.PathDetail.status, detail: status)]
      if let lastHeard = node.lastHeard {
        rows.append(.init(title: L10n.Contacts.Contacts.Detail.lastHeard, detail: HomeFormat.age(now.timeIntervalSince(lastHeard))))
      }
      return rows
    }
    var remaining = max(0, listLimit)
    var sections: [CarPlaySnapshot.HealthSection] = []
    let attentionRows = state.attention.prefix(remaining).map { node in
      CarPlaySnapshot.HealthRow(
        id: node.id,
        name: node.name,
        detail: NodeRouteFormat.joined(node.issues.map(\.title) + [heard(node)]),
        symbol: node.issues.first?.systemImage ?? "exclamationmark.triangle.fill",
        tint: node.isCritical ? .critical : .warning,
        info: info(node)
      )
    }
    remaining -= attentionRows.count
    if !attentionRows.isEmpty {
      sections.append(.init(title: L10n.Tools.Tools.NetworkHealth.Section.attention, rows: Array(attentionRows)))
    }
    let healthyRows = state.healthy.prefix(remaining).map { node in
      CarPlaySnapshot.HealthRow(
        id: node.id,
        name: node.name,
        detail: heard(node) ?? "",
        symbol: "checkmark.circle.fill",
        tint: .success,
        info: info(node)
      )
    }
    if !healthyRows.isEmpty {
      sections.append(.init(title: L10n.Tools.Tools.NetworkHealth.Section.healthy, rows: Array(healthyRows)))
    }
    return .init(summary: summary, sections: sections, emptyTitle: emptyTitle)
  }

  // MARK: - Spectrum

  /// The Spectrum screen as a read-only glance: the condition, the noise floor and its trend, the
  /// last packet, how busy the channel is, the traffic (rate, packets in the window, the peak),
  /// the channel, its modulation with a packet's airtime, and the TX power. On radio firmware that
  /// doesn't report its statistics, the readings they would fill say so instead of measuring; the
  /// last packet still comes from the RX log there.
  static func spectrum(_ state: CarPlayInputs.SpectrumState, inputs: CarPlayInputs) -> [CarPlaySnapshot.InfoRow] {
    guard inputs.isRadioReady, !inputs.isStarting else {
      let reason = CarPlayScanBuilder.blockedReason(inputs) ?? L10n.Localizable.CarPlay.Scan.notReady
      return [.init(title: L10n.Localizable.Tabs.spectrum, detail: reason)]
    }
    let measuring = state.isCalibrating ? L10n.Tools.Tools.Spectrum.Meter.calibrating : L10n.Tools.Tools.Spectrum.measuring
    // What the radio's statistics would fill, on firmware that never reports them
    let unread = state.statsUnsupported ? L10n.Localizable.CarPlay.Spectrum.unsupported : measuring
    let dbm: (Double) -> String = { L10n.Tools.Tools.Spectrum.Value.dbm($0.formatted(.number.precision(.fractionLength(0)))) }
    let percent: (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) }

    var rows: [CarPlaySnapshot.InfoRow] = []
    let condition: ChannelCondition? = if let floor = state.noiseFloor, let channel = state.channel {
      ChannelCondition(desensitization: channel.desensitization(noiseFloor: floor))
    } else {
      nil
    }
    rows.append(.init(title: L10n.Localizable.CarPlay.Spectrum.condition, detail: condition?.title ?? unread))
    rows.append(.init(
      title: L10n.Tools.Tools.Spectrum.Figure.noiseFloor,
      detail: state.noiseFloor.map { NodeRouteFormat.joined([dbm($0), state.trend?.title]) } ?? unread
    ))
    rows.append(.init(
      title: L10n.Tools.Tools.Spectrum.Figure.lastPacket,
      detail: state.lastRSSI.map { rssi in
        NodeRouteFormat.joined([
          dbm(Double(rssi)),
          state.lastSNR.map { L10n.Tools.Tools.Spectrum.Detail.snr($0.formatted(.number.precision(.fractionLength(1)))) },
        ])
      } ?? L10n.Tools.Tools.Spectrum.waitingForPacket
    ))
    rows.append(.init(
      title: L10n.Tools.Tools.Spectrum.Figure.airtime,
      detail: state.airtime.map { share in
        NodeRouteFormat.joined([
          percent(min(1, share.rx + share.tx)),
          L10n.Tools.Tools.Spectrum.Figure.busyCaption(percent(share.rx), percent(share.tx)),
        ])
      } ?? unread
    ))
    rows.append(.init(
      title: L10n.Localizable.CarPlay.Cards.traffic,
      detail: state.packetsPerMinute.map { rate in
        NodeRouteFormat.joined([
          L10n.Tools.Tools.Spectrum.Figure.perMinute(rate.formatted(.number.precision(.fractionLength(1)))),
          L10n.Tools.Tools.RxLog.packetsCount(state.packetCount),
          state.peak.map { L10n.Tools.Tools.Spectrum.Meter.peakPacket(dbm($0)) },
        ])
      } ?? measuring
    ))
    if state.presetName != nil || state.frequency != nil {
      rows.append(.init(
        title: L10n.Tools.Tools.Spectrum.Figure.channel,
        detail: NodeRouteFormat.joined([state.presetName, state.frequency])
      ))
    }
    if let modulation = state.modulation {
      rows.append(.init(
        title: L10n.Localizable.CarPlay.Home.modulation,
        detail: NodeRouteFormat.joined([modulation, state.airtimePerPacket])
      ))
    }
    if let txPower = state.txPower {
      rows.append(.init(title: L10n.Settings.Dashboard.txPower, detail: txPower))
    }
    return Array(rows.prefix(maxInfoItems))
  }

  // MARK: - GPS

  /// Reading ids the car leaves out: the compass course is the car's own instruments' job.
  static let gpsSkippedReadings: Set<String> = ["phone.course"]

  /// The GPS tab's two cards and its readings as a read-only glance, settings as one summary.
  static func gps(_ state: CarPlayInputs.GPSState) -> [CarPlaySnapshot.InfoRow] {
    var rows: [CarPlaySnapshot.InfoRow] = []
    if let status = state.radioStatus {
      rows.append(.init(
        title: L10n.Map.Map.Gps.Dash.radio,
        detail: NodeRouteFormat.joined([status.text, state.radioPosition ?? L10n.Localizable.Home.Gps.noPosition])
      ))
      if let source = state.source {
        rows.append(.init(title: L10n.Localizable.CarPlay.Gps.source, detail: source))
      }
    } else {
      rows.append(.init(title: L10n.Map.Map.Gps.Dash.radio, detail: GNSSStatus.noRadio.text))
    }
    rows.append(.init(
      title: L10n.Map.Map.Gps.Dash.phone,
      detail: NodeRouteFormat.joined([state.phoneStatus, state.phoneAccuracy])
    ))
    for reading in state.readings where !gpsSkippedReadings.contains(reading.id) {
      rows.append(.init(title: reading.title, detail: NodeRouteFormat.joined([reading.value, reading.caption])))
    }
    if state.radioStatus != nil {
      rows.append(.init(title: L10n.Localizable.CarPlay.Gps.sharing, detail: state.sharing))
    }
    return Array(rows.prefix(maxInfoItems))
  }
}

// MARK: - Spectrum Last Packet

extension CarPlayInputs.SpectrumState {
  /// Takes the last packet's signal from the RX log's newest packet when the radio's statistics
  /// have none. Every firmware pushes each received packet's signal in the RX log, also where its
  /// statistics never report a last packet (official MeshCore firmware before 1.11).
  mutating func fillLastPacket(from packet: SpectrumPacket?) {
    guard lastRSSI == nil, let packet, let rssi = packet.entry.rssi else { return }
    lastRSSI = rssi
    lastSNR = packet.snr
  }
}
