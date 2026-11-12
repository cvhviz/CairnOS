import SwiftUI

/// One radio setting as a card on Settings → Radio: what it is, its current value, and a line or
/// two of context, with a glyph that says how tapping edits it (a menu of choices, or an editor
/// sheet). Laid out like `MetricTile` so the page reads as the dashboard does, but a control:
/// it marks a value that's been changed and not yet applied, and takes an accessibility hint.
///
/// Only the label; the caller wraps it in the `Menu` or `Button` that edits the setting.
struct RadioSettingTile<Accessory: View>: View {
  enum EditStyle {
    /// Picks from a list in place (bandwidth, spreading factor, coding rate, hash size).
    case menu
    /// Opens an editor sheet (frequency, TX power).
    case sheet
  }

  let title: String
  let systemImage: String
  let value: String
  let captions: [String]
  let editStyle: EditStyle
  /// Edited here but not yet sent: flagged with a symbol and the "Not applied" caption, so the
  /// state doesn't rest on the symbol's color.
  let isPending: Bool
  let accessibilityHint: String?
  @ViewBuilder let accessory: () -> Accessory

  init(
    _ title: String,
    systemImage: String,
    value: String,
    captions: [String] = [],
    editStyle: EditStyle,
    isPending: Bool = false,
    accessibilityHint: String? = nil,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.title = title
    self.systemImage = systemImage
    self.value = value
    self.captions = captions
    self.editStyle = editStyle
    self.isPending = isPending
    self.accessibilityHint = accessibilityHint
    self.accessory = accessory
  }

  private var allCaptions: [String] {
    isPending ? [L10n.Settings.Radio.Tile.pending] + captions : captions
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
        Text(title)
          .lineLimit(1)
        Spacer(minLength: 0)
        if isPending {
          Image(systemName: "pencil.circle.fill")
            .foregroundStyle(Color.accentColor)
        }
        Image(systemName: editStyle == .menu ? "chevron.up.chevron.down" : "chevron.right")
          .fontWeight(.semibold)
          .foregroundStyle(Color(.tertiaryLabel))
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(Color.secondary)

      Text(value)
        .font(.title3.weight(.semibold))
        .foregroundStyle(Color.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(allCaptions, id: \.self) { caption in
        Text(caption)
          .font(.caption2)
          .foregroundStyle(caption == L10n.Settings.Radio.Tile.pending ? Color.accentColor : Color.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      accessory()
        .accessibilityHidden(true)
    }
    .cardSurface(padding: 10)
    .cardInteractionShape()
    .dimmedWhenDisabled()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(([value] + allCaptions).joined(separator: ", "))
    .accessibilityHint(accessibilityHint ?? "")
    .accessibilityAddTraits(.isButton)
  }
}

extension RadioSettingTile where Accessory == EmptyView {
  /// A tile with nothing under its captions. A separate init rather than a defaulted closure, which
  /// Swift can't use to infer the generic `Accessory`.
  init(
    _ title: String,
    systemImage: String,
    value: String,
    captions: [String] = [],
    editStyle: EditStyle,
    isPending: Bool = false,
    accessibilityHint: String? = nil
  ) {
    self.init(
      title,
      systemImage: systemImage,
      value: value,
      captions: captions,
      editStyle: editStyle,
      isPending: isPending,
      accessibilityHint: accessibilityHint
    ) {
      EmptyView()
    }
  }
}

extension View {
  /// Fades a card whose control is disabled (no radio, a write in flight). Cards set their own
  /// text colors, so they don't pick up the system's disabled look by themselves.
  func dimmedWhenDisabled() -> some View {
    modifier(DimmedWhenDisabled())
  }
}

private struct DimmedWhenDisabled: ViewModifier {
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    content.opacity(isEnabled ? 1 : 0.5)
  }
}

/// The Apply button for a card-form section whose edits are staged (radio parameters, auto-add):
/// a full-width card that spins while sending and checks off when done. The caller adds the
/// `radioDisabled` condition; the title greys out until there is something to send.
struct ApplyCard: View {
  let title: String
  let isLoading: Bool
  let showSuccess: Bool
  let canApply: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      AsyncActionLabel(isLoading: isLoading, showSuccess: showSuccess) {
        Text(title)
          .font(.body.weight(.semibold))
          .foregroundStyle(canApply ? Color.accentColor : .secondary)
          .transition(.opacity)
      }
      .frame(minHeight: 28)
      .cardSurface(padding: 12)
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}
