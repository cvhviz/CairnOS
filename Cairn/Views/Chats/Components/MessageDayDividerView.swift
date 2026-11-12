import SwiftUI

/// The day a message or conversation belongs to, in words: Today and Yesterday by name, the weekday
/// within the past week, then the date (with the year only when it isn't this one). Localized by
/// the system's own relative-date words.
enum ChatDayLabel {
  static func text(for date: Date, relativeTo now: Date = .now, calendar: Calendar = .current) -> String {
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    switch days {
    case 0, 1:
      let formatter = RelativeDateTimeFormatter()
      formatter.dateTimeStyle = .named
      formatter.unitsStyle = .full
      formatter.formattingContext = .standalone
      return formatter.localizedString(from: DateComponents(day: -days))
    case 2 ..< 7:
      return date.formatted(.dateTime.weekday(.wide))
    default:
      let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
      return sameYear
        ? date.formatted(.dateTime.month(.abbreviated).day())
        : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
  }
}

/// Day separator shown once per calendar day in chat history: the day in words (`ChatDayLabel`)
/// on a small pill centred between the messages, so the history reads in days at a glance.
struct MessageDayDividerView: View {
  let date: Date

  var body: some View {
    TimelineView(.everyMinute) { context in
      Text(ChatDayLabel.text(for: date, relativeTo: context.date))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .fixedSize()
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
    }
    .padding(.vertical, 6)
  }
}

#Preview("Today") {
  MessageDayDividerView(date: Date())
    .padding()
}

#Preview("Yesterday") {
  MessageDayDividerView(date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
    .padding()
}

#Preview("Last Year") {
  MessageDayDividerView(date: Calendar.current.date(byAdding: .year, value: -1, to: Date())!)
    .padding()
}
