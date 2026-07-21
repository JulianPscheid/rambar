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
        XCTAssertNil(groups.first { $0.displayName == "Node.js" }, "agent helpers must not be counted twice")
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

    func testOtherAppearsOnlyWhenUnmatchedFootprintCrossesThreshold() {
        let small = [Fixture.process(10, 1, "/usr/libexec/unmatched", mb: 499)]
        XCTAssertTrue(buildProcessGroups(samples: small, sessionTrees: []).isEmpty)

        let large = [Fixture.process(10, 1, "/usr/libexec/unmatched", mb: 501)]
        let groups = buildProcessGroups(samples: large, sessionTrees: [])
        XCTAssertEqual(groups.map(\.displayName), ["Other"])
        XCTAssertEqual(groups[0].processCount, 1)
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
