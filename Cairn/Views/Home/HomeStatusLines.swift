import CoreLocation
import Foundation
import CairnServices

/// The words on Home's status cards, as plain functions of what the app holds, so the Home cards
/// and the CarPlay Home screen say exactly the same thing. No view state: the tests pin the output.
enum HomeStatusLines {
  /// The connection rung in the status menu's words: "Ready", "Syncing", "Disconnected".
  static func linkTitle(_ state: DeviceConnectionState) -> String {
    switch state {
    case .disconnected: L10n.Settings.BleStatus.Status.disconnected
    case .connecting: L10n.Settings.BleStatus.Status.connecting
    case .connected: L10n.Settings.BleStatus.Status.connected
    case .syncing: L10n.Settings.BleStatus.Status.syncing
    case .ready: L10n.Settings.BleStatus.Status.ready
    }
  }

  /// "Heltec V3 · v1.9.1": the radio's model and firmware, for Home's header card and CarPlay's
  /// Dashboard ("LilyGO T-Display SF32 · Cairn 107" on Cairn firmware). The model falls back to a
  /// generic name when the radio doesn't report one.
  static func modelLine(_ device: DeviceDTO) -> String {
    let model = device.manufacturerName.isEmpty
      ? L10n.Settings.DeviceInfo.defaultManufacturer
      : device.manufacturerName
    let firmware = device.firmwareDisplayName
    guard !firmware.isEmpty else { return model }
    return L10n.Settings.Dashboard.firmware(model, firmware)
  }

  /// The voltage, or why there is no charge to show. No time-remaining estimate: the radio
  /// reports no current draw, so any figure would be a guess.
  static func batteryDetail(hasDevice: Bool, voltage: Double?, isReady: Bool, batteryPresent: Bool?) -> String {
    guard hasDevice else { return L10n.Localizable.Home.noRadio }
    if let voltage {
      return BatteryLevel.formattedVoltage(voltage)
    }
    let hasNoBattery = isReady && batteryPresent == false
    return hasNoBattery ? L10n.Settings.Battery.notPresent : L10n.Settings.Dashboard.noReading
  }

  /// The WiFi address, or whether Bluetooth pairs with the default PIN or the radio's own. The
  /// PIN itself shows on the Connection page. `includesPin` false leaves the
  /// Bluetooth PIN kind out, for screens where it is a setting rather than a reading.
  static func transportDetail(_ device: DeviceDTO, isWiFi: Bool, includesPin: Bool = true) -> String? {
    if isWiFi {
      guard case let .wifi(host, _, _) = device.connectionMethods.first(where: \.isWiFi) else { return nil }
      return host
    }
    guard includesPin else { return nil }
    // Only 0 is the radio's default: 123456 is a PIN someone chose, whatever it looks like.
    return device.blePin == 0 ? L10n.Localizable.Home.Network.defaultPin : L10n.Localizable.Home.Network.customPin
  }

  /// "Bluetooth" or "WiFi", the transport's name.
  static func transportName(isWiFi: Bool) -> String {
    isWiFi ? L10n.Settings.Wifi.header : L10n.Settings.Bluetooth.header
  }

  /// "910.525" from kHz.
  static func megahertz(_ kilohertz: UInt32) -> String {
    (Double(kilohertz) / 1000).formatted(.number.precision(.fractionLength(3)))
  }

  /// The preset's name, or "Custom" when the settings match none.
  static func presetName(_ device: DeviceDTO, region: RegionSelection?) -> String {
    preset(device, region: region)?.name ?? L10n.Settings.BatteryCurve.custom
  }

  /// The preset the radio's settings match, nil for custom settings.
  static func preset(_ device: DeviceDTO, region: RegionSelection?) -> RadioPreset? {
    device.clientRepeat
      ? RadioPresets.matchingRepeatPreset(frequencyKHz: device.frequency)
      : RadioPresets.resolvedPreset(
        frequencyKHz: device.frequency,
        bandwidthKHz: device.bandwidth,
        spreadingFactor: device.spreadingFactor,
        codingRate: device.codingRate,
        preferredID: device.appliedRadioPresetID,
        region: region
      )
  }

  /// "SF7 · 62.5 kHz".
  static func modulation(_ device: DeviceDTO) -> String {
    let bandwidth = RadioOptions.formatBandwidth(RadioOptions.nearestBandwidth(to: device.bandwidth))
    return L10n.Settings.Dashboard.modulation(Int(device.spreadingFactor), bandwidth)
  }

  /// "~300 ms/pkt": how long a short message takes on air on these settings, which says what the
  /// preset costs in a way SF and bandwidth don't.
  static func packetAirtime(_ device: DeviceDTO) -> String {
    let channel = LoRaChannelMath(
      frequencyHz: Double(device.frequency) * 1000,
      bandwidthHz: Double(device.bandwidth),
      spreadingFactor: Int(device.spreadingFactor),
      codingRate: Int(device.codingRate)
    )
    let milliseconds = (channel.timeOnAir(payloadBytes: LoRaChannelMath.airtimeHintBytes) * 1000).rounded()
    return L10n.Tools.Tools.Spectrum.Header.airtimeShort(milliseconds.formatted(.number.precision(.fractionLength(0))))
  }

  /// The Radio card's lines as groups of short facts: the preset's name; "SF7 · 62.5 kHz · CR 4/5";
  /// then the transmit power when read and a packet's time on air. Each group is one line on a card
  /// wide enough for it and splits one fact to a line otherwise (`HomeCardDetail(parts:)`), so the
  /// figures are never truncated.
  static func radioLineGroups(_ device: DeviceDTO, region: RegionSelection?, txPower: Int?) -> [[String]] {
    [
      [presetName(device, region: region)],
      [modulation(device), L10n.Tools.Tools.Spectrum.Header.codingRate(Int(device.codingRate))],
      [
        txPower.map { L10n.Settings.DeviceInfo.txPowerFormat($0.formatted()) },
        packetAirtime(device),
      ].compactMap(\.self),
    ]
    .map { $0.filter { !$0.isEmpty } }
    .filter { !$0.isEmpty }
  }

  /// The Radio card's lines, each group joined: what VoiceOver reads for the card.
  static func radioLines(_ device: DeviceDTO, region: RegionSelection?, txPower: Int?) -> [String] {
    radioLineGroups(device, region: region, txPower: txPower).map { NodeRouteFormat.joined($0) }
  }

  /// "1m · 3.4 mi NE": how long ago, and how far and which way from `origin` when both have a
  /// position.
  static func lastHeardLine(lastHeard: Date, coordinate: CLLocationCoordinate2D?, origin: CLLocation?, now: Date) -> String {
    let age = HomeFormat.age(now.timeIntervalSince(lastHeard))
    guard let coordinate, let origin,
          let distance = NodeRouteFormat.distance(from: origin, latitude: coordinate.latitude, longitude: coordinate.longitude) else {
      return age
    }
    let direction = HomeFormat.compassPoint(bearing: HomeFormat.bearing(from: origin.coordinate, to: coordinate))
    return NodeRouteFormat.joined([age, "\(distance) \(direction)"])
  }
}
