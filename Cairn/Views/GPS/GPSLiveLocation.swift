import CoreLocation
import OSLog
import UIKit

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "GPSLiveLocation")

/// The phone's live fix and compass heading while the GPS tab's Position page (or a map's
/// navigation readout) is on screen.
///
/// The app-wide `LocationService` only takes one-shot, hundred-metre fixes (for distance sorting
/// and the map's centre), which is right for everything else and wrong for a GPS readout. This
/// owns its own best-accuracy manager instead, started on appear and stopped on disappear, so the
/// GPS radio and the magnetometer only run while someone is looking. Permission still goes through
/// `LocationService`; this manager only starts updates once it has been granted.
@Observable
@MainActor
final class GPSLiveLocation: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()

  /// Who has asked for live updates. Views that share one instance (the GPS page and the
  /// full-screen compass it presents) each hold their own claim, so one leaving can't stop the
  /// other however SwiftUI orders their appear and disappear calls.
  enum Client: Hashable {
    /// The view or controller that owns this instance.
    case owner
    /// The full-screen compass, presented over the page that owns the instance.
    case fullScreenCompass
  }

  private var clients: Set<Client> = []

  /// Whether any client has live updates running.
  var isActive: Bool { !clients.isEmpty }

  /// The latest live fix, nil until the first one arrives after `start()`.
  private(set) var location: CLLocation?
  /// The last fix that carried a speed, for `steadySpeed(now:)`.
  private var lastSpeedFix: CLLocation?
  /// Degrees from north the device faces (true north when known), nil without a compass reading.
  private(set) var heading: CLLocationDirection?
  /// The same reading against magnetic north, for the full compass's declination.
  private(set) var magneticHeading: CLLocationDirection?
  /// Whether `heading` is against true north (a fix has given the declination) or magnetic.
  private(set) var isTrueHeading = false
  /// The compass's own error bound in degrees; large while it needs calibrating.
  private(set) var headingAccuracy: CLLocationDirection?

  /// Whether the compass runs while active. A map that only needs the fix (following without
  /// heading) turns it off so the magnetometer can sleep; the last heading is dropped with it so
  /// a stale reading can't steer an arrow.
  var tracksHeading: Bool {
    didSet {
      guard tracksHeading != oldValue else { return }
      syncHeadingUpdates()
    }
  }

  /// The fix accuracy asked of Core Location. A map that already shows MapLibre's own
  /// best-accuracy dot asks for less here: the GPS is on for that manager anyway, and two
  /// best-accuracy managers only add work.
  var desiredAccuracy: CLLocationAccuracy {
    didSet {
      guard desiredAccuracy != oldValue else { return }
      manager.desiredAccuracy = desiredAccuracy
    }
  }

  /// False on devices without a magnetometer (the Mac, the simulator).
  let isHeadingAvailable = CLLocationManager.headingAvailable()

  /// The app's location permission and whether it is precise, kept current while the page is
  /// open so the phone card's controls change as soon as the user answers or comes back from
  /// Settings. `LocationService` doesn't publish the accuracy grant.
  private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
  private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy

  init(desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest, tracksHeading: Bool = true) {
    self.desiredAccuracy = desiredAccuracy
    self.tracksHeading = tracksHeading
    super.init()
    authorizationStatus = manager.authorizationStatus
    accuracyAuthorization = manager.accuracyAuthorization
    manager.delegate = self
    manager.desiredAccuracy = desiredAccuracy
    manager.distanceFilter = kCLDistanceFilterNone
    // One degree keeps the needle smooth without waking the view for magnetometer noise.
    manager.headingFilter = 1
  }

  /// Claims live updates for `client`. Repeating a claim is harmless; the manager starts with
  /// the first client.
  func start(for client: Client = .owner) {
    let wasActive = isActive
    clients.insert(client)
    guard !wasActive else { return }
    startUpdatesIfAuthorized()
    syncHeadingOrientation()
    syncHeadingUpdates()
  }

  /// Drops `client`'s claim. Repeating it is harmless; the manager stops with the last client.
  func stop(for client: Client = .owner) {
    guard clients.remove(client) != nil, clients.isEmpty else { return }
    manager.stopUpdatingLocation()
    manager.stopUpdatingHeading()
  }

  /// Runs the compass exactly while active and asked for.
  private func syncHeadingUpdates() {
    if isActive, tracksHeading, isHeadingAvailable {
      manager.startUpdatingHeading()
    } else {
      manager.stopUpdatingHeading()
      if !tracksHeading {
        heading = nil
        magneticHeading = nil
        headingAccuracy = nil
      }
    }
  }

  /// CLHeading is measured from the top of the device in portrait unless told otherwise, so in
  /// landscape every reading would be a quarter turn off from the screen (and from the map, which
  /// corrects for it). Call when the interface may have rotated; it reads the active scene.
  func syncHeadingOrientation() {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
    let orientation = Self.headingOrientation(for: scene.effectiveGeometry.interfaceOrientation)
    guard manager.headingOrientation != orientation else { return }
    manager.headingOrientation = orientation
  }

  /// The device orientation whose top edge matches the screen's top. The landscape cases swap:
  /// the interface turns the opposite way to the device.
  nonisolated static func headingOrientation(for interface: UIInterfaceOrientation) -> CLDeviceOrientation {
    switch interface {
    case .portraitUpsideDown: .portraitUpsideDown
    case .landscapeLeft: .landscapeRight
    case .landscapeRight: .landscapeLeft
    default: .portrait
    }
  }

  private func startUpdatesIfAuthorized() {
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      manager.startUpdatingLocation()
    default:
      break
    }
  }

  // MARK: - CLLocationManagerDelegate

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    let accuracy = manager.accuracyAuthorization
    Task { @MainActor in
      self.authorizationStatus = status
      self.accuracyAuthorization = accuracy
      // Granted while the page is open (the Allow button): start without waiting for a revisit.
      guard self.isActive else { return }
      self.startUpdatesIfAuthorized()
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let latest = locations.last else { return }
    Task { @MainActor in
      guard self.isActive else { return }
      self.location = latest
      if latest.speed >= 0 { self.lastSpeedFix = latest }
    }
  }

  /// The speed to show now: iOS mixes fixes with and without a speed while standing still or
  /// indoors, so the last one holds for a while rather than the reading flickering off and on.
  func steadySpeed(now: Date) -> CLLocationSpeed? {
    GNSSReadings.steadySpeed(current: location, lastWithSpeed: lastSpeedFix, now: now)
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
    // Negative accuracy means the reading is invalid; true heading is negative until a fix.
    guard newHeading.headingAccuracy >= 0 else { return }
    let isTrue = newHeading.trueHeading >= 0
    let degrees = isTrue ? newHeading.trueHeading : newHeading.magneticHeading
    let magnetic = newHeading.magneticHeading
    let accuracy = newHeading.headingAccuracy
    Task { @MainActor in
      guard self.isActive, self.tracksHeading else { return }
      self.heading = degrees
      self.magneticHeading = magnetic
      self.isTrueHeading = isTrue
      self.headingAccuracy = accuracy
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // kCLErrorLocationUnknown is transient (still searching); the page keeps showing "Searching…".
    logger.debug("Live location error: \(error.localizedDescription)")
  }
}
