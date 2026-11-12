import CairnServices
import SwiftUI

/// Settings → Nodes → Remove Nodes: clear non-favorites or every node from the radio and the app,
/// or the Heard list from the app. The radio removals run in `AppState.nodeRemoval`, which
/// outlives this view: closing the sheet mid-way leaves a removal running, and its outcome (or why
/// it stopped) shows here when next opened. Heard nodes are only the app's, so they go at once.
/// Factory Reset and Forget Device sit on the Connection page (`DeviceResetSection`).
struct NodeRemovalSection: View {
  @Environment(\.appState) private var appState
  /// The heard nodes the confirmation counts: the Heard list, less the saved nodes' heard records.
  @State private var heardKeys: Set<Data> = []
  @State private var showingRemoveHeardAlert = false
  @State private var showHeardNoneFound = false
  @State private var showRemoveHeardSuccess = false
  @State private var heardErrorMessage: String?

  var body: some View {
    @Bindable var model = appState.nodeRemoval
    CardFormSection(L10n.Settings.Nodes.Remove.header, footer: L10n.Settings.Nodes.Remove.footer) {
      NodeRemovalCard(
        title: L10n.Settings.DangerZone.removeUnfavorited,
        systemImage: "person.2.slash",
        workingTitle: model.progressText,
        isWorking: model.isRemovingUnfavorited,
        isDone: model.showRemoveSuccess
      ) {
        Task { await model.fetchUnfavoritedCount() }
      }
      .radioDisabled(
        for: appState.connectionState,
        or: model.isRemovingNodes || model.showRemoveSuccess
      )

      NodeRemovalCard(
        title: L10n.Settings.DangerZone.removeAll,
        systemImage: "person.2.slash.fill",
        workingTitle: model.progressText,
        isWorking: model.isRemovingAll,
        isDone: model.showRemoveAllSuccess
      ) {
        Task { await model.fetchAllNodesCount() }
      }
      .radioDisabled(
        for: appState.connectionState,
        or: model.isRemovingNodes || model.showRemoveAllSuccess
      )

      NodeRemovalCard(
        title: L10n.Settings.Nodes.Remove.heard,
        systemImage: "antenna.radiowaves.left.and.right.slash",
        workingTitle: L10n.Settings.DangerZone.removing,
        isWorking: false,
        isDone: showRemoveHeardSuccess
      ) {
        Task { await fetchHeardKeys() }
      }
      .disabled(showRemoveHeardSuccess)
    }
    .alert(
      L10n.Settings.Nodes.Remove.Heard.title,
      isPresented: $showingRemoveHeardAlert
    ) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Settings.Nodes.Remove.Heard.confirm, role: .destructive) {
        Task { await removeHeardNodes() }
      }
    } message: {
      Text(L10n.Settings.Nodes.Remove.Heard.message(heardKeys.count))
    }
    .alert(L10n.Settings.Nodes.Remove.heard, isPresented: $showHeardNoneFound) {
      Button(L10n.Localizable.Common.ok) {}
    } message: {
      Text(L10n.Settings.Nodes.Remove.Heard.noneFound)
    }
    .errorAlert($heardErrorMessage)
    .alert(
      L10n.Settings.DangerZone.Alert.RemoveUnfavorited.title,
      isPresented: $model.showingRemoveUnfavoritedAlert
    ) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Settings.DangerZone.Alert.RemoveUnfavorited.confirm, role: .destructive) {
        model.removeUnfavoritedNodes()
      }
    } message: {
      Text(L10n.Settings.DangerZone.Alert.RemoveUnfavorited.message(model.unfavoritedCount))
    }
    .alert(
      L10n.Settings.DangerZone.Alert.RemoveAll.title,
      isPresented: $model.showingRemoveAllAlert
    ) {
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      Button(L10n.Settings.DangerZone.Alert.RemoveAll.confirm, role: .destructive) {
        model.removeAllNodes()
      }
    } message: {
      Text(L10n.Settings.DangerZone.Alert.RemoveAll.message(model.allNodesCount))
    }
    .alert(
      L10n.Settings.DangerZone.Alert.RemoveUnfavorited.resultTitle,
      isPresented: $model.showRemoveResult
    ) {
      Button(L10n.Localizable.Common.ok) {}
    } message: {
      Text(model.removeResult ?? "")
    }
    .errorAlert($model.errorMessage)
  }

  /// Counts the Heard list, then confirms; an empty one says so instead.
  private func fetchHeardKeys() async {
    guard let store = appState.offlineDataStore, let radioID = appState.currentRadioID else { return }
    do {
      let savedKeys = try await Set(store.fetchContacts(radioID: radioID).map(\.publicKey))
      heardKeys = try await Set(store.fetchDiscoveredNodes(radioID: radioID).map(\.publicKey)).subtracting(savedKeys)
      if heardKeys.isEmpty {
        showHeardNoneFound = true
      } else {
        showingRemoveHeardAlert = true
      }
    } catch {
      heardErrorMessage = error.userFacingMessage
    }
  }

  /// Removes the counted heard nodes from the app; the Heard list and the maps reload after.
  private func removeHeardNodes() async {
    guard let store = appState.offlineDataStore, let radioID = appState.currentRadioID else { return }
    defer {
      heardKeys = []
      appState.noteDiscoveredNodesChanged()
    }
    do {
      _ = try await store.deleteDiscoveredNodes(radioID: radioID, publicKeys: heardKeys)
    } catch {
      heardErrorMessage = error.userFacingMessage
      return
    }
    withAnimation { showRemoveHeardSuccess = true }
    try? await Task.sleep(for: .seconds(1.5))
    withAnimation { showRemoveHeardSuccess = false }
  }
}

/// A destructive removal as a card that reports its own progress: the action, then a spinner with
/// what it's doing, then a green "Removed" before it resets.
private struct NodeRemovalCard: View {
  let title: String
  let systemImage: String
  let workingTitle: String
  let isWorking: Bool
  let isDone: Bool
  let action: () -> Void

  var body: some View {
    Button(role: .destructive, action: action) {
      HStack(spacing: 12) {
        if isWorking {
          ProgressView()
            .frame(width: 28, height: 28)
          Text(workingTitle)
            .foregroundStyle(Color.secondary)
        } else if isDone {
          IconTile(systemImage: "checkmark", color: .green)
            .accessibilityHidden(true)
          Text(L10n.Settings.DangerZone.removed)
            .foregroundStyle(Color.green)
        } else {
          IconTile(systemImage: systemImage, color: .red)
            .accessibilityHidden(true)
          Text(title)
            .foregroundStyle(Color.red)
        }
        Spacer(minLength: 0)
      }
      .font(.body)
      .cardSurface(padding: 12)
      .cardInteractionShape()
      .dimmedWhenDisabled()
    }
    .buttonStyle(.plain)
  }
}
