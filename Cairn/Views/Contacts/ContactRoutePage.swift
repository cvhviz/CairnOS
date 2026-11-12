import CairnServices
import SwiftUI
import UIKit

/// How a node's out-path reads in one line: "Flood", "Direct", or "2 hops via Hilltop → Bridge".
enum ContactRouteSummary {
  /// Each hop's repeater name, or its hash in hex when no known node matches it.
  static func hopNames(for contact: ContactDTO, resolve: (Data) -> String?) -> [String] {
    contact.pathHops.map { resolve($0.data) ?? $0.hex }
  }

  static func text(isFloodRouted: Bool, pathHopCount: Int, hopNames: [String]) -> String {
    if isFloodRouted {
      L10n.Contacts.Contacts.Route.flood
    } else if pathHopCount == 0 || hopNames.isEmpty {
      L10n.Contacts.Contacts.Route.direct
    } else {
      L10n.Contacts.Contacts.Route.via(
        NodeRouteFormat.hopCount(pathHopCount),
        hopNames.joined(separator: " \u{2192} ")
      )
    }
  }
}

/// A node's out-path and the tools that change it: each hop by name, then Discover, Edit and
/// Reset. Path discovery replies are only listened for while this page is open, and leaving it
/// cancels a discovery still running.
struct ContactRoutePage: View {
  @Environment(\.appState) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var contact: ContactDTO
  @Bindable var pathViewModel: PathManagementViewModel

  @State private var showingResetConfirmation = false
  /// The last discovery's result, shown on the route card until dismissed or a new discovery.
  @State private var inlineDiscoveryResult: PathDiscoveryResult?

  private var isRoutePopulated: Bool {
    !contact.isFloodRouted && contact.pathHopCount > 0
  }

  /// A stored route with hops to trace, or a repeater to trace straight to.
  private var canTraceRoute: Bool {
    !contact.isFloodRouted && (contact.pathHopCount > 0 || contact.type == .repeater)
  }

  private var routeInfo: String {
    contact.isFloodRouted ? L10n.Contacts.Contacts.Detail.floodFooter : L10n.Contacts.Contacts.Detail.pathFooter
  }

  var body: some View {
    CardForm {
      CardFormSection(L10n.Contacts.Contacts.Detail.outboundPath, info: routeInfo) {
        ContentCard {
          routeRows
          // The discovery's result, under the route it found (or didn't), rather than an alert.
          if let result = inlineDiscoveryResult {
            Divider()
            discoveryResultRow(result)
          }
        }
      }

      CardFormSection {
        discoverCard

        // The stored route, through the node itself when it passes traces on (a repeater).
        if canTraceRoute {
          ActionCard(
            L10n.Contacts.Contacts.Detail.traceRoute,
            systemImage: "point.3.connected.trianglepath.dotted",
            color: .teal
          ) {
            let hops = contact.pathHops.map(\.data) + (contact.type == .repeater ? [contact.publicKey] : [])
            appState.navigation.navigateToTraceRoute(hops)
          }
          .radioDisabled(for: appState.connectionState)
        }

        ActionCard(L10n.Contacts.Contacts.Detail.editPath, systemImage: "pencil", color: .blue) {
          Task {
            await pathViewModel.loadContacts(radioID: contact.radioID)
            pathViewModel.initializeEditablePath(from: contact)
            pathViewModel.showingPathEditor = true
          }
        }
        .radioDisabled(for: appState.connectionState)

        // Disabled when already flood: there's no stored path to reset. A stored route with hops
        // asks first: it took a discovery or a hand edit to get.
        ActionCard(
          L10n.Contacts.Contacts.Detail.resetPath,
          systemImage: "arrow.triangle.2.circlepath",
          role: .destructive
        ) {
          if contact.pathHopCount > 0 {
            showingResetConfirmation = true
          } else {
            Task { await pathViewModel.resetPath(for: contact) }
          }
        }
        .confirmationDialog(
          L10n.Contacts.Contacts.Detail.ResetPath.confirmTitle,
          isPresented: $showingResetConfirmation,
          titleVisibility: .visible
        ) {
          Button(L10n.Contacts.Contacts.Detail.resetPath, role: .destructive) {
            Task { await pathViewModel.resetPath(for: contact) }
          }
        } message: {
          Text(L10n.Contacts.Contacts.Detail.ResetPath.confirmMessage(contact.displayName))
        }
        .overlay(alignment: .trailing) {
          if pathViewModel.isSettingPath {
            ProgressView()
              .controlSize(.small)
              .padding(.trailing, 12)
          }
        }
        .radioDisabled(for: appState.connectionState, or: pathViewModel.isSettingPath || contact.isFloodRouted)
      }
    }
    .flashingNavigationTitle(L10n.Contacts.Contacts.Detail.route)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(
      isPresented: $pathViewModel.showingPathEditor,
      onDismiss: { pathViewModel.insertionIntent = nil }
    ) {
      PathEditingSheet(viewModel: pathViewModel, contact: contact)
    }
    .alert(
      L10n.Contacts.Contacts.Detail.Alert.pathError,
      isPresented: Binding(
        get: { pathViewModel.errorMessage != nil },
        set: { if !$0 { pathViewModel.errorMessage = nil } }
      )
    ) {
      Button(L10n.Contacts.Contacts.Common.ok, role: .cancel) {}
    } message: {
      Text(pathViewModel.errorMessage ?? L10n.Contacts.Contacts.Common.errorOccurred)
    }
    // The result lands on the route card above instead of an alert; the flag is taken down here
    // so the node's page doesn't raise its alert once this page closes.
    .onChange(of: pathViewModel.showDiscoveryResult) { _, isShown in
      guard isShown else { return }
      pathViewModel.showDiscoveryResult = false
      withAnimation(reduceMotion ? nil : .snappy) {
        inlineDiscoveryResult = pathViewModel.discoveryResult
      }
    }
    .onChange(of: pathViewModel.isDiscovering) { _, isDiscovering in
      if isDiscovering { inlineDiscoveryResult = nil }
    }
    .task {
      // Path discovery replies arrive as pushes. The view-scoped task cancels the subscription
      // when the page closes; the stream is multicast, so a second detail column (iPad split
      // view) can subscribe concurrently.
      guard let advertisementService = appState.services?.advertisementService else { return }
      for await event in advertisementService.events() {
        // Only a response or path push for this contact may resolve this page's discovery;
        // a straggler from a discovery started on another contact must not.
        await pathViewModel.handleAdvertisementEvent(event, for: contact)
      }
    }
    .onDisappear {
      // A sheet over this page doesn't count; only leaving it does.
      if !pathViewModel.showingPathEditor {
        pathViewModel.cancelDiscovery()
      }
    }
  }

  @ViewBuilder
  private var routeRows: some View {
    if contact.isFloodRouted {
      Label(L10n.Contacts.Contacts.Route.flood, systemImage: "dot.radiowaves.left.and.right")
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if contact.pathHopCount == 0 {
      Label(L10n.Contacts.Contacts.Route.direct, systemImage: "arrow.right")
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      let routeIDPrefixes = contact.pathNodesHex.joined(separator: ",")
      ForEach(Array(contact.pathHops.enumerated()), id: \.offset) { index, hop in
        let name = pathViewModel.resolveHashToName(hop.data)
        if index > 0 {
          Divider()
        }
        HStack {
          Text("\(index + 1)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 20)
          Text(name ?? hop.hex)
            .font(name == nil ? .body.monospaced() : .body)
          Spacer()
          if name != nil {
            Text(hop.hex)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .copyRouteContextMenu(route: routeIDPrefixes, enabled: isRoutePopulated)
        .accessibilityAction(named: L10n.Contacts.Contacts.Detail.copyRoute) {
          UIPasteboard.general.string = routeIDPrefixes
        }
      }
    }
  }

  /// What the discovery found, in the words the alert used, with a button to put it away.
  private func discoveryResultRow(_ result: PathDiscoveryResult) -> some View {
    let isFailure: Bool = switch result {
    case .success: false
    case .noPathFound, .failed: true
    }
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .foregroundStyle(isFailure ? Color.orange : Color.green)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.Contacts.Contacts.Detail.Alert.pathDiscovery)
            .font(.subheadline.weight(.semibold))
          Text(result.description)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Button {
          withAnimation(reduceMotion ? nil : .snappy) { inlineDiscoveryResult = nil }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Contacts.Contacts.Detail.PathDiscovery.dismiss)
      }
      // The reply's routes, each storable as the node's path: the way out it found, or the way
      // its reply came back, which can differ.
      if pathViewModel.canUseDiscoveredRoute || pathViewModel.canUseReturnRoute {
        HStack(spacing: 8) {
          if pathViewModel.canUseDiscoveredRoute {
            Button(L10n.Contacts.Contacts.PathDiscovery.useRoute) {
              Task { await pathViewModel.applyDiscoveredRoute(for: contact) }
            }
          }
          if pathViewModel.canUseReturnRoute {
            Button(L10n.Contacts.Contacts.PathDiscovery.useReturnRoute) {
              Task { await pathViewModel.applyReturnRoute(for: contact) }
            }
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .radioDisabled(for: appState.connectionState, or: pathViewModel.isSettingPath)
      }
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var discoverCard: some View {
    if pathViewModel.isDiscovering {
      HStack(spacing: 12) {
        IconTile(systemImage: "antenna.radiowaves.left.and.right", color: .orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.Contacts.Contacts.Detail.discoveringPath)
          if let remaining = pathViewModel.discoverySecondsRemaining, remaining > 0 {
            Text(L10n.Contacts.Contacts.Detail.secondsRemaining(remaining))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        ProgressView()
        Button(L10n.Contacts.Contacts.Common.cancel) {
          pathViewModel.cancelDiscovery()
        }
        .buttonStyle(.borderless)
      }
      .cardSurface(padding: 12)
      .accessibilityElement(children: .contain)
    } else {
      ActionCard(
        L10n.Contacts.Contacts.Detail.discoverPath,
        systemImage: "antenna.radiowaves.left.and.right",
        color: .orange
      ) {
        Task { await pathViewModel.discoverPath(for: contact) }
      }
      .radioDisabled(for: appState.connectionState)
    }
  }
}

private extension View {
  /// Gates the whole `contextMenu`, not the button inside it: an always-present
  /// menu with an empty body still triggers the press-and-hold lift with no items.
  @ViewBuilder
  func copyRouteContextMenu(route: String, enabled: Bool) -> some View {
    if enabled {
      contextMenu {
        Button {
          UIPasteboard.general.string = route
        } label: {
          Label(L10n.Contacts.Contacts.Detail.copyRoute, systemImage: "doc.on.doc")
        }
      }
    } else {
      self
    }
  }
}
