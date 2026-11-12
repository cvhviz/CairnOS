import SwiftUI

/// One reading on a dashboard: what it is, its value, and a line of context, with an optional
/// meter under the value. The value is the loud part; everything else stays quiet around it.
struct MetricTile<Accessory: View>: View {
  let title: String
  let systemImage: String
  let value: String
  let caption: String?
  /// Colors the value for a status reading (a low battery, a weak signal). Leave nil for plain
  /// figures; the caption or meter should still carry the state for anyone who can't see color.
  let valueTint: Color?
  /// A symbol after the title that flags the reading, such as a warning triangle. Pair it with a
  /// caption that says what's wrong; the symbol alone is decoration for VoiceOver.
  let statusSymbol: String?
  let statusTint: Color
  /// Shows a chevron, for a tile that opens the page behind its reading. The caller supplies the
  /// `NavigationLink` or `Button` around the tile.
  let showsDisclosure: Bool
  @ViewBuilder let accessory: () -> Accessory

  static var cornerRadius: CGFloat { CardStyle.cornerRadius }

  init(
    _ title: String,
    systemImage: String,
    value: String,
    caption: String? = nil,
    valueTint: Color? = nil,
    statusSymbol: String? = nil,
    statusTint: Color = .orange,
    showsDisclosure: Bool = false,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.title = title
    self.systemImage = systemImage
    self.value = value
    self.caption = caption
    self.valueTint = valueTint
    self.statusSymbol = statusSymbol
    self.statusTint = statusTint
    self.showsDisclosure = showsDisclosure
    self.accessory = accessory
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        Image(systemName: systemImage)
        Text(title)
          .lineLimit(1)
        if statusSymbol != nil || showsDisclosure {
          Spacer(minLength: 0)
        }
        if let statusSymbol {
          Image(systemName: statusSymbol)
            .foregroundStyle(statusTint)
        }
        if showsDisclosure {
          Image(systemName: "chevron.right")
            .fontWeight(.semibold)
            .foregroundStyle(Color(.tertiaryLabel))
        }
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(Color.secondary)

      reading

      accessory()
    }
    .cardSurface(padding: 10)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue([value, caption].compactMap(\.self).joined(separator: ", "))
    .accessibilityAddTraits(showsDisclosure ? .isButton : [])
  }

  /// The value with its caption beside it when both fit on one line, which keeps the tile a line
  /// shorter; a long caption drops beneath the value instead of squeezing it.
  @ViewBuilder
  private var reading: some View {
    if let caption, !caption.isEmpty {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          valueText
            .fixedSize()
          captionText(caption)
            .lineLimit(1)
            .fixedSize()
        }
        VStack(alignment: .leading, spacing: 1) {
          valueText
          captionText(caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } else {
      valueText
    }
  }

  /// May narrow to fit a long value on one line, but never gives up height to do it: without
  /// this a tile with a meter squeezes its value smaller than its neighbours'.
  private var valueText: some View {
    Text(value)
      .font(.title3.weight(.semibold))
      .foregroundStyle(valueTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.primary))
      .lineLimit(1)
      .minimumScaleFactor(0.6)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func captionText(_ caption: String) -> some View {
    Text(caption)
      .font(.caption2)
      .foregroundStyle(Color.secondary)
  }
}

extension MetricTile where Accessory == EmptyView {
  /// A tile without a meter or other accessory under its value.
  init(
    _ title: String,
    systemImage: String,
    value: String,
    caption: String? = nil,
    valueTint: Color? = nil,
    statusSymbol: String? = nil,
    statusTint: Color = .orange,
    showsDisclosure: Bool = false
  ) {
    self.init(
      title,
      systemImage: systemImage,
      value: value,
      caption: caption,
      valueTint: valueTint,
      statusSymbol: statusSymbol,
      statusTint: statusTint,
      showsDisclosure: showsDisclosure
    ) {
      EmptyView()
    }
  }
}

/// A thin capacity bar: the filled part in `tint`, the rest a lighter step of the same color so
/// the state reads across the whole bar.
struct MeterBar: View {
  /// Filled share, 0 to 1.
  let fraction: Double
  let tint: Color

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(tint.opacity(0.22))
        Capsule()
          .fill(tint)
          .frame(width: max(geometry.size.height, geometry.size.width * min(max(fraction, 0), 1)))
      }
    }
    .frame(height: 6)
    .padding(.vertical, 2)
    .accessibilityHidden(true)
  }
}
