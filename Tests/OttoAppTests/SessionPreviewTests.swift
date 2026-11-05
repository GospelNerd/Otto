import Foundation
import OttoModels
import Testing

@testable import OttoApp

@Suite("Session previews")
struct SessionPreviewTests {
  @Test("Previews show what the person asked, not wrappers Otto or providers add")
  func humanRequest() {
    let ask = "whaat is the app doing?"
    let wrapped =
      "[MUSE CONTEXT PROMPT user-utf8-count:\(ask.utf8.count)]\nPrevious conversation context…\nCurrent user message:\n\(ask)"
    #expect(ChatWorkspaceView.humanRequest(wrapped) == ask)
    #expect(ChatWorkspaceView.humanRequest("# AGENTS.md instructions for /repo\n...").isEmpty)
    let environment = "<environment_context>cwd</environment_context>"
    #expect(ChatWorkspaceView.humanRequest(environment).isEmpty)
    #expect(ChatWorkspaceView.humanRequest("  Fix the login bug  ") == "Fix the login bug")
  }
  @Test("Saved notices disappear from chat rows and session previews")
  func backgroundNotice() {
    let notice =
      PromptSubmission.backgroundCompletionPrefix + "has finished.\n"
      + PromptSubmission.backgroundCompletionSuffix
    #expect(ChatWorkspaceView.humanRequest(notice).isEmpty)
    #expect(
      ChatWorkspaceView.humanRequest(
        PromptSubmission.contextualPrompt(notice, context: "memory")
      ).isEmpty)
    #expect(
      ChatWorkspaceView.humanRequest(
        notice + PromptSubmission.queuedMessageSeparator + "Continue please") == "Continue please")
  }

}
