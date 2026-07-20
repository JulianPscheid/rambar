import Foundation

// MARK: - Testable pattern matching logic (no AppKit dependency)

/// A pattern entry: name to display, match string, hex color.
/// If pattern starts with "^", it matches only the start of the command (case-insensitive).
/// Otherwise, it matches anywhere in the command (case-insensitive).
public struct AppPattern {
    public let name: String
    public let pattern: String
    public let color: String

    public init(name: String, pattern: String, color: String) {
        self.name = name
        self.pattern = pattern
        self.color = color
    }
}

/// Process metadata used for process-tree ownership and app categorization.
public struct ProcessSnapshot {
    public let pid: Int32
    public let parentPid: Int32
    public let terminal: String?
    public let command: String
    public let memory: UInt64

    public init(
        pid: Int32 = 0,
        parentPid: Int32 = 0,
        terminal: String? = nil,
        command: String,
        memory: UInt64
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.terminal = terminal
        self.command = command
        self.memory = memory
    }
}

/// Parses output from `ps -axww -o pid=,ppid=,tty=,rss=,command=`.
/// The physical-footprint provider can override RSS when macOS exposes a better measurement.
public func parseProcessList(
    _ output: String,
    footprintForPid: (Int32) -> UInt64? = { _ in nil }
) -> [ProcessSnapshot] {
    output.components(separatedBy: "\n").compactMap { line in
        let parts = line.split(
            maxSplits: 4,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let parentPid = Int32(parts[1]),
              let rss = UInt64(parts[3]) else {
            return nil
        }

        return ProcessSnapshot(
            pid: pid,
            parentPid: parentPid,
            terminal: String(parts[2]),
            command: String(parts[4]),
            memory: footprintForPid(pid) ?? rss * 1024
        )
    }
}

/// Parses `lsof -a -d cwd -p <pid-list> -Fn` output into working directories.
public func parseWorkingDirectories(_ output: String) -> [Int32: String] {
    var currentPid: Int32?
    var directories: [Int32: String] = [:]

    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        switch line.first {
        case "p":
            currentPid = Int32(line.dropFirst())
        case "n":
            guard let currentPid else { continue }
            directories[currentPid] = String(line.dropFirst())
        default:
            continue
        }
    }

    return directories
}

/// One interactive Claude Code process and every process descended from it.
public struct ClaudeProcessGroup {
    public let root: ProcessSnapshot
    public let processes: [ProcessSnapshot]

    public var memory: UInt64 {
        processes.reduce(0) { $0 + $1.memory }
    }

    public var processCount: Int {
        processes.count
    }

    public var helperSummary: ClaudeHelperSummary {
        let helpers = processes.filter { $0.pid != root.pid }
        return ClaudeHelperSummary(
            total: helpers.count,
            node: helpers.filter { executableBasename($0.command) == "node" }.count,
            python: helpers.filter { executableBasename($0.command).hasPrefix("python") }.count,
            claude: helpers.filter { isClaudeCLICommand($0.command) }.count
        )
    }
}

public struct ClaudeHelperSummary {
    public let total: Int
    public let node: Int
    public let python: Int
    public let claude: Int
}

public let claudeSessionMemoryWarningThreshold: UInt64 = 3 * 1_073_741_824
public let claudeSessionProcessWarningThreshold = 40

public func claudeSessionNeedsAttention(memory: UInt64, processCount: Int) -> Bool {
    memory >= claudeSessionMemoryWarningThreshold || processCount >= claudeSessionProcessWarningThreshold
}

public struct ClaudeOrphanSummary {
    public let processIDs: Set<Int32>
    public let memory: UInt64
    public let newProcessCount: Int

    public var processCount: Int {
        processIDs.count
    }
}

public struct ClaudeOrphanTracker {
    private var previousTrees: [Int32: [Int32: String]] = [:]
    private var orphanedProcesses: [Int32: String] = [:]

    public init() {}

    public mutating func update(
        processes: [ProcessSnapshot],
        groups: [ClaudeProcessGroup]
    ) -> ClaudeOrphanSummary {
        let activeByPid = Dictionary(uniqueKeysWithValues: processes.filter { $0.pid > 0 }.map { ($0.pid, $0) })
        let activeProcessIDs = Set(activeByPid.keys)
        let currentRootIDs = Set(groups.map { $0.root.pid })
        let currentlyClaimedIDs = Set(groups.flatMap { $0.processes.map(\.pid) })
        var newlyDetachedProcesses: [Int32: String] = [:]

        for (rootPid, processCommands) in previousTrees where !currentRootIDs.contains(rootPid) {
            for (pid, command) in processCommands where pid != rootPid {
                newlyDetachedProcesses[pid] = command
            }
        }

        let previousOrphanIDs = Set(orphanedProcesses.keys)
        orphanedProcesses.merge(newlyDetachedProcesses) { _, new in new }
        orphanedProcesses = orphanedProcesses.filter { pid, originalCommand in
            activeProcessIDs.contains(pid) &&
                !currentlyClaimedIDs.contains(pid) &&
                activeByPid[pid]?.command == originalCommand
        }

        previousTrees = Dictionary(uniqueKeysWithValues: groups.map { group in
            let processCommands = Dictionary(uniqueKeysWithValues: group.processes.map { ($0.pid, $0.command) })
            return (group.root.pid, processCommands)
        })

        let orphanedProcessIDs = Set(orphanedProcesses.keys)
        let memory = orphanedProcessIDs.reduce(UInt64(0)) { total, pid in
            total + (activeByPid[pid]?.memory ?? 0)
        }
        let newProcessCount = orphanedProcessIDs.subtracting(previousOrphanIDs).count

        return ClaudeOrphanSummary(
            processIDs: orphanedProcessIDs,
            memory: memory,
            newProcessCount: newProcessCount
        )
    }
}

/// Result of categorizing processes by app
public struct AppCategoryResult {
    public let name: String
    public let memory: UInt64
    public let processCount: Int
    public let color: String
}

/// Check if a command string matches an app pattern.
/// - `^prefix` patterns match case-insensitively at the start of the command
/// - Other patterns match case-insensitively anywhere in the command
public func matchesAppPattern(_ command: String, pattern: String) -> Bool {
    if pattern.hasPrefix("^") {
        let prefix = String(pattern.dropFirst())
        return command.lowercased().hasPrefix(prefix.lowercased())
    } else {
        return command.localizedCaseInsensitiveContains(pattern)
    }
}

private func executableBasename(_ command: String) -> String {
    guard let executable = command.split(whereSeparator: { $0.isWhitespace }).first else {
        return ""
    }
    return executable.split(separator: "/").last.map { $0.lowercased() } ?? ""
}

/// Returns true for Claude Code CLI executables without matching Claude Desktop.
public func isClaudeCLICommand(_ command: String) -> Bool {
    guard let executable = command.split(whereSeparator: { $0.isWhitespace }).first else {
        return false
    }

    let path = String(executable).lowercased()
    if path.contains(".app/contents/macos/") {
        return false
    }

    let basename = executableBasename(command)
    return basename == "claude" || path.contains("/.local/share/claude/versions/")
}

/// Groups all recursive descendants under each top-level, terminal-attached Claude CLI process.
/// Descendants can be npm, Node, Python, or any other helper executable.
public func groupClaudeProcessTrees(_ processes: [ProcessSnapshot]) -> [ClaudeProcessGroup] {
    let processByPid = Dictionary(uniqueKeysWithValues: processes.filter { $0.pid > 0 }.map { ($0.pid, $0) })

    func hasAttachedTerminal(_ process: ProcessSnapshot) -> Bool {
        guard let terminal = process.terminal?.trimmingCharacters(in: .whitespacesAndNewlines),
              !terminal.isEmpty else {
            return false
        }
        return terminal != "??" && terminal != "?" && terminal != "-"
    }

    func hasClaudeAncestor(_ process: ProcessSnapshot) -> Bool {
        var parentPid = process.parentPid
        var visited: Set<Int32> = [process.pid]

        while parentPid > 0, visited.insert(parentPid).inserted,
              let parent = processByPid[parentPid] {
            if isClaudeCLICommand(parent.command) {
                return true
            }
            parentPid = parent.parentPid
        }
        return false
    }

    let roots = processes.filter {
        $0.pid > 0 && isClaudeCLICommand($0.command) && hasAttachedTerminal($0) && !hasClaudeAncestor($0)
    }
    let rootPids = Set(roots.map(\.pid))
    var groupedProcesses: [Int32: [ProcessSnapshot]] = [:]

    for process in processes where process.pid > 0 {
        var currentPid = process.pid
        var visited: Set<Int32> = []

        while currentPid > 0, visited.insert(currentPid).inserted {
            if rootPids.contains(currentPid) {
                groupedProcesses[currentPid, default: []].append(process)
                break
            }
            guard let current = processByPid[currentPid] else { break }
            currentPid = current.parentPid
        }
    }

    return roots.compactMap { root in
        guard let ownedProcesses = groupedProcesses[root.pid] else { return nil }
        return ClaudeProcessGroup(root: root, processes: ownedProcesses)
    }.sorted { $0.memory > $1.memory }
}

/// Default app patterns used by RAMBar
public let defaultAppPatterns: [AppPattern] = [
    AppPattern(name: "Chrome", pattern: "Google Chrome", color: "#4285f4"),
    AppPattern(name: "Claude Code", pattern: "^claude", color: "#cc785c"),
    AppPattern(name: "Cursor", pattern: "Cursor", color: "#00bcd4"),
    AppPattern(name: "VS Code", pattern: "Code Helper", color: "#007acc"),
    AppPattern(name: "Slack", pattern: "Slack", color: "#4a154b"),
    AppPattern(name: "Granola", pattern: "Granola", color: "#f59e0b"),
    AppPattern(name: "Python", pattern: "python", color: "#3776ab"),
    AppPattern(name: "Node.js", pattern: "node", color: "#339933"),
    AppPattern(name: "Docker", pattern: "docker", color: "#2496ed"),
    AppPattern(name: "WhatsApp", pattern: "WhatsApp", color: "#25d366"),
    AppPattern(name: "Obsidian", pattern: "Obsidian", color: "#7c3aed"),
    AppPattern(name: "Safari", pattern: "Safari", color: "#006cff"),
    AppPattern(name: "Arc", pattern: "Arc", color: "#7c3aed"),
    AppPattern(name: "Warp", pattern: "Warp", color: "#01a4ff"),
    AppPattern(name: "Ghostty", pattern: "ghostty", color: "#f97316"),
    AppPattern(name: "iTerm", pattern: "iTerm", color: "#2bbc8a"),
    AppPattern(name: "Figma", pattern: "Figma", color: "#a259ff"),
    AppPattern(name: "Zoom", pattern: "zoom", color: "#2d8cff"),
    AppPattern(name: "Discord", pattern: "Discord", color: "#5865f2"),
    AppPattern(name: "Spotify", pattern: "Spotify", color: "#1db954"),
    AppPattern(name: "Brave", pattern: "Brave", color: "#fb542b"),
    AppPattern(name: "Firefox", pattern: "firefox", color: "#ff7139"),
]

/// Categorize processes into app groups using pattern matching.
/// Returns sorted by memory descending, with an "Other" entry if unmatched > 500MB.
public func categorizeProcesses(_ processes: [ProcessSnapshot], patterns: [AppPattern]) -> [AppCategoryResult] {
    var appMemory: [String: (memory: UInt64, count: Int, color: String)] = [:]
    var unmatchedMemory: UInt64 = 0
    var unmatchedCount: Int = 0

    let claudePattern = patterns.first { $0.name == "Claude Code" }
    let claudeGroups = claudePattern == nil ? [] : groupClaudeProcessTrees(processes)
    let claudeOwnedPids = Set(claudeGroups.flatMap { $0.processes.map(\.pid) })

    for process in processes where !claudeOwnedPids.contains(process.pid) {
        var matched = false
        for p in patterns {
            if matchesAppPattern(process.command, pattern: p.pattern) {
                let current = appMemory[p.name] ?? (0, 0, p.color)
                appMemory[p.name] = (current.memory + process.memory, current.count + 1, p.color)
                matched = true
                break
            }
        }
        if !matched {
            unmatchedMemory += process.memory
            unmatchedCount += 1
        }
    }

    if let claudePattern, !claudeGroups.isEmpty {
        let unownedClaude = appMemory[claudePattern.name] ?? (0, 0, claudePattern.color)
        appMemory[claudePattern.name] = (
            unownedClaude.memory + claudeGroups.reduce(0) { $0 + $1.memory },
            unownedClaude.count + claudeGroups.count,
            claudePattern.color
        )
    }

    var results = appMemory.map { name, data in
        AppCategoryResult(name: name, memory: data.memory, processCount: data.count, color: data.color)
    }.sorted { $0.memory > $1.memory }

    if unmatchedMemory > 500 * 1024 * 1024 {
        results.append(AppCategoryResult(name: "Other", memory: unmatchedMemory, processCount: unmatchedCount, color: "#6b7280"))
    }

    return results
}

/// Filter processes to only actual Claude CLI sessions (not node subprocesses).
/// Only processes whose command starts with "claude" and use > 50MB qualify.
public func filterClaudeSessions(_ processes: [ProcessSnapshot]) -> [ProcessSnapshot] {
    let groups = groupClaudeProcessTrees(processes)
    if !groups.isEmpty {
        return groups.map(\.root)
    }

    return processes.filter {
        isClaudeCLICommand($0.command) && $0.memory > 50 * 1024 * 1024
    }
}
