import CairnServices
import MeshCore
import SwiftUI

/// The radio parameters edited in a sheet rather than a menu, because they're numbers, not choices.
enum RadioValueEditor: String, Identifiable {
  case frequency
  case txPower

  var id: String { rawValue }
}

/// Edits the staged frequency. Done hands the value back to the tile; nothing reaches the radio
/// until Apply, which validates the range as it always has.
struct RadioFrequencyEditor: View {
  @Environment(\.dismiss) private var dismiss
  let onDone: (Double?) -> Void
  @State private var draft: Double?
  @FocusState private var isFocused: Bool

  init(frequency: Double?, onDone: @escaping (Double?) -> Void) {
    self.onDone = onDone
    _draft = State(initialValue: frequency)
  }

  var body: some View {
    NavigationStack {
      CardForm {
        CardFormSection(footer: L10n.Settings.AdvancedRadio.footer) {
          ContentCard {
            HStack {
              // The field carries the label for VoiceOver; the visible one would be a second,
              // orphaned element, and the placeholder ("MHz") alone doesn't say what it is.
              SettingCardLabel(L10n.Settings.AdvancedRadio.frequency, systemImage: "waveform", color: .blue)
                .accessibilityHidden(true)
              Spacer()
              DecimalTextField(
                title: L10n.Settings.AdvancedRadio.frequencyPlaceholder,
                value: draft,
                onChange: { draft = $0 }
              )
              .frame(minWidth: 100)
              .focused($isFocused)
              .accessibilityLabel(L10n.Settings.AdvancedRadio.frequency)
            }
          }
        }
      }
      .flashingNavigationTitle(L10n.Settings.Radio.Tile.frequency)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) {
            onDone(draft)
            dismiss()
          }
          .disabled(draft == nil)
        }
      }
      .onAppear { isFocused = true }
    }
    .presentationDetents([.medium, .large])
  }
}

/// Edits the staged TX power within what the radio allows: a slider for a quick change and a
/// stepper for an exact one. Done hands the value back to the tile; Apply sends it. The value is the
/// radio chip's setting (-9 to the radio's reported maximum); on a board with a known amplifier the
/// headline is the power at the antenna for it and the controls are titled "Radio setting".
struct RadioTxPowerEditor: View {
  @Environment(\.dismiss) private var dismiss
  let range: ClosedRange<Int>
  /// The radio's model string: boards with an amplifier show the power at the antenna too (`RadioAmplifier`).
  let model: String
  let onDone: (Int) -> Void
  @State private var draft: Int

  init(txPower: Int, maximum: Int, model: String, onDone: @escaping (Int) -> Void) {
    let floor = Int(PacketBuilder.txPowerFloor)
    let range = floor...max(maximum, floor)
    self.range = range
    self.model = model
    self.onDone = onDone
    _draft = State(initialValue: min(max(txPower, range.lowerBound), range.upperBound))
  }

  private func dBm(_ value: Int) -> String {
    L10n.Settings.DeviceInfo.txPowerFormat(value.formatted())
  }

  private var amplified: Bool { RadioAmplifier.hasAmplifier(model: model) }

  /// "Max 28 dBm at antenna (setting 16 dBm)" on an amplified board, else "Max 22 dBm".
  private var footer: String {
    guard amplified else { return L10n.Settings.Dashboard.maxTxPower(dBm(range.upperBound)) }
    return L10n.Settings.Radio.TxPower.maxAtAntenna(
      dBm(RadioAmplifier.antennaMaxTxPower(reportedMax: range.upperBound, model: model)),
      dBm(range.upperBound)
    )
  }

  var body: some View {
    NavigationStack {
      CardForm {
        CardFormSection(footer: footer) {
          ContentCard {
            VStack(alignment: .leading, spacing: 2) {
              let shown = RadioAmplifier.effectiveTxPower(reported: draft, model: model)
              Text(dBm(shown))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .contentTransition(.numericText(value: Double(shown)))
              if amplified {
                Text(L10n.Settings.Radio.TxPower.antennaCaption(dBm(draft)))
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
            }
            .accessibilityElement(children: .combine)

            Slider(
              value: Binding(
                get: { Double(draft) },
                set: { draft = Int($0.rounded()) }
              ),
              in: Double(range.lowerBound)...Double(range.upperBound),
              step: 1
            ) {
              Text(L10n.Settings.Dashboard.txPower)
            } minimumValueLabel: {
              Text(range.lowerBound.formatted())
            } maximumValueLabel: {
              Text(range.upperBound.formatted())
            }
            .accessibilityValue(dBm(draft))

            Divider()

            Stepper(value: $draft, in: range) {
              Text(amplified ? L10n.Settings.Radio.TxPower.radioSettingLabel : L10n.Settings.AdvancedRadio.txPower)
            }
            .accessibilityValue(dBm(draft))
          }
        }
      }
      .flashingNavigationTitle(L10n.Settings.Dashboard.txPower)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Localizable.Common.cancel) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Localizable.Common.done) {
            onDone(draft)
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}
