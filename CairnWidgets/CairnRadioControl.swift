import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center / Action Button button that opens the app. A control
/// runs in the widget process with no radio access, so this only foregrounds
/// the app; the live status glance and any send happen once the app is up.
struct CairnRadioControl: ControlWidget {
  static let kind = "cvhvisuals.Cairn.RadioControl"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: OpenRadioStatusIntent()) {
        Label("Open CAIRN", systemImage: "antenna.radiowaves.left.and.right")
      }
    }
    .displayName("CAIRN")
    .description("Open Cairn")
  }
}
