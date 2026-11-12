import SwiftUI

extension View {
  /// Pins a page's segmented control under the navigation bar, as GPS (Position | Map), Traffic
  /// and Trace Path (List | Map) do. iOS 26's `safeAreaBar` lets the scroll edge effect run
  /// under it like the bar itself; earlier systems get a plain inset on the bar material.
  @ViewBuilder
  func pageSegmentBar(@ViewBuilder content: () -> some View) -> some View {
    if #available(iOS 26.0, *) {
      safeAreaBar(edge: .top, spacing: 0, content: content)
    } else {
      safeAreaInset(edge: .top, spacing: 0) {
        content()
          .frame(maxWidth: .infinity)
          .background(.bar)
      }
    }
  }

  /// A segmented control laid out for `pageSegmentBar`: full width inside the page margins, like
  /// the Nodes and Comm bars, and on its own glass over a map, where there is no bar behind it.
  func pageSegmentStyle(isOverMap: Bool) -> some View {
    pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: .infinity)
      .padding(isOverMap ? 4 : 0)
      .background {
        if isOverMap {
          Capsule().fill(.regularMaterial)
        }
      }
      .padding(.horizontal, CardStyle.pageInset)
      .padding(.top, 8)
      .padding(.bottom, 6)
  }
}
