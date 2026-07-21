import XCTest
@testable import RambarKit

final class ProcessGroupTests: XCTestCase {
    func testAgentGroupIncludesSessionTreesAndDesktopHostProcessesOnce() throws {
        let trees = buildSessionTrees(Fixture.machine)
        let groups = buildProcessGroups(samples: Fixture.machine, sessionTrees: trees)

        let claude = try XCTUnwrap(groups.first { $0.family == .claude })
        XCTAssertEqual(claude.displayName, "Claude Code")
        XCTAssertEqual(claude.kind, .agent)
        XCTAssertEqual(claude.sessionCount, 4)
        XCTAssertEqual(claude.processCount, 13)
        XCTAssertEqual(claude.footprint, 2_544 * 1_048_576)
        XCTAssertEqual(claude.hostProcessCount, 4)
        XCTAssertEqual(claude.hostFootprint, 482 * 1_048_576)
        XCTAssertEqual(
            trees.filter { $0.family == .claude }.reduce(claude.hostFootprint) { $0 + $1.footprint },
            claude.footprint
        )
        XCTAssertNil(groups.first { $0.displayName == "Node.js" }, "agent helpers must not be counted twice")
    }

    func testDesktopAppWithoutSessionsStaysAnApplicationGroup() throws {
        let samples = [
            Fixture.process(1, 0, Fixture.launchd),
            Fixture.process(100, 1, Fixture.claudeDesktopUI, mb: 300),
            Fixture.process(120, 100, Fixture.claudeDesktopHelper, mb: 180),
        ]

        let group = try XCTUnwrap(buildProcessGroups(samples: samples, sessionTrees: []).first)
        XCTAssertEqual(group.displayName, "Claude")
        XCTAssertEqual(group.kind, .application)
        XCTAssertNil(group.family)
        XCTAssertEqual(group.footprint, 480 * 1_048_576)
    }

    func testKnownApplicationsAndStandaloneRuntimesBecomePrimaryGroups() throws {
        let samples = [
            Fixture.process(1, 0, Fixture.launchd),
            Fixture.process(10, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", mb: 800),
            Fixture.process(11, 1, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", mb: 300),
            Fixture.process(12, 1, Fixture.node, mb: 200),
        ]

        let groups = buildProcessGroups(samples: samples, sessionTrees: [])

        XCTAssertEqual(groups.map(\.displayName), ["Chrome", "VS Code", "Node.js"])
        XCTAssertEqual(groups.map(\.processCount), [1, 1, 1])
    }

    func testPreviouslyUnknownAppBundleGetsItsOwnGroup() throws {
        let signal = Fixture.process(
            10, 1,
            "/Applications/Signal.app/Contents/Frameworks/Signal Helper.app/Contents/MacOS/Signal Helper",
            mb: 700
        )

        let group = try XCTUnwrap(
            buildProcessGroups(samples: [signal], sessionTrees: []).first
        )
        XCTAssertEqual(group.key, "app:signal")
        XCTAssertEqual(group.displayName, "Signal")
        XCTAssertEqual(group.kind, .application)
    }

    func testVersionedClaudeExecutableAppearsInClaudeGroup() throws {
        let versioned = Fixture.process(
            10, 1, "/Users/dev/.local/share/claude/versions/2.1.216",
            cwd: "/Users/dev/projects/alpha", mb: 600
        )
        let samples = [Fixture.process(1, 0, Fixture.launchd), versioned]
        let trees = buildSessionTrees(samples)

        let claude = try XCTUnwrap(
            buildProcessGroups(samples: samples, sessionTrees: trees).first { $0.family == .claude }
        )
        XCTAssertEqual(claude.sessionCount, 1)
        XCTAssertEqual(claude.footprint, 600 * 1_048_576)
    }

    func testAgentInfrastructureCountsAsSharedOverheadNotSessions() throws {
        let samples = [
            Fixture.process(1, 0, Fixture.launchd, start: 0),
            Fixture.process(10, 1, Fixture.cliEngine, cwd: "/Users/dev/project", mb: 100, start: 100),
            Fixture.process(
                20, 1, Fixture.cliEngine, cwd: Fixture.home, mb: 200, start: 110,
                agentOwnerPID: 10, isAgentInfrastructure: true
            ),
            Fixture.process(21, 20, Fixture.node, mb: 300, start: 120),
            Fixture.process(
                30, 1, Fixture.cliEngine, cwd: "/tmp/spare", mb: 400, start: 130,
                isAgentInfrastructure: true
            ),
            Fixture.process(31, 30, Fixture.node, mb: 500, start: 140),
        ]

        let trees = buildSessionTrees(samples)
        let claude = try XCTUnwrap(
            buildProcessGroups(samples: samples, sessionTrees: trees).first { $0.family == .claude }
        )

        XCTAssertEqual(claude.sessionCount, 1)
        XCTAssertEqual(claude.processCount, 5)
        XCTAssertEqual(claude.footprint, 1_500 * 1_048_576)
        XCTAssertEqual(claude.hostProcessCount, 2)
        XCTAssertEqual(claude.hostFootprint, 900 * 1_048_576)
    }

    func testOtherAppearsOnlyWhenUnmatchedFootprintCrossesThreshold() {
        let small = [Fixture.process(10, 1, "/usr/libexec/unmatched", mb: 499)]
        XCTAssertTrue(buildProcessGroups(samples: small, sessionTrees: []).isEmpty)

        let large = [Fixture.process(10, 1, "/usr/libexec/unmatched", mb: 501)]
        let groups = buildProcessGroups(samples: large, sessionTrees: [])
        XCTAssertEqual(groups.map(\.displayName), ["Other"])
        XCTAssertEqual(groups[0].processCount, 1)

        let boundary = [Fixture.process(10, 1, "/usr/libexec/unmatched", mb: 500)]
        XCTAssertEqual(
            buildProcessGroups(samples: boundary, sessionTrees: []).map(\.displayName),
            ["Other"]
        )
    }

    func testGenericBundleKeysDoNotMergePunctuationVariants() {
        let groups = buildProcessGroups(samples: [
            Fixture.process(10, 1, "/Applications/Foo Bar.app/Contents/MacOS/Foo Bar", mb: 100),
            Fixture.process(11, 1, "/Applications/Foo-Bar.app/Contents/MacOS/Foo-Bar", mb: 100),
        ], sessionTrees: [])

        XCTAssertEqual(Set(groups.map(\.displayName)), ["Foo Bar", "Foo-Bar"])
        XCTAssertEqual(Set(groups.map(\.key)).count, 2)
    }

    func testTinyApplicationGroupsStayOutOfThePrimaryList() {
        let tiny = Fixture.process(
            10, 1, "/Applications/Tiny Utility.app/Contents/MacOS/Tiny Utility", mb: 49
        )
        XCTAssertTrue(buildProcessGroups(samples: [tiny], sessionTrees: []).isEmpty)
    }

    func testDuplicatePidIsNeverCountedTwice() throws {
        let chrome = Fixture.process(
            10, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", mb: 800
        )
        let groups = buildProcessGroups(samples: [chrome, chrome], sessionTrees: [])
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.processCount, 1)
        XCTAssertEqual(group.footprint, 800 * 1_048_576)
    }
}
