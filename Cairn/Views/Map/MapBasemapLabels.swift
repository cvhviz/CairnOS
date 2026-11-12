import MapLibre
import UIKit

/// Quiets the basemap's own labels so node badges stay the loudest text on the map: points of
/// interest (shops, cafés, …) are faded and only shown when zoomed into a street, and every
/// remaining basemap label (places, roads, water) gets a firm halo so it stays readable where it
/// meets our pins and lines. Our badges sit above all of these and win collisions with them.
enum MapBasemapLabels {
  enum Treatment: Equatable {
    /// A point-of-interest label or icon: faded and held back to street zoom.
    case pointOfInterest
    /// A place, road, or water name: kept, with a stronger halo.
    case name
    /// Not a basemap label (our own layers), or not a symbol layer.
    case untouched
  }

  /// OpenMapTiles (OpenFreeMap) source layers that carry points of interest.
  static let pointOfInterestSourceLayers: Set<String> = ["poi"]

  /// POIs appear from this zoom (about a street) instead of the style's own threshold.
  static let pointOfInterestMinimumZoom: Float = 15
  static let pointOfInterestOpacity = 0.55

  /// The layers Cairn adds; never restyled here.
  private static let ownLayerIDs: Set<String> = [
    MapLayerID.clusterCircles, MapLayerID.clusterLabels, MapLayerID.unclusteredIcons,
    MapLayerID.nameLabels, MapLayerID.badgeText, MapLayerID.fixedIcons,
    MapLayerID.fixedNameLabels, MapLayerID.fixedBadgeText,
  ]

  static func treatment(layerID: String, sourceLayerID: String?) -> Treatment {
    guard !ownLayerIDs.contains(layerID) else { return .untouched }
    if let sourceLayerID, pointOfInterestSourceLayers.contains(sourceLayerID) {
      return .pointOfInterest
    }
    return .name
  }

  /// - Parameter hidesAll: Hides every basemap label instead, for a map under its own lettering.
  @MainActor
  static func tune(style: MLNStyle, isDarkMode: Bool, hidesAll: Bool = false) {
    let haloColor = isDarkMode ? UIColor(white: 0, alpha: 0.85) : UIColor(white: 1, alpha: 0.95)
    for case let layer as MLNSymbolStyleLayer in style.layers {
      let treatment = treatment(layerID: layer.identifier, sourceLayerID: layer.sourceLayerIdentifier)
      if hidesAll, treatment != .untouched {
        layer.isVisible = false
        continue
      }
      switch treatment {
      case .pointOfInterest:
        layer.textOpacity = NSExpression(forConstantValue: pointOfInterestOpacity)
        layer.iconOpacity = NSExpression(forConstantValue: pointOfInterestOpacity)
        layer.minimumZoomLevel = max(layer.minimumZoomLevel, pointOfInterestMinimumZoom)
      case .name:
        layer.textHaloColor = NSExpression(forConstantValue: haloColor)
        layer.textHaloWidth = NSExpression(forConstantValue: 1.5)
        layer.textHaloBlur = NSExpression(forConstantValue: 0.5)
      case .untouched:
        break
      }
    }
  }
}
