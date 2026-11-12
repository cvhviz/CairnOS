import Foundation

/// Runs a page's teardown when the page itself goes away, not when it merely disappears.
///
/// A Dashboard is the root of its sheet's stack, so `onDisappear` also fires each time a page is
/// pushed over it (Neighbors, the CLI, History). Teardown there stopped a discovery the Neighbors
/// control had just started and cleared the reply handlers for the rest of the visit. Held in the
/// page's `@State`, this object is released only when the sheet closes, and its `deinit` runs the
/// teardown then.
@MainActor
final class NodePageLifetime {
  var onEnd: (@MainActor () -> Void)?

  isolated deinit {
    onEnd?()
  }
}
