import CryptoKit
import Foundation

public struct ControlPreferences: Codable, Equatable, Sendable {
  public var warningBanners = false
  public var criticalReminder = true
  public var selfRepair = true
  public var externalActionsEnabled = false
  public init() {}
}

public enum EpisodeStatus: String, Codable, Sendable {
  case observing, warning, automaticAction, actionRequired, recovering, resolved,
    evidenceUnavailable
  public var title: String {
    switch self {
    case .observing: "Observing"
    case .warning: "Warning"
    case .automaticAction: "Automatic action in progress"
    case .actionRequired: "Action required"
    case .recovering: "Recovering"
    case .resolved: "Resolved"
    case .evidenceUnavailable: "Evidence unavailable"
    }
  }
}

public struct ProblemSignal: Sendable {
  public var key: String
  public var label: String
  public var kind: ProblemKind
  public var level: RiskLevel
  public var evidence: String
  public var identities: [ProcessIdentity]
  public var complete: Bool
  public var criticalSystem: Bool
  public var humanReason: String?
  public var reviewAfter: Double?
  public var correlatedTo: String?
  public var snoozed: Bool
  public init(
    key: String, label: String, kind: ProblemKind, level: RiskLevel,
    evidence: String, identities: [ProcessIdentity] = [], complete: Bool = true,
    criticalSystem: Bool = false, humanReason: String? = nil, reviewAfter: Double? = nil,
    correlatedTo: String? = nil, snoozed: Bool = false
  ) {
    self.key =
      key.utf8.count <= 600
      ? key
      : "scope:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    self.label = String(label.prefix(160)); self.kind = kind
    self.level = level; self.evidence = String(evidence.prefix(1200))
    self.identities = Array(identities.prefix(32)); self.complete = complete
    self.criticalSystem = criticalSystem; self.humanReason = humanReason
    self.reviewAfter = reviewAfter; self.correlatedTo = correlatedTo; self.snoozed = snoozed
  }
}

public struct ProblemEpisode: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var key: String
  public var label: String
  public var kind: ProblemKind
  public var started: Date
  public var updated: Date
  public var status: EpisodeStatus = .observing
  public var level: RiskLevel
  public var evidence: String
  public var identities: [ProcessIdentity] = []
  public var criticalSystem = false
  public var humanReason: String?
  public var correlatedTo: String?
  public var reviewing = false
  public var resolvedAt: Date?
  public var knownSeconds = 0.0
  public var spanSeconds = 0.0
  public var healthySeconds = 0.0
  public var healthySpan = 0.0
  public var warningNoticeSent = false
  public var humanNoticeSent = false
  public var criticalNoticeAt: Date?
  public var reminderSent = false
  public var automaticAttemptID: UUID?
  public var automaticFailure: String?
  public var fixSessionIDs: [UUID] = []
  public var noticeFailure: String?
  public var noticeDecision: String?
}

public struct EpisodeNotice: Codable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case warning, humanDecision, critical, reminder }
  public var episodeID: UUID
  public var kind: Kind
  public var title: String
  public var body: String
  public var sound: Bool
  public var reservedAt: Date
  public var id: String { "episode-\(episodeID.uuidString)-\(kind.rawValue)" }
}

public struct EpisodeObservation: Codable, Sendable {
  public var date: Date
  public var uptime: Double
}

/// A value reducer with an injectable observation clock. Persist notice reservations before delivery.
public struct ProblemEpisodes: Codable, Sendable {
  public var episodes: [ProblemEpisode] = []
  public var ordinaryNotices: [Date] = []
  public var previous: EpisodeObservation?
  public init() {}
  public var active: [ProblemEpisode] { episodes.filter { $0.resolvedAt == nil } }
  public mutating func reviewing(_ id: UUID, value: Bool) {
    guard let i = episodes.firstIndex(where: { $0.id == id }) else { return }
    episodes[i].reviewing = value
  }
  public mutating func deliveryFailed(_ notice: EpisodeNotice, message: String) {
    guard let i = episodes.firstIndex(where: { $0.id == notice.episodeID }) else { return }
    episodes[i].noticeFailure = String(message.prefix(500))
  }
  public mutating func cancelReservation(_ notice: EpisodeNotice) {
    guard let i = episodes.firstIndex(where: { $0.id == notice.episodeID }) else { return }
    switch notice.kind {
    case .warning:
      episodes[i].warningNoticeSent = false
      if let j = ordinaryNotices.firstIndex(of: notice.reservedAt) { ordinaryNotices.remove(at: j) }
    case .humanDecision: episodes[i].humanNoticeSent = false
    case .critical: episodes[i].criticalNoticeAt = nil
    case .reminder: episodes[i].reminderSent = false
    }
  }
  public mutating func ingest(
    _ incoming: [ProblemSignal], date: Date, uptime: Double, interval: Int,
    complete: Bool, unreadable: Set<Int32> = [], preferences: ControlPreferences,
    deliveryAllowed: Bool
  ) -> [EpisodeNotice] {
    if previous?.date == date { return [] }
    let dt = previous.map { date.timeIntervalSince($0.date) }
    let continuous =
      previous.map {
        let wall = date.timeIntervalSince($0.date), monotonic = uptime - $0.uptime
        return wall > 0 && wall <= Double(max(15, interval * 3))
          && monotonic > 0 && abs(monotonic - wall) <= 2
      } ?? false
    let covered = continuous ? min(dt ?? 0, Double(interval) * 1.5) : 0
    previous = EpisodeObservation(date: date, uptime: uptime)
    ordinaryNotices.removeAll { date.timeIntervalSince($0) >= 3600 }
    let prioritized = incoming.sorted {
      if $0.criticalSystem != $1.criticalSystem { return $0.criticalSystem }
      if $0.level != $1.level { return $0.level > $1.level }
      return $0.key < $1.key
    }
    let signals = Array(
      Dictionary(
        prioritized.prefix(128).map { ($0.key, $0) },
        uniquingKeysWith: {
          a, b in a.criticalSystem || a.level > b.level ? a : b
        }
      ).values)
    let keys = Set(signals.map(\.key))
    for i in episodes.indices where episodes[i].resolvedAt == nil && !keys.contains(episodes[i].key)
    {
      if complete && continuous
        && !episodes[i].identities.contains(where: { unreadable.contains($0.pid) })
      {
        if episodes[i].status == .recovering {
          episodes[i].healthySeconds += covered
          episodes[i].healthySpan += dt ?? 0
        } else {
          episodes[i].healthySeconds = 0; episodes[i].healthySpan = 0
        }
        episodes[i].status = .recovering
        if episodes[i].healthySeconds >= 120
          && episodes[i].healthySeconds / max(1, episodes[i].healthySpan) >= 0.8
        {
          episodes[i].status = .resolved; episodes[i].resolvedAt = date
        }
      } else {
        episodes[i].healthySeconds = 0; episodes[i].healthySpan = 0
        episodes[i].status = .evidenceUnavailable
      }
      episodes[i].knownSeconds = 0; episodes[i].spanSeconds = 0
      episodes[i].updated = date
    }
    for signal in signals {
      let index: Int
      if let i = episodes.firstIndex(where: { $0.key == signal.key && $0.resolvedAt == nil }) {
        index = i
      } else {
        episodes.insert(
          ProblemEpisode(
            key: signal.key, label: signal.label, kind: signal.kind,
            started: date, updated: date, level: signal.level, evidence: signal.evidence), at: 0)
        index = 0
      }
      let canCount =
        continuous
        && [.warning, .actionRequired, .automaticAction].contains(episodes[index].status)
      episodes[index].label = signal.label; episodes[index].level = signal.level
      episodes[index].kind = signal.kind
      episodes[index].evidence = signal.evidence; episodes[index].updated = date
      episodes[index].identities = signal.identities;
      episodes[index].criticalSystem = signal.criticalSystem
      episodes[index].correlatedTo = signal.correlatedTo
      episodes[index].healthySeconds = 0; episodes[index].healthySpan = 0
      if signal.complete {
        if canCount {
          episodes[index].knownSeconds += covered; episodes[index].spanSeconds += dt ?? 0
        } else {
          episodes[index].knownSeconds = 0; episodes[index].spanSeconds = 0
        }
        let held = signal.reviewAfter.map { episodes[index].knownSeconds >= $0 } ?? true
        episodes[index].humanReason = signal.criticalSystem || held ? signal.humanReason : nil
        if let failure = episodes[index].automaticFailure { episodes[index].humanReason = failure }
        episodes[index].status = episodes[index].humanReason == nil ? .warning : .actionRequired
        if episodes[index].automaticAttemptID != nil && episodes[index].automaticFailure == nil {
          episodes[index].status = .automaticAction
        }
      } else {
        episodes[index].knownSeconds = 0; episodes[index].spanSeconds = 0
        episodes[index].status = .evidenceUnavailable
      }
      episodes[index].noticeDecision =
        !deliveryAllowed
        ? "Native delivery is disabled or unavailable."
        : signal.correlatedTo.map { keys.contains($0) } == true
          ? "Included in the related system episode."
          : signal.snoozed && !signal.criticalSystem
            ? "Scoped warning snooze is active."
            : !preferences.warningBanners && !signal.criticalSystem
              && episodes[index].humanReason == nil
              ? "Smart mode: warning remains visible without a banner."
              : "Only a new eligible transition can submit a notification."
    }
    var notices: [EpisodeNotice] = []
    if deliveryAllowed {
      let ordered = signals.sorted {
        if $0.criticalSystem != $1.criticalSystem { return $0.criticalSystem }
        if ($0.humanReason != nil) != ($1.humanReason != nil) { return $0.humanReason != nil }
        return $0.key < $1.key
      }
      for signal in ordered {
        guard let i = episodes.firstIndex(where: { $0.key == signal.key && $0.resolvedAt == nil }),
          signal.complete, signal.correlatedTo.map({ !keys.contains($0) }) ?? true
        else { continue }
        var kind: EpisodeNotice.Kind?
        if signal.criticalSystem, episodes[i].criticalNoticeAt == nil {
          kind = .critical; episodes[i].criticalNoticeAt = date
        } else if signal.criticalSystem, preferences.criticalReminder, !episodes[i].reviewing,
          !episodes[i].reminderSent, let sent = episodes[i].criticalNoticeAt,
          date.timeIntervalSince(sent) >= 300
        {
          kind = .reminder; episodes[i].reminderSent = true
        } else if !signal.snoozed, signal.humanReason != nil, episodes[i].humanReason != nil,
          !episodes[i].humanNoticeSent,
          !episodes[i].reviewing, !signal.criticalSystem
        {
          kind = .humanDecision; episodes[i].humanNoticeSent = true
        } else if !signal.snoozed, preferences.warningBanners, !episodes[i].reviewing,
          !episodes[i].warningNoticeSent, episodes[i].knownSeconds >= 60,
          episodes[i].knownSeconds / max(1, episodes[i].spanSeconds) >= 0.8,
          ordinaryNotices.count < 3, !signal.criticalSystem
        {
          kind = .warning; episodes[i].warningNoticeSent = true; ordinaryNotices.append(date)
        }
        guard let kind else { continue }
        notices.append(
          EpisodeNotice(
            episodeID: episodes[i].id, kind: kind,
            title: kind == .warning
              ? "\(signal.label) · Warning"
              : "\(signal.label) · \(signal.criticalSystem ? "Urgent memory pressure" : "Action required")",
            body: String(signal.evidence.prefix(650)) + "\n"
              + String(
                (episodes[i].humanReason
                  ?? "No immediate human decision is established. Monitoring continues.").prefix(
                    250))
              + "\nOpen Activity for evidence and the next step.",
            sound: kind != .warning, reservedAt: date))
      }
    }
    // Active evidence is retained ahead of resolved history; bounds apply even under scope churn.
    episodes.sort { a, b in
      if (a.resolvedAt == nil) != (b.resolvedAt == nil) { return a.resolvedAt == nil }
      if a.criticalSystem != b.criticalSystem { return a.criticalSystem }
      if (a.status == .actionRequired) != (b.status == .actionRequired) {
        return a.status == .actionRequired
      }
      if a.updated != b.updated { return a.updated > b.updated }
      return a.key < b.key
    }
    if episodes.count > 128 { episodes = Array(episodes.prefix(128)) }
    if ordinaryNotices.count > 3 { ordinaryNotices = Array(ordinaryNotices.suffix(3)) }
    return notices
  }
}
