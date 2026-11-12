import SwiftUI

/// Search for a tab's root list (Nodes' Saved and Heard, Comm) that stays out of the way: no
/// toolbar button and no standing field, but a field at the very top of the list that each visit
/// opens scrolled past, so it shows only when the list is pulled down. Put the list's content in
/// it, inside the list's `ScrollView` and `ScrollViewReader`.
struct PullDownSearch<Content: View>: View {
  @Binding var text: String
  let prompt: String
  let proxy: ScrollViewProxy
  /// Bumped to focus the field (⌘F); see `PullDownSearchField`.
  var focusRequest = 0
  @ViewBuilder let content: () -> Content

  /// The field's row: what a short list is lengthened by so the field can still scroll away.
  static var fieldHeight: CGFloat { 52 }
  /// The field itself, to scroll it back into view (⌘F).
  static var fieldID: String { "pullDownSearch.field" }
  /// Just under the field: where the list opens.
  static var listTopID: String { "pullDownSearch.listTop" }

  var body: some View {
    ZStack(alignment: .top) {
      // At least the visible height plus the field, so even a list of a few rows scrolls far
      // enough to tuck the field away.
      Color.clear
        .containerRelativeFrame(.vertical) { length, _ in length + Self.fieldHeight }
        .accessibilityHidden(true)
      VStack(spacing: 0) {
        PullDownSearchField(text: $text, prompt: prompt, focusRequest: focusRequest)
          .frame(height: Self.fieldHeight)
          .id(Self.fieldID)
          // Faded out while it's tucked under the bar, so its text doesn't show through the glass.
          .scrollTransition(.interactive.threshold(.visible(0.9))) { field, phase in
            field.opacity(phase.isIdentity ? 1 : 0)
          }
        Color.clear
          .frame(height: 0)
          .id(Self.listTopID)
        content()
      }
    }
    .onAppear {
      // Hidden on each visit, unless a search is still under way.
      guard text.isEmpty else { return }
      Task { @MainActor in proxy.scrollTo(Self.listTopID, anchor: .top) }
    }
  }
}

/// `PullDownSearch` for the `List` the node lists use before iOS 27 (`NodeListHosting.usesList`): the
/// field as the list's first row and the anchor under it as its second, opened scrolled past
/// the same way. A list too short to scroll keeps the field in view, which `List` can't help.
struct PullDownSearchRows: View {
  @Binding var text: String
  let prompt: String
  let proxy: ScrollViewProxy
  var focusRequest = 0

  var body: some View {
    PullDownSearchField(text: $text, prompt: prompt, focusRequest: focusRequest)
      .frame(height: PullDownSearch<EmptyView>.fieldHeight)
      .id(PullDownSearch<EmptyView>.fieldID)
      .nodeListRow()
      .onAppear {
        guard text.isEmpty else { return }
        Task { @MainActor in proxy.scrollTo(PullDownSearch<EmptyView>.listTopID, anchor: .top) }
      }
    Color.clear
      .frame(height: 0)
      .id(PullDownSearch<EmptyView>.listTopID)
      .nodeListRow()
  }
}

/// The search field itself: a capsule with the magnifier, a clear button once there's text, and
/// Cancel while it's in use, which clears the search and puts the keyboard away.
struct PullDownSearchField: View {
  @Binding var text: String
  let prompt: String
  /// Each change focuses the field: the list bumps it after scrolling the field into view (⌘F).
  var focusRequest = 0
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField(prompt, text: $text)
          .focused($isFocused)
          .submitLabel(.search)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        if !text.isEmpty {
          Button {
            text = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(L10n.Contacts.Contacts.Trace.Map.clear)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(Color(.tertiarySystemFill), in: Capsule())

      if isFocused || !text.isEmpty {
        Button(L10n.Localizable.Common.cancel) {
          text = ""
          isFocused = false
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .padding(.horizontal, CardStyle.pageInset)
    .animation(.snappy, value: isFocused || !text.isEmpty)
    .onChange(of: focusRequest) { _, _ in
      isFocused = true
    }
  }
}
