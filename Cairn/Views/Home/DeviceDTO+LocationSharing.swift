import CairnServices

extension DeviceDTO {
  /// Who can see the radio's position: everyone through adverts, whoever asks through telemetry
  /// replies that include it, or nobody. Worded as Location & Sharing words it.
  var locationSharingSummary: String {
    if sharesLocationPublicly {
      return L10n.Settings.Location.sharingPublicly
    }
    if telemetryModeBase > 0, telemetryModeLoc > 0 {
      return L10n.Settings.Location.sharedOnRequest
    }
    return L10n.Settings.Location.notSharing
  }
}
