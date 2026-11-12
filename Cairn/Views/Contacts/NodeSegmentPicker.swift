import SwiftUI

/// The Nodes tab's filter, as a segmented control.
struct NodeSegmentPicker: View {
  @Binding var selection: NodeSegment
  let isSearching: Bool

  var body: some View {
    GlassFilterBar(
      selection: $selection,
      isSearching: isSearching,
      pickerLabel: L10n.Contacts.Contacts.Segment.pickerLabel,
      title: { $0.localizedTitle },
      alwaysSegmented: true
    )
  }
}
