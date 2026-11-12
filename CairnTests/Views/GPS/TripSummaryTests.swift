import CairnServices
import Foundation
import Testing
@testable import Cairn

/// A trip's sums, worked out from the points copied from the radio, agree with what the radio's own Trip
/// page works out (firmware TripMath.h).
@Suite("TripSummary")
struct TripSummaryTests {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  /// ~111 m per 0.001 degree of latitude
  private let lat0 = 45.0, lon0 = -122.0

  private func point(_ i: Int, dLat: Double, alt: Double?, seconds: Double) -> TripLogPointDTO {
    TripLogPointDTO(timestamp: t0.addingTimeInterval(seconds), latitude: lat0 + dLat, longitude: lon0, altitude: alt)
  }

  @Test
  func `standing still adds nothing`() {
    let points = (0..<60).map { point($0, dLat: Double($0 % 4) * 0.00002, alt: 100 + Double($0 % 5) * 2, seconds: Double($0) * 5) }
    let s = TripSummary(points)
    #expect(s.distance == 0)
    #expect(s.movingTime == 0)
    #expect(s.climb == 0)
    #expect(s.points.count == 1)
  }

  @Test
  func `a walk counts its distance, moving time and climb`() {
    // 1 km north in 100 m steps a minute apart, 10 m higher each step
    let points = (0...10).map { point($0, dLat: Double($0) * 0.0009, alt: 100 + Double($0) * 10, seconds: Double($0) * 60) }
    let s = TripSummary(points)
    #expect(abs(s.distance - 1000) < 10)
    #expect(s.movingTime == 600)
    #expect(s.climb > 70 && s.climb <= 100)
    #expect(s.descent == 0)
    #expect(s.lowest == 100)
    #expect(s.points.count == 11)
  }

  @Test
  func `bad fixes and gaps are handled`() {
    let points = [
      point(0, dLat: 0, alt: nil, seconds: 0),
      point(1, dLat: 0.9, alt: nil, seconds: 10),                 // 100 km in 10 s: dropped
      point(2, dLat: 0.00005, alt: nil, seconds: 20),             // 5 m: jitter
      point(3, dLat: 0.009, alt: nil, seconds: 3600),             // 1 km after an hour
    ]
    let s = TripSummary(points)
    #expect(abs(s.distance - 1000) < 10)
    #expect(s.movingTime == 0)
    #expect(!s.hasAltitude)
  }

  @Test
  func `thinning keeps the ends`() {
    let points = (0...999).map { point($0, dLat: Double($0) * 0.0002, alt: nil, seconds: Double($0) * 30) }
    let s = TripSummary(points)
    let thin = s.thinned(to: 50)
    #expect(thin.count == 50)
    #expect(thin.first == s.points.first)
    #expect(thin.last == s.points.last)
  }
}
