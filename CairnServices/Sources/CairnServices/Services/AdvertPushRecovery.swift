import Foundation
import MeshCore

/// Recovers an advert push (0x80) the radio dropped, from the advert's RX log copy (0x88).
///
/// For a node the radio holds as a contact, official companion firmware answers a new advert by
/// updating the contact and pushing `PUSH_CODE_ADVERT` (0x80, the key alone), which is what
/// moves the node's heard time and starts the contact delta round. It writes the packet's RX log
/// copy first, before it even parses it, and both frames go through the same Bluetooth send queue
/// that drops a frame when it is full (companion-v1.18.0 src/Dispatcher.cpp checkRecv,
/// src/helpers/BaseChatMesh.cpp onAdvertRecv, examples/companion_radio/MyMesh.cpp
/// onDiscoveredContact). So the 0x88 often survives a burst that loses the 0x80, and a lost 0x80
/// leaves Contacts and Home showing the node as heard long ago.
///
/// An advert copy starts a check only when the radio itself would have pushed a 0x80 for it:
/// - the copy is a whole advert, `public_key(32) | timestamp(4) | signature(64) | app_data`
///   (src/Mesh.cpp onRecvPacket refuses a shorter one);
/// - it is not this radio's own advert;
/// - the node is a stored contact (the radio pushes 0x8A or nothing for any other node);
/// - its timestamp is newer than the stored contact's and than any copy already settled (the
///   radio ignores an older or equal one as a replay, and repeat copies of one advert are seen);
/// - no real 0x80 for the node arrived within ``duplicateWindow`` before it. The radio handles
///   only the first copy of an advert it hears (src/Mesh.cpp onRecvPacket `hasSeen`, by a hash
///   that leaves out the path); later copies reach the app as 0x88 alone. A 0x80 can arrive with
///   no copy before it (the first copy's 0x88 was dropped from the full queue or was too long to
///   forward, or a Cairn radio held it for RX_SYNC), and the copy that follows it then belongs to
///   an advert already handled. A node's genuinely new advert inside that window is rare (nodes
///   advertise hours apart), and its delta round still reads it if another push comes;
/// - its Ed25519 signature over `public_key | timestamp | app_data` holds (src/Mesh.cpp
///   createAdvert and onRecvPacket, app data read as at most 32 bytes);
/// - its app data carries a name (BaseChatMesh drops a nameless advert).
///
/// The check waits ``grace`` for the real 0x80, which follows its 0x88 within milliseconds when
/// both get through. A real push settles the check; when the grace ends without one, the advert
/// is recovered once, and a real 0x80 that turns up within ``duplicateWindow`` afterwards is the
/// same advert's, late: it is not announced again, but the radio has only now updated the
/// contact, so the caller still reads the radio's record. Pure: the caller supplies the time and
/// runs the grace timer.
struct AdvertPushRecovery: Sendable {
  /// How long a check waits for the real 0x80.
  static let grace: Duration = .seconds(3)
  /// How long after a recovery a real 0x80 for the key is taken as the same advert's, late. It
  /// covers a user-set `rx_delay_base`, which delays flood processing (and so the 0x80, but not
  /// the 0x88) by up to 32 s (src/Dispatcher.cpp MAX_RX_DELAY_MILLIS).
  static let duplicateWindow: TimeInterval = 40

  /// What a real 0x80 means for the checks.
  enum PushDisposition: Sendable, Equatable {
    /// It answers a pending check: the push got through and the check is settled.
    case answeredCheck
    /// The advert it reports was already recovered from its copy; announcing it again would
    /// count the node twice.
    case duplicateOfRecovery
    /// No check knows the key.
    case unrelated
  }

  /// The newest advert timestamp each key's pending check waits for a 0x80 for.
  private var pending: [Data: UInt32] = [:]
  /// The newest advert timestamp settled per key, by a real push or a recovery.
  private var settled: [Data: UInt32] = [:]
  /// When each key's advert was last recovered.
  private var recoveredAt: [Data: Date] = [:]
  /// When a real 0x80 no check knew last arrived for each key: copies of that advert may follow.
  private var pushedAt: [Data: Date] = [:]

  /// Whether an advert copy with `timestamp` heard at `now` is newer than anything settled or
  /// pending for `key`, and follows no recent real push: a cheap test before the store read and
  /// the signature check.
  func needsCheck(key: Data, timestamp: UInt32, now: Date) -> Bool {
    timestamp > max(settled[key] ?? 0, pending[key] ?? 0) && !followsPush(key: key, now: now)
  }

  /// Starts a check for a verified advert copy of a stored contact.
  ///
  /// - Parameters:
  ///   - key: The advertiser's public key.
  ///   - timestamp: The advert's timestamp.
  ///   - storedTimestamp: The stored contact's `lastAdvertTimestamp`.
  ///   - now: When the copy arrived.
  /// - Returns: `true` when a new grace period must start; `false` when the advert is not newer,
  ///   a real push for the key came within ``duplicateWindow``, or a check for the key is already
  ///   waiting (it now waits for this newer advert).
  mutating func beginCheck(key: Data, timestamp: UInt32, storedTimestamp: UInt32, now: Date) -> Bool {
    guard timestamp > max(storedTimestamp, settled[key] ?? 0), !followsPush(key: key, now: now) else { return false }
    if let current = pending[key] {
      pending[key] = max(current, timestamp)
      return false
    }
    pending[key] = timestamp
    return true
  }

  /// Notes a real 0x80 for `key` at `now`.
  mutating func notePush(key: Data, now: Date) -> PushDisposition {
    if answerCheck(key: key) {
      return .answeredCheck
    }
    if let at = recoveredAt.removeValue(forKey: key), now.timeIntervalSince(at) < Self.duplicateWindow {
      return .duplicateOfRecovery
    }
    // The radio handled this advert from a copy the app never saw: the copies still to come
    // are of an advert already handled
    pushedAt = pushedAt.filter { now.timeIntervalSince($0.value) < Self.duplicateWindow }
    pushedAt[key] = now
    return .unrelated
  }

  /// Whether a real push no check knew came for `key` within ``duplicateWindow`` before `now`.
  private func followsPush(key: Data, now: Date) -> Bool {
    guard let at = pushedAt[key] else { return false }
    return now.timeIntervalSince(at) < Self.duplicateWindow
  }

  /// Settles `key`'s pending check because the radio pushed something for the advert itself (a
  /// 0x80, or a 0x8A when it no longer holds the contact).
  ///
  /// - Returns: `true` when a check was pending; its grace timer can stop.
  mutating func answerCheck(key: Data) -> Bool {
    guard let timestamp = pending.removeValue(forKey: key) else { return false }
    settle(key: key, timestamp: timestamp)
    return true
  }

  /// Ends `key`'s grace period at `now`.
  ///
  /// - Returns: `true` when no real push came, so the advert must be handled from its copy.
  mutating func graceEnded(key: Data, now: Date) -> Bool {
    guard let timestamp = pending.removeValue(forKey: key) else { return false }
    settle(key: key, timestamp: timestamp)
    recoveredAt = recoveredAt.filter { now.timeIntervalSince($0.value) < Self.duplicateWindow }
    recoveredAt[key] = now
    return true
  }

  private mutating func settle(key: Data, timestamp: UInt32) {
    settled[key] = max(settled[key] ?? 0, timestamp)
  }
}

// MARK: - Signed Advert

extension AdvertPushRecovery {
  /// An advert packet's payload as the radio reads it (src/Mesh.cpp onRecvPacket).
  struct SignedAdvert: Sendable, Equatable {
    static let publicKeySize = 32
    static let signatureSize = 64
    /// public_key(32) + timestamp(4) + signature(64): the shortest payload the radio accepts.
    static let appDataOffset = publicKeySize + 4 + signatureSize
    /// MAX_ADVERT_DATA_SIZE: the radio signs and reads at most this much app data.
    static let maxAppDataSize = 32

    let publicKey: Data
    /// The advertiser's clock when it sent the advert.
    let timestamp: UInt32
    let signature: Data
    /// The app data the radio reads and the signature covers: at most 32 bytes.
    let appData: Data

    /// Reads an advert payload; nil when it is shorter than the radio accepts.
    init?(payload: Data) {
      let bytes = [UInt8](payload)
      guard bytes.count >= Self.appDataOffset else { return nil }
      publicKey = Data(bytes[0..<Self.publicKeySize])
      timestamp = UInt32(bytes[32]) | UInt32(bytes[33]) << 8 | UInt32(bytes[34]) << 16 | UInt32(bytes[35]) << 24
      signature = Data(bytes[36..<Self.appDataOffset])
      appData = Data(bytes[Self.appDataOffset...].prefix(Self.maxAppDataSize))
    }

    /// Whether the app data is valid and carries a name, as AdvertDataParser reads it: a flags
    /// byte, the position (8 bytes) if 0x10, a feature word each for 0x20 and 0x40, then the
    /// name to the end if 0x80. The radio drops an advert without one (src/helpers/
    /// AdvertDataHelpers.cpp, BaseChatMesh.cpp onAdvertRecv `parser.hasName()`).
    var hasName: Bool {
      let bytes = [UInt8](appData)
      guard let flags = bytes.first else { return false }
      var nameStart = 1
      if flags & 0x10 != 0 { nameStart += 8 }
      if flags & 0x20 != 0 { nameStart += 2 }
      if flags & 0x40 != 0 { nameStart += 2 }
      return flags & 0x80 != 0 && bytes.count > nameStart && bytes[nameStart] != 0
    }

    /// Whether the signature over `public_key | timestamp | app_data` holds for the key.
    var isSignatureValid: Bool {
      var message = publicKey
      withUnsafeBytes(of: timestamp.littleEndian) { message.append(contentsOf: $0) }
      message.append(appData)
      return SignatureService.verify(message: message, signature: signature, publicKey: publicKey)
    }
  }
}
