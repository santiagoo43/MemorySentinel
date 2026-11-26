import Foundation

public struct ApplicationDescriptor: Codable, Equatable, Sendable {
  public var name: String
  public var bundleID: String?
  public var bundlePath: String
  public var executablePath: String?
  public init(name: String, bundleID: String?, bundlePath: String, executablePath: String?) {
    self.name = String(name.prefix(160)); self.bundleID = bundleID
    self.bundlePath = bundlePath; self.executablePath = executablePath
  }
}

public struct ProcessAncestor: Codable, Equatable, Sendable, Identifiable {
  public var identity: ProcessIdentity
  public var name: String
  public var path: String
  public var id: ProcessIdentity { identity }
  public init(_ process: ProcessRecord) {
    identity = process.identity; name = String(process.name.prefix(160)); path = process.path
  }
}

public struct ProcessOrigin: Codable, Equatable, Sendable {
  public enum Confidence: String, Codable, Sendable {
    case bundle, ancestry, historical, unavailable
    public var title: String {
      switch self {
      case .bundle: "Verified application bundle"
      case .ancestry: "Verified launcher"
      case .historical: "Historical origin"
      case .unavailable: "Origin unavailable"
      }
    }
  }
  public var application: ApplicationDescriptor?
  public var applicationInstance: ProcessIdentity?
  public var launcher: ApplicationDescriptor? = nil
  public var launcherInstance: ProcessIdentity? = nil
  public var chain: [ProcessAncestor]
  public var confidence: Confidence
  public var verifiedAt: Date
  public var evidence: String
  public var isCurrent: Bool { confidence == .bundle || confidence == .ancestry }
  public var displayedApplication: ApplicationDescriptor? { launcher ?? application }
}

/// Presentation evidence is independent of watch groups and never grants a process action.
public struct AppIdentityResolver: Sendable {
  private struct Entry: Sendable {
    var uid: UInt32
    var path: String
    var origin: ProcessOrigin
    var seen: Date
  }
  private var known: [ProcessIdentity: Entry] = [:]
  private var lastDate: Date?
  public init() {}
  public var retainedIdentityCount: Int { known.count }
  public mutating func resolve(_ input: [ProcessRecord], at date: Date) -> [ProcessRecord] {
    if let lastDate, date < lastDate { known = [:] }
    lastDate = date
    let records = Dictionary(input.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
    var output = input
    for i in output.indices {
      let process = output[i]
      var current = process, visited = Set([process.identity.pid])
      var parents: [ProcessRecord] = []
      for _ in 0..<64 {
        guard let parent = records[current.ppid], parent.uid == process.uid,
          parent.identity.startDate <= current.identity.startDate,
          visited.insert(parent.identity.pid).inserted
        else { break }
        parents.append(parent); current = parent
      }
      let descriptor =
        process.applicationMetadata ?? parents.compactMap(\.applicationMetadata).first
      if let descriptor {
        let candidates = [process] + parents
        let root = candidates.last(where: {
          $0.applicationMetadata?.bundlePath == descriptor.bundlePath
            && $0.path == descriptor.executablePath
        })
        let launcher = parents.compactMap(\.applicationMetadata).first {
          process.applicationMetadata == nil || $0.bundlePath != descriptor.bundlePath
        }
        let launcherRoot = parents.last {
          $0.applicationMetadata?.bundlePath == launcher?.bundlePath
            && $0.path == launcher?.executablePath
        }
        let origin = ProcessOrigin(
          application: descriptor, applicationInstance: root?.identity,
          launcher: launcher ?? (process.applicationMetadata == nil ? descriptor : nil),
          launcherInstance: launcherRoot?.identity
            ?? (process.applicationMetadata == nil ? root?.identity : nil),
          chain: parents.map(ProcessAncestor.init),
          confidence: process.applicationMetadata == nil ? .ancestry : .bundle,
          verifiedAt: date,
          evidence: process.applicationMetadata == nil
            ? "Current parent identities, start times and owner establish the launcher."
            : "The executable is inside the \(descriptor.name) application bundle."
              + (launcher.map {
                " Current same-owner parent identities establish \($0.name) as its launcher."
              }
                ?? " A separate launcher is unavailable.")
        )
        output[i].origin = origin
        known[process.identity] = Entry(
          uid: process.uid, path: process.path, origin: origin, seen: date)
      } else if var prior = known[process.identity], prior.uid == process.uid,
        prior.path == process.path, date.timeIntervalSince(prior.origin.verifiedAt) <= 3600
      {
        prior.origin.confidence = .historical; prior.seen = date
        prior.origin.evidence =
          "Last verified origin only. Its current relationship is unavailable; this cannot authorize an action."
        known[process.identity] = prior; output[i].origin = prior.origin
      } else {
        known.removeValue(forKey: process.identity)
        output[i].origin = ProcessOrigin(
          application: nil, applicationInstance: nil, chain: parents.map(ProcessAncestor.init),
          confidence: .unavailable, verifiedAt: date,
          evidence:
            "No current application bundle or verified launcher was found. Runtime names, process groups and interpreter paths are insufficient."
        )
      }
    }
    known = known.filter { date.timeIntervalSince($0.value.seen) <= 3600 }
    if known.count > 4096 {
      let retain = Set(known.sorted { $0.value.seen > $1.value.seen }.prefix(4096).map(\.key))
      known = known.filter { retain.contains($0.key) }
    }
    return output
  }
}
