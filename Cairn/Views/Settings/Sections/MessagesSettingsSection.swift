import CairnServices
import SwiftUI

/// Chat settings section for incoming message routing info display. Five switches most people
/// never touch, so they fold away behind one card (open on arrival while any is on, so a reader
/// can see why the bubbles show extra lines).
struct MessagesSettingsSection: View {
  /// Nil until first shown; then only the Show/Hide card changes it, so flipping a switch inside
  /// the group never folds it away under the user's finger.
  @State private var isExpanded: Bool?
  @AppStorage(AppStorageKey.showIncomingPath.rawValue) private var showIncomingPath = false
  @AppStorage(AppStorageKey.showIncomingHopCount.rawValue)
  private var showIncomingHopCount = AppStorageKey.defaultShowIncomingHopCount
  @AppStorage(AppStorageKey.showIncomingRegion.rawValue) private var showIncomingRegion = false
  @AppStorage(AppStorageKey.showIncomingHeardCount.rawValue)
  private var showIncomingHeardCount = AppStorageKey.defaultShowIncomingHeardCount

  var body: some View {
    CardFormSection(L10n.Settings.Messages.header, info: L10n.Settings.Messages.footer) {
      disclosureCard

      if expanded {
        ToggleCard(
          L10n.Settings.Messages.showIncomingPath,
          systemImage: "point.3.connected.trianglepath.dotted",
          color: .purple,
          isOn: $showIncomingPath
        )
        ToggleCard(
          L10n.Settings.Messages.showIncomingHopCount,
          systemImage: "arrow.triangle.branch",
          color: .purple,
          isOn: $showIncomingHopCount
        )
        ToggleCard(L10n.Settings.Messages.showIncomingRegion, systemImage: "globe", color: .purple, isOn: $showIncomingRegion)
        ToggleCard(
          L10n.Settings.Messages.showIncomingHeardCount,
          systemImage: "ear.fill",
          color: .purple,
          isOn: $showIncomingHeardCount
        )
      }
    }
    .onAppear {
      if isExpanded == nil {
        isExpanded = anyEnabled
      }
    }
  }

  /// Folds the switches away or shows them, with how many are on so a folded group still says
  /// whether the bubbles carry extra lines.
  private var disclosureCard: some View {
    Button {
      withAnimation { isExpanded = !expanded }
    } label: {
      HStack(spacing: 8) {
        SettingCardLabel(
          expanded ? L10n.Settings.Messages.Options.hide : L10n.Settings.Messages.Options.show,
          systemImage: "info.bubble.fill",
          color: .purple,
          subtitle: L10n.Settings.Messages.Options.enabledCount(enabledCount, Self.switchCount)
        )
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color(.tertiaryLabel))
          .rotationEffect(.degrees(expanded ? 90 : 0))
          .accessibilityHidden(true)
      }
      .cardSurface(padding: 12)
      .cardInteractionShape()
    }
    .buttonStyle(.plain)
  }

  private var expanded: Bool {
    isExpanded ?? anyEnabled
  }

  private static let switchCount = 4

  private var enabledCount: Int {
    // No send-time switch: every bubble shows its time (`MessageFragmentBuilder.makeFooter`).
    [showIncomingPath, showIncomingHopCount, showIncomingRegion, showIncomingHeardCount]
      .filter(\.self)
      .count
  }

  private var anyEnabled: Bool {
    enabledCount > 0
  }
}

#Preview {
  CardForm {
    MessagesSettingsSection()
  }
}
