import CoreLocation
@testable import Cairn
import Testing

@Suite("LocationPickerConfirmation")
struct LocationPickerConfirmationTests {
  private static let pin = CLLocationCoordinate2D(latitude: 52.370216, longitude: 4.895168)
  private static let stored = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
  private static let nullIsland = CLLocationCoordinate2D(latitude: 0, longitude: 0)

  // MARK: - Pin

  @Test(arguments: [LocationPickerView.Purpose.nodePosition, LocationPickerView.Purpose.share])
  func `A pin confirms exactly the pinned coordinate`(purpose: LocationPickerView.Purpose) throws {
    let result = LocationPickerConfirmation.resolve(
      pin: Self.pin,
      storedCoordinate: Self.stored,
      purpose: purpose
    )
    let confirmed = try #require(Self.coordinate(of: result))
    #expect(confirmed.latitude == Self.pin.latitude)
    #expect(confirmed.longitude == Self.pin.longitude)
  }

  @Test
  func `A pin on the equator or the prime meridian is a real selection`() throws {
    let equator = CLLocationCoordinate2D(latitude: 0, longitude: 12.5)
    let meridian = CLLocationCoordinate2D(latitude: 51.4779, longitude: 0)
    for pin in [equator, meridian] {
      let result = LocationPickerConfirmation.resolve(pin: pin, storedCoordinate: nil, purpose: .share)
      let confirmed = try #require(Self.coordinate(of: result))
      #expect(confirmed.latitude == pin.latitude)
      #expect(confirmed.longitude == pin.longitude)
    }
  }

  // MARK: - No pin

  @Test
  func `Sharing without a pin has nothing to confirm`() {
    let result = LocationPickerConfirmation.resolve(pin: nil, storedCoordinate: nil, purpose: .share)
    #expect(Self.isUnavailable(result))
  }

  @Test
  func `Sharing never clears, even when a coordinate was passed in`() {
    let result = LocationPickerConfirmation.resolve(
      pin: nil,
      storedCoordinate: Self.stored,
      purpose: .share
    )
    #expect(Self.isUnavailable(result))
  }

  @Test(arguments: [nil, CLLocationCoordinate2D(latitude: 0, longitude: 0)])
  func `Node without a stored position and without a pin has nothing to confirm`(
    stored: CLLocationCoordinate2D?
  ) {
    let result = LocationPickerConfirmation.resolve(
      pin: nil,
      storedCoordinate: stored,
      purpose: .nodePosition
    )
    #expect(Self.isUnavailable(result))
  }

  @Test
  func `Removing the pin of a stored node position clears it`() {
    let result = LocationPickerConfirmation.resolve(
      pin: nil,
      storedCoordinate: Self.stored,
      purpose: .nodePosition
    )
    #expect(Self.isClear(result))
  }

  // MARK: - Unusable pin

  @Test(arguments: [LocationPickerView.Purpose.nodePosition, LocationPickerView.Purpose.share])
  func `A pin at 0,0 is never confirmed as a coordinate`(purpose: LocationPickerView.Purpose) {
    let result = LocationPickerConfirmation.resolve(
      pin: Self.nullIsland,
      storedCoordinate: nil,
      purpose: purpose
    )
    #expect(Self.isUnavailable(result))
  }

  @Test(arguments: [
    CLLocationCoordinate2D(latitude: 91, longitude: 10),
    CLLocationCoordinate2D(latitude: 10, longitude: 181),
    CLLocationCoordinate2D(latitude: .nan, longitude: 10)
  ])
  func `An out-of-range pin is never confirmed as a coordinate`(pin: CLLocationCoordinate2D) {
    let result = LocationPickerConfirmation.resolve(pin: pin, storedCoordinate: nil, purpose: .share)
    #expect(Self.isUnavailable(result))
  }

  // MARK: - Helpers

  private static func coordinate(of result: LocationPickerConfirmation) -> CLLocationCoordinate2D? {
    if case let .coordinate(coordinate) = result { coordinate } else { nil }
  }

  private static func isUnavailable(_ result: LocationPickerConfirmation) -> Bool {
    if case .unavailable = result { true } else { false }
  }

  private static func isClear(_ result: LocationPickerConfirmation) -> Bool {
    if case .clearStoredPosition = result { true } else { false }
  }
}
