import Foundation

public enum FixDiagnosis {
  public static func findings(snapshot s: Snapshot, settings: Settings, issue: ProblemKind? = nil)
    -> [ProblemDiagnosis]
  {
    var result: [ProblemDiagnosis] = []
    func add(
      _ kind: ProblemKind, _ severity: RiskLevel, _ summary: String, _ evidence: [String: Double],
      _ identity: ProcessIdentity? = nil,
      _ certainty: String = "Measured signal; attribution does not prove causation."
    ) {
      result.append(
        ProblemDiagnosis(
          kind: kind, severity: severity, identity: identity, summary: summary, evidence: evidence,
          certainty: certainty))
    }
    if let issue, [.monitoringFailure, .historyFailure, .notifications, .loginItem].contains(issue)
    {
      add(
        issue, .warning, issue.title, [:], nil,
        "Reported by the corresponding monitoring or settings component.")
    }
    if s.system.pressure == .critical || s.system.pressure == .warning {
      add(
        .systemPressure, s.system.pressure == .critical ? .critical : .warning,
        "macOS reports \(s.system.pressure.rawValue) memory pressure.",
        ["pressureLevel": s.system.pressure == .critical ? 2 : 1])
    }
    if let rate = s.swapGrowth, rate > settings.swapGrowthMiB * MiB {
      add(
        .swapGrowth, .warning, "Swap is growing \(Format.growth(rate)).",
        ["swapBytesPerMinute": rate])
    }
    if let free = s.system.diskFree, free < 5 * GiB {
      add(
        .lowDisk, .warning, "Only \(Format.bytes(free)) of storage is free.",
        ["diskFreeBytes": free])
    }
    if s.hasUnavailableMemoryReadings {
      let missing = s.monitored.filter { $0.footprint == nil }.count
      add(
        .unavailableMetrics, .elevated, "Some system or process readings are unavailable.",
        missing > 0 ? ["missingMonitoredFootprints": Double(missing)] : [:],
        nil, "Unavailable readings cannot establish recovery.")
    }
    for p in s.processes.prefix(512) {
      if let bytes = p.footprint, let total = s.system.total,
        bytes >= total * settings.warningFraction
      {
        add(
          .highFootprint, max(p.risk, .elevated),
          "\(p.name) accounts for \(Format.bytes(bytes)) footprint.",
          [
            "footprintBytes": bytes, "physicalBytes": total,
            "warningFraction": settings.warningFraction,
          ], p.identity)
      }
      if let growth = p.growth, growth > settings.growthMiB * MiB {
        add(
          .sustainedGrowth, max(p.risk, .elevated),
          "\(p.name) shows \(Format.growth(growth)) growth.", ["bytesPerMinute": growth],
          p.identity, "A measured growth trend is not proof of a leak.")
      }
    }
    return result
  }
  public static func plan(
    snapshot s: Snapshot, settings: Settings, origin: FixOrigin, target: FixTarget?,
    token: InterventionToken, explanation: String = ""
  ) -> FixPlan {
    var findings = findings(snapshot: s, settings: settings, issue: origin.issue)
    if let identity = origin.identity, s.unreadablePIDs?.contains(identity.pid) == true {
      findings.insert(
        ProblemDiagnosis(
          kind: .unavailableMetrics, severity: .elevated,
          identity: identity,
          summary:
            "The selected process identity cannot currently be read. Its exit is not verified.",
          evidence: ["pid": Double(identity.pid)],
          certainty:
            "An existing unreadable PID cannot authorize a process action or establish recovery."),
        at: 0)
    }
    let source = origin.identity.flatMap { id in s.processes.first { $0.identity == id } }
    if let source, !findings.contains(where: { $0.identity == source.identity }) {
      // Explicit selection must be assessed even beyond the bounded global scan.
      var selected = s; selected.processes = [source]
      findings += Self.findings(snapshot: selected, settings: settings).filter {
        $0.identity != nil
      }
    }
    let memoryConcern =
      s.system.pressure == .warning || s.system.pressure == .critical
      || (s.swapGrowth ?? 0) > settings.swapGrowthMiB * MiB
    var diagnosis =
      findings.first { $0.identity == source?.identity && $0.identity != nil } ?? findings.first
    if let source, diagnosis?.identity == nil, memoryConcern, source.footprint != nil {
      diagnosis = ProblemDiagnosis(
        kind: .selectedContributor, severity: s.risk, identity: source.identity,
        summary:
          "\(source.name) is a manually selected possible contributor (\(Format.bytes(source.footprint))).",
        evidence: ["footprintBytes": source.footprint!],
        certainty: "Selected by you. No causal relationship or Codex ownership is inferred.")
      findings.insert(diagnosis!, at: 0)
    }
    if let issue = origin.issue, let preferred = findings.first(where: { $0.kind == issue }) {
      diagnosis = preferred
    }
    if diagnosis == nil {
      diagnosis = ProblemDiagnosis(
        kind: .noActiveProblem, severity: .normal, identity: origin.identity,
        summary: origin.identity == nil
          ? "No current actionable warning in the available measurements."
          : "The original process has exited, changed identity, or has no current memory warning.",
        evidence: [:],
        certainty: "Old incidents are context only. No old PID is used for an action.")
    }
    let d = diagnosis!
    var actions: [FixAction] = []
    if let target, source != nil,
      [ProblemKind.highFootprint, .sustainedGrowth, .selectedContributor].contains(d.kind)
    {
      actions =
        target.application == nil
        ? [.terminateProcess, .forceQuit] : [.quitApplication, .restartApplication, .forceQuit]
    }
    if [.unavailableMetrics, .monitoringFailure].contains(d.kind) {
      actions.append(.restartMonitoring)
    }
    if d.kind == .lowDisk { actions.append(.storageSettings) }
    if d.kind == .notifications { actions.append(.notificationSettings) }
    if d.kind == .loginItem { actions.append(.loginSettings) }
    actions.append(.activityMonitor)
    let candidates = Array(
      s.processes.filter { $0.footprint != nil && !$0.path.isEmpty }.sorted {
        ($0.footprint ?? 0) > ($1.footprint ?? 0)
      }.prefix(20))
    return FixPlan(
      created: Date(), expires: Date().addingTimeInterval(120), token: token, origin: origin,
      diagnosis: d, findings: Array(findings.prefix(32)), target: target, candidates: candidates,
      source: source,
      actions: actions, before: FixMeasurement(snapshot: s, target: target?.process.identity),
      warningFraction: settings.warningFraction, growthThreshold: settings.growthMiB * MiB,
      swapThreshold: settings.swapGrowthMiB * MiB, explanation: explanation)
  }
  public static func isStillRelevant(_ plan: FixPlan, snapshot s: Snapshot) -> Bool {
    guard s.date.timeIntervalSinceNow > -10, s.date.timeIntervalSinceNow < 5 else { return false }
    switch plan.diagnosis.kind {
    case .highFootprint:
      guard let id = plan.diagnosis.identity,
        let p = s.processes.first(where: { $0.identity == id }), let bytes = p.footprint,
        let total = s.system.total
      else { return false }
      return bytes >= total * plan.warningFraction
    case .sustainedGrowth:
      return s.processes.first { $0.identity == plan.diagnosis.identity }?.growth.map {
        $0 > plan.growthThreshold
      } ?? false
    case .selectedContributor:
      return s.system.pressure == .warning || s.system.pressure == .critical
        || (s.swapGrowth ?? 0) > plan.swapThreshold
    default: return true
    }
  }
}
