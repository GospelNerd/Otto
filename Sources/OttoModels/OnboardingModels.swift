import Foundation

public struct FirstWorkflowStep: Identifiable, Sendable, Equatable {
  public let id: Int
  public let title: String
  public let detail: String
  public let isComplete: Bool

  public init(id: Int, title: String, detail: String, isComplete: Bool) {
    self.id = id
    self.title = title
    self.detail = detail
    self.isComplete = isComplete
  }
}

public enum FirstWorkflowProgress {
  public static func steps(for canvas: OttoCanvas) -> [FirstWorkflowStep] {
    let agents = canvas.nodes.filter { $0.kind == .agent }
    let providers = Set(
      agents.compactMap { node -> AgentProvider? in
        guard case .agent(let provider) = node.content else { return nil }
        return provider
      })
    let hasDispatchedWork = agents.contains {
      [.working, .done, .waiting, .failed].contains($0.status)
    }
    let hasChecklist = canvas.nodes.contains { node in
      guard case .markdown(_, let text) = node.content else { return false }
      return text.range(of: #"(?m)^\s*[-*]\s+\[[ xX]\]\s+"#, options: .regularExpression)
        != nil
    }
    return [
      FirstWorkflowStep(
        id: 1,
        title: "Create your first agent",
        detail: "Choose Claude Code or Codex and give it a bounded task.",
        isComplete: !agents.isEmpty
      ),
      FirstWorkflowStep(
        id: 2,
        title: "Add a second provider",
        detail: "Put Claude Code and Codex side by side.",
        isComplete: providers.contains(.claudeCode) && providers.contains(.codex)
      ),
      FirstWorkflowStep(
        id: 3,
        title: "Open a terminal",
        detail: "Keep a server or command visible on the canvas.",
        isComplete: canvas.nodes.contains { $0.kind == .terminal }
      ),
      FirstWorkflowStep(
        id: 4,
        title: "Dispatch and observe",
        detail: "Watch Fleet move through working, waiting, and done.",
        isComplete: hasDispatchedWork
      ),
      FirstWorkflowStep(
        id: 5,
        title: "Put a preview on Stage",
        detail: "Open a localhost URL and focus the browser.",
        isComplete: canvas.nodes.contains { $0.kind == .browser } && canvas.layoutMode == .stage
      ),
      FirstWorkflowStep(
        id: 6,
        title: "Create a goals checklist",
        detail: "Add numbered tasks Otto can update by voice.",
        isComplete: hasChecklist
      ),
    ]
  }
}

public struct VoiceOnboardingLesson: Identifiable, Sendable, Equatable {
  public var id: String
  public var title: String
  public var instruction: String
  public var requiresAPIKey: Bool

  public init(id: String, title: String, instruction: String, requiresAPIKey: Bool) {
    self.id = id
    self.title = title
    self.instruction = instruction
    self.requiresAPIKey = requiresAPIKey
  }
}

public enum VoiceOnboardingCatalog {
  public static let lessons = [
    VoiceOnboardingLesson(
      id: "local-command",
      title: "Give a private local command",
      instruction: "Say “organize the canvas” or “create a terminal”.",
      requiresAPIKey: false
    ),
    VoiceOnboardingLesson(
      id: "dictate",
      title: "Dictate an exact prompt",
      instruction: "Focus an agent, dictate, then stop to send the transcript verbatim.",
      requiresAPIKey: false
    ),
    VoiceOnboardingLesson(
      id: "command-palette",
      title: "Use the same tools with Command-F",
      instruction: "Press Command-F and search the typed Otto tool registry.",
      requiresAPIKey: false
    ),
    VoiceOnboardingLesson(
      id: "talk",
      title: "Optionally enable conversational Talk",
      instruction: "Configure a cloud provider key only if you want realtime conversation.",
      requiresAPIKey: true
    ),
  ]
}

// MARK: - First-run welcome

/// What a new user asked for help with on the welcome screen. Each interest picks a starter
/// agent and a first task, so Home opens with something useful to send.
public enum OnboardingInterest: String, CaseIterable, Codable, Sendable, Identifiable {
  case research
  case software
  case inbox
  case sales
  case writing
  case repetitive

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .research: "Research"
    case .software: "Building software"
    case .inbox: "Inbox & calendar"
    case .sales: "Sales & outreach"
    case .writing: "Writing"
    case .repetitive: "Repetitive tasks"
    }
  }

  public var symbol: String {
    switch self {
    case .research: "magnifyingglass"
    case .software: "chevron.left.forwardslash.chevron.right"
    case .inbox: "envelope"
    case .sales: "chart.line.uptrend.xyaxis"
    case .writing: "pencil.line"
    case .repetitive: "arrow.triangle.2.circlepath"
    }
  }

  public var starter: StarterAgent {
    switch self {
    case .research:
      StarterAgent(
        name: "Scout", jobTitle: "Research assistant",
        responsibility: "Find answers, compare options, and write up what matters with sources.",
        firstTask: "Compare the pricing of our top 5 competitors and make me a table.")
    case .software:
      StarterAgent(
        name: "Forge", jobTitle: "Software engineer",
        responsibility: "Build features, fix bugs, and explain changes in plain language.",
        firstTask: "Look through this project and tell me the three things most worth fixing.")
    case .inbox:
      StarterAgent(
        name: "Iris", jobTitle: "Inbox and calendar assistant",
        responsibility:
          "Keep on top of my inbox and calendar, draft replies, and flag what needs me.",
        firstTask: "Summarise what needs my attention today and draft replies I can approve.")
    case .sales:
      StarterAgent(
        name: "Hunter", jobTitle: "Sales assistant",
        responsibility: "Research prospects, find signals, and draft personal outreach.",
        firstTask: "Find five companies that look like our best customers and say why.")
    case .writing:
      StarterAgent(
        name: "Quill", jobTitle: "Writing partner",
        responsibility: "Draft, edit, and tighten writing in my voice.",
        firstTask: "Help me write a short post about what I'm working on this week.")
    case .repetitive:
      StarterAgent(
        name: "Otto", jobTitle: "Automation assistant",
        responsibility: "Take repetitive jobs off my plate and run them on a schedule.",
        firstTask: "Ask me about a task I do every week and set it up as an automation.")
    }
  }

  /// The starter for a set of picks: the first in display order, else research.
  public static func starter(for picks: Set<OnboardingInterest>) -> StarterAgent {
    (allCases.first { picks.contains($0) } ?? .research).starter
  }
}

/// A ready-made agent offered at the end of the welcome flow.
public struct StarterAgent: Sendable, Equatable {
  public var name: String
  public var jobTitle: String
  public var responsibility: String
  public var firstTask: String

  public init(name: String, jobTitle: String, responsibility: String, firstTask: String) {
    self.name = name
    self.jobTitle = jobTitle
    self.responsibility = responsibility
    self.firstTask = firstTask
  }
}

// MARK: - Getting started on Home

/// What Home's Getting started card knows about a new user. Every field comes from durable
/// state, so ticks survive a relaunch.
public struct GettingStartedState: Sendable, Equatable {
  public var hasPreferredName: Bool
  public var hasBot: Bool
  public var hasGivenTask: Bool
  public var hasUsedVoiceCommand: Bool
  public var hasMorningBrief: Bool
  public var hasJoinedCommunity: Bool
  public var hasMetOttoOnScreen: Bool
  /// Bots can see and operate native apps: the agent-desktop CLI is installed and Otto holds
  /// Accessibility permission.
  public var hasDesktopControl: Bool

  public init(
    hasPreferredName: Bool, hasBot: Bool, hasGivenTask: Bool, hasUsedVoiceCommand: Bool,
    hasMorningBrief: Bool, hasJoinedCommunity: Bool = false, hasMetOttoOnScreen: Bool = false,
    hasDesktopControl: Bool = false
  ) {
    self.hasPreferredName = hasPreferredName
    self.hasBot = hasBot
    self.hasGivenTask = hasGivenTask
    self.hasUsedVoiceCommand = hasUsedVoiceCommand
    self.hasMorningBrief = hasMorningBrief
    self.hasJoinedCommunity = hasJoinedCommunity
    self.hasMetOttoOnScreen = hasMetOttoOnScreen
    self.hasDesktopControl = hasDesktopControl
  }
}

public enum GettingStartedItemID: String, Sendable, CaseIterable {
  case aboutYou, hireAgent, firstTask, voiceCommand, morningBrief, joinCommunity, ottoOnScreen,
    desktopControl
}

public struct GettingStartedItem: Identifiable, Sendable, Equatable {
  public let id: GettingStartedItemID
  public let title: String
  public let detail: String?
  public let isComplete: Bool
}

public enum GettingStartedProgress {
  public static func items(_ state: GettingStartedState, botName: String?) -> [GettingStartedItem] {
    [
      GettingStartedItem(
        id: .aboutYou, title: "Tell Otto about you", detail: nil,
        isComplete: state.hasPreferredName),
      GettingStartedItem(
        id: .hireAgent, title: "Hire your first agent", detail: nil, isComplete: state.hasBot),
      GettingStartedItem(
        id: .firstTask, title: "Give \(botName ?? "an agent") its first task",
        detail: "Try the suggestion above", isComplete: state.hasGivenTask),
      GettingStartedItem(
        id: .voiceCommand, title: "Say a command", detail: "Speech stays on this Mac",
        isComplete: state.hasUsedVoiceCommand),
      GettingStartedItem(
        id: .morningBrief, title: "Set up your morning brief",
        detail: "Your day, ready when you open Otto", isComplete: state.hasMorningBrief),
      GettingStartedItem(
        id: .joinCommunity, title: "Join the Otto community",
        detail: "Ask questions and see what others build, on Discord",
        isComplete: state.hasJoinedCommunity),
      GettingStartedItem(
        id: .ottoOnScreen, title: "Put Otto on your screen",
        detail: "He stays over every app and says when work is done",
        isComplete: state.hasMetOttoOnScreen),
      GettingStartedItem(
        id: .desktopControl, title: "Let bots use your Mac's apps",
        detail: "Mail, Notes, Finder and more, without taking over your screen",
        isComplete: state.hasDesktopControl),
    ]
  }
}

// MARK: - Home tour

/// Controls on Home and in the window chrome that the first-run tour can spotlight.
public enum HomeTourTarget: String, Sendable, Hashable, CaseIterable {
  case composer, greeting, spaceSwitcher, surfaceSwitcher, shortcuts, gettingStarted
}

public struct HomeTourStep: Identifiable, Sendable, Equatable {
  public struct Term: Sendable, Equatable {
    public let term: String
    public let meaning: String
  }

  public enum Body: Sendable, Equatable {
    case text([String])
    case comparison([Term])
  }

  public enum Action: String, Sendable, Equatable {
    case openSettings
  }

  public let id: String
  public let kicker: String
  public let title: String
  public let body: Body
  public let target: HomeTourTarget?
  public let action: Action?
}

/// The guided tour a new user sees the first time Home opens. It explains each part of Otto
/// where it lives, and every step can be skipped.
public enum HomeTourCatalog {
  public static let steps: [HomeTourStep] = [
    HomeTourStep(
      id: "welcome", kicker: "WELCOME HOME", title: "Want a quick tour?",
      body: .text([
        "It takes about a minute and shows you where everything is. You can skip it and replay it any time from the Otto menu."
      ]), target: nil, action: nil),
    HomeTourStep(
      id: "ask", kicker: "ASK", title: "Start here",
      body: .text([
        "Type what you need. The menu on the left picks who answers: a new session, or one of your bots."
      ]), target: .composer, action: nil),
    HomeTourStep(
      id: "memory", kicker: "MEMORY", title: "Otto remembers you",
      body: .text([
        "What you tell Otto (your name, how you like things done, decisions you've made) goes into this space's memory, so every agent starts out knowing it.",
        "Bots also keep their own private memory of their job.",
      ]), target: .greeting, action: nil),
    HomeTourStep(
      id: "spaces", kicker: "SPACES", title: "Work and Personal stay separate",
      body: .text([
        "Each space has its own memory, bots, chats, files and theme. Agents in one space can't see another unless you turn that on."
      ]), target: .spaceSwitcher, action: nil),
    HomeTourStep(
      id: "kinds", kicker: "CHAT", title: "Sessions, bots and teams",
      body: .comparison([
        .init(term: "Session", meaning: "A one-off chat with an agent to get a task done."),
        .init(
          term: "Bot",
          meaning: "A teammate you hire once, with a name, a job, its own memory and automations."),
        .init(
          term: "Team",
          meaning: "A few bots in one room. A lead hands out the work and they report back."),
      ]), target: .surfaceSwitcher, action: nil),
    HomeTourStep(
      id: "automations", kicker: "AUTOMATIONS AND FILES", title: "Work that runs on its own",
      body: .text([
        "Give any bot a schedule in plain words, like \u{201C}every weekday at 8\u{201D}. Results come back to Home, a document or a dashboard."
      ]), target: .shortcuts, action: nil),
    HomeTourStep(
      id: "workspaces", kicker: "DASHBOARDS AND DOCUMENTS", title: "Where the results live",
      body: .text([
        "In Chat's sidebar, Dashboards show numbers and charts that agents keep up to date. Documents holds docs, sheets and slides, and agent edits arrive as suggestions you accept or reject."
      ]), target: .surfaceSwitcher, action: nil),
    HomeTourStep(
      id: "accounts", kicker: "ACCOUNTS", title: "Use the AI accounts you already pay for",
      body: .text([
        "In Settings \u{2192} Accounts, sign in with more than one Claude or Codex account, such as work and personal. Choose which one a project or automation uses, and let Otto switch when one reaches its usage limit."
      ]), target: nil, action: .openSettings),
    HomeTourStep(
      id: "checklist", kicker: "YOUR CHECKLIST", title: "You're set",
      body: .text([
        "Work through these at your own pace. The first task is already in the box above."
      ]), target: .gettingStarted, action: nil),
  ]
}
