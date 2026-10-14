import AppKit

// Port of xhisper-notify: the animated "wave pill" at the bottom centre, as a
// non-activating panel that never takes focus. Geometry, colours, timings and
// the one-overlay-at-a-time rules match the GTK version.

private let numBars = 17
private let barWidth: CGFloat = 5
private let barGap: CGFloat = 4
private let barRadius: CGFloat = 2.5
private let baseHeights: [CGFloat] = [0.30, 0.85, 0.30, 0.90, 0.55, 0.80, 0.95, 0.35,
                                      0.60, 0.95, 0.80, 0.25, 0.85, 0.90, 0.55, 0.30, 0.50]
private let barColor = (r: 0.93, g: 0.91, b: 0.85)
private let errorBarColor = (r: 0.91, g: 0.45, b: 0.40)
private let textColor = (r: 0.80, g: 0.78, b: 0.73, a: 0.9)
private let chipColor: CGFloat = 0.10
private let chipHoverColor: CGFloat = 0.22
private let launchSeconds = 0.28  // pill-to-window transition
// The geometry below is the Linux pill's, in its pixels. On a Mac those
// become points and the pill read too big, so the whole drawing is scaled.
private let pillScale: CGFloat = 0.8
private let stateLabels = ["recording": "Recording", "transcribing": "Transcribing", "editing": "Editing",
                           "done": "Done", "silent": "No sound", "error": "Failed",
                           "cancelled": "Cancelled", "learned": "Learned"]
private let historyStates: Set<String> = ["recording", "silent"]
/// States that update the pill already on screen instead of replacing it: one pill
/// per dictation, no new slide-in for every stage (user, 2026-10-14: "too many
/// pop-ups"). transcribing/editing both become the quiet "working" look; done just
/// lets the pill go — no Done pill, no checkmark.
let inPlaceStates: Set<String> = ["transcribing", "editing", "done"]
private let env = ProcessInfo.processInfo.environment

private func hasHistory() -> Bool {
    ((try? FileManager.default.attributesOfItem(atPath: HistoryStore.defaultPath())[.size] as? Int) ?? 0) > 0
}

private func learnCommand() -> String {
    env["XHISPER_LEARN"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/bin/xhisper-learn"
}

/// Open the history window. Through LaunchServices when we run from the
/// bundle: a window spawned directly by a background process cannot take
/// focus on macOS 14+, and the window needs keys (Enter copies, Escape closes).
func launchHistory() {
    let bundle = Bundle.main.bundlePath
    if bundle.hasSuffix(".app") {
        var argv = ["/usr/bin/open", "-n", "-a", bundle]
        for key in ["XHISPER_HISTORY_FILE", "XHISPER_LEARN", "XHISPER_RUNTIME_DIR"] {
            if let v = env[key], !v.isEmpty { argv += ["--env", "\(key)=\(v)"] }
        }
        spawnDetached(argv + ["--args", "history"])
    } else {
        spawnDetached([CommandLine.arguments[0], "history"])
    }
}

private func easeOutCubic(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PillView: NSView {
    unowned let pill: Pill
    init(pill: Pill, frame: NSRect) { self.pill = pill; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }  // same top-left coordinates as cairo
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.clear(bounds)
        cg.scaleBy(x: pillScale, y: pillScale)
        pill.draw(cg)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { pill.pointerInside = true }
    override func mouseExited(with event: NSEvent) { pill.pointerInside = false; pill.setChipHover(false) }
    override func mouseMoved(with event: NSEvent) { pill.setChipHover(pill.inChip(designPoint(event))) }
    override func mouseDown(with event: NSEvent) { pill.click(at: designPoint(event)) }
    /// The event position in the pill's unscaled geometry.
    private func designPoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x / pillScale, y: p.y / pillScale)
    }
}

final class Pill {
    var state: String
    var label: String
    let unlearn: [String]
    var showChip: Bool
    let chipLabel: String
    let showWaves: Bool
    let pillHeight: CGFloat, fontSize: CGFloat, chipFontSize: CGFloat, maxBarHeight: CGFloat
    let big: Bool
    let waveX: CGFloat = 20
    var textX: CGFloat = 0, pillWidth: CGFloat = 0
    var chipX: CGFloat = 0, chipY: CGFloat = 0, chipW: CGFloat = 0, chipH: CGFloat = 0
    var fadeAlpha: CGFloat = 0, slideProgress: CGFloat = 0
    var closing = false, chipHover = false, pointerInside = false
    var launchStart: Date?
    var live = false  // true once the recording yields audio
    var meter = LevelMeter(bars: numBars)
    var lastPush = Date.distantPast
    let wavPath: String
    let startTime = Date()
    var panel: PillPanel!
    var view: PillView!
    var target = NSPoint.zero
    let slideDistance: CGFloat = 60

    init(state: String, timeoutMs: Int, label: String?, unlearn: [String]) {
        self.state = state
        self.label = label ?? stateLabels[state] ?? state
        self.unlearn = unlearn
        // "History" on recording/silent pills, "Unlearn" on a learned pill.
        if state == "learned" && !unlearn.isEmpty {
            showChip = true; chipLabel = "Unlearn"
        } else {
            showChip = historyStates.contains(state) && hasHistory(); chipLabel = "History"
        }
        showWaves = state != "learned"
        wavPath = env["XHISPER_RECORDING"] ?? Runtime.path("xhisper.wav")
        // The learned pill is read, not glanced at: bigger text and button.
        big = state == "learned"
        pillHeight = big ? 60 : 48
        fontSize = big ? 17 : 13
        chipFontSize = big ? 14 : 12
        maxBarHeight = pillHeight - 14
        measure()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame  // above the Dock
        target = NSPoint(x: (visible.midX - pillWidth * pillScale / 2).rounded(), y: visible.minY + 55)
        let size = NSSize(width: (pillWidth + 2) * pillScale, height: (pillHeight + 4) * pillScale)
        panel = PillPanel(contentRect: NSRect(origin: NSPoint(x: target.x, y: target.y - slideDistance), size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = !showChip
        view = PillView(pill: self, frame: NSRect(origin: .zero, size: size))
        panel.contentView = view
        panel.orderFrontRegardless()

        let interval = (showChip || state == "recording") ? 0.016 : 0.033
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [unowned self] _ in self.tick() }
        if timeoutMs > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(max(timeoutMs - 500, 100)) / 1000) { self.startClose() }
        }
        // Last line of defence: no pill may outlive the pipeline that spawned it.
        let maxLife = Int(env["XHISPER_OVERLAY_MAX_SECONDS"] ?? "900") ?? 900
        if maxLife > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(maxLife)) { Overlay.quit() } }
    }

    /// Width of the pill for the current label and chip.
    func measure() {
        let waveW = CGFloat(numBars) * barWidth + CGFloat(numBars - 1) * barGap
        let textW: CGFloat = big
            ? (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width + 24
            : CGFloat((label.count + 3) * 8 + 8)
        if showWaves {
            textX = waveX + CGFloat(numBars) * (barWidth + barGap) + 8
            pillWidth = 24 + waveW + 16 + textW + 20
        } else {
            textX = big ? 26 : 24
            pillWidth = textX + textW + 12
        }
        if showChip {
            (chipW, chipH) = big ? (92, 36) : (72, 28)
            chipX = pillWidth - 8
            chipY = (pillHeight - chipH) / 2
            pillWidth += chipW + 2
        }
    }

    /// A later stage of the same dictation, applied to this pill where it stands:
    /// no new window, no slide-in. See `inPlaceStates`.
    func update(to next: String) {
        if launchStart != nil || closing { return }
        if next == "done" { startClose(); return }
        guard state != "working" else { return }
        state = "working"
        label = ""
        showChip = false
        setChipHover(false)
        pointerInside = false
        panel.ignoresMouseEvents = true
        // Narrower now (no "Recording", no History chip): shrink around the same centre.
        let oldWidth = pillWidth
        measure()
        target.x = (target.x + (oldWidth - pillWidth) * pillScale / 2).rounded()
        let size = NSSize(width: (pillWidth + 2) * pillScale, height: (pillHeight + 4) * pillScale)
        panel.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
    }

    func startClose() {
        if launchStart != nil { return }
        // Never slide away from under the pointer: the user may be reaching for the chip.
        if pointerInside {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.startClose() }
            return
        }
        closing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Overlay.quit() }
    }

    func inChip(_ p: NSPoint) -> Bool {
        showChip && p.x >= chipX && p.x <= chipX + chipW && p.y >= chipY && p.y <= chipY + chipH
    }

    func setChipHover(_ hover: Bool) {
        guard hover != chipHover else { return }
        chipHover = hover
        if hover { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }

    func click(at p: NSPoint) {
        guard inChip(p), launchStart == nil else { return }
        if state == "learned" { unlearnWords(); return }
        if state == "recording", let flag = env["XHISPER_HISTORYFLAG"], !flag.isEmpty {
            // Stop listening: xhisper.sh drops the recording, plays the cancel
            // sound and leaves this pill to finish its exit.
            FileManager.default.createFile(atPath: flag, contents: nil)
        }
        launchHistory()
        launchStart = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + launchSeconds + 0.04) { Overlay.quit() }
    }

    func unlearnWords() {
        var ok = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: learnCommand())
        p.arguments = ["remove"] + unlearn
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            ok = !p.isRunning
        }
        label = ok ? "Unlearned: " + unlearn.joined(separator: ", ") : "Could not unlearn"
        showChip = false
        setChipHover(false)
        pointerInside = false  // let it close even under the pointer
        panel.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.startClose() }
    }

    func sampleLevel() {
        let now = Date()
        guard now.timeIntervalSince(lastPush) >= levelPushSeconds else { return }
        lastPush = now
        guard let db = readTailDB(path: wavPath) else { return }
        live = true
        meter.push(db: db)
    }

    func tick() {
        if state == "recording" && launchStart == nil { sampleLevel() }
        if let started = launchStart {
            // Into the history window: lift toward where it opens and fade
            // while the window fades in.
            let p = min(1, CGFloat(Date().timeIntervalSince(started) / launchSeconds))
            fadeAlpha = 1 - p
            panel.setFrameOrigin(NSPoint(x: target.x, y: target.y + 40 * easeOutCubic(p)))
            view.needsDisplay = true
            return
        }
        if !closing {
            fadeAlpha = min(1, fadeAlpha + 0.12)
            slideProgress = min(1, slideProgress + 0.08)
        } else {
            fadeAlpha = max(0, fadeAlpha - 0.05)
            slideProgress = max(0, slideProgress - 0.06)
        }
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - slideDistance * (1 - easeOutCubic(slideProgress))))
        view.needsDisplay = true
    }

    func barHeight(_ i: Int, _ t: CGFloat) -> CGFloat {
        if state == "recording" && live {
            // Newest level enters on the right; the centre is a little taller.
            let weight = 0.75 + 0.25 * sin(.pi * (CGFloat(i) + 0.5) / CGFloat(numBars))
            return max(CGFloat(meter.levels[i]) * weight * maxBarHeight, barWidth)
        }
        let base = baseHeights[i] * maxBarHeight
        let f: CGFloat
        switch state {
        case "recording": f = 0.7 + 0.3 * sin(t * 5 + CGFloat(i) * 0.45)
        case "transcribing", "editing", "working": f = 0.75 + 0.15 * sin(t * 2.5 + CGFloat(i) * 0.35)
        case "done", "learned": f = max(0.15, 1.0 - t * 1.5)
        case "silent", "error", "cancelled": f = 0.2 + 0.05 * sin(t * 1.5 + CGFloat(i) * 0.3)
        default: f = 0.5
        }
        return max(base * f, barWidth)
    }

    private func roundedRect(_ cg: CGContext, _ rect: CGRect, _ radius: CGFloat) {
        let r = min(radius, rect.width / 2, rect.height / 2)
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    }

    private func text(_ s: String, x: CGFloat, centreY: CGFloat, size: CGFloat, alpha: CGFloat,
                      color: (r: Double, g: Double, b: Double)) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: alpha)]
        let h = (s as NSString).size(withAttributes: attrs).height
        (s as NSString).draw(at: NSPoint(x: x, y: centreY - h / 2), withAttributes: attrs)
    }

    func draw(_ cg: CGContext) {
        let t = CGFloat(Date().timeIntervalSince(startTime))
        let a = fadeAlpha, h = pillHeight, w = pillWidth, cy = h / 2
        cg.clear(view.bounds)
        roundedRect(cg, CGRect(x: 2, y: 3, width: w, height: h), h / 2)
        cg.setFillColor(CGColor(gray: 0, alpha: 0.3 * a))
        cg.fillPath()
        roundedRect(cg, CGRect(x: 0, y: 0, width: w, height: h), h / 2)
        cg.setFillColor(CGColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 0.93 * a))
        cg.fillPath()

        let bars = state == "error" ? errorBarColor : barColor
        if showWaves {
            cg.setFillColor(CGColor(srgbRed: bars.r, green: bars.g, blue: bars.b, alpha: a))
            for i in 0..<numBars {
                let bh = barHeight(i, t)
                roundedRect(cg, CGRect(x: waveX + CGFloat(i) * (barWidth + barGap), y: cy - bh / 2, width: barWidth, height: bh), barRadius)
                cg.fillPath()
            }
        }

        let dots = ["recording", "transcribing", "editing", "working"].contains(state) ? String(repeating: ".", count: Int(t * 2) % 4) : ""
        text(label + dots, x: textX, centreY: cy, size: fontSize, alpha: textColor.a * a,
             color: (textColor.r, textColor.g, textColor.b))

        if showChip {
            let shade = (chipHover || launchStart != nil) ? chipHoverColor : chipColor
            roundedRect(cg, CGRect(x: chipX, y: chipY, width: chipW, height: chipH), chipH / 2)
            cg.setFillColor(CGColor(gray: 1, alpha: shade * a))
            cg.fillPath()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: chipFontSize)]
            let width = (chipLabel as NSString).size(withAttributes: attrs).width
            text(chipLabel, x: chipX + (chipW - width) / 2, centreY: cy, size: chipFontSize, alpha: a, color: barColor)
        }
    }
}

enum Overlay {
    static let pidFile = Runtime.path("xhisper-notify.pid")
    static var pill: Pill?
    static var termSource: DispatchSourceSignal?
    static var nextSource: DispatchSourceSignal?
    static var pendingState: String?
    static let nextStateFile = Runtime.path("xhisper-notify.next")

    static func main(_ args: [String]) -> Int32 {
        guard let state = args.first else {
            FileHandle.standardError.write(Data("usage: Xhisper notify <state> [--timeout MS] [--label TEXT] [--unlearn WORD,...]\nstates: recording, transcribing, editing, done, silent, error, cancelled, learned, hide\n".utf8))
            return 1
        }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let timeout = value("--timeout").flatMap { Int($0) } ?? 0
        let unlearn = (value("--unlearn") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }

        // A later stage of a dictation goes to the pill already on screen (see
        // `inPlaceStates`). It is handed over in a file, then SIGUSR1; the pill
        // installs its handler before it registers its pid, so any pid found here
        // is one that will not die of the signal.
        if inPlaceStates.contains(state) {
            if let pid = readPid(pidFile), pid != getpid(), isAlive(pid), isOverlay(processArgs(pid)) {
                try? state.write(toFile: nextStateFile, atomically: true, encoding: .utf8)
                kill(pid, SIGUSR1)
                return 0
            }
            // Nothing on screen to update: a lone "done" shows nothing (no checkmark).
            if state == "done" { killExisting(); return 0 }
        }

        killExisting()
        if state == "hide" { return 0 }

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { quit() }
        source.resume()
        termSource = source

        signal(SIGUSR1, SIG_IGN)
        let next = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        next.setEventHandler {
            guard let s = try? String(contentsOfFile: nextStateFile, encoding: .utf8) else { return }
            if let pill = pill { pill.update(to: s) } else { pendingState = s }
        }
        next.resume()
        nextSource = next

        // Register before building the window, so the next overlay can find us.
        writePid(pidFile)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        pill = Pill(state: state, timeoutMs: timeout, label: value("--label"), unlearn: unlearn)
        if let s = pendingState { pill?.update(to: s); pendingState = nil }
        app.run()
        return 0
    }

    /// Drop our registration only if it is still ours: an unconditional unlink
    /// let a slow-exiting overlay delete its successor's registration.
    static func quit() {
        if readPid(pidFile) == getpid() { unlink(pidFile) }
        exit(0)
    }

    /// argv of this program running as an overlay, not something naming it.
    static func isOverlay(_ argv: [String]) -> Bool {
        argv.count > 1 && (argv[0] as NSString).lastPathComponent == "Xhisper" && argv[1] == "notify"
    }

    /// Overlays only ever supersede their predecessors: killing a newer one
    /// would take down the pill meant to replace ours.
    static func isOlder(_ pid: pid_t, _ myStart: Double?, _ me: pid_t) -> Bool {
        guard let other = startTime(pid), let mine = myStart else { return pid < me }
        return other != mine ? other < mine : pid < me
    }

    static func killExisting() {
        let me = getpid()
        let myStart = startTime(me)
        var targets = Set(userProcessIDs().filter { $0 != me && isOverlay(processArgs($0)) && isOlder($0, myStart, me) })
        if let recorded = readPid(pidFile), recorded != me, isOverlay(processArgs(recorded)), isOlder(recorded, myStart, me) {
            targets.insert(recorded)
        }
        targets.forEach { kill($0, SIGTERM) }
        let deadline = Date().addingTimeInterval(0.5)
        while !targets.isEmpty && Date() < deadline {
            targets = targets.filter { isAlive($0) && isOverlay(processArgs($0)) }
            if !targets.isEmpty { usleep(20_000) }
        }
        targets.forEach { kill($0, SIGKILL) }
        if let recorded = readPid(pidFile), !isAlive(recorded) { unlink(pidFile) }
    }
}
