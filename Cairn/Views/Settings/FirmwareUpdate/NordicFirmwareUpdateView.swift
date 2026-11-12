import CairnServices
import CairnUpdateKit
import OSLog
import SwiftUI

/// An nRF52 board's firmware update over Bluetooth (Nordic legacy DFU), from the latest Cairn
/// release on GitHub: the release's `.uf2` for the board is downloaded and checked against the
/// release's checksums, turned into a DFU package, and sent. A companion is updated over the link
/// the app has to it (the app lets go for the update and connects again after); a repeater is told
/// `start ota` over the mesh, then found nearby and updated directly.
@Observable
@MainActor
final class NordicFirmwareUpdateModel: Identifiable {
  enum Mode {
    /// The radio the app is connected to over Bluetooth, by its peripheral.
    case companion(peripheralID: UUID)
    /// A repeater the app is logged in to as admin: `start ota` goes over the mesh.
    case repeater(startOTA: @MainActor () async throws -> String)
  }

  enum Phase: Equatable {
    case checking
    case ready
    case releaseFailed(String)
    case preparing
    case startingOTA
    case searching
    case connecting
    case enablingBootloader
    case uploading(Double)
    case validating
    case restarting
    case finished
    /// The board took the image but the radio didn't come back: likely a bootloader that needs
    /// the reset button.
    case notBack
    case failed(String)

    /// While true the page can't be left: the board is mid-update with this screen.
    var holdsScreen: Bool {
      switch self {
      case .preparing, .startingOTA, .searching, .connecting, .enablingBootloader, .uploading,
           .validating, .restarting: true
      default: false
      }
    }
  }

  /// What the companion update does to the app's own link: let go before, connect again after.
  struct LinkHooks {
    var release: @MainActor () async -> Void
    /// True once the radio is connected again.
    var restore: @MainActor () async -> Bool
  }

  private static let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "NordicFirmwareUpdate")
  /// How long a repeater gets to start advertising after `start ota`.
  static let searchTimeout: Duration = .seconds(30)
  /// How long the board gets to come back in its update mode after it's asked into it. The
  /// update library waits on its own connection attempt and falls silent when that times out,
  /// so without this the page would say "Restarting into update mode…" for good.
  static let handoffTimeout: Duration = .seconds(45)
  /// The same for the connection before it, and for the upload stalling between progress reports.
  static let stepTimeout: Duration = .seconds(60)

  let target: NordicFirmwareTarget
  /// The build on the board ("Cairn 127", a version), when known.
  let installed: String?
  private let mode: Mode
  private let link: LinkHooks?

  private(set) var phase: Phase = .checking
  private(set) var latest: ReleaseImage?
  var showingConfirmation = false

  private let runner = NordicDFURunner()
  private var task: Task<Void, Never>?
  /// Cancels the update when a step outlasts its timeout (`handoffTimeout`, `stepTimeout`).
  private var watchdog: Task<Void, Never>?
  /// The update library's log of the last run, for the page's details when it stalls or fails.
  private(set) var transcript: [String] = []
  /// The step that timed out, when one did; the failure names it.
  private var timedOutStep: Phase?

  /// The connected radio the check is about (companion mode), for the Settings hub's
  /// "Update available"; nil for a repeater.
  private let deviceID: UUID?

  init(target: NordicFirmwareTarget, installed: String?, mode: Mode, link: LinkHooks? = nil, deviceID: UUID? = nil) {
    self.target = target
    self.installed = installed
    self.mode = mode
    self.link = link
    self.deviceID = deviceID
  }

  var isRepeater: Bool {
    if case .repeater = mode { return true }
    return false
  }

  /// Whether the latest release is newer than the board's build; nil when either has no number.
  var updateAvailable: Bool? {
    FirmwareUpdateCheck.updateAvailable(installed: installed, latestBuild: latest?.buildNumber)
  }

  func load() async {
    guard phase == .checking || isReleaseFailure else { return }
    phase = .checking
    do {
      latest = try await Releases().latest(assetPattern: target.assetPattern, boardName: target.displayName)
      // Kept for the repeater Device cards, which compare without a request of their own.
      LatestFirmwareBuildCache.record(build: latest?.buildNumber)
      phase = .ready
      if deviceID != nil {
        FirmwareUpdateHubFlag.record(available: updateAvailable, deviceID: deviceID)
      }
    } catch {
      phase = .releaseFailed(FirmwareUpdateViewModel.message(for: error))
    }
  }

  private var isReleaseFailure: Bool {
    if case .releaseFailed = phase { return true }
    return false
  }

  func install() {
    guard let latest, !phase.holdsScreen else { return }
    task = Task { await run(latest) }
  }

  /// Stops sending; the board's bootloader keeps waiting for an update until it gets one or is reset.
  func stop() {
    runner.abort()
  }

  /// (Re)starts the clock on the step just entered: a step that outlasts its timeout stops the
  /// update, which then fails naming the step. Each progress report during the upload restarts it.
  private func armWatchdog(for step: Phase) {
    watchdog?.cancel()
    let timeout: Duration? = switch step {
    case .enablingBootloader: Self.handoffTimeout
    case .connecting, .uploading, .validating: Self.stepTimeout
    default: nil
    }
    guard let timeout else { watchdog = nil; return }
    watchdog = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled, let self else { return }
      Self.logger.error("\(self.target.displayName): \(String(describing: step)) outlasted \(timeout) – stopping")
      timedOutStep = step
      runner.abort()
      runner.giveUp()
    }
  }

  /// The transcript as one text, for sharing.
  var transcriptText: String { transcript.joined(separator: "\n") }

  func tryAgain() {
    phase = latest == nil ? .checking : .ready
    if latest == nil { Task { await load() } }
  }

  // MARK: - Flow

  private func run(_ release: ReleaseImage) async {
    // The upload stops if the app is suspended mid-way: keep it running while the person switches
    // away for a moment.
    let backgroundTask = BackgroundTaskAssertion(name: "Bluetooth firmware update")
    defer { backgroundTask.end() }

    phase = .preparing
    let package: NordicFirmwarePackage
    do {
      let data = try await Releases().download(release)
      package = try NordicFirmwarePackage(uf2: data)
    } catch is NordicFirmwarePackage.Problem {
      phase = .failed(L10n.Settings.FirmwareUpdate.Nordic.Error.package)
      return
    } catch {
      phase = .failed(FirmwareUpdateViewModel.message(for: error))
      return
    }

    let peripheral: UUID
    switch mode {
    case let .companion(peripheralID):
      peripheral = peripheralID
      // The update library brings its own Bluetooth central; the app's link would reconnect
      // to the board mid-update and get in its way.
      await link?.release()
    case let .repeater(startOTA):
      phase = .startingOTA
      do {
        let reply = try await startOTA()
        guard reply.localizedCaseInsensitiveContains("OK") else {
          phase = .failed(L10n.Settings.FirmwareUpdate.Nordic.Error.otaRefused(reply))
          return
        }
      } catch {
        phase = .failed(L10n.Settings.FirmwareUpdate.Nordic.Error.otaRefused(error.userFacingMessage))
        return
      }
      phase = .searching
      guard let found = await NordicOTAScanner().find(name: target.otaAdvertisingName, timeout: Self.searchTimeout) else {
        phase = .failed(L10n.Settings.FirmwareUpdate.Nordic.Error.notFound)
        return
      }
      peripheral = found
    }

    phase = .connecting
    timedOutStep = nil
    var outcome: NordicDFURunner.Event = .failed(L10n.Settings.FirmwareUpdate.Nordic.Error.couldNotStart)
    armWatchdog(for: .connecting)
    for await event in runner.run(package, on: peripheral) {
      switch event {
      case .connecting: phase = .connecting
      case .enablingBootloader: phase = .enablingBootloader
      case let .uploading(fraction): phase = .uploading(fraction)
      case .validating: phase = .validating
      case .completed, .failed: outcome = event
      }
      armWatchdog(for: phase)
    }
    watchdog?.cancel()
    watchdog = nil
    transcript = runner.transcript
    if let timedOutStep, case .failed = outcome {
      outcome = .failed(timedOutStep == .enablingBootloader
        ? L10n.Settings.FirmwareUpdate.Nordic.Error.handoffTimeout
        : L10n.Settings.FirmwareUpdate.Nordic.Error.stalled)
    }

    switch outcome {
    case .completed:
      Self.logger.info("\(self.target.displayName): \(release.title) sent")
      if link != nil {
        phase = .restarting
        phase = await link?.restore() == true ? .finished : .notBack
      } else {
        phase = .finished
      }
    case let .failed(message):
      phase = .failed(message)
      // The radio is still on its old firmware (or waiting in its bootloader): connect again.
      if link != nil { _ = await link?.restore() }
    default:
      break
    }
  }
}

/// The update's page content: the build on the board and the latest release, the Install button
/// (asking first), the steps as they go, and how it ended.
struct NordicFirmwareUpdateContent: View {
  @Bindable var model: NordicFirmwareUpdateModel

  var body: some View {
    CardFormSection(footer: L10n.Settings.FirmwareUpdate.Nordic.footer) {
      MetricTileGrid {
        MetricTile(
          L10n.Settings.FirmwareUpdate.installed,
          systemImage: "memorychip",
          value: model.installed ?? "–",
          caption: model.target.displayName
        )
        MetricTile(
          L10n.Settings.FirmwareUpdate.latest,
          systemImage: "shippingbox",
          value: latestValue,
          caption: latestCaption,
          valueTint: model.updateAvailable == true ? .green : nil
        )
      }
      // What changed in the latest release, on its GitHub page.
      if let latest = model.latest, let pageURL = latest.pageURL {
        ExternalLinkTile(
          L10n.Settings.FirmwareUpdate.releaseNotes,
          accessibilityLabel: L10n.Settings.FirmwareUpdate.ReleaseNotes.accessibility(latest.title),
          systemImage: "doc.text",
          color: .blue,
          url: pageURL
        )
      }
    }

    statusCard
      .alert(
        L10n.Settings.FirmwareUpdate.Nordic.Confirm.title(model.latest?.title ?? "", model.target.displayName),
        isPresented: $model.showingConfirmation
      ) {
        Button(L10n.Settings.FirmwareUpdate.Confirm.install) { model.install() }
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      } message: {
        Text(model.isRepeater
          ? L10n.Settings.FirmwareUpdate.Nordic.Confirm.repeater
          : L10n.Settings.FirmwareUpdate.Nordic.Confirm.companion)
      }
      .task { await model.load() }
      .onChange(of: model.phase.holdsScreen) { _, holds in
        UIApplication.shared.isIdleTimerDisabled = holds
      }
      .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }

  private var latestValue: String {
    if let latest = model.latest { return latest.title }
    if case .releaseFailed = model.phase { return L10n.Settings.FirmwareUpdate.latestUnavailable }
    return L10n.Settings.FirmwareUpdate.checking
  }

  /// When the release was published, and whether it is newer than the board's build.
  private var latestCaption: String? {
    FirmwareReleaseCaption.caption(publishedAt: model.latest?.publishedAt, updateAvailable: model.updateAvailable)
  }

  @ViewBuilder
  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch model.phase {
      case .checking:
        ProgressView()
          .frame(maxWidth: .infinity)
      case let .releaseFailed(message), let .failed(message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        Button(L10n.Localizable.Common.tryAgain) { model.tryAgain() }
          .buttonStyle(.bordered)
        if !model.transcript.isEmpty {
          transcriptDisclosure
        }
      case .ready:
        if let latest = model.latest {
          Button {
            model.showingConfirmation = true
          } label: {
            Label(L10n.Settings.FirmwareUpdate.Nordic.install(latest.title), systemImage: "arrow.down.circle.fill")
              .frame(maxWidth: .infinity)
          }
          .liquidGlassProminentButtonStyle()
          .accessibilityIdentifier("firmwareUpdate.nordic.install")
        }
      case .finished:
        Label(
          model.isRepeater
            ? L10n.Settings.FirmwareUpdate.Nordic.Done.repeater
            : L10n.Settings.FirmwareUpdate.Nordic.Done.companion(model.latest?.title ?? ""),
          systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
        .fixedSize(horizontal: false, vertical: true)
      case .notBack:
        Label(L10n.Settings.FirmwareUpdate.Nordic.notBack, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      default:
        stepRows
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: 12)
  }

  /// The step under way with its progress, what to keep doing meanwhile, and Stop while sending.
  @ViewBuilder
  private var stepRows: some View {
    HStack(spacing: 10) {
      ProgressView()
      Text(stepText)
        .font(.body.weight(.medium))
        .monospacedDigit()
    }
    if case let .uploading(fraction) = model.phase {
      ProgressView(value: fraction)
    }
    // Plain and in front: leaving the page or cutting the board's power mid-update strands it in
    // its update mode.
    Label(L10n.Settings.FirmwareUpdate.Nordic.stayWarning, systemImage: "exclamationmark.triangle.fill")
      .font(.subheadline.weight(.medium))
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8, style: .continuous))
      .accessibilityIdentifier("firmwareUpdate.nordic.stayWarning")
    Text(L10n.Settings.FirmwareUpdate.Nordic.keepOpen)
      .font(.footnote)
      .foregroundStyle(.secondary)
    if case .uploading = model.phase {
      Button(L10n.Settings.FirmwareUpdate.Nordic.stop, role: .destructive) { model.stop() }
        .buttonStyle(.bordered)
    }
  }

  /// The update library's log of the run, for working out what the board did.
  private var transcriptDisclosure: some View {
    DisclosureGroup(L10n.Settings.FirmwareUpdate.Nordic.transcript) {
      ScrollView(.horizontal) {
        Text(model.transcriptText)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 220)
      ShareLink(item: model.transcriptText) {
        Label(L10n.Settings.FirmwareUpdate.Nordic.shareTranscript, systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.bordered)
    }
    .font(.footnote)
  }

  private var stepText: String {
    switch model.phase {
    case .preparing: L10n.Settings.FirmwareUpdate.Nordic.Step.preparing
    case .startingOTA: L10n.Settings.FirmwareUpdate.Nordic.Step.startingOta
    case .searching: L10n.Settings.FirmwareUpdate.Nordic.Step.searching
    case .connecting: L10n.Settings.FirmwareUpdate.Nordic.Step.connecting
    case .enablingBootloader: L10n.Settings.FirmwareUpdate.Nordic.Step.enablingBootloader
    case let .uploading(fraction):
      L10n.Settings.FirmwareUpdate.Nordic.Step.uploading(fraction.formatted(.percent.precision(.fractionLength(0))))
    case .validating: L10n.Settings.FirmwareUpdate.Nordic.Step.validating
    case .restarting: L10n.Settings.FirmwareUpdate.Nordic.Step.restarting
    default: ""
    }
  }
}

/// A logged-in repeater's update, as a sheet from its Device Info: Done is hidden while the board
/// is mid-update.
struct NordicRepeaterUpdateSheet: View {
  @State var model: NordicFirmwareUpdateModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      CardForm {
        NordicFirmwareUpdateContent(model: model)
      }
      .flashingNavigationTitle(L10n.Settings.FirmwareUpdate.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if !model.phase.holdsScreen {
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Localizable.Common.done) { dismiss() }
          }
        }
      }
    }
    .interactiveDismissDisabled(model.phase.holdsScreen)
  }
}
