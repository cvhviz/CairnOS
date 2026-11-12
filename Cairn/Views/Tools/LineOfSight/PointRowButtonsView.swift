import CoreLocation
import MapKit
import SwiftUI

/// A placed point's actions in one ••• menu: its antenna height, moving it, sharing where it is,
/// and removing it. One target in place of a row of small buttons.
struct PointRowButtonsView: View {
  var viewModel: LineOfSightViewModel
  let pointID: PointID
  let isEditing: Bool
  @Binding var copyHapticTrigger: Int
  @Binding var editingPoint: PointID?
  let onRelocate: () -> Void
  let onClear: () -> Void

  private var coordinate: CLLocationCoordinate2D? {
    switch pointID {
    case .pointA: viewModel.pointA?.coordinate
    case .pointB: viewModel.pointB?.coordinate
    case .repeater: viewModel.repeaterPoint?.coordinate
    }
  }

  private var mapItemName: String {
    switch pointID {
    case .pointA: L10n.Tools.Tools.LineOfSight.pointA
    case .pointB: L10n.Tools.Tools.LineOfSight.pointB
    case .repeater: L10n.Tools.Tools.LineOfSight.repeaterLocation
    }
  }

  var body: some View {
    Menu {
      Button(L10n.Tools.Tools.LineOfSight.antennaHeight, systemImage: "ruler") {
        withAnimation { editingPoint = isEditing ? nil : pointID }
      }
      Button(L10n.Tools.Tools.LineOfSight.relocate, systemImage: "mappin.and.ellipse") {
        viewModel.relocatingPoint = pointID
        onRelocate()
      }

      if let coord = coordinate {
        Divider()
        Button(L10n.Tools.Tools.LineOfSight.openInMaps, systemImage: "map") {
          let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coord))
          mapItem.name = mapItemName
          mapItem.openInMaps()
        }
        Button(L10n.Tools.Tools.LineOfSight.copyCoordinates, systemImage: "doc.on.doc") {
          copyHapticTrigger += 1
          UIPasteboard.general.string = coord.formattedString
        }
        ShareLink(item: coord.formattedString) {
          Label(L10n.Tools.Tools.LineOfSight.share, systemImage: "square.and.arrow.up")
        }
      }

      Divider()
      Button(L10n.Tools.Tools.LineOfSight.clear, systemImage: "xmark.circle", role: .destructive, action: onClear)
    } label: {
      Image(systemName: "ellipsis.circle.fill")
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 36)
        .contentShape(.circle)
    }
    .accessibilityLabel(L10n.Contacts.Contacts.Detail.more)
    .sensoryFeedback(.success, trigger: copyHapticTrigger)
  }
}
