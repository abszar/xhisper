import AppKit
import ApplicationServices

// Option then Control toggles dictation: each press runs `xhisper --toggle`
// once (port of xhisper-hotkey). Started at login by the LaunchAgent
// io.github.abszar.xhisper.hotkey; one instance per user (flock).
// While a recording listens it also swallows Escape and drops the cancel flag
// instead, so cancelling does not reach the focused app (X11 grabs it).
enum Hotkey {
    static var detector = ComboDetector()
    static var hold = HoldTracker()
    static var doubleTap = DoubleTap()
    static var tap: CFMachPort?
    static var command = "/usr/local/bin/xhisper"
    static var waitingLogged = false
    static var swallowingEscape = false
    static let escapeKey: Int64 = 53

    static func log(_ message: String) { appendLine(Runtime.path("xhisper-hotkey.log"), message) }

    static func main(_ args: [String]) -> Int32 {
        // O_CLOEXEC: dictations we launch must not inherit (and so outlive) the lock.
        let lock = open(Runtime.path("xhisper-hotkey.lock"), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lock < 0 {
            log("cannot open the lock file (errno \(errno))")
            return 1
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            log("already running")
            return 0
        }
        signal(SIGCHLD, SIG_IGN)  // launched dictations are fire-and-forget
        if let cmd = ProcessInfo.processInfo.environment["XHISPER_CMD"], !cmd.isEmpty { command = cmd }
        log("starting (command: \(command))")
        // Ask once; macOS lists Xhisper under Accessibility and Input Monitoring.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        installTap()
        CFRunLoopRun()
        return 0
    }

    static func installTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: { _, type, event, _ in Hotkey.handle(type, event) },
                                        userInfo: nil) else {
            if !waitingLogged {
                log("no permission yet: enable Xhisper in System Settings > Privacy & Security > Accessibility and > Input Monitoring")
                waitingLogged = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { installTap() }
            return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        log("listening: press Option, then Control")
    }

    static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            swallowingEscape = false  // a key-up may have been missed meanwhile
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        case .flagsChanged:
            let f = event.flags
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let now = Double(event.timestamp) / 1e9
            if detector.flagsChanged(keycode: code, option: f.contains(.maskAlternate), control: f.contains(.maskControl),
                                     command: f.contains(.maskCommand), shift: f.contains(.maskShift)) {
                let live = dictationListening()
                // Uptime, not the event's timestamp: on Apple silicon that is in
                // mach ticks, not nanoseconds. The tap callback runs at once.
                if doubleTap.comboFired(at: ProcessInfo.processInfo.systemUptime, recordingLive: live) {
                    hold.comboFired(at: now, recordingLive: true)  // never a hold
                    openHistory()
                } else {
                    hold.comboFired(at: now, recordingLive: live)
                    log("Option+Control: \(command) --toggle")
                    spawnDetached([command, "--toggle"])
                }
            } else if hold.controlChanged(down: f.contains(.maskControl), at: now) {
                // Held, not tapped: letting go ends the recording (push-to-talk).
                log("Control released after a hold: stop")
                FileManager.default.createFile(atPath: Runtime.path("xhisper.stop"), contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == escapeKey else { break }
            let isDown = type == .keyDown
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Only look for a live key loop on a fresh press.
            let listening = isDown && !repeating && dictationListening()
            let action = escapeAction(keyDown: isDown, autorepeat: repeating, swallowing: swallowingEscape, listening: listening)
            swallowingEscape = action.swallowingAfter
            if action.writeCancel {
                FileManager.default.createFile(atPath: Runtime.path("xhisper.cancel"), contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            if action.swallow { return nil }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Double tap: drop the History flag, as the pill's History chip does.
    /// The recording the first tap started cancels on it, and its pill rises
    /// into the History window (the pill watches the flag). The run may still
    /// be starting and clear stale flags, so the flag is written again while it
    /// lives; and if no window shows up (no pill), we open it ourselves.
    static func openHistory() {
        log("Option+Control twice: History")
        let flag = Runtime.path("xhisper.history")
        func drop() { FileManager.default.createFile(atPath: flag, contents: nil, attributes: [.posixPermissions: 0o600]) }
        drop()
        for delay in [0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if pipelineLive() && !FileManager.default.fileExists(atPath: flag) { drop() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if let pid = readPid(Runtime.path("xhisper-history.pid")), isAlive(pid) { return }
            log("no History window from the pill: opening it")
            launchHistory()
        }
    }

    static func pipelineLive() -> Bool {
        guard let pid = readPid(Runtime.path("xhisper.pid")) else { return false }
        return isAlive(pid)
    }

    static func dictationListening() -> Bool {
        guard let pid = readPid(Runtime.path("xhisper.listening")), isAlive(pid) else { return false }
        return isListener(processArgs(pid))
    }
}
