import Foundation
@testable import Cairn
import CairnServices
import Testing
import UIKit

@Suite("Background image store")
struct BackgroundImageStoreTests {
  private static func makeStore() -> BackgroundImageStore {
    BackgroundImageStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("BackgroundImageStoreTests-\(UUID().uuidString)", isDirectory: true)
    )
  }

  /// A solid-color PNG of the given pixel size.
  private static func pngData(width: Int, height: Int, color: UIColor = .red) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
    return renderer.pngData { context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  private static func pixelSize(of image: UIImage) -> CGSize {
    CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
  }

  @Test
  func `save downscales a large photo to the maximum long side`() throws {
    let store = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let saved = try store.save(imageData: Self.pngData(width: 3000, height: 1500))
    let image = try #require(store.image(named: saved.fileName))
    let size = Self.pixelSize(of: image)
    #expect(max(size.width, size.height) == CGFloat(BackgroundImageStore.maxPixelSize))
    #expect(abs(size.width / size.height - 2) < 0.01)
  }

  @Test
  func `save keeps a small photo at its own size`() throws {
    let store = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let saved = try store.save(imageData: Self.pngData(width: 400, height: 300))
    let image = try #require(store.image(named: saved.fileName))
    #expect(Self.pixelSize(of: image) == CGSize(width: 400, height: 300))
  }

  @Test
  func `save measures the average color`() throws {
    let store = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let saved = try store.save(imageData: Self.pngData(width: 64, height: 64, color: .red))
    #expect(saved.averageColor.red > 0.9)
    #expect(saved.averageColor.green < 0.1)
    #expect(saved.averageColor.blue < 0.1)
  }

  @Test
  func `save, contains and delete`() throws {
    let store = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let saved = try store.save(imageData: Self.pngData(width: 100, height: 100))
    #expect(BackgroundImageStore.isValidFileName(saved.fileName))
    #expect(store.contains(named: saved.fileName))

    store.delete(named: saved.fileName)
    #expect(!store.contains(named: saved.fileName))
    #expect(store.image(named: saved.fileName) == nil)
  }

  @Test
  func `unreadable data throws`() {
    let store = Self.makeStore()
    #expect(throws: BackgroundImageStore.StoreError.unreadableImage) {
      try store.save(imageData: Data("not an image".utf8))
    }
  }

  @Test
  func `blur renders are cached per radius and removed with the photo`() throws {
    let store = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let saved = try store.save(imageData: Self.pngData(width: 200, height: 200))
    #expect(store.blurRender(of: saved.fileName, radius: 10) == nil)
    _ = try store.makeBlurRender(of: saved.fileName, radius: 10)
    #expect(store.blurRender(of: saved.fileName, radius: 10) != nil)

    // A new radius replaces the old render.
    _ = try store.makeBlurRender(of: saved.fileName, radius: 20)
    #expect(store.blurRender(of: saved.fileName, radius: 10) == nil)
    #expect(store.blurRender(of: saved.fileName, radius: 20) != nil)

    store.delete(named: saved.fileName)
    #expect(store.blurRender(of: saved.fileName, radius: 20) == nil)
  }

  @Test
  func `removeAll keeps only the named photo`() throws {
    let store = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }

    let first = try store.save(imageData: Self.pngData(width: 50, height: 50))
    let second = try store.save(imageData: Self.pngData(width: 50, height: 50))
    store.removeAll(except: second.fileName)
    #expect(!store.contains(named: first.fileName))
    #expect(store.contains(named: second.fileName))
  }

  @Test
  func `only store-minted file names are accepted`() {
    #expect(BackgroundImageStore.isValidFileName("background-1234.jpg"))
    #expect(!BackgroundImageStore.isValidFileName("photo.jpg"))
    #expect(!BackgroundImageStore.isValidFileName("background-../../x.jpg"))
    #expect(!BackgroundImageStore.isValidFileName("background-a/b.jpg"))
    #expect(!BackgroundImageStore.isValidFileName("background-1234.png"))
  }
}

@Suite("ThemeService background")
@MainActor
struct ThemeServiceBackgroundTests {
  private static func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "ThemeServiceBackgroundTests.\(UUID().uuidString)")!
  }

  private static func makeStore() -> BackgroundImageStore {
    BackgroundImageStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("ThemeServiceBackgroundTests-\(UUID().uuidString)", isDirectory: true)
    )
  }

  @Test
  func `fresh install uses the app's default background and writes nothing`() {
    let defaults = Self.makeDefaults()
    let service = ThemeService(defaults: defaults, imageStore: Self.makeStore())
    #expect(service.background == .appDefault)
    #expect(service.current.hasBackdrop)
    #expect(defaults.object(forKey: AppStorageKey.appBackground.rawValue) == nil)
  }

  @Test
  func `updates persist, clamp and resolve a backdrop`() {
    let defaults = Self.makeDefaults()
    let store = Self.makeStore()
    let service = ThemeService(defaults: defaults, imageStore: store)
    service.updateBackground {
      $0.kind = .solid
      $0.dim = 5
    }
    #expect(service.background.dim == AppBackground.dimRange.upperBound)
    #expect(service.current.hasBackdrop)

    let reloaded = ThemeService(defaults: defaults, imageStore: store)
    #expect(reloaded.background == service.background)
  }

  @Test
  func `a restored photo background without its file falls back to system and is corrected`() {
    let defaults = Self.makeDefaults()
    var stored = AppBackground()
    stored.kind = .image
    stored.imageFileName = "background-missing.jpg"
    defaults.set(stored.encodedString, forKey: AppStorageKey.appBackground.rawValue)

    let service = ThemeService(defaults: defaults, imageStore: Self.makeStore())
    #expect(service.background.kind == .system)
    #expect(service.backdrop == nil)
    let persisted = AppBackground.decode(from: defaults.string(forKey: AppStorageKey.appBackground.rawValue))
    #expect(persisted.kind == .system)
  }

  @Test
  func `refreshFromUserDefaults picks up a restored background`() {
    let defaults = Self.makeDefaults()
    let service = ThemeService(defaults: defaults, imageStore: Self.makeStore())
    var restored = AppBackground()
    restored.kind = .gradient
    defaults.set(restored.encodedString, forKey: AppStorageKey.appBackground.rawValue)
    defaults.set("dark", forKey: PersistenceKeys.appColorSchemePreference)

    service.refreshFromUserDefaults()
    #expect(service.background.kind == .gradient)
    #expect(service.colorSchemePreference == .dark)
  }

  @Test
  func `setting and removing a photo`() async throws {
    let defaults = Self.makeDefaults()
    let store = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let service = ThemeService(defaults: defaults, imageStore: store)

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let data = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).pngData { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
    }
    try await service.setBackgroundImage(data: data)
    let name = try #require(service.background.imageFileName)
    #expect(service.background.kind == .image)
    #expect(service.backdrop?.image != nil)
    #expect(store.contains(named: name))

    service.removeBackgroundImage()
    #expect(service.background.kind == .system)
    #expect(!store.contains(named: name))
  }

  @Test
  func `unknown color scheme value falls back to system and is corrected`() {
    let defaults = Self.makeDefaults()
    defaults.set("auto", forKey: PersistenceKeys.appColorSchemePreference)
    let service = ThemeService(defaults: defaults, imageStore: Self.makeStore())
    #expect(service.colorSchemePreference == .system)
    #expect(defaults.string(forKey: PersistenceKeys.appColorSchemePreference) == "system")
  }
}
