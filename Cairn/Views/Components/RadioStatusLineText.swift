import CairnServices
import SwiftUI

/// The connected radio's battery percentage and TX power ("87% · 28 dBm"), shown
/// in small type under the device-name title. TX power includes the amplifier
/// gain of boards known to have one (see `RadioAmplifier`).
///
/// Always one `Text` whose string varies by value (empty when disconnected).
/// `DeviceInfoButton` documents why: an if/else inside a hosted toolbar item
/// gives the arms distinct identities, and swapping them on a connection change
/// rebuilds the item mid-update, which crashes on iOS 26.
struct RadioStatusLineText: View {
  @Environment(\.appState) private var appState

  var body: some View {
    let line = Self.text(
      batteryPercentage: appState.radioBatteryPercent,
      txPower: appState.isRadioReady ? appState.radioTxPower : nil
    )
    Text(line)
      .font(.caption2.weight(.medium))
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
      // Nothing to show: collapse the line so the name stays vertically centered in the bar.
      .frame(height: line.isEmpty ? 0 : nil)
      .dynamicTypeSize(...DynamicTypeSize.xLarge)
      .accessibilityHidden(line.isEmpty)
  }

  /// "87% · 22 dBm", or whichever part is known; empty when neither is.
  static func text(batteryPercentage: Int?, txPower: Int?) -> String {
    var parts: [String] = []
    if let batteryPercentage {
      let clamped = min(max(batteryPercentage, 0), 100)
      parts.append((Double(clamped) / 100).formatted(.percent.precision(.fractionLength(0))))
    }
    if let txPower {
      parts.append(L10n.Settings.DeviceInfo.txPowerFormat(txPower.formatted()))
    }
    return parts.joined(separator: " · ")
  }
}
