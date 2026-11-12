@testable import Cairn
import SwiftUI
import Testing

/// `opaqueFill` stays `nil` on iOS 26+ even when the user's background supplies a canvas color, so
/// glass on the compose controls can sample the timeline.
@Suite("Chat input bar themed chrome")
struct ChatInputBarThemedChromeTests {
  @available(iOS 26, *)
  @Test
  func `default theme does not paint an opaque fill on Liquid Glass`() {
    #expect(ChatInputBarChrome.opaqueFill(themedCanvas: nil) == nil)
  }

  @available(iOS 26, *)
  @Test
  func `a background canvas does not paint an opaque fill on Liquid Glass`() {
    #expect(ChatInputBarChrome.opaqueFill(themedCanvas: .black) == nil)
  }
}
