import CairnServices
import Charts
import MeshCore
import SwiftUI

/// The Map tab's Trips page (the hiking button in its bar): the trips the radio recorded.
///
/// - Record Trip / Stop Recording, which start and stop the radio's recorder (`TripRecorder`): the radio
///   keeps the trip on its card from its own GPS; the phone's GPS records nothing. Under it, how the radio
///   is: its GPS, its card, or why it can't record.
/// - The trips, newest first: what this phone copied and what is still only on the radio's card, each
///   with the radio's own distance, time and climb. Opening one copies it here (`TripDetailView`); Copy
///   All copies every one, for when there's no radio to hand.
/// - The last 14 days of steps from a Cairn radio's step counter.
struct TripsView: View {
  @Environment(\.appState) private var appState

  @State private var model = TripsModel()
  @State private var refusal: CairnTripStatus?
  @State private var copyingAll = false

  private static let teal = HomeStatusCards.cairnTeal

  var body: some View {
    let recorder = appState.tripRecorder
    CardForm {
      CardFormSection(footer: recorder.support == .supported ? L10n.Map.Map.Trips.Record.footer : nil) {
        recordCard(recorder)
      }

      CardFormSection(L10n.Map.Map.Trips.Logs.title, footer: model.logs.isEmpty ? nil : L10n.Map.Map.Trips.Logs.footer) {
        if model.logs.isEmpty {
          if model.hasLoaded {
            Text(L10n.Map.Map.Trips.Logs.empty)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .cardSurface(padding: 12)
          }
        } else {
          ForEach(model.logs) { log in
            NavigationLink(value: TripRoute(id: log.id)) {
              TripLogRow(log: log, progress: recorder.copying[log.id])
            }
            .buttonStyle(.plain)
          }
        }
      }

      stepsChart
    }
    .navigationTitle(L10n.Map.Map.Trips.title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(for: TripRoute.self) { route in TripDetailView(id: route.id) }
    .toolbar {
      if model.logs.contains(where: { recorder.canCopy($0) && !$0.isComplete }) {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            copyingAll = true
            Task {
              await recorder.copyAll()
              copyingAll = false
            }
          } label: {
            if copyingAll { ProgressView() } else { Label(L10n.Map.Map.Trips.Logs.copyAll, systemImage: "arrow.down.circle") }
          }
          .disabled(copyingAll)
          .accessibilityIdentifier("trips.copyAll")
        }
      }
    }
    .alert(
      refusal.map(Self.refusalText) ?? "",
      isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
    ) {
      Button(L10n.Localizable.Common.ok) { refusal = nil }
    }
    .task(id: recorder.version) {
      await model.load(store: appState.connectionManager.persistenceStore)
    }
    .task(id: appState.connectedDevice?.id) {
      await recorder.refresh()
      // while the radio records, its point count and fix every 15 s
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        if Task.isCancelled { break }
        if recorder.isRecording { await recorder.refreshState() }
      }
    }
  }

  // MARK: - Recording

  private func recordCard(_ recorder: TripRecorder) -> some View {
    VStack(spacing: 10) {
      Button {
        Task { refusal = await recorder.toggleRecording() }
      } label: {
        VStack(spacing: 2) {
          if recorder.isSwitching {
            ProgressView().tint(.white)
          } else {
            Label(
              recorder.isRecording ? L10n.Map.Map.Trips.Record.stop : L10n.Map.Map.Trips.Record.start,
              systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
            )
            .font(.headline)
          }
          if recorder.isRecording, let since = recorder.recordingStartedAt {
            Text(L10n.Map.Map.Trips.Record.since(since.formatted(date: .omitted, time: .shortened)))
              .font(.caption)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 36)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(recorder.isRecording ? .red : Self.teal)
      .disabled(recorder.support != .supported || recorder.isSwitching)
      .accessibilityIdentifier("trips.record")

      radioLine(recorder)
    }
    .cardSurface(padding: 12)
  }

  /// How the radio is, under the button: its GPS and card, or why it can't record.
  @ViewBuilder
  private func radioLine(_ recorder: TripRecorder) -> some View {
    switch recorder.support {
    case .unknown:
      Text(L10n.Map.Map.Trips.Radio.none)
        .font(.footnote)
        .foregroundStyle(.secondary)
    case .unsupported:
      Text(L10n.Map.Map.Trips.Radio.unsupported)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    case .supported:
      if let state = recorder.radioState {
        HStack(spacing: 16) {
          gpsLabel(state)
          if !state.hasCard {
            Label(L10n.Map.Map.Trips.Radio.noCard, systemImage: "sdcard")
              .foregroundStyle(.orange)
          }
        }
        .font(.footnote)
        .labelStyle(.titleAndIcon)
      }
    }
  }

  private func gpsLabel(_ state: CairnTripState) -> some View {
    let (text, color): (String, Color) = !state.isGPSOn
      ? (L10n.Map.Map.Trips.Radio.gpsOff, .orange)
      : state.hasFix ? (L10n.Map.Map.Trips.Radio.fix, .green) : (L10n.Map.Map.Trips.Radio.searching, .secondary)
    return Label(text, systemImage: state.hasFix ? "location.fill" : "location.slash")
      .foregroundStyle(color)
  }

  static func refusalText(_ status: CairnTripStatus) -> String {
    switch status {
    case .gpsOff: L10n.Map.Map.Trips.Refused.gpsOff
    case .noClock: L10n.Map.Map.Trips.Refused.noClock
    case .noCard: L10n.Map.Map.Trips.Refused.noCard
    case .busy: L10n.Map.Map.Trips.Refused.busy
    default: L10n.Map.Map.Trips.Refused.failed
    }
  }

  // MARK: - Steps

  /// The last 14 days of steps as bars, today in full green and the rest softer.
  private var stepsChart: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(L10n.Map.Map.Trips.Chart.steps, systemImage: "figure.walk")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.green)
      if model.steps.isEmpty {
        Text(L10n.Map.Map.Trips.Chart.noSteps)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Chart {
          ForEach(model.steps, id: \.day) { entry in
            BarMark(x: .value("Day", entry.day, unit: .day), y: .value("Steps", entry.steps))
              .foregroundStyle(Calendar.current.isDateInToday(entry.day) ? Color.green : Color.green.opacity(0.4))
              .cornerRadius(3)
          }
        }
        .chartXAxis {
          AxisMarks(values: .stride(by: .day, count: 2)) { _ in
            AxisValueLabel(format: .dateTime.day())
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            AxisValueLabel()
          }
        }
        .frame(height: 120)
        Text(L10n.Map.Map.Trips.Chart.stepsFooter)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .cardSurface(padding: 12)
  }
}

/// A trip on the Trips page.
struct TripRoute: Hashable {
  let id: String
}

/// One trip in the list: when it started, how far and how long, the climb, and where it is (recording,
/// on this iPhone, copying, only on the radio, or only here now).
struct TripLogRow: View {
  let log: TripLogDTO
  let progress: (done: Int, total: Int)?

  private static let teal = HomeStatusCards.cairnTeal

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: log.isRecording ? "record.circle" : "figure.hiking")
        .font(.title3)
        .foregroundStyle(log.isRecording ? Color.red : Self.teal)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(log.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
        HStack(spacing: 10) {
          Text(TripFormat.distance(log.distance))
          Text(TripFormat.duration(log.movingTime))
          if log.climb > 0 {
            Label(TripFormat.altitude(log.climb), systemImage: "arrow.up.right")
              .labelStyle(.titleAndIcon)
          }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      badge
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
    .cardSurface(padding: 12)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var badge: some View {
    if log.isRecording {
      tag(L10n.Map.Map.Trips.Status.recording, .red)
    } else if let progress, progress.total > 0 {
      tag(L10n.Map.Map.Trips.Status.copying(min(99, progress.done * 100 / progress.total)), Self.teal)
    } else if !log.onRadio {
      tag(L10n.Map.Map.Trips.Status.phoneOnly, .secondary)
    } else if log.isComplete {
      tag(L10n.Map.Map.Trips.Status.copied, .green)
    } else {
      tag(L10n.Map.Map.Trips.Status.onRadio, .secondary)
    }
  }

  private func tag(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(color.opacity(0.14)))
  }
}
