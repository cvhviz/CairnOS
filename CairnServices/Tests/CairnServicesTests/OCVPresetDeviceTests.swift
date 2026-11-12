@testable import CairnServices
import Testing

/// Each Cairn board's preset carries the curve its firmware draws on its own screen, so the app and
/// the device show the same charge. The names are the boards' `getManufacturerName()` strings.
@Suite("OCVPreset device tests")
struct OCVPresetDeviceTests {
  private static let boards: [(String, OCVPreset)] = [
    ("Seeed Wio Tracker L1", .seeedWioTracker),
    ("Seeed Wio Tracker L2 Pro", .seeedWioTrackerL2),
    ("SenseCAP MeshPager X2", .senseCapMeshPagerX2),
    ("LilyGO T-Deck", .lilyGoTDeck),
    ("LilyGO T-LoRa Pager", .lilyGoTLoRaPager),
    ("LilyGO T5 E-Paper S3 Pro", .lilyGoT5EPaper),
    ("LilyGO T-Display SF32", .lilyGoTDisplaySF32),
    ("Heltec V4 R8 Touch", .heltecV4Touch),
    ("Heltec V4 Kit V1 Touch", .heltecV4Touch),
    ("Heltec V4.3 Kit V1 Touch", .heltecV4Touch),
    ("Heltec T096", .heltecT096),
    ("Elecrow ThinkNode M9", .thinkNodeM9),
  ]

  @Test(arguments: boards)
  func `A Cairn board gets its own preset`(name: String, preset: OCVPreset) {
    #expect(OCVPreset.preset(forManufacturer: name) == preset)
  }

  @Test(arguments: OCVPreset.allCases.filter { $0 != .custom })
  func `Every preset is 11 descending values`(preset: OCVPreset) {
    let array = preset.ocvArray
    #expect(array.count == 11)
    #expect(zip(array, array.dropFirst()).allSatisfy { $0 > $1 })
  }

  @Test
  func `T-Deck matches the firmware's generic curve`() {
    #expect(OCVPreset.lilyGoTDeck.ocvArray == [4200, 4090, 4000, 3930, 3870, 3820, 3790, 3760, 3720, 3680, 3400])
  }

  @Test
  func `ThinkNode M9 matches the firmware's LiHV curve`() {
    #expect(OCVPreset.thinkNodeM9.ocvArray == [4300, 4180, 4080, 3990, 3920, 3860, 3815, 3780, 3740, 3690, 3300])
  }

  @Test
  func `The new presets are device specific, not chemistries`() {
    #expect(!OCVPreset.batteryChemistryPresets.contains(.lilyGoTDeck))
    #expect(OCVPreset.selectablePresets.contains(.lilyGoTDeck))
  }
}
