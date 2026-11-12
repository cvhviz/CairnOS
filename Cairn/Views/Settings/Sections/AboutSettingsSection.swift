import SwiftUI

/// The app's name and maker, the same in every language. The marketing version and build come from
/// the bundle, so they are never repeated here.
enum AppIdentity {
  /// Written in capitals wherever the app names itself (the Home title, About, the home screen).
  static let name = "CAIRN"
  /// How VoiceOver and Siri should say it: a word, not five letters.
  static let spokenName = "Cairn"
  static let developer = "Christopher Van Hoose"
  static let studio = "CVH Visuals"
  /// The App Store's page for writing a review, which opens every time, unlike Apple's own prompt.
  static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6819076554?action=write-review")!
}

/// Settings → About: the app (the hero card, when this isn't under the hub, which shows it at the
/// top), support for Cairn's development, the support links, the MeshCore network's pages with the credits folded beside
/// them, the developer's other apps, an Advanced fold for log export (`DiagnosticsSection`) and
/// debug tools, and the developer as a quiet centered footer.
struct AboutSettingsSection: View {
  /// The About content: the hero, support links, MeshCore links and credits, the developer footer.
  /// Off on Settings › Advanced, which keeps only Diagnostics.
  var showsAbout = true
  /// The log export. Off on Settings › About: it's a tool, on Settings › Advanced.
  var showsDiagnostics = true
  @State private var exportedLogFile: ExportedLogFile?
  /// The credits are read once, so they fold away beside the MeshCore links until asked for.
  @State private var showsCredits = false

  var body: some View {
    // One stack rather than a Group, so the share sheet below attaches once.
    VStack(alignment: .leading, spacing: 20) {
      if showsAbout {
        CardFormSection {
          AboutHeroCard()
        }

        SupportDevelopmentSection()

        AppSupportSection()

        // The MeshCore network's own pages (they open in the browser) with what the app is built on.
        // Short link titles under the header that already names MeshCore, with the full name kept
        // for VoiceOver.
        CardFormSection(L10n.Settings.About.Meshcore.header) {
          MetricTileGrid {
            ExternalLinkTile(
              L10n.Settings.About.Link.website,
              accessibilityLabel: L10n.Settings.About.website,
              systemImage: "globe",
              color: .blue,
              url: URL(string: "https://meshcore.io")!
            )
            ExternalLinkTile(
              L10n.Settings.About.Link.onlineMap,
              accessibilityLabel: L10n.Settings.About.onlineMap,
              systemImage: "map.fill",
              color: .teal,
              url: URL(string: "https://map.meshcore.io/")!
            )
          }

          NodeDisclosureCard(
            L10n.Settings.About.Credits.header,
            systemImage: "heart.text.square.fill",
            color: .pink,
            isExpanded: $showsCredits
          ) {
            CreditRow(text: L10n.Settings.About.Credits.meshcore, systemImage: "antenna.radiowaves.left.and.right")
            CreditRow(text: L10n.Settings.About.Credits.cairn, systemImage: "square.stack.3d.up.fill")
            // Small map previews hide MapLibre's attribution button, so the map credits live here.
            CreditRow(text: L10n.Settings.About.Credits.maps, systemImage: "map")
          }
        }

        MoreAppsSection()
      }

      if showsDiagnostics {
        DiagnosticsSection(exportedFile: $exportedLogFile)
      }

      if showsAbout {
        AboutDeveloperFooter()
      }
    }
    .sheet(item: $exportedLogFile) { file in
      ActivityView(activityItems: [file.url])
    }
    // Here rather than on the tip jar, which is absent until the tips load and so couldn't try
    // again: each visit retries until they do.
    .task {
      if showsAbout { await TipJarStore.shared.loadProducts() }
    }
  }
}

/// Where to get help with Cairn and find out more: the Cairn page, the support form, bug reports
/// and the firmware on GitHub, the privacy policy and the TestFlight beta. On Settings › About, which
/// the Dashboard's CAIRN title opens.
struct AppSupportSection: View {
  private static let links: [(title: String, image: String, color: Color, url: String)] = [
    (L10n.Settings.About.Support.website, "globe", .teal, "https://www.cvhvisuals.com/cairn.html"),
    (L10n.Settings.About.Support.getSupport, "questionmark.bubble.fill", .blue,
     "https://www.cvhvisuals.com/contact.html?topic=support&app=Cairn"),
    (L10n.Settings.About.Support.reportBug, "ladybug.fill", .orange, "https://github.com/cvhviz/Cairn/issues"),
    (L10n.Settings.About.Support.firmware, "cpu.fill", .indigo, "https://github.com/cvhviz/Cairn/releases/latest"),
    (L10n.Settings.About.Support.privacy, "hand.raised.fill", .gray, "https://www.cvhvisuals.com/privacy-policy.html#cairn"),
    (L10n.Settings.About.Support.beta, "testtube.2", .purple, "https://testflight.apple.com/join/MJJpsayp"),
  ]

  var body: some View {
    CardFormSection(L10n.Settings.About.Support.header) {
      ForEach(Array(stride(from: 0, to: Self.links.count, by: 2)), id: \.self) { i in
        MetricTileGrid {
          ForEach(Self.links[i..<min(i + 2, Self.links.count)], id: \.url) { link in
            ExternalLinkTile(
              link.title,
              accessibilityLabel: link.title,
              systemImage: link.image,
              color: link.color,
              url: URL(string: link.url)!
            )
          }
        }
      }
    }
  }
}

/// The developer's other apps, from the Apps page on cvhvisuals.com: each with its own icon,
/// opening its store page (the App Store, or TestFlight for a beta, marked as one), then the Apps
/// page for the full list.
struct MoreAppsSection: View {
  private struct App {
    let name: String
    let summary: String
    /// The app's icon in the asset catalog (from cvhvisuals.com/assets/img/apps).
    let icon: String
    let url: String
    var isBeta = false
  }

  @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40

  private static let apps: [App] = [
    App(name: "MyRate+", summary: L10n.Settings.About.MoreApps.myRate,
        icon: "MoreAppsMyRate",
        url: "https://apps.apple.com/us/app/myrate/id6758914473"),
    App(name: "GenR8", summary: L10n.Settings.About.MoreApps.genr8,
        icon: "MoreAppsGenR8",
        url: "https://apps.apple.com/us/app/genr8/id6751822886"),
    App(name: "ResEditor", summary: L10n.Settings.About.MoreApps.resEditor,
        icon: "MoreAppsResEditor",
        url: "https://apps.apple.com/us/app/reseditor/id6752496598"),
    App(name: "Switcher Pro", summary: L10n.Settings.About.MoreApps.switcherPro,
        icon: "MoreAppsSwitcherPro",
        url: "https://apps.apple.com/us/app/switcher-pro/id6754262874"),
    App(name: "For Isaiah", summary: L10n.Settings.About.MoreApps.forIsaiah,
        icon: "MoreAppsForIsaiah",
        url: "https://apps.apple.com/us/app/for-isaiah/id6763844348"),
  ]

  var body: some View {
    CardFormSection(L10n.Settings.About.MoreApps.header) {
      ForEach(Self.apps, id: \.name) { app in
        Link(destination: URL(string: app.url)!) {
          HStack(spacing: 12) {
            // The icon as the Home Screen shows it: a continuous rounded square with a hairline.
            Image(app.icon)
              .resizable()
              .scaledToFill()
              .frame(width: iconSize, height: iconSize)
              .clipShape(.rect(cornerRadius: iconSize * 0.225, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: iconSize * 0.225, style: .continuous)
                  .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
              }
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(app.name)
                  .font(.body.weight(.semibold))
                  .foregroundStyle(Color.primary)
                if app.isBeta {
                  Text(L10n.Settings.About.MoreApps.beta)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15), in: .capsule)
                }
              }
              Text(app.summary)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color(.tertiaryLabel))
              .accessibilityHidden(true)
          }
          .cardSurface()
          .cardInteractionShape()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
      }

      ExternalLinkTile(
        L10n.Settings.About.MoreApps.allApps,
        accessibilityLabel: L10n.Settings.About.MoreApps.allApps,
        systemImage: "square.grid.2x2.fill",
        color: .gray,
        url: URL(string: "https://www.cvhvisuals.com/apps.html")!
      )
    }
  }
}


/// The app at the top of Settings: its icon large, its name, what it is, and its version and
/// build (shown only here), centered on a card washed with the accent so it reads as the page's
/// header rather than one more setting.
struct AboutHeroCard: View {
  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(spacing: 8) {
      // The CAIRN lockup (the pebbles on the ridge over the wordmark): it carries the name, so no
      // title text. Light mode takes the dark-wordmark version.
      Image("CairnLockup")
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 220)
        .padding(.bottom, 6)
        .accessibilityLabel(AppIdentity.spokenName)
        .accessibilityAddTraits(.isHeader)
      Text(L10n.Settings.About.tagline)
        .font(.subheadline)
        .foregroundStyle(Color.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Text(L10n.Settings.About.versionLine(Bundle.main.appVersion, Bundle.main.appBuild))
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(theme.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(theme.accentColor.opacity(0.14), in: .capsule)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
    .padding(.horizontal, 16)
    .background {
      ZStack {
        CardBackground()
        CardStyle.shape.fill(
          LinearGradient(
            colors: [theme.accentColor.opacity(0.18), theme.accentColor.opacity(0.03)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        CardStyle.shape.strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Who made the app, centered and quiet at the foot of Settings: the studio's logo, the
/// developer, the studio and role.
struct AboutDeveloperFooter: View {
  @Environment(\.appTheme) private var theme

  var body: some View {
    VStack(spacing: 4) {
      Image("CVHVisualsLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 36, height: 36)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
      VStack(spacing: 2) {
        Text(AppIdentity.developer)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.primary)
        // The studio's wordmark in place of its name (dark letters in light mode)
        Image("CVHVisualsWordmark")
          .resizable()
          .scaledToFit()
          .frame(height: 13)
          .padding(.vertical, 3)
        Text(L10n.Settings.About.Developer.role)
          .font(.footnote)
          .foregroundStyle(Color.secondary)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "\(L10n.Settings.About.Developer.header): \(AppIdentity.developer), \(AppIdentity.studio), "
          + L10n.Settings.About.Developer.role
      )
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
    .padding(.bottom, 4)
  }
}

/// The app icon as the Home Screen shows it: the transparent cairn mark over the icon's dark
/// background (a teal glow fading to near-black), clipped to a continuous rounded square. Drawn
/// from the mark rather than shipping a second full icon bitmap.
struct CairnAppIcon: View {
  let size: CGFloat

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
    Image("CairnMark")
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .background(
        RadialGradient(
          colors: [Color(red: 0.027, green: 0.122, blue: 0.114), Color(red: 0.039, green: 0.043, blue: 0.047)],
          center: .center,
          startRadius: 0,
          endRadius: size * 0.7
        )
      )
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
  }
}

/// One credit: a small glyph and a line of text.
private struct CreditRow: View {
  let text: String
  let systemImage: String

  var body: some View {
    Label {
      Text(text)
        .font(.footnote)
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview {
  CardForm {
    AboutSettingsSection()
  }
}

/// A card that opens a web page outside the app: an icon tile, its title, and an outward arrow
/// (not a chevron) because it leaves the app.
struct ExternalLinkTile: View {
  let title: String
  let accessibilityLabel: String
  let systemImage: String
  let color: Color
  let url: URL

  init(_ title: String, accessibilityLabel: String, systemImage: String, color: Color, url: URL) {
    self.title = title
    self.accessibilityLabel = accessibilityLabel
    self.systemImage = systemImage
    self.color = color
    self.url = url
  }

  var body: some View {
    Link(destination: url) {
      HStack(spacing: 10) {
        IconTile(systemImage: systemImage, color: color)
          .accessibilityHidden(true)
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.primary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
          .accessibilityHidden(true)
      }
      .frame(maxHeight: .infinity)
      .cardSurface(padding: 10)
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }
}
