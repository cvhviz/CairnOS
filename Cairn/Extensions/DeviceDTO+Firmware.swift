import CairnServices

extension DeviceDTO {
  /// "Cairn 107" ("Cairn dev" for a development build) when the radio runs Cairn firmware, which
  /// marks its device info with a build number; nil on any other firmware.
  var cairnFirmwareName: String? {
    cairnBuild.map { build in
      L10n.Settings.DeviceInfo.cairnFirmware(build == 0 ? L10n.Settings.DeviceInfo.cairnDevBuild : String(build))
    }
  }

  /// The firmware as Home and Device Info name it: the Cairn build on Cairn firmware, else the
  /// version string the radio reports ("v1.11.0"). Empty when the radio reports neither.
  var firmwareDisplayName: String {
    cairnFirmwareName ?? firmwareVersionString
  }
}
