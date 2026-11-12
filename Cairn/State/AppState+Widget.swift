import CairnServices
import Foundation

// MARK: - Home-screen widget

extension AppState {
  /// Rebuilds the home-screen widget's snapshot from the current connection, battery and the
  /// counts `widgetSnapshotPublisher` keeps, and hands it to the publisher, which paces the
  /// writes. Called wherever one of those inputs changes: the link coming up or going down, a
  /// battery poll, the unread count, an advert.
  func publishWidgetSnapshot() {
    let state: WidgetSnapshot.ConnectionState = switch connectionState {
    case .disconnected: .disconnected
    case .connecting: .connecting
    case .connected, .syncing, .ready: .connected
    }
    let device = connectedDevice
    // A radio the app still knows keeps its name on the widget while disconnected; once the
    // last radio is forgotten the widget says there is none.
    let radioName = device?.nodeName
      ?? (connectionManager.lastConnectedDeviceID == nil ? nil : widgetSnapshotPublisher.lastWritten?.radioName)
    let batteryPercent: Int? = if state == .connected, let battery = batteryMonitor.deviceBattery {
      battery.percentage(using: batteryMonitor.activeBatteryOCVArray(for: device))
    } else {
      nil
    }
    widgetSnapshotPublisher.publish(WidgetSnapshot(
      radioName: radioName,
      connectionState: state,
      batteryPercent: batteryPercent,
      unreadCount: widgetSnapshotPublisher.unreadCount,
      lastHeard: widgetSnapshotPublisher.lastHeardNode,
      updatedAt: .now
    ))
  }

  /// An advert from `publicKey`: names the node for the widget's "Last heard" line when the
  /// app has a name for it (a contact's display name, else the name on air). An unnamed node
  /// leaves the line as it was.
  func noteWidgetNodeHeard(publicKey: Data) {
    let name = observationDirectory.contact(forKey: publicKey)?.displayName
      ?? neighbourDirectory.neighbour(publicKey: publicKey)?.record.name
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
    widgetSnapshotPublisher.lastHeardNode = WidgetSnapshot.HeardNode(name: name, date: .now)
    publishWidgetSnapshot()
  }
}
