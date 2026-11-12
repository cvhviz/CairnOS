import CairnServices
import SwiftUI

/// The Profiles segment: the saved radio config profiles as card rows, Save Current Radio on top.
/// On a phone a row opens the profile's page; beside a detail pane (iPad, Mac) it selects.
struct RadioProfilesPane: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Bindable var model: RadioProfilesModel
  let query: String
  let showsDetailPane: Bool
  @Binding var selection: UUID?

  /// Reading the settings needs a ready radio; the export it runs is the Export page's.
  private var canSave: Bool {
    appState.isRadioReady && appState.services?.nodeConfigService != nil && !model.isSaving
  }

  var body: some View {
    let profiles = model.filtered(by: query)
    List {
      if query.isEmpty {
        saveRow
      }
      ForEach(profiles) { profile in
        profileRow(profile)
      }
      if query.isEmpty, !profiles.isEmpty {
        // What a profile holds and leaves out, in the card form's footer style.
        Text(L10n.Settings.Connections.Profiles.info)
          .font(.footnote)
          .foregroundStyle(Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 8, leading: CardStyle.pageInset + 4, bottom: 16, trailing: CardStyle.pageInset + 4))
      }
    }
    .cardListCanvas(theme)
    .overlay {
      if profiles.isEmpty {
        if query.isEmpty {
          ContentUnavailableView {
            Label(L10n.Settings.Connections.Profiles.emptyTitle, systemImage: "slider.horizontal.below.rectangle")
          } description: {
            Text(appState.isRadioReady
              ? L10n.Settings.Connections.Profiles.empty
              : L10n.Settings.Connections.Profiles.saveDisconnected)
          }
          // Below the Save row, which stays the way in.
          .padding(.top, 80)
        } else {
          ContentUnavailableView.search(text: query)
        }
      }
    }
  }

  /// Save Current Radio as Profile, the list's first card.
  private var saveRow: some View {
    Button {
      model.beginSaving(radioName: appState.connectedDevice?.nodeName)
    } label: {
      HStack(spacing: 12) {
        if model.isSaving {
          ProgressView()
        } else {
          IconTile(systemImage: "square.and.arrow.down.on.square", color: .purple)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.Settings.Connections.Profiles.saveCurrent)
            .foregroundStyle(Color.accentColor)
          if !appState.isRadioReady {
            Text(L10n.Settings.Connections.Profiles.saveDisconnected)
              .font(.caption)
              .foregroundStyle(Color.secondary)
          }
        }
        Spacer(minLength: 0)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!canSave)
    .dimmedWhenDisabled()
    .cardListRow(theme)
  }

  @ViewBuilder
  private func profileRow(_ profile: RadioConfigProfile) -> some View {
    let label = HStack(spacing: 12) {
      IconTile(systemImage: "slider.horizontal.below.rectangle", color: .purple)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(profile.name)
          .font(.body.weight(.semibold))
          .foregroundStyle(Color.primary)
          .lineLimit(1)
        Text(RadioProfileSummary.line(profile.config))
          .font(.caption)
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if !showsDetailPane {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
          .accessibilityHidden(true)
      }
    }
    .contentShape(.rect)

    Group {
      if showsDetailPane {
        Button { selection = profile.id } label: { label }
          .buttonStyle(.plain)
      } else {
        NavigationLink {
          RadioProfileDetailView(model: model, profileID: profile.id)
        } label: {
          label
        }
        .buttonStyle(.plain)
      }
    }
    .cardListRow(theme, isSelected: showsDetailPane && selection == profile.id)
    .swipeActions(edge: .trailing) {
      Button(L10n.Settings.Connections.Profile.delete, systemImage: "trash", role: .destructive) {
        model.delete(profile.id)
        if selection == profile.id { selection = nil }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

extension View {
  /// The name alert for a new profile, and the profiles' errors.
  func radioProfilePrompts(_ model: RadioProfilesModel, appState: AppState) -> some View {
    modifier(RadioProfilePromptsModifier(model: model, appState: appState))
  }
}

private struct RadioProfilePromptsModifier: ViewModifier {
  @Bindable var model: RadioProfilesModel
  let appState: AppState

  func body(content: Content) -> some View {
    content
      .alert(L10n.Settings.Connections.Profiles.NewProfile.title, isPresented: $model.isNaming) {
        TextField(L10n.Settings.Connections.Profiles.NewProfile.placeholder, text: $model.newName)
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
        Button(L10n.Localizable.Common.save) {
          let name = model.newName
          Task {
            await model.saveCurrentRadio(
              named: name,
              nodeConfigService: appState.services?.nodeConfigService,
              device: appState.connectedDevice
            )
          }
        }
        .disabled(RadioConfigProfile.normalizedName(model.newName) == nil)
      } message: {
        Text(L10n.Settings.Connections.Profiles.NewProfile.message)
      }
      .errorAlert($model.errorMessage)
  }
}
