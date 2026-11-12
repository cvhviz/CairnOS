import CairnServices
import SwiftUI

/// Sheet explaining distance calculation details and limitations
struct DistanceInfoSheetView: View {
  let result: TraceResult
  @Bindable var viewModel: TracePathViewModel
  @Binding var showingDistanceInfo: Bool

  var body: some View {
    NavigationStack {
      CardForm {
        if viewModel.isDistanceUsingFallback {
          explanationCard(
            L10n.Contacts.Contacts.Results.partialDistanceHeader,
            systemImage: "location.slash",
            color: .orange,
            text: L10n.Contacts.Contacts.Results.partialDistanceExplanation
          )
          explanationCard(
            L10n.Contacts.Contacts.Results.fullPathHeader,
            systemImage: "lightbulb",
            color: .yellow,
            text: L10n.Contacts.Contacts.Results.fullPathTip
          )
        } else if result.hops.count(where: { !$0.isStartNode && !$0.isEndNode }) < 2 {
          explanationCard(text: L10n.Contacts.Contacts.Results.needsRepeaters)
        } else if viewModel.repeatersWithoutLocation.isEmpty {
          explanationCard(text: L10n.Contacts.Contacts.Results.distanceError)
        } else {
          explanationCard(text: L10n.Contacts.Contacts.Results.missingLocations)
          CardFormSection(L10n.Contacts.Contacts.Results.repeatersWithoutLocations) {
            ContentCard {
              ForEach(Array(viewModel.repeatersWithoutLocation.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                  Divider()
                }
                Text(name)
              }
            }
          }
        }
      }
      .flashingNavigationTitle(viewModel.isDistanceUsingFallback ? L10n.Contacts.Contacts.Results.distanceInfoTitlePartial : L10n.Contacts.Contacts.Results.distanceInfoTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(L10n.Contacts.Contacts.Common.done) {
            showingDistanceInfo = false
          }
        }
      }
    }
  }

  private func explanationCard(
    _ title: String? = nil,
    systemImage: String? = nil,
    color: Color = .accentColor,
    text: String
  ) -> some View {
    ContentCard(title, systemImage: systemImage, color: color) {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
