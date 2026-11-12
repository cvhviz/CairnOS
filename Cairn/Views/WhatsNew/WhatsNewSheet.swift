import SwiftUI

/// The "What's New" sheet. Non-safety chrome, so glass on the footer buttons is
/// allowed; Continue, Support Development, and swipe-to-dismiss share one dismiss path that
/// persists the baseline.
struct WhatsNewSheet: View {
  let release: WhatsNewRelease

  @Environment(\.dismiss) private var dismiss

  fileprivate enum Metrics {
    static let titleTopPadding: CGFloat = 32
    static let rowSpacing: CGFloat = 28
    static let titleToRowsSpacing: CGFloat = 36
    static let symbolColumnWidth: CGFloat = 44
    static let symbolToTextSpacing: CGFloat = 16
    static let titleToBodySpacing: CGFloat = 4
    static let buttonSpacing: CGFloat = 12
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Metrics.titleToRowsSpacing) {
        Text(L10n.WhatsNew.WhatsNew.title)
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, alignment: .center)
          .accessibilityHeading(.h1)
          .padding(.top, Metrics.titleTopPadding)

        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
          ForEach(release.items) { item in
            WhatsNewRow(item: item)
          }
        }

        if let releaseNotesURL = release.releaseNotesURL {
          Link(L10n.WhatsNew.WhatsNew.fullReleaseNotes, destination: releaseNotesURL)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .center)
        }
      }
      .padding()
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: Metrics.buttonSpacing) {
        Button {
          dismiss()
        } label: {
          Text(L10n.WhatsNew.WhatsNew.continueButton)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .liquidGlassProminentButtonStyle()
      }
      .padding()
    }
    .presentationDragIndicator(.hidden)
  }

}

/// A decorative SF Symbol plus the feature's title and description; VoiceOver reads
/// the pair as one element.
private struct WhatsNewRow: View {
  let item: WhatsNewItem

  var body: some View {
    HStack(alignment: .top, spacing: WhatsNewSheet.Metrics.symbolToTextSpacing) {
      (item.isCustomSymbol ? Image(item.symbol) : Image(systemName: item.symbol))
        .font(.title)
        .foregroundStyle(.tint)
        .frame(width: WhatsNewSheet.Metrics.symbolColumnWidth)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: WhatsNewSheet.Metrics.titleToBodySpacing) {
        Text(item.title)
          .font(.headline)
        Text(item.description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

#Preview {
  if let release = WhatsNewCatalog.releases.first {
    Color.clear.sheet(isPresented: .constant(true)) {
      WhatsNewSheet(release: release)
    }
    .environment(\.appState, AppState())
  }
}
