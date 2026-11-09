import AppKit
import Foundation
import OttoModels
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Otto on screen")
@MainActor
struct OttoBuddyTests {
  private let follow = OttoBuddyTarget.bot(
    profileID: UUID(), name: "Follow-ups", handle: "Followups")
  private let aria = OttoBuddyTarget.bot(profileID: UUID(), name: "Aria", handle: "Aria")

  @Test func staysOffUntilChosenButOtherSwitchesDefaultOn() throws {
    let defaults = try #require(UserDefaults(suiteName: "otto-buddy-\(UUID())"))
    #expect(!OttoBuddyPreferences.bool(OttoBuddyPreferences.enabledKey, defaults: defaults))
    #expect(OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey, defaults: defaults))
    #expect(OttoBuddyPreferences.bool(OttoBuddyPreferences.speakKey, defaults: defaults))
    #expect(OttoBuddyPreferences.bool(OttoBuddyPreferences.hideInFullScreenKey, defaults: defaults))
    #expect(OttoBuddyPreferences.size(defaults: defaults) == .medium)
    #expect(OttoBuddyPreferences.provider(defaults: defaults) == .codex)
    defaults.set(true, forKey: OttoBuddyPreferences.enabledKey)
    defaults.set(false, forKey: OttoBuddyPreferences.walkKey)
    #expect(OttoBuddyPreferences.bool(OttoBuddyPreferences.enabledKey, defaults: defaults))
    #expect(!OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey, defaults: defaults))
  }

  @Test func trailingMentionIsOnlyAWordAfterAt() {
    #expect(OttoBuddyMentions.trailingFragment(in: "draft a reply @") == "")
    #expect(OttoBuddyMentions.trailingFragment(in: "draft a reply @fol") == "fol")
    #expect(OttoBuddyMentions.trailingFragment(in: "@Aria") == "Aria")
    #expect(OttoBuddyMentions.trailingFragment(in: "email me@example") == nil)
    #expect(OttoBuddyMentions.trailingFragment(in: "@aria hello") == nil)
    #expect(
      OttoBuddyMentions.removingTrailingFragment(from: "draft a reply @fol") == "draft a reply")
  }

  @Test func mentionAnywhereRoutesTheQuestionToThatBot() throws {
    let resolved = try #require(
      OttoBuddyMentions.resolve("@followups draft a reply to Hugo", bots: [aria, follow]))
    #expect(resolved.0 == follow)
    #expect(resolved.1 == "draft a reply to Hugo")
    let middle = try #require(
      OttoBuddyMentions.resolve("ask @Aria about Q4", bots: [aria, follow]))
    #expect(middle.0 == aria)
    #expect(middle.1 == "ask about Q4")
    #expect(OttoBuddyMentions.resolve("ask @Arianna about Q4", bots: [aria]) == nil)
    #expect(OttoBuddyMentions.resolve("no mention here", bots: [aria]) == nil)
  }

  @Test func suggestionsFilterBotsByWhatIsTyped() {
    let model = OttoBuddyModel()
    model.targets = [.otto, .session(id: UUID(), name: "Dashboard update"), aria, follow]
    model.draft = "hello @"
    #expect(model.mentionSuggestions == [aria, follow])
    model.draft = "hello @fo"
    #expect(model.mentionSuggestions == [follow])
    model.draft = "hello"
    #expect(model.mentionSuggestions.isEmpty)
  }

  @Test func longAnswersAreSummarisedInTheBubble() {
    let short = OttoBuddyReply(
      nodeID: UUID(), question: "q", from: "Otto", thread: "Buddy chat", text: "Yes, at 11:30.",
      target: .otto)
    #expect(!short.isLong)
    var long = short
    long.text = String(repeating: "word ", count: 90)
    #expect(long.isLong)
    long.text = (1...8).map { "- point \($0)" }.joined(separator: "\n")
    #expect(long.isLong)
  }

  @Test func posesShipWithTheApp() {
    for pose in OttoBuddyPose.allCases { #expect(pose.image != nil, "\(pose.rawValue).png") }
    #expect(OttoBuddyFonts.registered)
  }

  @Test func onlyQuickNotesClearThemselves() {
    let note = OttoBuddyBubble(kind: .note, tone: .info, header: "Otto", lead: "On it…")
    let approval = OttoBuddyBubble(
      kind: .approval(nodeID: UUID()), tone: .attention, header: "Follow-ups", lead: "Can I?")
    #expect(note.isTransient && note.lifetime != nil)
    #expect(!approval.isTransient && approval.lifetime == nil)
  }

  @Test func landsOnTheVisibleWindowTopHePassesOnTheWayDown() {
    typealias W = OttoBuddyLedges.Window
    let notes = W(id: 1, frame: CGRect(x: 100, y: 300, width: 600, height: 400))  // top 700
    let browser = W(id: 2, frame: CGRect(x: 0, y: 200, width: 900, height: 300))  // top 500
    // Falling from 900 to 450 at x 400 passes both tops; the higher, visible one wins.
    let ledge = OttoBuddyLedges.find(
      in: [notes, browser], centerX: 400, from: 900, to: 450, above: 80)
    #expect(ledge?.windowID == 1)
    #expect(ledge?.top == 700)
    // Only the lower edge is in this step of the fall, and only beside the front window.
    #expect(
      OttoBuddyLedges.find(in: [notes, browser], centerX: 400, from: 600, to: 450, above: 80) == nil
    )
    #expect(
      OttoBuddyLedges.find(in: [notes, browser], centerX: 800, from: 600, to: 450, above: 80)?
        .windowID == 2)
    // A window in front hides the edge it covers, and is itself somewhere to land.
    let cover = W(id: 3, frame: CGRect(x: 300, y: 650, width: 300, height: 200))
    #expect(
      OttoBuddyLedges.find(in: [cover, notes], centerX: 400, from: 800, to: 650, above: 80) == nil)
    #expect(
      OttoBuddyLedges.find(in: [cover, notes], centerX: 400, from: 900, to: 650, above: 80)?
        .windowID == 3)
    // Off the window's ends, tiny windows, and edges at the Dock line don't count.
    #expect(OttoBuddyLedges.find(in: [notes], centerX: 110, from: 900, to: 0, above: 80) == nil)
    let tiny = W(id: 4, frame: CGRect(x: 350, y: 500, width: 200, height: 80))
    #expect(OttoBuddyLedges.find(in: [tiny], centerX: 400, from: 900, to: 0, above: 80) == nil)
    let low = W(id: 5, frame: CGRect(x: 0, y: -100, width: 900, height: 170))
    #expect(OttoBuddyLedges.find(in: [low], centerX: 400, from: 900, to: 0, above: 80) == nil)
  }

  @Test func gettingStartedOffersOttoOnScreen() {
    let items = GettingStartedProgress.items(
      GettingStartedState(
        hasPreferredName: true, hasBot: true, hasGivenTask: true, hasUsedVoiceCommand: true,
        hasMorningBrief: true),
      botName: nil)
    // Later items (such as desktop control) may follow it, so look it up by id, not position.
    let onScreen = items.first { $0.id == .ottoOnScreen }
    #expect(onScreen != nil)
    #expect(onScreen?.isComplete == false)
  }

  /// Opt-in visual check: set OTTO_BUDDY_SNAPSHOT_DIR to render each state to PNG.
  @Test func renderStates() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_BUDDY_SNAPSHOT_DIR"] else {
      return
    }
    try FileManager.default.createDirectory(
      atPath: output, withIntermediateDirectories: true)
    let node = UUID()

    let reply = OttoBuddyModel()
    reply.pose = .waving
    reply.inboxCount = 1
    reply.tailX = 90
    reply.bubble = OttoBuddyBubble(
      kind: .reply(
        OttoBuddyReply(
          nodeID: node, question: "Write a Q4 hiring update for the team", from: "Otto",
          thread: "Buddy chat",
          text:
            "**Q4 hiring update:** both open roles (Senior iOS, Growth lead) are in final rounds. Offers are planned for 4 Nov, and we’re £12k under the hiring budget. Risks: the iOS candidate has a competing offer, so we should move by Friday. Next steps are reference checks, a comp sign-off from finance, and lining up start dates for January.",
          target: .otto)),
      tone: .success, header: "Otto · Buddy chat", lead: "Here’s what I found.")
    try render(reply, to: "\(output)/reply.png")

    let approval = OttoBuddyModel()
    approval.pose = .thinking
    approval.tailX = 90
    approval.bubble = OttoBuddyBubble(
      kind: .approval(nodeID: node), tone: .attention, header: "Follow-ups",
      lead: "Can I go ahead?", detail: "gmail.send: Reply to Hugo — “Thursday works, deck attached”"
    )
    try render(approval, to: "\(output)/approval.png")

    let done = OttoBuddyModel()
    done.pose = .waving
    done.tailX = 90
    done.bubble = OttoBuddyBubble(
      kind: .finished(nodeID: node), tone: .success, header: "Dashboard update",
      lead: "Dashboard update is done ✓", detail: "The result is ready in Chat.")
    try render(done, to: "\(output)/finished.png")

    let menu = OttoBuddyModel()
    menu.menuOpen = true
    menu.running = 2
    menu.inboxCount = 1
    menu.tailX = 90
    menu.targets = [.otto, .session(id: UUID(), name: "Dashboard update"), aria, follow]
    menu.draft = "draft a reply to Hugo @"
    try render(menu, to: "\(output)/menu.png")

    let sleeping = OttoBuddyModel()
    sleeping.pose = .sleeping
    try render(sleeping, to: "\(output)/sleeping.png")

    try render(
      OttoBuddySettingsView(), size: CGSize(width: 540, height: 560), to: "\(output)/settings.png")
  }

  private func render(_ model: OttoBuddyModel, to path: String) throws {
    let scene = VStack(spacing: 0) {
      Spacer(minLength: 0)
      OttoBuddyBubbleHost(model: model, actions: OttoBuddyActions())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 20)
      OttoBuddyCharacterView(model: model)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 60)
        .padding(.top, -14)
      Rectangle().fill(Color.white.opacity(0.25)).frame(height: 30)
    }
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.36, green: 0.43, blue: 0.72), Color(red: 0.85, green: 0.6, blue: 0.52),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing))
    try render(scene, size: CGSize(width: 460, height: 620), to: path)
  }

  private func render<V: View>(_ view: V, size: CGSize, to path: String) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}
