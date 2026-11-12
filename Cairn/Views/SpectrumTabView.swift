import SwiftUI

/// The Spectrum tab root: `SpectrumView` in its own stack, titled with the connected radio like the
/// other tab roots, with the radio control and the tab's own settings (the sliders). The same on every device's tab bar. `SpectrumView` shows
/// its own not-connected state, and its polling follows the view's appearance, so it stops while
/// another tab is showing.
struct SpectrumTabView: View {
  var body: some View {
    NavigationStack {
      SpectrumView()
        // The bar's backdrop always drawn, as the Nodes list's shows it, so every tab's top reads alike
        // (the user, 2026-11-08).
        .tabTopBarBackdrop()
        .deviceNameTitle(pageTitle: AppTab.spectrum.title)
        .tabSettingsToolbarItem(for: .spectrum)
    }
  }
}

#Preview {
  SpectrumTabView()
    .environment(\.appState, AppState())
}
