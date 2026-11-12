import Foundation
@testable import Cairn
import CairnServices
@testable import MeshCore
import SwiftUI
import Testing
import UIKit

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.05) -> Bool { abs(a - b) <= tolerance }

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// A color as 0xRRGGBB in the light or the dark scheme.
private func hex(_ color: Color, dark: Bool) -> Int {
  let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
  var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
  resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
  return [red, green, blue].reduce(0) { $0 << 8 | Int(($1 * 255).rounded()) }
}

private func packet(
  _ type: PayloadType = .advert,
  route: RouteType = .flood,
  rssi: Int? = -90,
  snr: Double? = 6.25,
  path: [UInt8] = [],
  payload: [UInt8] = [0x01, 0x02],
  at date: Date = epoch,
  channelName: String? = nil
) -> SpectrumPacket {
  let parsed = ParsedRxLogData(
    snr: snr,
    rssi: rssi,
    rawPayload: Data(payload + path + [0, 0]),
    routeType: route,
    payloadType: type,
    payloadVersion: 0,
    payloadTypeBits: type.rawValue,
    transportCode: nil,
    pathLength: UInt8(path.count),
    pathNodes: path,
    packetPayload: Data(payload)
  )
  return SpectrumPacket(entry: RxLogEntryDTO(
    radioID: UUID(),
    receivedAt: date,
    from: parsed,
    channelName: channelName
  ))
}

// MARK: - LoRa figures

@Suite("Spectrum LoRa figures")
struct SpectrumLoRaTests {
  /// SF10 / 250 kHz / CR 4/5, a common MeshCore preset.
  private let channel = LoRaChannelMath(frequencyHz: 910_525_000, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5)

  @Test
  func `thermal noise follows kTB and the noise figure`() {
    #expect(near(channel.thermalNoiseFloor, -114.02))
    #expect(channel.desensitization(noiseFloor: -120) == 0)
    #expect(near(channel.desensitization(noiseFloor: -104.02), 9.98))
  }

  @Test
  func `airtime matches Cairn's hint for the same settings`() {
    // Cairn's Radio page on SF7 / 62.5 kHz / CR5 reads "~214 ms / 40B pkt".
    let fast = LoRaChannelMath(frequencyHz: 910_525_000, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)
    #expect(near(fast.timeOnAir(payloadBytes: LoRaChannelMath.airtimeHintBytes) * 1000, 213.5, 0.1))
    // (16 preamble + 4.25 + 73 payload symbols) × 4.096 ms
    #expect(near(channel.timeOnAir(payloadBytes: 64), 0.38195, 0.0005))
  }

  @Test
  func `low data rate optimisation starts at a 16 ms symbol, as on the radio`() {
    // SF11 / 125 kHz: a 16.384 ms symbol, so the optimisation is on.
    let slow = LoRaChannelMath(frequencyHz: 869_525_000, bandwidthHz: 125_000, spreadingFactor: 11, codingRate: 5)
    #expect(slow.symbolDuration >= 0.016)
    // 8·40 − 44 + 44 = 320 over 4·(11 − 2) = 36 → 9 blocks of 5 symbols, + 8; preamble 16 + 4.25.
    #expect(near(slow.timeOnAir(payloadBytes: 40), (16 + 4.25 + 8 + 45) * 0.016384, 0.0001))
  }

  @Test
  func `low spreading factors use the longer MeshCore preamble`() {
    let fast = LoRaChannelMath(frequencyHz: 869_525_000, bandwidthHz: 62_500, spreadingFactor: 8, codingRate: 8)
    #expect(fast.preambleSymbols == 32)
    #expect(channel.preambleSymbols == 16)
  }

  @Test(arguments: [(0, ChannelCondition.quiet), (2.9, .quiet), (3, .someInterference), (9.9, .someInterference), (10, .heavyInterference)])
  func `channel condition follows sensitivity lost to interference`(desensitization: Double, expected: ChannelCondition) {
    #expect(ChannelCondition(desensitization: desensitization) == expected)
  }

  @Test
  func `thermal noise is rounded to a whole dB before the condition, as on Cairn`() {
    // 62.5 kHz: thermal noise is -120.04 dBm, which Cairn's spec::thermalDbm rounds to -120.
    let narrow = LoRaChannelMath(frequencyHz: 910_525_000, bandwidthHz: 62_500, spreadingFactor: 7, codingRate: 5)
    #expect(narrow.desensitization(noiseFloor: -117) == 3)
    #expect(ChannelCondition(desensitization: narrow.desensitization(noiseFloor: -117)) == .someInterference)
    #expect(ChannelCondition(desensitization: narrow.desensitization(noiseFloor: -118)) == .quiet)
    #expect(ChannelCondition(desensitization: narrow.desensitization(noiseFloor: -110)) == .heavyInterference)
    #expect(ChannelCondition(desensitization: narrow.desensitization(noiseFloor: -111)) == .someInterference)
    // 250 kHz: -114.02 rounds to -114.
    #expect(channel.desensitization(noiseFloor: -104) == 10)
  }
}

// MARK: - Ring buffer

@Suite("Spectrum ring buffer")
struct SpectrumRingBufferTests {
  @Test
  func `the window start is found by date in sorted history`() {
    let dates = [0.0, 2, 2, 5, 9].map { epoch.addingTimeInterval($0) }
    #expect(dates.firstIndex(atOrAfter: epoch.addingTimeInterval(-1), date: { $0 }) == 0)
    #expect(dates.firstIndex(atOrAfter: epoch.addingTimeInterval(2), date: { $0 }) == 1)
    #expect(dates.firstIndex(atOrAfter: epoch.addingTimeInterval(3), date: { $0 }) == 3)
    #expect(dates.firstIndex(atOrAfter: epoch.addingTimeInterval(10), date: { $0 }) == 5)
    #expect(Array(dates.suffix(since: epoch.addingTimeInterval(5), date: { $0 })) == Array(dates.suffix(2)))
    #expect([Date]().firstIndex(atOrAfter: epoch, date: { $0 }) == 0)
  }

  @Test
  func `fills in order, then drops the oldest`() {
    var ring = RingBuffer<Int>(capacity: 3)
    #expect(ring.isEmpty)
    #expect(ring.first == nil)
    #expect(ring.last == nil)
    ring.append(1)
    ring.append(2)
    #expect(ring.elements == [1, 2])
    ring.append(3)
    ring.append(4)
    ring.append(5)
    #expect(ring.count == 3)
    #expect(ring.elements == [3, 4, 5])
    #expect(ring.first == 3)
    #expect(ring.last == 5)
  }

  @Test
  func `clearing starts over from empty`() {
    var ring = RingBuffer<Int>(capacity: 2)
    for value in 1...5 { ring.append(value) }
    ring.removeAll()
    #expect(ring.isEmpty)
    ring.append(9)
    #expect(ring.elements == [9])
    #expect(ring.last == 9)
  }

  @Test
  func `a capacity below one still holds the newest element`() {
    var ring = RingBuffer<Int>(capacity: 0)
    ring.append(1)
    ring.append(2)
    #expect(ring.elements == [2])
  }
}

// MARK: - Windows and buckets

@Suite("Spectrum windows")
struct SpectrumWindowTests {
  @Test
  func `windows are Cairn's 10s, 1m, 10m and 1h`() {
    #expect(SpectrumWindow.allCases.map(\.duration) == [10, 60, 600, 3600])
  }

  @Test
  func `short windows draw each reading, long ones sixty columns`() {
    #expect(SpectrumWindow.tenSeconds.bucketCount(readingInterval: 5) == 2)
    #expect(SpectrumWindow.oneMinute.bucketCount(readingInterval: 5) == 12)
    #expect(SpectrumWindow.tenMinutes.bucketCount(readingInterval: 5) == 60)
    #expect(SpectrumWindow.oneHour.bucketCount(readingInterval: 5) == 60)
  }

  @Test
  func `the live rate draws a column per reading on the short windows`() {
    #expect(SpectrumWindow.tenSeconds.bucketCount(readingInterval: SpectrumUpdateRate.live.interval) == 5)
    #expect(SpectrumWindow.oneMinute.bucketCount(readingInterval: SpectrumUpdateRate.live.interval) == 30)
    #expect(SpectrumWindow.oneHour.bucketCount(readingInterval: SpectrumUpdateRate.live.interval) == 60)
  }

  @Test
  func `update rates read every 5 and 2 seconds, Normal by default`() {
    #expect(SpectrumUpdateRate.normal.interval == 5)
    #expect(SpectrumUpdateRate.live.interval == 2)
    #expect(SpectrumUpdateRate(rawValue: AppStorageKey.defaultSpectrumUpdateRate) == .normal)
    #expect(SpectrumWindow(rawValue: AppStorageKey.defaultSpectrumWindow) == .oneMinute)
    #expect(SpectrumTrafficRows.options.contains(AppStorageKey.defaultSpectrumTrafficRows))
  }

  @Test @MainActor
  func `the view model starts at the normal rate and takes a new one`() {
    let model = SpectrumViewModel()
    #expect(model.readingInterval == SpectrumUpdateRate.normal.interval)
    model.readingInterval = SpectrumUpdateRate.live.interval
    #expect(model.readingInterval == 2)
  }

  @Test
  func `only the long windows thin their packet marks`() {
    #expect(SpectrumWindow.tenSeconds.packetMarkColumns == nil)
    #expect(SpectrumWindow.oneMinute.packetMarkColumns == nil)
    #expect(SpectrumWindow.tenMinutes.packetMarkColumns == 180)
    #expect(SpectrumWindow.oneHour.packetMarkColumns == 180)
  }

  @Test
  func `figures never cover less than a minute`() {
    #expect(SpectrumWindow.tenSeconds.statsDuration == 60)
    #expect(SpectrumWindow.oneMinute.statsDuration == 60)
    #expect(SpectrumWindow.oneHour.statsDuration == 3600)
  }
}

@Suite("Spectrum buckets")
struct SpectrumBucketTests {
  private let domain = epoch...epoch.addingTimeInterval(60)

  private func sample(_ offset: TimeInterval, _ dBm: Double) -> NoiseSample {
    NoiseSample(date: epoch.addingTimeInterval(offset), dBm: dBm)
  }

  @Test
  func `each column keeps its low, mean and high`() throws {
    let buckets = SpectrumBuckets.bucket([sample(1, -110), sample(5, -106), sample(9, -108)], in: domain, count: 6)
    let first = try #require(buckets.first)
    #expect(buckets.count == 1)
    #expect(first.index == 0)
    #expect(first.min == -110)
    #expect(first.max == -106)
    #expect(first.avg == -108)
    #expect(first.count == 3)
    #expect(first.start == epoch)
    #expect(first.end == epoch.addingTimeInterval(10))
  }

  @Test
  func `empty columns are left out and split the line into segments`() {
    let buckets = SpectrumBuckets.bucket(
      [sample(1, -110), sample(12, -109), sample(45, -108)],
      in: domain,
      count: 6
    )
    #expect(buckets.map(\.index) == [0, 1, 4])
    #expect(buckets.map(\.segment) == [0, 0, 1])
  }

  @Test
  func `short runs of empty columns are bridged rather than split`() {
    // Readings 5 s apart in 2 s columns, as after switching from Normal to Live: every other
    // column or two is empty, but the line is one segment.
    let samples = stride(from: 0.5, to: 60, by: 5).map { sample($0, -110) }
    let bridged = SpectrumBuckets.bucket(samples, in: domain, count: 30, bridging: 5)
    #expect(Set(bridged.map(\.segment)) == [0])
    // A gap longer than the bridge still breaks the line.
    let broken = SpectrumBuckets.bucket([sample(1, -110), sample(45, -108)], in: domain, count: 30, bridging: 5)
    #expect(broken.map(\.segment) == [0, 1])
  }

  @Test
  func `readings outside the window are ignored and the end lands in the last column`() {
    let buckets = SpectrumBuckets.bucket(
      [sample(-5, -100), sample(60, -111), sample(90, -100)],
      in: domain,
      count: 6
    )
    #expect(buckets.map(\.index) == [5])
    #expect(buckets.first?.avg == -111)
  }

  @Test
  func `an empty window gives no columns`() {
    #expect(SpectrumBuckets.bucket([sample(1, -110)], in: epoch...epoch, count: 6).isEmpty)
  }
}

// MARK: - Packet marks

@Suite("Spectrum packet marks")
struct SpectrumPacketMarkTests {
  private let domain = epoch...epoch.addingTimeInterval(60)

  @Test
  func `each column keeps the strongest packet of each kind, in time order`() {
    let weakAdvert = packet(.advert, rssi: -100, at: epoch.addingTimeInterval(1))
    let strongAdvert = packet(.advert, rssi: -70, at: epoch.addingTimeInterval(2))
    let ack = packet(.ack, rssi: -110, at: epoch.addingTimeInterval(3))
    let later = packet(.advert, rssi: -95, at: epoch.addingTimeInterval(40))
    let thinned = SpectrumPacketMarks.thin([weakAdvert, strongAdvert, ack, later], in: domain, columns: 3)
    #expect(thinned.map(\.id) == [strongAdvert.id, ack.id, later.id])
  }

  @Test
  func `the selected packet is always kept, and few packets pass through untouched`() {
    let selected = packet(.advert, rssi: -100, at: epoch.addingTimeInterval(1))
    let stronger = packet(.advert, rssi: -70, at: epoch.addingTimeInterval(2))
    let filler = packet(.ack, at: epoch.addingTimeInterval(50))
    let thinned = SpectrumPacketMarks.thin([selected, stronger, filler], in: domain, columns: 2, keeping: selected.id)
    #expect(thinned.map(\.id) == [selected.id, stronger.id, filler.id])
    let few = [selected, stronger]
    #expect(SpectrumPacketMarks.thin(few, in: domain, columns: 2).map(\.id) == few.map(\.id))
  }
}

// MARK: - Figures

@Suite("Spectrum figures")
struct SpectrumStatsTests {
  @Test
  func `margin is the last packet above the floor, against Cairn's stand-in while uncalibrated`() {
    #expect(SpectrumStats.margin(packetRSSI: -98, floor: -112) == 14)
    #expect(SpectrumStats.margin(packetRSSI: -98, floor: nil) == 12)
    #expect(SpectrumStats.margin(packetRSSI: nil, floor: -112) == nil)
  }

  @Test
  func `peak is the strongest packet inside the window`() {
    let packets = [
      packet(rssi: -60, at: epoch.addingTimeInterval(-120)),
      packet(rssi: -91, at: epoch.addingTimeInterval(-30)),
      packet(rssi: nil, at: epoch.addingTimeInterval(-20)),
      packet(rssi: -75, at: epoch.addingTimeInterval(-10)),
    ]
    #expect(SpectrumStats.peak(packets, since: epoch.addingTimeInterval(-60)) == -75)
    #expect(SpectrumStats.peak(packets, since: epoch) == nil)
  }

  @Test
  func `packet rate counts only the time something was listening, never under a minute`() {
    // An hour's window, but listening for only ten minutes: 20 packets is 2 a minute.
    let rate = SpectrumStats.packetsPerMinute(count: 20, window: 3600, observedSince: epoch.addingTimeInterval(-600), now: epoch)
    #expect(rate == 2)
    // Ten seconds of listening still counts as a minute.
    #expect(SpectrumStats.packetsPerMinute(count: 3, window: 60, observedSince: epoch.addingTimeInterval(-10), now: epoch) == 3)
    // Listening for longer than the window: the window is the span.
    #expect(SpectrumStats.packetsPerMinute(count: 30, window: 600, observedSince: .distantPast, now: epoch) == 3)
    #expect(SpectrumStats.packetsPerMinute(count: 3, window: 60, observedSince: nil, now: epoch) == nil)
  }

  private func air(_ offset: TimeInterval, tx: UInt32, rx: UInt32) -> AirtimeSample {
    AirtimeSample(date: epoch.addingTimeInterval(offset), tx: tx, rx: rx)
  }

  @Test
  func `airtime share comes from the counters inside the window`() throws {
    let samples = [air(-300, tx: 0, rx: 0), air(-60, tx: 100, rx: 1000), air(0, tx: 106, rx: 1030)]
    let share = try #require(SpectrumStats.airtimeShare(samples, window: 60, now: epoch))
    #expect(share.rx == 0.5)
    #expect(share.tx == 0.1)
  }

  @Test
  func `counters that went backwards mean a reboot, so only later samples count`() throws {
    let samples = [air(-120, tx: 50, rx: 5000), air(-60, tx: 0, rx: 3), air(0, tx: 0, rx: 9)]
    let share = try #require(SpectrumStats.airtimeShare(samples, window: 600, now: epoch))
    #expect(share.rx == 0.1)
    #expect(share.tx == 0)
  }

  @Test
  func `too short a span gives no share yet, and a share never exceeds all of the time`() throws {
    #expect(SpectrumStats.airtimeShare([air(-10, tx: 0, rx: 0), air(0, tx: 1, rx: 1)], window: 60, now: epoch) == nil)
    #expect(SpectrumStats.airtimeShare([], window: 60, now: epoch) == nil)
    let share = try #require(SpectrumStats.airtimeShare([air(-60, tx: 0, rx: 0), air(0, tx: 0, rx: 90)], window: 60, now: epoch))
    #expect(share.rx == 1)
  }

  @Test(arguments: [(0.0, SpectrumStats.Load.normal), (0.30, .normal), (0.31, .heavy), (0.60, .heavy), (0.61, .veryHeavy)])
  func `load follows Cairn's airtime limits`(share: Double, expected: SpectrumStats.Load) {
    #expect(SpectrumStats.Load(share: share) == expected)
  }

  @Test
  func `the air caption says how heavy the use is, never busy`() {
    #expect(SpectrumStats.Load.normal.title == nil)
    #expect(SpectrumStats.Load.normal.color == nil)
    #expect(SpectrumStats.Load.heavy.title == L10n.Tools.Tools.Spectrum.Meter.heavyUse)
    #expect(SpectrumStats.Load.heavy.color == SpectrumPalette.warning)
    #expect(SpectrumStats.Load.veryHeavy.title == L10n.Tools.Tools.Spectrum.Meter.veryHeavyUse)
    #expect(SpectrumStats.Load.veryHeavy.color == SpectrumPalette.critical)
    // "Busy" is the radio's time above the floor, which the app doesn't measure.
    for load in [SpectrumStats.Load.heavy, .veryHeavy] {
      #expect(load.title?.localizedCaseInsensitiveContains("busy") == false)
      #expect(load.title?.localizedCaseInsensitiveContains("congested") == false)
    }
  }

  @Test
  func `a floor counts only under -40 dBm, as on Cairn`() {
    #expect(SpectrumStats.acceptsFloor(-112))
    #expect(SpectrumStats.acceptsFloor(-41))
    #expect(!SpectrumStats.acceptsFloor(-40))
    #expect(!SpectrumStats.acceptsFloor(-12))
    #expect(!SpectrumStats.acceptsFloor(0))
  }
}

// MARK: - Levels and colors

@Suite("Spectrum levels")
struct SpectrumLevelTests {
  @Test(arguments: [
    (-20.0, SpectrumLevel.noise), (0, .noise), (5.9, .noise), (6, .signal), (19.9, .signal),
    (20, .strong), (34.9, .strong), (35, .veryStrong), (70, .veryStrong),
  ])
  func `levels over the floor follow Cairn's classes, each edge in the class above`(dB: Double, expected: SpectrumLevel) {
    #expect(SpectrumLevel(dBAboveFloor: dB) == expected)
  }

  @Test
  func `a level is taken over the floor, or Cairn's stand-in while uncalibrated`() {
    #expect(SpectrumLevel(rssi: -100, floor: -112) == .signal)
    #expect(SpectrumLevel(rssi: -107, floor: -112) == .noise)
    #expect(SpectrumLevel(rssi: -90, floor: nil) == .strong)
    #expect(SpectrumLevel(rssi: -75, floor: nil) == .veryStrong)
  }

  @Test
  func `noise keeps the text color, then teal, amber and red`() {
    #expect(SpectrumLevel.noise.color == nil)
    #expect(SpectrumLevel.signal.color == SpectrumPalette.noise)
    #expect(SpectrumLevel.strong.color == SpectrumPalette.warning)
    #expect(SpectrumLevel.veryStrong.color == SpectrumPalette.critical)
  }

  @Test
  func `status colors are Cairn's, in each scheme`() {
    #expect(hex(SpectrumPalette.good, dark: true) == 0x53C06B)
    #expect(hex(SpectrumPalette.warning, dark: true) == 0xE8A33D)
    #expect(hex(SpectrumPalette.critical, dark: true) == 0xE05544)
    #expect(hex(SpectrumPalette.good, dark: false) == 0x237A3A)
    #expect(hex(SpectrumPalette.warning, dark: false) == 0xA35F00)
    #expect(hex(SpectrumPalette.critical, dark: false) == 0xC0301F)
    #expect(hex(SpectrumPalette.noise, dark: true) == 0x15B6A6)
    // One amber: the peak line is the warning color.
    #expect(SpectrumPalette.peak == SpectrumPalette.warning)
  }

  @Test
  func `packet types wear Cairn's type colors`() {
    #expect(hex(SpectrumPacketKind.message.color, dark: true) == 0x4F9DF7)
    #expect(hex(SpectrumPacketKind.message.color, dark: false) == 0x1A62C2)
    #expect(hex(SpectrumPacketKind.advert.color, dark: true) == 0xE072B0)
    #expect(hex(SpectrumPacketKind.path.color, dark: true) == 0xA784E0)
    #expect(hex(SpectrumPacketKind.ack.color, dark: true) == 0x828891)
    #expect(SpectrumPacketKind.trace.color == SpectrumPalette.warning)
    #expect(SpectrumPacketKind.groupText.color == SpectrumPalette.good)
  }
}

// MARK: - Scale

@Suite("Spectrum scale")
struct SpectrumScaleTests {
  @Test
  func `the bottom is 8 below the floor, rounded down to an even dB`() {
    #expect(SpectrumTraceScale.bottom(floor: -112) == -120)
    #expect(SpectrumTraceScale.bottom(floor: -109) == -118)
    #expect(SpectrumTraceScale.bottom(floor: -100) == -108)
    // Uncalibrated: Cairn's -110 stand-in.
    #expect(SpectrumTraceScale.bottom(floor: nil) == -118)
  }

  @Test
  func `the bottom holds until the floor's own moves 6 dB`() {
    #expect(SpectrumTraceScale.heldBottom(previous: nil, floor: -112) == -120)
    // -107 wants -116: 4 dB away, held.
    #expect(SpectrumTraceScale.heldBottom(previous: -120, floor: -107) == -120)
    #expect(SpectrumTraceScale.heldBottom(previous: -120, floor: -115) == -120)
    // -106 wants -114, 6 dB away: it moves.
    #expect(SpectrumTraceScale.heldBottom(previous: -120, floor: -106) == -114)
    #expect(SpectrumTraceScale.heldBottom(previous: -120, floor: -118) == -126)
  }

  @Test
  func `the scale spans 56 dB and rises only for a packet above it`() {
    #expect(SpectrumTraceScale.domain(bottom: -120, peak: nil) == -120...(-64))
    // A strong packet inside the span changes nothing: no stretch for headroom.
    #expect(SpectrumTraceScale.domain(bottom: -120, peak: -67) == -120...(-64))
    // One above it raises the top just enough to keep its dot whole.
    #expect(SpectrumTraceScale.domain(bottom: -120, peak: -63) == -120...(-60))
    #expect(SpectrumTraceScale.domain(bottom: -120, peak: -40) == -120...(-38))
  }

  @Test
  func `gridlines fall every 12 dB, on Cairn's labels`() {
    #expect(SpectrumTraceScale.gridlines(in: -120...(-64)) == [-120, -108, -96, -84, -72])
    #expect(SpectrumTraceScale.gridlines(in: -118...(-62)) == [-108, -96, -84, -72])
    #expect(SpectrumTraceScale.gridlines(in: -116...(-60)) == [-108, -96, -84, -72])   // none on the top edge
  }
}

// MARK: - Packets

@Suite("Spectrum packets")
struct SpectrumPacketTests {
  @Test
  func `every payload type has Cairn's code`() {
    let codes = PayloadType.allCases.map { SpectrumPacketKind($0).code }
    #expect(codes == ["REQ", "RSP", "MSG", "ACK", "ADV", "GTX", "GDA", "ANQ", "PTH", "TRC", "MPT", "CTL", "RAW", "?"])
  }

  @Test
  func `the legend's kinds each wear their own color`() {
    let colors = SpectrumPacketKind.legendOrder.map(\.color)
    #expect(Set(colors.map { [hex($0, dark: true), hex($0, dark: false)] }).count == colors.count)
    #expect(SpectrumPacketKind.groupText.color == SpectrumPacketKind.groupData.color)
  }

  @Test
  func `route reads as flood with its hops, or direct`() {
    #expect(packet(route: .flood, path: [0x5C, 0x71]).routeTitle == L10n.Tools.Tools.Spectrum.Route.flood(2))
    #expect(packet(route: .tcFlood).routeTitle == L10n.Tools.Tools.Spectrum.Route.flood(0))
    #expect(packet(route: .direct).routeTitle == L10n.Tools.Tools.RxLog.direct)
    #expect(packet(route: .direct, path: [0x5C]).routeTitle == L10n.Tools.Tools.Spectrum.Route.directHops(1))
  }

  private typealias World = TrafficClaremontFixtures

  /// The Claremont world as the app's directory holds it, with no saved or discovered nodes, so
  /// every name is one the nodes advertised.
  @MainActor
  private func unlabelledWorld() -> ObservationDirectory {
    World.observationDirectory(contacts: [], discovered: [])
  }

  /// `entry`'s party, its nodes resolved as the RX Log list resolves them.
  @MainActor
  private func party(_ entry: RxLogEntryDTO, in directory: ObservationDirectory) -> String? {
    let packet = SpectrumPacket(entry: entry)
    return packet.party(packet.nodes(in: directory, sent: TrafficSentPackets()))
  }

  @Test
  @MainActor
  func `an advert names its signed sender and the relay that passed it on`() {
    let directory = unlabelledWorld()
    #expect(party(World.onAirAdvert(.stock, withPosition: true), in: directory)
      == "\(L10n.Tools.Tools.Spectrum.Party.from("WCM-CLR-RPT")) · \(L10n.Tools.Tools.Spectrum.Party.via("Mt Baldy"))")
    // A forged advert names nobody: its claimed key's prefix, never the node it claims to be
    let forged = World.entry(
      World.frame(.advert, route: .direct, pathLength: 0, path: [], payload: World.forgedAdvertPayload(claimedKey: World.claremontKey, name: "Fake")),
      firmware: .stock
    )
    #expect(party(forged, in: directory) == L10n.Tools.Tools.Spectrum.Party.from(Data(World.claremontKey.prefix(3)).uppercaseHexString()))
  }

  @Test
  @MainActor
  func `a relay no node heard on the channel reads as its hash, never a saved node sharing it`() {
    // Kona Hill is saved and shares the relay's byte, but was never heard here
    let kona = World.contact(World.key([0x7F, 0x3A], fill: 0x91), name: "Kona Hill", type: ContactType.repeater.rawValue, latitude: 19.6, longitude: -156)
    let directory = World.observationDirectory(contacts: [kona], discovered: [])
    let viaUnknown = World.entry(World.frame(.groupText, pathLength: 0x01, path: [0x7F], payload: World.groupTextPayload), firmware: .stock)
    let text = party(viaUnknown, in: directory)
    #expect(text?.hasSuffix(L10n.Tools.Tools.Spectrum.Party.via("7F")) == true)
    #expect(text?.contains("Kona Hill") == false)
  }

  @Test
  @MainActor
  func `a direct message reads from sender to recipient, with you as you`() {
    #expect(party(World.directFromAlex(.stock), in: unlabelledWorld())
      == L10n.Tools.Tools.Spectrum.Party.fromTo("Alex", L10n.Tools.Tools.RxLog.pathYou))
  }

  @Test
  @MainActor
  func `channel traffic reads as its channel, or its hash when the channel is unknown`() {
    let directory = unlabelledWorld()
    let named = packet(.groupText, route: .direct, channelName: "#Public")
    #expect(named.party(named.nodes(in: directory, sent: TrafficSentPackets())) == "#Public")
    let unnamed = packet(.groupData, route: .direct, payload: [0x1F, 0x00])
    #expect(unnamed.party(unnamed.nodes(in: directory, sent: TrafficSentPackets())) == L10n.Tools.Tools.Spectrum.Party.channel("1F"))
  }

  @Test
  @MainActor
  func `types without addresses have no party`() {
    let ack = packet(.ack, route: .direct)
    #expect(ack.party(ack.nodes(in: unlabelledWorld(), sent: TrafficSentPackets())) == nil)
  }

  @Test(arguments: TrafficClaremontFixtures.Firmware.allCases)
  @MainActor
  func `Spectrum names each packet's nodes as the RX Log list does`(firmware: TrafficClaremontFixtures.Firmware) throws {
    let directory = World.observationDirectory()
    let entries = [
      World.c1(firmware), World.c2(firmware), World.c3(firmware), World.c5(firmware),
      World.onAirAdvert(firmware, withPosition: true), World.c6Advert(firmware), World.viaClaremont(firmware),
      World.directFromAlex(firmware), World.c9(firmware), World.c5(firmware, channel: nil),
    ]
    for entry in entries {
      let packet = SpectrumPacket(entry: entry)
      let index = directory.index(for: entry)
      let nodes = packet.nodes(in: directory, sent: TrafficSentPackets())
      #expect(nodes == TrafficRouteResolver.packetNodes(for: entry, in: index, sent: TrafficSentPackets()))
      let row = RxLogRowView(entry: entry, groupCount: 1, nodeIndex: index, packet: nodes)
      let text = try #require(packet.party(nodes))
      // Who it is from, as the list's first line names the sender
      if entry.payloadType == .advert || entry.payloadType == .textMessage, let sender = row.sender {
        #expect(text.contains(sender.name), "\(text) names \(sender.name)")
      }
      // The relay that handed it over, as the list's "Heard from" names it
      if packet.isFlood, packet.hops > 0, let relay = nodes.transmitterNode {
        let name = relay.isRadio ? L10n.Tools.Tools.RxLog.pathYou : relay.displayName ?? relay.hash.uppercaseHexString()
        #expect(text.hasSuffix(L10n.Tools.Tools.Spectrum.Party.via(name)))
        #expect(row.heardFromText == L10n.Tools.Tools.Traffic.Link.heardFromSignal(name, "\(SpectrumPacketFormat.snr(6.5)) dB"))
      }
    }
  }

  @Test
  func `signal numbers in Cairn's precision and ages in one unit`() {
    #expect(SpectrumPacketFormat.snr(6.25) == 6.25.formatted(.number.precision(.fractionLength(0...2))))
    #expect(SpectrumPacketFormat.age(12.7) == Duration.seconds(12).formatted(.units(allowed: [.seconds], width: .narrow)))
    #expect(SpectrumPacketFormat.age(-3) == Duration.seconds(0).formatted(.units(allowed: [.seconds], width: .narrow)))
    #expect(SpectrumPacketFormat.age(125) == Duration.seconds(120).formatted(.units(allowed: [.minutes], width: .narrow)))
  }
}

// MARK: - View model

@Suite("Spectrum readings")
@MainActor
struct SpectrumReadingTests {
  @Test
  func `a zero noise floor means the radio is still calibrating`() {
    let model = SpectrumViewModel()
    model.record(noiseFloor: 0, at: epoch)
    #expect(model.isCalibrating)
    #expect(model.currentNoiseFloor == nil)
    #expect(model.samplingSince == nil)
    model.record(noiseFloor: -112, at: epoch.addingTimeInterval(2))
    #expect(!model.isCalibrating)
    #expect(model.currentNoiseFloor == -112)
    #expect(model.samplingSince == epoch.addingTimeInterval(2))
  }

  @Test
  func `a reading at or above -40 dBm isn't a floor`() {
    let model = SpectrumViewModel()
    model.record(noiseFloor: -40, at: epoch)
    #expect(model.isCalibrating)
    #expect(model.currentNoiseFloor == nil)
    #expect(model.traceBottom == nil)
    model.record(noiseFloor: -41, at: epoch.addingTimeInterval(2))
    #expect(!model.isCalibrating)
    #expect(model.currentNoiseFloor == -41)
  }

  @Test
  func `the chart's bottom holds through jitter and starts over when reset`() {
    let model = SpectrumViewModel()
    model.record(noiseFloor: -112, at: epoch)
    #expect(model.traceBottom == -120)
    // Jitter: -108 wants -116, 4 dB away.
    model.record(noiseFloor: -108, at: epoch.addingTimeInterval(2))
    #expect(model.traceBottom == -120)
    // A calibrating reading leaves the scale where it was.
    model.record(noiseFloor: 0, at: epoch.addingTimeInterval(4))
    #expect(model.traceBottom == -120)
    // A new channel or window drops the hold; the next reading seeds it again.
    model.resetTraceScale()
    #expect(model.traceBottom == nil)
    model.record(noiseFloor: -100, at: epoch.addingTimeInterval(6))
    #expect(model.traceBottom == -108)
  }

  @Test
  func `the floor history keeps one average per minute, with the open minute last`() {
    let model = SpectrumViewModel()
    // epoch is on a whole minute.
    model.record(noiseFloor: -110, at: epoch)
    model.record(noiseFloor: -112, at: epoch.addingTimeInterval(30))
    model.record(noiseFloor: -100, at: epoch.addingTimeInterval(61))
    #expect(model.floorHistory.elements.map(\.dBm) == [-111])
    #expect(model.floorTrend.map(\.dBm) == [-111, -100])
  }

  @Test
  func `packets stay in time order and each one once`() {
    let model = SpectrumViewModel()
    let live = packet(at: epoch.addingTimeInterval(10))
    model.record(packets: [live])
    let older = packet(at: epoch)
    // The read-back arrives after a live packet and overlaps it.
    model.record(packets: [older, live])
    #expect(model.packets.elements.map(\.id) == [older.id, live.id])
    model.record(packets: [live])
    #expect(model.packets.count == 2)
  }

  @Test
  func `now is the latest packet, or the radio's own reading before one arrives`() {
    let model = SpectrumViewModel()
    #expect(model.nowRSSI == nil)
    model.record(packets: [packet(rssi: -97, at: epoch)])
    #expect(model.nowRSSI == -97)
  }

  @Test
  func `packets are counted from the oldest one heard or the first reading`() {
    let model = SpectrumViewModel()
    #expect(model.packetsObservedSince == nil)
    model.record(noiseFloor: -110, at: epoch)
    #expect(model.packetsObservedSince == epoch)
    model.record(packets: [packet(at: epoch.addingTimeInterval(-300))])
    #expect(model.packetsObservedSince == epoch.addingTimeInterval(-300))
  }

  @Test
  func `the trend needs readings before it has a direction`() {
    let model = SpectrumViewModel()
    #expect(model.noiseTrend == nil)
    for (offset, dBm) in [-112.0, -112, -104, -104].enumerated() {
      model.record(noiseFloor: dBm, at: epoch.addingTimeInterval(Double(offset)))
    }
    #expect(model.noiseTrend == .rising)
  }

  @Test
  func `firmware without the stats command stops the readings and says so`() throws {
    let model = SpectrumViewModel()
    // Official companion v1.7–v1.10 answer CMD_GET_STATS with ERR_CODE_UNSUPPORTED_CMD, written as
    // [RESP_CODE_ERR 0x01][0x01] (companion-v1.9.0 MyMesh.cpp:1488-1490); the session throws it as is.
    let error = try #require(MeshCoreSession.deviceErrorMatcher(PacketParser.parse(Data([0x01, 0x01]))))
    #expect(!model.notePollFailure(error), "the poll loop stops")
    #expect(model.statsUnsupported)
    #expect(model.errorMessage == L10n.Tools.Tools.NoiseFloor.Error.unsupported)
  }

  @Test
  func `other failed readings are tried again`() {
    let model = SpectrumViewModel()
    #expect(model.notePollFailure(MeshCoreError.timeout), "the poll loop keeps going")
    #expect(!model.statsUnsupported)
    #expect(model.errorMessage == L10n.Tools.Tools.NoiseFloor.Error.unableToRead)
  }
}

/// Ported from the retired Noise Floor tool's trend rule, now the caption on Spectrum's floor tile.
@Suite("Noise trend")
struct NoiseTrendTests {
  @Test
  func `too few readings count as steady`() {
    #expect(NoiseTrend(readings: []) == .steady)
    #expect(NoiseTrend(readings: [-120, -110, -100]) == .steady)
  }

  @Test
  func `the later half beyond three decibels of the earlier half sets the direction`() {
    #expect(NoiseTrend(readings: [-110, -110, -105, -105]) == .rising)
    #expect(NoiseTrend(readings: [-100, -100, -105, -105]) == .falling)
    // Exactly three decibels is still jitter.
    #expect(NoiseTrend(readings: [-110, -110, -107, -107]) == .steady)
  }
}

// MARK: - Scan for Nodes traffic

@Suite("Scan for Nodes traffic")
struct NodeDiscoveryTrafficStatsTests {
  private static let now = Date(timeIntervalSince1970: 1_000_000)

  private static func entry(secondsAgo: TimeInterval, snr: Double? = 5, type: PayloadType = .advert) -> RxLogEntryDTO {
    let parsed = ParsedRxLogData(
      snr: snr,
      rssi: -80,
      rawPayload: Data([0x01]),
      routeType: .flood,
      payloadType: type,
      payloadVersion: 0,
      payloadTypeBits: 0,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: Data([0x02])
    )
    return RxLogEntryDTO(radioID: UUID(), receivedAt: now.addingTimeInterval(-secondsAgo), from: parsed)
  }

  @Test
  func `only packets since the start count, newest first`() {
    let log = [Self.entry(secondsAgo: 90), Self.entry(secondsAgo: 30), Self.entry(secondsAgo: 2)]
    let picked = NodeDiscoveryTrafficStats.entries(log, since: Self.now.addingTimeInterval(-60))
    #expect(picked.map(\.id) == [log[2].id, log[1].id])
  }

  @Test
  func `with no scan it looks back ten minutes`() {
    let scan = Self.now.addingTimeInterval(-20)
    #expect(NodeDiscoveryTrafficStats.start(scanStartedAt: scan, now: Self.now) == scan)
    #expect(NodeDiscoveryTrafficStats.start(scanStartedAt: nil, now: Self.now) == Self.now.addingTimeInterval(-600))
  }

  @Test
  func `figures come from the packets, with no rate before there's time to measure`() {
    let packets = [Self.entry(secondsAgo: 1, snr: 3), Self.entry(secondsAgo: 2, snr: 9), Self.entry(secondsAgo: 3, snr: nil)]
    let stats = NodeDiscoveryTrafficStats(entries: packets, start: Self.now.addingTimeInterval(-30), now: Self.now)
    #expect(stats.count == 3)
    #expect(stats.perMinute == 6)
    #expect(stats.bestSNR == 9)
    #expect(NodeDiscoveryTrafficStats(entries: packets, start: Self.now.addingTimeInterval(-2), now: Self.now).perMinute == nil)
  }
}

// MARK: - Mini spectrum

@Suite("Mini spectrum")
struct MiniSpectrumFrameTests {
  private static let now = Date(timeIntervalSince1970: 1_000_000)

  private static func packet(secondsAgo: TimeInterval, rssi: Int, type: PayloadType = .advert) -> SpectrumPacket {
    let parsed = ParsedRxLogData(
      snr: 5,
      rssi: rssi,
      rawPayload: Data([0x01]),
      routeType: .flood,
      payloadType: type,
      payloadVersion: 0,
      payloadTypeBits: 0,
      transportCode: nil,
      pathLength: 0,
      pathNodes: [],
      packetPayload: Data([0x02])
    )
    return SpectrumPacket(entry: RxLogEntryDTO(radioID: UUID(), receivedAt: now.addingTimeInterval(-secondsAgo), from: parsed))
  }

  @Test
  func `the scale is the radios': 4 under the floor to 24 over it`() {
    #expect(MiniSpectrumFrame.height(dBm: -114, floor: -110) == 0)
    #expect(MiniSpectrumFrame.height(dBm: -86, floor: -110) == 1)
    #expect(MiniSpectrumFrame.height(dBm: -40, floor: -110) == 1)
    #expect(MiniSpectrumFrame.height(dBm: -130, floor: -110) == 0)
    #expect(abs(MiniSpectrumFrame.height(dBOverFloor: 6) - 10.0 / 28) < 0.0001)
  }

  @Test
  func `a radio without its own view shows its floor readings and each packet, newest at the right`() {
    let noise = [NoiseSample(date: Self.now.addingTimeInterval(-59.5), dBm: -112)]
    let packets = [Self.packet(secondsAgo: 0.5, rssi: -80, type: .ack), Self.packet(secondsAgo: 300, rssi: -50)]
    let frame = MiniSpectrumFrame.readings(noise: noise, packets: packets, barCount: 60, window: 60, now: Self.now)
    #expect(frame.bars.count == 60)
    #expect(frame.floor == -112)
    #expect(frame.bars.last?.dBm == -80)
    #expect(frame.bars.first?.dBm == -112)
    #expect(frame.peak == -80, "the packet older than the window is left out")
    #expect(frame.marks.map(\.kind) == [.ack])
  }

  @Test
  func `a floor reading stands until the next, but not forever`() {
    let noise = [
      NoiseSample(date: Self.now.addingTimeInterval(-50), dBm: -112),
      NoiseSample(date: Self.now.addingTimeInterval(-45), dBm: -111),
    ]
    let frame = MiniSpectrumFrame.readings(noise: noise, packets: [], barCount: 60, window: 60, now: Self.now)
    #expect(frame.bars[12].dBm == -112, "between two readings the first stands")
    #expect(frame.bars[20].dBm == -111)
    #expect(frame.bars[59].dBm == nil, "past the hold, nothing is made up")
  }

  @Test
  func `a bar keeps its reading and its time as the clock moves on`() {
    let packets = [Self.packet(secondsAgo: 10.5, rssi: -80)]
    let first = MiniSpectrumFrame.readings(noise: [], packets: packets, barCount: 60, window: 60, now: Self.now)
    let later = MiniSpectrumFrame.readings(noise: [], packets: packets, barCount: 60, window: 60, now: Self.now.addingTimeInterval(1))
    let firstIndex = first.bars.firstIndex { $0.dBm == -80 }
    let laterIndex = later.bars.firstIndex { $0.dBm == -80 }
    #expect(firstIndex != nil)
    #expect(laterIndex == firstIndex.map { $0 - 1 }, "a second on, the bar is one place older with the same height")
    #expect(later.newestDate.timeIntervalSince(first.newestDate) == 1)
  }

  @Test
  func `a bar keeps the scale it was read against when the floor moves`() {
    let noise = [
      NoiseSample(date: Self.now.addingTimeInterval(-40), dBm: -112),
      NoiseSample(date: Self.now.addingTimeInterval(-5), dBm: -100),
    ]
    let packets = [Self.packet(secondsAgo: 20.5, rssi: -90)]
    let frame = MiniSpectrumFrame.readings(noise: noise, packets: packets, barCount: 60, window: 60, now: Self.now)
    #expect(frame.floor == -100, "the floor has risen 12 dB since")
    let bar = frame.bars[39]
    #expect(bar.dBm == -90)
    #expect(bar.floor == -112, "the packet's bar stays against the floor when it was heard")
    #expect(bar.height(current: frame.floor) == MiniSpectrumFrame.height(dBm: -90, floor: -112))
    #expect(bar.dBOverFloor(current: frame.floor) == 22)
    // The old floor readings stand where they stood, on the floor line, as does the new one.
    #expect(frame.bars[25].height(current: frame.floor) == MiniSpectrumFrame.height(dBOverFloor: 0))
    #expect(frame.bars[58].height(current: frame.floor) == MiniSpectrumFrame.height(dBOverFloor: 0))
  }

  @Test
  func `a bar stays until it scrolls off, whatever a later frame carries`() {
    let history = MiniSpectrumHistory()
    let first = MiniSpectrumFrame.readings(
      noise: [], packets: [Self.packet(secondsAgo: 50.5, rssi: -80)], barCount: 60, window: 60, now: Self.now
    )
    #expect(history.merged(first).bars[9].dBm == -80)

    // A later frame without the packet, as when the radio's view resyncs: it stays, a bar older.
    let later = MiniSpectrumFrame.readings(noise: [], packets: [], barCount: 60, window: 60, now: Self.now.addingTimeInterval(5))
    let merged = history.merged(later)
    #expect(merged.bars.count == 60)
    #expect(merged.bars[4].dBm == -80)

    // Past the left edge it goes.
    let gone = MiniSpectrumFrame.readings(noise: [], packets: [], barCount: 60, window: 60, now: Self.now.addingTimeInterval(11))
    #expect(!history.merged(gone).hasData)
  }

  @Test
  func `a bar keeps the first floor it was read against, even with none of its own`() {
    let history = MiniSpectrumHistory()
    // A packet without a floor reading before it: the bar has no floor of its own.
    let first = MiniSpectrumFrame.readings(
      noise: [], packets: [Self.packet(secondsAgo: 30.5, rssi: -80)], barCount: 60, window: 60, now: Self.now
    )
    var merged = history.merged(first)
    #expect(merged.bars[29].floor == MiniSpectrumFrame.fallbackFloor)
    let height = merged.bars[29].height(current: merged.floor)

    // The frame's floor moves with the radio's estimate; the bar stands where it stood.
    let later = MiniSpectrumFrame.readings(
      noise: [NoiseSample(date: Self.now.addingTimeInterval(0.5), dBm: -100)],
      packets: [Self.packet(secondsAgo: 30.5, rssi: -80)],
      barCount: 60, window: 60, now: Self.now.addingTimeInterval(1)
    )
    merged = history.merged(later)
    #expect(merged.floor == -100)
    #expect(merged.bars[28].floor == MiniSpectrumFrame.fallbackFloor)
    #expect(merged.bars[28].height(current: merged.floor) == height)
  }

  @Test
  func `a reset history takes the next frame, and starts over`() {
    let history = MiniSpectrumHistory()
    let frame = MiniSpectrumFrame.readings(
      noise: [], packets: [Self.packet(secondsAgo: 5, rssi: -80)], barCount: 60, window: 60, now: Self.now
    )
    history.reset()
    #expect(history.merged(frame).hasData)
    history.reset()
    let empty = MiniSpectrumFrame.readings(noise: [], packets: [], barCount: 60, window: 60, now: Self.now)
    #expect(!history.merged(empty).hasData)
  }

  @Test
  func `a clock that jumps back starts the history over`() {
    let history = MiniSpectrumHistory()
    let later = Self.now.addingTimeInterval(1000)
    _ = history.merged(.readings(
      noise: [], packets: [Self.packet(secondsAgo: -995, rssi: -80)], barCount: 60, window: 60, now: later
    ))
    #expect(!history.merged(.readings(noise: [], packets: [], barCount: 60, window: 60, now: Self.now)).hasData)
  }

  @Test
  func `a new window starts the history over`() {
    let history = MiniSpectrumHistory()
    let oneMinute = MiniSpectrumFrame.readings(
      noise: [], packets: [Self.packet(secondsAgo: 5, rssi: -80)], barCount: 60, window: 60, now: Self.now
    )
    _ = history.merged(oneMinute)
    let tenMinutes = MiniSpectrumFrame.readings(noise: [], packets: [], barCount: 60, window: 600, now: Self.now)
    #expect(!history.merged(tenMinutes).hasData)
  }

  @Test
  func `a packet's mark stays with its time across frames`() {
    let history = MiniSpectrumHistory()
    let packet = Self.packet(secondsAgo: 10, rssi: -80)
    _ = history.merged(.readings(noise: [], packets: [packet], barCount: 60, window: 60, now: Self.now))
    let merged = history.merged(.readings(noise: [], packets: [], barCount: 60, window: 60, now: Self.now.addingTimeInterval(5)))
    #expect(merged.marks.map(\.packetID) == [packet.id])
    #expect(abs((merged.marks.first?.secondsBeforeNewest ?? 0) - 15) < 0.01)
  }

  @Test
  @MainActor
  func `every screen gets the same plot from the one feed`() {
    let feed = SpectrumFeed()
    feed.model.record(packets: [Self.packet(secondsAgo: 5, rssi: -80)])
    let first = feed.frame(barCount: 90, now: Self.now)
    #expect(feed.frame(barCount: 90, now: Self.now) == first)
    feed.pickedWindow = .tenSeconds
    #expect(feed.window == .tenSeconds)
    #expect(feed.frame(barCount: 90, now: Self.now).barSeconds != first.barSeconds, "a window picked anywhere shows everywhere")
  }

  @Test
  func `a mark names the packet it stands for, so a tap can pick it`() {
    let packet = Self.packet(secondsAgo: 5, rssi: -80)
    let frame = MiniSpectrumFrame.readings(noise: [], packets: [packet], barCount: 60, window: 60, now: Self.now)
    #expect(frame.marks.first?.packetID == packet.id)
    #expect(frame.marks.first?.rxMs == nil)
  }

  @Test
  func `no readings means nothing to draw`() {
    let frame = MiniSpectrumFrame.readings(noise: [], packets: [], barCount: 10, window: 60, now: Self.now)
    #expect(!frame.hasData)
    #expect(frame.peak == nil)
    #expect(frame.floor == MiniSpectrumFrame.fallbackFloor)
  }

  @Test
  func `an empty device view has no bars with data`() {
    let history = SpectrumDeviceHistory(window: 1, ncols: 180)
    let frame = MiniSpectrumFrame.device(history, barCount: 90, window: 60, clock: SpectrumDeviceSlotClock(), now: Self.now)
    #expect(frame.bars.count == 90)
    #expect(!frame.hasData)
  }
}
