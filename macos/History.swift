import AppKit

// Port of xhisper-history: the last dictations, newest first, each with Copy
// and Edit, plus Paste when a text field had the focus as the window opened. Edit fixes an entry and learns the corrected words through
// `xhisper-learn diff` (JSON on stdin, never argv). One window at a time: a
// second launch raises the open one.
//
// The window is a borderless, non-activating panel (design A9): it takes the
// keys without activating Xhisper, so the app the user was typing in stays
// frontmost and Paste lands there. It closes on esc, ×, or a click elsewhere.

private let pidFile = Runtime.path("xhisper-history.pid")
private let sizeKey = "HistoryWindowSize"

/// Design tokens (A9 §2 and §3). Dark only, sRGB.
enum HistoryStyle {
    static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    static func white(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }

    static let surface = srgb(26, 26, 26, 0.90)
    static let edge = white(0.08)
    static let separator = white(0.06)
    static let inkPrimary = srgb(237, 232, 217)
    static let inkLabel = srgb(204, 199, 186, 0.90)
    static let inkSecondary = srgb(204, 199, 186, 0.62)
    static let focus = srgb(237, 232, 217, 0.60)
    static let keycap = white(0.08)
    static let closeFill: (rest: CGFloat, hover: CGFloat, pressed: CGFloat) = (0.08, 0.16, 0.24)
    static let iconFill: (rest: CGFloat, hover: CGFloat, pressed: CGFloat) = (0, 0.10, 0.18)
    static let ghostFill: (rest: CGFloat, hover: CGFloat, pressed: CGFloat) = (0.10, 0.18, 0.26)
    static let primary = srgb(237, 232, 217)
    static let primaryHover = srgb(248, 244, 233)
    static let primaryPressed = srgb(212, 207, 193)
    static let primaryInk = srgb(26, 26, 26)
    static let success = srgb(150, 200, 140)
    static let successFill = srgb(150, 200, 140, 0.14)
    static let fieldFill = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
    static let fieldBorder = srgb(237, 232, 217, 0.55)
    static let error = srgb(232, 115, 102)
    static let toastSurface = srgb(40, 40, 40, 0.98)
    static let chipSurface = srgb(48, 48, 48, 0.98)  // the "N new" chip (mockup)
    static let floatEdge = white(0.10)  // toast and floating chips
    static let chipFill: (rest: CGFloat, hover: CGFloat, pressed: CGFloat) = (0.10, 0.22, 0.30)
    static let learnedHighlight = srgb(237, 232, 217, 0.16)
    static let arrivalHighlight = srgb(237, 232, 217, 0.10)
    static let dim: CGFloat = 0.40
    static let radius: CGFloat = 19  // the pill's end radius
    static let entryLineHeight: CGFloat = 18

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func label(_ text: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        return l
    }

    static func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    /// A fixed line height. AppKit puts the extra leading above the glyphs;
    /// CSS splits it, so the glyphs are lifted (`baselineOffset`) by half of it.
    static func paragraph(lineHeight: CGFloat, alignment: NSTextAlignment = .natural,
                          direction: NSWritingDirection = .natural) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.alignment = alignment
        p.baseWritingDirection = direction
        return p
    }

    static func lift(_ font: NSFont, lineHeight: CGFloat) -> CGFloat {
        max(0, (lineHeight - (font.ascender - font.descender)) / 2)
    }

    /// Text with a fixed line height (see `paragraph`).
    static func text(_ s: String, font: NSFont, color: NSColor, lineHeight: CGFloat,
                     alignment: NSTextAlignment = .natural) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color,
                                                   .paragraphStyle: paragraph(lineHeight: lineHeight, alignment: alignment),
                                                   .baselineOffset: lift(font, lineHeight: lineHeight)])
    }

    /// An entry as the list shows it (A9 "Lists", "RTL"): 13 / 18 ink.primary,
    /// list lines with the bullet (ink.secondary) in a 16 pt hanging column,
    /// the writing direction of the whole entry from its first strong character.
    static func entry(_ text: String) -> NSAttributedString {
        let f = font(13)
        let direction: NSWritingDirection = HistoryStore.isRightToLeft(text) ? .rightToLeft : .leftToRight
        let lines = HistoryStore.displayLines(text)
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let p = paragraph(lineHeight: entryLineHeight, direction: direction)
            if line.bullet != nil {
                p.headIndent = 16
                p.tabStops = [NSTextTab(textAlignment: .natural, location: 16)]
                p.defaultTabInterval = 16
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: inkPrimary, .paragraphStyle: p,
                                                        .baselineOffset: lift(f, lineHeight: entryLineHeight)]
            if let bullet = line.bullet {
                attrs[.foregroundColor] = inkSecondary
                out.append(NSAttributedString(string: bullet + "\t", attributes: attrs))
                attrs[.foregroundColor] = inkPrimary
            }
            out.append(NSAttributedString(string: line.text + (i < lines.count - 1 ? "\n" : ""), attributes: attrs))
        }
        return out
    }

    /// Straight sRGB interpolation, for fills crossfading inside a Tween.
    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return t < 0.5 ? a : b }
        func m(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return NSColor(srgbRed: m(a.redComponent, b.redComponent), green: m(a.greenComponent, b.greenComponent),
                       blue: m(a.blueComponent, b.blueComponent), alpha: m(a.alphaComponent, b.alphaComponent))
    }

    /// Set a layer's fill, animated from what is on screen when `duration` > 0.
    static func setFill(_ layer: CALayer?, _ color: NSColor, duration: Double, curve: Curve = .linear) {
        guard let l = layer else { return }
        l.removeAnimation(forKey: "fill")
        if duration > 0 {
            let a = CABasicAnimation(keyPath: "backgroundColor")
            a.fromValue = l.presentation()?.backgroundColor ?? l.backgroundColor
            a.toValue = color.cgColor
            a.duration = duration
            a.timingFunction = curve.timing
            l.add(a, forKey: "fill")
        }
        l.backgroundColor = color.cgColor
    }

    /// A 1 pt separator line (white 0.06).
    static func line() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = separator.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    /// A stretchable rounded-rect mask for the blur view: a behind-window
    /// blur does not always honour its layer's corner radius.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// The keyboard focus ring (2 pt, ink.primary 0.6, 1 pt off the control),
    /// as a layer around `rect` of the control's own layer.
    static func focusRing(around rect: CGRect, radius: CGFloat) -> CALayer {
        let ring = CALayer()
        ring.frame = rect.insetBy(dx: -3, dy: -3)
        ring.cornerRadius = radius + 3
        ring.borderWidth = 2
        ring.borderColor = focus.cgColor
        ring.isHidden = true
        return ring
    }
}

extension Curve {
    var timing: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }
}

/// One animation driven by a timer in the common modes (so it keeps running
/// during drags and menu tracking). `step` gets the eased progress 0...1.
final class Tween {
    private var timer: Timer?

    init(duration: Double, delay: Double = 0, curve: Curve,
         step: @escaping (CGFloat) -> Void, done: (() -> Void)? = nil) {
        let start = CACurrentMediaTime() + delay
        step(0)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let p = (CACurrentMediaTime() - start) / duration
            guard p >= 0 else { return }  // still in the delay
            step(CGFloat(curve(p)))
            if p >= 1 { timer.invalidate(); done?() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
}

final class HistoryWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onClose: (() -> Void)?
    /// Sees every key press before the first responder: ↩, esc and ↑/↓ must
    /// work while an entry's selectable text holds the focus.
    var onKey: ((NSEvent) -> Bool)?

    /// Off while a dictation runs that the window must not catch (see `holdKey`).
    var keyAllowed = true

    // Borderless panels refuse key by default; this one needs the keys.
    override var canBecomeKey: Bool { keyAllowed }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    // No close button to click: Cmd+W and the menu's Close come here.
    override func performClose(_ sender: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }  // Escape (positional)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    /// Xhisper is usually not the active app (the panel never activates it), so
    /// the editing shortcuts are sent to the first responder from here rather
    /// than trusting the hidden main menu to see them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command || mods == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = mods.contains(.shift)
        let action: Selector
        switch key {
        case "w" where !shift: onClose?(); return true
        case "c" where !shift: action = #selector(NSText.copy(_:))
        case "x" where !shift: action = #selector(NSText.cut(_:))
        case "v" where !shift: action = #selector(NSText.paste(_:))
        case "a" where !shift: action = #selector(NSText.selectAll(_:))
        case "z": action = shift ? Selector(("redo:")) : Selector(("undo:"))
        default: return false
        }
        // Our own first responder first: NSApp's key window is not this one
        // while another app is active.
        if let responder = firstResponder, responder.tryToPerform(action, with: self) { return true }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// The window's content view: hands out the 6 pt edge band for resizing
/// (a borderless window gets no resize edges from AppKit), the rest to the card.
final class HistoryRootView: NSView {
    var visibleFrame: () -> NSRect = { NSScreen.main?.visibleFrame ?? .zero }
    var onResized: (() -> Void)?
    private var drag: (edges: HistoryLayout.Edges, frame: NSRect, mouse: NSPoint)?
    private var resizeCursorShown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // activeAlways: Xhisper is usually not the active app.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func edges(_ windowPoint: NSPoint) -> HistoryLayout.Edges {
        HistoryLayout.edges(at: convert(windowPoint, from: nil), in: bounds.size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        if !HistoryLayout.edges(at: local, in: bounds.size).isEmpty { return self }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    static func cursor(for e: HistoryLayout.Edges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (e.contains(.top), e.contains(.bottom), e.contains(.left), e.contains(.right)) {
            case (true, _, true, _): position = .topLeft
            case (true, _, _, true): position = .topRight
            case (_, true, true, _): position = .bottomLeft
            case (_, true, _, true): position = .bottomRight
            case (true, _, _, _): position = .top
            case (_, true, _, _): position = .bottom
            case (_, _, true, _): position = .left
            default: position = .right
            }
            return .frameResize(position: position, directions: .all)
        }
        if e == .left || e == .right { return .resizeLeftRight }
        if e == .top || e == .bottom { return .resizeUpDown }
        return .crosshair  // no public diagonal resize cursor before macOS 15
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let e = edges(event.locationInWindow)
        if !e.isEmpty {
            HistoryRootView.cursor(for: e).set()
            resizeCursorShown = true
        } else if resizeCursorShown {
            NSCursor.arrow.set()
            resizeCursorShown = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        if resizeCursorShown && drag == nil { NSCursor.arrow.set(); resizeCursorShown = false }
    }

    override func mouseDown(with event: NSEvent) {
        let e = edges(event.locationInWindow)
        guard !e.isEmpty, let window = window else { super.mouseDown(with: event); return }
        drag = (e, window.frame, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = drag, let window = window else { return }
        let m = NSEvent.mouseLocation
        let frame = HistoryLayout.resize(d.frame, edges: d.edges, dx: m.x - d.mouse.x, dy: m.y - d.mouse.y,
                                         visible: visibleFrame())
        window.setFrame(frame, display: true)
        HistoryRootView.cursor(for: d.edges).set()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        onResized?()
    }
}

/// Rounded bars drawn with Core Graphics, like the pill's: the header mark and
/// the empty state.
final class BarsView: NSView {
    let heights: [CGFloat], barWidth: CGFloat, gap: CGFloat, radius: CGFloat, color: NSColor, boxHeight: CGFloat

    init(heights: [CGFloat], barWidth: CGFloat, gap: CGFloat, radius: CGFloat, color: NSColor, boxHeight: CGFloat) {
        self.heights = heights; self.barWidth = barWidth; self.gap = gap
        self.radius = radius; self.color = color; self.boxHeight = boxHeight
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(heights.count) * barWidth + CGFloat(max(0, heights.count - 1)) * gap, height: boxHeight)
    }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.setFillColor(color.cgColor)
        for (i, h) in heights.enumerated() {
            let r = CGRect(x: CGFloat(i) * (barWidth + gap), y: (bounds.height - h) / 2, width: barWidth, height: h)
            cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        cg.fillPath()
    }
}

/// An image view that keeps its tint inside the vibrant card.
final class PlainImageView: NSImageView {
    override var allowsVibrancy: Bool { false }
}

/// A hand-drawn control (A9 §5): hover fades 80 ms linear, pressed is
/// instant, the whole frame is the hit area, the first click counts (the
/// panel's app is usually not active), and under Full Keyboard Access it
/// takes focus with the design's ring (2 pt, ink.primary 0.6, offset 1).
class PressableView: NSView {
    var action: (() -> Void)?
    private(set) var hovered = false, pressed = false
    /// Ignores clicks and hover changes (the Copied capsule).
    var inert = false
    /// Focus gained / lost: a row shows its hidden actions while one has it.
    var onFocus: ((Bool) -> Void)?
    private let ring = HistoryStyle.focusRing(around: .zero, radius: 0)

    /// Where the ring goes (it sits 1 pt outside this), in own coordinates.
    var ringRect: CGRect { bounds }
    var ringRadius: CGFloat { 14 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if #available(macOS 14.0, *) { clipsToBounds = false }  // the focus ring sits outside
        layer?.addSublayer(ring)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Redraw for the current hover / pressed state.
    func stateChanged(animated: Bool) {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = ringRect.insetBy(dx: -3, dy: -3)
        ring.cornerRadius = ringRadius + 3
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    // The whole frame is the control (subviews would take the clicks).
    override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }

    override func mouseEntered(with event: NSEvent) { hovered = true; if !inert { stateChanged(animated: true) } }
    override func mouseExited(with event: NSEvent) { hovered = false; if !inert { stateChanged(animated: true) } }

    override func mouseDown(with event: NSEvent) {
        guard !inert else { return }
        pressed = true
        stateChanged(animated: false)
    }
    override func mouseDragged(with event: NSEvent) {
        guard !inert else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed { pressed = inside; stateChanged(animated: false) }
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let was = pressed
        pressed = false
        guard !inert else { return }
        stateChanged(animated: false)
        if inside && was { action?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard !inert else { return false }
        action?()
        return true
    }

    // Keyboard focus only with Full Keyboard Access, like a native button:
    // otherwise a click would leave the ring on.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override func becomeFirstResponder() -> Bool { ring.isHidden = false; onFocus?(true); return true }
    override func resignFirstResponder() -> Bool { ring.isHidden = true; onFocus?(false); return true }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { if !inert { action?() } } else { super.keyDown(with: event) }
    }
}

/// The header's close button: a 24 pt circle in a 28 pt hit area.
final class CloseButton: PressableView {
    private let circle = NSView()
    private let glyph = PlainImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        circle.frame = NSRect(x: 2, y: 2, width: 24, height: 24)
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 12
        addSubview(circle)
        glyph.image = HistoryStyle.symbol("xmark", 10, .semibold)
        glyph.contentTintColor = HistoryStyle.inkLabel
        glyph.frame = bounds
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        toolTip = "Close (esc)"
        setAccessibilityLabel("Close")
        stateChanged(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override var ringRect: CGRect { circle.frame }
    override var ringRadius: CGFloat { 12 }

    /// Fills white 0.08 / 0.16 / 0.24.
    override func stateChanged(animated: Bool) {
        let f = HistoryStyle.closeFill
        HistoryStyle.setFill(circle.layer, HistoryStyle.white(pressed ? f.pressed : hovered ? f.hover : f.rest),
                             duration: animated ? 0.08 : 0)
    }
}

/// A row action (A9 §5, §6): the 28 pt icon button (Edit, Copy), the primary
/// capsule (Paste, or Copy without a paste target; Save) and the ghost capsule
/// (Cancel). Copy turns into the Copied capsule for a moment (`showCopied`).
final class RowButton: PressableView {
    enum Style {
        case icon(String)
        case primary(String)
        case ghost(String)
    }

    let style: Style
    private let fill = NSView()  // the circle / capsule; clips the crossfading content
    private let rest = NSStackView()
    private let copied = NSStackView()
    private var glyph: NSImageView?
    private var returnGlyph: NSImageView?
    private var width: NSLayoutConstraint!
    private var tween: Tween?
    private var saved: (tip: String?, label: String?) = (nil, nil)

    init(_ style: Style, label: String, tooltip: String?) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 14
        fill.layer?.masksToBounds = true
        addSubview(fill)
        rest.orientation = .horizontal
        rest.alignment = .centerY
        rest.spacing = 6  // the ↩ glyph sits 6 after the label
        switch style {
        case .icon(let name):
            let g = PlainImageView()
            g.image = HistoryStyle.symbol(name, 13, .medium)
            g.imageScaling = .scaleNone
            rest.addArrangedSubview(g)
            glyph = g
        case .primary(let title):
            rest.addArrangedSubview(HistoryStyle.label(title, HistoryStyle.font(12, .semibold), HistoryStyle.primaryInk))
        case .ghost(let title):
            rest.addArrangedSubview(HistoryStyle.label(title, HistoryStyle.font(12, .medium), HistoryStyle.inkPrimary))
        }
        fill.addSubview(rest)
        // Copied: green capsule for the icon button; on the primary, the label
        // becomes "✓ Copied" and the fill stays.
        let ink: NSColor
        switch style {
        case .icon: ink = HistoryStyle.success
        default: ink = HistoryStyle.primaryInk
        }
        let check = PlainImageView()
        check.image = HistoryStyle.symbol("checkmark", 11, .bold)
        check.contentTintColor = ink
        check.imageScaling = .scaleNone
        copied.addArrangedSubview(check)
        copied.addArrangedSubview(HistoryStyle.label("Copied", HistoryStyle.font(12, .semibold), ink))
        copied.orientation = .horizontal
        copied.alignment = .centerY
        copied.spacing = 5
        copied.alphaValue = 0
        fill.addSubview(copied)
        for v in rest.arrangedSubviews + copied.arrangedSubviews + [rest, copied] { v.setAccessibilityElement(false) }

        toolTip = tooltip
        setAccessibilityLabel(label)
        width = widthAnchor.constraint(equalToConstant: restWidth)
        NSLayoutConstraint.activate([width, heightAnchor.constraint(equalToConstant: 28)])
        stateChanged(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var isIcon: Bool { if case .icon = style { return true } else { return false } }

    /// 28 for the circle; padding 0 12 around the label (and ↩) for a capsule.
    private var restWidth: CGFloat { isIcon ? 28 : 24 + rest.fittingSize.width }
    /// Copied: padding L9 R11 on the green capsule; L10 R12 on the primary.
    private var copiedWidth: CGFloat { copied.fittingSize.width + (isIcon ? 20 : 22) }

    override func layout() {
        super.layout()
        fill.frame = bounds
        let r = rest.fittingSize
        rest.frame = NSRect(x: ((bounds.width - r.width) / 2).rounded(), y: ((bounds.height - r.height) / 2).rounded(),
                            width: r.width, height: r.height)
        let c = copied.fittingSize
        copied.frame = NSRect(x: isIcon ? 9 : 10, y: ((bounds.height - c.height) / 2).rounded(), width: c.width, height: c.height)
    }

    private var restFill: NSColor {
        switch style {
        case .icon:
            let f = HistoryStyle.iconFill
            return HistoryStyle.white(pressed ? f.pressed : hovered ? f.hover : f.rest)
        case .primary:
            return pressed ? HistoryStyle.primaryPressed : hovered ? HistoryStyle.primaryHover : HistoryStyle.primary
        case .ghost:
            let f = HistoryStyle.ghostFill
            return HistoryStyle.white(pressed ? f.pressed : hovered ? f.hover : f.rest)
        }
    }

    /// Icon button: fill white 0 / 0.10 / 0.18, glyph ink.label -> ink.primary.
    override func stateChanged(animated: Bool) {
        HistoryStyle.setFill(fill.layer, restFill, duration: animated ? 0.08 : 0)
        glyph?.contentTintColor = hovered || pressed ? HistoryStyle.inkPrimary : HistoryStyle.inkLabel
    }

    /// The primary capsule of the Enter-target row shows ↩ (SF return, 10
    /// semibold, primary.ink at 0.5) 6 after its label.
    func setReturnGlyph(_ on: Bool) {
        guard !isIcon, on != (returnGlyph != nil) else { return }
        if on {
            let g = PlainImageView()
            g.image = HistoryStyle.symbol("return", 10, .semibold)
            g.contentTintColor = HistoryStyle.primaryInk.withAlphaComponent(0.5)
            g.imageScaling = .scaleNone
            g.setAccessibilityElement(false)
            rest.addArrangedSubview(g)
            returnGlyph = g
        } else {
            returnGlyph?.removeFromSuperview()
            returnGlyph = nil
        }
        if !inert { width.constant = restWidth }
        needsLayout = true
    }

    /// Copied (A9 §7): 160 ms std widen + crossfade into the check and
    /// "Copied", hold 1200, 200 ms std back. Not clickable meanwhile.
    /// `shown` runs once the check is in (at once if it already is).
    func showCopied(shown: (() -> Void)? = nil) {
        if inert { shown?(); return }
        inert = true
        saved = (toolTip, accessibilityLabel())
        toolTip = nil
        setAccessibilityLabel("Copied")
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let fromFill = restFill
        let toFill = isIcon ? HistoryStyle.successFill : HistoryStyle.primary
        let w0 = width.constant, w1 = copiedWidth
        tween?.stop()
        tween = Tween(duration: 0.16, curve: .std, step: { [weak self] e in
            guard let self = self else { return }
            self.width.constant = w0 + (w1 - w0) * e
            self.rest.alphaValue = 1 - e
            self.copied.alphaValue = e
            self.fill.layer?.backgroundColor = HistoryStyle.mix(fromFill, toFill, e).cgColor
        }, done: { [weak self] in
            shown?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.hideCopied() }
        })
    }

    private func hideCopied() {
        let fromFill = isIcon ? HistoryStyle.successFill : HistoryStyle.primary
        let w0 = width.constant
        tween?.stop()
        tween = Tween(duration: 0.2, curve: .std, step: { [weak self] e in
            guard let self = self else { return }
            // Back to whatever the pointer says now (hovered or not).
            self.width.constant = w0 + (self.restWidth - w0) * e
            self.rest.alphaValue = e
            self.copied.alphaValue = 1 - e
            self.fill.layer?.backgroundColor = HistoryStyle.mix(fromFill, self.restFill, e).cgColor
        }, done: { [weak self] in
            guard let self = self else { return }
            self.inert = false
            self.toolTip = self.saved.tip
            self.setAccessibilityLabel(self.saved.label)
            self.stateChanged(animated: false)
        })
    }
}

/// "Show more" / "Show less" (A9 §5): 11 medium ink.label, chevron 8
/// semibold 3 after it; 20 tall, padding 0 2, in a 24 pt hit area.
final class MoreButton: PressableView {
    private let label = HistoryStyle.label("Show more", HistoryStyle.font(11, .medium), HistoryStyle.inkLabel)
    private let chevron = PlainImageView()

    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            label.stringValue = expanded ? "Show less" : "Show more"
            chevron.image = HistoryStyle.symbol(expanded ? "chevron.up" : "chevron.down", 8, .semibold)
            setAccessibilityLabel(label.stringValue)
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        chevron.image = HistoryStyle.symbol("chevron.down", 8, .semibold)
        chevron.imageScaling = .scaleNone
        let stack = NSStackView(views: [label, chevron])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        chevron.setAccessibilityElement(false)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("Show more")
        stateChanged(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var ringRect: CGRect { NSRect(x: 0, y: (bounds.height - 20) / 2, width: bounds.width, height: 20) }
    override var ringRadius: CGFloat { 4 }

    /// ink.label -> ink.primary on hover -> ink.primary 0.7 pressed.
    override func stateChanged(animated: Bool) {
        let c = pressed ? HistoryStyle.inkPrimary.withAlphaComponent(0.7) : hovered ? HistoryStyle.inkPrimary : HistoryStyle.inkLabel
        label.textColor = c
        chevron.contentTintColor = c
    }
}

/// An entry's text (A9 §4 Text, "Truncation"): selectable, not editable,
/// clamped to N lines with the last one truncated. TextKit 1, whose
/// container honours `maximumNumberOfLines` and truncates the last line.
/// Not a label: a selectable NSTextField swaps in a field editor on click,
/// which drops the clamp.
final class EntryTextView: NSTextView {
    static func make() -> EntryTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.lineBreakMode = .byTruncatingTail
        layout.addTextContainer(container)
        let v = EntryTextView(frame: .zero, textContainer: container)
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.allowsUndo = false
        v.usesFindBar = false
        v.focusRingType = .none
        v.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 14.0, *) { v.clipsToBounds = true }  // the height animation clips the lines
        return v
    }

    private var shown: (full: NSAttributedString, cut: Int?)?

    /// Show `full` clamped to `limit` lines (0: all). `cut` (see
    /// `HistoryLayout.paragraphCut`) shows a copy cut there and ending in "…",
    /// for a clamp that ends at a paragraph break, which the container's own
    /// truncation leaves without an ellipsis.
    func show(_ full: NSAttributedString, limit: Int, cut: Int?) {
        let cut = limit > 0 ? cut : nil
        if shown?.full !== full || shown?.cut != cut, let storage = textStorage {
            shown = (full, cut)
            if let cut = cut, cut <= full.length {
                let copy = NSMutableAttributedString(attributedString: full.attributedSubstring(from: NSRange(location: 0, length: cut)))
                let attrs = full.length > 0 ? full.attributes(at: max(0, cut - 1), effectiveRange: nil) : [:]
                copy.append(NSAttributedString(string: "\u{2026}", attributes: attrs))
                storage.setAttributedString(copy)
            } else {
                storage.setAttributedString(full)
            }
        }
        guard let container = textContainer, container.maximumNumberOfLines != limit else { return }
        container.maximumNumberOfLines = limit
        layoutManager?.textContainerChangedGeometry(container)
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // ⌘C copies plain text: as RTF it would carry the window's light ink
    // into the app it is pasted in.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    // One selection at a time across the rows.
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        return true
    }

    /// The lines `text` takes at `width` (no clamp), as the UTF-16 end of
    /// each line, from one shared TextKit 1 stack.
    static func lineEnds(_ text: NSAttributedString, width: CGFloat) -> [Int] {
        let m = measure
        m.container.size = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        m.storage.setAttributedString(text)
        m.layout.ensureLayout(for: m.container)
        var ends: [Int] = []
        m.layout.enumerateLineFragments(forGlyphRange: m.layout.glyphRange(for: m.container)) { _, _, _, glyphs, _ in
            ends.append(NSMaxRange(m.layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
        }
        if m.layout.extraLineFragmentTextContainer != nil { ends.append(text.length) }  // a trailing newline
        return ends
    }

    private static let measure: (storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer) = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer()
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        return (storage, layout, container)
    }()
}

/// The edit field (A3, A9 §4, §8): plain 13 / 18 text on black 0.28, a 1 pt
/// border (237,232,217 @0.55; error colour after a failed save), radius 8,
/// padding 7 × 9, undo on, caret ink.primary, no focus ring. It grows with its
/// text from 2 to 10 lines, then scrolls.
final class EditField: NSView {
    let textView: NSTextView
    private let scroll = NSScrollView()
    private var height: NSLayoutConstraint!
    private var width: CGFloat = 0

    var failed = false {
        didSet { layer?.borderColor = (failed ? HistoryStyle.error : HistoryStyle.fieldBorder).cgColor }
    }
    var fieldHeight: CGFloat { height.constant }

    init(text: String) {
        // TextKit 1, built explicitly: `fit` counts its line fragments.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40), textContainer: container)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1  // drawn inside the bounds
        layer?.borderColor = HistoryStyle.fieldBorder.cgColor
        layer?.backgroundColor = HistoryStyle.fieldFill.cgColor
        layer?.masksToBounds = true

        let f = HistoryStyle.font(13)
        let p = HistoryStyle.paragraph(lineHeight: HistoryStyle.entryLineHeight,
                                       direction: HistoryStore.isRightToLeft(text) ? .rightToLeft : .natural)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: HistoryStyle.inkPrimary, .paragraphStyle: p,
                                                    .baselineOffset: HistoryStyle.lift(f, lineHeight: HistoryStyle.entryLineHeight)]
        let tv = textView
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.focusRingType = .none
        tv.textContainerInset = NSSize(width: 9, height: 7)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.font = f
        tv.textColor = HistoryStyle.inkPrimary
        tv.insertionPointColor = HistoryStyle.inkPrimary
        tv.defaultParagraphStyle = p
        tv.typingAttributes = attrs
        // The dictation goes back as typed: no smart quotes, dashes or replacements.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.usesFindBar = false
        tv.setAccessibilityLabel("Edit dictation")
        storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScroller = OverlayScroller()
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = tv
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        height = heightAnchor.constraint(equalToConstant: HistoryLayout.editorHeight(lines: 2))
        NSLayoutConstraint.activate([
            height,
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            scroll.leftAnchor.constraint(equalTo: leftAnchor, constant: 1),
            scroll.rightAnchor.constraint(equalTo: rightAnchor, constant: -1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Size the field for its text at `width` (the row's text column).
    func fit(width w: CGFloat? = nil) {
        if let w = w { width = w }
        guard width > 0, let lm = textView.layoutManager, let c = textView.textContainer else { return }
        let inner = width - 2
        if abs(textView.frame.width - inner) > 0.5 { textView.setFrameSize(NSSize(width: inner, height: textView.frame.height)) }
        c.size = NSSize(width: max(1, inner - 18), height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: c)
        var lines = 0
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: c)) { _, _, _, _, _ in lines += 1 }
        if lm.extraLineFragmentTextContainer != nil { lines += 1 }  // an empty last line
        let h = HistoryLayout.editorHeight(lines: lines)
        if abs(height.constant - h) > 0.5 { height.constant = h }
        // The text view fills the field, so a click below a short text still lands in it.
        textView.minSize = NSSize(width: 0, height: h - 2)
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// The caret's line, in the field's coordinates.
    func caretRect() -> NSRect {
        guard let lm = textView.layoutManager else { return bounds }
        let length = (textView.string as NSString).length
        let loc = textView.selectedRange().location
        var line: NSRect
        if length == 0 || (loc >= length && lm.extraLineFragmentTextContainer != nil) {
            line = lm.extraLineFragmentTextContainer != nil ? lm.extraLineFragmentRect : .zero
        } else {
            let glyph = lm.glyphIndexForCharacter(at: min(loc, length - 1))
            line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let o = textView.textContainerOrigin
        line.origin.x += o.x
        line.origin.y += o.y
        return convert(line, from: textView)
    }

    /// Put the caret at the end of the text.
    func caretToEnd() {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}

/// Rounded fills drawn under an entry's text: the learned-word highlight
/// (A4). A view of its own, outside the text storage, so Copy never sees it.
final class HighlightView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func show(_ rects: [CGRect], color: NSColor, radius: CGFloat) {
        wantsLayer = true
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for r in rects {
            let l = CALayer()
            l.frame = r
            l.cornerRadius = radius
            l.backgroundColor = color.cgColor
            layer?.addSublayer(l)
        }
        CATransaction.commit()
    }
}

/// One history entry (A9 §4, A5): radius 11, padding T6 R12 B12 L12; a 28 pt
/// meta line (time left, actions right), the text 2 below, "Show more" 4
/// below the text when it is truncated.
final class HistoryRowView: NSView {
    /// Position in the list (0 = newest); shifts when new dictations land on top.
    var index: Int
    private(set) var entry: HistoryEntry
    let time = HistoryStyle.label("", .monospacedDigitSystemFont(ofSize: 11, weight: .medium), HistoryStyle.inkSecondary)
    let actions = NSStackView()
    let text = EntryTextView.make()
    let more = MoreButton()
    private let meta = NSView()
    private let highlight = HighlightView()
    /// The button Copy morphs (icon, or the primary capsule without a target).
    var copyButton: RowButton?
    /// The primary capsule, which shows ↩ on the Enter-target row.
    var primary: RowButton?
    /// False while another row is edited: no hover there.
    var interactive: () -> Bool = { true }
    private(set) var isTarget = false
    private(set) var expanded = false
    private(set) var editing = false
    /// Another row is being edited: 40 %, no hover, no clicks.
    private(set) var dimmed = false
    private var hovered = false, focusInActions = false, actionsShown = false
    private var display: NSAttributedString
    private var lineEnds: [Int] = []
    private var lines: Int { max(1, lineEnds.count) }
    private var utf16: [UInt16]
    private var textWidth: CGFloat = 0
    private var textHeight: NSLayoutConstraint!
    private var bottomToText: NSLayoutConstraint!
    private var bottomToMore: NSLayoutConstraint!
    private var heightTween: Tween?
    // Edit mode, arrival and highlights.
    private(set) var field: EditField?
    private var fieldBottom: NSLayoutConstraint?
    private var restActions: [PressableView] = []
    /// A fixed row height while a transition animates it (the bottom
    /// constraints are 999, so this wins without a conflict).
    private var pinned: NSLayoutConstraint?
    private var transition: Tween?
    private var fades: [Tween] = []
    private var pendingHighlight: [String]?

    init(entry: HistoryEntry, index: Int) {
        self.entry = entry
        self.index = index
        display = HistoryStyle.entry(entry.text)
        utf16 = Array(display.string.utf16)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous

        meta.translatesAutoresizingMaskIntoConstraints = false
        time.translatesAutoresizingMaskIntoConstraints = false
        time.lineBreakMode = .byTruncatingTail
        time.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshTime()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.alphaValue = 0
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        meta.addSubview(time)
        meta.addSubview(actions)
        text.show(display, limit: 0, cut: nil)
        more.action = { [unowned self] in self.setExpanded(!self.expanded) }
        highlight.translatesAutoresizingMaskIntoConstraints = false
        for v in [highlight, meta, text, more] as [NSView] { addSubview(v) }

        textHeight = text.heightAnchor.constraint(equalToConstant: HistoryStyle.entryLineHeight)
        bottomToText = text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        bottomToMore = more.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)  // 24 hit, 20 visual
        // Below required: a pinned height (transitions) overrides them quietly.
        bottomToText.priority = NSLayoutConstraint.Priority(999)
        bottomToMore.priority = NSLayoutConstraint.Priority(999)
        // Times and buttons stay in the UI's direction (left to right).
        NSLayoutConstraint.activate([
            meta.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            meta.leftAnchor.constraint(equalTo: leftAnchor, constant: 12),
            meta.rightAnchor.constraint(equalTo: rightAnchor, constant: -12),
            meta.heightAnchor.constraint(equalToConstant: 28),
            time.leftAnchor.constraint(equalTo: meta.leftAnchor),
            time.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            time.rightAnchor.constraint(lessThanOrEqualTo: actions.leftAnchor, constant: -4),
            actions.rightAnchor.constraint(equalTo: meta.rightAnchor),
            actions.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            text.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 2),
            text.leftAnchor.constraint(equalTo: leftAnchor, constant: 12),
            text.rightAnchor.constraint(equalTo: rightAnchor, constant: -12),
            textHeight, bottomToText,
            more.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            more.leftAnchor.constraint(equalTo: leftAnchor, constant: 12),
            highlight.topAnchor.constraint(equalTo: text.topAnchor),
            highlight.leftAnchor.constraint(equalTo: text.leftAnchor),
            highlight.rightAnchor.constraint(equalTo: text.rightAnchor),
            highlight.bottomAnchor.constraint(equalTo: text.bottomAnchor),
        ])
        more.isHidden = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setActions(_ buttons: [PressableView]) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for b in buttons {
            b.onFocus = { [weak self] on in self?.focusInActions = on; self?.refresh(animated: true) }
            actions.addArrangedSubview(b)
        }
    }

    /// "2 min ago", or "2 min ago · Editing" while the editor is open (A3).
    func refreshTime() {
        time.stringValue = HistoryStore.describe(entry.time) + (editing ? " \u{00B7} Editing" : "")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Dimmed beside an edit: not clickable (A5).
        guard !dimmed, let hit = super.hitTest(point) else { return nil }
        // Hidden actions (alpha 0) take no clicks.
        return !actionsShown && hit.isDescendant(of: actions) ? self : hit
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh(animated: true) }

    /// Fill (100 ms, out on the way in, in on the way out) and the actions
    /// (in 120 out, out 80 in): shown on hover, keyboard focus, the Enter
    /// target and the row being edited.
    func refresh(animated: Bool) {
        let hover = hovered && interactive() && !dimmed
        let fill = HistoryLayout.rowFill(target: isTarget || editing, hovered: hover && !editing)
        HistoryStyle.setFill(layer, HistoryStyle.white(fill), duration: animated ? 0.1 : 0, curve: hover ? .out : .in)
        primary?.setReturnGlyph(isTarget && !editing)
        let show = isTarget || editing || hover || focusInActions
        guard show != actionsShown else { return }
        actionsShown = show
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = show ? 0.12 : 0.08
                ctx.timingFunction = (show ? Curve.out : Curve.in).timing
                actions.animator().alphaValue = show ? 1 : 0
            }
        } else {
            actions.alphaValue = show ? 1 : 0
        }
    }

    func setTarget(_ on: Bool, animated: Bool, done: (() -> Void)? = nil) {
        isTarget = on
        refresh(animated: animated)
        applyClamp(animated: animated && !editing, done: done)
    }

    func setExpanded(_ on: Bool, animated: Bool = true) {
        expanded = on
        applyClamp(animated: animated)
    }

    /// Re-measure at `width` (the text column) and size the text to its clamp.
    func layoutText(width: CGFloat) {
        textWidth = width
        if editing { field?.fit(width: width); return }
        lineEnds = EntryTextView.lineEnds(display, width: width)
        applyClamp(animated: false)
    }

    /// The row's height at rest (no transition): padding, meta, text, Show more.
    var restingHeight: CGFloat {
        if editing, let f = field { return 6 + 28 + 2 + f.fieldHeight + 12 }
        return 6 + 28 + 2 + textHeight.constant + (more.isHidden ? 12 : 2 + 24 + 10)
    }

    /// Show more / less (200 ms std, height). Growing lifts the line limit
    /// first; shrinking sets it once the height is in, so the ellipsis lands
    /// at the end.
    private func applyClamp(animated: Bool, done: (() -> Void)? = nil) {
        guard !editing else { done?(); return }  // the editor owns the height
        let clampAt = HistoryLayout.clampLines(target: isTarget)
        let truncatable = lines > clampAt
        let limit = expanded && truncatable ? 0 : clampAt
        let target = CGFloat(HistoryLayout.shownLines(lines, clamp: limit)) * HistoryStyle.entryLineHeight
        more.expanded = expanded
        if more.isHidden == truncatable {
            more.isHidden = !truncatable
            NSLayoutConstraint.deactivate([truncatable ? bottomToText : bottomToMore])
            NSLayoutConstraint.activate([truncatable ? bottomToMore : bottomToText])
        }
        // The clamp ends at a paragraph break: show a copy cut there, with "…".
        let cut = limit > 0 && lines > limit ? HistoryLayout.paragraphCut(utf16, visibleEnd: lineEnds[limit - 1]) : nil
        heightTween?.stop()
        let from = textHeight.constant
        guard animated, abs(from - target) > 0.5 else {
            textClamp(limit, cut)
            textHeight.constant = target
            done?()
            return
        }
        if target > from { textClamp(limit, cut) }
        heightTween = Tween(duration: 0.2, curve: .std, step: { [weak self] e in
            self?.textHeight.constant = from + (target - from) * e
        }, done: { [weak self] in
            self?.textClamp(limit, cut)
            done?()
        })
    }

    private func textClamp(_ limit: Int, _ cut: Int?) { text.show(display, limit: limit, cut: cut) }

    // MARK: Transitions

    /// Rows clip their content while their height animates.
    private func setClipping(_ on: Bool) {
        if #available(macOS 14.0, *) { clipsToBounds = on }  // earlier systems always clip
    }

    /// Animate the row's height from `from` to `to` (a pinned constraint),
    /// `step` running alongside; the pin goes once it is done.
    private func animateHeight(from: CGFloat, to: CGFloat, duration: Double, curve: Curve,
                               step: @escaping (CGFloat) -> Void, done: @escaping () -> Void) {
        transition?.stop()
        if pinned == nil {
            pinned = heightAnchor.constraint(equalToConstant: from)
            pinned?.isActive = true
        }
        setClipping(true)
        transition = Tween(duration: duration, curve: curve, step: { [weak self] e in
            guard let self = self else { return }  // the row is gone: nothing to drive
            self.pinned?.constant = from + (to - from) * e
            step(e)
        }, done: { [weak self] in
            guard let self = self else { return }
            self.pinned?.isActive = false
            self.pinned = nil
            self.transition = nil
            self.setClipping(false)
            done()
        })
    }

    /// A3 enter edit (180 ms std): the row's height goes to the field's, the
    /// text crossfades into the field and the actions become Cancel / Save.
    func enterEdit(_ f: EditField, actions buttons: [PressableView], animated: Bool, done: @escaping () -> Void) {
        let from = frame.height > 0 ? frame.height : restingHeight
        heightTween?.stop()
        editing = true
        field = f
        refreshTime()
        restActions = actions.arrangedSubviews.compactMap { $0 as? PressableView }
        addSubview(f)
        let bottom = f.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        bottom.priority = NSLayoutConstraint.Priority(999)
        fieldBottom = bottom
        NSLayoutConstraint.deactivate([bottomToText, bottomToMore])
        NSLayoutConstraint.activate([
            f.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 2),
            f.leftAnchor.constraint(equalTo: leftAnchor, constant: 12),
            f.rightAnchor.constraint(equalTo: rightAnchor, constant: -12),
            bottom,
        ])
        f.fit(width: textWidth)
        setActions(buttons)
        refresh(animated: true)
        let fadeOut = [text, more, highlight] as [NSView]
        let finish = {
            fadeOut.forEach { $0.isHidden = true; $0.alphaValue = 1 }
            done()
        }
        guard animated else { f.alphaValue = 1; finish(); return }
        f.alphaValue = 0
        buttons.forEach { $0.alphaValue = 0 }
        animateHeight(from: from, to: restingHeight, duration: 0.18, curve: .std, step: { e in
            f.alphaValue = e
            buttons.forEach { $0.alphaValue = e }
            fadeOut.forEach { $0.alphaValue = 1 - e }
        }, done: finish)
    }

    /// A3 leave edit (150 ms std), the reverse. `saved` is the entry's new
    /// text after a Save; the row then shows (and measures) it.
    func leaveEdit(saved: HistoryEntry?, animated: Bool, done: @escaping () -> Void) {
        guard editing, let f = field else { done(); return }
        let from = frame.height > 0 ? frame.height : restingHeight
        if let e = saved {
            entry = e
            display = HistoryStyle.entry(e.text)
            utf16 = Array(display.string.utf16)
            text.show(display, limit: 0, cut: nil)
        }
        editing = false
        refreshTime()
        fieldBottom?.isActive = false
        fieldBottom = nil
        // Back to the resting constraints: text bottom, Show more hidden; the clamp sorts out the rest.
        more.isHidden = true
        bottomToText.isActive = true
        text.isHidden = false
        highlight.isHidden = false
        if textWidth > 0 { lineEnds = EntryTextView.lineEnds(display, width: textWidth) }
        applyClamp(animated: false)
        let buttons = restActions
        setActions(buttons)
        restActions = []
        refresh(animated: true)
        let fadeIn = ([text, highlight] + (more.isHidden ? [] : [more])) as [NSView]
        let finish = { [weak self] in
            f.removeFromSuperview()
            guard let self = self else { return }
            self.field = nil
            if let words = self.pendingHighlight { self.pendingHighlight = nil; self.highlightWords(words) }
            done()
        }
        guard animated else { finish(); return }
        fadeIn.forEach { $0.alphaValue = 0 }
        buttons.forEach { $0.alphaValue = 0 }
        animateHeight(from: from, to: restingHeight, duration: 0.15, curve: .std, step: { e in
            f.alphaValue = 1 - e
            buttons.forEach { $0.alphaValue = e }
            fadeIn.forEach { $0.alphaValue = e }
        }, done: finish)
    }

    /// Another row is edited (A5): whole row at 40 %, no hover, no clicks.
    func setDimmed(_ on: Bool, duration: Double) {
        guard on != dimmed else { return }
        dimmed = on
        text.isSelectable = !on  // no I-beam either
        if on, text.selectedRange().length > 0 { text.setSelectedRange(NSRange(location: 0, length: 0)) }
        refresh(animated: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = Curve.std.timing
            animator().alphaValue = on ? HistoryStyle.dim : 1
        }
    }

    /// A7 new entry: height 0 -> h (220 ms out), content fades in (180 ms
    /// after 60), and an ink.primary 0.10 fill fades out over 900 ms (out).
    /// `spacing` animates the stack gap after the row along with it.
    func arrive(animated: Bool, spacing: @escaping (CGFloat) -> Void) {
        let flash = HighlightView()  // takes no clicks
        flash.wantsLayer = true
        flash.layer?.backgroundColor = HistoryStyle.arrivalHighlight.cgColor
        flash.layer?.cornerRadius = 11
        flash.layer?.cornerCurve = .continuous
        flash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flash, positioned: .below, relativeTo: highlight)
        NSLayoutConstraint.activate([
            flash.topAnchor.constraint(equalTo: topAnchor), flash.bottomAnchor.constraint(equalTo: bottomAnchor),
            flash.leftAnchor.constraint(equalTo: leftAnchor), flash.rightAnchor.constraint(equalTo: rightAnchor),
        ])
        fades.append(Tween(duration: 0.9, curve: .out, step: { e in flash.alphaValue = 1 - e },
                           done: { flash.removeFromSuperview() }))
        guard animated else { spacing(1); return }
        let content = [meta, text, more] as [NSView]
        content.forEach { $0.alphaValue = 0 }
        fades.append(Tween(duration: 0.18, delay: 0.06, curve: .out, step: { e in content.forEach { $0.alphaValue = e } }))
        animateHeight(from: 0, to: restingHeight, duration: 0.22, curve: .out, step: spacing, done: {})
    }

    /// A4: the learned words get a 237,232,217 @0.16 fill (radius 3) in the
    /// shown text for 1500 ms, which then fades out over 600 ms (std).
    func highlightWords(_ words: [String]) {
        guard field == nil else { pendingHighlight = words; return }  // after the leave-edit motion
        guard let lm = text.layoutManager, let c = text.textContainer, let storage = text.textStorage else { return }
        lm.ensureLayout(for: c)
        let shown = text.bounds.height + 0.5
        let rects = HistoryLayout.wordRanges(words, in: display.string).flatMap { r -> [CGRect] in
            guard NSMaxRange(r) <= storage.length else { return [] }  // past a "…" cut
            var out: [CGRect] = []
            let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            // One rect per line the word sits on (a word can wrap only if it fills a line).
            lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: c) { rect, _ in
                // The mockup's 1 pt spread (box-shadow), inside the 18 pt line.
                let box = rect.insetBy(dx: -1, dy: 0.5)
                if rect.width > 0, rect.maxY <= shown { out.append(box) }
            }
            return out
        }
        guard !rects.isEmpty else { return }
        highlight.alphaValue = 1
        highlight.show(rects, color: HistoryStyle.learnedHighlight, radius: 3)
        fades.append(Tween(duration: 0.6, delay: 1.5, curve: .std, step: { [weak self] e in
            self?.highlight.alphaValue = 1 - e
        }, done: { [weak self] in self?.highlight.show([], color: .clear, radius: 0) }))
    }

    /// Whether a height transition (edit enter / leave, arrival) is running.
    var inTransition: Bool { transition != nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview == nil else { return }
        // A dropped row stops its timers: their steps must not run on a row the list let go.
        fades.forEach { $0.stop() }
        fades.removeAll()
        transition?.stop()
        transition = nil
        heightTween?.stop()
        heightTween = nil
    }
}

/// The 44 pt header: mark, title, close. It is the window's drag area.
final class HeaderView: NSView {
    let close = CloseButton()
    private let separator = HistoryStyle.line()
    private var scrolled = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let mark = BarsView(heights: [5, 9, 14, 8, 11], barWidth: 2, gap: 1.5, radius: 1,
                            color: HistoryStyle.inkPrimary, boxHeight: 14)
        let title = HistoryStyle.label("History", HistoryStyle.font(13, .semibold), HistoryStyle.inkPrimary)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        separator.alphaValue = 0
        for v in [mark, title, close, separator] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }
    // The first click drags, even when the panel is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Everything but the close button belongs to the drag area.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === close || hit.isDescendant(of: close) ? hit : self
    }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    /// The bottom separator shows only while the list is scrolled (120 ms, linear).
    func setScrolled(_ on: Bool) {
        guard on != scrolled else { return }
        scrolled = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            separator.animator().alphaValue = on ? 1 : 0
        }
    }
}

typealias FooterHint = (key: String, label: String)

/// The 32 pt footer: keycap hints on the left, one right-aligned.
final class FooterView: NSView {
    private let leading = NSStackView()
    private let trailing = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let line = HistoryStyle.line()
        addSubview(line)
        for s in [leading, trailing] {
            s.orientation = .horizontal
            s.alignment = .centerY
            s.spacing = 16
            s.translatesAutoresizingMaskIntoConstraints = false
            addSubview(s)
        }
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setHints(_ hints: [FooterHint], trailing end: FooterHint?) {
        leading.arrangedSubviews.forEach { $0.removeFromSuperview() }
        trailing.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hints.forEach { leading.addArrangedSubview(FooterView.hint($0)) }
        if let end = end { trailing.addArrangedSubview(FooterView.hint(end)) }
    }

    /// Keycap (18 tall, min 18 wide, radius 5, padding 0 5), 6 pt, label.
    static func hint(_ h: FooterHint) -> NSView {
        let key = HistoryStyle.label(h.key, HistoryStyle.font(11, .medium), HistoryStyle.inkLabel)
        key.alignment = .center
        key.translatesAutoresizingMaskIntoConstraints = false
        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = HistoryStyle.keycap.cgColor
        cap.layer?.cornerRadius = 5
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(key)
        let snug = cap.widthAnchor.constraint(equalTo: key.widthAnchor, constant: 10)
        snug.priority = .defaultHigh
        NSLayoutConstraint.activate([
            cap.heightAnchor.constraint(equalToConstant: 18),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            cap.widthAnchor.constraint(greaterThanOrEqualTo: key.widthAnchor, constant: 10),
            snug,
            key.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            key.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        ])
        let label = HistoryStyle.label(h.label, HistoryStyle.font(11), HistoryStyle.inkSecondary)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [cap, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }
}

/// A toast's chip, Unlearn or Retry (A9 §5, = the pill's chip): 24 tall,
/// padding 0 10, radius 12, white 0.10 / 0.22 / 0.30, 12 medium ink.primary,
/// in a 28 pt hit area.
final class ToastChip: PressableView {
    private let capsule = NSView()
    private let label: NSTextField

    init(_ title: String) {
        label = HistoryStyle.label(title, HistoryStyle.font(12, .medium), HistoryStyle.inkPrimary)
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 28))
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 12
        addSubview(capsule)
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityLabel(title)
        let w = (label.fittingSize.width + 20).rounded(.up)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: w), heightAnchor.constraint(equalToConstant: 28)])
        stateChanged(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var ringRect: CGRect { capsule.frame }
    override var ringRadius: CGFloat { 12 }

    override func layout() {
        super.layout()
        capsule.frame = NSRect(x: 0, y: ((bounds.height - 24) / 2).rounded(), width: bounds.width, height: 24)
        let l = label.fittingSize
        label.frame = NSRect(x: ((bounds.width - l.width) / 2).rounded(), y: ((bounds.height - l.height) / 2).rounded(),
                             width: l.width, height: l.height)
    }

    override func stateChanged(animated: Bool) {
        let f = HistoryStyle.chipFill
        HistoryStyle.setFill(capsule.layer, HistoryStyle.white(pressed ? f.pressed : hovered ? f.hover : f.rest),
                             duration: animated ? 0.08 : 0)
    }
}

/// The feedback toast (A4, A9 §4): 34 tall, radius 17, surface 40,40,40 @0.98,
/// edge white 0.10, shadow 0 6 16 black 0.4; icon, text, optional chip, 8
/// apart; padding L12 R14 (R5 with a chip).
final class ToastView: NSView {
    var onHover: ((Bool) -> Void)?
    let chip: ToastChip?
    let message: String

    init(icon: NSImage?, tint: NSColor?, text: NSAttributedString, chip: ToastChip?) {
        self.chip = chip
        message = text.string
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if #available(macOS 14.0, *) { clipsToBounds = false }  // the shadow
        layer?.backgroundColor = HistoryStyle.toastSurface.cgColor
        layer?.cornerRadius = 17
        layer?.borderWidth = 1  // inside the bounds
        layer?.borderColor = HistoryStyle.floatEdge.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8  // CSS blur 16
        layer?.shadowOffset = CGSize(width: 0, height: -6)  // 6 down (y up)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let icon = icon {
            let v = PlainImageView()
            v.image = icon
            v.contentTintColor = tint
            v.imageScaling = .scaleNone
            v.setAccessibilityElement(false)
            stack.addArrangedSubview(v)
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(label)
        if let chip = chip { stack.addArrangedSubview(chip) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: chip == nil ? -14 : -5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 17, cornerHeight: 17, transform: nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    // Swallow clicks on the toast body: they must not reach the rows under it.
    override func mouseDown(with event: NSEvent) {}
}

/// The "N new" chip (A7, A9 §4): 24 tall, radius 12, padding L8 R10, surface
/// 48,48,48 @0.98, edge white 0.10, arrow.up 9 semibold 4 before 11 medium
/// ink.primary. A click scrolls the list to the top.
final class NewChip: PressableView {
    private let label = HistoryStyle.label("", HistoryStyle.font(11, .medium), HistoryStyle.inkPrimary)
    private let arrow = PlainImageView()
    private var width: NSLayoutConstraint!

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        if #available(macOS 14.0, *) { clipsToBounds = false }
        layer?.backgroundColor = HistoryStyle.chipSurface.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = HistoryStyle.floatEdge.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 6  // mockup: 0 4 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        arrow.image = HistoryStyle.symbol("arrow.up", 9, .semibold)
        arrow.contentTintColor = HistoryStyle.inkPrimary
        arrow.imageScaling = .scaleNone
        for v in [arrow, label] as [NSView] { v.setAccessibilityElement(false); addSubview(v) }
        width = widthAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([width, heightAnchor.constraint(equalToConstant: 24)])
        toolTip = "Scroll to the newest"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var ringRadius: CGFloat { 12 }

    func setCount(_ n: Int) {
        label.stringValue = HistoryLayout.newChipLabel(n)
        setAccessibilityLabel(n == 1 ? "1 new dictation" : "\(n) new dictations")
        width.constant = (8 + (arrow.image?.size.width ?? 9) + 4 + label.fittingSize.width + 10).rounded(.up)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        let a = arrow.image?.size ?? .zero, l = label.fittingSize
        arrow.frame = NSRect(x: 8, y: ((bounds.height - a.height) / 2).rounded(), width: a.width, height: a.height)
        label.frame = NSRect(x: arrow.frame.maxX + 4, y: ((bounds.height - l.height) / 2).rounded(), width: l.width, height: l.height)
    }
}

/// Overlay scroller: a 6 pt knob, white 0.32, no track.
final class OverlayScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let r = rect(for: .knob)
        guard r.height > 4 else { return }
        let knob = NSRect(x: (r.midX - 3).rounded(), y: r.minY + 2, width: 6, height: r.height - 4)
        HistoryStyle.white(0.32).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3).fill()
    }
}

final class HistoryController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    let path = HistoryStore.defaultPath()
    var window: HistoryWindow!
    let list = NSStackView()
    let card = NSVisualEffectView()
    let header = HeaderView()
    let footer = FooterView()
    let scroll = NSScrollView()
    var emptyView: NSView!
    var entries: [HistoryEntry] = []
    /// The entry being edited, its field and its row's position.
    var editing: (entry: HistoryEntry, field: EditField, index: Int)?
    /// The file changed while an editor was open: applied when it closes.
    var stale = false
    /// A deferred refresh is scheduled (rows were mid-motion).
    var retryPending = false
    var fileStamp = ""
    /// The row ↩ acts on (A9 §8): the newest on every open and refresh, moved by ↑/↓.
    var targetIndex = 0
    /// ↩ copied and the window is about to close: further ↩ do nothing.
    var closingAfterCopy = false
    var copyClose: DispatchWorkItem?
    /// Paste is fading the window out: a raise must not bring it back.
    var pasting = false
    /// The app whose focused text field Paste types into; nil hides Paste.
    var pasteTarget: NSRunningApplication?
    /// The app the user was in when the window opened: closing gives it the keys back.
    var returnApp: NSRunningApplication?
    /// Activate Xhisper when showing the window. Off for the pill's launch
    /// (`open -g`), where the panel takes the keys and the user's app stays
    /// frontmost; on for `xhisper --history` and a Finder double-click.
    var activateOnOpen = true
    var motion: Tween?
    /// Losing the key closes the window, but only once it has had it: not
    /// while it is still opening.
    var everKey = false
    /// The dictation pipeline seen on the last look (xhisper.pid), nil when none.
    var pipeline: pid_t?
    /// Shown while a dictation was running: no key until it has pasted.
    var awaitingKey = false
    var closing = false
    // Toasts (A4): one at a time.
    var toast: ToastView?
    var toastKind: HistoryLayout.Toast?
    var toastBottom: NSLayoutConstraint?
    var toastHold: DispatchWorkItem?
    var toastDeadline = Date()
    var toastRemaining: Double = 0
    var toastMotion: Tween?
    /// A toast fading out (180 ms); dropped at once when another comes in.
    var leavingToast: (view: ToastView, motion: Tween)?
    // Live arrival (A7): the "N new" chip, shown when dictations land while scrolled down.
    let newChip = NewChip()
    var newChipTop: NSLayoutConstraint!
    var newCount = 0
    var newChipShown = false
    var chipMotion: Tween?
    var scrollMotion: Tween?

    /// The app the user was typing in: the pill hands its pid over (it never
    /// takes focus), else whatever is frontmost. Never ourselves.
    static func findPasteTarget(pid: pid_t?) -> NSRunningApplication? {
        guard let app = userApp(pid: pid), AXIsProcessTrusted(),
              AXCommand.hasFocusedTextField(app.processIdentifier) else { return nil }
        return app
    }

    /// The pill's handed-over pid, else the frontmost app; never ourselves.
    static func userApp(pid: pid_t?) -> NSRunningApplication? {
        let me = Bundle.main.bundleIdentifier
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
        guard let app = app, app.processIdentifier != getpid(), me == nil || app.bundleIdentifier != me else { return nil }
        return app
    }

    /// Paste steps go to xhisper.log (never the text): a paste that lands
    /// nowhere is otherwise invisible.
    func log(_ message: String) { appendLine(Runtime.path("xhisper.log"), "History: " + message) }

    /// Hand the keys back to the user's app (see `AXCommand.refocus`).
    func handBackKeys(to app: NSRunningApplication?) {
        guard let app = app, !app.isTerminated else { return }
        let ax = AXIsProcessTrusted() ? AXCommand.refocus(app.processIdentifier) : "no accessibility"
        app.activate(options: [.activateIgnoringOtherApps])
        log("keys back to \(app.bundleIdentifier ?? "?") (\(ax))")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        window = HistoryWindow(contentRect: NSRect(origin: .zero, size: HistoryLayout.defaultSize),
                               styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        window.title = "History"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.animationBehavior = .none  // the open/close motion is ours
        window.isMovableByWindowBackground = false
        // A clear window lets clicks on fully transparent pixels fall through to
        // the window below; the rounded-off corners hold the resize zones.
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.minSize = HistoryLayout.minSize
        window.delegate = self
        window.onEscape = { [unowned self] in
            if self.editing != nil { self.finishEdit(save: false) } else { self.closeAnimated() }
        }
        window.onClose = { [unowned self] in self.closeAnimated() }
        window.onKey = { [unowned self] in self.handleKey($0) }

        let root = HistoryRootView(frame: NSRect(origin: .zero, size: HistoryLayout.defaultSize))
        root.wantsLayer = true
        root.visibleFrame = { [unowned self] in (self.window.screen ?? NSScreen.main)?.visibleFrame ?? .zero }
        root.onResized = { [unowned self] in self.saveSize() }
        window.contentView = root
        buildCard(in: root)

        populate()
        fileStamp = stamp()
        // Opened while a dictation runs (History chip on its pill): its paste
        // must reach the user's app, so the panel waits for it to finish.
        pipeline = Pipeline.current()
        if pipeline != nil { holdKey() }
        let watch = Timer(timeInterval: 0.25, repeats: true) { [unowned self] _ in self.watchPipeline() }
        watch.tolerance = 0.05
        RunLoop.main.add(watch, forMode: .common)
        // Live refresh when a new dictation lands while the window is open.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [unowned self] _ in
            let now = self.stamp()
            if now != self.fileStamp { self.fileStamp = now; self.refreshFromFile() }
        }
        // Relative times ("2 min ago") age while the window is open.
        let times = Timer(timeInterval: 30, repeats: true) { [unowned self] _ in self.rows.forEach { $0.refreshTime() } }
        times.tolerance = 1
        RunLoop.main.add(times, forMode: .common)
        presentAnimated()
    }

    /// Material, tint and edge (A9 §1), then header, list / empty state, footer.
    func buildCard(in root: NSView) {
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.appearance = NSAppearance(named: .darkAqua)
        card.wantsLayer = true
        card.layer?.cornerRadius = HistoryStyle.radius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.maskImage = HistoryStyle.roundedMask(radius: HistoryStyle.radius)
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = HistoryStyle.surface.cgColor
        tint.layer?.cornerRadius = HistoryStyle.radius
        tint.layer?.cornerCurve = .continuous
        tint.layer?.borderWidth = 1  // drawn inside the bounds
        tint.layer?.borderColor = HistoryStyle.edge.cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(tint)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScroller = OverlayScroller()
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                               queue: .main) { [unowned self] _ in
            let scrolled = !self.scroll.isHidden && self.scroll.contentView.bounds.minY > 0.5
            self.header.setScrolled(scrolled)
            if !scrolled { self.hideNewChip() }  // the new rows are in view
        }

        emptyView = makeEmptyView()
        header.close.action = { [unowned self] in self.closeAnimated() }

        newChip.isHidden = true
        newChip.action = { [unowned self] in self.scrollToTop() }
        for v in [scroll, emptyView!, header, footer, newChip] { card.addSubview(v) }
        newChipTop = newChip.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.topAnchor.constraint(equalTo: card.topAnchor),
            tint.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            newChip.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            newChipTop,
        ])
    }

    /// A6: seven bars, title, one line of help; centred, raised 22 pt.
    func makeEmptyView() -> NSView {
        let bars = BarsView(heights: [6, 10, 15, 20, 15, 10, 6], barWidth: 4, gap: 3, radius: 2,
                            color: HistoryStyle.inkPrimary.withAlphaComponent(0.35), boxHeight: 28)
        let title = HistoryStyle.label("No dictations yet", HistoryStyle.font(13, .semibold),
                                       HistoryStyle.inkPrimary.withAlphaComponent(0.9))
        let body = NSTextField(wrappingLabelWithString: "")
        body.attributedStringValue = HistoryStyle.text(
            "Hold your dictation hotkey and speak. Your last 20 dictations will show up here.",
            font: HistoryStyle.font(12), color: HistoryStyle.inkSecondary, lineHeight: 17, alignment: .center)
        body.isSelectable = false
        body.preferredMaxLayoutWidth = 250
        body.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        let stack = NSStackView(views: [bars, title, body])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: bars)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let area = NSView()
        area.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: area.centerYAnchor, constant: -22),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: area.trailingAnchor, constant: -40),
        ])
        area.isHidden = true
        return area
    }

    /// Footer hints; edit mode passes its own (↩ Save, ⇧↩ New line, esc Cancel).
    func setFooterHints(_ hints: [FooterHint], trailing: FooterHint?) {
        footer.setHints(hints, trailing: trailing)
    }

    /// The resting footer: what ↩ does, and esc. "newest" only while the
    /// Enter target is the newest row.
    func updateFooter() {
        if editing != nil {
            setFooterHints([("↩", "Save"), ("⇧↩", "New line")], trailing: ("esc", "Cancel"))
            return
        }
        var hints: [FooterHint] = []
        if !entries.isEmpty {
            let which = targetIndex == 0 ? "newest " : ""
            hints.append(("↩", pasteTarget.map { "Paste \(which)in \($0.localizedName ?? "the app")" }
                                ?? (targetIndex == 0 ? "Copy newest" : "Copy")))
        }
        setFooterHints(hints, trailing: ("esc", "Close"))
    }

    // Not while pasting: hiding the panel before ⌘V counts as closing the
    // last window, and quitting there dropped every paste.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !pasting }

    func applicationWillTerminate(_ notification: Notification) {
        if readPid(pidFile) == getpid() { unlink(pidFile) }
    }

    /// Edit/Close shortcuts (Cmd+C/V/X/A/Z, Cmd+W) need a main menu, even for
    /// an app without a Dock icon.
    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func stamp() -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((a?[.size] as? Int) ?? -1)"
    }

    var rows: [HistoryRowView] { list.arrangedSubviews.compactMap { $0 as? HistoryRowView } }
    func row(_ index: Int) -> HistoryRowView? { rows.first { $0.index == index } }

    /// The whole list from the file, the Enter target on the newest: on open
    /// and on a raise.
    func populate() {
        rebuild(HistoryStore.load(path), keepPlace: false)
    }

    /// Rebuild every row from `file`. `keepPlace` (a live change that is not a
    /// plain arrival) keeps the scroll position, the expanded rows and a moved
    /// Enter target. Never under an open editor: applied once it closes.
    func rebuild(_ file: [HistoryEntry], keepPlace: Bool) {
        if editing != nil { stale = true; return }  // don't wipe an edit in progress
        cancelCopyClose()
        let y = scroll.contentView.bounds.minY
        let moved = keepPlace && targetIndex > 0 && entries.indices.contains(targetIndex) ? entries[targetIndex] : nil
        let open = keepPlace ? Set(rows.filter { $0.expanded }.map { $0.entry.time + "\u{0}" + $0.entry.text }) : []
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries = file
        // ↩ goes back to the newest dictation, unless the user had moved it and the entry is still here.
        targetIndex = moved.flatMap { file.firstIndex(of: $0) } ?? 0
        emptyView.isHidden = !entries.isEmpty
        scroll.isHidden = entries.isEmpty
        if entries.isEmpty { header.setScrolled(false) }
        for (index, entry) in entries.enumerated() {
            let row = makeRow(entry, index: index)
            if open.contains(entry.time + "\u{0}" + entry.text) { row.setExpanded(true, animated: false) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
        }
        fitRowText()
        if keepPlace, !entries.isEmpty { scrollList(toY: y) } else { hideNewChip() }
        updateFooter()
    }

    /// The text column: the list's width minus its inset (16) and the row
    /// padding (24). The actions sit on the meta line above. Measured on the
    /// laid-out clip view, which a legacy scroller narrows.
    func textColumnWidth() -> CGFloat {
        card.layoutSubtreeIfNeeded()
        let clip = scroll.contentView.bounds.width
        return (clip > 0 ? clip : window?.frame.width ?? HistoryLayout.defaultSize.width) - 40
    }

    /// Wrap each entry at its text column.
    func fitRowText() {
        guard !rows.isEmpty else { return }
        let width = textColumnWidth()
        rows.forEach { $0.layoutText(width: width) }
    }

    // MARK: Live arrival (A7)

    /// The history file changed: insert new dictations on top when that is
    /// all that happened, else rebuild in place. Waits while an editor is open.
    func refreshFromFile() {
        guard editing == nil else { stale = true; return }
        // A row is mid-motion (leave edit, arrival): apply once it has settled.
        if rows.contains(where: { $0.inTransition }) {
            stale = true
            if !retryPending {
                retryPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self = self else { return }
                    self.retryPending = false
                    if self.stale { self.refreshFromFile() }
                }
            }
            return
        }
        stale = false
        let file = HistoryStore.load(path)
        switch HistoryLayout.arrival(shown: entries, file: file) {
        case .same: return
        case .rebuild: rebuild(file, keepPlace: true)
        case let .insert(count, keep): insertArrivals(file, count: count, keep: keep)
        }
    }

    /// `count` new rows on top, old rows past `keep` dropped silently. At the
    /// top of the list they open animated; scrolled down, the visible rows
    /// stay put and the "N new" chip counts them.
    func insertArrivals(_ file: [HistoryEntry], count: Int, keep: Int) {
        let old = rows
        let scrolled = scroll.contentView.bounds.minY > 0.5
        let oldTarget = targetIndex
        targetIndex = HistoryLayout.targetAfterArrival(oldTarget, inserted: count, keep: keep)
        let change = {
            for row in old.dropFirst(keep) { row.removeFromSuperview() }
            for row in old.prefix(keep) { row.index += count }
            self.entries = file
            let width = self.textColumnWidth()
            var added: [HistoryRowView] = []
            for (index, entry) in file.prefix(count).enumerated() {
                let row = self.makeRow(entry, index: index)
                self.list.insertArrangedSubview(row, at: index)
                row.widthAnchor.constraint(equalTo: self.list.widthAnchor, constant: -16).isActive = true
                row.layoutText(width: width)
                added.append(row)
            }
            // The target highlight (and its 6-line clamp) moves when the newest had it.
            for row in old.prefix(keep) where row.isTarget != (row.index == self.targetIndex) {
                row.setTarget(row.index == self.targetIndex, animated: !scrolled)
            }
            for row in added {
                self.list.setCustomSpacing(scrolled ? 4 : 0, after: row)
                let list = self.list
                row.arrive(animated: !scrolled) { [weak row] e in
                    guard let row = row, row.superview === list else { return }
                    list.setCustomSpacing(4 * e, after: row)
                }
            }
        }
        if scrolled {
            keepingScroll(change)
            if count > 0 { newCount += count; showNewChip() }
        } else {
            change()
        }
        updateFooter()
    }

    /// Run `change` and keep the first visible row where it was on screen.
    func keepingScroll(_ change: () -> Void) {
        guard let document = scroll.documentView else { change(); return }
        let top = scroll.contentView.bounds.minY
        let anchor = rows.first { document.convert($0.bounds, from: $0).maxY > top }
        let before = anchor.map { document.convert($0.bounds, from: $0).minY }
        change()
        card.layoutSubtreeIfNeeded()
        var y = top
        if let a = anchor, a.superview != nil, let b = before { y = top + document.convert(a.bounds, from: a).minY - b }
        scrollList(toY: y)
    }

    /// Scroll the list to `y` (clamped to its content).
    func scrollList(toY y: CGFloat) {
        guard let document = scroll.documentView else { return }
        card.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY).rounded()))
        scroll.reflectScrolledClipView(clip)
    }

    /// "N new" in: 160 ms out, opacity and y −4 -> 0 (no move with Reduce Motion).
    func showNewChip() {
        newChip.setCount(newCount)
        guard !newChipShown else { return }
        newChipShown = true
        newChip.isHidden = false
        let rise: CGFloat = HistoryStyle.reduceMotion ? 0 : 4
        chipMotion?.stop()
        chipMotion = Tween(duration: 0.16, curve: .out, step: { [unowned self] e in
            self.newChip.alphaValue = e
            self.newChipTop.constant = 8 - rise * (1 - e)
        })
    }

    /// The chip goes when the list is back at the top (scrolled or clicked).
    func hideNewChip() {
        newCount = 0
        guard newChipShown else { return }
        newChipShown = false
        let alpha = newChip.alphaValue
        chipMotion?.stop()
        chipMotion = Tween(duration: 0.16, curve: .in, step: { [unowned self] e in
            self.newChip.alphaValue = alpha * (1 - e)
        }, done: { [unowned self] in
            if !self.newChipShown { self.newChip.isHidden = true; self.newChipTop.constant = 8 }
        })
    }

    /// The chip's click: back to the newest, 200 ms std.
    func scrollToTop() {
        let clip = scroll.contentView
        let from = clip.bounds.minY
        hideNewChip()
        scrollMotion?.stop()
        scrollMotion = Tween(duration: 0.2, curve: .std, step: { [unowned self] e in
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: (from * (1 - e)).rounded()))
            self.scroll.reflectScrolledClipView(clip)
        })
    }

    /// The single row builder. Actions in the order Edit · Copy · Paste, the
    /// primary capsule last: Paste when a text field waits for it, else Copy.
    func makeRow(_ entry: HistoryEntry, index: Int) -> HistoryRowView {
        let row = HistoryRowView(entry: entry, index: index)
        row.interactive = { [unowned self] in self.editing == nil }
        // Actions look their row's position up when clicked: arrivals shift it.
        let edit = RowButton(.icon("pencil"), label: "Edit", tooltip: "Edit")
        edit.action = { [unowned self, weak row] in if let row = row { self.editEntry(row.index) } }
        if let target = pasteTarget {
            let copy = RowButton(.icon("doc.on.doc"), label: "Copy", tooltip: "Copy")
            copy.action = { [unowned self, weak row] in if let row = row { self.copyEntry(row.index) } }
            let paste = RowButton(.primary("Paste"), label: "Paste",
                                  tooltip: "Paste into \(target.localizedName ?? "the app")")
            paste.action = { [unowned self, weak row] in if let row = row { self.pasteEntry(row.index) } }
            row.setActions([edit, copy, paste])
            row.copyButton = copy
            row.primary = paste
        } else {
            let copy = RowButton(.primary("Copy"), label: "Copy", tooltip: "Copy")
            copy.action = { [unowned self, weak row] in if let row = row { self.copyEntry(row.index) } }
            row.setActions([edit, copy])
            row.copyButton = copy
            row.primary = copy
        }
        row.setTarget(index == targetIndex, animated: false)
        return row
    }

    // MARK: Keyboard (A9 §8)

    /// ↩ acts on the Enter-target row, ↑/↓ move it, esc closes. While an
    /// entry is edited every key belongs to the editor (esc cancels it there).
    func handleKey(_ event: NSEvent) -> Bool {
        guard editing == nil else { return false }
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 36, 76:  // Return, keypad Enter
            if !event.isARepeat { activateTarget() }
            return true
        case 53:  // Escape
            closeAnimated()
            return true
        case 126: moveTarget(by: -1); return true  // ↑
        case 125: moveTarget(by: 1); return true   // ↓
        default: return false
        }
    }

    /// ↩: Paste the target row; with nowhere to paste, Copy it and close
    /// 500 ms after the check appears.
    func activateTarget() {
        guard !closing, !closingAfterCopy, entries.indices.contains(targetIndex) else { return }
        if pasteTarget != nil {
            pasteEntry(targetIndex)
        } else {
            closingAfterCopy = true
            copyEntry(targetIndex) { [weak self] in
                guard let self = self, self.closingAfterCopy else { return }  // cancelled meanwhile
                let close = DispatchWorkItem { [weak self] in self?.copyClose = nil; self?.closeAnimated() }
                self.copyClose = close
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: close)
            }
        }
    }

    /// Call off a pending ↩ copy-close (a raise, an edit, a refresh, a refused close).
    func cancelCopyClose() {
        copyClose?.cancel()
        copyClose = nil
        closingAfterCopy = false
    }

    /// ↑/↓: move the Enter-target highlight (clamp, ↩ glyph, actions) and
    /// keep the row in view, also once its height has settled.
    func moveTarget(by delta: Int) {
        guard !closing else { return }
        let all = rows
        let next = HistoryLayout.moveTarget(targetIndex, by: delta, count: all.count)
        guard next != targetIndex, all.indices.contains(targetIndex) else { return }
        let old = all[targetIndex], new = all[next]
        targetIndex = next
        old.setTarget(false, animated: true)
        new.setTarget(true, animated: true) { [weak self] in self?.reveal(new) }
        reveal(new)
        updateFooter()
    }

    func reveal(_ row: NSView) {
        list.layoutSubtreeIfNeeded()
        // Rows are 4 apart and the list ends 8 below the last: show that margin too.
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -4))
    }

    // MARK: Copy, Paste, Edit

    /// Clipboard = the raw stored text; the Copy button shows Copied.
    /// `shown` runs once the check is in.
    func copyEntry(_ index: Int, shown: (() -> Void)? = nil) {
        guard editing == nil, !closing, entries.indices.contains(index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[index].text, forType: .string)
        if let button = row(index)?.copyButton { button.showCopied(shown: shown) } else { shown?() }
    }

    /// Paste (A9 §7, §8): clipboard = the raw text, the window fades out in
    /// 120 ms (curve in, opacity only) and orders out, ⌘V goes to the target
    /// at 160 ms, the old clipboard comes back 0.3 s later, then we quit.
    /// The non-activating panel never took the target's place at the front,
    /// so normally the keystroke can go at once.
    func pasteEntry(_ index: Int) {
        log("paste clicked: row \(index) of \(entries.count), editing \(editing != nil), closing \(closing), target \(pasteTarget?.bundleIdentifier ?? "none")")
        guard editing == nil, !closing, let target = pasteTarget, entries.indices.contains(index) else { return }
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(entries[index].text, forType: .string)
        closing = true  // losing the key below must not start the close motion
        pasting = true
        motion?.stop()
        let alpha = window.alphaValue
        let start = CACurrentMediaTime()
        motion = Tween(duration: 0.12, curve: .in, step: { [unowned self] e in
            self.window.alphaValue = alpha * (1 - e)
        }, done: { [unowned self] in
            self.window.orderOut(nil)
            // ⌘V at 160 ms, and never sooner than 40 ms after the order-out
            // (a lagging fade): the window server must have dropped the panel.
            let wait = max(0.16 - (CACurrentMediaTime() - start), 0.04)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [unowned self] in
                self.sendPaste(to: target, restoring: saved)
            }
        })
    }

    func sendPaste(to target: NSRunningApplication, restoring saved: String?) {
        func post() {
            let rc = Paste.keystroke()
            if rc != 0 { log("paste: keystroke failed (\(rc == 2 ? "no Accessibility" : "no event source"))") }
            // The app reads the clipboard after the keystroke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let saved = saved {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(saved, forType: .string)
                }
                NSApp.terminate(nil)
            }
        }
        func isFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }
        log("paste: target \(target.bundleIdentifier ?? "?"), front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"), we are active \(NSApp.isActive)")
        // Even with the target frontmost the keys are still ours (the panel
        // had them): its window must be made key again before ⌘V.
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: target) }
        handBackKeys(to: target)
        let deadline = Date().addingTimeInterval(1.5)
        func waitForFocus() {
            guard isFront() || Date() > deadline else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: waitForFocus)
                return
            }
            // A moment for its window to take the key focus back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [unowned self] in
                self.log("paste: ⌘V, front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
                post()
            }
        }
        waitForFocus()
    }

    /// A3 edit: the row's text becomes a field, its actions Cancel and Save,
    /// the other rows dim, the footer shows the editor's keys.
    func editEntry(_ index: Int) {
        guard editing == nil, !closing, entries.indices.contains(index), let row = row(index) else { return }
        cancelCopyClose()
        dismissToast()
        let entry = entries[index]
        let cancel = RowButton(.ghost("Cancel"), label: "Cancel", tooltip: nil)
        cancel.action = { [unowned self] in self.finishEdit(save: false) }
        let save = RowButton(.primary("Save"), label: "Save", tooltip: nil)
        save.action = { [unowned self] in self.finishEdit(save: true) }
        let field = EditField(text: entry.text)
        field.textView.delegate = self
        editing = (entry, field, index)
        row.enterEdit(field, actions: [cancel, save], animated: true) { [weak self] in self?.reveal(row) }
        for other in rows where other !== row { other.setDimmed(true, duration: 0.18) }
        rows.forEach { $0.refresh(animated: true) }  // no hover elsewhere while editing
        updateFooter()
        field.caretToEnd()
        window.makeFirstResponder(field.textView)
    }

    /// Editor keys (A9 §8), as text commands so input methods keep their own
    /// Return: ↩ Save, ⇧↩ or ⌥↩ a new line, esc Cancel.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let mods = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]) ?? []
            if mods.isEmpty { finishEdit(save: true) } else { textView.insertNewlineIgnoringFieldEditor(nil) }
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)  // a plain newline, not U+2028
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            finishEdit(save: false)  // NSTextView would autocomplete
            return true
        default:
            return false
        }
    }

    /// The field grows with its text (2 to 10 lines),
    /// and the caret stays in view in the list as the field grows.
    func textDidChange(_ notification: Notification) {
        guard let field = editing?.field else { return }
        field.fit()
        list.layoutSubtreeIfNeeded()
        // Its closest clip view is the list's (the field's own scroll view is inside it).
        field.scrollToVisible(field.caretRect().insetBy(dx: 0, dy: -8))
    }

    /// Save or Cancel. A save writes the file first, then learns the changed
    /// words off the main thread; the toast says how it went. A failed write
    /// keeps the editor open (red border) so Retry can try the same text again.
    func finishEdit(save: Bool) {
        guard let (entry, field, index) = editing else { return }
        let newText = field.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved: HistoryEntry?
        if save && !newText.isEmpty && newText != entry.text {
            dismissToast()
            guard HistoryStore.update(path, entry: entry, newText: newText) else {
                field.failed = true
                showToast(.failed)
                return
            }
            saved = HistoryEntry(time: entry.time, text: newText)
            entries[index] = saved!
        } else if toastKind == .failed {
            dismissToast()
        }
        editing = nil
        let row = self.row(index)
        // Dictations that landed meanwhile come in once the row is back.
        if let row = row {
            row.leaveEdit(saved: saved, animated: true) { [weak self] in
                if self?.stale == true { self?.refreshFromFile() }
            }
        } else {
            refreshFromFile()
        }
        for other in rows where other !== row { other.setDimmed(false, duration: 0.15) }
        rows.forEach { $0.refresh(animated: true) }
        updateFooter()
        window.makeFirstResponder(nil)
        if let saved = saved {
            let old = entry.text
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let learned = HistoryController.learnFromEdit(old: old, new: saved.text)
                DispatchQueue.main.async {
                    guard let self = self, !self.closing else { return }
                    if !learned.isEmpty { self.rows.first { $0.entry == saved }?.highlightWords(learned) }
                    // A later edit's "Could not save" (and its Retry) outranks this news.
                    if self.toastKind == .failed || self.editing?.field.failed == true { return }
                    if learned.isEmpty {
                        self.showToast(.saved)
                    } else {
                        self.showToast(.learned, words: learned)
                    }
                }
            }
        }
    }

    static var learnCommand: String {
        ProcessInfo.processInfo.environment["XHISPER_LEARN"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/bin/xhisper-learn"
    }

    /// `xhisper-learn diff`, text over stdin; the words it learned. Blocks up
    /// to 10 s: call it off the main thread.
    static func learnFromEdit(old: String, new: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: learnCommand)
        p.arguments = ["diff"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil,
              let body = try? JSONSerialization.data(withJSONObject: ["old": old, "new": new]) else { return [] }
        try? input.fileHandleForWriting.write(contentsOf: body)  // EPIPE if it died: ignored
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return [] }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The toast's Unlearn: `xhisper-learn remove W…` (the words only, as the
    /// pill does), off the main thread, then "Unlearned W".
    func unlearn(_ words: [String]) {
        toast?.chip?.inert = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var ok = false
            let p = Process()
            p.executableURL = URL(fileURLWithPath: HistoryController.learnCommand)
            p.arguments = ["remove"] + words
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let deadline = Date().addingTimeInterval(5)
                while p.isRunning && Date() < deadline { usleep(20_000) }
                if p.isRunning { p.terminate() } else { ok = p.terminationStatus == 0 }
            }
            DispatchQueue.main.async {
                guard let self = self, !self.closing else { return }
                self.showToast(.unlearned, words: words, failed: !ok)
            }
        }
    }

    // MARK: Toasts (A4)

    /// Show a toast, replacing any other: Saved (1.8 s), Learned + Unlearn
    /// (3.5 s, paused while hovered), Could not save + Retry (6 s or the next
    /// action), Unlearned (1.8 s). In 200 ms out (y +8 -> 0, fade).
    func showToast(_ kind: HistoryLayout.Toast, words: [String] = [], failed: Bool = false) {
        dismissToast(animated: false)
        let regular = HistoryStyle.font(12), bold = HistoryStyle.font(12, .semibold)
        func plain(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: regular, .foregroundColor: HistoryStyle.inkLabel])
        }
        func word(_ s: String) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: bold, .foregroundColor: HistoryStyle.inkPrimary])
        }
        func list(_ prefix: String) -> NSAttributedString {
            let t = NSMutableAttributedString(attributedString: plain(prefix))
            for (i, w) in words.enumerated() {
                if i > 0 { t.append(plain(", ")) }
                t.append(word(w))
            }
            return t
        }
        let check = HistoryStyle.symbol("checkmark", 12, .bold)
        let warning = HistoryStyle.symbol("exclamationmark.triangle", 12, .semibold)
        let view: ToastView
        switch kind {
        case .saved:
            view = ToastView(icon: check, tint: HistoryStyle.success, text: plain("Saved"), chip: nil)
        case .learned:
            let chip = ToastChip("Unlearn")
            chip.action = { [unowned self] in self.unlearn(words) }
            view = ToastView(icon: check, tint: HistoryStyle.success, text: list("Learned: "), chip: chip)
        case .failed:
            let chip = ToastChip("Retry")
            chip.action = { [unowned self] in self.finishEdit(save: true) }
            let text = NSAttributedString(string: "Could not save",
                                          attributes: [.font: HistoryStyle.font(12, .medium), .foregroundColor: HistoryStyle.error])
            view = ToastView(icon: warning, tint: HistoryStyle.error, text: text, chip: chip)
        case .unlearned:
            view = failed
                ? ToastView(icon: warning, tint: HistoryStyle.error,
                            text: NSAttributedString(string: "Could not unlearn", attributes: [
                                .font: HistoryStyle.font(12, .medium), .foregroundColor: HistoryStyle.error]), chip: nil)
                : ToastView(icon: nil, tint: nil, text: list("Unlearned "), chip: nil)
        }
        if kind == .learned {
            view.onHover = { [unowned self, unowned view] in if self.toast === view { self.toastHovered($0) } }
        }
        card.addSubview(view)
        let bottom = view.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            view.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -32),
            bottom,
        ])
        toast = view
        toastKind = kind
        toastBottom = bottom
        NSAccessibility.post(element: window as Any, notification: .announcementRequested,
                             userInfo: [.announcement: view.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let rise: CGFloat = HistoryStyle.reduceMotion ? 0 : 8
        toastMotion = Tween(duration: 0.2, curve: .out, step: { e in
            view.alphaValue = e
            bottom.constant = -12 + rise * (1 - e)
        })
        holdToast(HistoryLayout.toastHold(kind))
    }

    func holdToast(_ seconds: Double) {
        toastHold?.cancel()
        let hide = DispatchWorkItem { [weak self] in self?.dismissToast() }
        toastHold = hide
        toastRemaining = seconds
        toastDeadline = Date().addingTimeInterval(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: hide)
    }

    /// Learned holds while the pointer is on it, then runs out what was left.
    func toastHovered(_ inside: Bool) {
        guard toast != nil else { return }
        if inside {
            guard toastHold != nil else { return }  // already paused
            toastHold?.cancel()
            toastHold = nil
            toastRemaining = max(0, toastDeadline.timeIntervalSinceNow)
        } else if toastHold == nil {
            holdToast(max(0.6, toastRemaining))
        }
    }

    /// Toast out: 180 ms, curve in, fade.
    func dismissToast(animated: Bool = true) {
        toastHold?.cancel()
        toastHold = nil
        toastMotion?.stop()
        toastMotion = nil
        if let leaving = leavingToast { leaving.motion.stop(); leaving.view.removeFromSuperview(); leavingToast = nil }
        guard let view = toast else { return }
        toast = nil
        toastKind = nil
        toastBottom = nil
        guard animated else { view.removeFromSuperview(); return }
        let alpha = view.alphaValue
        let motion = Tween(duration: 0.18, curve: .in, step: { e in view.alphaValue = alpha * (1 - e) },
                           done: { [weak self] in
            view.removeFromSuperview()
            if self?.leavingToast?.view === view { self?.leavingToast = nil }
        })
        leavingToast = (view, motion)
    }

    // MARK: Size, placement, motion

    func savedSize() -> NSSize {
        let s = NSSizeFromString(UserDefaults.standard.string(forKey: sizeKey) ?? "")
        return s.width > 0 && s.height > 0 ? s : HistoryLayout.defaultSize
    }

    /// Only the size is kept: the position is recomputed on every open.
    func saveSize() {
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: sizeKey)
    }

    /// Scale the card about its bottom centre (the open motion's 0.98 -> 1).
    func setCardScale(_ s: CGFloat) {
        guard let layer = card.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if s == 1 {
            layer.transform = CATransform3DIdentity
        } else {
            // The transform pivots on the anchor point; move the pivot to the bottom centre.
            let b = layer.bounds
            let anchor = CGPoint(x: b.minX + layer.anchorPoint.x * b.width, y: b.minY + layer.anchorPoint.y * b.height)
            let bottom = layer.contentsAreFlipped() ? b.maxY : b.minY
            let d = CGPoint(x: b.midX - anchor.x, y: bottom - anchor.y)
            var t = CATransform3DMakeTranslation(d.x, d.y, 0)
            t = CATransform3DScale(t, s, s, 1)
            t = CATransform3DTranslate(t, -d.x, -d.y, 0)
            layer.transform = t
        }
        CATransaction.commit()
    }

    /// Give the panel the keys. It is non-activating, so the user's app stays
    /// frontmost; activation is only for launches that are not the pill's, and
    /// as a fallback when AppKit would not make the panel key.
    func bringToFront(activate: Bool) {
        // A dictation is running: show, but leave the keys (and the front) to the user's app.
        if awaitingKey { window.orderFrontRegardless(); return }
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async { [unowned self] in
            guard !self.window.isKeyWindow, !self.closing, !self.awaitingKey else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    /// Open (A8): 220 ms after 40, curve out; rise 24 pt, fade in, card 0.98 -> 1
    /// from its bottom centre. Reduce Motion keeps the fade only.
    func presentAnimated() {
        let mouse = NSEvent.mouseLocation
        // No display at all (lid closed, headless): nothing to show on.
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
                ?? NSScreen.screens.first else { NSApp.terminate(nil); return }
        let visible = screen.visibleFrame
        let frame = HistoryLayout.frame(size: savedSize(), visible: visible)
        window.maxSize = HistoryLayout.maxSize(visible: visible)
        let rise: CGFloat = HistoryStyle.reduceMotion ? 0 : 24
        window.setFrame(NSRect(x: frame.minX, y: frame.minY - rise, width: frame.width, height: frame.height), display: false)
        window.alphaValue = 0
        fitRowText()
        card.layoutSubtreeIfNeeded()
        setCardScale(rise > 0 ? 0.98 : 1)
        bringToFront(activate: activateOnOpen)
        motion?.stop()
        motion = Tween(duration: 0.22, delay: 0.04, curve: .out, step: { [unowned self] e in
            self.window.alphaValue = e
            self.window.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - rise * (1 - e)))
            if rise > 0 { self.setCardScale(0.98 + 0.02 * e) }
        }, done: { [unowned self] in
            self.setCardScale(1)
            self.window.invalidateShadow()
        })
    }

    /// Close (A8): 160 ms, curve in; fade out and drop 12 pt, then quit.
    /// `handBack`: give the keys back to the user's app (esc, ×, ↩, a new
    /// dictation); not when the user clicked elsewhere, which chose its own window.
    func closeAnimated(handBack: Bool = true) {
        guard !closing else { return }
        if let edit = editing {
            // Never close over unsaved changes (×, Cmd+W); esc cancels the edit first.
            if edit.field.textView.string.trimmingCharacters(in: .whitespacesAndNewlines) != edit.entry.text {
                NSSound.beep()
                cancelCopyClose()
                return
            }
            editing = nil  // an untouched editor just goes with the window
        }
        closing = true
        motion?.stop()
        let origin = window.frame.origin
        let alpha = window.alphaValue
        let drop: CGFloat = HistoryStyle.reduceMotion ? 0 : 12
        motion = Tween(duration: 0.16, curve: .in, step: { [unowned self] e in
            self.window.alphaValue = alpha * (1 - e)
            self.window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - drop * e))
        }, done: { [unowned self] in
            self.window.orderOut(nil)
            if handBack && self.everKey { self.handBackKeys(to: self.returnApp) }
            NSApp.terminate(nil)
        })
    }

    func windowDidBecomeKey(_ notification: Notification) { everKey = true }

    /// A click elsewhere closes the window, except over an edit in progress.
    func windowDidResignKey(_ notification: Notification) {
        guard everKey, !closing, editing == nil, !awaitingKey else { return }
        closeAnimated(handBack: false)
    }

    func windowDidResize(_ notification: Notification) {
        window.invalidateShadow()
        fitRowText()
    }

    func raise() {
        guard !pasting else { return }  // on its way out with a paste: let it finish
        cancelCopyClose()
        // Opened again from another app: Paste now goes there.
        // (Not when the front app is us, or the launch that just signalled us.)
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            pasteTarget = HistoryController.findPasteTarget(pid: nil)
            returnApp = HistoryController.userApp(pid: nil)
        }
        populate()
        // Asked for while a dictation runs (History chip on its pill): show
        // without the keys until it has pasted. Not over an edit, where
        // dictating into the open editor is the point.
        if let live = Pipeline.current(), editing == nil {
            pipeline = live
            holdKey()
        }
        if closing && window.isVisible {
            // Asked again while fading out: come back instead of quitting.
            closing = false
            presentAnimated()
        } else if !closing {
            bringToFront(activate: activateOnOpen)
        }
    }

    /// Give the keys up until the running dictation has pasted: a key panel
    /// would take its ⌘V (it never activates, so the user's app looks frontmost).
    func holdKey() {
        log("dictation running: window shown without the keys")
        awaitingKey = true
        window.keyAllowed = false
        if window.isKeyWindow {
            // Ordering out hands the keys back to the active app's window.
            window.orderOut(nil)
            window.orderFrontRegardless()
        }
    }

    /// Every 0.25 s: a dictation starting closes the window (unless an entry
    /// is being edited); one finishing hands the keys to a window shown during it.
    /// A recording lasts far longer than that before its paste.
    func watchPipeline() {
        let now = Pipeline.current()
        let change = Pipeline.change(was: pipeline, now: now)
        pipeline = now
        guard !closing else { return }
        switch change {
        case .started:
            log("dictation started")
            if editing == nil { closeAnimated() }
        case .finished:
            log("dictation finished, awaiting keys \(awaitingKey)")
            guard awaitingKey else { return }
            awaitingKey = false
            window.keyAllowed = true
            bringToFront(activate: activateOnOpen)
        case .none:
            break
        }
    }
}

enum HistoryApp {
    static func main(_ args: [String]) -> Int32 {
        // A second launch raises the open window instead of opening another.
        if let pid = readPid(pidFile), pid != getpid(), isAlive(pid),
           processArgs(pid).dropFirst().first == "history" {
            kill(pid, SIGUSR1)
            return 0
        }
        writePid(pidFile)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = HistoryController()
        // Before anything activates us: the focused field is the user's.
        let handed = ProcessInfo.processInfo.environment["XHISPER_PASTE_PID"].flatMap { pid_t($0) }
        controller.pasteTarget = HistoryController.findPasteTarget(pid: handed)
        controller.returnApp = HistoryController.userApp(pid: handed)
        controller.log("open: handed pid \(handed.map(String.init) ?? "none"), paste target \(controller.pasteTarget?.bundleIdentifier ?? "none"), return app \(controller.returnApp?.bundleIdentifier ?? "none")")
        // The pill's launch hands a pid over and comes through `open -g`: no activation.
        controller.activateOnOpen = handed == nil
        app.delegate = controller
        signal(SIGUSR1, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)  // a dying xhisper-learn must not take the window down
        let raise = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        raise.setEventHandler { controller.raise() }
        raise.resume()
        withExtendedLifetime((controller, raise)) { app.run() }
        return 0
    }
}
