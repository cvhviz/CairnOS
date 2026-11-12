import SwiftUI

private enum BarMetrics {
  static let height: CGFloat = 44
  static let keySpacing: CGFloat = 12
}

struct CLIInputAccessoryView: View {
  let isWaiting: Bool
  var showSessionsButton: Bool = true
  let onHistoryUp: () -> Void
  let onHistoryDown: () -> Void
  let onTabComplete: () -> Void
  let onMoveLeft: () -> Void
  let onMoveRight: () -> Void
  let onPaste: () -> Void
  let onSessions: () -> Void
  let onCancel: () -> Void
  let onDismiss: () -> Void
  /// Opens a command list; its key shows only when set, and is off while a command is in flight.
  var onCommands: (() -> Void)?

  @State private var showCancel = false

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        // The gaps between keys belong to the keys' hit areas, so the stack itself adds none.
        HStack(spacing: 0) {
          Button(action: onTabComplete) {
            Image(systemName: "arrow.right.to.line")
              .keyHitArea()
          }
          .accessibilityLabel(L10n.Tools.Tools.Cli.tabComplete)

          Button(action: onHistoryUp) {
            Image(systemName: "arrow.up")
              .keyHitArea()
          }
          .accessibilityLabel(L10n.Tools.Tools.Cli.historyUp)

          Button(action: onHistoryDown) {
            Image(systemName: "arrow.down")
              .keyHitArea()
          }
          .accessibilityLabel(L10n.Tools.Tools.Cli.historyDown)

          Button(action: onMoveLeft) {
            Image(systemName: "arrow.left")
              .keyHitArea()
          }
          .accessibilityLabel(L10n.Tools.Tools.Cli.cursorLeft)

          Button(action: onMoveRight) {
            Image(systemName: "arrow.right")
              .keyHitArea()
          }
          .accessibilityLabel(L10n.Tools.Tools.Cli.cursorRight)

          Button(action: onPaste) {
            Image(systemName: "doc.on.clipboard")
              .keyHitArea()
          }
          .accessibilityLabel(L10n.Tools.Tools.Cli.paste)

          if let onCommands {
            Button(action: onCommands) {
              Image(systemName: "list.bullet.rectangle")
                .keyHitArea()
            }
            // One command at a time, as the toolbar's Commands button.
            .disabled(isWaiting)
            .accessibilityLabel(L10n.Tools.Tools.Cli.Companion.commands)
          }

          if showSessionsButton {
            Divider()
              .frame(height: 20)
              .padding(.horizontal, BarMetrics.keySpacing / 2)

            Button(action: onSessions) {
              Image(systemName: "rectangle.stack")
                .keyHitArea()
            }
            .accessibilityLabel(L10n.Tools.Tools.Cli.sessions)
          }

          Button(action: onCancel) {
            Image(systemName: "stop.circle")
              .foregroundStyle(showCancel ? .red : .secondary)
              .keyHitArea()
          }
          .disabled(!showCancel)
          .accessibilityLabel(L10n.Tools.Tools.Cli.cancelOperation)
        }
        .font(.body)
        .padding(.horizontal, -BarMetrics.keySpacing / 2)
      }

      Spacer()

      Button(action: onDismiss) {
        Image(systemName: "keyboard.chevron.compact.down")
          .frame(minWidth: BarMetrics.height, minHeight: BarMetrics.height, alignment: .trailing)
          .contentShape(.rect)
      }
      .font(.body)
      .accessibilityLabel(L10n.Tools.Tools.Cli.dismiss)
    }
    .padding(.horizontal)
    .frame(height: BarMetrics.height)
    .task(id: isWaiting) {
      if isWaiting {
        try? await Task.sleep(for: .milliseconds(150))
        showCancel = true
      } else {
        showCancel = false
      }
    }
    .background {
      if #available(iOS 26.0, *) {
        Rectangle().fill(.clear).glassEffect()
      } else {
        Rectangle().fill(.ultraThinMaterial)
      }
    }
    .padding(.horizontal, 4)
  }
}

private extension View {
  /// Extends a bar key's hit area to the full bar height and halfway to each neighbour. The keys
  /// sit on a pitch of about 32 points, so a 44 point width would overlap the key next door.
  func keyHitArea() -> some View {
    padding(.horizontal, BarMetrics.keySpacing / 2)
      .frame(minHeight: BarMetrics.height)
      .contentShape(.rect)
  }
}

#Preview {
  CLIInputAccessoryView(
    isWaiting: false,
    onHistoryUp: {},
    onHistoryDown: {},
    onTabComplete: {},
    onMoveLeft: {},
    onMoveRight: {},
    onPaste: {},
    onSessions: {},
    onCancel: {},
    onDismiss: {}
  )
}
