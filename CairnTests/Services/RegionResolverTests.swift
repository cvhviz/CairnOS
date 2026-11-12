import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("RegionResolver")
@MainActor
struct RegionResolverTests {
  // MARK: - Test doubles

  private final class StubGeocoder: Geocoder, @unchecked Sendable {
    var stub: GeocodeResult?
    private(set) var cancelGeocodeCallCount = 0

    func reverseGeocode(_ location: CLLocation, preferredLocale: Locale?) async throws -> GeocodeResult? {
      stub
    }

    func cancelGeocode() {
      cancelGeocodeCallCount += 1
    }
  }

  // MARK: - Failure paths

  //
  // These tests exercise the `location.isAuthorized` guard — the resolver
  // returns nil before the geocoder runs when authorization is undetermined.
  // Success-path coverage requires injecting a stubbed `LocationService`, which
  // is a follow-up (LocationService is not currently abstracted behind a
  // protocol).

  @Test
  func `nil isoCountryCode → nil`() async {
    let location = LocationService()
    let geocoder = StubGeocoder()
    geocoder.stub = nil
    let resolver = RegionResolver(location: location, geocoder: geocoder)
    let result = await resolver.resolve()
    #expect(result == nil)
  }

  @Test
  func `Unauthorized location → nil`() async {
    let location = LocationService() // .notDetermined by default
    let geocoder = StubGeocoder()
    let resolver = RegionResolver(location: location, geocoder: geocoder)
    let result = await resolver.resolve()
    #expect(result == nil)
  }

  // MARK: - Placemark mapping

  private func resolution(
    country: String? = "US",
    area: String? = "California",
    subarea: String?
  ) -> RegionResolution? {
    RegionResolver.resolution(from: GeocodeResult(
      countryCode: country,
      administrativeArea: area,
      subAdministrativeArea: subarea
    ))
  }

  @Test
  func `Los Angeles County resolves to the los angeles key`() {
    let result = resolution(subarea: "Los Angeles County")
    #expect(result?.selection == RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: "los angeles",
      source: .location
    ))
    #expect(result?.countyFieldMissing == false)
  }

  @Test
  func `postal state code and bare county name resolve too`() {
    let result = resolution(area: "CA", subarea: "Orange")
    #expect(result?.selection.administrativeAreaCode == "US-CA")
    #expect(result?.selection.countyKey == "orange")
  }

  @Test
  func `a missing county field is reported as missing`() {
    for subarea in [nil, "", "  "] as [String?] {
      let result = resolution(subarea: subarea)
      #expect(result?.selection.administrativeAreaCode == "US-CA")
      #expect(result?.selection.countyKey == nil)
      #expect(result?.countyFieldMissing == true)
    }
  }

  @Test
  func `an unlisted county is present, not missing, and marked as other`() {
    let result = resolution(subarea: "Sacramento County")
    #expect(result?.selection.countyKey == RegionalAreas.otherCountyKey)
    #expect(result?.countyFieldMissing == false)
  }

  @Test
  func `a county in a state without county presets is not recorded`() {
    let result = resolution(area: "Texas", subarea: "Travis County")
    #expect(result?.selection.administrativeAreaCode == "US-TX")
    #expect(result?.selection.countyKey == nil)
  }

  // MARK: - Cache cells

  @Test
  func `neighbouring counties in one whole-degree cell get different cache keys`() {
    // Porterville (Tulare County) and Delano (Kern County) both round to (36, -119).
    let porterville = RegionResolver.CacheKey(latitude: 36.07, longitude: -119.02)
    let delano = RegionResolver.CacheKey(latitude: 35.77, longitude: -119.25)
    #expect(porterville != delano)
  }

  @Test
  func `nearby fixes share a cache key`() {
    let first = RegionResolver.CacheKey(latitude: 34.0522, longitude: -118.2437)
    let second = RegionResolver.CacheKey(latitude: 34.0530, longitude: -118.2445)
    #expect(first == second)
  }

  @Test
  func `no country code maps to nil`() {
    #expect(resolution(country: nil, subarea: "Los Angeles County") == nil)
  }
}

