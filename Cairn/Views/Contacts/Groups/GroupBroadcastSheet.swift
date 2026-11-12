import CairnServices
import SwiftUI

/// Sends one direct message to every chat contact in a group, one recipient at a time,
/// through the same durable DM queue the chat composer uses (`createPendingMessage` +
/// `ChatSendQueueService.enqueueDM`), so each message also appears in that contact's chat.
@Observable
@MainActor
final class GroupBroadcastModel {
  enum Status: Equatable {
    case waiting
    case sending
    /// Handed to the send queue but the radio has not confirmed it yet.
    case queued
    case sent
    case delivered
    case failed(String?)
    /// Not attempted because the user stopped the broadcast.
    case skipped

    var isAwaitingOutcome: Bool {
      self == .queued || self == .sent
    }
  }

  struct Recipient: Identifiable {
    let contact: ContactDTO
    var status: Status = .waiting
    var messageID: UUID?
    var id: UUID { contact.id }
  }

  private(set) var recipients: [Recipient]
  private(set) var isSending = false
  private(set) var hasStarted = false
  private var stopRequested = false

  /// How long to wait for the radio to accept one message before moving on to the next.
  private static let perRecipientTimeout: Duration = .seconds(45)
  /// How long to keep watching for delivery ACKs after the last send.
  private static let deliveryWatchWindow: Duration = .seconds(90)
  private static let pollInterval: Duration = .milliseconds(500)

  init(contacts: [ContactDTO]) {
    recipients = contacts.map { Recipient(contact: $0) }
  }

  /// Members that can receive a DM on the current radio: chat-type and not blocked.
  static func eligibleRecipients(of group: ContactGroup, in contacts: [ContactDTO]) -> [ContactDTO] {
    group.members(in: contacts)
      .filter { $0.type == .chat && !$0.isBlocked }
      .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
  }

  var completedCount: Int {
    recipients.count { $0.status != .waiting && $0.status != .sending }
  }

  func stop() {
    stopRequested = true
  }

  func send(text: String, appState: AppState) async {
    guard !hasStarted else { return }
    hasStarted = true
    isSending = true
    defer { isSending = false }

    for index in recipients.indices {
      if stopRequested || Task.isCancelled {
        recipients[index].status = .skipped
        continue
      }
      guard let services = appState.services else {
        recipients[index].status = .failed(L10n.Contacts.Contacts.GroupBroadcast.notConnected)
        continue
      }
      recipients[index].status = .sending
      let contact = recipients[index].contact
      do {
        let pending = try await services.messageService.createPendingMessage(text: text, to: contact)
        recipients[index].messageID = pending.id
        do {
          try await services.chatSendQueueService.enqueueDM(
            DirectMessageEnvelope(messageID: pending.id, contactID: contact.id)
          )
        } catch {
          // Same recovery as the chat composer: a persisted row with no queue entry
          // would hang as pending, so surface it as failed (retryable from the chat).
          _ = try? await services.dataStore.updateMessageStatusUnlessDelivered(id: pending.id, status: .failed)
          throw error
        }
        appState.refreshConversations()
        recipients[index].status = await waitForRadio(messageID: pending.id, dataStore: services.dataStore)
      } catch {
        recipients[index].status = .failed(error.userFacingMessage)
      }
    }

    // Everything is handed to the radio; the delivery watch below only updates row
    // statuses, so it must not keep the sheet locked behind a Stop with nothing to stop.
    isSending = false
    await watchForDeliveries(appState: appState)
  }

  /// Polls the message row until the radio has sent (or failed) it, so recipients go
  /// out one after another instead of flooding the queue.
  private func waitForRadio(messageID: UUID, dataStore: PersistenceStore) async -> Status {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: Self.perRecipientTimeout)
    while clock.now < deadline, !Task.isCancelled {
      if let status = await resolvedStatus(messageID: messageID, dataStore: dataStore) {
        return status
      }
      try? await Task.sleep(for: Self.pollInterval)
    }
    return .queued
  }

  private func watchForDeliveries(appState: AppState) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: Self.deliveryWatchWindow)
    while clock.now < deadline, !Task.isCancelled {
      guard let dataStore = appState.services?.dataStore else { return }
      var anyOpen = false
      for index in recipients.indices where recipients[index].status.isAwaitingOutcome {
        guard let messageID = recipients[index].messageID else { continue }
        if let status = await resolvedStatus(messageID: messageID, dataStore: dataStore) {
          recipients[index].status = status
        }
        if recipients[index].status.isAwaitingOutcome {
          anyOpen = true
        }
      }
      guard anyOpen else { return }
      try? await Task.sleep(for: .seconds(2))
    }
  }

  /// Maps a persisted message status to a row status; nil while still pending or sending.
  private func resolvedStatus(messageID: UUID, dataStore: PersistenceStore) async -> Status? {
    guard let message = try? await dataStore.fetchMessage(id: messageID) else { return nil }
    switch message.status {
    case .sent: return .sent
    case .delivered: return .delivered
    case .failed: return .failed(nil)
    case .pending, .sending, .retrying: return nil
    }
  }
}

struct GroupBroadcastSheet: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  let group: ContactGroup

  @State private var text = ""
  @State private var model: GroupBroadcastModel
  @State private var sendTask: Task<Void, Never>?
  @FocusState private var isTextFocused: Bool

  private let skippedCount: Int

  init(group: ContactGroup, contacts: [ContactDTO]) {
    self.group = group
    let eligible = GroupBroadcastModel.eligibleRecipients(of: group, in: contacts)
    _model = State(initialValue: GroupBroadcastModel(contacts: eligible))
    skippedCount = group.memberKeys.count - eligible.count
  }

  private var trimmedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isConnected: Bool {
    appState.connectionState == .ready
  }

  private var canSend: Bool {
    !model.hasStarted && !model.recipients.isEmpty && !trimmedText.isEmpty && isConnected
      && trimmedText.utf8.count <= ProtocolLimits.maxDirectMessageLength
  }

  var body: some View {
    NavigationStack {
      CardForm {
        Label {
          Text(L10n.Contacts.Contacts.GroupBroadcast.warning)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "antenna.radiowaves.left.and.right")
            .foregroundStyle(.orange)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            ContactGroupIcon(group: group, size: 18)
            Text(group.name)
          }
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.secondary)
          .padding(.horizontal, 4)
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isHeader)

          ContentCard {
            TextField(L10n.Contacts.Contacts.GroupBroadcast.placeholder, text: $text, axis: .vertical)
              .lineLimit(3...8)
              .focused($isTextFocused)
              .disabled(model.hasStarted)
              .onChange(of: text) { _, newValue in
                text = Self.clamped(newValue, maxBytes: ProtocolLimits.maxDirectMessageLength)
              }
          }

          HStack {
            if !isConnected {
              Text(L10n.Contacts.Contacts.GroupBroadcast.notConnected)
                .foregroundStyle(.red)
            }
            Spacer()
            Text(verbatim: "\(text.utf8.count)/\(ProtocolLimits.maxDirectMessageLength)")
              .monospacedDigit()
              .foregroundStyle(Color.secondary)
          }
          .font(.footnote)
          .padding(.horizontal, 4)
        }

        recipientsSection
      }
      .flashingNavigationTitle(L10n.Contacts.Contacts.GroupBroadcast.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbarContent }
      .interactiveDismissDisabled(model.isSending)
      .onAppear { isTextFocused = true }
      // Delivery polling outlives the send itself, so a swipe-dismiss after sending must stop it.
      .onDisappear { sendTask?.cancel() }
    }
  }

  private var recipientsSection: some View {
    CardFormSection(
      "\(L10n.Contacts.Contacts.GroupBroadcast.recipients) (\(model.recipients.count))",
      footer: skippedCount > 0 ? L10n.Contacts.Contacts.GroupBroadcast.skippedNote : nil
    ) {
      ContentCard {
        if model.recipients.isEmpty {
          Text(L10n.Contacts.Contacts.GroupBroadcast.noRecipients)
            .foregroundStyle(.secondary)
        } else {
          if model.hasStarted {
            ProgressView(value: Double(model.completedCount), total: Double(model.recipients.count))
          }
          ForEach(Array(model.recipients.enumerated()), id: \.element.id) { index, recipient in
            if index > 0 {
              Divider()
            }
            HStack(spacing: 12) {
              ContactAvatar(contact: recipient.contact, size: 28)
              Text(recipient.contact.displayName)
                .lineLimit(1)
              Spacer()
              GroupBroadcastStatusView(status: recipient.status)
            }
          }
        }
      }
    }
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      if model.isSending {
        Button(L10n.Contacts.Contacts.GroupBroadcast.stop, role: .destructive) {
          model.stop()
        }
      } else {
        Button(model.hasStarted ? L10n.Contacts.Contacts.Common.done : L10n.Contacts.Contacts.Common.cancel) {
          sendTask?.cancel()
          dismiss()
        }
      }
    }
    ToolbarItem(placement: .confirmationAction) {
      if model.isSending {
        ProgressView()
      } else if !model.hasStarted {
        Button(L10n.Contacts.Contacts.GroupBroadcast.send) {
          isTextFocused = false
          let message = trimmedText
          sendTask = Task { await model.send(text: message, appState: appState) }
        }
        .disabled(!canSend)
      }
    }
  }

  /// Trims the tail so the UTF-8 encoding fits the DM payload limit.
  private static func clamped(_ value: String, maxBytes: Int) -> String {
    guard value.utf8.count > maxBytes else { return value }
    var result = ""
    for character in value {
      if result.utf8.count + String(character).utf8.count > maxBytes { break }
      result.append(character)
    }
    return result
  }
}

private struct GroupBroadcastStatusView: View {
  let status: GroupBroadcastModel.Status

  var body: some View {
    switch status {
    case .waiting:
      label(L10n.Contacts.Contacts.GroupBroadcast.Status.waiting, icon: "clock", color: .secondary)
    case .sending:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(L10n.Contacts.Contacts.GroupBroadcast.Status.sending)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .queued:
      label(L10n.Contacts.Contacts.GroupBroadcast.Status.queued, icon: "tray.full", color: .orange)
    case .sent:
      label(L10n.Contacts.Contacts.GroupBroadcast.Status.sent, icon: "checkmark", color: .secondary)
    case .delivered:
      label(L10n.Contacts.Contacts.GroupBroadcast.Status.delivered, icon: "checkmark.circle.fill", color: .green)
    case let .failed(reason):
      label(L10n.Contacts.Contacts.GroupBroadcast.Status.failed, icon: "exclamationmark.triangle.fill", color: .red)
        .help(reason ?? "")
        .accessibilityHint(reason ?? "")
    case .skipped:
      label(L10n.Contacts.Contacts.GroupBroadcast.Status.skipped, icon: "minus.circle", color: .secondary)
    }
  }

  private func label(_ title: String, icon: String, color: Color) -> some View {
    Label(title, systemImage: icon)
      .font(.caption)
      .foregroundStyle(color)
      .labelStyle(.titleAndIcon)
  }
}
