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

/// The key loop in xhisper.sh is `python3 -` (system python's real binary is
/// named Python). Anything else holding a recycled pid is not listening.
func isListener(_ argv: [String]) -> Bool {
    guard let first = argv.first else { return false }
    return (first as NSString).lastPathComponent.lowercased().hasPrefix("python")
}
