import CairnServices
import SwiftUI

// The pieces the channel and room info sheets share: a compact identity header and a row of
// action cards for the things people change most (favorite, notifications, share, open a page),
// so the sheet opens on what matters without scrolling past a large avatar and stacked rows.

/// Compact identity header: small avatar beside the name and one line of context.
/// Sits at the top of the sheet's card page (or a clear `List` row); reports its height so the inline title reveals once it scrolls away.
struct ConversationInfoHeader<Avatar: View>: View {
  let title: String
  let subtitle: String
  @Binding var measuredHeight: CGFloat
  @ViewBuilder let avatar: Avatar

  var body: some View {
    HStack(spacing: 14) {
      avatar
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title3.bold())
          .lineLimit(2)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .scrollRevealHeaderHeight(into: $measuredHeight)
  }
}

/// Size of the avatar in `ConversationInfoHeader`.
enum ConversationInfoLayout {
  static let avatarSize: CGFloat = 56
  /// Gap between the header and the action cards below it.
  static let headerSpacing: CGFloat = 16
}

/// Lays action cards out side by side with equal widths; stacks them at accessibility text
/// sizes, where a third or a quarter of the width can't hold the label.
struct ConversationActionCardRow<Content: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ViewBuilder let content: Content

  var body: some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: CardStyle.spacing))
      : AnyLayout(HStackLayout(alignment: .top, spacing: CardStyle.spacing))
    layout {
      content
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// The face of an action card: glyph over a short label. `isActive` tints the glyph with the
/// accent (favorite on, a non-default notification level) so state reads at a glance; the label
/// or the accessibility value always carries the same meaning.
struct ConversationActionCardLabel<Title: View>: View {
  @Environment(\.appTheme) private var theme
  let systemImage: String
  var isActive = false
  @ViewBuilder let title: Title

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(isActive ? AnyShapeStyle(theme.accentColor) : AnyShapeStyle(.primary))
        .contentTransition(.symbolEffect(.replace))
        .frame(height: 24)

      title
        .font(.caption.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity)
    .cardSurface(padding: 10)
    .cardInteractionShape()
  }
}

extension ConversationActionCardLabel where Title == Text {
  init(_ title: String, systemImage: String, isActive: Bool = false) {
    self.init(systemImage: systemImage, isActive: isActive) { Text(title) }
  }
}

/// A `Toggle` drawn as an action card, so VoiceOver still reports it as a switch with its state.
struct ActionCardToggleStyle: ToggleStyle {
  let systemImage: String
  let activeSystemImage: String

  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      ConversationActionCardLabel(
        systemImage: configuration.isOn ? activeSystemImage : systemImage,
        isActive: configuration.isOn
      ) {
        configuration.label
      }
    }
    .buttonStyle(.plain)
  }
}

/// Favorite as an action card (a switch for VoiceOver).
struct FavoriteActionCard: View {
  @Binding var isFavorite: Bool

  var body: some View {
    Toggle(L10n.Chats.Chats.Action.favorite, isOn: $isFavorite)
      .toggleStyle(ActionCardToggleStyle(systemImage: "star", activeSystemImage: "star.fill"))
  }
}

/// Notification level as an action card: the card shows the current level, and tapping it
/// opens a menu of the levels this conversation type supports.
struct NotificationLevelActionCard: View {
  @Binding var selection: NotificationLevel
  let availableLevels: [NotificationLevel]

  var body: some View {
    Menu {
      Picker(L10n.Chats.Chats.NotificationLevel.label, selection: $selection) {
        ForEach(availableLevels, id: \.self) { level in
          Label(level.localizedName, systemImage: level.iconName).tag(level)
        }
      }
      .pickerStyle(.inline)
    } label: {
      ConversationActionCardLabel(
        selection.localizedName,
        systemImage: selection.iconName,
        isActive: selection != .all
      )
    }
    // Plain button styling keeps each card its own tap target inside the shared list row.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Chats.Chats.NotificationLevel.label)
    .accessibilityValue(selection.localizedAccessibilityDescription)
    .accessibilityHint(L10n.Chats.Chats.NotificationLevel.hint)
  }
}

/// An action card that runs `action` (opens a page or a sheet).
struct ConversationActionCard: View {
  let title: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ConversationActionCardLabel(title, systemImage: systemImage)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}

extension View {
  /// Puts the receiver in a clear, edge-to-edge-of-the-inset `List` row so cards and the
  /// header draw on the canvas rather than inside a grouped cell.
  func conversationInfoClearRow() -> some View {
    listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
  }
}

/// A destructive action card (Clear Messages, Delete, Leave) whose icon turns into a spinner
/// while the action runs. The button's label is just the title, so UI tests and VoiceOver find
/// it by name.
struct ConversationDestructiveActionCard: View {
  let title: String
  let systemImage: String
  var isBusy = false
  let action: () -> Void

  var body: some View {
    Button(role: .destructive, action: action) {
      HStack(spacing: 12) {
        if isBusy {
          ProgressView()
            .frame(width: 28, height: 28)
        } else {
          IconTile(systemImage: systemImage, color: .red)
            .accessibilityHidden(true)
        }
        Text(title)
          .font(.body)
          .foregroundStyle(Color.red)
        Spacer(minLength: 0)
      }
      .cardSurface(padding: 12)
      .cardInteractionShape()
      .dimmedWhenDisabled()
    }
    .buttonStyle(.plain)
  }
}

/// A failed action's message with Try Again, as a card in the sheet's card page.
struct ConversationInfoErrorCard: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      Button(L10n.Localizable.Common.tryAgain, action: onRetry)
    }
    .cardSurface(padding: 12)
  }
}

/// A failed action's message as a card, for the create and join forms.
struct InlineErrorCard: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .foregroundStyle(.red)
      .fixedSize(horizontal: false, vertical: true)
      .cardSurface(padding: 12)
  }
}
