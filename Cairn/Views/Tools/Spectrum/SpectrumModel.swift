import Foundation
import CairnServices
import MeshCore
import SwiftUI

// The Spectrum tab's pure parts: the bounded history it keeps, the time windows it shows, the
// figures it derives, and how it names and colors a packet. Kept free of views and of the radio
// so each rule is unit-tested on its own (Cairn's `SpecMath` plays the same role on the L2).

// MARK: - Ring buffer

/// A fixed-capacity history, oldest first. Appending past capacity drops the oldest element, so a
/// tab left open for hours holds a bounded amount of memory (Cairn's raw and tier rings).
struct RingBuffer<Element> {
  let capacity: Int
  private var storage: [Element] = []
  /// Index of the oldest element once the buffer has wrapped.
  private var head = 0

  init(capacity: Int) {
    self.capacity = max(1, capacity)
    storage.reserveCapacity(self.capacity)
  }

  var count: Int { storage.count }
  var isEmpty: Bool { storage.isEmpty }

  mutating func append(_ element: Element) {
    if storage.count < capacity {
      storage.append(element)
    } else {
      storage[head] = element
      head = (head + 1) % capacity
    }
  }

  mutating func removeAll() {
    storage.removeAll(keepingCapacity: true)
    head = 0
  }

  /// The elements, oldest first.
  var elements: [Element] {
    head == 0 ? storage : Array(storage[head...] + storage[..<head])
  }

  var last: Element? {
    guard !storage.isEmpty else { return nil }
    return storage[(head + storage.count - 1) % storage.count]
  }

  var first: Element? {
    storage.isEmpty ? nil : storage[head % storage.count]
  }
}

// MARK: - Time-ordered search

extension RandomAccessCollection where Index == Int {
  /// The index of the first element dated at or after `start`, in elements already sorted by
  /// date (the rings append in time order). A binary search, so the chart's per-tick window
  /// lookups stay cheap however much history is kept.
  func firstIndex(atOrAfter start: Date, date: (Element) -> Date) -> Int {
    var low = startIndex
    var high = endIndex
    while low < high {
      let mid = low + (high - low) / 2
      if date(self[mid]) < start {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }

  /// The elements dated at or after `start`, sorted by date as above.
  func suffix(since start: Date, date: (Element) -> Date) -> SubSequence {
    self[firstIndex(atOrAfter: start, date: date)...]
  }
}

// MARK: - Samples

/// One reading of the radio's averaged noise floor.
struct NoiseSample: Equatable {
  let date: Date
  let dBm: Double
}

/// The radio's cumulative airtime counters at one moment. They count whole seconds since boot.
struct AirtimeSample: Equatable {
  let date: Date
  let tx: UInt32
  let rx: UInt32
}

// MARK: - Window

/// The time windows the channel chart offers, Cairn's 10s / 1m / 10m / 1h chips.
enum SpectrumWindow: Int, CaseIterable, Identifiable {
  case tenSeconds
  case oneMinute
  case tenMinutes
  case oneHour

  var id: Int { rawValue }

  var duration: TimeInterval {
    switch self {
    case .tenSeconds: 10
    case .oneMinute: 60
    case .tenMinutes: 600
    case .oneHour: 3600
    }
  }

  /// Short chip label ("10s", "1m"), localized by the duration formatter.
  var shortTitle: String {
    Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
  }

  /// Spoken label ("10 seconds"), for VoiceOver and the chart summary.
  var spokenTitle: String {
    Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
  }

  /// Columns the min/avg/max band is drawn in. Never finer than the noise readings, taken every
  /// `readingInterval` seconds, so a short window draws each reading rather than empty columns
  /// between them.
  func bucketCount(readingInterval: TimeInterval) -> Int {
    min(60, max(1, Int(duration / max(1, readingInterval))))
  }

  /// How often the chart's time axis moves on.
  var refreshInterval: TimeInterval {
    duration <= 60 ? 1 : 5
  }

  /// Time columns the packet marks are thinned to, or nil to draw every packet. An hour can hold
  /// the full 2048 packets, each three marks, far more than the chart has points to show them
  /// in; a lane marker is never narrower than a 180th of the window anyway.
  var packetMarkColumns: Int? {
    duration > 60 ? 180 : nil
  }

  /// Figures over the window, but never over less than a minute: a 10 s window holds too few
  /// packets and airtime seconds to give a meaningful rate (Cairn's `STATS_MIN_MS`).
  var statsDuration: TimeInterval {
    max(duration, 60)
  }
}

// MARK: - Update rate

/// How often the Spectrum tab reads the radio's statistics while it's on screen (Spectrum
/// Settings). The firmware's floor is a running average that moves slowly, so Normal's 5 s loses
/// little on the chart and costs the radio and the Bluetooth link two-fifths the wakeups of Live,
/// which matches the firmware's own 2 s cadence. Packets arrive as heard at either rate.
enum SpectrumUpdateRate: Int, CaseIterable, Identifiable {
  case normal = 5
  case live = 2

  var id: Int { rawValue }

  var interval: TimeInterval { TimeInterval(rawValue) }

  var title: String {
    switch self {
    case .normal: L10n.Tools.Tools.Spectrum.Settings.Rate.normal
    case .live: L10n.Tools.Tools.Spectrum.Settings.Rate.live
    }
  }
}

/// The traffic table's row counts Spectrum Settings offers; the RX Log holds the rest.
enum SpectrumTrafficRows {
  static let options = [5, 8, 15]
}

// MARK: - Buckets

/// Noise readings gathered into equal time columns: the low, mean and high of each.
struct SpectrumBucket: Equatable, Identifiable {
  let index: Int
  let start: Date
  let end: Date
  let min: Double
  let avg: Double
  let max: Double
  let count: Int
  /// Buckets with a missing column between them belong to different segments, so the chart
  /// breaks its line across a gap (the app wasn't sampling) instead of bridging it.
  let segment: Int

  var id: Int { index }
  var mid: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
}

enum SpectrumBuckets {
  /// Splits `domain` into `count` equal columns and summarizes the samples in each. Columns with
  /// no sample are left out; samples outside `domain` are ignored. A run of empty columns starts a
  /// new segment (a break in the line) only when it spans more than `bridging` seconds: readings
  /// land a round trip later than the column width now and then, and history taken at a slower
  /// rate leaves every other column empty, neither of which is a real gap in the readings.
  static func bucket(
    _ samples: some Sequence<NoiseSample>,
    in domain: ClosedRange<Date>,
    count: Int,
    bridging: TimeInterval = 0
  ) -> [SpectrumBucket] {
    let count = max(1, count)
    let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
    guard span > 0 else { return [] }
    let width = span / Double(count)

    var sums = [Double](repeating: 0, count: count)
    var mins = [Double](repeating: .infinity, count: count)
    var maxs = [Double](repeating: -.infinity, count: count)
    var counts = [Int](repeating: 0, count: count)
    for sample in samples where domain.contains(sample.date) {
      let offset = sample.date.timeIntervalSince(domain.lowerBound)
      let index = min(count - 1, Int(offset / width))
      sums[index] += sample.dBm
      mins[index] = Swift.min(mins[index], sample.dBm)
      maxs[index] = Swift.max(maxs[index], sample.dBm)
      counts[index] += 1
    }

    var buckets: [SpectrumBucket] = []
    var segment = 0
    var previous: Int?
    for index in 0..<count where counts[index] > 0 {
      if let previous, Double(index - previous - 1) * width > bridging {
        segment += 1
      }
      previous = index
      let start = domain.lowerBound.addingTimeInterval(Double(index) * width)
      buckets.append(SpectrumBucket(
        index: index,
        start: start,
        end: start.addingTimeInterval(width),
        min: mins[index],
        avg: sums[index] / Double(counts[index]),
        max: maxs[index],
        count: counts[index],
        segment: segment
      ))
    }
    return buckets
  }

  /// As `bucket(_:in:count:bridging:)`, but on a grid fixed on the clock (cells `width` seconds
  /// long from the reference date) rather than on `domain`, so a reading keeps its cell as the
  /// window slides on and nothing drawn changes shape; and a cell with no reading holds the
  /// reading before it for up to `holding` seconds, as the floor itself stands until the next
  /// reading, so the band runs to the plot's edges. `samples` run in time order and may start
  /// before `domain` (the one held into its first cells).
  static func aligned(
    _ samples: some Sequence<NoiseSample>,
    in domain: ClosedRange<Date>,
    width: TimeInterval,
    bridging: TimeInterval,
    holding: TimeInterval
  ) -> [SpectrumBucket] {
    guard width > 0 else { return [] }
    let firstCell = Int64((domain.lowerBound.timeIntervalSinceReferenceDate / width).rounded(.down))
    let lastCell = Int64((domain.upperBound.timeIntervalSinceReferenceDate / width).rounded(.down))
    let count = Int(lastCell - firstCell + 1)
    guard count > 0, count <= 10_000 else { return [] }

    var sums = [Double](repeating: 0, count: count)
    var mins = [Double](repeating: .infinity, count: count)
    var maxs = [Double](repeating: -.infinity, count: count)
    var counts = [Int](repeating: 0, count: count)
    var last = [(date: Date, dBm: Double)?](repeating: nil, count: count)
    var before: (date: Date, dBm: Double)?
    for sample in samples where sample.date <= domain.upperBound {
      let cell = Int64((sample.date.timeIntervalSinceReferenceDate / width).rounded(.down))
      if cell < firstCell {
        before = (sample.date, sample.dBm)
        continue
      }
      let index = Int(cell - firstCell)
      guard index < count else { continue }
      sums[index] += sample.dBm
      mins[index] = Swift.min(mins[index], sample.dBm)
      maxs[index] = Swift.max(maxs[index], sample.dBm)
      counts[index] += 1
      last[index] = (sample.date, sample.dBm)
    }

    var buckets: [SpectrumBucket] = []
    var segment = 0
    var previous: Int?
    var held = before
    for index in 0..<count {
      let start = Date(timeIntervalSinceReferenceDate: Double(firstCell + Int64(index)) * width)
      let low: Double
      let high: Double
      let average: Double
      if counts[index] > 0 {
        low = mins[index]
        high = maxs[index]
        average = sums[index] / Double(counts[index])
        held = last[index]
      } else if let held, start.timeIntervalSince(held.date) <= holding {
        low = held.dBm
        high = held.dBm
        average = held.dBm
      } else {
        continue
      }
      if let previous, Double(index - previous - 1) * width > bridging {
        segment += 1
      }
      previous = index
      buckets.append(SpectrumBucket(
        index: index, start: start, end: start.addingTimeInterval(width),
        min: low, avg: average, max: high, count: counts[index], segment: segment
      ))
    }
    return buckets
  }
}

// MARK: - Figures

/// The numbers on the meter tiles, worked out from the history for one window.
enum SpectrumStats {
  /// The level Cairn scales against while the radio's floor is still uncalibrated
  /// (`spec::kNoFloorDbm`); shown with "≈" so it never passes for a measurement.
  static let uncalibratedFloor = -110.0
  /// The radio reports 0 until its floor has converged; Cairn takes a floor only under this
  /// (`nf != 0 && nf < -40`), so a stray reading near zero never passes for a measurement.
  static let maximumFloor = -40.0

  static func acceptsFloor(_ dBm: Double) -> Bool {
    dBm < maximumFloor
  }

  /// A packet this far above the floor reads as clear of the noise (Cairn's MARGIN in green, and
  /// its busy rule: a reading above NF + 6 is a signal, not noise).
  static let clearMargin = 6.0
  /// Airtime shares above these read as heavy and very heavy use, in the warning and the critical
  /// color (Cairn's BUSY limits). Not "busy": on the radio, BUSY is the time spent above the floor,
  /// which the app can't measure yet.
  static let heavyUse = 0.30
  static let veryHeavyUse = 0.60
  /// The airtime counters tick in whole seconds; under this much elapsed time a share means little.
  static let minimumAirtimeSpan: TimeInterval = 30

  /// How far the latest packet arrived above the floor (Cairn: NOW − FLOOR), against the
  /// uncalibrated stand-in when the radio hasn't settled its floor yet.
  static func margin(packetRSSI: Double?, floor: Double?) -> Double? {
    packetRSSI.map { $0 - (floor ?? uncalibratedFloor) }
  }

  /// The strongest packet that arrived inside the window. `packets` are in time order.
  static func peak<Packets: RandomAccessCollection>(_ packets: Packets, since start: Date) -> Double?
    where Packets.Element == SpectrumPacket, Packets.Index == Int {
    packets.suffix(since: start, date: \.date).lazy.compactMap(\.rssi).max()
  }

  /// Packets per minute over the window, counted only over the time something was listening:
  /// a radio connected two minutes ago hasn't had an hour of silence (Cairn counts over the
  /// seconds its history covers). Never over less than a minute.
  static func packetsPerMinute(count: Int, window: TimeInterval, observedSince: Date?, now: Date) -> Double? {
    guard let observedSince else { return nil }
    let covered = min(window, max(0, now.timeIntervalSince(observedSince)))
    return Double(count) / (max(covered, 60) / 60)
  }

  /// Share of time spent receiving and transmitting over the window, from the counters the
  /// radio reports. Measured from the oldest sample inside the window back to the newest; a
  /// counter that went backwards is a reboot, so only samples since then count.
  static func airtimeShare(_ samples: [AirtimeSample], window: TimeInterval, now: Date) -> (rx: Double, tx: Double)? {
    guard let latest = samples.last else { return nil }
    let start = now.addingTimeInterval(-window)
    var baseline: AirtimeSample?
    for sample in samples.reversed() {
      if sample.rx > latest.rx || sample.tx > latest.tx { break }
      if sample.date < start { break }
      if let current = baseline, sample.rx > current.rx || sample.tx > current.tx { break }
      baseline = sample
    }
    guard let baseline else { return nil }
    let elapsed = latest.date.timeIntervalSince(baseline.date)
    guard elapsed >= minimumAirtimeSpan else { return nil }
    let rx = min(1, Double(latest.rx - baseline.rx) / elapsed)
    let tx = min(1, Double(latest.tx - baseline.tx) / elapsed)
    return (rx, tx)
  }

  enum Load: Equatable {
    case normal
    case heavy
    case veryHeavy

    init(share: Double) {
      if share > SpectrumStats.veryHeavyUse {
        self = .veryHeavy
      } else if share > SpectrumStats.heavyUse {
        self = .heavy
      } else {
        self = .normal
      }
    }

    /// The AIR tile's words, beside the warning glyph: how much the channel is used, not "busy".
    var title: String? {
      switch self {
      case .normal: nil
      case .heavy: L10n.Tools.Tools.Spectrum.Meter.heavyUse
      case .veryHeavy: L10n.Tools.Tools.Spectrum.Meter.veryHeavyUse
      }
    }

    var color: Color? {
      switch self {
      case .normal: nil
      case .heavy: SpectrumPalette.warning
      case .veryHeavy: SpectrumPalette.critical
      }
    }
  }
}

// MARK: - Scale

/// The chart's dB scale, Cairn's trace's (`spec::scaleLo`, `spec::scaleLoHold`): 56 dB up from 8
/// below the floor rounded down to an even dB, held while the floor only jitters so the trace
/// doesn't hop with every reading, and gridlines every 12 dB.
enum SpectrumTraceScale {
  static let belowFloor = 8.0
  static let span = 56.0
  /// The held bottom moves once the new one is this far from it (`spec::kScaleHoldDb`).
  static let hold = 6.0
  static let gridStep = 12.0
  /// Room left over a packet above the scale's top, so its dot isn't cut in half.
  static let peakHeadroom = 2.0

  /// The bottom for `floor` (Cairn's stand-in while uncalibrated): 8 below it, rounded down to an
  /// even dB.
  static func bottom(floor: Double?) -> Double {
    (((floor ?? SpectrumStats.uncalibratedFloor) - belowFloor) / 2).rounded(.down) * 2
  }

  /// The bottom to draw from: `previous` until the floor's own bottom is 6 dB or more away from
  /// it, then that one. No previous bottom takes the floor's.
  static func heldBottom(previous: Double?, floor: Double?) -> Double {
    let target = bottom(floor: floor)
    guard let previous else { return target }
    return abs(target - previous) >= hold ? target : previous
  }

  /// 56 dB up from `bottom`; raised only when a packet stands above that, and then just enough
  /// to keep it on the chart.
  static func domain(bottom: Double, peak: Double?) -> ClosedRange<Double> {
    var top = bottom + span
    if let peak, peak + peakHeadroom > top {
      top = ((peak + peakHeadroom) / 2).rounded(.up) * 2
    }
    return bottom...top
  }

  /// The gridlines inside `domain`, every 12 dB on whole multiples of 12 dBm as on Cairn's trace
  /// (-108, -96, …), so the labels read the same on the radio and the app.
  static func gridlines(in domain: ClosedRange<Double>) -> [Double] {
    let first = (domain.lowerBound / gridStep).rounded(.up) * gridStep
    // below the top edge, as the radio's loop stops at lo + H - 1 (no line on the frame itself)
    return Array(stride(from: first, to: domain.upperBound, by: gridStep))
  }
}

// MARK: - Packets

/// What kind of packet the radio heard, from the header's payload type (Cairn's TYPE column).
enum SpectrumPacketKind: CaseIterable, Equatable {
  case request
  case response
  case message
  case ack
  case advert
  case groupText
  case groupData
  case anonRequest
  case path
  case trace
  case multipart
  case control
  case raw
  case unknown

  init(_ type: PayloadType) {
    self = switch type {
    case .request: .request
    case .response: .response
    case .textMessage: .message
    case .ack: .ack
    case .advert: .advert
    case .groupText: .groupText
    case .groupData: .groupData
    case .anonRequest: .anonRequest
    case .path: .path
    case .trace: .trace
    case .multipart: .multipart
    case .control: .control
    case .rawCustom: .raw
    case .unknown: .unknown
    }
  }

  /// Cairn's three-letter code. Protocol shorthand, the same in every language, so it isn't
  /// localized; `title` is the readable name VoiceOver and the detail use.
  var code: String {
    switch self {
    case .request: "REQ"
    case .response: "RSP"
    case .message: "MSG"
    case .ack: "ACK"
    case .advert: "ADV"
    case .groupText: "GTX"
    case .groupData: "GDA"
    case .anonRequest: "ANQ"
    case .path: "PTH"
    case .trace: "TRC"
    case .multipart: "MPT"
    case .control: "CTL"
    case .raw: "RAW"
    case .unknown: "?"
    }
  }

  var title: String {
    switch self {
    case .request: L10n.Tools.Tools.Spectrum.Kind.request
    case .response: L10n.Tools.Tools.Spectrum.Kind.response
    case .message: L10n.Tools.Tools.Spectrum.Kind.message
    case .ack: L10n.Tools.Tools.Spectrum.Kind.ack
    case .advert: L10n.Tools.Tools.Spectrum.Kind.advert
    case .groupText: L10n.Tools.Tools.Spectrum.Kind.groupText
    case .groupData: L10n.Tools.Tools.Spectrum.Kind.groupData
    case .anonRequest: L10n.Tools.Tools.Spectrum.Kind.anonRequest
    case .path: L10n.Tools.Tools.Spectrum.Kind.path
    case .trace: L10n.Tools.Tools.Spectrum.Kind.trace
    case .multipart: L10n.Tools.Tools.Spectrum.Kind.multipart
    case .control: L10n.Tools.Tools.Spectrum.Kind.control
    case .raw: L10n.Tools.Tools.Spectrum.Kind.raw
    case .unknown: L10n.Tools.Tools.Spectrum.Kind.unknown
    }
  }

  /// Cairn's type colors (`RadioMeters.cpp` `typeColour`): messages LINK blue, acks TEXT2 grey,
  /// adverts MAGENTA, channel traffic OK green, paths VIOLET, traces WARN amber, control and raw
  /// quiet (TEXT3, the system's tertiary label), the rest plain text.
  var color: Color {
    switch self {
    case .message: SpectrumPalette.link
    case .ack: SpectrumPalette.text2
    case .advert: SpectrumPalette.magenta
    case .groupText, .groupData: SpectrumPalette.good
    case .path: SpectrumPalette.violet
    case .trace: SpectrumPalette.warning
    case .control, .raw: Color(.tertiaryLabel)
    case .request, .response, .anonRequest, .multipart, .unknown: .primary
    }
  }

  /// The kinds the legend names, in the order Cairn's mockup lists them.
  static let legendOrder: [SpectrumPacketKind] = [.advert, .message, .groupText, .ack, .trace, .path]
}

/// One received packet as the Spectrum tab shows it, backed by its RX log entry.
struct SpectrumPacket: Identifiable, Equatable {
  let entry: RxLogEntryDTO

  var id: UUID { entry.id }
  var date: Date { entry.receivedAt }
  var kind: SpectrumPacketKind { SpectrumPacketKind(entry.payloadType) }
  var rssi: Double? { entry.rssi.map(Double.init) }
  var snr: Double? { entry.snr }
  var size: Int { entry.rawPayload.count }
  var isFlood: Bool { entry.isFlood }
  var hops: Int { entry.hopCount }

  /// "Flood 2", "Direct", or "Direct 3" for a direct packet still carrying its route ahead.
  var routeTitle: String {
    if isFlood { return L10n.Tools.Tools.Spectrum.Route.flood(hops) }
    return hops > 0 ? L10n.Tools.Tools.Spectrum.Route.directHops(hops) : L10n.Tools.Tools.RxLog.direct
  }

  /// Who the packet is from, to, or for (Cairn's third card line), each node named as the RX Log
  /// list names it from `nodes`, the packet resolved as the list resolves it: "from Bob → You", "from Hill · via
  /// RPT-Hill", "#Public · via RPT-Hill". A relay no node heard on the channel has reads as its
  /// hash, one of several as the likeliest's name with a "?". Nil when the type carries no address
  /// the app can read.
  func party(_ nodes: PacketNodes) -> String? {
    // A flood's newest hop handed it to us; a direct packet's path is the route still ahead, so
    // it says nothing about where the packet came from.
    var via: String?
    if isFlood, hops > 0, case .hop? = nodes.transmitter, let relay = nodes.transmitterNode {
      via = L10n.Tools.Tools.Spectrum.Party.via(Self.name(of: relay))
    }

    var who: String?
    switch entry.payloadType {
    case .advert:
      if let sender = nodes.sender {
        who = L10n.Tools.Tools.Spectrum.Party.from(Self.name(of: sender))
      }
    case .textMessage:
      if let sender = nodes.sender, let recipient = nodes.recipient {
        who = L10n.Tools.Tools.Spectrum.Party.fromTo(Self.name(of: sender), Self.name(of: recipient))
      }
    case .groupText, .groupData:
      if let channel = entry.channelName {
        who = channel
      } else if let hash = entry.packetPayload.first {
        who = L10n.Tools.Tools.Spectrum.Party.channel(String(format: "%02X", hash))
      }
    default:
      break
    }

    let parts = [who, via].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// A node as the RX Log list names it: "You" for this radio, else the resolver's name, its hash
  /// in hex when it has none.
  private static func name(of node: PacketNode) -> String {
    node.isRadio ? L10n.Tools.Tools.RxLog.pathYou : node.displayName ?? node.hash.uppercaseHexString()
  }

  /// Who a packet is addressed to, named as ``name(of:)`` names a node.
  private static func name(of match: PacketNodeMatch) -> String {
    name(of: PacketNode(role: .sender(.peerHash), hash: Data(), match: match))
  }
}

/// The packets the chart draws on its long windows.
enum SpectrumPacketMarks {
  private struct Slot: Hashable {
    let column: Int
    let kind: SpectrumPacketKind
  }

  /// Thins `packets` to what the chart can show: in each of `columns` equal time columns, the
  /// strongest packet of each kind, so the lane keeps every color it would have drawn and the
  /// dots keep their highs. The packet `keeping` names stays wherever it falls, so a selection
  /// never vanishes. `packets` are in time order inside `domain`; the result keeps that order.
  static func thin(
    _ packets: [SpectrumPacket],
    in domain: ClosedRange<Date>,
    columns: Int,
    keeping keptID: UUID? = nil
  ) -> [SpectrumPacket] {
    let columns = max(1, columns)
    let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
    guard span > 0, packets.count > columns else { return packets }
    let width = span / Double(columns)

    var best: [Slot: Int] = [:]
    var kept: Int?
    for (index, packet) in packets.enumerated() {
      if packet.id == keptID { kept = index }
      let offset = packet.date.timeIntervalSince(domain.lowerBound)
      let slot = Slot(column: min(columns - 1, max(0, Int(offset / width))), kind: packet.kind)
      // Ties and packets without a reading go to the newer one, as the chart's selection does.
      if let current = best[slot], (packets[current].rssi ?? -.infinity) > (packet.rssi ?? -.infinity) {
        continue
      }
      best[slot] = index
    }
    var indices = Set(best.values)
    if let kept { indices.insert(kept) }
    return indices.sorted().map { packets[$0] }
  }
}

/// Signal strings in Cairn's terse style.
enum SpectrumPacketFormat {
  /// SNR to the radio's quarter-dB precision: "6.25", "-4.5".
  static func snr(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
  }

  /// "12s", "4m", "2h": one unit, the narrow style, for the traffic table's AGE column.
  static func age(_ seconds: TimeInterval) -> String {
    let seconds = max(0, seconds.rounded(.down))
    let allowed: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : (seconds < 3600 ? [.minutes] : [.hours, .days])
    return Duration.seconds(seconds).formatted(.units(allowed: allowed, width: .narrow, maximumUnitCount: 1, fractionalPart: .hide(rounded: .down)))
  }
}
