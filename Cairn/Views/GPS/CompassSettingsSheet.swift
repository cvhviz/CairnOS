import CairnServices
import SwiftUI

/// The full compass's settings, behind its sliders button as every tab's own settings are, in the
/// Comm sheet's card style: how the dial turns and which north it reads, the sun and course
/// markers, which nodes it shows and how many, and the haptics and screen. Each card opens its
/// controls in a small sheet. Device-local preferences, not backed up.
struct CompassSettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme

  @AppStorage(AppStorageKey.compassNorthUp.rawValue) private var northUp = false
  @AppStorage(AppStorageKey.compassUsesMagneticNorth.rawValue) private var usesMagneticNorth = false
  @AppStorage(AppStorageKey.compassShowsSun.rawValue) private var showsSun = true
  @AppStorage(AppStorageKey.compassShowsCourse.rawValue) private var showsCourse = true
  @AppStorage(AppStorageKey.compassShowsNodes.rawValue) private var showsNodes = true
  @AppStorage(AppStorageKey.compassShowsCompanions.rawValue) private var showsCompanions = true
  @AppStorage(AppStorageKey.compassShowsRepeaters.rawValue) private var showsRepeaters = true
  @AppStorage(AppStorageKey.compassShowsRooms.rawValue) private var showsRooms = true
  @AppStorage(AppStorageKey.compassNodeLimit.rawValue) private var nodeLimit = AppStorageKey.defaultCompassNodeLimit
  @AppStorage(AppStorageKey.compassHaptics.rawValue) private var haptics = true
  @AppStorage(AppStorageKey.compassKeepsScreenOn.rawValue) private var keepsScreenOn = false

  static let nodeLimitOptions = [6, 12, 24]

  // MARK: - Cards

  private var cards: [NodeDashboardCardItem] {
    [dialCard, sunCard, courseCard, nodesCard, generalCard]
  }

  private static func onOff(_ isOn: Bool) -> String {
    isOn ? L10n.Localizable.Accessibility.on : L10n.Localizable.Accessibility.off
  }

  private var dialCard: NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "dial",
      title: L10n.Map.Map.Gps.Compass.dial,
      systemImage: "dial.medium.fill",
      tint: .orange,
      value: northUp ? L10n.Map.Map.Gps.Compass.northUp : L10n.Map.Map.Gps.Compass.headingUp,
      details: [usesMagneticNorth ? L10n.Map.Map.Gps.Compass.magneticNorth : L10n.Map.Map.Gps.Compass.trueNorth],
      destination: .controls(AnyView(
        CardFormSection(info: L10n.Map.Map.Gps.Compass.northInfo) {
          PickerCard(L10n.Map.Map.Gps.Compass.dial, systemImage: "dial.medium.fill", color: .orange, selection: $northUp) {
            Text(L10n.Map.Map.Gps.Compass.headingUp).tag(false)
            Text(L10n.Map.Map.Gps.Compass.northUp).tag(true)
          }
          PickerCard(L10n.Map.Map.Gps.Compass.north, systemImage: "location.north.line.fill", color: .red, selection: $usesMagneticNorth) {
            Text(L10n.Map.Map.Gps.Compass.trueNorth).tag(false)
            Text(L10n.Map.Map.Gps.Compass.magneticNorth).tag(true)
          }
        }
      ))
    )
  }

  private var sunCard: NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "sun",
      title: L10n.Map.Map.Gps.Compass.sun,
      systemImage: "sun.max.fill",
      tint: .yellow,
      value: Self.onOff(showsSun),
      valueTint: showsSun ? .primary : .secondary,
      destination: .controls(AnyView(
        CardFormSection {
          ToggleCard(L10n.Map.Map.Gps.Compass.showSun, systemImage: "sun.max.fill", color: .yellow, isOn: $showsSun)
        }
      ))
    )
  }

  private var courseCard: NodeDashboardCardItem {
    NodeDashboardCardItem(
      id: "course",
      title: L10n.Map.Map.Gps.course,
      systemImage: "arrowtriangle.up.fill",
      tint: .green,
      value: Self.onOff(showsCourse),
      valueTint: showsCourse ? .primary : .secondary,
      destination: .controls(AnyView(
        CardFormSection {
          ToggleCard(L10n.Map.Map.Gps.Compass.showCourse, systemImage: "arrowtriangle.up.fill", color: .green, isOn: $showsCourse)
        }
      ))
    )
  }

  /// How many nodes, and which kinds; "Off" when the dial hides them.
  private var nodesCard: NodeDashboardCardItem {
    let kinds = [
      (L10n.Contacts.Contacts.Segment.contacts, showsCompanions),
      (L10n.Contacts.Contacts.Segment.repeaters, showsRepeaters),
      (L10n.Contacts.Contacts.Segment.rooms, showsRooms),
    ]
    return NodeDashboardCardItem(
      id: "nodes",
      title: L10n.Map.Map.Gps.Compass.nearbyNodes,
      systemImage: "point.3.filled.connected.trianglepath.dotted",
      tint: HomeStatusCards.cairnTeal,
      value: showsNodes ? nodeLimit.formatted() : L10n.Localizable.Accessibility.off,
      valueTint: showsNodes ? .primary : .secondary,
      details: showsNodes ? [kinds.filter(\.1).map(\.0).joined(separator: " · ")].filter { !$0.isEmpty } : [],
      destination: .controls(AnyView(
        CardFormSection {
          ToggleCard(L10n.Map.Map.Gps.Compass.showNodes, systemImage: "eye", color: HomeStatusCards.cairnTeal, isOn: $showsNodes)
          ToggleCard(L10n.Contacts.Contacts.Segment.contacts, systemImage: "person.fill", color: .cyan, isOn: $showsCompanions)
          ToggleCard(L10n.Contacts.Contacts.Segment.repeaters, systemImage: "antenna.radiowaves.left.and.right", color: HomeStatusCards.cairnTeal, isOn: $showsRepeaters)
          ToggleCard(L10n.Contacts.Contacts.Segment.rooms, systemImage: "door.left.hand.closed", color: .brown, isOn: $showsRooms)
          PickerCard(L10n.Map.Map.Gps.Compass.nodesShown, systemImage: "list.number", color: .purple, selection: $nodeLimit) {
            ForEach(Self.nodeLimitOptions, id: \.self) { count in
              Text(count.formatted()).tag(count)
            }
          }
        }
      ))
    )
  }

  private var generalCard: NodeDashboardCardItem {
    let switches = [
      (L10n.Map.Map.Gps.Compass.haptics, haptics),
      (L10n.Map.Map.Gps.Compass.keepScreenOn, keepsScreenOn),
    ]
    return NodeDashboardCardItem(
      id: "general",
      title: L10n.Map.Map.Gps.Compass.general,
      systemImage: "gearshape.fill",
      tint: .gray,
      value: "\(switches.count(where: \.1))/\(switches.count)",
      details: switches.filter(\.1).map(\.0),
      destination: .controls(AnyView(
        CardFormSection {
          ToggleCard(
            L10n.Map.Map.Gps.Compass.haptics,
            systemImage: "hand.tap.fill",
            color: .pink,
            subtitle: L10n.Map.Map.Gps.Compass.hapticsSubtitle,
            isOn: $haptics
          )
          ToggleCard(
            L10n.Map.Map.Gps.Compass.keepScreenOn,
            systemImage: "sun.max.circle.fill",
            color: .blue,
            subtitle: L10n.Map.Map.Gps.Compass.keepScreenOnSubtitle,
            isOn: $keepsScreenOn
          )
        }
      ))
    )
  }

  var body: some View {
    NavigationStack {
      // The Comm sheet's style: cards that sum up each group and open its controls in a small sheet.
      CardForm {
        NodeDashboardCardGrid(items: cards)
      }
      .flashingNavigationTitle(L10n.Map.Map.Gps.Compass.settingsTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
    }
    // Presented outside the tab shell, so it takes the shell's bar styling itself.
    .themedChrome(theme)
    // Half height, dragging to full, like every tab's settings sheet.
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

#Preview {
  Text(verbatim: "Compass")
    .sheet(isPresented: .constant(true)) { CompassSettingsSheet() }
}
