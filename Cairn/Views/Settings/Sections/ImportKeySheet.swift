import CairnServices
import SwiftUI

/// Sheet for importing an existing Ed25519 private key onto the device. It opens on what is at
/// stake, in view: the radio and its current key, and what replacing the identity does. Then the
/// key field with its length, and Import, which still validates and asks for confirmation before
/// anything reaches the radio.
struct ImportKeySheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState

  @State private var viewModel = ImportKeyViewModel()

  var body: some View {
    NavigationStack {
      CardForm {
        if let device = appState.connectedDevice {
          // The new public key can't be derived from an expanded private key here, so the header
          // says where it comes from rather than showing a guess.
          RadioIdentityChangeHeader(
            device: device,
            newKey: .note(L10n.Settings.ImportKey.NewKey.note),
            tone: .red
          )
        }
        ImportantConsequenceCard(
          lines: [
            L10n.Settings.ImportKey.Sheet.explanation,
            L10n.Settings.RegenerateIdentity.Alert.Replace.message,
          ],
          tone: .orange
        )
        keyInputSection
      }
      .flashingNavigationTitle(L10n.Settings.ImportKey.Sheet.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) {
            dismiss()
          }
          .disabled(viewModel.isImporting)
          .keyboardShortcut(.cancelAction)
        }
      }
      .interactiveDismissDisabled(viewModel.isImporting)
      .alert(
        L10n.Settings.RegenerateIdentity.Alert.Replace.title,
        isPresented: $viewModel.showingReplaceAlert
      ) {
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
        Button(L10n.Settings.RegenerateIdentity.Alert.Replace.confirm, role: .destructive) {
          Task {
            if await viewModel.importKey() {
              dismiss()
            }
          }
        }
      } message: {
        Text(L10n.Settings.RegenerateIdentity.Alert.Replace.message)
      }
      .errorAlert($viewModel.errorMessage)
      .cairnFeedback(.success, trigger: viewModel.successTrigger)
      .task {
        viewModel.configure(settingsService: { appState.services?.settingsService })
      }
    }
    // Large so the radio, the consequences and the key field are all in view without dragging.
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  // MARK: - Sections

  /// The key, how much of it is pasted, and the button that sends it, in one section; what the
  /// import does is on the consequence card above, and the Replace Identity alert spells it out
  /// again before anything is sent.
  private var keyInputSection: some View {
    CardFormSection(L10n.Settings.ImportKey.KeyInput.label) {
      ContentCard {
        TextField(L10n.Settings.ImportKey.KeyInput.placeholder, text: $viewModel.hexInput, axis: .vertical)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
          .font(.system(.body, design: .monospaced))
          .lineLimit(3...6)
          .onChange(of: viewModel.hexInput) { _, newValue in
            viewModel.sanitizeInput(newValue)
          }
      }

      keyLengthLine

      Button {
        viewModel.validateAndConfirm()
      } label: {
        BusyActionCardLabel(
          title: viewModel.isImporting ? L10n.Settings.ImportKey.importing : L10n.Settings.ImportKey.import,
          systemImage: "key",
          // Red: it replaces the radio's identity for good.
          color: .red,
          isBusy: viewModel.isImporting
        )
      }
      .buttonStyle(.plain)
      // Importing writes to the radio: without a ready connection the confirmed import would do
      // nothing.
      .radioDisabled(for: appState.connectionState, or: viewModel.isImporting || viewModel.hexInput.isEmpty)
    }
  }

  /// Display only: "64 of 128 characters", green with a check at the full length and orange past
  /// it. Validation stays with Import.
  private var keyLengthLine: some View {
    let count = viewModel.hexInput.count
    let expected = Self.expectedHexLength
    let tint: Color = count == expected ? .green : (count > expected ? .orange : .secondary)
    return HStack(spacing: 4) {
      if count == expected {
        Image(systemName: "checkmark.circle.fill")
          .accessibilityHidden(true)
      }
      Text(L10n.Settings.ImportKey.KeyInput.progress(count, expected))
        .monospacedDigit()
    }
    .font(.caption)
    .foregroundStyle(tint)
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Two hex characters per byte of the expanded private key.
  private static let expectedHexLength = ProtocolLimits.privateKeySize * 2
}
