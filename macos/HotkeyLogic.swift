import Foundation

/// Option, then Control: the macOS twin of xhisper-hotkey's X11 grab on
/// Control with Mod1 already down. Fires once per Control press, only when
/// Option was held first and neither Command nor Shift is (Caps Lock is
/// ignored). Control-then-Option never matches. Re-arms only once every
/// Control key is up, so a held key can never toggle twice.
struct ComboDetector {
    static let leftControl = 59
    static let rightControl = 62
    private var controlsDown = Set<Int>()
    private var armed = true

    mutating func flagsChanged(keycode: Int, option: Bool, control: Bool, command: Bool, shift: Bool) -> Bool {
        if !control {
            // No Control held at all: resync, in case an event was missed.
            controlsDown.removeAll()
            armed = true
            return false
        }
        guard keycode == Self.leftControl || keycode == Self.rightControl else { return false }
        if controlsDown.contains(keycode) {
            controlsDown.remove(keycode)
            if controlsDown.isEmpty { armed = true }
            return false
        }
        controlsDown.insert(keycode)
        guard armed, controlsDown.count == 1, option, !command, !shift else { return false }
        armed = false
        return true
    }
}

/// Tap or hold. The combo always starts `xhisper --toggle` at once; when the
/// press that started a recording is held at least `holdSeconds`, letting go
/// of Control stops it again (push-to-talk). A quick tap leaves the recording
/// running until the next combo. Only the release decides, so auto-repeat can
/// never stop a recording.
struct HoldTracker {
    static let holdSeconds = 0.4
    private var pressedAt: Double?

    /// The combo fired. A press that stops a live recording is never a hold.
    mutating func comboFired(at time: Double, recordingLive: Bool) {
        pressedAt = recordingLive ? nil : time
    }

    /// Feed every Control change (`down`: some Control key still held).
    /// Returns true when the recording should stop now.
    mutating func controlChanged(down: Bool, at time: Double) -> Bool {
        guard !down, let start = pressedAt else { return false }
        pressedAt = nil
        return time - start >= Self.holdSeconds
    }
}

/// The key loop in xhisper.sh is `python3 -` (system python's real binary is
/// named Python). Anything else holding a recycled pid is not listening.
func isListener(_ argv: [String]) -> Bool {
    guard let first = argv.first else { return false }
    return (first as NSString).lastPathComponent.lowercased().hasPrefix("python")
}

/// What to do with an Escape event. Only a live key loop gets Escape eaten:
/// a fresh press needs `listening`; a repeat continues an eaten press only
/// while `swallowing` is set; the key-up is eaten to match its press.
func escapeAction(keyDown: Bool, autorepeat: Bool, swallowing: Bool, listening: Bool)
    -> (swallow: Bool, writeCancel: Bool, swallowingAfter: Bool) {
    if keyDown {
        if autorepeat && swallowing { return (true, false, true) }
        if listening { return (true, true, true) }
        return (false, false, false)
    }
    if swallowing { return (true, false, false) }
    return (false, false, false)
}
