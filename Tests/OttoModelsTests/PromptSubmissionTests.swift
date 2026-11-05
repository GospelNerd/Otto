import OttoModels
import Testing

@Suite("Prompt submission fidelity")
struct PromptSubmissionTests {
  @Test("Recovered context never changes the visible original user message")
  func contextualPromptRoundTrip() {
    let prompt = "  Please review 👩🏽‍💻\nCurrent user message:\nDo not alter this.  "
    let submitted = PromptSubmission.contextualPrompt(
      prompt, context: "Old context with ]\n markers")
    #expect(submitted.contains("Old context"))
    #expect(PromptSubmission.originalUserText(submitted) == prompt)
    #expect(PromptSubmission.originalUserText(prompt) == prompt)
  }

  @Test("Nested context envelopes still recover the person's words")
  func nestedContextPrompt() {
    let prompt = "Type my name into the email box"
    let page = PromptSubmission.contextualPrompt(prompt, context: "Active tab: Sign in")
    let turn = PromptSubmission.contextualPrompt(page, context: "Memory selection")
    #expect(turn.contains("Active tab: Sign in"))
    #expect(turn.contains("Memory selection"))
    #expect(PromptSubmission.originalUserText(turn) == prompt)
  }

  @Test("Hidden control prompts are identifiable without changing provider text")
  func hiddenControlPrompt() {
    let prompt = PromptSubmission.hiddenControlPrompt("private team context")
    #expect(PromptSubmission.isHiddenControlPrompt(prompt))
    #expect(prompt.contains("private team context"))
  }

  @Test(
    "Meaningful drafts pass through byte-for-byte",
    arguments: [
      "Keep punctuation: []{}!? — exactly.",
      "  leading and trailing whitespace  ",
      "first line\n\n  indented second line\n",
      "Unicode: café, 東京, 👩🏽‍💻, e\u{301}",
    ])
  func verbatim(_ source: String) {
    let submitted = PromptSubmission.verbatimText(from: source)
    #expect(submitted == source)
    #expect(submitted.map { Array($0.utf8) } == Array(source.utf8))
  }

  @Test("Whitespace-only drafts are not submitted", arguments: ["", "   ", "\n\t\r"])
  func empty(_ source: String) {
    #expect(PromptSubmission.verbatimText(from: source) == nil)
  }
  private var completionNotice: String {
    PromptSubmission.backgroundCompletionPrefix + "has finished.\n<<<output\n"
      + "Tests passed" + PromptSubmission.queuedMessageSeparator + "more output\noutput>>>\n\n"
      + PromptSubmission.backgroundCompletionSuffix
  }

  @Test("Completion input is hidden through nested context envelopes")
  func backgroundNoticeProjection() {
    let notice = completionNotice
    let wrapped = PromptSubmission.contextualPrompt(
      PromptSubmission.contextualPrompt(notice, context: "page"), context: "memory")
    #expect(PromptSubmission.visibleUserText(notice) == nil)
    #expect(PromptSubmission.visibleUserText(wrapped) == nil)
    #expect(!PromptSubmission.isHiddenControlPrompt(notice))
  }

  @Test("Merged notices preserve genuine user messages in either order")
  func mixedBackgroundNoticeProjection() {
    let separator = PromptSubmission.queuedMessageSeparator
    let first = "  Keep my Unicode 👩🏽‍💻 and whitespace  "
    let second = "Please continue"
    for parts in [
      [completionNotice, first, second],
      [first, completionNotice, second],
      [first, second, completionNotice],
      [completionNotice, first, completionNotice, second],
    ] {
      #expect(
        PromptSubmission.visibleUserText(parts.joined(separator: separator))
          == first + separator + second)
    }
    #expect(
      PromptSubmission.visibleUserText(completionNotice + separator + completionNotice) == nil)
  }

  @Test("Quoted and incomplete notices are still the person's words")
  func noticeLookingUserText() {
    for text in [
      "Why did I get this?\n" + completionNotice,
      PromptSubmission.backgroundCompletionPrefix + "what does this mean?",
      "My separator" + PromptSubmission.queuedMessageSeparator + "is intentional",
    ] {
      #expect(PromptSubmission.visibleUserText(text) == text)
    }
  }

}
