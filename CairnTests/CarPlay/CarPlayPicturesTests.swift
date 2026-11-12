import CoreLocation
import Foundation
import MapKit
import UIKit
@testable import Cairn
import Testing

@Suite("CarPlay pictures")
struct CarPlayPicturesTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - Throttle

  @Test
  func `A picture's revision moves on when its data changes`() {
    var throttle = CarPlayPictureThrottle(minimumInterval: 8)
    #expect(throttle.revision(for: "a", now: start) == 1)
    #expect(throttle.revision(for: "a", now: start.addingTimeInterval(30)) == 1)
    #expect(throttle.revision(for: "b", now: start.addingTimeInterval(30)) == 2)
  }

  @Test
  func `A change inside the interval waits, and the first call after it takes it`() {
    var throttle = CarPlayPictureThrottle(minimumInterval: 8)
    #expect(throttle.revision(for: "a", now: start) == 1)
    #expect(throttle.revision(for: "b", now: start.addingTimeInterval(3)) == 1)
    #expect(throttle.revision(for: "c", now: start.addingTimeInterval(7.9)) == 1)
    #expect(throttle.revision(for: "c", now: start.addingTimeInterval(8)) == 2)
    #expect(throttle.revision(for: "c", now: start.addingTimeInterval(9)) == 2)
  }

  @Test
  func `A clock that steps back doesn't hold a change back`() {
    var throttle = CarPlayPictureThrottle(minimumInterval: 8)
    _ = throttle.revision(for: "a", now: start)
    #expect(throttle.revision(for: "b", now: start.addingTimeInterval(-60)) == 2)
  }

  @Test
  func `Forgetting the data keeps the revision growing, so no cached picture comes back`() {
    var throttle = CarPlayPictureThrottle(minimumInterval: 8)
    _ = throttle.revision(for: "a", now: start)
    throttle.forget()
    #expect(throttle.revision(for: "a", now: start.addingTimeInterval(1)) == 2)
  }

  // MARK: - Map framing

  @Test @MainActor
  func `The map frames both positions as the phone's preview does`() throws {
    let radio = CLLocationCoordinate2D(latitude: 41.88, longitude: -87.63)
    let phone = CLLocationCoordinate2D(latitude: 41.90, longitude: -87.60)
    let base = try #require(GNSSMapFraming.region(for: [radio, phone]))
    let region = try #require(CarPlayPictureSource.region(radio: radio, phone: phone, nodes: []))
    #expect(region.center.latitude == base.center.latitude)
    #expect(region.center.longitude == base.center.longitude)
    #expect(region.span.latitudeDelta == base.span.latitudeDelta)
    #expect(region.span.longitudeDelta == base.span.longitudeDelta)
  }

  // MARK: - Rendering

  private static let size = CGSize(width: 165, height: 220)

  private static let pictures: [CarPlaySnapshot.Picture] = [
    .spectrumHeader(.init(
      condition: "Quiet",
      conditionSymbol: "checkmark.circle.fill",
      conditionTint: .success,
      preset: "USA/Canada",
      frequency: "910.525 MHz",
      modulation: "SF7 · 62.5 kHz · CR 4/5",
      txPower: "22 dBm",
      airtime: "~98 ms/pkt"
    )),
    .spectrumReadings(.init(
      now: "−80 dBm", margin: "+20 dB", isClear: true, snr: "SNR 7.5",
      floor: "−100 dBm", hasFloor: true, trend: "Rising", trendSymbol: "arrow.up.right", history: [-101, -100, -99],
      air: "35.0%", split: "RX 30.0% · TX 5.0%", load: "Busy", loadTint: .warning,
      rate: "12.0/min", count: "12 packets", peak: "Peak −71 dBm"
    )),
    .spectrumChart(revision: 1),
    .spectrumTraffic(revision: 1),
    .compass(.init(course: 90, reading: "90° E", speed: "50 km/h")),
    .compass(.init(course: nil, reading: "No heading")),
    .gnssDevice(.init(side: .radio, detail: "Heltec", status: .fix, latitude: 41.8823, longitude: -87.6232, caption: "Live GPS")),
    .gnssDevice(.init(side: .phone, status: .fix, latitude: 41.8801, longitude: -87.6301, accuracy: 5)),
    .gnssDevice(.init(side: .radio, status: .noRadio, note: "Not connected")),
    .gpsMap(revision: 1),
  ]

  @Test @MainActor
  func `Every picture draws at the card's size and the car's scale, light and dark`() throws {
    for picture in Self.pictures {
      for style in [UIUserInterfaceStyle.light, .dark] {
        let image = try #require(CarPlayPictureImage.render(picture, size: Self.size, scale: 2, style: style), "\(picture)")
        #expect(image.size == Self.size, "\(picture)")
        #expect(image.scale == 2, "\(picture)")
      }
    }
  }

  @Test @MainActor
  func `A picture holds both appearances, and an unchanged one is drawn once`() throws {
    let picture = Self.pictures[0]
    let dark = UITraitCollection { $0.displayScale = 3; $0.userInterfaceStyle = .dark }
    let light = UITraitCollection { $0.displayScale = 3; $0.userInterfaceStyle = .light }
    let first = try #require(CarPlayPictureImage.image(picture, size: Self.size, traits: dark))
    let again = try #require(CarPlayPictureImage.image(picture, size: Self.size, traits: dark))
    #expect(first.imageAsset === again.imageAsset)
    let other = try #require(first.imageAsset?.image(with: light))
    #expect(other.traitCollection.userInterfaceStyle == .light)
    #expect(first.traitCollection.userInterfaceStyle == .dark)
    #expect(first.scale == 3)
  }
}
