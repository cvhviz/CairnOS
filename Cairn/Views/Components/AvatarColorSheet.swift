import CairnServices
import SwiftUI

/// Picks the colour for a node's avatar: Automatic, a hue swatch, one of the type colours or any
/// colour from the system picker. A live preview shows the avatar and the name as they'll look.
/// Hue swatches are solved per theme, appearance and contrast like identity colours; type and
/// custom colours fill the avatar exactly, and names move them only as far as legibility needs.
struct AvatarColorSheet<Preview: View>: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  let name: String
  /// The node's kind, whose colour Automatic keeps for the name in the preview.
  let category: AvatarCategory
  let hasPhoto: Bool
  let preview: (NodeAvatarColor?) -> Preview
  let onDone: (NodeAvatarColor?) -> Void
  @State private var selection: NodeAvatarColor?
  /// The last colour from the system picker, kept when another swatch is chosen so the Custom row
  /// can bring it back.
  @State private var customRGB: Int

  private static var previewSize: CGFloat { 56 }
  private static var swatchSize: CGFloat { 40 }
  /// Adaptive so a narrow window wraps to more rows instead of overlapping the swatches.
  private let columns = [GridItem(.adaptive(minimum: 44), spacing: 10)]

  init(
    name: String,
    category: AvatarCategory,
    hasPhoto: Bool,
    color: NodeAvatarColor?,
    @ViewBuilder preview: @escaping (NodeAvatarColor?) -> Preview,
    onDone: @escaping (NodeAvatarColor?) -> Void
  ) {
    self.name = name
    self.category = category
    self.hasPhoto = hasPhoto
    self.preview = preview
    self.onDone = onDone
    _selection = State(initialValue: color)
    if case let .custom(rgb) = color {
      _customRGB = State(initialValue: rgb)
    } else {
      _customRGB = State(initialValue: AvatarCategory.radio.rgb)
    }
  }

  var body: some View {
    NavigationStack {
      CardForm {
        previewCard

        CardFormSection(footer: footer) {
          ContentCard {
            VStack(spacing: 16) {
              automaticRow
              LazyVGrid(columns: columns, spacing: 12) {
                ForEach(NodeAvatarColor.pickerSwatches, id: \.self) { swatch in
                  swatchButton(swatch)
                }
              }
              Divider()
              customRow
            }
          }
        }
      }
      .flashingNavigationTitle(L10n.Contacts.Contacts.AvatarColor.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Contacts.Contacts.Common.cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) {
            onDone(selection)
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  /// The avatar and the name in the chosen colour, as a sender name shows it in a channel.
  private var previewCard: some View {
    HStack(spacing: 14) {
      preview(selection)
        .frame(width: Self.previewSize, height: Self.previewSize)
        .accessibilityHidden(true)
      Text(name)
        .font(.headline)
        .foregroundStyle(theme.nameColor(selection, category: category, colorScheme: colorScheme, contrast: colorSchemeContrast))
        .lineLimit(2)
      Spacer(minLength: 0)
    }
    .cardSurface()
    .accessibilityElement(children: .combine)
  }

  private var footer: String {
    hasPhoto ? L10n.Contacts.Contacts.AvatarColor.photoFooter : L10n.Contacts.Contacts.AvatarColor.automaticFooter
  }

  private var automaticRow: some View {
    Button {
      selection = nil
    } label: {
      HStack {
        Label(L10n.Contacts.Contacts.AvatarColor.automatic, systemImage: "wand.and.stars")
          .foregroundStyle(Color.primary)
        Spacer()
        if selection == nil {
          Image(systemName: "checkmark")
            .fontWeight(.semibold)
            .foregroundStyle(theme.accentColor)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selection == nil ? .isSelected : [])
  }

  /// Picks the last custom colour; the well opens the system picker for a new one.
  private var customRow: some View {
    let isSelected = if case .custom = selection { true } else { false }
    return HStack {
      Button {
        selection = .custom(rgb: customRGB)
      } label: {
        HStack {
          Label(L10n.Contacts.Contacts.AvatarColor.custom, systemImage: "eyedropper")
            .foregroundStyle(Color.primary)
          Spacer()
          if isSelected {
            Image(systemName: "checkmark")
              .fontWeight(.semibold)
              .foregroundStyle(theme.accentColor)
          }
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      ColorPicker(L10n.Contacts.Contacts.AvatarColor.custom, selection: customColor, supportsOpacity: false)
        .labelsHidden()
    }
  }

  /// The picker's colour; a new pick becomes the selection.
  private var customColor: Binding<Color> {
    Binding {
      Color(hex: customRGB)
    } set: { color in
      customRGB = Self.rgb(of: color)
      selection = .custom(rgb: customRGB)
    }
  }

  /// A picked colour as 0xRRGGBB in sRGB, clamping wide-gamut components.
  private static func rgb(of color: Color) -> Int {
    var cgColor = UIColor(color).cgColor
    if let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
       let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil) {
      cgColor = converted
    }
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    UIColor(cgColor: cgColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let byte = { (component: CGFloat) in Int((min(max(component, 0), 1) * 255).rounded()) }
    return byte(red) << 16 | byte(green) << 8 | byte(blue)
  }

  private func swatchButton(_ swatch: NodeAvatarColor) -> some View {
    let fill = theme.swatchFill(swatch, colorScheme: colorScheme, contrast: colorSchemeContrast)
    let glyph = theme.avatarGlyphColor(forFill: fill, swatch: swatch, colorScheme: colorScheme, contrast: colorSchemeContrast)
    let isSelected = selection == swatch
    return Button {
      selection = swatch
    } label: {
      AvatarPebble()
        .fill(fill)
        .frame(width: Self.swatchSize, height: Self.swatchSize)
        .overlay {
          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(glyph)
          } else if case let .category(category) = swatch {
            // A type colour wears its type's glyph, so it reads as that type's colour.
            category.glyph
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(glyph)
          }
        }
        .overlay {
          AvatarPebble()
            .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 2)
            .padding(-4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(swatch.localizedName)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

extension NodeAvatarColor {
  /// The hue swatches and the category colours as one turn of the wheel, ordered by hue.
  static let pickerSwatches: [NodeAvatarColor] = [
    .red, .orange, .amber, .lime, .category(.companion), .teal, .category(.channel), .sky,
    .category(.radio), .category(.repeater), .purple, .category(.room),
  ]

  /// The swatch's name, for VoiceOver.
  var localizedName: String {
    switch self {
    case .red: L10n.Contacts.Contacts.AvatarColor.Swatch.red
    case .orange: L10n.Contacts.Contacts.AvatarColor.Swatch.orange
    case .amber: L10n.Contacts.Contacts.AvatarColor.Swatch.amber
    case .lime: L10n.Contacts.Contacts.AvatarColor.Swatch.lime
    case .teal: L10n.Contacts.Contacts.AvatarColor.Swatch.teal
    case .sky: L10n.Contacts.Contacts.AvatarColor.Swatch.sky
    case .purple: L10n.Contacts.Contacts.AvatarColor.Swatch.purple
    case .category(.companion): L10n.Contacts.Contacts.AvatarColor.Category.companion
    case .category(.repeater): L10n.Contacts.Contacts.AvatarColor.Category.repeater
    case .category(.room): L10n.Contacts.Contacts.AvatarColor.Category.room
    case .category(.channel): L10n.Contacts.Contacts.AvatarColor.Category.channel
    case .category(.radio): L10n.Contacts.Contacts.AvatarColor.Category.radio
    case .custom: L10n.Contacts.Contacts.AvatarColor.custom
    }
  }
}

extension AvatarCategory {
  /// The glyph the category's avatars wear without a photo.
  var glyph: Image {
    switch self {
    case .companion, .radio: Image(AppTab.home.symbolName)
    case .repeater: Image("cairn.repeater.fill")
    case .room: Image(systemName: "door.left.hand.closed")
    case .channel: Image(systemName: "number")
    }
  }
}
