import CairnServices
import SwiftUI

/// Where the Radio page's tuning read stands.
enum RadioTuningReadState: Equatable {
  case loading
  case loaded
  /// The firmware has no tuning commands.
  case unsupported
  case failed
}

/// The radio's flood timing, in a sheet from Settings → Radio's Tuning card: the RX delay base and
/// the airtime factor, each stepped and sent together by Apply, then read back to confirm. Reset
/// returns both to the firmware's defaults. The same two settings a repeater's Controls page sets
/// with `set rxdelay` and `set af`.
struct RadioTuningSection: View {
  @Environment(\.appState) private var appState
  @Environment(\.dismiss) private var dismiss

  @Binding var tuning: RadioTuning?
  let readState: RadioTuningReadState
  let onReload: () async -> Void
  /// Runs when the retry alert gives up, in place of dismissing this view.
  var onGiveUp: (() -> Void)?
  /// Reports a write in flight or its alert showing, so the sheet holds itself open.
  var onBusyChange: ((Bool) -> Void)?

  @State private var draft: RadioTuning?
  @State private var isApplying = false
  @State private var applied = false
  @State private var errorMessage: String?
  @State private var retryAlert = RetryAlertState()

  private static let rxDelayRange: ClosedRange<Double> = 0...20
  private static let airtimeRange: ClosedRange<Double> = 0...9
  private static let step = 0.5

  private var shown: RadioTuning? { draft ?? tuning }
  private var hasChanges: Bool { draft != nil && draft != tuning }

  var body: some View {
    CardFormSection(L10n.Settings.Radio.Tuning.header, info: L10n.Settings.Radio.Tuning.footer) {
      switch readState {
      case .loading where tuning == nil:
        ContentCard {
          HStack {
            ProgressView()
            Text(L10n.RemoteNodes.RemoteNodes.Settings.loading)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .unsupported:
        ContentCard {
          Label(L10n.Settings.Radio.Tuning.unsupported, systemImage: "info.circle")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .failed where tuning == nil:
        ContentCard {
          HStack {
            Label(L10n.RemoteNodes.RemoteNodes.Controls.failed, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
            Spacer()
            Button(L10n.RemoteNodes.RemoteNodes.Controls.retry) {
              Task { await onReload() }
            }
          }
        }
      default:
        if let shown {
          editor(shown)
        }
      }
    }
    .onChange(of: isBusy) { _, busy in onBusyChange?(busy) }
    .cairnFeedback(.success, trigger: applied)
    .errorAlert($errorMessage)
    .retryAlert(retryAlert)
  }

  private var isBusy: Bool {
    isApplying || errorMessage != nil || retryAlert.isPresented
  }

  @ViewBuilder
  private func editor(_ shown: RadioTuning) -> some View {
    ContentCard {
      VStack(alignment: .leading, spacing: 12) {
        row(
          title: L10n.Settings.Radio.Tuning.rxDelay,
          detail: L10n.Settings.Radio.Tuning.RxDelay.detail,
          systemImage: "hourglass",
          color: .teal,
          value: shown.rxDelayBase,
          range: Self.rxDelayRange,
          isChanged: draft.map { $0.rxDelayBase != tuning?.rxDelayBase } ?? false
        ) { newValue in
          var next = shown
          next.rxDelayBase = newValue
          draft = next
        }
        Divider()
        row(
          title: L10n.Settings.Radio.Tuning.airtimeFactor,
          detail: L10n.Settings.Radio.Tuning.AirtimeFactor.detail,
          systemImage: "timer",
          color: .orange,
          value: shown.airtimeFactor,
          range: Self.airtimeRange,
          isChanged: draft.map { $0.airtimeFactor != tuning?.airtimeFactor } ?? false
        ) { newValue in
          var next = shown
          next.airtimeFactor = newValue
          draft = next
        }
      }
    }

    VStack(spacing: 10) {
      Button {
        apply()
      } label: {
        Group {
          if isApplying {
            ProgressView()
          } else {
            Text(L10n.Settings.Radio.Tuning.apply)
          }
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .radioDisabled(for: appState.connectionState, or: !hasChanges || isApplying)

      if shown != .firmwareDefault {
        Button(L10n.Settings.Radio.Tuning.reset) {
          draft = .firmwareDefault
        }
        .buttonStyle(.borderless)
        .disabled(isApplying)
      }
    }
  }

  private func row(
    title: String,
    detail: String,
    systemImage: String,
    color: Color,
    value: Double,
    range: ClosedRange<Double>,
    isChanged: Bool,
    onChange: @escaping (Double) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        SettingCardLabel(title, systemImage: systemImage, color: color)
          .accessibilityHidden(true)
        Spacer(minLength: 8)
        Stepper(value: Binding(get: { value }, set: { onChange(min(range.upperBound, max(range.lowerBound, $0))) }), in: range, step: Self.step) {
          Text(Self.format(value))
            .font(.body.monospacedDigit())
            .foregroundStyle(isChanged ? Color.accentColor : Color.secondary)
            .contentTransition(.numericText(value: value))
        }
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(Self.format(value))
      }
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .animation(.snappy, value: value)
  }

  static func format(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
  }

  private func apply() {
    guard let draft else { return }
    isApplying = true
    Task {
      do {
        guard let settingsService = appState.services?.settingsService else {
          throw ConnectionError.notConnected
        }
        tuning = try await settingsService.setRadioTuningVerified(draft)
        self.draft = nil
        applied.toggle()
        retryAlert.reset()
      } catch let error as SettingsServiceError where error.isRetryable {
        retryAlert.show(
          message: error.userFacingMessage,
          onRetry: { apply() },
          onMaxRetriesExceeded: { onGiveUp?() ?? dismiss() }
        )
      } catch {
        errorMessage = error.userFacingMessage
      }
      isApplying = false
    }
  }
}
