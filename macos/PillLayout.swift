import CoreGraphics
import Foundation

// Pure geometry and timing for the status pill (design B1 / B2), kept out of
// AppKit so `make check` can selftest it. Everything is in points, the same
// numbers as the GTK pill's logical pixels (no more 0.8 scaling).

enum PillLayout {
    static let width: CGFloat = 310       // every dictation state, so the pill never resizes
    static let height: CGFloat = 38
    static let padLeft: CGFloat = 16
    static let padRight: CGFloat = 7      // = chip inset: chip radius 12 = 19 - 7, concentric
    static let barCount = 17
    static let barWidth: CGFloat = 4
    static let barGap: CGFloat = 3
    static let barRadius: CGFloat = 2
    static let minBar: CGFloat = 4
    static let maxBar: CGFloat = 24
    static let labelGap: CGFloat = 12     // bars to label
    static let dotWidth: CGFloat = 4
    static let chipHeight: CGFloat = 24
    static let chipPad: CGFloat = 10
    static let hitLead: CGFloat = 6       // hit area starts this far left of the chip
    static let learnedPadLeft: CGFloat = 14
    static let learnedGap: CGFloat = 8    // check to text
    static let learnedChipGap: CGFloat = 14  // text to chip: gap 8 + the chip's 6 (mockup)
    static let learnedMinWidth: CGFloat = 200
    /// Room around the drawing for the two shadows (blur 18, y 6): the panel is
    /// this much bigger on every side, the pill itself does not move.
    static let shadowMargin: CGFloat = 30

    /// 116: 17 bars of 4 with gaps of 3.
    static var barBlockWidth: CGFloat { CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap }
    static func barX(_ i: Int) -> CGFloat { padLeft + CGFloat(i) * (barWidth + barGap) }
    static var labelX: CGFloat { padLeft + barBlockWidth + labelGap }

    static func chipWidth(labelWidth: CGFloat) -> CGFloat { (labelWidth + 2 * chipPad).rounded(.up) }

    /// The chip, right-aligned with the 7 pt inset (pill coordinates, y down).
    static func chipRect(pillWidth: CGFloat, chipWidth: CGFloat) -> CGRect {
        CGRect(x: pillWidth - padRight - chipWidth, y: (height - chipHeight) / 2, width: chipWidth, height: chipHeight)
    }

    /// The only click target: full height, from 6 left of the chip to the pill's end.
    static func hitRect(pillWidth: CGFloat, chip: CGRect) -> CGRect {
        CGRect(x: chip.minX - hitLead, y: 0, width: pillWidth - (chip.minX - hitLead), height: height)
    }

    /// Learned pill: hugs check + text (+ chip), at least 200 wide.
    static func learnedWidth(check: CGFloat, text: CGFloat, chipWidth: CGFloat?) -> CGFloat {
        let lead = learnedPadLeft + (check > 0 ? check + learnedGap : 0) + text
        let tail = chipWidth.map { learnedChipGap + $0 + padRight } ?? learnedPadLeft
        return max(learnedMinWidth, (lead + tail).rounded(.up))
    }

    /// Bar group opacity (design B2, "Bar colour").
    static func barAlpha(_ state: String) -> CGFloat {
        switch state {
        case "transcribing", "editing": return 0.55
        case "silent": return 0.35
        case "cancelled": return 0.30
        default: return 1
        }
    }

    static func labelAlpha(_ state: String) -> CGFloat { state == "cancelled" ? 0.62 : 0.9 }

    /// How long the bars take to reach a state: (heights, opacity and colour).
    static func transitionSeconds(to state: String) -> (heights: Double, alpha: Double) {
        switch state {
        case "transcribing", "editing": return (0.4, 0.24)
        case "error": return (0.24, 0.2)
        case "silent": return (0.24, 0.24)
        case "cancelled": return (0.16, 0.16)
        default: return (0, 0)
        }
    }

    /// The design's holds, used when the caller passes no --timeout.
    static func defaultHoldMs(_ state: String) -> Int? {
        switch state {
        case "silent", "error": return 2400
        case "cancelled": return 900
        case "learned": return 3000
        default: return nil
        }
    }

    /// Seconds until the exit starts, nil = stays until told otherwise. A
    /// caller's --timeout is the whole time on screen, exit included.
    static func closeDelay(state: String, timeoutMs: Int) -> Double? {
        if timeoutMs > 0 { return Double(max(timeoutMs - Int(PillMotion.exitSeconds * 1000), 100)) / 1000 }
        return defaultHoldMs(state).map { Double($0) / 1000 }
    }

    /// Pills that a later stage of their own dictation may update.
    static let updatableStates: Set<String> = ["recording", "transcribing", "editing"]
    /// What such a pill can turn into, in place.
    static let followStates: Set<String> = ["transcribing", "editing", "done", "silent", "error", "cancelled"]

    static func accepts(from: String, to: String) -> Bool {
        updatableStates.contains(from) && followStates.contains(to)
    }
}

enum PillMotion {
    static let entrySlide: CGFloat = 60, entrySeconds = 0.36, entryFadeSeconds = 0.24
    static let exitSlide: CGFloat = 16, exitSeconds = 0.32
    static let launchRise: CGFloat = 24, launchSeconds = 0.28  // pill-to-window (A8)
    static let labelSeconds = 0.18
    static let labelLift: CGFloat = 4
    static let chipHoverSeconds = 0.08
    static let wavePeriod = 1.6, waveLength = 10.0  // bars per wave
    static let waveMid: CGFloat = 12, waveAmp: CGFloat = 4  // 8...16
    static let dotPeriod = 1.2, dotStep = 0.2

    /// Window offset (points down from rest) and opacity.
    typealias Pose = (offset: CGFloat, alpha: CGFloat)

    static func entry(_ elapsed: Double, reduceMotion: Bool) -> Pose {
        let slide = reduceMotion ? 0 : entrySlide * CGFloat(1 - Curve.out(elapsed / entrySeconds))
        return (slide, CGFloat(Curve.out(elapsed / entryFadeSeconds)))
    }

    /// Down 16 and out, from wherever the pill was (it may still be arriving).
    static func exit(_ elapsed: Double, from: Pose, reduceMotion: Bool) -> Pose {
        let p = CGFloat(Curve.in(elapsed / exitSeconds))
        return (from.offset + (reduceMotion ? 0 : exitSlide * p), from.alpha * (1 - p))
    }

    /// Up 24 and out, toward the history window opening over it.
    static func launch(_ elapsed: Double, from: Pose, reduceMotion: Bool) -> Pose {
        let p = CGFloat(Curve.std(elapsed / launchSeconds))
        return (from.offset - (reduceMotion ? 0 : launchRise * p), from.alpha * (1 - p))
    }

    /// Dot k's opacity: 0.25 -> 1 -> 0.25 every 1.2 s, each dot 200 ms behind
    /// the one before, so the pulse runs left to right.
    static func dotAlpha(_ k: Int, _ t: Double) -> CGFloat {
        let phase = (t - Double(k) * dotStep) / dotPeriod
        return CGFloat(0.25 + 0.75 * (0.5 - 0.5 * cos(2 * Double.pi * phase)))
    }

    /// Slow wave while working: a sine across the bars, 8...16 tall, drifting
    /// left like the live levels did.
    static func slowWave(_ i: Int, _ t: Double) -> CGFloat {
        waveMid + waveAmp * CGFloat(sin(2 * Double.pi * (t / wavePeriod + Double(i) / waveLength)))
    }

    /// Failed: a still, low ridge 4...8 (period 8 bars).
    static func ridge(_ i: Int) -> CGFloat { 8 - CGFloat(abs(i % 8 - 4)) }

    /// Live level to bar height: newest level enters on the right; the centre
    /// is a little taller.
    static func liveHeight(level: Double, bar i: Int) -> CGFloat {
        let n = CGFloat(PillLayout.barCount)
        let weight = 0.75 + 0.25 * sin(.pi * (CGFloat(i) + 0.5) / n)
        return max(CGFloat(level) * weight * PillLayout.maxBar, PillLayout.minBar)
    }

    private static let idleShape: [CGFloat] = [0.30, 0.85, 0.30, 0.90, 0.55, 0.80, 0.95, 0.35,
                                               0.60, 0.95, 0.80, 0.25, 0.85, 0.90, 0.55, 0.30, 0.50]

    /// Recording before the first audio arrives (a few tens of ms).
    static func idleHeight(_ i: Int, _ t: Double) -> CGFloat {
        let f = 0.7 + 0.3 * sin(t * 5 + Double(i) * 0.45)
        return max(idleShape[i % idleShape.count] * PillLayout.maxBar * CGFloat(f), PillLayout.minBar)
    }

    /// Resting bar height for the states that do not move.
    static func stillHeight(_ state: String, _ i: Int) -> CGFloat? {
        switch state {
        case "silent": return 3
        case "error": return ridge(i)
        case "cancelled": return PillLayout.minBar  // 4 x 4 at radius 2: a dot
        default: return nil
        }
    }
}

/// One eased value over time (time in seconds, any clock).
struct PillTween {
    var from: Double, to: Double, start: Double, duration: Double
    var curve: Curve = .std

    init(_ value: Double) { from = value; to = value; start = 0; duration = 0 }
    init(from: Double, to: Double, start: Double, duration: Double, curve: Curve = .std) {
        self.from = from; self.to = to; self.start = start; self.duration = duration; self.curve = curve
    }

    func value(at t: Double) -> Double {
        guard duration > 0 else { return to }
        return from + (to - from) * curve((t - start) / duration)
    }

    /// A new tween from wherever this one is now.
    func retarget(_ to: Double, at t: Double, duration: Double, curve: Curve = .std) -> PillTween {
        PillTween(from: value(at: t), to: to, start: t, duration: duration, curve: curve)
    }
}

/// The SIGUSR1 hand-off: "STATE" or "STATE TIMEOUT_MS" in xhisper-notify.next;
/// for the final states the pill answers "STATE 1|0" in xhisper-notify.ack so
/// the sender can show its own pill when the one on screen cannot take it.
enum PillHandoff {
    static let ackedStates: Set<String> = ["silent", "error", "cancelled"]

    static func encode(state: String, timeoutMs: Int) -> String {
        timeoutMs > 0 ? "\(state) \(timeoutMs)" : state
    }

    static func decode(_ s: String) -> (state: String, timeoutMs: Int)? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard let state = parts.first, !state.isEmpty else { return nil }
        return (state, parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    }

    static func ack(state: String, accepted: Bool) -> String { "\(state) \(accepted ? 1 : 0)" }

    /// nil until the pill has answered for this state.
    static func accepted(_ ack: String, for state: String) -> Bool? {
        let parts = ack.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count == 2, parts[0] == Substring(state) else { return nil }
        return parts[1] == "1"
    }
}

/// "Learned: a, b" -> ("Learned", ["a", "b"]); the words are drawn semibold.
func splitNotice(_ label: String) -> (prefix: String, words: [String]) {
    guard let r = label.range(of: ": ") else { return (label, []) }
    let words = label[r.upperBound...].components(separatedBy: ", ").filter { !$0.isEmpty }
    return (String(label[..<r.lowerBound]), words)
}
