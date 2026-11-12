@testable import Cairn
@testable import CairnServices
import Testing

/// Covers the preset step's Use button against the radio link. A tester picked "USA", saw the
/// checkmark and "Use USA", and the button stayed dim with nothing said: the link had dropped
/// after pairing (services nil), and the old gate disabled the button on that alone.
@Suite("Preset Step Link Status")
@MainActor
struct PresetStepLinkStatusTests {
  @Test
  func `picked preset with the link down keeps Use enabled and offers Reconnect`() {
    let status = PresetStepView.linkStatus(
      hasServices: false,
      connectionState: .disconnected,
      isBusy: false,
      hasSavedRadio: true
    )

    #expect(status == .disconnected)
    #expect(PresetStepView.isApplyDisabled(selectedID: "us-ca", isApplying: false, linkStatus: status) == false)
  }

  @Test
  func `no saved radio to reconnect offers Pair Again and keeps Use enabled`() {
    let status = PresetStepView.linkStatus(
      hasServices: false,
      connectionState: .disconnected,
      isBusy: false,
      hasSavedRadio: false
    )

    #expect(status == .unpaired)
    #expect(PresetStepView.isApplyDisabled(selectedID: "us-ca", isApplying: false, linkStatus: status) == false)
  }

  @Test(arguments: [DeviceConnectionState.connecting, .connected])
  func `connect or session rebuild under way reads as connecting and holds Use`(state: DeviceConnectionState) {
    let status = PresetStepView.linkStatus(
      hasServices: false,
      connectionState: state,
      isBusy: false,
      hasSavedRadio: true
    )

    #expect(status == .connecting)
    #expect(PresetStepView.isApplyDisabled(selectedID: "us-ca", isApplying: false, linkStatus: status))
  }

  @Test
  func `reconnect in flight reads as connecting even once services appear`() {
    let status = PresetStepView.linkStatus(
      hasServices: true,
      connectionState: .ready,
      isBusy: true,
      hasSavedRadio: true
    )

    #expect(status == .connecting)
  }

  @Test(arguments: [DeviceConnectionState.syncing, .ready])
  func `live services enable Use once a preset is picked`(state: DeviceConnectionState) {
    let status = PresetStepView.linkStatus(
      hasServices: true,
      connectionState: state,
      isBusy: false,
      hasSavedRadio: true
    )

    #expect(status == .live)
    #expect(PresetStepView.isApplyDisabled(selectedID: "us-ca", isApplying: false, linkStatus: status) == false)
  }

  @Test(arguments: [
    PresetStepView.LinkStatus.live, .connecting, .disconnected, .unpaired,
  ])
  func `nothing picked or an apply under way holds Use whatever the link`(status: PresetStepView.LinkStatus) {
    #expect(PresetStepView.isApplyDisabled(selectedID: nil, isApplying: false, linkStatus: status))
    #expect(PresetStepView.isApplyDisabled(selectedID: "us-ca", isApplying: true, linkStatus: status))
  }

  @Test(arguments: [
    [OnboardingStep.permissions, .pair, .region, .preset],
    [.permissions, .pair, .preset],
  ])
  func `reconnect started by Use applies the preset while the user is still on the step`(path: [OnboardingStep]) {
    #expect(PresetStepView.shouldApplyAfterReconnect(
      hasServices: true,
      isApplying: false,
      hasCompletedOnboarding: false,
      onboardingPath: path
    ))
  }

  @Test
  func `Set Up Later during the reconnect drops the pending preset`() {
    #expect(PresetStepView.shouldApplyAfterReconnect(
      hasServices: true,
      isApplying: false,
      hasCompletedOnboarding: true,
      onboardingPath: [.permissions, .pair, .region, .preset]
    ) == false)
  }

  @Test
  func `Back during the reconnect drops the pending preset`() {
    #expect(PresetStepView.shouldApplyAfterReconnect(
      hasServices: true,
      isApplying: false,
      hasCompletedOnboarding: false,
      onboardingPath: [.permissions, .pair, .region]
    ) == false)
  }

  @Test
  func `failed reconnect or an apply already running writes nothing more`() {
    let path: [OnboardingStep] = [.permissions, .pair, .region, .preset]
    #expect(PresetStepView.shouldApplyAfterReconnect(
      hasServices: false,
      isApplying: false,
      hasCompletedOnboarding: false,
      onboardingPath: path
    ) == false)
    #expect(PresetStepView.shouldApplyAfterReconnect(
      hasServices: true,
      isApplying: true,
      hasCompletedOnboarding: false,
      onboardingPath: path
    ) == false)
  }

  @Test
  func `pair again from the preset step keeps the steps before pairing`() {
    #expect(PresetStepView.pathBackToPairStep([.permissions, .pair, .region, .preset]) == [.permissions, .pair])
    // A relaunch with a saved region resumes without the region step.
    #expect(PresetStepView.pathBackToPairStep([.permissions, .pair, .preset]) == [.permissions, .pair])
    #expect(PresetStepView.pathBackToPairStep([.preset]) == [.permissions, .pair])
  }

  @Test
  func `over Wi-Fi Set Up Later is always offered, and a refusal there holds Use`() {
    #expect(PresetStepView.showsSetUpLater(linkStatus: .live, isWiFi: true))
    #expect(PresetStepView.showsSetUpLater(linkStatus: .live, isWiFi: false) == false)
    #expect(PresetStepView.showsSetUpLater(linkStatus: .disconnected, isWiFi: false))
    #expect(PresetStepView.isApplyDisabled(
      selectedID: "us-ca", isApplying: false, linkStatus: .live, refusesOverWiFi: true
    ))
    #expect(PresetStepView.isApplyDisabled(
      selectedID: "us-ca", isApplying: false, linkStatus: .live, refusesOverWiFi: false
    ) == false)
  }
}

