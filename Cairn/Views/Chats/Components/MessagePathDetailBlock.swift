import CoreLocation
import CairnServices
import SwiftUI

/// Capsules, compact preview map, hop list, and expand-to-full-map sheet.
struct MessagePathDetailBlock: View {
  private static let expandedContentTopPadding: CGFloat = 8
  private static let outgoingDisclosureSymbol = "arrow.triangle.branch"
  private static let incomingDisclosureSymbol = "point.topleft.down.to.point.bottomright.curvepath"

  @Environment(\.appState) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.appTheme) private var theme

  let message: MessageDTO
  let arrivals: [MessagePathArrival]
  let pathViewModel: MessagePathViewModel
  @Binding var isDetailExpanded: Bool

  @State private var selectedID: UUID?
  @State private var showFullMap = false
  @State private var containerWidth: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      disclosureButton

      if isDetailExpanded {
        Divider()
          .padding(.horizontal, MessagePathPreviewSnapshot.expandedHorizontalPadding)
        expandedContent
          .padding(.horizontal, MessagePathPreviewSnapshot.expandedHorizontalPadding)
          .padding(.top, Self.expandedContentTopPadding)
          .padding(.bottom)
          .id("expandedContent")
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { containerWidth = $0 }
    // A card, as the detail tiles above it, so the row reads as something to tap rather than a
    // caption on the sheet (the user, 2026-11-08); it opens in place, the map and hops inside it.
    .background(Color(.secondarySystemBackground), in: CardStyle.shape)
    .clipShape(CardStyle.shape)
    .padding(.horizontal)
    .task(id: prefetchID) {
      await pathViewModel.prefetchPreviews(
        message: message,
        arrivals: arrivals,
        selectedID: selectedID,
        connectedDevice: appState.connectedDevice,
        userLocation: appState.bestAvailableLocation,
        isDark: colorScheme == .dark,
        isOffline: isOffline,
        containerWidth: containerWidth,
        appearance: avatarAppearance
      )
    }
    .onAppear {
      selectedID = MessagePathArrivals.resolvedSelection(preferred: selectedID, arrivals: arrivals)
    }
    .onChange(of: arrivals.map(\.id)) { _, _ in
      selectedID = MessagePathArrivals.resolvedSelection(preferred: selectedID, arrivals: arrivals)
    }
    .sheet(isPresented: $showFullMap) {
      MessagePathMapView(
        message: message,
        arrivals: arrivals,
        selectedID: selectedBinding,
        pathViewModel: pathViewModel
      )
    }
  }

  private var selectedBinding: Binding<UUID?> {
    Binding(
      get: { MessagePathArrivals.resolvedSelection(preferred: selectedID, arrivals: arrivals) },
      set: { selectedID = $0 }
    )
  }

  private var selectedArrival: MessagePathArrival? {
    let selected = MessagePathArrivals.resolvedSelection(preferred: selectedID, arrivals: arrivals)
    return arrivals.first { $0.id == selected } ?? arrivals.first
  }

  private var disclosureButton: some View {
    Button {
      withAnimation(reduceMotion ? nil : .default) {
        isDetailExpanded.toggle()
      }
    } label: {
      HStack {
        Label {
          Text(disclosureTitle)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
        } icon: {
          Image(systemName: disclosureSymbol)
            .foregroundStyle(.tint)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .rotationEffect(.degrees(isDetailExpanded ? 90 : 0))
          .foregroundStyle(.tertiary)
          .font(.footnote.weight(.semibold))
          .accessibilityHidden(true)
      }
      .padding()
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .cardInteractionShape()
    .accessibilityLabel(disclosureTitle)
    .accessibilityValue(
      isDetailExpanded
        ? L10n.Chats.Chats.Message.Action.expanded
        : L10n.Chats.Chats.Message.Action.collapsed
    )
  }

  private var disclosureTitle: String {
    message.isOutgoing
      ? L10n.Chats.Chats.Message.Action.repeatDetails
      : L10n.Chats.Chats.Message.Action.pathDetails
  }

  private var disclosureSymbol: String {
    message.isOutgoing
      ? Self.outgoingDisclosureSymbol
      : Self.incomingDisclosureSymbol
  }

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      if arrivals.count > 1 {
        MessagePathArrivalCapsules(
          arrivals: arrivals,
          selectedID: selectedBinding,
          reduceMotion: reduceMotion
        )
      }

      previewMap

      if let selectedArrival {
        MessagePathContent(
          message: message,
          arrival: selectedArrival,
          viewModel: pathViewModel,
          receiverName: appState.connectedDevice?.nodeName ?? L10n.Chats.Chats.Path.Receiver.you,
          userLocation: appState.bestAvailableLocation
        )
      }
    }
  }

  private var previewMapModel: MessagePathMapView.CanvasModel? {
    MessagePathMapView.canvasModel(
      message: message,
      arrivals: arrivals,
      selectedID: selectedBinding.wrappedValue,
      pathViewModel: pathViewModel,
      connectedDevice: appState.connectedDevice,
      userLocation: appState.bestAvailableLocation
    )
  }

  private var isOffline: Bool {
    !appState.offlineMapService.isNetworkAvailable
  }

  private var previewKey: MessagePathPreviewSnapshot.Key? {
    guard let arrivalID = selectedArrival?.id else { return nil }
    return MessagePathPreviewSnapshot.key(
      arrivalID: arrivalID,
      isDark: colorScheme == .dark,
      isOffline: isOffline,
      containerWidth: containerWidth,
      appearance: avatarAppearance
    )
  }

  /// The theme, light or dark, and contrast the live path map draws its hop pins in, so the
  /// preview thumbnail matches the map it opens.
  private var avatarAppearance: MapAvatarAppearance {
    MapAvatarAppearance(theme: theme, colorScheme: colorScheme, contrast: colorSchemeContrast)
  }

  private var prefetchID: PrefetchID {
    PrefetchID(
      arrivalIDs: arrivals.map(\.id),
      isLoading: pathViewModel.isLoading,
      isDark: colorScheme == .dark,
      isOffline: isOffline,
      appearance: avatarAppearance.fingerprint,
      widthBucket: MessagePathPreviewSnapshot.bucketedWidth(
        max(0, containerWidth - 2 * MessagePathPreviewSnapshot.expandedHorizontalPadding)
      )
    )
  }

  @ViewBuilder
  private var previewMap: some View {
    if let model = previewMapModel, model.showsPathMap, let key = previewKey {
      if let image = pathViewModel.previewImage(for: key) {
        pathPreview(image: image, didFail: false, model: model, onRetry: {})
      } else if pathViewModel.previewFailed(for: key) {
        pathPreview(image: nil, didFail: true, model: model, onRetry: retrySelectedPreview)
      } else if let stale = pathViewModel.lastPreviewImage {
        pathPreview(image: stale, didFail: false, model: model, onRetry: {})
      }
    }
  }

  private func pathPreview(
    image: UIImage?,
    didFail: Bool,
    model: MessagePathMapView.CanvasModel,
    onRetry: @escaping () -> Void
  ) -> MessagePathPreviewMap {
    MessagePathPreviewMap(
      image: image,
      didFail: didFail,
      totalPathDistance: model.selectedCoordinates.totalDistance(),
      isDistanceIncomplete: model.isDistanceIncomplete,
      onExpand: { showFullMap = true },
      onRetry: onRetry
    )
  }

  private func retrySelectedPreview() {
    guard let key = previewKey else { return }
    Task {
      await pathViewModel.retryPreview(
        arrivalID: key.arrivalID,
        message: message,
        arrivals: arrivals,
        connectedDevice: appState.connectedDevice,
        userLocation: appState.bestAvailableLocation,
        isDark: colorScheme == .dark,
        isOffline: isOffline,
        containerWidth: containerWidth,
        appearance: avatarAppearance
      )
    }
  }

  private struct PrefetchID: Hashable {
    let arrivalIDs: [UUID]
    let isLoading: Bool
    let isDark: Bool
    let isOffline: Bool
    let appearance: String
    let widthBucket: Int
  }
}
