import CairnServices
import SwiftUI

/// Sheet for editing a contact's routing path. Two surfaces:
/// 1. Main screen (this view) — ordered hops, primary CTA, empty-state actions
/// 2. Add Hop picker — pushed via navigationDestination(item:) (see `AddHopPickerView`)
struct PathEditingSheet: View {
  /// Firmware path-length sentinel: 0x00 = direct routing (no repeaters).
  /// Distinct from the flood sentinel 0xFF and from `encodePathLen` output,
  /// which only uses values where the top two bits encode the hash mode.
  private static let directRoutingPathLength: UInt8 = 0x00

  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var viewModel: PathManagementViewModel
  let contact: ContactDTO

  @State private var dragHapticTrigger = 0
  @State private var deleteHapticTrigger = 0
  @State private var saveCompletedToken = 0
  @State private var routingConfirmedToken = 0

  @State private var showingDirectConfirmation = false
  @State private var showingFloodConfirmation = false
  /// Cancel with edits asks first; a swipe down is held off the same way.
  @State private var showingDiscardConfirmation = false
  @State private var showingCopyFrom = false

  var body: some View {
    NavigationStack {
      // Each hop is a card row; the list stays in edit mode so the hops keep their drag
      // handles and delete controls.
      List {
        if viewModel.editablePath.isEmpty {
          emptyStateSection
        } else {
          currentPathSection
          addHopCtaSection
        }
      }
      .cardListCanvas(theme)
      .flashingNavigationTitle(L10n.Contacts.Contacts.PathEdit.title)
      .navigationBarTitleDisplayMode(.inline)
      .environment(\.editMode, .constant(.active))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Contacts.Contacts.Common.cancel) {
            if viewModel.hasChanges {
              showingDiscardConfirmation = true
            } else {
              dismiss()
            }
          }
          .keyboardShortcut(.cancelAction)
        }
        if !viewModel.editablePath.isEmpty {
          ToolbarItem(placement: .confirmationAction) {
            Button(L10n.Contacts.Contacts.Common.save) {
              Task {
                await viewModel.saveEditedPath(for: contact)
                guard viewModel.errorMessage == nil else { return }
                saveCompletedToken += 1
                dismiss()
              }
            }
            .keyboardShortcut(.defaultAction)
          }
        }
      }
      .addHopPicker(for: $viewModel.insertionIntent, source: viewModel)
      // One level of undo after a swiped-away hop, a reorder or a copied path, for a moment.
      .safeAreaInset(edge: .bottom) {
        if let undo = viewModel.undoEntry {
          PathUndoToast(text: undo.description) {
            viewModel.undo()
          }
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.snappy, value: viewModel.undoEntry)
      .task(id: viewModel.undoVersion) {
        guard viewModel.undoEntry != nil else { return }
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        viewModel.clearUndo()
      }
      .sheet(isPresented: $showingCopyFrom) {
        CopyPathFromSheet(viewModel: viewModel, contact: contact)
      }
      .alert(L10n.Contacts.Contacts.PathEdit.Discard.title, isPresented: $showingDiscardConfirmation) {
        Button(L10n.Contacts.Contacts.PathEdit.Discard.confirm, role: .destructive) { dismiss() }
        Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
      } message: {
        Text(L10n.Contacts.Contacts.PathEdit.Discard.message)
      }
      .sensoryFeedback(.impact(weight: .light), trigger: dragHapticTrigger)
      .sensoryFeedback(.impact(weight: .medium), trigger: deleteHapticTrigger)
      .sensoryFeedback(.success, trigger: saveCompletedToken)
      .sensoryFeedback(.selection, trigger: routingConfirmedToken)
      .alert(
        L10n.Contacts.Contacts.PathEdit.DirectRouting.Confirm.title,
        isPresented: $showingDirectConfirmation
      ) {
        Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
        Button(L10n.Contacts.Contacts.PathEdit.DirectRouting.Confirm.confirm, role: .destructive) {
          Task {
            await viewModel.setPath(
              for: contact,
              path: Data(),
              pathLength: Self.directRoutingPathLength
            )
            guard viewModel.errorMessage == nil else { return }
            routingConfirmedToken += 1
            dismiss()
          }
        }
      } message: {
        Text(L10n.Contacts.Contacts.PathEdit.DirectRouting.Confirm.message(
          contact.displayName,
          contact.displayName
        ))
      }
      .alert(
        L10n.Contacts.Contacts.PathEdit.FloodRouting.Confirm.title,
        isPresented: $showingFloodConfirmation
      ) {
        Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
        Button(L10n.Contacts.Contacts.PathEdit.FloodRouting.Confirm.confirm, role: .destructive) {
          Task {
            await viewModel.resetPath(for: contact)
            guard viewModel.errorMessage == nil else { return }
            routingConfirmedToken += 1
            dismiss()
          }
        }
      } message: {
        Text(L10n.Contacts.Contacts.PathEdit.FloodRouting.Confirm.message(
          contact.displayName
        ))
      }
    }
    .presentationDragIndicator(.visible)
    .presentationSizing(.page)
    // A swipe down with edits would lose them silently; Cancel asks instead.
    .interactiveDismissDisabled(viewModel.hasChanges)
  }

  // MARK: - Sections

  /// Ordered hops with drag-to-reorder and swipe-to-delete.
  /// Uses `.onDelete` (not `.swipeActions`) because the list is in
  /// `.editMode == .active` for the always-visible drag handles, and
  /// active edit mode suppresses `.swipeActions`. `.onDelete` provides
  /// both the leading minus-circle and the trailing swipe gesture.
  private var currentPathSection: some View {
    Section {
      ForEach(Array(viewModel.editablePath.enumerated()), id: \.element.id) { index, hop in
        PathHopRow(
          hop: hop,
          index: index,
          totalCount: viewModel.editablePath.count
        )
        .cardListRow(theme)
        .contextMenu {
          Button(L10n.Contacts.Contacts.PathEdit.insertBefore, systemImage: "arrow.turn.down.left") {
            viewModel.insertionIntent = .insert(at: index)
          }
          .disabled(viewModel.isPathFull)
        }
      }
      .onMove { source, destination in
        dragHapticTrigger += 1
        viewModel.moveRepeater(from: source, to: destination)
      }
      .onDelete { indexSet in
        deleteHapticTrigger += 1
        for index in indexSet.sorted().reversed() {
          viewModel.removeRepeater(at: index)
        }
      }
    } header: {
      // What the page is for and how to edit it sit behind the "i" rather than as a
      // paragraph above the hops and a footer under them.
      InfoHeader(
        L10n.Contacts.Contacts.PathEdit.currentPath,
        info: L10n.Contacts.Contacts.PathEdit.description(contact.displayName)
          + "\n\n" + L10n.Contacts.Contacts.PathEdit.reorderHint
      )
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Color.secondary)
      .textCase(nil)
      .accessibilityAddTraits(.isHeader)
    }
  }

  private var addHopCtaSection: some View {
    Section {
      Button {
        viewModel.insertionIntent = .append
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
      .listRowInsets(PathEditMetrics.ctaRowInsets)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)

      copyPathFromButton

      // Stays visible: it says why the button is off and how to turn it back on.
      if viewModel.isPathFull {
        Text(L10n.Contacts.Contacts.PathEdit.MaxHops.footer(viewModel.maxHopCount))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .listRowInsets(PathEditMetrics.ctaRowInsets)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      }
    }
  }

  @ViewBuilder
  private var emptyStateSection: some View {
    Section {
      ContentUnavailableView {
        Label(
          L10n.Contacts.Contacts.PathEdit.Empty.title,
          systemImage: "antenna.radiowaves.left.and.right.slash"
        )
      } description: {
        Text(L10n.Contacts.Contacts.PathEdit.Empty.description(contact.displayName))
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
    }

    Section {
      Button {
        viewModel.insertionIntent = .append
      } label: {
        PathEditCTALabel(
          title: L10n.Contacts.Contacts.PathEdit.addHop,
          systemImage: "plus.circle.fill"
        )
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .listRowInsets(PathEditMetrics.ctaRowInsets)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)

      copyPathFromButton

      Button {
        showingDirectConfirmation = true
      } label: {
        PathEditCTALabel(
          title: L10n.Contacts.Contacts.PathEdit.useDirectRouting,
          systemImage: "person.wave.2"
        )
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .listRowInsets(PathEditMetrics.ctaRowInsets)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)

      Button {
        showingFloodConfirmation = true
      } label: {
        PathEditCTALabel(
          title: L10n.Contacts.Contacts.PathEdit.useFloodRouting,
          systemImage: "dot.radiowaves.left.and.right"
        )
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .listRowInsets(PathEditMetrics.ctaRowInsets)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    }
  }

  /// Takes another node's stored route as this one's hops: a neighbour that is reached the
  /// same way is the usual case.
  private var copyPathFromButton: some View {
    Button {
      showingCopyFrom = true
    } label: {
      PathEditCTALabel(
        title: L10n.Contacts.Contacts.PathEdit.copyFrom,
        systemImage: "doc.on.doc"
      )
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .listRowInsets(PathEditMetrics.ctaRowInsets)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }
}

// MARK: - Undo toast

/// "Removed Hilltop · Undo", over the bottom of the editor for a few seconds.
private struct PathUndoToast: View {
  let text: String
  let onUndo: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Text(text)
        .font(.subheadline)
        .lineLimit(1)
        .truncationMode(.middle)
      Button(L10n.Contacts.Contacts.PathEdit.undo, systemImage: "arrow.uturn.backward", action: onUndo)
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderless)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .liquidGlass(in: .capsule)
    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    .padding(.bottom, 8)
    .accessibilityElement(children: .contain)
  }
}

// MARK: - Copy Path From

/// The other nodes with a stored route; picking one replaces the hops with its route.
private struct CopyPathFromSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let viewModel: PathManagementViewModel
  let contact: ContactDTO

  private var sources: [ContactDTO] {
    viewModel.copyablePathSources(excluding: contact.publicKey)
  }

  var body: some View {
    NavigationStack {
      Group {
        if sources.isEmpty {
          ContentUnavailableView(
            L10n.Contacts.Contacts.PathEdit.copyFrom,
            systemImage: "doc.on.doc",
            description: Text(L10n.Contacts.Contacts.PathEdit.CopyFrom.empty)
          )
        } else {
          List(sources) { source in
            Button {
              viewModel.adoptPath(from: source)
              dismiss()
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                  .font(.body)
                  .foregroundStyle(.primary)
                Text(ContactRouteSummary.text(
                  isFloodRouted: source.isFloodRouted,
                  pathHopCount: source.pathHopCount,
                  hopNames: ContactRouteSummary.hopNames(for: source) { viewModel.resolveHashToName($0) }
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .cardListRow(theme)
          }
          .cardListCanvas(theme)
        }
      }
      .flashingNavigationTitle(L10n.Contacts.Contacts.PathEdit.copyFrom)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Contacts.Contacts.Common.cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

// MARK: - Row views

/// Row displaying a single hop in the path with an index capsule.
private struct PathHopRow: View {
  let hop: PathHop
  let index: Int
  let totalCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let name = hop.resolvedName {
        Text(name).font(.body)
        Text(hop.hashHex)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      } else {
        Text(hop.hashHex).font(.body.monospaced())
      }
    }
    .frame(minHeight: PathEditMetrics.tapTarget)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
    .accessibilityHint(L10n.Contacts.Contacts.PathEdit.hopHint)
  }

  private var accessibilityDescription: String {
    if let name = hop.resolvedName {
      L10n.Contacts.Contacts.PathEdit.hopWithName(index + 1, totalCount, name)
    } else {
      L10n.Contacts.Contacts.PathEdit.hopWithHex(index + 1, totalCount, hop.hashHex)
    }
  }
}
