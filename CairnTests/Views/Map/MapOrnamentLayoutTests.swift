import CoreGraphics
@testable import Cairn
import Testing

@Suite("Map ornament layout")
struct MapOrnamentLayoutTests {
  @Test
  func `nil clearance keeps the default logo and attribution margins`() {
    let logo = CairnMapView.OrnamentLayout.logoMargins(bottomClearance: nil)
    let attribution = CairnMapView.OrnamentLayout.attributionMargins(
      bottomClearance: nil,
      logoWidth: 80
    )
    #expect(logo == CairnMapView.OrnamentLayout.defaultLogoMargins)
    #expect(attribution == CairnMapView.OrnamentLayout.defaultAttributionMargins)
  }

  @Test
  func `clearance lifts logo and attribution to the same baseline beside each other`() {
    let clearance: CGFloat = 64
    let logoWidth: CGFloat = 80
    let logo = CairnMapView.OrnamentLayout.logoMargins(bottomClearance: clearance)
    let attribution = CairnMapView.OrnamentLayout.attributionMargins(
      bottomClearance: clearance,
      logoWidth: logoWidth
    )
    #expect(logo.x == CairnMapView.OrnamentLayout.defaultLogoMargins.x)
    #expect(logo.y == clearance)
    #expect(attribution.y == clearance)
    #expect(
      attribution.x
        == CairnMapView.OrnamentLayout.defaultLogoMargins.x
        + logoWidth
        + CairnMapView.OrnamentLayout.clusterSpacing
    )
  }
}
