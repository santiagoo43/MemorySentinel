import Foundation

public enum ProblemSignals {
  public static func applicationScope(_ process: ProcessRecord, in snapshot: Snapshot) -> String {
    var root = process, visited = Set([process.identity])
    let records = Dictionary(
      snapshot.processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
    for _ in 0..<64 {
      guard let parent = records[root.ppid], parent.group == process.group,
        parent.uid == process.uid, parent.identity.startDate <= root.identity.startDate,
        visited.insert(parent.identity).inserted
      else { break }
      root = parent
    }
    if let app = root.applicationMetadata {
      return "app:\(root.uid):\(app.bundlePath)"
    }
    return "process:\(root.uid):\(root.identity.id)"
  }
  public static func build(snapshot: Snapshot, settings: Settings, experience: ExperienceSummary)
    -> [ProblemSignal]
  {
    var result: [ProblemSignal] = []
    let pressure = snapshot.system.pressure
    let memoryKey = pressure == .warning || pressure == .critical ? "system:memory" : nil
    let worsening =
      (snapshot.swapGrowth ?? 0) > settings.swapGrowthMiB * MiB
      || snapshot.groupGrowth.values.contains { $0 > settings.growthMiB * MiB }
    if let memoryKey {
      result.append(
        ProblemSignal(
          key: memoryKey, label: "System memory", kind: .systemPressure,
          level: pressure == .critical ? .critical : .warning,
          evidence:
            "macOS pressure: \(pressure.rawValue). Swap: \(Format.bytes(snapshot.system.swap)); trend: \(Format.growth(snapshot.swapGrowth)).",
          criticalSystem: pressure == .critical,
          humanReason: pressure == .critical
            ? "Save work and review current workloads. No application was selected automatically."
            : worsening
              ? "Sustained elevated pressure and worsening trends need review; save work before approving a process action."
              : nil,
          reviewAfter: pressure == .critical ? nil : 120))
    } else if let growth = snapshot.swapGrowth, growth > settings.swapGrowthMiB * MiB {
      result.append(
        ProblemSignal(
          key: "system:swap", label: "Swap growth", kind: .swapGrowth,
          level: .warning,
          evidence:
            "Measured swap growth is \(Format.growth(growth)). Swap occupancy alone does not establish urgent intervention."
        ))
    }
    if let free = snapshot.system.diskFree, free < 5 * GiB {
      result.append(
        ProblemSignal(
          key: "system:storage", label: "Free storage", kind: .lowDisk,
          level: .warning,
          evidence:
            "\(Format.bytes(free)) free storage remains. No user files or swap files will be deleted.",
          humanReason: free < GiB
            ? "Review Storage settings and choose what to keep. Automatic deletion is unavailable."
            : nil,
          reviewAfter: 60))
    }
    if snapshot.hasUnavailableMemoryReadings {
      result.append(
        ProblemSignal(
          key: "monitor:metrics", label: "Monitoring evidence", kind: .unavailableMetrics,
          level: .elevated,
          evidence: "Required measurements are unavailable. Missing values cannot prove recovery."))
    }
    let monitored = snapshot.monitored.filter { $0.risk >= .warning }
    let grouped = Dictionary(grouping: monitored) { applicationScope($0, in: snapshot) }
    for (scope, processes) in grouped {
      let first = processes[0]
      let label = first.origin?.application?.name ?? first.group ?? first.name
      let kind: ProblemKind =
        processes.contains { ($0.growth ?? 0) > settings.growthMiB * MiB }
        ? .sustainedGrowth : .highFootprint
      let key = "\(scope):memory"
      let snoozed = experience.snoozes.contains { snooze in
        guard let health = experience.apps.first(where: { $0.app.root == first.identity }) else {
          return false
        }
        return snooze.suppresses(
          profile: settings.activeProfile.id, app: health.id,
          kind: kind == .sustainedGrowth ? .growth : .footprint, level: .warning, now: snapshot.date
        )
      }
      result.append(
        ProblemSignal(
          key: key, label: label, kind: kind,
          level: processes.map(\.risk).max() ?? .warning,
          evidence:
            "\(processes.count) attributed process signal(s). Largest measured footprint: \(Format.bytes(processes.compactMap(\.footprint).max())). Growth is not proof of a leak.",
          identities: processes.map(\.identity),
          complete: processes.allSatisfy { $0.footprint != nil },
          correlatedTo: memoryKey, snoozed: snoozed))
    }
    for health in experience.apps where health.overBudget || health.unusual {
      let kind: ExperienceEventKind = health.overBudget ? .budget : .unusual
      let key = "reference:\(settings.activeProfile.id):\(health.id):\(kind.rawValue)"
      let snoozed = experience.snoozes.contains {
        $0.suppresses(
          profile: settings.activeProfile.id, app: health.id, kind: kind,
          level: .warning, now: snapshot.date)
      }
      result.append(
        ProblemSignal(
          key: key, label: health.app.name, kind: .highFootprint,
          level: .warning,
          evidence: health.overBudget
            ? "\(Format.bytes(health.app.footprint)) footprint exceeds the \(Format.bytes(health.budget)) advisory reference budget. This is not an automatic stop limit."
            : "Footprint differs from the observed normal range; compare the current workload before acting.",
          identities: [health.app.root], complete: health.app.complete, correlatedTo: memoryKey,
          snoozed: snoozed))
    }
    return result
  }
}
