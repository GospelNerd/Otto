import Foundation

/// A five-field cron expression (minute, hour, day-of-month, month, day-of-week) supporting
/// `*`, single values, ranges (`a-b`), steps (`*/n`, `a-b/n`, `a/n`), and comma lists. Days
/// of week are numeric, 0–7 where both 0 and 7 mean Sunday. Standard cron semantics apply: when
/// both day fields are restricted, a day matches if either field matches.
public struct CronExpression: Equatable, Sendable {
  public let expression: String
  private let minutes: Set<Int>
  private let hours: Set<Int>
  private let daysOfMonth: Set<Int>
  private let months: Set<Int>
  /// Calendar weekday values, 1 (Sunday) through 7 (Saturday).
  private let weekdays: Set<Int>
  private let dayOfMonthRestricted: Bool
  private let dayOfWeekRestricted: Bool

  public init?(_ expression: String) {
    let fields = expression.split(separator: " ", omittingEmptySubsequences: true)
      .map(String.init)
    guard fields.count == 5,
      let minutes = Self.parseField(fields[0], range: 0...59),
      let hours = Self.parseField(fields[1], range: 0...23),
      let daysOfMonth = Self.parseField(fields[2], range: 1...31),
      let months = Self.parseField(fields[3], range: 1...12),
      let rawWeekdays = Self.parseField(fields[4], range: 0...7)
    else { return nil }
    self.expression = expression
    self.minutes = minutes.values
    self.hours = hours.values
    self.daysOfMonth = daysOfMonth.values
    self.months = months.values
    weekdays = Set(rawWeekdays.values.map { ($0 % 7) + 1 })
    dayOfMonthRestricted = daysOfMonth.restricted
    dayOfWeekRestricted = rawWeekdays.restricted
  }

  /// The first fire date strictly after `date`, or nil if none exists within four years
  /// (e.g. `0 0 30 2 *`).
  public func nextFire(after date: Date, timeZone: TimeZone = .current) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard var day = calendar.dateInterval(of: .day, for: date)?.start else { return nil }
    let sortedHours = hours.sorted()
    let sortedMinutes = minutes.sorted()
    for _ in 0..<1_462 {
      let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
      if let month = components.month, let dayOfMonth = components.day,
        let weekday = components.weekday, months.contains(month),
        matchesDay(dayOfMonth: dayOfMonth, weekday: weekday)
      {
        for hour in sortedHours {
          for minute in sortedMinutes {
            var fireComponents = components
            fireComponents.hour = hour
            fireComponents.minute = minute
            fireComponents.second = 0
            fireComponents.weekday = nil
            if let fire = calendar.date(from: fireComponents), fire > date {
              return fire
            }
          }
        }
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
      day = next
    }
    return nil
  }

  private func matchesDay(dayOfMonth: Int, weekday: Int) -> Bool {
    let monthMatch = daysOfMonth.contains(dayOfMonth)
    let weekMatch = weekdays.contains(weekday)
    switch (dayOfMonthRestricted, dayOfWeekRestricted) {
    case (true, true): return monthMatch || weekMatch
    case (true, false): return monthMatch
    case (false, true): return weekMatch
    case (false, false): return true
    }
  }

  private static func parseField(
    _ field: String, range: ClosedRange<Int>
  ) -> (values: Set<Int>, restricted: Bool)? {
    if field == "*" { return (Set(range), false) }
    var values: Set<Int> = []
    for part in field.split(separator: ",", omittingEmptySubsequences: false) {
      guard let parsed = parseComponent(String(part), range: range) else { return nil }
      values.formUnion(parsed)
    }
    guard !values.isEmpty else { return nil }
    return (values, true)
  }

  private static func parseComponent(_ component: String, range: ClosedRange<Int>) -> Set<Int>? {
    let pieces = component.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...2).contains(pieces.count) else { return nil }
    var step = 1
    if pieces.count == 2 {
      guard let parsedStep = Int(pieces[1]), parsedStep >= 1 else { return nil }
      step = parsedStep
    }
    let base = String(pieces[0])
    let span: ClosedRange<Int>
    if base == "*" {
      span = range
    } else if base.contains("-") {
      let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
      guard bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]),
        low <= high, range.contains(low), range.contains(high)
      else { return nil }
      span = low...high
    } else {
      guard let value = Int(base), range.contains(value) else { return nil }
      // `a/n` is standard cron shorthand for `a-<field maximum>/n`, stepping from the start
      // value to the end of the field. A plain `a` keeps its single-value meaning.
      if step > 1 {
        span = value...range.upperBound
      } else {
        return [value]
      }
    }
    return Set(stride(from: span.lowerBound, through: span.upperBound, by: step))
  }
}
