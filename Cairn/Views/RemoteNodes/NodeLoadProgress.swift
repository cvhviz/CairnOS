import SwiftUI

/// One automatic read on a node's page after login, named (with its section's symbol) for the
/// loading bar.
struct NodeLoadStep {
  let title: String
  let systemImage: String
  let color: Color
  let run: () async -> Void
}

/// How far a node page's automatic reads have got: `done` finished of `total`, and the one running.
struct NodeLoadProgress: Equatable {
  let done: Int
  let total: Int
  let title: String
  let systemImage: String
  let color: Color

  /// "Radio · 4/6": the step the page is loading, for a navigation subtitle.
  var stepText: String { "\(title) · \(done)/\(total)" }
}

extension View {
  /// A slim bar along the top of the page while it loads a known number of steps: the theme's
  /// accent filling as each starts, and a small chip under its right end naming the one running,
  /// "Radio · 4/6". It floats over the content, so nothing on the page moves when it comes or
  /// goes. Nil hides it. `showsChip` false leaves the naming to the page (its navigation subtitle).
  func pageLoadingBar(_ progress: NodeLoadProgress?, showsChip: Bool = true) -> some View {
    loadingBarLayer(PageLoadingBar(state: progress.map(PageLoadingBar.State.steps), showsChip: showsChip))
  }

  /// The bar sits just under the navigation bar, not at the scroll view's top edge (which runs up
  /// under the bar): a zero-height top inset marks the spot, so the content still never moves.
  fileprivate func loadingBarLayer(_ bar: PageLoadingBar) -> some View {
    safeAreaInset(edge: .top, spacing: 0) {
      Color.clear.frame(height: 0).overlay(alignment: .top) { bar }
    }
  }

  /// The same bar for a load of unknown length (one request across the mesh): a sweep rather
  /// than a fill, with `title` in the chip when given.
  func pageLoadingBar(isLoading: Bool, title: String? = nil) -> some View {
    loadingBarLayer(PageLoadingBar(state: isLoading ? .indeterminate(title: title) : nil))
  }

  /// The same bar for something heard getting `done` of `total` steps along (a trace's hops),
  /// filled that far, with `title` in the chip as given. Nil hides it.
  func pageLoadingBar(reached: (done: Int, total: Int, title: String)?) -> some View {
    loadingBarLayer(PageLoadingBar(state: reached.map { .reached(done: $0.done, total: $0.total, title: $0.title) }))
  }
}

/// The bar `pageLoadingBar` draws. Kept quiet: a 3 pt line and a caption-sized chip, so it says
/// the page is still filling in without competing with the readings.
fileprivate struct PageLoadingBar: View {
  enum State: Equatable {
    case steps(NodeLoadProgress)
    case indeterminate(title: String?)
    case reached(done: Int, total: Int, title: String)
  }

  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let state: State?
  var showsChip = true

  var body: some View {
    ZStack(alignment: .top) {
      if let state {
        VStack(alignment: .trailing, spacing: 6) {
          line(for: state)
            .frame(height: 3)
          if showsChip, let chip = chipText(for: state) {
            chipView(chip, systemImage: chipSymbol(for: state))
              .padding(.trailing, CardStyle.pageInset)
          }
        }
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: state))
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func line(for state: State) -> some View {
    switch state {
    case let .steps(progress):
      GeometryReader { geometry in
        let step = min(progress.done + 1, progress.total)
        let fraction = Double(step) / Double(max(1, progress.total))
        ZStack(alignment: .leading) {
          Rectangle().fill(theme.accentColor.opacity(0.18))
          Capsule()
            .fill(theme.accentColor)
            .frame(width: geometry.size.width * fraction)
            .animation(reduceMotion ? nil : .snappy, value: fraction)
        }
      }
    case .indeterminate:
      IndeterminateSweep(tint: theme.accentColor, isAnimated: !reduceMotion)
    case let .reached(done, total, _):
      GeometryReader { geometry in
        let fraction = Double(min(done, total)) / Double(max(1, total))
        ZStack(alignment: .leading) {
          Rectangle().fill(theme.accentColor.opacity(0.18))
          Capsule()
            .fill(theme.accentColor)
            .frame(width: geometry.size.width * fraction)
            .animation(reduceMotion ? nil : .snappy, value: fraction)
        }
      }
    }
  }

  private func chipView(_ text: String, systemImage: String?) -> some View {
    HStack(spacing: 5) {
      if let systemImage {
        Image(systemName: systemImage)
          .foregroundStyle(theme.accentColor)
          .contentTransition(.symbolEffect(.replace))
      }
      Text(text)
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    // The app's floating chip (SNRLegendChip, the map banners): its glass capsule and soft
    // shadow, a size smaller since it only reports.
    .font(.caption.weight(.semibold))
    .foregroundStyle(.primary)
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .liquidGlass(in: .capsule)
    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
  }

  private func chipText(for state: State) -> String? {
    switch state {
    case let .steps(progress):
      let step = min(progress.done + 1, progress.total)
      return "\(progress.title) · \(L10n.RemoteNodes.RemoteNodes.Status.loadingCount(step, progress.total))"
    case let .indeterminate(title):
      return title
    case let .reached(_, _, title):
      return title
    }
  }

  private func chipSymbol(for state: State) -> String? {
    if case let .steps(progress) = state { return progress.systemImage }
    return nil
  }

  private func accessibilityText(for state: State) -> String {
    switch state {
    case let .steps(progress):
      let step = min(progress.done + 1, progress.total)
      return L10n.RemoteNodes.RemoteNodes.Status.loadingStep(step, progress.total, progress.title)
    case let .indeterminate(title):
      return title ?? L10n.RemoteNodes.RemoteNodes.Settings.loading
    case let .reached(_, _, title):
      return title
    }
  }
}

/// A short accent segment sliding across the track, for a load with no count. Still under Reduce
/// Motion: a steady half-tint track instead.
private struct IndeterminateSweep: View {
  let tint: Color
  let isAnimated: Bool
  @State private var phase: CGFloat = -0.35

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Rectangle().fill(tint.opacity(isAnimated ? 0.18 : 0.45))
        if isAnimated {
          Capsule()
            .fill(tint)
            .frame(width: geometry.size.width * 0.35)
            .offset(x: geometry.size.width * phase)
        }
      }
      .clipped()
    }
    .onAppear {
      guard isAnimated else { return }
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
        phase = 1.0
      }
    }
  }
}
