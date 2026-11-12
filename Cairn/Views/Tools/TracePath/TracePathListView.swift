import CairnServices
import SwiftUI

/// List-based view for building trace paths. Hops are added through the shared
/// `AddHopPickerView`, pushed onto the Tools navigation stack via the Add Hop CTA.
/// Every hop and option is its own card row; it stays a `List` in edit mode so hops keep
/// their drag handles and delete controls.
struct TracePathListView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: TracePathViewModel

  @Binding var dragHapticTrigger: Int
  @Binding var copyHapticTrigger: Int
  @Binding var showingClearConfirmation: Bool
  @Binding var presentedResult: TraceResult?
  @Binding var showJumpToPath: Bool

  /// Drives the pushed Add Hop picker via `.navigationDestination(item:)`.
  @State private var insertionIntent: AddHopIntent?

  var body: some View {
    List {
      if viewModel.outboundPath.isEmpty {
        emptyStateSection
      } else {
        outboundPathSection
        addHopCtaSection
      }
      PathActionsSectionView(
        viewModel: viewModel,
        showingClearConfirmation: $showingClearConfirmation,
        copyHapticTrigger: $copyHapticTrigger
      )
      RunTraceSectionView(
        viewModel: viewModel,
        showJumpToPath: $showJumpToPath
      )

      Color.clear
        .frame(height: 1)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .id("bottom")
    }
    .cardListCanvas(theme)
    .environment(\.editMode, .constant(.active))
    .addHopPicker(for: $insertionIntent, source: viewModel, inDetailColumn: true)
  }

  // MARK: - Empty state

  @ViewBuilder
  private var emptyStateSection: some View {
    Section {
      ContentUnavailableView {
        Label(
          L10n.Contacts.Contacts.PathEdit.Empty.title,
          systemImage: "antenna.radiowaves.left.and.right.slash"
        )
      } description: {
        Text(L10n.Contacts.Contacts.Trace.List.emptyPath)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
    }

    Section {
      addHopButton
        .listRowInsets(PathEditMetrics.ctaRowInsets)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
  }

  // MARK: - Add Hop CTA

  private var addHopCtaSection: some View {
    Section {
      addHopButton
        .listRowInsets(PathEditMetrics.ctaRowInsets)
        .listRowBackground(Color.clear)

      // Stays visible: it says why the button is off (or Run Trace is) and how to turn it back on.
      if viewModel.isPathFull || viewModel.isOverTraceHopCap {
        Text(viewModel.hopLimitDescription)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .listRowInsets(PathEditMetrics.ctaRowInsets)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      }
    }
  }

  private var addHopButton: some View {
    Button {
      insertionIntent = .append
    } label: {
      PathEditCTALabel(
        title: viewModel.isPathFull
          ? L10n.Contacts.Contacts.PathEdit.MaxHops.reached
          : L10n.Contacts.Contacts.PathEdit.addHop,
        systemImage: viewModel.isPathFull ? "checkmark.circle" : "plus.circle.fill"
      )
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .disabled(viewModel.isPathFull)
  }

  // MARK: - Outbound Path Section

  private var outboundPathSection: some View {
    Section {
      ForEach(Array(viewModel.outboundPath.enumerated()), id: \.element.id) { index, hop in
        TracePathHopRow(hop: hop, hopNumber: index + 1, isReached: index < viewModel.reachedOutboundHopCount)
          .cardListRow(theme)
      }
      .onMove { source, destination in
        dragHapticTrigger += 1
        viewModel.moveRepeater(from: source, to: destination)
      }
      .onDelete { indexSet in
        for index in indexSet.sorted().reversed() {
          viewModel.removeRepeater(at: index)
        }
      }
    } header: {
      // The range caveat applies to the whole path, so it sits behind the path's "i".
      InfoHeader(L10n.Contacts.Contacts.Trace.List.roundTripPath, info: L10n.Contacts.Contacts.Trace.List.rangeWarning)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.secondary)
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
    }
  }
}
