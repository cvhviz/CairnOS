import CairnServices
import SwiftUI
import UIKit

/// Troubleshooting sheet for when devices don't appear in the ASK picker
/// Per Apple Developer Forums: Factory-reset devices won't appear until the stale
/// system pairing is removed via removeAccessory()
struct TroubleshootingSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var isClearing = false

  var body: some View {
    NavigationStack {
      CardForm {
        CardFormSection(L10n.Onboarding.Troubleshooting.BasicChecks.header) {
          ContentCard {
            checkRow(L10n.Onboarding.Troubleshooting.BasicChecks.powerOn, systemImage: "power")
            Divider()
            checkRow(L10n.Onboarding.Troubleshooting.BasicChecks.moveCloser, systemImage: "iphone.radiowaves.left.and.right")
            Divider()
            checkRow(L10n.Onboarding.Troubleshooting.BasicChecks.notConnectedElsewhere, systemImage: "app.dashed")
            Divider()
            checkRow(L10n.Onboarding.Troubleshooting.BasicChecks.restart, systemImage: "arrow.clockwise")
          }
        }

        CardFormSection(
          L10n.Onboarding.Troubleshooting.FactoryReset.header,
          footer: appState.connectionManager.pairedAccessoriesCount == 0
            ? L10n.Onboarding.Troubleshooting.FactoryReset.noPairings
            : L10n.Onboarding.Troubleshooting.FactoryReset.pairingsFound(appState.connectionManager.pairedAccessoriesCount)
        ) {
          ContentCard {
            Text(L10n.Onboarding.Troubleshooting.FactoryReset.explanation)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Text(L10n.Onboarding.Troubleshooting.FactoryReset.confirmationNote)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Button {
            clearStalePairings()
          } label: {
            BusyActionCardLabel(
              title: L10n.Onboarding.Troubleshooting.FactoryReset.clearPairing,
              systemImage: "trash",
              color: .red,
              isBusy: isClearing
            )
          }
          .buttonStyle(.plain)
          .disabled(isClearing || appState.connectionManager.pairedAccessoriesCount == 0)
        }

        CardFormSection(L10n.Onboarding.Troubleshooting.SystemSettings.header) {
          ContentCard {
            Text(L10n.Onboarding.Troubleshooting.SystemSettings.manageAccessories)
              .font(.subheadline)
              .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Onboarding.Troubleshooting.SystemSettings.path)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          ActionCard(
            L10n.Onboarding.Troubleshooting.SystemSettings.openSettings,
            systemImage: "gear",
            color: .gray
          ) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              openURL(url)
            }
          }
        }

        CardFormSection(L10n.Onboarding.Troubleshooting.StillNotAppearing.header) {
          ContentCard {
            Text(L10n.Onboarding.Troubleshooting.StillNotAppearing.body)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .flashingNavigationTitle(L10n.Onboarding.Troubleshooting.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(L10n.Localizable.Common.done) {
            dismiss()
          }
        }
      }
    }
  }

  private func checkRow(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func clearStalePairings() {
    isClearing = true

    Task {
      defer { isClearing = false }

      await appState.connectionManager.clearStalePairings()

      dismiss()
    }
  }
}
