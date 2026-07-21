import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var updateTimer: Timer?
    private var lastMemoryWarningTime: Date?
    private let viewModel = RAMBarViewModel()
    private let orphanScanQueue = DispatchQueue(label: "com.maxghenis.RAMBar.orphan-watchdog", qos: .utility)
    private var orphanScanInFlight = false
    private var statusUpdateCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize notification authorization and workspace observers on the main actor.
        _ = CrashDetector.shared

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Show "Loading..." initially until memory data is available
            button.title = "Loading..."
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ContentView(viewModel: viewModel))

        // Start update timer — 5s is responsive enough for a menu bar icon
        updateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleStatusTimer()
            }
        }
        RunLoop.main.add(updateTimer!, forMode: .common)
        scanForOrphanedClaudeHelpers()

        // Delay first update so user sees "Loading..." briefly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateStatusButton()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            viewModel.setPopoverVisible(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Ensure popover window is key
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        viewModel.setPopoverVisible(false)
    }

    private func handleStatusTimer() {
        updateStatusButton()
        checkMemoryPressure()
        statusUpdateCount += 1
        if statusUpdateCount.isMultiple(of: 2) {
            scanForOrphanedClaudeHelpers()
        }
    }

    /// Keep process-tree safeguards active even when the popover is closed.
    /// The scan reads only PID, PPID, TTY, and command metadata. It collects
    /// physical memory only if a helper survives the grace observation.
    private func scanForOrphanedClaudeHelpers() {
        guard !orphanScanInFlight else { return }
        orphanScanInFlight = true

        orphanScanQueue.async {
            let processes = ProcessMonitor.shared.getProcessTopology()
            guard !processes.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    self?.orphanScanInFlight = false
                }
                return
            }

            let summary = ProcessMonitor.shared.scanClaudeOrphans(from: processes)
            let memory = summary.newProcessCount > 0
                ? ProcessMonitor.shared.physicalMemoryUsage(for: summary.processIDs)
                : 0

            DispatchQueue.main.async { [weak self] in
                self?.orphanScanInFlight = false
                guard summary.newProcessCount > 0 else { return }
                CrashDetector.shared.sendOrphanedClaudeWarning(
                    processCount: summary.processCount,
                    memory: memory
                )
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }

        let memory = MemoryMonitor.shared.getSystemMemory()
        let percent = Int(memory.usagePercent)

        // Create attributed string with icon and percentage
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attachment = NSTextAttachment()
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        let symbolName: String
        let color: NSColor

        switch memory.status {
        case .nominal:
            symbolName = "memorychip"
            color = NSColor.systemGreen
        case .warning:
            symbolName = "memorychip.fill"
            color = NSColor.systemOrange
        case .critical:
            symbolName = "memorychip.fill"
            color = NSColor.systemRed
        }

        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let tintedSymbol = symbol.tinted(with: color)
            attachment.image = tintedSymbol
            attachment.bounds = NSRect(
                x: 0,
                y: (font.capHeight - tintedSymbol.size.height) / 2,
                width: tintedSymbol.size.width,
                height: tintedSymbol.size.height
            )
        }

        let attachmentString = NSAttributedString(attachment: attachment)
        let percentString = NSAttributedString(
            string: " \(percent)%",
            attributes: [
                .font: font,
                .foregroundColor: color
            ]
        )

        let combined = NSMutableAttributedString()
        combined.append(attachmentString)
        combined.append(percentString)

        button.attributedTitle = combined
    }

    private func checkMemoryPressure() {
        let memory = MemoryMonitor.shared.getSystemMemory()

        // Send warning if above 85% and not warned in last 5 minutes
        if memory.usagePercent >= 85 {
            let now = Date()
            if lastMemoryWarningTime == nil || now.timeIntervalSince(lastMemoryWarningTime!) > 300 {
                CrashDetector.shared.sendMemoryWarning(usagePercent: memory.usagePercent)
                lastMemoryWarningTime = now
            }
        }
    }
}

// Helper to tint NSImage
extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
