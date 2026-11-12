import CoreLocation
import OSLog

enum LocationServiceError: Error, LocalizedError {
  case notAuthorized(CLAuthorizationStatus)
  case requestInProgress
  case permissionTimeout
  case locationTimeout
  case requestFailed(String)

  var errorDescription: String? {
    switch self {
    case let .notAuthorized(status):
      switch status {
      case .notDetermined:
        "Location permission is required to update your node's location."
      case .denied, .restricted:
        "Location permission is denied. Enable it in Settings to update your node's location."
      default:
        "Location permission is not available."
      }
    case .requestInProgress:
      "A location request is already in progress."
    case .permissionTimeout:
      "Timed out while waiting for location permission."
    case .locationTimeout:
      "Timed out while requesting location."
    case let .requestFailed(message):
      "Location request failed: \(message)"
    }
  }
}

/// App-wide location service for managing location permissions and access.
/// Used by MapView, LineOfSightView, ContactsListView, and other location-dependent features.
@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
  // MARK: - Properties

  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "LocationService")
  private let locationManager: CLLocationManager

  private var requestContinuation: CheckedContinuation<CLLocation, Error>?
  private var locationTimeoutTask: Task<Void, Never>?

  private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Error>?
  private var permissionTimeoutTask: Task<Void, Never>?

  /// Current authorization status
  private(set) var authorizationStatus: CLAuthorizationStatus

  /// Current device location (nil if unavailable or not yet determined). While following, it
  /// moves only once the phone has moved `FollowSettings.publishDistance` (or the fix sharpened),
  /// so views reading it don't redraw on every update.
  private(set) var currentLocation: CLLocation?

  /// The newest fix, every update while following, without waking views. Node Discovery stamps
  /// replies with it, and a parked phone's fix has to stay fresh as well as a moving one's.
  @ObservationIgnored private(set) var latestFix: CLLocation?

  /// Whether a location request is in progress
  private(set) var isRequestingLocation = false

  /// Screens that keep the fix following the phone (Node Discovery's scans and Wardrive, which
  /// stamp each reply with where it arrived), each with whether it needs updates in the
  /// background. Updates run while any claim one and are allowed.
  private var followClaims = FollowClaims()
  private var isFollowing = false

  /// Whether updates keep running with the screen locked or another app in front: only while a
  /// client asked for that (Wardrive), and off again once none does.
  var isFollowingInBackground: Bool {
    locationManager.allowsBackgroundLocationUpdates
  }

  /// The screens following the phone, each with whether it needs background updates. Each claim
  /// is its own (a window, CarPlay), so one ending leaves the others' in place. Pure, so the tests
  /// can play out overlapping claims such as the phone's Wardrive alongside a CarPlay scan.
  struct FollowClaims: Equatable {
    private(set) var clients: [String: Bool] = [:]

    /// Adds `client`'s claim, or updates it.
    mutating func claim(_ client: String, inBackground: Bool) {
      clients[client] = inBackground
    }

    /// Drops `client`'s claim; false when it had none.
    @discardableResult
    mutating func release(_ client: String) -> Bool {
      clients.removeValue(forKey: client) != nil
    }

    /// The location manager's settings for these claims; nil when nothing follows.
    var settings: FollowSettings? {
      FollowSettings.following(clients: clients)
    }
  }

  /// The location manager's settings for a set of follow claims, kept pure for the tests.
  struct FollowSettings: Equatable {
    var desiredAccuracy: CLLocationAccuracy
    var distanceFilter: CLLocationDistance
    var activityType: CLActivityType
    var pausesAutomatically: Bool
    var allowsBackground: Bool

    /// One-shot requests outside following: a hundred metres is plenty for distance sorting.
    static let idle = FollowSettings(
      desiredAccuracy: kCLLocationAccuracyHundredMeters,
      distanceFilter: kCLDistanceFilterNone,
      activityType: .other,
      pausesAutomatically: true,
      allowsBackground: false
    )

    /// How far the phone moves before `currentLocation` follows.
    static let publishDistance: CLLocationDistance = 10

    /// Oldest following fix a location request is answered with at once.
    static let currentFixAge: TimeInterval = 10

    /// `fix` when it is recent enough to answer a request without waiting: following may have
    /// just started (its newest fix is then an old one-shot) or lost the signal, and the callers
    /// (adverts, the radio's position, region lookup) want where the phone is, not where it was.
    static func currentFix(_ fix: CLLocation?, now: Date) -> CLLocation? {
      guard let fix, fix.horizontalAccuracy >= 0, now.timeIntervalSince(fix.timestamp) <= currentFixAge else { return nil }
      return fix
    }

    /// The settings for `clients` (client → wants background updates); nil when nothing follows.
    /// Every update is delivered (no distance filter), so a parked phone's fix stays fresh too.
    /// GPS accuracy and navigation activity, without road snapping, so a fix is where the phone was
    /// rather than the nearest road; and never paused, since Wardrive stops at lights and parks.
    /// Background updates only while a client asks, which When-In-Use allows for updates started
    /// in the foreground (iOS shows the location indicator meanwhile).
    static func following(clients: [String: Bool]) -> FollowSettings? {
      guard !clients.isEmpty else { return nil }
      let inBackground = clients.values.contains(true)
      return FollowSettings(
        // GPS precision for Wardrive's map of where each node was heard; navigation accuracy's
        // extra sensor fusion is meant for a phone on power, and Wardrive often runs on battery.
        desiredAccuracy: inBackground ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters,
        distanceFilter: kCLDistanceFilterNone,
        activityType: .otherNavigation,
        pausesAutomatically: false,
        allowsBackground: inBackground
      )
    }

    /// Whether a following update moves `currentLocation`: the first fix, a move of
    /// `publishDistance`, or a fix at least `publishDistance` sharper than the shown one.
    static func publishes(_ location: CLLocation, over current: CLLocation?) -> Bool {
      guard let current else { return true }
      if location.distance(from: current) >= publishDistance { return true }
      guard location.horizontalAccuracy >= 0 else { return false }
      return current.horizontalAccuracy < 0
        || location.horizontalAccuracy <= current.horizontalAccuracy - publishDistance
    }
  }

  /// Whether location services are authorized for use
  var isAuthorized: Bool {
    authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
  }

  /// Whether permission has been determined (not .notDetermined)
  var hasRequestedPermission: Bool {
    authorizationStatus != .notDetermined
  }

  /// Whether location is denied or restricted
  var isLocationDenied: Bool {
    authorizationStatus == .denied || authorizationStatus == .restricted
  }

  // MARK: - Initialization

  override init() {
    locationManager = CLLocationManager()
    authorizationStatus = locationManager.authorizationStatus
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  // MARK: - Public Methods

  /// Request location permission if not already determined.
  /// Call this when a location-dependent feature is accessed.
  func requestPermissionIfNeeded() {
    guard authorizationStatus == .notDetermined else {
      let raw = authorizationStatus.rawValue
      logger.debug("Location permission already determined: \(String(describing: raw))")
      return
    }

    logger.info("Requesting location permission")
    locationManager.requestWhenInUseAuthorization()
  }

  /// Request a one-shot location update.
  /// Call this when you need the current location (e.g., for distance sorting).
  func requestLocation() {
    guard isAuthorized else {
      logger.debug("Cannot request location: not authorized")
      requestPermissionIfNeeded()
      return
    }

    guard !isRequestingLocation else {
      logger.debug("Location request already in progress")
      return
    }

    // While following, `currentLocation` is already within the distance filter of the phone.
    guard !isFollowing || currentLocation == nil else { return }

    logger.info("Requesting one-shot location update")
    isRequestingLocation = true
    locationManager.requestLocation()
  }

  /// Request current location asynchronously with timeout.
  /// Handles permission prompting if needed.
  func requestCurrentLocation(timeout: Duration = .seconds(10)) async throws -> CLLocation {
    guard requestContinuation == nil, authorizationContinuation == nil else {
      throw LocationServiceError.requestInProgress
    }

    if !isAuthorized {
      if authorizationStatus == .notDetermined {
        requestPermissionIfNeeded()
        _ = try await waitForAuthorizationDecision(timeout: .seconds(30))
      }

      guard isAuthorized else {
        throw LocationServiceError.notAuthorized(authorizationStatus)
      }
    }

    // An older following fix waits for the next update, which resumes the request below.
    if isFollowing, let location = FollowSettings.currentFix(latestFix, now: Date()) { return location }

    isRequestingLocation = true

    return try await withCheckedThrowingContinuation { continuation in
      requestContinuation = continuation
      // Following already delivers the first fix; a one-shot on top of it isn't needed.
      if !isFollowing { locationManager.requestLocation() }

      locationTimeoutTask?.cancel()
      locationTimeoutTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        guard let self, let continuation = requestContinuation else { return }

        requestContinuation = nil
        isRequestingLocation = false
        continuation.resume(throwing: LocationServiceError.locationTimeout)
      }
    }
  }

  /// Keeps the fix following the phone for `client` (see `FollowSettings.following`) until
  /// `stopFollowing(for:)`. `inBackground` keeps it running with the screen locked or another app
  /// in front, for as long as this claim says so. Repeating a claim updates it; updates start
  /// with the first client, or once location is allowed.
  func startFollowing(for client: String, inBackground: Bool = false) {
    followClaims.claim(client, inBackground: inBackground)
    if isAuthorized {
      applyFollowSettings()
    } else {
      requestPermissionIfNeeded()
    }
  }

  /// Drops `client`'s claim. Repeating it is harmless; background updates end with the last
  /// claim that wanted them, updates stop with the last client, and one-shot requests go back to
  /// hundred-metre accuracy.
  func stopFollowing(for client: String) {
    guard followClaims.release(client) else { return }
    applyFollowSettings()
  }

  // MARK: - Private Methods

  /// Brings the location manager in line with the claims: started, retuned, or stopped.
  private func applyFollowSettings() {
    guard let settings = followClaims.settings, isAuthorized else {
      guard isFollowing else { return }
      isFollowing = false
      locationManager.stopUpdatingLocation()
      apply(.idle)
      logger.info("Stopped following location updates")
      // A request left waiting on the updates asks for its own fix.
      if isRequestingLocation { locationManager.requestLocation() }
      return
    }
    apply(settings)
    guard !isFollowing else { return }
    isFollowing = true
    logger.info("Following location updates")
    locationManager.startUpdatingLocation()
  }

  private func apply(_ settings: FollowSettings) {
    locationManager.desiredAccuracy = settings.desiredAccuracy
    locationManager.distanceFilter = settings.distanceFilter
    locationManager.activityType = settings.activityType
    locationManager.pausesLocationUpdatesAutomatically = settings.pausesAutomatically
    guard locationManager.allowsBackgroundLocationUpdates != settings.allowsBackground else { return }
    // Needs the `location` background mode in Info.plist, which only Wardrive's claim uses.
    locationManager.allowsBackgroundLocationUpdates = settings.allowsBackground
    #if os(iOS)
      locationManager.showsBackgroundLocationIndicator = settings.allowsBackground
    #endif
    logger.info("Background location updates \(settings.allowsBackground ? "on" : "off")")
  }

  private func waitForAuthorizationDecision(timeout: Duration) async throws -> CLAuthorizationStatus {
    guard authorizationStatus == .notDetermined else { return authorizationStatus }
    guard authorizationContinuation == nil else {
      throw LocationServiceError.requestInProgress
    }

    return try await withCheckedThrowingContinuation { continuation in
      authorizationContinuation = continuation

      permissionTimeoutTask?.cancel()
      permissionTimeoutTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        guard let self, let continuation = authorizationContinuation else { return }

        authorizationContinuation = nil
        continuation.resume(throwing: LocationServiceError.permissionTimeout)
      }
    }
  }

  // MARK: - CLLocationManagerDelegate

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      self.authorizationStatus = status
      self.logger.info("Location authorization changed: \(String(describing: status.rawValue))")
      self.applyFollowSettings()

      if status != .notDetermined, let authorizationContinuation = self.authorizationContinuation {
        self.authorizationContinuation = nil
        self.permissionTimeoutTask?.cancel()
        self.permissionTimeoutTask = nil
        authorizationContinuation.resume(returning: status)
      }

      if status == .denied || status == .restricted {
        if let continuation = self.requestContinuation {
          self.requestContinuation = nil
          self.locationTimeoutTask?.cancel()
          self.locationTimeoutTask = nil
          self.isRequestingLocation = false
          continuation.resume(throwing: LocationServiceError.notAuthorized(status))
        }
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    Task { @MainActor in
      self.latestFix = location
      if !self.isFollowing || FollowSettings.publishes(location, over: self.currentLocation) {
        self.currentLocation = location
      }
      self.isRequestingLocation = false
      if !self.isFollowing {
        self.logger.info("Location updated: \(location.coordinate.latitude, privacy: .private), \(location.coordinate.longitude, privacy: .private)")
      }

      self.locationTimeoutTask?.cancel()
      self.locationTimeoutTask = nil

      if let continuation = self.requestContinuation {
        self.requestContinuation = nil
        continuation.resume(returning: location)
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in
      self.isRequestingLocation = false
      self.logger.error("Location request failed: \(error.localizedDescription)")

      self.locationTimeoutTask?.cancel()
      self.locationTimeoutTask = nil

      if let continuation = self.requestContinuation {
        self.requestContinuation = nil
        continuation.resume(throwing: LocationServiceError.requestFailed(error.localizedDescription))
      }
    }
  }
}
