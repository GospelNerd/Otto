import Foundation
import OttoModels
import Testing

@Suite("Typed widget data contracts")
struct WidgetDataTests {
  @Test("Legacy manifests without view or job still decode")
  func legacyManifestDecodes() throws {
    let legacy = #"{"name":"Pulse","entry":"index.html","permissions":{"network":[]}}"#
    let manifest = try JSONDecoder().decode(WidgetManifest.self, from: Data(legacy.utf8))
    #expect(manifest.view == nil)
    #expect(manifest.job == nil)
  }

  @Test("Typed manifests round-trip view, job, and cron schedule")
  func typedManifestRoundTrip() throws {
    let manifest = WidgetManifest(
      name: "Substack Followers",
      schedule: WidgetSchedule(enabled: true, intervalSeconds: 3_600, cron: "0 */6 * * *"),
      view: WidgetViewDescriptor(kind: .number, unit: "followers", historyLimit: 96),
      job: WidgetJob(script: "scripts/refresh.sh", timeoutSeconds: 120)
    )
    let data = try JSONEncoder().encode(manifest)
    #expect(try JSONDecoder().decode(WidgetManifest.self, from: data) == manifest)
  }

  @Test("Widget execution budgets default low and stay bounded")
  func executionBudgetBounds() {
    #expect(WidgetJob(script: "refresh.sh").resolvedTimeoutSeconds == 15)
    #expect(WidgetJob(script: "refresh.sh", timeoutSeconds: 0).resolvedTimeoutSeconds == 1)
    #expect(WidgetJob(script: "refresh.sh", timeoutSeconds: 600).resolvedTimeoutSeconds == 60)
  }

  @Test("Number payloads parse and reject non-finite values")
  func numberPayload() throws {
    let parsed = try WidgetPayload.parse(
      json: #"{"value": 1284, "label": "Substack"}"#, kind: .number)
    #expect(parsed == .number(WidgetNumberPayload(value: 1_284, label: "Substack")))
    #expect(throws: WidgetPayloadError.self) {
      try WidgetPayload.parse(json: #"{"value": "many"}"#, kind: .number)
    }
  }

  @Test("Series payloads back line, bar, and pie views")
  func seriesPayload() throws {
    let json = #"{"points": [{"label": "Mon", "value": 3}, {"label": "Tue", "value": 5}]}"#
    for kind in [WidgetViewKind.line, .bar, .pie] {
      let parsed = try WidgetPayload.parse(json: json, kind: kind)
      guard case .series(let series) = parsed else {
        Issue.record("Expected a series payload for \(kind)")
        return
      }
      #expect(series.points.count == 2)
    }
    #expect(throws: WidgetPayloadError.self) {
      try WidgetPayload.parse(json: #"{"points": [{"label": "Neg", "value": -1}]}"#, kind: .pie)
    }
    #expect(throws: WidgetPayloadError.self) {
      try WidgetPayload.parse(json: #"{"points": []}"#, kind: .line)
    }
  }

  @Test("Table payloads enforce rectangular shape")
  func tablePayload() throws {
    let parsed = try WidgetPayload.parse(
      json: #"{"columns": ["Name", "Count"], "rows": [["Substack", "1284"]]}"#, kind: .table)
    guard case .table(let table) = parsed else {
      Issue.record("Expected a table payload")
      return
    }
    #expect(table.rows.first?.count == 2)
    #expect(throws: WidgetPayloadError.self) {
      try WidgetPayload.parse(
        json: #"{"columns": ["Name", "Count"], "rows": [["only-one"]]}"#, kind: .table)
    }
  }

  @Test("Runtime state records successes with capped number history")
  func runtimeStateHistory() throws {
    var state = WidgetRuntimeState()
    let start = Date(timeIntervalSince1970: 1_754_900_000)
    for index in 0..<5 {
      let json = #"{"value": \#(index)}"#
      let payload = try WidgetPayload.parse(json: json, kind: .number)
      state.recordSuccess(
        payloadJSON: json, payload: payload,
        at: start.addingTimeInterval(Double(index) * 60), historyLimit: 3)
    }
    #expect(state.history.map(\.value) == [2, 3, 4])
    #expect(state.lastError == nil)
    let decoded = WidgetRuntimeState.decode(from: state.encoded())
    #expect(decoded.history.map(\.value) == [2, 3, 4])
    #expect(decoded.payload == #"{"value": 4}"#)
  }

  @Test("Runtime state survives failures without losing the last payload")
  func runtimeStateFailure() throws {
    var state = WidgetRuntimeState(payload: #"{"value": 9}"#)
    state.recordFailure("script exited 1", at: Date(timeIntervalSince1970: 1_754_900_000))
    #expect(state.payload == #"{"value": 9}"#)
    #expect(state.lastError == "script exited 1")
    #expect(WidgetRuntimeState.decode(from: "not-json") == WidgetRuntimeState())
  }

  @Test("Custom HTML widget data accepts arbitrary JSON and preserves widget state")
  func htmlWidgetDataAndState() throws {
    let json = try validatedWidgetDataJSON(#"{"current":808,"goal":1000}"#)
    var state = WidgetRuntimeState(widgetState: #"{"compact":true}"#)
    state.recordHTMLSuccess(payloadJSON: json, at: Date(timeIntervalSince1970: 1_754_900_000))
    let decoded = WidgetRuntimeState.decode(from: state.encoded())
    #expect(decoded.payload == json)
    #expect(decoded.widgetState == #"{"compact":true}"#)
    #expect(throws: WidgetPayloadError.self) {
      try validatedWidgetDataJSON("not-json")
    }
  }
}

@Suite("Cron expressions")
struct CronExpressionTests {
  private let utc = TimeZone(identifier: "UTC")!

  private func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: iso)!
  }

  @Test("Every-six-hours schedules fire on the next boundary")
  func everySixHours() throws {
    let cron = try #require(CronExpression("0 */6 * * *"))
    let next = cron.nextFire(after: date("2026-08-11T07:15:00Z"), timeZone: utc)
    #expect(next == date("2026-08-11T12:00:00Z"))
  }

  @Test("Exact times roll to the next day once passed")
  func dailyRollover() throws {
    let cron = try #require(CronExpression("30 9 * * *"))
    let next = cron.nextFire(after: date("2026-08-11T09:30:00Z"), timeZone: utc)
    #expect(next == date("2026-08-12T09:30:00Z"))
  }

  @Test("Day-of-week fields respect Sunday as both 0 and 7")
  func weekdayMatching() throws {
    let cron = try #require(CronExpression("0 8 * * 1"))
    let next = cron.nextFire(after: date("2026-08-11T09:00:00Z"), timeZone: utc)
    #expect(next == date("2026-08-17T08:00:00Z"))
    let sundayZero = try #require(CronExpression("0 8 * * 0"))
    let sundaySeven = try #require(CronExpression("0 8 * * 7"))
    let afterSaturday = date("2026-08-15T12:00:00Z")
    #expect(
      sundayZero.nextFire(after: afterSaturday, timeZone: utc)
        == sundaySeven.nextFire(after: afterSaturday, timeZone: utc))
  }

  @Test("Restricted day-of-month and day-of-week union per cron convention")
  func dayFieldUnion() throws {
    let cron = try #require(CronExpression("0 0 13 * 5"))
    let next = try #require(cron.nextFire(after: date("2026-08-11T00:00:00Z"), timeZone: utc))
    #expect(next == date("2026-08-13T00:00:00Z"))
  }

  @Test("Lists, ranges, and stepped ranges parse")
  func componentForms() throws {
    let cron = try #require(CronExpression("0,30 9-17/4 1,15 * *"))
    let next = cron.nextFire(after: date("2026-08-11T00:00:00Z"), timeZone: utc)
    #expect(next == date("2026-08-15T09:00:00Z"))
  }

  @Test("A start value with a step runs to the end of the field")
  func startValueWithStep() throws {
    // Vixie cron reads "5/15" as "5-59/15", so the minute set is 5, 20, 35, and 50.
    let cron = try #require(CronExpression("5/15 * * * *"))
    let base = date("2026-08-11T00:00:00Z")
    #expect(cron.nextFire(after: base, timeZone: utc) == date("2026-08-11T00:05:00Z"))
    #expect(
      cron.nextFire(after: date("2026-08-11T00:05:00Z"), timeZone: utc)
        == date("2026-08-11T00:20:00Z"))
    #expect(
      cron.nextFire(after: date("2026-08-11T00:34:00Z"), timeZone: utc)
        == date("2026-08-11T00:35:00Z"))
    #expect(
      cron.nextFire(after: date("2026-08-11T00:49:00Z"), timeZone: utc)
        == date("2026-08-11T00:50:00Z"))
    #expect(
      cron.nextFire(after: date("2026-08-11T00:50:00Z"), timeZone: utc)
        == date("2026-08-11T01:05:00Z"))
    // The same rule applies to the other fields: "1/2" in the hour field is "1-23/2".
    let hourly = try #require(CronExpression("0 1/2 * * *"))
    #expect(hourly.nextFire(after: base, timeZone: utc) == date("2026-08-11T01:00:00Z"))
    #expect(
      hourly.nextFire(after: date("2026-08-11T01:00:00Z"), timeZone: utc)
        == date("2026-08-11T03:00:00Z"))
    // A bare single value is unchanged.
    let plain = try #require(CronExpression("5 * * * *"))
    #expect(plain.nextFire(after: base, timeZone: utc) == date("2026-08-11T00:05:00Z"))
    #expect(
      plain.nextFire(after: date("2026-08-11T00:05:00Z"), timeZone: utc)
        == date("2026-08-11T01:05:00Z"))
  }

  @Test("Impossible dates return nil instead of hanging")
  func impossibleDate() throws {
    let cron = try #require(CronExpression("0 0 30 2 *"))
    #expect(cron.nextFire(after: date("2026-08-11T00:00:00Z"), timeZone: utc) == nil)
  }

  @Test("Invalid expressions are rejected")
  func invalidExpressions() {
    #expect(CronExpression("* * * *") == nil)
    #expect(CronExpression("61 * * * *") == nil)
    #expect(CronExpression("* * * * 8") == nil)
    #expect(CronExpression("*/0 * * * *") == nil)
    #expect(CronExpression("a b c d e") == nil)
  }
}
