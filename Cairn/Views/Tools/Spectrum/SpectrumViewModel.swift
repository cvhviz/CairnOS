import Foundation
import CairnServices
import MeshCore
import OSLog

/// Live readings for the Spectrum tab. A companion radio can't sweep the band or sample its
/// instantaneous RSSI over the app link; what it reports is its averaged noise floor, its airtime
/// counters, and every packet it hears (the RX log). So this keeps Cairn's Channel view where the
/// protocol allows: a noise-floor history, the packets on the same time axis, and the figures
/// derived from both. Band scanning stays on the radio's own screen.
///
/// A Cairn radio that sends its own Channel view (firmware's `net/SPEC_SYNC.md`) feeds the page
/// from that instead: its columns, marks, readings and 24 h trend, polled while the page is on
/// screen (``Source/device``). Stock MeshCore radios, the SF32 port and older Cairn builds keep
/// the readings above (``Source/legacy``).
@Observable
@MainActor
final class SpectrumViewModel {
  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "SpectrumViewModel")

  /// 2048 readings: about 68 minutes at Live's 2 s, nearly three hours at Normal's 5 s, so
  /// either covers the longest window the chart offers.
  static let noiseCapacity = 2048
  /// A day of one-minute floor averages for the history sparkline (Cairn's "NF 24h").
  static let floorHistoryCapacity = 24 * 60
  /// Cairn keeps 2048 packet marks: about 34 a minute for a full hour.
  static let packetCapacity = 2048
  /// The RX log is read back this far when the tab opens, so the longest window starts full.
  static let packetLookback: TimeInterval = 3600

  /// Where the page's readings come from.
  enum Source: Equatable {
    /// Asking the radio whether it sends its own Channel view.
    case probing
    /// The radio's own Channel view (``deviceHistory``, ``deviceTrend``).
    case device
    /// The radio statistics poll and the RX log.
    case legacy
  }

  private(set) var source: Source = .probing
  /// The radio's Channel view, in ``Source/device``.
  private(set) var deviceHistory = SpectrumDeviceHistory(
    window: SpectrumWindow.oneMinute.deviceIndex, ncols: SpectrumDeviceFeed.compactColumns
  )
  /// The radio's 24 h noise-floor trend, in ``Source/device``; nil until the first arrives and
  /// after a retune.
  private(set) var deviceTrend: CairnSpectrumTrend?
  /// When ``deviceTrend`` arrived: its last point ends then.
  private(set) var deviceTrendDate: Date?
  /// When the reply behind the radio's latest readings arrived: its `nowMs` was then, which dates
  /// its marks.
  private(set) var deviceStatsDate: Date?
  /// Where the radio's slots fall on the phone's clock, for the plots that scroll between replies.
  private(set) var deviceSlotClock = SpectrumDeviceSlotClock()
  /// The page's window, for the radio's Channel view. A change starts the view over at once: the
  /// poll in flight is dropped and a FULL for the new window goes out.
  var deviceWindow: SpectrumWindow = .oneMinute {
    didSet { if deviceWindow != oldValue { restartDeviceView() } }
  }
  /// Columns across the radio's view: 180 at compact width, 240 at regular. A change starts the
  /// view over, as a new window does, since the radio's slot grid changes with it.
  var deviceColumns = SpectrumDeviceFeed.compactColumns {
    didSet { if deviceColumns != oldValue { restartDeviceView() } }
  }

  private(set) var noise = RingBuffer<NoiseSample>(capacity: noiseCapacity)
  private(set) var floorHistory = RingBuffer<NoiseSample>(capacity: floorHistoryCapacity)
  private(set) var airtime = RingBuffer<AirtimeSample>(capacity: noiseCapacity)
  private(set) var packets = RingBuffer<SpectrumPacket>(capacity: packetCapacity)
  /// Which way the floor has moved over the readings kept; nil until there are any. Worked out
  /// as each reading lands rather than on every redraw of the meters.
  private(set) var noiseTrend: NoiseTrend?
  private(set) var isCalibrating = false
  private(set) var errorMessage: String?
  /// The radio's firmware has no stats command (companion before v1.11): no noise or airtime
  /// readings come, only packets.
  private(set) var statsUnsupported = false
  /// When this session's first noise reading arrived: how far back the chart's readings reach.
  private(set) var samplingSince: Date?
  /// The radio's own last-packet RSSI, for NOW when the RX log has nothing to offer.
  private(set) var radioLastRSSI: Double?
  /// The chart's held dB bottom (`SpectrumTraceScale.heldBottom`), moved by each floor reading
  /// once the floor has drifted far enough; nil until the first. The page resets it when the
  /// channel or the window changes, so a new view starts from its own floor.
  private(set) var traceBottom: Double?
  /// Seconds between the radio's statistics readings while the tab is on screen (Spectrum
  /// Settings' update rate). The poll loop re-reads it on each pass, so a change applies after
  /// the current wait without restarting the packet stream.
  var readingInterval: TimeInterval = SpectrumUpdateRate.normal.interval

  /// While paused, the moment the chart holds: its window stops advancing and the ages freeze,
  /// while the readings keep landing behind it. Nil while live.
  private(set) var pausedAt: Date?

  var isPaused: Bool { pausedAt != nil }

  /// Holds the chart at `now`, or lets it go on.
  func setPaused(_ paused: Bool, now: Date = Date()) {
    pausedAt = paused ? (pausedAt ?? now) : nil
  }

  /// The moment the chart draws for: `now` while live, the held moment while paused.
  func displayNow(_ now: Date) -> Date {
    pausedAt ?? now
  }

  /// The radio whose minute floor averages go to ``readingsStore``; nil keeps none.
  var readingsRadioID: UUID?
  /// Where the minute averages are kept between sessions, per radio.
  var readingsStore: SpectrumReadingsStore = .shared

  /// The minute being averaged into `floorHistory`.
  private var openMinute: (minute: Int, total: Double, count: Int)?
  /// The probe, then the radio statistics poll when the radio has no view of its own.
  private var pollTask: Task<Void, Never>?
  /// The radio's own view: HISTORY on the window's cadence.
  private var deviceTask: Task<Void, Never>?
  private var packetTask: Task<Void, Never>?
  private var trendTask: Task<Void, Never>?
  /// The session the radio's own view reads from while it runs, to restart its HISTORY loop for a
  /// new window and its TREND loop after a retune. Dropped on ``stop()``, so a link that went away
  /// isn't kept alive by the page.
  private var feedSession: MeshCoreSession?
  /// HISTORY transfers in a row that didn't complete; past a couple the poll slows down.
  private var deviceFailures = 0
  /// When the radio's floor last went into the noise ring, which the device feed fills at Live's
  /// pace rather than at every poll.
  private var lastDeviceFloorRecord: Date?
  /// The session the readings came from; a different one means a different or rebooted link.
  private var sessionID: ObjectIdentifier?

  // MARK: - Derived

  var currentNoiseFloor: Double? {
    if source == .device { return deviceStats?.floor.map(Double.init) }
    return noise.last?.dBm
  }

  var latestPacket: SpectrumPacket? { packets.last }

  /// The radio's readings, in ``Source/device``.
  var deviceStats: CairnSpectrumStats? {
    source == .device ? deviceHistory.stats : nil
  }

  /// NOW: the latest packet's strength, or the radio's own last reading before one arrives. From
  /// the radio's own view, its live reading.
  var nowRSSI: Double? {
    if source == .device { return deviceStats?.nowRSSI.map(Double.init) }
    return latestPacket?.rssi ?? radioLastRSSI
  }

  /// The noise floor a minute at a time, with the minute still open as its last point. From the
  /// radio's own view, its 24 h trend once it has arrived.
  var floorTrend: [NoiseSample] {
    if source == .device, let deviceTrend, let deviceTrendDate {
      return Self.samples(of: deviceTrend, endingAt: deviceTrendDate)
    }
    var trend = floorHistory.elements
    if let openMinute {
      trend.append(NoiseSample(
        date: Date(timeIntervalSince1970: Double(openMinute.minute) * 60 + 30),
        dBm: openMinute.total / Double(openMinute.count)
      ))
    }
    return trend
  }

  /// Since when packets have been counted: the oldest packet the RX log handed back, or when
  /// this session started reading.
  var packetsObservedSince: Date? {
    [samplingSince, packets.first?.date].compactMap(\.self).min()
  }

  // MARK: - Lifecycle

  /// Starts reading from `session`, replacing whatever was running. Readings from a different
  /// session are dropped first: they belong to another radio, or to this one before it restarted.
  /// The packets' nodes are named by the app's `ObservationDirectory` where they are shown, as
  /// the RX Log list names them.
  func start(session: MeshCoreSession, rxLogService: RxLogService?) {
    stop()
    let id = ObjectIdentifier(session)
    if sessionID != id {
      reset()
      sessionID = id
    }
    errorMessage = nil

    #if DEBUG && targetEnvironment(simulator)
      if let demo = SpectrumDemo.requested {
        pollTask = Task { [weak self] in await self?.runDemo(demo) }
        return
      }
    #endif

    if let rxLogService {
      packetTask = Task { [weak self] in
        await self?.followPackets(rxLogService)
      }
    }
    pollTask = Task { [weak self] in
      guard let useDevice = await self?.probeDeviceFeed(session), !Task.isCancelled, let self else { return }
      if useDevice {
        source = .device
        feedSession = session
        startTrend(session: session)
        startDevicePolls(session: session)
      } else {
        startLegacyPolls(session: session)
      }
    }
  }

  /// Ends every loop and lets go of the session, so a closed link's session is released.
  func stop() {
    pollTask?.cancel()
    deviceTask?.cancel()
    packetTask?.cancel()
    trendTask?.cancel()
    pollTask = nil
    deviceTask = nil
    packetTask = nil
    trendTask = nil
    feedSession = nil
  }

  /// HISTORY on the window's cadence, timed from each poll's start: the radio's minimum interval
  /// runs from its reply, and the radio owns the slot grid, so there is no drift to correct.
  /// Replaces the loop running, dropping its poll in flight.
  private func startDevicePolls(session: MeshCoreSession) {
    deviceTask?.cancel()
    deviceTask = Task { [weak self] in
      let clock = ContinuousClock()
      while !Task.isCancelled {
        let started = clock.now
        guard let self else { return }
        guard let wait = await pollDevice(session: session) else {
          guard !Task.isCancelled else { return }
          // the radio stopped offering its view: carry on with its statistics
          trendTask?.cancel()
          trendTask = nil
          feedSession = nil
          deviceTask = nil
          startLegacyPolls(session: session)
          return
        }
        try? await Task.sleep(until: max(started + wait, clock.now), clock: clock)
      }
    }
  }

  /// The radio statistics poll, for a radio without a view of its own. Stops for good on firmware
  /// without the stats command (official companion firmware before v1.11), leaving the packets.
  private func startLegacyPolls(session: MeshCoreSession) {
    source = .legacy
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      // A radio that already answered unsupported on this connection isn't asked again.
      if await session.statsSupport == false {
        self?.markStatsUnsupported()
        return
      }
      let clock = ContinuousClock()
      // On a fixed cadence rather than a fixed pause after each reading: the round trip would
      // otherwise stretch every interval, and the readings drift out of the chart's columns.
      var deadline = clock.now
      while !Task.isCancelled {
        guard let self else { return }
        guard await poll(session: session) else { return }
        deadline += .seconds(readingInterval)
        // A reading that overran its slot (a slow link) restarts the cadence instead of
        // firing a burst to catch up.
        if deadline < clock.now { deadline = clock.now }
        try? await Task.sleep(until: deadline, clock: clock)
      }
    }
  }

  /// Drops the chart's held scale for a new channel or window: the next floor reading seeds it again.
  func resetTraceScale() {
    // nil, not the current floor: after a retune that is still the old channel's last reading; the
    // chart follows the live floor until the new channel's first one seeds the hold
    traceBottom = nil
  }

  private func reset() {
    traceBottom = nil
    noise.removeAll()
    floorHistory.removeAll()
    airtime.removeAll()
    packets.removeAll()
    noiseTrend = nil
    openMinute = nil
    isCalibrating = false
    statsUnsupported = false
    samplingSince = nil
    radioLastRSSI = nil
    source = .probing
    deviceTrend = nil
    deviceTrendDate = nil
    deviceStatsDate = nil
    lastDeviceFloorRecord = nil
    resetDeviceHistory()
  }

  /// A new window or width: the view starts over, and while the radio's view is being polled, the
  /// poll in flight (for the old grid, whose reply would be passed by) is dropped and the FULL for
  /// the new one goes out now rather than after it.
  private func restartDeviceView() {
    resetDeviceHistory()
    if deviceTask != nil, let feedSession { startDevicePolls(session: feedSession) }
  }

  /// Starts the radio's view over for the current window and width: the next poll asks for all of it.
  private func resetDeviceHistory() {
    deviceHistory.reset(window: deviceWindow.deviceIndex, ncols: deviceColumns)
    deviceSlotClock.reset()
    deviceFailures = 0
  }

  // MARK: - Recording

  func record(noiseFloor: Double, at date: Date = Date()) {
    // The firmware reports 0 until its sample average has converged; like Cairn, nothing at or
    // above -40 dBm counts as a floor.
    guard SpectrumStats.acceptsFloor(noiseFloor) else {
      isCalibrating = true
      return
    }
    isCalibrating = false
    traceBottom = SpectrumTraceScale.heldBottom(previous: traceBottom, floor: noiseFloor)
    if samplingSince == nil { samplingSince = date }
    noise.append(NoiseSample(date: date, dBm: noiseFloor))
    noiseTrend = NoiseTrend(readings: noise.elements.map(\.dBm))
    recordMinute(noiseFloor, at: date)
  }

  private func recordMinute(_ dBm: Double, at date: Date) {
    let minute = Int(floor(date.timeIntervalSince1970 / 60))
    if let open = openMinute, open.minute == minute {
      openMinute = (minute, open.total + dBm, open.count + 1)
      return
    }
    if let open = openMinute, minute > open.minute {
      let closed = NoiseSample(
        date: Date(timeIntervalSince1970: Double(open.minute) * 60 + 30),
        dBm: open.total / Double(open.count)
      )
      floorHistory.append(closed)
      // A closed minute is worth keeping: the export reaches back a week.
      if let radioID = readingsRadioID {
        let store = readingsStore
        let sample = SpectrumReadingsStore.Sample(date: closed.date, dBm: closed.dBm)
        Task { await store.append(sample, radioID: radioID) }
      }
    }
    // A reading stamped earlier than the open minute (a clock step) restarts it rather than
    // writing history out of order.
    openMinute = (minute, dBm, 1)
  }

  func record(airtime tx: UInt32, rx: UInt32, at date: Date) {
    airtime.append(AirtimeSample(date: date, tx: tx, rx: rx))
  }

  /// Adds packets, keeping them in time order and each one once: the RX log read-back and its
  /// live stream can overlap while the tab opens.
  func record(packets newPackets: [SpectrumPacket]) {
    guard !newPackets.isEmpty else { return }
    let current = packets.elements
    if let last = current.last, newPackets.allSatisfy({ $0.date >= last.date }) {
      let recent = Set(current.suffix(64).map(\.id))
      for packet in newPackets where !recent.contains(packet.id) {
        packets.append(packet)
      }
      return
    }
    var seen = Set<UUID>()
    let merged = (current + newPackets)
      .filter { seen.insert($0.id).inserted }
      .sorted { $0.date < $1.date }
    packets.removeAll()
    for packet in merged.suffix(Self.packetCapacity) {
      packets.append(packet)
    }
  }

  // MARK: - Radio

  /// One statistics reading; returns whether to keep polling.
  private func poll(session: MeshCoreSession) async -> Bool {
    do {
      let radio = try await session.getStatsRadio()
      let now = Date()
      record(noiseFloor: Double(radio.noiseFloor), at: now)
      record(airtime: radio.txAirtimeSeconds, rx: radio.rxAirtimeSeconds, at: now)
      if radio.lastRSSI != 0 {
        radioLastRSSI = Double(radio.lastRSSI)
      }
      errorMessage = nil
      return true
    } catch {
      return notePollFailure(error)
    }
  }

  /// A failed statistics reading; returns whether to keep polling. Firmware without the stats
  /// command answers `ERR_CODE_UNSUPPORTED_CMD`: polling stops and the page says the radio doesn't
  /// report noise or airtime, instead of failing again every few seconds. Anything else is a
  /// failed read, tried again next time.
  func notePollFailure(_ error: any Error) -> Bool {
    if case let MeshCoreError.deviceError(code) = error, code == ErrorCode.unsupportedCommand.rawValue {
      markStatsUnsupported()
      return false
    }
    Self.logger.warning("Spectrum poll failed: \(error.localizedDescription)")
    errorMessage = L10n.Tools.Tools.NoiseFloor.Error.unableToRead
    return true
  }

  private func markStatsUnsupported() {
    Self.logger.info("Spectrum: radio firmware has no stats command; noise and airtime stop")
    statsUnsupported = true
    errorMessage = L10n.Tools.Tools.NoiseFloor.Error.unsupported
  }

  // MARK: - Radio's own view (SPEC_SYNC)

  /// Whether this radio sends its own Channel view. Asked once per session: a radio that answers
  /// unsupported or unavailable is remembered by the session; a timeout asks again next visit.
  private func probeDeviceFeed(_ session: MeshCoreSession) async -> Bool {
    switch await session.cairnSpectrumSupport {
    case true?: return true
    case false?: return false
    case nil: break
    }
    do {
      let reply = try await session.getCairnSpectrumStats(window: deviceWindow.deviceIndex, timeout: 4)
      switch reply.status {
      case .ok, .busy, .tooSoon: return true
      case .unavailable, .other: return false
      }
    } catch {
      Self.logger.info("Spectrum: radio has no Channel feed (\(error.localizedDescription)); using radio stats")
      return false
    }
  }

  /// The next HISTORY poll. After transfers keep failing (a crowded link) it also stops asking for
  /// the marks still behind the cursor, so the transfers that follow are smaller.
  var nextDeviceRequest: CairnSpectrumHistoryRequest {
    deviceHistory.nextRequest(skippingMarkBacklog: deviceFailures >= SpectrumDeviceFeed.slowAfterFailures)
  }

  /// One HISTORY poll; returns how long after its start the next one goes, or nil when the radio
  /// no longer offers its view.
  private func pollDevice(session: MeshCoreSession) async -> Duration? {
    let request = nextDeviceRequest
    do {
      let history = try await session.fetchCairnSpectrumHistory(request)
      guard !Task.isCancelled else { return .zero }
      switch history.reply.status {
      case .ok:
        return applyDevice(history)
      case .busy:
        return SpectrumDeviceFeed.busyBackoff
      case .tooSoon:
        return SpectrumDeviceFeed.tooSoonBackoff
      case .unavailable:
        return nil
      case .other:
        return deviceWindow.deviceCadence
      }
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      return nil
    } catch {
      // dropped for a new window or a closed link: not a failed read
      guard !Task.isCancelled else { return .zero }
      Self.logger.warning("Spectrum HISTORY failed: \(error.localizedDescription)")
      errorMessage = L10n.Tools.Tools.NoiseFloor.Error.unableToRead
      return .seconds(1)
    }
  }

  /// Folds a HISTORY into the page; returns the wait before the next poll. Its readings and the
  /// time its reply arrived (which dates the marks) go in only with its columns.
  @discardableResult
  func applyDevice(_ history: CairnSpectrumHistory) -> Duration {
    let outcome = deviceHistory.apply(history)
    errorMessage = nil
    if outcome.applied, let stats = deviceHistory.stats {
      deviceStatsDate = history.receivedAt
      deviceSlotClock.observe(
        nowSlot: deviceHistory.nowSlot, nowMs: stats.nowMs, epoch: stats.epoch, isRaw: deviceHistory.isRaw,
        window: deviceWindow.duration, ncols: deviceHistory.ncols, receivedAt: history.receivedAt
      )
      recordDevice(stats, at: history.receivedAt)
    }
    if outcome.epochChanged {
      // a retune: the radio cleared its 24 h trend, so the page drops it and asks again at once
      deviceTrend = nil
      deviceTrendDate = nil
      if trendTask != nil, let feedSession { startTrend(session: feedSession) }
    }
    deviceFailures = history.completed ? 0 : deviceFailures + 1
    if history.completed, deviceHistory.marksMore > 0 {
      return SpectrumDeviceFeed.minimumInterval
    }
    return deviceFailures >= SpectrumDeviceFeed.slowAfterFailures ? .seconds(1) : deviceWindow.deviceCadence
  }

  /// The radio's readings into the page's own: NOW from its live reading, and its floor into the
  /// noise ring at Live's pace, so the floor's direction and the meters keep working.
  private func recordDevice(_ stats: CairnSpectrumStats, at date: Date) {
    if let now = stats.nowRSSI { radioLastRSSI = Double(now) }
    isCalibrating = stats.floor == nil
    if let last = lastDeviceFloorRecord, date.timeIntervalSince(last) < SpectrumUpdateRate.live.interval,
       date >= last {
      return
    }
    lastDeviceFloorRecord = date
    record(noiseFloor: stats.floor.map(Double.init) ?? 0, at: date)
  }

  /// The TREND loop: now, then every 10 s.
  private func startTrend(session: MeshCoreSession) {
    trendTask?.cancel()
    trendTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let wait = await self?.fetchDeviceTrend(session: session) else { return }
        try? await Task.sleep(for: wait)
      }
    }
  }

  private func fetchDeviceTrend(session: MeshCoreSession) async -> Duration {
    do {
      let reply = try await session.fetchCairnSpectrumTrend(points: SpectrumDeviceFeed.trendPoints)
      guard !Task.isCancelled else { return .zero }
      switch reply.status {
      case .ok:
        if let trend = reply.trend { applyDevice(trend: trend) }
        return SpectrumDeviceFeed.trendInterval
      case .tooSoon:
        return SpectrumDeviceFeed.trendMinimum
      default:
        return SpectrumDeviceFeed.trendInterval
      }
    } catch {
      Self.logger.warning("Spectrum TREND failed: \(error.localizedDescription)")
      return SpectrumDeviceFeed.trendInterval
    }
  }

  func applyDevice(trend: CairnSpectrumTrend, at date: Date = Date()) {
    // a trend from before a retune would be the old channel's
    if let epoch = deviceHistory.stats?.epoch, epoch != trend.epoch { return }
    deviceTrend = trend
    deviceTrendDate = date
  }

  /// The radio's trend as floor samples: oldest first across the day, each at its slice's middle.
  static func samples(of trend: CairnSpectrumTrend, endingAt end: Date) -> [NoiseSample] {
    guard !trend.points.isEmpty else { return [] }
    let slice = 86_400 / Double(trend.points.count)
    let start = end.addingTimeInterval(-86_400)
    return trend.points.enumerated().compactMap { index, point in
      point.map { NoiseSample(date: start.addingTimeInterval((Double(index) + 0.5) * slice), dBm: Double($0)) }
    }
  }

  /// The RX log's last hour, then every packet it records while the tab is open. Subscribing
  /// before reading back means a packet that lands in between is caught by one or the other.
  private func followPackets(_ service: RxLogService) async {
    let stream = service.entryStream()
    let recent = await service.recentEntries(since: Date().addingTimeInterval(-Self.packetLookback))
    guard !Task.isCancelled else { return }
    record(packets: recent.reversed().map(SpectrumPacket.init(entry:)))
    for await entry in stream {
      guard !Task.isCancelled else { return }
      record(packets: [SpectrumPacket(entry: entry)])
    }
  }
}

#if DEBUG && targetEnvironment(simulator)
  /// Made-up readings for UI tests: the simulator's mock radio reports no radio statistics.
  /// `-uiTestSpectrumDemo 1` starts empty and fills in live; `2` starts with an hour of history.
  /// Both add packets of every common kind, so the lane and the traffic list have content. `3` is a
  /// Cairn radio sending its own Channel view (``SpectrumViewModel/Source/device``).
  enum SpectrumDemo: Int {
    case live = 1
    case fullHistory = 2
    case device = 3

    static var requested: SpectrumDemo? {
      SpectrumDemo(rawValue: UserDefaults.standard.integer(forKey: "uiTestSpectrumDemo"))
    }
  }

  private struct DemoPacket {
    let type: PayloadType
    let route: RouteType
    let rssi: Int
    let snr: Double
    let path: [UInt8]
    let payload: [UInt8]
    var channel: String?
  }

  extension SpectrumViewModel {
    fileprivate func runDemo(_ demo: SpectrumDemo) async {
      if demo == .device {
        await runDeviceDemo()
        return
      }
      source = .legacy
      var step = 0
      var airtime = (tx: UInt32(100), rx: UInt32(1000))
      if demo == .fullHistory {
        let now = Date()
        var backfill: [SpectrumPacket] = []
        for back in stride(from: Int(Self.packetLookback), through: 2, by: -2) {
          let date = now.addingTimeInterval(-Double(back))
          addDemoNoise(step: step, at: date)
          if step % 5 == 0 {
            airtime.rx += step % 3 == 0 ? 1 : 0
            airtime.tx += step % 40 == 0 ? 1 : 0
            record(airtime: airtime.tx, rx: airtime.rx, at: date)
          }
          if step % 9 == 4 { backfill.append(Self.demoPacket(step: step, at: date)) }
          step += 1
        }
        record(packets: backfill)
      }
      while !Task.isCancelled {
        let now = Date()
        addDemoNoise(step: step, at: now)
        airtime.rx += step % 3 == 0 ? 1 : 0
        airtime.tx += step % 40 == 0 ? 1 : 0
        record(airtime: airtime.tx, rx: airtime.rx, at: now)
        if step % 3 == 1 { record(packets: [Self.demoPacket(step: step, at: now)]) }
        step += 1
        try? await Task.sleep(for: .seconds(readingInterval))
      }
    }

    /// A Cairn radio's view: a floor near -112 dBm with its scatter, packets every few seconds of
    /// every common type, a stretch of interference, a TX slot or two, and a day's floor trend with
    /// a heavy hour. Each second the radio's slot grid moves on and a fresh FULL lands.
    private func runDeviceDemo() async {
      source = .device
      let started = Date()
      let radioStart: UInt32 = 3_600_000
      var step = 0
      applyDevice(trend: Self.demoTrend(), at: started)
      while !Task.isCancelled {
        let now = Date()
        let elapsed = UInt32(now.timeIntervalSince(started) * 1000)
        let nowMs = radioStart &+ elapsed
        applyDevice(Self.demoHistory(window: deviceWindow, ncols: deviceColumns, nowMs: nowMs, receivedAt: now))
        if deviceTrend == nil { applyDevice(trend: Self.demoTrend(), at: now) }
        if step % 3 == 1 { record(packets: [Self.demoPacket(step: step, at: now)]) }
        step += 1
        try? await Task.sleep(for: .seconds(1))
      }
    }

    private static let demoEpoch: UInt16 = 7

    private static func demoTrend() -> CairnSpectrumTrend {
      let points: [Int8?] = (0..<160).map { index in
        if index < 6 { return nil }
        if (96..<104).contains(index) { return -103 }
        return Int8(-113 + Int((sin(Double(index) / 9) * 1.6).rounded()))
      }
      return CairnSpectrumTrend(epoch: demoEpoch, thermal: -114, have: 154, points: points)
    }

    /// A pseudo-random 0..<1 for a slot, stable as the grid moves.
    private static func demoNoise(_ slot: Int, _ salt: Int) -> Double {
      let value = sin(Double(slot) * 12.9898 + Double(salt) * 78.233) * 43758.5453
      return value - value.rounded(.down)
    }

    private static func demoHistory(window: SpectrumWindow, ncols: Int, nowMs: UInt32, receivedAt: Date) -> CairnSpectrumHistory {
      let windowMs = UInt64(SpectrumDeviceHistory.windowMilliseconds[Int(window.deviceIndex)])
      let nowSlot = UInt32(UInt64(nowMs) * UInt64(ncols) / windowMs)
      let floor = -112
      let scaleLo = -120
      let headers: [UInt8] = [0x11, 0x0A, 0x15, 0x0E, 0x26, 0x21]
      var columns: [CairnSpectrumColumn?] = []
      var marks: [CairnSpectrumMark] = []
      var peak: (value: Int, back: Int)?
      for index in 0..<ncols {
        let back = ncols - 1 - index
        let slot = Int(nowSlot) - back
        let jitter = Int((demoNoise(slot, 1) * 4).rounded(.down))
        // a packet every 23 slots, a few columns wide; an interferer for a stretch; TX now and then
        let packet = slot % 23 < 2 + slot / 23 % 3
        let interferer = (slot / 11) % 17 == 4
        let transmitting = slot % 97 == 50
        if transmitting {
          columns.append(CairnSpectrumColumn(isData: false, isTX: true))
          continue
        }
        var low = floor - 3 - jitter / 2
        var high = floor + 2 + jitter
        if interferer { high = floor + 9 + jitter; low = floor + 2 }
        let level = -96 + Int(demoNoise(slot / 23, 2) * 30) - (slot % 23) * 4
        if packet { high = max(high, level) }
        var occupancy = [UInt8](repeating: 0, count: CairnSpectrumColumn.rows)
        func fill(_ dBm: Int, _ heat: Int) {
          let row = min(max((dBm - scaleLo) / 2, 0), CairnSpectrumColumn.rows - 1)
          occupancy[row] = UInt8(max(Int(occupancy[row]), heat))
        }
        fill(floor - 2, 14 + jitter)
        fill(floor, 26 + jitter)
        fill(floor + 2, 18 + jitter)
        if interferer { fill(floor + 6, 22); fill(floor + 8, 16) }
        if packet { fill(level, 9 + jitter) }
        let busy = interferer ? 60 : (packet ? 20 : 2)
        columns.append(CairnSpectrumColumn(
          isData: true, isTX: false, min: Int8(low), max: Int8(high), avg: Int8(floor + jitter / 2),
          nf: Int8(floor - 1), busy: UInt8(busy), occupancy: occupancy
        ))
        if high >= (peak?.value ?? .min) { peak = (high, back) }
        if packet, slot % 23 == 0 {
          let header = headers[(slot / 23) % headers.count]
          let ageMs = UInt32(UInt64(back) * windowMs / UInt64(ncols))
          marks.append(CairnSpectrumMark(
            back: UInt8(clamping: max(0, back - 1)), width: 2, header: header, pathLength: UInt8((slot / 23) % 3),
            rssi: Int8(level), snrX4: Int8(clamping: 4 * (level + 120) / 3), length: 40 + UInt8((slot / 23) % 60),
            rxMs: nowMs &- ageMs
          ))
        }
      }
      let marksInWindow = marks.filter { Int($0.back) < ncols }
      let stats = CairnSpectrumStats(
        floorCalibrated: true, sweeping: false, fast: true, epoch: demoEpoch, nowMs: nowMs,
        frequencyKHz: 910_525, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 5,
        window: window.deviceIndex, nowRSSI: -113, floor: Int8(floor), thermal: -114, busyPercent: 7,
        packetsPerMinuteX10: 60, airX10: 36, rxAirX10: 31, txAirX10: 5, packets: 6, coveredSeconds: 60,
        statsSeconds: 60, peak: peak.map { Int8($0.value) }
      )
      let reply = CairnSpectrumHistoryReply(
        status: .ok, stats: stats, xfer: 1, isFull: true, isRaw: window.deviceIndex < 2, marksReset: true,
        columns: UInt8(ncols), nowSlot: nowSlot, count: UInt8(ncols), scaleLo: Int8(scaleLo),
        refFloor: Int8(floor), peakBack: peak.map { UInt8($0.back) }, marks: UInt8(marksInWindow.count),
        marksMore: 0, frames: 1, markCursor: marksInWindow.last?.rxMs ?? 0
      )
      return CairnSpectrumHistory(reply: reply, columns: columns, marks: marksInWindow, completed: true, receivedAt: receivedAt)
    }

    private func addDemoNoise(step: Int, at date: Date) {
      let wobble = sin(Double(step) / 7) * 2.5 + sin(Double(step) / 2.3)
      record(noiseFloor: (-111 + wobble).rounded(), at: date)
    }

    /// A rotating cast: a flood advert relayed by RPT-Hill, a direct message from Bob, channel
    /// chatter, an ack, a trace and a path, at a strong, a middling and an edge-of-range level.
    private static func demoPacket(step: Int, at date: Date) -> SpectrumPacket {
      let cast: [DemoPacket] = [
        DemoPacket(type: .advert, route: .flood, rssi: -91, snr: 7.25, path: [0x5C, 0x5C], payload: [0x71] + [UInt8](repeating: 0x42, count: 60)),
        DemoPacket(type: .textMessage, route: .direct, rssi: -63, snr: 11, path: [], payload: [0x2B, 0xA3] + [UInt8](repeating: 0x11, count: 30)),
        DemoPacket(type: .groupText, route: .flood, rssi: -88, snr: 8.5, path: [0x5C], payload: [0x11] + [UInt8](repeating: 0x22, count: 40), channel: "#Public"),
        DemoPacket(type: .ack, route: .direct, rssi: -70, snr: 10.25, path: [], payload: [UInt8](repeating: 0x33, count: 4)),
        DemoPacket(type: .trace, route: .direct, rssi: -95, snr: 4.75, path: [0x5C], payload: [UInt8](repeating: 0x44, count: 14)),
        DemoPacket(type: .path, route: .flood, rssi: -112, snr: -4.5, path: [0xA3, 0x5C, 0x71], payload: [UInt8](repeating: 0x55, count: 24)),
      ]
      let pick = cast[(step / 3) % cast.count]
      let parsed = ParsedRxLogData(
        snr: pick.snr,
        rssi: pick.rssi + Int((sin(Double(step)) * 3).rounded()),
        rawPayload: Data(pick.payload + pick.path),
        routeType: pick.route,
        payloadType: pick.type,
        payloadVersion: 0,
        payloadTypeBits: pick.type.rawValue,
        transportCode: nil,
        pathLength: UInt8(pick.path.count),
        pathNodes: pick.path,
        packetPayload: Data(pick.payload)
      )
      let entry = RxLogEntryDTO(
        radioID: UUID(),
        receivedAt: date,
        from: parsed,
        channelName: pick.channel
      )
      return SpectrumPacket(entry: entry)
    }
  }
#endif
