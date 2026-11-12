import MapKit
import MapLibre
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "MapPins")

struct CairnMapView: UIViewRepresentable {
  // Data
  let points: [MapPoint]
  let lines: [MapLine]
  let mapStyle: MapStyleSelection
  let isDarkMode: Bool
  var isOffline: Bool = false

  // Configuration
  let showLabels: Bool
  var clusteringEnabled: Bool = true
  let showsUserLocation: Bool
  let isInteractive: Bool
  let showsScale: Bool
  var isNorthLocked: Bool = false
  /// Hides MapLibre's logo and attribution button. Only for small, non-interactive previews,
  /// where the ornaments crowd the picture and can't be tapped anyway; the credits live in
  /// Settings > About instead. Full maps keep them.
  var hidesAttribution = false
  /// Washes the basemap out so the pins and lines drawn over it stand out, for previews that
  /// only need to show where something is. See `Coordinator.applyMutedBasemap`.
  var isMuted = false
  /// Hides every basemap label (places, roads, points of interest), for a map that sits behind
  /// its own lettering, like the full compass's dial. Set once; not changed while showing.
  var hidesBasemapLabels = false

  // Camera
  @Binding var cameraRegion: MKCoordinateRegion?
  let cameraRegionVersion: Int
  var cameraEdgePadding: UIEdgeInsets = .zero
  var cameraBottomSheetFraction: CGFloat?
  /// Pads one region request (the one whose version it names) to the part of the map left
  /// clear by the safe area and the caller's overlays, so a trace fit lands in view.
  var cameraFitPadding: MapCameraFitPadding?
  /// How much of the map's bottom a sheet over it covers, for a map that runs full height behind
  /// one (Scan & Traffic): the map's viewport ends above it, so centering, framing and following
  /// all land in the part that shows, and moving the sheet never resizes the map. Nil leaves
  /// MapLibre to inset for the bars on its own.
  var contentBottomInset: CGFloat?
  /// When set, the MapLibre logo and attribution sit this far above the safe-area bottom so overlay chrome does not cover them.
  var legalOrnamentBottomMargin: CGFloat?
  /// The MapLibre logo and attribution in the bottom-right corner rather than the bottom-left
  /// (Scan & Traffic on an iPad, whose ticker runs along the whole bottom with its colour key in
  /// that corner), the logo at the edge and the attribution to its left.
  var legalOrnamentsAtTrailing = false
  /// When set, the MapLibre logo and attribution sit just above this window y (an overlay's top
  /// edge, in global coordinates). Measured from the map's own safe area, which a floating tab bar
  /// over a full-bleed map isn't part of, so a fixed margin can't clear an overlay above it.
  var legalOrnamentTopLimit: CGFloat?

  // Programmatic selection: the id of the point to select, plus a version
  // counter bumped to (re)fire it, mirroring the camera region + version idiom.
  // The coordinator projects the point and routes it through `onPointTap`, so a
  // programmatic selection is the same code path as a user tap.
  var selectionRequestID: UUID?
  var selectionRequestVersion: Int = 0

  /// The pin whose callout is open. Its name badge wins every label collision.
  var selectedPointID: UUID?
  /// Told where the selected pin's callout anchor is on screen as the camera moves, so a callout
  /// drawn over the map can stay on its pin while the map is panned or zoomed.
  var onSelectedPointMove: ((CGPoint) -> Void)?

  // Output callbacks
  let onPointTap: ((MapPoint, CGPoint) -> Void)?
  let onMapTap: ((CLLocationCoordinate2D) -> Void)?
  var onMapLongPress: ((CLLocationCoordinate2D) -> Void)?
  /// A tap on a line, by its `MapLine.id`. Nil leaves lines untappable (every map but Traffic).
  var onLineTap: ((String) -> Void)?
  let onCameraRegionChange: ((MKCoordinateRegion) -> Void)?
  /// Reports a user drag/pinch/rotate starting (true) and the camera settling after it (false).
  var onUserGestureChange: ((Bool) -> Void)?

  /// Optional features
  var isStyleLoaded: Binding<Bool> = .constant(true)

  /// Reports whether the camera is currently centered on the user's location.
  var isCenteredOnUser: Binding<Bool> = .constant(false)

  /// How precisely MapLibre's own location manager tracks the user's dot. Best (MapLibre's
  /// default) suits a map that follows the phone; a detail or preview map that only shows
  /// roughly where you are asks for less so it doesn't keep the GPS radio running.
  var userLocationAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest

  // Navigation: Apple Maps-style following, used by the GPS tab's map. Every other surface
  // leaves these at their defaults and keeps MapLibre's own compass and no tracking.

  /// How the camera follows the user. MapLibre drops it when the user pans (and from heading to
  /// follow when they rotate), and the change is written back here. Nil leaves tracking alone.
  var userTrackingMode: Binding<MapTrackingMode>?
  /// Draws a heading cone on the user's location dot when the phone has a compass.
  var showsUserHeadingIndicator = false
  /// Hides MapLibre's compass ornament for a caller that draws its own, and moves the scale
  /// bar from the top-left (where that caller's readout sits) to just above the logo.
  var hidesCompassOrnament = false
  /// Puts the scale bar at the bottom right, level with the logo: above a floating tab bar or the
  /// overlay `legalOrnamentTopLimit` names. For a map whose controls sit at the top.
  var scaleBarAtBottomTrailing = false
  /// Reports the camera's rotation and tilt as they change, for the caller's compass.
  var onCameraOrientationChange: ((MapCameraOrientation) -> Void)?
  /// Bumped to animate the camera back to north-up and flat (the compass tap).
  var resetOrientationVersion = 0
  /// Reports where following moved the camera, so zoom steps, offline gating and the saved camera
  /// start from where the map really is. Separate from `onCameraRegionChange`, which also closes
  /// callouts: a following camera moves with every fix, and that shouldn't dismiss them.
  var onFollowingCameraChange: ((MKCoordinateRegion) -> Void)?

  /// Given the map view, so an overlay can place what it draws on the map (see `MapProjection`).
  var projection: MapProjection?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> MLNMapView {
    let mapView = context.coordinator.mapView
    mapView.delegate = context.coordinator

    context.coordinator.requestedUserLocationAccuracy = userLocationAccuracy
    context.coordinator.syncUserLocationAccuracy()
    mapView.wantsUserLocation = showsUserLocation
    mapView.showsUserHeadingIndicator = showsUserHeadingIndicator
    mapView.compassViewPosition = .topRight
    mapView.compassViewMargins = OrnamentLayout.compassMargins
    mapView.logoViewPosition = legalOrnamentsAtTrailing ? .bottomRight : .bottomLeft
    mapView.attributionButtonPosition = legalOrnamentsAtTrailing ? .bottomRight : .bottomLeft
    // The logo is the credits button: a tap on it opens the attribution the (i) used to, and the
    // (i) itself stays out of the picture.
    mapView.attributionButton.isHidden = true
    mapView.logoView.isUserInteractionEnabled = true
    mapView.logoView.isAccessibilityElement = true
    mapView.logoView.accessibilityTraits = .button
    mapView.logoView.accessibilityLabel = mapView.attributionButton.accessibilityLabel
    mapView.logoView.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.logoTapped(_:))))
    Self.applyOrnamentMargins(to: mapView, bottomClearance: ornamentClearance(for: mapView), atTrailing: legalOrnamentsAtTrailing)

    // On an interactive map the scale bar only shows while the camera moves (see
    // `Coordinator.setScaleBarVisible`), as in Apple Maps; a static map has no moves to wait for.
    if showsScale {
      mapView.showsScale = !isInteractive
      context.coordinator.fadesScaleBar = isInteractive
    }
    if hidesAttribution {
      mapView.logoView.isHidden = true
      mapView.attributionButton.isHidden = true
    }

    if !isInteractive {
      mapView.isScrollEnabled = false
      mapView.isZoomEnabled = false
      mapView.isRotateEnabled = false
      mapView.isPitchEnabled = false
      mapView.compassView.isHidden = true
    }
    if hidesCompassOrnament {
      mapView.compassView.isHidden = true
      mapView.scaleBarPosition = .bottomLeft
      mapView.scaleBarMargins = OrnamentLayout.scaleBarAboveLogoMargins
    }
    if scaleBarAtBottomTrailing {
      mapView.scaleBarPosition = .bottomRight
      applyScaleBarMargins(to: mapView)
    }

    // Disable quick-zoom (tap-then-hold-drag) gesture
    mapView.gestureRecognizers?
      .compactMap { $0 as? UILongPressGestureRecognizer }
      .filter { $0.numberOfTapsRequired == 1 && $0.minimumPressDuration == 0 }
      .forEach { $0.isEnabled = false }

    // Tap gesture for feature queries
    let tap = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleTap(_:))
    )
    tap.delegate = context.coordinator
    mapView.addGestureRecognizer(tap)

    // Long-press gesture for dropping a pin at the pressed coordinate
    let longPress = UILongPressGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleLongPress(_:))
    )
    longPress.delegate = context.coordinator
    mapView.addGestureRecognizer(longPress)

    if isInteractive {
      context.coordinator.installScrollInputRecognizers()
    }

    return mapView
  }

  static func dismantleUIView(_ mapView: MLNMapView, coordinator: Coordinator) {
    coordinator.pendingRegionTask?.cancel()
    coordinator.scaleBarFadeTask?.cancel()
    coordinator.mastLightFlasher.stop()
    mapView.delegate = nil
  }

  func updateUIView(_ mapView: MLNMapView, context: Context) {
    let coordinator = context.coordinator
    coordinator.isUpdatingFromSwiftUI = true
    defer { coordinator.isUpdatingFromSwiftUI = false }

    if let projection, projection.mapView !== mapView {
      projection.mapView = mapView
    }

    // Refresh callbacks
    coordinator.onPointTap = onPointTap
    coordinator.onMapTap = onMapTap
    coordinator.onMapLongPress = onMapLongPress
    coordinator.onLineTap = onLineTap
    coordinator.onCameraRegionChange = onCameraRegionChange
    coordinator.onUserGestureChange = onUserGestureChange
    coordinator.setIsStyleLoaded = { isStyleLoaded.wrappedValue = $0 }
    coordinator.setIsCenteredOnUser = { isCenteredOnUser.wrappedValue = $0 }
    coordinator.onCameraOrientationChange = onCameraOrientationChange
    coordinator.onFollowingCameraChange = onFollowingCameraChange
    coordinator.setUserTrackingMode = userTrackingMode.map { binding in { binding.wrappedValue = $0 } }
    coordinator.currentPoints = points
    coordinator.currentLines = lines
    // Set before the styleURL below: a theme switch changes the styleURL and triggers
    // a reload, so didFinishLoading -> renderAll must already see the new theme.
    coordinator.currentIsDarkMode = isDarkMode
    coordinator.currentAvatarAppearance = MapAvatarAppearance(
      theme: context.environment.appTheme,
      colorScheme: context.environment.colorScheme,
      contrast: context.environment.colorSchemeContrast
    )
    coordinator.currentIsMuted = isMuted
    coordinator.hidesBasemapLabels = hidesBasemapLabels
    coordinator.currentClusteringEnabled = clusteringEnabled
    coordinator.currentSelectedPointID = selectedPointID
    coordinator.onSelectedPointMove = onSelectedPointMove
    coordinator.currentLabelFontSize = MapLabelBadge.fontSize(
      for: mapView.traitCollection.preferredContentSizeCategory
    )

    // Style URL change — compare against our tracked value, not mapView.styleURL
    // which MapLibre may transiently nil during layout/rotation.
    let newStyleURL = mapStyle.styleURL(isDarkMode: isDarkMode, isOffline: isOffline)
    if coordinator.lastAppliedStyleURL != newStyleURL {
      coordinator.lastAppliedStyleURL = newStyleURL
      coordinator.isStyleLoaded = false
      mapView.styleURL = newStyleURL
    }
    coordinator.currentMapStyle = mapStyle

    // User location
    coordinator.requestedUserLocationAccuracy = userLocationAccuracy
    if let mapView = mapView as? WindowAwareMapView, mapView.wantsUserLocation != showsUserLocation {
      mapView.wantsUserLocation = showsUserLocation
    }
    if mapView.showsUserHeadingIndicator != showsUserHeadingIndicator {
      mapView.showsUserHeadingIndicator = showsUserHeadingIndicator
    }

    // North lock
    if isInteractive {
      mapView.isRotateEnabled = !isNorthLocked
      if isNorthLocked, mapView.direction != 0 {
        mapView.setDirection(0, animated: true)
      }
    }

    // Update data layers (only when style is loaded and not mid-gesture).
    // Compare against lastApplied* so updates arriving during a gesture
    // are applied once the gesture ends.
    if coordinator.isStyleLoaded, !coordinator.isUserInteracting {
      if coordinator.lastAppliedMapStyle != mapStyle {
        coordinator.updateRasterLayerVisibility(mapView: mapView)
        coordinator.lastAppliedMapStyle = mapStyle
      }
      if coordinator.lastAppliedPoints != points
        || coordinator.lastAppliedClusteringEnabled != clusteringEnabled
        || coordinator.lastAppliedSelectedPointID != coordinator.currentSelectedPointID
        || coordinator.lastAppliedLabelFontSize != coordinator.currentLabelFontSize
        || coordinator.lastAppliedLabelIsDark != isDarkMode
        || coordinator.lastAppliedAvatarAppearance != coordinator.currentAvatarAppearance {
        coordinator.currentClusteringEnabled = clusteringEnabled
        coordinator.updatePointSource(mapView: mapView)
        coordinator.lastAppliedPoints = points
        coordinator.lastAppliedClusteringEnabled = clusteringEnabled
      }
      if coordinator.lastAppliedLines != lines {
        coordinator.updateLineSource(mapView: mapView)
        coordinator.lastAppliedLines = lines
      }
      // Offline maps keep one style for both themes, so a theme switch can arrive without a
      // reload and the wash must follow it here.
      if coordinator.lastAppliedIsMuted != isMuted
        || (isMuted && coordinator.lastAppliedMutedIsDark != isDarkMode) {
        coordinator.applyMutedBasemap(style: mapView.style)
      }
      if coordinator.currentShowLabels != showLabels {
        coordinator.currentShowLabels = showLabels
        coordinator.updateLabelVisibility(mapView: mapView, showLabels: showLabels)
      }
    }

    Self.applyOrnamentMargins(to: mapView, bottomClearance: ornamentClearance(for: mapView), atTrailing: legalOrnamentsAtTrailing)
    applyScaleBarMargins(to: mapView)
    applyContentBottomInset(to: mapView, coordinator: coordinator)

    // Camera region (version-number pattern)
    updateCameraRegion(in: mapView, coordinator: coordinator)

    // Following and the compass tap, after the region so a location-button recenter lands
    // before following takes over.
    updateUserTracking(in: mapView, coordinator: coordinator)
    coordinator.syncUserLocationAccuracy()
    if coordinator.lastAppliedResetOrientationVersion != resetOrientationVersion {
      coordinator.lastAppliedResetOrientationVersion = resetOrientationVersion
      coordinator.resetOrientation()
    }

    // Programmatic selection (version-number pattern). Runs once per bump, after the
    // camera update so the projection reads the just-applied camera. Dispatched async
    // so it never mutates SwiftUI state during this representable update, matching how
    // `onCameraRegionChange` defers its write-back.
    if coordinator.isStyleLoaded,
       coordinator.lastAppliedSelectionVersion != selectionRequestVersion {
      coordinator.lastAppliedSelectionVersion = selectionRequestVersion
      if let id = selectionRequestID,
         let point = coordinator.currentPoints.first(where: { $0.id == id }) {
        DispatchQueue.main.async { coordinator.selectPoint(point) }
      }
    }
  }

  /// Maximum absolute latitude MapLibre's `mbgl::LatLng` accepts; it throws an
  /// uncaught `std::domain_error` (aborting the app) for any value beyond ±90.
  private static let latitudeLimit = 90.0

  private func updateCameraRegion(in mapView: MLNMapView, coordinator: Coordinator) {
    guard let region = cameraRegion else { return }
    guard cameraRegionVersion != coordinator.lastAppliedRegionVersion else { return }

    guard CLLocationCoordinate2DIsValid(region.center) else {
      coordinator.lastAppliedRegionVersion = cameraRegionVersion
      return
    }

    // Corners are center ± span/2, so a non-finite span makes MapLibre's LatLng
    // constructor throw and abort the process — and the latitude clamp below can't
    // catch it because Swift's max/min propagate NaN. Skip the update when non-finite.
    guard region.span.latitudeDelta.isFinite,
          region.span.longitudeDelta.isFinite else {
      coordinator.lastAppliedRegionVersion = cameraRegionVersion
      return
    }

    // A region request (center all, a chat pin, zoom) moves the camera somewhere else, so it
    // ends any following first, or MapLibre would pull the camera straight back to the user.
    if mapView.userTrackingMode != .none {
      mapView.setUserTrackingMode(.none, animated: false, completionHandler: nil)
    }
    // A follow still waiting on an earlier recenter is off too, or it would start when this
    // flight settles and undo the framing. MapLibre never started it, so report it here. The
    // location button's own recenter sets its follow again in `updateUserTracking`, which runs
    // after this in the same pass.
    if coordinator.pendingTrackingMode != nil {
      coordinator.pendingTrackingMode = nil
      let report = coordinator.setUserTrackingMode
      DispatchQueue.main.async { report?(.none) }
    }

    let isInflated = mapView.window.map { mapView.bounds.height > $0.bounds.height * 1.5 } ?? false
    // Reduce Motion: jump straight to the new framing instead of flying there.
    let animated = coordinator.lastAppliedRegionVersion > 0 && !isInflated
      && !UIAccessibility.isReduceMotionEnabled
    coordinator.lastAppliedRegionVersion = cameraRegionVersion

    // Clamp latitude so a near-pole center can't push a corner past ±90 (another
    // LatLng abort). Longitude is left unclamped because MapLibre wraps it.
    let limit = Self.latitudeLimit
    let bounds = MLNCoordinateBounds(
      sw: CLLocationCoordinate2D(
        latitude: max(-limit, region.center.latitude - region.span.latitudeDelta / 2),
        longitude: region.center.longitude - region.span.longitudeDelta / 2
      ),
      ne: CLLocationCoordinate2D(
        latitude: min(limit, region.center.latitude + region.span.latitudeDelta / 2),
        longitude: region.center.longitude + region.span.longitudeDelta / 2
      )
    )
    var padding = cameraEdgePadding
    if let sheetFraction = cameraBottomSheetFraction {
      let insets = mapView.safeAreaInsets
      padding.top = max(padding.top, insets.top + 20)
      padding.left = max(padding.left, insets.left + 20)
      if sheetFraction > 0 {
        let stableHeight = mapView.window?.bounds.height ?? mapView.bounds.height
        padding.bottom = max(padding.bottom, stableHeight * sheetFraction)
      }
    }
    if let fit = cameraFitPadding, fit.regionVersion == cameraRegionVersion {
      // Replaces, not maxes, the padding above: MapLibre adds its own `contentInset` (kept in
      // step with the safe area once the map is laid out) to whatever we pass, so the request
      // must carry only the part of the fit padding that inset does not already cover.
      padding = TraceCameraFit.requestEdgePadding(
        safeArea: mapView.safeAreaInsets,
        contentInset: mapView.contentInset,
        overlays: fit.overlays,
        viewSize: mapView.bounds.size
      )
      logger.debug(
        "Trace fit: size \(String(describing: mapView.bounds.size)) safe \(String(describing: mapView.safeAreaInsets)) contentInset \(String(describing: mapView.contentInset)) request \(String(describing: padding))"
      )
    }

    if let windowSize = mapView.window?.bounds.size,
       mapView.bounds.height > windowSize.height * 1.5 {
      let centerLat = (bounds.sw.latitude + bounds.ne.latitude) / 2
      let centerLon = (bounds.sw.longitude + bounds.ne.longitude) / 2
      let latSpanMeters = abs(bounds.ne.latitude - bounds.sw.latitude) * 111_000
      let lonSpanMeters = abs(bounds.ne.longitude - bounds.sw.longitude) * 111_000
        * cos(centerLat * .pi / 180)

      let usableWidth = max(1, Double(windowSize.width) - Double(padding.left + padding.right))
      let usableHeight = max(1, Double(windowSize.height) - Double(padding.top + padding.bottom))

      let mppForLat = latSpanMeters / usableHeight
      let mppForLon = lonSpanMeters / usableWidth
      let requiredMPP = max(mppForLat, mppForLon)

      let currentMPP = mapView.metersPerPoint(atLatitude: centerLat)
      let targetZoom = mapView.zoomLevel + log2(currentMPP / requiredMPP)

      let pixelOffset = (Double(padding.top) - Double(padding.bottom)) / 2
      let offsetDeg = pixelOffset * requiredMPP / 111_000
      let center = CLLocationCoordinate2D(
        latitude: min(limit, max(-limit, centerLat + offsetDeg)),
        longitude: centerLon
      )

      mapView.setCenter(center, zoomLevel: targetZoom, animated: false)
    } else {
      // Following requested with this region (the location button) starts once it settles.
      coordinator.isRegionAnimating = animated
      mapView.setVisibleCoordinateBounds(
        bounds,
        edgePadding: padding,
        animated: animated,
        // Also settles a flight that ends without a region change (already there). A flight a
        // newer request cut short completes too; the version keeps it from settling the new one.
        completionHandler: animated ? { [weak coordinator, cameraRegionVersion] in
          guard coordinator?.lastAppliedRegionVersion == cameraRegionVersion else { return }
          coordinator?.settleRegionAnimation()
        } : nil
      )
    }
  }

  /// Applies a follow mode the caller changed. Only a change to the binding reaches the map:
  /// a mode MapLibre reported (a pan ending it, a region request clearing it) is already in
  /// force, and re-applying the binding's older value in the same pass would undo it.
  private func updateUserTracking(in mapView: MLNMapView, coordinator: Coordinator) {
    guard isInteractive, let requested = userTrackingMode?.wrappedValue else { return }
    // North lock keeps the map still, so heading mode steps down to plain following.
    if isNorthLocked, mapView.userTrackingMode == .followWithHeading {
      coordinator.applyTrackingMode(.follow)
    }
    guard requested != coordinator.lastSeenTrackingRequest else { return }
    coordinator.lastSeenTrackingRequest = requested
    let mode = isNorthLocked && requested == .followWithHeading ? .follow : requested
    if mode != .none, coordinator.isRegionAnimating {
      coordinator.pendingTrackingMode = mode
    } else {
      coordinator.pendingTrackingMode = nil
      coordinator.applyTrackingMode(mode)
    }
  }

  enum OrnamentLayout {
    static let compassMargins = CGPoint(x: 8, y: 8)
    static let defaultLogoMargins = CGPoint(x: 8, y: 8)
    static let defaultAttributionMargins = CGPoint(x: 4, y: 30)
    static let clusterSpacing: CGFloat = 8
    /// The scale bar's bottom-left spot, above the logo and the attribution stacked over it.
    static let scaleBarAboveLogoMargins = CGPoint(x: 8, y: 60)

    static func logoMargins(bottomClearance: CGFloat?) -> CGPoint {
      guard let bottomClearance else { return defaultLogoMargins }
      return CGPoint(x: defaultLogoMargins.x, y: max(defaultLogoMargins.y, bottomClearance))
    }

    static func attributionMargins(bottomClearance: CGFloat?, logoWidth: CGFloat) -> CGPoint {
      guard let bottomClearance else { return defaultAttributionMargins }
      let y = max(defaultLogoMargins.y, bottomClearance)
      if logoWidth > 0 {
        return CGPoint(
          x: defaultLogoMargins.x + logoWidth + clusterSpacing,
          y: y
        )
      }
      let lift = max(0, y - defaultLogoMargins.y)
      return CGPoint(
        x: defaultAttributionMargins.x,
        y: defaultAttributionMargins.y + lift
      )
    }
  }

  /// `legalOrnamentBottomMargin`, or the clearance from the map's safe-area bottom up to
  /// `legalOrnamentTopLimit` once the map is in a window to measure against.
  private func ornamentClearance(for mapView: MLNMapView) -> CGFloat? {
    guard let legalOrnamentTopLimit, mapView.window != nil else { return legalOrnamentBottomMargin }
    let safeBottom = mapView.convert(mapView.bounds, to: nil).maxY - mapView.safeAreaInsets.bottom
    return max(0, safeBottom - legalOrnamentTopLimit) + OrnamentLayout.defaultLogoMargins.y
  }

  /// The viewport's bottom kept above a sheet covering the map (`contentBottomInset`), with the
  /// safe area's other edges as MapLibre would set them; never more than leaves a strip of map to
  /// show. Changing it moves the camera, so it waits while a camera flight runs (it would stop the
  /// flight part way).
  private func applyContentBottomInset(to mapView: MLNMapView, coordinator: Coordinator) {
    guard let contentBottomInset else { return }
    if mapView.automaticallyAdjustsContentInset { mapView.automaticallyAdjustsContentInset = false }
    let safe = mapView.safeAreaInsets
    let limit = max(0, mapView.bounds.height - safe.top - 80)
    let inset = UIEdgeInsets(
      top: safe.top,
      left: safe.left,
      bottom: min(max(safe.bottom, contentBottomInset), limit),
      right: safe.right
    )
    guard mapView.contentInset != inset, !coordinator.isRegionAnimating else { return }
    // Never animated: MapLibre's animated inset change runs a camera transition of its own, which
    // cancels a camera request made alongside it and left the map at its opening world view.
    mapView.setContentInset(inset, animated: false, completionHandler: nil)
  }

  /// A bottom-right scale bar sits as high as the logo, so neither goes under the tab bar; with
  /// the logo in that corner too (`legalOrnamentsAtTrailing`), just above it.
  private func applyScaleBarMargins(to mapView: MLNMapView) {
    guard scaleBarAtBottomTrailing else { return }
    let logoY = OrnamentLayout.logoMargins(bottomClearance: ornamentClearance(for: mapView)).y
    let logoHeight = mapView.logoView.isHidden ? 0 : mapView.logoView.image?.size.height ?? 0
    let aboveLogo = legalOrnamentsAtTrailing && logoHeight > 0 ? logoHeight + OrnamentLayout.clusterSpacing : 0
    let margins = CGPoint(x: OrnamentLayout.defaultLogoMargins.x, y: logoY + aboveLogo)
    if mapView.scaleBarMargins != margins {
      mapView.scaleBarMargins = margins
    }
  }

  private static func applyOrnamentMargins(to mapView: MLNMapView, bottomClearance: CGFloat?, atTrailing: Bool = false) {
    let logoWidth = mapView.logoView.image?.size.width ?? 0
    let logo = OrnamentLayout.logoMargins(bottomClearance: bottomClearance)
    // In the trailing corner the margins count from the right: the attribution goes left of the
    // logo by the logo's width, whatever the clearance.
    let attribution = atTrailing
      ? CGPoint(x: OrnamentLayout.defaultLogoMargins.x + logoWidth + OrnamentLayout.clusterSpacing, y: logo.y)
      : OrnamentLayout.attributionMargins(bottomClearance: bottomClearance, logoWidth: logoWidth)
    if mapView.logoViewMargins != logo {
      mapView.logoViewMargins = logo
    }
    if mapView.attributionButtonMargins != attribution {
      mapView.attributionButtonMargins = attribution
    }
  }
}

// MARK: - Coordinator

extension CairnMapView {
  @MainActor
  class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate, UIGestureRecognizerDelegate {
    /// Non-zero frame avoids MapLibre zero-size Metal init (issue #67).
    let mapView = WindowAwareMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    /// The caller's accuracy for the user's dot, applied in full only while following
    /// (`syncUserLocationAccuracy()`).
    var requestedUserLocationAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest

    /// The logo stands in for the attribution button: its tap runs the button's own action.
    @objc func logoTapped(_ recognizer: UITapGestureRecognizer) {
      mapView.attributionButton.sendActions(for: .touchUpInside)
    }

    // Callbacks
    var onPointTap: ((MapPoint, CGPoint) -> Void)?
    var onMapTap: ((CLLocationCoordinate2D) -> Void)?
    var onMapLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onLineTap: ((String) -> Void)?
    var onCameraRegionChange: ((MKCoordinateRegion) -> Void)?
    var onUserGestureChange: ((Bool) -> Void)?
    var setIsStyleLoaded: ((Bool) -> Void)?
    var setIsCenteredOnUser: ((Bool) -> Void)?
    var setUserTrackingMode: ((MapTrackingMode) -> Void)?
    var onCameraOrientationChange: ((MapCameraOrientation) -> Void)?
    var onFollowingCameraChange: ((MKCoordinateRegion) -> Void)?

    // State
    var isUserInteracting = false
    /// A user gesture moved the camera and it has not settled yet.
    var isUserGestureActive = false
    /// A Mac scroll-wheel zoom or trackpad scroll is in progress.
    var isScrollInputActive = false
    var isUpdatingFromSwiftUI = false
    var isStyleLoaded = false
    var lastAppliedRegionVersion = 0
    var lastAppliedSelectionVersion = 0
    var lastAppliedResetOrientationVersion = 0
    /// The follow mode the binding held at the last update, so only a caller's change applies.
    var lastSeenTrackingRequest: MapTrackingMode = .none
    /// Following asked for while a recenter is still flying; it starts when the camera settles.
    var pendingTrackingMode: MapTrackingMode?
    /// An animated region request is in flight.
    var isRegionAnimating = false
    /// The orientation last reported, so small drift doesn't wake SwiftUI.
    var lastReportedOrientation = MapCameraOrientation()
    var pendingRegionTask: Task<Void, Never>?
    var currentShowLabels = true
    var currentClusteringEnabled = true
    var lastAppliedClusteringEnabled: Bool?
    var currentSelectedPointID: UUID?
    var onSelectedPointMove: ((CGPoint) -> Void)?
    var lastAppliedSelectedPointID: UUID?
    var currentLabelFontSize = MapLabelBadge.baseFontSize
    var lastAppliedLabelFontSize: Int?
    var lastAppliedLabelIsDark: Bool?
    /// The basemap theme in force, mirrored from the view so `renderAll` can pick the
    /// location-dot recency palette at style-load time. Kept current by `updateUIView`.
    var currentIsDarkMode = false
    /// The app's theme, light or dark, and contrast, which node pins' avatars are drawn in.
    var currentAvatarAppearance = MapAvatarAppearance.standard(isDark: false)
    var lastAppliedAvatarAppearance: MapAvatarAppearance?
    /// Avatar sprites this map has put in its style, so ones no pin uses can be removed.
    var appliedAvatarSpriteNames: Set<String> = []
    /// Flashes the quiet repeaters' red lights while the style is loaded.
    lazy var mastLightFlasher = MastLightFlasher { [weak self] in
      guard let self, let style = mapView.style else { return }
      updateMastLightOpacity(style: style)
    }
    /// Whether the basemap wash is wanted, mirrored from the view like `currentIsDarkMode`.
    var currentIsMuted = false
    var hidesBasemapLabels = false
    var lastAppliedIsMuted: Bool?
    var lastAppliedMutedIsDark: Bool?
    /// The scale bar shows only while a gesture moves the camera (interactive maps with a scale).
    var fadesScaleBar = false
    var scaleBarFadeTask: Task<Void, Never>?
    var lastAppliedStyleURL: URL?
    var currentMapStyle: MapStyleSelection?
    var lastAppliedMapStyle: MapStyleSelection?
    var currentPoints: [MapPoint] = []
    var currentLines: [MapLine] = []
    var lastAppliedPoints: [MapPoint] = []
    var lastAppliedClusterablePoints: [MapPoint] = []
    var lastAppliedFixedPoints: [MapPoint] = []
    var lastAppliedLines: [MapLine] = []
    var clusterSource: MLNShapeSource?
    var fixedSource: MLNShapeSource?

    // MARK: - Style loading

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
      isStyleLoaded = true
      setIsStyleLoaded?(true)

      // Clear stale source/state references from the previous style.
      // Reset currentShowLabels to the new layer default (visible) so
      // updateUIView detects the mismatch and reapplies the user's preference.
      // A reload rebuilds the raster layers with isVisible == false, so clear
      // lastAppliedMapStyle to force updateUIView to re-apply the selected overlay.
      clusterSource = nil
      fixedSource = nil
      lastAppliedPoints = []
      lastAppliedClusterablePoints = []
      lastAppliedFixedPoints = []
      lastAppliedLines = []
      lastAppliedMapStyle = nil
      lastAppliedClusteringEnabled = nil
      lastAppliedLabelFontSize = nil
      lastAppliedLabelIsDark = nil
      lastAppliedAvatarAppearance = nil
      appliedAvatarSpriteNames = []
      lastAppliedIsMuted = nil
      lastAppliedMutedIsDark = nil
      currentShowLabels = true

      PinSpriteRenderer.renderAll(into: style, isDarkMode: currentIsDarkMode)
      style.performsPlacementTransitions = false
      MapBasemapLabels.tune(style: style, isDarkMode: currentIsDarkMode, hidesAll: hidesBasemapLabels)
      setupRasterSources(style: style, mapView: mapView)
      // After the rasters and before our lines and pins, so the wash sits over every basemap
      // layer and under everything Cairn draws.
      applyMutedBasemap(style: style)
      setupLineLayers(style: style)

      updatePointSource(mapView: mapView)
      updateLineSource(mapView: mapView)
      if RepeaterMastSprite.isEnabled { mastLightFlasher.start() }
      #if DEBUG
        applyUITestPitch(mapView: mapView)
      #endif
    }

    #if DEBUG
      /// `-uiTestMapPitch 55`: tilts an interactive map that many degrees once its first framing
      /// has settled, for screenshots of the repeater masts standing on their shadows.
      private func applyUITestPitch(mapView: MLNMapView) {
        let pitch = UserDefaults.standard.double(forKey: "uiTestMapPitch")
        guard pitch > 0, mapView.isPitchEnabled else { return }
        Task { [weak mapView] in
          try? await Task.sleep(for: .seconds(6))
          guard let mapView else { return }
          let camera = mapView.camera
          camera.pitch = pitch
          mapView.setCamera(camera, animated: false)
        }
      }
    #endif

    func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
      if let image = PinSpriteRenderer.image(named: imageName) {
        // Tracked so a later prune can remove it again.
        if PinSpriteRenderer.isPerPinSprite(imageName) { appliedAvatarSpriteNames.insert(imageName) }
        return image
      }
      logger.error("didFailToLoadImage: \(imageName)")
      return nil
    }

    func mapView(_ mapView: MLNMapView, shouldRemoveStyleImage imageName: String) -> Bool {
      !PinSpriteRenderer.shouldRetainStyleImage(imageName)
    }

    // MARK: - Region changes

    private static let userGestureReasons: MLNCameraChangeReason = [
      .gesturePan, .gesturePinch, .gestureZoomIn, .gestureZoomOut,
      .gestureRotate, .gestureTilt, .gestureOneFingerZoom
    ]

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
      isUserInteracting = true
      reportOrientation()
      reportSelectedPointPosition()
    }

    /// Where the open callout's pin now sits on screen, for a callout that follows it.
    func reportSelectedPointPosition() {
      guard let report = onSelectedPointMove, let id = currentSelectedPointID,
            let point = currentPoints.first(where: { $0.id == id }) else { return }
      let anchor = calloutAnchor(for: point)
      DispatchQueue.main.async { report(anchor) }
    }

    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
      // A user drag/zoom/rotate moves the camera off the user's location, so clear the
      // centered-on-user flag. Programmatic recenters keep it — the location button sets
      // it back to true when it centers the map.
      guard !reason.isDisjoint(with: Self.userGestureReasons) else { return }
      // The user took the camera, so a recenter's pending follow is off. MapLibre never
      // started it, so nothing else reports the change.
      isRegionAnimating = false
      if pendingTrackingMode != nil {
        pendingTrackingMode = nil
        let reportTracking = setUserTrackingMode
        DispatchQueue.main.async { reportTracking?(.none) }
      }
      let report = setIsCenteredOnUser
      DispatchQueue.main.async { report?(false) }
      if !isUserGestureActive {
        setUserGestureActive(true)
      }
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
      isUserInteracting = false
      reportOrientation()
      reportSelectedPointPosition()
      settleRegionAnimation()
      // MapLibre holds back did-change until a gesture's drift ends, so this is the settle point.
      if isUserGestureActive, !isScrollInputActive {
        setUserGestureActive(false)
      }
      guard !isUpdatingFromSwiftUI else { return }

      let isUserGesture = !reason.isDisjoint(with: Self.userGestureReasons)
      if isUserGesture {
        scheduleCameraWriteBack()
      } else if mapView.userTrackingMode != .none {
        // Following moves the camera on its own; keep the caller's region in step with it.
        scheduleCameraWriteBack(isFollowing: true)
      }
    }

    /// Records a user gesture starting or the camera settling after one, reports it to the
    /// caller, and shows or hides the scale bar with it.
    func setUserGestureActive(_ isActive: Bool) {
      isUserGestureActive = isActive
      setScaleBarVisible(isActive)
      let reportGesture = onUserGestureChange
      DispatchQueue.main.async { reportGesture?(isActive) }
    }

    // MARK: - Scale bar

    /// How long the scale bar lingers after the camera settles, long enough to read it.
    private static let scaleBarLinger: Duration = .milliseconds(1500)
    private static let scaleBarFadeDuration: TimeInterval = 0.25

    /// Fades the scale bar in as a gesture starts and out a moment after the camera settles,
    /// as Apple Maps does, so the map stays clean at rest. Toggles `showsScale` inside a
    /// cross-dissolve rather than animating `alpha`, which MapLibre drives itself (it hides
    /// the bar when zoomed too far out to measure).
    func setScaleBarVisible(_ isVisible: Bool) {
      guard fadesScaleBar else { return }
      scaleBarFadeTask?.cancel()
      scaleBarFadeTask = nil
      if isVisible {
        fadeScaleBar(toVisible: true)
      } else {
        scaleBarFadeTask = Task { [weak self] in
          try? await Task.sleep(for: Self.scaleBarLinger)
          guard !Task.isCancelled else { return }
          self?.fadeScaleBar(toVisible: false)
        }
      }
    }

    private func fadeScaleBar(toVisible isVisible: Bool) {
      guard mapView.showsScale != isVisible else { return }
      let duration = UIAccessibility.isReduceMotionEnabled ? 0 : Self.scaleBarFadeDuration
      UIView.transition(
        with: mapView.scaleBar,
        duration: duration,
        options: [.transitionCrossDissolve, .allowUserInteraction]
      ) { [mapView] in
        mapView.showsScale = isVisible
      }
    }

    // MARK: - Muted basemap

    /// Lays a translucent wash of the canvas colour over the whole basemap, rasters included,
    /// with Cairn's lines and pins drawn above it at full colour. One background layer works the
    /// same for the vector style and the satellite and topo overlays, where restyling each
    /// basemap layer's paint would have to know every layer type the style ships.
    func applyMutedBasemap(style: MLNStyle?) {
      guard let style else { return }
      lastAppliedIsMuted = currentIsMuted
      lastAppliedMutedIsDark = currentIsDarkMode
      let existing = style.layer(withIdentifier: MapLayerID.mutedWash) as? MLNBackgroundStyleLayer
      guard currentIsMuted else {
        existing?.isVisible = false
        return
      }
      let wash = existing ?? MLNBackgroundStyleLayer(identifier: MapLayerID.mutedWash)
      wash.isVisible = true
      wash.backgroundColor = NSExpression(
        forConstantValue: currentIsDarkMode ? UIColor.black : UIColor.white
      )
      wash.backgroundOpacity = NSExpression(
        forConstantValue: currentIsDarkMode ? Self.mutedWashDarkOpacity : Self.mutedWashLightOpacity
      )
      guard existing == nil else { return }
      // Below our first line layer when they exist (a toggle after load), else on top for now
      // and the lines and pins added after it land above.
      if let firstOwn = style.layers.first(where: { $0.identifier == MapLayerID.lineLOSCasing }) {
        style.insertLayer(wash, below: firstOwn)
      } else {
        style.addLayer(wash)
      }
    }

    /// Strong enough to push roads and labels back without losing the place, measured by eye. The
    /// dark map is already low in contrast, so a light touch: more, and on a black page the
    /// preview reads as an empty black box.
    private static let mutedWashLightOpacity = 0.45
    private static let mutedWashDarkOpacity = 0.15

    // MARK: - Following and orientation

    /// A region flight ended: start the following that was waiting for it.
    func settleRegionAnimation() {
      guard isRegionAnimating else { return }
      isRegionAnimating = false
      if let pending = pendingTrackingMode {
        pendingTrackingMode = nil
        applyTrackingMode(pending)
      }
    }

    /// The caller's accuracy while the camera follows the phone, where the dot leads the map;
    /// otherwise at most ten metres, enough to place the dot without holding the GPS at its best.
    func syncUserLocationAccuracy() {
      let following = mapView.userTrackingMode != .none
      let accuracy = following ? requestedUserLocationAccuracy : max(requestedUserLocationAccuracy, kCLLocationAccuracyNearestTenMeters)
      if mapView.locationManager.desiredAccuracy?() != accuracy {
        mapView.locationManager.setDesiredAccuracy?(accuracy)
      }
    }

    func applyTrackingMode(_ mode: MapTrackingMode) {
      guard mapView.userTrackingMode != mode.mlnMode else { return }
      mapView.setUserTrackingMode(
        mode.mlnMode,
        animated: !UIAccessibility.isReduceMotionEnabled,
        completionHandler: nil
      )
    }

    func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
      syncUserLocationAccuracy()
      // The dot stopped or restarted with the map leaving or rejoining the window: following
      // isn't the user's to lose, and comes back with the dot.
      if self.mapView.isSuspendingUserLocation { return }
      // MapLibre drops following on a pan and steps heading down to follow on a rotate;
      // mirror it so the location button shows the mode actually in force.
      // A recenter's own clearing of following is not the user's; its follow starts on settle.
      guard pendingTrackingMode == nil else { return }
      // Following ended: record where it left the camera (a pan's own write-back supersedes this).
      if mode == .none, onFollowingCameraChange != nil {
        scheduleCameraWriteBack(isFollowing: true)
      }
      let reported = MapTrackingMode(mode)
      let report = setUserTrackingMode
      DispatchQueue.main.async { report?(reported) }
    }

    /// Animates back to north-up and flat, keeping the center and zoom. Heading mode steps down
    /// to plain following, as Apple Maps' compass does.
    func resetOrientation() {
      if mapView.userTrackingMode == .followWithHeading {
        mapView.setUserTrackingMode(.follow, animated: false, completionHandler: nil)
      }
      let camera = mapView.camera
      let duration: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0 : 0.35
      if camera.pitch > 0 {
        // A flat camera at the tilted camera's viewing distance keeps the zoom level.
        let flat = MLNMapCamera(
          lookingAtCenter: camera.centerCoordinate,
          altitude: camera.viewingDistance,
          pitch: 0,
          heading: 0
        )
        mapView.setCamera(
          flat,
          withDuration: duration,
          animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut)
        )
      } else {
        mapView.setDirection(0, animated: duration > 0)
      }
    }

    /// Reports the camera's rotation and tilt when either moved by a noticeable amount, or
    /// crossed back to north-up and flat, so the compass appears and hides on time.
    func reportOrientation() {
      guard let onCameraOrientationChange else { return }
      let current = MapCameraOrientation(direction: mapView.direction, pitch: mapView.camera.pitch)
      let last = lastReportedOrientation
      let moved = abs(MapNavigationMath.shortestTurn(from: last.direction, to: current.direction)) >= 0.5
        || abs(current.pitch - last.pitch) >= 0.5
      guard moved || current.isRotatedOrTilted != last.isRotatedOrTilted else { return }
      lastReportedOrientation = current
      DispatchQueue.main.async { onCameraOrientationChange(current) }
    }

    /// Debounced write-back of the camera region after a user-driven move, or (less eagerly, as
    /// it moves with every fix and heading change) after following moved it.
    func scheduleCameraWriteBack(isFollowing: Bool = false) {
      if isFollowing, onFollowingCameraChange == nil { return }
      pendingRegionTask?.cancel()
      pendingRegionTask = Task {
        try? await Task.sleep(for: .milliseconds(isFollowing ? 300 : 50))
        guard !Task.isCancelled else { return }
        let region = self.mapView.mlnRegion
        if isFollowing {
          self.onFollowingCameraChange?(region)
        } else {
          self.onCameraRegionChange?(region)
        }
      }
    }

    // MARK: - Gesture recognizer delegate

    nonisolated func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      true
    }

    // MARK: - Tap handling

    /// Projects a point to its on-screen anchor (lifted above the pin by its style's
    /// callout clearance) and routes it through `onPointTap`, so a programmatic
    /// selection presents the callout exactly like a user tap.
    func selectPoint(_ mapPoint: MapPoint) {
      onPointTap?(mapPoint, calloutAnchor(for: mapPoint))
    }

    /// The point a callout hangs from: the top of the pin's sprite.
    func calloutAnchor(for mapPoint: MapPoint) -> CGPoint {
      let pinScreenPos = mapView.convert(mapPoint.coordinate, toPointTo: mapView)
      return CGPoint(
        x: pinScreenPos.x,
        y: pinScreenPos.y - PinSpriteRenderer.calloutLift(for: mapPoint.pinStyle)
      )
    }

    @objc func handleTap(_ sender: UITapGestureRecognizer) {
      guard sender.state == .ended else { return }
      let point = sender.location(in: mapView)
      let clusterRect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
      logger.debug("handleTap at \(point.x, privacy: .public), \(point.y, privacy: .public)")

      // 1. Check cluster layers
      let clusterFeatures = mapView.visibleFeatures(
        in: clusterRect,
        styleLayerIdentifiers: [MapLayerID.clusterCircles]
      )
      if let cluster = clusterFeatures.first(where: { $0 is MLNPointFeatureCluster }) as? MLNPointFeatureCluster,
         let source = mapView.style?.source(withIdentifier: MapSourceID.points) as? MLNShapeSource {
        let zoom = source.zoomLevel(forExpanding: cluster)
        guard zoom >= 0 else { return }
        mapView.setCenter(cluster.coordinate, zoomLevel: zoom + 2.0, animated: true)
        return
      }

      // 2. Check point and name label layers (both clustered and fixed)
      let pointFeatures = mapView.visibleFeatures(
        at: point,
        styleLayerIdentifiers: [
          MapLayerID.unclusteredIcons, MapLayerID.fixedIcons,
          MapLayerID.nameLabels, MapLayerID.fixedNameLabels
        ]
      )
      logger.debug("pointFeatures: \(pointFeatures.count, privacy: .public), clusterFeatures: \(clusterFeatures.count, privacy: .public)")
      if let feature = pointFeatures.first,
         let idString = feature.attribute(forKey: "pointId") as? String,
         let id = UUID(uuidString: idString),
         let mapPoint = currentPoints.first(where: { $0.id == id }) {
        logger.debug("Matched pin: \(mapPoint.label ?? "unnamed", privacy: .public)")
        selectPoint(mapPoint)
        return
      }

      // 3. Check tappable lines (the Traffic map's links), within a finger's width; a link's count
      // chip sits on its line, so a tap on the chip opens the link too.
      if let onLineTap {
        let lineFeatures = mapView.visibleFeatures(
          in: clusterRect,
          styleLayerIdentifiers: [MapLayerID.lineTrafficLink, MapLayerID.lineTrafficLinkGlow]
        )
        if let id = lineFeatures.lazy.compactMap({ $0.attribute(forKey: "lineId") as? String }).first {
          onLineTap(id)
          return
        }
      }

      // 4. Check badge text layers — dismiss any open callout but don't select
      let badgeFeatures = mapView.visibleFeatures(
        at: point,
        styleLayerIdentifiers: [MapLayerID.badgeText, MapLayerID.fixedBadgeText]
      )
      if badgeFeatures.first != nil {
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        onMapTap?(coordinate)
        return
      }

      // 5. Map background tap
      let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
      onMapTap?(coordinate)
    }

    @objc func handleLongPress(_ sender: UILongPressGestureRecognizer) {
      guard sender.state == .began else { return }
      let point = sender.location(in: mapView)
      let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
      onMapLongPress?(coordinate)
    }
  }
}

// MARK: - MLNMapView region helper

extension MLNMapView {
  var mlnRegion: MKCoordinateRegion {
    let bounds = visibleCoordinateBounds
    let center = CLLocationCoordinate2D(
      latitude: (bounds.sw.latitude + bounds.ne.latitude) / 2,
      longitude: (bounds.sw.longitude + bounds.ne.longitude) / 2
    )
    let span = MKCoordinateSpan(
      latitudeDelta: bounds.ne.latitude - bounds.sw.latitude,
      longitudeDelta: bounds.ne.longitude - bounds.sw.longitude
    )
    return MKCoordinateRegion(center: center, span: span)
  }
}

/// MapLibre's map, with the user's dot (and the location updates behind it) running only while
/// the map is in a window. MapLibre stops them in the background but not when its map is off
/// screen in a running app: a tab not shown, a page pushed over it. Following in force when the
/// map left comes back with it.
final class WindowAwareMapView: MLNMapView {
  /// Whether the caller shows the user's dot; it draws while the map is in a window.
  var wantsUserLocation = false {
    didSet { syncUserLocation() }
  }

  /// The dot is being stopped or restarted for the window, not by the user or the caller.
  private(set) var isSuspendingUserLocation = false
  /// The following in force when the map left its window, restored when it returns.
  private var suspendedTrackingMode: MLNUserTrackingMode?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    syncUserLocation()
  }

  private func syncUserLocation() {
    let shows = wantsUserLocation && window != nil
    if !wantsUserLocation { suspendedTrackingMode = nil }
    guard showsUserLocation != shows else { return }
    isSuspendingUserLocation = true
    defer { isSuspendingUserLocation = false }
    if shows {
      showsUserLocation = true
      if let mode = suspendedTrackingMode, mode != .none {
        setUserTrackingMode(mode, animated: false, completionHandler: nil)
      }
      suspendedTrackingMode = nil
    } else {
      if wantsUserLocation { suspendedTrackingMode = userTrackingMode }
      showsUserLocation = false
    }
  }
}
