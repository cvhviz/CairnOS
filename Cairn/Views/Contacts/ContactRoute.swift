import Foundation
import CairnServices

/// Push destinations for the Contacts feature stacks, registered once in
/// `ContactsSidebarContent` so the compact stack and the iPad content column share one set.
/// Equality and hashing use the contact's stable id, so path identity survives row updates
/// while the carried payload still lets the destination build before the list has loaded.
enum ContactRoute: Hashable {
  case detail(ContactDTO)

  /// Telemetry history push destination. `ContactDetailView` registers and pushes this
  /// itself because it is hosted by three different stacks (Contacts stack, iPad detail
  /// column, chat info sheet), so the destination must travel with the view.
  struct TelemetryHistory: Hashable {
    let publicKey: Data
    let radioID: UUID
    var showNeighbors = true
  }

  static func == (lhs: ContactRoute, rhs: ContactRoute) -> Bool {
    switch (lhs, rhs) {
    case let (.detail(lhsContact), .detail(rhsContact)):
      lhsContact.id == rhsContact.id
    }
  }

  func hash(into hasher: inout Hasher) {
    if case let .detail(contact) = self {
      hasher.combine(contact.id)
    }
  }
}
