import CairnServices
import PhotosUI
import SwiftUI

/// The Appearance group of the Settings page: Light/Dark Mode, units and the app language, then the
/// page background — the kind (System, Color, Gradient, Photo) as cards, the controls for that
/// kind, and dim/blur. Every change applies app-wide immediately, including to the Settings page's
/// own background. Embeddable: a stack of `CardFormSection`s for a `CardForm`, not a page.
struct AppearanceSettingsSection: View {
  @Environment(\.appState) private var appState

  @State private var schemeTrigger = 0
  @State private var selectionTrigger = 0
  @State private var photoItem: PhotosPickerItem?
  @State private var showingPhotoPicker = false
  @State private var isLoadingPhoto = false
  @State private var photoError: String?
  @AppStorage(AppStorageKey.hapticFeedbackEnabled.rawValue)
  private var hapticsEnabled = AppStorageKey.defaultHapticFeedbackEnabled

  private var themeService: ThemeService {
    appState.themeService
  }

  private var background: AppBackground {
    themeService.background
  }

  var body: some View {
    // One stack rather than a Group, so the picker and alert below attach once, not per section.
    VStack(alignment: .leading, spacing: 20) {
      displaySection
      backgroundSection
      kindControlsSection
      if background.kind != .system {
        adjustmentsSection
      }
    }
    .cairnFeedback(.selection, trigger: schemeTrigger)
    .cairnFeedback(.selection, trigger: selectionTrigger)
    // One picker for both the Photo kind card and Change Photo. Presented from a flag rather
    // than a `PhotosPicker` button, whose label closure isn't main-actor isolated.
    .photosPicker(
      isPresented: $showingPhotoPicker,
      selection: $photoItem,
      matching: .images,
      preferredItemEncoding: .compatible
    )
    .onChange(of: photoItem) { _, item in
      guard let item else { return }
      Task { await loadPhoto(item) }
    }
    .errorAlert($photoError)
  }

  /// Color scheme, units and the app's language in one group: how the app reads, as display
  /// preferences.
  private var displaySection: some View {
    CardFormSection(L10n.Settings.Maps.displayHeader, info: displayInfo) {
      PickerCard(
        L10n.Settings.Appearance.Scheme.header,
        systemImage: "circle.lefthalf.filled",
        color: .indigo,
        selection: schemeBinding
      ) {
        ForEach(AppColorSchemePreference.allCases) { preference in
          Text(schemeLabel(preference)).tag(preference)
        }
      }

      NightModeToggleCard()

      // The app's taps on success, errors and selections (`cairnFeedback`); the compass's own
      // bearing ticks keep their switch on its settings sheet.
      ToggleCard(
        L10n.Settings.Appearance.haptics,
        systemImage: "hand.tap.fill",
        color: .pink,
        subtitle: L10n.Settings.Appearance.Haptics.footer,
        isOn: $hapticsEnabled
      )
      .accessibilityIdentifier("appearance.haptics")

      MeasurementUnitsPicker()

      // The app's language is set in iOS Settings; this card is the way there.
      AppLanguageRow()
    }
  }

  /// What Units and App Language each change, labelled since one "i" covers both rows.
  private var displayInfo: String {
    "\(L10n.Settings.Units.title): \(L10n.Settings.Units.footer)\n\n"
      + "\(L10n.Settings.Language.AppLanguage.title): \(L10n.Settings.Language.AppLanguage.footer)"
  }

  /// The kind cards. No separate preview: the page itself shows the background as it changes.
  private var backgroundSection: some View {
    CardFormSection(L10n.Settings.Appearance.Background.header) {
      BackgroundKindPicker(
        selection: background.kind,
        background: background,
        photo: themeService.backgroundPhoto,
        isLoadingPhoto: isLoadingPhoto,
        onSelect: selectKind,
        onChoosePhoto: { showingPhotoPicker = true }
      )
    }
  }

  @ViewBuilder
  private var kindControlsSection: some View {
    switch background.kind {
    case .system:
      EmptyView()
    case .solid:
      CardFormSection {
        ContentCard {
          SolidBackgroundControls(color: backgroundBinding(\.solidColor))
        }
      }
    case .gradient:
      CardFormSection {
        ContentCard {
          GradientBackgroundControls(
            colors: backgroundBinding(\.gradientColors),
            style: backgroundBinding(\.gradientStyle),
            direction: backgroundBinding(\.gradientDirection)
          )
        }
      }
    case .image:
      CardFormSection {
        ActionCard(
          L10n.Settings.Appearance.Background.Photo.change,
          systemImage: "photo.on.rectangle",
          color: .blue
        ) {
          showingPhotoPicker = true
        }
        .disabled(isLoadingPhoto)

        ActionCard(
          L10n.Settings.Appearance.Background.Photo.remove,
          systemImage: "trash",
          role: .destructive
        ) {
          themeService.removeBackgroundImage()
          selectionTrigger += 1
        }
        // A photo still loading would be set right after the removal, bringing it back.
        .disabled(isLoadingPhoto)
      }
    }
  }

  private var adjustmentsSection: some View {
    CardFormSection {
      ContentCard {
        BackgroundSliderRow(
          title: L10n.Settings.Appearance.Background.dim,
          systemImage: "circle.lefthalf.filled.inverse",
          value: backgroundBinding(\.dim),
          range: AppBackground.dimRange,
          step: 0.05,
          valueText: (background.dim).formatted(.percent.precision(.fractionLength(0))),
          info: L10n.Settings.Appearance.Background.footer
        )
        // Blur only changes a photo; on flat colors and gradients the slider would do nothing.
        if background.kind == .image {
          Divider()
          BackgroundSliderRow(
            title: L10n.Settings.Appearance.Background.blur,
            systemImage: "drop.halffull",
            value: backgroundBinding(\.blur),
            range: AppBackground.blurRange,
            step: 1,
            valueText: L10n.Settings.Appearance.Background.blurValue(Int(background.blur.rounded()))
          )
        }
      }
    }
  }

  // MARK: Actions

  private func selectKind(_ kind: AppBackground.Kind) {
    themeService.updateBackground { $0.kind = kind }
    selectionTrigger += 1
  }

  private func loadPhoto(_ item: PhotosPickerItem) async {
    isLoadingPhoto = true
    defer {
      isLoadingPhoto = false
      photoItem = nil
    }
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        photoError = L10n.Settings.Appearance.Background.Photo.loadFailed
        return
      }
      try await themeService.setBackgroundImage(data: data)
      selectionTrigger += 1
    } catch {
      photoError = L10n.Settings.Appearance.Background.Photo.loadFailed
    }
  }

  // MARK: Bindings

  private func backgroundBinding<Value>(_ keyPath: WritableKeyPath<AppBackground, Value>) -> Binding<Value> {
    Binding(
      get: { themeService.background[keyPath: keyPath] },
      set: { newValue in themeService.updateBackground { $0[keyPath: keyPath] = newValue } }
    )
  }

  private var schemeBinding: Binding<AppColorSchemePreference> {
    Binding(
      get: { themeService.colorSchemePreference },
      set: {
        themeService.setColorSchemePreference($0)
        schemeTrigger += 1
      }
    )
  }

  private func schemeLabel(_ preference: AppColorSchemePreference) -> String {
    switch preference {
    case .system: L10n.Settings.Appearance.Scheme.system
    case .light: L10n.Settings.Appearance.Scheme.light
    case .dark: L10n.Settings.Appearance.Scheme.dark
    }
  }
}

/// A labelled slider with its current value on the trailing edge.
private struct BackgroundSliderRow: View {
  let title: String
  let systemImage: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let valueText: String
  /// Explanation shown behind an "i" beside the title, when the slider needs one.
  var info: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        // The title and value are read through the slider; only the "i" stays reachable.
        SettingCardLabel(title, systemImage: systemImage, color: .gray)
          .accessibilityHidden(true)
        if let info {
          InfoButton(info, title: title)
        }
        Spacer()
        Text(valueText)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityHidden(true)
      }
      Slider(value: $value, in: range, step: step)
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }
  }
}

#Preview {
  CardForm {
    AppearanceSettingsSection()
  }
}
