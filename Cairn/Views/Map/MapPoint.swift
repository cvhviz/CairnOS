import CairnServices
import CoreLocation
import Foundation

struct MapPoint: Identifiable, Equatable {
  let id: UUID
  let coordinate: CLLocationCoordinate2D
  let pinStyle: PinStyle
  let label: String?
  let isClusterable: Bool

  enum PinStyle: String, Hashable {
    case contactChat
    case contactRepeater
    case contactRoom
    case repeater
    case repeaterRingBlue
    case repeaterRingGreen
    case repeaterRingWhite
    case repeaterHop
    case pointA
    case pointB
    case crosshair
    case obstruction
    case badge
    case droppedPin
    /// A sampled node location report: a small neutral dot threaded onto the
    /// history trail. Center-anchored, unlike the bottom-anchored teardrops.
    case locationFix
    /// The node's most recent location report: the emphasized hero teardrop that
    /// caps the trail.
    case locationFixLatest
    /// Heard on the mesh but not on the node list: outlined versions of the contact pins.
    case discoveredChat
    case discoveredRepeater
    case discoveredRoom
  }

  let hopIndex: Int?
  let badgeText: String?
  /// Icon and label opacity; below 1 fades a pin, e.g. a discovered node not heard recently.
  var opacity: Double = 1
  /// Short secondary info shown beside the name in its badge, e.g. "5m" or "+7.5 dB".
  var detail: String?
  /// Favorites win the badge collision over other nodes.
  var isFavorite = false
  /// The link SNR a stats badge (`badgeText`) reports; the stronger link wins when two stats
  /// badges would overlap. Nil for anything else.
  var badgeSNR: Double?
  /// Who a node pin stands for, so it draws that node's avatar. Nil on a node pin draws its
  /// category's avatar; other pins ignore it.
  var avatar: MapPinAvatar?

  static func == (lhs: MapPoint, rhs: MapPoint) -> Bool {
    lhs.id == rhs.id
      && lhs.coordinate.latitude == rhs.coordinate.latitude
      && lhs.coordinate.longitude == rhs.coordinate.longitude
      && lhs.pinStyle == rhs.pinStyle
      && lhs.label == rhs.label
      && lhs.isClusterable == rhs.isClusterable
      && lhs.hopIndex == rhs.hopIndex
      && lhs.badgeText == rhs.badgeText
      && lhs.opacity == rhs.opacity
      && lhs.detail == rhs.detail
      && lhs.isFavorite == rhs.isFavorite
      && lhs.badgeSNR == rhs.badgeSNR
      && lhs.avatar == rhs.avatar
  }
}

/// The parts of a node's avatar a map pin draws: the name, whose leading emoji a companion shows,
/// the photo, if the node has one, and the colour picked for it. Without a photo or picked colour,
/// every node draws its category's colour.
struct MapPinAvatar: Equatable {
  let name: String
  /// One of the user's own radios, drawn in the radio colour rather than the companions'.
  let isRadio: Bool
  /// The photo's JPEG bytes, drawn only on a saved node's pin.
  let photo: Data?
  /// Stands for the photo in comparisons and sprite names, so the bytes are hashed once.
  let photoRevision: UInt64?
  /// The picked colour; nil means Automatic.
  let color: NodeAvatarColor?

  init(name: String, photo: Data? = nil, color: NodeAvatarColor? = nil, isRadio: Bool = false) {
    self.name = name
    self.isRadio = isRadio
    let revision = IncomingAvatarIdentity.revision(of: photo)
    self.photo = revision == nil ? nil : photo
    photoRevision = revision
    self.color = color
  }

  init(contact: ContactDTO) {
    self.init(name: contact.displayName, photo: contact.avatarImageData, color: contact.avatarColor)
  }

  /// A node known only by name and key: its photo and colour come from the contact with that key,
  /// if there is one.
  init(name: String, appearance: NodeAppearance?) {
    self.init(name: name, photo: appearance?.photo, color: appearance?.color)
  }

  static func == (lhs: MapPinAvatar, rhs: MapPinAvatar) -> Bool {
    lhs.name == rhs.name && lhs.isRadio == rhs.isRadio && lhs.photoRevision == rhs.photoRevision
      && lhs.color == rhs.color
  }
}

extension MapPinAvatar: Hashable {
  func hash(into hasher: inout Hasher) {
    hasher.combine(name)
    hasher.combine(isRadio)
    hasher.combine(photoRevision)
    hasher.combine(color)
  }
}
