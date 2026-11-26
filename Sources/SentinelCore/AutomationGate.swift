import Foundation

public struct AutomationContext: Equatable, Sendable {
  public var profileID: UUID
  public var configuration: String
  public var owner: UInt32
  public var enabled: Bool
  public var demo: Bool
  public var paused: Bool
  public var manualBusy: Bool
  public init(
    profileID: UUID, configuration: String, owner: UInt32, enabled: Bool,
    demo: Bool = false, paused: Bool = false, manualBusy: Bool = false
  ) {
    self.profileID = profileID; self.configuration = configuration; self.owner = owner
    self.enabled = enabled; self.demo = demo; self.paused = paused; self.manualBusy = manualBusy
  }
}
public struct AutomationPermit: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let ruleID: UUID
  public let ruleRevision: UInt64
  public let episodeID: UUID
  public let target: ProcessIdentity
  public let executable: ExecutableIdentity
  public let operation: AutomaticOperation
  public let token: InterventionToken
  public let contextEpoch: UInt64
  public let issued: Date
  public let expires: Date
}
public enum AutomaticEffectStage: Sendable { case primary, reopen }

/// The synchronous policy boundary is independent of UI approval and history. Persist a reservation before issuing.
public final class AutomationGate: @unchecked Sendable {
  private struct Entry {
    var permit: AutomationPermit
    var planID: UUID?
    var sessionID: UUID?
    var primaryUsed = false
    var reopenUsed = false
    var reopenUntil: Date?
  }
  private let lock = NSLock()
  private let intervention: InterventionGate
  private var context: AutomationContext?
  private var rules: [AutomationRule] = []
  private var epoch: UInt64 = 0
  private var entry: Entry?
  public init(intervention: InterventionGate) { self.intervention = intervention }
  public func configure(context next: AutomationContext, rules nextRules: [AutomationRule]) {
    lock.lock(); defer { lock.unlock() }
    guard context != next || rules != nextRules else { return }
    epoch &+= 1; entry = nil; context = next; rules = Array(nextRules.prefix(64))
  }
  public func invalidate() {
    lock.lock(); defer { lock.unlock() }
    epoch &+= 1; entry = nil
  }
  public var activePermitCount: Int {
    lock.lock(); defer { lock.unlock() }; return entry == nil ? 0 : 1
  }
  public func release(_ id: UUID) {
    lock.lock(); defer { lock.unlock() }
    if entry?.permit.id == id { entry = nil }
  }
  private func currentRule(_ permit: AutomationPermit, now: Date) throws -> AutomationRule {
    guard let context, context.enabled, !context.demo, !context.paused, !context.manualBusy,
      permit.contextEpoch == epoch, intervention.current() == permit.token, !permit.token.demo,
      let rule = rules.first(where: { $0.id == permit.ruleID }), rule.enabled,
      rule.reviewReason == nil, rule.configurationError == nil,
      rule.revision == permit.ruleRevision,
      rule.profileID == context.profileID, rule.configuration == context.configuration,
      rule.owner == context.owner, rule.created <= now, rule.expires > now,
      rule.operation == permit.operation, rule.executable == permit.executable
    else {
      throw FixError.invalidated(
        "The automatic permission, profile, owner, mode or executable changed.")
    }
    return rule
  }
  public func issue(
    rule: AutomationRule, episodeID: UUID, target: FixTarget,
    token: InterventionToken, now: Date = Date()
  ) throws -> AutomationPermit {
    lock.lock(); defer { lock.unlock() }
    if let entry, !entry.primaryUsed, entry.permit.expires < now { self.entry = nil }
    guard entry == nil else { throw FixError.busy }
    let permit = AutomationPermit(
      id: UUID(), ruleID: rule.id, ruleRevision: rule.revision,
      episodeID: episodeID, target: target.process.identity, executable: rule.executable,
      operation: rule.operation, token: token, contextEpoch: epoch,
      issued: now, expires: now.addingTimeInterval(30))
    let configured = try currentRule(permit, now: now)
    guard configured == rule, target.process.uid == rule.owner,
      target.process.path == rule.executable.path, target.source.identity == target.process.identity
    else {
      throw FixError.invalidated("Automatic authority is restricted to one exact root target.")
    }
    if rule.subject == .taskInstance {
      guard target.process.identity == rule.instance, target.application == nil
      else {
        throw FixError.invalidated(
          "The registered task instance changed or expanded into an application action.")
      }
    } else {
      guard target.application == rule.application else {
        throw FixError.invalidated("The application's pinned identity changed.")
      }
    }
    entry = Entry(permit: permit)
    return permit
  }
  public func claim(_ permit: AutomationPermit, sessionID: UUID, planID: UUID, now: Date = Date())
    throws
  {
    lock.lock(); defer { lock.unlock() }
    _ = try currentRule(permit, now: now)
    guard var current = entry, current.permit == permit, current.planID == nil,
      permit.issued <= now, now <= permit.expires
    else {
      throw FixError.invalidated(
        "This automatic permit expired, was already claimed or is not current.")
    }
    current.planID = planID; current.sessionID = sessionID; entry = current
  }
  public func effect<T>(
    _ permit: AutomationPermit, planID: UUID,
    target: ProcessIdentity, operation: AutomaticOperation, stage: AutomaticEffectStage,
    executable: ExecutableIdentity, now: Date = Date(), _ body: (AutomationRule) throws -> T
  ) throws -> T {
    lock.lock(); defer { lock.unlock() }
    let rule = try currentRule(permit, now: now)
    guard var current = entry, current.permit == permit, current.planID == planID,
      current.sessionID != nil, target == permit.target, operation == permit.operation,
      executable == permit.executable, now >= permit.issued
    else {
      throw FixError.invalidated("The automatic action does not match the claimed plan and target.")
    }
    switch stage {
    case .primary:
      guard !current.primaryUsed, now <= permit.expires else {
        throw FixError.invalidated("The primary automatic request expired or was already sent.")
      }
      current.primaryUsed = true
      if operation != .stopTask { current.reopenUntil = now.addingTimeInterval(45) }
    case .reopen:
      guard current.primaryUsed, !current.reopenUsed, operation != .stopTask,
        let until = current.reopenUntil, now <= until
      else {
        throw FixError.invalidated("Reopening was not authorized, already requested or timed out.")
      }
      current.reopenUsed = true
    }
    // Claim before an effect that can partially succeed and then throw; no automatic replay.
    entry = current
    return try body(rule)
  }
}
