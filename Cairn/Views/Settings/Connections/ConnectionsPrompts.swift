import CairnServices
import SwiftUI

extension View {
  /// The Radios side's questions and sheets (connect, rename, forget, switch transport, edit
  /// address, errors), attached to whichever page is on top: the list, or a radio's page pushed over it.
  func connectionsPrompts(_ model: ConnectionsModel, appState: AppState, isActive: Bool = true) -> some View {
    modifier(ConnectionsPromptsModifier(model: model, appState: appState, isActive: isActive))
  }
}

private struct ConnectionsPromptsModifier: ViewModifier {
  @Bindable var model: ConnectionsModel
  let appState: AppState
  let isActive: Bool

  func body(content: Content) -> some View {
    content
      .sheet(item: active(\.wifiAddressEdit), onDismiss: { Task { await model.reload(appState) } }) { edit in
        WiFiEditSheet(editing: edit)
      }
      .alert(L10n.Settings.Connections.Rename.title, isPresented: isPresented(\.renaming)) {
        TextField(model.renaming?.device.nodeName ?? "", text: $model.renameText)
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
        Button(L10n.Localizable.Common.save) {
          model.commitRename(appState)
        }
      } message: {
        Text(L10n.Settings.Connections.Rename.message)
      }
      .confirmationDialog(
        L10n.Settings.Connections.Forget.title(model.forgetting?.displayName ?? ""),
        isPresented: isPresented(\.forgetting),
        titleVisibility: .visible,
        presenting: model.forgetting
      ) { row in
        Button(L10n.Settings.Connections.Forget.confirm, role: .destructive) {
          model.forget(row, appState: appState)
        }
      } message: { _ in
        Text(L10n.Settings.Connections.Forget.message)
      }
      .alert(
        L10n.Settings.Connections.ConnectPrompt.title(model.confirmingConnect?.displayName ?? ""),
        isPresented: isPresented(\.confirmingConnect),
        presenting: model.confirmingConnect
      ) { row in
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
        Button(L10n.Settings.Connections.Action.connect) {
          model.connect(row, appState: appState)
        }
        .keyboardShortcut(.defaultAction)
      } message: { _ in
        if let current = appState.connectedDevice {
          Text(L10n.Settings.Connections.ConnectPrompt.switchMessage(current.nodeName))
        }
      }
      .transportSwitchAlert(active(\.transportSwitch)) { prompt in
        model.confirmSwitch(prompt, appState: appState)
      }
      .errorAlert(active(\.errorMessage))
  }

  /// The model's value while this page is the one presenting, else nothing.
  private func active<Value>(_ keyPath: ReferenceWritableKeyPath<ConnectionsModel, Value?>) -> Binding<Value?> {
    Binding(
      get: { isActive ? model[keyPath: keyPath] : nil },
      set: { model[keyPath: keyPath] = $0 }
    )
  }

  private func isPresented<Value>(_ keyPath: ReferenceWritableKeyPath<ConnectionsModel, Value?>) -> Binding<Bool> {
    Binding(
      get: { isActive && model[keyPath: keyPath] != nil },
      set: { if !$0 { model[keyPath: keyPath] = nil } }
    )
  }
}
