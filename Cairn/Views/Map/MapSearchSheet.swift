import CoreLocation
import CairnServices
import SwiftUI

/// Finds a node on the map by name or ID: every contact and heard node with a position, whether
/// or not the filter shows it (one it doesn't gets a dropped pin where it is). Picking one
/// selects its pin, as a tap would.
struct MapSearchSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let viewModel: MapViewModel
  let onSelect: (_ publicKey: Data, _ coordinate: CLLocationCoordinate2D) -> Void

  @State private var searchText = ""

  /// One searchable node: a contact or a heard node, by key.
  nonisolated struct Entry: Identifiable, Equatable, Sendable {
    let publicKey: Data
    let name: String
    let type: ContactType
    let coordinate: CLLocationCoordinate2D
    let isDiscovered: Bool

    nonisolated var id: Data { publicKey }

    nonisolated static func == (lhs: Entry, rhs: Entry) -> Bool {
      lhs.publicKey == rhs.publicKey
    }
  }

  /// The located nodes, contacts first, each key once.
  nonisolated static func entries(contacts: [ContactDTO], discovered: [DiscoveredNodeDTO]) -> [Entry] {
    var seen: Set<Data> = []
    var entries: [Entry] = contacts.compactMap { contact in
      guard seen.insert(contact.publicKey).inserted else { return nil }
      return Entry(
        publicKey: contact.publicKey,
        name: contact.displayName,
        type: contact.type,
        coordinate: contact.coordinate,
        isDiscovered: false
      )
    }
    entries += discovered.compactMap { node in
      guard seen.insert(node.publicKey).inserted else { return nil }
      return Entry(publicKey: node.publicKey, name: node.name, type: node.nodeType, coordinate: node.coordinate, isDiscovered: true)
    }
    return entries
  }

  /// The entries matching `query` (a name fragment or a hex ID prefix), nearest first when the
  /// phone or the radio has a position, by name otherwise.
  nonisolated static func matches(_ entries: [Entry], query: String, origin: CLLocation?) -> [Entry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matched = entries.filter { entry in
      guard !trimmed.isEmpty else { return true }
      if entry.name.localizedCaseInsensitiveContains(trimmed) { return true }
      let hex = entry.publicKey.uppercaseHexString()
      return hex.hasPrefix(trimmed.uppercased())
    }
    if let origin {
      return matched.sorted { lhs, rhs in
        distance(from: origin, to: lhs) < distance(from: origin, to: rhs)
      }
    }
    return matched.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  nonisolated private static func distance(from origin: CLLocation, to entry: Entry) -> CLLocationDistance {
    origin.distance(from: CLLocation(latitude: entry.coordinate.latitude, longitude: entry.coordinate.longitude))
  }

  private var origin: CLLocation? {
    appState.bestAvailableLocation
  }

  private var results: [Entry] {
    Self.matches(
      Self.entries(contacts: viewModel.allLocatedContacts, discovered: viewModel.allLocatedDiscovered),
      query: searchText,
      origin: origin
    )
  }

  var body: some View {
    NavigationStack {
      Group {
        let results = results
        if results.isEmpty {
          ContentUnavailableView(
            L10n.Map.Map.Search.empty,
            systemImage: "magnifyingglass"
          )
        } else {
          List(results) { entry in
            Button {
              onSelect(entry.publicKey, entry.coordinate)
              dismiss()
            } label: {
              row(entry)
            }
            .buttonStyle(.plain)
            .cardListRow(theme)
          }
          .cardListCanvas(theme)
        }
      }
      .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.Map.Map.Search.prompt)
      .flashingNavigationTitle(L10n.Map.Map.Search.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private func row(_ entry: Entry) -> some View {
    HStack(spacing: 12) {
      Image(systemName: entry.type.iconSystemName)
        .foregroundStyle(entry.type.displayColor)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(entry.name)
            .font(.body)
            .foregroundStyle(.primary)
          if entry.isDiscovered {
            NodeKindBadge(text: L10n.Map.Map.Callout.discovered, color: .blue)
          }
        }
        Text(detail(entry))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  /// "2.3 km away · 47° NE · A1B2": where it is from here, and its short ID.
  private func detail(_ entry: Entry) -> String {
    let hashSize = appState.connectedDevice?.hashSize ?? 1
    let shortID = entry.publicKey.prefix(max(1, hashSize)).uppercaseHexString()
    guard let origin,
          let distance = NodeRouteFormat.distanceAway(
            from: origin,
            latitude: entry.coordinate.latitude,
            longitude: entry.coordinate.longitude
          ) else { return shortID }
    let bearing = GPSFormat.bearing(from: origin.coordinate, to: entry.coordinate)
    return NodeRouteFormat.joined([distance, GPSFormat.bearingText(bearing), shortID])
  }
}
