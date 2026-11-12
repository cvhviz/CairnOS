import SwiftUI

/// One of a logged-in repeater's or room's settings sheets, opened from its Dashboard card (Radio,
/// Device, Behavior) or the header's pencil (identity), the way Home's cards open the companion's.
enum NodeSettingsPage: String, Identifiable, CaseIterable {
  case radio
  case identity
  case contactInfo
  case behavior
  case regions
  case roomAccess
  case security
  case deviceInfo

  var id: String { rawValue }

  var title: String {
    switch self {
    case .radio: L10n.RemoteNodes.RemoteNodes.Settings.radioParameters
    case .identity: L10n.RemoteNodes.RemoteNodes.Settings.identityLocation
    case .contactInfo: L10n.RemoteNodes.RemoteNodes.Settings.contactInfo
    case .behavior: L10n.RemoteNodes.RemoteNodes.Settings.behavior
    case .regions: L10n.RemoteNodes.RemoteNodes.Settings.regions
    case .roomAccess: L10n.RemoteNodes.RemoteNodes.RoomSettings.roomSettingsSection
    case .security: L10n.RemoteNodes.RemoteNodes.Settings.security
    case .deviceInfo: L10n.RemoteNodes.RemoteNodes.Settings.deviceInfo
    }
  }

  var systemImage: String {
    switch self {
    case .radio: "antenna.radiowaves.left.and.right"
    case .identity: "person.text.rectangle"
    case .contactInfo: "person.crop.rectangle"
    case .behavior: "slider.horizontal.3"
    case .regions: "globe"
    case .roomAccess: "person.badge.key"
    case .security: "lock.fill"
    case .deviceInfo: "info"
    }
  }

  var color: Color {
    switch self {
    case .radio: .orange
    case .identity: .blue
    case .contactInfo: .teal
    case .behavior: .indigo
    case .regions: .green
    case .roomAccess: .purple
    case .security, .deviceInfo: .gray
    }
  }
}

/// A setting's sheet: the setting's card on its own, opened and reading, with Done. Its own stack
/// keeps the pickers and pushed pages inside the sheet. With edits not yet sent to the node
/// (`hasUnsavedChanges`) a drag can't close it and Done asks first: discard them, send them
/// (`onSave`, when the page has one Apply for them), or keep editing.
struct NodeSettingsPageSheet<Content: View>: View {
  let page: NodeSettingsPage
  /// The page's values are still on their way from the node: the loading bar runs along the top.
  var isLoading = false
  /// Edits on the page that the node hasn't been sent.
  var hasUnsavedChanges = false
  /// Drops the unsent edits (back to the node's values) before the sheet closes.
  var onDiscard: (() -> Void)?
  /// Sends the unsent edits; nil when the page's Apply needs its own confirmation (the radio).
  var onSave: (() async -> Void)?
  let onDone: () -> Void
  @ViewBuilder let content: () -> Content

  @State private var showsUnsavedPrompt = false
  @State private var isSaving = false

  var body: some View {
    NavigationStack {
      CardForm {
        content()
      }
      .pageLoadingBar(isLoading: isLoading)
      .flashingNavigationTitle(page.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.RemoteNodes.RemoteNodes.done) {
            if hasUnsavedChanges {
              showsUnsavedPrompt = true
            } else {
              onDone()
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving)
        }
      }
      .confirmationDialog(
        L10n.RemoteNodes.RemoteNodes.Settings.Unsaved.title,
        isPresented: $showsUnsavedPrompt,
        titleVisibility: .visible
      ) {
        if let onSave {
          Button(L10n.RemoteNodes.RemoteNodes.Settings.Unsaved.save) {
            isSaving = true
            Task {
              await onSave()
              isSaving = false
              // Apply reports its own failure on the card; the sheet stays for it.
              if !hasUnsavedChanges { onDone() }
            }
          }
        }
        Button(L10n.RemoteNodes.RemoteNodes.Settings.Unsaved.discard, role: .destructive) {
          onDiscard?()
          onDone()
        }
        Button(L10n.RemoteNodes.RemoteNodes.Settings.Unsaved.keepEditing, role: .cancel) {}
      } message: {
        Text(L10n.RemoteNodes.RemoteNodes.Settings.Unsaved.message)
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(hasUnsavedChanges)
  }
}

extension NodeSettingsViewModel {
  /// Opens the shared settings' cards so they read their values as their sheet appears.
  func expand(_ page: NodeSettingsPage) {
    switch page {
    case .radio: isRadioExpanded = true
    case .identity: isIdentityExpanded = true
    case .contactInfo: isContactInfoExpanded = true
    case .security: isSecurityExpanded = true
    case .deviceInfo: isDeviceInfoExpanded = true
    case .behavior, .regions, .roomAccess: break
    }
  }
}
