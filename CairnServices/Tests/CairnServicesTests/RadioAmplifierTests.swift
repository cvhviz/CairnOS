import Foundation
@testable import CairnServices
import Testing

@Suite("RadioAmplifier")
struct RadioAmplifierTests {
  @Test(arguments: [
    ("Heltec T096", RadioAmplifier.Curve.t096),
    ("heltec t096", .t096),
    ("Heltec T096 (nRF52)", .t096),
    ("HT-T096", .t096),
    ("Heltec Tracker V2", .trackerV2),
    ("Heltec V4 R8 Touch", .kct8103l),
    ("Heltec V4 R8 TFT", .kct8103l),
    ("Heltec V4 R8 OLED", .kct8103l),
    ("Heltec V4.3 OLED", .kct8103l),
    ("Heltec V4.3 TFT", .kct8103l),
    ("Heltec V4.3 Kit V1 Touch", .kct8103l),
    ("Heltec V4 OLED", .gc1109),
    ("Heltec V4 TFT", .gc1109),
    ("Heltec V4 Kit V1 Touch", .gc1109),
  ])
  func `amplified boards map to their own curve`(model: String, curve: RadioAmplifier.Curve) {
    #expect(RadioAmplifier.curve(model: model) == curve)
    #expect(RadioAmplifier.hasAmplifier(model: model))
  }

  @Test
  func `a V4.3 Kit V1 is not read on the V4.2's GC1109 curve`() {
    #expect(RadioAmplifier.curve(model: "Heltec V4.3 Kit V1 Touch") != .gc1109)
  }

  /// The firmware's T096 default (9) and cap (16): about 23 dBm and 28 dBm at the antenna, never 30.
  @Test(arguments: [(-9, 5), (0, 14), (9, 23), (12, 26), (13, 26), (14, 27), (15, 28), (16, 28), (22, 28)])
  func `the T096 follows its own curve`(setting: Int, antenna: Int) {
    #expect(RadioAmplifier.effectiveTxPower(reported: setting, model: "Heltec T096") == antenna)
  }

  @Test(arguments: [(-9, 4), (0, 13), (10, 23), (13, 26), (14, 26), (17, 28), (18, 28), (22, 28)])
  func `the V4-R8 and V4.3 follow the KCT8103L curve`(setting: Int, antenna: Int) {
    #expect(RadioAmplifier.effectiveTxPower(reported: setting, model: "Heltec V4 R8 Touch") == antenna)
    #expect(RadioAmplifier.effectiveTxPower(reported: setting, model: "Heltec V4.3 OLED") == antenna)
  }

  @Test(arguments: [(-9, 2), (10, 21), (15, 26), (17, 27), (18, 27), (22, 28)])
  func `a V4.2 follows the GC1109 curve`(setting: Int, antenna: Int) {
    #expect(RadioAmplifier.effectiveTxPower(reported: setting, model: "Heltec V4 OLED") == antenna)
  }

  @Test(arguments: [(9, 23), (11, 25), (16, 28), (18, 28)])
  func `the Tracker V2 follows its own curve`(setting: Int, antenna: Int) {
    #expect(RadioAmplifier.effectiveTxPower(reported: setting, model: "Heltec Tracker V2") == antenna)
  }

  @Test
  func `no curve falls as the setting rises`() {
    for curve in RadioAmplifier.Curve.allCases {
      for setting in -9..<30 {
        #expect(curve.antennaDbm(setting: setting) <= curve.antennaDbm(setting: setting + 1), "\(curve) \(setting)")
      }
    }
  }

  /// The firmware's caps (T096 16, V4 family 18) through each curve: the most each board radiates.
  @Test(arguments: [
    ("Heltec T096", 16, 28),
    ("Heltec V4 OLED", 18, 27),
    ("Heltec V4.3 OLED", 18, 28),
    ("Heltec V4 R8 Touch", 18, 28),
    ("Heltec Tracker V2", 18, 28),
    ("Heltec V3", 22, 22),
    ("RAK4631", 22, 22),
  ])
  func `the antenna maximum is the reported maximum through the curve`(model: String, reportedMax: Int, antenna: Int) {
    #expect(RadioAmplifier.antennaMaxTxPower(reportedMax: reportedMax, model: model) == antenna)
  }

  @Test(arguments: ["Heltec V3", "Heltec T114", "RAK4631", "Seeed Wio Tracker L2", "Meshnology W12", "Sim", ""])
  func `other boards display the TX power they report`(model: String) {
    #expect(!RadioAmplifier.hasAmplifier(model: model))
    #expect(RadioAmplifier.effectiveTxPower(reported: 22, model: model) == 22)
  }
}
