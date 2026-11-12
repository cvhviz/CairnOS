import MapLibre
@testable import Cairn
import Testing

@Suite("MapNameLabelVisibility")
@MainActor
struct MapNameLabelVisibilityTests {
  @Test
  func `hidden preference makes the name-label layer not visible`() {
    let layer = Self.configuredLayer(showLabels: false)
    #expect(layer.isVisible == false)
  }

  @Test
  func `shown preference makes the name-label layer visible`() {
    let layer = Self.configuredLayer(showLabels: true)
    #expect(layer.isVisible == true)
  }

  @Test
  func `name badges collide instead of stacking and hang under the pin`() {
    let layer = Self.configuredLayer(showLabels: true)
    #expect(layer.iconAllowsOverlap == NSExpression(forConstantValue: false))
    #expect(layer.iconIgnoresPlacement == NSExpression(forConstantValue: false))
    #expect(layer.iconAnchor == NSExpression(forConstantValue: "top"))
    // MapLibre wraps a key-path sort key in a numeric cast, so check the key it reads.
    #expect(layer.symbolSortKey?.description.contains("labelSortKey") == true)
  }

  @Test
  func `managed style images are not evicted`() {
    let coordinator = CairnMapView.Coordinator()
    let mapView = coordinator.mapView
    #expect(coordinator.mapView(mapView, shouldRemoveStyleImage: "label-Alice") == false)
    #expect(coordinator.mapView(mapView, shouldRemoveStyleImage: "pin-repeater") == false)
    #expect(coordinator.mapView(mapView, shouldRemoveStyleImage: "pill-bg") == false)
    #expect(coordinator.mapView(mapView, shouldRemoveStyleImage: "osm-sprite") == true)
  }

  private static func configuredLayer(showLabels: Bool) -> MLNSymbolStyleLayer {
    let coordinator = CairnMapView.Coordinator()
    coordinator.currentShowLabels = showLabels
    let source = MLNShapeSource(identifier: "probe-points", features: [], options: nil)
    let layer = MLNSymbolStyleLayer(identifier: "probe-name-labels", source: source)
    coordinator.configureNameLabelLayer(layer)
    return layer
  }
}
