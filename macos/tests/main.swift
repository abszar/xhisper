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
check(HistoryStore.describe("2026-10-12T14:03:05+0000", now: noon, calendar: utc) == "Today 14:03", "today label")
check(HistoryStore.describe("2026-10-11T09:00:00+0000", now: noon, calendar: utc) == "Yesterday 09:00", "yesterday label")
check(HistoryStore.describe("2026-10-01T08:05:00+0000", now: noon, calendar: utc) == "01 Oct 08:05", "older label")
check(HistoryStore.describe("garbage", now: noon, calendar: utc) == "garbage", "bad stamp shown as is")
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

try? FileManager.default.removeItem(atPath: tmpRoot)
print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
exit(failures == 0 ? 0 : 1)
