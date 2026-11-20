import AppKit
import CoreGraphics

/// Shared setup for the borderless, focus-free windows Frosty floats above other apps.
enum OverlayWindow {
    /// One step above the screen saver level, so it stays over the blackout curtain.
    static let aboveBlackout = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    static func panel(
        frame: CGRect = .zero,
        level: NSWindow.Level,
        shadow: Bool = true,
        clickThrough: Bool = false
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        makeFloating(panel)
        style(panel, level: level, shadow: shadow, clickThrough: clickThrough)
        return panel
    }

    static func makeFloating(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
    }

    static func style(_ window: NSWindow, level: NSWindow.Level, shadow: Bool, clickThrough: Bool) {
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = shadow
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = clickThrough
    }

    static func dismiss(_ window: NSWindow?) {
        window?.orderOut(nil)
        window?.contentView = nil
    }
}

// MARK: - Pointer shield

/// Freezes the cursor where it is and lays an invisible sheet over every screen that
/// drops whatever reaches it, so clicks, scrolls and gestures go nowhere during a lock.
@MainActor
final class PointerShieldController {
    private var sheets: [NSPanel] = []
    private var pinTask: Task<Void, Never>?
    private var pinnedPoint: CGPoint?
    private var cursorHidden = false

    var isActive: Bool { !sheets.isEmpty }

    func show() {
        hide()

        let point = CGEvent(source: nil)?.location ?? .zero
        pinnedPoint = point
        pin(at: point)
        NSCursor.hide()
        cursorHidden = true

        // macOS can reattach the cursor when focus moves or a system alert appears,
        // so keep pinning it for as long as the shield is up.
        pinTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let point = self.pinnedPoint else { return }
                self.pin(at: point)
            }
        }

        sheets = NSScreen.screens.map(makeSheet(for:))
    }

    func hide() {
        pinTask?.cancel()
        pinTask = nil
        sheets.forEach { OverlayWindow.dismiss($0) }
        sheets.removeAll()

        if pinnedPoint != nil {
            CGAssociateMouseAndMouseCursorPosition(1)
            pinnedPoint = nil
        }
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    private func pin(at point: CGPoint) {
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(point)
    }

    private func makeSheet(for screen: NSScreen) -> NSPanel {
        let sheet = InputSinkPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        OverlayWindow.makeFloating(sheet)
        OverlayWindow.style(sheet, level: .screenSaver, shadow: false, clickThrough: false)
        sheet.collectionBehavior.insert(.ignoresCycle)
        sheet.worksWhenModal = true
        sheet.acceptsMouseMovedEvents = true

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        view.allowedTouchTypes = [.direct, .indirect]
        view.wantsRestingTouches = true
        sheet.contentView = view

        sheet.setFrame(screen.frame, display: false)
        sheet.orderFrontRegardless()
        return sheet
    }
}

/// A window that never takes focus and discards every event delivered to it.
private final class InputSinkPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {}
}
