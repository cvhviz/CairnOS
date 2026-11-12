import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "HomeTools")

/// The colours of Home's tools that other pages share.
enum HomeToolColors {
  /// Scan & Traffic and Send Advert, one colour for the pair.
  static let lead = ToolSelection.nodeDiscovery.tileColor
}

/// Something the Tools button offers: a tool that opens on Home's stack, or one of the two actions
/// that aren't pages of their own.
enum HomeToolEntry: Hashable {
  case tool(ToolSelection)
  case sendAdvert
  case location

  /// Everything, the two reached for most first.
  static let all: [HomeToolEntry] = [
    .sendAdvert, .tool(.nodeDiscovery), .tool(.tracePath), .location,
    .tool(.networkHealth), .tool(.lineOfSight), .tool(.cli), .tool(.signVerify),
  ]

  var title: String {
    switch self {
    case let .tool(tool): tool.title
    case .sendAdvert: L10n.Tools.Tools.advert
    case .location: L10n.Settings.Location.header
    }
  }

  var subtitle: String {
    switch self {
    case let .tool(tool): tool.subtitle
    case .sendAdvert: L10n.Tools.Tools.Subtitle.advert
    case .location: L10n.Localizable.CarPlay.Gps.sharing
    }
  }

  var systemImage: String {
    switch self {
    case let .tool(tool): tool.systemImage
    case .sendAdvert: "megaphone.fill"
    case .location: "location.fill"
    }
  }

  var color: Color {
    switch self {
    case let .tool(tool): tool.tileColor
    case .sendAdvert: HomeToolColors.lead
    case .location: .green
    }
  }

  /// Nothing but a "connect a radio" page without one. Send Advert needs a ready link, which
  /// `isDisabled` checks on its own.
  var needsRadio: Bool {
    switch self {
    case let .tool(tool): tool.needsRadio
    case .sendAdvert, .location: true
    }
  }

  var identifier: String {
    switch self {
    case let .tool(tool): "home.tools.\(tool)"
    case .sendAdvert: "home.tools.sendAdvert"
    case .location: "home.tools.location"
    }
  }
}

/// The button at the top of Home that holds every tool: it opens `HomeToolsSheet`, and what's picked
/// there opens once the sheet has gone, so a push or a second sheet isn't lost to it. The glyph says
/// an advert was sent or failed for a moment after. Always the same button, varied by value, so the
/// toolbar item keeps one identity (see `DeviceInfoButton`).
struct HomeToolsButton: View {
  @Environment(\.appState) private var appState

  @State private var isPicking = false
  /// What was picked, acted on once the sheet has gone.
  @State private var picked: HomeToolEntry?
  @State private var isChoosingAdvert = false
  /// The last advert's result, for a moment; nil otherwise.
  @State private var advertResult: Bool?

  private var systemImage: String {
    switch advertResult {
    case true?: "checkmark"
    case false?: "exclamationmark.triangle.fill"
    case nil: "square.grid.2x2"
    }
  }

  var body: some View {
    Button {
      isPicking = true
    } label: {
      Label(L10n.Localizable.Tabs.tools, systemImage: systemImage)
        .labelStyle(.iconOnly)
    }
    .help(L10n.Localizable.Tabs.tools)
    .accessibilityIdentifier("home.moreTools")
    #if DEBUG
      // Screenshot runs open the tool picker: `-uiTestToolsSheet YES`.
      .onAppear {
        if UserDefaults.standard.bool(forKey: "uiTestToolsSheet") { isPicking = true }
      }
    #endif
    .sheet(isPresented: $isPicking, onDismiss: actOnPicked) {
      HomeToolsSheet(
        hasNoRadio: appState.connectedDevice == nil,
        canAdvertise: appState.connectionState == .ready
      ) { entry in
        picked = entry
        isPicking = false
      }
    }
    .sheet(isPresented: $isChoosingAdvert) {
      AdvertChoiceSheet { flood in send(flood: flood) }
    }
    .sensoryFeedback(trigger: advertResult) { _, result in
      result.map { $0 ? .success : .error }
    }
  }

  private func actOnPicked() {
    guard let picked else { return }
    self.picked = nil
    switch picked {
    case let .tool(tool):
      appState.navigation.homePath.append(.tool(tool))
    case .sendAdvert:
      isChoosingAdvert = true
    case .location:
      appState.navigation.navigateToSetting(.location)
    }
  }

  private func send(flood: Bool) {
    Task {
      let succeeded: Bool
      do {
        try await appState.sendSelfAdvert(flood: flood)
        succeeded = true
      } catch {
        logger.error("Failed to send advert from Home Tools (flood=\(flood)): \(error.localizedDescription)")
        succeeded = false
      }
      advertResult = succeeded
      try? await Task.sleep(for: .seconds(succeeded ? 2 : 3))
      advertResult = nil
    }
  }
}

/// The tool picker the Tools button opens: a grid of large tiles, one per tool, each in its own
/// colour with what it's for beneath its name. Picking one closes the sheet. The tools that only
/// talk to a radio grey out without one, and say so.
struct HomeToolsSheet: View {
  let hasNoRadio: Bool
  /// A ready link, which Send Advert waits for.
  let canAdvertise: Bool
  let onPick: (HomeToolEntry) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var hasAppeared = false

  private var columns: [GridItem] {
    let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
    return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
  }

  private func isDisabled(_ entry: HomeToolEntry) -> Bool {
    (entry.needsRadio && hasNoRadio) || (entry == .sendAdvert && !canAdvertise)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 12) {
          ForEach(Array(HomeToolEntry.all.enumerated()), id: \.element) { index, entry in
            let isDisabled = isDisabled(entry)
            Button {
              onPick(entry)
            } label: {
              HomeToolTile(entry: entry, isDisabled: isDisabled)
            }
            .buttonStyle(HomeToolTileButtonStyle())
            .disabled(isDisabled)
            .accessibilityIdentifier(entry.identifier)
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.92)
            .animation(
              reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.04),
              value: hasAppeared
            )
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
      }
      .scrollBounceBehavior(.basedOnSize)
      .flashingNavigationTitle(L10n.Localizable.Tabs.tools)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
    }
    // Half the screen reaches the first rows with the thumb; the rest is a drag away.
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .onAppear { hasAppeared = true }
  }
}

/// One tool in the picker: its glyph on a tile of its colour, its name, and what it's for.
private struct HomeToolTile: View {
  let entry: HomeToolEntry
  let isDisabled: Bool

  @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 44
  @ScaledMetric(relativeTo: .headline) private var minHeight: CGFloat = 112

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: entry.systemImage)
        .font(.system(size: glyphSize * 0.46, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: glyphSize, height: glyphSize)
        .background(entry.color.gradient, in: .rect(cornerRadius: glyphSize * 0.28, style: .continuous))
        .shadow(color: entry.color.opacity(0.35), radius: 6, y: 3)
        .accessibilityHidden(true)

      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)
        Text(isDisabled ? L10n.Localizable.Home.noRadio : entry.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
    .padding(14)
    .background {
      let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
      ZStack {
        shape.fill(Color(.secondarySystemGroupedBackground))
        shape.fill(
          LinearGradient(
            colors: [entry.color.opacity(0.2), entry.color.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        shape.strokeBorder(entry.color.opacity(0.3), lineWidth: 1)
      }
    }
    .contentShape(.rect(cornerRadius: 20, style: .continuous))
    .opacity(isDisabled ? 0.45 : 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(entry.title)
    .accessibilityValue(isDisabled ? L10n.Localizable.Home.noRadio : entry.subtitle)
    .accessibilityAddTraits(.isButton)
  }
}

/// A press that sinks the tile a little, with a tap of haptics as it opens.
private struct HomeToolTileButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .brightness(configuration.isPressed ? -0.03 : 0)
      .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
      .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
  }
}
