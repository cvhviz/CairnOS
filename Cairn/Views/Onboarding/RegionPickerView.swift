import CairnServices
import SwiftUI

/// Country + state picker used in onboarding step 4 and Settings → Radio → Location.
/// Hides the state row for countries with no subdivision catalog.
struct RegionPickerView: View {
  @Binding var selection: RegionSelection?
  @State private var activeSheet: RegionPickerRows.Sheet?

  var body: some View {
    // The onboarding page is the plain system background, where the grouped card color would
    // vanish, so the card takes the secondary fill. It keeps the flexible height the form had,
    // so the step's buttons stay at the bottom.
    VStack {
      ContentCard {
        RegionPickerRows(selection: $selection, activeSheet: $activeSheet)
      }
      .cardFill(Color(.secondarySystemBackground))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, CardStyle.pageInset)
    .frame(maxHeight: .infinity, alignment: .top)
    .regionPickerSheet($activeSheet, selection: $selection)
  }
}
