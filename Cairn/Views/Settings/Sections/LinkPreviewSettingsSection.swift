import CairnServices
import SwiftUI

/// Settings section for content fetched over the internet rather than the mesh. One master
/// (`linkPreviewsEnabled`) governs both link-preview cards and inline images; the DM/channel
/// scope sub-toggles and GIF autoplay nest beneath it. Map thumbnails sit here too, since they
/// carry the same privacy trade-off. Their switch gates the third-party tile request fired from
/// `MapPreviewFragmentView.onAppear`; when off, `MessageFragmentBuilder` skips the fragment
/// entirely and the coordinate text in the message body remains tappable.
struct LinkPreviewSettingsSection: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(AppStorageKey.linkPreviewsEnabled.rawValue) private var previewsEnabled = AppStorageKey.defaultLinkPreviewsEnabled
  @AppStorage(AppStorageKey.linkPreviewsAutoResolveDM.rawValue) private var autoResolveDM = AppStorageKey.defaultLinkPreviewsAutoResolveDM
  @AppStorage(AppStorageKey.linkPreviewsAutoResolveChannels.rawValue) private var autoResolveChannels = AppStorageKey.defaultLinkPreviewsAutoResolveChannels
  @AppStorage(AppStorageKey.autoPlayGIFs.rawValue) private var autoPlayGIFs = AppStorageKey.defaultAutoPlayGIFs
  @AppStorage(AppStorageKey.showMapPreviewThumbnails.rawValue)
  private var showMapPreviewThumbnails = AppStorageKey.defaultShowMapPreviewThumbnails

  var body: some View {
    CardFormSection(L10n.Settings.LinkPreviews.header, info: infoMessage) {
      ToggleCard(L10n.Settings.LinkPreviews.toggle, systemImage: "link", color: .blue, isOn: $previewsEnabled)

      if previewsEnabled {
        ToggleCard(L10n.Settings.LinkPreviews.showInDMs, systemImage: "person.fill", color: .blue, isOn: $autoResolveDM)
        ToggleCard(L10n.Settings.LinkPreviews.showInChannels, systemImage: "number", color: .blue, isOn: $autoResolveChannels)
        ToggleCard(
          L10n.Settings.InlineImages.autoPlayGifs,
          systemImage: "play.rectangle.fill",
          color: .pink,
          isOn: $autoPlayGIFs
        )
      }

      ToggleCard(L10n.Settings.MapPreviews.toggle, systemImage: "map.fill", color: .teal, isOn: $showMapPreviewThumbnails)
    }
  }

  /// The privacy trade-off of both switches, plus why GIFs stay still under Reduce Motion.
  private var infoMessage: String {
    var parts = [L10n.Settings.LinkPreviews.footer]
    if previewsEnabled, reduceMotion {
      parts.append(L10n.Settings.LinkPreviews.reduceMotionNote)
    }
    parts.append(L10n.Settings.MapPreviews.footer)
    return parts.joined(separator: "\n\n")
  }
}

#Preview {
  CardForm {
    LinkPreviewSettingsSection()
  }
}
