import CairnServices
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a page does with an edited avatar: save or remove the photo, or save the colour. Contacts
/// write through `ContactService`; this radio writes to `RadioAvatarStore`.
struct AvatarEditActions {
  let savePhoto: (Data) async throws -> Void
  let removePhoto: () async throws -> Void
  let setColor: (NodeAvatarColor?) async throws -> Void
}

/// Shrinks a cropped avatar so it stays small wherever it's stored.
enum AvatarImageProcessor {
  nonisolated static let maxDimension: CGFloat = 512
  nonisolated static let jpegQuality: CGFloat = 0.8

  /// Downscales to `maxDimension` and re-encodes as JPEG.
  nonisolated static func process(image: UIImage) -> Data? {
    let longest = max(image.size.width, image.size.height)
    guard longest > 0 else { return nil }
    if longest <= maxDimension {
      return image.jpegData(compressionQuality: jpegQuality)
    }
    let scale = maxDimension / longest
    let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    return resized.jpegData(compressionQuality: jpegQuality)
  }
}

/// The state of editing one avatar: which picker is up, the image waiting to be cropped, and
/// whether a save is running. A page keeps one in `@State`, puts `AvatarEditButton` on its
/// avatar and `.avatarEditing(...)` on its content.
@Observable
@MainActor
final class AvatarEditor {
  /// Wraps a decoded image so `fullScreenCover(item:)` can't present an empty cover.
  struct CropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
  }

  var showsSourceMenu = false
  var showsPhotosPicker = false
  var showsFileImporter = false
  var showsColorSheet = false
  var pickerItem: PhotosPickerItem?
  var cropRequest: CropRequest?
  var isSaving = false
  var errorMessage: String?
  /// A decoded image waiting for the photo picker / file importer sheet that produced it to
  /// finish dismissing, so the crop cover isn't presented while another is still animating out.
  @ObservationIgnored private var pendingCropImage: UIImage?

  func loadPickedPhoto(_ item: PhotosPickerItem?) async {
    defer { pickerItem = nil }
    guard let item else { return }
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        errorMessage = L10n.Contacts.Contacts.Detail.Avatar.invalidImage
        return
      }
      await presentCropSheet(data: data)
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  func handleFileImport(_ result: Result<URL, Error>) async {
    switch result {
    case let .success(url):
      let didAccess = url.startAccessingSecurityScopedResource()
      defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
      do {
        let data = try Data(contentsOf: url)
        await presentCropSheet(data: data)
      } catch {
        errorMessage = error.userFacingMessage
      }
    case let .failure(error):
      errorMessage = error.userFacingMessage
    }
  }

  /// Decodes off the main actor and downsamples before crop, so a camera photo
  /// cannot hitch the UI or hold a full-resolution bitmap.
  func presentCropSheet(data: Data) async {
    let decoded = await Task.detached(priority: .userInitiated) {
      ImageURLDetector.downsampledImage(
        from: data,
        maxPixelSize: AvatarCropGeometry.decodeMaxPixelSize
      )
    }.value
    guard let image = decoded else {
      errorMessage = L10n.Contacts.Contacts.Detail.Avatar.invalidImage
      return
    }
    pendingCropImage = image
    // Both sheets already closed: present now. Otherwise `presentPendingCropIfReady`
    // runs when `showsPhotosPicker` or `showsFileImporter` becomes false.
    if !showsPhotosPicker, !showsFileImporter {
      presentPendingCropIfReady()
    }
  }

  func presentPendingCropIfReady() {
    guard let image = pendingCropImage else { return }
    pendingCropImage = nil
    cropRequest = CropRequest(image: image)
  }

  func savePhoto(_ image: UIImage, actions: AvatarEditActions) async {
    isSaving = true
    defer { isSaving = false }
    let processed = await Task.detached(priority: .userInitiated) {
      AvatarImageProcessor.process(image: image)
    }.value
    guard let processed else {
      errorMessage = L10n.Contacts.Contacts.Detail.Avatar.invalidImage
      return
    }
    do {
      try await actions.savePhoto(processed)
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  func removePhoto(actions: AvatarEditActions) async {
    isSaving = true
    defer { isSaving = false }
    do {
      try await actions.removePhoto()
    } catch {
      errorMessage = error.userFacingMessage
    }
  }

  func setColor(_ color: NodeAvatarColor?, actions: AvatarEditActions) async {
    do {
      try await actions.setColor(color)
    } catch {
      errorMessage = error.userFacingMessage
    }
  }
}

/// A node's avatar as a button that opens the source menu: Choose Photo, Choose File, Color…, and
/// Remove Photo when there is one. Marked with a camera badge; dims with a spinner while saving.
struct AvatarEditButton<Avatar: View>: View {
  @Bindable var editor: AvatarEditor
  let name: String
  let hasPhoto: Bool
  let size: CGFloat
  let actions: AvatarEditActions
  @ViewBuilder let avatar: () -> Avatar

  var body: some View {
    Button {
      editor.showsSourceMenu = true
    } label: {
      ZStack {
        avatar()
        if editor.isSaving {
          AvatarPebble()
            .fill(.black.opacity(0.4))
            .frame(width: size, height: size)
          ProgressView()
            .controlSize(.small)
            .tint(.white)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        editBadge
      }
    }
    .buttonStyle(.plain)
    .disabled(editor.isSaving)
    .accessibilityLabel(accessibilityLabel)
    .confirmationDialog(
      L10n.Contacts.Contacts.Detail.Avatar.chooseSource,
      isPresented: $editor.showsSourceMenu,
      titleVisibility: .visible
    ) {
      Button(L10n.Contacts.Contacts.Detail.Avatar.choosePhoto) { editor.showsPhotosPicker = true }
      Button(L10n.Contacts.Contacts.Detail.Avatar.chooseFile) { editor.showsFileImporter = true }
      Button(L10n.Contacts.Contacts.Detail.Avatar.chooseColor) { editor.showsColorSheet = true }
      if hasPhoto {
        Button(L10n.Contacts.Contacts.Detail.Avatar.removePhoto, role: .destructive) {
          Task { await editor.removePhoto(actions: actions) }
        }
      }
      Button(L10n.Contacts.Contacts.Common.cancel, role: .cancel) {}
    }
  }

  private var accessibilityLabel: String {
    guard editor.isSaving else {
      return "\(name), \(L10n.Contacts.Contacts.Detail.Avatar.chooseSource)"
    }
    return "\(name), \(L10n.Contacts.Contacts.Detail.Avatar.savingAnnouncement)"
  }

  /// Hangs off the avatar's corner, so the photo stays visible at this small size.
  private var editBadge: some View {
    Image(systemName: "camera.circle.fill")
      .font(.system(size: 16))
      .symbolRenderingMode(.palette)
      .foregroundStyle(.white, .gray)
      .offset(x: 4, y: 4)
  }
}

private struct AvatarEditingModifier<Preview: View>: ViewModifier {
  @Bindable var editor: AvatarEditor
  let name: String
  let category: AvatarCategory
  let hasPhoto: Bool
  let color: NodeAvatarColor?
  let actions: AvatarEditActions
  let preview: (NodeAvatarColor?) -> Preview

  func body(content: Content) -> some View {
    content
      .photosPicker(isPresented: $editor.showsPhotosPicker, selection: $editor.pickerItem, matching: .images)
      .onChange(of: editor.pickerItem) { _, newItem in
        Task { await editor.loadPickedPhoto(newItem) }
      }
      .onChange(of: editor.showsPhotosPicker) { _, isPresented in
        if !isPresented { editor.presentPendingCropIfReady() }
      }
      .fileImporter(isPresented: $editor.showsFileImporter, allowedContentTypes: [.image]) { result in
        Task { await editor.handleFileImport(result) }
      }
      // Mac / iPad: an image dragged onto the page goes straight to the avatar crop step.
      .dropDestination(for: Data.self) { items, _ in
        guard let data = items.first else { return false }
        Task { await editor.presentCropSheet(data: data) }
        return true
      }
      .onChange(of: editor.showsFileImporter) { _, isPresented in
        if !isPresented { editor.presentPendingCropIfReady() }
      }
      .fullScreenCover(item: $editor.cropRequest) { request in
        AvatarCropView(
          image: request.image,
          onCancel: { editor.cropRequest = nil },
          onComplete: { cropped in
            editor.cropRequest = nil
            Task { await editor.savePhoto(cropped, actions: actions) }
          }
        )
      }
      .sheet(isPresented: $editor.showsColorSheet) {
        AvatarColorSheet(name: name, category: category, hasPhoto: hasPhoto, color: color, preview: preview) { picked in
          Task { await editor.setColor(picked, actions: actions) }
        }
      }
      .errorAlert($editor.errorMessage)
  }
}

extension View {
  /// The pickers, crop step and colour sheet behind an `AvatarEditButton`, attached to the page.
  /// `preview` draws the avatar in a candidate colour for the colour sheet; `category` is the
  /// node's kind, whose colour Automatic keeps.
  func avatarEditing(
    _ editor: AvatarEditor,
    name: String,
    category: AvatarCategory,
    hasPhoto: Bool,
    color: NodeAvatarColor?,
    actions: AvatarEditActions,
    @ViewBuilder preview: @escaping (NodeAvatarColor?) -> some View
  ) -> some View {
    modifier(AvatarEditingModifier(
      editor: editor,
      name: name,
      category: category,
      hasPhoto: hasPhoto,
      color: color,
      actions: actions,
      preview: preview
    ))
  }
}
