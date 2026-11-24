import CSystem
import Darwin
import Foundation
import SentinelCore

@main struct Diagnostics {
  static func main() async throws {
    let args = CommandLine.arguments
    func argument(_ name: String, _ fallback: Int) -> Int {
      guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
      return Int(args[i + 1]) ?? fallback
    }
    let duration = min(3600, max(0, argument("--duration", 0)))
    let interval = min(30, max(2, argument("--interval", 5)))
    var analyzer = Analyzer()
    var settings = Settings()
    settings.interval = interval
    let started = ProcessInfo.processInfo.systemUptime
    func cpuTime() -> Double {
      var r = rusage()
      getrusage(RUSAGE_SELF, &r)
      return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(
        r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }
    let cpuStart = cpuTime()
    var samples = 0
    var maxFootprint = 0.0
    var totalLatency = 0.0
    repeat {
      let before = ProcessInfo.processInfo.systemUptime
      let raw = LiveCollector().collect()
      let s = analyzer.evaluate(raw, settings: settings).snapshot
      samples += 1
      totalLatency += ProcessInfo.processInfo.systemUptime - before
      var own = MSProcess()
      if ms_process(getpid(), &own) != 0 { maxFootprint = max(maxFootprint, Double(own.footprint)) }
      if samples == 1 {
        print(
          "Physical: \(Format.bytes(s.system.total)); pressure: \(s.system.pressure.rawValue); system used estimate: \(Format.bytes(s.system.used)); swap: \(Format.bytes(s.system.swap)); processes: \(s.processes.count)"
        )
        for p in s.monitored {
          print(
            "\(p.name) PID \(p.identity.pid) start \(p.identity.seconds).\(p.identity.microseconds): footprint \(Format.bytes(p.footprint)), RSS \(Format.bytes(p.rss)) [\(p.group ?? "")] \(p.evidence ?? "")"
          )
        }
        print("Attributed accounting sum: \(Format.bytes(s.monitoredBytes)); risk: \(s.risk.title)")
      }
      if ProcessInfo.processInfo.systemUptime - started >= Double(duration) { break }
      try await Task.sleep(for: .seconds(interval))
    } while true
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    print(
      String(
        format:
          "SUMMARY samples=%d elapsed=%.2fs mean_sample=%.2fms cpu=%.3f%% peak_own_footprint=%.2fMiB",
        samples, elapsed, totalLatency / Double(samples) * 1000,
        (cpuTime() - cpuStart) / max(elapsed, 0.001) * 100, maxFootprint / MiB))
  }
}
