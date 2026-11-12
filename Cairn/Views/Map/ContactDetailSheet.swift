import CairnServices
import SwiftUI

// MARK: - Contact Detail Sheet

/// A saved node's page over the map: the full Contact Detail in its own stack, so its history
/// and other pushes work inside the sheet. The map behind already shows where the node is, so
/// the page drops its header map, and adds Hide from Map where the host offers it.
struct ContactDetailSheet: View {
  let contact: ContactDTO
  let onMessage: () -> Void
  let onDelete: () -> Void
  /// Hides the node from the Map tab; nil on maps that do not offer hiding.
  let onHide: (() -> Void)?

  init(
    contact: ContactDTO,
    onMessage: @escaping () -> Void,
    onDelete: @escaping () -> Void,
    onHide: (() -> Void)? = nil
  ) {
    self.contact = contact
    self.onMessage = onMessage
    self.onDelete = onDelete
    self.onHide = onHide
  }

  var body: some View {
    NavigationStack {
      ContactDetailView(
        contact: contact,
        mapHost: ContactDetailMapHost(onMessage: onMessage, onDelete: onDelete, onHide: onHide)
      )
    }
  }
}
