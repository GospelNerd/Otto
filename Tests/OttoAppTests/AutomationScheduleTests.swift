import Foundation
import Testing

@testable import OttoApp

@Suite("Automation schedules")
struct AutomationScheduleTests {
  @Test("Friendly schedules round-trip through cron and read in plain words")
  func roundTrip() throws {
    let cases: [(AutomationSchedule, String, String)] = [
      (.init(frequency: .daily, hour: 7, minute: 30), "30 7 * * *", "Every day at 07:30"),
      (.init(frequency: .weekdays, hour: 9, minute: 0), "0 9 * * 1-5", "Weekdays at 09:00"),
      (
        .init(frequency: .weekly, hour: 16, minute: 5, weekday: 6), "5 16 * * 5", "Fridays at 16:05"
      ),
      (.init(frequency: .hourly, hour: 0, minute: 15), "15 * * * *", "Every hour"),
    ]
    for (schedule, cron, label) in cases {
      #expect(schedule.cron == cron)
      let parsed = try #require(AutomationSchedule(cron: cron))
      #expect(parsed.cron == cron)
      #expect(parsed.label == label)
    }
    #expect(AutomationSchedule(cron: "*/5 * 1 * *") == nil)
    #expect(AutomationSchedule(cron: "nonsense") == nil)
  }

  @Test("Out-of-range clock values are rejected, not echoed back")
  func clockRanges() throws {
    // The friendly editor only ever writes in-range values, but a routine saved from an agent
    // tool can carry any cron. Without a guard, "5 24 * * *" parsed as "Every day at 24:05" and
    // the editor round-tripped it back to the same invalid cron; the store's CronExpression
    // validator then refused every save that touched the routine.
    #expect(AutomationSchedule(cron: "5 24 * * *") == nil)
    #expect(AutomationSchedule(cron: "99 9 * * *") == nil)
    #expect(AutomationSchedule(cron: "60 9 * * *") == nil)
    #expect(AutomationSchedule(cron: "30 23 * * *") != nil)
    #expect(AutomationSchedule(cron: "0 0 * * *") != nil)
    // The weekday field has always been range-checked here; clock values were missed.
    #expect(AutomationSchedule(cron: "30 7 * * 8") == nil)
  }
}
