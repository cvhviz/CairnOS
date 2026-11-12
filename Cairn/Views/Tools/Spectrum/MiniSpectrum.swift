import CairnServices
import MeshCore
import SwiftUI

/// What the mini spectrum draws, one moment of it: bars oldest first, the floor they stand against,
/// the packets over them, and the loudest bar. Only real readings: the radio's own columns where it
/// sends them, else its noise-floor readings and the strength of each packet it heard.
///
/// Each bar belongs to a fixed span of time, the bars cut on the clock rather than counted back from
/// now, so a bar keeps its height for as long as it's on screen. The plot scrolls by the clock
/// between readings, as the radios' does, rather than redrawing its bars in place.
struct MiniSpectrumFrame: Equatable {
  struct Bar: Equatable {
    /// The column's loudest reading; nil where there is none.
    var dBm: Double?
    /// The floor when it was read. A bar keeps the scale it was read against, as the radios' columns
    /// do, so a floor that drifts never rescales the history.
    var floor: Double?
    /// The radio was transmitting.
    var isTX = false
    /// The column's quietest reading, where the radio reports one (else the floor it was read
    /// against, or nothing): the bottom of the band the Waterfall style draws.
    var low: Double?
    /// From a Cairn radio's own view: its density rows, 2 dB each from `densityBase` up, each the
    /// radio's heat index for how much of the column's time sat in that bin (0 = none).
    var occupancy: [UInt8]?
    var densityBase: Double?

    /// Where the bar stands on the scale; `current` until it has a floor of its own.
    func height(current: Double) -> Double {
      dBm.map { MiniSpectrumFrame.height(dBm: $0, floor: floor ?? current) } ?? 0
    }

    /// The bar's density: 28 rows of 2 dB up from `base`, each as hot as the share of the bar's
    /// time the channel sat at that level (the radio's own rows, where it sends them), else rows
    /// stood in for from what the bar has: its floor's row hot, its loudest reading's a burst,
    /// and a faint ramp between (a chirp's rise). Nil without a reading.
    func densityRows(base: Double, current: Double) -> (base: Double, rows: [UInt8])? {
      guard let dBm else { return nil }
      if let occupancy, let densityBase, occupancy.contains(where: { $0 > 0 }) {
        return (densityBase, occupancy)
      }
      let count = 28
      func row(_ level: Double) -> Int { min(max(Int((level - base) / 2), 0), count - 1) }
      var rows = [UInt8](repeating: 0, count: count)
      let floorRow = row(low ?? floor ?? current)
      rows[floorRow] = MiniSpectrumFrame.standInFloorHeat
      let top = row(dBm)
      if top > floorRow {
        for between in (floorRow + 1)..<top { rows[between] = MiniSpectrumFrame.standInRampHeat }
        rows[top] = MiniSpectrumFrame.standInPacketHeat
      }
      return (base, rows)
    }

    /// How far over its floor the bar reached.
    func dBOverFloor(current: Double) -> Double? {
      dBm.map { $0 - (floor ?? current) }
    }
  }

  struct Mark: Equatable {
    /// How long before `newestDate` the packet arrived.
    var secondsBeforeNewest: TimeInterval
    let kind: SpectrumPacketKind
    /// The RX log's packet, on a radio without its own view.
    var packetID: UUID?
    /// The radio's mark (its `rxMs`), on a radio with its own view.
    var rxMs: UInt32?
  }

  /// The heat the stood-in density rows get (`Bar.densityRows`): the floor's row, a reading's
  /// burst, the ramp between.
  static let standInFloorHeat: UInt8 = 27
  static let standInPacketHeat: UInt8 = 16
  static let standInRampHeat: UInt8 = 6

  /// The radios' scale (`SpectrumRing::SPAN_DB`, ui-new's `NOISE_SPAN_DB`): 28 dB, from 4 under the
  /// floor to 24 over it.
  static let spanDB = 28.0
  static let dBUnderFloor = 4.0
  /// Before the radio's floor is calibrated, the radios' own stand-in.
  static let fallbackFloor = -110.0
  /// A floor reading stands until the next one, up to this long; past it a bar is left empty.
  static let floorHold: TimeInterval = 30

  var bars: [Bar]
  var floor: Double
  var marks: [Mark]
  /// How long one bar spans.
  var barSeconds: TimeInterval = 1
  /// When the newest bar's span ends: the plot's clock.
  var newestDate: Date = .distantPast
  /// The newest bar's place on the clock, the same for the same span in every frame, so frames can
  /// be laid over each other (`MiniSpectrumHistory`).
  var newestKey: Int64 = 0
  /// How far behind now the plot's edge runs, so a reading scrolls in from past the edge rather than
  /// appearing on it.
  var lag: TimeInterval = 0

  var hasData: Bool { bars.contains { $0.dBm != nil } }
  var peak: Double? { bars.compactMap(\.dBm).max() }
  /// The tallest bar as drawn, for the peak's rule: each bar stands on its own floor's scale.
  var peakHeight: Double? { bars.filter { $0.dBm != nil }.map { $0.height(current: floor) }.max() }

  /// Where a level stands on the scale, 0 at the bottom and 1 at the top, clamped.
  static func height(dBm: Double, floor: Double) -> Double {
    min(max((dBm - (floor - dBUnderFloor)) / spanDB, 0), 1)
  }

  /// Where a level over the floor stands on the scale, for its gridlines and colour bands.
  static func height(dBOverFloor: Double) -> Double {
    (dBOverFloor + dBUnderFloor) / spanDB
  }

  /// From the radio's own Channel view: its columns folded into about `barCount` bars on the radio's
  /// slot grid, keeping each bar's loudest, so a short burst is never averaged away.
  ///
  /// - Parameters:
  ///   - window: How long the view spans.
  ///   - clock: Where the radio's slots fall on the phone's clock.
  ///   - now: Stands in for the clock before its first reply.
  static func device(
    _ history: SpectrumDeviceHistory,
    barCount: Int,
    window: TimeInterval,
    clock: SpectrumDeviceSlotClock,
    now: Date
  ) -> MiniSpectrumFrame {
    let total = max(history.columns.count, 1)
    let fold = max(Int((Double(total) / Double(max(barCount, 1))).rounded()), 1)
    let count = max(total / fold, 1)
    let slotSeconds = window / Double(total)
    let nowSlot = Int64(history.nowSlot)
    let newestKey = nowSlot / Int64(fold)
    // The density rows' bottom: the radio's held scale, or the app's stand-in before it sends one.
    let densityBase = history.scaleLo != 0
      ? Double(history.scaleLo)
      : SpectrumTraceScale.bottom(floor: history.refFloor.map(Double.init))
    var bars = [Bar](repeating: Bar(), count: count)
    for (index, column) in history.columns.enumerated() {
      guard let column, column.isData || column.isTX else { continue }
      let slot = nowSlot - Int64(total - 1 - index)
      let bar = count - 1 - Int(newestKey - floorDivide(slot, Int64(fold)))
      guard bars.indices.contains(bar) else { continue }
      if column.isData {
        bars[bar].dBm = max(bars[bar].dBm ?? -.infinity, Double(column.max))
        bars[bar].low = min(bars[bar].low ?? .infinity, Double(column.min))
        // The column's own floor; the bar keeps the first it's given, so a bar still filling holds still.
        if bars[bar].floor == nil, let nf = column.nf { bars[bar].floor = Double(nf) }
        // Folded columns keep each row's busiest.
        if column.occupancy.contains(where: { $0 > 0 }) {
          if var rows = bars[bar].occupancy {
            for (row, heat) in column.occupancy.enumerated() where row < rows.count { rows[row] = max(rows[row], heat) }
            bars[bar].occupancy = rows
          } else {
            bars[bar].occupancy = column.occupancy
          }
          bars[bar].densityBase = densityBase
        }
      }
      if column.isTX { bars[bar].isTX = true }
    }
    // The newest bar ends where the slot after its last begins, placed by the steady clock rather
    // than by when each reply arrived, so neither the link's delay nor where in its slot a reply
    // came moves the plot; the slots after the newest in this bar are still to come.
    let slotsLeftInBar = (newestKey + 1) * Int64(fold) - nowSlot
    let endSlot = (newestKey + 1) * Int64(fold)
    let newestDate = clock.date(ofSlot: endSlot, slotSeconds: slotSeconds)
      ?? now.addingTimeInterval(Double(slotsLeftInBar) * slotSeconds)
    let leftSeconds = Double(slotsLeftInBar) * slotSeconds
    let marks = history.marks.compactMap { mark -> Mark? in
      let back = Int64(nowSlot) - Int64(mark.endSlot)
      guard back >= 0, back < Int64(total) else { return nil }
      return Mark(
        secondsBeforeNewest: Double(back) * slotSeconds + leftSeconds,
        kind: SpectrumPacketKind(mark.mark.payloadType),
        rxMs: mark.mark.rxMs
      )
    }
    let floor = history.stats?.floor ?? history.refFloor
    return MiniSpectrumFrame(
      bars: bars,
      floor: floor.map(Double.init) ?? fallbackFloor,
      marks: marks,
      barSeconds: slotSeconds * Double(fold),
      newestDate: newestDate,
      newestKey: newestKey,
      // Long enough for the next reply (1 s, or 0.5 s on the 10 s window) to land past the edge.
      lag: window <= 10 ? 1.5 : max(2.5, slotSeconds * Double(fold) * 1.5)
    )
  }

  /// From what a radio without its own view reports: each bar holds the floor last read, or the
  /// strongest packet heard then. `noise` and `packets` run oldest first.
  static func readings(
    noise: [NoiseSample],
    packets: [SpectrumPacket],
    barCount: Int,
    window: TimeInterval,
    now: Date
  ) -> MiniSpectrumFrame {
    let count = max(barCount, 1)
    let barSeconds = window / Double(count)
    func key(_ date: Date) -> Int64 { Int64((date.timeIntervalSinceReferenceDate / barSeconds).rounded(.down)) }
    let newestKey = Int64((now.timeIntervalSinceReferenceDate / barSeconds).rounded(.up)) - 1
    func index(_ date: Date) -> Int? {
      let index = count - 1 - Int(newestKey - key(date))
      return index >= 0 && index < count ? index : nil
    }
    var bars = [Bar](repeating: Bar(), count: count)
    // A floor reading stands until the next, as the floor itself does, up to `floorHold`.
    for (position, sample) in noise.enumerated() {
      let next = position + 1 < noise.count ? noise[position + 1].date : now
      let until = min(next, sample.date.addingTimeInterval(floorHold))
      guard until >= sample.date else { continue }
      let first = Int(newestKey - key(sample.date))
      let last = Int(newestKey - key(until))
      guard first >= last else { continue }
      for back in stride(from: first, through: last, by: -1) where back >= 0 && back < count {
        bars[count - 1 - back].dBm = sample.dBm
        bars[count - 1 - back].floor = sample.dBm
        bars[count - 1 - back].low = sample.dBm
      }
    }
    let newestDate = Date(timeIntervalSinceReferenceDate: Double(newestKey + 1) * barSeconds)
    var marks: [Mark] = []
    for packet in packets {
      guard let bar = index(packet.date) else { continue }
      if let rssi = packet.rssi {
        bars[bar].dBm = max(bars[bar].dBm ?? -.infinity, rssi)
        // Against the floor last read before it, as a radio would have scaled it.
        if bars[bar].floor == nil {
          bars[bar].floor = noise.last { $0.date <= packet.date }?.dBm
        }
        bars[bar].low = min(bars[bar].low ?? rssi, rssi)
      }
      marks.append(Mark(secondsBeforeNewest: newestDate.timeIntervalSince(packet.date), kind: packet.kind, packetID: packet.id))
    }
    return MiniSpectrumFrame(
      bars: bars,
      floor: noise.last?.dBm ?? fallbackFloor,
      marks: marks,
      barSeconds: barSeconds,
      newestDate: newestDate,
      newestKey: newestKey,
      lag: max(1, barSeconds * 1.5)
    )
  }

  /// Division that rounds down for a negative slot too, so every bar spans the same slots.
  private static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
    let quotient = value / divisor
    return value % divisor < 0 ? quotient - 1 : quotient
  }
}

/// What a mini spectrum has shown lately, so it scans endlessly: each frame is laid over it, and a bar
/// goes only by scrolling off the left edge, never because a later frame didn't carry it (a resync
/// with the radio, its window moving on). A bar keeps the first floor it was read against. A new
/// scale or a clock that jumps back (another window, a rebooted radio) starts over.
final class MiniSpectrumHistory {
  private var bars: [Int64: MiniSpectrumFrame.Bar] = [:]
  /// By the packet's identity, when it arrived.
  private var marks: [String: (date: Date, mark: MiniSpectrumFrame.Mark)] = [:]
  private var barSeconds: TimeInterval = 0
  /// Nil until the first frame, or after a reset.
  private var newestKey: Int64?

  func reset() {
    bars = [:]
    marks = [:]
    newestKey = nil
  }

  func merged(_ frame: MiniSpectrumFrame) -> MiniSpectrumFrame {
    let count = Int64(frame.bars.count)
    let jumpedBack = newestKey.map { frame.newestKey < $0 - count } ?? false
    if abs(frame.barSeconds - barSeconds) > 0.0001 || jumpedBack {
      bars = [:]
      marks = [:]
      barSeconds = frame.barSeconds
    }
    newestKey = frame.newestKey

    for (index, bar) in frame.bars.enumerated() where bar.dBm != nil || bar.isTX {
      let key = frame.newestKey - (count - 1 - Int64(index))
      var kept = bars[key] ?? MiniSpectrumFrame.Bar()
      kept.dBm = bar.dBm ?? kept.dBm
      // The first floor the bar was read against, kept for good: its own, else the bar before
      // it (the floor its neighbours stand on), else the frame's as it is now. Left nil, a bar
      // stood against the frame's live floor, the radio's estimate, which moves with every reply
      // and is nothing at all for a moment after each AGC reset: those bars rose and fell once a
      // reply, and the Analyzer's peak caps rode up and down on them.
      kept.floor = kept.floor ?? bar.floor ?? bars[key - 1]?.floor ?? frame.floor
      kept.isTX = kept.isTX || bar.isTX
      kept.low = bar.low ?? kept.low
      if bar.occupancy != nil {
        kept.occupancy = bar.occupancy
        kept.densityBase = bar.densityBase
      }
      bars[key] = kept
    }
    let oldest = frame.newestKey - count
    bars = bars.filter { $0.key > oldest }

    for mark in frame.marks {
      guard let id = mark.packetID?.uuidString ?? mark.rxMs.map(String.init) else { continue }
      marks[id] = (frame.newestDate.addingTimeInterval(-mark.secondsBeforeNewest), mark)
    }
    let span = Double(count) * frame.barSeconds
    marks = marks.filter { frame.newestDate.timeIntervalSince($0.value.date) <= span }

    var merged = frame
    merged.bars = (0..<count).map { index in
      bars[frame.newestKey - (count - 1 - index)] ?? MiniSpectrumFrame.Bar()
    }
    merged.marks = marks.values
      .sorted { $0.date < $1.date }
      .map { kept in
        var mark = kept.mark
        mark.secondsBeforeNewest = frame.newestDate.timeIntervalSince(kept.date)
        return mark
      }
    return merged
  }
}

/// How far each of a mini spectrum's bars has come toward its reading, so a bar whose reading
/// lands or changes moves there over a quarter of a second rather than stepping. A bar landing at
/// the newest edge starts from the bar before it, so a new reading continues the plot; a radio's
/// history arriving in chunks as a page opens, or a bar filled in further back, stands on its
/// reading at once. Kept by the view across frames, by each bar's place on the clock as
/// `MiniSpectrumHistory` keeps its bars; a new scale or a clock that jumps back starts over.
@MainActor
final class MiniSpectrumEasing {
  /// How long a reading takes to arrive.
  nonisolated static let easeIn: TimeInterval = 0.25

  private var shown: [Int64: Double] = [:]
  private var lastTick: TimeInterval?
  private var barSeconds: TimeInterval = 0

  /// Each bar's drawn height, oldest first; nil where there's no reading.
  func heights(frame: MiniSpectrumFrame, at date: Date, animated: Bool) -> [Double?] {
    let now = date.timeIntervalSinceReferenceDate
    let first = lastTick == nil
    let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 0
    lastTick = now
    let count = Int64(frame.bars.count)
    let jumpedBack = shown.keys.max().map { frame.newestKey < $0 - count } ?? false
    if abs(frame.barSeconds - barSeconds) > 0.0001 || jumpedBack {
      shown = [:]
      barSeconds = frame.barSeconds
    }
    let previousNewest = shown.keys.max()
    let blend = animated ? 1 - exp(-dt / Self.easeIn) : 1

    var heights: [Double?] = []
    heights.reserveCapacity(frame.bars.count)
    for (index, bar) in frame.bars.enumerated() {
      guard bar.dBm != nil else {
        heights.append(nil)
        continue
      }
      let key = frame.newestKey - (count - 1 - Int64(index))
      let target = bar.height(current: frame.floor)
      let height: Double
      if let current = shown[key] {
        height = current + (target - current) * blend
      } else if animated, !first, let previousNewest, key > previousNewest, let neighbour = shown[key - 1] {
        height = neighbour + (target - neighbour) * blend
      } else {
        height = target
      }
      shown[key] = height
      heights.append(height)
    }
    let oldest = frame.newestKey - count
    shown = shown.filter { $0.key > oldest }
    return heights
  }
}

/// The app's one view of the radio's channel: its readings, and what's been drawn of them. The
/// Dashboard's card, Scan for Nodes and the Spectrum tab all show this, so they agree and carry on
/// from each other. The radio is read while any of them is on screen, and what was read is kept
/// between them.
@Observable
@MainActor
final class SpectrumFeed {
  let model = SpectrumViewModel()
  /// The window picked on the Spectrum tab, until the default changes.
  var pickedWindow: SpectrumWindow?

  @ObservationIgnored private let history = MiniSpectrumHistory()
  @ObservationIgnored private var viewers: Set<UUID> = []
  /// The session being read now, and the last one read, whose history is still good.
  @ObservationIgnored private var runningSession: ObjectIdentifier?
  @ObservationIgnored private var lastSession: ObjectIdentifier?

  /// The window everything shows: the one picked, else Spectrum Settings' default.
  var window: SpectrumWindow {
    if let pickedWindow { return pickedWindow }
    let raw = UserDefaults.standard.object(forKey: AppStorageKey.spectrumDefaultWindow.rawValue) as? Int
    return SpectrumWindow(rawValue: raw ?? AppStorageKey.defaultSpectrumWindow) ?? .oneMinute
  }

  /// Bars across a plot, one figure everywhere so every plot cuts the same bars.
  static func barCount(_ sizeClass: UserInterfaceSizeClass?) -> Int {
    sizeClass == .regular ? 120 : 90
  }

  /// Columns across the radio's own view (SPEC_SYNC).
  static func deviceColumns(_ sizeClass: UserInterfaceSizeClass?) -> Int {
    sizeClass == .regular ? SpectrumDeviceFeed.regularColumns : SpectrumDeviceFeed.compactColumns
  }

  /// The plot as of `now`.
  func frame(barCount: Int, now: Date) -> MiniSpectrumFrame {
    history.merged(model.miniSpectrumFrame(barCount: barCount, window: window, now: now))
  }

  /// A screen showing the feed, on a live link: starts the readings if they aren't running.
  func claim(_ viewer: UUID, session: MeshCoreSession, rxLogService: RxLogService?, columns: Int) {
    viewers.insert(viewer)
    model.deviceWindow = window
    model.deviceColumns = columns
    let id = ObjectIdentifier(session)
    guard runningSession != id else { return }
    // Another session is another radio, or this one restarted: nothing drawn still lines up.
    if lastSession != id { history.reset() }
    runningSession = id
    lastSession = id
    model.start(session: session, rxLogService: rxLogService)
  }

  /// A screen gone, or its link: the readings stop with the last one, and what was read is kept.
  func release(_ viewer: UUID) {
    viewers.remove(viewer)
    guard viewers.isEmpty else { return }
    runningSession = nil
    model.stop()
  }
}

/// Reads the radio's channel while this view is on screen, the link is up and the app is in front.
struct SpectrumFeedViewer: ViewModifier {
  @Environment(\.appState) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var viewer = UUID()

  private var pollKey: SpectrumPollKey {
    SpectrumPollKey(
      servicesVersion: appState.servicesVersion,
      services: appState.services.map(ObjectIdentifier.init),
      isConnected: appState.connectionState.isOperational,
      isActive: scenePhase == .active
    )
  }

  func body(content: Content) -> some View {
    content
      // Keyed on the connection, not the view: a disconnect ends the polls and lets the session go,
      // and a reconnect brings a new session for the readings to follow rather than keep polling
      // the one that went away. Readings pause while the app is in the background and resume, from
      // the same history, when it returns.
      .task(id: pollKey) {
        if pollKey.polls, let services = appState.services {
          appState.spectrumFeed.claim(
            viewer,
            session: services.session,
            rxLogService: services.rxLogService,
            columns: SpectrumFeed.deviceColumns(horizontalSizeClass)
          )
        } else {
          appState.spectrumFeed.release(viewer)
        }
      }
      .onDisappear { appState.spectrumFeed.release(viewer) }
      // The radio's own view follows the width; a change starts it over.
      .onChange(of: horizontalSizeClass) {
        appState.spectrumFeed.model.deviceColumns = SpectrumFeed.deviceColumns(horizontalSizeClass)
      }
  }
}

extension SpectrumViewModel {
  /// `window`'s worth of whatever this radio reports. A radio with its own view spans the window it
  /// was asked for (`deviceWindow`).
  func miniSpectrumFrame(barCount: Int, window: SpectrumWindow = .oneMinute, now: Date) -> MiniSpectrumFrame {
    if source == .device {
      return .device(deviceHistory, barCount: barCount, window: deviceWindow.duration, clock: deviceSlotClock, now: now)
    }
    let since = now.addingTimeInterval(-window.duration)
    return .readings(
      noise: noise.elements.filter { $0.date >= since },
      packets: packets.elements.filter { $0.date >= since },
      barCount: barCount,
      window: window.duration,
      now: now
    )
  }
}

/// The mini spectrum the L1 Pro and T-Deck show on their Radio pages, drawn straight on the card it
/// sits in, or on an instrument's dark glass for the large one: bars on the radios' scale, each coloured by the band its height reaches (+6 and +20 dB over the
/// floor), a red cap on anything past +35, the floor's dashed line and the loudest bar's dotted one.
/// It scrolls by the clock, each bar keeping its height as it slides left. Here the bars also glow,
/// under a lane of the packets heard in their kinds' colours.
struct MiniSpectrumView: View {
  let frame: MiniSpectrumFrame
  /// Under its packet lane and labels, or only the bars for a small strip.
  var showsDetail = true
  /// The packet lane's height.
  var laneHeight: CGFloat = 12
  /// On dark glass of its own in either appearance, for the Spectrum tab's large plot.
  var isOnDarkGlass = false
  /// The picked mark, ringed with a line down the plot.
  var selectedPacketID: UUID?
  var selectedRxMs: UInt32?
  /// A tap picks the packet nearest it, or nil away from any. Nil leaves taps to what's around it.
  var onSelectMark: ((MiniSpectrumFrame.Mark?) -> Void)?
  /// The moment the plot is held at while its page is paused: nothing scrolls or eases; nil live.
  var heldAt: Date?
  /// The cursor, as seconds before the newest bar's end (`SpectrumCursor`); nil for none.
  var cursor: TimeInterval?
  /// A tap away from any packet puts the cursor there (or clears it): the moment tapped, or nil.
  var onCursorTap: ((TimeInterval?) -> Void)?
  /// The glass's corners.
  var cornerRadius: CGFloat = 12

  /// A tap this close to a packet picks it.
  private static let hitRadius: CGFloat = 18

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @State private var isVisible = false
  @State private var plotWidth: CGFloat = 0
  @State private var easing = MiniSpectrumEasing()

  private func painter(at date: Date) -> MiniSpectrumPainter {
    let date = heldAt ?? date
    return MiniSpectrumPainter(
      frame: frame,
      heights: easing.heights(frame: frame, at: date, animated: !reduceMotion),
      // Without motion the plot moves only as new readings land, its newest bar at the edge.
      secondsPastNewest: reduceMotion ? 0 : date.timeIntervalSince(frame.newestDate) - frame.lag,
      lag: reduceMotion ? 0 : frame.lag,
      showsDetail: showsDetail,
      isDark: isOnDarkGlass || colorScheme == .dark,
      drawsGlass: isOnDarkGlass,
      laneHeight: laneHeight,
      selectedPacketID: selectedPacketID,
      selectedRxMs: selectedRxMs,
      scale: displayScale,
      cursorSeconds: cursor
    )
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isVisible || scenePhase != .active || heldAt != nil)) { timeline in
      Canvas { context, size in
        painter(at: timeline.date).draw(in: &context, size: size)
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
    .gesture(SpatialTapGesture().onEnded { value in
      guard onSelectMark != nil || onCursorTap != nil else { return }
      let painter = painter(at: heldAt ?? .now)
      let nearest = frame.marks
        .map { (mark: $0, gap: abs(painter.x(secondsBeforeNewest: $0.secondsBeforeNewest, width: plotWidth) - value.location.x)) }
        .min { $0.gap < $1.gap }
      if let onSelectMark, let mark = nearest.flatMap({ $0.gap <= Self.hitRadius ? $0.mark : nil }) {
        onSelectMark(mark)
        onCursorTap?(nil)
      } else {
        onSelectMark?(nil)
        onCursorTap?(SpectrumCursor.toggled(
          cursor, tapped: painter.secondsBeforeNewest(atX: value.location.x, width: plotWidth), barSeconds: frame.barSeconds
        ))
      }
    }, including: onSelectMark == nil && onCursorTap == nil ? .subviews : .all)
    .overlay {
      if !frame.hasData {
        Text(L10n.Tools.Tools.Spectrum.measuring)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .clipShape(.rect(cornerRadius: isOnDarkGlass ? cornerRadius : 0, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(.white.opacity(isOnDarkGlass ? 0.12 : 0), lineWidth: 1)
    }
    .environment(\.colorScheme, isOnDarkGlass ? .dark : colorScheme)
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
    .accessibilityHidden(true)
  }
}

/// One frame of the mini spectrum.
private struct MiniSpectrumPainter {
  let frame: MiniSpectrumFrame
  /// Each bar's drawn height on its way to its reading (`MiniSpectrumEasing`); nil where there's
  /// no reading.
  let heights: [Double?]
  /// How far the plot's edge has moved past the newest bar's end; below 0 that bar is still coming.
  let secondsPastNewest: TimeInterval
  /// How much of the bars lie beyond the edge at rest.
  let lag: TimeInterval
  let showsDetail: Bool
  let isDark: Bool
  let drawsGlass: Bool
  let laneHeight: CGFloat
  let selectedPacketID: UUID?
  let selectedRxMs: UInt32?
  /// Pixels per point, for the bars' edges: snapped to whole pixels, so a plot sliding by the
  /// clock steps a pixel at a time rather than smearing each bar's edge across two.
  var scale: CGFloat = 2
  /// The cursor's moment, seconds before the newest bar's end; nil for none.
  var cursorSeconds: TimeInterval?

  /// `x` on the pixel grid.
  private func snap(_ x: CGFloat) -> CGFloat {
    (x * scale).rounded() / scale
  }

  // Deeper on a light card, where the radios' bright teal and amber wash out.
  private var noiseColor: Color { isDark ? Color(red: 0.16, green: 0.55, blue: 0.52) : Color(red: 0.36, green: 0.66, blue: 0.64) }
  private var signalColor: Color { isDark ? Color(red: 0.25, green: 0.95, blue: 0.80) : Color(red: 0, green: 0.62, blue: 0.54) }
  private var strongColor: Color { isDark ? Color(red: 1, green: 0.66, blue: 0.20) : Color(red: 0.90, green: 0.50, blue: 0) }
  private static let criticalColor = Color(red: 1, green: 0.27, blue: 0.27)
  private static let txColor = Color(red: 1, green: 0.40, blue: 0.62)

  func draw(in context: inout GraphicsContext, size: CGSize) {
    let lane: CGFloat = showsDetail ? laneHeight : 0
    let plot = CGRect(x: 0, y: lane + 3, width: size.width, height: max(size.height - lane - 5, 1))

    if drawsGlass {
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
        Gradient(colors: [Color(red: 0.03, green: 0.08, blue: 0.11), Color(red: 0.01, green: 0.03, blue: 0.05)]),
        startPoint: .zero,
        endPoint: CGPoint(x: 0, y: size.height)
      ))
    }
    drawGrid(in: &context, plot: plot)
    drawBars(in: &context, plot: plot)
    drawRules(in: &context, plot: plot)
    if showsDetail {
      drawPeakMarker(in: &context, plot: plot)
    }
    drawCursor(in: &context, plot: plot)
    if showsDetail {
      drawMarks(in: context, laneHeight: lane, plot: plot)
    }
  }

  /// The middle of the bar at `index` and the top of its drawn height.
  private func barTop(_ index: Int, plot: CGRect) -> CGPoint {
    let count = frame.bars.count
    let left = plot.minX + x(secondsBeforeNewest: Double(count - index) * frame.barSeconds, width: plot.width)
    let height = index < heights.count ? heights[index] ?? frame.bars[index].height(current: frame.floor) : frame.bars[index].height(current: frame.floor)
    return CGPoint(x: left + pitch(in: plot.width) / 2, y: plot.maxY - max(plot.height * height, 1.5))
  }

  /// The cursor: a line down the plot at its moment, a marker diamond on the bar under it and
  /// its tag at the top.
  private func drawCursor(in context: inout GraphicsContext, plot: CGRect) {
    guard let cursorSeconds else { return }
    let cx = snap(plot.minX + x(secondsBeforeNewest: cursorSeconds, width: plot.width))
    guard cx >= plot.minX, cx <= plot.maxX else { return }
    context.fill(Path(CGRect(x: cx - 0.5, y: plot.minY, width: 1, height: plot.height)), with: .color(.primary.opacity(0.85)))
    guard showsDetail else { return }
    if let index = frame.barIndex(secondsBeforeNewest: cursorSeconds), frame.bars[index].dBm != nil {
      let top = barTop(index, plot: plot)
      let diamond = SpectrumMarkerGlyph.diamond(at: CGPoint(x: cx, y: top.y))
      context.fill(diamond, with: .color(.primary))
      context.stroke(diamond, with: .color(isDark ? .black : .white), lineWidth: 1)
    }
    SpectrumMarkerGlyph.tag(in: &context, "M1", at: CGPoint(x: min(cx + 2, plot.maxX - 22), y: plot.minY + 1), color: .primary)
  }

  /// ▼ over the loudest bar in view.
  private func drawPeakMarker(in context: inout GraphicsContext, plot: CGRect) {
    guard frame.hasData, let peakHeight = frame.peakHeight, peakHeight >= MiniSpectrumFrame.height(dBOverFloor: 2),
          let index = frame.bars.indices.max(by: { (frame.bars[$0].dBm ?? -.infinity) < (frame.bars[$1].dBm ?? -.infinity) })
    else { return }
    let top = barTop(index, plot: plot)
    guard top.x >= plot.minX, top.x <= plot.maxX else { return }
    context.fill(SpectrumMarkerGlyph.peak(at: CGPoint(x: top.x, y: max(top.y - 2, plot.minY + 8))), with: .color(strongColor))
  }

  /// The moment `x` stands for, in seconds before the newest bar's end (the inverse of `x(secondsBeforeNewest:width:)`).
  func secondsBeforeNewest(atX x: CGFloat, width: CGFloat) -> TimeInterval {
    Double((width - x) / max(pitch(in: width), 0.001)) * frame.barSeconds - secondsPastNewest
  }

  /// A bar's width on screen: the bars beyond the edge at rest don't count against the plot.
  private func pitch(in width: CGFloat) -> CGFloat {
    let shown = max(Double(frame.bars.count) - lag / max(frame.barSeconds, 0.001), 1)
    return width / CGFloat(shown)
  }

  /// Where the plot puts a moment `seconds` before the newest bar's end.
  func x(secondsBeforeNewest seconds: TimeInterval, width: CGFloat) -> CGFloat {
    width - CGFloat((seconds + secondsPastNewest) / max(frame.barSeconds, 0.001)) * pitch(in: width)
  }

  private func y(_ height: Double, in plot: CGRect) -> CGFloat {
    plot.maxY - plot.height * height
  }

  /// The band edges behind the bars.
  private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
    for over in [6.0, 20.0] {
      let lineY = y(MiniSpectrumFrame.height(dBOverFloor: over), in: plot)
      var line = Path()
      line.move(to: CGPoint(x: plot.minX, y: lineY))
      line.addLine(to: CGPoint(x: plot.maxX, y: lineY))
      context.stroke(line, with: .color(.primary.opacity(0.16)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 3]))
      if showsDetail {
        context.draw(
          Text("+\(Int(over))").font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.primary.opacity(0.55)),
          at: CGPoint(x: plot.minX + 5, y: lineY - 1),
          anchor: .bottomLeading
        )
      }
    }
  }

  /// One path for all the bars under one gradient up the plot, so a bar's colour follows its height
  /// as the radios' rows do, then the same shape blurred under it for the glow.
  private func drawBars(in context: inout GraphicsContext, plot: CGRect) {
    guard !frame.bars.isEmpty else { return }
    let pitch = pitch(in: plot.width)
    let count = frame.bars.count
    /// The bar's left edge, on the clock.
    func barX(_ index: Int) -> CGFloat {
      plot.minX + x(secondsBeforeNewest: Double(count - index) * frame.barSeconds, width: plot.width)
    }
    var path = Path()
    var lastHeight: Double?
    var lastIndex: Int?
    for (index, bar) in frame.bars.enumerated() where bar.dBm != nil {
      // Both edges on the pixel grid, the gap a whole pixel.
      let edge = barX(index)
      var left = snap(edge)
      var barWidth = max(snap(edge + pitch) - left - 1 / scale, 1 / scale)
      // The oldest bar reaches the left edge: with the newest bar's end still to come, the plot
      // sits a little to the right, and the edge would otherwise show a sliver of nothing.
      if index == 0, left > plot.minX {
        barWidth += left - plot.minX
        left = plot.minX
      }
      let height = index < heights.count ? heights[index] ?? bar.height(current: frame.floor) : bar.height(current: frame.floor)
      lastHeight = height
      lastIndex = index
      guard left + barWidth >= plot.minX, left <= plot.maxX else { continue }
      let barHeight = max(plot.height * height, 1.5)
      path.addRoundedRect(
        in: CGRect(x: left, y: plot.maxY - barHeight, width: barWidth, height: barHeight),
        cornerSize: CGSize(width: min(barWidth / 2, 1.5), height: min(barWidth / 2, 1.5)),
        style: .continuous
      )
    }
    // The hold: the newest bars still waiting on their reading keep the last one's height,
    // faintly, so the plot runs to the edge until theirs lands.
    var hold = Path()
    if let lastHeight, let lastIndex {
      for index in (lastIndex + 1)..<min(lastIndex + 7, count) where frame.bars[index].dBm == nil {
        let edge = barX(index)
        let left = snap(edge)
        guard left <= plot.maxX else { break }
        let barHeight = max(plot.height * lastHeight, 1.5)
        let holdWidth = max(snap(edge + pitch) - left - 1 / scale, 1 / scale)
        hold.addRect(CGRect(x: left, y: plot.maxY - barHeight, width: holdWidth, height: barHeight))
      }
    }
    let signalEdge = MiniSpectrumFrame.height(dBOverFloor: 6)
    let strongEdge = MiniSpectrumFrame.height(dBOverFloor: 20)
    let shading = GraphicsContext.Shading.linearGradient(
      Gradient(stops: [
        .init(color: noiseColor.opacity(0.75), location: 0),
        .init(color: noiseColor, location: signalEdge - 0.02),
        .init(color: signalColor, location: signalEdge + 0.02),
        .init(color: signalColor, location: strongEdge - 0.02),
        .init(color: strongColor, location: strongEdge + 0.02),
        .init(color: strongColor, location: 1),
      ]),
      startPoint: CGPoint(x: 0, y: plot.maxY),
      endPoint: CGPoint(x: 0, y: plot.minY)
    )
    if showsDetail {
      context.drawLayer { glow in
        glow.addFilter(.blur(radius: 5))
        glow.opacity = isDark ? 0.55 : 0.25
        glow.fill(path, with: shading)
      }
    }
    context.fill(path, with: shading)
    context.drawLayer { faint in
      faint.opacity = 0.4
      faint.fill(hold, with: shading)
    }

    // A red cap past +35 dB, and the radio's own transmissions along the bottom.
    for (index, bar) in frame.bars.enumerated() {
      let edge = barX(index)
      let left = snap(edge)
      let width = max(snap(edge + pitch) - left - 1 / scale, 1 / scale)
      guard left + width >= plot.minX, left <= plot.maxX else { continue }
      if let over = bar.dBOverFloor(current: frame.floor), over >= SpectrumLevel.veryStrong.from {
        let height = index < heights.count ? heights[index] ?? bar.height(current: frame.floor) : bar.height(current: frame.floor)
        let top = plot.maxY - plot.height * height
        context.fill(Path(CGRect(x: left, y: top, width: width, height: 2)), with: .color(Self.criticalColor))
      }
      if bar.isTX {
        context.fill(Path(CGRect(x: left, y: plot.maxY - 2, width: width, height: 2)), with: .color(Self.txColor))
      }
    }
  }

  /// The floor the bars stand against, and how far the loudest got.
  private func drawRules(in context: inout GraphicsContext, plot: CGRect) {
    let floorY = y(MiniSpectrumFrame.height(dBOverFloor: 0), in: plot)
    var floorLine = Path()
    floorLine.move(to: CGPoint(x: plot.minX, y: floorY))
    floorLine.addLine(to: CGPoint(x: plot.maxX, y: floorY))
    context.stroke(floorLine, with: .color(.primary.opacity(0.45)), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))

    guard showsDetail, frame.hasData else { return }
    context.draw(
      Text("\(Int(frame.floor.rounded()))").font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(.primary.opacity(0.75)),
      at: CGPoint(x: plot.minX + 5, y: floorY - 1),
      anchor: .bottomLeading
    )
    guard let peak = frame.peak, let peakHeight = frame.peakHeight,
          peakHeight >= MiniSpectrumFrame.height(dBOverFloor: 2) else { return }
    let peakY = y(peakHeight, in: plot)
    var peakLine = Path()
    peakLine.move(to: CGPoint(x: plot.minX, y: peakY))
    peakLine.addLine(to: CGPoint(x: plot.maxX, y: peakY))
    context.stroke(peakLine, with: .color(strongColor.opacity(0.8)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
    context.draw(
      Text("\(Int(peak.rounded()))").font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(strongColor),
      at: CGPoint(x: plot.maxX - 5, y: max(peakY - 1, plot.minY + 10)),
      anchor: .bottomTrailing
    )
  }

  /// The packets heard, each a tick in its kind's colour; the picked one ringed, with a line down to
  /// its bar.
  private func drawMarks(in context: GraphicsContext, laneHeight: CGFloat, plot: CGRect) {
    for mark in frame.marks {
      let tickX = x(secondsBeforeNewest: mark.secondsBeforeNewest, width: plot.width)
      guard tickX >= -2, tickX <= plot.width + 2 else { continue }
      let tick = CGRect(x: tickX - 2, y: 4, width: 4, height: laneHeight - 5)
      context.fill(Path(roundedRect: tick, cornerRadius: 1.5), with: .color(mark.kind.color))
      let isSelected = (mark.packetID != nil && mark.packetID == selectedPacketID)
        || (mark.rxMs != nil && mark.rxMs == selectedRxMs)
      if isSelected {
        context.stroke(Path(roundedRect: tick.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 2.5), with: .color(.primary), lineWidth: 1)
        var line = Path()
        line.move(to: CGPoint(x: tickX, y: tick.maxY + 2))
        line.addLine(to: CGPoint(x: tickX, y: plot.maxY))
        context.stroke(line, with: .color(.primary.opacity(0.55)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
      }
    }
  }
}

/// NOW, FLOOR and PEAK small enough for a card's title row, in dBm as the plot's own numbers are. The text
/// stops growing where it would no longer fit.
struct MiniSpectrumTitleReadings: View {
  let now: Double?
  let floor: Double?
  let peak: Double?

  var body: some View {
    HStack(spacing: 7) {
      reading(L10n.Tools.Tools.Spectrum.Meter.now, dBm: now)
      reading(L10n.Tools.Tools.Spectrum.Meter.floor, dBm: floor)
      reading(L10n.Tools.Tools.Spectrum.Meter.peak, dBm: peak)
    }
    .font(.caption2.weight(.semibold).monospacedDigit())
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .lineLimit(1)
    .minimumScaleFactor(0.7)
  }

  private func reading(_ title: String, dBm: Double?) -> some View {
    HStack(spacing: 3) {
      Text(title)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
      Text(dBm.map { "\(Int($0.rounded()))" } ?? "—")
        .foregroundStyle(.primary)
        .contentTransition(.numericText())
    }
  }
}

/// NOW, FLOOR and PEAK side by side in one line over a mini spectrum, each label beside its value:
/// at the largest text sizes, over it.
struct MiniSpectrumReadings: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let now: Double?
  let floor: Double?
  let peak: Double?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      reading(L10n.Tools.Tools.Spectrum.Meter.now, dBm: now)
      Spacer(minLength: 6)
      reading(L10n.Tools.Tools.Spectrum.Meter.floor, dBm: floor)
      Spacer(minLength: 6)
      reading(L10n.Tools.Tools.Spectrum.Meter.peak, dBm: peak)
    }
  }

  private func reading(_ title: String, dBm: Double?) -> some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 4))
    return layout {
      Text(title)
        .font(.caption2.weight(.medium))
        .textCase(.uppercase)
        .foregroundStyle(Color.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(dBm.map { SpectrumFormat.dBm($0) } ?? "—")
        .font(.footnote.weight(.semibold).monospacedDigit())
        .foregroundStyle(dBm == nil ? Color.secondary : Color.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(.numericText())
    }
    .accessibilityElement(children: .combine)
  }
}

/// "-1m · -30s · now" under a large spectrum.
struct MiniSpectrumTimeAxis: View {
  let window: SpectrumWindow

  var body: some View {
    ZStack {
      Text(Self.ago(window.duration))
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(Self.ago(window.duration / 2))
      Text(L10n.Tools.Tools.Spectrum.Axis.now)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.tertiary)
    .lineLimit(1)
    .accessibilityHidden(true)
  }

  nonisolated static func ago(_ seconds: TimeInterval) -> String {
    "−" + Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1))
  }
}

/// How the Spectrum tab draws its channel (Settings › Spectrum). The raw values are stored, so a
/// case keeps its number for good.
enum SpectrumChartStyle: Int, CaseIterable, Identifiable {
  /// The mini spectrum's design, larger.
  case modern = 0
  /// The radio's own Channel view, as its screen draws it (a Cairn radio that sends one:
  /// `SpectrumDeviceCard`). On a radio without one the Modern plot stands in.
  case radioScreen = 1
  /// A bench analyzer's screen, moving at the display's rate between readings (``AnalyzerSpectrumView``).
  case analyzer = 2
  /// A spectrogram: each moment a column of heat by level (``WaterfallSpectrumView``).
  case waterfall = 3
  /// The floor as a line with the packets over it, on a dB axis (`SpectrumChannelChart`), from the
  /// app's own readings on every radio.
  case lineChart = 4

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .modern: L10n.Tools.Tools.Spectrum.Settings.styleModern
    case .radioScreen: L10n.Tools.Tools.Spectrum.Settings.styleRadioScreen
    case .analyzer: L10n.Tools.Tools.Spectrum.Settings.styleAnalyzer
    case .waterfall: L10n.Tools.Tools.Spectrum.Settings.styleWaterfall
    case .lineChart: L10n.Tools.Tools.Spectrum.Settings.styleLineChart
    }
  }

  /// The style read from storage, the Modern plot where nothing is stored.
  static func stored(_ raw: Int) -> SpectrumChartStyle {
    SpectrumChartStyle(rawValue: raw) ?? .modern
  }

  /// Bars across the style's plot: the Waterfall runs at the radio's full column count, a row a
  /// column; the rest share `SpectrumFeed.barCount`.
  @MainActor func barCount(_ sizeClass: UserInterfaceSizeClass?) -> Int {
    self == .waterfall ? SpectrumFeed.deviceColumns(sizeClass) : SpectrumFeed.barCount(sizeClass)
  }

  /// The plot runs time across, so the "-1m · -30s · now" axis goes under it; the Waterfall runs
  /// time down and labels it itself.
  var showsTimeAxis: Bool { self != .waterfall }
}

/// The large spectrum in the chosen style: the Modern plot on dark glass, the Analyzer or the
/// Waterfall. The Radio Screen and Line Chart styles are pages of their own, so where only a plot
/// fits (the Dashboard's card) they show the Modern plot. Tapping a packet on the lane picks it,
/// where `onSelectMark` is given.
struct StyledSpectrumPlot: View {
  let style: SpectrumChartStyle
  let frame: MiniSpectrumFrame
  /// The radio's channel, for the Waterfall's band and its labels.
  var channelHz: Double?
  var bandwidthHz: Double?
  var laneHeight: CGFloat = 20
  var selectedPacketID: UUID?
  var selectedRxMs: UInt32?
  var onSelectMark: ((MiniSpectrumFrame.Mark?) -> Void)?
  /// The moment the plot is held at while the page is paused; nil while live.
  var heldAt: Date?
  /// A tap on the plot puts a cursor there and reads the bar under it (`SpectrumCursor`), as a
  /// tap on the Radio Screen does. Off where the plot is a button of its own (the Dashboard card).
  var allowsCursor = true
  /// Told where the cursor goes (nil when cleared), for a readout outside the plot.
  var onCursorChange: ((TimeInterval?) -> Void)?
  /// The glass's corners.
  var cornerRadius: CGFloat = 12

  /// The moment tapped. The cursor is drawn that long before the newest bar, so it travels with the
  /// bars as they slide by the clock, as a packet's mark does (the user, 2026-11-07: it stayed put
  /// while the trace moved under it). Gone once its moment leaves the window.
  @State private var cursorDate: Date?

  private var cursor: TimeInterval? {
    guard let cursorDate else { return nil }
    let seconds = frame.newestDate.timeIntervalSince(cursorDate)
    return seconds >= 0 && seconds <= Double(frame.bars.count) * frame.barSeconds ? seconds : nil
  }

  var body: some View {
    plot
      .overlay(alignment: .topLeading) {
        if allowsCursor, let cursor, let lines = SpectrumBarReadout.lines(frame: frame, secondsBeforeNewest: cursor) {
          SpectrumFrameReadoutChip(lines: lines, level: SpectrumBarReadout.level(frame: frame, secondsBeforeNewest: cursor))
            .padding(.top, laneHeight + 4)
            .padding(.leading, style == .analyzer ? AnalyzerGeometry.scaleWidth + 2 : 4)
            .allowsHitTesting(false)
        }
      }
      // Another window cuts other bars: the cursor's moment means nothing on them.
      .onChange(of: frame.barSeconds) {
        cursorDate = nil
        onCursorChange?(nil)
      }
  }

  private var onCursorTap: ((TimeInterval?) -> Void)? {
    allowsCursor ? {
      cursorDate = $0.map { frame.newestDate.addingTimeInterval(-$0) }
      onCursorChange?($0)
    } : nil
  }

  @ViewBuilder
  private var plot: some View {
    switch style {
    case .analyzer:
      AnalyzerSpectrumView(
        frame: frame,
        laneHeight: laneHeight,
        selectedPacketID: selectedPacketID,
        selectedRxMs: selectedRxMs,
        onSelectMark: onSelectMark,
        heldAt: heldAt,
        cursor: allowsCursor ? cursor : nil,
        onCursorTap: onCursorTap,
        cornerRadius: cornerRadius
      )
    case .waterfall:
      WaterfallSpectrumView(
        frame: frame,
        channelHz: channelHz,
        bandwidthHz: bandwidthHz,
        laneHeight: laneHeight,
        selectedPacketID: selectedPacketID,
        selectedRxMs: selectedRxMs,
        onSelectMark: onSelectMark,
        heldAt: heldAt,
        cursor: allowsCursor ? cursor : nil,
        onCursorTap: onCursorTap,
        cornerRadius: cornerRadius
      )
    case .modern, .radioScreen, .lineChart:
      MiniSpectrumView(
        frame: frame,
        laneHeight: laneHeight,
        isOnDarkGlass: true,
        selectedPacketID: selectedPacketID,
        selectedRxMs: selectedRxMs,
        onSelectMark: onSelectMark,
        heldAt: heldAt,
        cursor: allowsCursor ? cursor : nil,
        onCursorTap: onCursorTap,
        cornerRadius: cornerRadius
      )
    }
  }
}

// MARK: - Dashboard tile

/// Live traffic across Home's width, on the same card as the others: the readings on the title row, the
/// plot with its scale, and the latest packet, all from the app's one `SpectrumFeed`. Opens the Traffic page.
///
/// Filling the height (the Dashboard on iPad), the card stretches to the bottom of the screen: the
/// plot shares it with the latest packets in the Spectrum tab's columns, as many whole rows as fit.
struct HomeTrafficCard: View {
  @Environment(\.appState) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  /// Stretch to the height offered, with a taller plot and the latest packets under it.
  var fillsHeight = false

  /// The most packets the tall card lists; the rows that fit show, newest first.
  private static let packetRows = 30

  /// The Spectrum tab's chart style: the card's plot follows it.
  @AppStorage(AppStorageKey.spectrumChartStyle.rawValue)
  private var chartStyleRaw = 0

  private var spectrum: SpectrumViewModel { appState.spectrumFeed.model }
  private var chartStyle: SpectrumChartStyle { .stored(chartStyleRaw) }

  /// The radio's channel, for the Line Chart and the Radio Screen's airtime; nil without a radio.
  private var channel: LoRaChannelMath? {
    guard let device = appState.connectedDevice else { return nil }
    return LoRaChannelMath(
      frequencyHz: Double(device.frequency) * 1000,
      bandwidthHz: Double(device.bandwidth),
      spreadingFactor: Int(device.spreadingFactor),
      codingRate: Int(device.codingRate)
    )
  }

  /// The plot in the chosen style, every style the Spectrum tab offers: the Radio Screen's
  /// density view fitted to the card's height (from the radio's own view or the app's readings,
  /// as there), the Line Chart from the app's readings, the rest on their dark glass.
  @ViewBuilder
  private func plot(_ frame: MiniSpectrumFrame, now: Date) -> some View {
    switch chartStyle {
    case .radioScreen:
      GeometryReader { geometry in
        let history = SpectrumRadioScreenSource.history(
          viewModel: spectrum,
          window: appState.spectrumFeed.window,
          columns: SpectrumFeed.deviceColumns(horizontalSizeClass),
          now: now,
          channel: channel
        )
        SpectrumDeviceCanvas(
          history: history,
          layout: {
            var layout = SpectrumDeviceLayout(traceHeight: max(geometry.size.height - SpectrumDeviceLayout.laneHeight, 40), densityHeight: 0)
            layout.cornerRadius = Self.cornerRadius
            return layout
          }(),
          cursor: nil,
          selectedMark: nil,
          showsKeys: false,
          motion: SpectrumRadioScreenSource.motion(viewModel: spectrum, window: appState.spectrumFeed.window, history: history),
          heldAt: spectrum.pausedAt
        )
      }
    case .lineChart:
      if let channel {
        SpectrumChannelChart(
          channel: channel,
          viewModel: spectrum,
          packets: spectrum.packets.elements,
          window: appState.spectrumFeed.window,
          now: now,
          selectedPacketID: .constant(nil)
        )
        .lineChartPanel(cornerRadius: Self.cornerRadius)
      } else {
        styledPlot(frame, style: .modern)
      }
    case .modern, .analyzer, .waterfall:
      styledPlot(frame, style: chartStyle)
    }
  }

  private func styledPlot(_ frame: MiniSpectrumFrame, style: SpectrumChartStyle) -> some View {
    let device = appState.connectedDevice
    return StyledSpectrumPlot(
      style: style,
      frame: frame,
      channelHz: device.map { Double($0.frequency) * 1000 },
      bandwidthHz: device.map { Double($0.bandwidth) },
      laneHeight: 12,
      allowsCursor: false,
      cornerRadius: Self.cornerRadius
    )
  }

  /// The plot's corners on the card: rounder than the Spectrum tab's, nearer the card's own.
  private static let cornerRadius: CGFloat = 16

  var body: some View {
    // Once a second, so the plot moves along between the radio's readings.
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let frame = appState.spectrumFeed.frame(barCount: chartStyle.barCount(horizontalSizeClass), now: context.date)
      let recent = spectrum.packets.elements.filter { context.date.timeIntervalSince($0.date) < 60 }
      let rate = L10n.Tools.Tools.Spectrum.Figure.perMinute(recent.count.formatted())
      HomeCard(
        title: L10n.Tools.Tools.Traffic.title,
        systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill",
        tint: .blue,
        // Always shown, "0/min" included, so the title row never changes with the traffic.
        pill: rate,
        pillIsReading: true,
        accessibilityValue: accessibilityValue(frame: frame, rate: rate),
        hint: L10n.Tools.Tools.Traffic.subtitle,
        titleDetail: {
          MiniSpectrumTitleReadings(now: spectrum.nowRSSI, floor: spectrum.currentNoiseFloor, peak: frame.peak)
        },
        content: {
          if fillsHeight {
            // The plot and the packets share the card's height evenly.
            plot(frame, now: spectrum.displayNow(max(context.date, Date())))
              .frame(minHeight: 160, maxHeight: .infinity)
              .padding(.top, 4)
            if chartStyle.showsTimeAxis {
              MiniSpectrumTimeAxis(window: appState.spectrumFeed.window)
            }
            recentPackets(now: max(context.date, Date()))
              .frame(minHeight: 120, maxHeight: .infinity, alignment: .top)
              .padding(.top, 10)
          } else {
            // The plot takes the card between its title and the footer.
            // shorter on the phone's Dashboard (was 140, then 96; the user, 2026-11-09: so the page fits,
            // then a tad taller)
            plot(frame, now: spectrum.displayNow(max(context.date, Date())))
              .frame(height: 112)
              .padding(.top, 2)
            latestLine
          }
        }
      )
    }
    .modifier(SpectrumFeedViewer())
  }

  /// The newest packet in a line: its kind, how far it came and its signal. One height, so a first
  /// packet doesn't move the card.
  private var latestLine: some View {
    HStack(spacing: 6) {
      if let packet = spectrum.latestPacket {
        SpectrumKindPill(kind: packet.kind, showsName: true)
        Text(NodeRouteFormat.joined([
          packet.routeTitle,
          packet.snr.map { "\(SpectrumPacketFormat.snr($0)) dB" },
        ]))
        .font(.caption)
        .foregroundStyle(HomeCardDetail.ink)
        .lineLimit(1)
        Spacer(minLength: 0)
        Text(packet.date, format: .dateTime.hour().minute().second())
          .font(.caption.monospacedDigit())
          .foregroundStyle(Color.secondary)
      } else {
        Text(L10n.Tools.Tools.RxLog.listening)
          .font(.caption)
          .foregroundStyle(Color.secondary)
        Spacer(minLength: 0)
      }
    }
    .frame(minHeight: 22)
  }

  /// The latest packets as the Spectrum tab's traffic table lists them, newest first, drawn
  /// straight on the card: the column titles, then as many whole rows as the height holds. Until
  /// the first packet, Listening… in the first row's place, so nothing moves when it lands.
  private func recentPackets(now: Date) -> some View {
    let packets = Array(spectrum.packets.elements.suffix(Self.packetRows).reversed())
    return VStack(alignment: .leading, spacing: 0) {
      SpectrumTrafficRow.header
        .padding(.bottom, 4)
      WholeRowsLayout {
        if packets.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text(L10n.Tools.Tools.RxLog.listening)
              .font(.subheadline)
              .foregroundStyle(Color.secondary)
              .padding(.vertical, 8)
          }
        } else {
          ForEach(packets) { packet in
            VStack(spacing: 0) {
              Divider()
              SpectrumTrafficRow(packet: packet, now: now, stacked: false)
                .padding(.vertical, 8)
            }
          }
        }
      }
      .clipped()
    }
  }

  private func accessibilityValue(frame: MiniSpectrumFrame, rate: String) -> String {
    [
      spectrum.nowRSSI.map { "\(L10n.Tools.Tools.Spectrum.Meter.now) \(SpectrumFormat.dBm($0))" },
      spectrum.currentNoiseFloor.map { "\(L10n.Tools.Tools.Spectrum.Meter.floor) \(SpectrumFormat.dBm($0))" },
      frame.peak.map { "\(L10n.Tools.Tools.Spectrum.Meter.peak) \(SpectrumFormat.dBm($0))" },
      rate,
    ].compactMap(\.self).joined(separator: ", ")
  }
}

/// Rows from the top, as many whole ones as the height it is offered holds; the rest sit just below
/// its bounds, for the caller to clip, so no row is ever cut in half. Asked for its ideal height, it
/// is as tall as all its rows.
struct WholeRowsLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
      ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    if let height = proposal.height, height.isFinite {
      return CGSize(width: width, height: height)
    }
    let rows = ProposedViewSize(width: width, height: nil)
    return CGSize(width: width, height: subviews.reduce(0) { $0 + $1.sizeThatFits(rows).height })
  }

  func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
    var y = bounds.minY
    var fits = true
    for subview in subviews {
      let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
      fits = fits && y + height <= bounds.maxY + 0.5
      subview.place(
        at: CGPoint(x: bounds.minX, y: fits ? y : bounds.maxY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: height)
      )
      if fits { y += height }
    }
  }
}
