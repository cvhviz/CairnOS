import Foundation
@testable import CairnServices
import Testing

@Suite("ReplyQuote parsing")
struct ReplyQuoteParsingTests {
  @Test
  func `MeshCore reply splits into mention, quote and body`() {
    let quote = ReplyQuote.parse("@[Alice]\n>Meet at th..\nSure, see you there")
    #expect(quote == ReplyQuote(mentionName: "Alice", quotedText: "Meet at th..", body: "Sure, see you there"))
  }

  @Test
  func `our own reply text round-trips through the parser`() {
    let sent = MentionUtilities.buildReplyText(mentionName: "Bob Base", messageText: "Hello everyone out there")
    #expect(sent == "@[Bob Base]\n>Hello ever..\n")
    let quote = ReplyQuote.parse(sent + "Hi!")
    #expect(quote?.mentionName == "Bob Base")
    #expect(quote?.quotedText == "Hello ever..")
    #expect(quote?.body == "Hi!")
  }

  @Test
  func `quote-only reply has an empty body`() {
    #expect(ReplyQuote.parse("@[Alice]\n>short\n")?.body == "")
  }

  @Test
  func `space after the quote marker and CRLF are tolerated`() {
    let quote = ReplyQuote.parse("@[Alice]\r\n> hello\r\nok")
    #expect(quote?.quotedText == "hello")
    #expect(quote?.body == "ok")
  }

  @Test
  func `several quote lines join`() {
    #expect(ReplyQuote.parse("@[A]\n>one\n>two\nbody")?.quotedText == "one\ntwo")
  }

  @Test(arguments: [
    "Hello @[Alice]\n>not a reply",
    "@[Alice] hi\n>quote\nbody",
    "@[Alice]\nno quote line",
    "@[Alice]",
    ">just a quote\nbody",
    "@[Alice]\n>   \nbody",
    "plain text",
  ])
  func `non-replies are left alone`(text: String) {
    #expect(ReplyQuote.parse(text) == nil)
  }
}

@Suite("Channel echo timing")
struct ChannelEchoTimingTests {
  private let sent = Date(timeIntervalSince1970: 1_700_000_000)

  @Test
  func `echoes count as heard straight away`() {
    #expect(ChannelEchoTiming.state(heardRepeats: 2, sentAt: sent, now: sent) == .heard(2))
  }

  @Test
  func `no echo yet is listening inside the wait and not heard after it`() {
    #expect(ChannelEchoTiming.state(heardRepeats: 0, sentAt: sent, now: sent.addingTimeInterval(10)) == .listening)
    #expect(ChannelEchoTiming.state(heardRepeats: 0, sentAt: sent, now: sent.addingTimeInterval(30)) == .notHeard)
  }

  @Test
  func `remaining wait counts down to zero`() {
    #expect(ChannelEchoTiming.remaining(sentAt: sent, now: sent.addingTimeInterval(12)) == 18)
    #expect(ChannelEchoTiming.remaining(sentAt: sent, now: sent.addingTimeInterval(90)) == 0)
  }
}

@Suite("Message clock reading")
struct MessageClockReadingTests {
  private let sent = Date(timeIntervalSince1970: 1_700_000_000)

  @Test
  func `a few seconds is transit`() {
    #expect(MessageClockReading(sent: sent, heard: sent.addingTimeInterval(4)) == .inTransit(4))
    // Whole-second stamps can land a moment after the reception.
    #expect(MessageClockReading(sent: sent, heard: sent.addingTimeInterval(-3)) == .inTransit(0))
  }

  @Test
  func `stamped well after it was heard is a fast sender clock`() {
    let reading = MessageClockReading(sent: sent, heard: sent.addingTimeInterval(-300))
    #expect(reading == .senderAhead(300))
    #expect(reading.suggestsClockOffset)
  }

  @Test
  func `longer than a flood takes is a slow sender clock`() {
    let reading = MessageClockReading(sent: sent, heard: sent.addingTimeInterval(600))
    #expect(reading == .senderBehind(600))
    #expect(reading.suggestsClockOffset)
  }
}

@Suite("Message reception match")
struct MessageReceptionMatchTests {
  private func candidate(_ path: [UInt8], length: UInt8? = nil, source: UInt8? = nil) -> MessageReceptionMatch.Candidate {
    MessageReceptionMatch.Candidate(pathNodes: Data(path), pathLength: length ?? UInt8(path.count), sourceByte: source)
  }

  @Test
  func `the copy with the message's own path wins`() {
    let index = MessageReceptionMatch.bestIndex(
      messagePath: Data([0xA3, 0x7F]),
      messagePathLength: 2,
      senderPrefixByte: nil,
      candidates: [candidate([0xA3]), candidate([0xA3, 0x7F]), candidate([0xA3, 0x7F])]
    )
    #expect(index == 1)
  }

  @Test
  func `no stored path takes a lone candidate but never guesses between several`() {
    #expect(MessageReceptionMatch.bestIndex(
      messagePath: nil, messagePathLength: 0, senderPrefixByte: nil, candidates: [candidate([0x01])]
    ) == 0)
    #expect(MessageReceptionMatch.bestIndex(
      messagePath: nil, messagePathLength: 0, senderPrefixByte: nil, candidates: [candidate([0x01]), candidate([0x02])]
    ) == nil)
  }

  @Test
  func `a DM from another sender is skipped`() {
    let index = MessageReceptionMatch.bestIndex(
      messagePath: Data(),
      messagePathLength: 0,
      senderPrefixByte: 0x42,
      candidates: [candidate([], source: 0x11), candidate([], source: 0x42)]
    )
    #expect(index == 1)
  }

  @Test
  func `no matching path finds nothing`() {
    #expect(MessageReceptionMatch.bestIndex(
      messagePath: Data([0x01]), messagePathLength: 1, senderPrefixByte: nil, candidates: [candidate([0x02])]
    ) == nil)
  }
}
