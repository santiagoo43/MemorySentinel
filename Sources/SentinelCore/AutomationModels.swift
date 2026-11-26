import CryptoKit
import Darwin
import Foundation

public struct ExecutableIdentity: Codable, Equatable, Sendable {
  public var path: String
  public var sha256: String
  public var device: Int32
  public var inode: UInt64
  public var size: Int64
  public var modifiedSeconds: Int64
  public var modifiedNanoseconds: Int64
  public var fileOwner: UInt32? = nil
  public var fileMode: UInt16? = nil
  public var changedSeconds: Int64? = nil
  public var changedNanoseconds: Int64? = nil
  public var hasCompleteMetadata: Bool {
    fileOwner != nil && fileMode != nil && changedSeconds != nil && changedNanoseconds != nil
  }
  /// Cheap final check after a fresh full digest, immediately before the native effect.
  public func validateCurrentMetadata() throws {
    var value = stat()
    guard let fileOwner, let fileMode, let changedSeconds, let changedNanoseconds,
      lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
      value.st_dev == device, value.st_ino == inode, value.st_size == size,
      value.st_uid == fileOwner, value.st_mode == fileMode,
      value.st_ctimespec.tv_sec == changedSeconds, value.st_ctimespec.tv_nsec == changedNanoseconds,
      value.st_mtimespec.tv_sec == modifiedSeconds,
      value.st_mtimespec.tv_nsec == modifiedNanoseconds
    else {
      throw FixError.invalidated("The executable file changed before the action.")
    }
  }
  public static func capture(_ requestedPath: String) throws -> Self {
    // Preserve the kernel-reported path spelling. Foundation can rewrite /private/var
    // aliases differently from proc_pidpath. The no-follow descriptor, inode and digest
    // pin the actual file; registrations take this path from a freshly verified process.
    guard requestedPath.hasPrefix("/"), !requestedPath.contains("\0") else {
      throw FixError.refused("An absolute executable path is required.")
    }
    let path = requestedPath
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw FixError.unavailable("The executable cannot be read without additional privileges.")
    }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0, before.st_size <= 512 * 1024 * 1024
    else {
      throw FixError.unavailable(
        "Executable identity requires a regular file no larger than 512 MiB.")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var hash = SHA256(), readBytes: Int64 = 0
    while let data = try handle.read(upToCount: 65536), !data.isEmpty {
      readBytes += Int64(data.count)
      guard readBytes <= before.st_size else {
        throw FixError.invalidated("The executable changed during identification.")
      }
      hash.update(data: data)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size, readBytes == after.st_size,
      before.st_uid == after.st_uid, before.st_mode == after.st_mode,
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else {
      throw FixError.invalidated("The executable changed during identification.")
    }
    return Self(
      path: path, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
      device: before.st_dev, inode: before.st_ino, size: before.st_size,
      modifiedSeconds: Int64(before.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec), fileOwner: before.st_uid,
      fileMode: before.st_mode, changedSeconds: Int64(before.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(before.st_ctimespec.tv_nsec))
  }
}

public struct ManagedLaunchSpecification: Codable, Equatable, Sendable {
  public var executable: ExecutableIdentity
  public var arguments: [String]
  public var directory: String?
  public init(executable: ExecutableIdentity, arguments: [String], directory: String? = nil) {
    self.executable = executable; self.arguments = arguments; self.directory = directory
  }
  public var valid: Bool {
    executable.path.hasPrefix("/") && arguments.count <= 64
      && arguments.allSatisfy { !$0.contains("\0") && $0.utf8.count <= 4096 }
      && arguments.reduce(0, { $0 + $1.utf8.count }) <= 16384
      && directory.map { $0.hasPrefix("/") && !$0.contains("\0") } ?? true
  }
}

public enum AutomaticOperation: String, Codable, CaseIterable, Sendable {
  case stopTask, restartTask, restartApplication
  public var action: FixAction {
    switch self {
    case .stopTask: .terminateProcess
    case .restartTask: .restartManagedTask
    case .restartApplication: .restartApplication
    }
  }
  public var title: String {
    switch self {
    case .stopTask: "Stop this disposable task · SIGTERM"
    case .restartTask: "Stop and restart this registered task"
    case .restartApplication: "Quit and reopen this application normally"
    }
  }
}

public struct AutomationExecution: Codable, Sendable {
  public var rule: AutomationRule
  public var permit: AutomationPermit
  public init(rule: AutomationRule, permit: AutomationPermit) {
    self.rule = rule; self.permit = permit
  }
  /// Coverage is established by the policy coordinator before issuing the short-lived permit.
  /// Every effect still needs these current measurements and the synchronous permission gate.
  public func currentlyRelevant(_ snapshot: Snapshot) -> Bool {
    guard !snapshot.demo, !snapshot.hasUnavailableMemoryReadings,
      abs(snapshot.date.timeIntervalSinceNow) < 10,
      let process = snapshot.processes.first(where: { $0.identity == permit.target }),
      process.path == rule.executable.path, process.uid == rule.owner,
      let footprint = process.footprint, footprint.isFinite
    else { return false }
    switch rule.trigger {
    case .criticalPressure: return snapshot.system.pressure == .critical
    case .sustainedPressure:
      return snapshot.system.pressure == .warning || snapshot.system.pressure == .critical
    case .taskFootprint: return footprint >= (rule.footprintLimit ?? .infinity)
    }
  }
}
public enum AutomaticTrigger: String, Codable, CaseIterable, Sendable {
  case sustainedPressure, criticalPressure, taskFootprint
  public var title: String {
    switch self {
    case .sustainedPressure: "Sustained system pressure"
    case .criticalPressure: "Critical system pressure"
    case .taskFootprint: "Explicit task stop threshold"
    }
  }
}

public struct AutomationRule: Codable, Equatable, Sendable, Identifiable {
  public enum Subject: String, Codable, Sendable { case taskInstance, application }
  public var id = UUID()
  public var revision: UInt64 = 1
  public var label: String
  public var subject: Subject
  public var profileID: UUID
  public var configuration: String
  public var owner: UInt32
  public var instance: ProcessIdentity?
  public var executable: ExecutableIdentity
  public var application: ApplicationIdentity?
  public var operation: AutomaticOperation
  public var trigger: AutomaticTrigger
  public var footprintLimit: Double?
  public var holdSeconds: Double = 60
  public var launch: ManagedLaunchSpecification?
  public var cooperativeEndpoint: String?
  public var created: Date
  public var expires: Date
  public var enabled = true
  public var reviewReason: String?
  public var reviewedAt: Date?
  public init(
    label: String, subject: Subject, profileID: UUID, configuration: String,
    owner: UInt32, instance: ProcessIdentity?, executable: ExecutableIdentity,
    application: ApplicationIdentity? = nil, operation: AutomaticOperation,
    trigger: AutomaticTrigger, footprintLimit: Double? = nil,
    launch: ManagedLaunchSpecification? = nil, cooperativeEndpoint: String? = nil,
    now: Date = Date()
  ) {
    self.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    self.subject = subject; self.profileID = profileID; self.configuration = configuration
    self.owner = owner; self.instance = instance; self.executable = executable
    self.application = application; self.operation = operation; self.trigger = trigger
    self.footprintLimit = footprintLimit; self.launch = launch;
    self.cooperativeEndpoint = cooperativeEndpoint
    self.created = now; self.expires = now.addingTimeInterval(30 * 86400)
  }
  public var subjectKey: String {
    subject == .application
      ? "application:\(owner):\(application?.bundlePath ?? executable.path)"
      : "registered-task:\(id)"
  }
  public var configurationError: String? {
    if label.isEmpty || !executable.path.hasPrefix("/") {
      return "A named, exact executable is required."
    }
    if !executable.hasCompleteMetadata {
      return
        "This executable pin lacks current ownership and change-time evidence. Register a fresh exact permission."
    }
    if !holdSeconds.isFinite || !(15...600).contains(holdSeconds) {
      return "The sustained trigger duration must be 15–600 seconds."
    }
    if !created.timeIntervalSince1970.isFinite || !expires.timeIntervalSince1970.isFinite
      || expires <= created || expires.timeIntervalSince(created) > 30 * 86400 + 1
    {
      return "Permissions need a finite expiry within 30 days of registration."
    }
    if subject == .taskInstance && instance == nil {
      return "Register the exact current task instance."
    }
    if subject == .application && (operation != .restartApplication || application == nil) {
      return "Application rules require an exact application and normal restart."
    }
    if subject == .taskInstance && operation == .restartApplication {
      return "A task cannot use application restart permission."
    }
    if trigger == .taskFootprint
      && (subject != .taskInstance || footprintLimit.map { !$0.isFinite || $0 < 16 * MiB } ?? true)
    {
      return "An explicit task threshold of at least 16 MiB is required."
    }
    if operation == .restartTask && (launch?.valid != true || launch?.executable != executable) {
      return "A separately approved launch specification for the same executable is required."
    }
    if subject == .application && cooperativeEndpoint?.hasPrefix("/") != true {
      return
        "A local cooperative readiness endpoint is required; unknown work state needs a person."
    }
    return nil
  }
}

public struct AutomaticAttempt: Codable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case reserved, executing, verifying, finished, interrupted
  }
  public var id = UUID()
  public var ruleID: UUID
  public var ruleRevision: UInt64
  public var episodeID: UUID
  public var subjectKey: String
  public var operation: AutomaticOperation
  public var created: Date
  public var status: Status = .reserved
  public var fixSessionID: UUID?
  public var failed = false
  public var message = "Reserved before execution; no successful effect is assumed."
  public var active: Bool { [.reserved, .executing, .verifying].contains(status) }
  public init(rule: AutomationRule, episodeID: UUID, now: Date = Date()) {
    ruleID = rule.id; ruleRevision = rule.revision; self.episodeID = episodeID
    subjectKey = rule.subjectKey; operation = rule.operation; created = now
  }
}

public struct ApplicationReadiness: Sendable {
  public var nonce: UUID
  public var identity: ProcessIdentity
  public var idle: Bool
  public var unsavedWork: Bool
  public var peerVerified: Bool
  public var expires: Date
  public init(
    nonce: UUID, identity: ProcessIdentity, idle: Bool, unsavedWork: Bool,
    peerVerified: Bool, expires: Date
  ) {
    self.nonce = nonce; self.identity = identity; self.idle = idle; self.unsavedWork = unsavedWork
    self.peerVerified = peerVerified; self.expires = expires
  }
}

public enum AutomationEligibility {
  /// A passing result is still not an execution permit. The native boundary rechecks identity and authority.
  public static func reason(
    rule: AutomationRule, episode: ProblemEpisode, snapshot: Snapshot,
    settings: Settings, journal: [AutomaticAttempt], executable: ExecutableIdentity,
    currentUser: UInt32, now: Date, warmupSeconds: Double, manualBusy: Bool,
    readiness: ApplicationReadiness? = nil, nonce: UUID? = nil, excludingAttempt: UUID? = nil,
    requireReadiness: Bool = true
  ) -> String? {
    if !settings.controls.externalActionsEnabled { return "External automation is off." }
    if snapshot.demo { return "Simulation cannot authorize a native effect." }
    if manualBusy { return "A manual Fix has priority." }
    if !warmupSeconds.isFinite || warmupSeconds < 60 {
      return "Collecting 60 seconds of fresh monitoring context."
    }
    if !now.timeIntervalSince1970.isFinite || !snapshot.date.timeIntervalSince1970.isFinite
      || !episode.knownSeconds.isFinite || !episode.spanSeconds.isFinite
    {
      return "The observation clock or coverage is invalid."
    }
    if abs(snapshot.date.timeIntervalSince(now)) > 10 || snapshot.hasUnavailableMemoryReadings {
      return "Fresh, complete measurements are required."
    }
    if let error = rule.configurationError { return error }
    if !rule.enabled || rule.reviewReason != nil {
      return rule.reviewReason ?? "The permission is disabled."
    }
    if rule.created > now || rule.expires <= now {
      return "The permission expired or the observation clock changed."
    }
    if rule.profileID != settings.activeProfile.id
      || rule.configuration != settings.analysisSignature
    {
      return "The profile or monitoring context changed; review this permission."
    }
    if rule.owner != currentUser || executable != rule.executable {
      return "Owner or executable identity changed; review this permission."
    }
    if episode.resolvedAt != nil || episode.status == .evidenceUnavailable {
      return "The issue has no current actionable evidence."
    }
    let other = journal.filter { $0.id != excludingAttempt }
    if other.contains(where: \.active) { return "Another automatic intervention is in progress." }
    if other.contains(where: { $0.episodeID == episode.id }) {
      return "This episode already had an automatic attempt."
    }
    if other.contains(where: {
      $0.subjectKey == rule.subjectKey && now.timeIntervalSince($0.created) < 3600
    }) {
      return "The target's one-hour attempt limit is active."
    }
    if other.filter({ now.timeIntervalSince($0.created) < 86400 }).count >= 3 {
      return "The three-attempt daily limit is active."
    }
    if other.filter({
      $0.ruleID == rule.id && $0.failed && $0.created >= (rule.reviewedAt ?? rule.created)
    }).count >= 2 {
      return "Two attempts failed; review this permission before resuming."
    }
    let target: ProcessRecord?
    if rule.subject == .taskInstance {
      target = snapshot.processes.first { $0.identity == rule.instance }
    } else {
      target = snapshot.processes.first {
        $0.path == rule.executable.path && $0.uid == rule.owner
          && $0.bundleID == rule.application?.bundleID
          && (readiness == nil || $0.identity == readiness?.identity)
      }
    }
    guard let target, target.uid == currentUser, target.path == executable.path,
      target.footprint != nil
    else { return "The exact approved target is unavailable or changed." }
    if rule.subject == .application && requireReadiness {
      guard let readiness, let nonce, readiness.nonce == nonce,
        readiness.identity == target.identity,
        readiness.peerVerified, readiness.idle, !readiness.unsavedWork,
        readiness.expires > now, readiness.expires.timeIntervalSince(now) <= 3
      else {
        return
          "A fresh, peer-verified idle and unsaved-work assessment is required. Hidden windows or low CPU are insufficient."
      }
    }
    switch rule.trigger {
    case .criticalPressure:
      if episode.key != "system:memory" {
        return "The episode does not establish this system-pressure trigger."
      }
      if snapshot.system.pressure != .critical {
        return "Critical system pressure is not currently measured."
      }
    case .sustainedPressure:
      if episode.key != "system:memory" {
        return "The episode does not establish this system-pressure trigger."
      }
      if snapshot.system.pressure != .warning && snapshot.system.pressure != .critical {
        return "System pressure recovered."
      }
      if episode.knownSeconds < rule.holdSeconds
        || episode.knownSeconds / max(1, episode.spanSeconds) < 0.8
      {
        return "The sustained trigger lacks adequate observed coverage."
      }
    case .taskFootprint:
      if episode.key != "automation-rule:\(rule.id):\(rule.revision)"
        || !episode.identities.contains(target.identity)
      {
        return "The observed episode does not match this task rule and revision."
      }
      if (target.footprint ?? 0) < (rule.footprintLimit ?? .infinity)
        || episode.knownSeconds < rule.holdSeconds
        || episode.knownSeconds / max(1, episode.spanSeconds) < 0.8
      {
        return "The explicit task stop threshold is not confirmed."
      }
    }
    return nil
  }
}
