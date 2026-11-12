import SwiftUI

/// The four background kinds as cards, each showing a swatch of what it paints. The Photo card
/// asks the host to open the photo picker while no photo has been chosen yet.
struct BackgroundKindPicker: View {
  let selection: AppBackground.Kind
  let background: AppBackground
  let photo: UIImage?
  let isLoadingPhoto: Bool
  let onSelect: (AppBackground.Kind) -> Void
  /// Presents the photo picker (the host owns it, so Change Photo shares the same one).
  let onChoosePhoto: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var columns: [GridItem] {
    let count = dynamicTypeSize.isAccessibilitySize ? 2 : 4
    return Array(repeating: GridItem(.flexible(), spacing: CardStyle.spacing), count: count)
  }

  var body: some View {
    LazyVGrid(columns: columns, spacing: CardStyle.spacing) {
      ForEach(AppBackground.Kind.allCases) { kind in
        if kind == .image, photo == nil {
          Button(action: onChoosePhoto) {
            tile(for: kind)
          }
          .buttonStyle(.plain)
          .disabled(isLoadingPhoto)
          .accessibilityHint(L10n.Settings.Appearance.Background.Photo.choose)
        } else {
          Button {
            onSelect(kind)
          } label: {
            tile(for: kind)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func tile(for kind: AppBackground.Kind) -> some View {
    VStack(spacing: 6) {
      swatch(for: kind)
        .frame(height: Self.swatchHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.swatchCornerRadius, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: Self.swatchCornerRadius, style: .continuous)
            .strokeBorder(Color(.separator), lineWidth: 0.5)
        }
      Text(kind.localizedName)
        .font(.footnote.weight(kind == selection ? .semibold : .regular))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .cardSurface(isSelected: kind == selection, padding: 8)
    .cardInteractionShape()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.localizedName)
    .accessibilityAddTraits(kind == selection ? [.isButton, .isSelected] : .isButton)
  }

  @ViewBuilder
  private func swatch(for kind: AppBackground.Kind) -> some View {
    switch kind {
    case .system:
      // A grouped page with a card on it: the look the System background keeps.
      ZStack {
        Color(.systemGroupedBackground)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color(.secondarySystemGroupedBackground))
          .padding(10)
      }
    case .solid:
      background.solidColor.color
    case .gradient:
      BackgroundGradientView(
        colors: background.gradientColors,
        style: background.gradientStyle,
        direction: background.gradientDirection
      )
    case .image:
      if let photo {
        Color.clear.overlay {
          Image(uiImage: photo)
            .resizable()
            .scaledToFill()
        }
      } else {
        ZStack {
          Color(.tertiarySystemFill)
          if isLoadingPhoto {
            ProgressView()
          } else {
            Image(systemName: "photo.badge.plus")
              .font(.title3)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private static let swatchHeight: CGFloat = 56
  private static let swatchCornerRadius: CGFloat = 8
}
