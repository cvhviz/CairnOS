import CoreLocation
import MapKit
import SwiftUI

/// A node callout's overflow menu: where it is, handed on. Open in Apple Maps, the coordinates
/// shared or copied, Send My Location for a chat contact (the chat opens with where you are
/// already typed), and Look Around where Apple has street imagery there.
struct MapCalloutActionsMenu: View {
  let name: String
  let coordinate: CLLocationCoordinate2D
  /// Opens the chat with the user's own position inserted; nil for a node that has no chat.
  var onSendMyLocation: (() -> Void)?

  @State private var copied = false
  @State private var lookAroundScene: LookAroundScene?
  @State private var isLoadingLookAround = false
  @State private var toast: String?

  private var coordinateText: String {
    GPSFormat.coordinatePairText(coordinate)
  }

  var body: some View {
    Menu {
      if let onSendMyLocation {
        Button(L10n.Map.Map.Callout.sendMyLocation, systemImage: "location.fill.viewfinder", action: onSendMyLocation)
      }
      Button(L10n.Contacts.Contacts.Detail.openInMaps, systemImage: "map") {
        NodeLocation.openInMaps(name: name, coordinate: coordinate)
      }
      ShareLink(item: coordinateText) {
        Label(L10n.Map.Map.Callout.shareLocation, systemImage: "square.and.arrow.up")
      }
      Button(L10n.Map.Map.Callout.copyCoordinates, systemImage: "doc.on.doc") {
        UIPasteboard.general.string = coordinateText
        copied.toggle()
      }
      Divider()
      Button(L10n.Map.Map.Callout.lookAround, systemImage: "binoculars") {
        openLookAround()
      }
      .disabled(isLoadingLookAround)
    } label: {
      Label { Text(L10n.Map.Map.Callout.more) } icon: { MapCalloutIcon(systemImage: "ellipsis") }
    }
    .mapCalloutIconButton()
    .accessibilityHint(name)
    .sensoryFeedback(.success, trigger: copied)
    .sheet(item: $lookAroundScene) { scene in
      LookAroundSheet(scene: scene.scene, title: name)
    }
    .mapToast($toast)
  }

  /// Asks Apple for Look Around at the node; a place without it gets a word rather than a blank.
  private func openLookAround() {
    guard !isLoadingLookAround else { return }
    isLoadingLookAround = true
    Task {
      defer { isLoadingLookAround = false }
      let scene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
      if let scene {
        lookAroundScene = LookAroundScene(scene: scene)
      } else {
        toast = L10n.Map.Map.Callout.LookAround.unavailable
      }
    }
  }
}

/// A fetched scene, identifiable for the sheet that shows it.
struct LookAroundScene: Identifiable {
  let id = UUID()
  let scene: MKLookAroundScene
}

/// Apple's Look Around viewer over the node's position, with a Done button of its own.
struct LookAroundSheet: View {
  @Environment(\.dismiss) private var dismiss
  let scene: MKLookAroundScene
  let title: String

  var body: some View {
    NavigationStack {
      LookAroundViewer(scene: scene)
        .ignoresSafeArea(edges: .bottom)
        .flashingNavigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Localizable.Common.done) { dismiss() }
          }
        }
    }
    .presentationDetents([.large])
  }
}

/// `MKLookAroundViewController`, which SwiftUI has no view for.
private struct LookAroundViewer: UIViewControllerRepresentable {
  let scene: MKLookAroundScene

  func makeUIViewController(context: Context) -> MKLookAroundViewController {
    let controller = MKLookAroundViewController(scene: scene)
    controller.isNavigationEnabled = true
    controller.showsRoadLabels = true
    return controller
  }

  func updateUIViewController(_ controller: MKLookAroundViewController, context: Context) {
    if controller.scene !== scene {
      controller.scene = scene
    }
  }
}
