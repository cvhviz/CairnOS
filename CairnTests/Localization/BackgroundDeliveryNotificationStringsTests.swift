import Foundation
@testable import Cairn
@testable import CairnServices
import Testing

/// The notices background delivery posts read from the app's localized strings, with the radio's
/// name and the lost-message count in place, and AppState installs the reminder that posts them.
@Suite("Background delivery notification strings")
@MainActor
struct BackgroundDeliveryNotificationStringsTests {
  private let strings = NotificationStringProviderImpl()

  @Test
  func `not-receiving and Bluetooth-off notices name the radio`() {
    #expect(!strings.notReceivingTitle.isEmpty)
    #expect(strings.notReceivingBody(deviceName: "Trail T096").contains("Trail T096"))
    #expect(!strings.bluetoothOffTitle.isEmpty)
    #expect(strings.bluetoothOffBody(deviceName: "Trail T096").contains("Trail T096"))
  }

  @Test
  func `the radio queue loss notice names the radio and the count`() {
    let body = strings.radioQueueLossBody(deviceName: "Trail T096", count: 7)
    #expect(!strings.radioQueueLossTitle.isEmpty)
    #expect(body.contains("Trail T096"))
    #expect(body.contains("7"))
  }

  @Test
  func `the Settings card for an unreported radio queue loss names the radio and the count`() {
    let title = L10n.Settings.Notifications.RadioQueueLoss.title(12)
    let subtitle = L10n.Settings.Notifications.RadioQueueLoss.subtitle("Trail T096")
    #expect(title.contains("12"))
    #expect(subtitle.contains("Trail T096"))
    #expect(!title.hasPrefix("notifications."), "the key resolves to a string")
  }

  @Test
  func `AppState installs the not-receiving reminder`() {
    let appState = AppState()
    #expect(appState.connectionManager.listeningReminder != nil)
  }
}
