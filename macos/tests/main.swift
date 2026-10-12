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

try? FileManager.default.removeItem(atPath: tmpRoot)
print(failures == 0 ? "selftest: all passed" : "selftest: \(failures) failed")
exit(failures == 0 ? 0 : 1)
