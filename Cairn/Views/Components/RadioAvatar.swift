import CairnServices
import SwiftUI

/// The avatar of one of the user's own radios: the photo or colour picked for it on this phone
/// (`RadioAvatarStore`), drawn as a companion's avatar is, on the radio's own colour.
struct RadioAvatar: View {
  @Environment(\.appState) private var appState
  let device: DeviceDTO
  let size: CGFloat

  var body: some View {
    ContactAvatar(
      name: device.nodeName,
      size: size,
      imageData: appState.radioAvatars.photo(for: device.radioID),
      color: appState.radioAvatars.color(for: device.radioID),
      category: .radio
    )
  }
}

extension MapPinAvatar {
  /// One of the user's own radios, with the photo and colour picked for it.
  @MainActor
  init(device: DeviceDTO, store: RadioAvatarStore) {
    self.init(
      name: device.nodeName,
      photo: store.photo(for: device.radioID),
      color: store.color(for: device.radioID),
      isRadio: true
    )
  }
}
