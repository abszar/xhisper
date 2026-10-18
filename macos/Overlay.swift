import AppKit

// Port of xhisper-notify: the "wave pill" at the bottom centre, as a
// non-activating panel that never takes focus. Look and motion follow design
// B1 / B2 (geometry, timings and the bar maths in PillLayout.swift, in
// points); the one-overlay-at-a-time rules match the GTK version.

private func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
private let surface = srgb(26, 26, 26, 0.93)
private let edge = NSColor(white: 1, alpha: 0.08)
private let inkPrimary = srgb(237, 232, 217)          // bars, chip label, learned word
private let inkLabel = (r: 204.0, g: 199.0, b: 186.0)  // label, at 0.9 (Cancelled 0.62)
private let coral = (r: 232.0, g: 115.0, b: 102.0)     // Failed bars
private let success = srgb(150, 200, 140)
private let chipFill = (rest: 0.12, hover: 0.22, pressed: 0.30)
private let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
private let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
private let learnedFont = NSFont.systemFont(ofSize: 13)
private let learnedWordFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

private let stateLabels = ["recording": "Recording", "transcribing": "Transcribing", "editing": "Editing",
                           "done": "Done", "silent": "No sound", "error": "Failed",
                           "cancelled": "Cancelled", "learned": "Learned"]
/// Fresh pills that carry the History chip (one updated in place keeps the
/// chip it had while recording).
private let historyStates: Set<String> = ["recording", "silent", "error", "cancelled"]
/// States that update the pill already on screen instead of replacing it: one
/// pill per dictation, no new slide-in for every stage (user, 2026-10-14: "too
/// many pop-ups"; a pill that shrank into a second look was not liked either).
/// The recording pill keeps its size, place and History chip; its text and bars
/// change. done just lets it go — no Done pill. learned still replaces it, and
/// silent/error/cancelled do when no dictation pill is there to take them.
let inPlaceStates: Set<String> = ["transcribing", "editing", "done", "silent", "error", "cancelled"]
private let env = ProcessInfo.processInfo.environment

private func hasHistory() -> Bool {
    ((try? FileManager.default.attributesOfItem(atPath: HistoryStore.defaultPath())[.size] as? Int) ?? 0) > 0
}

private func learnCommand() -> String {
    env["XHISPER_LEARN"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/bin/xhisper-learn"
}

private func now() -> Double { ProcessInfo.processInfo.systemUptime }

/// Open the history window. Through LaunchServices when we run from the
/// bundle: a window spawned directly by a background process cannot take
/// focus on macOS 14+, and the window needs keys (Enter copies, Escape closes).
/// `-g` keeps LaunchServices from activating Xhisper: the window is a
/// non-activating panel that takes the keys itself, so the user's app stays
/// frontmost and Paste lands there without switching apps.
func launchHistory() {
    // The app the user was typing in (this pill never takes focus): the
    // window offers Paste into it.
    if let front = NSWorkspace.shared.frontmostApplication {
        setenv("XHISPER_PASTE_PID", String(front.processIdentifier), 1)
    }
    let env = ProcessInfo.processInfo.environment
    let bundle = Bundle.main.bundlePath
    if bundle.hasSuffix(".app") {
        var argv = ["/usr/bin/open", "-g", "-n", "-a", bundle]
        for key in ["XHISPER_HISTORY_FILE", "XHISPER_LEARN", "XHISPER_RUNTIME_DIR", "XHISPER_PASTE_PID"] {
            if let v = env[key], !v.isEmpty { argv += ["--env", "\(key)=\(v)"] }
        }
        spawnDetached(argv + ["--args", "history"])
    } else {
        spawnDetached([CommandLine.arguments[0], "history"])
    }
}

final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PillView: NSView {
    unowned let pill: Pill
    init(pill: Pill, frame: NSRect) { self.pill = pill; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }  // same top-left coordinates as cairo and the CSS
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.clear(bounds)
        // The pill sits inside the shadow margin.
        cg.translateBy(x: PillLayout.shadowMargin, y: PillLayout.shadowMargin)
        pill.draw(cg)
    }
    // A backup for the event monitors: tracking areas reach a non-key window too.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { pill.pointerMoved() }
    override func mouseExited(with event: NSEvent) { pill.pointerMoved() }
    override func mouseMoved(with event: NSEvent) { pill.pointerMoved() }
    override func mouseDown(with event: NSEvent) { pill.mouseDown(at: pillPoint(event)) }
    override func mouseUp(with event: NSEvent) { pill.mouseUp() }
    private func pillPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - PillLayout.shadowMargin, y: p.y - PillLayout.shadowMargin)
    }
}

/// The label slot: a word, the three working dots or not, its opacity.
struct PillLabel: Equatable {
    var text: String
    var dots: Bool
    var alpha: CGFloat
}

final class Pill {
    private(set) var state: String
    let learned: Bool
    var notice: String  // the learned pill's text ("Learned: W", then "Unlearned: W")
    let unlearn: [String]
    var unlearned = false
    var showChip: Bool
    let chipLabel: String
    let pillWidth: CGFloat
    var chipRect = CGRect.zero, hitRect = CGRect.zero
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let wavPath: String
    let startTime = now()

    var label: PillLabel
    var oldLabel: PillLabel?
    var labelStart = -1.0

    var meter = LevelMeter(bars: PillLayout.barCount)
    var live = false  // true once the recording yields audio
    var lastPush = Date.distantPast
    var heightsFrom: [CGFloat]?  // frozen bars easing into the state's own
    var heightsStart = 0.0, heightsSeconds = 0.0
    var barAlpha: PillTween
    var coralMix: PillTween  // 0 = ink, 1 = coral

    var chip: PillTween
    var chipHover = false, chipPressed = false
    var lastFlagCheck = -Double.infinity
    var pointerInside = false

    enum Phase { case shown, closing(PillMotion.Pose), launching(PillMotion.Pose) }
    var phase = Phase.shown
    var phaseStart = 0.0
    var closeGeneration = 0

    var panel: PillPanel?
    var view: PillView!
    var origin = NSPoint.zero  // the pill's bottom-left at rest, screen coordinates
    var monitors: [Any] = []
    var timer: Timer?

    var isLeaving: Bool { if case .shown = phase { return false } else { return true } }
    /// No sound / Failed / Learned wait for the pointer to leave. A dictation
    /// pill goes at once (the user's attention is on the pasted text), and so
    /// does Cancelled: a quiet acknowledgement of Escape.
    var holdsUnderPointer: Bool { ["silent", "error", "learned"].contains(state) && !unlearned }

    init(state: String, label custom: String?, unlearn: [String]) {
        self.state = state
        self.unlearn = unlearn
        learned = state == "learned"
        notice = custom ?? stateLabels[state] ?? state
        // "History" on dictation pills, "Unlearn" on a learned pill.
        let chipText = learned ? "Unlearn" : "History"
        chipLabel = chipText
        showChip = learned ? !unlearn.isEmpty : historyStates.contains(state) && hasHistory()
        wavPath = env["XHISPER_RECORDING"] ?? Runtime.path("xhisper.wav")
        label = PillLabel(text: custom ?? stateLabels[state] ?? state,
                          dots: state == "transcribing" || state == "editing", alpha: PillLayout.labelAlpha(state))
        barAlpha = PillTween(Double(PillLayout.barAlpha(state)))
        coralMix = PillTween(state == "error" ? 1 : 0)
        chip = PillTween(chipFill.rest)

        let chipW = PillLayout.chipWidth(labelWidth: (chipText as NSString).size(withAttributes: [.font: chipFont]).width)
        if state == "learned" {
            let checkW = checkImage.map { $0.size.width } ?? 0
            pillWidth = PillLayout.learnedWidth(check: checkW, text: Pill.noticeText(notice).size().width,
                                                chipWidth: unlearn.isEmpty ? nil : chipW)
        } else {
            pillWidth = PillLayout.width
        }
        chipRect = PillLayout.chipRect(pillWidth: pillWidth, chipWidth: chipW)
        hitRect = PillLayout.hitRect(pillWidth: pillWidth, chip: chipRect)
        let m = PillLayout.shadowMargin
        view = PillView(pill: self, frame: NSRect(x: 0, y: 0, width: pillWidth + 2 * m, height: PillLayout.height + 2 * m))
    }

    /// Put the panel on screen and start the clock: bottom centre of the
    /// pointer's screen, 55 above the Dock.
    func show(timeoutMs: Int) {
        let mouse = NSEvent.mouseLocation
        // No display at all (lid closed, headless): nothing to show on.
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
                ?? NSScreen.screens.first else { Overlay.quit() }
        let visible = screen.visibleFrame
        origin = NSPoint(x: (visible.midX - pillWidth / 2).rounded(), y: visible.minY + HistoryLayout.bottomGap)
        let m = PillLayout.shadowMargin
        let p = PillPanel(contentRect: NSRect(x: origin.x - m, y: origin.y - m - PillMotion.entrySlide,
                                              width: view.frame.width, height: view.frame.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false  // drawn in the view (two shadows, the system one is one)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        // Clicks go through to the app below, except on the chip (pointerMoved).
        p.ignoresMouseEvents = true
        p.acceptsMouseMovedEvents = true
        p.alphaValue = 0
        p.contentView = view
        panel = p
        phaseStart = now()
        tick()
        p.orderFrontRegardless()

        // Global monitors see moves over other apps (no Accessibility needed for
        // mouse events); the local one sees them once the chip takes the clicks.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [unowned self] _ in
            self.pointerMoved()
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [unowned self] e in
            self.pointerMoved(); return e
        }) { monitors.append(l) }

        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [unowned self] _ in self.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if let delay = PillLayout.closeDelay(state: state, timeoutMs: timeoutMs) { scheduleClose(after: delay) }
        // Last line of defence: no pill may outlive the pipeline that spawned it.
        let maxLife = Int(env["XHISPER_OVERLAY_MAX_SECONDS"] ?? "900") ?? 900
        if maxLife > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(maxLife)) { Overlay.quit() } }
    }

    func teardown() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
    }

    // MARK: State

    /// A later stage of the same dictation, applied to this pill where it stands:
    /// no new window, no slide-in, no resize. See `inPlaceStates`. false when
    /// this pill cannot take it (another kind of pill, or one on its way out).
    func update(to next: String, timeoutMs: Int) -> Bool {
        guard !isLeaving, PillLayout.accepts(from: state, to: next) else { return false }
        if next == "done" { startClose(); return true }
        if next == state || (state == "editing" && next == "transcribing") { return true }
        let t = now()
        let wave: Set<String> = ["transcribing", "editing"]
        // Freeze the bars where they stand and ease them into the new state's
        // (wave to wave needs nothing: the wave just goes on).
        if !(wave.contains(state) && wave.contains(next)) {
            heightsFrom = (0..<PillLayout.barCount).map { barHeight($0, t) }
            heightsStart = t
        }
        let seconds = PillLayout.transitionSeconds(to: next)
        heightsSeconds = seconds.heights
        barAlpha = barAlpha.retarget(Double(PillLayout.barAlpha(next)), at: t, duration: seconds.alpha)
        coralMix = coralMix.retarget(next == "error" ? 1 : 0, at: t, duration: seconds.alpha)
        state = next
        setLabel(PillLabel(text: stateLabels[next] ?? next, dots: wave.contains(next), alpha: PillLayout.labelAlpha(next)), at: t)
        if let delay = PillLayout.closeDelay(state: next, timeoutMs: timeoutMs) { scheduleClose(after: delay) }
        view.needsDisplay = true
        return true
    }

    private func setLabel(_ next: PillLabel, at t: Double) {
        guard next != label else { return }
        oldLabel = label
        label = next
        labelStart = t
    }

    /// Only the latest schedule counts (a final state replaces any earlier one).
    func scheduleClose(after seconds: Double) {
        closeGeneration += 1
        let generation = closeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.closeGeneration == generation { self?.startClose() }
        }
    }

    func startClose() {
        if isLeaving { return }
        // Never slide away from under the pointer: the user may be reaching for the chip.
        if pointerInside && holdsUnderPointer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startClose() }
            return
        }
        let t = now()
        phase = .closing(pose(at: t))
        phaseStart = t
        panel?.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PillMotion.exitSeconds) { Overlay.quit() }
    }

    // MARK: Pointer

    /// Hover, the chip's hit area and click-through, from wherever the pointer is.
    func pointerMoved() {
        guard let panel = panel else { return }
        let mouse = NSEvent.mouseLocation
        let f = panel.frame, m = PillLayout.shadowMargin
        let p = CGPoint(x: mouse.x - f.minX - m, y: f.maxY - m - mouse.y)
        pointerInside = CGRect(x: 0, y: 0, width: pillWidth, height: PillLayout.height).contains(p)
        let inHit = showChip && !isLeaving && hitRect.contains(p)
        // While the button is held, keep the clicks: its mouseUp must come back here.
        if !chipPressed && panel.ignoresMouseEvents == inHit { panel.ignoresMouseEvents = !inHit }
        setChipHover(inHit)
    }

    func setChipHover(_ hover: Bool) {
        guard hover != chipHover else { return }
        chipHover = hover
        if !chipPressed {
            chip = chip.retarget(hover ? chipFill.hover : chipFill.rest, at: now(), duration: PillMotion.chipHoverSeconds, curve: .linear)
        }
        view.needsDisplay = true
    }

    func mouseDown(at p: CGPoint) {
        guard showChip, !isLeaving, hitRect.contains(p) else { return }
        chipPressed = true
        chip = PillTween(chipFill.pressed)  // pressed is instant
        view.needsDisplay = true
        if learned {
            // Let the pressed fill show before unlearning blocks for a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.unlearnWords() }
            return
        }
        if state == "recording", let flag = historyFlag {
            // Stop listening: xhisper.sh drops the recording, plays the cancel
            // sound and leaves this pill to finish its exit.
            FileManager.default.createFile(atPath: flag, contents: nil)
        }
        riseIntoHistory()
    }

    var historyFlag: String? { env["XHISPER_HISTORYFLAG"].flatMap { $0.isEmpty ? nil : $0 } }

    /// Open the History window and lift into it (A8), then quit.
    func riseIntoHistory() {
        launchHistory()
        let t = now()
        phase = .launching(pose(at: t))
        phaseStart = t
        DispatchQueue.main.asyncAfter(deadline: .now() + PillMotion.launchSeconds + 0.04) { Overlay.quit() }
    }

    /// The hotkey's double tap drops the History flag without a click: the
    /// recording pill answers it like a click on its chip.
    func checkHistoryFlag(at t: Double) {
        guard state == "recording", !isLeaving, t - lastFlagCheck >= 0.05, let flag = historyFlag else { return }
        lastFlagCheck = t
        if FileManager.default.fileExists(atPath: flag) { riseIntoHistory() }
    }

    func mouseUp() {
        guard chipPressed, !isLeaving else { return }
        chipPressed = false
        chip = chip.retarget(chipHover ? chipFill.hover : chipFill.rest, at: now(), duration: PillMotion.chipHoverSeconds, curve: .linear)
        pointerMoved()
        view.needsDisplay = true
    }

    func unlearnWords() {
        guard !unlearned else { return }  // a double click
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
        notice = ok ? "Unlearned: " + unlearn.joined(separator: ", ") : "Could not unlearn"
        unlearned = true  // let it close even under the pointer
        showChip = false
        chipPressed = false
        setChipHover(false)
        panel?.ignoresMouseEvents = true
        view.needsDisplay = true
        scheduleClose(after: 1.4)
    }

    // MARK: Animation

    /// Where the window is and how opaque, for the current phase.
    func pose(at t: Double) -> PillMotion.Pose {
        let elapsed = t - phaseStart
        switch phase {
        case .shown: return PillMotion.entry(elapsed, reduceMotion: reduceMotion)
        case .closing(let from): return PillMotion.exit(elapsed, from: from, reduceMotion: reduceMotion)
        case .launching(let from): return PillMotion.launch(elapsed, from: from, reduceMotion: reduceMotion)
        }
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
        guard let panel = panel else { return }
        let t = now()
        if state == "recording" && !isLeaving { sampleLevel() }
        checkHistoryFlag(at: t)
        let p = pose(at: t)
        let m = PillLayout.shadowMargin
        panel.setFrameOrigin(NSPoint(x: origin.x - m, y: origin.y - m - p.offset))
        panel.alphaValue = p.alpha
        // The pill moves under a still pointer while it slides in.
        if case .shown = phase, t - phaseStart < PillMotion.entrySeconds + 0.05 { pointerMoved() }
        view.needsDisplay = true
    }

    /// The bar height the state asks for right now.
    func targetHeight(_ i: Int, _ t: Double) -> CGFloat {
        switch state {
        case "recording":
            return live ? PillMotion.liveHeight(level: meter.levels[i], bar: i) : PillMotion.idleHeight(i, t - startTime)
        case "transcribing", "editing": return PillMotion.slowWave(i, t - startTime)
        default: return PillMotion.stillHeight(state, i) ?? PillLayout.minBar
        }
    }

    func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        let target = targetHeight(i, t)
        guard let from = heightsFrom, heightsSeconds > 0 else { return target }
        let e = CGFloat(Curve.std((t - heightsStart) / heightsSeconds))
        return from[i] + (target - from[i]) * e
    }

    // MARK: Drawing

    private func capsule(_ rect: CGRect) -> CGPath {
        let r = min(rect.height / 2, rect.width / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Fills `path` in one shadow, outside the path only (as CSS draws a
    /// box-shadow), so the pill's 7 % transparency does not show it.
    private func shadow(_ cg: CGContext, _ path: CGPath, alpha: CGFloat, blur: CGFloat, y: CGFloat) {
        cg.saveGState()
        cg.addRect(cg.boundingBoxOfClipPath)
        cg.addPath(path)
        cg.clip(using: .evenOdd)
        let s = NSShadow()
        s.shadowColor = NSColor(white: 0, alpha: alpha)
        s.shadowBlurRadius = blur
        s.shadowOffset = NSSize(width: 0, height: -y)  // shadows ignore the view's flip: negative is down
        s.set()
        cg.addPath(path)
        cg.setFillColor(.black)
        cg.fillPath()
        cg.restoreGState()
    }

    func draw(_ cg: CGContext) {
        let t = now()
        let w = pillWidth, h = PillLayout.height, cy = h / 2
        let body = capsule(CGRect(x: 0, y: 0, width: w, height: h))
        shadow(cg, body, alpha: 0.32, blur: 18, y: 6)  // ambient
        shadow(cg, body, alpha: 0.30, blur: 2, y: 1)   // contact
        cg.addPath(body)
        cg.setFillColor(surface.cgColor)
        cg.fillPath()
        // 1 pt inner edge: keeps the capsule readable over dark apps.
        cg.addPath(capsule(CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)))
        cg.setStrokeColor(edge.cgColor)
        cg.setLineWidth(1)
        cg.strokePath()

        if learned { drawNotice(cg, cy: cy) } else { drawBars(cg, t, cy: cy); drawLabels(t, cy: cy) }

        if showChip {
            cg.addPath(capsule(chipRect))
            cg.setFillColor(CGColor(gray: 1, alpha: CGFloat(chip.value(at: t))))
            cg.fillPath()
            let attrs: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: inkPrimary]
            let size = (chipLabel as NSString).size(withAttributes: attrs)
            (chipLabel as NSString).draw(at: NSPoint(x: chipRect.midX - size.width / 2, y: cy - size.height / 2), withAttributes: attrs)
        }
    }

    private func drawBars(_ cg: CGContext, _ t: Double, cy: CGFloat) {
        let mix = CGFloat(coralMix.value(at: t))
        func blend(_ a: Double, _ b: Double) -> CGFloat { (CGFloat(a) + (CGFloat(b) - CGFloat(a)) * mix) / 255 }
        cg.setFillColor(CGColor(srgbRed: blend(237, coral.r), green: blend(232, coral.g), blue: blend(217, coral.b),
                                alpha: CGFloat(barAlpha.value(at: t))))
        for i in 0..<PillLayout.barCount {
            let bh = barHeight(i, t)
            let rect = CGRect(x: PillLayout.barX(i), y: cy - bh / 2, width: PillLayout.barWidth, height: bh)
            let r = min(PillLayout.barRadius, bh / 2)
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        }
        cg.fillPath()
    }

    /// The label, crossfading with a 4 pt lift when it changes (none under
    /// Reduce Motion).
    private func drawLabels(_ t: Double, cy: CGFloat) {
        var p: CGFloat = 1
        if let old = oldLabel {
            p = CGFloat(Curve.std((t - labelStart) / PillMotion.labelSeconds))
            if p >= 1 { oldLabel = nil } else {
                drawLabel(old, t, cy: cy, dy: reduceMotion ? 0 : -PillMotion.labelLift * p, fade: 1 - p)
            }
        }
        drawLabel(label, t, cy: cy, dy: reduceMotion ? 0 : PillMotion.labelLift * (1 - p), fade: p)
    }

    private func drawLabel(_ l: PillLabel, _ t: Double, cy: CGFloat, dy: CGFloat, fade: CGFloat) {
        guard fade > 0 else { return }
        func attrs(_ a: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: labelFont, .foregroundColor: srgb(inkLabel.r, inkLabel.g, inkLabel.b, l.alpha * fade * a)]
        }
        let size = (l.text as NSString).size(withAttributes: attrs(1))
        let y = cy - size.height / 2 + dy
        (l.text as NSString).draw(at: NSPoint(x: PillLayout.labelX, y: y), withAttributes: attrs(1))
        guard l.dots else { return }
        // Three dots always laid out, pulsing in opacity: no text ever grows.
        for k in 0..<3 {
            let x = PillLayout.labelX + size.width + CGFloat(k) * PillLayout.dotWidth
            ("." as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs(PillMotion.dotAlpha(k, t - startTime)))
        }
    }

    /// "Learned" regular + the words semibold (", " between them).
    static func noticeText(_ notice: String) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: learnedFont, .foregroundColor: srgb(inkLabel.r, inkLabel.g, inkLabel.b, 0.9)]
        let bold: [NSAttributedString.Key: Any] = [.font: learnedWordFont, .foregroundColor: inkPrimary]
        let (prefix, words) = splitNotice(notice)
        let s = NSMutableAttributedString(string: words.isEmpty ? prefix : prefix + " ", attributes: plain)
        for (i, word) in words.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: ", ", attributes: plain)) }
            s.append(NSAttributedString(string: word, attributes: bold))
        }
        return s
    }

    private func drawNotice(_ cg: CGContext, cy: CGFloat) {
        var x = PillLayout.learnedPadLeft
        if !unlearned, let check = checkImage {
            let r = NSRect(x: x, y: (cy - check.size.height / 2).rounded(), width: check.size.width, height: check.size.height)
            check.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += check.size.width + PillLayout.learnedGap
        }
        let text = Pill.noticeText(notice)
        text.draw(at: NSPoint(x: x, y: cy - text.size().height / 2))
    }
}

/// The learned pill's check: SF Symbol checkmark, 12 bold, in the success green.
private let checkImage: NSImage? = {
    guard let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .bold)) else { return nil }
    return NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        success.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}()

enum Overlay {
    static let pidFile = Runtime.path("xhisper-notify.pid")
    static var pill: Pill?
    static var termSource: DispatchSourceSignal?
    static var nextSource: DispatchSourceSignal?
    static let nextStateFile = Runtime.path("xhisper-notify.next")
    static let ackFile = Runtime.path("xhisper-notify.ack")

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
        // is one that will not die of the signal. Only an older pill qualifies: a
        // slow `done` from the last dictation must not close the next one's pill.
        if inPlaceStates.contains(state) {
            let me = getpid()
            if let pid = readPid(pidFile), pid != me, isAlive(pid), isOverlay(processArgs(pid)),
               isOlder(pid, startTime(me), me) {
                let acked = PillHandoff.ackedStates.contains(state)
                if acked { unlink(ackFile) }
                try? PillHandoff.encode(state: state, timeoutMs: timeout).write(toFile: nextStateFile, atomically: true, encoding: .utf8)
                kill(pid, SIGUSR1)
                // A final state must be seen: if that pill cannot take it (a
                // Learned notice, one on its way out), show our own below.
                if !acked || waitForAck(state) { return 0 }
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
        // Runs once app.run() drains the main queue, so the pill exists by then.
        next.setEventHandler {
            // Claim the file before reading it: a read-then-unlink could delete
            // a later state (a `done`) written in between, and leave the pill up.
            let mine = nextStateFile + ".\(getpid())"
            guard rename(nextStateFile, mine) == 0 else { return }
            defer { unlink(mine) }
            guard let s = try? String(contentsOfFile: mine, encoding: .utf8),
                  let handoff = PillHandoff.decode(s) else { return }
            apply(handoff)
        }
        next.resume()
        nextSource = next

        // Register before building the window, so the next overlay can find us.
        writePid(pidFile)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let p = Pill(state: state, label: value("--label"), unlearn: unlearn)
        pill = p
        p.show(timeoutMs: timeout)
        app.run()
        return 0
    }

    static func apply(_ h: (state: String, timeoutMs: Int)) {
        let ok = pill?.update(to: h.state, timeoutMs: h.timeoutMs) ?? false
        if PillHandoff.ackedStates.contains(h.state) {
            try? PillHandoff.ack(state: h.state, accepted: ok).write(toFile: ackFile, atomically: true, encoding: .utf8)
        }
    }

    /// The pill's answer to a final state, false when it refused or is wedged.
    static func waitForAck(_ state: String) -> Bool {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if let s = try? String(contentsOfFile: ackFile, encoding: .utf8),
               let ok = PillHandoff.accepted(s, for: state) {
                unlink(ackFile)
                return ok
            }
            usleep(10_000)
        }
        return false
    }

    /// Drop our registration only if it is still ours: an unconditional unlink
    /// let a slow-exiting overlay delete its successor's registration.
    static func quit() -> Never {
        pill?.teardown()
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
