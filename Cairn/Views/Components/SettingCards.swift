import SwiftUI

// The card form: settings pages built from cards instead of grouped list rows. Each control is its
// own rounded card (the same surface as every other card in the app, glass over a background),
// grouped under a section title with an optional "i". Use these on every settings page and
// sub-page so toggles, pickers, fields and actions read as one family with the tiles.

/// A scrolling page of `CardFormSection`s on the card canvas.
struct CardForm<Content: View>: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.isInSettings) private var isInSettings
  @ViewBuilder let content: () -> Content

  init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
  }

  var body: some View {
    ScrollView {
      // Settings spaces its grouped sections a little further apart, as the iPhone's Settings does.
      VStack(alignment: .leading, spacing: isInSettings ? 28 : 20) {
        content()
      }
      .padding(.horizontal, CardStyle.pageInset)
      .padding(.vertical, CardStyle.formVerticalInset)
    }
    .cardCanvas(theme)
  }
}

/// A titled group of setting cards. The title takes an `InfoButton` for explanations; `footer` is
/// for short lines that must stay visible (a destructive consequence, a permission state).
///
/// Inside Settings (`isInSettings`) the group draws as the iPhone's Settings does: its cards become
/// rows of one rounded card, with a separator between each, under a small capitalised header. A
/// child marked `settingsStandalone()` (a grid of tiles, a header card) keeps its own look, outside
/// the rows. Elsewhere each card stays a card of its own.
struct CardFormSection<Content: View>: View {
  let title: String?
  let info: String?
  let footer: String?
  @ViewBuilder let content: () -> Content
  @Environment(\.isInSettings) private var isInSettings

  init(
    _ title: String? = nil,
    info: String? = nil,
    footer: String? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.info = info
    self.footer = footer
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        Group {
          if let info {
            InfoHeader(title, info: info)
          } else {
            Text(title)
          }
        }
        // Settings: the iPhone Settings header, small capitals in line with the rows' text.
        .font(isInSettings ? .footnote : .subheadline.weight(.semibold))
        .textCase(isInSettings ? .uppercase : nil)
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, isInSettings ? CardStyle.rowInset : 4)
        .accessibilityAddTraits(.isHeader)
      } else if let info {
        HStack {
          Spacer()
          InfoButton(info)
        }
      }

      if isInSettings {
        GroupedSettingsRows(content: content)
      } else {
        VStack(spacing: CardStyle.spacing) {
          content()
        }
      }

      if let footer, !footer.isEmpty {
        Text(footer)
          .font(.footnote)
          .foregroundStyle(Color.secondary)
          .padding(.horizontal, isInSettings ? CardStyle.rowInset : 4)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A Settings section's children as the iPhone's Settings draws them: each run of rows on one card
/// with separators between, and a `settingsStandalone()` child on its own between the runs.
private struct GroupedSettingsRows<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    // The row flag goes on the content as it is declared, not on the subviews below: a modifier
    // on a resolved subview does not reach into a child declared directly in the section (only
    // into one a `ForEach` builds). Standalone children turn it off again for themselves.
    Group(subviews: content().environment(\.isGroupedRow, true)) { subviews in
      VStack(spacing: CardStyle.spacing) {
        ForEach(Self.runs(of: subviews)) { run in
          if run.isStandalone {
            ForEach(run.subviews) { $0 }
          } else {
            VStack(spacing: 0) {
              ForEach(run.subviews) { subview in
                subview
                if subview.id != run.subviews.last?.id {
                  Divider()
                    .padding(.leading, CardStyle.rowSeparatorInset)
                }
              }
            }
            .environment(\.isGroupedRow, true)
            .background { CardBackground() }
            .clipShape(CardStyle.shape)
          }
        }
      }
    }
  }

  /// Consecutive children of the same kind: rows that share a card, or standalone children.
  private struct Run: Identifiable {
    var id: Subview.ID
    var isStandalone: Bool
    var subviews: [Subview]
  }

  private static func runs(of subviews: SubviewsCollection) -> [Run] {
    var runs: [Run] = []
    for subview in subviews {
      let isStandalone = subview.containerValues.isSettingsStandalone
      if let last = runs.indices.last, runs[last].isStandalone == isStandalone {
        runs[last].subviews.append(subview)
      } else {
        runs.append(Run(id: subview.id, isStandalone: isStandalone, subviews: [subview]))
      }
    }
    return runs
  }
}

/// The leading part every setting card shares: an icon tile, the title, and an optional line of
/// detail under it. `isBusy` turns the icon tile into a same-size spinner while the setting is
/// being sent, as `BusyActionCardLabel` does, so the title doesn't move.
struct SettingCardLabel: View {
  let title: String
  let systemImage: String?
  let color: Color
  let subtitle: String?
  let isBusy: Bool

  /// Matches `IconTile`'s scaled size.
  @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 28

  init(
    _ title: String,
    systemImage: String? = nil,
    color: Color = .accentColor,
    subtitle: String? = nil,
    isBusy: Bool = false
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    self.subtitle = subtitle
    self.isBusy = isBusy
  }

  var body: some View {
    HStack(spacing: 12) {
      if let systemImage {
        if isBusy {
          ProgressView()
            .frame(width: tileSize, height: tileSize)
        } else {
          IconTile(systemImage: systemImage, color: color)
            .accessibilityHidden(true)
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
          .foregroundStyle(Color.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

/// An on/off setting as a card. The whole card is the switch for VoiceOver and taps.
struct ToggleCard: View {
  let title: String
  let systemImage: String?
  let color: Color
  let subtitle: String?
  /// The change is being sent: the icon tile turns into a spinner (`SettingCardLabel`).
  let isBusy: Bool
  @Binding var isOn: Bool

  init(
    _ title: String,
    systemImage: String? = nil,
    color: Color = .accentColor,
    subtitle: String? = nil,
    isBusy: Bool = false,
    isOn: Binding<Bool>
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    self.subtitle = subtitle
    self.isBusy = isBusy
    _isOn = isOn
  }

  var body: some View {
    Toggle(isOn: $isOn) {
      SettingCardLabel(title, systemImage: systemImage, color: color, subtitle: subtitle, isBusy: isBusy)
    }
    .cardSurface(padding: 12)
  }
}

/// A choice among options as a card, with the current value and a menu.
struct PickerCard<Value: Hashable, Options: View>: View {
  let title: String
  let systemImage: String?
  let color: Color
  let subtitle: String?
  @Binding var selection: Value
  @ViewBuilder let options: () -> Options

  init(
    _ title: String,
    systemImage: String? = nil,
    color: Color = .accentColor,
    subtitle: String? = nil,
    selection: Binding<Value>,
    @ViewBuilder options: @escaping () -> Options
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    self.subtitle = subtitle
    _selection = selection
    self.options = options
  }

  var body: some View {
    HStack(spacing: 8) {
      SettingCardLabel(title, systemImage: systemImage, color: color, subtitle: subtitle)
      Spacer(minLength: 8)
      Picker(title, selection: $selection, content: options)
        .pickerStyle(.menu)
        .labelsHidden()
    }
    .cardSurface(padding: 12)
  }
}

/// A button as a card: an action that happens here (Reboot, Clear, Export) rather than a page it
/// opens. Destructive actions draw their title in red.
struct ActionCard: View {
  let title: String
  let systemImage: String?
  let color: Color
  let subtitle: String?
  let role: ButtonRole?
  let action: () -> Void

  init(
    _ title: String,
    systemImage: String? = nil,
    color: Color = .accentColor,
    subtitle: String? = nil,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    self.subtitle = subtitle
    self.role = role
    self.action = action
  }

  var body: some View {
    Button(role: role, action: action) {
      HStack(spacing: 12) {
        if let systemImage {
          IconTile(systemImage: systemImage, color: role == .destructive ? .red : color)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.body)
            .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
          if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.footnote)
              .foregroundStyle(Color.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .cardSurface(padding: 12)
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
  }
}

/// A read-only value as a card: a title on the left and its value on the right.
struct ValueCard: View {
  let title: String
  let systemImage: String?
  let color: Color
  let value: String

  init(_ title: String, systemImage: String? = nil, color: Color = .accentColor, value: String) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    self.value = value
  }

  var body: some View {
    HStack(spacing: 8) {
      SettingCardLabel(title, systemImage: systemImage, color: color)
      Spacer(minLength: 8)
      Text(value)
        .foregroundStyle(Color.secondary)
        .multilineTextAlignment(.trailing)
    }
    .cardSurface(padding: 12)
    .accessibilityElement(children: .combine)
  }
}

/// Free-form content (a text field, a slider, a stepper, a list of rows) on one card, under a title.
struct ContentCard<Content: View>: View {
  let title: String?
  let systemImage: String?
  let color: Color
  @ViewBuilder let content: () -> Content

  init(
    _ title: String? = nil,
    systemImage: String? = nil,
    color: Color = .accentColor,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let title {
        SettingCardLabel(title, systemImage: systemImage, color: color)
      }
      content()
    }
    .cardSurface(padding: 12)
  }
}
