import Foundation

/// Shared `UserDefaults` keys used by both the services layer and the app
/// target. Centralising the string literals prevents drift between writer and
/// reader — e.g. `ConnectionManager` persisting under one name while another
/// reader looks under a stale name and silently no-ops.
///
/// Lane: connection-infrastructure identity (reverse-DNS `cvhvisuals.Cairn.*`)
/// plus the color-scheme key. User preferences and UI
/// state belong in `AppStorageKey` instead; the two namespaces never share a key.
public enum PersistenceKeys {
  public static let lastConnectedDeviceID = "cvhvisuals.Cairn.lastConnectedDeviceID"
  public static let lastConnectedDeviceName = "cvhvisuals.Cairn.lastConnectedDeviceName"
  public static let lastConnectedRadioID = "cvhvisuals.Cairn.lastConnectedRadioID"
  public static let lastDisconnectDiagnostic = "cvhvisuals.Cairn.lastDisconnectDiagnostic"
  public static let lastBondVerifiedDeviceID = "cvhvisuals.Cairn.lastBondVerifiedDeviceID"
  public static let lastBondVerifiedDate = "cvhvisuals.Cairn.lastBondVerifiedDate"
  /// Radio ID string → the transport ("bluetooth" or "wifi") it last connected over.
  public static let lastTransportByRadio = "cvhvisuals.Cairn.lastTransportByRadio"
  public static let userExplicitlyDisconnected = "cvhvisuals.Cairn.userExplicitlyDisconnected"
  /// WiFi endpoints (`host:port`) whose radio left a background attempt unanswered, each with
  /// when (seconds since 1970); background attempts wait for the user or for the block to lapse
  /// (`BackgroundWiFiApprovalGate`).
  public static let backgroundWiFiAwaitingApproval = "cvhvisuals.Cairn.backgroundWiFiAwaitingApproval"
  /// Radio ID string of the radio whose channel table the store last copied in full and cleanly
  /// (`ConnectionManager.verifiedChannelTableRadioID`). Removed when a read that did not finish
  /// cleanly changed the stored table, and on user disconnect, device switch, forget and backup
  /// import.
  public static let verifiedChannelTableRadioID = "cvhvisuals.Cairn.verifiedChannelTableRadioID"
  /// Bumped by each backup import, which rewrites the stored channel rows. `ConnectionManager`
  /// drops its in-memory channel sync records when it sees a new value
  /// (`ConnectionManager.dropChannelSyncRecordsPredatingImport()`).
  public static let channelRowsImportGeneration = "cvhvisuals.Cairn.channelRowsImportGeneration"

  /// App color-scheme preference raw value (`"system"` | `"light"` | `"dark"`). Bare string.
  public static let appColorSchemePreference = "appColorSchemePreference"
}
