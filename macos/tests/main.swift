import Foundation

// Selftest for the pure-logic Swift files (no AppKit). Run: make check
var failures = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) (tests/main.swift:\(line))") }
}

// --- Runtime ---
let tmpRoot = NSTemporaryDirectory() + "xhisper-selftest-\(getpid())"
setenv("XHISPER_RUNTIME_DIR", tmpRoot, 1)
check(Runtime.dir == tmpRoot, "runtime dir honours XHISPER_RUNTIME_DIR")
var st = stat()
check(stat(tmpRoot, &st) == 0 && (st.st_mode & 0o777) == 0o700, "runtime dir is 0700")
check(Runtime.path("x.pid") == tmpRoot + "/x.pid", "runtime path join")
check(Runtime.darwinUserTempDir().hasSuffix("/T/"), "DARWIN_USER_TEMP_DIR found")
writePid(Runtime.path("t.pid"))
check(readPid(Runtime.path("t.pid")) == getpid(), "pid file round trip")
try? "123 1791800000\n".write(toFile: Runtime.path("u.pid"), atomically: true, encoding: .utf8)
check(readPid(Runtime.path("u.pid")) == 123, "pid file with epoch (xhisper.pid format)")
check(readPid(Runtime.path("missing.pid")) == nil, "missing pid file")
check(isAlive(getpid()), "self is alive")
check(!isAlive(99999), "unused pid is not alive")
if let t = startTime(getpid()) { check(t <= Date().timeIntervalSince1970 && t > 1_700_000_000, "start time plausible") } else { check(false, "start time readable") }
check(processArgs(getpid()).first.map { $0.hasSuffix("selftest") } ?? false, "own argv[0] via KERN_PROCARGS2")
check(userProcessIDs().contains(getpid()), "process scan sees self")
check(spawnDetached(["/usr/bin/true"]) != nil, "spawn detached")
appendLine(Runtime.path("log.txt"), "hello")
check((try? String(contentsOfFile: Runtime.path("log.txt"), encoding: .utf8))?.hasSuffix("hello\n") ?? false, "append log line")
let mixed = "h\u{e9}llo \u{1F44B} w\u{f6}rld"  // héllo 👋 wörld
check(scalarOffset(mixed, utf16: 8) == 7, "caret after emoji: utf16 8 -> scalar 7")
check(scalarOffset(mixed, utf16: 999) == mixed.unicodeScalars.count, "caret clamped to end")
check(scalarOffset(mixed, utf16: -1) == -1, "no caret stays -1")
let twoLines = Array("first line.\n".utf16)
check(webCaretOnEmptyLastLine(11, selection: 0, utf16: twoLines, isWeb: true) == 12, "web: empty last line reported before its newline")
check(webCaretOnEmptyLastLine(11, selection: 0, utf16: twoLines, isWeb: false) == 11, "native fields are trusted")
check(webCaretOnEmptyLastLine(5, selection: 0, utf16: twoLines, isWeb: true) == 5, "web: caret inside the text unchanged")
check(webCaretOnEmptyLastLine(11, selection: 2, utf16: twoLines, isWeb: true) == 11, "web: a selection is left alone")
let oneLine = Array("finished?".utf16)
check(webCaretOnEmptyLastLine(9, selection: 0, utf16: oneLine, isWeb: true) == 9, "web: caret at the end of plain text unchanged")

// --- LevelMeter ---
check(abs((rmsDB(Data(count: 3200)) ?? 0) - (-90.309)) < 0.01, "silence is -90.3 dBFS")
var half = Data(); for _ in 0..<1600 { var s = Int16(16384).littleEndian; half.append(Data(bytes: &s, count: 2)) }
check(abs((rmsDB(half) ?? 0) - (-6.0206)) < 0.01, "half scale is -6 dBFS")
check(rmsDB(Data()) == nil, "no samples, no level")
var meter = LevelMeter(bars: 17)
for _ in 0..<30 { meter.push(db: -60) }
check(meter.levels.allSatisfy { $0 < 0.01 }, "room noise stays flat")
for _ in 0..<5 { meter.push(db: -20) }
check(meter.level > 0.5, "speech fills the pill")
for _ in 0..<40 { meter.push(db: -60) }
check(meter.level < 0.1, "pause settles")
check(meter.levels.count == 17, "bar count fixed")
let wav = NSTemporaryDirectory() + "xhisper-selftest-\(getpid()).wav"
FileManager.default.createFile(atPath: wav, contents: Data(count: 44 + 3200))
check(abs((readTailDB(path: wav) ?? 0) - (-90.309)) < 0.01, "reads the WAV tail")
FileManager.default.createFile(atPath: wav, contents: Data(count: 100))
check(readTailDB(path: wav) == nil, "too short a WAV gives no level yet")
check(readTailDB(path: wav + ".missing") == nil, "missing WAV gives no level")
try? FileManager.default.removeItem(atPath: wav)

// --- HistoryStore ---
var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
let noon = ISO8601DateFormatter().date(from: "2026-10-12T18:00:00Z")!
// noon = Monday 2026-10-12 18:00 UTC. Time labels (design A9 section 8, "Times").
func label(_ stamp: String) -> String { HistoryStore.describe(stamp, now: noon, calendar: utc) }
check(label("2026-10-12T17:59:30+0000") == "Just now", "30 s ago is Just now")
check(label("2026-10-12T17:59:01+0000") == "Just now", "59 s ago is Just now")
check(label("2026-10-12T17:59:00+0000") == "1 min ago", "60 s ago is 1 min ago")
check(label("2026-10-12T17:01:00+0000") == "59 min ago", "59 min ago")
check(label("2026-10-12T17:00:00+0000") == "1 h ago", "60 min ago is 1 h ago")
check(label("2026-10-12T12:01:00+0000") == "5 h ago", "5 h 59 min ago is 5 h ago")
check(label("2026-10-12T12:00:00+0000") == "Today 12:00", "6 h ago, same day, is Today")
check(label("2026-10-12T00:05:00+0000") == "Today 00:05", "earlier today")
check(label("2026-10-11T23:59:00+0000") == "Yesterday 23:59", "previous day is Yesterday")
check(label("2026-10-11T09:00:00+0000") == "Yesterday 09:00", "yesterday label")
check(label("2026-10-10T09:00:00+0000") == "Sat 09:00", "2 days ago is a weekday")
check(label("2026-10-06T18:00:00+0000") == "Tue 18:00", "6 days ago is a weekday")
check(label("2026-10-05T18:01:00+0000") == "Mon 18:01", "just under 7 days is a weekday")
check(label("2026-10-05T18:00:00+0000") == "05 Oct 18:00", "7 days ago is a date")
check(label("2026-10-01T08:05:00+0000") == "01 Oct 08:05", "older label")
check(label("2025-12-24T09:30:00+0000") == "24 Dec 09:30", "much older label")
check(label("2026-10-12T18:00:30+0000") == "Just now", "stamp slightly in the future is Just now")
check(label("2026-11-01T09:00:00+0000") == "Just now", "stamp far in the future is Just now")
check(label("garbage") == "garbage", "bad stamp shown as is")
check(label("") == "", "empty stamp shown as is")
// Midnight crossing: 1 h ago but on the previous day stays "1 h ago" (relative rules win under 6 h).
check(HistoryStore.describe("2026-10-11T23:30:00+0000", now: ISO8601DateFormatter().date(from: "2026-10-12T00:30:00Z")!, calendar: utc) == "1 h ago", "relative wins across midnight")

// List display lines (design A9 section 8, "Lists").
func lines(_ t: String) -> [String] { HistoryStore.displayLines(t).map { ($0.bullet ?? "~") + "|" + $0.text } }
check(lines("hello world") == ["~|hello world"], "plain line has no bullet")
check(lines("- one\n* two\n\u{2022} three") == ["\u{2022}|one", "\u{2022}|two", "\u{2022}|three"], "dash, star and bullet markers")
check(lines("1. first\n2. second\n10. tenth") == ["1.|first", "2.|second", "10.|tenth"], "numbered lines keep their number")
check(lines("-nope\n*also\n1.no space\n2024 was good") == ["~|-nope", "~|*also", "~|1.no space", "~|2024 was good"], "markers without a space stay plain")
check(lines("intro:\n- a\n- b\noutro") == ["~|intro:", "\u{2022}|a", "\u{2022}|b", "~|outro"], "mixed lines")
check(lines("a\n\nb") == ["~|a", "~|", "~|b"], "blank lines are kept")
check(lines("- ") == ["\u{2022}|"], "empty bullet item")
check(lines("  - indented") == ["~|  - indented"], "indented marker stays plain")
check(HistoryStore.displayLines("").count == 1, "empty text is one empty line")
check(HistoryStore.defaultPath(env: ["XHISPER_HISTORY_FILE": "/x/h.jsonl"]) == "/x/h.jsonl", "history path from env")
check(HistoryStore.defaultPath(env: ["XDG_STATE_HOME": "/s"]) == "/s/xhisper/history.jsonl", "history path from XDG_STATE_HOME")
let hist = NSTemporaryDirectory() + "xhisper-selftest-\(getpid()).jsonl"
check(HistoryStore.load(hist).isEmpty, "missing history file is empty")
let lines = ["{\"time\":\"t1\",\"text\":\"first one\"}", "not json", "{\"time\":\"t2\",\"text\":\"\"}", "{\"time\":\"t3\",\"text\":\"third\"}", ""]
try? lines.joined(separator: "\n").write(toFile: hist, atomically: true, encoding: .utf8)
let loaded = HistoryStore.load(hist)
check(loaded == [HistoryEntry(time: "t3", text: "third"), HistoryEntry(time: "t1", text: "first one")], "load: newest first, bad lines skipped")
check(HistoryStore.update(hist, entry: loaded[1], newText: "fixed \"quoted\" é/x"), "update an entry")
let after = (try? String(contentsOfFile: hist, encoding: .utf8)) ?? ""
check(after.contains("not json\n"), "other lines kept verbatim")
check(HistoryStore.load(hist).last == HistoryEntry(time: "t1", text: "fixed \"quoted\" é/x"), "updated text round-trips")
var hs = stat(); stat(hist, &hs)
check((hs.st_mode & 0o777) == 0o600, "history stays 0600")
check(!FileManager.default.fileExists(atPath: hist + ".tmp"), "no temp file left")
check(!HistoryStore.update(hist, entry: HistoryEntry(time: "nope", text: "x"), newText: "y"), "unknown entry not updated")
try? FileManager.default.removeItem(atPath: hist)

// --- ComboDetector (Option then Control) ---
var combo = ComboDetector()
check(!combo.flagsChanged(keycode: 58, option: true, control: false, command: false, shift: false), "Option alone: nothing")
check(combo.flagsChanged(keycode: 59, option: true, control: true, command: false, shift: false), "Option then left Control: fire")
check(!combo.flagsChanged(keycode: 62, option: true, control: true, command: false, shift: false), "second Control while held: no refire")
check(!combo.flagsChanged(keycode: 62, option: true, control: true, command: false, shift: false), "right Control up, left still held")
check(!combo.flagsChanged(keycode: 59, option: true, control: false, command: false, shift: false), "Control up: nothing")
check(combo.flagsChanged(keycode: 62, option: true, control: true, command: false, shift: false), "re-armed: right Control fires")
check(!combo.flagsChanged(keycode: 62, option: true, control: false, command: false, shift: false), "release")
var reverse = ComboDetector()
check(!reverse.flagsChanged(keycode: 59, option: false, control: true, command: false, shift: false), "Control first: nothing")
check(!reverse.flagsChanged(keycode: 58, option: true, control: true, command: false, shift: false), "then Option: still nothing")
var withCmd = ComboDetector()
check(!withCmd.flagsChanged(keycode: 59, option: true, control: true, command: true, shift: false), "Command held: nothing")
var withShift = ComboDetector()
check(!withShift.flagsChanged(keycode: 59, option: true, control: true, command: false, shift: true), "Shift held: nothing")
var resync = ComboDetector()
check(resync.flagsChanged(keycode: 59, option: true, control: true, command: false, shift: false), "fire")
check(!resync.flagsChanged(keycode: 58, option: false, control: false, command: false, shift: false), "missed Control-up, all modifiers gone")
check(resync.flagsChanged(keycode: 59, option: true, control: true, command: false, shift: false), "resynced: fires again")
// --- DoubleTap (Option+Control twice opens History) ---
var dt = DoubleTap()
check(!dt.comboFired(at: 10.0, recordingLive: false), "first tap starts a recording")
check(dt.comboFired(at: 10.4, recordingLive: true), "second tap within 0.5 s: History")
check(!dt.comboFired(at: 10.6, recordingLive: false), "third tap: a fresh first tap")
var slow = DoubleTap()
check(!slow.comboFired(at: 10.0, recordingLive: false), "first tap")
check(!slow.comboFired(at: 10.7, recordingLive: true), "second tap after 0.5 s: a normal stop")
var stopThenStart = DoubleTap()
check(!stopThenStart.comboFired(at: 20.0, recordingLive: true), "a tap that stops a recording")
check(!stopThenStart.comboFired(at: 20.3, recordingLive: false), "quick start after a stop records, no History")
// --- isListener (Escape is only swallowed for a live key loop) ---
check(isListener(["/usr/bin/python3", "-"]), "python3 key loop")
check(isListener(["/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"]), "system python's real binary")
check(!isListener(["/usr/bin/vim"]), "recycled pid running something else")
check(!isListener([]), "unreadable argv")

// --- escapeAction (Escape only eaten while a key loop is live) ---
let fresh = escapeAction(keyDown: true, autorepeat: false, swallowing: false, listening: true)
check(fresh.swallow && fresh.writeCancel && fresh.swallowingAfter, "fresh press while listening: eat, write cancel")
let rep = escapeAction(keyDown: true, autorepeat: true, swallowing: true, listening: false)
check(rep.swallow && !rep.writeCancel && rep.swallowingAfter, "repeat while swallowing: eat, no second cancel")
let stale = escapeAction(keyDown: true, autorepeat: false, swallowing: true, listening: false)
check(!stale.swallow && !stale.writeCancel && !stale.swallowingAfter, "press not listening after stale flag: pass through")
let idle = escapeAction(keyDown: true, autorepeat: false, swallowing: false, listening: false)
check(!idle.swallow && !idle.writeCancel && !idle.swallowingAfter, "press while idle: pass through")
let strayRepeat = escapeAction(keyDown: true, autorepeat: true, swallowing: false, listening: false)
check(!strayRepeat.swallow && !strayRepeat.writeCancel, "repeat without swallowing: pass through")
let up = escapeAction(keyDown: false, autorepeat: false, swallowing: true, listening: false)
check(up.swallow && !up.writeCancel && !up.swallowingAfter, "key-up while swallowing: eat and clear")
let upIdle = escapeAction(keyDown: false, autorepeat: false, swallowing: false, listening: true)
check(!upIdle.swallow && !upIdle.writeCancel && !upIdle.swallowingAfter, "key-up of a passed press: pass through")

// --- HoldTracker (tap = toggle, hold = push-to-talk) ---
var tap = HoldTracker()
tap.comboFired(at: 10.0, recordingLive: false)
check(!tap.controlChanged(down: false, at: 10.2), "quick tap: recording keeps going (toggle)")
var hold = HoldTracker()
hold.comboFired(at: 10.0, recordingLive: false)
check(!hold.controlChanged(down: true, at: 10.1), "other Control down while held: nothing yet")
check(hold.controlChanged(down: false, at: 11.5), "held 1.5 s then released: stop (push-to-talk)")
check(!hold.controlChanged(down: false, at: 12.0), "a second release does not stop again")
var stopPress = HoldTracker()
stopPress.comboFired(at: 10.0, recordingLive: true)
check(!stopPress.controlChanged(down: false, at: 12.0), "the press that stops a recording is never a hold")
var edge = HoldTracker()
edge.comboFired(at: 10.0, recordingLive: false)
check(edge.controlChanged(down: false, at: 10.0 + HoldTracker.holdSeconds), "exactly the threshold counts as a hold")
var noCombo = HoldTracker()
check(!noCombo.controlChanged(down: false, at: 5.0), "release without a fired combo: nothing")

// --- Curve (design A8 timing curves) ---
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-3) -> Bool { abs(a - b) < eps }
check(Curve.out(0) == 0 && Curve.out(1) == 1 && Curve.in(-1) == 0 && Curve.std(2) == 1, "curves pinned at 0 and 1, clamped outside")
check(near(Curve.linear(0.37), 0.37), "linear curve is the identity")
check(Curve.out(0.25) > 0.6, "out: fast start")
check(Curve.in(0.25) < 0.1, "in: slow start")
check(near(Curve.std(0.5), 0.878), "std at half time = 0.878 (bisection reference)")
check(near(Curve.out(0.25), 0.826), "out at a quarter = 0.826 (bisection reference)")
var monotonic = true
var prevY = 0.0
for i in 1...100 { let y = Curve.out(Double(i) / 100); if y < prevY - 1e-9 { monotonic = false }; prevY = y }
check(monotonic, "out curve never goes backwards")

// --- HistoryLayout (window size, position, edge resize) ---
let screenVisible = CGRect(x: 0, y: 80, width: 1512, height: 862)  // above a Dock
let opened = HistoryLayout.frame(size: HistoryLayout.defaultSize, visible: screenVisible)
check(opened == CGRect(x: 536, y: 135, width: 440, height: 520), "opens centred, bottom 55 above the Dock")
check(HistoryLayout.clamp(CGSize(width: 100, height: 100), visible: screenVisible) == HistoryLayout.minSize, "min size 360x260")
check(HistoryLayout.clamp(CGSize(width: 440, height: 2000), visible: screenVisible).height == 742, "max height = visible - 120")
let small = CGRect(x: 0, y: 0, width: 800, height: 400)
let tall = HistoryLayout.frame(size: CGSize(width: 440, height: 520), visible: small)
check(tall.height == 280 && tall.maxY <= small.maxY - 12 && tall.minY >= 12, "small screen: clamped 12 inside")
let offset = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
check(HistoryLayout.frame(size: HistoryLayout.defaultSize, visible: offset).midX == -960, "second screen left of the main one")
let win = CGSize(width: 440, height: 520)
check(HistoryLayout.edges(at: CGPoint(x: 2, y: 200), in: win) == .left, "left edge zone")
check(HistoryLayout.edges(at: CGPoint(x: 437, y: 517), in: win) == [.right, .top], "top-right corner")
check(HistoryLayout.edges(at: CGPoint(x: 6, y: 6), in: win) == [], "6 pt inside is content")
check(HistoryLayout.edges(at: CGPoint(x: -1, y: 3), in: win) == [], "outside the window")
check(HistoryLayout.edges(at: CGPoint(x: 15, y: 2), in: win) == [.left, .bottom], "bottom-left corner: along the bottom edge, inside 19")
check(HistoryLayout.edges(at: CGPoint(x: 2, y: 15), in: win) == [.left, .bottom], "bottom-left corner: along the left edge, inside 19")
check(HistoryLayout.edges(at: CGPoint(x: 437, y: 505), in: win) == [.right, .top], "top-right corner: L arm on the right edge")
check(HistoryLayout.edges(at: CGPoint(x: 425, y: 2), in: win) == [.right, .bottom], "bottom-right corner: L arm on the bottom edge")
check(HistoryLayout.edges(at: CGPoint(x: 2, y: 20), in: win) == .left, "past 19 along the edge: plain left")
check(HistoryLayout.edges(at: CGPoint(x: 25, y: 518), in: win) == .top, "past 19 along the top: plain top")
check(HistoryLayout.edges(at: CGPoint(x: 15, y: 15), in: win) == [], "inside the L (6 deep) is content")
let start = CGRect(x: 536, y: 135, width: 440, height: 520)
check(HistoryLayout.resize(start, edges: .right, dx: 30, dy: 99, visible: screenVisible) == CGRect(x: 536, y: 135, width: 470, height: 520), "right edge widens, height kept")
check(HistoryLayout.resize(start, edges: .left, dx: 200, dy: 0, visible: screenVisible) == CGRect(x: 616, y: 135, width: 360, height: 520), "left edge stops at min, right edge fixed")
check(HistoryLayout.resize(start, edges: .bottom, dx: 0, dy: -50, visible: screenVisible) == CGRect(x: 536, y: 85, width: 440, height: 570), "bottom edge grows down, top fixed")
check(HistoryLayout.resize(start, edges: .top, dx: 0, dy: 1000, visible: screenVisible).height == 742, "top edge stops at max height")

// --- History rows (design A9 §2, §4, §8) ---
check(HistoryLayout.rowFill(target: false, hovered: false) == 0, "row at rest: no fill")
check(HistoryLayout.rowFill(target: false, hovered: true) == 0.04, "row hover: white 0.04")
check(HistoryLayout.rowFill(target: true, hovered: false) == 0.06, "Enter-target row: white 0.06")
check(HistoryLayout.rowFill(target: true, hovered: true) == 0.08, "Enter target + hover: white 0.08")
check(HistoryLayout.clampLines(target: true) == 6 && HistoryLayout.clampLines(target: false) == 3, "clamp 6 on the target row, 3 elsewhere")
check(HistoryLayout.shownLines(10, clamp: 3) == 3, "long text clamped")
check(HistoryLayout.shownLines(2, clamp: 6) == 2, "short text keeps its lines")
check(HistoryLayout.shownLines(10, clamp: 0) == 10, "expanded shows every line")
check(HistoryLayout.shownLines(0, clamp: 3) == 1, "empty text still one line")
check(HistoryLayout.moveTarget(0, by: -1, count: 5) == 0, "up from the newest stays")
check(HistoryLayout.moveTarget(0, by: 1, count: 5) == 1, "down moves to the next row")
check(HistoryLayout.moveTarget(4, by: 1, count: 5) == 4, "down from the last stays")
check(HistoryLayout.moveTarget(3, by: 0, count: 0) == 0, "no rows: target 0")
check(HistoryLayout.moveTarget(7, by: -1, count: 3) == 2, "target past the end is pulled back")
let fourLines = Array("aaa\nbbb\nccc\nddd".utf16)
check(HistoryLayout.paragraphCut(fourLines, visibleEnd: 12) == 11, "clamp ends at a paragraph break: cut before the newline")
check(HistoryLayout.paragraphCut(fourLines, visibleEnd: 10) == nil, "clamp ends mid-paragraph: the container truncates")
check(HistoryLayout.paragraphCut(fourLines, visibleEnd: 15) == nil, "nothing hidden after the last line")
check(HistoryLayout.paragraphCut(Array("\nb".utf16), visibleEnd: 1) == 0, "empty first line: cut at 0")
check(HistoryLayout.paragraphCut(Array("a\r\nb".utf16), visibleEnd: 3) == 1, "CRLF break: cut before both")
check(HistoryLayout.paragraphCut(fourLines, visibleEnd: 0) == nil, "no visible text: no cut")
// Edit field, live arrival, learned-word highlight (A3, A7, A4)
check(HistoryLayout.editorLines(1) == 2 && HistoryLayout.editorLines(5) == 5 && HistoryLayout.editorLines(14) == 10,
      "edit field: 2 to 10 lines")
check(HistoryLayout.editorHeight(lines: 3) == 70, "edit field: 3 lines = 54 + padding 14 + border 2")
let ea = HistoryEntry(time: "t1", text: "a"), eb = HistoryEntry(time: "t2", text: "b"), ec = HistoryEntry(time: "t3", text: "c")
let ed = HistoryEntry(time: "t4", text: "d"), ee = HistoryEntry(time: "t5", text: "e")
check(HistoryLayout.arrival(shown: [ec, eb, ea], file: [ec, eb, ea]) == .same, "arrival: unchanged file")
check(HistoryLayout.arrival(shown: [ec, eb, ea], file: [ed, ec, eb, ea]) == .insert(count: 1, keep: 3), "arrival: one new on top")
check(HistoryLayout.arrival(shown: [ec, eb, ea], file: [ee, ed, ec, eb, ea]) == .insert(count: 2, keep: 3), "arrival: two new on top")
check(HistoryLayout.arrival(shown: [ec, eb, ea], file: [ed, ec, eb]) == .insert(count: 1, keep: 2), "arrival: new on top, oldest trimmed")
check(HistoryLayout.arrival(shown: [ec, eb, ea], file: [ec, eb]) == .insert(count: 0, keep: 2), "arrival: trimmed only")
check(HistoryLayout.arrival(shown: [ec, eb, ea], file: [ec, HistoryEntry(time: "t2", text: "B"), ea]) == .rebuild,
      "arrival: an entry edited elsewhere rebuilds")
check(HistoryLayout.arrival(shown: [ec, eb, ea], file: [ee, ed]) == .rebuild, "arrival: nothing shown survives: rebuild")
check(HistoryLayout.arrival(shown: [], file: [ea]) == .rebuild, "arrival: from the empty state: rebuild")
check(HistoryLayout.arrival(shown: [ea], file: []) == .rebuild, "arrival: file cleared: rebuild")
check(HistoryLayout.arrival(shown: [eb, ea], file: [ea, eb]) == .rebuild, "arrival: reordered: rebuild")
check(HistoryLayout.targetAfterArrival(0, inserted: 2, keep: 5) == 0, "target on the newest follows the new newest")
check(HistoryLayout.targetAfterArrival(3, inserted: 2, keep: 5) == 5, "moved target stays on its entry")
check(HistoryLayout.targetAfterArrival(4, inserted: 1, keep: 4) == 0, "moved target dropped: back to the newest")
check(HistoryLayout.newChipLabel(1) == "1 new" && HistoryLayout.newChipLabel(3) == "3 new", "new chip label")
check(HistoryLayout.toastHold(.saved) == 1.8 && HistoryLayout.toastHold(.learned) == 3.5
      && HistoryLayout.toastHold(.failed) == 6 && HistoryLayout.toastHold(.unlearned) == 1.8, "toast holds")
let hlText = "Kubernetes and kubernetes, Kubernetes-ready; notKubernetes Kubernetes2 Kubernetes."
check(HistoryLayout.wordRanges(["Kubernetes"], in: hlText).map { $0.location } == [0, 27, 71],
      "learned word: whole-word, case-sensitive matches")
check(HistoryLayout.wordRanges(["Sara", "Sara", ""], in: "Sara met Sara").count == 2, "learned word: duplicates and empty ignored")
check(HistoryLayout.wordRanges(["café"], in: "\u{1F44B} café!") == [NSRange(location: 3, length: 4)], "learned word: UTF-16 offsets after an emoji")
check(HistoryStore.isRightToLeft("سأرسل لك التقرير"), "Arabic reads right to left")
check(HistoryStore.isRightToLeft("שלום"), "Hebrew reads right to left")
check(!HistoryStore.isRightToLeft("Thanks, that works"), "English reads left to right")
check(HistoryStore.isRightToLeft("12. \u{2022} سأرسل"), "digits and bullets are weak: first strong is Arabic")
check(!HistoryStore.isRightToLeft("OK سأرسل"), "first strong character decides (Latin)")
check(!HistoryStore.isRightToLeft("123 ..."), "no strong character: left to right")

// --- Pipeline (History window vs a running dictation) ---
check(Pipeline.parse("4242 1791800000\n")! == (4242, 1791800000) && Pipeline.parse("17")! == (17, nil)
      && Pipeline.parse("") == nil && Pipeline.parse("x 1") == nil, "xhisper.pid parse")
let xargv = ["/bin/bash", "/usr/local/bin/xhisper", "--toggle"]
check(Pipeline.isLive(alive: true, argv: xargv, epoch: 1000, now: 1010), "a running xhisper is live")
check(!Pipeline.isLive(alive: false, argv: xargv, epoch: 1000, now: 1010), "a dead pid is not")
check(!Pipeline.isLive(alive: true, argv: ["/usr/bin/vim"], epoch: 1000, now: 1010), "a reused pid is not")
check(!Pipeline.isLive(alive: true, argv: [], epoch: nil, now: 0), "unreadable argv is not")
check(!Pipeline.isLive(alive: true, argv: xargv, epoch: 1000, now: 1000 + Pipeline.maxAge), "a wedged one is not")
check(Pipeline.isLive(alive: true, argv: xargv, epoch: nil, now: 0), "no epoch: alive decides")
try? "99999 1\n".write(toFile: Runtime.path("xhisper.pid"), atomically: true, encoding: .utf8)
check(Pipeline.current() == nil, "stale xhisper.pid: no pipeline")
check(Pipeline.current(Runtime.path("missing.pid")) == nil, "no xhisper.pid: no pipeline")
check(Pipeline.change(was: nil, now: 5) == .started && Pipeline.change(was: 5, now: 6) == .started,
      "a new pid is a new dictation")
check(Pipeline.change(was: 5, now: nil) == .finished, "pid gone: pipeline finished")
check(Pipeline.change(was: 5, now: 5) == .none && Pipeline.change(was: nil, now: nil) == .none, "no change")

// --- PillLayout / PillMotion (design B1 / B2, points) ---
check(PillLayout.barBlockWidth == 116, "bar block: 17 x 4 with gaps of 3 = 116")
check(PillLayout.barX(0) == 16 && PillLayout.barX(16) == 128, "bars start at the 16 pt padding")
check(PillLayout.labelX == 144, "label 12 after the bars")
let pillChip = PillLayout.chipRect(pillWidth: 310, chipWidth: PillLayout.chipWidth(labelWidth: 39.4))
check(pillChip == CGRect(x: 243, y: 7, width: 60, height: 24), "chip: padding 10, 24 tall, inset 7 (radius 12 concentric)")
check(PillLayout.hitRect(pillWidth: 310, chip: pillChip) == CGRect(x: 237, y: 0, width: 73, height: 38),
      "hit area: full height, 6 left of the chip to the pill's end")
check(PillLayout.learnedWidth(check: 12, text: 20, chipWidth: nil) == 200, "learned pill: at least 200 wide")
check(PillLayout.learnedWidth(check: 12, text: 120, chipWidth: 62) == 14 + 12 + 8 + 120 + 14 + 62 + 7, "learned pill hugs check, text and chip")
check(PillLayout.barAlpha("recording") == 1 && PillLayout.barAlpha("transcribing") == 0.55 && PillLayout.barAlpha("editing") == 0.55
      && PillLayout.barAlpha("silent") == 0.35 && PillLayout.barAlpha("cancelled") == 0.30 && PillLayout.barAlpha("error") == 1,
      "bar group opacity per state")
check(PillLayout.labelAlpha("cancelled") == 0.62 && PillLayout.labelAlpha("recording") == 0.9, "label 0.9, Cancelled 0.62")
check(PillLayout.closeDelay(state: "silent", timeoutMs: 0) == 2.4 && PillLayout.closeDelay(state: "error", timeoutMs: 0) == 2.4
      && PillLayout.closeDelay(state: "cancelled", timeoutMs: 0) == 0.9 && PillLayout.closeDelay(state: "learned", timeoutMs: 0) == 3,
      "design holds without --timeout")
check(PillLayout.closeDelay(state: "silent", timeoutMs: 3500) == 3.18, "a caller's timeout includes the 320 ms exit")
check(PillLayout.closeDelay(state: "cancelled", timeoutMs: 200) == 0.1, "a tiny timeout still shows the pill a moment")
check(PillLayout.closeDelay(state: "recording", timeoutMs: 0) == nil && PillLayout.closeDelay(state: "transcribing", timeoutMs: 0) == nil,
      "dictation pills stay until told")
check(PillLayout.accepts(from: "recording", to: "cancelled") && PillLayout.accepts(from: "transcribing", to: "error")
      && PillLayout.accepts(from: "editing", to: "done"), "dictation pills take their own later stages")
check(!PillLayout.accepts(from: "learned", to: "transcribing") && !PillLayout.accepts(from: "silent", to: "error")
      && !PillLayout.accepts(from: "recording", to: "learned"), "other pills are not updated in place")
check(PillMotion.entry(0, reduceMotion: false) == (60, 0) && PillMotion.entry(0.36, reduceMotion: false) == (0, 1),
      "entry: 60 below and clear, to rest")
check(PillMotion.entry(0.24, reduceMotion: false).alpha == 1 && PillMotion.entry(0.24, reduceMotion: false).offset > 0,
      "entry fade (240) ends before the slide (360)")
check(PillMotion.entry(0, reduceMotion: true).offset == 0, "Reduce Motion: no slide in")
let exitEnd = PillMotion.exit(0.32, from: (0, 1), reduceMotion: false)
check(exitEnd.offset == 16 && exitEnd.alpha == 0, "exit: 16 down and out in 320")
check(PillMotion.exit(0.32, from: (30, 0.5), reduceMotion: false) == (46, 0), "exit starts from a pill still arriving")
check(PillMotion.exit(0.32, from: (0, 1), reduceMotion: true).offset == 0, "Reduce Motion: exit fades in place")
check(PillMotion.launch(0.28, from: (0, 1), reduceMotion: false) == (-24, 0), "History click: 24 up and out in 280")
check(PillMotion.dotAlpha(0, 0) == 0.25 && near(Double(PillMotion.dotAlpha(0, 0.6)), 1), "dot pulse 0.25 -> 1 over half of 1.2 s")
check(near(Double(PillMotion.dotAlpha(1, 0.8)), 1) && near(Double(PillMotion.dotAlpha(2, 1.0)), 1), "each dot 200 ms behind the last")
check(near(Double(PillMotion.dotAlpha(0, 1.2)), 0.25), "dot period 1.2 s")
var waveLo: CGFloat = 99, waveHi: CGFloat = 0
for i in 0..<17 { for k in 0..<160 { let h = PillMotion.slowWave(i, Double(k) / 100); waveLo = min(waveLo, h); waveHi = max(waveHi, h) } }
check(waveLo >= 8 - 1e-9 && waveHi <= 16 + 1e-9 && waveHi - waveLo > 7.9, "slow wave spans 8...16")
check(near(Double(PillMotion.slowWave(3, 0.25)), Double(PillMotion.slowWave(3, 1.85))), "slow wave period 1.6 s")
check((0..<17).map { PillMotion.ridge($0) } == [4, 5, 6, 7, 8, 7, 6, 5, 4, 5, 6, 7, 8, 7, 6, 5, 4], "Failed ridge 4...8 (mockup)")
check(PillMotion.stillHeight("silent", 5) == 3 && PillMotion.stillHeight("cancelled", 5) == 4 && PillMotion.stillHeight("recording", 5) == nil,
      "No sound flat at 3, Cancelled dots of 4")
check(PillMotion.liveHeight(level: 0, bar: 0) == 4 && PillMotion.liveHeight(level: 1, bar: 8) <= 24
      && PillMotion.liveHeight(level: 1, bar: 8) > PillMotion.liveHeight(level: 1, bar: 0), "live bars 4...24, centre taller")
check((0..<17).allSatisfy { i in (0..<50).allSatisfy { k in
    let h = PillMotion.idleHeight(i, Double(k) / 10); return h >= 4 && h <= 24 } }, "idle bars stay in 4...24")
let tw = PillTween(from: 1, to: 0.55, start: 10, duration: 0.24)
check(tw.value(at: 10) == 1 && tw.value(at: 10.24) == 0.55 && tw.value(at: 99) == 0.55, "tween runs on the clock, clamped")
check(near(tw.retarget(0.35, at: 10.12, duration: 0.24).from, tw.value(at: 10.12)), "retarget starts where the tween is")
check(PillTween(0.3).value(at: 0) == 0.3, "a still value")
check(PillHandoff.encode(state: "silent", timeoutMs: 3500) == "silent 3500" && PillHandoff.encode(state: "done", timeoutMs: 0) == "done",
      "hand-off message")
check(PillHandoff.decode("silent 3500")! == ("silent", 3500) && PillHandoff.decode("editing\n")! == ("editing", 0)
      && PillHandoff.decode("") == nil, "hand-off parse")
check(PillHandoff.accepted(PillHandoff.ack(state: "error", accepted: true), for: "error") == true
      && PillHandoff.accepted(PillHandoff.ack(state: "error", accepted: false), for: "error") == false
      && PillHandoff.accepted(PillHandoff.ack(state: "silent", accepted: true), for: "error") == nil, "ack is per state")
check(splitNotice("Learned: Kubernetes") == ("Learned", ["Kubernetes"]) && splitNotice("Learned: a, b").words == ["a", "b"]
      && splitNotice("Could not unlearn") == ("Could not unlearn", []), "learned notice: prefix and words")

try? FileManager.default.removeItem(atPath: tmpRoot)
print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
exit(failures == 0 ? 0 : 1)
