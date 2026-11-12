import UIKit

/// What to call this phone on its GPS card, as the radio's card shows the radio's name. iOS hands
/// apps the name the user gave the phone ("Chris's iPhone") only with Apple's
/// user-assigned-device-name entitlement; without it `UIDevice.name` is just "iPhone", so the model
/// ("iPhone 16 Pro") stands in, from the hardware identifier.
@MainActor
enum PhoneName {
  static var display: String {
    let device = UIDevice.current
    if device.name != device.model, !device.name.isEmpty { return device.name }
    return modelName(identifier: hardwareIdentifier) ?? device.model
  }

  /// "iPhone17,1"; the simulated device's on the simulator.
  static var hardwareIdentifier: String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  /// Marketing names for the iPhones recent enough to run Cairn; nil for any other identifier.
  static func modelName(identifier: String) -> String? {
    models[identifier]
  }

  private static let models: [String: String] = [
    "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
    "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
    "iPhone14,6": "iPhone SE",
    "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
    "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
    "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
    "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
    "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
    "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
    "iPhone17,5": "iPhone 16e",
    "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
    "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
    "iPhone19,3": "iPhone 18 Pro Max",
  ]
}
