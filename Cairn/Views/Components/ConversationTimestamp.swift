import SwiftUI

struct ConversationTimestamp: View {
  let date: Date
  var font: Font = .caption
  var referenceDate: Date?

  var body: some View {
    if let referenceDate {
      Text(formattedDate(relativeTo: referenceDate))
        .font(font)
        .foregroundStyle(.secondary)
    } else {
      TimelineView(.everyMinute) { context in
        Text(formattedDate(relativeTo: context.date))
          .font(font)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The time for today; otherwise the day in words, as the chat's day dividers say it
  /// (Yesterday, a weekday, a date).
  private func formattedDate(relativeTo now: Date) -> String {
    if Calendar.current.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    return ChatDayLabel.text(for: date, relativeTo: now)
  }
}
