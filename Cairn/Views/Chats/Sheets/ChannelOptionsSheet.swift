import CairnServices
import SwiftUI

/// Sheet presenting channel creation and joining options
struct ChannelOptionsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appState) private var appState

  let onChannelCreated: ((ChannelDTO) -> Void)?

  @State private var selectedOption: ChannelOption?
  @State private var availableSlots: [UInt8] = []
  @State private var hasPublicChannel = false
  @State private var isLoading = true

  init(onChannelCreated: ((ChannelDTO) -> Void)? = nil) {
    self.onChannelCreated = onChannelCreated
  }

  enum ChannelOption: Identifiable {
    case createPrivate
    case joinPrivate
    case joinPublic
    case joinHashtag
    case scanQR

    var id: Self {
      self
    }
  }

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          ProgressView(L10n.Chats.Chats.ChannelOptions.loading)
        } else {
          optionsList
        }
      }
      .flashingNavigationTitle(L10n.Chats.Chats.ChannelOptions.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Chats.Chats.Common.cancel) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
      }
      .task {
        await loadChannelState()
      }
      .navigationDestination(item: $selectedOption) { option in
        switch option {
        case .createPrivate:
          CreatePrivateChannelView(availableSlots: availableSlots) { channel in
            if let channel { onChannelCreated?(channel) }
            dismiss()
          }
        case .joinPrivate:
          JoinPrivateChannelView(availableSlots: availableSlots) { channel in
            if let channel { onChannelCreated?(channel) }
            dismiss()
          }
        case .joinPublic:
          JoinPublicChannelView { channel in
            if let channel { onChannelCreated?(channel) }
            dismiss()
          }
        case .joinHashtag:
          JoinHashtagChannelView(availableSlots: availableSlots) { channel in
            if let channel { onChannelCreated?(channel) }
            dismiss()
          }
        case .scanQR:
          ScanChannelQRView(availableSlots: availableSlots) { channel in
            if let channel { onChannelCreated?(channel) }
            dismiss()
          }
        }
      }
    }
  }

  private var optionsList: some View {
    CardForm {
      CardFormSection(L10n.Chats.Chats.ChannelOptions.Section.private) {
        // Create Private Channel
        Button {
          selectedOption = .createPrivate
        } label: {
          ChannelOptionRow(
            title: L10n.Chats.Chats.ChannelOptions.CreatePrivate.title,
            description: L10n.Chats.Chats.ChannelOptions.CreatePrivate.description,
            icon: "lock.fill",
            iconColor: .blue
          )
        }
        .buttonStyle(.plain)
        .disabled(availableSlots.isEmpty)

        // Join Private Channel
        Button {
          selectedOption = .joinPrivate
        } label: {
          ChannelOptionRow(
            title: L10n.Chats.Chats.ChannelOptions.JoinPrivate.title,
            description: L10n.Chats.Chats.ChannelOptions.JoinPrivate.description,
            icon: "key.fill",
            iconColor: .orange
          )
        }
        .buttonStyle(.plain)
        .disabled(availableSlots.isEmpty)

        // Scan QR Code
        Button {
          selectedOption = .scanQR
        } label: {
          ChannelOptionRow(
            title: L10n.Chats.Chats.ChannelOptions.ScanQR.title,
            description: L10n.Chats.Chats.ChannelOptions.ScanQR.description,
            icon: "qrcode.viewfinder",
            iconColor: .purple
          )
        }
        .buttonStyle(.plain)
        .disabled(availableSlots.isEmpty)
      }

      CardFormSection(L10n.Chats.Chats.ChannelOptions.Section.public, footer: optionsFooter) {
        // Join Public Channel
        Button {
          selectedOption = .joinPublic
        } label: {
          ChannelOptionRow(
            title: L10n.Chats.Chats.ChannelOptions.JoinPublic.title,
            description: L10n.Chats.Chats.ChannelOptions.JoinPublic.description,
            icon: "globe",
            iconColor: .green
          )
        }
        .buttonStyle(.plain)
        .disabled(hasPublicChannel)

        // Join Hashtag Channel
        Button {
          selectedOption = .joinHashtag
        } label: {
          ChannelOptionRow(
            title: L10n.Chats.Chats.ChannelOptions.JoinHashtag.title,
            description: L10n.Chats.Chats.ChannelOptions.JoinHashtag.description,
            icon: "number",
            iconColor: .cyan
          )
        }
        .buttonStyle(.plain)
        .disabled(availableSlots.isEmpty)
      }
    }
  }

  /// Why some options are dimmed: a short state line, so it stays visible under the cards.
  private var optionsFooter: String? {
    if availableSlots.isEmpty {
      L10n.Chats.Chats.ChannelOptions.Footer.noSlots
    } else if hasPublicChannel {
      L10n.Chats.Chats.ChannelOptions.Footer.hasPublic
    } else {
      nil
    }
  }

  private func loadChannelState() async {
    guard let radioID = appState.connectedDevice?.radioID else {
      isLoading = false
      return
    }

    do {
      let existingChannels = try await appState.services?.dataStore.fetchChannels(radioID: radioID) ?? []
      let usedSlots = Set(existingChannels.map(\.index))

      // Public is the channel with the Public key, not whatever sits in slot 0
      hasPublicChannel = existingChannels.contains(where: \.isPublicChannel)

      // Slots 1 through (maxChannels-1) are available for user channels
      // Slot 0 is reserved for public channel
      let maxChannels = appState.connectedDevice?.maxChannels ?? 0
      if maxChannels > 1 {
        availableSlots = (1..<maxChannels).filter { !usedSlots.contains($0) }
      } else {
        availableSlots = []
      }
    } catch {
      // Handle error silently, show empty state
    }

    isLoading = false
  }
}

/// Card for a channel option: icon tile, title, description and a chevron, dimmed when the
/// option is unavailable (no free slots, public channel already joined). Each way in is its own
/// full-width card so the descriptions fit.
struct ChannelOptionRow: View {
  @Environment(\.isEnabled) private var isEnabled

  let title: String
  let description: String
  let icon: String
  let iconColor: Color

  var body: some View {
    HStack(spacing: 12) {
      IconTile(systemImage: icon, color: isEnabled ? iconColor : .secondary)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isEnabled ? .primary : .secondary)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .cardSurface(padding: 12)
    .cardInteractionShape()
  }
}

#Preview {
  ChannelOptionsSheet()
    .environment(\.appState, AppState())
}
