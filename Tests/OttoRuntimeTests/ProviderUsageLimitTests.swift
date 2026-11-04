import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Provider usage limits")
struct ProviderUsageLimitTests {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  @Test(
    "Each provider's limit wording is recognised",
    arguments: [
      (AgentProvider.claudeCode, "Claude AI usage limit reached|1790003600"),
      (.claudeCode, "You've hit your limit · resets 2pm (Europe/London)"),
      (.codex, "■ You've hit your usage limit. Upgrade to Pro or try again in 2 hours 13 minutes."),
      (.grok, "Error: 429 Too Many Requests: rate limit exceeded for grok-code"),
      (.kimi, "error: exceeded_current_quota_error: Your account has exceeded its quota"),
      (.cursor, "You've hit your usage limit for this billing cycle"),
      (.openAI, "OpenAI error insufficient_quota: You exceeded your current quota"),
      (.openCode, "AI_APICallError: rate_limit_error: This request would exceed the rate limit"),
    ])
  func recognisesProviderWording(provider: AgentProvider, text: String) {
    let limit = ProviderUsageLimit.detect(
      in: text, provider: provider, now: now, calendar: calendar)
    #expect(limit?.provider == provider)
  }

  @Test("Ordinary failures are not treated as usage limits")
  func ignoresOtherErrors() {
    for text in ["Context exhausted", "Sandbox initialization failed", "Permission denied"] {
      #expect(ProviderUsageLimit.detect(in: text, provider: .codex) == nil)
    }
  }

  @Test("Reset times are read from epoch, relative, and clock wording")
  func parsesResetTimes() {
    let epoch = ProviderUsageLimit.detect(
      in: "Claude AI usage limit reached|1790003600", provider: .claudeCode, now: now,
      calendar: calendar)
    #expect(epoch?.resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
    #expect(epoch?.message == "Claude AI usage limit reached")

    let relative = ProviderUsageLimit.detect(
      in: "You've hit your usage limit. Try again in 2 hours 13 minutes.", provider: .codex,
      now: now, calendar: calendar)
    #expect(relative?.resetsAt == now.addingTimeInterval(2 * 3600 + 13 * 60))

    let clock = ProviderUsageLimit.detect(
      in: "5-hour limit reached ∙ resets 11pm", provider: .claudeCode, now: now,
      calendar: calendar)
    let components = clock?.resetsAt.map { calendar.dateComponents([.hour, .minute], from: $0) }
    #expect(components?.hour == 23)
    #expect(components?.minute == 0)
    #expect((clock?.resetsAt ?? .distantPast) > now)

    let unknown = ProviderUsageLimit.detect(
      in: "rate limit exceeded", provider: .grok, now: now, calendar: calendar)
    #expect(unknown != nil && unknown?.resetsAt == nil)
  }

  @Test("Relative reset durations keep their minutes and day units")
  func compoundRelativeReset() {
    // The old pattern matched at most one unit: "in 2 hours and 15 minutes" lost the minutes,
    // and a weekly "in 3 days" matched no unit at all. Both left the notice without the reset
    // time its "wait and retry at…" action needs.
    let forms: [(String, TimeInterval)] = [
      ("You've hit your usage limit. Try again in 2 hours.", 2 * 3600),
      ("5-hour limit reached. Try again in 2 hours and 15 minutes.", 2 * 3600 + 15 * 60),
      ("You've hit your weekly limit, try again in 3 days.", 3 * 86_400),
      ("Usage limit reached · resets in 1 day 6 hours", 30 * 3600),
    ]
    for (text, expected) in forms {
      let limit = ProviderUsageLimit.detect(
        in: text, provider: .codex, now: now, calendar: calendar)
      #expect(limit?.resetsAt == now.addingTimeInterval(expected), "\(text)")
    }
  }
}
