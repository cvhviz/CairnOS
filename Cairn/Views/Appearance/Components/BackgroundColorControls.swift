import SwiftUI

/// Solid background: a row of preset swatches plus a picker for any custom color.
struct SolidBackgroundControls: View {
  @Binding var color: BackgroundColor

  var body: some View {
    PresetSwatchRow(
      presets: SolidBackgroundPreset.allCases,
      isSelected: { $0.color == color },
      name: \.localizedName,
      onSelect: { color = $0.color }
    ) { preset in
      preset.color.color
    }

    Divider()

    ColorPicker(selection: colorBinding($color), supportsOpacity: false) {
      SettingCardLabel(L10n.Settings.Appearance.Background.customColor, systemImage: "eyedropper", color: .gray)
    }
  }
}

/// Gradient background: presets, then the 2–3 colors, the style and (for a linear gradient) the
/// direction. A preset copies its colors in, so it is a starting point for further edits.
struct GradientBackgroundControls: View {
  @Binding var colors: [BackgroundColor]
  @Binding var style: AppBackground.GradientStyle
  @Binding var direction: AppBackground.GradientDirection

  var body: some View {
    PresetSwatchRow(
      presets: GradientBackgroundPreset.allCases,
      isSelected: { $0.colors == colors },
      name: \.localizedName,
      onSelect: { colors = $0.colors }
    ) { preset in
      BackgroundGradientView(colors: preset.colors, style: style, direction: direction)
    }

    // Laid out on one card (ContentCard), so dividers stand in for list row separators.
    Divider()

    ForEach(colors.indices, id: \.self) { index in
      ColorPicker(selection: colorBinding(at: index), supportsOpacity: false) {
        Text(L10n.Settings.Appearance.Background.gradientColor(index + 1))
      }
      Divider()
    }

    Toggle(L10n.Settings.Appearance.Background.thirdColor, isOn: thirdColorBinding)

    Divider()

    Picker(L10n.Settings.Appearance.Background.Style.title, selection: $style) {
      ForEach(AppBackground.GradientStyle.allCases) { style in
        Text(style.localizedName).tag(style)
      }
    }
    .pickerStyle(.segmented)

    if style == .linear {
      Divider()
      // Outside a List a menu picker shows no title, so lay out the title beside it.
      HStack {
        Text(L10n.Settings.Appearance.Background.Direction.title)
        Spacer(minLength: 8)
        Picker(L10n.Settings.Appearance.Background.Direction.title, selection: $direction) {
          ForEach(AppBackground.GradientDirection.allCases) { direction in
            Text(direction.localizedName).tag(direction)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
      }
    }
  }

  private func colorBinding(at index: Int) -> Binding<Color> {
    Binding(
      get: { colors.indices.contains(index) ? colors[index].color : .black },
      set: { newValue in
        guard colors.indices.contains(index) else { return }
        colors[index] = BackgroundColor(newValue)
      }
    )
  }

  /// Adding a third color starts it as the blend of the first two, so the gradient does not
  /// jump; removing it keeps the first two.
  private var thirdColorBinding: Binding<Bool> {
    Binding(
      get: { colors.count >= 3 },
      set: { isOn in
        if isOn, colors.count == 2 {
          colors.insert(colors[0].mixed(with: colors[1], by: 0.5), at: 1)
        } else if !isOn, colors.count > 2 {
          colors = [colors[0], colors[colors.count - 1]]
        }
      }
    )
  }
}

/// Bridges a stored background color to the `Color` a `ColorPicker` edits.
private func colorBinding(_ color: Binding<BackgroundColor>) -> Binding<Color> {
  Binding(
    get: { color.wrappedValue.color },
    set: { color.wrappedValue = BackgroundColor($0) }
  )
}

/// A wrapping row of round preset swatches with a check on the selected one.
private struct PresetSwatchRow<Preset: Identifiable, Swatch: View>: View {
  let presets: [Preset]
  let isSelected: (Preset) -> Bool
  let name: KeyPath<Preset, String>
  let onSelect: (Preset) -> Void
  @ViewBuilder let swatch: (Preset) -> Swatch

  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 36

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.Settings.Appearance.Background.presets)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: max(size, 44)), spacing: 8)], spacing: 8) {
        ForEach(presets) { preset in
          Button {
            onSelect(preset)
          } label: {
            swatch(preset)
              .frame(width: size, height: size)
              .clipShape(Circle())
              .overlay { Circle().strokeBorder(Color(.separator), lineWidth: 0.5) }
              .overlay {
                if isSelected(preset) {
                  Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-4)
                }
              }
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(preset[keyPath: name])
          .accessibilityAddTraits(isSelected(preset) ? [.isSelected] : [])
        }
      }
    }
    .padding(.vertical, 4)
  }
}
