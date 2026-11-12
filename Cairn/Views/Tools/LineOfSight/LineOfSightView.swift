import CoreLocation
import MapKit
import CairnServices
import SwiftUI

private let analysisSheetDetentCollapsed: PresentationDetent = .fraction(0.25)
private let analysisSheetDetentHalf: PresentationDetent = .fraction(0.5)
private let analysisSheetDetentExpanded: PresentationDetent = .large

// MARK: - Line of Sight View

/// Full-screen map view for analyzing line-of-sight between two points
struct LineOfSightView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  @State private var viewModel: LineOfSightViewModel
  @State private var sheetDetent: PresentationDetent = analysisSheetDetentCollapsed
  @State private var enableHalfDetent = false
  @State private var showAnalysisSheet: Bool
  @State private var editingPoint: PointID?
  @AppStorage(AppStorageKey.mapStyleSelection.rawValue) private var mapStyleSelection: MapStyleSelection = .standard
  @AppStorage(AppStorageKey.mapShowLabels.rawValue) private var showLabels = AppStorageKey.defaultMapShowLabels
  @AppStorage(AppStorageKey.mapClusteringEnabled.rawValue)
  private var clusteringEnabled = AppStorageKey.defaultMapClusteringEnabled
  @AppStorage(AppStorageKey.mapNorthLocked.rawValue) private var isNorthLocked = AppStorageKey.defaultMapNorthLocked
  @AppStorage(AppStorageKey.mapFilterLineOfSight.rawValue)
  private var mapFilterRaw: String = ""
  @State private var sheetBottomInset: CGFloat = 220
  @State private var isResultsExpanded = false
  @State private var copyHapticTrigger = 0

  private let layoutMode: LineOfSightLayoutMode

  // One-time drag hint tooltip for repeater marker
  @AppStorage(AppStorageKey.hasSeenRepeaterDragHint.rawValue) private var hasSeenDragHint = AppStorageKey.defaultHasSeenRepeaterDragHint
  @State private var showDragHint = false
  @State private var repeaterMarkerCenter: CGPoint?
  @State private var isNavigatingBack = false

  private var isRelocating: Bool {
    viewModel.relocatingPoint != nil
  }

  private var mapFilter: MapFilterState {
    MapFilterPreferences.state(fromRaw: mapFilterRaw, host: .lineOfSight)
  }

  private var mapFilterBinding: Binding<MapFilterState> {
    MapFilterPreferences.binding(raw: $mapFilterRaw, host: .lineOfSight)
  }

  private var shouldShowExpandedAnalysis: Bool {
    sheetDetent != analysisSheetDetentCollapsed
  }

  private var mapOverlayBottomPadding: CGFloat {
    showAnalysisSheet ? sheetBottomInset : 0
  }

  private var availableSheetDetents: Set<PresentationDetent> {
    if enableHalfDetent {
      [analysisSheetDetentCollapsed, analysisSheetDetentHalf, analysisSheetDetentExpanded]
    } else {
      [analysisSheetDetentCollapsed, analysisSheetDetentExpanded]
    }
  }

  // MARK: - Initialization

  init(preselectedContact: ContactDTO? = nil) {
    _viewModel = State(initialValue: LineOfSightViewModel(preselectedContact: preselectedContact))
    layoutMode = .mapWithSheet
    _showAnalysisSheet = State(initialValue: true)
  }

  /// From `origin` to a node, both points set, framed on them.
  init(
    from origin: CLLocationCoordinate2D,
    to target: CLLocationCoordinate2D,
    contact: ContactDTO? = nil,
    discovered: DiscoveredNodeDTO? = nil
  ) {
    _viewModel = State(initialValue: LineOfSightViewModel(from: origin, to: target, contact: contact, discovered: discovered))
    layoutMode = .mapWithSheet
    _showAnalysisSheet = State(initialValue: true)
    // Both points are in, so the sheet opens at half with Analyze in view, as picking them does.
    _sheetDetent = State(initialValue: analysisSheetDetentHalf)
    _enableHalfDetent = State(initialValue: true)
  }

  init(viewModel: LineOfSightViewModel, layoutMode: LineOfSightLayoutMode) {
    _viewModel = State(initialValue: viewModel)
    self.layoutMode = layoutMode
    _showAnalysisSheet = State(initialValue: layoutMode == .mapWithSheet)
  }

  // MARK: - Body

  var body: some View {
    switch layoutMode {
    case .panel:
      ScrollView {
        analysisSheetContent
      }
      .scrollDismissesKeyboard(.immediately)
      .cardCanvas(theme)

    case .map:
      mapCanvasWithBehaviors(showSheet: false)

    case .mapWithSheet:
      mapCanvasWithBehaviors(showSheet: true)
    }
  }

  @ViewBuilder
  private func mapCanvasWithBehaviors(showSheet: Bool) -> some View {
    let base = LOSMapCanvasView(
      viewModel: viewModel,
      appState: appState,
      mapStyleSelection: $mapStyleSelection,
      showLabels: $showLabels,
      clusteringEnabled: $clusteringEnabled,
      isNorthLocked: $isNorthLocked,
      mapOverlayBottomPadding: mapOverlayBottomPadding,
      cameraBottomSheetFraction: showSheet ? 0.25 : 0,
      filter: MapFilterControl(host: .lineOfSight, state: mapFilterBinding),
      onRepeaterTap: { handleRepeaterTap($0) },
      onDiscoveredTap: { handleDiscoveredTap($0) },
      onMapTap: { handleMapTap(at: $0) },
      onMapLongPress: { handleMapLongPress(at: $0) }
    )
    .onChange(of: viewModel.pointA) { oldValue, newValue in
      if oldValue == nil, newValue != nil, viewModel.pointB != nil {
        if showSheet {
          enableHalfDetent = true
          withAnimation {
            sheetDetent = analysisSheetDetentHalf
          }
        }
      }

      if showSheet, newValue == nil, viewModel.pointB == nil {
        withAnimation {
          sheetDetent = analysisSheetDetentCollapsed
        }
      }
    }
    .onChange(of: viewModel.pointB) { oldValue, newValue in
      if oldValue == nil, newValue != nil, viewModel.pointA != nil {
        if showSheet {
          enableHalfDetent = true
          withAnimation {
            sheetDetent = analysisSheetDetentHalf
          }
        }
      }

      if showSheet, newValue == nil, viewModel.pointA == nil {
        withAnimation {
          sheetDetent = analysisSheetDetentCollapsed
        }
      }
    }
    .onChange(of: sheetDetent) { oldValue, newValue in
      guard showSheet else { return }

      if isRelocating, newValue != analysisSheetDetentCollapsed {
        viewModel.relocatingPoint = nil
      }

      // Disable half detent once user drags away from it
      if oldValue == analysisSheetDetentHalf, newValue != analysisSheetDetentHalf {
        enableHalfDetent = false
      }
    }
    .onChange(of: viewModel.repeaterPoint) { oldValue, newValue in
      if oldValue == nil,
         newValue != nil,
         newValue?.isOnPath == true,
         !hasSeenDragHint {
        withAnimation(.easeIn(duration: 0.3)) {
          showDragHint = true
        }
        hasSeenDragHint = true
        Task {
          try? await Task.sleep(for: .seconds(5))
          withAnimation(.easeOut(duration: 0.3)) {
            showDragHint = false
          }
        }
      }
    }
    .onChange(of: viewModel.analysisStatus) { _, newStatus in
      handleAnalysisStatusChange(newStatus, showSheet: showSheet)
    }
    .task {
      appState.locationService.requestPermissionIfNeeded()
      viewModel.configure(
        dataStore: { [appState] in appState.offlineDataStore },
        radioID: { [appState] in appState.currentRadioID },
        deviceFrequencyKHz: appState.connectedDevice?.frequency
      )
      viewModel.showLabels = showLabels
      MapFilterPreferences.ensureMigrated(raw: &mapFilterRaw, host: .lineOfSight)
      viewModel.applyFilter(mapFilter)
      await viewModel.loadRepeaters()
      #if DEBUG
        // Screenshot runs fill A and B with two repeaters and analyze: `-uiTestLineOfSightDemo YES`.
        if UserDefaults.standard.bool(forKey: "uiTestLineOfSightDemo"), viewModel.pointA == nil,
           viewModel.repeatersWithLocation.count >= 2 {
          let repeaters = viewModel.repeatersWithLocation
          viewModel.setPointA(coordinate: repeaters[0].coordinate, contact: repeaters[0])
          viewModel.setPointB(coordinate: repeaters[1].coordinate, contact: repeaters[1])
          try? await Task.sleep(for: .seconds(3))
          viewModel.analyze()
        }
      #endif
      // Opened on two points (from a map's target), frame them rather than every repeater.
      if viewModel.pointA != nil, viewModel.pointB != nil {
        viewModel.zoomToShowBothPoints()
      } else {
        viewModel.centerOnAllRepeaters()
      }
    }
    .onChange(of: showLabels) { _, newValue in
      viewModel.showLabels = newValue
    }
    .onChange(of: mapFilterRaw) { _, _ in
      viewModel.applyFilter(mapFilter)
    }
    // A deleted node leaves this map as it leaves the Map tab; so do adds and moves.
    .onChange(of: appState.contactsVersion) { _, _ in
      Task { await viewModel.loadRepeaters() }
    }

    if showSheet {
      base
        .navigationBarBackButtonHidden(true)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              dismissLineOfSight()
            } label: {
              Label(L10n.Tools.Tools.LineOfSight.back, systemImage: "chevron.left")
                .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel(L10n.Tools.Tools.LineOfSight.back)
          }
        }
        .liquidGlassToolbarBackground()
        .onDisappear {
          showAnalysisSheet = false
        }
        .sheet(isPresented: $showAnalysisSheet) {
          analysisSheet
            .onGeometryChange(for: CGFloat.self) { proxy in
              proxy.size.height - proxy.safeAreaInsets.bottom - 16
            } action: { inset in
              if sheetDetent == analysisSheetDetentCollapsed {
                sheetBottomInset = max(0, inset)
              }
            }
            .presentationDetents(availableSheetDetents, selection: $sheetDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled)
            // The app's canvas, the user's background included, so the cards read as they do
            // on every other page.
            .presentationBackground(theme.canvasColor ?? Color(.systemGroupedBackground))
            .interactiveDismissDisabled()
        }
    } else {
      base
        .liquidGlassToolbarBackground()
    }
  }

  @MainActor
  private func dismissLineOfSight() {
    guard !isNavigatingBack else { return }
    isNavigatingBack = true

    showAnalysisSheet = false
    viewModel.relocatingPoint = nil

    // Yield to let showAnalysisSheet = false commit before dismiss fires,
    // avoiding a sheet-dismissal animation conflict.
    Task { @MainActor in
      await Task.yield()
      dismiss()
    }
  }

  // MARK: - Analysis Sheet

  private var analysisSheet: some View {
    NavigationStack {
      ScrollView {
        analysisSheetContent
      }
      .scrollDismissesKeyboard(.immediately)
      .cardCanvas(theme)
      .toolbar(.hidden, for: .navigationBar)
    }
  }

  /// The panel as a card form, top to bottom in the order you use it: the points, Analyze, then
  /// what the analysis found (verdict, figures, terrain) and the radio assumptions behind it.
  private var analysisSheetContent: some View {
    VStack(alignment: .leading, spacing: 20) {
      PointsSummarySectionView(
        viewModel: viewModel,
        copyHapticTrigger: $copyHapticTrigger,
        editingPoint: $editingPoint,
        onRelocate: { withAnimation { sheetDetent = analysisSheetDetentCollapsed } },
        onUseMyLocation: { useMyLocation(for: $0) }
      )

      if viewModel.relocatingPoint == nil {
        analyzeButtonSection
      }

      if case let .result(result) = viewModel.analysisStatus {
        resultSummarySection(result)
        if shouldShowExpandedAnalysis {
          terrainSection
        }
      }

      if case let .relayResult(result) = viewModel.analysisStatus {
        RelayResultsCardView(result: result, isExpanded: $isResultsExpanded)
        if shouldShowExpandedAnalysis {
          terrainSection
        }
      }

      if case let .error(message) = viewModel.analysisStatus {
        AnalysisErrorView(
          message: message,
          hasRepeater: viewModel.repeaterPoint != nil,
          onRetry: {
            if viewModel.repeaterPoint != nil {
              viewModel.analyzeWithRepeater()
            } else {
              viewModel.analyze()
            }
          }
        )
      }

      if shouldShowExpandedAnalysis || !hasAnalysisResult {
        RFSettingsSectionView(viewModel: viewModel)
      }
    }
    .padding(.horizontal, CardStyle.pageInset)
    .padding(.vertical, CardStyle.formVerticalInset)
  }

  private var terrainSection: some View {
    TerrainProfileSectionView(
      viewModel: viewModel,
      showDragHint: $showDragHint,
      repeaterMarkerCenter: $repeaterMarkerCenter
    )
  }

  // MARK: - Analyze Button Section

  /// Always there, so it's clear what the points are for; until both are placed it waits, and
  /// says why under it.
  private var analyzeButtonSection: some View {
    VStack(spacing: 6) {
      AnalyzeButton(
        viewModel: viewModel,
        hasAnalysisResult: hasAnalysisResult,
        onAnalyze: {
          withAnimation { sheetDetent = analysisSheetDetentExpanded }
        }
      )
      .disabled(!viewModel.canAnalyze)
      if !viewModel.canAnalyze {
        Text(L10n.Tools.Tools.LineOfSight.selectTwoPoints)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Result Summary Section

  private func resultSummarySection(_ result: PathAnalysisResult) -> some View {
    ResultsCardView(result: result, isExpanded: $isResultsExpanded)
  }

  // MARK: - Computed Properties

  private var analysisResult: PathAnalysisResult? {
    if case let .result(result) = viewModel.analysisStatus {
      return result
    }
    return nil
  }

  private var hasAnalysisResult: Bool {
    if case .result = viewModel.analysisStatus { return true }
    if case .relayResult = viewModel.analysisStatus { return true }
    return false
  }

  // MARK: - Helper Methods

  private func handleMapTap(at coordinate: CLLocationCoordinate2D) {
    if let relocating = viewModel.relocatingPoint {
      handleRelocation(to: coordinate, for: relocating)
    }
  }

  private func handleMapLongPress(at coordinate: CLLocationCoordinate2D) {
    if let relocating = viewModel.relocatingPoint {
      handleRelocation(to: coordinate, for: relocating)
      return
    }
    viewModel.selectPoint(at: coordinate)
  }

  private func handleRelocation(
    to coordinate: CLLocationCoordinate2D,
    for pointID: PointID,
    contact: ContactDTO? = nil,
    discovered: DiscoveredNodeDTO? = nil
  ) {
    switch pointID {
    case .pointA:
      viewModel.setPointA(coordinate: coordinate, contact: contact, discovered: discovered)
    case .pointB:
      viewModel.setPointB(coordinate: coordinate, contact: contact, discovered: discovered)
    case .repeater:
      viewModel.setRepeaterOffPath(coordinate: coordinate)
    }

    // Clear results and show Analyze button
    viewModel.clearAnalysisResults()
    viewModel.relocatingPoint = nil
    enableHalfDetent = true
    withAnimation {
      sheetDetent = analysisSheetDetentHalf
    }
  }

  private func handleAnalysisStatusChange(_ status: AnalysisStatus, showSheet: Bool) {
    switch status {
    case .result:
      if showSheet {
        sheetDetent = analysisSheetDetentExpanded
      }
    case .relayResult:
      break
    default:
      return
    }

    if viewModel.shouldAutoZoomOnNextResult {
      viewModel.shouldAutoZoomOnNextResult = false
      viewModel.zoomToShowBothPoints()
    }
  }

  /// A repeater tapped while a point is being placed becomes that point; otherwise it toggles
  /// in or out of the path.
  private func handleRepeaterTap(_ contact: ContactDTO) {
    if let relocating = viewModel.relocatingPoint {
      handleRelocation(to: contact.coordinate, for: relocating, contact: contact)
    } else {
      viewModel.toggleContact(contact)
    }
  }

  private func handleDiscoveredTap(_ node: DiscoveredNodeDTO) {
    if let relocating = viewModel.relocatingPoint {
      handleRelocation(to: node.coordinate, for: relocating, discovered: node)
    } else {
      viewModel.toggleDiscoveredNode(node)
    }
  }

  /// Puts A or B where the phone is, from a fresh fix.
  private func useMyLocation(for pointID: PointID) {
    Task {
      appState.locationService.requestPermissionIfNeeded()
      guard let location = try? await appState.locationService.requestCurrentLocation() else { return }
      handleRelocation(to: location.coordinate, for: pointID)
    }
  }
}

// MARK: - Map Canvas View

private struct LOSMapCanvasView: View {
  @Bindable var viewModel: LineOfSightViewModel
  let appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  @Binding var mapStyleSelection: MapStyleSelection
  @Binding var showLabels: Bool
  @Binding var clusteringEnabled: Bool
  @Binding var isNorthLocked: Bool
  let mapOverlayBottomPadding: CGFloat
  let cameraBottomSheetFraction: CGFloat?
  let filter: MapFilterControl
  let onRepeaterTap: (ContactDTO) -> Void
  let onDiscoveredTap: (DiscoveredNodeDTO) -> Void
  let onMapTap: (CLLocationCoordinate2D) -> Void
  let onMapLongPress: (CLLocationCoordinate2D) -> Void

  @AppStorage(AppStorageKey.mapColorSchemePreference.rawValue)
  private var mapColorSchemeRaw = AppStorageKey.defaultMapColorSchemePreference

  @State private var isCenteredOnUser = false

  private var mapIsDark: Bool {
    let preference = AppColorSchemePreference(rawValue: mapColorSchemeRaw) ?? .system
    return resolvedMapIsDark(preference: preference, colorScheme: colorScheme)
  }

  var body: some View {
    ZStack {
      CairnMapView(
        points: viewModel.mapPoints,
        lines: viewModel.mapLines,
        mapStyle: mapStyleSelection,
        isDarkMode: mapIsDark,
        isOffline: !appState.offlineMapService.isNetworkAvailable,
        showLabels: showLabels,
        clusteringEnabled: clusteringEnabled,
        showsUserLocation: true,
        isInteractive: true,
        showsScale: true,
        isNorthLocked: isNorthLocked,
        cameraRegion: $viewModel.cameraRegion,
        cameraRegionVersion: viewModel.cameraRegionVersion,
        cameraBottomSheetFraction: cameraBottomSheetFraction,
        onPointTap: { point, _ in
          if let repeater = viewModel.repeatersWithLocation.first(where: { $0.id == point.id }) {
            onRepeaterTap(repeater)
          } else if let node = viewModel.discoveredNode(forPointID: point.id) {
            onDiscoveredTap(node)
          }
        },
        onMapTap: onMapTap,
        onMapLongPress: onMapLongPress,
        onCameraRegionChange: { region in
          viewModel.cameraRegion = region
        },
        isCenteredOnUser: $isCenteredOnUser,
        // Only shows roughly where you are: no need to keep the GPS radio on for it.
        userLocationAccuracy: kCLLocationAccuracyHundredMeters
      )
      .ignoresSafeArea()

      VStack {
        Spacer()
        HStack {
          Spacer()
          MapControlsToolbar(
            onLocationTap: {
              // Unlike other maps, LOS needs a precise fresh fix (no device-GPS fallback,
              // tighter span), so it fetches live rather than using AppState.centerOnUserLocation.
              Task {
                if let location = try? await appState.locationService.requestCurrentLocation() {
                  viewModel.setCameraRegion(MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                  ))
                  isCenteredOnUser = true
                }
              }
            },
            isCenteredOnUser: isCenteredOnUser,
            isNorthLocked: $isNorthLocked,
            showLabels: $showLabels,
            clusteringEnabled: $clusteringEnabled,
            mapStyleSelection: $mapStyleSelection,
            viewportBounds: viewModel.cameraRegion?.toMLNCoordinateBounds(),
            filter: filter
          ) {
            EmptyView()
          }
        }
      }
      .padding(.bottom, mapOverlayBottomPadding)
    }
  }
}

// MARK: - Frequency Input Row

/// Extracted view for frequency input with its own @FocusState
/// This is necessary because @FocusState doesn't work properly when declared in a parent view
/// and used in sheet content.
struct FrequencyInputRow: View {
  @Bindable var viewModel: LineOfSightViewModel
  @FocusState private var isFocused: Bool
  @State private var text: String = ""

  var body: some View {
    HStack(spacing: 8) {
      SettingCardLabel(L10n.Tools.Tools.LineOfSight.frequency, systemImage: "antenna.radiowaves.left.and.right", color: .orange)
      Spacer(minLength: 8)
      TextField(L10n.Tools.Tools.LineOfSight.mhz, text: $text)
        .keyboardType(.decimalPad)
        .multilineTextAlignment(.trailing)
        .frame(width: 80)
        .focused($isFocused)
        .onChange(of: text) { _, newValue in
          let replaced = newValue.replacing(",", with: ".")
          if replaced != newValue {
            text = replaced
          }
        }
        .onChange(of: isFocused) { _, focused in
          if focused {
            // Sync text from view model when gaining focus
            text = viewModel.formatFrequencyForEditing(viewModel.frequencyMHz)
          } else {
            // Commit when focus is lost
            commitEdit()
          }
        }

      Text(L10n.Tools.Tools.LineOfSight.mhz)
        .foregroundStyle(.secondary)

      if isFocused {
        Button {
          commitEdit()
          isFocused = false
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.title2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Tools.Tools.LineOfSight.done)
      }
    }
    .onAppear {
      text = viewModel.formatFrequencyForEditing(viewModel.frequencyMHz)
    }
  }

  private func commitEdit() {
    guard let parsed = viewModel.parseFrequency(text) else {
      // Reject empty, unparseable, or non-positive input by restoring
      // the last valid value rather than passing it to analysis.
      text = viewModel.formatFrequencyForEditing(viewModel.frequencyMHz)
      return
    }
    viewModel.frequencyMHz = parsed
    viewModel.commitFrequencyChange()
  }
}

// MARK: - Analyze Button

private struct AnalyzeButton: View {
  var viewModel: LineOfSightViewModel
  let hasAnalysisResult: Bool
  let onAnalyze: () -> Void

  var body: some View {
    Button {
      viewModel.shouldAutoZoomOnNextResult = true
      onAnalyze()
      if viewModel.repeaterPoint != nil {
        viewModel.analyzeWithRepeater()
      } else {
        viewModel.analyze()
      }
    } label: {
      if viewModel.isAnalyzing {
        HStack {
          ProgressView()
            .controlSize(.small)
          Text(L10n.Tools.Tools.LineOfSight.analyzing)
        }
        .frame(maxWidth: .infinity)
      } else {
        Label(L10n.Tools.Tools.LineOfSight.analyze, systemImage: "waveform.path")
          .frame(maxWidth: .infinity)
      }
    }
    .liquidGlassProminentButtonStyle()
    .controlSize(.large)
    .disabled(viewModel.isAnalyzing)
  }
}

// MARK: - Preview

#Preview("Empty") {
  LineOfSightView()
    .environment(\.appState, AppState())
}

#Preview("With Contact") {
  let contact = ContactDTO(
    id: UUID(),
    radioID: UUID(),
    publicKey: Data(repeating: 0x01, count: 32),
    name: "Test Contact",
    typeRawValue: 0,
    flags: 0,
    outPathLength: PacketBuilder.floodPathSentinel,
    outPath: Data(),
    lastAdvertTimestamp: 0,
    latitude: 37.7749,
    longitude: -122.4194,
    lastModified: 0,
    lastHeardTimestamp: nil,
    nickname: nil,
    isBlocked: false,
    isMuted: false,
    isFavorite: false,
    lastMessageDate: nil,
    unreadCount: 0
  )

  LineOfSightView(preselectedContact: contact)
    .environment(\.appState, AppState())
}
