import SwiftUI

/// Pushed view showing discovered regions as selectable cards; Add Selected adds the checked ones.
struct RegionDiscoveryResultsView: View {
  let sortedRegions: [String]
  let onAdd: ([String]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedRegions: Set<String>

  init(discoveredRegions: [String], onAdd: @escaping ([String]) -> Void) {
    // Same order as Manage Regions, so a name sits in the same place on both pages.
    let sorted = discoveredRegions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    sortedRegions = sorted
    self.onAdd = onAdd
    _selectedRegions = State(initialValue: Set(discoveredRegions))
  }

  var body: some View {
    CardForm {
      CardFormSection {
        ForEach(sortedRegions, id: \.self) { region in
          let isSelected = selectedRegions.contains(region)
          Button {
            toggleSelection(region)
          } label: {
            HStack {
              Text(region)
                .foregroundStyle(Color.primary)
              Spacer()
              // Trailing, as on the Manage Regions cards.
              if region.isPrivateRegion {
                Text(L10n.Chats.Chats.ChannelInfo.Region.private)
                  .font(.caption)
                  .foregroundStyle(.tertiary)
              }
              if isSelected {
                Image(systemName: "checkmark")
                  .fontWeight(.semibold)
                  .foregroundStyle(.tint)
                  .accessibilityHidden(true)
              }
            }
            .cardSurface(isSelected: isSelected, padding: 12)
            .cardInteractionShape()
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
      }

      CardFormSection {
        ActionCard(L10n.Chats.Chats.ChannelInfo.Region.addSelected, systemImage: "plus", color: .green) {
          onAdd(Array(selectedRegions))
          dismiss()
        }
        .dimmedWhenDisabled()
        .disabled(selectedRegions.isEmpty)
      }
    }
    .flashingNavigationTitle(L10n.Chats.Chats.ChannelInfo.Region.discover)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func toggleSelection(_ region: String) {
    if selectedRegions.contains(region) {
      selectedRegions.remove(region)
    } else {
      selectedRegions.insert(region)
    }
  }
}
