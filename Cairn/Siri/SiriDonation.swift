import Intents
import CairnServices
import OSLog

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "SiriDonation")

/// Tells Siri about messages the user sends, so it learns who and which channels they write to
/// and can suggest them (in Siri, Shortcuts and CarPlay). Donates who and where only; the system
/// keeps the donation on the device.
@MainActor
enum SiriDonation {
  static func donateSend(to recipient: MessageRecipient) {
    let intent: INSendMessageIntent
    switch recipient {
    case let .contact(contact):
      let person = INPerson(
        personHandle: INPersonHandle(value: contact.id.uuidString, type: .unknown),
        nameComponents: nil,
        displayName: contact.displayName,
        image: nil,
        contactIdentifier: nil,
        customIdentifier: contact.id.uuidString
      )
      intent = INSendMessageIntent(
        recipients: [person],
        outgoingMessageType: .outgoingMessageText,
        content: nil,
        speakableGroupName: nil,
        conversationIdentifier: contact.id.uuidString,
        serviceName: nil,
        sender: nil,
        attachments: nil
      )
    case let .channel(channel):
      intent = INSendMessageIntent(
        recipients: nil,
        outgoingMessageType: .outgoingMessageText,
        content: nil,
        speakableGroupName: INSpeakableString(
          vocabularyIdentifier: channel.id.uuidString,
          spokenPhrase: channel.displayName,
          pronunciationHint: nil
        ),
        conversationIdentifier: channel.id.uuidString,
        serviceName: nil,
        sender: nil,
        attachments: nil
      )
    }
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .outgoing
    interaction.donate { error in
      if let error {
        logger.warning("Siri donation failed: \(error.localizedDescription)")
      }
    }
  }
}
