import CoreLocation
import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// The map's search (what it lists, how it matches and orders) and the long-press pin, which
/// lands without moving the camera.
@Suite("Map search and dropped pin")
struct MapSearchAndDropPinTests {
  private func entry(_ name: String, key: UInt8, latitude: Double, discovered: Bool = false) -> MapSearchSheet.Entry {
    MapSearchSheet.Entry(
      publicKey: Data([key] + Array(repeating: 0, count: 31)),
      name: name,
      type: .repeater,
      coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -122),
      isDiscovered: discovered
    )
  }

  @Test
  func `Search matches a name fragment or a hex ID prefix, case-insensitively`() {
    let entries = [entry("Hilltop", key: 0xA1, latitude: 37), entry("Base", key: 0xB2, latitude: 38)]
    #expect(MapSearchSheet.matches(entries, query: "hill", origin: nil).map(\.name) == ["Hilltop"])
    #expect(MapSearchSheet.matches(entries, query: "b2", origin: nil).map(\.name) == ["Base"])
    #expect(MapSearchSheet.matches(entries, query: "", origin: nil).map(\.name) == ["Base", "Hilltop"])
    #expect(MapSearchSheet.matches(entries, query: "zzz", origin: nil).isEmpty)
  }

  @Test
  func `Search lists the nearest first when there is somewhere to measure from`() {
    let entries = [entry("Far", key: 0x01, latitude: 39), entry("Near", key: 0x02, latitude: 37.01)]
    let origin = CLLocation(latitude: 37, longitude: -122)
    #expect(MapSearchSheet.matches(entries, query: "", origin: origin).map(\.name) == ["Near", "Far"])
  }

  @Test
  func `Entries list each key once, contacts before heard nodes`() {
    let shared = Data(repeating: 0x05, count: 32)
    let contact = ContactDTO.fixture(name: "Saved", publicKey: shared)
    let heard = DiscoveredNodeDTO.fixture(name: "Heard", publicKey: shared)
    let other = DiscoveredNodeDTO.fixture(name: "Other", publicKey: Data(repeating: 0x06, count: 32))
    let entries = MapSearchSheet.entries(contacts: [contact], discovered: [heard, other])
    #expect(entries.map(\.name) == ["Saved", "Other"])
    #expect(entries.map(\.isDiscovered) == [false, true])
  }

  @Test
  @MainActor
  func `A dropped pin joins the points without moving the camera`() {
    let viewModel = MapViewModel()
    let version = viewModel.cameraRegionVersion
    let coordinate = CLLocationCoordinate2D(latitude: 37.5, longitude: -122.5)
    viewModel.dropPin(at: coordinate)
    let pin = viewModel.mapPoints.first { $0.id == MapViewModel.focusedPinID }
    #expect(pin?.pinStyle == .droppedPin)
    #expect(pin?.coordinate.latitude == 37.5)
    #expect(viewModel.cameraRegionVersion == version)
    #expect(viewModel.cameraRegion == nil)

    // Focusing on a coordinate still moves the camera, as a chat's coordinate tap always has.
    viewModel.focusOnCoordinate(coordinate)
    #expect(viewModel.cameraRegionVersion == version + 1)
    #expect(viewModel.mapPoints.filter { $0.id == MapViewModel.focusedPinID }.count == 1)
  }
}
