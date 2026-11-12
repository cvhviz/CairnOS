import CairnServices
import SwiftUI

/// Battery curve configuration as a card-form section: the preset as a picker card, and the
/// curve with its eleven values folded into a card below it.
/// Pure UI component - caller provides data and save callback. Place it in a `CardForm` (or any
/// vertical stack on the card canvas); it draws its own title and cards.
struct BatteryCurveSection: View {
  let availablePresets: [OCVPreset]
  let headerText: String
  let footerText: String
  /// Explanation behind an "i" beside the header, for callers that don't want a footer paragraph.
  var infoText: String?

  @Binding var selectedPreset: OCVPreset
  @Binding var voltageValues: [Int]

  let onSave: (OCVPreset, [Int]) async -> Void
  var isDisabled: Bool = false

  @State private var isEditingValues = false
  @State private var validationError: String?

  var body: some View {
    CardFormSection(
      headerText.isEmpty ? nil : headerText,
      info: headerText.isEmpty ? nil : infoText,
      footer: footerText.isEmpty ? nil : footerText
    ) {
      PickerCard(
        L10n.Settings.BatteryCurve.preset,
        systemImage: "chart.xyaxis.line",
        color: .green,
        selection: userPresetSelection
      ) {
        ForEach(availablePresets, id: \.self) { preset in
          Text(preset.displayName).tag(preset)
        }
        if selectedPreset == .custom, !availablePresets.contains(.custom) {
          Text(L10n.Settings.BatteryCurve.custom).tag(OCVPreset.custom)
        }
      }
      .dimmedWhenDisabled()
      .disabled(isDisabled)

      // The curve and its values fold away together: the preset is the everyday choice, the
      // tall chart and eleven fields are for the rare custom curve.
      ContentCard {
        DisclosureGroup(isExpanded: $isEditingValues) {
          VStack(alignment: .leading, spacing: 8) {
            BatteryCurveChart(ocvArray: voltageValues)
            VoltageFieldsGrid(
              voltageValues: $voltageValues,
              validationError: $validationError,
              onCommit: handleCommit
            )
          }
          .padding(.top, 8)
        } label: {
          SettingCardLabel(L10n.Settings.BatteryCurve.editValues, systemImage: "slider.horizontal.3", color: .gray)
        }
      }
      .dimmedWhenDisabled()
      .disabled(isDisabled)

      // Outside the fold, so a rejected edit stays explained after the values are collapsed.
      if let error = validationError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.horizontal, 4)
      }
    }
  }

  /// The picker's selection. Saving lives in the setter rather than an `onChange` of the preset,
  /// so only a user's pick writes: the caller loading the stored preset into the binding (on
  /// every visit, and on reconnect) must not save it straight back.
  private var userPresetSelection: Binding<OCVPreset> {
    Binding(
      get: { selectedPreset },
      set: { newValue in
        guard newValue != selectedPreset else { return }
        selectedPreset = newValue
        guard newValue != .custom else { return }
        voltageValues = newValue.ocvArray
        Task {
          await onSave(newValue, newValue.ocvArray)
        }
      }
    )
  }

  private func handleCommit() {
    if let error = validateVoltageValues() {
      validationError = error
      return
    }
    validationError = nil

    // A commit whose values still match the selected preset is a no-op (e.g. focus
    // left a field just after a preset switch replaced the values); reclassifying
    // it as a custom curve would flip the picker and re-save identical values.
    if selectedPreset != .custom, voltageValues == selectedPreset.ocvArray {
      return
    }

    selectedPreset = .custom
    Task {
      await onSave(.custom, voltageValues)
    }
  }

  private func validateVoltageValues() -> String? {
    for (index, value) in voltageValues.enumerated() {
      if !OCVPreset.validMillivoltRange.contains(value) {
        return L10n.Settings.BatteryCurve.Validation.outOfRange((10 - index) * 10)
      }
    }

    for (current, next) in zip(voltageValues, voltageValues.dropFirst()) where current <= next {
      return L10n.Settings.BatteryCurve.Validation.notDescending
    }

    return nil
  }
}

/// Grid of voltage input fields
struct VoltageFieldsGrid: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Binding var voltageValues: [Int]
  @Binding var validationError: String?
  let onCommit: () -> Void

  /// Two columns, one at accessibility sizes so the fields keep room for four digits.
  private var columns: [GridItem] {
    dynamicTypeSize.isAccessibilitySize
      ? [GridItem(.flexible())]
      : [GridItem(.flexible()), GridItem(.flexible())]
  }

  var body: some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(0..<11, id: \.self) { index in
        VoltageField(
          percent: (10 - index) * 10,
          value: $voltageValues[index],
          hasError: fieldHasError(at: index),
          onCommit: onCommit
        )
      }
    }
    .padding(.vertical, 8)
  }

  private func fieldHasError(at index: Int) -> Bool {
    let value = voltageValues[index]
    if !OCVPreset.validMillivoltRange.contains(value) { return true }
    if index > 0, voltageValues[index - 1] <= value { return true }
    if index < 10, value <= voltageValues[index + 1] { return true }
    return false
  }
}

/// Individual voltage input field. Commits when focus leaves the field (or on submit),
/// not per keystroke, so transient mid-edit values never reach the device.
struct VoltageField: View {
  let percent: Int
  @Binding var value: Int
  let hasError: Bool
  let onCommit: () -> Void

  @FocusState private var isFocused: Bool
  @State private var valueWhenFocused: Int?
  /// Fits "100 %" in every locale's percent format, growing with the text size.
  @ScaledMetric(relativeTo: .caption) private var percentLabelWidth: CGFloat = 44

  var body: some View {
    HStack {
      Text((Double(percent) / 100).formatted(.percent))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(minWidth: percentLabelWidth, alignment: .trailing)
        .fixedSize()
        .accessibilityHidden(true)

      TextField("", value: $value, format: .number)
        .keyboardType(.numberPad)
        .textFieldStyle(.roundedBorder)
        .focused($isFocused)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(hasError ? .red : .clear, lineWidth: 1)
        )
        .onChange(of: isFocused) { _, focused in
          if focused {
            valueWhenFocused = value
          } else {
            commitEdit()
            valueWhenFocused = nil
          }
        }
        .onSubmit(commitEdit)
        .accessibilityLabel(L10n.Settings.BatteryCurve.Accessibility.voltageLabel(percent))
        .accessibilityValue(L10n.Settings.BatteryCurve.Accessibility.voltageValue(value))
        .accessibilityHint(L10n.Settings.BatteryCurve.Accessibility.voltageHint)

      Text(L10n.Settings.BatteryCurve.mv)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func commitEdit() {
    guard valueWhenFocused != value else { return }
    valueWhenFocused = value
    onCommit()
  }
}

#Preview {
  @Previewable @State var preset: OCVPreset = .liIon
  @Previewable @State var values: [Int] = OCVPreset.liIon.ocvArray

  NavigationStack {
    CardForm {
      BatteryCurveSection(
        availablePresets: OCVPreset.selectablePresets,
        headerText: "Battery Curve",
        footerText: "Configure the voltage-to-percentage curve for your device's battery.",
        selectedPreset: $preset,
        voltageValues: $values,
        onSave: { _, _ in }
      )
    }
  }
}
