@testable import Cairn
import SwiftUI
import Testing

@MainActor
@Suite("AppTheme environment")
struct AppThemeEnvironmentTests {
  @Test
  func `the default appTheme environment value is Theme.default`() {
    let values = EnvironmentValues()
    #expect(values.appTheme.id == Theme.default.id)
  }
}
