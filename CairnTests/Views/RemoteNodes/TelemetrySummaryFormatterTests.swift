import Foundation
@testable import Cairn
import MeshCore
import Testing

@Suite("TelemetrySummaryFormatter")
struct TelemetrySummaryFormatterTests {
  private let locale = Locale(identifier: "en_US_POSIX")

  @Test
  func `Voltage keeps two decimals and its unit`() {
    #expect(TelemetrySummaryFormatter.format(4.1, type: .voltage, locale: locale, convertUnits: false) == "4.10 V")
  }

  @Test
  func `Percent and direction attach their unit without a space`() {
    #expect(TelemetrySummaryFormatter.format(87, type: .percentage, locale: locale, convertUnits: false) == "87%")
    #expect(TelemetrySummaryFormatter.format(270, type: .direction, locale: locale, convertUnits: false) == "270\u{00B0}")
  }

  @Test
  func `Unconverted temperature uses Celsius with one decimal`() {
    #expect(TelemetrySummaryFormatter.format(21.24, type: .temperature, locale: locale, convertUnits: false) == "21.2 \u{00B0}C")
  }

  @Test
  func `Unknown type formats the bare number`() {
    #expect(TelemetrySummaryFormatter.format(3.5, type: nil, locale: locale) == "3.5")
  }

  @Test
  func `Rows map each entry and label channels only when several are present`() {
    let single = TelemetrySummaryFormatter.rows(
      from: [MMAEntry(channel: 1, type: "Voltage", min: 3.9, max: 4.2, avg: 4.0)],
      locale: locale,
      convertUnits: false
    )
    #expect(single.count == 1)
    #expect(single[0].label == LPPSensorType.voltage.localizedName)
    #expect(single[0].min == "3.90 V")
    #expect(single[0].avg == "4.00 V")
    #expect(single[0].max == "4.20 V")

    let multi = TelemetrySummaryFormatter.rows(
      from: [
        MMAEntry(channel: 1, type: "Voltage", min: 3.9, max: 4.2, avg: 4.0),
        MMAEntry(channel: 2, type: "Humidity", min: 40, max: 60, avg: 50)
      ],
      locale: locale,
      convertUnits: false
    )
    #expect(multi[1].label.contains(L10n.RemoteNodes.RemoteNodes.Status.channel(2)))
    #expect(multi[1].max == "60.0%")
  }
}
