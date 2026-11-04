import Foundation
import OttoApplicationTools
import OttoModels
import OttoRuntime
import OttoTools

extension ApplicationServices {
  func launchAccountID(nodeID: UUID) throws -> UUID? {
    let definition = store.snapshot.canvases.lazy.flatMap(\.nodes)
      .first(where: { $0.id == nodeID })?.agentDefinition
    if definition?.requiresExplicitAccount == true {
      guard let accountID = definition?.accountID else { return nil }
      guard providerAccounts.account(id: accountID) != nil
      else {
        throw ToolRegistryError.invalidInput(
          "This subagent’s saved account is unavailable. Choose an account in the bot editor and start a new helper."
        )
      }
      return accountID
    }
    return effectiveAccountID(nodeID: nodeID)
  }

  func validateBotSubagents(_ helpers: [BotSubagentConfiguration]) throws {
    guard Set(helpers.map(\.id)).count == helpers.count else {
      throw ToolRegistryError.invalidInput("Subagent identifiers must be unique")
    }
    for helper in helpers {
      guard !helper.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        [.codex, .claudeCode].contains(helper.provider)
      else {
        throw ToolRegistryError.invalidInput("Each subagent needs a name and Codex or Claude Code")
      }
      if let accountID = helper.accountID, providerAccounts.account(id: accountID) == nil {
        throw ToolRegistryError.invalidInput(
          "The account for \(helper.name) is unavailable. Choose another account in the bot editor."
        )
      }
    }
  }

  /// Resolve against the caller's current saved configuration, never agent-supplied identity.
  func resolveBotSubagent(
    _ request: AgentSpawnProviderInput, helperID: UUID,
    context: ToolContext
  ) throws -> AgentSpawnProviderInput {
    guard let source = context.sourceNodeID,
      let definition = store.snapshot.canvases.lazy.flatMap(\.nodes)
        .first(where: { $0.id == source })?.agentDefinition,
      let profileID = definition.profileID,
      let profile = agentProfiles.profile(id: profileID), !profile.isArchived,
      let helper = profile.subagents?.first(where: { $0.id == helperID })
    else {
      throw ToolRegistryError.invalidInput("This helper is not configured for the calling bot")
    }
    try validateBotSubagents([helper])
    guard let task = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty
    else {
      throw ToolRegistryError.invalidInput("Give the subagent a task")
    }
    var resolved = request
    resolved.provider = helper.provider
    resolved.accountID = helper.accountID
    resolved.model = helper.model
    resolved.effort = nil
    resolved.displayName = helper.name
    resolved.executionStrategy = .direct
    resolved.profileID = nil
    resolved.profileRevision = nil
    resolved.profileInstructions = nil
    let parentMode = AgentPermissionMode(rawValue: definition.permissionMode) ?? .readOnly
    let modes: [AgentPermissionMode] = [.readOnly, .workspaceWrite, .unrestricted]
    let limit = min(
      modes.firstIndex(of: parentMode) ?? 0, modes.firstIndex(of: request.permissionMode) ?? 0)
    resolved.permissionMode = modes[limit]
    resolved.allowCrossAccount = true  // The user saved this exact helper/account route.
    resolved.prompt = "Your role: \(helper.role)\n\nTask:\n\(task)"
    return resolved
  }

  func botSubagentInstructions(profileID: UUID) -> String {
    guard let helpers = agentProfiles.profile(id: profileID)?.subagents, !helpers.isEmpty else {
      return ""
    }
    let rows = helpers.map { helper in
      let account =
        helper.accountID == nil
        ? "This Mac’s login"
        : providerAccounts.account(id: helper.accountID)?.name ?? "Unavailable account"
      return
        "- \(helper.name): \(helper.role); provider \(helper.provider.rawValue); account \(account); model \(helper.model ?? "provider default"); subagentID \(helper.id.uuidString)"
    }.joined(separator: "\n")
    return """
      ## Configured subagents
      The user has approved these helpers and their accounts. Use agent.spawn with subagentID and a focused prompt to delegate suitable work. Required provider, position and permission fields remain in the tool schema; Otto resolves the saved provider/account/model and caps permissions to yours. For these helpers use Otto delegation, so their selected subscription is respected. Send only the task context needed, not your entire conversation or private memory. When the user is waiting, wait using event.wait, read agent.get_result, then synthesise the result; otherwise you may end your turn, and Otto messages you when each helper finishes. Do not substitute another account if a helper fails. These helpers cannot recursively access your saved helper list.
      \(rows)
      """
  }
}
