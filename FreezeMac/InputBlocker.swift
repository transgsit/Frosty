import ApplicationServices
import CoreGraphics
import Foundation

/// Swallows keyboard input, and optionally pointer input, for the whole login session
/// through an active Quartz event tap, while watching for the configured ways out.
final class InputBlocker {
    var onSignal: ((BlockerSignal) -> Void)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var detachedCursor = false
    private var detector = UnlockDetector()

    var isBlocking: Bool {
        tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    deinit {
        stop()
    }

    func start(lockPointer: Bool, triggers: UnlockTriggers = UnlockTriggers()) throws {
        stop()
        guard AXIsProcessTrusted() else { throw LockError.accessibilityNotGranted }

        try installTap(mask: Self.watchedEvents(includePointer: lockPointer))
        detector = UnlockDetector(triggers: triggers)

        guard isBlocking else {
            stop()
            throw LockError.filterInactive
        }

        if lockPointer {
            guard CGAssociateMouseAndMouseCursorPosition(0) == .success else {
                stop()
                throw LockError.pointerFreezeFailed
            }
            detachedCursor = true
        }
    }

    /// Safe to call at any time, including when nothing is running.
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tap = nil
        tapSource = nil
        detector = UnlockDetector()

        if detachedCursor {
            CGAssociateMouseAndMouseCursorPosition(1)
            detachedCursor = false
        }
    }

    // MARK: Tap

    private func installTap(mask: CGEventMask) throws {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputBlockerTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw LockError.filterUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw LockError.filterUnavailable
        }

        // The callback runs on the main run loop, so every signal below is main-thread work.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
    }

    /// Every event that reaches here is dropped; the switch only decides what to report.
    fileprivate func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns slow or interrupted taps off. Try to take over again; if that
            // fails the keyboard is live, so the session has to end.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if !isBlocking {
                send(.filterLost)
            }

        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let pressed = type == .keyDown
            if code == detector.holdKeyCode {
                send(.holdKey(pressed: pressed))
            }
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if pressed, !repeated, detector.registerKey(code) {
                send(.unlockRequested)
            }

        case .leftMouseDown:
            if detector.registerClick() {
                send(.unlockRequested)
            }

        default:
            break
        }
        return nil
    }

    private func send(_ signal: BlockerSignal) {
        DispatchQueue.main.async { [weak self] in
            self?.onSignal?(signal)
        }
    }

    static func watchedEvents(includePointer: Bool) -> CGEventMask {
        var types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        if includePointer {
            types += [
                .mouseMoved, .scrollWheel,
                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                .tabletPointer, .tabletProximity,
            ]
        }
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // Type 14 (NX_SYSDEFINED) carries brightness, volume and media keys; CGEventType has no case for it.
        return mask | (CGEventMask(1) << 14)
    }
}

private let inputBlockerTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputBlocker>.fromOpaque(userInfo).takeUnretainedValue().process(type, event)
}

// MARK: - Unlock detection

/// Recognises the unlock word and the click streak from the raw input the tap sees.
struct UnlockDetector {
    // A word or a click streak has to arrive as one continuous attempt.
    static let wordPause: TimeInterval = 5
    static let clickPause: TimeInterval = 1

    let holdKeyCode: Int64?
    private let word: [Int64]?
    private let clicksNeeded: Int?

    private var typed: [Int64] = []
    private var lastKeyAt: TimeInterval = 0
    private var clicks = 0
    private var lastClickAt: TimeInterval = 0

    init(triggers: UnlockTriggers = UnlockTriggers()) {
        holdKeyCode = triggers.holdKeyCode
        word = triggers.wordKeyCodes
        clicksNeeded = triggers.clickCount
    }

    /// True when the latest key positions spell the unlock word.
    mutating func registerKey(_ code: Int64, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let word else { return false }
        if now - lastKeyAt > Self.wordPause {
            typed.removeAll()
        }
        lastKeyAt = now
        typed = Array((typed + [code]).suffix(word.count))
        guard typed == word else { return false }
        clearProgress()
        return true
    }

    /// True when enough clicks landed close enough together.
    mutating func registerClick(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let clicksNeeded else { return false }
        clicks = now - lastClickAt <= Self.clickPause ? clicks + 1 : 1
        lastClickAt = now
        guard clicks >= clicksNeeded else { return false }
        clearProgress()
        return true
    }

    private mutating func clearProgress() {
        typed.removeAll()
        clicks = 0
    }
}
