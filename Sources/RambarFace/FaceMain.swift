import SwiftUI
import AppKit
import RambarKit

@main
struct RambarFaceApp: App {
    @StateObject private var model: FaceModel

    init() {
        let model = FaceModel()
        _model = StateObject(wrappedValue: model)

        // Render the panel to a PNG and exit — used for verification and
        // README screenshots without needing screen-capture permissions.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > flagIndex + 1 {
            let path = CommandLine.arguments[flagIndex + 1]
            model.refresh()
            if CommandLine.arguments.contains("--snapshot-expanded") {
                expandFirstSession(
                    model: model,
                    showPaused: CommandLine.arguments.contains("--snapshot-paused")
                )
            }
            renderSnapshot(model: model, to: path)
            exit(0)
        }

        // Host the live panel in a regular window at a fixed position —
        // for screen recordings and UI automation, where the transient
        // MenuBarExtra popover dismisses too eagerly.
        if CommandLine.arguments.contains("--demo-window") {
            model.start()
            // Matte backdrop so recordings show the panel, not the desktop.
            let backdrop = NSWindow(
                contentRect: NSRect(x: 150, y: 120, width: 444, height: 820),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            backdrop.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
            backdrop.level = .floating
            backdrop.orderFront(nil)

            let window = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 344, height: 10),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.level = .floating
            window.contentViewController = NSHostingController(
                rootView: PanelView(model: model).background(.regularMaterial)
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // Template rendering keeps menu bar icons monochrome; state is
            // encoded in the symbol itself, not a color that would be lost.
            // A paused session needs action even after pressure recovers, so
            // it takes precedence over the normal pressure-state chip.
            Label {
                Text(model.usedPercentText)
                    .monospacedDigit()
            } icon: {
                Image(nsImage: menuBarSymbol(named: model.menuBarSymbolName))
            }
            .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

private func menuBarSymbol(named name: String) -> NSImage {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        return NSImage()
    }

    // The memorychip glyph sits below the text's visible center. Move only
    // its drawing so MenuBarExtra cannot recenter away the correction.
    let image = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(
            in: rect.offsetBy(dx: 0, dy: 1.25),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        return true
    }
    image.isTemplate = true
    return image
}

@MainActor
private func expandFirstSession(model: FaceModel, showPaused: Bool) {
    guard let group = model.processGroups.first(where: { $0.family != nil }),
          let session = model.sessions(for: group).first else { return }
    model.toggleExpansion(group)
    model.toggleExpansion(session)
    if showPaused {
        model.sessionInterventionStates[session.key] = SessionTreeInterventionState(
            stoppedProcessCount: max(session.processCount, 1),
            runningProcessCount: 0
        )
    }
}

@MainActor
private func renderSnapshot(model: FaceModel, to path: String) {
    let renderer = ImageRenderer(
        content: PanelView(model: model, snapshotMode: true)
            .background(.regularMaterial)
            .environment(\.colorScheme, .dark)
    )
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("snapshot render failed\n".utf8))
        exit(1)
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("snapshot written to \(path)")
    } catch {
        FileHandle.standardError.write(Data("snapshot write failed: \(error)\n".utf8))
        exit(1)
    }
}
