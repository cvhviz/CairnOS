import Foundation

// MARK: - Demo Room

/// Diana's Room as a joined room server with a short history, so demo mode shows a room in the
/// Chats list and how its posts name their authors. A room server pushes each post with only the
/// first 4 bytes of its author's key (`simple_room_server` `pushPostToClient`, the same on stock
/// MeshCore and Cairn firmware); the app names the author from that prefix when it is shown. The
/// posts cover each case:
/// - the room's own welcome post, from the room's key: reads as the room
/// - a contact saved under their advertised name (Alice Chen)
/// - a contact given a nickname after posting (Frank Wilson, now "Dad"): reads as the nickname,
///   not the name saved with the post
/// - an author saved as a contact after posting (Hannah Lee): saved with no name, reads by name
/// - an author this radio has never heard of: reads as their key prefix, marked unknown
/// - the user's own post: reads as theirs
extension MockDataProvider {
  public static let dianasRoomSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!

  /// The key prefix of an author no contact matches.
  static let unknownRoomAuthorPrefix = Data([0xDE, 0xAD, 0xBE, 0xEF])

  /// The joined Diana's Room session, logged in so the demo can open it: a room that isn't
  /// logged in asks for its password before it opens, which the demo radio can't answer.
  static func dianasRoomSession(now: Date = Date()) -> RemoteNodeSessionDTO {
    RemoteNodeSessionDTO(
      id: dianasRoomSessionID,
      radioID: simulatorDeviceID,
      publicKey: mockPublicKey(seed: 40),
      name: "Diana's Room",
      role: .roomServer,
      latitude: 37.7449,
      longitude: -122.4494,
      isConnected: true,
      permissionLevel: .readWrite,
      lastConnectedDate: now.addingTimeInterval(-3600),
      unreadCount: 2,
      lastMessageDate: now.addingTimeInterval(-4 * 60)
    )
  }

  /// `existing`, the seeded session as the user has left it, brought back to the seed on a new
  /// connect: logged in again, with its last activity at the newest post's now-relative time (or
  /// later, if the user was active since).
  /// Everything the user can change (name, unread count, notifications, favourite) is kept.
  static func dianasRoomSession(refreshing existing: RemoteNodeSessionDTO, now: Date = Date()) -> RemoteNodeSessionDTO {
    let seeded = dianasRoomSession(now: now)
    return RemoteNodeSessionDTO(
      id: existing.id,
      radioID: existing.radioID,
      publicKey: existing.publicKey,
      name: existing.name,
      role: existing.role,
      latitude: existing.latitude,
      longitude: existing.longitude,
      isConnected: true,
      permissionLevel: seeded.permissionLevel,
      lastConnectedDate: existing.isConnected ? existing.lastConnectedDate : now,
      lastBatteryMillivolts: existing.lastBatteryMillivolts,
      lastUptimeSeconds: existing.lastUptimeSeconds,
      lastNoiseFloor: existing.lastNoiseFloor,
      unreadCount: existing.unreadCount,
      notificationLevel: existing.notificationLevel,
      isFavorite: existing.isFavorite,
      lastRxAirtimeSeconds: existing.lastRxAirtimeSeconds,
      neighborCount: existing.neighborCount,
      lastSyncTimestamp: existing.lastSyncTimestamp,
      lastMessageDate: [existing.lastMessageDate, seeded.lastMessageDate].compactMap(\.self).max()
    )
  }

  /// The room's posts, oldest first.
  static func dianasRoomPosts(now: Date = Date()) -> [RoomMessageDTO] {
    func post(
      _ id: String,
      minutesAgo: Double,
      author: Data,
      savedName: String?,
      text: String,
      isFromSelf: Bool = false
    ) -> RoomMessageDTO {
      let date = now.addingTimeInterval(-minutesAgo * 60)
      return RoomMessageDTO(
        id: UUID(uuidString: id)!,
        sessionID: dianasRoomSessionID,
        authorKeyPrefix: author.prefix(4),
        authorName: savedName,
        text: text,
        timestamp: UInt32(date.timeIntervalSince1970),
        createdAt: date,
        isFromSelf: isFromSelf,
        status: .delivered
      )
    }
    return [
      post("40000000-0000-0000-0000-000000000001", minutesAgo: 180, author: mockPublicKey(seed: 40),
           savedName: nil, text: "Welcome to Diana's Room. Trail reports and meetups for the ridge."),
      post("40000000-0000-0000-0000-000000000002", minutesAgo: 95, author: mockPublicKey(seed: 10),
           savedName: "Alice Chen", text: "Morning all, the lower trail is clear today."),
      // Saved under his advertised name, before he was given the nickname "Dad".
      post("40000000-0000-0000-0000-000000000003", minutesAgo: 70, author: mockPublicKey(seed: 60),
           savedName: "Frank Wilson", text: "Heading up at noon, will report conditions from the top."),
      // Arrived before Hannah was saved as a contact, so no name was known then.
      post("40000000-0000-0000-0000-000000000004", minutesAgo: 40, author: mockPublicKey(seed: 80),
           savedName: nil, text: "Snow above 8,000 ft. Bring traction."),
      post("40000000-0000-0000-0000-000000000005", minutesAgo: 22, author: unknownRoomAuthorPrefix,
           savedName: nil, text: "Anyone near the north gate? Could use a relay."),
      post("40000000-0000-0000-0000-000000000006", minutesAgo: 4, author: mockPublicKey(seed: 1),
           savedName: nil, text: "On my way up, about 20 minutes out.", isFromSelf: true),
    ]
  }
}
