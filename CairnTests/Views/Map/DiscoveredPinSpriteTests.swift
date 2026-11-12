import CoreLocation
import Foundation
@testable import Cairn
import Testing
import UIKit

@Suite("Discovered pin sprites")
@MainActor
struct DiscoveredPinSpriteTests {
  @Test
  func `outlined discovered pins render beside the solid contact pins`() throws {
    let styles: [MapPoint.PinStyle] = [.contactChat, .discoveredChat, .repeater, .discoveredRepeater, .contactRoom, .discoveredRoom]
    let appearance = MapAvatarAppearance.standard(isDark: false)
    let images = styles.map { style in
      PinSpriteRenderer.snapshotSprite(
        for: MapPoint(
          id: UUID(),
          coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
          pinStyle: style,
          label: nil,
          isClusterable: false,
          hopIndex: nil,
          badgeText: nil,
          avatar: MapPinAvatar(name: "Alice")
        ),
        appearance: appearance,
        fallbackName: ""
      )
    }
    for image in images {
      #expect(image.size.width > 10)
    }
    // Contact sheet for a visual check.
    let cell = CGSize(width: 60, height: 60)
    let sheet = UIGraphicsImageRenderer(size: CGSize(width: cell.width * CGFloat(images.count), height: cell.height)).image { ctx in
      UIColor(white: 0.85, alpha: 1).setFill()
      ctx.fill(CGRect(origin: .zero, size: CGSize(width: cell.width * CGFloat(images.count), height: cell.height)))
      for (index, image) in images.enumerated() {
        image.draw(at: CGPoint(x: CGFloat(index) * cell.width + (cell.width - image.size.width) / 2, y: 6))
      }
    }
    try sheet.pngData()?.write(to: URL(fileURLWithPath: "/tmp/discovered-sprites.png"))
  }
}
