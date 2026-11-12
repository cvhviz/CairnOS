import CairnServices
import CoreLocation
import MeshCore
import SwiftUI
import UIKit

/// The packets the radio hears as a list on its own: Spectrum's See All, and the main map's traffic
/// sheet. The Traffic page's map is Scan & Traffic's now (`NodeDiscoveryView`), whose Packets
/// section lists the same packets with the same filters and actions.
struct RxLogView: View {
  @Environment(\.appState) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appTheme) private var theme

  @State private var viewModel = RxLogViewModel()
  /// The packet whose details are open in a sheet.
  @State private var detailEntry: RxLogEntryDTO?
  @State private var groupDuplicates = false
  /// The list held still while scrolled away from the top (`PacketListFreeze`).
  @State private var freeze = PacketListFreeze<RxLogEntryDTO>()
  @State private var contactForDetail: ContactDTO?
  @State private var discoveredForDetail: DiscoveredNodeDTO?

  var body: some View {
    Group {
      if appState.services?.rxLogService == nil {
        disconnectedState
      } else {
        packetList
      }
    }
    .navigationTitle(L10n.Tools.Tools.Traffic.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        MarkedPageTitle(title: L10n.Tools.Tools.Traffic.title)
      }
      toolbarContent
    }
    .searchable(text: $viewModel.searchText, prompt: L10n.Tools.Tools.RxLog.search)
    .detailPresentation(item: $contactForDetail, route: { .contact(id: $0.id, canHideFromMap: false) }) { contact in
      ContactDetailSheet(
        contact: contact,
        onMessage: {
          contactForDetail = nil
          appState.navigation.navigateToChat(with: contact)
        },
        onDelete: {}
      )
      .presentationDetents([.large])
    }
    .detailPresentation(item: $discoveredForDetail, route: {
      .discoveredNode(id: $0.id, radioID: $0.radioID, canHideFromMap: false)
    }) { node in
      DiscoveredNodeDetailSheet(node: node, isAdding: false, onAdd: {
        discoveredForDetail = nil
        guard let service = appState.services?.contactService, let radioID = appState.currentRadioID else { return }
        Task { try? await service.addOrUpdateContact(radioID: radioID, contact: node.makeContactFrame()) }
      })
      .presentationDetents([.medium, .large])
    }
    .task(id: appState.servicesVersion) {
      viewModel.configure(
        rxLogService: { [appState] in appState.services?.rxLogService },
        rxStreamService: { [appState] in appState.services?.rxStreamService },
        observations: appState.observationDirectory
      )
      await viewModel.subscribe()
    }
    .onDisappear {
      viewModel.unsubscribe()
    }
  }

  // MARK: - List

  /// The packets newest first, or the listening state before any; with the CSV export its menu
  /// offers, so the export presents from wherever the list is.
  private var packetList: some View {
    Group {
      if viewModel.entries.isEmpty {
        emptyState
      } else {
        entryList
      }
    }
    .fileExporter(
      isPresented: Binding(
        get: { csvExport != nil },
        set: { if !$0 { discardCSVExport() } }
      ),
      document: csvExport?.document,
      contentType: .commaSeparatedText,
      defaultFilename: csvExport?.filename
    ) { _ in
      discardCSVExport()
    }
    .sensoryFeedback(.selection, trigger: detailEntry) { _, entry in entry != nil }
    .sheet(item: $detailEntry) { entry in
      RxPacketDetailSheet(
        entry: entry,
        groupCount: groupDuplicates ? viewModel.groupCounts[entry.packetHash, default: 1] : 1,
        nodeIndex: viewModel.nodeIndex,
        packet: viewModel.packetNodes(for: entry),
        origin: appState.bestAvailableLocation,
        currentChannelKey: viewModel.nodeIndex.channelKey,
        echo: viewModel.echo(for: entry),
        actions: packetActions(closingSheet: true)
      )
    }
  }

  /// What a packet's menu can do from this page: open a node's page (looked up in the stored
  /// records), show its sender on the map, build Trace Path on its route. From the detail sheet
  /// the sheet closes first, so the page under it can present or navigate.
  private func packetActions(closingSheet: Bool) -> RxPacketActionHandlers {
    RxPacketActionHandlers(
      openNode: { node in
        if closingSheet { detailEntry = nil }
        Task {
          let stored = await PacketNodeLookup.stored(key: node.publicKey, appState: appState)
          if let contact = stored.contact {
            contactForDetail = contact
          } else if let discovered = stored.discovered {
            discoveredForDetail = discovered
          }
        }
      },
      showOnMap: { coordinate in
        if closingSheet { detailEntry = nil }
        appState.navigation.navigateToMap(coordinate: coordinate)
      },
      traceRoute: { route in
        if closingSheet { detailEntry = nil }
        appState.navigation.navigateToTraceRoute(route)
      }
    )
  }

  // MARK: - Empty State

  private var emptyState: some View {
    ContentUnavailableView {
      Label(L10n.Tools.Tools.RxLog.listening, systemImage: "antenna.radiowaves.left.and.right")
    } description: {
      Text(L10n.Tools.Tools.RxLog.listeningDescription)
    }
  }

  private var disconnectedState: some View {
    RadioNotConnectedView(description: L10n.Tools.Tools.RxLog.notConnectedDescription)
  }

  // MARK: - Entry List

  /// The list, held still while scrolled away from its top, with a pill saying how many packets
  /// landed meanwhile that jumps back to the top.
  private var entryList: some View {
    let live = Array(displayEntries)
    let shown = freeze.entries(live: live)
    let newCount = freeze.newCount(live: live)
    return ScrollViewReader { proxy in
      List {
        Section {
          ForEach(shown, id: \.id) { entry in
            let packet = viewModel.packetNodes(for: entry)
            RxLogRowView(
              entry: entry,
              onOpen: { detailEntry = entry },
              groupCount: groupDuplicates ? viewModel.groupCounts[entry.packetHash, default: 1] : 1,
              nodeIndex: viewModel.nodeIndex,
              packet: packet,
              origin: appState.bestAvailableLocation,
              currentChannelKey: viewModel.nodeIndex.channelKey,
              echo: viewModel.echo(for: entry)
            )
            .cardListRow(theme)
            .contextMenu {
              RxPacketActionsMenu(entry: entry, packet: packet, handlers: packetActions(closingSheet: false))
            }
          }
        } header: {
          liveStatusHeader
            .textCase(nil)
            .id(Self.topAnchor)
        }
      }
      .cardListCanvas(theme)
      // Away from the top, the rows hold still; back at it, the list goes live again.
      .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > Self.freezeOffset } action: { _, away in
        if away {
          freeze.freeze(live)
        } else {
          freeze.release()
        }
      }
      .overlay(alignment: .top) {
        if newCount > 0 {
          NewPacketsPill(count: newCount) {
            withAnimation(reduceMotion ? nil : .snappy) {
              proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
            freeze.release()
          }
          .padding(.top, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(reduceMotion ? nil : .snappy, value: newCount > 0)
    }
  }

  private static let topAnchor = "rxLog.top"
  /// How far down the list counts as scrolled away from the top.
  static let freezeOffset: CGFloat = 60

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      filterMenu
    }
    ToolbarItem(placement: .topBarTrailing) {
      overflowMenu
    }
  }

  private var isConnected: Bool {
    appState.services?.rxLogService != nil
  }

  private var liveStatusHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        statusPill

        Text(L10n.Tools.Tools.RxLog.packetsCount(viewModel.entries.count))
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Spacer()
      }

      RxLogDeliveryNotes(viewModel: viewModel, isConnected: isConnected)
    }
    .modifier(GlassContainerModifier())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(liveStatusAccessibilityLabel)
  }

  private var liveStatusAccessibilityLabel: String {
    let status = "\(isConnected ? L10n.Tools.Tools.RxLog.live : L10n.Tools.Tools.RxLog.offline), \(L10n.Tools.Tools.RxLog.packetsCount(viewModel.entries.count))"
    let learning = viewModel.isLearningChannel ? L10n.Tools.Tools.RxLog.learningChannel(viewModel.ledgerNodeCount) : nil
    guard isConnected else { return ([status] + [learning].compactMap(\.self)).joined(separator: ", ") }
    return ([status] + [viewModel.deliveryLine, viewModel.longPacketNote, learning].compactMap(\.self)).joined(separator: ", ")
  }

  private var statusPill: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(isConnected ? .green : .gray)
        .frame(width: 8, height: 8)
        .modifier(PulseAnimationModifier(isActive: isConnected && !reduceMotion))

      Text(isConnected ? L10n.Tools.Tools.RxLog.live : L10n.Tools.Tools.RxLog.offline)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .modifier(GlassEffectModifier())
  }

  private var filterMenu: some View {
    Menu {
      RxLogFilterSections(viewModel: viewModel)
    } label: {
      RxLogFilterLabel(viewModel: viewModel)
    }
    .liquidGlassSecondaryButtonStyle()
  }

  @State private var showClearConfirmation = false
  @State private var csvExport: ExportedFile?

  private var overflowMenu: some View {
    Menu {
      RxLogListActions(
        viewModel: viewModel,
        groupDuplicates: $groupDuplicates,
        onExport: exportCSV,
        onDelete: { showClearConfirmation = true }
      )
    } label: {
      Label(L10n.Tools.Tools.RxLog.more, systemImage: "ellipsis.circle")
    }
    .liquidGlassSecondaryButtonStyle()
    .modifier(DeleteLogsConfirmation(isPresented: $showClearConfirmation, delete: clearLog))
  }

  // MARK: - Helpers

  /// Newest first; the view model keeps the filtered and grouped lists current as packets land.
  private var displayEntries: ReversedCollection<ArraySlice<RxLogEntryDTO>> {
    viewModel.displayEntries(groupingDuplicates: groupDuplicates)
  }

  /// Exports the currently filtered (and decrypted) entries.
  private func exportCSV() {
    csvExport = viewModel.csvExport(for: displayEntries)
  }

  /// The exporter saves from the document, so the staged temporary copy goes as soon as it closes.
  private func discardCSVExport() {
    csvExport?.removeTemporaryFile()
    csvExport = nil
  }

  private func clearLog() {
    Task {
      await viewModel.clearLog()
    }
    detailEntry = nil
  }
}

// MARK: - Shared list pieces

/// The list's filters, as menu sections: the route type (which the Scan & Traffic map follows too)
/// and the decrypt status. Shared by this list's toolbar and Scan & Traffic's Packets section.
struct RxLogFilterSections: View {
  let viewModel: RxLogViewModel

  var body: some View {
    Section(L10n.Tools.Tools.RxLog.routeType) {
      ForEach(RxLogViewModel.RouteFilter.allCases, id: \.self) { filter in
        Button {
          viewModel.setRouteFilter(filter)
        } label: {
          HStack {
            Text(filter.displayName)
            if viewModel.routeFilter == filter {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    }

    Section(L10n.Tools.Tools.RxLog.decryptStatus) {
      ForEach(RxLogViewModel.DecryptFilter.allCases, id: \.self) { filter in
        Button {
          viewModel.setDecryptFilter(filter)
        } label: {
          HStack {
            Text(filter.displayName)
            if viewModel.decryptFilter == filter {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    }

    Section(L10n.Tools.Tools.RxLog.Filter.type) {
      ForEach(RxLogViewModel.TypeFilter.allCases, id: \.self) { filter in
        Button {
          viewModel.setTypeFilter(filter)
        } label: {
          HStack {
            Text(filter.displayName)
            if viewModel.typeFilter == filter {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    }

    // The nodes packets came from, busiest first; a submenu, since the list can be long.
    let senders = viewModel.senderOptions
    if !senders.isEmpty {
      Menu {
        Button {
          viewModel.setSenderFilter(nil)
        } label: {
          HStack {
            Text(L10n.Tools.Tools.RxLog.Filter.anyNode)
            if viewModel.senderFilter == nil { Image(systemName: "checkmark") }
          }
        }
        ForEach(senders) { sender in
          Button {
            viewModel.setSenderFilter(sender.key)
          } label: {
            HStack {
              Text("\(sender.name) · \(sender.count.formatted())")
              if viewModel.senderFilter == sender.key { Image(systemName: "checkmark") }
            }
          }
        }
      } label: {
        let picked = senders.first { $0.key == viewModel.senderFilter }
        Label(
          picked.map { "\(L10n.Tools.Tools.RxLog.Filter.fromNode): \($0.name)" } ?? L10n.Tools.Tools.RxLog.Filter.fromNode,
          systemImage: "person.wave.2"
        )
      }
    }
  }
}

/// "3 new ↑": over a held list, how many packets landed since it was held; a tap jumps back to
/// the top, where the list goes live again.
struct NewPacketsPill: View {
  let count: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(L10n.Tools.Tools.RxLog.newPackets(count), systemImage: "arrow.up")
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor, in: .capsule)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("rxLog.newPackets")
  }
}

/// The filter menu's label, filled while a filter leaves packets out.
struct RxLogFilterLabel: View {
  let viewModel: RxLogViewModel

  var body: some View {
    Label(L10n.Tools.Tools.RxLog.filter, systemImage: viewModel.isFiltered
      ? "line.3.horizontal.decrease.circle.fill"
      : "line.3.horizontal.decrease.circle")
  }
}

/// What the list's ⋯ menu offers: grouping duplicates, the CSV export and deleting the log. The
/// export and the delete confirmation present from the menu's owner.
struct RxLogListActions: View {
  let viewModel: RxLogViewModel
  @Binding var groupDuplicates: Bool
  let onExport: () -> Void
  let onDelete: () -> Void

  var body: some View {
    Button {
      groupDuplicates.toggle()
    } label: {
      HStack {
        Text(L10n.Tools.Tools.RxLog.groupDuplicates)
        if groupDuplicates { Image(systemName: "checkmark") }
      }
    }

    Button(action: onExport) {
      Label(L10n.Tools.Tools.RxLog.exportCSV, systemImage: "square.and.arrow.up")
    }
    .disabled(viewModel.entries.isEmpty)

    Divider()

    Button(role: .destructive, action: onDelete) {
      Label(L10n.Tools.Tools.RxLog.deleteLogs, systemImage: "trash")
    }
  }
}

/// How the packets reach the app, under the list's count: counted with Cairn RX_SYNC, measured with
/// the radio's packet counter on other firmware, or a caveat where neither is possible; what
/// never leaves the radio without RX_SYNC; and, while the channel is still being learned, that
/// relays show by hash until their nodes are heard.
struct RxLogDeliveryNotes: View {
  let viewModel: RxLogViewModel
  let isConnected: Bool

  var body: some View {
    if isConnected, let deliveryLine = viewModel.deliveryLine {
      Text(deliveryLine)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    // Without RX_SYNC, long packets never leave the radio.
    if isConnected, let longPacketNote = viewModel.longPacketNote {
      Text(longPacketNote)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    // Relays are named only once their nodes are heard on this channel: lately started, many
    // still show by hash.
    if viewModel.isLearningChannel {
      Label(L10n.Tools.Tools.RxLog.learningChannel(viewModel.ledgerNodeCount), systemImage: "ear")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

extension RxLogViewModel {
  /// A filter leaves packets out of the list (and, for the route, off the map).
  var isFiltered: Bool {
    activeFilterCount > 0
  }

  /// How many of the filters are on, for a badge: the route, the decrypt status, the type and
  /// the sender. The search isn't a filter: its field shows what it does.
  var activeFilterCount: Int {
    (routeFilter == .all ? 0 : 1) + (decryptFilter == .all ? 0 : 1) + (typeFilter == .all ? 0 : 1) + (senderFilter == nil ? 0 : 1)
  }

  /// The CSV of `entries` (the list as filtered and decrypted), staged for the file exporter.
  func csvExport(for entries: some Sequence<RxLogEntryDTO>) -> ExportedFile {
    let table = csvTable(for: entries)
    return ExportedFile(
      data: table.renderData(),
      filename: "Cairn-rx-log-\(ExportFormat.filenameStamp()).csv",
      contentType: .commaSeparatedText,
      recordCount: table.rows.count
    )
  }
}

// MARK: - Row View

struct RxLogRowView: View {
  let entry: RxLogEntryDTO
  /// Opens this packet's details, for a row in a list.
  var onOpen: (() -> Void)?
  let groupCount: Int
  /// Every node the packet names (sender, hops, recipient), resolved by the same index and rules
  /// the Traffic map places them by.
  let packet: PacketNodes
  /// Where you are, for the sender's distance and direction.
  var origin: CLLocation?
  /// Lays the packet out as the detail sheet's cards rather than as a list row.
  var showsDetailOnly = false
  /// The channel the radio is on now: a packet received on another says so.
  var currentChannelKey: ChannelKey?
  /// The send this packet echoes or answers, when this radio sent it.
  var echo: (send: OwnTransmission, match: EchoMatch)?
  /// One line (Scan & Traffic's Packets): its type, who to whom, hops, time and signal. The rest,
  /// and the notes about it, are in its detail sheet.
  var isCompact = false
  /// The saved node an anonymous request's claimed key belongs to, for "Claims to be".
  private let claimedName: String?

  /// - Parameter packet: `entry`'s nodes already resolved against `nodeIndex` (the list keeps
  ///   them per entry); resolved here when nil, as the list and the map resolve them.
  init(
    entry: RxLogEntryDTO,
    onOpen: (() -> Void)? = nil,
    groupCount: Int,
    nodeIndex: PacketNodeIndex,
    packet: PacketNodes? = nil,
    origin: CLLocation? = nil,
    showsDetailOnly: Bool = false,
    currentChannelKey: ChannelKey? = nil,
    echo: (send: OwnTransmission, match: EchoMatch)? = nil,
    isCompact: Bool = false
  ) {
    self.entry = entry
    self.onOpen = onOpen
    self.groupCount = groupCount
    let packet = packet ?? TrafficRouteResolver.packetNodes(for: entry, in: nodeIndex, sent: TrafficSentLog.shared.snapshot)
    self.packet = packet
    self.origin = origin
    self.showsDetailOnly = showsDetailOnly
    self.currentChannelKey = currentChannelKey
    self.echo = echo
    self.isCompact = isCompact
    claimedName = packet.sender?.claimedKey.flatMap { nodeIndex.label(forKey: $0) }
  }

  var body: some View {
    if showsDetailOnly {
      packetDetail
    } else {
      Button {
        onOpen?()
      } label: {
        HStack(spacing: 8) {
          if isCompact {
            compactContent
          } else {
            collapsedContent
          }
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(.tertiaryLabel))
            .accessibilityHidden(true)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityHint(L10n.Tools.Tools.Spectrum.Detail.title)
    }
  }

  // MARK: - Collapsed Content (3 lines)

  /// Who sent a packet, as far as it says and as the resolver the Traffic map shares names it: an
  /// advert's or anonymous request's key, a decrypted direct message's contact, a peer packet's
  /// source byte, a node discovery answer's key, a channel message's typed name.
  struct Sender {
    let name: String
    let kind: ContactType?
    let coordinate: CLLocationCoordinate2D?
    /// A guess among nodes sharing a short hash: its name ends "?".
    var isUncertain = false
  }

  var sender: Sender? {
    guard let node = packet.sender, let name = label(for: node) else { return nil }
    return Sender(
      name: name,
      kind: ContactType(rawValue: node.nodeTypeRaw),
      coordinate: node.coordinate,
      isUncertain: node.match?.isUncertain == true || node.isProbable
    )
  }

  /// Who the packet is addressed to, from its destination byte: a direct message, request or reply.
  private var recipientName: String? {
    packet.recipient.map { label(for: $0) }
  }

  /// "4.2 mi NE": how far and which way the sender is, when both positions are known.
  private func distanceText(_ coordinate: CLLocationCoordinate2D?) -> String? {
    guard let coordinate, let origin,
          let distance = NodeRouteFormat.distance(from: origin, latitude: coordinate.latitude, longitude: coordinate.longitude)
    else { return nil }
    return "\(distance) \(HomeFormat.compassPoint(bearing: HomeFormat.bearing(from: origin.coordinate, to: coordinate)))"
  }

  /// The message without its sender, who is on the line above.
  private var previewText: String? {
    guard let text = entry.decodedText else { return nil }
    if packet.sender?.channelName != nil, let colon = text.range(of: ": ") {
      return String(text[colon.upperBound...])
    }
    return text
  }

  /// Fetched again from the radio after its frame went missing, so it arrived late and out of
  /// order: its time is when the radio heard it.
  var isRecovered: Bool {
    entry.isBackfill
  }

  /// "Received on 910.525 MHz · SF10" for a packet heard on another channel than the radio is on
  /// now, named against what was heard there; "Cairn couldn't confirm which radio channel…" for
  /// one with no channel stamp (stored before channels were recorded, heard during a retune, or
  /// held by the radio before this connection confirmed its channel). Nil otherwise.
  var channelCaption: String? {
    guard packet.isChannelRecorded else { return L10n.Tools.Tools.RxLog.channelNotRecorded }
    guard let key = entry.channelKey, let currentChannelKey, key != currentChannelKey else { return nil }
    let channel = entry.channel ?? RadioChannelConfig(key: key)
    return channel.map { L10n.Tools.Tools.RxLog.receivedOn(Self.channelText($0)) }
  }

  /// "910.525 MHz · SF10". Nonisolated: RxPacketShare formats packets off the main actor.
  nonisolated static func channelText(_ channel: RadioChannelConfig) -> String {
    "\(channel.frequencyMHz.formatted(.number.precision(.fractionLength(0...3)))) MHz · SF\(channel.spreadingFactor)"
  }

  /// "Heard from Claremont · 6.5 dB": the node that transmitted the frame this radio received, by
  /// name, or by hash when no node heard on this channel has it. Nil when the packet doesn't say.
  var heardFromText: String? {
    guard let node = packet.transmitterNode, let name = label(for: node) ?? (node.hash.isEmpty ? nil : node.hash.uppercaseHexString()) else { return nil }
    guard let snr = entry.snr else { return L10n.Tools.Tools.Traffic.Link.heardFrom(name) }
    return L10n.Tools.Tools.Traffic.Link.heardFromSignal(name, "\(SpectrumPacketFormat.snr(snr)) dB")
  }

  private var signalText: String? {
    let parts = [
      entry.snrDisplayString.map { "SNR \($0)" },
      entry.rssi.map { "RSSI \($0)" },
    ].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The packet in one line: its type by its laser's colour, who sent it and to whom (else its
  /// type), how many hops, when, and how well it was heard; how many times, when grouped.
  private var compactContent: some View {
    let kind = SpectrumPacketKind(entry.payloadType)
    return HStack(spacing: 6) {
      Capsule()
        .fill(TrafficLaserTiming.color(for: kind).gradient)
        .frame(width: 4, height: 18)
        .accessibilityLabel(kind.title)
      if let sender {
        Text(recipientName.map { "\(sender.name) → \($0)" } ?? sender.name)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .accessibilityLabel(senderAccessibilityLabel(sender))
      } else {
        Text(kind.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if !isTrace, entry.hopCount > 0 {
        Text("· \(entry.hopCount) \(entry.hopCount == 1 ? L10n.Tools.Tools.RxLog.hopSingular : L10n.Tools.Tools.RxLog.hopPlural)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
      }
      Spacer(minLength: 4)
      if groupCount > 1 {
        Text("×\(groupCount)")
          .font(.caption.bold())
          .foregroundStyle(.orange)
          .accessibilityLabel(L10n.Tools.Tools.RxLog.receivedTimes(groupCount))
      }
      Text(entry.receivedAt, format: .dateTime.hour().minute())
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .fixedSize()
      Image(systemName: "cellularbars", variableValue: entry.snr == nil ? 0 : entry.snrLevel)
        .foregroundStyle(entry.snr == nil ? Color.secondary.opacity(0.4) : entry.snrQuality.color)
        .accessibilityLabel(entry.snr == nil ? "" : L10n.Tools.Tools.RxLog.signalStrength(entry.snrQuality.localizedLabel))
    }
  }

  private var collapsedContent: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Line 1: who it's from (kind, name, how far and which way), the time, signal bars
      HStack(spacing: 6) {
        if let sender {
          Image(systemName: sender.kind?.iconSystemName ?? "dot.radiowaves.left.and.right")
            .font(.caption)
            .foregroundStyle(sender.kind?.displayColor ?? .secondary)
            .accessibilityHidden(true)
          Text(recipientName.map { "\(sender.name) → \($0)" } ?? sender.name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .accessibilityLabel(senderAccessibilityLabel(sender))
          if let distance = distanceText(sender.coordinate) {
            Text("· \(distance)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .layoutPriority(-1)
          }
        } else {
          Text(entry.payloadType.displayName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 4)

        if isRecovered {
          Image(systemName: "arrow.counterclockwise")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.Tools.Tools.RxLog.recovered)
        }

        Text(entry.receivedAt, format: .dateTime.hour().minute().second())
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)

        if entry.snr != nil {
          Image(systemName: "cellularbars", variableValue: entry.snrLevel)
            .foregroundStyle(entry.snrQuality.color)
            .accessibilityLabel(L10n.Tools.Tools.RxLog.signalStrength(entry.snrQuality.localizedLabel))
        }
      }

      // Line 2: flood or direct, then the route by name (hex where a hop isn't known), the hop count
      HStack(spacing: 4) {
        Text(entry.routeTypeSimple)
          .font(.caption.bold())
          .foregroundStyle(entry.isFlood ? .green : .blue)
        Text("· \(pathDisplayString)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityLabel(pathDisplay(spoken: true))
        if !isTrace, entry.hopCount > 0 {
          Text("(\(entry.hopCount) \(entry.hopCount == 1 ? L10n.Tools.Tools.RxLog.hopSingular : L10n.Tools.Tools.RxLog.hopPlural))")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize()
        }
      }

      // Line 3: the message (or the packet), SNR and RSSI, how many times it was heard
      HStack {
        if let text = previewText {
          Text("\"\(text)\"")
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
        } else {
          let versionSuffix = entry.payloadVersion > 0 ? " v\(entry.payloadVersion)" : ""
          Text("\(entry.payloadType.displayName)\(versionSuffix) · \(entry.rawPayload.count) \(L10n.Tools.Tools.RxLog.bytes)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if let signalText {
          Text(signalText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        if groupCount > 1 {
          Text("×\(groupCount)")
            .font(.caption.bold())
            .foregroundStyle(.orange)
            .accessibilityLabel(L10n.Tools.Tools.RxLog.receivedTimes(groupCount))
        }
      }

      // Line 4, when it applies: received on another channel, or on no confirmed channel
      if let channelCaption {
        Text(channelCaption)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Path Display

  private var isTrace: Bool {
    entry.payloadType == .trace
  }

  var pathDisplayString: String {
    pathDisplay(spoken: false)
  }

  /// `spoken` adds that a hop is a possible match where its name is a guess, for VoiceOver.
  private func pathDisplay(spoken: Bool) -> String {
    // A trace's route is in its payload, so one heard before any hop added an SNR still has one.
    if isTrace {
      let routeParts = traceRouteIdParts(spoken: spoken)
      if !routeParts.isEmpty {
        return truncatedJoin(routeParts, separator: " → ")
      }
      let count = entry.hopCount
      let hopLabel = count == 1 ? L10n.Tools.Tools.RxLog.hopSingular : L10n.Tools.Tools.RxLog.hopPlural
      return "\(count) \(hopLabel)"
    }

    if entry.pathNodes.isEmpty {
      return L10n.Tools.Tools.RxLog.direct
    }

    let hops = truncatedJoin(hopIdParts(spoken: spoken), separator: " → ")
    // A direct packet's path is the route still ahead: each repeater drops itself before passing it on.
    return entry.isFlood ? hops : L10n.Tools.Tools.RxLog.routeAhead(hops)
  }

  var pathDetailString: String {
    if entry.pathNodes.isEmpty {
      return L10n.Tools.Tools.RxLog.direct
    }
    let hopCount = entry.hopCount
    let hopLabel = hopCount == 1 ? L10n.Tools.Tools.RxLog.hopSingular : L10n.Tools.Tools.RxLog.hopPlural
    let detail = "\(hopCount) \(hopLabel) [\(hopIdParts().joined(separator: ", "))]"
    return entry.isFlood ? detail : L10n.Tools.Tools.RxLog.routeAhead(detail)
  }

  /// For TRACE packets: the repeaters it is sent through, by name where it has reached them, the
  /// rest by key prefix.
  private func traceRouteIdParts(spoken: Bool = false) -> [String] {
    guard isTrace else { return [] }
    return packet.hops.map { hopLabel($0, spoken: spoken) }
  }

  /// For non-TRACE packets: each hop by name ("You" for this radio, "Name?" for a guess among
  /// nodes sharing a short hash), by key prefix where no node has it.
  private func hopIdParts(spoken: Bool = false) -> [String] {
    guard !isTrace else { return [] }
    guard !packet.hops.isEmpty else {
      // A path its length byte doesn't describe can't be trusted hop by hop: its bytes, chunked.
      let hashSize = max(entry.pathHashSize, 1)
      return stride(from: 0, to: entry.pathNodes.count, by: hashSize).map { start in
        Data(entry.pathNodes[start..<min(start + hashSize, entry.pathNodes.count)]).uppercaseHexString()
      }
    }
    return packet.hops.map { hopLabel($0, spoken: spoken) }
  }

  private func hopLabel(_ node: PacketNode, spoken: Bool) -> String {
    let name = label(for: node) ?? node.hash.uppercaseHexString()
    if spoken, case let .unknown(hash) = node.match {
      return L10n.Tools.Tools.Traffic.Hop.unknown(hash.uppercaseHexString())
    }
    guard spoken, node.match?.isUncertain == true || node.isProbable else { return name }
    return "\(name), \(L10n.Chats.Chats.Path.Hop.possibleMatch)"
  }

  /// Join parts with separator, truncating to first 3 … last 3 if > 6 elements.
  private func truncatedJoin(_ parts: [String], separator: String) -> String {
    if parts.count > 6 {
      let first = parts.prefix(3).joined(separator: separator)
      let last = parts.suffix(3).joined(separator: separator)
      return "\(first) \(separator) … \(separator) \(last)"
    }
    return parts.joined(separator: separator)
  }

  /// A node as the list names it: "You" for this radio, otherwise the resolver's name for it.
  private func label(for node: PacketNode) -> String? {
    node.isRadio ? L10n.Tools.Tools.RxLog.pathYou : node.displayName
  }

  private func label(for match: PacketNodeMatch) -> String {
    label(for: PacketNode(role: .sender(.peerHash), hash: Data(), match: match)) ?? "?"
  }

  private func senderAccessibilityLabel(_ sender: Sender) -> String {
    let line = recipientName.map { "\(sender.name) → \($0)" } ?? sender.name
    return sender.isUncertain ? "\(line), \(L10n.Chats.Chats.Path.Hop.possibleMatch)" : line
  }

  // MARK: - Observed and Claimed

  /// What this radio observed of the packet and what it only claims: who transmitted the frame
  /// (and how this radio knows that node), the nodes sharing an unknown relay's prefix that it
  /// isn't taken for, an anonymous request's claimed key, an advert whose signature fails, a
  /// link far longer than LoRa usually reaches, and for our own packet what the radio answered
  /// and whether a repeater passed it on.
  @ViewBuilder
  private var observedDetail: some View {
    if let heardFromText {
      Text(heardFromText)
        .font(.caption)
      if let entry = packet.transmitterNode?.entry, let basis = TrafficNodeFormat.basis(of: entry, now: .now) {
        Text(basis)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
      Text(hint)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    if let claimedName {
      Label(L10n.Tools.Tools.Traffic.Hop.claimsToBe(claimedName), systemImage: "questionmark.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    if packet.sender?.isUnverified == true {
      Label(L10n.Tools.Tools.Traffic.Node.unverifiedAdvert, systemImage: "exclamationmark.shield")
        .font(.caption)
        .foregroundStyle(.orange)
    }
    if packet.transmitterNode?.isSuspicious == true || !packet.suspiciousLegs.isEmpty {
      Label(L10n.Tools.Tools.Traffic.Link.suspicious, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
    }
    if let echo {
      Text([
        L10n.Tools.Tools.Traffic.Sent.byRadio,
        TrafficTickerCard.sendTitle(TrafficFlight.Transmission(echo.send.outcome, route: echo.send.route)),
      ].joined(separator: " · "))
        .font(.caption)
      if echo.match.relation == .echo {
        Text(echo.match.confidence == .exact ? L10n.Tools.Tools.Traffic.Link.heardYou : L10n.Tools.Tools.Traffic.Echo.probable)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// "Unknown relay 7F · Not heard on this channel: Kona Hill shares this prefix", for each
  /// unknown node of the packet that a node not taken for it shares the prefix of.
  private var hints: [String] {
    let now = Date.now
    return ([packet.sender].compactMap(\.self) + packet.hops).compactMap { node in
      guard case let .unknown(hash) = node.match, let hint = node.unobservedHint else { return nil }
      return "\(L10n.Tools.Tools.Traffic.Hop.unknown(hash.uppercaseHexString())) · \(TrafficNodeFormat.hint(hint, now: now))"
    }
  }

  // MARK: - Packet Detail

  /// The packet as the sheet shows it, one card to a subject: who and what, the signal, the route
  /// hop by hop however long it is, what this radio observed, then the particulars and the bytes.
  private var packetDetail: some View {
    VStack(alignment: .leading, spacing: CardStyle.spacing) {
      detailHeader
      detailStats
      routeCard
      if hasObservedDetail {
        VStack(alignment: .leading, spacing: 6) {
          observedDetail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
      }
      // A message's card: who it was for and, where the app could read it, whether it is in the chats.
      RxMessageReachCard(entry: entry)
      particulars
      RawPayloadSection(payload: entry.rawPayload)
        .cardSurface()
    }
  }

  private var detailHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        SpectrumKindPill(kind: SpectrumPacketKind(entry.payloadType), showsName: true)
        Spacer(minLength: 4)
        Text(entry.receivedAt, format: .dateTime.hour().minute().second())
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if let sender {
        HStack(spacing: 8) {
          Image(systemName: sender.kind?.iconSystemName ?? "dot.radiowaves.left.and.right")
            .foregroundStyle(sender.kind?.displayColor ?? .secondary)
            .accessibilityHidden(true)
          Text(recipientName.map { "\(sender.name) → \($0)" } ?? sender.name)
            .font(.title3.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(senderAccessibilityLabel(sender))
        }
        if let distance = distanceText(sender.coordinate) {
          Text(distance)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      if let text = previewText {
        Text(text)
          .font(.body)
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
      }
      if let channelCaption {
        Text(channelCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface()
  }

  /// The numbers worth a glance, side by side.
  private var detailStats: some View {
    Grid(horizontalSpacing: CardStyle.spacing) {
      GridRow {
        detailStat(
          Self.bareLabel(L10n.Tools.Tools.RxLog.snrLabel),
          value: entry.snr.map { $0.formatted(.number.precision(.fractionLength(1))) + " dB" } ?? "—",
          tint: entry.snr == nil ? .secondary : entry.snrQuality.color
        )
        detailStat(Self.bareLabel(L10n.Tools.Tools.RxLog.rssiLabel), value: entry.rssi.map { "\($0) dBm" } ?? "—")
        detailStat(L10n.Tools.Tools.RxLog.hopPlural, value: entry.hopCount.formatted())
        if groupCount > 1 {
          detailStat("×", value: groupCount.formatted(), tint: .orange)
        } else {
          detailStat(Self.bareLabel(L10n.Tools.Tools.RxLog.sizeLabel), value: "\(entry.rawPayload.count)")
        }
      }
    }
  }

  private func detailStat(_ title: String, value: String, tint: Color = .primary) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text(value)
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(padding: 10)
    .accessibilityElement(children: .combine)
  }

  /// "SNR:" as a heading: the log's labels carry their own punctuation. Nonisolated: RxPacketShare
  /// formats packets off the main actor.
  nonisolated static func bareLabel(_ label: String) -> String {
    label.trimmingCharacters(in: CharacterSet(charactersIn: ":：").union(.whitespaces))
  }

  // MARK: Route

  /// What the card calls the route: a direct packet's is what's still ahead of it, a flood's only
  /// what the packet claims.
  private var routeTitle: String {
    if isTrace { return Self.bareLabel(L10n.Tools.Tools.RxLog.traceRouteLabel) }
    if !entry.isFlood, !entry.pathNodes.isEmpty {
      let count = routeStops.count
      return L10n.Tools.Tools.RxLog.routeAhead("\(count) \(count == 1 ? L10n.Tools.Tools.RxLog.hopSingular : L10n.Tools.Tools.RxLog.hopPlural)")
    }
    return entry.pathNodes.isEmpty ? Self.bareLabel(L10n.Tools.Tools.RxLog.pathLabel) : L10n.Tools.Tools.Traffic.Link.claimed
  }

  /// One stop on the card's route.
  struct RouteStop: Identifiable {
    let id: Int
    let name: String
    var hash: String?
    var systemImage = "dot.radiowaves.left.and.right"
    var tint: Color = .secondary
    /// How far and which way, when the stop has a position.
    var distance: String?
    /// The signal on this stop's link, when the packet says.
    var signal: String?
    /// A guess among nodes sharing a short hash.
    var isUncertain = false
    /// A leg far longer than LoRa usually reaches.
    var isSuspicious = false
    /// The node this radio heard the frame from: the one link it observed.
    var isHeardFrom = false
    /// A trace target the packet hasn't reached yet.
    var isAhead = false
  }

  private func routeStop(_ node: PacketNode, id: Int, signal: String? = nil) -> RouteStop {
    let kind = ContactType(rawValue: node.nodeTypeRaw)
    var isAhead = false
    if case let .hop(_, isReached) = node.role { isAhead = !isReached }
    let hash = node.hash.uppercaseHexString()
    let name = label(for: node) ?? L10n.Tools.Tools.Traffic.Hop.unknown(hash)
    return RouteStop(
      id: id,
      name: name,
      // Under a name only: a hop known by its hash alone already reads as that.
      hash: node.hash.isEmpty || name == hash ? nil : hash,
      systemImage: node.isRadio ? "person.fill" : (kind?.iconSystemName ?? "questionmark"),
      tint: node.isRadio ? .accentColor : (kind?.displayColor ?? .secondary),
      distance: node.isRadio ? nil : distanceText(node.coordinate),
      signal: signal,
      isUncertain: node.match?.isUncertain == true || node.isProbable,
      isHeardFrom: node.role == packet.transmitter,
      isAhead: isAhead
    )
  }

  /// The stops in order: only what the packet says. A flood runs from its sender through the relays
  /// it names to this radio; a direct packet lists the route still ahead; a trace, its targets
  /// with the signal each heard it at. The one observed link carries this radio's own reading.
  var routeStops: [RouteStop] {
    let received = entry.snr.map { "\(SpectrumPacketFormat.snr($0)) dB" }
    var stops: [RouteStop] = []
    let isFloodRoute = entry.isFlood && !isTrace
    if isFloodRoute, let sender = packet.sender {
      stops.append(routeStop(sender, id: 0, signal: sender.role == packet.transmitter ? received : nil))
    }
    if packet.hops.isEmpty {
      // A path its length byte doesn't describe can't be trusted hop by hop: its bytes, chunked.
      if !isTrace {
        for (index, part) in hopIdParts().enumerated() {
          stops.append(RouteStop(id: index + 1, name: part, systemImage: "questionmark"))
        }
      }
    } else {
      for (index, hop) in packet.hops.enumerated() {
        var signal: String?
        if isTrace, index < entry.pathNodes.count {
          signal = (Double(Int8(bitPattern: entry.pathNodes[index])) / 4).formatted(.number.precision(.fractionLength(1))) + " dB"
        } else if hop.role == packet.transmitter {
          signal = received
        }
        var stop = routeStop(hop, id: index + 1, signal: signal)
        stop.isSuspicious = packet.suspiciousLegs.contains(index)
        stops.append(stop)
      }
    }
    if isFloodRoute, packet.hops.last?.isRadio != true {
      stops.append(RouteStop(
        id: stops.count + 1_000,
        name: L10n.Tools.Tools.RxLog.pathYou,
        systemImage: "person.fill",
        tint: .accentColor
      ))
    }
    return stops
  }

  private var routeCard: some View {
    let stops = routeStops
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(routeTitle)
          .font(.subheadline.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 4)
        Text(entry.routeTypeSimple)
          .font(.caption.bold())
          .foregroundStyle(entry.isFlood ? .green : .blue)
      }
      if stops.isEmpty {
        Text(L10n.Tools.Tools.RxLog.direct)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(stops.indices, id: \.self) { index in
            RxRouteStopRow(stop: stops[index], isFirst: index == 0, isLast: index == stops.count - 1)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface()
  }

  private var hasObservedDetail: Bool {
    heardFromText != nil || !hints.isEmpty || claimedName != nil || packet.sender?.isUnverified == true
      || packet.transmitterNode?.isSuspicious == true || !packet.suspiciousLegs.isEmpty || echo != nil
  }

  // MARK: Particulars

  private var particulars: some View {
    VStack(alignment: .leading, spacing: 8) {
      DetailRow(label: L10n.Tools.Tools.RxLog.typeLabel, value: entry.payloadType.displayName)
      DetailRow(label: L10n.Tools.Tools.RxLog.sizeLabel, value: "\(entry.rawPayload.count) \(L10n.Tools.Tools.RxLog.bytes)")
      if let sender, let recipientName {
        DetailRow(label: L10n.Tools.Tools.RxLog.fromLabel, value: sender.name)
        DetailRow(label: L10n.Tools.Tools.RxLog.toLabel, value: recipientName)
      }

      // Channel message: show channel info
      if entry.decryptStatus == .success {
        if entry.channelIndex != nil, let channelHashByte = entry.packetPayload.first {
          DetailRow(label: L10n.Tools.Tools.RxLog.channelHashLabel, value: String(format: "%02x", channelHashByte))
        }
        if let channelName = entry.channelName {
          DetailRow(label: L10n.Tools.Tools.RxLog.channelNameLabel, value: channelName)
        }
        if let transportCode = entry.transportCode, !transportCode.isEmpty {
          let regionValue: String = switch RegionScopeSemantics.coalesce(
            scope: entry.regionScope,
            matches: entry.regionScopeMatches
          ) {
          case .none:
            L10n.Tools.Tools.RxLog.regionUnresolved
          case let .unique(name):
            name
          case let .ambiguous(names):
            ListFormatter.localizedString(byJoining: names)
          }
          DetailRow(
            label: L10n.Tools.Tools.RxLog.regionLabel,
            value: regionValue
          )
        }
      }

      if entry.payloadType == .textMessage || entry.payloadType == .groupText || entry.payloadType == .groupData {
        DetailRow(label: L10n.Tools.Tools.RxLog.decryptionLabel, value: entry.decryptStatus.localizedName)
      }
      if let senderTimestamp = entry.senderTimestamp, entry.decodedText != nil {
        DetailRow(
          label: L10n.Tools.Tools.RxLog.senderTimeLabel,
          value: Date(timeIntervalSince1970: TimeInterval(senderTimestamp))
            .formatted(date: .abbreviated, time: .standard)
        )
      }
      DetailRow(label: L10n.Tools.Tools.RxLog.hashLabel, value: entry.packetHash, truncate: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface()
  }
}

// MARK: - Route Stop Row

/// One stop on a packet's route: its tile on a line joining the stops, its name, and under that its
/// short id and where it is. The signal on its link sits at the right.
private struct RxRouteStopRow: View {
  let stop: RxLogRowView.RouteStop
  let isFirst: Bool
  let isLast: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      rail
      VStack(alignment: .leading, spacing: 1) {
        Text(stop.name)
          .font(.subheadline.weight(stop.isHeardFrom ? .bold : .medium))
          .foregroundStyle(stop.isAhead ? Color.secondary : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let line = detailLine {
          Text(line)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if stop.isUncertain {
          Text(L10n.Chats.Chats.Path.Hop.possibleMatch)
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 3)
      .padding(.bottom, isLast ? 0 : 12)
      Spacer(minLength: 4)
      if stop.isSuspicious {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .padding(.top, 5)
          .accessibilityLabel(L10n.Tools.Tools.Traffic.Link.suspicious)
      }
      if let signal = stop.signal {
        Text(signal)
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(stop.isHeardFrom ? Color.green : Color.secondary)
          .fixedSize()
          .padding(.top, 4)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var detailLine: String? {
    let parts = [stop.hash, stop.distance].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var rail: some View {
    VStack(spacing: 0) {
      Image(systemName: stop.systemImage)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(stop.isAhead ? Color.secondary : stop.tint)
        .frame(width: 26, height: 26)
        .background((stop.isAhead ? Color.secondary : stop.tint).opacity(0.16), in: Circle())
        .overlay {
          if stop.isHeardFrom {
            Circle().strokeBorder(Color.green, lineWidth: 1.5)
          }
        }
      if !isLast {
        Rectangle()
          .fill(Color.secondary.opacity(0.35))
          .frame(width: 2)
          .frame(maxHeight: .infinity)
      }
    }
    .frame(width: 26)
    .accessibilityHidden(true)
  }
}

// MARK: - Packet Sheet

/// One packet's details in a sheet, from the traffic list, Scan for Nodes and the Spectrum tab.
struct RxPacketDetailSheet: View {
  let entry: RxLogEntryDTO
  let groupCount: Int
  let nodeIndex: PacketNodeIndex
  let packet: PacketNodes
  let origin: CLLocation?
  let currentChannelKey: ChannelKey?
  let echo: (send: OwnTransmission, match: EchoMatch)?
  /// What the ⋯ menu can do with the packet beyond sharing it; the share and copy items are
  /// always there.
  var actions = RxPacketActionHandlers()

  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        RxLogRowView(
          entry: entry,
          groupCount: groupCount,
          nodeIndex: nodeIndex,
          packet: packet,
          origin: origin,
          showsDetailOnly: true,
          currentChannelKey: currentChannelKey,
          echo: echo
        )
        .padding(CardStyle.pageInset)
      }
      .cardCanvas(theme)
      .flashingNavigationTitle(L10n.Tools.Tools.Spectrum.Detail.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            RxPacketActionsMenu(entry: entry, packet: packet, handlers: actions)
          } label: {
            Label(L10n.Tools.Tools.RxLog.actions, systemImage: "ellipsis.circle")
          }
          .accessibilityIdentifier("rxLog.detail.actions")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) { dismiss() }
        }
      }
    }
    // A long route opens at full height, where its hops are in view without a drag.
    .presentationDetents(entry.hopCount > 3 ? [.large] : [.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

// MARK: - Detail Row

/// A label and its value, the value at the right and wrapping rather than cutting off.
private struct DetailRow: View {
  let label: String
  let value: String
  var truncate: Bool = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(RxLogRowView.bareLabel(label))
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .font(.subheadline.monospacedDigit())
        .multilineTextAlignment(.trailing)
        .lineLimit(truncate ? 1 : nil)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Raw Payload Section

private struct RawPayloadSection: View {
  let payload: Data

  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(L10n.Tools.Tools.RxLog.rawPayload)
          .font(.caption.bold())
          .foregroundStyle(.secondary)

        Spacer()

        Button(action: copyToClipboard) {
          Label(L10n.Tools.Tools.RxLog.copy, systemImage: copied ? "checkmark" : "doc.on.doc")
            .contentShape(MinimumHitShape())
        }
        .font(.caption)
        .foregroundStyle(copied ? .green : .secondary)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: copied) { _, newValue in newValue }
      }

      Text(hexString)
        .font(.caption2.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var hexString: String {
    payload.map { String(format: "%02X", $0) }.joined(separator: " ")
  }

  private func copyToClipboard() {
    UIPasteboard.general.string = hexString
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
  }
}

// MARK: - Glass Effect Modifiers

private struct GlassEffectModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect()
    } else {
      content.background(.ultraThinMaterial, in: .capsule)
    }
  }
}

private struct GlassContainerModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer { content }
    } else {
      content
    }
  }
}

// MARK: - Pulse Animation

private struct PulseAnimationModifier: ViewModifier {
  let isActive: Bool

  @State private var isPulsing = false

  func body(content: Content) -> some View {
    content
      .opacity(isActive && isPulsing ? 0.4 : 1.0)
      .animation(
        isActive ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
        value: isPulsing
      )
      .onAppear {
        if isActive {
          isPulsing = true
        }
      }
      .onChange(of: isActive) { _, newValue in
        isPulsing = newValue
      }
  }
}

#Preview {
  NavigationStack {
    RxLogView()
  }
  .environment(\.appState, AppState())
}

/// Asks before the log is deleted, wherever the menu with Delete Logs sits.
struct DeleteLogsConfirmation: ViewModifier {
  @Binding var isPresented: Bool
  let delete: () -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(L10n.Tools.Tools.RxLog.deleteConfirmation, isPresented: $isPresented, titleVisibility: .visible) {
      Button(L10n.Tools.Tools.RxLog.delete, role: .destructive) {
        delete()
      }
    }
  }
}
