import CairnServices
import SwiftUI

/// The nodes hidden from the Map tab, reached from the map's filter menu. Each Hide from Map asks
/// first (`hideFromMapConfirmation`) and points here, where it is undone.
struct HiddenMapNodesSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  let nodes: [HiddenMapNode]
  let onShow: (HiddenMapNode) -> Void
  let onShowAll: () -> Void

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(nodes) { node in
            row(for: node)
              .cardListRow(theme)
          }
        } footer: {
          Text(L10n.Map.Map.HiddenNodes.footer)
        }
      }
      .cardListCanvas(theme)
      .flashingNavigationTitle(L10n.Map.Map.HiddenNodes.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(L10n.Map.Map.HiddenNodes.showAll, action: onShowAll)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Map.Map.Common.done) {
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private func row(for node: HiddenMapNode) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        Image(systemName: node.type.iconSystemName)
          .foregroundStyle(node.type.displayColor)
          .frame(width: 28)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(node.name)
          Text(kindLine(for: node))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)

      Button(L10n.Map.Map.HiddenNodes.show, systemImage: "eye") {
        onShow(node)
      }
      .font(.caption.weight(.medium))
      .buttonStyle(.borderless)
      .accessibilityHint(node.name)
    }
  }

  private func kindLine(for node: HiddenMapNode) -> String {
    guard node.isDiscovered else { return node.type.localizedName }
    return "\(node.type.localizedName) · \(L10n.Map.Map.Callout.discovered)"
  }
}

// MARK: - Preview

#Preview {
  HiddenMapNodesSheet(
    nodes: [
      HiddenMapNode(publicKey: Data([0x01]), name: "Alice", type: .chat, isDiscovered: false),
      HiddenMapNode(publicKey: Data([0x02]), name: "Hilltop", type: .repeater, isDiscovered: true)
    ],
    onShow: { _ in },
    onShowAll: {}
  )
}
