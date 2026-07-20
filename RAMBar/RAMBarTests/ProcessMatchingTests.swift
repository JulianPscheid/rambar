import XCTest
@testable import RAMBarLib

final class ProcessMatchingTests: XCTestCase {

    // MARK: - Process list parsing

    func testParseProcessListPreservesAncestryTerminalAndFullCommand() {
        let output = """
          100    10 ttys001 512000 claude --resume session-id
          101   100       ??   2048 /opt/homebrew/bin/node mcp server.js
        malformed row
        """

        let processes = parseProcessList(output) { pid in
            pid == 100 ? 700_000_000 : nil
        }

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].pid, 100)
        XCTAssertEqual(processes[0].parentPid, 10)
        XCTAssertEqual(processes[0].terminal, "ttys001")
        XCTAssertEqual(processes[0].command, "claude --resume session-id")
        XCTAssertEqual(processes[0].memory, 700_000_000, "Physical footprint should take precedence over RSS")
        XCTAssertEqual(processes[1].memory, 2_097_152, "RSS should remain as a fallback")
    }

    // MARK: - Pattern matching

    func testClaudeCliMatchesClaude() {
        XCTAssertTrue(
            matchesAppPattern("claude --dangerously-skip-permissions", pattern: "^claude"),
            "Actual claude CLI should match"
        )
    }

    func testClaudeDesktopAppDoesNotMatch() {
        // macOS ps shows full path for .app bundles
        XCTAssertFalse(
            matchesAppPattern("/Applications/Claude.app/Contents/MacOS/Claude", pattern: "^claude"),
            "Claude desktop app (full path) should not match prefix pattern"
        )
    }

    func testClaudeCliCommandRecognizesInstalledBinaryPaths() {
        XCTAssertTrue(isClaudeCLICommand("/Users/max/.local/bin/claude --resume"))
        XCTAssertTrue(isClaudeCLICommand("/Users/max/.local/share/claude/versions/2.1.215 --resume abc"))
        XCTAssertFalse(isClaudeCLICommand("/Applications/Claude.app/Contents/MacOS/Claude"))
    }

    func testNodeMcpServerWithClaudePathDoesNotMatchClaude() {
        let cmd = "/usr/local/bin/node /Users/max/.claude/mcp-servers/some-server/index.js"
        XCTAssertFalse(
            matchesAppPattern(cmd, pattern: "^claude"),
            "Node MCP server with .claude/ in path should NOT match Claude Code"
        )
    }

    func testNodeWorkerWithClaudeInPathDoesNotMatchClaude() {
        let cmd = "/opt/homebrew/bin/node /Users/max/.claude/local/agent-tool-runner.mjs"
        XCTAssertFalse(
            matchesAppPattern(cmd, pattern: "^claude"),
            "Node worker spawned by claude should NOT match Claude Code"
        )
    }

    func testContainsPatternStillWorksForChrome() {
        let cmd = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        XCTAssertTrue(
            matchesAppPattern(cmd, pattern: "Google Chrome"),
            "Contains-based pattern should still work for Chrome"
        )
    }

    func testContainsPatternStillWorksForSlack() {
        let cmd = "/Applications/Slack.app/Contents/MacOS/Slack Helper (Renderer)"
        XCTAssertTrue(
            matchesAppPattern(cmd, pattern: "Slack"),
            "Contains-based pattern should still work for Slack"
        )
    }

    func testGranolaPatternMatches() {
        let cmd = "/Applications/Granola.app/Contents/Frameworks/Granola Helper (Renderer).app/Contents/MacOS/Granola Helper (Renderer)"
        XCTAssertTrue(
            matchesAppPattern(cmd, pattern: "Granola"),
            "Granola should match its pattern"
        )
    }

    // MARK: - App categorization

    func testCategorizeProcesses_ClaudeNotOvercounted() {
        let processes: [ProcessSnapshot] = [
            ProcessSnapshot(command: "claude --dangerously-skip-permissions", memory: 1_600_000_000),
            ProcessSnapshot(command: "claude --dangerously-skip-permissions --dangerously-skip-permissions", memory: 800_000_000),
            ProcessSnapshot(command: "/opt/homebrew/bin/node /Users/max/.claude/mcp-servers/voice-mode/server.js", memory: 60_000_000),
            ProcessSnapshot(command: "/opt/homebrew/bin/node /Users/max/.claude/local/agent-tool-runner.mjs", memory: 120_000_000),
        ]

        let result = categorizeProcesses(processes, patterns: defaultAppPatterns)

        let claudeEntry = result.first { $0.name == "Claude Code" }
        let nodeEntry = result.first { $0.name == "Node.js" }

        XCTAssertNotNil(claudeEntry, "Should have Claude Code entry")
        XCTAssertEqual(claudeEntry?.processCount, 2, "Only 2 actual claude CLI processes")
        XCTAssertEqual(claudeEntry?.memory, 2_400_000_000, "Memory should be sum of 2 CLI processes only")

        XCTAssertNotNil(nodeEntry, "Node workers should be categorized as Node.js")
        XCTAssertEqual(nodeEntry?.processCount, 2, "2 node worker processes")
    }

    func testCategorizeProcesses_AttributesClaudeDescendantsOnlyToClaude() {
        let processes: [ProcessSnapshot] = [
            ProcessSnapshot(pid: 100, parentPid: 10, terminal: "ttys001", command: "claude --resume", memory: 500_000_000),
            ProcessSnapshot(pid: 101, parentPid: 100, command: "npm exec mcp-server", memory: 100_000_000),
            ProcessSnapshot(pid: 102, parentPid: 101, command: "/opt/homebrew/bin/node mcp-server.js", memory: 2_000_000_000),
            ProcessSnapshot(pid: 103, parentPid: 100, command: "/usr/bin/python3 tool.py", memory: 300_000_000),
            ProcessSnapshot(pid: 200, parentPid: 1, command: "/opt/homebrew/bin/node unrelated.js", memory: 700_000_000),
        ]

        let result = categorizeProcesses(processes, patterns: defaultAppPatterns)

        let claudeEntry = result.first { $0.name == "Claude Code" }
        let nodeEntry = result.first { $0.name == "Node.js" }
        let pythonEntry = result.first { $0.name == "Python" }

        XCTAssertEqual(claudeEntry?.processCount, 1, "The count should represent interactive Claude sessions")
        XCTAssertEqual(claudeEntry?.memory, 2_900_000_000, "Claude should include its npm, Node, and Python descendants")
        XCTAssertEqual(nodeEntry?.processCount, 1, "A Claude-owned Node process should not be counted twice")
        XCTAssertEqual(nodeEntry?.memory, 700_000_000)
        XCTAssertNil(pythonEntry, "A Claude-owned Python process should not also appear under Python")
    }

    func testCategorizeProcesses_GranolaNotMissing() {
        let processes: [ProcessSnapshot] = [
            ProcessSnapshot(command: "/Applications/Granola.app/Contents/MacOS/Granola", memory: 200_000_000),
            ProcessSnapshot(command: "/Applications/Granola.app/Contents/Frameworks/Granola Helper (Renderer).app/Contents/MacOS/Granola Helper (Renderer)", memory: 500_000_000),
        ]

        let result = categorizeProcesses(processes, patterns: defaultAppPatterns)

        let granolaEntry = result.first { $0.name == "Granola" }
        XCTAssertNotNil(granolaEntry, "Granola should appear as its own category")
        XCTAssertEqual(granolaEntry?.processCount, 2)
        XCTAssertEqual(granolaEntry?.memory, 700_000_000)
    }

    func testCategorizeProcesses_GranolaNotInOther() {
        let processes: [ProcessSnapshot] = [
            ProcessSnapshot(command: "/Applications/Granola.app/Contents/Frameworks/Granola Helper (Renderer).app/Contents/MacOS/Granola Helper (Renderer)", memory: 8_000_000_000),
        ]

        let result = categorizeProcesses(processes, patterns: defaultAppPatterns)

        let otherEntry = result.first { $0.name == "Other" }
        XCTAssertNil(otherEntry, "Granola should NOT end up in Other")
    }

    // MARK: - Claude session detection

    func testGroupClaudeProcessTrees_AggregatesRecursiveDescendants() throws {
        let processes: [ProcessSnapshot] = [
            ProcessSnapshot(pid: 100, parentPid: 10, terminal: "ttys001", command: "claude", memory: 500_000_000),
            ProcessSnapshot(pid: 101, parentPid: 100, command: "npm exec mcp-server", memory: 100_000_000),
            ProcessSnapshot(pid: 102, parentPid: 101, command: "/opt/homebrew/bin/node mcp-server.js", memory: 2_000_000_000),
            ProcessSnapshot(pid: 103, parentPid: 102, command: "/usr/bin/python3 tool.py", memory: 300_000_000),
            ProcessSnapshot(pid: 200, parentPid: 1, command: "/opt/homebrew/bin/node unrelated.js", memory: 700_000_000),
        ]

        let group = try XCTUnwrap(groupClaudeProcessTrees(processes).first)

        XCTAssertEqual(group.root.pid, 100)
        XCTAssertEqual(group.processCount, 4)
        XCTAssertEqual(group.memory, 2_900_000_000)
        XCTAssertEqual(Set(group.processes.map(\.pid)), Set([100, 101, 102, 103]))
    }

    func testGroupClaudeProcessTrees_DoesNotTreatDetachedHelperAsSession() {
        let processes: [ProcessSnapshot] = [
            ProcessSnapshot(pid: 100, parentPid: 1, command: "claude daemon run", memory: 500_000_000),
            ProcessSnapshot(pid: 101, parentPid: 100, command: "/opt/homebrew/bin/node helper.js", memory: 2_000_000_000),
        ]

        XCTAssertTrue(groupClaudeProcessTrees(processes).isEmpty)
    }

    func testGroupClaudeProcessTrees_StopsAtMissingParentWithoutLooping() {
        let processes: [ProcessSnapshot] = [
            ProcessSnapshot(pid: 101, parentPid: 999, command: "/opt/homebrew/bin/node orphan.js", memory: 2_000_000_000),
        ]

        XCTAssertTrue(groupClaudeProcessTrees(processes).isEmpty)
    }

    func testFilterClaudeSessions_OnlyCliProcesses() {
        let processes: [ProcessSnapshot] = [
            ProcessSnapshot(pid: 100, command: "claude --dangerously-skip-permissions", memory: 1_600_000_000),
            ProcessSnapshot(pid: 101, command: "claude --dangerously-skip-permissions --dangerously-skip-permissions", memory: 800_000_000),
            ProcessSnapshot(pid: 102, command: "/opt/homebrew/bin/node /Users/max/.claude/mcp-servers/voice-mode/server.js", memory: 60_000_000),
            ProcessSnapshot(pid: 103, command: "/opt/homebrew/bin/node /Users/max/.claude/local/agent-tool-runner.mjs", memory: 120_000_000),
        ]

        let sessions = filterClaudeSessions(processes)

        XCTAssertEqual(sessions.count, 2, "Only actual claude CLI processes should be sessions")
        XCTAssertTrue(sessions.allSatisfy { $0.command.hasPrefix("claude") })
    }
}
