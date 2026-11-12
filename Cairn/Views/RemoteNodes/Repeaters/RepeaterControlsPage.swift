import CairnServices
import SwiftUI

/// A logged-in repeater's Controls: its transmit power as the page's lead, with a slider, the
/// power in milliwatts and its own Apply; then the tuning and switches its firmware exposes, in groups
/// that are read only when opened (`RepeaterTuningGroup`: 24 settings were 24 requests over the mesh
/// on every visit); then one-tap commands. Settings this firmware doesn't have are left out. Everything
/// else is a command away in the CLI.
struct RepeaterControlsPage: View {
  @Environment(\.appState) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let settings: NodeSettingsViewModel
  /// The repeater's Behavior (repeat mode, flood hops, regions) as a card at the top, opening its sheet
  /// (the user, 2026-11-09: it was a Dashboard card).
  var behavior: NodeDashboardCardItem?

  @State private var model: RepeaterControlsModel
  @State private var txDraft: Double?
  @State private var pendingCommand: RepeaterCommand?
  /// The groups open on the page (all closed on arrival: nothing is read until asked for).
  @State private var openGroups: Set<String> = []

  init(settings: NodeSettingsViewModel, behavior: NodeDashboardCardItem? = nil) {
    self.settings = settings
    self.behavior = behavior
    _model = State(initialValue: RepeaterControlsModel(settings: settings))
  }

  var body: some View {
    CardForm {
      txPowerSection

      if let behavior {
        // one settings row: its title says what it is
        NodeDashboardCardGrid(items: [behavior])
          .environment(\.isInSettings, true)
      }

      CardFormSection(
        L10n.RemoteNodes.RemoteNodes.Controls.Tuning.title,
        info: L10n.RemoteNodes.RemoteNodes.Controls.Tuning.footer,
        footer: L10n.RemoteNodes.RemoteNodes.Controls.Groups.footer
      ) {
        ForEach(RepeaterControlsModel.groups) { group in
          groupView(group)
        }
      }

      CardFormSection(
        L10n.RemoteNodes.RemoteNodes.Controls.Commands.title,
        footer: L10n.RemoteNodes.RemoteNodes.Controls.Commands.footer
      ) {
        // Two across: the commands' full titles ("Sync Clock from GPS") would shrink at three.
        MetricTileGrid {
          ForEach(RepeaterControlsModel.commands) { command in
            Button {
              if command.confirmation != nil {
                pendingCommand = command
              } else {
                Task { await model.run(command) }
              }
            } label: {
              NodeActionTile(command.title, systemImage: command.systemImage, isBusy: model.busyKeys.contains(command.id))
                .tint(command.isDestructive ? Color.red : nil)
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.busyKeys.contains(command.id) ? L10n.RemoteNodes.RemoteNodes.Controls.inProgress : "")
            .radioDisabled(for: appState.connectionState, or: model.busyKeys.contains(command.id))
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if let outcome = model.outcome {
        RepeaterControlsBanner(outcome: outcome)
          .padding(.horizontal, CardStyle.pageInset)
          .padding(.bottom, 8)
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
          .task(id: outcome.id) {
            AccessibilityNotification.Announcement(
              [outcome.title, RepeaterControlsBanner.text(for: outcome)].joined(separator: ", ")
            ).post()
            try? await Task.sleep(for: .seconds(outcome.succeeded ? 2.5 : 5))
            withAnimation(reduceMotion ? nil : .snappy) { model.clearOutcome(outcome.id) }
          }
      }
    }
    .animation(reduceMotion ? nil : .snappy, value: model.outcome)
    .sensoryFeedback(trigger: model.outcome) { _, outcome in
      outcome.map { $0.succeeded ? .success : .error }
    }
    .confirmationDialog(
      pendingCommand?.confirmation ?? "",
      isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } }),
      titleVisibility: .visible,
      presenting: pendingCommand
    ) { command in
      Button(command.title, role: .destructive) {
        Task { await model.run(command) }
      }
      Button(L10n.Localizable.Common.cancel, role: .cancel) {}
    }
    .pageLoadingBar(loadProgress)
    .flashingNavigationTitle(L10n.RemoteNodes.RemoteNodes.Controls.title)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable {
      // what's on screen: the transmit power and the open groups, nothing closed
      await Task {
        await settings.fetchRadioSettings()
        for group in RepeaterControlsModel.groups where openGroups.contains(group.id) {
          await model.load(group, again: true)
        }
      }.value
    }
    .task {
      #if DEBUG
        Self.installUITestDemoReplies(on: settings)
      #endif
      if !settings.radioLoaded {
        await settings.fetchRadioSettings()
      }
    }
  }

  // MARK: - Groups

  /// A group: its card (title, what's in it or how far its reads are, a chevron) opens and closes it,
  /// and opening reads what this visit doesn't have yet. Open: its numbers in one card, then its switches.
  @ViewBuilder
  private func groupView(_ group: RepeaterTuningGroup) -> some View {
    let isOpen = openGroups.contains(group.id)
    let tunables = RepeaterControlsModel.tunables(in: group)
    Button {
      withAnimation(reduceMotion ? nil : .snappy) {
        if isOpen { openGroups.remove(group.id) } else { openGroups.insert(group.id) }
      }
      if !isOpen { Task { await model.load(group) } }
    } label: {
      HStack(spacing: 8) {
        SettingCardLabel(
          group.title,
          systemImage: group.systemImage,
          color: .teal,
          subtitle: groupSubtitle(group, count: tunables.count),
          isBusy: { if case .reading = model.progress(of: group) { return true } else { return false } }()
        )
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isOpen ? 90 : 0))
      }
      .contentShape(.rect)
      .cardSurface(padding: 12)
    }
    .buttonStyle(.plain)
    .accessibilityValue(isOpen ? L10n.RemoteNodes.RemoteNodes.Controls.Group.expanded : L10n.RemoteNodes.RemoteNodes.Controls.Group.collapsed)
    .accessibilityHint(groupSubtitle(group, count: tunables.count))

    if isOpen {
      let numbers = model.shown(tunables.filter { if case .number = $0.kind { return true } else { return false } })
      let options = model.shown(tunables.filter { if case .number = $0.kind { return false } else { return true } })
      if !numbers.isEmpty {
        ContentCard {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(numbers.enumerated()), id: \.element.id) { index, tunable in
              if index > 0 { Divider() }
              RepeaterNumberRow(tunable: tunable, model: model)
            }
          }
        }
      }
      ForEach(options) { tunable in
        RepeaterOptionCard(tunable: tunable, model: model)
      }
      if numbers.isEmpty, options.isEmpty, model.progress(of: group) == .read {
        Text(L10n.RemoteNodes.RemoteNodes.Controls.Group.noneOnFirmware)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
      }
    }
  }

  /// Under a group's title: "Tap to read 5 settings" before its first read, "Reading 2 of 5…" while
  /// it's read, then what's in it.
  private func groupSubtitle(_ group: RepeaterTuningGroup, count: Int) -> String {
    switch model.progress(of: group) {
    case .notRead: L10n.RemoteNodes.RemoteNodes.Controls.Group.tapToRead(count)
    case let .reading(done, total): L10n.RemoteNodes.RemoteNodes.Controls.Group.reading(min(done + 1, total), total)
    case .read: group.detail
    }
  }

  /// The page's reads as steps, "Airtime Factor · 2 of 6": the radio (for the transmit power), then
  /// each setting of the open groups in turn, with the running one's icon. Nil once nothing is being read.
  private var loadProgress: NodeLoadProgress? {
    let all = RepeaterControlsModel.groups.filter { openGroups.contains($0.id) }.flatMap(RepeaterControlsModel.tunables(in:))
    let reading = all.first { model.states[$0.key] == .loading }
    guard settings.isLoadingRadio || reading != nil else { return nil }
    let done = all.count(where: { model.states[$0.key].map { $0 != .loading } ?? false })
      + (settings.isLoadingRadio ? 0 : 1)
    let running = settings.isLoadingRadio ? nil : reading
    let icon = running?.icon ?? Self.txIcon
    return NodeLoadProgress(
      done: done,
      total: all.count + 1,
      title: running?.title ?? L10n.Settings.Dashboard.txPower,
      systemImage: icon.systemImage,
      color: icon.color
    )
  }

  // MARK: - Transmit power

  private static let txIcon = (systemImage: "antenna.radiowaves.left.and.right", color: Color.orange)

  /// The radio chip settings the node takes: -9 up to its reported maximum (`txm=`, 22 from a node
  /// that reports none). A stored value outside it (an older firmware's unchecked 30) shows in the
  /// headline and caption only; the slider and stepper stay within the range.
  private var txRange: ClosedRange<Int> { settings.txPowerRange }

  /// A power outside the range, brought into it.
  private func clampedTx(_ dbm: Int) -> Int {
    min(txRange.upperBound, max(txRange.lowerBound, dbm))
  }

  /// Under the setting: on a node that reports a PA (`txa=`), what it radiates now and at most;
  /// else the setting in milliwatts.
  private func txCaption(_ setting: Int) -> String {
    guard txRange.contains(setting) else {
      return L10n.RemoteNodes.RemoteNodes.Settings.txPowerOutOfRange(txRange.lowerBound, txRange.upperBound)
    }
    guard settings.txIsAmplified, let antennaMax = settings.txAntennaMax else { return Self.milliwatts(setting) }
    guard let antenna = settings.txAntennaPower else {
      return L10n.RemoteNodes.RemoteNodes.Controls.Tx.amplifiedCaptionMax(dBm(Double(antennaMax)))
    }
    return L10n.RemoteNodes.RemoteNodes.Controls.Tx.amplifiedCaption(dBm(Double(antenna)), dBm(Double(antennaMax)))
  }

  private var currentTx: Int? { settings.originalTxPower ?? settings.txPower }

  private var shownTx: Double? {
    txDraft ?? currentTx.map(Double.init)
  }

  private func dBm(_ value: Double) -> String {
    L10n.Settings.DeviceInfo.txPowerFormat(Int(value).formatted())
  }

  private var txPowerSection: some View {
    CardFormSection(footer: L10n.RemoteNodes.RemoteNodes.Controls.Tx.footer) {
      ContentCard {
        // The card's title, as `ContentCard` draws it, but a heading: the page's lead section.
        SettingCardLabel(L10n.Settings.Dashboard.txPower, systemImage: Self.txIcon.systemImage, color: Self.txIcon.color)
          .accessibilityAddTraits(.isHeader)
        if let shownTx {
          VStack(alignment: .leading, spacing: 2) {
            Text(dBm(shownTx))
              .font(.system(.largeTitle, design: .rounded).weight(.bold))
              .monospacedDigit()
              .contentTransition(.numericText(value: shownTx))
            Text(txCaption(Int(shownTx)))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .animation(reduceMotion ? nil : .snappy, value: shownTx)
          .accessibilityElement(children: .combine)

          Slider(
            value: Binding(get: { Double(clampedTx(Int(shownTx))) }, set: { txDraft = $0.rounded() }),
            in: Double(txRange.lowerBound)...Double(txRange.upperBound),
            step: 1
          ) {
            Text(L10n.Settings.Dashboard.txPower)
          } minimumValueLabel: {
            Text(txRange.lowerBound.formatted())
          } maximumValueLabel: {
            Text(txRange.upperBound.formatted())
          }
          .accessibilityValue(dBm(shownTx))
          .sensoryFeedback(.selection, trigger: Int(shownTx))
          .disabled(model.busyKeys.contains("tx"))   // held while a power is being sent

          Divider()

          Stepper(
            // A power outside the node's range (an older firmware's unchecked value) steps back into it.
            value: Binding(get: { clampedTx(Int(shownTx)) }, set: { txDraft = Double(clampedTx($0)) }),
            in: txRange
          ) {
            Text(L10n.Settings.AdvancedRadio.txPower)
          }
          .accessibilityValue(dBm(shownTx))
          .disabled(model.busyKeys.contains("tx"))
        } else if settings.isLoadingRadio {
          HStack {
            ProgressView()
            Text(L10n.RemoteNodes.RemoteNodes.Settings.loading)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else if settings.radioError {
          NodeCardLoadFailure {
            await settings.fetchRadioSettings()
          }
          .radioDisabled(for: appState.connectionState)
        } else {
          SettingsLoadPlaceholder(isLoading: false, hasError: false)
        }
      }

      if let shownTx {
        let changed = txDraft.map { Int($0) != currentTx } ?? false
        let isApplying = model.busyKeys.contains("tx")
        Button {
          guard let sent = txDraft else { return }
          Task {
            await model.applyTxPower(Int(sent))
            if self.txDraft == sent { self.txDraft = nil }   // a newer pick stays
          }
        } label: {
          Group {
            if isApplying {
              ProgressView()
            } else {
              Text(changed
                ? L10n.RemoteNodes.RemoteNodes.Controls.Tx.apply(Int(shownTx))
                : L10n.RemoteNodes.RemoteNodes.Controls.Tx.current)
            }
          }
          .font(.headline)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel(changed
          ? L10n.RemoteNodes.RemoteNodes.Controls.Tx.apply(Int(shownTx))
          : L10n.RemoteNodes.RemoteNodes.Controls.Tx.current)
        .accessibilityValue(isApplying ? L10n.RemoteNodes.RemoteNodes.Controls.inProgress : "")
        .radioDisabled(for: appState.connectionState, or: !changed || isApplying)
      }
    }
  }

  /// "≈ 158 mW": what a dBm figure is in milliwatts.
  static func milliwatts(_ dbm: Int) -> String {
    let mw = pow(10, Double(dbm) / 10)
    let figure: Measurement<UnitPower> = Measurement(value: mw, unit: .milliwatts)
    let style: FloatingPointFormatStyle<Double> = mw >= 100 ? .number.precision(.fractionLength(0))
      : .number.precision(.significantDigits(2))
    return L10n.RemoteNodes.RemoteNodes.Controls.Tx.milliwatts(
      figure.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: style))
    )
  }

  #if DEBUG
    /// UI tests (`-uiTestControlsDemo`): the mock radio answers no CLI, so canned replies stand in
    /// for a repeater's, one of them "unknown command" to show a setting the firmware lacks.
    /// Sets answer "OK", so Apply, the switches and the banner work too.
    private static func installUITestDemoReplies(on settings: NodeSettingsViewModel) {
      guard ProcessInfo.processInfo.arguments.contains("-uiTestControlsDemo"), let session = settings.session else { return }
      let replies = [
        "get tx": "> 22", "get radio": "> 869.525,250.0,11,5", "get af": "> 1.0", "get rxdelay": "> 0.0",
        "get txdelay": "> 0.5", "get direct.txdelay": "> 0.2", "get int.thresh": "> 14",
        "get agc.reset.interval": "Error: unknown command", "get multi.acks": "> 1",
        "get allow.read.only": "> on", "get radio.rxgain": "> off", "get radio.fem.rxgain": "> on",
        "powersaving": "> off", "gps": "> on",
        "get loop.detect": "> moderate",
      ]
      let reply: (UUID, String, Duration) async throws -> String = { _, command, _ in
        try await Task.sleep(for: .milliseconds(150))
        return replies[command] ?? "> OK"
      }
      settings.configure(session: session, sendCommand: reply, sendRawCommand: reply)
      settings.radioError = false
    }
  #endif
}

// MARK: - Icons

private extension RepeaterTunable {
  /// The row's icon tile: tuning in the Radio tuning colours, switches in the Behavior colour.
  var icon: (systemImage: String, color: Color) {
    switch key {
    case "af": ("timer", .orange)
    case "rxdelay": ("hourglass", .teal)
    case "txdelay": ("dice", .teal)
    case "direct.txdelay": ("arrow.right.circle", .teal)
    case "int.thresh": ("waveform.badge.exclamationmark", .teal)
    case "agc.reset.interval": ("dial.low", .teal)
    case "multi.acks": ("checkmark.message", .indigo)
    case "allow.read.only": ("eye", .indigo)
    case "radio.rxgain": ("ear.badge.waveform", .indigo)
    case "radio.fem.rxgain": ("dot.radiowaves.left.and.right", .orange)
    case "powersaving": ("leaf", .indigo)
    case "gps": ("location", .indigo)
    case "loop.detect": ("arrow.triangle.2.circlepath", .indigo)
    case "dutycycle": ("percent", .orange)
    case "flood.max.advert": ("megaphone", .teal)
    case "flood.max.unscoped": ("globe", .teal)
    case "bridge.delay": ("hourglass.bottomhalf.filled", .purple)
    case "bridge.baud": ("speedometer", .purple)
    case "bridge.channel": ("wifi", .purple)
    case "cad": ("ear", .indigo)
    case "path.hash.mode": ("number", .indigo)
    case "gps.advert": ("location.viewfinder", .indigo)
    case "bridge.enabled": ("arrow.left.arrow.right", .purple)
    case "bridge.source": ("arrow.triangle.branch", .purple)
    default: ("slider.horizontal.3", .indigo)
    }
  }
}

// MARK: - Row states

/// What a setting shows in place of its control until it has a value: a placeholder while it's
/// read, "Not supported" when the firmware lacks it, or "Failed to load" with a reload.
private struct RepeaterTunableStateView: View {
  @Environment(\.appState) private var appState

  let tunable: RepeaterTunable
  let state: RepeaterControlsModel.ReadState
  let model: RepeaterControlsModel

  private enum Layout {
    /// Grows the caption-size reload icon's hit area to about 44 pt, as `SectionReloadButton` does.
    static let reloadHitSlop: CGFloat = 16
  }

  var body: some View {
    switch state {
    case .loading:
      SettingsLoadPlaceholder(isLoading: true, hasError: false)
    case .unsupported:
      Text(L10n.RemoteNodes.RemoteNodes.Controls.unsupported)
        .font(.caption)
        .foregroundStyle(.secondary)
    case .failed:
      HStack(spacing: 4) {
        SettingsLoadPlaceholder(isLoading: false, hasError: true)
        Button {
          Task { await model.read(tunable) }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.caption)
            .padding(Layout.reloadHitSlop)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .padding(-Layout.reloadHitSlop)
        .accessibilityLabel(L10n.Localizable.Common.reloadSection(tunable.title))
        // Gated as the transmit power's Try Again is: no reload while the radio isn't ready.
        .radioDisabled(for: appState.connectionState)
      }
    case .value:
      EmptyView()
    }
  }
}

// MARK: - Number rows

/// One stepped setting in the Tuning card, laid out as the radio's own Tuning rows: icon and
/// title, the value and a stepper, what it does beneath, and "Not applied" with Revert and Apply
/// once it's been changed here.
private struct RepeaterNumberRow: View {
  @Environment(\.appState) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let tunable: RepeaterTunable
  let model: RepeaterControlsModel

  private var state: RepeaterControlsModel.ReadState { model.states[tunable.key] ?? .loading }
  private var isBusy: Bool { model.busyKeys.contains(tunable.key) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        SettingCardLabel(tunable.title, systemImage: tunable.icon.systemImage, color: tunable.icon.color, isBusy: isBusy)
          .accessibilityHidden(state.isValue)
          .opacity(state == .unsupported ? 0.5 : 1)
        Spacer(minLength: 8)
        if case let .value(current) = state {
          stepper(current: current)
        } else {
          RepeaterTunableStateView(tunable: tunable, state: state, model: model)
        }
      }
      Text(tunable.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(state == .unsupported ? 0.5 : 1)
      if let pending {
        pendingBar(value: pending)
      }
    }
    .animation(reduceMotion ? nil : .snappy, value: model.drafts[tunable.key])
  }

  /// The edited value, when it differs from the repeater's.
  private var pending: String? {
    guard let draft = model.drafts[tunable.key], case let .value(current) = state, draft != current else { return nil }
    return draft
  }

  @ViewBuilder
  private func stepper(current: String) -> some View {
    if case let .number(range, step, digits) = tunable.kind {
      let shown = Double(model.drafts[tunable.key] ?? current) ?? range.lowerBound
      let formatted = [Self.format(shown, digits: digits, range: range, step: step), tunable.unit]
        .compactMap(\.self).joined(separator: " ")
      Stepper(value: Binding(
        get: { shown },
        set: { model.drafts[tunable.key] = Self.format($0, digits: digits, range: range, step: step) }
      ), in: range, step: step) {
        Text(formatted)
          .font(.body.monospacedDigit())
          .foregroundStyle(model.drafts[tunable.key] == nil ? Color.secondary : Color.accentColor)
          .contentTransition(.numericText(value: shown))
      }
      .fixedSize()
      .accessibilityLabel(tunable.title)
      .accessibilityValue(isBusy ? [formatted, L10n.RemoteNodes.RemoteNodes.Controls.inProgress].joined(separator: ", ") : formatted)
      .radioDisabled(for: appState.connectionState, or: isBusy)
    }
  }

  private func pendingBar(value draft: String) -> some View {
    // twice the hit slop apart, so Revert's and Apply's grown tap areas never overlap
    HStack(spacing: Layout.hitSlop.leading + Layout.hitSlop.trailing) {
      Text(L10n.Settings.Radio.Tile.pending)
        .font(.caption)
        .foregroundStyle(Color.accentColor)
      Spacer()
      Button {
        model.drafts[tunable.key] = nil
      } label: {
        hitArea(Text(L10n.RemoteNodes.RemoteNodes.Controls.revert))
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .padding(-Layout.hitSlop)
      Button {
        guard case let .number(range, step, digits) = tunable.kind else { return }
        Task { await model.write(tunable, value: Self.format(Double(draft) ?? 0, digits: digits, range: range, step: step)) }
      } label: {
        hitArea(Text(L10n.RemoteNodes.RemoteNodes.Controls.apply))
      }
      .buttonStyle(.borderless)
      .fontWeight(.semibold)
      .padding(-Layout.hitSlop)
      .accessibilityValue(isBusy ? L10n.RemoteNodes.RemoteNodes.Controls.inProgress : "")
      .radioDisabled(for: appState.connectionState, or: isBusy)
    }
    .padding(.top, 2)
  }

  private enum Layout {
    /// Grows the text-only Revert and Apply to at least 44 pt to tap, without moving the row.
    static let hitSlop = EdgeInsets(top: 11, leading: 8, bottom: 11, trailing: 8)
  }

  private func hitArea(_ text: Text) -> some View {
    text
      .padding(Layout.hitSlop)
      .contentShape(.rect)
  }

  static func format(_ value: Double, digits: Int, range: ClosedRange<Double>, step: Double) -> String {
    let clamped = min(range.upperBound, max(range.lowerBound, value))
    return clamped.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
  }
}

// MARK: - Option cards

/// One switch or menu in Options, as its own card: the whole card is the switch (`ToggleCard`),
/// or the menu sits trailing (`PickerCard`). Until it has a value, the card shows why.
private struct RepeaterOptionCard: View {
  @Environment(\.appState) private var appState

  let tunable: RepeaterTunable
  let model: RepeaterControlsModel

  private var state: RepeaterControlsModel.ReadState { model.states[tunable.key] ?? .loading }
  private var isBusy: Bool { model.busyKeys.contains(tunable.key) }

  /// The card's name for VoiceOver (with what it does, for the switch), saying when it's being sent.
  private func accessibilityTitle(includingDetail: Bool) -> String {
    ([tunable.title] + (includingDetail ? [tunable.detail] : [])
      + (isBusy ? [L10n.RemoteNodes.RemoteNodes.Controls.inProgress] : []))
      .joined(separator: ", ")
  }

  private var label: SettingCardLabel {
    SettingCardLabel(
      tunable.title,
      systemImage: tunable.icon.systemImage,
      color: tunable.icon.color,
      subtitle: tunable.detail,
      isBusy: isBusy
    )
  }

  var body: some View {
    Group {
      switch (state, tunable.kind) {
      case let (.value(current), .toggle):
        Toggle(isOn: Binding(
          get: { current == "on" },
          set: { isOn in Task { await model.write(tunable, value: isOn ? "on" : "off") } }
        )) {
          label
        }
        .accessibilityLabel(accessibilityTitle(includingDetail: true))
        .radioDisabled(for: appState.connectionState, or: isBusy)
      case let (.value(current), .choice(options)):
        HStack(spacing: 8) {
          label
          Spacer(minLength: 8)
          Picker(tunable.title, selection: Binding(
            get: { current },
            set: { choice in Task { await model.write(tunable, value: choice) } }
          )) {
            ForEach(options, id: \.self) { option in
              Text(tunable.title(of: option)).tag(option)
            }
            if !options.contains(current) {
              Text(current).tag(current)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .tint(.primary)
          .accessibilityLabel(accessibilityTitle(includingDetail: false))
          .radioDisabled(for: appState.connectionState, or: isBusy)
        }
      default:
        HStack(spacing: 8) {
          label
            .opacity(state == .unsupported ? 0.5 : 1)
          Spacer(minLength: 8)
          RepeaterTunableStateView(tunable: tunable, state: state, model: model)
        }
      }
    }
    .cardSurface(padding: 12)
  }
}

private extension RepeaterControlsModel.ReadState {
  var isValue: Bool {
    if case .value = self { return true }
    return false
  }
}

// MARK: - Banner

/// What a command or a change came back with, for a moment at the foot of the page.
private struct RepeaterControlsBanner: View {
  let outcome: RepeaterControlsModel.Outcome

  private enum Layout {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 10
  }

  static func text(for outcome: RepeaterControlsModel.Outcome) -> String {
    outcome.reply ?? (outcome.succeeded
      ? L10n.RemoteNodes.RemoteNodes.Settings.settingsApplied
      : L10n.RemoteNodes.RemoteNodes.Controls.failed)
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(outcome.succeeded ? .green : .orange)
        .font(.title3)
      VStack(alignment: .leading, spacing: 1) {
        Text(outcome.title)
          .font(.subheadline.weight(.semibold))
        Text(Self.text(for: outcome))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      Spacer(minLength: 0)
    }
    // The app's glass chips and map banners (TracePath, the neighbor map's pills): 16 by 10.
    .padding(.horizontal, Layout.horizontalPadding)
    .padding(.vertical, Layout.verticalPadding)
    .frame(maxWidth: 520)
    .liquidGlass(in: .rect(cornerRadius: CardStyle.cornerRadius + 6, style: .continuous))
    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    .accessibilityElement(children: .combine)
  }
}
