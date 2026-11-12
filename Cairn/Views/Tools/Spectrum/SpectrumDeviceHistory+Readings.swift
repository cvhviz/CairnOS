import Foundation
import MeshCore

// The Radio Screen on a radio without a Channel view of its own: the same view, put together by
// the app from what it reads itself (the floor readings, the RX log's packets, the airtime
// counters), on the same slot grid the radio would use. Every radio then draws the Radio Screen
// the same way; a Cairn radio that sends its view fills in what the app can't read (the density
// rows, the busy share).

extension SpectrumDeviceHistory {
  /// What the app reads on its own, for ``readings(_:)``.
  struct ReadingsInput {
    /// Oldest first.
    var noise: [NoiseSample]
    var packets: [SpectrumPacket]
    var airtime: [AirtimeSample]
    var window: SpectrumWindow
    var ncols: Int
    var now: Date
    var channel: LoRaChannelMath?
    /// The radio's latest reading, for NOW.
    var nowRSSI: Double?
    /// Since when packets have been counted, for PKT/MIN.
    var packetsObservedSince: Date?
  }

  /// The heat the floor's own row gets in a column's density: the column spent nearly all its
  /// time there.
  static let readingsFloorHeat: UInt8 = 27
  /// The heat a packet's row gets: a burst, a fraction of the column.
  static let readingsPacketHeat: UInt8 = 16
  /// The rows between the floor and a packet (the chirp's ramp): barely there.
  static let readingsRampHeat: UInt8 = 6

  /// The view from the app's readings, as of `input.now`. A floor reading stands until the next,
  /// up to `MiniSpectrumFrame.floorHold`; a packet raises its column's max and marks the lane.
  static func readings(_ input: ReadingsInput) -> SpectrumDeviceHistory {
    let ncols = max(input.ncols, 1)
    let windowSeconds = input.window.duration
    let slotSeconds = windowSeconds / Double(ncols)
    func slot(_ date: Date) -> Int64 { Int64((date.timeIntervalSinceReferenceDate / slotSeconds).rounded(.down)) }
    let nowSlot = slot(input.now)
    func index(_ date: Date) -> Int? {
      let back = nowSlot - slot(date)
      guard back >= 0, back < Int64(ncols) else { return nil }
      return ncols - 1 - Int(back)
    }

    // The floor at each moment: the readings in the window, each held until the next.
    struct Level { var min: Int; var max: Int; var sum: Int; var count: Int; var floor: Int?; var packets: [Int] }
    var levels = [Level?](repeating: nil, count: ncols)
    func add(_ dBm: Int, floor: Int?, to column: Int, packet: Bool) {
      var level = levels[column] ?? Level(min: dBm, max: dBm, sum: 0, count: 0, floor: nil, packets: [])
      level.min = min(level.min, dBm)
      level.max = max(level.max, dBm)
      level.sum += dBm
      level.count += 1
      if level.floor == nil { level.floor = floor }
      if packet { level.packets.append(dBm) }
      levels[column] = level
    }
    let noise = input.noise
    for (position, sample) in noise.enumerated() {
      let next = position + 1 < noise.count ? noise[position + 1].date : input.now
      let until = min(next, sample.date.addingTimeInterval(MiniSpectrumFrame.floorHold))
      guard until >= sample.date else { continue }
      let first = nowSlot - slot(sample.date)
      let last = nowSlot - slot(until)
      guard first >= last else { continue }
      let dBm = Int(sample.dBm.rounded())
      for back in stride(from: first, through: last, by: -1) where back >= 0 && back < Int64(ncols) {
        add(dBm, floor: dBm, to: ncols - 1 - Int(back), packet: false)
      }
    }
    var marks: [DeviceMark] = []
    var peak: (dBm: Int, slot: Int64)?
    for packet in input.packets {
      guard let column = index(packet.date), let rssi = packet.rssi else { continue }
      let dBm = Int(rssi.rounded())
      let floor = noise.last { $0.date <= packet.date }.map { Int($0.dBm.rounded()) }
      add(dBm, floor: floor, to: column, packet: true)
      if peak.map({ dBm > $0.dBm }) ?? true { peak = (dBm, slot(packet.date)) }
      // The mark's width as the radio would size it: the packet's airtime in slots, at least one.
      let airtime = input.channel?.timeOnAir(payloadBytes: packet.size) ?? 0
      let width = max(1, Int((airtime / slotSeconds).rounded()))
      let mark = CairnSpectrumMark(
        back: UInt8(clamping: nowSlot - slot(packet.date)),
        width: UInt8(clamping: width),
        header: (packet.entry.payloadTypeBits & 0x0F) << 2 | (packet.entry.routeType.rawValue & 0x03),
        pathLength: packet.entry.pathLength,
        rssi: Int8(clamping: dBm),
        snrX4: Int8(clamping: Int(((packet.snr ?? 0) * 4).rounded())),
        length: UInt8(clamping: packet.size),
        rxMs: Self.milliseconds(packet.date)
      )
      marks.append(DeviceMark(mark: mark, endSlot: UInt32(truncatingIfNeeded: slot(packet.date))))
    }

    // The scale's bottom, from the floor the window was read against.
    let currentFloor = noise.last.flatMap { input.now.timeIntervalSince($0.date) <= MiniSpectrumFrame.floorHold ? $0.dBm : nil }
    let scaleLo = Int(SpectrumTraceScale.bottom(floor: currentFloor))
    let rows = CairnSpectrumColumn.rows
    func row(_ dBm: Int) -> Int { min(max((dBm - scaleLo) / 2, 0), rows - 1) }

    var columns = [CairnSpectrumColumn?](repeating: nil, count: ncols)
    for (column, level) in levels.enumerated() {
      guard let level, level.count > 0 else { continue }
      // The density as the radio would have counted it: the floor's row for most of the column,
      // each packet's row for a burst, and a faint ramp between.
      var occupancy = [UInt8](repeating: 0, count: rows)
      let floorRow = row(level.floor ?? level.min)
      occupancy[floorRow] = Self.readingsFloorHeat
      for dBm in level.packets {
        let top = row(dBm)
        if top > floorRow {
          for between in (floorRow + 1)..<top where occupancy[between] < Self.readingsRampHeat {
            occupancy[between] = Self.readingsRampHeat
          }
        }
        occupancy[top] = max(occupancy[top], Self.readingsPacketHeat)
      }
      columns[column] = CairnSpectrumColumn(
        isData: true,
        isTX: false,
        min: Int8(clamping: level.min),
        max: Int8(clamping: level.max),
        avg: Int8(clamping: level.sum / level.count),
        nf: level.floor.map { Int8(clamping: $0) },
        busy: nil,
        occupancy: occupancy
      )
    }

    // The readings row, from the same span the page's own strip reads.
    let statsSpan = input.window.statsDuration
    let start = input.now.addingTimeInterval(-statsSpan)
    let counted = input.packets.filter { $0.date >= start }
    let rate = SpectrumStats.packetsPerMinute(
      count: counted.count, window: statsSpan, observedSince: input.packetsObservedSince, now: input.now
    )
    let share = SpectrumStats.airtimeShare(input.airtime, window: statsSpan, now: input.now)
    let covered = input.packetsObservedSince.map { min(statsSpan, max(0, input.now.timeIntervalSince($0))) } ?? 0
    let thermal = input.channel.map { Int8(clamping: Int($0.thermalNoiseFloor.rounded())) } ?? 0
    let stats = CairnSpectrumStats(
      floorCalibrated: currentFloor != nil,
      sweeping: false,
      fast: false,
      epoch: 1,
      nowMs: Self.milliseconds(input.now),
      frequencyKHz: UInt32(clamping: Int((input.channel?.frequencyHz ?? 0) / 1000)),
      bandwidthHz: UInt32(clamping: Int(input.channel?.bandwidthHz ?? 0)),
      spreadingFactor: UInt8(clamping: input.channel?.spreadingFactor ?? 0),
      codingRate: UInt8(clamping: input.channel?.codingRate ?? 0),
      window: input.window.deviceIndex,
      nowRSSI: input.nowRSSI.map { Int8(clamping: Int($0.rounded())) },
      floor: currentFloor.map { Int8(clamping: Int($0.rounded())) },
      thermal: thermal,
      busyPercent: nil,
      packetsPerMinuteX10: rate.map { UInt16(clamping: Int(($0 * 10).rounded())) },
      airX10: share.map { UInt16(clamping: Int((($0.rx + $0.tx) * 1000).rounded())) },
      rxAirX10: share.map { UInt16(clamping: Int(($0.rx * 1000).rounded())) },
      txAirX10: share.map { UInt16(clamping: Int(($0.tx * 1000).rounded())) },
      packets: UInt16(clamping: counted.count),
      coveredSeconds: UInt16(clamping: Int(covered)),
      statsSeconds: UInt16(clamping: Int(statsSpan)),
      peak: peak.map { Int8(clamping: $0.dBm) }
    )

    return SpectrumDeviceHistory(
      window: input.window.deviceIndex,
      ncols: ncols,
      nowSlot: UInt32(truncatingIfNeeded: nowSlot),
      stats: stats,
      columns: columns,
      marks: marks,
      scaleLo: Int8(clamping: scaleLo),
      refFloor: currentFloor.map { Int8(clamping: Int($0.rounded())) },
      peakBack: peak.map { UInt8(clamping: nowSlot - $0.slot) }
    )
  }

  /// A date as the radio would stamp it: milliseconds, wrapping as `millis()` does. The marks'
  /// `rxMs` and the readings' `nowMs` share it, so `SpectrumDeviceMarkMatch.date` gives the
  /// packet's time back.
  static func milliseconds(_ date: Date) -> UInt32 {
    UInt32(truncatingIfNeeded: Int64((date.timeIntervalSinceReferenceDate * 1000).rounded()))
  }

  /// The 24 h floor trend from the app's own minute averages, laid on the radio's grid of points.
  static func trend(samples: [NoiseSample], thermal: Int8, now: Date) -> CairnSpectrumTrend? {
    guard !samples.isEmpty else { return nil }
    let count = Int(SpectrumDeviceFeed.trendPoints)
    let slice = 86_400 / Double(count)
    let start = now.addingTimeInterval(-86_400)
    var sums = [(total: Double, count: Int)](repeating: (0, 0), count: count)
    for sample in samples {
      let position = Int(sample.date.timeIntervalSince(start) / slice)
      guard position >= 0, position < count else { continue }
      sums[position].total += sample.dBm
      sums[position].count += 1
    }
    let points: [Int8?] = sums.map { $0.count > 0 ? Int8(clamping: Int(($0.total / Double($0.count)).rounded())) : nil }
    return CairnSpectrumTrend(epoch: 1, thermal: thermal, have: UInt8(clamping: points.compactMap(\.self).count), points: points)
  }
}
