import CairnServices
import SwiftUI

/// Card content letting the user save the current trace path: an action that opens an inline
/// name field. The caller paints the card.
struct SavePathRowView: View {
  @Bindable var viewModel: TracePathViewModel
  @Binding var saveHapticTrigger: Int

  @State private var showingSaveDialog = false
  @State private var savePathName = ""

  var body: some View {
    if showingSaveDialog {
      VStack(alignment: .leading, spacing: 8) {
        TextField(L10n.Contacts.Contacts.Trace.Map.pathName, text: $savePathName)
          .textFieldStyle(.roundedBorder)

        HStack {
          Button(L10n.Contacts.Contacts.Common.cancel) {
            showingSaveDialog = false
            savePathName = ""
          }
          .buttonStyle(.bordered)

          Spacer()

          Button(L10n.Contacts.Contacts.Common.save) {
            Task {
              let success = await viewModel.savePath(name: savePathName)
              if success {
                saveHapticTrigger += 1
              }
              showingSaveDialog = false
              savePathName = ""
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(savePathName.trimmingCharacters(in: .whitespaces).isEmpty || !viewModel.canSavePath)
        }
      }
      .padding(.vertical, 4)
    } else {
      Button {
        savePathName = viewModel.generatePathName()
        showingSaveDialog = true
      } label: {
        HStack(spacing: 12) {
          IconTile(systemImage: "bookmark", color: .orange)
            .accessibilityHidden(true)
          Text(L10n.Contacts.Contacts.Results.savePath)
            .foregroundStyle(Color.accentColor)
          Spacer(minLength: 0)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(!viewModel.canSavePath)
    }
  }
}
