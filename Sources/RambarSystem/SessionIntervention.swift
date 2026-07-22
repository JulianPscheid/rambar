import Darwin
import Foundation
import RambarKit

public enum SessionInterventionAction: String, Equatable, Sendable {
    case interrupt
    case pause
    case resume
    case terminate
}

public struct SessionInterventionResult: Equatable, Sendable {
    public let foundSession: Bool
    public let targetedProcessCount: Int
    public let signaledProcessCount: Int
    public let staleProcessCount: Int
    public let failedProcessCount: Int
}

func processIdentity(pid: Int32) -> ProcessIdentity? {
    guard let info = Proc.basicInfo(pid) else { return nil }
    return ProcessIdentity(pid: pid, start: info.startTime)
}

/// Signal one process only if the PID still belongs to the process observed by
/// the collector. This closes the ordinary PID-reuse failure mode immediately
/// before every signal.
@discardableResult
func validatedSignal(_ identity: ProcessIdentity, signal: Int32) -> Bool {
    guard processIdentity(pid: identity.pid) == identity else { return false }
    return kill(identity.pid, signal) == 0
}

public func performSessionIntervention(
    root: ProcessIdentity,
    action: SessionInterventionAction
) -> SessionInterventionResult {
    let samples = collectProcessSamples()
    return performSessionIntervention(
        root: root,
        action: action,
        trees: buildSessionTrees(samples),
        identityLookup: processIdentity,
        sendSignal: kill
    )
}

/// `nil` means the process identity is no longer live. A definite value is
/// returned only after matching both PID and start time.
public func processIsStopped(_ identity: ProcessIdentity) -> Bool? {
    guard let info = Proc.basicInfo(identity.pid),
          info.startTime == identity.start else { return nil }
    return info.status == SSTOP
}

func performSessionIntervention(
    root: ProcessIdentity,
    action: SessionInterventionAction,
    trees: [AgentSessionTree],
    identityLookup: (Int32) -> ProcessIdentity?,
    sendSignal: (Int32, Int32) -> Int32
) -> SessionInterventionResult {
    guard let tree = trees.first(where: { $0.root.identity == root }) else {
        return SessionInterventionResult(
            foundSession: false,
            targetedProcessCount: 0,
            signaledProcessCount: 0,
            staleProcessCount: 0,
            failedProcessCount: 0
        )
    }

    var targets = [root]
    if action != .interrupt {
        targets.append(contentsOf: tree.members.map(\.identity)
            .filter { $0 != root }
            .sorted { $0.pid < $1.pid })
    }

    var signaled = 0
    var stale = 0
    var failed = 0
    var terminatedTargets: [ProcessIdentity] = []
    for target in targets {
        guard identityLookup(target.pid) == target else {
            stale += 1
            if target == root { break }
            continue
        }

        let primarySignal: Int32
        switch action {
        case .interrupt: primarySignal = SIGINT
        case .pause: primarySignal = SIGSTOP
        case .resume: primarySignal = SIGCONT
        case .terminate: primarySignal = SIGTERM
        }

        if sendSignal(target.pid, primarySignal) == 0 {
            signaled += 1
            if action == .terminate {
                terminatedTargets.append(target)
            }
        } else {
            failed += 1
            if target == root { break }
        }
    }

    // SIGTERM remains pending for a stopped process. Queue TERM for every
    // verified member first, then continue survivors so the tree cannot
    // briefly resume with only part of it scheduled to terminate.
    if action == .terminate {
        for target in terminatedTargets where identityLookup(target.pid) == target {
            _ = sendSignal(target.pid, SIGCONT)
        }
    }

    return SessionInterventionResult(
        foundSession: true,
        targetedProcessCount: targets.count,
        signaledProcessCount: signaled,
        staleProcessCount: stale,
        failedProcessCount: failed
    )
}
