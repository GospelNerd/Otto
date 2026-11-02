import Testing

@testable import OttoApp

struct HomeReviewCardTests {
  @Test func agentRepliesShowWithoutMarkdown() {
    #expect(
      HomeReviewActionCard.plain(
        "I added it to [tips.md](</Users/max/Muse Workspace/output/tips.md>).")
        == "I added it to tips.md.")
    #expect(
      HomeReviewActionCard.plain("Posted in **#tips** via `curl`") == "Posted in #tips via curl")
    #expect(HomeReviewActionCard.plain("Done.") == "Done.")
  }
}
