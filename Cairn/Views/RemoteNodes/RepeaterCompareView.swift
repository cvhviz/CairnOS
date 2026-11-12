import CairnServices
import SwiftUI

/// Two repeaters (or rooms) side by side, from their latest stored readings: battery, uptime,
/// noise, packets, neighbours and firmware. Nothing is asked of the mesh; the figures are what
/// their pages last saved (`NodeSnapshotService`, `NodeCardCache`).
struct RepeaterCompareView: View {
  @Environment(\.appState) private var appState
  /// The node the comparison was opened from, preselected on the left.
  let primaryPublicKey: Data?

  @State private var candidates: [ContactDTO] = []
  @State private var leftKey: Data?
  @State private var rightKey: Data?
  @State private var left: RepeaterCompareColumn?
  @State private var right: RepeaterCompareColumn?

  var body: some View {
    CardForm {
      CardFormSection(info: L10n.RemoteNodes.RemoteNodes.Compare.pickPrompt) {
        ContentCard {
          picker(L10n.RemoteNodes.RemoteNodes.Compare.pickA, selection: $leftKey)
          Divider()
          picker(L10n.RemoteNodes.RemoteNodes.Compare.pickB, selection: $rightKey)
        }
      }

      if left != nil || right != nil {
        CardFormSection {
          table
            .cardSurface(padding: 12)
        }
      }
    }
    .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Compare.title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      guard let radioID = appState.connectedDevice?.radioID, let dataStore = appState.services?.dataStore else { return }
      let contacts = await (try? dataStore.fetchContacts(radioID: radioID)) ?? []
      candidates = contacts.filter { $0.type == .repeater || $0.type == .room }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
      if leftKey == nil, let primaryPublicKey, candidates.contains(where: { $0.publicKey == primaryPublicKey }) {
        leftKey = primaryPublicKey
      }
    }
    .task(id: leftKey) { left = await load(leftKey) }
    .task(id: rightKey) { right = await load(rightKey) }
  }

  private func picker(_ title: String, selection: Binding<Data?>) -> some View {
    CardFieldRow(title: title, hidesTitleFromAccessibility: true) {
      Picker(title, selection: selection) {
        Text(verbatim: "—").tag(Data?.none)
        ForEach(candidates) { contact in
          Text(contact.displayName).tag(Data?.some(contact.publicKey))
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .tint(.primary)
    }
  }

  private func load(_ key: Data?) async -> RepeaterCompareColumn? {
    guard let key, let contact = candidates.first(where: { $0.publicKey == key }) else { return nil }
    let snapshot = await appState.services?.nodeSnapshotService.previousStatusSnapshot(for: key, before: .now)
    let curve = NodeStatusViewModel.batteryCurve(presetName: contact.ocvPreset, customString: contact.customOCVArrayString)
    return RepeaterCompareColumn(
      name: contact.displayName,
      snapshot: snapshot,
      cache: NodeCardCache.load(publicKey: key),
      ocvValues: curve.values
    )
  }

  /// The rows, a value for each side; a side without a stored reading says so.
  private var table: some View {
    let rows = RepeaterCompareColumn.rows(left: left, right: right)
    return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
      GridRow {
        Text(verbatim: "")
        Text(left?.name ?? "—")
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
        Text(right?.name ?? "—")
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
      }
      Divider().gridCellUnsizedAxes(.horizontal)
      ForEach(rows) { row in
        GridRow {
          Text(row.title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(row.left)
            .monospacedDigit()
          Text(row.right)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
      }
    }
    .font(.subheadline)
  }
}

/// One side of the comparison: the figures as text, from the node's last stored reading. Main
/// actor, as the formatters it borrows from the status view model are.
@MainActor
struct RepeaterCompareColumn: Equatable {
  struct Row: Identifiable, Equatable {
    let title: String
    let left: String
    let right: String
    var id: String { title }
  }

  let name: String
  let snapshot: NodeStatusSnapshotDTO?
  let cache: NodeCardCache.Entry?
  let ocvValues: [Int]

  private static let dash = "—"

  var battery: String {
    guard let mv = snapshot?.batteryMillivolts, mv > 0 else { return Self.dash }
    let percent = BatteryInfo(level: Int(mv)).percentage(using: ocvValues)
    let volts = (Double(mv) / 1000).formatted(.number.precision(.fractionLength(2)))
    return "\(BatteryLevel.formattedPercent(percent)) · \(volts) V"
  }

  var uptime: String {
    guard let seconds = snapshot?.uptimeSeconds else { return Self.dash }
    return NodeStatusViewModel.formatDuration(seconds)
  }

  var noise: String {
    guard let noise = snapshot?.noiseFloor else { return Self.dash }
    return "\(noise) dBm"
  }

  var packets: String {
    guard let snapshot, let received = snapshot.packetsReceived, let sent = snapshot.packetsSent else {
      return Self.dash
    }
    return "↓ \(received.formatted()) · ↑ \(sent.formatted())"
  }

  var neighbors: String {
    if let count = snapshot?.neighborSnapshots?.count { return count.formatted() }
    if let count = cache?.neighborCount { return count.formatted() }
    return Self.dash
  }

  var firmware: String {
    cache?.firmwareVersion ?? Self.dash
  }

  var readAt: String {
    guard let snapshot else { return L10n.RemoteNodes.RemoteNodes.Compare.noSnapshot }
    let when = snapshot.timestamp.formatted(.relative(presentation: .named))
    return L10n.RemoteNodes.RemoteNodes.Compare.readAt(when)
  }

  static func rows(left: RepeaterCompareColumn?, right: RepeaterCompareColumn?) -> [Row] {
    func row(_ title: String, _ value: (RepeaterCompareColumn) -> String) -> Row {
      let leftText = left.map(value) ?? dash
      let rightText = right.map(value) ?? dash
      return Row(title: title, left: leftText, right: rightText)
    }
    let status = L10n.RemoteNodes.RemoteNodes.Status.self
    var rows: [Row] = []
    rows.append(row(status.battery) { $0.battery })
    rows.append(row(status.uptime) { $0.uptime })
    rows.append(row(status.noiseFloor) { $0.noise })
    rows.append(row(status.packets) { $0.packets })
    rows.append(row(status.neighbors) { $0.neighbors })
    rows.append(row(L10n.RemoteNodes.RemoteNodes.Settings.firmware) { $0.firmware })
    rows.append(row(L10n.Contacts.Contacts.Detail.lastHeard) { $0.readAt })
    return rows
  }
}
