import Foundation
import OttoModels
import Testing

@testable import OttoApp

@Suite("Activity inbox digest")
struct ActivityInboxDigestTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  // 2027-01-15 08:00 UTC
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let woody = UUID()
  private let coder = UUID()

  private func item(
    _ id: String, _ state: BotActivityState, _ link: BotActivityDeepLink, hoursAgo: Double,
    title: String = "Woody", detail: String? = nil
  ) -> BotActivityItem {
    BotActivityItem(
      id: id, state: state, title: title, detail: detail, deepLink: link,
      sourceEventSequence: 1, updatedAt: now.addingTimeInterval(-hoursAgo * 3600))
  }

  @Test("One source collapses to its latest run and a count")
  @MainActor func collapsesASource() {
    let link = BotActivityDeepLink.bot(profileID: woody, channelID: nil)
    let rows = ActivityInboxDigest.rows(
      from: [
        item("a", .completed, link, hoursAgo: 3, detail: "first"),
        item("b", .completed, link, hoursAgo: 2, detail: "second"),
        item("c", .completed, link, hoursAgo: 1, detail: "third"),
      ], now: now, calendar: calendar)
    #expect(rows.count == 1)
    #expect(rows[0].count == 3)
    #expect(rows[0].detail == "third")
    #expect(rows[0].state == .completed)
  }

  @Test("Working, needs-you and yesterday's items stay out of the log")
  @MainActor func leavesOutLiveAndOld() {
    let link = BotActivityDeepLink.agent(nodeID: coder)
    let rows = ActivityInboxDigest.rows(
      from: [
        item("live", .working, link, hoursAgo: 0.1),
        item("ask", .needsUser, link, hoursAgo: 0.2),
        item("old", .completed, link, hoursAgo: 30),
        item("today", .completed, link, hoursAgo: 1),
      ], now: now, calendar: calendar)
    #expect(rows.count == 1)
    #expect(rows[0].count == 1)
    #expect(rows[0].id == ActivityInboxDigest.sourceKey(link))
  }

  @Test("Failures come first, then newest")
  @MainActor func failuresFirst() {
    let a = BotActivityDeepLink.bot(profileID: woody, channelID: nil)
    let b = BotActivityDeepLink.routine(routineID: coder, runID: UUID())
    let c = BotActivityDeepLink.agent(nodeID: UUID())
    let rows = ActivityInboxDigest.rows(
      from: [
        item("1", .completed, a, hoursAgo: 0.5, title: "Woody"),
        item("2", .failed, b, hoursAgo: 4, title: "Lead follow-up", detail: "Not signed in"),
        item("3", .completed, c, hoursAgo: 2, title: "Fable"),
      ], now: now, calendar: calendar)
    #expect(rows.map(\.title) == ["Lead follow-up", "Woody", "Fable"])
    #expect(rows[0].detail == "Not signed in")
  }

  @Test("Routine runs share one line regardless of run id")
  @MainActor func routineRunsShareALine() {
    let routine = UUID()
    let rows = ActivityInboxDigest.rows(
      from: [
        item("r1", .completed, .routine(routineID: routine, runID: UUID()), hoursAgo: 2),
        item("r2", .completed, .routine(routineID: routine, runID: UUID()), hoursAgo: 1),
      ], now: now, calendar: calendar)
    #expect(rows.count == 1)
    #expect(rows[0].count == 2)
  }

  @Test("Runs interrupted by a restart are counted once, not listed")
  @MainActor func restartInterruptionsCollapse() {
    let a = BotActivityDeepLink.agent(nodeID: UUID())
    let b = BotActivityDeepLink.agent(nodeID: UUID())
    let c = BotActivityDeepLink.agent(nodeID: UUID())
    let digest = ActivityInboxDigest.digest(
      from: [
        item("1", .failed, a, hoursAgo: 1, title: ActivityInboxDigest.restartInterruptionTitle),
        item("2", .failed, b, hoursAgo: 2, title: ActivityInboxDigest.restartInterruptionTitle),
        item("3", .failed, c, hoursAgo: 3, title: "Work failed", detail: "Build exited 1"),
      ], now: now, calendar: calendar)
    #expect(digest.interruptedCount == 2)
    #expect(digest.rows.count == 1)
    #expect(digest.rows[0].detail == "Build exited 1")
  }
}
