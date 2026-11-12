import SwiftUI

// Fold-away cards for the repeater and room server pages. Their settings and readings are read
// from the node over the mesh, so each group stays closed (and unrequested) until opened. Built on
// the card form (`CardForm`, `SettingCardLabel`) so these pages read as the same family as Settings.

/// A card with a title row that opens and closes the content under it, on the same card.
///
/// The title row is the toggle; `accessory` sits between it and the chevron and takes its own
/// taps (a reload button, a count, an "i"), which a control inside a `DisclosureGroup` label
/// wouldn't reliably do outside a `List`. Pass `hasContent: false` while there's nothing to show
/// inside, for groups whose readings follow the card as tiles of their own.
struct NodeDisclosureCard<Accessory: View, Content: View>: View {
  let title: String
  let systemImage: String?
  let color: Color
  @Binding var isExpanded: Bool
  let hasContent: Bool
  @ViewBuilder let accessory: () -> Accessory
  @ViewBuilder let content: () -> Content

  init(
    _ title: String,
    systemImage: String? = nil,
    color: Color = .accentColor,
    isExpanded: Binding<Bool>,
    hasContent: Bool = true,
    @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    _isExpanded = isExpanded
    self.hasContent = hasContent
    self.accessory = accessory
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button(action: toggle) {
          HStack(spacing: 8) {
            SettingCardLabel(title, systemImage: systemImage, color: color)
            Spacer(minLength: 0)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(
          isExpanded ? L10n.Chats.Chats.Message.Action.expanded : L10n.Chats.Chats.Message.Action.collapsed
        )

        accessory()

        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .contentShape(.rect)
          .onTapGesture(perform: toggle)
          .accessibilityHidden(true)
      }

      if isExpanded, hasContent {
        VStack(alignment: .leading, spacing: 10) {
          content()
        }
        .padding(.top, 12)
      }
    }
    .cardSurface(padding: 12)
  }

  private func toggle() {
    withAnimation(.snappy) { isExpanded.toggle() }
  }
}

/// A node settings group that reads its values from the node the first time it's opened (or on
/// appear when it starts open), with a reload button once loaded and a retry when the read failed.
/// A settings card that loads its fields when first opened: the fields inside show their own
/// "Loading…" placeholders until their values arrive.
struct ExpandableSettingsCard<Content: View>: View {
  let title: String
  let icon: String
  let color: Color
  /// An explanation behind an "i" beside the title.
  var info: String?
  /// False for a group whose values follow the card as tiles: the card then opens only to show
  /// a failed load.
  var hasContent: Bool

  @Binding var isExpanded: Bool
  let isLoaded: () -> Bool
  @Binding var isLoading: Bool
  @Binding var hasError: Bool
  let onLoad: () async -> Void
  @ViewBuilder let content: () -> Content

  init(
    title: String,
    icon: String,
    color: Color,
    info: String? = nil,
    hasContent: Bool = true,
    isExpanded: Binding<Bool>,
    isLoaded: @escaping () -> Bool,
    isLoading: Binding<Bool>,
    hasError: Binding<Bool>,
    onLoad: @escaping () async -> Void,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.icon = icon
    self.color = color
    self.info = info
    self.hasContent = hasContent
    _isExpanded = isExpanded
    self.isLoaded = isLoaded
    _isLoading = isLoading
    _hasError = hasError
    self.onLoad = onLoad
    self.content = content
  }

  var body: some View {
    NodeDisclosureCard(
      title,
      systemImage: icon,
      color: color,
      isExpanded: $isExpanded,
      hasContent: hasContent || (hasError && !isLoaded())
    ) {
      if let info {
        InfoButton(info, title: title)
      }
      SectionReloadButton(
        isLoading: isLoading,
        isLoaded: isExpanded && isLoaded(),
        hasError: false,
        isDisabled: false,
        accessibilityLabel: L10n.Localizable.Common.reloadSection(title),
        onReload: onLoad
      )
    } content: {
      content()

      if hasError, !isLoaded() {
        NodeCardLoadFailure { await onLoad() }
      }
    }
    .onChange(of: isExpanded) { _, expanded in
      if expanded, !isLoaded(), !isLoading {
        Task { await onLoad() }
      }
    }
    .task {
      // onChange only fires on a change, so a group that starts open loads here.
      if isExpanded, !isLoaded(), !isLoading {
        await onLoad()
      }
    }
  }
}

/// "Failed to load" with a Try Again button, inside a fold-away card. `message` says why, when
/// the caller has a user-facing reason (a timeout, a firmware error).
struct NodeCardLoadFailure: View {
  var message: String?
  let onRetry: () async -> Void

  var body: some View {
    VStack(spacing: 12) {
      VStack(spacing: 4) {
        Label(L10n.Localizable.Common.Error.failedToLoad, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        if let message {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .accessibilityElement(children: .combine)
      Button(L10n.Localizable.Common.tryAgain) {
        Task { await onRetry() }
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }
}

/// A row inside a settings card: the title on the left and a field, menu or value on the right.
struct CardFieldRow<Trailing: View>: View {
  let title: String
  /// Hides the visible title from VoiceOver when the trailing control already carries it (a
  /// picker labelled with the same title), so it isn't read twice.
  var hidesTitleFromAccessibility = false
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
        .foregroundStyle(Color.primary)
        .accessibilityHidden(hidesTitleFromAccessibility)
      Spacer(minLength: 8)
      trailing()
    }
  }
}

/// A short status line inside a fold-away card: a spinner while loading, an error, or an empty note.
struct NodeCardStatusLine: View {
  enum Kind {
    case loading
    case error(String)
    case note(String)
  }

  let kind: Kind

  var body: some View {
    switch kind {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity)
    case let .error(message):
      Text(message)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    case let .note(message):
      Text(message)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#Preview {
  @Previewable @State var isExpanded = true
  @Previewable @State var isLoading = false
  @Previewable @State var hasError = false
  @Previewable @State var data: String?

  CardForm {
    CardFormSection {
      ExpandableSettingsCard(
        title: "Device Info",
        icon: "info.circle",
        color: .gray,
        isExpanded: $isExpanded,
        isLoaded: { data != nil },
        isLoading: $isLoading,
        hasError: $hasError,
        onLoad: {
          isLoading = true
          try? await Task.sleep(for: .seconds(1))
          data = "Loaded!"
          isLoading = false
        }
      ) {
        CardFieldRow(title: "Value") {
          Text(data ?? "—")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
