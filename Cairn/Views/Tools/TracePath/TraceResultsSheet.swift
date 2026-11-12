import CairnServices
import SwiftUI

/// Full-screen sheet displaying trace results
struct TraceResultsSheet: View {
  let result: TraceResult
  @Bindable var viewModel: TracePathViewModel
  @Environment(\.dismiss) private var dismiss

  // Save dialog state
  @State private var saveHapticTrigger = 0
  @State private var copyHapticTrigger = 0
  @State private var showingDistanceInfo = false
  @State private var lineOfSight: LineOfSightRequest?

  var body: some View {
    NavigationStack {
      CardForm {
        TraceResultsSectionView(
          result: result,
          viewModel: viewModel,
          saveHapticTrigger: $saveHapticTrigger,
          showingDistanceInfo: $showingDistanceInfo,
          onCheckLineOfSight: { origin, target in
            lineOfSight = LineOfSightRequest(origin: origin, target: target, contact: nil, discovered: nil)
          }
        )
        roundTripPathSection
      }
      .sheet(isPresented: $showingDistanceInfo) {
        DistanceInfoSheetView(result: result, viewModel: viewModel, showingDistanceInfo: $showingDistanceInfo)
          .presentationDetents([.medium])
          .presentationDragIndicator(.visible)
      }
      .navigationDestination(item: $lineOfSight) { request in
        LineOfSightView(from: request.origin, to: request.target)
          .flashingNavigationTitle(L10n.Tools.Tools.lineOfSight)
          .navigationBarTitleDisplayMode(.inline)
      }
      .navigationDestination(for: TracePathRoute.self) { route in
        switch route {
        case let .savedPathDetail(savedPath):
          SavedPathDetailView(savedPath: savedPath)
        }
      }
      .flashingNavigationTitle(L10n.Contacts.Contacts.Results.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          ShareLink(item: TraceExport.summary(for: result)) {
            Label(L10n.Tools.Tools.TracePath.Share.summary, systemImage: "square.and.arrow.up")
          }
          .accessibilityIdentifier("traceResults.share")
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(L10n.Contacts.Contacts.Results.dismiss, systemImage: "xmark") {
            dismiss()
          }
        }
      }
      .sensoryFeedback(.success, trigger: saveHapticTrigger)
      .sensoryFeedback(.success, trigger: copyHapticTrigger)
    }
  }

  // MARK: - Outbound Path Section

  private var roundTripPathSection: some View {
    CardFormSection(L10n.Contacts.Contacts.Trace.List.roundTripPath) {
      HStack {
        Text(result.tracedPathString)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)

        Spacer()

        Button(L10n.Contacts.Contacts.Trace.List.copyPath, systemImage: "doc.on.doc") {
          copyHapticTrigger += 1
          UIPasteboard.general.string = result.tracedPathString
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
      }
      .cardSurface()
    }
  }
}
