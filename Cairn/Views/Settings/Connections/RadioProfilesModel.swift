import CairnServices
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "cvhvisuals.Cairn", category: "RadioProfiles")

/// The Connections page's radio config profiles: the list as stored, and saving one from the
/// connected radio. Shared with the profile page pushed from it, so a rename or delete there shows
/// on the list at once.
@Observable
@MainActor
final class RadioProfilesModel {
  private(set) var profiles: [RadioConfigProfile] = []
  private(set) var isSaving = false
  var errorMessage: String?
  /// The name alert for a new profile, opened from the list or the toolbar's add menu.
  var isNaming = false
  var newName = ""

  private let store: RadioConfigProfileStore

  init(store: RadioConfigProfileStore = RadioConfigProfileStore()) {
    self.store = store
  }

  /// Opens the name alert, prefilled with the connected radio's name.
  func beginSaving(radioName: String?) {
    newName = radioName ?? ""
    isNaming = true
  }

  /// Profiles whose name contains `query`, all of them for an empty one.
  func filtered(by query: String) -> [RadioConfigProfile] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return profiles }
    return profiles.filter { $0.name.localizedStandardContains(query) }
  }

  func profile(id: UUID) -> RadioConfigProfile? {
    profiles.first { $0.id == id }
  }

  func load() {
    perform { try store.load() }
  }

  /// Reads the connected radio's settings with the export (`RadioConfigProfile.captureSections`,
  /// never the identity section, which would read the private key) and saves them under `name`.
  /// The radio's name comes from the connected device, so a profile can rename a radio too.
  func saveCurrentRadio(named name: String, nodeConfigService: NodeConfigService?, device: DeviceDTO?) async {
    guard !isSaving, let nodeConfigService, let device,
          let name = RadioConfigProfile.normalizedName(name) else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      var config = try await nodeConfigService.exportConfig(sections: RadioConfigProfile.captureSections)
      config.name = device.nodeName
      let profile = RadioConfigProfile(name: name, sourceDeviceName: device.nodeName, config: config)
      profiles = try store.upsert(profile)
    } catch is CancellationError {
      return
    } catch {
      logger.error("Saving profile failed: \(error.localizedDescription)")
      errorMessage = error.userFacingMessage
    }
  }

  func rename(_ id: UUID, to name: String) {
    perform { try store.rename(id: id, to: name) }
  }

  func delete(_ id: UUID) {
    perform { try store.delete(id: id) }
  }

  private func perform(_ change: () throws -> [RadioConfigProfile]) {
    do {
      profiles = try change()
    } catch {
      logger.error("Profile store failed: \(error.localizedDescription)")
      errorMessage = error.userFacingMessage
    }
  }
}
