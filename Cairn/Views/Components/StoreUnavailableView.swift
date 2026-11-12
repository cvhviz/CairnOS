import SwiftUI

/// Shown in place of the app when its database could not be opened at launch
/// (`AppLaunchController.storeFailure`). The data is left exactly as it is: the only action is to
/// try again, and the error is shown so a tester can send it.
struct StoreUnavailableView: View {
  let details: String
  let isRetrying: Bool
  let retry: () async -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        Image(systemName: "externaldrive.badge.exclamationmark")
          .font(.system(size: 52))
          .foregroundStyle(.orange)
          .accessibilityHidden(true)

        Text(L10n.Localizable.StoreUnavailable.title)
          .font(.title2.bold())
          .multilineTextAlignment(.center)

        Text(L10n.Localizable.StoreUnavailable.message)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Button {
          Task { await retry() }
        } label: {
          Text(isRetrying ? L10n.Localizable.StoreUnavailable.retrying : L10n.Localizable.Common.tryAgain)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isRetrying)

        VStack(alignment: .leading, spacing: 6) {
          Text(L10n.Localizable.StoreUnavailable.details)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(details)
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: 480)
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
  }
}

#Preview {
  StoreUnavailableView(details: "NSCocoaErrorDomain 134110: An error occurred during persistent store migration.", isRetrying: false) {}
}
