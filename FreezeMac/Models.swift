import Foundation

enum LockPhase: Equatable {
    case idle
    case countdown(Int)
    case locked
    case ending

    /// Anything but idle: a lock is starting, running or tearing down.
    var isBusy: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// What the input blocker reports back from inside its event tap.
enum BlockerSignal: Sendable {
    case holdKey(pressed: Bool)
    case unlockRequested
    /// macOS turned the tap off and it could not be switched back on.
    case filterLost
}

enum LockError: LocalizedError {
    case accessibilityNotGranted
    case filterUnavailable
    case filterInactive
    case pointerFreezeFailed
    case invalidUnlockWord

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return String(localized: "Frosty needs Accessibility access before it can lock input. Turn it on in System Settings › Privacy & Security › Accessibility.")
        case .filterUnavailable:
            return String(localized: "Frosty could not set up input locking. Check Accessibility access and try again.")
        case .filterInactive:
            return String(localized: "Input locking did not switch on, so nothing was locked. Try again.")
        case .pointerFreezeFailed:
            return String(localized: "Frosty could not freeze the pointer, so it did not lock anything to stay safe.")
        case .invalidUnlockWord:
            return String(localized: "The unlock word must be 3–16 letters (A–Z) or digits. Fix it or turn the word unlock off.")
        }
    }
}

struct LockOptions: Equatable {
    let lockPointer: Bool
    let blackoutScreen: Bool
    let durationSeconds: Int
    let triggers: UnlockTriggers
    let holdSeconds: Int
    let unlockHints: [UnlockHint]
}

@MainActor
final class LockHUDViewModel: ObservableObject {
    @Published var remainingSeconds: Int

    let totalSeconds: Int
    let pointerLocked: Bool
    let blackoutEnabled: Bool
    let unlockHints: [UnlockHint]
    let onUnlock: () -> Void

    init(
        remainingSeconds: Int,
        totalSeconds: Int,
        pointerLocked: Bool,
        blackoutEnabled: Bool,
        unlockHints: [UnlockHint],
        onUnlock: @escaping () -> Void
    ) {
        self.remainingSeconds = remainingSeconds
        self.totalSeconds = max(totalSeconds, 1)
        self.pointerLocked = pointerLocked
        self.blackoutEnabled = blackoutEnabled
        self.unlockHints = unlockHints
        self.onUnlock = onUnlock
    }

    var remainingFraction: Double {
        min(max(Double(remainingSeconds) / Double(totalSeconds), 0), 1)
    }

    var formattedRemainingTime: String {
        String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }
}
