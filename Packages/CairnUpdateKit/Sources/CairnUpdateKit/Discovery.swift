import Foundation
import Network

/// A board found on the network while in updater mode. Updater mode advertises `_arduino._tcp` (the espota
/// service) under the board's Wi-Fi hostname; the web updater listens on port 80 at the same address.
public struct FoundBoard: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String          // the Bonjour instance name (the board's hostname)
    public var address: String?      // IPv4, once resolved
}

/// Browses for boards in updater mode and resolves each to an IPv4 address.
/// iOS needs NSLocalNetworkUsageDescription and `_arduino._tcp` in NSBonjourServices.
@MainActor
public final class BoardBrowser: ObservableObject {
    @Published public private(set) var boards: [FoundBoard] = []
    @Published public private(set) var browsing = false
    @Published public private(set) var problem: String?

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    public init() { }

    public func start() {
        stop()
        problem = nil
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_arduino._tcp", domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.browsing = true
                    self.problem = nil
                case .failed(let e):
                    self.browsing = false
                    self.problem = "Can't look for boards: \(e.localizedDescription)"
                case .waiting(let e):
                    self.problem = "Waiting for the local network: \(e.localizedDescription). On iPhone, allow Local Network for this app in Settings."
                case .cancelled: self.browsing = false
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        browsing = false
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var names: [String] = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            names.append(name)
            if !boards.contains(where: { $0.name == name }) {
                boards.append(FoundBoard(name: name, address: nil))
            }
            if boards.first(where: { $0.name == name })?.address == nil && resolvers[name] == nil {
                resolve(name: name, endpoint: r.endpoint)
            }
        }
        boards.removeAll { !names.contains($0.name) }
        for (n, c) in resolvers where !names.contains(n) { c.cancel(); resolvers[n] = nil }
        boards.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Resolves the service to its IPv4 address with a UDP "connection" (nothing is sent: UDP is ready as
    /// soon as the name resolves). Not TCP: the advertised port is espota's, which listens on UDP only.
    private func resolve(name: String, endpoint: NWEndpoint) {
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolvers[name] = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = c.currentPath?.remoteEndpoint {
                        var s = "\(host)"
                        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }   // an interface suffix
                        if let i = self.boards.firstIndex(where: { $0.name == name }) { self.boards[i].address = s }
                    }
                    c.cancel()
                    self.resolvers[name] = nil
                case .waiting, .failed:
                    // give up for now; the next browse update tries again
                    c.cancel()
                    self.resolvers[name] = nil
                case .cancelled:
                    if self.resolvers[name] === c { self.resolvers[name] = nil }
                default: break
                }
            }
        }
        c.start(queue: .main)
    }
}
