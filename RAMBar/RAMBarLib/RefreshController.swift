import Foundation

/// Owns the lifecycle of a periodic refresh without depending on AppKit or SwiftUI.
public final class PopoverRefreshController {
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

    private let interval: TimeInterval
    private let refresh: () -> Void
    private let schedule: Schedule
    private var cancelSchedule: (() -> Void)?
    private var isActive = false

    public init(
        interval: TimeInterval,
        refresh: @escaping () -> Void,
        schedule: @escaping Schedule
    ) {
        self.interval = interval
        self.refresh = refresh
        self.schedule = schedule
    }

    deinit {
        cancelSchedule?()
    }

    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active

        if active {
            refresh()
            cancelSchedule = schedule(interval, refresh)
        } else {
            cancelSchedule?()
            cancelSchedule = nil
        }
    }
}

/// Uses an actual Chrome tab count when available and otherwise labels the
/// cheap renderer-process estimate honestly.
public struct ChromeDetailCount {
    public let rendererCount: Int
    public let tabCount: Int?

    public init(rendererCount: Int, tabCount: Int?) {
        self.rendererCount = rendererCount
        self.tabCount = tabCount
    }

    public var count: Int {
        tabCount ?? rendererCount
    }

    public var label: String {
        tabCount == nil ? "renderers" : "tabs"
    }
}
