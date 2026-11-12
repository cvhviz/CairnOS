import CairnServices
import CairnUpdateKit
import Foundation
import MeshCore
import OSLog

extension FirmwareUpdateViewModel.Dependencies {
  /// Reads everything from the app's current connection, which is rebuilt when the radio comes
  /// back after its update.
  @MainActor
  static func live(appState: AppState) -> Self {
    Self(
      session: { [appState] in appState.services?.session },
      firmwareName: { [appState] in appState.connectedDevice?.firmwareDisplayName },
      cairnBuild: { [appState] in appState.connectedDevice?.cairnBuild },
      deviceID: { [appState] in appState.connectedDevice?.id },
      holdDevicePages: { [appState] hold in appState.navigation.holdsDevicePagesForUpdate = hold },
      closeDevicePages: { [appState] in
        appState.navigation.holdsDevicePagesForUpdate = false
        appState.navigation.clearPerDeviceSelection()
      }
    )
  }
}

/// An update started from the app (APP_UPDATE.md): STATUS reads the board, the image is fetched
/// and checked before anything changes on the board, START asks the person at the board to allow
/// it, and the board's answer carries Updater mode's address and password. The Bluetooth link then
/// drops by design while the image goes over WiFi with CairnUpdateKit, the same upload the Cairn
/// Updater uses; the board restarts on the new build and the app's own reconnect brings it back.
@Observable
@MainActor
final class FirmwareUpdateViewModel {
  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "FirmwareUpdateViewModel")
  /// The board answers within 60 s of a START; a little more covers the link.
  static let answerTimeout: TimeInterval = 70
  /// How long Updater mode gets to come up on WiFi (and the Local Network prompt to be answered).
  static let connectWindow: Duration = .seconds(30)
  static let connectRetryInterval: Duration = .milliseconds(1500)
  /// How long to wait for the radio to come back after the image was accepted.
  static let reconnectWindow: Duration = .seconds(240)
  /// How long an Allow already on its way is listened for after a CANCEL.
  static let lateAnswerWindow: TimeInterval = 5

  enum Phase: Equatable {
    /// Reading the board's STATUS.
    case checking
    /// The firmware doesn't answer: no update from the app.
    case unsupported
    /// STATUS went unanswered.
    case noAnswer
    /// The board is read; pick an image.
    case ready
    /// Downloading and checking the release.
    case preparing
    /// Checking the phone can reach the board over WiFi before asking.
    case reaching
    /// START sent; waiting for the person at the board.
    case asking
    /// Reaching Updater mode over WiFi.
    case connecting
    /// The image going out, 0...1.
    case sending(Double)
    /// The board took the image and restarts; waiting for the radio to come back.
    case restarting
    /// Back on `build`; `changed` is false when the name stayed the same (a dev build).
    case finished(build: String, changed: Bool)
    /// Back, but still on the old `build`: the board kept its firmware.
    case unchanged(build: String)
    /// The image went out but the radio hasn't come back within the wait.
    case notBack
    /// The board allowed the update but sending failed; it stays in Updater mode a while.
    case interrupted

    /// While true the page can't be left: the board is waiting on this screen.
    var holdsScreen: Bool {
      switch self {
      case .reaching, .asking, .connecting, .sending: true
      default: false
      }
    }
  }

  struct Dependencies {
    var session: @MainActor () -> MeshCoreSession?
    var firmwareName: @MainActor () -> String?
    /// The connected radio's Cairn build number (0 on a dev build), when STATUS isn't answered.
    var cairnBuild: @MainActor () -> UInt16?
    /// Tells the updated radio coming back from another one connecting in its place.
    var deviceID: @MainActor () -> UUID?
    /// Keeps the radio's pages on the stack while the link is down on purpose.
    var holdDevicePages: @MainActor (Bool) -> Void
    /// Releases the hold and pops the radio's pages: another radio came back instead.
    var closeDevicePages: @MainActor () -> Void
  }

  // MARK: - State

  private(set) var phase: Phase = .checking
  private(set) var status: CairnFirmwareStatus?
  private(set) var latest: ReleaseImage?
  private(set) var isCheckingLatest = false
  private(set) var latestFailed = false
  /// The image the confirmation asks about, then the one being sent.
  private(set) var image: FirmwareImage?
  /// The checked release, kept so a cancelled confirmation doesn't download it again.
  private var downloadedRelease: FirmwareImage?
  var showingConfirmation = false
  var showingFileImporter = false
  var errorMessage: String?

  var board: Board? { status.flatMap { Board(realm: $0.realm) } }

  /// Whether the latest release is newer than the board's build; nil when either has no number
  /// (a dev build) or the release isn't known.
  var updateAvailable: Bool? {
    guard let installed = status.flatMap({ cairnBuildNumber($0.build) }),
          let release = latest?.buildNumber else { return nil }
    return release > installed
  }

  /// Whether the busy marker belongs on the latest release's button rather than the file's.
  var isBusyWithRelease: Bool {
    phase == .preparing || (phase == .reaching && image != nil && image?.fileName == latest?.assetName)
  }

  var canStart: Bool {
    phase == .ready && status?.wifi == .connected && deps.session() != nil
  }

  private var deps = Dependencies(
    session: { nil },
    firmwareName: { nil },
    cairnBuild: { nil },
    deviceID: { nil },
    holdDevicePages: { _ in },
    closeDevicePages: {}
  )
  /// Updater mode's address and password, kept for a retry while the board stays in Updater mode.
  private var login: (address: String, password: String)?
  private var buildBefore: String?
  /// The build number the image installs ("Cairn 112" → 112); nil for a dev build or an unnamed file.
  private var expectedBuild: Int?
  /// The radio being updated; only it coming back finishes the update.
  private var updatingDevice: UUID?
  /// Set once the page closed, so a late Allow doesn't hold pages that are gone.
  private var hasLeft = false
  /// Whether the first probe that brings up the Local Network prompt went out.
  private var probedNetwork = false
  private var flowTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?

  func configure(dependencies: Dependencies) {
    deps = dependencies
  }

  // MARK: - Status

  /// Reads the board and, once its board is known, the latest release for it.
  func load() async {
    guard let session = deps.session() else { return }
    phase = .checking
    do {
      let status = try await session.getCairnFirmwareStatus()
      self.status = status
      phase = .ready
      // Ask for Local Network now, while the person is looking, rather than after Allow.
      if !probedNetwork, status.wifi == .connected, let address = status.ipAddress {
        probedNetwork = true
        Task { _ = await LocalNetworkProbe.canReach(address) }
      }
      if latest == nil, !isCheckingLatest {
        await checkLatest()
      }
    } catch let MeshCoreError.deviceError(code) where code == ErrorCode.unsupportedCommand.rawValue {
      phase = .unsupported
    } catch {
      Self.logger.warning("STATUS failed: \(error.localizedDescription)")
      phase = .noAnswer
    }
  }

  private func checkLatest() async {
    guard let board else { return }
    isCheckingLatest = true
    latestFailed = false
    defer { isCheckingLatest = false }
    do {
      latest = try await Releases().latest(for: board)
      FirmwareUpdateHubFlag.record(available: updateAvailable, deviceID: deps.deviceID())
    } catch {
      Self.logger.warning("Latest release: \(error.localizedDescription)")
      latestFailed = true
    }
  }

  /// The radio is ready (again): read it on first open, or finish an update once it is back. While
  /// Updater mode runs the board's Bluetooth is off, so after the image went out (or a send failed),
  /// the radio turning ready again is the board out of Updater mode, on its new build or its old one.
  func radioBecameReady() async {
    switch phase {
    case .checking, .noAnswer:
      await load()
    case .restarting, .notBack, .interrupted:
      guard deps.deviceID() == updatingDevice else {
        // Another radio connected in place of the one being updated: its pages aren't for it.
        reconnectTask?.cancel()
        endUpdate(phase: .ready)
        deps.closeDevicePages()
        return
      }
      guard let session = deps.session() else { return }
      reconnectTask?.cancel()
      let wasSent = phase != .interrupted
      let status = try? await session.getCairnFirmwareStatus()
      if let status { self.status = status }
      let build = status?.build ?? deps.firmwareName() ?? ""
      endUpdate(phase: Self.outcome(
        build: build,
        number: status.map { cairnBuildNumber($0.build) } ?? deps.cairnBuild().flatMap { $0 == 0 ? nil : Int($0) },
        changed: status.map { $0.build != buildBefore },
        before: buildBefore.flatMap(cairnBuildNumber),
        expected: expectedBuild,
        wasSent: wasSent
      ))
      deps.holdDevicePages(false)
    default:
      break
    }
  }

  /// Where an update ends once the radio is back on `build` (`number` nil for a dev build).
  /// `changed` compares STATUS's build names when STATUS answered; otherwise the numbers decide.
  static func outcome(build: String, number: Int?, changed: Bool?, before: Int?, expected: Int?, wasSent: Bool) -> Phase {
    let changed = changed ?? (number != before)
    if let expected, number == expected {
      return .finished(build: build, changed: changed)
    }
    if changed {
      return .finished(build: build, changed: true)
    }
    // A failed send that never reached the board just goes back to the start.
    guard wasSent else { return .ready }
    return expected == nil ? .finished(build: build, changed: false) : .unchanged(build: build)
  }

  private func endUpdate(phase: Phase) {
    self.phase = phase
    image = nil
    login = nil
    updatingDevice = nil
  }

  // MARK: - Choosing the image

  /// Downloads the latest release and checks it against SHA256SUMS before the board is asked.
  func prepareLatest() {
    guard let latest, phase == .ready else { return }
    if let downloadedRelease, downloadedRelease.fileName == latest.assetName {
      image = downloadedRelease
      showingConfirmation = true
      return
    }
    phase = .preparing
    flowTask = Task {
      do {
        let data = try await Releases().download(latest)
        let release = FirmwareImage(data: data, fileName: latest.assetName, name: latest.title)
        downloadedRelease = release
        image = release
        phase = .ready
        showingConfirmation = true
      } catch is CancellationError {
        phase = .ready
      } catch {
        phase = .ready
        errorMessage = Self.message(for: error)
      }
    }
  }

  func useFile(at url: URL) {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    let data: Data
    do {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      errorMessage = L10n.Settings.FirmwareUpdate.File.unreadable
      return
    }
    let fileName = url.lastPathComponent
    if let problem = FirmwareImage.check(data, fileName: fileName, board: board) {
      errorMessage = Self.message(for: problem)
      return
    }
    image = FirmwareImage(data: data, fileName: fileName, name: fileName)
    showingConfirmation = true
  }

  func discardImage() {
    if phase == .ready { image = nil }
  }

  // MARK: - Update

  /// Check the board can be reached over WiFi, then START and wait for the board's answer; on Allow
  /// the link drops and the image goes over WiFi.
  func startUpdate() {
    guard let image, let session = deps.session(), phase == .ready else { return }
    phase = .reaching
    buildBefore = status?.build
    expectedBuild = cairnBuildNumber(image.name)
    updatingDevice = deps.deviceID()
    let address = status?.ipAddress
    flowTask = Task {
      // Once the board allows it, its Bluetooth is off until Updater mode ends; make sure the
      // image can get there first.
      if let address {
        let reachable = await LocalNetworkProbe.canReach(address)
        guard !Task.isCancelled else { return }
        guard reachable else {
          stopAsking(message: L10n.Settings.FirmwareUpdate.Error.network)
          return
        }
      }
      phase = .asking
      deps.holdDevicePages(true)
      // Listening before START goes out, so the answer can't slip past.
      async let answer = session.waitForCairnFirmwareStartResult(timeout: Self.answerTimeout)
      do {
        let reply = try await session.startCairnFirmwareUpdate()
        guard reply == .asking else {
          stopAsking(message: Self.message(for: reply))
          return
        }
      } catch {
        // The board may have taken the START and opened its prompt before the reply went missing.
        if !Task.isCancelled { withdraw(session, image: image, message: error.userFacingMessage) }
        return
      }
      let result = await answer
      guard !Task.isCancelled else { return }
      guard let result else {
        stopAsking(message: L10n.Settings.FirmwareUpdate.Result.noAnswer)
        return
      }
      guard result.outcome == .allowed, let ip = result.ipAddress else {
        stopAsking(message: Self.message(for: result.outcome))
        return
      }
      // The board starts Updater mode about half a second after this push and Bluetooth goes off:
      // the link dropping now is the update going ahead, not an error.
      login = Self.login(ip: ip, result: result)
      await send(image)
    }
  }

  /// Gives up waiting for the board: its prompt closes and no answer follows.
  func cancelAsking() {
    guard phase == .asking else { return }
    flowTask?.cancel()
    if let session = deps.session(), let image {
      withdraw(session, image: image, message: nil)
    } else {
      stopAsking(message: nil)
    }
  }

  /// Stops waiting and withdraws the START. An Allow already on its way when the CANCEL goes out
  /// still puts the board in Updater mode with its Bluetooth off, so its answer is listened for a
  /// little longer: if it comes, the page offers Try Again rather than leaving the board waiting.
  private func withdraw(_ session: MeshCoreSession, image: FirmwareImage, message: String?) {
    stopAsking(message: message)
    Task {
      async let late = session.waitForCairnFirmwareStartResult(timeout: Self.lateAnswerWindow)
      try? await session.cancelCairnFirmwareUpdate()
      guard let result = await late, result.outcome == .allowed, let ip = result.ipAddress,
            !hasLeft, phase == .ready else { return }
      self.image = image
      login = Self.login(ip: ip, result: result)
      deps.holdDevicePages(true)
      phase = .interrupted
    }
  }

  private static func login(ip: String, result: CairnFirmwareStartResult) -> (address: String, password: String) {
    (result.port == 80 || result.port == 0 ? ip : "\(ip):\(result.port)", result.password)
  }

  /// Sends again while the board is still in Updater mode after a failed send.
  func retrySend() {
    guard phase == .interrupted, let image else { return }
    flowTask = Task { await send(image) }
  }

  /// The page closed: stop waiting, and withdraw a START the board is still asking about.
  func leave() {
    hasLeft = true
    if phase == .asking { cancelAsking() }
    if phase == .reaching {
      flowTask?.cancel()
      stopAsking(message: nil)
    }
    reconnectTask?.cancel()
    deps.holdDevicePages(false)
  }

  private func stopAsking(message: String?) {
    phase = .ready
    image = nil
    deps.holdDevicePages(false)
    if let message { errorMessage = message }
  }

  private func send(_ image: FirmwareImage) async {
    guard let login else { return }
    // The image goes over WiFi, and a suspension mid-upload (the person switching apps or
    // locking the phone) would cut the socket and leave the board waiting in Updater mode.
    let backgroundTask = BackgroundTaskAssertion(name: "Firmware upload")
    defer { backgroundTask.end() }
    phase = .connecting
    do {
      let client = try DeviceClient(address: login.address)
      try await connect(client, password: login.password)
      try await client.install(image: image.data, fileName: image.fileName, password: login.password) { [weak self] fraction in
        Task { @MainActor in self?.updateProgress(fraction) }
      }
      phase = .restarting
      waitForReconnect()
    } catch is CancellationError {
      phase = .interrupted
    } catch {
      Self.logger.error("Sending the image failed: \(error.localizedDescription)")
      phase = .interrupted
      errorMessage = Self.message(for: error)
    }
  }

  /// Updater mode needs a moment to come up on WiFi after Bluetooth goes off, and the first reach
  /// into the local network may wait on its permission prompt, so an unreachable board is tried
  /// again for a while. A wrong password is never retried: each one costs one of the board's tries.
  private func connect(_ client: DeviceClient, password: String) async throws {
    let deadline = ContinuousClock.now + Self.connectWindow
    while true {
      do {
        _ = try await client.connect(password: password)
        return
      } catch let error as UpdateError {
        switch error {
        case .network, .notInUpdateMode:
          guard ContinuousClock.now < deadline else { throw error }
          try await Task.sleep(for: Self.connectRetryInterval)
        default:
          throw error
        }
      }
    }
  }

  private func updateProgress(_ fraction: Double) {
    switch phase {
    case .connecting, .sending: phase = .sending(fraction)
    default: break
    }
  }

  private func waitForReconnect() {
    reconnectTask?.cancel()
    reconnectTask = Task {
      try? await Task.sleep(for: Self.reconnectWindow)
      guard !Task.isCancelled, phase == .restarting else { return }
      phase = .notBack
      deps.holdDevicePages(false)
    }
  }

  // MARK: - Messages

  static func message(for reply: CairnFirmwareStartReply) -> String {
    switch reply {
    case .wifiNotConnected: L10n.Settings.FirmwareUpdate.needsWifi
    case .busy: L10n.Settings.FirmwareUpdate.Reply.busy
    case .notNow, .asking, .other: L10n.Settings.FirmwareUpdate.Reply.notNow
    }
  }

  static func message(for outcome: CairnFirmwareStartResult.Outcome) -> String {
    switch outcome {
    case .declined: L10n.Settings.FirmwareUpdate.Result.declined
    case .noAnswer: L10n.Settings.FirmwareUpdate.Result.noAnswer
    case .failed, .allowed, .other: L10n.Settings.FirmwareUpdate.Result.failed
    }
  }

  static func message(for problem: FirmwareImage.Problem) -> String {
    switch problem {
    case .tooSmall: L10n.Settings.FirmwareUpdate.File.tooSmall
    case .notFirmware: L10n.Settings.FirmwareUpdate.File.notFirmware
    case .fullImage: L10n.Settings.FirmwareUpdate.File.full
    case .otherBoard: L10n.Settings.FirmwareUpdate.File.otherBoard
    }
  }

  /// CairnUpdateKit's errors in the app's words; the board's own text (a refused upload) and a
  /// wrong password keep the kit's message.
  static func message(for error: Error) -> String {
    switch error as? UpdateError {
    case .network?, .badAddress?: L10n.Settings.FirmwareUpdate.Error.network
    case .notInUpdateMode?: L10n.Settings.FirmwareUpdate.Error.notInUpdater
    case .checksumMismatch?, .checksumMissing?: L10n.Settings.FirmwareUpdate.Error.checksum
    case .noReleaseImage?: L10n.Settings.FirmwareUpdate.Error.noImage
    case .github?: L10n.Settings.FirmwareUpdate.Error.release
    case .wrongPassword?, .device?: error.localizedDescription
    case nil: error.userFacingMessage
    }
  }
}
