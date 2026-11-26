import Foundation

/// A bounded retry cycle resets only after two minutes of continuously healthy monitoring.
public struct SelfRepairBudget: Sendable {
  public private(set) var attempts: [Double] = []
  public private(set) var consecutive = 0
  private var unhealthySince: Double?
  private var healthySince: Double?
  private var last: Double?
  public init() {}
  public mutating func resetContinuity() { unhealthySince = nil; healthySince = nil; last = nil }
  public mutating func observe(healthy: Bool, uptime: Double) {
    guard uptime.isFinite else { resetContinuity(); return }
    if let last, uptime < last || uptime - last > 15 { unhealthySince = nil; healthySince = nil }
    last = uptime
    if healthy {
      unhealthySince = nil
      if healthySince == nil { healthySince = uptime }
      if uptime - (healthySince ?? uptime) >= 120 { consecutive = 0 }
    } else {
      healthySince = nil
      if unhealthySince == nil { unhealthySince = uptime }
    }
    attempts.removeAll { uptime - $0 >= 300 }
  }
  public func reason(uptime: Double) -> String? {
    guard uptime.isFinite, let since = unhealthySince else {
      return "Monitoring is healthy or not yet assessed."
    }
    if consecutive >= 3 {
      return
        "Three self-repair attempts did not establish stable recovery. Review monitoring manually."
    }
    if attempts.count >= 3 {
      return "The three-attempt self-repair limit is active for five minutes."
    }
    let delay = [2.0, 10.0, 30.0][min(2, consecutive)]
    if uptime - max(since, attempts.last ?? since) < delay {
      return "Waiting for the bounded self-repair backoff."
    }
    return nil
  }
  @discardableResult public mutating func reserve(uptime: Double) -> Bool {
    guard reason(uptime: uptime) == nil else { return false }
    attempts.append(uptime); consecutive += 1; return true
  }
}
