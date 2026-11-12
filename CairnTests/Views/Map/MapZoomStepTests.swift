import MapKit
@testable import Cairn
import Testing

@Suite("MapZoomStep")
struct MapZoomStepTests {
  private let region = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 21.3, longitude: -157.8),
    span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.8)
  )

  @Test
  func `zooming in halves the span and keeps the center`() {
    let zoomed = MapZoomStep.region(from: region, direction: .zoomIn)
    #expect(zoomed.span.latitudeDelta == 0.2)
    #expect(zoomed.span.longitudeDelta == 0.4)
    #expect(zoomed.center.latitude == region.center.latitude)
    #expect(zoomed.center.longitude == region.center.longitude)
  }

  @Test
  func `zooming out doubles the span`() {
    let zoomed = MapZoomStep.region(from: region, direction: .zoomOut)
    #expect(zoomed.span.latitudeDelta == 0.8)
    #expect(zoomed.span.longitudeDelta == 1.6)
  }

  @Test
  func `in then out returns to the starting span`() {
    let roundTrip = MapZoomStep.region(
      from: MapZoomStep.region(from: region, direction: .zoomIn),
      direction: .zoomOut
    )
    #expect(roundTrip.span.latitudeDelta == region.span.latitudeDelta)
    #expect(roundTrip.span.longitudeDelta == region.span.longitudeDelta)
  }

  @Test
  func `spans are clamped at both ends`() {
    let tiny = MKCoordinateRegion(center: region.center, span: MKCoordinateSpan(latitudeDelta: 0.0001, longitudeDelta: 0.0001))
    let world = MKCoordinateRegion(center: region.center, span: MKCoordinateSpan(latitudeDelta: 160, longitudeDelta: 300))

    let zoomedIn = MapZoomStep.region(from: tiny, direction: .zoomIn)
    let zoomedOut = MapZoomStep.region(from: world, direction: .zoomOut)

    #expect(zoomedIn.span.latitudeDelta == MapZoomStep.minimumSpan)
    #expect(zoomedOut.span.latitudeDelta == MapZoomStep.maximumLatitudeSpan)
    #expect(zoomedOut.span.longitudeDelta == MapZoomStep.maximumLongitudeSpan)
  }
}
