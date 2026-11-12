import SwiftUI

/// The Comm tab's filter, as a segmented control like the Nodes tab's.
struct ChatFilterPicker: View {
  @Binding var selection: ChatFilter
  /// A search is typed: the filter steps aside, as the Nodes filter does.
  let isSearching: Bool

  var body: some View {
    GlassFilterBar(
      selection: $selection,
      isSearching: isSearching,
      pickerLabel: L10n.Chats.Chats.Filter.title,
      title: { $0.localizedName },
      alwaysSegmented: true
    )
  }
}
