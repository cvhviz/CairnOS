import Foundation
@testable import MeshCore
import Testing

@Suite("CommandCode.transmitsOverAir")
struct TransmitsOverAirTests {
  @Test
  func `Commands that send a packet over the air are flagged`() {
    let onAir: [CommandCode] = [
      .sendMessage, .sendChannelMessage, .sendAdvertisement, .shareContact, .sendRawData, .sendLogin,
      .sendStatusRequest, .sendLogout, .sendTrace, .binaryRequest, .pathDiscovery, .sendControlData,
      .sendAnonReq, .sendChannelData, .sendRawPacket,
    ]
    for code in onAir {
      #expect(code.transmitsOverAir, "\(code)")
    }
  }

  @Test
  func `Commands answered by the radio itself are not`() {
    let local: [CommandCode] = [
      .appStart, .getContacts, .getTime, .setTime, .setName, .setRadio, .setTxPower, .getBattery,
      .deviceQuery, .getChannel, .setChannel, .setOtherParams, .getSelfTelemetry, .getStats,
    ]
    for code in local {
      #expect(!code.transmitsOverAir, "\(code)")
    }
  }

  @Test
  func `Built packets lead with their command code`() {
    #expect(PacketBuilder.sendAdvertisement(flood: true).first.flatMap(CommandCode.init(rawValue:))?.transmitsOverAir == true)
  }
}
