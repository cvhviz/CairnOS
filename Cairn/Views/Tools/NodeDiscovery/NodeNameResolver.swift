import Foundation
import CairnServices
import MeshCore

/// A name found for a node that answered a discovery scan but matched no stored record.
struct ResolvedNodeName: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    /// The radio's own contact table had the node; no airtime used.
    case radioContact
    /// The node answered a name request over the air.
    case node
  }

  let publicKey: Data
  let name: String
  let source: Source
  /// Only a radio contact carries a type and position; a name request returns a name alone.
  var typeRawValue: UInt8?
  var latitude: Double = 0
  var longitude: Double = 0
}

/// Finds a name for a discovery responder that no stored contact or discovered node names.
///
/// A discovery reply carries a public key and signal readings, nothing else, so a repeater whose
/// advert this phone never received shows as "Unknown". Two places can still name it: the radio's
/// own contact table (a lookup over the link, no airtime), and the repeater itself, which answers
/// an anonymous owner request with its name.
struct NodeNameResolver: Sendable {
  struct Dependencies: Sendable {
    /// Throws when the radio could not be asked; `nil` means it holds no entry for the key.
    var radioContact: @Sendable (Data) async throws -> MeshContact?
    var requestName: @Sendable (Data) async throws -> NodeOwnerInfo
    /// Adds the placeholder contact an older radio needs before it sends a request to a key it
    /// does not hold, returning whether it did. `nil` when the radio (1.16+) makes its own.
    var addTemporaryContact: (@Sendable (Data) async throws -> Bool)?
    var removeTemporaryContact: @Sendable (Data) async throws -> Void
  }

  let dependencies: Dependencies

  /// - Parameter overTheAir: Whether to ask the node itself when the radio does not know it.
  /// - Returns: `nil` when neither source produced a name.
  func resolve(publicKey: Data, overTheAir: Bool) async -> ResolvedNodeName? {
    var radioEntry: MeshContact?
    var lookupFailed = false
    do {
      radioEntry = try await dependencies.radioContact(publicKey)
    } catch {
      lookupFailed = true
    }
    if let radioEntry, !radioEntry.advertisedName.isEmpty {
      return ResolvedNodeName(
        publicKey: publicKey,
        name: radioEntry.advertisedName,
        source: .radioContact,
        typeRawValue: radioEntry.typeRawValue,
        latitude: radioEntry.latitude,
        longitude: radioEntry.longitude
      )
    }
    guard overTheAir else { return nil }

    // Only a placeholder added here is removed afterwards. One a 1.16+ radio makes itself sits in
    // a reserved slot that it recycles; removing it shifts the radio's contact table and hides
    // its first real contact from sync. A nameless entry already on the radio is used as it is.
    var addedPlaceholder = false
    if let addTemporaryContact = dependencies.addTemporaryContact, radioEntry == nil {
      // Unless the radio said it holds no entry, a placeholder could overwrite a real contact.
      guard !lookupFailed else { return nil }
      do {
        addedPlaceholder = try await addTemporaryContact(publicKey)
      } catch {
        // The write may have reached the radio before the error arrived.
        await removePlaceholder(publicKey)
        return nil
      }
    }

    let info = try? await dependencies.requestName(publicKey)
    if addedPlaceholder {
      await removePlaceholder(publicKey)
    }
    guard let info else { return nil }
    return ResolvedNodeName(publicKey: publicKey, name: info.nodeName, source: .node)
  }

  /// Removes in a task of its own: stopping a scan cancels the request, and a cancelled task's
  /// radio commands are refused, which would leave the placeholder behind.
  private func removePlaceholder(_ publicKey: Data) async {
    let remove = dependencies.removeTemporaryContact
    await Task { try? await remove(publicKey) }.value
  }
}

extension NodeNameResolver.Dependencies {
  /// - Parameter radioAddsTemporaryContact: Whether the radio (firmware 1.16+) makes its own
  ///   placeholder contact for a request to a stranger. An older radio rejects the request unless
  ///   the key is already a contact, so one is added first and removed afterwards.
  static func live(session: MeshCoreSession, radioAddsTemporaryContact: Bool) -> Self {
    var addPlaceholder: (@Sendable (Data) async throws -> Bool)?
    if !radioAddsTemporaryContact {
      addPlaceholder = { @Sendable key in try await session.addTemporaryContact(publicKey: key) }
    }
    return Self(
      radioContact: { try await session.getContact(publicKey: $0) },
      requestName: { try await session.requestNodeName(fromNearby: $0) },
      addTemporaryContact: addPlaceholder,
      removeTemporaryContact: { _ = try await session.removeTemporaryContact(publicKey: $0) }
    )
  }

  #if DEBUG && targetEnvironment(simulator)
    /// Stand-in for UI tests, where the mock radio answers nothing: the first stranger of the
    /// simulated scan reports a name after a moment, the second stays silent.
    static let simulated = Self(
      radioContact: { _ in nil },
      requestName: { key in
        try await Task.sleep(for: .milliseconds(1200))
        guard key.first == 0xA7 else { throw MeshCoreError.timeout }
        return NodeOwnerInfo(nodeName: "Mt Diablo Summit", ownerInfo: "")
      },
      addTemporaryContact: nil,
      removeTemporaryContact: { _ in }
    )
  #endif
}
