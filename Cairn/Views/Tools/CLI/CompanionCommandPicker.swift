import CairnServices
import SwiftUI

/// The command list of another companion's command line, as the Cairn firmware's Remote commands
/// page offers it (ui-l2 `CompanionCli.h`): the four quick commands (Send tiles), then Read,
/// Change and Power as tiles. A Read or simple Change command goes at once; a Change that needs
/// a value starts the line ("set name ") for it to be typed; Restart and Power off ask first.
///
/// The pick reaches the host through `onPick` just before the sheet closes; a host applies it
/// in the sheet's `onDismiss`, so the keyboard comes up once the sheet is gone.
struct CompanionCommandPicker: View {
  /// What picking a command does in the terminal.
  enum Pick: Equatable {
    /// Send this command now.
    case run(String)
    /// Put this start of a command in the input line for the rest to be typed.
    case edit(String)
  }

  /// What a tap on a command leads to: a pick, or a question first (``CompanionCLICommand/Kind/confirm``).
  enum Choice: Equatable {
    case pick(Pick)
    case confirm(CompanionCLICommand)
  }

  /// The firmware's `run` for one command.
  static func choice(for command: CompanionCLICommand) -> Choice {
    switch command.kind {
    case .send: .pick(.run(command.command))
    case .edit: .pick(.edit(command.command))
    case .confirm: .confirm(command)
    }
  }

  @Environment(\.dismiss) private var dismiss

  let onPick: (Pick) -> Void

  @State private var pendingConfirmation: CompanionCLICommand?
  /// The ids of the commands pinned at the top, as JSON, kept between visits.
  @AppStorage(AppStorageKey.pinnedCompanionCommands.rawValue) private var pinnedRaw = ""

  private var pinnedIDs: [String] {
    get { CompanionCommandPins.decode(pinnedRaw) }
    nonmutating set { pinnedRaw = CompanionCommandPins.encode(newValue) }
  }

  private var pinned: [CompanionCLICommand] {
    pinnedIDs.compactMap { id in CompanionCLICatalog.commands.first { $0.id == id } }
  }

  var body: some View {
    NavigationStack {
      CardForm {
        if !pinned.isEmpty {
          CardFormSection(L10n.Tools.Tools.Cli.Companion.pinned) {
            tiles(pinned, quick: false)
          }
        }
        CardFormSection(L10n.Tools.Tools.Cli.Companion.Group.quick) {
          tiles(CompanionCLICatalog.quick, quick: true)
        }

        ForEach(CompanionCLICommand.Group.allCases, id: \.self) { group in
          CardFormSection(
            group.title,
            footer: group == .power ? L10n.Tools.Tools.Cli.Companion.note : nil
          ) {
            tiles(CompanionCLICatalog.commands(in: group), quick: false)
          }
        }
      }
      .flashingNavigationTitle(L10n.Tools.Tools.Cli.Companion.commands)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) { dismiss() }
        }
      }
      .confirmationDialog(
        pendingConfirmation?.title ?? "",
        isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
        titleVisibility: .visible,
        presenting: pendingConfirmation
      ) { command in
        Button(command.title, role: .destructive) {
          finish(.run(command.command))
        }
      } message: { command in
        Text(L10n.Tools.Tools.Cli.Companion.confirmMessage(command.title, command.command))
      }
    }
  }

  private func tiles(_ commands: [CompanionCLICommand], quick: Bool) -> some View {
    MetricTileGrid {
      ForEach(commands) { command in
        let title = quick ? command.quickTitle : command.title
        Button {
          switch Self.choice(for: command) {
          case let .pick(pick): finish(pick)
          case let .confirm(command): pendingConfirmation = command
          }
        } label: {
          // Quick tiles send, as the firmware's QUICK tiles do: Send, in the link tint.
          NodeActionTile(
            title,
            systemImage: quick ? CompanionCLICommand.quickSystemImage : command.systemImage,
            accessibilityTitle: "\(title), \(command.command.trimmingCharacters(in: .whitespaces))"
          )
          .tint(quick ? CompanionCLICommand.quickTint : command.tint)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companionCommand.\(quick ? "quick." : "")\(command.id)")
        // A long press pins the command at the top, or takes it down again.
        .contextMenu {
          let isPinned = pinnedIDs.contains(command.id)
          Button(
            isPinned ? L10n.Tools.Tools.Cli.Companion.unpin : L10n.Tools.Tools.Cli.Companion.pin,
            systemImage: isPinned ? "pin.slash" : "pin"
          ) {
            pinnedIDs = CompanionCommandPins.toggled(command.id, in: pinnedIDs)
          }
        }
      }
    }
  }

  private func finish(_ pick: Pick) {
    onPick(pick)
    dismiss()
  }
}

/// The pinned commands' ids as they are kept in `UserDefaults`: a JSON array of strings.
enum CompanionCommandPins {
  static func decode(_ raw: String) -> [String] {
    guard let data = raw.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return ids
  }

  static func encode(_ ids: [String]) -> String {
    guard let data = try? JSONEncoder().encode(ids) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// `ids` with `id` added at the end, or taken out when it is there.
  static func toggled(_ id: String, in ids: [String]) -> [String] {
    ids.contains(id) ? ids.filter { $0 != id } : ids + [id]
  }
}

#Preview {
  CompanionCommandPicker { _ in }
}
