import CairnServices
import SwiftUI

/// Creates a group, or edits an existing group's name, icon, and color.
struct ContactGroupEditorSheet: View {
  enum Mode {
    /// `initialMember` is added to the new group, e.g. when created from a node's menu.
    case create(initialMember: Data?)
    case edit(ContactGroup)
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  /// Smallest comfortable touch target; the grids size their cells to it.
  private static let minimumTapTarget: CGFloat = 44

  let mode: Mode

  @State private var name: String
  @State private var symbol: String
  @State private var color: String
  @FocusState private var isNameFocused: Bool

  private let store = ContactGroupStore.shared

  init(mode: Mode) {
    self.mode = mode
    switch mode {
    case .create:
      _name = State(initialValue: "")
      _symbol = State(initialValue: ContactGroup.defaultSymbol)
      _color = State(initialValue: ContactGroup.Palette.blue.rawValue)
    case let .edit(group):
      _name = State(initialValue: group.name)
      _symbol = State(initialValue: group.symbol)
      _color = State(initialValue: group.color)
    }
  }

  private var editingID: UUID? {
    if case let .edit(group) = mode { return group.id }
    return nil
  }

  private var isNameTaken: Bool {
    ContactGroup.normalizedName(name) != nil && !store.isNameAvailable(name, excluding: editingID)
  }

  private var canSave: Bool {
    ContactGroup.normalizedName(name) != nil && !isNameTaken
  }

  private var tint: Color {
    (ContactGroup.Palette(rawValue: color) ?? .blue).swatch
  }

  private var choiceColumns: [GridItem] {
    [GridItem(.adaptive(minimum: Self.minimumTapTarget))]
  }

  var body: some View {
    NavigationStack {
      CardForm {
        CardFormSection(L10n.Contacts.Contacts.Groups.name) {
          ContentCard {
            HStack(spacing: 12) {
              ContactGroupIcon(symbol: symbol, tint: tint, size: 36)
              TextField(L10n.Contacts.Contacts.Groups.namePlaceholder, text: $name)
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .onChange(of: name) { _, newValue in
                  if newValue.count > ContactGroup.maxNameLength {
                    name = String(newValue.prefix(ContactGroup.maxNameLength))
                  }
                }
            }
            // On the card rather than in a footer, so it can stay red beside the field it's about.
            if isNameTaken {
              Text(L10n.Contacts.Contacts.Groups.nameTaken)
                .font(.footnote)
                .foregroundStyle(.red)
            }
          }
        }

        CardFormSection(L10n.Contacts.Contacts.Groups.icon) {
          ContentCard {
            LazyVGrid(columns: choiceColumns, spacing: 12) {
              let selectedGlyph = ContactGroup.glyphColor(
                onFill: tint,
                colorScheme: colorScheme,
                contrast: colorSchemeContrast
              )
              ForEach(ContactGroup.symbolChoices, id: \.self) { choice in
                Button {
                  symbol = choice
                } label: {
                  Image(systemName: choice)
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .foregroundStyle(symbol == choice ? selectedGlyph : .primary)
                    .background(
                      symbol == choice ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary),
                      in: .circle
                    )
                    .frame(minWidth: Self.minimumTapTarget, minHeight: Self.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ContactGroup.localizedSymbolName(choice))
                .accessibilityAddTraits(symbol == choice ? .isSelected : [])
              }
            }
            .padding(.vertical, 4)
          }
        }

        CardFormSection(L10n.Contacts.Contacts.Groups.color) {
          ContentCard {
            LazyVGrid(columns: choiceColumns, spacing: 12) {
              ForEach(ContactGroup.Palette.allCases, id: \.self) { choice in
                Button {
                  color = choice.rawValue
                } label: {
                  Circle()
                    .fill(choice.swatch)
                    .frame(width: 28, height: 28)
                    .overlay {
                      if color == choice.rawValue {
                        Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
                      }
                    }
                    .frame(minWidth: Self.minimumTapTarget, minHeight: Self.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.localizedName)
                .accessibilityAddTraits(color == choice.rawValue ? .isSelected : [])
              }
            }
            .padding(.vertical, 6)
          }
        }
      }
      .flashingNavigationTitle(editingID == nil ? L10n.Contacts.Contacts.Groups.new : L10n.Contacts.Contacts.Groups.edit)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.Contacts.Contacts.Common.cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.Contacts.Contacts.Common.save, action: save)
            .disabled(!canSave)
          .keyboardShortcut(.defaultAction)
        }
      }
      .onAppear {
        if editingID == nil {
          isNameFocused = true
        }
      }
    }
  }

  private func save() {
    guard canSave else { return }
    switch mode {
    case let .create(initialMember):
      let members = initialMember.map { [ContactGroup.memberKey(for: $0)] } ?? []
      guard store.createGroup(name: name, symbol: symbol, color: color, memberKeys: members) != nil else { return }
    case let .edit(group):
      guard store.rename(group.id, to: name) else { return }
      store.setAppearance(group.id, symbol: symbol, color: color)
    }
    dismiss()
  }
}
