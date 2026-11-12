import CairnServices
import SwiftUI

/// When the support pop-up may show: only after real use, and rarely. Apple's own review prompt
/// follows it, and decides whether to appear: up to three times a year, and never in TestFlight.
enum SupportPromptSchedule {
  /// Days since first use, and connections to a radio, before it may show.
  static let minimumDays: TimeInterval = 7
  static let minimumConnections = 5
  /// Days before it may show again.
  static let repeatDays: TimeInterval = 120

  private static let day: TimeInterval = 24 * 60 * 60

  static func shouldShow(firstUse: Date, connections: Int, lastShown: Date?, now: Date) -> Bool {
    guard connections >= minimumConnections,
          now.timeIntervalSince(firstUse) >= minimumDays * day else { return false }
    guard let lastShown else { return true }
    return now.timeIntervalSince(lastShown) >= repeatDays * day
  }

  /// Counts a connection, and says whether the pop-up is due. It stays due until `markShown`.
  @MainActor
  static func noteConnection(in defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
    let firstUseKey = AppStorageKey.supportPromptFirstUse.rawValue
    let connectionsKey = AppStorageKey.supportPromptConnections.rawValue
    let lastShownKey = AppStorageKey.supportPromptLastShown.rawValue
    if defaults.object(forKey: firstUseKey) == nil {
      defaults.set(now.timeIntervalSince1970, forKey: firstUseKey)
    }
    let connections = defaults.integer(forKey: connectionsKey) + 1
    defaults.set(connections, forKey: connectionsKey)
    let lastShown = defaults.object(forKey: lastShownKey) == nil
      ? nil
      : Date(timeIntervalSince1970: defaults.double(forKey: lastShownKey))
    return shouldShow(
      firstUse: Date(timeIntervalSince1970: defaults.double(forKey: firstUseKey)),
      connections: connections,
      lastShown: lastShown,
      now: now
    )
  }

  @MainActor
  static func markShown(in defaults: UserDefaults = .standard, now: Date = .now) {
    defaults.set(now.timeIntervalSince1970, forKey: AppStorageKey.supportPromptLastShown.rawValue)
  }
}

/// Settings › About's support for Cairn's continued development: the tips with why they matter (the
/// message alone while the App Store has no tips to offer), and the App Store's review page, which
/// helps others find the app.
struct SupportDevelopmentSection: View {
  @Environment(\.appTheme) private var theme
  @State private var store = TipJarStore.shared

  var body: some View {
    CardFormSection {
      if store.loadState == .loaded {
        TipJarRow()
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Label {
            Text(L10n.Settings.About.TipJar.header)
          } icon: {
            Image(systemName: "cup.and.saucer.fill")
              .foregroundStyle(theme.accentColor)
          }
          .font(.subheadline.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
          Text(L10n.Settings.About.TipJar.footer)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
      }
      ExternalLinkTile(
        L10n.Settings.About.Review.title,
        accessibilityLabel: "\(L10n.Settings.About.Review.title). \(L10n.Settings.About.Review.detail)",
        systemImage: "star.fill",
        color: .yellow,
        url: AppIdentity.writeReviewURL
      )
      .accessibilityIdentifier("about.review")
    }
  }
}

/// The occasional pop-up asking for support: why it matters, the tips, and a way out. It has no review
/// button: App Review allows only Apple's own review prompt to ask, so Home calls that as this closes.
struct SupportPromptSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        CairnAppIcon(size: 64)
          .accessibilityHidden(true)
        Text(L10n.Settings.About.SupportPrompt.title)
          .font(.title3.weight(.bold))
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
        Text(L10n.Settings.About.SupportPrompt.message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        TipJarRow()
        Button(L10n.Settings.About.Support.done) { dismiss() }
          .font(.headline)
          .accessibilityIdentifier("supportPrompt.done")
      }
      .padding(.horizontal, 24)
      .padding(.top, 28)
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}
