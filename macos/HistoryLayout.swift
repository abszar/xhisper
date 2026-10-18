import CoreGraphics
import Foundation

// Pure geometry and timing for the history window (design A8 / A9), kept out
// of AppKit so `make check` can selftest it.

/// A CSS cubic-bezier timing curve: maps elapsed fraction to progress.
struct Curve {
    let x1: Double, y1: Double, x2: Double, y2: Double

    static let out = Curve(x1: 0.16, y1: 1, x2: 0.3, y2: 1)
    static let `in` = Curve(x1: 0.4, y1: 0, x2: 1, y2: 1)
    static let std = Curve(x1: 0.2, y1: 0, x2: 0, y2: 1)
    static let linear = Curve(x1: 0, y1: 0, x2: 1, y2: 1)

    private func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
        // B(u) with P0 = 0, P3 = 1.
        let v = 1 - u
        return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
    }

    /// Progress at time fraction t (clamped to 0...1).
    func callAsFunction(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        // Solve x(u) = t; x is monotonic since x1, x2 are in 0...1.
        var u = t
        for _ in 0..<8 {
            let x = bezier(u, x1, x2) - t
            if abs(x) < 1e-6 { return bezier(u, y1, y2) }
            let v = 1 - u
            let dx = 3 * v * v * x1 + 6 * v * u * (x2 - x1) + 3 * u * u * (1 - x2)
            if abs(dx) < 1e-6 { break }
            u -= x / dx
        }
        // Newton stalled (flat start of the curve): bisect.
        var lo = 0.0, hi = 1.0
        u = t
        for _ in 0..<40 {
            let x = bezier(u, x1, x2)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = u } else { hi = u }
            u = (lo + hi) / 2
        }
        return bezier(u, y1, y2)
    }
}

enum HistoryLayout {
    static let defaultSize = CGSize(width: 440, height: 520)
    static let minSize = CGSize(width: 360, height: 260)
    /// Bottom edge above the Dock, the same as the pill's.
    static let bottomGap: CGFloat = 55
    static let screenMargin: CGFloat = 12
    /// Max height = visible height minus this.
    static let heightReserve: CGFloat = 120
    static let grab: CGFloat = 6

    static func maxSize(visible: CGRect) -> CGSize {
        CGSize(width: visible.width - 2 * screenMargin, height: visible.height - heightReserve)
    }

    /// Clamp to min and max; the minimum wins on a screen too small for it.
    static func clamp(_ size: CGSize, visible: CGRect) -> CGSize {
        let top = maxSize(visible: visible)
        return CGSize(width: max(minSize.width, min(top.width, size.width)).rounded(),
                      height: max(minSize.height, min(top.height, size.height)).rounded())
    }

    /// Where the window opens: centred on the screen, bottom edge where the
    /// pill's is, kept 12 pt inside the visible frame. Screen coordinates (y up).
    static func frame(size: CGSize, visible: CGRect) -> CGRect {
        let s = clamp(size, visible: visible)
        var x = (visible.midX - s.width / 2).rounded()
        var y = visible.minY + bottomGap
        x = max(visible.minX + screenMargin, min(visible.maxX - screenMargin - s.width, x))
        y = max(visible.minY + screenMargin, min(visible.maxY - screenMargin - s.height, y))
        return CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4)
        static let top = Edges(rawValue: 8)
    }

    /// How far a corner's zone runs along each edge: the window radius, so the
    /// corner is grabbable on the card and not only on its clear rounded-off tip.
    static let cornerSpan: CGFloat = 19

    /// The edges whose grab zone holds p (window coordinates, y up). Edge bands
    /// are `grab` deep; corners are L-shaped, `grab` deep and `cornerSpan` long.
    static func edges(at p: CGPoint, in size: CGSize) -> Edges {
        guard p.x >= 0, p.y >= 0, p.x <= size.width, p.y <= size.height else { return [] }
        let nearLeft = p.x < grab, nearRight = p.x > size.width - grab
        let nearBottom = p.y < grab, nearTop = p.y > size.height - grab
        var e: Edges = []
        if nearLeft || nearRight {
            e.insert(nearLeft ? .left : .right)
            if p.y < cornerSpan { e.insert(.bottom) } else if p.y > size.height - cornerSpan { e.insert(.top) }
        }
        if nearBottom || nearTop {
            e.insert(nearBottom ? .bottom : .top)
            if p.x < cornerSpan { e.insert(.left) } else if p.x > size.width - cornerSpan { e.insert(.right) }
        }
        return e
    }

    // MARK: Rows (A9 §2, §4, §8)

    /// Row background (white alpha): 0.04 hover, 0.06 Enter target or editing,
    /// 0.08 Enter target + hover.
    static func rowFill(target: Bool, hovered: Bool) -> CGFloat {
        switch (target, hovered) {
        case (true, true): return 0.08
        case (true, false): return 0.06
        case (false, true): return 0.04
        default: return 0
        }
    }

    /// Lines shown before "Show more": 6 on the Enter-target row, 3 elsewhere.
    static func clampLines(target: Bool) -> Int { target ? 6 : 3 }

    /// The text's height in lines once clamped (0 clamp = expanded).
    static func shownLines(_ lines: Int, clamp: Int) -> Int {
        clamp > 0 ? min(max(1, lines), clamp) : max(1, lines)
    }

    /// Where to cut a clamped entry so it can end in "…" (A9 "Truncation").
    /// A text container truncates only a line whose own paragraph runs on, so
    /// when the last visible line ends at a paragraph break (`visibleEnd`, the
    /// UTF-16 end of that line, newline included) and text follows, the shown
    /// copy is cut before that newline and gets "…". nil: the line wraps
    /// mid-paragraph (the container truncates it) or nothing follows.
    static func paragraphCut(_ utf16: [UInt16], visibleEnd: Int) -> Int? {
        guard visibleEnd > 0, visibleEnd < utf16.count else { return nil }
        let last = utf16[visibleEnd - 1]
        guard last == 0x0A || last == 0x2029 || last == 0x0D else { return nil }
        // A CRLF break: cut before both.
        if last == 0x0A, visibleEnd >= 2, utf16[visibleEnd - 2] == 0x0D { return visibleEnd - 2 }
        return visibleEnd - 1
    }

    /// ↑ / ↓: the Enter target moves by `delta` rows and stops at either end.
    static func moveTarget(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(count - 1, index + delta))
    }

    // MARK: Edit, toasts, live arrival (A3, A4, A7)

    /// The edit field's lines: grows with its text from 2 up to 10, then scrolls.
    static func editorLines(_ lines: Int) -> Int { max(2, min(10, lines)) }

    /// The edit field's height: 18 pt lines, padding 7 above and below, 1 pt border.
    static func editorHeight(lines: Int) -> CGFloat { CGFloat(editorLines(lines)) * 18 + 14 + 2 }

    /// What a change of the history file does to the shown list.
    enum Arrival: Equatable {
        /// Nothing to do.
        case same
        /// `count` new entries go on top; the old rows after the first `keep`
        /// are dropped (the file was trimmed to history-size).
        case insert(count: Int, keep: Int)
        /// Anything else (an edit made elsewhere, a cleared file): rebuild.
        case rebuild
    }

    /// Diff the file (newest first) against the shown entries, matched on time
    /// and text: the normal case is new dictations prepended, with the oldest
    /// trimmed off the end. At least one shown entry must still be there, so a
    /// replaced file rebuilds; an empty list rebuilds too (it shows the empty state).
    static func arrival(shown: [HistoryEntry], file: [HistoryEntry]) -> Arrival {
        if shown == file { return .same }
        guard !shown.isEmpty, !file.isEmpty else { return .rebuild }
        for k in 0..<file.count {
            let keep = file.count - k
            guard keep <= shown.count else { continue }
            // The new entries must really be new (not shown rows moved up).
            if file[k...].elementsEqual(shown[..<keep]), !file[..<k].contains(where: shown.contains) {
                return .insert(count: k, keep: keep)
            }
        }
        return .rebuild
    }

    /// The Enter target after `inserted` rows land on top (keeping `keep` old
    /// rows): it stays on its entry when the user had moved it off the newest
    /// and the entry is still shown, else it goes to the (new) newest.
    static func targetAfterArrival(_ target: Int, inserted: Int, keep: Int) -> Int {
        target > 0 && target < keep ? target + inserted : 0
    }

    /// The "N new" chip's label.
    static func newChipLabel(_ count: Int) -> String { "\(count) new" }

    /// Toast holds in seconds (A9 §7): Saved 1.8, Learned 3.5 (paused while
    /// hovered), Could not save 6 (or until the next action), Unlearned 1.8.
    enum Toast { case saved, learned, failed, unlearned }
    static func toastHold(_ t: Toast) -> Double {
        switch t {
        case .saved, .unlearned: return 1.8
        case .learned: return 3.5
        case .failed: return 6
        }
    }

    /// Every whole-word occurrence of `words` in `text`, as UTF-16 ranges (for
    /// the learned-word highlight). Whole word: no letter or digit on either side.
    static func wordRanges(_ words: [String], in text: String) -> [NSRange] {
        let s = text as NSString
        func isWordUnit(_ i: Int) -> Bool {
            guard i >= 0, i < s.length else { return false }
            let u = s.character(at: i)
            if UTF16.isLeadSurrogate(u) || UTF16.isTrailSurrogate(u) { return true }
            return Unicode.Scalar(u).map { CharacterSet.alphanumerics.contains($0) } ?? false
        }
        var out: [NSRange] = []
        for w in Set(words) where !w.isEmpty {
            var from = 0
            while from < s.length {
                let r = s.range(of: w, options: [.literal], range: NSRange(location: from, length: s.length - from))
                guard r.location != NSNotFound else { break }
                if !isWordUnit(r.location - 1) && !isWordUnit(NSMaxRange(r)) { out.append(r) }
                from = r.location + max(1, r.length)
            }
        }
        return out.sorted { $0.location < $1.location }
    }

    /// The frame after dragging `edges` by (dx, dy) from `start`. The opposite
    /// edges stay put, also when the size hits its min or max.
    static func resize(_ start: CGRect, edges: Edges, dx: CGFloat, dy: CGFloat, visible: CGRect) -> CGRect {
        let top = maxSize(visible: visible)
        func fit(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)).rounded() }
        var r = start
        if edges.contains(.right) {
            r.size.width = fit(start.width + dx, minSize.width, top.width)
        } else if edges.contains(.left) {
            r.size.width = fit(start.width - dx, minSize.width, top.width)
            r.origin.x = start.maxX - r.width
        }
        if edges.contains(.top) {
            r.size.height = fit(start.height + dy, minSize.height, top.height)
        } else if edges.contains(.bottom) {
            r.size.height = fit(start.height - dy, minSize.height, top.height)
            r.origin.y = start.maxY - r.height
        }
        return r
    }
}

/// A dictation running (xhisper.sh, between its hotkey and its paste): the
/// History window must not hold the keys then, or ⌘V lands in the panel.
enum Pipeline {
    /// Past this a pipeline is wedged, not busy (xhisper.sh's own bound is
    /// max-recording-seconds + both timeouts + 60, 480 s by default).
    static let maxAge: Double = 1800

    /// xhisper.pid is "PID EPOCH".
    static func parse(_ s: String) -> (pid: pid_t, epoch: Double?)? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let first = parts.first, let pid = pid_t(first), pid > 0 else { return nil }
        return (pid, parts.dropFirst().first.flatMap { Double($0) })
    }

    /// Same test as xhisper.sh's instance_alive: alive, running something
    /// named xhisper (a reused pid is not), and not wedged.
    static func isLive(alive: Bool, argv: [String], epoch: Double?, now: Double) -> Bool {
        guard alive, argv.contains(where: { $0.contains("xhisper") }) else { return false }
        guard let e = epoch else { return true }
        return now - e < maxAge
    }

    /// The live pipeline's pid, nil when none.
    static func current(_ file: String = Runtime.path("xhisper.pid")) -> pid_t? {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8), let p = parse(s) else { return nil }
        return isLive(alive: isAlive(p.pid), argv: processArgs(p.pid), epoch: p.epoch,
                      now: Date().timeIntervalSince1970) ? p.pid : nil
    }

    enum Change: Equatable { case none, started, finished }

    /// Between two looks: another pid is a new dictation (also when one ended
    /// and the next began in between), no pid after one is the paste done.
    static func change(was: pid_t?, now: pid_t?) -> Change {
        if let n = now, n != was { return .started }
        if now == nil, was != nil { return .finished }
        return .none
    }
}
