import CairnServices
import SwiftUI

struct UnreadBadges: View {
  @Environment(\.appTheme) private var theme

  let unreadCount: Int
  var unreadMentionCount: Int = 0
  var notificationLevel: NotificationLevel = .all

  // `.tint` follows the theme's chrome tint (system blue on the default theme).
  private var mentionBadgeStyle: AnyShapeStyle {
    notificationLevel == .muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)
  }

  private var unreadBadgeStyle: AnyShapeStyle {
    notificationLevel == .all ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
  }

  // Tint fills pair with the theme's outgoing text color: several themes have a light
  // dark-mode accent that white cannot clear. The `.secondary` fill keeps white.
  private var mentionBadgeForeground: Color {
    notificationLevel == .muted ? .white : theme.outgoingTextColor
  }

  private var unreadBadgeForeground: Color {
    notificationLevel == .all ? theme.outgoingTextColor : .white
  }

  /// What VoiceOver reads for the badges: "mentions you" and "N unread", or nothing.
  var accessibilityLabel: String {
    var parts: [String] = []
    if unreadMentionCount > 0 { parts.append(L10n.Chats.Chats.Unread.mentionAccessibility) }
    if unreadCount > 0 { parts.append(L10n.Chats.Chats.Unread.countAccessibility(unreadCount)) }
    return parts.joined(separator: ", ")
  }

  var body: some View {
    HStack(spacing: 4) {
      if unreadMentionCount > 0 {
        Text("@")
          .font(.caption.bold())
          .foregroundStyle(mentionBadgeForeground)
          .frame(width: 18, height: 18)
          .background(mentionBadgeStyle, in: .circle)
          .accessibilityHidden(true)
      }

      if unreadCount > 0 {
        Text(unreadCount, format: .number)
          .font(.caption2)
          .bold()
          .fontDesign(.rounded)
          .monospacedDigit()
          .contentTransition(.numericText(value: Double(unreadCount)))
          .foregroundStyle(unreadBadgeForeground)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .frame(minWidth: 18)
          .background(unreadBadgeStyle, in: .capsule)
          .animation(.snappy, value: unreadCount)
          .accessibilityHidden(true)
      }
    }
    // One element: the numeral alone would read as a bare number.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHidden(unreadCount == 0 && unreadMentionCount == 0)
  }
}
