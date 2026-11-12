import CairnServices
import SwiftUI

/// Titles a top-level tab page with the connected radio's name, in the same green
/// as the ready status icon, instead of the page's own name, with the radio's
/// battery percentage and TX power in small type beneath it. The tab bar already
/// says which page this is; the bar's title slot says which radio it is talking to.
/// With no radio connected it falls back to the page title in the normal color; while
/// the session is not ready (connecting, syncing, auto-reconnecting) the name is not green.
/// The radio's RX/TX LED flashes behind it, green for each packet heard and red for each one sent
/// (`radioActivityFlash`).
///
/// The Cairn mark sits to its left in the same capsule, the name itself centred. Tapping it opens
/// Device Info, with or without a radio connected, whose My Radios button lists the radios. The page
/// title stays the navigation title, so back buttons on pushed screens, VoiceOver, and the iPad
/// sidebar still name the page.
private struct DeviceNameTitleModifier: ViewModifier {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.isBarTitleInColumn) private var isInColumn
  @ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 26

  let pageTitle: String
  /// The page draws behind the bar (the map). The title then sits on a glass capsule,
  /// because bare text over map labels and coastlines is hard to pick out.
  let floatsOverContent: Bool

  private var deviceName: String? {
    guard let name = appState.connectedDevice?.nodeName, !name.isEmpty else { return nil }
    return name
  }

  /// Bare text over the map or over the user's background image or gradient is hard to read, so
  /// the title sits on a glass capsule there.
  private var needsCapsule: Bool {
    floatsOverContent || theme.hasBackdrop
  }

  func body(content: Content) -> some View {
    content
      .navigationTitle(pageTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          // Always the same two Texts, varied by value: branching between views inside a
          // hosted toolbar item rebuilds it on connection changes (see DeviceInfoButton).
          DeviceInfoButton {
            // A thin column keeps the mark when the name won't fit beside it; both views are always
            // there, so the item keeps one identity (see the note above).
            ViewThatFits(in: .horizontal) {
              MarkedBarTitle(markSize: markSize) {
                VStack(spacing: 0) {
                  Text(deviceName ?? pageTitle)
                    .font(.headline)
                    .foregroundStyle(appState.isRadioReady && deviceName != nil ? AppColors.Radio.readyText : Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: isInColumn, vertical: false)
                  RadioStatusLineText()
                    .fixedSize(horizontal: isInColumn, vertical: false)
                }
              }
              CairnStonesMark(size: markSize)
            }
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            // Values only, never a branch, so the item keeps one identity (see the note above).
            .padding(.horizontal, needsCapsule ? 10 : 0)
            .padding(.vertical, needsCapsule ? 4 : 0)
            // The radio's RX/TX LED, lit behind the name as packets are heard and sent: it fills
            // the glass capsule when there is one, and reaches a little past bare text.
            .radioActivityFlash(horizontalOutset: needsCapsule ? 0 : 12, verticalOutset: needsCapsule ? 0 : 3)
            .background {
              Capsule()
                .fill(.regularMaterial)
                .opacity(needsCapsule ? 1 : 0)
            }
          }
          .buttonStyle(.plain)
          // A column's title has little room to move into: it stays between the bar's buttons.
          .offset(x: isInColumn ? 0 : MarkedBarTitle<EmptyView>.centeringOffset(markSize: markSize))
          .accessibilityIdentifier("title.radio")
        }
      }
  }
}

extension EnvironmentValues {
  /// The bar's title heads a list column on the iPad (Chats, Nodes, Settings), not a whole page.
  @Entry var isBarTitleInColumn = false
}

extension View {
  /// Shows the connected radio's name (green) as this page's title; see `DeviceNameTitleModifier`.
  func deviceNameTitle(pageTitle: String, floatsOverContent: Bool = false) -> some View {
    modifier(DeviceNameTitleModifier(pageTitle: pageTitle, floatsOverContent: floatsOverContent))
  }
}
