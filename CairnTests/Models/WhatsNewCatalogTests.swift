@testable import Cairn
import Testing
import UIKit

@Suite("WhatsNewCatalog")
struct WhatsNewCatalogTests {
  @Test
  func `every catalog symbol name resolves to an image`() {
    for release in WhatsNewCatalog.releases {
      for item in release.items {
        let image = item.isCustomSymbol ? UIImage(named: item.symbol) : UIImage(systemName: item.symbol)
        #expect(
          image != nil,
          "Symbol \"\(item.symbol)\" does not resolve and would render blank"
        )
      }
    }
  }

  @Test
  func `no release ships an empty item list`() {
    for release in WhatsNewCatalog.releases {
      #expect(!release.items.isEmpty)
    }
  }
}
