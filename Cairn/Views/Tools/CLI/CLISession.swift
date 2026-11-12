import CairnServices
import Foundation

struct CLISession: Identifiable, Hashable {
  let id: UUID
  let name: String
  let isLocal: Bool
  let pathLength: UInt8
  /// Another companion's key when the session is its command line (MeshCore 1.18): commands go
  /// straight to it with no login, and it runs them only if its contact for this radio allows it.
  var companionPublicKey: Data?

  /// Whether commands go to another companion rather than a logged-in repeater or room.
  var isCompanion: Bool { companionPublicKey != nil }

  static func local(deviceName: String) -> CLISession {
    CLISession(id: UUID(), name: deviceName, isLocal: true, pathLength: 0)
  }

  static func remote(id: UUID, name: String, pathLength: UInt8) -> CLISession {
    CLISession(id: id, name: name, isLocal: false, pathLength: pathLength)
  }

  /// A companion's command line, keyed by its contact so opening it twice finds the same session.
  static func companion(contact: ContactDTO) -> CLISession {
    CLISession(
      id: contact.id,
      name: contact.name,
      isLocal: false,
      pathLength: contact.outPathLength,
      companionPublicKey: contact.publicKey
    )
  }
}
