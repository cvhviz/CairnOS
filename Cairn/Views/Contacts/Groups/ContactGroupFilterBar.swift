import CairnServices
import SwiftUI

/// Replaces the Nodes segment bar while a group filter is active: shows the group as a
/// pill with a menu (switch group, message group) and a clear button.
struct ContactGroupFilterBar: View {
  private static let minimumTapTarget: CGFloat = 44

  let group: ContactGroup
  let viewModel: ContactsViewModel

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        ContactGroupFilterMenuItems(viewModel: viewModel)
        Divider()
        Button {
          viewModel.broadcastGroup = group
        } label: {
          Label(L10n.Contacts.Contacts.Groups.message, systemImage: "paperplane")
        }
      } label: {
        HStack(spacing: 8) {
          ContactGroupIcon(group: group, size: 20)
          Text(group.name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .contentShape(.capsule)
      }
      .buttonStyle(.plain)
      .groupFilterPillBackground(tint: group.tint)

      Button {
        withAnimation { viewModel.selectedGroupID = nil }
      } label: {
        Image(systemName: "xmark")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 30, height: 30)
          .contentShape(.circle)
      }
      .buttonStyle(.plain)
      .groupFilterPillBackground(tint: nil, circle: true)
      .accessibilityLabel(L10n.Contacts.Contacts.Groups.allNodes)
      // Invisible and behind the circle: it overflows to a 44 pt target while the glass
      // circle and the bar keep their size.
      .background {
        Button {
          withAnimation { viewModel.selectedGroupID = nil }
        } label: {
          Color.clear
            .frame(width: Self.minimumTapTarget, height: Self.minimumTapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.top, 4)
    .padding(.bottom, 8)
  }
}

/// Menu items that pick the Nodes list's group filter; shared by the toolbar menu and the pill.
struct ContactGroupFilterMenuItems: View {
  let viewModel: ContactsViewModel

  private let store = ContactGroupStore.shared

  var body: some View {
    Picker(L10n.Contacts.Contacts.Groups.filter, selection: Binding(
      get: { viewModel.selectedGroup?.id },
      set: { newValue in withAnimation { viewModel.selectedGroupID = newValue } }
    )) {
      Label(L10n.Contacts.Contacts.Groups.allNodes, systemImage: "circle.grid.2x2")
        .tag(UUID?.none)
      ForEach(store.groups) { group in
        Label(group.name, systemImage: group.symbol)
          .tag(UUID?.some(group.id))
      }
    }
    .pickerStyle(.inline)
  }
}

private extension View {
  @ViewBuilder
  func groupFilterPillBackground(tint: Color?, circle: Bool = false) -> some View {
    if #available(iOS 26.0, *) {
      if circle {
        glassEffect(.regular.interactive(), in: .circle)
      } else {
        glassEffect(.regular.tint(tint?.opacity(0.25)).interactive(), in: .capsule)
      }
    } else if circle {
      background(.quaternary, in: .circle)
    } else {
      background((tint ?? .secondary).opacity(0.18), in: .capsule)
    }
  }
}
