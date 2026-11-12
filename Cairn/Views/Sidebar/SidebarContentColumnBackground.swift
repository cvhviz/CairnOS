import SwiftUI

/// Places a static section background behind an iPad sidebar content column and extends it under
/// the floating Liquid Glass sidebar on iOS 26+ via `sidebarBackgroundExtension()`.
///
/// Only a user background is painted here, and the effect is applied to that static layer (not
/// the scrolling list), so only a single static surface is routed through the GPU
/// duplicate-mirror-blur. The system background leaves the system list background
/// untouched to preserve iOS 26 List Liquid Glass, matching `ThemedCanvasModifier`'s deliberate
/// no-op; the floating sidebar simply overlays the unmodified system surface there. The leading
/// inset keeps row content clear of the floating glass in both cases.
struct SidebarContentColumnBackground: ViewModifier {
  let theme: Theme

  func body(content: Content) -> some View {
    if let backdrop = theme.backdrop {
      content
        .scrollContentBackground(.hidden)
        .safeAreaPadding(.leading, sidebarContentLeadingInset)
        .background {
          AppBackdropView(backdrop: backdrop)
            .ignoresSafeArea()
            .sidebarBackgroundExtension()
        }
        .environment(\.isOnAppBackdrop, true)
    } else {
      content
        .safeAreaPadding(.leading, sidebarContentLeadingInset)
    }
  }
}
