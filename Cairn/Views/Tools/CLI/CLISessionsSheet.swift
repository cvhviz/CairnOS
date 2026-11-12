import CairnServices
import SwiftUI

/// The CLI's sessions as a list: the radio's own line and every session open (a tap switches to
/// it), then the repeaters, rooms and companions saved as contacts, each a tap from logging in.
/// The pick reaches the terminal through `onPick` as the command it runs (`session 2`,
/// `login Ridge`), applied once the sheet has closed so the keyboard can come back.
struct CLISessionsSheet: View {
  let viewModel: CLIToolViewModel
  let onPick: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var contacts: [ContactDTO] = []
  @State private var hasLoaded = false

  private var openSessionKeys: Set<Data> {
    Set(viewModel.remoteSessions.compactMap(\.companionPublicKey))
  }

  private var openSessionNames: Set<String> {
    Set(viewModel.remoteSessions.map { $0.name.lowercased() })
  }

  /// Saved repeaters and rooms not logged in to yet, by name.
  private var repeaters: [ContactDTO] {
    contacts
      .filter { ($0.type == .repeater || $0.type == .room) && !openSessionNames.contains($0.name.lowercased()) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Saved companions whose command line isn't open yet.
  private var companions: [ContactDTO] {
    contacts
      .filter { $0.type == .chat && !openSessionKeys.contains($0.publicKey) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    NavigationStack {
      List {
        Section(L10n.Tools.Tools.Cli.Sessions.open) {
          sessionRow(
            name: viewModel.localDeviceName,
            detail: L10n.Tools.Tools.Cli.sessionLocal,
            systemImage: "iphone.radiowaves.left.and.right",
            isActive: viewModel.activeSession?.isLocal == true,
            command: "session local"
          )
          ForEach(Array(viewModel.remoteSessions.enumerated()), id: \.element.id) { index, session in
            sessionRow(
              name: "@\(session.name)",
              detail: session.isCompanion ? L10n.Contacts.Contacts.NodeKind.chat : nil,
              systemImage: session.isCompanion ? "person" : "antenna.radiowaves.left.and.right",
              isActive: viewModel.activeSession?.id == session.id,
              command: "session \(index + 2)"
            )
          }
        }
        if !repeaters.isEmpty {
          Section(L10n.Tools.Tools.Cli.Sessions.repeaters) {
            ForEach(repeaters) { contact in
              loginRow(contact, systemImage: contact.type == .room ? "person.3" : "antenna.radiowaves.left.and.right")
            }
          }
        }
        if !companions.isEmpty {
          Section(L10n.Tools.Tools.Cli.Sessions.companions) {
            ForEach(companions) { contact in
              loginRow(contact, systemImage: "person")
            }
          }
        }
      }
      .overlay {
        if !hasLoaded {
          ProgressView()
        }
      }
      .flashingNavigationTitle(L10n.Tools.Tools.Cli.Sessions.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
      .task {
        if let store = viewModel.dataStore, let radioID = viewModel.radioID {
          contacts = (try? await store.fetchContacts(radioID: radioID)) ?? []
        }
        hasLoaded = true
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private func sessionRow(name: String, detail: String?, systemImage: String, isActive: Bool, command: String) -> some View {
    Button {
      onPick(command)
      dismiss()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .foregroundStyle(isActive ? Color.accentColor : .secondary)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(name)
            .font(.body.monospaced())
            .foregroundStyle(.primary)
          if let detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        if isActive {
          Text(L10n.Tools.Tools.Cli.Sessions.active)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityValue(isActive ? L10n.Tools.Tools.Cli.Sessions.active : "")
  }

  private func loginRow(_ contact: ContactDTO, systemImage: String) -> some View {
    Button {
      onPick("login \(contact.name)")
      dismiss()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .foregroundStyle(contact.type.displayColor)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(contact.name)
            .foregroundStyle(.primary)
          Text(L10n.Tools.Tools.Cli.Sessions.loginHint)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Image(systemName: "arrow.right.circle")
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityHint(L10n.Tools.Tools.Cli.Sessions.loginHint)
  }
}
