import CairnServices
import SwiftUI

struct ChatsStackLayout<RootContent: View>: View {
  @Environment(\.appState) private var appState

  let viewModel: ChatViewModel
  @Binding var navigationPath: NavigationPath
  @Binding var activeRoute: ChatRoute?

  @ViewBuilder let rootContent: RootContent

  var body: some View {
    NavigationStack(path: $navigationPath) {
      rootContent
        // The bar's backdrop always drawn, so it doesn't come and go with the pulled-down search
        // and every tab's top reads alike (the user, 2026-11-08).
        .tabTopBarBackdrop()
        .navigationDestination(for: ChatRoute.self) { route in
          Group {
            switch route {
            case let .direct(contact):
              ChatConversationView(
                conversationType: .dm(contact),
                parentViewModel: viewModel,
                coordinatorRegistry: appState.ensureChatCoordinatorRegistry()
              )
              .id(contact.id)

            case let .channel(channel):
              ChatConversationView(
                conversationType: .channel(channel),
                parentViewModel: viewModel,
                coordinatorRegistry: appState.ensureChatCoordinatorRegistry()
              )
              .id(channel.id)

            case let .room(session):
              RoomConversationView(session: session)
                .id(session.id)
            }
          }
          .onAppear {
            activeRoute = route
            // Shared with the iPad split, so a resize to regular width keeps this chat open.
            appState.navigation.chatsSelectedRoute = route
            appState.navigation.tabBarVisibility = .hidden
          }
        }
        .onChange(of: navigationPath) { _, newPath in
          if newPath.isEmpty {
            activeRoute = nil
            appState.navigation.chatsSelectedRoute = nil
            appState.navigation.tabBarVisibility = .visible
            viewModel.requestConversationReload()
          }
        }
        .toolbarVisibility(appState.navigation.tabBarVisibility, for: .tabBar)
    }
  }
}
