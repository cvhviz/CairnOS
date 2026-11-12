import CoreLocation
import CairnServices

enum PresetLocationPolicy {
  enum ResolveKind: Equatable {
    case appear
    case userInitiated
  }

  enum UseMyLocationAction: Equatable {
    case resolve
    case waitForAuthorization
    case openSettings
  }

  enum AfterAuthorizationWait: Equatable {
    case resolve
    case openSettings
    case none
  }

  static func isIncomplete(_ selection: RegionSelection?) -> Bool {
    guard let selection else { return true }
    return RegionalAreas.showsSubdivisionPicker(for: selection.countryCode)
      && selection.administrativeAreaCode == nil
  }

  /// Whether Radio's inline Location group opens expanded: only when location can't fill the
  /// selection in for the user and it's still missing a country or a required state.
  static func startsExpandedOnRadio(authorized: Bool, selection: RegionSelection?) -> Bool {
    !authorized && isIncomplete(selection)
  }

  static func shouldResolveOnAppear(
    authorized: Bool,
    source: RegionSelection.Source?
  ) -> Bool {
    authorized && source != .manual
  }

  static func shouldCommitAppearResult(currentSource: RegionSelection.Source?) -> Bool {
    currentSource != .manual
  }

  static func committedSelection(
    current: RegionSelection?,
    result: RegionResolution?,
    kind: ResolveKind
  ) -> RegionSelection? {
    guard let result else { return current }
    switch kind {
    case .appear:
      guard shouldCommitAppearResult(currentSource: current?.source) else { return current }
      return keepingSavedCounty(result, current: current)
    case .userInitiated:
      return keepingSavedCounty(result, current: current)
    }
  }

  /// The lookup's place, keeping `current`'s county when the placemark had no county field for
  /// the same state, since the geocoder can leave it out. A county it did name, listed or not
  /// (`RegionalAreas.otherCountyKey`), always wins, so a move to another county never keeps the
  /// old one.
  static func keepingSavedCounty(
    _ result: RegionResolution,
    current: RegionSelection?
  ) -> RegionSelection {
    let located = result.selection
    guard result.countyFieldMissing,
          let current,
          let savedCounty = current.countyKey,
          current.countryCode == located.countryCode,
          let state = located.administrativeAreaCode,
          current.administrativeAreaCode == state else {
      return located
    }
    return RegionSelection(
      countryCode: located.countryCode,
      administrativeAreaCode: state,
      countyKey: savedCounty,
      source: located.source
    )
  }

  static func useMyLocationAction(status: CLAuthorizationStatus) -> UseMyLocationAction {
    switch status {
    case .authorizedWhenInUse, .authorizedAlways:
      return .resolve
    case .notDetermined:
      return .waitForAuthorization
    case .denied, .restricted:
      return .openSettings
    @unknown default:
      return .openSettings
    }
  }

  static func actionAfterAuthorizationWait(
    status: CLAuthorizationStatus
  ) -> AfterAuthorizationWait {
    switch status {
    case .authorizedWhenInUse, .authorizedAlways:
      return .resolve
    case .denied, .restricted:
      return .openSettings
    case .notDetermined:
      return .none
    @unknown default:
      return .openSettings
    }
  }

  /// Whether a finished lookup reports that it found no place: when another request held the
  /// location slot past the wait (`slotFreed` false, so no lookup ran), or when it ran and got no
  /// result. Only a lookup the user asked for says so; one run on appear stays quiet.
  static func lookupMissMessageShown(
    slotFreed: Bool,
    result: RegionResolution?,
    kind: ResolveKind
  ) -> Bool {
    guard kind == .userInitiated else { return false }
    return !slotFreed || result == nil
  }
}
