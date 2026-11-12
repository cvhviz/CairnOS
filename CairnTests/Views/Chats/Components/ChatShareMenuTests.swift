import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

@Suite("ChatShareMenu predicate tests")
struct ChatShareMenuTests {
  private static let validKey = Data(repeating: 0xAB, count: ProtocolLimits.publicKeySize)
  private static let sampleCoordinate = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)

  // MARK: - canShareLocation

  @Test
  func `Location is shareable when authorized, even with no current fix or node coordinate`() {
    #expect(ChatShareMenu.canShareLocation(
      phoneCoordinate: nil,
      nodeCoordinate: nil,
      locationAuthorized: true
    ))
  }

  @Test
  func `Location is shareable from a node coordinate without authorization`() {
    #expect(ChatShareMenu.canShareLocation(
      phoneCoordinate: nil,
      nodeCoordinate: Self.sampleCoordinate,
      locationAuthorized: false
    ))
  }

  @Test
  func `Location is not shareable with no coordinate and no authorization`() {
    #expect(!ChatShareMenu.canShareLocation(
      phoneCoordinate: nil,
      nodeCoordinate: nil,
      locationAuthorized: false
    ))
  }

  // MARK: - canShareMyInfo

  @Test
  func `My info is shareable with a full-length key and a non-empty name`() {
    #expect(ChatShareMenu.canShareMyInfo(publicKey: Self.validKey, nodeName: "Base 1"))
  }

  @Test
  func `My info is not shareable with a wrong-length public key`() {
    #expect(!ChatShareMenu.canShareMyInfo(
      publicKey: Data(repeating: 0xAB, count: 8),
      nodeName: "Base 1"
    ))
  }

  @Test
  func `My info is not shareable with a blank name`() {
    #expect(!ChatShareMenu.canShareMyInfo(publicKey: Self.validKey, nodeName: "   "))
  }

  // MARK: - coordinateText

  @Test
  func `Coordinate text is latitude then longitude with six fractional digits`() {
    let text = ChatShareMenu.coordinateText(for: Self.sampleCoordinate)
    #expect(text == "37.000000, -122.000000")
  }

  @Test
  func `Coordinate text rounds to six fractional digits`() {
    let coordinate = CLLocationCoordinate2D(latitude: 52.37021549, longitude: 4.89516851)
    #expect(ChatShareMenu.coordinateText(for: coordinate) == "52.370215, 4.895169")
  }

  @Test
  func `Coordinate text keeps the sign in the southern and western hemispheres`() {
    let coordinate = CLLocationCoordinate2D(latitude: -33.8688, longitude: -70.6693)
    #expect(ChatShareMenu.coordinateText(for: coordinate) == "-33.868800, -70.669300")
  }

  @Test(arguments: [
    CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
    CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
    CLLocationCoordinate2D(latitude: 0.000001, longitude: -0.000001),
    CLLocationCoordinate2D(latitude: 89.999999, longitude: 179.999999)
  ])
  func `Coordinate text is detected as the same coordinate on the receiving side`(
    coordinate: CLLocationCoordinate2D
  ) throws {
    let text = ChatShareMenu.coordinateText(for: coordinate)
    let detected = try #require(ChatCoordinateDetector.firstCoordinate(in: text))
    #expect(abs(detected.latitude - coordinate.latitude) < 0.000001)
    #expect(abs(detected.longitude - coordinate.longitude) < 0.000001)
  }

  @Test
  func `Coordinate text is still detected after other draft text`() throws {
    let text = "Meet here " + ChatShareMenu.coordinateText(for: Self.sampleCoordinate)
    let detected = try #require(ChatCoordinateDetector.firstCoordinate(in: text))
    #expect(detected.latitude == 37.0)
    #expect(detected.longitude == -122.0)
  }
}
