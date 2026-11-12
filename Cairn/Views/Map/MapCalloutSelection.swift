import Foundation
import CairnServices

enum MapCalloutSelection: Identifiable, Equatable {
  case contact(ContactDTO)
  case discovered(DiscoveredNodeDTO)
  /// This radio's own pin; the callout reads the connected device as it changes.
  case thisRadio

  /// A fixed id for this radio's own pin and callout, so it never collides with a contact's.
  static let thisRadioID = UUID(uuidString: "4D41502D-5261-6469-6F2D-53656C660000")!

  var id: UUID {
    switch self {
    case let .contact(contact): contact.id
    case let .discovered(node): node.id
    case .thisRadio: Self.thisRadioID
    }
  }
}
