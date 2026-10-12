import CoreGraphics
import ApplicationServices
import Foundation

// Cmd+V into the focused app, like xhispertool's uinput Ctrl+V on Linux: the
// virtual key is the V position (kVK_ANSI_V), stable on QWERTY, AZERTY and
// QWERTZ, and the text itself travels through the clipboard.
enum Paste {
    static func main(_ args: [String]) -> Int32 {
        // Without Accessibility macOS drops posted events silently: say so.
        guard AXIsProcessTrusted() else { return 2 }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return 1 }
        let v: CGKeyCode = 9  // kVK_ANSI_V
        var flags: CGEventFlags = .maskCommand
        if args.contains("--shift") { flags.insert(.maskShift) }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else { return 1 }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
        usleep(10_000)
        return 0
    }
}
