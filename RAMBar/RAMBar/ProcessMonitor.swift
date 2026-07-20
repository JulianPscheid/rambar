import Foundation
import AppKit
import Darwin

/// Monitors running processes and categorizes memory usage
class ProcessMonitor {
    static let shared = ProcessMonitor()

    private var claudeOrphanTracker = ClaudeOrphanTracker()

    private init() {}

    /// Run a shell command and return output
    private func shell(_ command: String) -> String? {
        let task = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()

        task.standardOutput = pipe
        task.standardError = errorPipe
        task.standardInput = FileHandle.nullDevice

        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["bash", "-c", command]

        var env = Foundation.ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = NSHomeDirectory()
        env["LANG"] = "en_US.UTF-8"
        task.environment = env

        // Read data BEFORE waitUntilExit to prevent deadlock
        var outputData = Data()
        var errorData = Data()

        let outputHandle = pipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        do {
            try task.run()
        } catch {
            print("RAMBar shell launch error for '\(command.prefix(50))...': \(error)")
            return nil
        }

        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            outputData = outputHandle.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            errorData = errorHandle.readDataToEndOfFile()
            group.leave()
        }

        let result = group.wait(timeout: .now() + 10.0)

        if result == .timedOut {
            task.terminate()
            print("RAMBar shell timeout for '\(command.prefix(50))...'")
            return nil
        }

        task.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8)

        if task.terminationStatus != 0 && !errorData.isEmpty {
            if let errorStr = String(data: errorData, encoding: .utf8), !errorStr.isEmpty {
                print("RAMBar shell stderr for '\(command.prefix(30))...': \(errorStr.prefix(200))")
            }
        }

        return output
    }

    /// Read the macOS physical footprint, which includes compressed memory charged to the process.
    private func physicalFootprint(for pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }

        guard result == 0, info.ri_phys_footprint > 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// Get all running processes with ancestry, terminal, and memory metadata.
    func getProcessList() -> [ProcessInfo] {
        guard let output = shell("ps -axww -o pid=,ppid=,tty=,rss=,command=") else {
            print("Failed to read the process list")
            return []
        }

        return parseProcessList(output, footprintForPid: physicalFootprint).map {
            ProcessInfo(
                pid: $0.pid,
                parentPid: $0.parentPid,
                terminal: $0.terminal ?? "??",
                command: $0.command,
                memory: $0.memory
            )
        }
    }

    /// Get memory usage grouped by app.
    func getAppMemory(from processes: [ProcessInfo]) -> [AppMemory] {
        categorizeProcesses(processes.map(\.snapshot), patterns: defaultAppPatterns).map {
            AppMemory(name: $0.name, memory: $0.memory, processCount: $0.processCount, color: $0.color)
        }
    }

    /// Get Claude Code sessions, helper details, and processes left behind by closed sessions.
    func getClaudeProcessReport(from processes: [ProcessInfo]) -> ClaudeProcessReport {
        let snapshots = processes.map(\.snapshot)
        let groups = groupClaudeProcessTrees(snapshots)
        let orphanSummary = claudeOrphanTracker.update(processes: snapshots, groups: groups)
        let workingDirectories = getWorkingDirectories(for: groups.map { $0.root.pid })
        var sessions: [ClaudeSession] = []

        for group in groups {
            let process = group.root
            let helpers = group.helperSummary
            let workingDir = workingDirectories[process.pid] ?? "Unknown"

            let pathComponents = workingDir.split(separator: "/")
            let projectName = pathComponents.last.map(String.init) ?? "Unknown"

            sessions.append(ClaudeSession(
                pid: process.pid,
                projectName: projectName,
                workingDirectory: workingDir,
                terminal: process.terminal ?? "??",
                memory: group.memory,
                processCount: group.processCount,
                helperProcessCount: helpers.total,
                nodeProcessCount: helpers.node,
                pythonProcessCount: helpers.python
            ))
        }

        let orphanedProcesses = OrphanedClaudeProcesses(
            processCount: orphanSummary.processCount,
            memory: orphanSummary.memory
        )
        if orphanSummary.newProcessCount > 0 {
            CrashDetector.shared.sendOrphanedClaudeWarning(
                processCount: orphanSummary.processCount,
                memory: orphanSummary.memory
            )
        }

        return ClaudeProcessReport(
            sessions: sessions.sorted { $0.memory > $1.memory },
            orphanedProcesses: orphanedProcesses
        )
    }

    private func getWorkingDirectories(for pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }

        let pidList = pids.map(String.init).joined(separator: ",")
        guard let output = shell("lsof -a -d cwd -p \(pidList) -Fn") else { return [:] }
        return parseWorkingDirectories(output)
    }

    /// Get Chrome tabs (approximation based on renderer processes)
    func getChromeTabs(from processes: [ProcessInfo]) -> [ChromeTab] {
        let renderers = processes.filter {
            $0.command.contains("Google Chrome Helper (Renderer)")
        }.sorted { $0.memory > $1.memory }
        guard !renderers.isEmpty else { return [] }

        // Get actual tab titles via AppleScript
        var tabTitles: [String] = []

        if let output = shell("""
            osascript -e 'tell application "Google Chrome"
                set tabList to ""
                try
                    repeat with w from 1 to (count of windows)
                        repeat with t from 1 to (count of tabs of window w)
                            set tabTitle to title of tab t of window w
                            set tabList to tabList & tabTitle & "\\n"
                        end repeat
                    end repeat
                end try
                return tabList
            end tell' 2>/dev/null
            """) {
            let lines = output.components(separatedBy: "\n")
            for line in lines where !line.isEmpty {
                tabTitles.append(line)
            }
        }

        // Match tabs with renderer processes (approximate)
        var tabs: [ChromeTab] = []
        for (index, process) in renderers.prefix(15).enumerated() {
            let tabTitle = index < tabTitles.count ? tabTitles[index] : "Chrome Tab \(index + 1)"
            let title = tabTitle.trimmingCharacters(in: .whitespaces)
            if title.isEmpty || title.lowercased() == "chrome" || title.lowercased() == "new tab" {
                continue
            }
            tabs.append(ChromeTab(
                pid: process.pid,
                title: String(title.prefix(50)),
                memory: process.memory
            ))
        }

        return tabs
    }

    func getChromeRendererCount(from processes: [ProcessInfo]) -> Int {
        processes.count {
            $0.command.contains("Google Chrome Helper (Renderer)")
        }
    }

    /// Get Python processes
    func getPythonProcesses(from processes: [ProcessInfo]) -> [PythonProcess] {
        let pythonProcs = processes.filter {
            $0.command.localizedCaseInsensitiveContains("python") && $0.memory > 10 * 1024 * 1024
        }

        return pythonProcs.map { process in
            var script = "Python Process"

            if let match = process.command.range(of: #"([^\s/]+\.py)"#, options: .regularExpression) {
                script = String(process.command[match])
            } else if process.command.contains("voice-mode") {
                script = "voice-mode (MCP)"
            } else if process.command.contains("jupyter") {
                script = "Jupyter"
            } else if process.command.contains("ipython") {
                script = "IPython"
            }

            return PythonProcess(pid: process.pid, script: script, memory: process.memory)
        }.sorted { $0.memory > $1.memory }
    }

    /// Get VS Code workspaces
    func getVSCodeWorkspaces(from processes: [ProcessInfo]) -> [VSCodeWorkspace] {
        let vscodeProcs = processes.filter {
            $0.command.contains("Visual Studio Code") || $0.command.contains("Code Helper")
        }

        guard !vscodeProcs.isEmpty else { return [] }

        let totalMemory = vscodeProcs.reduce(0) { $0 + $1.memory }
        let totalCount = vscodeProcs.count

        var windows: [String] = []

        if let output = shell("""
            osascript -e 'tell application "Visual Studio Code"
                try
                    return name of every window
                end try
            end tell' 2>/dev/null
            """) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                windows = trimmed.components(separatedBy: ", ")
            }
        }

        if windows.isEmpty {
            return [VSCodeWorkspace(name: "VS Code (total)", memory: totalMemory, processCount: totalCount)]
        }

        let memPerWindow = totalMemory / UInt64(max(windows.count, 1))
        let procsPerWindow = totalCount / max(windows.count, 1)

        return windows.map { window in
            var name = window
            if let range = window.range(of: " — ") {
                let afterDash = String(window[range.upperBound...])
                name = afterDash.components(separatedBy: " [").first ?? afterDash
            }
            return VSCodeWorkspace(name: name, memory: memPerWindow, processCount: procsPerWindow)
        }
    }

    /// Generate diagnostics based on current state
    func generateDiagnostics(state: RAMBarState) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        if let mem = state.systemMemory {
            if mem.usagePercent > 90 {
                diagnostics.append(Diagnostic(
                    message: "Memory critical (\(Int(mem.usagePercent))%)",
                    severity: .critical
                ))
            } else if mem.usagePercent > 80 {
                diagnostics.append(Diagnostic(
                    message: "Memory high (\(Int(mem.usagePercent))%)",
                    severity: .warning
                ))
            }
        }

        let activeSessions = state.claudeSessions.count
        if activeSessions > 3 {
            diagnostics.append(Diagnostic(
                message: "\(activeSessions) Claude sessions active",
                severity: .warning
            ))
        }

        if let hotSession = state.claudeSessions.filter(\.needsAttention).max(by: { $0.memory < $1.memory }) {
            diagnostics.append(Diagnostic(
                message: "Claude PID \(hotSession.pid) high: \(hotSession.formattedMemory), \(hotSession.processCount) processes",
                severity: .critical
            ))
        }

        let orphaned = state.orphanedClaudeProcesses
        if orphaned.processCount > 0 {
            diagnostics.append(Diagnostic(
                message: "\(orphaned.processCount) orphaned Claude helpers using \(orphaned.formattedMemory)",
                severity: orphaned.memory >= 1_073_741_824 ? .critical : .warning
            ))
        }

        if let chrome = state.apps.first(where: { $0.name == "Chrome" }), chrome.memoryGB > 4 {
            diagnostics.append(Diagnostic(
                message: "Chrome using \(chrome.formattedMemory)",
                severity: .warning
            ))
        }

        if diagnostics.isEmpty {
            diagnostics.append(Diagnostic(message: "All systems nominal", severity: .info))
        }

        return diagnostics
    }
}

struct ProcessInfo {
    let pid: Int32
    let parentPid: Int32
    let terminal: String
    let command: String
    let memory: UInt64

    var snapshot: ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            parentPid: parentPid,
            terminal: terminal,
            command: command,
            memory: memory
        )
    }
}
