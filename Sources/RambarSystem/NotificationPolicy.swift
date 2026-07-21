import Foundation
import RambarKit

public struct NotificationMessage: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

/// Result of consuming a set of stored events. `updatedThrough` advances even
/// when notifications are disabled, so opting back in never delivers a burst
/// of alerts accumulated while the setting was off.
public struct NotificationBatch: Equatable, Sendable {
    public let updatedThrough: Double?
    public let messages: [NotificationMessage]

    public init(updatedThrough: Double?, messages: [NotificationMessage]) {
        self.updatedThrough = updatedThrough
        self.messages = messages
    }
}

public func notificationBatch(
    events: [StoredEvent],
    enabled: Bool
) -> NotificationBatch {
    let updatedThrough = events.last?.ts
    guard enabled else {
        return NotificationBatch(updatedThrough: updatedThrough, messages: [])
    }

    let messages = events.compactMap { event -> NotificationMessage? in
        let payload = (try? JSONSerialization.jsonObject(
            with: Data(event.payload.utf8)
        )) as? [String: String] ?? [:]

        let title: String
        let body: String
        switch event.kind {
        case EventKind.pressure where payload["to"] != "normal":
            title = "Memory pressure \(payload["to"] ?? "")"
            if let project = payload["mover_project"],
               let delta = payload["mover_delta"].flatMap(UInt64.init) {
                body = "Biggest recent mover: \(project), +\(formatBytes(delta)) in 10 min"
            } else {
                body = "The kernel raised memory pressure"
            }
        case EventKind.orphans:
            let count = payload["count"] ?? "?"
            let footprint = payload["footprint"].flatMap(UInt64.init).map(formatBytes) ?? ""
            title = "Agent helpers left behind"
            body = "\(count) processes outlived their session, using \(footprint)"
        case EventKind.attention:
            let project = payload["project"] ?? "session"
            let footprint = payload["footprint"].flatMap(UInt64.init).map(formatBytes) ?? ""
            title = "Session running large"
            body = "\(project) is at \(footprint) (\(payload["procs"] ?? "?") processes)"
        default:
            return nil
        }
        return NotificationMessage(
            identifier: "rambar-\(event.kind)-\(Int(event.ts))",
            title: title,
            body: body
        )
    }
    return NotificationBatch(updatedThrough: updatedThrough, messages: messages)
}
