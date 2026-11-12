import SwiftUI
import UIKit

extension View {
  /// Presents a node's page: on a Mac, in its own window (`MacDetailWindowView`), which can be
  /// moved, resized and kept beside the main window; on iPhone and iPad, as the same sheet as ever.
  ///
  /// On a Mac the item is cleared as soon as it is set, so the presenter never shows a sheet and
  /// setting the same node again brings its window forward. `onDismiss` runs for the sheet only: a
  /// window closes on its own, with no presenter to tell.
  @ViewBuilder
  func detailPresentation<Item: Identifiable, Content: View>(
    item: Binding<Item?>,
    route: @escaping (Item) -> MacDetailRoute,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    if ProcessInfo.processInfo.isiOSAppOnMac {
      modifier(MacDetailWindowOpener(item: item, route: route))
    } else {
      sheet(item: item, onDismiss: onDismiss, content: content)
    }
  }

  /// Presents a page opened from inside a node's page (its status, admin dashboard, telemetry or
  /// full map): on a Mac, pushed onto the stack the node's page is in, so it stays in that node's
  /// window (or column) with a back button rather than opening another window; on iPhone and iPad,
  /// as the same sheet as ever. `sheet` is the page as a sheet, with its own stack and Done;
  /// `pushed` is the same page without them.
  ///
  /// `pushesOnMac` false keeps an item a sheet on a Mac too (a login form), and `onDismiss` runs
  /// when that sheet closes, so a login can lead on to the page it opens. `pushesInRegularWidth`
  /// pushes the same way on an iPad in a regular-width column (the split view's detail), where a
  /// page-sized sheet would cover the whole split; a compact iPad stays with the sheet.
  @ViewBuilder
  func nodePagePresentation<Item: Identifiable & Hashable, Sheet: View, Pushed: View>(
    item: Binding<Item?>,
    pushesOnMac: @escaping (Item) -> Bool = { _ in true },
    pushesInRegularWidth: Bool = false,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder sheet: @escaping (Item) -> Sheet,
    @ViewBuilder pushed: @escaping (Item) -> Pushed
  ) -> some View {
    if ProcessInfo.processInfo.isiOSAppOnMac {
      modifier(MacNodePagePusher(
        item: item,
        pushesOnMac: pushesOnMac,
        onDismiss: onDismiss,
        sheetContent: sheet,
        pushedContent: pushed
      ))
    } else if pushesInRegularWidth, UIDevice.current.userInterfaceIdiom == .pad {
      modifier(RegularWidthNodePagePusher(
        item: item,
        pushes: pushesOnMac,
        onDismiss: onDismiss,
        sheetContent: sheet,
        pushedContent: pushed
      ))
    } else {
      self.sheet(item: item, onDismiss: onDismiss, content: sheet)
    }
  }

  /// `nodePagePresentation(item:…)` for a presenter that holds a flag.
  @ViewBuilder
  func nodePagePresentation<Sheet: View, Pushed: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder sheet: @escaping () -> Sheet,
    @ViewBuilder pushed: @escaping () -> Pushed
  ) -> some View {
    if ProcessInfo.processInfo.isiOSAppOnMac {
      navigationDestination(isPresented: isPresented) {
        pushed().macPushedPageBackButton()
      }
    } else {
      self.sheet(isPresented: isPresented, content: sheet)
    }
  }

  /// A Mac push gets a back button of its own: in a split view's detail column an iPad app on a
  /// Mac shows the pushed page without the system one (see `addHopPicker`).
  func macPushedPageBackButton() -> some View {
    modifier(MacPushedPageBackButton())
  }
}

private struct MacDetailWindowOpener<Item: Identifiable>: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  @Binding var item: Item?
  let route: (Item) -> MacDetailRoute

  func body(content: Content) -> some View {
    content
      .onChange(of: item?.id, initial: true) {
        guard let value = item else { return }
        item = nil
        MacDetailWindows.shared.open(route(value), with: openWindow)
      }
  }
}

private struct MacNodePagePusher<Item: Identifiable & Hashable, SheetContent: View, PushedContent: View>: ViewModifier {
  @Binding var item: Item?
  let pushesOnMac: (Item) -> Bool
  let onDismiss: (() -> Void)?
  let sheetContent: (Item) -> SheetContent
  let pushedContent: (Item) -> PushedContent

  @State private var pushedItem: Item?
  @State private var sheetItem: Item?

  func body(content: Content) -> some View {
    content
      // Handed on at once, so the presenter's item is free for the next request (a login's
      // `onDismiss` setting the page it leads to, say).
      .onChange(of: item?.id, initial: true) {
        guard let value = item else { return }
        item = nil
        if pushesOnMac(value) {
          pushedItem = value
        } else {
          sheetItem = value
        }
      }
      .navigationDestination(item: $pushedItem) { value in
        pushedContent(value).macPushedPageBackButton()
      }
      .sheet(item: $sheetItem, onDismiss: onDismiss, content: sheetContent)
  }
}

/// An iPad's `MacNodePagePusher`: pushes while the column is regular width (the system back
/// button serves), and presents the sheet as ever when it's compact (a slide-over, a split).
private struct RegularWidthNodePagePusher<Item: Identifiable & Hashable, SheetContent: View, PushedContent: View>: ViewModifier {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Binding var item: Item?
  let pushes: (Item) -> Bool
  let onDismiss: (() -> Void)?
  let sheetContent: (Item) -> SheetContent
  let pushedContent: (Item) -> PushedContent

  @State private var pushedItem: Item?
  @State private var sheetItem: Item?

  func body(content: Content) -> some View {
    content
      .onChange(of: item?.id, initial: true) {
        guard let value = item else { return }
        item = nil
        if horizontalSizeClass == .regular, pushes(value) {
          pushedItem = value
        } else {
          sheetItem = value
        }
      }
      .navigationDestination(item: $pushedItem) { value in
        pushedContent(value)
      }
      .sheet(item: $sheetItem, onDismiss: onDismiss, content: sheetContent)
  }
}

private struct MacPushedPageBackButton: ViewModifier {
  @Environment(\.dismiss) private var dismiss

  func body(content: Content) -> some View {
    content
      .navigationBarBackButtonHidden(true)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(L10n.Localizable.Common.back, systemImage: "chevron.left") { dismiss() }
            .keyboardShortcut("[", modifiers: .command)
        }
      }
  }
}

// MARK: - Opened windows

/// The detail windows asked for in this run of the app. A window the system restores at relaunch
/// was not, which is how the admin and status windows tell a login from this run, which they can
/// use, from one that lapsed with the last run.
@MainActor @Observable
final class MacDetailWindows {
  static let shared = MacDetailWindows()

  /// How many times each route was opened; a window reloads when its count goes up, so opening it
  /// again (after a fresh login, say) shows what is current rather than what it first loaded.
  private(set) var openCounts: [MacDetailRoute: Int] = [:]

  func open(_ route: MacDetailRoute, with openWindow: OpenWindowAction) {
    openCounts[route, default: 0] += 1
    // An open window showing an equal route comes to the front rather than opening a second one.
    openWindow(value: route)
  }

  func openCount(for route: MacDetailRoute) -> Int {
    openCounts[route] ?? 0
  }
}

// MARK: - Closing

/// Closes the detail window a page sits at the root of. Set by `MacDetailWindowView` on its content.
struct MacDetailWindowCloser {
  let close: @MainActor (_ showingMainWindow: Bool) -> Void
}

extension EnvironmentValues {
  /// The detail window hosting this view, on a Mac; nil in the main window, sheets and pushes.
  @Entry var macDetailWindow: MacDetailWindowCloser?
}

/// What a detail page calls to close itself. `dismiss` pops a push or closes a sheet, but does
/// nothing at the root of a window, so there it closes the Mac detail window instead.
struct CloseDetailAction {
  fileprivate let window: MacDetailWindowCloser?
  fileprivate let dismiss: DismissAction

  @MainActor
  func callAsFunction() {
    callAsFunction(showingMainWindow: false)
  }

  /// `showingMainWindow` brings the main window forward as the detail window closes, for an
  /// action that carries on there (opening a chat or room).
  @MainActor
  func callAsFunction(showingMainWindow: Bool) {
    if let window {
      window.close(showingMainWindow)
    } else {
      dismiss()
    }
  }
}

/// The page's `CloseDetailAction`. A presented or pushed page (`isPresented`) always dismisses,
/// so a page pushed inside a detail window pops rather than closing the window.
@propertyWrapper
struct CloseDetail: DynamicProperty {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.isPresented) private var isPresented
  @Environment(\.macDetailWindow) private var window

  init() {}

  var wrappedValue: CloseDetailAction {
    CloseDetailAction(window: isPresented ? nil : window, dismiss: dismiss)
  }
}

// MARK: - Scenes

/// The main windows' scenes, so a detail window can bring one forward: `openWindow(id:)` would
/// open another main window rather than show the one already there.
@MainActor
enum MacMainWindow {
  private static let scenes = NSHashTable<UIWindowScene>.weakObjects()

  static func register(_ scene: UIWindowScene) {
    scenes.add(scene)
  }

  /// Brings the frontmost main window forward, if one is open.
  static func activate() {
    let all = scenes.allObjects
    let scene = all.first { $0.activationState == .foregroundActive }
      ?? all.first { $0.activationState == .foregroundInactive }
      ?? all.first
    guard let scene else { return }
    UIApplication.shared.activateSceneSession(
      for: UISceneSessionActivationRequest(session: scene.session),
      errorHandler: nil
    )
  }
}

extension View {
  /// On a Mac, records this view's window as a main window for `MacMainWindow.activate()`.
  func registersMacMainWindow() -> some View {
    background {
      if ProcessInfo.processInfo.isiOSAppOnMac {
        WindowSceneReader { MacMainWindow.register($0) }
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
      }
    }
  }
}

extension View {
  /// On a Mac, the window's title in the title bar and the Window menu. No effect on iPhone or
  /// iPad, whose scenes keep the titles the system gives them.
  func macWindowTitle(_ title: String) -> some View {
    background {
      if ProcessInfo.processInfo.isiOSAppOnMac {
        WindowSceneReader { scene in
          if scene.title != title { scene.title = title }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
    }
  }
}

/// Hands over the window scene this view is shown in, once it is in a window and on each update.
struct WindowSceneReader: UIViewRepresentable {
  let onScene: @MainActor (UIWindowScene) -> Void

  func makeUIView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onScene = onScene
    return view
  }

  func updateUIView(_ view: ReaderView, context: Context) {
    view.onScene = onScene
    // Again on each update, so a reader passing on changing state (a title) stays current.
    if let scene = view.window?.windowScene {
      onScene(scene)
    }
  }

  final class ReaderView: UIView {
    var onScene: (@MainActor (UIWindowScene) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let scene = window?.windowScene {
        onScene?(scene)
      }
    }
  }
}
