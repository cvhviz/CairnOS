import CairnServices
import SwiftUI
import UIKit

/// A node's page in its own window on a Mac, which the phone and iPad show as a sheet. What the
/// page opens (status, admin, telemetry, the full map) pushes onto this window's stack. Rebuilt
/// from the route's ids, so a window restored at relaunch shows what is current, or says it's gone.
struct MacDetailWindowView: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismissWindow) private var dismissWindow

  let route: MacDetailRoute?

  @State private var page: Page?
  @State private var didLoad = false
  @State private var windowScene = WeakWindowScene()
  /// Add to Nodes in progress, for a discovered node's window.
  @State private var isAdding = false
  @State private var errorMessage: String?

  private enum Page {
    case contact(ContactDTO, canHideFromMap: Bool)
    case discoveredNode(DiscoveredNodeDTO, canHideFromMap: Bool)
  }

  /// Reloads when the window is asked for again, once the store is there to read, and when the
  /// saved nodes change (a rename, which the title follows).
  private struct LoadKey: Hashable {
    let route: MacDetailRoute?
    let openCount: Int
    let hasStore: Bool
    let contactsVersion: Int
  }

  private var store: PersistenceStore? {
    appState.services?.dataStore ?? appState.offlineDataStore
  }

  private var loadKey: LoadKey {
    LoadKey(
      route: route,
      openCount: route.map { MacDetailWindows.shared.openCount(for: $0) } ?? 0,
      hasStore: store != nil,
      contactsVersion: appState.contactsVersion
    )
  }

  /// The node's name in the title bar; the Nodes section's name until it loads.
  private var windowTitle: String {
    switch page {
    case let .contact(contact, _): contact.displayName
    case let .discoveredNode(node, _): node.name.isEmpty ? L10n.Map.Map.DiscoveredDetail.title : node.name
    case nil: didLoad ? L10n.Contacts.Contacts.Window.unavailable : AppTab.contacts.title
    }
  }

  var body: some View {
    content
      .environment(\.macDetailWindow, MacDetailWindowCloser { close(showingMainWindow: $0) })
      .background {
        WindowSceneReader { windowScene.scene = $0 }
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
      }
      .task(id: loadKey) { await load() }
      .macWindowTitle(windowTitle)
      .errorAlert($errorMessage)
  }

  @ViewBuilder
  private var content: some View {
    switch page {
    case let .contact(contact, canHideFromMap):
      NavigationStack {
        // As the map sheets host it: the conversation opens in the main window, and a delete
        // reaches the maps and lists through `contactsVersion`.
        ContactDetailView(
          contact: contact,
          mapHost: ContactDetailMapHost(
            onMessage: { appState.navigation.navigateToChat(with: contact) },
            onDelete: {},
            onHide: canHideFromMap ? { hideFromMap(contact.publicKey) } : nil
          )
        )
      }
    case let .discoveredNode(node, canHideFromMap):
      DiscoveredNodeDetailSheet(
        node: node,
        isAdding: isAdding,
        onAdd: { add(node) },
        onHide: canHideFromMap ? { hideFromMap(node.publicKey) } : nil
      )
    case nil:
      NavigationStack {
        if didLoad {
          ContentUnavailableView(L10n.Contacts.Contacts.Window.unavailable, systemImage: "questionmark.circle")
        } else {
          ProgressView()
        }
      }
    }
  }

  // MARK: - Loading

  private func load() async {
    defer { didLoad = true }
    guard let route else { return }
    switch route {
    case let .contact(id, canHideFromMap):
      page = (try? await store?.fetchContact(id: id)).map { .contact($0, canHideFromMap: canHideFromMap) }
    case let .discoveredNode(id, radioID, canHideFromMap):
      let nodes = (try? await store?.fetchDiscoveredNodes(radioID: radioID)) ?? []
      page = nodes.first { $0.id == id }.map { .discoveredNode($0, canHideFromMap: canHideFromMap) }
    }
  }

  // MARK: - Actions

  /// Hides the node from the Map tab for the current radio; the maps follow the stored list.
  private func hideFromMap(_ publicKey: Data) {
    guard let radioID = appState.currentRadioID else { return }
    var hidden = HiddenMapNodesStorage.load()
    hidden.hide(publicKey, radioID: radioID)
    HiddenMapNodesStorage.save(hidden)
  }

  /// Saves a heard node to the radio's list, as the map sheets do, then closes: the node is a
  /// saved contact from here on, and the maps and lists reload through `contactsVersion`.
  private func add(_ node: DiscoveredNodeDTO) {
    guard !isAdding else { return }
    guard let contactService = appState.services?.contactService else {
      errorMessage = L10n.Contacts.Contacts.Add.Error.notConnected
      return
    }
    isAdding = true
    Task {
      defer { isAdding = false }
      do {
        try await contactService.addOrUpdateContact(radioID: node.radioID, contact: node.makeContactFrame())
        close(showingMainWindow: false)
      } catch ContactServiceError.contactTableFull {
        errorMessage = appState.connectedDevice.map { L10n.Contacts.Contacts.Add.Error.nodeListFull(Int($0.maxContacts)) }
          ?? L10n.Contacts.Contacts.Add.Error.nodeListFullSimple
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }

  private func close(showingMainWindow: Bool) {
    if showingMainWindow {
      MacMainWindow.activate()
    }
    let scene = windowScene.scene
    dismissWindow()
    // Should `dismissWindow` leave the window up, end its scene directly.
    guard let scene else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(500))
      guard UIApplication.shared.connectedScenes.contains(scene) else { return }
      UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil, errorHandler: nil)
    }
  }
}

/// The window's scene, kept weakly so the view doesn't hold a scene the system has let go.
private final class WeakWindowScene {
  weak var scene: UIWindowScene?
}
