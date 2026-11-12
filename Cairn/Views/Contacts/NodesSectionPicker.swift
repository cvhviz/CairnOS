import CairnServices
import SwiftUI

/// The Nodes tab's two lists: the nodes saved on the radio, and the nodes heard by advert that
/// aren't saved. They were one tab and a page pushed inside it, but both list nodes with the same
/// search, sort and layout, so they now share the tab behind a segmented control.
enum NodesSection: String, CaseIterable, Sendable {
  case saved
  case heard

  var localizedTitle: String {
    switch self {
    case .saved: L10n.Contacts.Contacts.Section.saved
    case .heard: L10n.Contacts.Contacts.Section.heard
    }
  }
}

/// Saved | Heard at the top of the Nodes tab's list, above that list's own filter pills. Reads
/// and writes `NavigationCoordinator.nodesSection` so `navigateToDiscovery()` can switch it, and
/// so the compact stack and the iPad content column show the same list.
struct NodesSectionPicker: View {
  @Environment(\.appState) private var appState

  var body: some View {
    let navigation = appState.navigation
    // A pick here is remembered for the next launch (`AppStorageKey.nodesSection`).
    let selection = Binding(
      get: { navigation.nodesSection },
      set: { section in
        navigation.nodesSection = section
        UserDefaults.standard.set(section.rawValue, forKey: AppStorageKey.nodesSection.rawValue)
      }
    )
    Picker(L10n.Contacts.Contacts.Section.pickerLabel, selection: selection.animation(.snappy)) {
      ForEach(NodesSection.allCases, id: \.self) { section in
        Text(section.localizedTitle).tag(section)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 16)
    // As far below the bar as every tab's first section (`CardStyle.pageInset`), so switching
    // tabs doesn't jump (the user, 2026-11-08).
    .padding(.top, CardStyle.pageInset)
    // The filter below brings its own top padding, so only a little here: the two controls
    // read as one header.
    .padding(.bottom, 2)
    .accessibilityIdentifier("nodes.section")
  }
}
