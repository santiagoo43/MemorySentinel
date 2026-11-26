import CSystem
import Foundation

public struct ReadinessRequest: Codable, Sendable {
  public var version = 1
  public var nonce: UUID
  public var identity: ProcessIdentity
  public init(nonce: UUID, identity: ProcessIdentity) {
    self.nonce = nonce; self.identity = identity
  }
}
public struct ReadinessResponse: Codable, Sendable {
  public var version = 1
  public var nonce: UUID
  public var identity: ProcessIdentity
  public var idle: Bool
  public var unsavedWork: Bool
  public var leaseMilliseconds: Int
  public init(
    nonce: UUID, identity: ProcessIdentity, idle: Bool, unsavedWork: Bool, leaseMilliseconds: Int
  ) {
    self.nonce = nonce; self.identity = identity; self.idle = idle; self.unsavedWork = unsavedWork
    self.leaseMilliseconds = leaseMilliseconds
  }
}
public enum CooperativeReadiness {
  /// The cooperating app must hold its declared idle/no-unsaved-work state for the lease.
  /// Socket ownership and kernel peer PID+UID+start time are checked before and after the exchange.
  public static func query(endpoint: String, target: ProcessRecord, nonce: UUID = UUID())
    async throws -> ApplicationReadiness
  {
    guard endpoint.hasPrefix("/"), !endpoint.contains("\0") else {
      throw FixError.unavailable("The readiness endpoint must be an absolute local socket path.")
    }
    let path = URL(fileURLWithPath: endpoint).resolvingSymlinksInPath().path
    guard path.utf8.count < 104 else {
      throw FixError.unavailable("The resolved local socket path must be shorter than 104 bytes.")
    }
    let start = Date()
    var request = try JSONEncoder().encode(
      ReadinessRequest(nonce: nonce, identity: target.identity))
    request.append(10)
    let requestText = String(decoding: request, as: UTF8.self)
    let response: Data = try await Task.detached(priority: .utility) {
      var bytes = [CChar](repeating: 0, count: 4096)
      let count = ms_cooperative_query(
        path, target.identity.pid, target.uid,
        target.identity.seconds, target.identity.microseconds, requestText, &bytes,
        Int32(bytes.count))
      guard count > 0 else {
        let reasons: [Int32: String] = [
          -2: "The readiness socket is unavailable, not private or owned by another user.",
          -3: "The readiness socket requires a private directory owned by this user.",
          -4: "The readiness endpoint could not be connected within one second.",
          -5: "The readiness endpoint's kernel peer identity did not match the exact application.",
          -6: "The readiness challenge could not be sent within one second.",
          -7: "The application did not return a complete readiness reply within one second.",
          -8:
            "The readiness peer identity became unavailable or changed before the reply was verified.",
        ]
        throw FixError.unavailable(
          reasons[count] ?? "The private readiness exchange is unavailable.")
      }
      return Data(bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) })
    }.value
    try Task.checkCancellation()
    let reply = try JSONDecoder().decode(ReadinessResponse.self, from: response)
    let expires = start.addingTimeInterval(Double(reply.leaseMilliseconds) / 1000)
    guard reply.version == 1, reply.nonce == nonce, reply.identity == target.identity,
      (1...2000).contains(reply.leaseMilliseconds), expires > Date()
    else {
      throw FixError.refused(
        "The readiness reply was stale or did not match the exact challenge and process.")
    }
    return ApplicationReadiness(
      nonce: nonce, identity: target.identity, idle: reply.idle,
      unsavedWork: reply.unsavedWork, peerVerified: true, expires: expires)
  }
}
