import CoreLocation
import Foundation
@testable import Cairn
import CairnServices
import Testing

@Suite("PresetLocationPolicy")
struct PresetLocationPolicyTests {
  private func usCA() -> RegionSelection {
    RegionSelection(countryCode: "US", administrativeAreaCode: "US-CA", source: .location)
  }

  private func makePortugal(source: RegionSelection.Source) -> RegionSelection {
    RegionSelection(countryCode: "PT", source: source)
  }

  /// A lookup result whose placemark named a county (or a place with no county to name).
  private func located(_ selection: RegionSelection) -> RegionResolution {
    RegionResolution(selection: selection, countyFieldMissing: false)
  }

  private func losAngeles(source: RegionSelection.Source) -> RegionSelection {
    RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: "los angeles",
      source: source
    )
  }

  @Test
  func `starts expanded only when not authorized and incomplete`() {
    #expect(
      PresetLocationPolicy.startsExpandedOnRadio(authorized: false, selection: nil)
    )
    #expect(
      !PresetLocationPolicy.startsExpandedOnRadio(authorized: true, selection: nil)
    )
    let usNoAdmin = RegionSelection(countryCode: "US", source: .manual)
    #expect(
      PresetLocationPolicy.startsExpandedOnRadio(authorized: false, selection: usNoAdmin)
    )
    #expect(
      !PresetLocationPolicy.startsExpandedOnRadio(authorized: true, selection: usNoAdmin)
    )
    #expect(
      !PresetLocationPolicy.startsExpandedOnRadio(authorized: false, selection: usCA())
    )
  }

  @Test
  func `incomplete is nil or a subdivided country with no administrativeAreaCode`() {
    #expect(PresetLocationPolicy.isIncomplete(nil))
    #expect(
      PresetLocationPolicy.isIncomplete(
        RegionSelection(countryCode: "US", source: .manual)
      )
    )
    #expect(!PresetLocationPolicy.isIncomplete(usCA()))
    #expect(
      !PresetLocationPolicy.isIncomplete(
        RegionSelection(countryCode: "US", administrativeAreaCode: "US-TX", source: .manual)
      )
    )
    #expect(
      PresetLocationPolicy.isIncomplete(
        RegionSelection(countryCode: "AU", source: .manual)
      )
    )
    #expect(!PresetLocationPolicy.isIncomplete(makePortugal(source: .manual)))
  }

  @Test
  func `shouldResolveOnAppear is true only when authorized and source is not manual`() {
    #expect(
      PresetLocationPolicy.shouldResolveOnAppear(authorized: true, source: nil)
    )
    #expect(
      PresetLocationPolicy.shouldResolveOnAppear(authorized: true, source: .location)
    )
    #expect(
      !PresetLocationPolicy.shouldResolveOnAppear(authorized: true, source: .manual)
    )
    #expect(
      !PresetLocationPolicy.shouldResolveOnAppear(authorized: false, source: .location)
    )
    #expect(
      !PresetLocationPolicy.shouldResolveOnAppear(authorized: false, source: nil)
    )
  }

  @Test
  func `useMyLocationAction maps authorization status`() {
    #expect(
      PresetLocationPolicy.useMyLocationAction(status: .authorizedWhenInUse) == .resolve
    )
    #expect(
      PresetLocationPolicy.useMyLocationAction(status: .authorizedAlways) == .resolve
    )
    #expect(
      PresetLocationPolicy.useMyLocationAction(status: .notDetermined) == .waitForAuthorization
    )
    #expect(
      PresetLocationPolicy.useMyLocationAction(status: .denied) == .openSettings
    )
    #expect(
      PresetLocationPolicy.useMyLocationAction(status: .restricted) == .openSettings
    )
  }

  @Test
  func `appear commit keeps manual Portugal over California GPS`() {
    let portugal = makePortugal(source: .manual)
    let california = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      source: .location
    )
    #expect(
      PresetLocationPolicy.committedSelection(
        current: portugal,
        result: located(california),
        kind: .appear
      ) == portugal
    )
  }

  @Test
  func `user-initiated commit replaces manual Portugal with California GPS`() {
    let portugal = makePortugal(source: .manual)
    let california = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      source: .location
    )
    #expect(
      PresetLocationPolicy.committedSelection(
        current: portugal,
        result: located(california),
        kind: .userInitiated
      ) == california
    )
  }

  @Test
  func `actionAfterAuthorizationWait`() {
    #expect(
      PresetLocationPolicy.actionAfterAuthorizationWait(status: .authorizedWhenInUse) == .resolve
    )
    #expect(
      PresetLocationPolicy.actionAfterAuthorizationWait(status: .denied) == .openSettings
    )
    #expect(
      PresetLocationPolicy.actionAfterAuthorizationWait(status: .restricted) == .openSettings
    )
    #expect(
      PresetLocationPolicy.actionAfterAuthorizationWait(status: .notDetermined) == .none
    )
  }

  @Test
  func `a busy location slot reports a miss only for a lookup the user asked for`() {
    #expect(PresetLocationPolicy.lookupMissMessageShown(slotFreed: false, result: nil, kind: .userInitiated))
    #expect(!PresetLocationPolicy.lookupMissMessageShown(slotFreed: false, result: nil, kind: .appear))
  }

  @Test
  func `a lookup that ran reports a miss only when the user asked and it found nothing`() {
    let found = located(usCA())
    #expect(PresetLocationPolicy.lookupMissMessageShown(slotFreed: true, result: nil, kind: .userInitiated))
    #expect(!PresetLocationPolicy.lookupMissMessageShown(slotFreed: true, result: found, kind: .userInitiated))
    #expect(!PresetLocationPolicy.lookupMissMessageShown(slotFreed: true, result: nil, kind: .appear))
    #expect(!PresetLocationPolicy.lookupMissMessageShown(slotFreed: true, result: found, kind: .appear))
  }

  @Test
  func `committedSelection with nil GPS keeps current`() {
    let portugal = makePortugal(source: .manual)
    #expect(
      PresetLocationPolicy.committedSelection(
        current: portugal,
        result: nil,
        kind: .appear
      ) == portugal
    )
    #expect(
      PresetLocationPolicy.committedSelection(
        current: portugal,
        result: nil,
        kind: .userInitiated
      ) == portugal
    )
    #expect(
      PresetLocationPolicy.committedSelection(
        current: nil,
        result: nil,
        kind: .appear
      ) == nil
    )
  }

  @Test
  func `shouldCommitAppearResult is false only for manual`() {
    #expect(!PresetLocationPolicy.shouldCommitAppearResult(currentSource: .manual))
    #expect(PresetLocationPolicy.shouldCommitAppearResult(currentSource: .location))
    #expect(PresetLocationPolicy.shouldCommitAppearResult(currentSource: nil))
  }

  @Test
  func `appear commit of nil current takes GPS result`() {
    let california = usCA()
    #expect(
      PresetLocationPolicy.committedSelection(
        current: nil,
        result: located(california),
        kind: .appear
      ) == california
    )
  }

  @Test
  func `appear commit of location current takes GPS result`() {
    let portugal = makePortugal(source: .location)
    let california = usCA()
    #expect(
      PresetLocationPolicy.committedSelection(
        current: portugal,
        result: located(california),
        kind: .appear
      ) == california
    )
  }

  @Test
  func `a lookup with no county field keeps the saved county for the same state`() {
    let saved = losAngeles(source: .location)
    let noCountyField = RegionResolution(selection: usCA(), countyFieldMissing: true)
    #expect(
      PresetLocationPolicy.committedSelection(
        current: saved,
        result: noCountyField,
        kind: .appear
      ) == saved
    )
    let manual = losAngeles(source: .manual)
    #expect(
      PresetLocationPolicy.committedSelection(
        current: manual,
        result: noCountyField,
        kind: .userInitiated
      ) == losAngeles(source: .location)
    )
  }

  @Test
  func `a lookup that names an unlisted county drops the saved one`() {
    // A move from Los Angeles to Sacramento: the placemark has a county the catalog doesn't list.
    let otherCounty = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: RegionalAreas.otherCountyKey,
      source: .location
    )
    #expect(
      PresetLocationPolicy.committedSelection(
        current: losAngeles(source: .location),
        result: located(otherCounty),
        kind: .appear
      ) == otherCounty
    )
  }

  @Test
  func `a lookup with no county field keeps a saved Other county`() {
    let otherCounty = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: RegionalAreas.otherCountyKey,
      source: .location
    )
    #expect(
      PresetLocationPolicy.committedSelection(
        current: otherCounty,
        result: RegionResolution(selection: usCA(), countyFieldMissing: true),
        kind: .appear
      ) == otherCounty
    )
  }

  @Test
  func `a lookup with no county field in another state does not carry the county over`() {
    let nevada = RegionSelection(countryCode: "US", administrativeAreaCode: "US-NV", source: .location)
    #expect(
      PresetLocationPolicy.committedSelection(
        current: losAngeles(source: .location),
        result: RegionResolution(selection: nevada, countyFieldMissing: true),
        kind: .appear
      ) == nevada
    )
    let unknownState = RegionSelection(countryCode: "US", source: .location)
    #expect(
      PresetLocationPolicy.keepingSavedCounty(
        RegionResolution(selection: unknownState, countyFieldMissing: true),
        current: losAngeles(source: .location)
      ) == unknownState
    )
  }

  @Test
  func `a lookup that names a listed county replaces the saved one`() {
    let orange = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: "orange",
      source: .location
    )
    #expect(
      PresetLocationPolicy.committedSelection(
        current: losAngeles(source: .location),
        result: located(orange),
        kind: .appear
      ) == orange
    )
  }

  @Test
  func `useMyLocation failure copy does not say region, below, or this screen`() {
    let text = L10n.Settings.Radio.PresetLocation.UseMyLocation.failure
    #expect(!text.localizedCaseInsensitiveContains("region"))
    #expect(!text.localizedCaseInsensitiveContains("below"))
    #expect(!text.localizedCaseInsensitiveContains("this screen"))
  }

  @Test
  func `useMyLocation locating copy does not say region`() {
    let text = L10n.Settings.Radio.PresetLocation.UseMyLocation.locating
    #expect(!text.localizedCaseInsensitiveContains("region"))
    #expect(!text.isEmpty)
  }

  @Test
  func `denied copy does not say region or mesh contacts`() {
    let text = L10n.Settings.Radio.PresetLocation.denied
    #expect(!text.localizedCaseInsensitiveContains("region"))
    #expect(!text.localizedCaseInsensitiveContains("contact"))
    #expect(!text.localizedCaseInsensitiveContains("mesh"))
  }

  @Test
  func `pt lookup-miss and denied use voce`() throws {
    let bundle = try #require(Self.localeBundle("pt"))
    let failure = bundle.localizedString(
      forKey: "radio.presetLocation.useMyLocation.failure",
      value: Self.sentinel,
      table: "Settings"
    )
    let denied = bundle.localizedString(
      forKey: "radio.presetLocation.denied",
      value: Self.sentinel,
      table: "Settings"
    )
    #expect(failure.contains("sua localização"))
    #expect(!failure.contains("tua"))
    #expect(denied.contains("Ative-a"))
    #expect(!denied.contains("Ativa-a"))
  }

  private static let sentinel = "\u{0}__settings_key_missing__\u{0}"

  private static func localeBundle(_ locale: String) -> Bundle? {
    guard let url = Bundle.main.url(forResource: locale, withExtension: "lproj") else {
      return nil
    }
    return Bundle(url: url)
  }
}
