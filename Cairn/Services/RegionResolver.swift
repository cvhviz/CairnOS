import CoreLocation
import Foundation
import CairnServices
import OSLog

/// A location lookup's place, plus whether the geocoder named a county at all.
struct RegionResolution: Equatable {
  let selection: RegionSelection
  /// True when the placemark had no county. `selection.countyKey` is then nil, where a county the
  /// catalog doesn't list is `RegionalAreas.otherCountyKey`.
  let countyFieldMissing: Bool
}

/// Resolves a `RegionSelection` from the device's current location.
///
/// Lives in Cairn (next to `LocationService`) because CairnServices is intentionally
/// CoreLocation-free. The resolver is a one-shot orchestrator — views observe
/// `AppState.regionSelection`, not this object — so it is not `@Observable`.
@MainActor
final class RegionResolver {
  static let locationTimeout: Duration = .seconds(5)
  static let geocodeTimeout: Duration = .seconds(5)
  static let cacheTTL: TimeInterval = 24 * 60 * 60

  private static let geocodingLocale = Locale(identifier: "en_US")
  private static let countySuffix = " county"

  private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "RegionResolver")
  private let location: LocationService
  private let geocoder: any Geocoder
  private var cache: [CacheKey: CachedResolution] = [:]

  init(location: LocationService, geocoder: any Geocoder = AppleGeocoder()) {
    self.location = location
    self.geocoder = geocoder
  }

  /// Returns a `RegionSelection` derived from the device's current location, or
  /// nil for any failure (denied, timeout, no network, nil isoCountryCode).
  /// Failure modes are silent — callers fall through to manual picker.
  func resolve() async -> RegionSelection? {
    await resolveDetailed()?.selection
  }

  /// `resolve()` plus whether the placemark carried a county, so a caller can keep a saved
  /// county when the geocoder simply left the field out. `bypassingCache` geocodes afresh, for a
  /// lookup the user asked for; its result still refreshes the cache.
  func resolveDetailed(bypassingCache: Bool = false) async -> RegionResolution? {
    guard location.isAuthorized else { return nil }
    do {
      let loc = try await location.requestCurrentLocation(timeout: Self.locationTimeout)
      let key = CacheKey(loc)
      if !bypassingCache, let cached = cache[key], cached.isFresh { return cached.value }

      let result = try await reverseGeocode(loc)
      // The raw fields, so a place that misses its state or county can be traced from the logs.
      // State and county only: coarse enough to log in the clear, unlike the coordinate.
      logger.info(
        """
        Reverse geocode: country \(result?.countryCode ?? "nil", privacy: .public), \
        area \(result?.administrativeArea ?? "nil", privacy: .public), \
        subarea \(result?.subAdministrativeArea ?? "nil", privacy: .public)
        """
      )

      guard let result, let resolution = Self.resolution(from: result) else { return nil }
      cache[key] = CachedResolution(value: resolution, expiresAt: Date().addingTimeInterval(Self.cacheTTL))
      return resolution
    } catch {
      logger.info("Region resolution failed: \(error)")
      return nil
    }
  }

  /// Maps a placemark onto the catalog's keys; nil without a country code.
  static func resolution(from result: GeocodeResult) -> RegionResolution? {
    guard let countryCode = result.countryCode else { return nil }

    let normalize: (String) -> String = {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .folding(options: .diacriticInsensitive, locale: Self.geocodingLocale)
    }
    let normalizedAdmin = result.administrativeArea.map(normalize)
    let normalizedCounty = result.subAdministrativeArea
      .map(normalize)
      .map { $0.replacingOccurrences(of: Self.countySuffix, with: "") }
      .flatMap { $0.isEmpty ? nil : $0 }

    let adminCode = RegionalAreas.matchSubdivision(
      country: countryCode, normalized: normalizedAdmin
    )
    let countyKey = RegionalAreas.countyKey(
      country: countryCode, state: adminCode, normalized: normalizedCounty
    )

    return RegionResolution(
      selection: RegionSelection(
        countryCode: countryCode,
        administrativeAreaCode: adminCode,
        countyKey: countyKey,
        source: .location
      ),
      countyFieldMissing: normalizedCounty == nil
    )
  }

  /// Bounds the geocoder call. The location request already has its own timeout via
  /// `LocationService`; without a separate bound here, a slow geocode (offline, throttled
  /// CLGeocoder) would leave the user staring at the resolving screen indefinitely. On
  /// timeout the geocoder is cancelled and `TimeoutError` surfaces to `resolve()`'s catch,
  /// which returns nil and falls through to the manual picker — matching every other
  /// failure mode in this resolver.
  private func reverseGeocode(_ loc: CLLocation) async throws -> GeocodeResult? {
    try await withTimeout(Self.geocodeTimeout, operationName: "reverseGeocode") { [geocoder] in
      try await withTaskCancellationHandler {
        try await geocoder.reverseGeocode(loc, preferredLocale: Self.geocodingLocale)
      } onCancel: {
        geocoder.cancelGeocode()
      }
    }
  }

  struct CacheKey: Hashable {
    /// Cells per degree: 0.05° (about 5 km), well under a county, so a cached place doesn't carry
    /// one county's lookup into the next.
    static let cellsPerDegree = 20.0

    let lat: Int
    let lng: Int
    init(latitude: CLLocationDegrees, longitude: CLLocationDegrees) {
      lat = Int((latitude * Self.cellsPerDegree).rounded())
      lng = Int((longitude * Self.cellsPerDegree).rounded())
    }

    init(_ location: CLLocation) {
      self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }
  }

  private struct CachedResolution {
    let value: RegionResolution
    let expiresAt: Date
    var isFresh: Bool {
      Date() < expiresAt
    }
  }
}
