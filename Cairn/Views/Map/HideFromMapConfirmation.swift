import SwiftUI

extension View {
  /// Asks before a node is hidden from the Map tab, and says where to bring it back. `onHide`
  /// runs only when Hide is chosen.
  func hideFromMapConfirmation(
    name: String,
    isPresented: Binding<Bool>,
    onHide: @escaping () -> Void
  ) -> some View {
    confirmationDialog(
      L10n.Map.Map.HiddenNodes.Confirm.title(name),
      isPresented: isPresented,
      titleVisibility: .visible
    ) {
      Button(L10n.Map.Map.Detail.Action.hide, role: .destructive, action: onHide)
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Map.Map.HiddenNodes.Confirm.message)
    }
  }
}
