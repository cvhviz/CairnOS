import CairnServices
import SwiftUI

/// Sheet for generating a new Ed25519 identity and importing it to the device. It opens on what is
/// at stake, in view: the radio, its current key and the new one once generated, and what replacing
/// the identity does. Then the optional prefix and Generate, the full new keys, and Use This Key,
/// which still asks for confirmation before anything reaches the radio.
struct RegenerateIdentitySheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState

  @State private var viewModel = RegenerateIdentityViewModel()

  /// Scroll target: Use This Key, brought into view once a key is generated.
  private static let replaceSectionID = "replace"

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        CardForm {
          if let device = appState.connectedDevice {
            RadioIdentityChangeHeader(
              device: device,
              newKey: viewModel.generatedKey.map { .keyHex($0.publicKeyHex) }
                ?? .pending(L10n.Settings.IdentityChange.NewKey.pending),
              tone: .red
            )
          }
          ImportantConsequenceCard(
            lines: [
              L10n.Settings.RegenerateIdentity.Sheet.explanation,
              L10n.Settings.RegenerateIdentity.Alert.Replace.message,
            ],
            tone: .orange
          )
          newKeySection
          if let generatedKey = viewModel.generatedKey {
            keyPreviewSection(generatedKey)
            replaceSection
              .id(Self.replaceSectionID)
          }
        }
        // Keyed on the key itself so every Generate, not only the first, brings Use This Key into view.
        .onChange(of: viewModel.generatedKey?.publicKeyHex) { _, newKey in
          guard newKey != nil else { return }
          withAnimation {
            proxy.scrollTo(Self.replaceSectionID, anchor: .bottom)
          }
        }
      }
      .flashingNavigationTitle(L10n.Settings.RegenerateIdentity.Sheet.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) {
            dismiss()
          }
          .disabled(viewModel.isBusy)
          .keyboardShortcut(.cancelAction)
        }
      }
      .interactiveDismissDisabled(viewModel.isBusy)
      .alert(
        L10n.Settings.RegenerateIdentity.Alert.Replace.title,
        isPresented: $viewModel.showingReplaceAlert
      ) {
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
        Button(L10n.Settings.RegenerateIdentity.Alert.Replace.confirm, role: .destructive) {
          Task {
            if await viewModel.replaceIdentity() {
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
    // Large so the radio, the consequences and Generate are all in view without dragging.
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .onDisappear {
      viewModel.cancelGeneration()
    }
  }

  // MARK: - Sections

  /// The optional prefix and Generate. What regenerating does is on the consequence card above;
  /// only what a prefix costs is behind the header's "i".
  private var newKeySection: some View {
    CardFormSection(
      L10n.Settings.RegenerateIdentity.NewKey.header,
      info: L10n.Settings.RegenerateIdentity.Prefix.footer
    ) {
      prefixCard
      generateCard
    }
  }

  private var prefixCard: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        TextField(L10n.Settings.RegenerateIdentity.Prefix.placeholder, text: $viewModel.hexPrefix)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
          .onChange(of: viewModel.hexPrefix) { _, newValue in
            viewModel.sanitizePrefix(newValue)
          }

        if let prefixError = viewModel.prefixError {
          Label(prefixError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(.footnote)
        }
      }
      .padding(.top, 8)
    } label: {
      SettingCardLabel(L10n.Settings.RegenerateIdentity.Prefix.label, systemImage: "textformat.abc", color: .indigo)
    }
    .cardSurface(padding: 12)
  }

  /// Local only: generating never touches the radio, so it stays available while disconnected.
  private var generateCard: some View {
    Button {
      viewModel.generateKey()
    } label: {
      BusyActionCardLabel(
        title: viewModel.isGenerating ? L10n.Settings.RegenerateIdentity.generating : L10n.Settings.RegenerateIdentity.generate,
        systemImage: "dice",
        color: .purple,
        isBusy: viewModel.isGenerating
      )
    }
    .buttonStyle(.plain)
    .disabled(viewModel.isBusy)
  }

  @ViewBuilder
  private func keyPreviewSection(_ key: RegenerateIdentityViewModel.GeneratedKey) -> some View {
    CardFormSection(L10n.Settings.PublicKey.header) {
      ContentCard {
        Text(key.publicKeyHex)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .accessibilityLabel(key.accessibilityLabel)
      }
    }
    CardFormSection(L10n.Settings.PrivateKey.header) {
      ContentCard {
        Text(key.privateKeyHex)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
      }
    }
  }

  private var replaceSection: some View {
    CardFormSection(L10n.Settings.RegenerateIdentity.Replace.header) {
      Button {
        viewModel.showingReplaceAlert = true
      } label: {
        BusyActionCardLabel(
          title: viewModel.isImporting ? L10n.Settings.RegenerateIdentity.importing : L10n.Settings.RegenerateIdentity.replace,
          systemImage: "arrow.triangle.2.circlepath",
          // Red: it replaces the radio's identity for good.
          color: .red,
          isBusy: viewModel.isImporting
        )
      }
      .buttonStyle(.plain)
      // Writes the key to the radio: without a ready connection the confirmed replace would do
      // nothing.
      .radioDisabled(for: appState.connectionState, or: viewModel.isBusy)
    }
  }
}
