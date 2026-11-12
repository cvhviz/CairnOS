import AudioToolbox
import CairnServices
import OSLog
import SwiftUI
import VisionKit

/// View for scanning a channel QR code to join
struct ScanChannelQRView: View {
  @Environment(\.appState) private var appState

  let availableSlots: [UInt8]
  let onComplete: (ChannelDTO?) -> Void

  @State private var scannedChannel: MeshCoreURLParser.ChannelResult?
  @State private var selectedSlot: UInt8
  @State private var isJoining = false
  @State private var errorMessage: String?
  @State private var cameraPermissionDenied = false
  @State private var existingChannels: [ChannelDTO] = []
  /// Name to join under; starts as the scanned name and is editable only when
  /// that name is already taken on this radio.
  @State private var channelName = ""

  init(availableSlots: [UInt8], onComplete: @escaping (ChannelDTO?) -> Void) {
    self.availableSlots = availableSlots
    self.onComplete = onComplete
    _selectedSlot = State(initialValue: availableSlots.first ?? 1)
  }

  private var scannedConflict: PrivateChannelConflict? {
    guard let channel = scannedChannel else { return nil }
    return PrivateChannelConflict.check(
      name: channel.name,
      secret: channel.secret,
      existingChannels: existingChannels
    )
  }

  private var alreadyJoinedChannel: ChannelDTO? {
    if case let .alreadyJoined(channel) = scannedConflict { return channel }
    return nil
  }

  var body: some View {
    Group {
      if let channel = scannedChannel {
        ScanConfirmationContent(
          scannedChannel: channel,
          alreadyJoinedChannel: alreadyJoinedChannel,
          needsRename: scannedConflict == .nameTaken,
          channelName: $channelName,
          isNameTaken: PrivateChannelConflict.isNameTaken(channelName, existingChannels: existingChannels),
          isJoining: isJoining,
          errorMessage: errorMessage,
          onJoin: { Task { await joinChannel() } },
          onGoToExisting: { onComplete($0) },
          onScanAgain: {
            scannedChannel = nil
            errorMessage = nil
          }
        )
      } else if cameraPermissionDenied {
        CameraPermissionDeniedContent()
      } else {
        ScannerContent(
          onScanResult: handleScanResult,
          errorMessage: $errorMessage,
          cameraPermissionDenied: $cameraPermissionDenied
        )
      }
    }
    .flashingNavigationTitle(L10n.Chats.Chats.ScanQR.title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      guard let radioID = appState.connectedDevice?.radioID,
            let dataStore = appState.services?.dataStore else { return }
      // Fail open: without the list, joining proceeds unchecked.
      existingChannels = await (try? dataStore.fetchChannels(radioID: radioID)) ?? []
    }
  }

  // MARK: - Private Methods

  /// Returns whether the payload was accepted, so the scanner keeps running after a
  /// code that is not a MeshCore channel.
  private func handleScanResult(_ result: String) -> Bool {
    guard let parsed = MeshCoreURLParser.parseChannelURL(result) else {
      errorMessage = L10n.Chats.Chats.ScanQR.Error.invalidFormat
      return false
    }
    errorMessage = nil
    scannedChannel = parsed
    channelName = parsed.name
    return true
  }

  private func joinChannel() async {
    guard let radioID = appState.connectedDevice?.radioID,
          let channel = scannedChannel else {
      errorMessage = L10n.Chats.Chats.Error.noDeviceConnected
      return
    }

    isJoining = true
    defer { isJoining = false }
    errorMessage = nil

    do {
      guard let channelService = appState.services?.channelService else {
        errorMessage = L10n.Chats.Chats.Error.servicesUnavailable
        return
      }
      try await channelService.setChannelWithSecret(
        radioID: radioID,
        index: selectedSlot,
        name: channelName.trimmingCharacters(in: .whitespacesAndNewlines),
        secret: channel.secret
      )

      // Fetch the joined channel to return it
      guard let dataStore = appState.services?.dataStore,
            let channels = try? await dataStore.fetchChannels(radioID: radioID),
            let joined = channels.first(where: { $0.index == selectedSlot }) else {
        onComplete(nil)
        return
      }

      let completed = await ChannelJoinFloodScopeApplier.applyIfNeeded(
        channel: joined,
        regionScope: channel.regionScope,
        setFloodScope: { channelID, scope in
          try await dataStore.setChannelFloodScope(channelID, floodScope: scope)
        },
        logger: Logger(subsystem: "cvhvisuals.Cairn", category: "ScanChannelQRView")
      )
      onComplete(completed)
    } catch {
      errorMessage = error.userFacingMessage
    }
  }
}

// MARK: - Extracted Views

private struct ScannerContent: View {
  let onScanResult: (String) -> Bool
  @Binding var errorMessage: String?
  @Binding var cameraPermissionDenied: Bool

  private static let errorOpacity: CGFloat = 0.8

  var body: some View {
    ZStack {
      if QRDataScannerView.isSupported, QRDataScannerView.isAvailable {
        QRDataScannerView { result in
          onScanResult(result)
        } onPermissionDenied: {
          cameraPermissionDenied = true
        }
      } else {
        // Fallback for unsupported devices
        ContentUnavailableView(
          L10n.Chats.Chats.ScanQR.NotAvailable.title,
          systemImage: "qrcode.viewfinder",
          description: Text(L10n.Chats.Chats.ScanQR.NotAvailable.description)
        )
      }

      // Overlay with scan frame
      VStack {
        Spacer()

        RoundedRectangle(cornerRadius: 20)
          .stroke(.white, lineWidth: 3)
          .frame(width: 250, height: 250)

        Spacer()

        if let errorMessage {
          Button {
            self.errorMessage = nil
          } label: {
            Text(errorMessage)
              .font(.subheadline)
              .foregroundStyle(.white)
              .padding()
              .background(.red.opacity(Self.errorOpacity), in: .capsule)
          }
          .buttonStyle(.plain)
          .padding(.bottom, 50)
        } else {
          Text(L10n.Chats.Chats.ScanQR.instruction)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding()
            .background(.black.opacity(0.6), in: .capsule)
            .padding(.bottom, 50)
        }
      }
    }
    .ignoresSafeArea()
  }
}

private struct ScanConfirmationContent: View {
  let scannedChannel: MeshCoreURLParser.ChannelResult
  let alreadyJoinedChannel: ChannelDTO?
  let needsRename: Bool
  @Binding var channelName: String
  let isNameTaken: Bool
  let isJoining: Bool
  let errorMessage: String?
  let onJoin: () -> Void
  let onGoToExisting: (ChannelDTO) -> Void
  let onScanAgain: () -> Void

  private var isJoinDisabled: Bool {
    if isJoining { return true }
    if alreadyJoinedChannel != nil { return false }
    return channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isNameTaken
  }

  var body: some View {
    CardForm {
      CardFormSection(
        L10n.Chats.Chats.CreatePrivate.Section.details,
        footer: scannedChannel.hasHashtagSecretMismatch ? L10n.Chats.Chats.JoinFromMessage.hashtagSecretMismatch : nil
      ) {
        ContentCard {
          if needsRename {
            TextField(L10n.Chats.Chats.CreatePrivate.channelName, text: $channelName)
              .textContentType(.name)
              .onChange(of: channelName) { _, newValue in
                if newValue.utf8.count > ProtocolLimits.maxUsableNameBytes {
                  channelName = newValue.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
                }
              }
            if isNameTaken {
              Text(L10n.Chats.Chats.CreatePrivate.Error.nameTaken(channelName))
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
          } else {
            LabeledContent(L10n.Chats.Chats.CreatePrivate.channelName, value: scannedChannel.name)
          }

          Divider()

          LabeledContent(L10n.Chats.Chats.ChannelInfo.secretKey) {
            Text(scannedChannel.secret.uppercaseHexString())
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
          }

          if let regionScope = scannedChannel.regionScope {
            Divider()
            LabeledContent(L10n.Chats.Chats.ChannelInfo.region, value: regionScope)
          }
        }
      }

      if let errorMessage {
        InlineErrorCard(message: errorMessage)
      }

      VStack(spacing: CardStyle.spacing) {
        Button {
          if let existing = alreadyJoinedChannel {
            onGoToExisting(existing)
          } else {
            onJoin()
          }
        } label: {
          BusyActionCardLabel(
            title: alreadyJoinedChannel.map { L10n.Chats.Chats.JoinPrivate.goToButton($0.name) }
              ?? L10n.Chats.Chats.JoinPrivate.joinButton,
            systemImage: alreadyJoinedChannel == nil ? "key.fill" : "arrow.right.circle",
            color: .orange,
            isBusy: isJoining
          )
        }
        .buttonStyle(.plain)
        .disabled(isJoinDisabled)

        if alreadyJoinedChannel != nil {
          Label(L10n.Chats.Chats.JoinHashtag.alreadyJoined, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.green)
            .accessibilityLabel(L10n.Chats.Chats.JoinHashtag.alreadyJoinedAccessibility)
            .frame(maxWidth: .infinity)
        }

        ActionCard(
          L10n.Chats.Chats.ScanQR.scanAgain,
          systemImage: "qrcode.viewfinder",
          color: .purple,
          action: onScanAgain
        )
      }
    }
  }
}

private struct CameraPermissionDeniedContent: View {
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "camera.fill")
        .font(.system(size: 60))
        .foregroundStyle(.secondary)

      Text(L10n.Chats.Chats.ScanQR.PermissionDenied.title)
        .font(.title2)
        .bold()

      Text(L10n.Chats.Chats.ScanQR.PermissionDenied.message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Button(L10n.Chats.Chats.ScanQR.openSettings) {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
  }
}

// MARK: - QR Scanner using DataScannerViewController

struct QRDataScannerView: UIViewControllerRepresentable {
  /// Returns whether the host accepted the payload. A rejected payload leaves the scanner running.
  let onScan: (String) -> Bool
  let onPermissionDenied: () -> Void

  static var isSupported: Bool {
    DataScannerViewController.isSupported
  }

  static var isAvailable: Bool {
    DataScannerViewController.isAvailable
  }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: false,
      isHighlightingEnabled: true
    )
    scanner.delegate = context.coordinator
    return scanner
  }

  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
    // Start scanning when view appears
    if !controller.isScanning {
      try? controller.startScanning()
    }
  }

  static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
    controller.stopScanning()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onScan: onScan)
  }

  @MainActor
  class Coordinator: NSObject, DataScannerViewControllerDelegate {
    /// How long a re-read of the same rejected payload is ignored, so a code that stays
    /// in frame does not re-fire the host's error.
    private static let rejectedPayloadDebounce: Duration = .seconds(2)

    let onScan: (String) -> Bool
    private var hasScanned = false
    private var lastRejection: (payload: String, at: ContinuousClock.Instant)?

    init(onScan: @escaping (String) -> Bool) {
      self.onScan = onScan
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
      processItem(item, scanner: dataScanner)
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      // Auto-capture first QR code detected
      guard !hasScanned, let item = addedItems.first else { return }
      processItem(item, scanner: dataScanner)
    }

    private func processItem(_ item: RecognizedItem, scanner: DataScannerViewController) {
      guard !hasScanned else { return }

      if case let .barcode(barcode) = item,
         let payload = barcode.payloadStringValue {
        let now = ContinuousClock.now
        if let lastRejection, lastRejection.payload == payload,
           now - lastRejection.at < Self.rejectedPayloadDebounce {
          // Each re-read extends the window while the same code stays in view.
          self.lastRejection = (payload, now)
          return
        }

        guard onScan(payload) else {
          lastRejection = (payload, now)
          return
        }

        hasScanned = true
        scanner.stopScanning()
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
      }
    }
  }
}

#Preview {
  NavigationStack {
    ScanChannelQRView(availableSlots: [1, 2, 3], onComplete: { _ in })
  }
  .environment(\.appState, AppState())
}
