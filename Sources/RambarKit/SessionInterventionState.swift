/// The observed stop state of every current member of an agent session tree.
public enum SessionTreeInterventionStatus: Equatable, Sendable {
    case running
    case partiallyStopped
    case stopped
}

/// A point-in-time summary derived from a fresh process sample.
public struct SessionTreeInterventionState: Equatable, Sendable {
    public let status: SessionTreeInterventionStatus
    public let stoppedProcessCount: Int
    public let runningProcessCount: Int

    public var processCount: Int {
        stoppedProcessCount + runningProcessCount
    }

    public init(stoppedProcessCount: Int, runningProcessCount: Int) {
        precondition(stoppedProcessCount >= 0)
        precondition(runningProcessCount >= 0)
        self.stoppedProcessCount = stoppedProcessCount
        self.runningProcessCount = runningProcessCount

        if stoppedProcessCount == 0 {
            status = .running
        } else if runningProcessCount == 0 {
            status = .stopped
        } else {
            status = .partiallyStopped
        }
    }
}

/// Summarize all current members; the root has no special status.
public func sessionTreeInterventionState(
    _ tree: AgentSessionTree
) -> SessionTreeInterventionState {
    let stopped = tree.members.filter(\.isStopped).count
    return SessionTreeInterventionState(
        stoppedProcessCount: stopped,
        runningProcessCount: tree.members.count - stopped
    )
}
