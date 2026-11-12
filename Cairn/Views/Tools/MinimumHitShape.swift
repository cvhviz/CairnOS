import SwiftUI

/// Hit-testing shape that covers at least `minimum` points in each dimension, centered on the
/// view. It reaches past the view's bounds instead of growing its frame, so a small control gets
/// a finger-sized target without moving anything around it.
struct MinimumHitShape: Shape {
  var minimum: CGFloat = 44

  func path(in rect: CGRect) -> Path {
    let horizontal = max(0, (minimum - rect.width) / 2)
    let vertical = max(0, (minimum - rect.height) / 2)
    return Path(rect.insetBy(dx: -horizontal, dy: -vertical))
  }
}
