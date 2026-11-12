import Accessibility
import SwiftUI

/// Why a locate button couldn't move the map: Location is off for the app (an alert with Open
/// Settings, as the Location Settings sheet shows), or it's allowed but no fix has come yet (a
/// moment's toast, while the request already made runs).
enum MapLocateFeedback: Equatable {
  case denied
  case searching
}

extension View {
  /// Shows the locate button's failure: the denied alert, or the searching toast over the bottom
  /// of this view, which clears itself.
  func mapLocateFeedback(_ feedback: Binding<MapLocateFeedback?>) -> some View {
    modifier(MapLocateFeedbackModifier(feedback: feedback))
  }

  /// A short message over the bottom of this view, cleared after a moment (or at once when set
  /// to nil): Look Around having nothing to show, say.
  func mapToast(_ text: Binding<String?>) -> some View {
    modifier(MapToastModifier(text: text))
  }
}

private struct MapLocateFeedbackModifier: ViewModifier {
  @Binding var feedback: MapLocateFeedback?
  @Environment(\.openURL) private var openURL

  private var deniedAlert: Binding<Bool> {
    Binding(
      get: { feedback == .denied },
      set: { if !$0, feedback == .denied { feedback = nil } }
    )
  }

  private var toast: Binding<String?> {
    Binding(
      get: { feedback == .searching ? L10n.Map.Map.Locate.searching : nil },
      set: { if $0 == nil, feedback == .searching { feedback = nil } }
    )
  }

  func body(content: Content) -> some View {
    content
      .mapToast(toast)
      .alert(L10n.Onboarding.Permissions.LocationAlert.title, isPresented: deniedAlert) {
        Button(L10n.Onboarding.Permissions.LocationAlert.openSettings) {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
          }
        }
        Button(L10n.Localizable.Common.cancel, role: .cancel) {}
      } message: {
        Text(L10n.Map.Map.Gps.Denied.message)
      }
  }
}

private struct MapToastModifier: ViewModifier {
  @Binding var text: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let duration: Duration = .seconds(2.5)

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let text {
          MapToastView(text: text)
            .padding(.bottom, 24)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.snappy, value: text)
      .task(id: text) {
        guard text != nil else { return }
        try? await Task.sleep(for: Self.duration)
        guard !Task.isCancelled else { return }
        text = nil
      }
  }
}

/// A capsule of text floating over the map, as the offline badge is drawn.
struct MapToastView: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.subheadline.weight(.medium))
      .multilineTextAlignment(.center)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .liquidGlass(in: .capsule)
      .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
      .padding(.horizontal)
      .accessibilityAddTraits(.isStaticText)
      .onAppear {
        AccessibilityNotification.Announcement(text).post()
      }
  }
}
