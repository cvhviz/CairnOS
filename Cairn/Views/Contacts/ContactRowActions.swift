import CairnServices
import SwiftUI

/// Shared menu and swipe buttons for a node row. `edge` picks the full set or one swipe side; send message is menu-only.
struct ContactRowActions: View {
  enum Edge {
    case all
    case leading
    case trailing
  }

  @Environment(\.appState) private var appState

  let contact: ContactDTO
  let viewModel: ContactsViewModel
  let edge: Edge

  private var isConnected: Bool {
    appState.connectionState == .ready
  }

  /// ZephCore V-contact remove is disabled (would turn off firmware admin CLI).
  private var isVContact: Bool {
    guard let selfKey = appState.connectedDevice?.publicKey else { return false }
    return VContactIdentity.isVContact(publicKey: contact.publicKey, selfPublicKey: selfKey)
  }

  var body: some View {
    if edge == .all, contact.type == .chat, !contact.isBlocked {
      sendMessageButton
    }

    if edge == .all, contact.type == .chat {
      discoverPathButton
    }

    if edge == .all, contact.type == .repeater {
      repeaterQuickActions
    }

    if edge == .all {
      if contact.hasLocation {
        showOnMapButton
      }
      shareButton
      renameButton
      copyPublicKeyButton
      Divider()
      ContactGroupsMenu(contact: contact, viewModel: viewModel)
      Divider()
    }

    if edge != .leading {
      if !isVContact {
        deleteButton
      }
      if contact.type == .chat {
        blockButton
      }
    }

    if edge != .trailing {
      favoriteButton
    }
  }

  private var sendMessageButton: some View {
    Button {
      appState.navigation.navigateToChat(with: contact)
    } label: {
      Label(L10n.Contacts.Contacts.Detail.sendMessage, systemImage: "message.fill")
    }
    .disabled(!isConnected)
  }

  /// Opens the node's page and starts a path discovery there, as its Discover Path tile does.
  private var discoverPathButton: some View {
    Button {
      appState.navigation.navigateToContactDetail(contact, performing: .discoverPath)
    } label: {
      Label(L10n.Contacts.Contacts.Detail.discoverPath, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
    }
    .disabled(!isConnected)
  }

  /// The node on the map, as the page's header opens it; presented by the list host.
  private var showOnMapButton: some View {
    Button {
      viewModel.mapContact = contact
    } label: {
      Label(L10n.Contacts.Contacts.Row.showOnMap, systemImage: "map")
    }
  }

  /// The QR share sheet, as the page's Share tile opens it.
  private var shareButton: some View {
    Button {
      viewModel.shareContact = contact
    } label: {
      Label(L10n.Contacts.Contacts.Row.share, systemImage: "square.and.arrow.up")
    }
  }

  private var renameButton: some View {
    Button {
      viewModel.renameContact = contact
    } label: {
      Label(L10n.Contacts.Contacts.Detail.rename, systemImage: "pencil")
    }
  }

  private var copyPublicKeyButton: some View {
    Button {
      UIPasteboard.general.string = contact.publicKey.hexString.uppercased()
    } label: {
      Label(L10n.Contacts.Contacts.Row.copyPublicKey, systemImage: "doc.on.doc")
    }
  }

  /// Menu-only shortcuts into the repeater's detail actions.
  @ViewBuilder
  private var repeaterQuickActions: some View {
    Button {
      appState.navigation.navigateToContactDetail(contact, performing: .telemetry)
    } label: {
      Label(L10n.Contacts.Contacts.Detail.telemetry, systemImage: "chart.line.uptrend.xyaxis")
    }
    .disabled(!isConnected)

    Button {
      appState.navigation.navigateToContactDetail(contact, performing: .management)
    } label: {
      Label(L10n.Contacts.Contacts.Detail.management, systemImage: "gearshape.2")
    }
    .disabled(!isConnected)

    Button {
      appState.navigation.navigateToContactDetail(contact, performing: .ping)
    } label: {
      Label(L10n.Contacts.Contacts.Detail.ping, systemImage: "wave.3.right")
    }
    .disabled(!isConnected)

    Divider()
  }

  /// Asks first, through the list host's alert, as the node's page does.
  private var deleteButton: some View {
    Button(role: .destructive) {
      viewModel.deleteConfirmation = contact
    } label: {
      Label(L10n.Contacts.Contacts.Common.delete, systemImage: "trash")
    }
    .disabled(!isConnected || viewModel.isDeletePending(contact.id))
  }

  /// Blocking asks first, as on the node's page; unblocking is immediate.
  private var blockButton: some View {
    Button {
      if contact.isBlocked {
        Task {
          await viewModel.toggleBlocked(contact: contact)
        }
      } else {
        viewModel.blockConfirmation = contact
      }
    } label: {
      Label(
        contact.isBlocked ? L10n.Contacts.Contacts.Action.unblock : L10n.Contacts.Contacts.Action.block,
        systemImage: contact.isBlocked ? "hand.raised.slash" : "hand.raised"
      )
    }
    .disabled(!isConnected)
  }

  private var favoriteButton: some View {
    Button {
      Task {
        await viewModel.toggleFavorite(contact: contact)
      }
    } label: {
      Label(
        contact.isFavorite ? L10n.Contacts.Contacts.Action.unfavorite : L10n.Contacts.Contacts.Row.favorite,
        systemImage: contact.isFavorite ? "star.slash" : "star.fill"
      )
    }
    .disabled(!isConnected || viewModel.togglingFavoriteID == contact.id)
  }
}

extension View {
  func contactContextMenu(contact: ContactDTO, viewModel: ContactsViewModel) -> some View {
    contextMenu {
      ContactRowActions(contact: contact, viewModel: viewModel, edge: .all)
    }
  }

  /// Favorite from the leading edge, Delete and Block from the trailing. `isEnabled` false (select
  /// mode) leaves the row without swipes, as on the Heard list.
  func contactSwipeActions(contact: ContactDTO, viewModel: ContactsViewModel, isEnabled: Bool = true) -> some View {
    swipeActions(edge: .leading, allowsFullSwipe: true) {
      if isEnabled {
        ContactRowActions(contact: contact, viewModel: viewModel, edge: .leading)
      }
    }
    // Full-swipe off so Delete cannot fire without a tap.
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if isEnabled {
        ContactRowActions(contact: contact, viewModel: viewModel, edge: .trailing)
      }
    }
  }

  /// The alerts a row's Delete and Block wait for, worded as the node's page words them, and the
  /// Retry a timed-out delete is offered. On the list host, once, for every row.
  func contactRowConfirmations(viewModel: ContactsViewModel) -> some View {
    modifier(ContactRowConfirmations(viewModel: viewModel))
  }
}

private struct ContactRowConfirmations: ViewModifier {
  @Bindable var viewModel: ContactsViewModel

  func body(content: Content) -> some View {
    content
      .alert(
        L10n.Contacts.Contacts.Detail.Alert.Delete.title(viewModel.deleteConfirmation?.type.localizedName ?? ""),
        isPresented: isPresented($viewModel.deleteConfirmation),
        presenting: viewModel.deleteConfirmation
      ) { contact in
        Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
        Button(L10n.Contacts.Contacts.Common.delete, role: .destructive) {
          Task { await viewModel.deleteContact(contact) }
        }
      } message: { contact in
        Text(L10n.Contacts.Contacts.Detail.Alert.Delete.message(contact.displayName))
      }
      .alert(
        L10n.Contacts.Contacts.Detail.Alert.Block.title,
        isPresented: isPresented($viewModel.blockConfirmation),
        presenting: viewModel.blockConfirmation
      ) { contact in
        Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
        Button(L10n.Contacts.Contacts.Action.block, role: .destructive) {
          Task { await viewModel.toggleBlocked(contact: contact) }
        }
      } message: { contact in
        Text(L10n.Contacts.Contacts.Detail.Alert.Block.message(contact.displayName))
      }
      .alert(
        L10n.Contacts.Contacts.ViewModel.deleteTimedOutTitle,
        isPresented: isPresented($viewModel.deleteTimedOut),
        presenting: viewModel.deleteTimedOut
      ) { _ in
        Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
        Button(L10n.Localizable.Common.tryAgain) {
          Task { await viewModel.retryTimedOutDelete() }
        }
      } message: { _ in
        Text(L10n.Contacts.Contacts.ViewModel.removeTimedOut)
      }
  }

  private func isPresented(_ item: Binding<ContactDTO?>) -> Binding<Bool> {
    Binding(
      get: { item.wrappedValue != nil },
      set: { if !$0 { item.wrappedValue = nil } }
    )
  }
}
