import Foundation
import CairnUpdateKit

// cairn-update <address> <password> [--file image.bin] [--check]
//   no --file: installs the latest Cairn release's update image for the board (after its SHA-256 check)
//   --check: connect and show the board and the latest release, send nothing
let args = Array(CommandLine.arguments.dropFirst())
func usage() -> Never {
    print("usage: cairn-update <address> <password> [--file image.bin] [--check] [--repo owner/name]")
    exit(2)
}
guard args.count >= 2 else { usage() }
let address = args[0]
guard let password = BoardPassword.normalize(args[1]) else {
    print("That isn't a board password: 12 letters and digits, as shown on the board's screen.")
    exit(2)
}
var file: String?
var checkOnly = false
var repo = "cvhviz/Cairn"
var i = 2
while i < args.count {
    switch args[i] {
    case "--file": i += 1; guard i < args.count else { usage() }; file = args[i]
    case "--check": checkOnly = true
    case "--repo": i += 1; guard i < args.count else { usage() }; repo = args[i]
    default: usage()
    }
    i += 1
}

final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func report(_ p: Double) {
        let pct = Int(p * 100)
        lock.lock(); defer { lock.unlock() }
        if pct / 10 != last / 10 { last = pct; print("  \(pct)%") }
    }
}

func run(address: String, password: String, file: String?, checkOnly: Bool, repo: String) async -> Int32 {
    do {
        let client = try DeviceClient(address: address)
        let info = try await client.connect(password: password)
        print("Board: \(info.board?.displayName ?? info.realm)  node: \(info.nodeName ?? "?")  build: \(info.buildName ?? "?")")
        let image: Data, name: String
        if let file {
            image = try Data(contentsOf: URL(fileURLWithPath: file))
            name = (file as NSString).lastPathComponent
        } else {
            guard let board = info.board else { print("Unknown board (\(info.realm)): use --file"); return 1 }
            let rel = try await Releases(repo: repo).latest(for: board)
            print("Latest release: \(rel.title) (\(rel.assetName), \(rel.size) bytes)")
            if checkOnly { return 0 }
            image = try await Releases(repo: repo).download(rel)
            print("Downloaded and checked (SHA-256 matches)")
            name = rel.assetName
        }
        if checkOnly { return 0 }
        let ticker = Ticker()
        try await client.install(image: image, fileName: name, password: password) { ticker.report($0) }
        print("Installed. The board restarts into it (on trial: it goes back by itself if it fails to start).")
        return 0
    } catch {
        print("Error: \(error.localizedDescription)")
        return 1
    }
}

let code = await run(address: address, password: password, file: file, checkOnly: checkOnly, repo: repo)
exit(code)
