import Foundation
import Network

/// A minimal HTTP/1.1 client on Network.framework, for the board's update server only.
///
/// Why not URLSession: after a 401 it sends the same request again, our own Digest header included,
/// so one wrong password would count twice (or more) against the board's ten tries. Here every request
/// goes out exactly once, one request per connection (the board answers `Connection: close`), and an
/// answer that arrives while the body is still going out (the board refusing an upload early) is read
/// and returned instead of surfacing as a broken pipe.
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]   // lowercased names
    var body: Data
    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum MiniHTTPError: Error {
    case cannotConnect(String)
    case timedOut
    case connectionLost(String)
    case badResponse
}

final class MiniHTTP: @unchecked Sendable {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port

    /// `authority`: "10.0.1.140", "board.local:8080", "[fe80::1]:80"
    init?(authority: String) {
        guard let u = URL(string: "http://\(authority)/"), let h = u.host, !h.isEmpty else { return nil }
        host = NWEndpoint.Host(h)
        guard let p = NWEndpoint.Port(rawValue: UInt16(u.port ?? 80)) else { return nil }
        port = p
    }

    func send(method: String, target: String, hostHeader: String, headers: [(String, String)] = [],
              body: Data? = nil, connectTimeout: TimeInterval = 8, idleTimeout: TimeInterval = 30,
              progress: (@Sendable (Double) -> Void)? = nil) async throws -> HTTPResponse {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: \(hostHeader)\r\nConnection: close\r\nUser-Agent: CairnUpdater\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        let exchange = Exchange(conn: NWConnection(host: host, port: port, using: .tcp),
                                head: Data(head.utf8), body: body ?? Data(),
                                connectTimeout: connectTimeout, idleTimeout: idleTimeout, progress: progress)
        return try await withTaskCancellationHandler {
            try await exchange.run()
        } onCancel: {
            exchange.cancel()
        }
    }
}

/// One request/response on its own connection. All state lives on `queue`.
private final class Exchange: @unchecked Sendable {
    let conn: NWConnection
    let queue = DispatchQueue(label: "cairn.minihttp")
    let head: Data
    let body: Data
    let connectTimeout: TimeInterval
    let idleTimeout: TimeInterval
    let progress: (@Sendable (Double) -> Void)?

    private var cont: CheckedContinuation<HTTPResponse, Error>?
    private var finished = false
    private var rx = Data()
    private var sentBody = 0
    private var sendDone = false
    private var lastActivity = Date()
    private var connected = false
    private var timer: DispatchSourceTimer?

    init(conn: NWConnection, head: Data, body: Data, connectTimeout: TimeInterval, idleTimeout: TimeInterval,
         progress: (@Sendable (Double) -> Void)?) {
        self.conn = conn
        self.head = head
        self.body = body
        self.connectTimeout = connectTimeout
        self.idleTimeout = idleTimeout
        self.progress = progress
    }

    func run() async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPResponse, Error>) in
            queue.async {
                if self.finished { return c.resume(throwing: CancellationError()) }   // cancelled before it began
                self.cont = c
                self.start()
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func start() {
        let started = Date()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.connected else { return }
                self.connected = true
                self.lastActivity = Date()
                self.receive()
                self.sendHead()
            case .waiting(let e):
                // no route / refused: waiting would retry forever; report it once the connect time is up
                if Date().timeIntervalSince(started) > self.connectTimeout {
                    self.finish(.failure(MiniHTTPError.cannotConnect(e.localizedDescription)))
                }
            case .failed(let e):
                self.finish(.failure(self.connected ? MiniHTTPError.connectionLost(e.localizedDescription)
                                                    : MiniHTTPError.cannotConnect(e.localizedDescription)))
            default: break
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.connected {
                if Date().timeIntervalSince(started) > self.connectTimeout { self.finish(.failure(MiniHTTPError.cannotConnect("timed out"))) }
            } else if Date().timeIntervalSince(self.lastActivity) > self.idleTimeout {
                self.finish(.failure(MiniHTTPError.timedOut))
            }
        }
        timer = t
        t.resume()
        conn.start(queue: queue)
    }

    private func sendHead() {
        conn.send(content: head, completion: .contentProcessed { [weak self] err in
            guard let self, !self.finished else { return }
            if let err { return self.sendFailed(err) }
            self.lastActivity = Date()
            self.sendNextChunk()
        })
    }

    private static let chunk = 16 * 1024

    private func sendNextChunk() {
        guard !finished else { return }
        if sentBody >= body.count {
            sendDone = true
            return
        }
        let end = min(sentBody + Self.chunk, body.count)
        let piece = body.subdata(in: sentBody..<end)
        conn.send(content: piece, completion: .contentProcessed { [weak self] err in
            guard let self, !self.finished else { return }
            if let err { return self.sendFailed(err) }
            self.sentBody = end
            self.lastActivity = Date()
            if !self.body.isEmpty { self.progress?(Double(end) / Double(self.body.count)) }
            self.sendNextChunk()
        })
    }

    /// The board may answer and close while the body is still going (a refused upload): if a whole
    /// answer is already here, that answer is the result, not the broken pipe.
    private func sendFailed(_ err: NWError) {
        if let r = parse(final: true) { return finish(.success(r)) }
        // give the answer a moment to arrive before calling it a dropped connection
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.finished else { return }
            if let r = self.parse(final: true) { self.finish(.success(r)) }
            else { self.finish(.failure(MiniHTTPError.connectionLost(err.localizedDescription))) }
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.rx.append(data)
                self.lastActivity = Date()
            }
            if let r = self.parse(final: isComplete) { return self.finish(.success(r)) }
            if isComplete {
                return self.finish(.failure(self.rx.isEmpty ? MiniHTTPError.connectionLost("closed without an answer")
                                                            : MiniHTTPError.badResponse))
            }
            if let err {
                if let r = self.parse(final: true) { return self.finish(.success(r)) }
                return self.finish(.failure(MiniHTTPError.connectionLost(err.localizedDescription)))
            }
            self.receive()
        }
    }

    /// A complete response in `rx`: by Content-Length, or (without one) once the server has closed.
    private func parse(final: Bool) -> HTTPResponse? {
        guard let sep = rx.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: rx[..<sep.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"), let status = Int(statusLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            let k = l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = headers[k].map { "\($0), \(v)" } ?? v
        }
        let bodyStart = sep.upperBound
        if let cl = headers["content-length"].flatMap({ Int($0) }) {
            guard rx.count - bodyStart >= cl else { return nil }
            return HTTPResponse(status: status, headers: headers, body: rx.subdata(in: bodyStart..<(bodyStart + cl)))
        }
        guard final else { return nil }
        return HTTPResponse(status: status, headers: headers, body: rx.subdata(in: bodyStart..<rx.count))
    }

    private func finish(_ r: Result<HTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        conn.stateUpdateHandler = nil
        conn.cancel()
        let c = cont
        cont = nil
        c?.resume(with: r)
    }
}
