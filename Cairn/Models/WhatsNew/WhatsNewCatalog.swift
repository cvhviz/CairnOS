import Foundation

/// Per-release What's New notes, keyed by the `major.minor` they belong to. Add a
/// release as one `WhatsNewRelease` plus its `L10n` strings; it presents once on upgrade.
enum WhatsNewCatalog {
  static let releases: [WhatsNewRelease] = [
    WhatsNewRelease(
      version: WhatsNewVersion(major: 1, minor: 0),
      items: [
        WhatsNewItem(
          symbol: AppTab.home.symbolName,
          isCustomSymbol: AppTab.home.isCustomSymbol,
          title: L10n.WhatsNew.WhatsNew.Home.title,
          description: L10n.WhatsNew.WhatsNew.Home.description
        ),
        WhatsNewItem(
          symbol: "rectangle.on.rectangle",
          title: L10n.WhatsNew.WhatsNew.Cards.title,
          description: L10n.WhatsNew.WhatsNew.Cards.description
        ),
        WhatsNewItem(
          symbol: "location.north.circle.fill",
          title: L10n.WhatsNew.WhatsNew.Gnss.title,
          description: L10n.WhatsNew.WhatsNew.Gnss.description
        ),
        WhatsNewItem(
          symbol: "scope",
          title: L10n.WhatsNew.WhatsNew.Aim.title,
          description: L10n.WhatsNew.WhatsNew.Aim.description
        ),
        WhatsNewItem(
          symbol: "chart.xyaxis.line",
          title: L10n.WhatsNew.WhatsNew.Spectrum.title,
          description: L10n.WhatsNew.WhatsNew.Spectrum.description
        ),
        WhatsNewItem(
          symbol: "slider.horizontal.3",
          title: L10n.WhatsNew.WhatsNew.Settings.title,
          description: L10n.WhatsNew.WhatsNew.Settings.description
        )
      ],
      // Cairn has no public release notes page yet, so the sheet shows no link.
      releaseNotesURL: nil
    )
  ]
}
