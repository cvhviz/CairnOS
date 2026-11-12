import Foundation
import SwiftData

// MARK: - Data export (CSV/GPX)

public extension PersistenceStore {
  /// Messages for one radio, optionally narrowed to a single DM contact or channel slot.
  /// Link-preview blobs are skipped so export never faults external storage in.
  func fetchMessagesForExport(radioID: UUID, contactID: UUID?, channelIndex: UInt8?) throws -> [MessageDTO] {
    let targetRadioID = radioID
    let descriptor: FetchDescriptor<Message>
    if let contactID {
      let targetContactID: UUID? = contactID
      descriptor = FetchDescriptor<Message>(
        predicate: #Predicate { $0.radioID == targetRadioID && $0.contactID == targetContactID },
        sortBy: [SortDescriptor(\.createdAt)]
      )
    } else if let channelIndex {
      let targetChannel: UInt8? = channelIndex
      descriptor = FetchDescriptor<Message>(
        predicate: #Predicate { $0.radioID == targetRadioID && $0.channelIndex == targetChannel },
        sortBy: [SortDescriptor(\.createdAt)]
      )
    } else {
      descriptor = FetchDescriptor<Message>(
        predicate: #Predicate { $0.radioID == targetRadioID },
        sortBy: [SortDescriptor(\.createdAt)]
      )
    }
    return try modelContext.fetch(descriptor).map { MessageDTO(from: $0) }
  }
}
