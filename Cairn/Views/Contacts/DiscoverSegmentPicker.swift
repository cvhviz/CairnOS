import SwiftUI

/// The Heard list's filter, as a segmented control like the Saved list's.
struct DiscoverSegmentPicker: View {
  @Binding var selection: DiscoverSegment
  let isSearching: Bool

  var body: some View {
    GlassFilterBar(
      selection: $selection,
      isSearching: isSearching,
      pickerLabel: L10n.Contacts.Contacts.Discovery.Segment.pickerLabel,
      title: { $0.localizedTitle },
      alwaysSegmented: true
    )
  }
}
