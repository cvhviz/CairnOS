import Foundation

/// One feature row in a What's New release: a symbol with a localized title and description.
/// The symbol is an SF Symbol name, or with `isCustomSymbol` one of the app's own symbols in the
/// asset catalog (such as the Dashboard's walkie-talkie).
struct WhatsNewItem: Identifiable {
  let id = UUID()
  let symbol: String
  var isCustomSymbol = false
  let title: String
  let description: String
}
