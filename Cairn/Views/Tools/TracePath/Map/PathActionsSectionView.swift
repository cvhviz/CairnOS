import CairnServices
import SwiftUI

/// The trace options as card rows: return path, batch runs, hash size, the path string to copy,
/// and Clear Path. Rows rather than `ToggleCard`s because they sit in the trace `List`, which
/// paints each row as a card (`cardListRow`).
struct PathActionsSectionView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @Bindable var viewModel: TracePathViewModel
  @Binding var showingClearConfirmation: Bool
  @Binding var copyHapticTrigger: Int

  var body: some View {
    if !viewModel.outboundPath.isEmpty {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Toggle(isOn: $viewModel.autoReturnPath) {
            SettingCardLabel(
              L10n.Contacts.Contacts.Trace.List.autoReturn,
              systemImage: "arrow.uturn.backward",
              color: .blue,
              subtitle: L10n.Contacts.Contacts.Trace.List.autoReturnDescription
            )
          }
          // Without the way back, only this radio hearing the last hop directly gets the result.
          if !viewModel.autoReturnPath {
            Text(L10n.Contacts.Contacts.Trace.List.rangeWarning)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .cardListRow(theme)

        VStack(alignment: .leading, spacing: 12) {
          Toggle(isOn: $viewModel.batchEnabled) {
            SettingCardLabel(
              L10n.Contacts.Contacts.Trace.List.batchTrace,
              systemImage: "square.stack.3d.up",
              color: .purple,
              subtitle: L10n.Contacts.Contacts.Trace.List.batchTraceDescription
            )
          }

          if viewModel.batchEnabled {
            HStack(spacing: 12) {
              Text(L10n.Contacts.Contacts.Trace.List.traces)
                .foregroundStyle(.secondary)
              Spacer()
              BatchSizeChip(size: 3, selectedSize: $viewModel.batchSize)
              BatchSizeChip(size: 5, selectedSize: $viewModel.batchSize)
            }
          }
        }
        // The mode, count, and hop width belong to the run in flight; changing them under it
        // would leave its progress and results describing a different trace.
        .disabled(viewModel.isRunning)
        .cardListRow(theme)

        if appState.connectedDevice?.supportsTraceHashSizeOverride == true {
          hashSizeRow
            .cardListRow(theme)
        } else if viewModel.effectiveTraceMode > 0 {
          // No per-trace picker, but the radio's own hash mode is wide: the same caveat applies
          // (repeaters before 1.11.0 read one-byte trace hashes only).
          Text(L10n.Contacts.Contacts.Trace.List.hashSizeFooter)
            .font(.caption)
            .foregroundStyle(.secondary)
            .cardListRow(theme)
        }

        HStack(spacing: 12) {
          IconTile(systemImage: "point.topleft.down.to.point.bottomright.curvepath", color: .teal)
            .accessibilityHidden(true)
          Text(viewModel.fullPathString)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

          Spacer(minLength: 8)

          Button(L10n.Contacts.Contacts.Trace.List.copyPath, systemImage: "doc.on.doc") {
            copyHapticTrigger += 1
            viewModel.copyPathToClipboard()
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
        }
        .cardListRow(theme)

        Button(role: .destructive) {
          showingClearConfirmation = true
        } label: {
          HStack(spacing: 12) {
            IconTile(systemImage: "trash", color: .red)
              .accessibilityHidden(true)
            Text(L10n.Contacts.Contacts.Trace.clearPath)
              .foregroundStyle(Color.red)
            Spacer(minLength: 0)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cardListRow(theme)
      }
    }
  }

  /// The hash width picker, with the firmware caveat under it while a wider hash is chosen: it
  /// stays visible because older repeaters silently drop those traces.
  private var hashSizeRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        SettingCardLabel(L10n.Contacts.Contacts.Trace.List.hashSize, systemImage: "number", color: .gray)
          .accessibilityHidden(true)
        Spacer(minLength: 8)
        Picker(L10n.Contacts.Contacts.Trace.List.hashSize, selection: Binding(
          get: { viewModel.effectiveTraceMode },
          set: { viewModel.setTraceHashMode($0) }
        )) {
          Text(L10n.Contacts.Contacts.Trace.List.hashSizeOneByte).tag(UInt8(0))
          Text(L10n.Contacts.Contacts.Trace.List.hashSizeTwoBytes).tag(UInt8(1))
          Text(L10n.Contacts.Contacts.Trace.List.hashSizeFourBytes).tag(UInt8(2))
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(viewModel.isRunning)
      }

      if viewModel.effectiveTraceMode > 0 {
        Text(L10n.Contacts.Contacts.Trace.List.hashSizeFooter)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
