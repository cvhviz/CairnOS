// CairnServices - iOS-specific services for Cairn
// Re-exports MeshCore so consumers only need to import CairnServices

@_exported import MeshCore

/// CairnServices provides iOS-specific implementations on top of MeshCore:
/// - SwiftData models (Device, Contact, Message, Channel)
/// - PersistenceStore (@ModelActor for SwiftData operations)
/// - iOS BLE transport with state restoration and background mode
/// - Notification, Keychain, and AccessorySetupKit services
/// - High-level service layer (ContactService, MessageService, ChannelService)
enum CairnServicesVersion {
  static let version = "0.1.0"
}
