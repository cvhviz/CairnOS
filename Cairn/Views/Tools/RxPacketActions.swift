import CairnServices
import CoreLocation
import MeshCore
import SwiftUI
import UIKit

/// What a packet leads to beyond its own details, for a row's long-press and the detail sheet's
/// ⋯ menu: the nodes it names open their pages, its sender shows on the map, its route goes to
/// Trace Path, and the packet itself can be shared or its hash copied. The handlers that need
/// the page (opening a node, the map, Trace Path) come from the host; the rest is the menu's own.
struct RxPacketActionHandlers {
  /// Opens the page of a node the packet names, by its key.
  var openNode: ((NeighbourKeyEntry) -> Void)?
  var showOnMap: ((CLLocationCoordinate2D) -> Void)?
  /// Builds Trace Path on the packet's route, first hop beside this radio.
  var traceRoute: (([Data]) -> Void)?
}

/// The menu's items, shared by the context menu and the toolbar menu.
struct RxPacketActionsMenu: View {
  let entry: RxLogEntryDTO
  let packet: PacketNodes
  var handlers = RxPacketActionHandlers()

  @State private var copied = false

  var body: some View {
    let openable = RxPacketShare.openableNodes(packet)
    if let openNode = handlers.openNode, !openable.isEmpty {
      Section {
        ForEach(Array(openable.enumerated()), id: \.offset) { _, node in
          Button {
            openNode(node.entry)
          } label: {
            Label(node.title, systemImage: node.isSender ? "person.crop.circle" : "point.3.connected.trianglepath.dotted")
          }
        }
      }
    }
    Section {
      if let showOnMap = handlers.showOnMap, let coordinate = RxPacketShare.senderCoordinate(packet) {
        Button {
          showOnMap(coordinate)
        } label: {
          Label(L10n.Tools.Tools.RxLog.Action.showOnMap, systemImage: "map")
        }
      }
      if let traceRoute = handlers.traceRoute, let route = RxPacketShare.traceRoute(entry: entry, packet: packet) {
        Button {
          traceRoute(route)
        } label: {
          Label(L10n.Tools.Tools.RxLog.Action.traceRoute, systemImage: ToolSelection.tracePath.systemImage)
        }
      }
    }
    Section {
      ShareLink(item: RxPacketShare.text(entry: entry, packet: packet)) {
        Label(L10n.Tools.Tools.RxLog.Action.shareText, systemImage: "square.and.arrow.up")
      }
      ShareLink(item: RxPacketShare.json(entry: entry, packet: packet)) {
        Label(L10n.Tools.Tools.RxLog.Action.shareJSON, systemImage: "curlybraces")
      }
      Button {
        UIPasteboard.general.string = entry.packetHash
        copied = true
      } label: {
        Label(L10n.Tools.Tools.RxLog.Action.copyHash, systemImage: copied ? "checkmark" : "doc.on.doc")
      }
      .sensoryFeedback(.success, trigger: copied) { _, newValue in newValue }
    }
  }
}

/// A packet as text and as JSON, and the nodes and route it offers, kept pure for the tests.
enum RxPacketShare {
  /// A node the packet names that has a whole key, so it has a page to open.
  struct OpenableNode: Equatable {
    let entry: NeighbourKeyEntry
    let title: String
    let isSender: Bool
  }

  /// The sender, then each hop, that resolves to one node by its whole key.
  static func openableNodes(_ packet: PacketNodes) -> [OpenableNode] {
    var nodes: [OpenableNode] = []
    if let sender = packet.sender, let entry = sender.entry, entry.publicKey.count == ProtocolLimits.publicKeySize {
      nodes.append(OpenableNode(entry: entry, title: L10n.Tools.Tools.RxLog.Action.openSender, isSender: true))
    }
    for hop in packet.hops where !hop.isRadio {
      guard let entry = hop.entry, entry.publicKey.count == ProtocolLimits.publicKeySize,
            !nodes.contains(where: { $0.entry.publicKey == entry.publicKey }) else { continue }
      nodes.append(OpenableNode(entry: entry, title: L10n.Tools.Tools.RxLog.Action.openNode(name(of: hop)), isSender: false))
    }
    return nodes
  }

  /// Where the sender is, when the packet names it and it has advertised a position.
  static func senderCoordinate(_ packet: PacketNodes) -> CLLocationCoordinate2D? {
    guard let sender = packet.sender, !sender.isUnverified, let coordinate = sender.coordinate,
          coordinate.latitude != 0 || coordinate.longitude != 0 else { return nil }
    return coordinate
  }

  /// The route for Trace Path, first hop beside this radio: a flood's hops back the way it came,
  /// ending at its sender when the sender's whole key is known; a direct packet's route still
  /// ahead as it stands; a trace's targets. Nil when the packet names no hop.
  static func traceRoute(entry: RxLogEntryDTO, packet: PacketNodes) -> [Data]? {
    let hops = packet.hops.filter { !$0.isRadio }.map { $0.key ?? $0.hash }.filter { !$0.isEmpty }
    guard !hops.isEmpty else { return nil }
    if entry.payloadType == .trace || packet.isRouteAhead { return hops }
    var route = Array(hops.reversed())
    if let sender = packet.sender, let key = sender.key, key.count == ProtocolLimits.publicKeySize, !sender.isUnverified {
      route.append(key)
    }
    return route
  }

  /// The packet as a few lines of text: when, type and route, who to whom, the signal, the hops,
  /// the message, the hash.
  static func text(entry: RxLogEntryDTO, packet: PacketNodes) -> String {
    var lines: [String] = []
    lines.append("\(entry.payloadType.displayName) · \(entry.routeTypeSimple) · \(entry.receivedAt.formatted(date: .abbreviated, time: .standard))")
    let from = packet.sender.map(name(of:)) ?? entry.fromContactName
    let to = packet.recipient.map { labelOf($0) } ?? entry.toContactName
    if let from {
      lines.append("\(RxLogRowView.bareLabel(L10n.Tools.Tools.RxLog.fromLabel)): \(from)")
    }
    if let to {
      lines.append("\(RxLogRowView.bareLabel(L10n.Tools.Tools.RxLog.toLabel)): \(to)")
    }
    var signal: [String] = []
    if let snr = entry.snr { signal.append("SNR \(snr.formatted(.number.precision(.fractionLength(1)))) dB") }
    if let rssi = entry.rssi { signal.append("RSSI \(rssi) dBm") }
    if !signal.isEmpty { lines.append(signal.joined(separator: " · ")) }
    let hops = packet.hops.map(name(of:))
    if !hops.isEmpty {
      lines.append("\(RxLogRowView.bareLabel(L10n.Tools.Tools.RxLog.pathLabel)): \(hops.joined(separator: " → "))")
    }
    if let text = entry.decodedText {
      lines.append("\u{201C}\(text)\u{201D}")
    }
    lines.append("\(RxLogRowView.bareLabel(L10n.Tools.Tools.RxLog.hashLabel)): \(entry.packetHash)")
    return lines.joined(separator: "\n")
  }

  /// The packet as JSON, keys sorted: its figures as the CSV export writes them, the nodes it
  /// names by name and hex, and its bytes.
  static func json(entry: RxLogEntryDTO, packet: PacketNodes) -> String {
    var object: [String: Any] = [
      "received_at_utc": ExportFormat.timestamp(entry.receivedAt) ?? "",
      "route": entry.routeTypeSimple,
      "payload_type": entry.payloadType.displayName,
      "payload_version": Int(entry.payloadVersion),
      "hops": entry.hopCount,
      "path_hex": ExportFormat.hex(entry.pathNodes) ?? "",
      "packet_hash": entry.packetHash,
      "decrypt_status": "\(entry.decryptStatus)",
      "size_bytes": entry.rawPayload.count,
      "raw_hex": ExportFormat.hex(entry.rawPayload) ?? "",
      "hop_names": packet.hops.map(name(of:)),
    ]
    if let snr = entry.snr { object["snr_db"] = snr }
    if let rssi = entry.rssi { object["rssi_dbm"] = rssi }
    if let sender = packet.sender {
      object["from"] = name(of: sender)
      if let key = sender.key { object["from_key_hex"] = ExportFormat.hex(key) ?? "" }
    } else if let from = entry.fromContactName {
      object["from"] = from
    }
    if let recipient = packet.recipient {
      object["to"] = labelOf(recipient)
    } else if let to = entry.toContactName {
      object["to"] = to
    }
    if let text = entry.decodedText { object["text"] = text }
    if let channelName = entry.channelName { object["channel"] = channelName }
    if let channel = entry.channel { object["radio_channel"] = RxLogRowView.channelText(channel) }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let json = String(data: data, encoding: .utf8) else { return "{}" }
    return json
  }

  /// A node as the lists name it: "You" for this radio, its name or hash otherwise.
  static func name(of node: PacketNode) -> String {
    if node.isRadio { return L10n.Tools.Tools.RxLog.pathYou }
    return node.displayName ?? node.hash.uppercaseHexString()
  }

  private static func labelOf(_ match: PacketNodeMatch) -> String {
    name(of: PacketNode(role: .sender(.peerHash), hash: Data(), match: match))
  }
}

/// Finds the stored page for a node a packet names: its saved contact, or its heard node.
@MainActor
enum PacketNodeLookup {
  static func stored(key: Data, appState: AppState) async -> (contact: ContactDTO?, discovered: DiscoveredNodeDTO?) {
    guard let radioID = appState.currentRadioID, let store = appState.offlineDataStore else { return (nil, nil) }
    if let contact = try? await store.fetchContact(radioID: radioID, publicKey: key) {
      return (contact, nil)
    }
    let discovered = (try? await store.fetchDiscoveredNodes(radioID: radioID))?.first { $0.publicKey == key }
    return (nil, discovered)
  }
}
