import XCTest
@testable import RAMBarLib

final class RefreshControllerTests: XCTestCase {
    func testPopoverRefreshControllerStartsStopsAndRestartsOneSchedule() {
        var refreshCount = 0
        var scheduledHandlers: [() -> Void] = []
        var cancellationCount = 0
        let controller = PopoverRefreshController(
            interval: 5,
            refresh: { refreshCount += 1 },
            schedule: { _, handler in
                scheduledHandlers.append(handler)
                return { cancellationCount += 1 }
            }
        )

        controller.setActive(true)
        controller.setActive(true)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(scheduledHandlers.count, 1)
        scheduledHandlers[0]()
        XCTAssertEqual(refreshCount, 2)

        controller.setActive(false)
        controller.setActive(false)
        XCTAssertEqual(cancellationCount, 1)

        controller.setActive(true)
        XCTAssertEqual(refreshCount, 3)
        XCTAssertEqual(scheduledHandlers.count, 2)
    }

    func testChromeDetailCountDoesNotLabelRendererEstimateAsTabs() {
        let estimated = ChromeDetailCount(rendererCount: 75, tabCount: nil)
        XCTAssertEqual(estimated.count, 75)
        XCTAssertEqual(estimated.label, "renderers")

        let loaded = ChromeDetailCount(rendererCount: 75, tabCount: 109)
        XCTAssertEqual(loaded.count, 109)
        XCTAssertEqual(loaded.label, "tabs")
    }
}
