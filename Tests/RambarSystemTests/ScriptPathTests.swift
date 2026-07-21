import XCTest
@testable import RambarSystem
@testable import RambarKit

final class ScriptPathTests: XCTestCase {
    func testFirstNonFlagArgumentWins() {
        XCTAssertEqual(
            scriptPath(fromArguments: ["node", "/x/mcp/index.js", "--port", "3000"]),
            "/x/mcp/index.js"
        )
        XCTAssertEqual(
            scriptPath(fromArguments: ["node", "--max-old-space-size=4096", "/x/server.js"]),
            "/x/server.js"
        )
    }

    func testNoScriptReturnsNil() {
        XCTAssertNil(scriptPath(fromArguments: ["node"]))
        XCTAssertNil(scriptPath(fromArguments: ["node", "--version"]))
    }

    func testEnvAssignmentsSkipped() {
        XCTAssertEqual(
            scriptPath(fromArguments: ["python", "PYTHONHASHSEED=0", "/x/train.py"]),
            "/x/train.py"
        )
    }

    func testAgentSessionIDHintUsesOnlyKnownResumeForms() {
        let claudeID = "33333333-3333-4333-8333-333333333333"
        XCTAssertEqual(
            agentSessionIDHint(
                family: .claude,
                arguments: ["/usr/bin/claude", "--resume", claudeID]
            ),
            claudeID
        )

        let codexID = "019f81d6-f643-7003-b55c-856d51701c9f"
        XCTAssertEqual(
            agentSessionIDHint(
                family: .codex,
                arguments: ["/usr/bin/codex", "resume", codexID]
            ),
            codexID
        )
        XCTAssertNil(agentSessionIDHint(
            family: .codex,
            arguments: ["/usr/bin/codex", "exec", codexID]
        ))
    }

    func testClaudeProcessMetadataRecognizesDetachedDaemonOwner() {
        let metadata = agentProcessMetadata(
            family: .claude,
            arguments: [
                "/Users/dev/.local/bin/claude", "daemon", "run",
                "--origin", "transient",
                "--spawned-by",
                #"{"label":"claude","cwd":"/Users/dev/project","pid":70889}"#,
            ]
        )

        XCTAssertEqual(metadata.ownerPID, 70889)
        XCTAssertTrue(metadata.isInfrastructure)
    }

    func testClaudeProcessMetadataRecognizesBackgroundSpare() {
        let metadata = agentProcessMetadata(
            family: .claude,
            arguments: [
                "claude", "bg-pty-host", "--bg-pty-host", "/tmp/worker.pty.sock",
                "--", "/Users/dev/.local/bin/claude", "--bg-spare", "/tmp/claim.sock",
            ]
        )

        XCTAssertNil(metadata.ownerPID)
        XCTAssertTrue(metadata.isInfrastructure)
    }

    func testOrdinaryAgentProcessIsNotInfrastructure() {
        let metadata = agentProcessMetadata(
            family: .claude,
            arguments: ["claude", "--resume", "33333333-3333-4333-8333-333333333333"]
        )

        XCTAssertNil(metadata.ownerPID)
        XCTAssertFalse(metadata.isInfrastructure)
    }

    func testAgentFallbackUsesExecutableArgument() {
        let codex = "/Users/dev/.npm/@openai/.codex-old/bin/codex"
        XCTAssertEqual(
            fallbackAgentExecutablePath(fromArguments: [codex, "exec"]),
            codex
        )
        XCTAssertEqual(
            fallbackAgentExecutablePath(fromArguments: ["/opt/homebrew/bin/gemini"]),
            "/opt/homebrew/bin/gemini"
        )
    }

    func testAgentFallbackRejectsDesktopUIAndUnrelatedProcesses() {
        XCTAssertNil(fallbackAgentExecutablePath(fromArguments: []))
        XCTAssertNil(fallbackAgentExecutablePath(fromArguments: ["/usr/bin/node", "codex.js"]))
        XCTAssertNil(fallbackAgentExecutablePath(fromArguments: [
            "/Applications/Claude.app/Contents/MacOS/Claude"
        ]))
    }
}
