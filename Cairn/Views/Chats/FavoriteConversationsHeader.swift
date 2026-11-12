import SwiftUI

/// The Favorites group's header on the conversation list: its title and count, and a chevron
/// that turns as the group opens and closes. The whole row is the toggle, and VoiceOver reads it
/// as one button ("Favorites, 3, Expanded"). Folded, it carries the group's unread badge, since
/// the rows that would show it are hidden ("Favorites, 3, 2 unread messages, Collapsed").
struct FavoriteConversationsHeader: View {
  let count: Int
  /// Unread messages in the folded group (`ConversationListSections.foldedUnreadCount`).
  var unreadCount = 0
  @Binding var isCollapsed: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 6) {
        Image(systemName: "star.fill")
          .foregroundStyle(.yellow)
        Text(L10n.Chats.Chats.Section.Favorites.title)
        Text(count, format: .number)
          .foregroundStyle(.tertiary)
        Spacer(minLength: 8)
        if unreadCount > 0 {
          UnreadBadges(unreadCount: unreadCount)
        }
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
      }
      // The card list's section header type (`CardFormSection` outside Settings).
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Color.secondary)
      .padding(.horizontal, 4)
      .frame(minHeight: 44)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    // The button's label already reads as one element; these replace its words with the count
    // spelled for VoiceOver and add the fold state. Header too, so the rotor's headings find it.
    .accessibilityLabel(L10n.Chats.Chats.Section.Favorites.accessibilityLabel(count))
    .accessibilityValue(accessibilityValue)
    .accessibilityAddTraits(.isHeader)
    .padding(.horizontal, CardStyle.pageInset)
  }

  /// The fold state, after the unread count when the badge shows.
  private var accessibilityValue: String {
    let state = isCollapsed ? L10n.Chats.Chats.Message.Action.collapsed : L10n.Chats.Chats.Message.Action.expanded
    guard unreadCount > 0 else { return state }
    return "\(L10n.Chats.Chats.ScrollButton.ScrollToBottom.accessibilityValue(unreadCount)), \(state)"
  }

  private func toggle() {
    withAnimation(reduceMotion ? nil : .snappy) { isCollapsed.toggle() }
  }
}

#Preview {
  @Previewable @State var isCollapsed = false

  FavoriteConversationsHeader(count: 3, unreadCount: isCollapsed ? 2 : 0, isCollapsed: $isCollapsed)
}
