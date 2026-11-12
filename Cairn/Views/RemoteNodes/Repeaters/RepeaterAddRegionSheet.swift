import CairnServices
import SwiftUI

struct RepeaterAddRegionSheet: View {
  @Environment(\.dismiss) private var dismiss

  let existingRegions: [RepeaterRegionEntry]
  /// Names on the repeater that aren't in `existingRegions` (a table read only in part).
  let otherRegionNames: [String]
  let onAdd: @MainActor (_ name: String, _ parent: RepeaterRegionEntry.Parent) async throws -> Void

  @State private var regionName = ""
  @State private var selectedParent: RepeaterRegionEntry.Parent
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @FocusState private var nameFieldFocused: Bool

  init(
    parent: RepeaterRegionEntry.Parent,
    existingRegions: [RepeaterRegionEntry],
    otherRegionNames: [String] = [],
    onAdd: @escaping @MainActor (_ name: String, _ parent: RepeaterRegionEntry.Parent) async throws -> Void
  ) {
    _selectedParent = State(initialValue: parent)
    self.existingRegions = existingRegions
    self.otherRegionNames = otherRegionNames
    self.onAdd = onAdd
  }

  private var validationError: RegionNameValidator.ValidationError? {
    RegionNameValidator.validateForRepeater(regionName, existingRegions: existingRegions.map(\.name) + otherRegionNames)
  }

  private var validationErrorText: String? {
    switch validationError {
    case .invalidCharacters:
      L10n.RemoteNodes.RemoteNodes.Settings.Regions.invalidName
    case .privateRegion:
      L10n.RemoteNodes.RemoteNodes.Settings.Regions.privateName
    case let .tooLong(maxBytes):
      L10n.RemoteNodes.RemoteNodes.Settings.Regions.nameTooLong(maxBytes)
    case .duplicate:
      L10n.RemoteNodes.RemoteNodes.Settings.Regions.duplicate
    case .empty, nil:
      nil
    }
  }

  private var canAdd: Bool {
    validationError == nil && !isSubmitting
  }

  var body: some View {
    NavigationStack {
      CardForm {
        CardFormSection {
          ContentCard {
            TextField(L10n.RemoteNodes.RemoteNodes.Settings.Regions.regionName, text: $regionName)
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)
              .focused($nameFieldFocused)
              .onSubmit {
                if canAdd { submit() }
              }
          }

          PickerCard(L10n.RemoteNodes.RemoteNodes.Settings.Regions.parent, selection: $selectedParent) {
            Text(L10n.RemoteNodes.RemoteNodes.Settings.Regions.allTrafficWildcard)
              .tag(RepeaterRegionEntry.Parent.unscoped)
              .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Settings.Regions.allTraffic)
            ForEach(existingRegions.filter { !$0.isUnscoped }, id: \.name) { region in
              Text(region.name)
                .tag(RepeaterRegionEntry.Parent.named(region.name))
            }
          }
        }

        if let errorText = errorMessage ?? validationErrorText {
          Text(errorText)
            .foregroundStyle(.red)
            .font(.caption)
            .padding(.horizontal, 4)
        }
      }
      .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Settings.Regions.addRegionTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.RemoteNodes.RemoteNodes.cancel) {
            dismiss()
          }
          .disabled(isSubmitting)
          .keyboardShortcut(.cancelAction)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(action: submit) {
            if isSubmitting {
              ProgressView()
            } else {
              Text(L10n.RemoteNodes.RemoteNodes.Settings.Regions.addRegion)
            }
          }
          .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Settings.Regions.addRegion)
          .disabled(!canAdd)
        }
      }
      .interactiveDismissDisabled(isSubmitting)
      .disabled(isSubmitting)
      .onAppear { nameFieldFocused = true }
      .onChange(of: regionName) { _, _ in errorMessage = nil }
      .onChange(of: selectedParent) { _, _ in errorMessage = nil }
    }
  }

  private func submit() {
    isSubmitting = true
    errorMessage = nil
    let nameToAdd = RegionNameValidator.cleanedName(regionName)
    Task {
      defer { isSubmitting = false }
      do {
        try await onAdd(nameToAdd, selectedParent)
        dismiss()
      } catch let RepeaterSettingsViewModel.AddRegionError.rejected(reason) {
        errorMessage = reason ?? L10n.RemoteNodes.RemoteNodes.Settings.Regions.addFailed
      } catch is RepeaterSettingsViewModel.RegionFloodDefaultError {
        // The region was added; the settings screen reports that its flood stayed off.
        dismiss()
      } catch {
        errorMessage = error.userFacingMessage
      }
    }
  }
}
