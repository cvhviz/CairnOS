import CairnServices
import SwiftUI

/// Scan & Traffic: Scan for Nodes and the Traffic page on one screen, the way Find My and Maps
/// pair a map with a result panel. The map is the Traffic map (the packets' routes as lasers, its
/// ticker, a short rail of Locate, Fit and ⋯) with the scan's neighbours pinned on it, a live dot
/// by the title and Send Advert at the top right. The panel's header says what the scan is doing and holds Scan and Wardrive
/// side by side under that line, so nothing covers the map; under it Nodes (the scan's list) or Packets
/// (the Traffic list, with its filters), and the map's camera follows the one shown. Each
/// scan starts a new list, which fills with what the radio hears from then on until the next scan
/// (Show Older adds what was heard before it); probes and Wardrive run in the app's probe
/// coordinator, so leaving the screen ends neither, and coming back shows the last scan's list. On
/// a phone the results are a sheet over the map's lower part, its rounded top over the map and a
/// grabber to drag the split: down past the bottom lowers it to its header and buttons, giving the map
/// the screen; up past the top it fills the screen with the list. With room to spare (iPad, Mac)
/// the panel sits beside a larger map.
struct NodeDiscoveryView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var viewModel = NodeDiscoveryViewModel()
  /// The radio's packets, for the map, the live strip and the Packets list alike.
  @State private var traffic = RxLogViewModel()
  /// Nodes or Packets under the live strip; the map's camera follows it. Opens on Nodes unless
  /// the page was opened for its packets (`NavigationCoordinator.navigateToScan(section:)`).
  @State private var section: NodeDiscoverySection = .nodes
  /// Where a phone's results sheet rests: over the map, sharing the screen, or lowered to its
  /// header and buttons so the map has the screen. Opens lowered, the map the whole screen, from
  /// wherever it's opened; the section opened for waits in the sheet. A probe keeps running in
  /// every one.
  @State private var sheetState: NodeDiscoverySheetState = .lowered
  /// The map's traffic, owned here so the lowered sheet can show the packet now flying.
  @State private var trafficMap = TrafficMapModel()
  /// The lowered sheet's height, so the map's overlays and fits keep clear of it.
  @State private var loweredSheetHeight: CGFloat = 180
  /// The finger on the sheet's grabber or header. Only the sheet's offset reads it, so a drag
  /// moves the sheet without laying out the map or the list again.
  @State private var sheetDrag = NodeDiscoverySheetDrag()

  /// Share of the height the map takes above the results sheet when the two share the screen.
  /// Opens with the results taking the larger share, starting close under the map; VoiceOver moves
  /// it a step at a time.
  @State private var mapFraction: CGFloat = 0.4
  /// The Wardrive prompt on screen (`NodeDiscoveryViewModel.wardrivePrompt`), held here so a
  /// prompt answered with the next one due isn't cancelled by the first alert closing.
  @State private var presentedWardrivePrompt: WardrivePrompt?

  /// The range VoiceOver moves the split through.
  private static let mapFractionRange: ClosedRange<CGFloat> = 0.22...0.72
  /// A drag starts once the finger has gone this far, so taps on the header's buttons still land.
  private static let dragThreshold: CGFloat = 6

  /// The sheet is lowered: the map has the screen.
  private var isMapFullScreen: Bool { sheetState == .lowered }
  /// The panel's width beside the map in a regular-width layout.
  private static let sidePanelWidth: CGFloat = 400
  /// The results sheet's rounded top, which overlaps the map by the same amount.
  private static let sheetCornerRadius: CGFloat = 24

  private var isConnected: Bool {
    appState.services?.session != nil
  }

  /// Disconnected, the list stays while the directory holds what was heard before, marked stale.
  private var hasHeardNodes: Bool {
    appState.neighbourDirectory.snapshot != nil
  }

  var body: some View {
    Group {
      if !isConnected, !hasHeardNodes {
        RadioNotConnectedView(
          description: L10n.Tools.Tools.NodeDiscovery.notConnectedDescription(viewModel.filter.localizedTitle)
        )
      } else if horizontalSizeClass == .regular {
        HStack(spacing: 0) {
          NodeDiscoveryPanel(viewModel: viewModel, traffic: traffic, section: $section)
            .frame(width: Self.sidePanelWidth)
            .cardCanvas(theme)
          Divider()
            .ignoresSafeArea(edges: .bottom)
          // The map runs under the tab bar; its ticker and controls stay above it.
          map(bottomInset: 0, isCompact: false)
        }
      } else {
        GeometryReader { geometry in
          let height = geometry.size.height
          let top = sheetTop(sheetState, height: height)
          ZStack(alignment: .top) {
            // The same map view in every state, so its camera and fit state carry over. It runs
            // full height under the sheet, never resized as the sheet moves; its viewport ends at
            // the sheet's top (under the list, where the sheet shares the screen).
            map(bottomInset: height - sheetTop(sheetState == .list ? .split : sheetState, height: height), isCompact: !isMapFullScreen)
              .frame(height: height)
            resultsSheet(height: height)
              .frame(height: isMapFullScreen ? nil : height - top)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight in
                if isMapFullScreen { loweredSheetHeight = sheetHeight }
              }
              .frame(maxHeight: .infinity, alignment: .bottom)
              // A drag moves the sheet by an offset alone, until it settles.
              .modifier(NodeDiscoverySheetOffset(
                drag: sheetDrag,
                state: sheetState,
                height: height,
                splitFraction: mapFraction,
                loweredHeight: loweredSheetHeight
              ))
          }
        }
      }
    }
    .flashingNavigationTitle(ToolSelection.nodeDiscovery.pageTitle, liveDot: appState.services?.rxLogService != nil)
    .toolbar {
      // Always present, connected or not, so the toolbar's item identity never changes.
      ToolbarItem(placement: .topBarTrailing) {
        ScanAdvertButton()
      }
    }
    .errorAlert($viewModel.errorMessage, title: L10n.Tools.Tools.NodeDiscovery.errorTitle)
    .onChange(of: viewModel.wardrivePrompt) { _, prompt in
      if let prompt { presentedWardrivePrompt = prompt }
    }
    .alert(
      presentedWardrivePrompt.map(Self.promptTitle) ?? "",
      isPresented: Binding(
        get: { presentedWardrivePrompt != nil },
        set: { shown in
          guard !shown, let dismissed = presentedWardrivePrompt else { return }
          presentedWardrivePrompt = nil
          // Still the same prompt: it was dismissed, not answered.
          if viewModel.wardrivePrompt == dismissed { viewModel.cancelWardrivePrompt() }
        }
      ),
      presenting: presentedWardrivePrompt
    ) { prompt in
      if prompt == .locationDenied {
        Button(L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.openSettings) {
          viewModel.cancelWardrivePrompt()
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        }
      }
      Button(prompt == .firstRun
        ? L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.start
        : L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.startAnyway) {
        viewModel.confirmWardrivePrompt()
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {
        viewModel.cancelWardrivePrompt()
      }
    } message: { prompt in
      Text(Self.promptMessage(prompt))
    }
    .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.scanStartHapticTrigger)
    // A probe finished: a tap for answers, a warning for silence.
    .sensoryFeedback(trigger: appState.probeCoordinator.lastSummary) { _, summary in
      summary.map { $0.answered > 0 ? SensoryFeedback.success : .warning }
    }
    .sensoryFeedback(.success, trigger: viewModel.addSuccessHapticTrigger)
    .sensoryFeedback(.error, trigger: viewModel.addErrorHapticTrigger)
    .sensoryFeedback(.selection, trigger: viewModel.selectedKey) { _, key in key != nil }
    .task(id: appState.servicesVersion) {
      viewModel.configure(dependencies: .live(appState: appState))
      // A cooldown another screen's probe (or CarPlay's) started shows at once.
      await viewModel.refreshCooldown()
      #if DEBUG
        // Screenshot runs with `-uiTestDiscoveryDemo YES`: `-uiTestScanNow YES` starts a scan, so
        // the demo's neighbours land on the map and in the list; `-uiTestScanShowOlder YES` adds
        // the ones heard before it.
        if UserDefaults.standard.bool(forKey: "uiTestScanNow"), viewModel.scanStartedAt == nil {
          viewModel.toggleScan()
        }
        if UserDefaults.standard.bool(forKey: "uiTestScanShowOlder") { viewModel.showsOlder = true }
        // `-uiTestScanLowered YES` opens with the sheet lowered to its header; `-uiTestScanRaised
        // YES` with it all the way up, the list over the map.
        if UserDefaults.standard.bool(forKey: "uiTestScanLowered") { sheetState = .lowered }
        if UserDefaults.standard.bool(forKey: "uiTestScanRaised") { sheetState = .list }
        // `-uiTestScanDragOffset -200`: the sheet held mid-drag by that many points, to look at it.
        if let text = ProcessInfo.processInfo.launchArgument("uiTestScanDragOffset"), let offset = Double(text) {
          sheetDrag.isDragging = true
          sheetDrag.translation = offset
        }
        // `-uiTestWardrive YES` starts Wardrive (the demo's, with `-uiTestDiscoveryDemo YES`),
        // its first-run note taken as read.
        if UserDefaults.standard.bool(forKey: "uiTestWardrive"), !viewModel.isWardriving {
          UserDefaults.standard.set(true, forKey: AppStorageKey.hasSeenWardriveNote.rawValue)
          viewModel.startWardrive()
        }
      #endif
    }
    .task(id: appState.servicesVersion) {
      traffic.configure(
        rxLogService: { [appState] in appState.services?.rxLogService },
        rxStreamService: { [appState] in appState.services?.rxStreamService },
        observations: appState.observationDirectory
      )
      await traffic.subscribe()
      #if DEBUG
        // Screenshot runs: `-uiTestScanPackets YES` adds a minute of packets, `-uiTestScanTraffic YES`
        // opens their section.
        if UserDefaults.standard.bool(forKey: "uiTestScanPackets"), let radioID = appState.currentRadioID {
          traffic.addDemoPackets(radioID: radioID)
        }
        if UserDefaults.standard.bool(forKey: "uiTestScanTraffic") { section = .packets }
      #endif
    }
    // Opened (or, already open, switched) for a section: Home's Traffic card opens the packets,
    // the Nodes tab's link the nodes.
    .onChange(of: appState.navigation.pendingScanSection, initial: true) { _, pending in
      guard let pending else { return }
      appState.navigation.pendingScanSection = nil
      if pending == .packets { viewModel.selectedKey = nil }
      section = pending
    }
    .onChange(of: appState.connectedDevice?.radioID) { _, _ in
      // Configuring drops the previous radio's selection and stored names.
      viewModel.configure(dependencies: .live(appState: appState))
    }
    .onAppear {
      appState.locationService.requestLocation()
      if viewModel.isWardriving { UIApplication.shared.isIdleTimerDisabled = true }
    }
    .onDisappear {
      traffic.unsubscribe()
      // Probes and Wardrive run on in the coordinator. Wardrive keeps the screen on while it
      // runs; with it off, the screen may sleep again.
      if !viewModel.isWardriving { UIApplication.shared.isIdleTimerDisabled = false }
    }
    .onChange(of: isConnected) { _, connected in
      // No radio, nothing to hear: don't keep the phone's location running in the background.
      if !connected { viewModel.stopWardrive() }
    }
    .onChange(of: viewModel.isWardriving) { _, wardriving in
      // Wardrive rides along in the car: the screen stays on while it runs. The coordinator
      // follows the phone's location meanwhile, so each node is placed where it was heard.
      UIApplication.shared.isIdleTimerDisabled = wardriving
    }
    .onChange(of: viewModel.filter) { _, _ in
      // Only the list changes: a probe or Wardrive for the other kind runs on.
      viewModel.selectedKey = nil
    }
    .onChange(of: viewModel.scanStartedAt) { _, _ in
      // A new scan empties the list: the node picked from the last one goes with it.
      viewModel.selectedKey = nil
    }
  }
}

// MARK: - Wardrive prompts

extension NodeDiscoveryView {
  static func promptTitle(_ prompt: WardrivePrompt) -> String {
    switch prompt {
    case .locationDenied: L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.LocationDenied.title
    case .firstRun: L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.FirstRun.title
    case let .lowBattery(percent): L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.LowBattery.title(percent)
    case .lowPowerMode: L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.LowPower.title
    }
  }

  static func promptMessage(_ prompt: WardrivePrompt) -> String {
    switch prompt {
    case .locationDenied: L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.LocationDenied.message
    case .firstRun: L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.FirstRun.message
    case .lowBattery: L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.LowBattery.message
    case .lowPowerMode: L10n.Tools.Tools.NodeDiscovery.Wardrive.Preflight.LowPower.message
    }
  }
}

// MARK: - Full screen

extension NodeDiscoveryView {
  /// The Traffic map with the scan's neighbours. The map follows the route filter only, and names
  /// nodes from the index the list does.
  private func map(bottomInset: CGFloat, isCompact: Bool) -> some View {
    let isConnected = appState.services?.rxLogService != nil
    return TrafficMapView(
      entries: traffic.mapEntries,
      filterKey: traffic.routeFilter.rawValue,
      hasLoadedHistory: traffic.hasLoadedHistory,
      isConnected: isConnected,
      onOpenList: showPackets,
      stockNote: isConnected ? traffic.longPacketNote : nil,
      scan: viewModel,
      section: section,
      isFullScreen: isMapFullScreen,
      isCompact: isCompact,
      bottomInset: bottomInset,
      // A phone's lowered sheet shows the packet under its mini spectrum instead.
      showsTicker: horizontalSizeClass == .regular,
      model: trafficMap,
      // A tap on an empty spot of the map hides the list, giving the map the screen.
      onMapBackgroundTap: { if !isMapFullScreen { settle(.lowered) } }
    )
  }

  /// The ticker's tap: the Packets list, the sheet raised from its header.
  private func showPackets() {
    section = .packets
    if isMapFullScreen { settle(.split) }
  }

  /// The sheet's top for `state`, from the top of the space the map and sheet share.
  private func sheetTop(_ state: NodeDiscoverySheetState, height: CGFloat) -> CGFloat {
    NodeDiscoverySheetSnap.top(of: state, height: height, splitFraction: mapFraction, loweredHeight: loweredSheetHeight)
  }

  /// The results on the page background, with a rounded top and a grabber; the grabber and the
  /// header under it move the sheet. Lowered, the header alone, and a tap on the grabber raises it.
  private func resultsSheet(height: CGFloat) -> some View {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: Self.sheetCornerRadius,
      topTrailingRadius: Self.sheetCornerRadius,
      style: .continuous
    )
    return VStack(spacing: 0) {
      grabber
        .highPriorityGesture(sheetDragGesture(height: height))
      NodeDiscoveryPanel(
        viewModel: viewModel,
        traffic: traffic,
        section: $section,
        isCollapsed: isMapFullScreen,
        trafficMap: trafficMap,
        onOpenPackets: showPackets,
        onExpandSheet: { if isMapFullScreen { settle(.split) } },
        headerDrag: AnyGesture(sheetDragGesture(height: height).map { _ in () })
      )
    }
    .background(alignment: .top) {
      // Taller than the sheet, so a sheet dragged up shows more of itself below, not the map, and
      // on past the safe area's bottom to cover the home indicator's strip by plain height: no
      // `ignoresSafeArea` here, which laid the backdrop out against the safe area and left the
      // grabber and header running ahead of it while a drag moved the sheet.
      sheetBackdrop
        .frame(height: height + Self.sheetCornerRadius + Self.sheetBackdropOverrun)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.18), radius: 8, y: -2)
    }
  }

  /// How far past the sheet's bottom its backdrop runs: the home indicator's strip and more.
  private static let sheetBackdropOverrun: CGFloat = 120

  /// The page background the sheet's cards sit on: the user's backdrop, or the grouped colour.
  @ViewBuilder
  private var sheetBackdrop: some View {
    if let backdrop = theme.backdrop {
      AppBackdropView(backdrop: backdrop)
    } else {
      Color(.systemGroupedBackground)
    }
  }

  /// The sheet follows a vertical drag on its grabber or header from any resting place, by an
  /// offset only; let go, it settles where the drag's speed would have carried it (the list, the
  /// split, or lowered), once, and only then do the map's viewport and overlays follow. A mostly
  /// sideways drag is left alone.
  private func sheetDragGesture(height: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .global)
      .onChanged { value in
        if !sheetDrag.isDragging {
          guard abs(value.translation.height) > abs(value.translation.width) else { return }
          sheetDrag.isDragging = true
        }
        sheetDrag.translation = value.translation.height
      }
      .onEnded { value in
        guard sheetDrag.isDragging else { return }
        sheetDrag.isDragging = false
        let target = NodeDiscoverySheetSnap.target(
          from: sheetState,
          predictedTranslation: value.predictedEndTranslation.height,
          height: height,
          splitFraction: mapFraction,
          loweredHeight: loweredSheetHeight
        )
        settle(target)
      }
  }

  /// Moves the sheet to rest at `state`, the drag's offset folded into the same animation.
  private func settle(_ state: NodeDiscoverySheetState) {
    withAnimation(reduceMotion ? nil : .snappy) {
      sheetState = state
      sheetDrag.translation = 0
    }
  }

  /// The handle: drags with the header (see `sheetDragGesture`); a tap on the lowered sheet's
  /// raises it. VoiceOver moves the split a step at a time, and past either end lowers the sheet
  /// or raises it again.
  private var grabber: some View {
    Capsule()
      .fill(Color.secondary.opacity(0.5))
      .frame(width: 36, height: 5)
      .frame(maxWidth: .infinity, minHeight: 22)
      .contentShape(.rect)
      .onTapGesture {
        if isMapFullScreen { settle(.split) }
      }
      .accessibilityElement()
      .accessibilityLabel(L10n.Tools.Tools.NodeDiscovery.Map.resize)
      .accessibilityValue(Double(isMapFullScreen ? 1 : sheetState == .list ? 0 : mapFraction).formatted(.percent.precision(.fractionLength(0))))
      .accessibilityAdjustableAction { direction in
        switch (sheetState, direction) {
        case (.lowered, .decrement): settle(.split)
        case (.list, .increment): settle(.split)
        case (.split, _):
          let step: CGFloat = direction == .increment ? 0.1 : -0.1
          let next = mapFraction + step
          if next > Self.mapFractionRange.upperBound {
            settle(.lowered)
          } else if next < Self.mapFractionRange.lowerBound {
            settle(.list)
          } else {
            mapFraction = next
          }
        default: break
        }
      }
      .accessibilityIdentifier("nodeDiscovery.grabber")
  }
}

/// The finger on the results sheet: how far it has moved and whether it's a vertical drag. Kept
/// apart from the page's state so a drag redraws only the sheet's offset.
@Observable
@MainActor
final class NodeDiscoverySheetDrag {
  var translation: CGFloat = 0
  @ObservationIgnored var isDragging = false
}

/// Moves the sheet with the finger (`NodeDiscoverySheetSnap.offset`): the one view that reads the
/// drag, so the sheet's contents and the map aren't laid out again as it moves.
private struct NodeDiscoverySheetOffset: ViewModifier {
  let drag: NodeDiscoverySheetDrag
  let state: NodeDiscoverySheetState
  let height: CGFloat
  let splitFraction: CGFloat
  let loweredHeight: CGFloat

  func body(content: Content) -> some View {
    content.offset(y: NodeDiscoverySheetSnap.offset(
      from: state,
      translation: drag.translation,
      height: height,
      splitFraction: splitFraction,
      loweredHeight: loweredHeight
    ))
  }
}

/// Sends this radio's advert from the page's top-right corner, the quickest way to see the mesh at
/// work: each repeater that passes it on shows up on the map as it comes back. A tap asks which,
/// zero-hop to the nodes in range or flooded across the mesh, as Home's Send Advert does; the glyph
/// says sent or failed for a moment after. Always the same button, varied by value, so the toolbar
/// item keeps one identity.
private struct ScanAdvertButton: View {
  @Environment(\.appState) private var appState
  @State private var isChoosing = false
  @State private var isSending = false
  @State private var result: Bool?

  private var systemImage: String {
    switch result {
    case true?: "checkmark"
    case false?: "exclamationmark.triangle.fill"
    case nil: "megaphone.fill"
    }
  }

  var body: some View {
    Button {
      isChoosing = true
    } label: {
      Label(L10n.Tools.Tools.advert, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .contentTransition(.symbolEffect(.replace))
    }
    .tint(HomeToolColors.lead)
    .radioDisabled(for: appState.connectionState, or: isSending)
    .help(L10n.Tools.Tools.advert)
    .accessibilityLabel(L10n.Tools.Tools.advert)
    .accessibilityHint(L10n.Tools.Tools.Subtitle.advert)
    .accessibilityValue(result.map { $0 ? L10n.Chats.Chats.Message.Status.sent : L10n.Chats.Chats.Message.Status.failed } ?? "")
    .accessibilityIdentifier("nodeDiscovery.advert")
    .sheet(isPresented: $isChoosing) {
      AdvertChoiceSheet { flood in send(flood: flood) }
    }
    .sensoryFeedback(trigger: result) { _, result in
      result.map { $0 ? .success : .error }
    }
  }

  private func send(flood: Bool) {
    guard !isSending else { return }
    isSending = true
    Task {
      let succeeded: Bool
      do {
        try await appState.sendSelfAdvert(flood: flood)
        succeeded = true
      } catch {
        succeeded = false
      }
      isSending = false
      withAnimation { result = succeeded }
      try? await Task.sleep(for: .seconds(succeeded ? 2 : 3))
      withAnimation { result = nil }
    }
  }
}

#Preview {
  NavigationStack {
    NodeDiscoveryView()
  }
  .environment(\.appState, AppState())
}
