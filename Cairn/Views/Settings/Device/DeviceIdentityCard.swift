import CairnServices
import MeshCore
import SwiftUI

// The radio's identity on Device Info. The page's map header carries the name, the model and the
// position, as on a repeater's or room's Dashboard; these are the two pieces it adds to that header:
// the in-place rename card the header's pencil opens, and the key chip under the name. Below them,
// the two cards the sheets that replace or erase that identity open with: the radio and its current
// key (and the new one), and the consequences, always in view.

// MARK: - Name Editor

/// The rename card that opens under the header when its pencil is tapped: the name field, the
/// bytes it can still hold, and Cancel and Save.
struct DeviceNameEditor: View {
  let device: DeviceDTO
  @Binding var isEditingName: Bool
  @Binding var draftName: String
  let isSaving: Bool
  /// False while the radio isn't ready to take the new name.
  let canEditName: Bool
  let onSaveName: () -> Void

  @FocusState private var isNameFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      nameField
      editControls
    }
    .cardSurface(padding: 12)
  }

  private var nameField: some View {
    TextField(L10n.Settings.Node.name, text: $draftName)
      .font(.title3.weight(.semibold))
      .textInputAutocapitalization(.words)
      .autocorrectionDisabled()
      .submitLabel(.done)
      .focused($isNameFieldFocused)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8, style: .continuous))
      .onChange(of: draftName) { _, newValue in
        if newValue.utf8.count > ProtocolLimits.maxUsableNameBytes {
          draftName = newValue.utf8Prefix(maxBytes: ProtocolLimits.maxUsableNameBytes)
        }
      }
      .onSubmit {
        if canSave { onSaveName() }
      }
      .onKeyPress(.escape) {
        cancelEditing()
        return .handled
      }
      .onAppear { isNameFieldFocused = true }
      .disabled(isSaving)
      .accessibilityLabel(L10n.Settings.Node.name)
  }

  /// What the name can still hold and who sees it, beside Cancel and Save.
  private var editControls: some View {
    HStack(spacing: 10) {
      HStack(spacing: 4) {
        Text(L10n.Settings.DeviceInfo.nameBytesLeft(Self.bytesLeft(in: draftName)))
          .monospacedDigit()
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        // Who sees the name, behind an "i" rather than a second caption line.
        InfoButton(L10n.Settings.Node.footer, title: L10n.Settings.Node.name)
      }

      Spacer(minLength: 0)

      Button(L10n.Localizable.Common.cancel, role: .cancel) {
        cancelEditing()
      }
      .buttonStyle(.bordered)
      .disabled(isSaving)

      Button {
        onSaveName()
      } label: {
        if isSaving {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(L10n.Localizable.Common.save)
        } else {
          Text(L10n.Localizable.Common.save)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canSave)
    }
    .controlSize(.small)
  }

  private var canSave: Bool {
    canEditName && !isSaving && Self.isValidNewName(draftName, current: device.nodeName)
  }

  private func cancelEditing() {
    guard !isSaving else { return }
    isEditingName = false
    draftName = device.nodeName
  }

  // MARK: - Pure helpers

  static func bytesLeft(in name: String) -> Int {
    max(0, ProtocolLimits.maxUsableNameBytes - name.utf8.count)
  }

  /// A name worth sending: not blank, and not the name the radio already has.
  static func isValidNewName(_ draft: String, current: String) -> Bool {
    let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return !name.isEmpty && name != current
  }
}

// MARK: - Key Chip

/// The radio's public key, shortened, as the small chip under a node header's name: a tap copies
/// the whole key (the page's only Copy Key), and the context menu also shares it as text. The key
/// half of `NodeHeaderChips`, without the contact groups, which don't apply to your own radio.
struct DeviceKeyChip: View {
  let publicKey: Data
  /// The first six characters only, the node's prefix, as every node header's chip shows it (the user,
  /// 2026-11-09: the longer form made the subtitle beside it wrap). A tap still copies it whole.
  var compact = false

  private var shown: String {
    compact ? String(publicKey.uppercaseHexString().prefix(6)) : Self.shortKey(publicKey)
  }

  @State private var showsCopied = false
  @State private var copyTrigger = 0

  /// How long the chip says "Copied".
  private static let copiedFeedbackDuration: Duration = .seconds(1.5)

  var body: some View {
    let hex = publicKey.uppercaseHexString()
    Button(action: copyKey) {
      HStack(spacing: 4) {
        Image(systemName: showsCopied ? "checkmark" : "key.fill")
          .imageScale(.small)
          .contentTransition(.symbolEffect(.replace))
        Text(showsCopied ? L10n.Settings.DeviceInfo.Action.copied : shown)
          .lineLimit(1)
          .fontDesign(showsCopied ? nil : .monospaced)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      // A small rounded rectangle, matching the key on node pages (`NodeHeaderChips`).
      .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 6, style: .continuous))
      .contentShape(.rect(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .cairnFeedback(.success, trigger: copyTrigger)
    .contextMenu {
      Button(L10n.Settings.PublicKey.copy, systemImage: "doc.on.doc", action: copyKey)
      ShareLink(item: hex) {
        Label(L10n.Settings.PublicKey.share, systemImage: "square.and.arrow.up")
      }
    }
    .task(id: copyTrigger) {
      guard showsCopied else { return }
      try? await Task.sleep(for: Self.copiedFeedbackDuration)
      guard !Task.isCancelled else { return }
      showsCopied = false
    }
    .accessibilityLabel(L10n.Settings.DeviceInfo.publicKey)
    .accessibilityValue(showsCopied ? L10n.Settings.DeviceInfo.Action.copied : Self.shortKey(publicKey))
    .accessibilityHint(L10n.Settings.PublicKey.copy)
    .accessibilityInputLabels([L10n.Settings.DeviceInfo.Action.copyKey, L10n.Settings.PublicKey.copy])
  }

  private func copyKey() {
    UIPasteboard.general.string = publicKey.uppercaseHexString()
    showsCopied = true
    copyTrigger += 1
  }

  /// "1E1F20…3C3D": enough of each end to tell keys apart, as on every node header.
  static func shortKey(_ publicKey: Data) -> String {
    let hex = publicKey.uppercaseHexString()
    guard hex.count > 12 else { return hex }
    return "\(hex.prefix(6))…\(hex.suffix(4))"
  }
}

// MARK: - Identity Change Header

/// The top of a sheet or section that changes the radio's identity or erases it: which radio (its
/// avatar, name and "Companion · <model>"), its current key and, when the change has one, the key it
/// becomes. Without `newKey` only the radio and its current key show, to name the target of the
/// actions below it.
struct RadioIdentityChangeHeader: View {
  enum NewKey {
    /// No key yet; the text says how to get one.
    case pending(String)
    /// The new public key as hex, shortened like the current one.
    case keyHex(String)
    /// The key isn't known here; the text says where it comes from.
    case note(String)
  }

  let device: DeviceDTO
  var newKey: NewKey?
  /// The colour of the new key, which marks the change.
  var tone: Color = .red

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        RadioAvatar(device: device, size: NodeMapHeader<EmptyView>.avatarSize)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(device.nodeName)
            .font(.headline)
            .lineLimit(2)
          Text(DeviceInfoView.subtitle(for: device))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }

      Divider()

      keyRow(L10n.Settings.IdentityChange.currentKey) {
        Text(DeviceKeyChip.shortKey(device.publicKey))
          .fontDesign(.monospaced)
          .foregroundStyle(.secondary)
      }

      if let newKey {
        Image(systemName: "arrow.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .padding(.leading, 4)
          .accessibilityHidden(true)

        keyRow(L10n.Settings.RegenerateIdentity.NewKey.header) {
          switch newKey {
          case let .keyHex(hex):
            Text(Self.shortHex(hex))
              .fontDesign(.monospaced)
              .fontWeight(.semibold)
              .foregroundStyle(tone)
          case let .pending(text), let .note(text):
            Text(text)
              .italic()
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: 12)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }

  /// Label and value side by side, or stacked when they don't fit (large Dynamic Type), so neither
  /// wraps into a narrow column.
  private func keyRow(_ title: String, @ViewBuilder value: () -> some View) -> some View {
    let label = Label(title, systemImage: "key.fill")
      .foregroundStyle(.secondary)
    let content = value()
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        label
          .fixedSize()
        Spacer(minLength: 8)
        content
          .fixedSize()
      }
      VStack(alignment: .leading, spacing: 2) {
        label
        content
          .multilineTextAlignment(.leading)
      }
    }
    .font(.subheadline)
  }

  private var accessibilityText: String {
    let current = DeviceKeyChip.shortKey(device.publicKey)
    let identity = NodeRouteFormat.joined([device.nodeName, DeviceInfoView.subtitle(for: device)])
    guard let newKey else {
      return L10n.Settings.IdentityChange.A11y.current(identity, current)
    }
    let new: String = switch newKey {
    case let .keyHex(hex): Self.shortHex(hex)
    case let .pending(text), let .note(text): text
    }
    return L10n.Settings.IdentityChange.a11y(identity, current, new)
  }

  /// "1E1F20…3C3D", as `DeviceKeyChip.shortKey` shortens the current key. Spaces between bytes
  /// (the generated key's display form) are dropped first.
  static func shortHex(_ spacedHex: String) -> String {
    let hex = spacedHex.filter { !$0.isWhitespace }
    guard hex.count > 12 else { return hex }
    return "\(hex.prefix(6))…\(hex.suffix(4))"
  }
}

// MARK: - Consequence Card

/// What an identity change or erase does, always in view rather than behind an "i": each line with
/// a warning glyph, on a card outlined in `tone`.
struct ImportantConsequenceCard: View {
  let lines: [String]
  var tone: Color = .orange

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(lines, id: \.self) { line in
        Label {
          Text(line)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(tone)
        }
        .font(.subheadline)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: 12)
    .overlay {
      CardStyle.shape
        .strokeBorder(tone.opacity(0.6), lineWidth: 1)
    }
  }
}
