import Foundation

public extension MeshCoreSession {
  // MARK: - Node Name Requests

  /// Asks a node in direct radio range for its name.
  ///
  /// A discovery response carries only a public key, so a node whose advert this radio has never
  /// heard has no name. This sends an anonymous owner request, zero-hop, and returns the name the
  /// node reports. Only nodes heard directly answer: the firmware ignores anonymous requests that
  /// arrive by flood, and limits each requester to a handful per few minutes.
  ///
  /// Radios on firmware 1.16+ accept this for a key that is not a contact by creating a temporary
  /// contact entry; older radios reject it with ``MeshCoreError/deviceError(code:)``, so call
  /// ``addTemporaryContact(publicKey:)`` first on those, and
  /// ``removeTemporaryContact(publicKey:)`` afterwards to take that entry back out. Leave the entry
  /// a 1.16+ radio makes alone: it recycles by itself (see ``removeTemporaryContact(publicKey:)``).
  ///
  /// - Parameters:
  ///   - publicKey: The node's full 32-byte public key.
  ///   - timeout: Longest time to wait for the reply.
  /// - Throws: ``MeshCoreError/timeout`` if the node does not answer in time,
  ///   ``MeshCoreError/deviceError(code:)`` if the radio rejects the request,
  ///   ``MeshCoreError/parseError(_:)`` if the reply is malformed.
  func requestNodeName(fromNearby publicKey: Data, timeout: Duration = .seconds(12)) async throws -> NodeOwnerInfo {
    try requireFullPublicKey(publicKey, operation: "requestNodeName")
    return try await withThrowingTaskGroup(of: NodeOwnerInfo.self) { group in
      group.addTask { [self] in
        try await requestResponseSerializer.withSerialization { [self] in
          try await performBinaryExchange(
            request: PacketBuilder.sendAnonReq(to: publicKey, type: .owner, pathLength: 0, path: Data()),
            to: publicKey,
            operation: "Node name"
          ) { payload, _ in
            try NodeNameParser.parse(payload)
          }
        }
      }
      group.addTask { [clock = self.clock] in
        try await clock.sleep(for: timeout)
        throw MeshCoreError.timeout
      }
      defer { group.cancelAll() }
      guard let info = try await group.next() else { throw MeshCoreError.timeout }
      return info
    }
  }

  /// Adds the placeholder contact a radio older than firmware 1.16 needs before it will send an
  /// anonymous request to a key: the same nameless, zero-hop, type 0 entry newer radios create by
  /// themselves.
  ///
  /// Writing a contact overwrites any entry the radio holds for the key, so this first looks the
  /// key up and adds nothing when an entry exists.
  ///
  /// - Returns: `true` if the placeholder was added, `false` if the radio already holds the key.
  @discardableResult
  func addTemporaryContact(publicKey: Data) async throws -> Bool {
    try requireFullPublicKey(publicKey, operation: "addTemporaryContact")
    guard try await getContact(publicKey: publicKey) == nil else { return false }
    let placeholder = MeshContact(
      id: publicKey.hexString,
      publicKey: publicKey,
      type: .chat,
      typeRawValue: 0,
      flags: [],
      outPathLength: 0,
      outPath: Data(),
      advertisedName: "",
      lastAdvertisement: Date(timeIntervalSince1970: 0),
      latitude: 0,
      longitude: 0,
      lastModified: Date(timeIntervalSince1970: 0)
    )
    try await sendSimpleCommand(PacketBuilder.updateContact(placeholder))
    return true
  }

  /// Removes a placeholder added with ``addTemporaryContact(publicKey:)``, and nothing else: an
  /// entry that has since become a real contact is left alone.
  ///
  /// Use it only on a radio older than firmware 1.16, where the placeholder sits in the ordinary
  /// contact table, shows up in contact sync and holds a slot. Never use it on a placeholder a
  /// 1.16+ radio made itself: the radio keeps those in reserved slots at the front of its table
  /// that it hides from sync and reuses, and removing one shifts the whole table down, moving the
  /// first real contact into the hidden reserved range, where it is neither synced nor saved.
  ///
  /// - Returns: `true` if a placeholder was found and removed.
  @discardableResult
  func removeTemporaryContact(publicKey: Data) async throws -> Bool {
    guard let contact = try await getContact(publicKey: publicKey) else { return false }
    guard contact.isTemporaryPlaceholder else { return false }
    try await removeContact(publicKey: publicKey)
    return true
  }
}

public extension MeshContact {
  /// Whether this is the nameless type 0 entry made to send an anonymous request to a node that
  /// is not a contact (see ``MeshCoreSession/addTemporaryContact(publicKey:)``). It is not a
  /// contact the user added, so it should not be stored or shown as one.
  var isTemporaryPlaceholder: Bool {
    typeRawValue == 0 && advertisedName.isEmpty
  }
}
