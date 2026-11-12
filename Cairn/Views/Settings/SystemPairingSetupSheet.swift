import SwiftUI

/// Explains that ASK-authorized radios must be forgotten before they can be added.
struct SystemPairingSetupSheet: View {
  let prompt: SystemPairingSetupPrompt
  let onForget: () -> Void
  let onCancel: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var isPlural: Bool {
    prompt.accessories.count > 1
  }

  var body: some View {
    NavigationStack {
      // A card form, so a long accessory list and large text scroll instead of running off the
      // sheet and taking the Forget card with them.
      CardForm {
        VStack(spacing: 8) {
          Text(title)
            .font(.title2.bold())
            .accessibilityHeading(.h1)
          Text(isPlural
            ? L10n.Settings.DeviceSelection.setupMessagePlural
            : L10n.Settings.DeviceSelection.setupMessage)
            .font(.body)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .cardSurface(padding: 16)

        if isPlural {
          CardFormSection {
            ForEach(prompt.accessories) { accessory in
              SettingCardLabel(accessory.name, systemImage: "antenna.radiowaves.left.and.right", color: .green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(padding: 12)
            }
          }
        }

        // The reassurance stays visible beside the destructive action it qualifies.
        CardFormSection(footer: L10n.Settings.DeviceSelection.setupConversations) {
          ActionCard(forgetTitle, systemImage: "trash", role: .destructive, action: onForget)
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel, action: onCancel)
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var title: String {
    if prompt.accessories.count == 1, let name = prompt.accessories.first?.name {
      return L10n.Settings.DeviceSelection.setupTitle(name)
    }
    return L10n.Settings.DeviceSelection.setupTitleGeneric
  }

  private var forgetTitle: String {
    isPlural
      ? L10n.Settings.DeviceSelection.forgetTheseDevices
      : L10n.Settings.DeviceSelection.forgetThisDevice
  }
}

#Preview {
  Color.clear.sheet(isPresented: .constant(true)) {
    SystemPairingSetupSheet(
      prompt: SystemPairingSetupPrompt(
        accessories: [SystemPairedAccessory(id: UUID(), name: "Radio")]
      ),
      onForget: {},
      onCancel: {}
    )
  }
}
