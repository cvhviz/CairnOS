import Foundation

/// `Identifiable` by its `major.minor` version so a release drives `.sheet(item:)`.
struct WhatsNewRelease: Identifiable {
  let version: WhatsNewVersion
  let items: [WhatsNewItem]
  /// The full release notes, when there is a page for them; the sheet hides its link otherwise.
  let releaseNotesURL: URL?

  var id: WhatsNewVersion {
    version
  }
}
