import Foundation
@testable import CairnServices
import Testing

@Suite("RegionSelection picker writes")
struct RegionSelectionTests {
  @Test
  func `afterChoosingCountry skips a re-tap and otherwise writes a manual country`() {
    let current = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: "los angeles",
      source: .location
    )
    #expect(RegionSelection.afterChoosingCountry("US", current: current) == nil)
    #expect(
      RegionSelection.afterChoosingCountry("PT", current: current)
        == RegionSelection(countryCode: "PT", source: .manual)
    )
    #expect(
      RegionSelection.afterChoosingCountry("US", current: nil)
        == RegionSelection(countryCode: "US", source: .manual)
    )
  }

  @Test
  func `afterChoosingSubdivision skips a re-tap, drops county on change, and needs a country`() {
    let current = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: "los angeles",
      source: .location
    )
    #expect(RegionSelection.afterChoosingSubdivision("US-CA", current: current) == nil)
    #expect(
      RegionSelection.afterChoosingSubdivision("US-TX", current: current)
        == RegionSelection(
          countryCode: "US",
          administrativeAreaCode: "US-TX",
          source: .manual
        )
    )
    #expect(RegionSelection.afterChoosingSubdivision("US-CA", current: nil) == nil)
  }

  @Test
  func `afterChoosingCounty writes a manual county, clears it with nil, and needs a state`() {
    let california = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      source: .location
    )
    #expect(
      RegionSelection.afterChoosingCounty("orange", current: california)
        == RegionSelection(
          countryCode: "US",
          administrativeAreaCode: "US-CA",
          countyKey: "orange",
          source: .manual
        )
    )
    #expect(RegionSelection.afterChoosingCounty(nil, current: california) == nil)

    let orange = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: "orange",
      source: .manual
    )
    #expect(RegionSelection.afterChoosingCounty("orange", current: orange) == nil)
    #expect(
      RegionSelection.afterChoosingCounty(nil, current: orange)
        == RegionSelection(countryCode: "US", administrativeAreaCode: "US-CA", source: .manual)
    )

    #expect(RegionSelection.afterChoosingCounty("orange", current: nil) == nil)
    #expect(
      RegionSelection.afterChoosingCounty(
        "orange",
        current: RegionSelection(countryCode: "US", source: .manual)
      ) == nil
    )
  }

  @Test
  func `Other county moves WCMesh to other regions and Not set brings it back`() throws {
    let locale = Locale(identifier: "en_US")
    let california = RegionSelection(countryCode: "US", administrativeAreaCode: "US-CA", source: .manual)

    let otherCounty = RegionSelection.afterChoosingCounty(RegionalAreas.otherCountyKey, current: california)
    #expect(otherCounty == RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: RegionalAreas.otherCountyKey,
      source: .manual
    ))
    let outside = try #require(otherCounty)
    #expect(!RadioPresets.visiblePresets(for: outside, locale: locale).regional.map(\.id).contains("wcmesh"))
    #expect(RadioPresets.visiblePresets(for: outside, locale: locale).otherRegions.map(\.id).contains("wcmesh"))

    let notSet = try #require(RegionSelection.afterChoosingCounty(nil, current: outside))
    #expect(notSet == california)
    #expect(RadioPresets.visiblePresets(for: notSet, locale: locale).regional.map(\.id).contains("wcmesh"))
  }

  @Test
  func `changing country or state drops a manually chosen county`() {
    let orange = RegionSelection(
      countryCode: "US",
      administrativeAreaCode: "US-CA",
      countyKey: "orange",
      source: .manual
    )
    #expect(RegionSelection.afterChoosingSubdivision("US-NV", current: orange)?.countyKey == nil)
    #expect(RegionSelection.afterChoosingCountry("CA", current: orange)?.countyKey == nil)
  }
}
