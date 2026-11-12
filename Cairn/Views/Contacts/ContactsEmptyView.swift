import SwiftUI

struct ContactsEmptyView: View {
  let selectedSegment: NodeSegment
  var favoritesOnly = false

  var body: some View {
    if favoritesOnly {
      ContentUnavailableView(
        L10n.Contacts.Contacts.List.Empty.Favorites.title,
        systemImage: "star",
        description: Text(L10n.Contacts.Contacts.List.Empty.Favorites.description)
      )
    } else {
      segmentEmpty
    }
  }

  @ViewBuilder
  private var segmentEmpty: some View {
    switch selectedSegment {
    case .all, .contacts:
      ContentUnavailableView(
        L10n.Contacts.Contacts.List.Empty.Contacts.title,
        systemImage: "person.2",
        description: Text(L10n.Contacts.Contacts.List.Empty.Contacts.description)
      )
    case .repeaters:
      ContentUnavailableView(
        L10n.Contacts.Contacts.List.Empty.Repeaters.title,
        systemImage: "antenna.radiowaves.left.and.right",
        description: Text(L10n.Contacts.Contacts.List.Empty.Repeaters.description)
      )
    case .rooms:
      ContentUnavailableView(
        L10n.Contacts.Contacts.List.Empty.Rooms.title,
        systemImage: "door.left.hand.open",
        description: Text(L10n.Contacts.Contacts.List.Empty.Rooms.description)
      )
    }
  }
}
