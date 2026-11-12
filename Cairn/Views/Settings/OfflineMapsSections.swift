import MapKit
import MapLibre
import CairnServices
import SwiftUI

// MARK: - Offline Maps Sections

/// The offline-map part of Settings → Maps: storage readings, the downloaded packs, and the
/// download action. The host page owns the region-picker sheet and delete confirmation
/// (`offlineMapsPresentations`) so they attach to its `CardForm` rather than to a section.
struct OfflineMapsSections: View {
  @Environment(\.appState) private var appState
  @Binding var showingRegionPicker: Bool
  @Binding var pendingDeletion: [OfflinePack]

  private var packs: [OfflinePack] {
    appState.offlineMapService.packs
  }

  var body: some View {
    CardFormSection(
      L10n.Settings.Maps.offlineHeader,
      info: packs.isEmpty ? nil : L10n.Settings.OfflineMaps.storageFooter
    ) {
      if packs.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(L10n.Settings.OfflineMaps.emptyTitle)
          Text(L10n.Settings.OfflineMaps.emptyDescription)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)
        .accessibilityElement(children: .combine)
      } else {
        MetricTileGrid {
          MetricTile(
            L10n.Settings.OfflineMaps.storageUsed,
            systemImage: "internaldrive",
            value: appState.offlineMapService.databaseSize.formatted(.byteCount(style: .file))
          )
          MetricTile(
            L10n.Settings.OfflineMaps.complete,
            systemImage: "checkmark.circle",
            value: L10n.Settings.OfflineMaps.downloadedCount(
              packs.filter(\.isComplete).count,
              packs.count
            )
          )
        }

        ForEach(packs) { pack in
          // A pack can be hundreds of megabytes and can't be fetched again off-grid, so the
          // delete affordances only queue it for the host's confirmation.
          OfflinePackRow(pack: pack) {
            pendingDeletion = [pack]
          }
          .cardSurface(padding: 12)
          .cardInteractionShape()
          .contextMenu {
            Button(L10n.Localizable.Common.delete, systemImage: "trash", role: .destructive) {
              pendingDeletion = [pack]
            }
          }
        }
      }

      ActionCard(L10n.Settings.OfflineMaps.downloadRegion, systemImage: "arrow.down.circle.fill", color: .teal) {
        showingRegionPicker = true
      }
    }
  }
}

extension View {
  /// The region-picker sheet, delete confirmation, and pack-error alert that go with
  /// `OfflineMapsSections`. Apply once to the page hosting the sections.
  func offlineMapsPresentations(
    showingRegionPicker: Binding<Bool>,
    pendingDeletion: Binding<[OfflinePack]>
  ) -> some View {
    modifier(OfflineMapsPresentations(
      showingRegionPicker: showingRegionPicker,
      pendingDeletion: pendingDeletion
    ))
  }
}

private struct OfflineMapsPresentations: ViewModifier {
  @Environment(\.appState) private var appState
  @Binding var showingRegionPicker: Bool
  @Binding var pendingDeletion: [OfflinePack]
  @State private var errorMessage: String?

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: $showingRegionPicker) {
        RegionPickerSheet()
      }
      .confirmationDialog(
        L10n.Settings.OfflineMaps.DeleteConfirm.title,
        isPresented: Binding(
          get: { !pendingDeletion.isEmpty },
          set: { if !$0 { pendingDeletion = [] } }
        ),
        titleVisibility: .visible,
        presenting: pendingDeletion
      ) { packs in
        Button(L10n.Localizable.Common.delete, role: .destructive) {
          Task {
            for pack in packs {
              await appState.offlineMapService.deletePack(pack)
            }
          }
        }
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      } message: { packs in
        Text(L10n.Settings.OfflineMaps.DeleteConfirm.message(
          packs.map { "\($0.name) — \($0.layer.label)" }.formatted(.list(type: .and))
        ))
      }
      .onChange(of: appState.offlineMapService.lastPackError) { _, newValue in
        if let newValue {
          errorMessage = newValue
          appState.offlineMapService.clearLastPackError()
        }
      }
      .errorAlert($errorMessage)
  }
}

// MARK: - Offline Pack Row

private struct OfflinePackRow: View {
  @Environment(\.appState) private var appState
  let pack: OfflinePack
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      IconTile(systemImage: pack.layer.systemImage, color: pack.layer.tileColor)
        .accessibilityHidden(true)
      details
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(pack.name)
        Text("— \(pack.layer.label)")
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button(L10n.Localizable.Common.delete, systemImage: "trash", role: .destructive, action: onDelete)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
          .frame(minWidth: Self.minHitTarget, minHeight: Self.minHitTarget)
          .contentShape(.rect)
      }

      HStack {
        if pack.isComplete {
          Text(L10n.Settings.OfflineMaps.complete)
            .foregroundStyle(.secondary)
        } else if pack.isPaused {
          Text(L10n.Settings.OfflineMaps.paused)
            .foregroundStyle(.secondary)
        } else {
          Text(L10n.Settings.OfflineMaps.downloading)
            .foregroundStyle(.secondary)
        }

        Spacer()

        VStack(alignment: .trailing) {
          Text(Int64(pack.completedBytes), format: .byteCount(style: .file))
          if let speed = pack.downloadSpeed, speed > 0 {
            Text("\(speed, format: .byteCount(style: .file))/s")
          }
        }
        .foregroundStyle(.secondary)
      }
      .font(.caption)

      if !pack.isComplete {
        HStack {
          ProgressView(value: pack.completedFraction)
            .accessibilityLabel(pack.name)

          Button(
            pack.isPaused
              ? L10n.Settings.OfflineMaps.resume
              : L10n.Settings.OfflineMaps.pause,
            systemImage: pack.isPaused ? "play.fill" : "pause.fill"
          ) {
            if pack.isPaused {
              appState.offlineMapService.resumePack(pack)
            } else {
              appState.offlineMapService.pausePack(pack)
            }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .frame(minWidth: Self.minHitTarget, minHeight: Self.minHitTarget)
          .contentShape(.rect)
        }
      }
    }
  }

  /// The HIG minimum for the icon-only pause and delete buttons.
  private static let minHitTarget: CGFloat = 44
}

private extension OfflineMapLayer {
  /// The icon tile glyph for a downloaded pack, so packs and the region sheet share one symbol.
  var systemImage: String {
    switch self {
    case .base: "map"
    case .topo: "mountain.2"
    }
  }

  var tileColor: Color {
    switch self {
    case .base: .teal
    case .topo: .brown
    }
  }
}

// MARK: - Region Picker Sheet

/// Picks an area to download as an offline pack. Opened from Settings on the map's last
/// camera, or from a map's options menu on the area that map shows (`initialRegion`).
struct RegionPickerSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference

  @State private var regionName = ""
  @State private var cameraRegion: MKCoordinateRegion?
  /// Bumped once for a region the sheet opens on, so the map lands there.
  @State private var cameraRegionVersion = 0

  init(initialRegion: MKCoordinateRegion? = nil) {
    _cameraRegion = State(initialValue: initialRegion)
    _debouncedRegion = State(initialValue: initialRegion)
    _cameraRegionVersion = State(initialValue: initialRegion == nil ? 0 : 1)
  }
  @State private var isDownloading = false
  @State private var errorMessage: String?
  @State private var mapSize: CGSize = .zero
  @State private var includeTopo = false
  @State private var isStyleLoaded = false
  @State private var debouncedRegion: MKCoordinateRegion?
  @State private var debounceTask: Task<Void, Never>?
  @State private var availableBytes: Int64?

  private static let selectionPadding: CGFloat = 40

  private var mapIsDark: Bool {
    let preference = AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system
    return resolvedMapIsDark(preference: preference, colorScheme: colorScheme)
  }

  var body: some View {
    NavigationStack {
      ZStack {
        CairnMapView(
          points: [],
          lines: [],
          mapStyle: .standard,
          isDarkMode: mapIsDark,
          showLabels: false,
          showsUserLocation: true,
          isInteractive: true,
          showsScale: false,
          isNorthLocked: true,
          cameraRegion: $cameraRegion,
          cameraRegionVersion: cameraRegionVersion,
          onPointTap: nil,
          onMapTap: nil,
          onCameraRegionChange: { region in
            cameraRegion = region
            debounceTask?.cancel()
            debounceTask = Task {
              try? await Task.sleep(for: .milliseconds(200))
              guard !Task.isCancelled else { return }
              debouncedRegion = region
            }
          },
          isStyleLoaded: $isStyleLoaded
        )

        // Selection rectangle overlay
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .padding(Self.selectionPadding)
          .allowsHitTesting(false)
      }
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { newValue in
        mapSize = newValue
      }
      .flashingNavigationTitle(L10n.Settings.OfflineMaps.pickRegion)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Settings.OfflineMaps.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Settings.OfflineMaps.download) {
            downloadRegion()
          }
          .disabled(
            trimmedRegionName.isEmpty || isDownloading || exceedsAvailableSpace
              || !appState.offlineMapService.isNetworkAvailable
              || selectionBounds == nil
          )
          .keyboardShortcut(.defaultAction)
        }
      }
      .safeAreaInset(edge: .bottom) {
        RegionPickerBottomCard(
          regionName: $regionName,
          includeTopo: $includeTopo,
          estimatedDownloadBytes: estimatedDownloadBytes,
          exceedsAvailableSpace: exceedsAvailableSpace,
          isNetworkAvailable: appState.offlineMapService.isNetworkAvailable
        )
      }
      .errorAlert($errorMessage)
      .onAppear { refreshAvailableBytes() }
      .onChange(of: debouncedRegion?.center.latitude) { _, _ in refreshAvailableBytes() }
      .onChange(of: debouncedRegion?.center.longitude) { _, _ in refreshAvailableBytes() }
    }
  }

  /// The name the pack is saved under; a name of only spaces would list as a blank pack.
  private var trimmedRegionName: String {
    regionName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Download Estimate

  private var selectedLayers: Set<OfflineMapLayer> {
    var layers: Set<OfflineMapLayer> = [.base]
    if includeTopo { layers.insert(.topo) }
    return layers
  }

  private var estimatedDownloadBytes: Int64? {
    guard let bounds = selectionBounds else { return nil }
    return selectedLayers.reduce(Int64(0)) { total, layer in
      total + OfflineMapService.estimatedDownloadSize(bounds: bounds, minZoom: 10, maxZoom: Int(layer.maxDownloadZoom), layer: layer)
    }
  }

  private var exceedsAvailableSpace: Bool {
    guard let estimated = estimatedDownloadBytes,
          let available = availableBytes else { return false }
    return estimated > available
  }

  private func refreshAvailableBytes() {
    let values = try? URL.documentsDirectory.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    )
    availableBytes = values?.volumeAvailableCapacityForImportantUsage
  }

  // MARK: - Bounds

  private var selectionBounds: MLNCoordinateBounds? {
    guard let region = debouncedRegion,
          mapSize.width > 0, mapSize.height > 0 else { return nil }

    let lonFraction = Self.selectionPadding / (mapSize.width / 2)
    let latFraction = Self.selectionPadding / (mapSize.height / 2)

    let latInset = region.span.latitudeDelta * latFraction
    let lonInset = region.span.longitudeDelta * lonFraction

    return MLNCoordinateBounds(
      sw: CLLocationCoordinate2D(
        latitude: region.center.latitude - (region.span.latitudeDelta / 2 - latInset),
        longitude: region.center.longitude - (region.span.longitudeDelta / 2 - lonInset)
      ),
      ne: CLLocationCoordinate2D(
        latitude: region.center.latitude + (region.span.latitudeDelta / 2 - latInset),
        longitude: region.center.longitude + (region.span.longitudeDelta / 2 - lonInset)
      )
    )
  }

  // MARK: - Download

  private func downloadRegion() {
    guard let bounds = selectionBounds else { return }
    isDownloading = true

    let layers = selectedLayers

    Task {
      defer { isDownloading = false }
      do {
        try await appState.offlineMapService.downloadRegion(
          name: trimmedRegionName,
          bounds: bounds,
          layers: layers
        )
        dismiss()
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }
}

// MARK: - Region Picker Bottom Card

private struct RegionPickerBottomCard: View {
  @Binding var regionName: String
  @Binding var includeTopo: Bool
  let estimatedDownloadBytes: Int64?
  let exceedsAvailableSpace: Bool
  let isNetworkAvailable: Bool

  /// Warn when estimated download exceeds 500 MB.
  private static let largeDownloadThreshold: Int64 = 500_000_000

  @State private var footerMinHeight: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        IconTile(systemImage: "character.cursor.ibeam", color: .teal)
          .accessibilityHidden(true)
        TextField(L10n.Settings.OfflineMaps.regionName, text: $regionName)
          .textFieldStyle(.plain)
          .submitLabel(.done)
      }

      Divider()

      // The base map always downloads; topography is the optional extra layer.
      Toggle(isOn: $includeTopo) {
        SettingCardLabel(
          L10n.Settings.OfflineMaps.Layer.topo,
          systemImage: OfflineMapLayer.topo.systemImage,
          color: OfflineMapLayer.topo.tileColor
        )
      }

      Divider()

      footerContent
        .frame(minHeight: footerMinHeight, alignment: .top)
        .background {
          // Measure the tallest possible footer state (estimate + warning)
          // to reserve stable space regardless of current state or Dynamic Type size.
          tallestFooterState
            .hidden()
            .onGeometryChange(for: CGFloat.self) { proxy in
              proxy.size.height
            } action: { height in
              footerMinHeight = height
            }
        }
    }
    .padding(12)
    .background { RegionPanelBackground() }
    .padding(.horizontal, CardStyle.pageInset)
    .padding(.bottom, 4)
  }

  private var footerContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !isNetworkAvailable {
        HStack {
          Image(systemName: "wifi.slash")
            .foregroundStyle(.red)
          Text(L10n.Settings.OfflineMaps.noNetwork)
            .foregroundStyle(.red)
        }
        .font(.caption)
      } else if let bytes = estimatedDownloadBytes {
        let isLarge = bytes > Self.largeDownloadThreshold

        HStack {
          if exceedsAvailableSpace {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.red)
          } else if isLarge {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }

          Text(L10n.Settings.OfflineMaps.estimatedSize(
            bytes.formatted(.byteCount(style: .file))
          ))
          .foregroundStyle(exceedsAvailableSpace ? .red : isLarge ? .orange : .secondary)
        }
        .font(.caption)

        if exceedsAvailableSpace {
          Text(L10n.Settings.OfflineMaps.exceedsStorage)
            .font(.caption)
            .foregroundStyle(.red)
        } else if isLarge {
          Text(L10n.Settings.OfflineMaps.largeTileWarning)
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
          Text(L10n.Settings.OfflineMaps.downloadHint)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text(L10n.Settings.OfflineMaps.downloadHint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The tallest possible single footer state: estimate line + the longest warning.
  /// Rendered hidden to measure the height needed at the current Dynamic Type size.
  private var tallestFooterState: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "xmark.circle.fill")
        Text(L10n.Settings.OfflineMaps.estimatedSize("999 GB"))
      }
      .font(.caption)

      Text(L10n.Settings.OfflineMaps.exceedsStorage)
        .font(.caption)
    }
  }
}

/// The bottom panel floats over the live map rather than the card canvas, so it is always
/// translucent (glass on iOS 26, material before) in the shared card shape, and opaque with
/// Reduce Transparency.
private struct RegionPanelBackground: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if reduceTransparency {
      CardStyle.shape.fill(Color(.secondarySystemGroupedBackground))
    } else if #available(iOS 26.0, *) {
      Color.clear.glassEffect(.regular, in: CardStyle.shape)
    } else {
      CardStyle.shape.fill(.regularMaterial)
    }
  }
}
