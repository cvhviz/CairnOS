import CairnServices
import SwiftUI

/// The small chips under a node's name in its header: the public key, shortened, which a tap
/// copies; and the contact groups, a menu that adds or removes the node. They replace the Details
/// card the key and groups used to need at the foot of a node's page.
struct NodeHeaderChips: View {
  let publicKey: Data
  /// The note kept for the node on this phone (`ContactDTO.note`), under the chips when there is one.
  var note: String?
  /// For the end of the header's subtitle line: the key's first six characters, and the groups as a
  /// glyph with how many the node is in.
  var compact = false

  @State private var showsCopied = false
  @State private var copyTrigger = 0
  @State private var editorMode: ContactGroupEditorItem?

  private let store = ContactGroupStore.shared

  /// "1E1F20…3C3D": enough of each end to tell keys apart; "1E1F20", the node's prefix, when compact.
  private var shortKey: String {
    let hex = publicKey.hexString.uppercased()
    if compact { return String(hex.prefix(6)) }
    guard hex.count > 12 else { return hex }
    return "\(hex.prefix(6))…\(hex.suffix(4))"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Button(action: copyKey) {
          chip(
            systemImage: showsCopied ? "checkmark" : "key.fill",
            text: showsCopied ? L10n.Contacts.Contacts.Qr.copied : shortKey,
            monospaced: !showsCopied
          )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: copyTrigger)
        .accessibilityLabel(L10n.Contacts.Contacts.Detail.publicKey)
        .accessibilityValue(showsCopied ? L10n.Contacts.Contacts.Qr.copied : shortKey)
        .accessibilityHint(L10n.Contacts.Contacts.Qr.copy)

        groupsMenu
      }
      if !compact, let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
        Label(note, systemImage: "note.text")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(L10n.RemoteNodes.RemoteNodes.Note.title)
          .accessibilityValue(note)
      }
    }
  }

  private var groupsMenu: some View {
    let memberOf = store.groups(containing: publicKey)
    let value = memberOf.isEmpty
      ? L10n.Contacts.Contacts.Groups.title
      : memberOf.map(\.name).formatted(.list(type: .and))
    return Menu {
      ForEach(store.groups) { group in
        Toggle(isOn: Binding(
          get: { group.contains(publicKey) },
          set: { _ in store.toggle(publicKey, in: group.id) }
        )) {
          Label(group.name, systemImage: group.symbol)
        }
      }
      Section(L10n.Contacts.Contacts.Groups.footer) {
        Button {
          editorMode = ContactGroupEditorItem(mode: .create(initialMember: publicKey))
        } label: {
          Label(L10n.Contacts.Contacts.Groups.new, systemImage: "plus")
        }
      }
    } label: {
      chip(
        systemImage: memberOf.isEmpty ? "person.3" : "person.3.fill",
        text: compact ? (memberOf.isEmpty ? "" : "\(memberOf.count)") : value,
        monospaced: false
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(L10n.Contacts.Contacts.Groups.title)
    .accessibilityValue(memberOf.isEmpty ? L10n.Contacts.Contacts.Groups.notInAny : value)
    .accessibilityHint(L10n.Contacts.Contacts.Groups.editMembers)
    .sheet(item: $editorMode) { item in
      ContactGroupEditorSheet(mode: item.mode)
    }
  }

  private func chip(systemImage: String, text: String, monospaced: Bool) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage)
        .imageScale(.small)
      if !text.isEmpty {
        Text(text)
          .lineLimit(1)
          .fontDesign(monospaced ? .monospaced : nil)
      }
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    // A small rounded rectangle rather than a pill: it reads as a field holding a value (the key),
    // not as a tag.
    .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 6, style: .continuous))
    .contentShape(.rect(cornerRadius: 6, style: .continuous))
  }

  private func copyKey() {
    UIPasteboard.general.string = publicKey.hexString.uppercased()
    copyTrigger += 1
    showsCopied = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      showsCopied = false
    }
  }
}
