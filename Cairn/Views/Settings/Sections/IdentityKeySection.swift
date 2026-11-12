import SwiftUI

/// Settings › Connection & Security › Identity: replacing the radio's key, by importing one or
/// generating a new one. Each keeps its own sheet and confirmation. Moved here from Device Info's
/// action tiles (user, 2026-11-07): they change the radio rather than show it, and are rare.
/// Sharing the contact is Device Info's toolbar button; copying the key is its header's key chip.
struct IdentityKeySection: View {
  @Environment(\.appState) private var appState
  @State private var showingImportKeySheet = false
  @State private var showingRegenerateSheet = false

  var body: some View {
    CardFormSection(L10n.Settings.RegenerateIdentity.header) {
      ActionCard(L10n.Settings.ImportKey.title, systemImage: "square.and.arrow.down") {
        showingImportKeySheet = true
      }
      .accessibilityIdentifier("identity.importKey")
      .dimmedWhenDisabled()
      .radioDisabled(for: appState.connectionState)

      ActionCard(L10n.Settings.RegenerateIdentity.title, systemImage: "arrow.triangle.2.circlepath") {
        showingRegenerateSheet = true
      }
      .accessibilityIdentifier("identity.regenerateKey")
      .dimmedWhenDisabled()
      .radioDisabled(for: appState.connectionState)
    }
    .sheet(isPresented: $showingImportKeySheet) {
      ImportKeySheet()
    }
    .sheet(isPresented: $showingRegenerateSheet) {
      RegenerateIdentitySheet()
    }
  }
}
