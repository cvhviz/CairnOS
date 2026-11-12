import Foundation
@testable import CairnServices
import Testing

@Suite("RemoteCLICommandRewriter")
struct RemoteCLICommandRewriterTests {
  private static let now = Date(timeIntervalSince1970: 1_786_722_487)
  private static let expected = "time 1786722487"

  @Test
  func `clock sync becomes time with the host epoch`() {
    #expect(RemoteCLICommandRewriter.rewrite("clock sync", now: Self.now) == Self.expected)
  }

  @Test(arguments: ["CLOCK SYNC", "  clock   sync  ", "Clock Sync"])
  func `clock sync match is case and whitespace insensitive`(command: String) {
    #expect(RemoteCLICommandRewriter.rewrite(command, now: Self.now) == Self.expected)
    #expect(RemoteCLICommandRewriter.isClockSync(command))
  }

  @Test(arguments: ["clock", "time 123", "clock sync extra", "sync_time", "st"])
  func `other commands are left unchanged`(command: String) {
    #expect(RemoteCLICommandRewriter.rewrite(command, now: Self.now, lead: 3) == command)
    #expect(!RemoteCLICommandRewriter.isClockSync(command))
  }

  @Test
  func `pre epoch dates saturate to zero`() {
    let preEpoch = Date(timeIntervalSince1970: -1000)
    #expect(RemoteCLICommandRewriter.rewrite("clock sync", now: preEpoch) == "time 0")
  }

  @Test
  func `a part second rounds up so the node is never set behind the phone`() {
    let now = Date(timeIntervalSince1970: 1_786_722_487.2)
    #expect(RemoteCLICommandRewriter.rewrite("clock sync", now: now) == "time 1786722488")
  }

  @Test
  func `the time is stamped ahead by the lead`() {
    #expect(RemoteCLICommandRewriter.rewrite("clock sync", now: Self.now, lead: 2) == "time 1786722489")
    let now = Date(timeIntervalSince1970: 1_786_722_487.4)
    #expect(RemoteCLICommandRewriter.rewrite("clock sync", now: now, lead: 1.5) == "time 1786722489")
  }

  @Test
  func `a negative lead stamps the phone time`() {
    #expect(RemoteCLICommandRewriter.rewrite("clock sync", now: Self.now, lead: -10) == Self.expected)
  }

  @Test
  func `the lead grows a second a hop and is capped`() {
    #expect(RemoteCLICommandRewriter.clockSyncLead(pathHopCount: 0) == 1)
    #expect(RemoteCLICommandRewriter.clockSyncLead(pathHopCount: 1) == 2)
    #expect(RemoteCLICommandRewriter.clockSyncLead(pathHopCount: 3) == 4)
    #expect(RemoteCLICommandRewriter.clockSyncLead(pathHopCount: 12) == RemoteCLICommandRewriter.maximumClockSyncLead)
  }

  @Test
  func `a flood or unknown route takes the flood lead`() {
    #expect(RemoteCLICommandRewriter.clockSyncLead(pathHopCount: nil) == RemoteCLICommandRewriter.floodClockSyncLead)
  }
}
