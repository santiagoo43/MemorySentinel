import Foundation

public enum SimulationScenario: String, CaseIterable, Sendable {
  case stable, gradualGrowth, suddenJump, warning, critical, processExit, newPID, pidReuse,
    uncertain, missingMetrics, budgetApproach
  public var title: String {
    switch self {
    case .stable: "Stable memory"
    case .gradualGrowth: "Sustained growth"
    case .suddenJump: "Sudden footprint jump"
    case .warning: "High footprint warning"
    case .critical: "Critical system pressure"
    case .processExit: "Process exit"
    case .newPID: "New process instance"
    case .pidReuse: "Reused PID"
    case .uncertain: "Uncertain attribution"
    case .missingMetrics: "Unavailable measurements"
    case .budgetApproach: "Growth toward reference budget"
    }
  }
}
public struct Simulator: Sendable {
  public init() {}
  public func sample(step: Int, scenario: SimulationScenario, origin: Date) -> RawSample {
    let date = origin.addingTimeInterval(Double(step) * 5)
    let size: Double
    switch scenario {
    case .gradualGrowth: size = GiB + Double(step) * 40 * MiB
    case .suddenJump: size = GiB + (step >= 12 ? 2 * GiB : 0)
    case .warning: size = 7 * GiB
    case .critical: size = 8 * GiB
    case .budgetApproach: size = 3 * GiB + Double(step) * 10 * MiB
    default: size = GiB + sin(Double(step) / 8) * 8 * MiB
    }
    let identity = ProcessIdentity(
      pid: scenario == .newPID && step > 10 ? 4201 : 4200,
      seconds: UInt64(origin.timeIntervalSince1970) - 100
        + (scenario == .pidReuse && step > 10 ? 150 : 0))
    var process = ProcessRecord(
      identity: identity, name: scenario == .uncertain ? "codex-like" : "Codex • Simulation",
      path: scenario == .uncertain ? "/tmp/codex-like" : "/Demo/Codex.app/Contents/MacOS/Codex",
      bundleID: scenario == .uncertain ? nil : "com.openai.codex",
      footprint: scenario == .missingMetrics ? nil : size, rss: size * 0.85, appVersion: "1.0 (100)"
    )
    if scenario != .uncertain {
      process.applicationMetadata = ApplicationDescriptor(
        name: "Codex · Simulation", bundleID: "com.openai.codex",
        bundlePath: "/Demo/Codex.app", executablePath: process.path)
    }
    let system = SystemMetrics(
      total: 18 * GiB, used: scenario == .missingMetrics ? nil : 7 * GiB + size,
      available: scenario == .missingMetrics ? nil : max(0, 11 * GiB - size), compressed: GiB,
      swap: scenario == .missingMetrics ? nil : Double(step) * MiB, diskFree: 100 * GiB,
      pressure: scenario == .critical
        ? .critical : scenario == .missingMetrics ? .unavailable : .normal)
    return RawSample(
      date: date, system: system, processes: scenario == .processExit && step > 10 ? [] : [process])
  }
}
