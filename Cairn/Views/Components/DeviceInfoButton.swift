import CairnServices
import SwiftUI

/// Opens the connected radio's Device Info over the page, the disconnected page when no radio is
/// linked, from the title on each tab. On iPhone it opens in Settings' sheet; at regular width
/// (iPad), where Settings covers the tabs with its hub beside its page, as a sheet of its own over
/// the page, so it never moves Settings' page.
///
/// Always the same Button whatever the link's state (only the label's values change), so the hosted
/// toolbar item keeps its identity: swapping view types mid-update crashes the iOS 26 bar.
struct DeviceInfoButton<Label: View>: View {
  @Environment(\.appState) private var appState
  @Environment(\.opensDeviceInfoAsSheet) private var opensDeviceInfoAsSheet
  @ViewBuilder let label: () -> Label

  var body: some View {
    Button {
      // A phone opens it in Settings' sheet over the hub: Back on the left goes to Settings, and
      // the page's Disconnect is on the right. At regular width it opens as its own sheet.
      if opensDeviceInfoAsSheet {
        appState.navigation.deviceInfoSheet.open()
      } else {
        appState.navigation.navigateToSettingOverHub(.deviceInfo)
      }
    } label: {
      label()
    }
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(L10n.Settings.BleStatus.hint)
    #if DEBUG
      // Screenshot runs open the sheet: `-uiTestDeviceInfoSheet YES`.
      .onAppear {
        if opensDeviceInfoAsSheet, UserDefaults.standard.bool(forKey: "uiTestDeviceInfoSheet") {
          appState.navigation.deviceInfoSheet.open()
        }
      }
    #endif
  }

  /// "Ready, Basecamp", or "Disconnected": the link's state and the radio on it.
  private var accessibilityValue: String {
    let state = HomeStatusLines.linkTitle(appState.connectionState)
    guard let name = appState.connectedDevice?.nodeName else { return state }
    return "\(state), \(name)"
  }
}

extension EnvironmentValues {
  /// Device Info opens as a sheet over the page (regular width, `MainTabView`) rather than in
  /// Settings. Set at the root: a split view's list column reports a compact size class.
  @Entry var opensDeviceInfoAsSheet = false
}

// MARK: - Device Info Sheet Flow

/// Device Info's sheet on an iPad: it opens over the page it was opened from and closes back to
/// it, touching neither Settings' path nor whether Settings shows. Two pages leave it for
/// Settings: the firmware card's Firmware Update (it holds the radio's pages there while the board
/// installs, through the link's planned drop) and the toolbar's Connections. The sheet closes
/// first and Settings opens on the page once it has gone, never two sheets at once.
struct DeviceInfoSheetFlow: Equatable {
  var isPresented = false
  /// The Settings page a card asked for; taken once when the sheet has gone.
  private(set) var handOff: SettingsDetail?

  mutating func open() {
    handOff = nil
    isPresented = true
  }

  /// The firmware card's Firmware Update: close the sheet, and hand over once it has gone.
  mutating func requestFirmwareUpdate() {
    request(.firmwareUpdate)
  }

  /// The toolbar's Connections: close the sheet, and hand over once it has gone.
  mutating func requestConnections() {
    request(.connections)
  }

  /// A Radio Settings row: close the sheet, and hand that page over once it has gone.
  mutating func requestSetting(_ page: SettingsDetail) {
    request(page)
  }

  private mutating func request(_ page: SettingsDetail) {
    handOff = page
    isPresented = false
  }

  /// The sheet has gone (Done, a swipe, or a hand-off).
  @MainActor
  mutating func dismissed(navigation: NavigationCoordinator) {
    isPresented = false
    guard let page = handOff else { return }
    handOff = nil
    navigation.navigateToSetting(page)
  }
}

// MARK: - Bar title

/// A bar's centre title with the Cairn mark to its left, for one capsule around both.
struct MarkedBarTitle<Title: View>: View {
  let markSize: CGFloat
  @ViewBuilder let title: () -> Title

  private static var spacing: CGFloat { 6 }
  /// The mark stops growing with the title's text, which the bar caps: a scaled metric read outside
  /// that cap would otherwise grow the capsule out of the bar at the largest text sizes.
  private static var largestMark: CGFloat { 30 }

  static func cappedMark(_ size: CGFloat) -> CGFloat {
    min(size, largestMark)
  }

  /// The bar centres the whole capsule; moved this far, the title itself is centred, under the Dynamic
  /// Island, with the mark hanging to its left.
  static func centeringOffset(markSize: CGFloat) -> CGFloat {
    -(cappedMark(markSize) + spacing) / 2
  }

  var body: some View {
    HStack(spacing: Self.spacing) {
      CairnStonesMark(size: Self.cappedMark(markSize))
        .accessibilityHidden(true)
      title()
    }
  }
}

/// A page's name with the mark beside it, as the tabs' titles have it, on its capsule, for a title that
/// doesn't open anything. The bar's title item for a page that floats over a map or sits in a sheet.
struct MarkedPageTitle: View {
  let title: String
  @ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 22

  var body: some View {
    MarkedBarTitle(markSize: markSize) {
      Text(title)
        .font(.headline)
        .lineLimit(1)
    }
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .radioActivityFlash()
    .background(.regularMaterial, in: .capsule)
    .offset(x: MarkedBarTitle<EmptyView>.centeringOffset(markSize: markSize))
    // The navigation title already names the page for VoiceOver.
    .accessibilityHidden(true)
  }
}

extension View {
  /// This page's navigation title, shown with the mark and the radio's RX/TX LED (`MarkedPageTitle`).
  func markedNavigationTitle(_ title: String) -> some View {
    navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .principal) {
          MarkedPageTitle(title: title)
        }
      }
  }
}

/// The Cairn mark's stones in their own colours, filling a square of `size`.
struct CairnStonesMark: View {
  let size: CGFloat
  /// The artwork's stones fill only 140 of its 256 points; drawn this much larger, they fill
  /// `size` and the transparent margin spills harmlessly past it.
  private static let artworkScale: CGFloat = 256 / 140

  var body: some View {
    Image("CairnMark")
      .renderingMode(.original)
      .resizable()
      .scaledToFit()
      .frame(width: size * Self.artworkScale, height: size * Self.artworkScale)
      // The stones sit a little below the artwork's middle; this centres them.
      .offset(y: -size * 0.035)
      .frame(width: size, height: size)
      .clipped()
  }
}
