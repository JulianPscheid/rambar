import XCTest
@testable import RambarSystem
@testable import RambarKit

final class SessionIndexTests: XCTestCase {
    func testEncodingMatchesLiveLayout() {
        // Verified live: /Users/x/.axiom-worktrees/y → -Users-x--axiom-worktrees-y
        XCTAssertEqual(
            SessionIndex.encodeClaudeProjectDirectory(cwd: "/Users/x/.axiom-worktrees/y"),
            "-Users-x--axiom-worktrees-y"
        )
        XCTAssertEqual(
            SessionIndex.encodeClaudeProjectDirectory(cwd: "/Users/x"),
            "-Users-x"
        )
        XCTAssertEqual(
            SessionIndex.encodeClaudeProjectDirectory(cwd: "/Users/x/hedy_mobile"),
            "-Users-x-hedy-mobile"
        )
    }

    func testClaudeTitlePrecedenceUsesCustomThenAIThenPrompt() throws {
        let home = NSTemporaryDirectory() + "rambar-home-\(UUID().uuidString)"
        let projectDirectory = home + "/.claude/projects/-Users-x-proj"
        try FileManager.default.createDirectory(
            atPath: projectDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Shape observed in live ccd transcripts: queue-operation first.
        let queued = """
        {"type":"ai-title","aiTitle":"Review RAMBar pull requests","sessionId":"queued"}
        {"type":"queue-operation","operation":"enqueue","content":"review the rambar prs/issues"}
        {"type":"user","message":{"role":"user","content":"review the rambar prs/issues"}}
        """
        try queued.write(
            toFile: projectDirectory + "/queued.jsonl", atomically: true, encoding: .utf8
        )

        // CLI shape: user entry with content blocks, preceded by noise.
        let blocks = """
        {"type":"summary","summary":"whatever"}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"  fix the\\nlogin bug   now"}]}}
        """
        try blocks.write(
            toFile: projectDirectory + "/blocks.jsonl", atomically: true, encoding: .utf8
        )

        let custom = """
        {"type":"ai-title","aiTitle":"Generated title","sessionId":"custom"}
        {"type":"custom-title","customTitle":"My release audit","sessionId":"custom"}
        {"type":"user","message":{"role":"user","content":"audit the next release"}}
        """
        try custom.write(
            toFile: projectDirectory + "/custom.jsonl", atomically: true, encoding: .utf8
        )

        let start = Date().timeIntervalSince1970
        let trees = buildSessionTrees([
            ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"),
            ProcessSample(
                pid: 10, ppid: 1,
                execPath: "/Users/x/.local/share/claude/versions/2.1.216",
                sessionIDHint: "queued", cwd: "/Users/x/proj", startTime: start
            ),
            ProcessSample(
                pid: 11, ppid: 1,
                execPath: "/Users/x/.local/share/claude/versions/2.1.216",
                sessionIDHint: "blocks", cwd: "/Users/x/proj", startTime: start + 1
            ),
            ProcessSample(
                pid: 12, ppid: 1,
                execPath: "/Users/x/.local/share/claude/versions/2.1.216",
                sessionIDHint: "custom", cwd: "/Users/x/proj", startTime: start + 2
            ),
        ])
        let identities = SessionIndex(home: home).identities(for: trees)
        XCTAssertEqual(
            identities[trees[0].key]?.title,
            "Review RAMBar pull requests"
        )
        XCTAssertEqual(
            identities[trees[1].key]?.title,
            "fix the login bug now"
        )
        XCTAssertEqual(
            identities[trees[2].key]?.title,
            "My release audit"
        )
    }

    func testResolvesConcurrentClaudeSessionsByStartTime() throws {
        let home = NSTemporaryDirectory() + "rambar-home-\(UUID().uuidString)"
        let projectDirectory = home + "/.claude/projects/-Users-x-hedy-mobile"
        try FileManager.default.createDirectory(
            atPath: projectDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let firstStart = Date().timeIntervalSince1970 - 120
        let secondStart = firstStart + 45
        try claudeTranscript(
            id: "11111111-1111-4111-8111-111111111111",
            title: "Fix memory accounting",
            timestamp: firstStart,
            path: projectDirectory + "/11111111-1111-4111-8111-111111111111.jsonl"
        )
        try claudeTranscript(
            id: "22222222-2222-4222-8222-222222222222",
            title: "Audit the release build",
            timestamp: secondStart,
            path: projectDirectory + "/22222222-2222-4222-8222-222222222222.jsonl"
        )

        let trees = buildSessionTrees([
            ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"),
            ProcessSample(
                pid: 10, ppid: 1,
                execPath: "/Users/x/.local/share/claude/versions/2.1.216",
                cwd: "/Users/x/hedy_mobile", startTime: firstStart
            ),
            ProcessSample(
                pid: 11, ppid: 1,
                execPath: "/Users/x/.local/share/claude/versions/2.1.216",
                cwd: "/Users/x/hedy_mobile", startTime: secondStart
            ),
        ])

        let identities = SessionIndex(home: home).identities(for: trees)
        XCTAssertEqual(identities[trees[0].key]?.title, "Fix memory accounting")
        XCTAssertEqual(identities[trees[1].key]?.title, "Audit the release build")
    }

    func testClaudeResumeHintWinsOverStartTime() throws {
        let home = NSTemporaryDirectory() + "rambar-home-\(UUID().uuidString)"
        let projectDirectory = home + "/.claude/projects/-Users-x-proj"
        try FileManager.default.createDirectory(
            atPath: projectDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let id = "33333333-3333-4333-8333-333333333333"
        try claudeTranscript(
            id: id,
            title: "Continue the older investigation",
            timestamp: Date().timeIntervalSince1970 - 86_400,
            path: projectDirectory + "/\(id).jsonl"
        )
        let start = Date().timeIntervalSince1970
        let trees = buildSessionTrees([
            ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"),
            ProcessSample(
                pid: 10, ppid: 1,
                execPath: "/Users/x/.local/share/claude/versions/2.1.216",
                sessionIDHint: id,
                cwd: "/Users/x/proj", startTime: start
            ),
        ])

        let identity = try XCTUnwrap(SessionIndex(home: home).identities(for: trees).values.first)
        XCTAssertEqual(identity.sessionID, id)
        XCTAssertEqual(identity.title, "Continue the older investigation")
    }

    func testCodexThreadNameResolvesFromRolloutStart() throws {
        let home = NSTemporaryDirectory() + "rambar-home-\(UUID().uuidString)"
        let sessionsDirectory = home + "/.codex/sessions/2026/07/21"
        try FileManager.default.createDirectory(
            atPath: sessionsDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let id = "019f81d6-f643-7003-b55c-856d51701c9f"
        let start = Date().timeIntervalSince1970 - 30
        let sessionIndex = """
        {"id":"\(id)","thread_name":"Show session names in RAMBar","updated_at":"\(iso8601(start))"}
        """
        try sessionIndex.write(
            toFile: home + "/.codex/session_index.jsonl", atomically: true, encoding: .utf8
        )
        let rollout = """
        {"timestamp":"\(iso8601(start))","type":"session_meta","payload":{"id":"\(id)","timestamp":"\(iso8601(start))","cwd":"/Users/x/proj"}}
        """
        try rollout.write(
            toFile: sessionsDirectory + "/rollout-2026-07-21T10-00-00-\(id).jsonl",
            atomically: true,
            encoding: .utf8
        )
        let trees = buildSessionTrees([
            ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"),
            ProcessSample(
                pid: 10, ppid: 1, execPath: "/opt/homebrew/bin/codex",
                cwd: "/Users/x/proj", startTime: start
            ),
        ])

        let identity = try XCTUnwrap(SessionIndex(home: home).identities(for: trees).values.first)
        XCTAssertEqual(identity.sessionID, id)
        XCTAssertEqual(identity.title, "Show session names in RAMBar")
    }

    func testCodexRolloutPromptNamesThreadMissingFromIndex() throws {
        let home = NSTemporaryDirectory() + "rambar-home-\(UUID().uuidString)"
        let sessionsDirectory = home + "/.codex/sessions/2026/07/21"
        try FileManager.default.createDirectory(
            atPath: sessionsDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let id = "019f81d6-f643-7003-b55c-856d51701c9e"
        let start = Date().timeIntervalSince1970 - 30
        let rollout = """
        {"timestamp":"\(iso8601(start))","type":"session_meta","payload":{"id":"\(id)","timestamp":"\(iso8601(start))","cwd":"/Users/x/proj","originator":"codex_cli"}}
        {"timestamp":"\(iso8601(start + 1))","type":"event_msg","payload":{"type":"user_message","message":"Investigate the memory spike"}}
        """
        try rollout.write(
            toFile: sessionsDirectory + "/rollout-2026-07-21T10-00-00-\(id).jsonl",
            atomically: true,
            encoding: .utf8
        )
        let trees = buildSessionTrees([
            ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"),
            ProcessSample(
                pid: 10, ppid: 1, execPath: "/opt/homebrew/bin/codex",
                cwd: "/Users/x/proj", startTime: start
            ),
        ])

        XCTAssertEqual(
            SessionIndex(home: home).identities(for: trees).values.first?.title,
            "Investigate the memory spike"
        )
    }

    func testHeadlessCodexExecGetsProcessFallbackName() throws {
        let home = NSTemporaryDirectory() + "rambar-home-\(UUID().uuidString)"
        let sessionsDirectory = home + "/.codex/sessions/2026/07/21"
        try FileManager.default.createDirectory(
            atPath: sessionsDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: home) }

        let id = "019f81d6-f643-7003-b55c-856d51701c9d"
        let start = Date().timeIntervalSince1970 - 30
        let rollout = """
        {"timestamp":"\(iso8601(start))","type":"session_meta","payload":{"id":"\(id)","timestamp":"\(iso8601(start))","cwd":"/Users/x/proj","originator":"codex_exec"}}
        """
        try rollout.write(
            toFile: sessionsDirectory + "/rollout-2026-07-21T10-00-00-\(id).jsonl",
            atomically: true,
            encoding: .utf8
        )
        let trees = buildSessionTrees([
            ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"),
            ProcessSample(
                pid: 10, ppid: 1, execPath: "/opt/homebrew/bin/codex",
                cwd: "/Users/x/proj", startTime: start
            ),
        ])

        XCTAssertEqual(
            SessionIndex(home: home).identities(for: trees).values.first?.title,
            "Codex exec"
        )
    }

    func testCodexDesktopHostGetsDescriptiveFallback() throws {
        let start = Date().timeIntervalSince1970
        let trees = buildSessionTrees([
            ProcessSample(pid: 1, ppid: 0, execPath: "/sbin/launchd"),
            ProcessSample(
                pid: 9, ppid: 1,
                execPath: "/Applications/Codex.app/Contents/MacOS/ChatGPT",
                startTime: start - 10
            ),
            ProcessSample(
                pid: 10, ppid: 9, execPath: "/opt/homebrew/bin/codex",
                cwd: "/", startTime: start
            ),
        ])

        let tree = try XCTUnwrap(trees.first)
        XCTAssertEqual(tree.mode, .desktop)
        XCTAssertEqual(
            SessionIndex(home: "/nonexistent").identities(for: trees)[tree.key]?.title,
            "Codex desktop"
        )
    }

    func testCleanTitleStripsMarkupAndTruncates() {
        // Tags are stripped, their inner text kept — a /prep transcript still
        // gets a name.
        XCTAssertEqual(
            cleanTitle("<command-message>prep</command-message> run the briefing"),
            "prep run the briefing"
        )
        XCTAssertNil(cleanTitle("<tag></tag>  \n "))
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(cleanTitle(long)?.count, 60)
    }

    private func claudeTranscript(
        id: String,
        title: String,
        timestamp: Double,
        path: String
    ) throws {
        let contents = """
        {"type":"ai-title","aiTitle":"\(title)","sessionId":"\(id)"}
        {"type":"user","timestamp":"\(iso8601(timestamp))","sessionId":"\(id)","cwd":"/Users/x/proj","message":{"role":"user","content":"fixture prompt"}}
        """
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func iso8601(_ timestamp: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
