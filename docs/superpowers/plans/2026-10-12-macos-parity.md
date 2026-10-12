# macOS Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give xhisper on macOS the same features as on Linux/X11 (Option→Control toggle, overlay pill, Escape cancel, sounds, history window, word learning, screen context) without changing Linux behaviour.

**Architecture:** One Swift app bundle `Xhisper.app` (built by `make` with `swiftc`, no Xcode project) with subcommands `hotkey`, `notify`, `history`, `ax`, `front`, `paste`. `xhisper.sh` keeps orchestrating and calls those subcommands from its `if [ "$OS" = "Darwin" ]` branches. `xhisper-learn` stays the single Python home of the learning rules; only its "read the focused field" backend gets a macOS reader that talks to `Xhisper ax --follow`.

**Tech Stack:** Swift 6.4 compiler in Swift 5 language mode (AppKit, ApplicationServices, CoreGraphics), bash 3.2 (`/bin/bash`), system python3 3.9 (stdlib only), sox `rec`, launchd LaunchAgent.

**Spec:** `docs/superpowers/specs/2026-10-12-macos-parity-design.md`

## Global Constraints

- Linux must behave exactly as today. Platform split: `if [ "$OS" = "Darwin" ]` in shell, `sys.platform == "darwin"` in Python. Linux Python programs `xhisper-notify`, `xhisper-history`, `xhisper-hotkey` are not edited.
- Runtime dir on macOS: `$XHISPER_RUNTIME_DIR`, else `$XDG_RUNTIME_DIR/xhisper`, else `$(getconf DARWIN_USER_TEMP_DIR)` + `xhisper`; mode 0700.
- Dictated text never in argv (stdin, pipes or files in the runtime dir). API keys only via `curl -K -` (already done, do not touch). History file 0600 under a 0700 dir.
- Bundle id `io.github.abszar.xhisper`; app at `/Applications/Xhisper.app`; binary `Contents/MacOS/Xhisper`; LaunchAgent label `io.github.abszar.xhisper.hotkey`.
- Signing identity name: `xhisper Code Signing` (ad-hoc `-` when absent).
- Swift: `swiftc -O -swift-version 5 -target $(uname -m)-apple-macos13.0`.
- macOS sound defaults (key absent from xhisperrc): start `/System/Library/Sounds/Tink.aiff`, stop `/System/Library/Sounds/Pop.aiff`, cancel `/System/Library/Sounds/Basso.aiff`, learned `/System/Library/Sounds/Glass.aiff`. Key present with empty value = silent.
- No Chrome/Electron accessibility forcing (`AXManualAccessibility`).
- Commits: small, one per task. **The user must approve each commit before it is made** (controller asks). Never add `Co-Authored-By` or any AI attribution. Commit messages extremely concise.
- Installing on this Mac from Claude Code (no tty for sudo): build as the user with `make`, then
  `osascript -e 'do shell script "make -C /Users/abszar/Documents/xhisper install INSTALL_USER=abszar" with administrator privileges'` (macOS password dialog).
- The app/dev processes are already running when relevant; never `pkill` user apps other than xhisper's own processes.

## Review Focus

1. Clipboard restore races the paste: the target app reads the pasteboard after xhisper already restored the old clipboard, so the *old* clipboard gets pasted. Expected: the dictation is pasted, then the old clipboard is back. Pinned in Task 2 (real paste check) and Task 7.
2. A stale `xhisper.listening` whose pid got recycled by an unrelated process would make the agent swallow every Escape forever. Expected: Escape is only swallowed while a python key loop is live. Pinned in Task 5 (`isListener` selftest).
3. Text with emoji/accents before the caret: AX gives the caret in UTF-16 units, Python indexes code points, so the caret would drift and `locate()`/context would cut mid-word. Expected: exact code-point caret. Pinned in Task 1 (`scalarOffset` selftest) and Task 6.
4. Missing or revoked permissions (fresh install, ad-hoc rebuild): paste silently does nothing, or the hotkey never fires. Expected: an explicit log line naming the permission. Pinned in Task 2 (paste exit 2 → log line) and Task 5 (agent log line).
5. No history yet (file missing or empty): History chip must not show, history window must show "No dictations yet" rather than crash. Pinned in Task 4 (`HistoryStore.load` on a missing file + window check).

---

## File Structure

```
macos/
  Info.plist                              bundle metadata (LSUIElement, mic usage string)
  main.swift                              subcommand dispatch
  Runtime.swift                           runtime dir, pid files, process scan, spawn, log, scalarOffset  [logic, selftested]
  HotkeyLogic.swift                       ComboDetector, isListener                                       [logic, selftested]
  LevelMeter.swift                        WAV-tail RMS + level normalisation                              [logic, selftested]
  HistoryStore.swift                      history.jsonl load/update, time labels                          [logic, selftested]
  Paste.swift                             `paste`
  AX.swift                                `front`, `ax [--follow]`
  Overlay.swift                           `notify`
  History.swift                           `history`
  Hotkey.swift                            `hotkey`
  make-cert.sh                            one-time signing identity
  io.github.abszar.xhisper.hotkey.plist   LaunchAgent
  tests/main.swift                        selftest runner for the [logic] files
tests/test_learn.py                       Python rules + reader tests (runs on Linux too)
Makefile                                  Darwin build/check/install; `check` on Linux
xhisper.sh                                Darwin branches
xhisper-learn                             reader split, is_english, afplay, defaults
default_xhisperrc, README.md, CLAUDE.md   docs
```

---

### Task 1: Swift build skeleton, signing, selftest harness

**Files:**
- Create: `macos/Info.plist`, `macos/main.swift`, `macos/Runtime.swift`, `macos/tests/main.swift`, `macos/make-cert.sh`
- Modify: `Makefile` (Darwin branch, `clean`, add Linux `check`), `.gitignore` (create if absent)

**Interfaces:**
- Produces (Runtime.swift, all top-level, Foundation/Darwin only — no AppKit, it is compiled into the selftest):
  - `enum Runtime { static let dir: String; static func path(_ name: String) -> String; static func darwinUserTempDir() -> String }`
  - `func readPid(_ file: String) -> pid_t?`, `func writePid(_ file: String)`, `func isAlive(_ pid: pid_t) -> Bool`
  - `func startTime(_ pid: pid_t) -> Double?` (seconds since epoch), `func processArgs(_ pid: pid_t) -> [String]`, `func userProcessIDs() -> [pid_t]`
  - `@discardableResult func spawnDetached(_ argv: [String]) -> pid_t?` (new session, stdio /dev/null, PATH lookup)
  - `func appendLine(_ file: String, _ message: String)` (`[HH:mm:ss] message\n`, 0600)
  - `func scalarOffset(_ s: String, utf16 offset: Int) -> Int` (−1 for negative input)
  - `let xhisperVersion = "1.4"`
- `main.swift` dispatch: `notify`, `history`, `hotkey`, `ax`, `front`, `paste`, `--version`; no argument → `history`. Later tasks add the case bodies; in this task the not-yet-written ones print `Xhisper: <sub> not built yet` and exit 1.

- [ ] **Step 1: Write the failing selftest**

`macos/tests/main.swift`:

```swift
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
```

- [ ] **Step 2: Add the Makefile Darwin targets (selftest only for now) and run it to see it fail**

Replace the whole `ifeq ($(UNAME),Darwin)` … `else` part of `Makefile` with the block below (recipe lines start with a real TAB), and add `rm -rf build` to `clean`. Leave the Linux branch as is except for the new `check` target shown at the end.

```make
ifeq ($(UNAME),Darwin)
# macOS: the native parts live in one Swift app, Xhisper.app (see macos/).
APP = build/Xhisper.app
APP_BIN = $(APP)/Contents/MacOS/Xhisper
APP_SOURCES = $(wildcard macos/*.swift)
LOGIC_SOURCES = macos/Runtime.swift
SWIFTFLAGS = -O -swift-version 5 -target $(shell uname -m)-apple-macos13.0
# A stable signature keeps the Accessibility / Input Monitoring grants across
# rebuilds; ad-hoc (-) changes identity each time. See macos/make-cert.sh.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"xhisper Code Signing"' && echo 'xhisper Code Signing' || echo -)
INSTALL_USER ?= $(or $(SUDO_USER),$(shell stat -f %Su /dev/console))
INSTALL_HOME = $(shell dscl . -read /Users/$(INSTALL_USER) NFSHomeDirectory | awk '{print $$2}')
AGENT = io.github.abszar.xhisper.hotkey
APPLICATIONS = $(DESTDIR)/Applications

all: $(APP_BIN)

$(APP_BIN): $(APP_SOURCES) macos/Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp macos/Info.plist $(APP)/Contents/Info.plist
	swiftc $(SWIFTFLAGS) $(APP_SOURCES) -o $(APP_BIN)
	codesign --force --sign "$(SIGN_ID)" --identifier io.github.abszar.xhisper $(APP)

build/selftest: $(LOGIC_SOURCES) macos/tests/main.swift
	mkdir -p build
	swiftc -swift-version 5 $(LOGIC_SOURCES) macos/tests/main.swift -o build/selftest

check: build/selftest
	build/selftest
	@if [ -d tests ]; then python3 -m unittest discover -s tests -v; fi

install: $(APP_BIN)
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 xhisper.sh $(DESTDIR)$(BINDIR)/xhisper
	install -m 755 xhisper-learn $(DESTDIR)$(BINDIR)/xhisper-learn
	rm -rf $(APPLICATIONS)/Xhisper.app
	ditto $(APP) $(APPLICATIONS)/Xhisper.app
	for sub in notify history hotkey; do \
	  printf '#!/bin/sh\nexec /Applications/Xhisper.app/Contents/MacOS/Xhisper %s "$$@"\n' $$sub > $(DESTDIR)$(BINDIR)/xhisper-$$sub; \
	  chmod 755 $(DESTDIR)$(BINDIR)/xhisper-$$sub; \
	done

uninstall:
	rm -rf $(APPLICATIONS)/Xhisper.app
	rm -f $(DESTDIR)$(BINDIR)/xhisper $(DESTDIR)$(BINDIR)/xhisper-learn
	rm -f $(DESTDIR)$(BINDIR)/xhisper-notify $(DESTDIR)$(BINDIR)/xhisper-history $(DESTDIR)$(BINDIR)/xhisper-hotkey

else
```

Linux branch: add after its `test:` rule:

```make
check:
	@if [ -d tests ]; then python3 -m unittest discover -s tests -v; fi
```

`clean` (shared) becomes:

```make
clean:
	rm -f xhispertool xhispertoold test
	rm -rf build
```

`.PHONY` line: add `check`.

`.gitignore` (create or append): `build/`

Run: `make check`
Expected: FAIL — swiftc errors `cannot find 'Runtime' in scope` (Runtime.swift does not exist yet).

- [ ] **Step 3: Write `macos/Runtime.swift`**

```swift
import Foundation
import Darwin

// Shared plumbing for every Xhisper subcommand. Foundation/Darwin only: this
// file is also compiled into the selftest (make check).

let xhisperVersion = "1.4"

enum Runtime {
    /// Same rule as xhisper.sh: $XHISPER_RUNTIME_DIR, else $XDG_RUNTIME_DIR/xhisper,
    /// else the per-user temp dir (macOS has no XDG_RUNTIME_DIR). Private (0700):
    /// it holds the recording, the log and the LLM request body.
    static let dir: String = {
        let env = ProcessInfo.processInfo.environment
        var path: String
        if let d = env["XHISPER_RUNTIME_DIR"], !d.isEmpty {
            path = d
        } else if let x = env["XDG_RUNTIME_DIR"], !x.isEmpty {
            path = x + "/xhisper"
        } else {
            path = (darwinUserTempDir() as NSString).appendingPathComponent("xhisper")
        }
        mkdir(path, 0o700)
        if access(path, W_OK) != 0 {
            path = NSHomeDirectory() + "/.cache/xhisper"
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        chmod(path, 0o700)
        return path
    }()

    static func path(_ name: String) -> String { dir + "/" + name }

    static func darwinUserTempDir() -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 { return String(cString: buf) }
        return NSTemporaryDirectory()
    }
}

/// First number in a pid file ("PID" or xhisper.pid's "PID EPOCH").
func readPid(_ file: String) -> pid_t? {
    guard let s = try? String(contentsOfFile: file, encoding: .utf8),
          let first = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).first else { return nil }
    return pid_t(first)
}

func writePid(_ file: String) {
    try? "\(getpid())".write(toFile: file, atomically: false, encoding: .utf8)
}

func isAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

/// Process start time in seconds since the epoch (kinfo_proc.p_starttime).
func startTime(_ pid: pid_t) -> Double? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
}

/// argv of a process (KERN_PROCARGS2), or [] when unreadable.
func processArgs(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }  // executable path
    while i < size && buf[i] == 0 { i += 1 }  // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

/// Every process of the current user.
func userProcessIDs() -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
    size = procs.count * stride
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
    return procs.prefix(size / stride).map { $0.kp_proc.p_pid }
}

/// Fire-and-forget launch: own session, stdio on /dev/null, PATH lookup.
@discardableResult
func spawnDetached(_ argv: [String]) -> pid_t? {
    guard !argv.isEmpty else { return nil }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    defer { cargs.forEach { free($0) } }
    var pid: pid_t = 0
    return posix_spawnp(&pid, argv[0], &actions, &attr, &cargs, environ) == 0 ? pid : nil
}

/// One "[HH:mm:ss] message" line appended to a private log file.
func appendLine(_ file: String, _ message: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(message)\n"
    let fd = open(file, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

/// Accessibility reports the caret in UTF-16 units; Python indexes code
/// points. Converts one to the other, clamped to the end of the string.
func scalarOffset(_ s: String, utf16 offset: Int) -> Int {
    guard offset >= 0 else { return -1 }
    let units = Array(s.utf16.prefix(offset))
    return String(decoding: units, as: UTF16.self).unicodeScalars.count
}
```

If `info.kp_proc.p_un.__p_starttime` does not compile, the field is the C macro `p_starttime`; use whatever name the Swift importer exposes (`swiftc -print-ast` or Xcode's generated interface for `sys/proc.h`) — it is the `struct timeval` start time.

- [ ] **Step 4: Run the selftest**

Run: `make check`
Expected: every line `ok`, last line `selftest: all passed`. (`python3 -m unittest` is skipped: no `tests/` dir yet.)

- [ ] **Step 5: Write `macos/Info.plist`, `macos/main.swift`, `macos/make-cert.sh`**

`macos/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.github.abszar.xhisper</string>
	<key>CFBundleName</key>
	<string>Xhisper</string>
	<key>CFBundleDisplayName</key>
	<string>Xhisper</string>
	<key>CFBundleExecutable</key>
	<string>Xhisper</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.4</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>xhisper records your voice while you dictate.</string>
</dict>
</plist>
```

`macos/main.swift`:

```swift
import Foundation

// Xhisper.app: the macOS side of xhisper. One binary, one subcommand per job,
// the way xhispertool dispatches on its name on Linux.
//   hotkey   Option then Control toggles dictation (LaunchAgent)
//   notify   the overlay pill            (xhisper-notify on Linux)
//   history  the dictation history window (xhisper-history on Linux)
//   ax       focused text field as JSON, for xhisper-learn
//   front    frontmost app: bundle id, name, window title
//   paste    Cmd+V into the focused app

let arguments = Array(CommandLine.arguments.dropFirst())
let subcommand = arguments.first ?? "history"  // double-clicking the app opens the history
let rest = Array(arguments.dropFirst())

func notBuiltYet() -> Int32 {
    FileHandle.standardError.write(Data("Xhisper: \(subcommand) not built yet\n".utf8))
    return 1
}

switch subcommand {
case "notify": exit(notBuiltYet())
case "history": exit(notBuiltYet())
case "hotkey": exit(notBuiltYet())
case "ax": exit(notBuiltYet())
case "front": exit(notBuiltYet())
case "paste": exit(notBuiltYet())
case "--version", "-V": print("Xhisper \(xhisperVersion)"); exit(0)
default:
    FileHandle.standardError.write(Data("usage: Xhisper hotkey|notify|history|ax|front|paste|--version\n".utf8))
    exit(1)
}
```

`macos/make-cert.sh` (mode 755):

```bash
#!/bin/bash
# Create the "xhisper Code Signing" identity once, in the login keychain.
# `make` signs Xhisper.app with it, so rebuilds keep the Accessibility and
# Input Monitoring grants (an ad-hoc signature changes on every build and macOS
# silently drops them). macOS asks for your password to trust the certificate.
NAME="xhisper Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists"
  exit 0
fi

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" || exit 1
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
  -passout pass:xhisper -out "$work/id.p12" || exit 1
security import "$work/id.p12" -k "$KEYCHAIN" -P xhisper -T /usr/bin/codesign || exit 1
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$work/cert.pem" || exit 1
security find-identity -v -p codesigning | grep "\"$NAME\""
```

- [ ] **Step 6: Create the cert (USER STEP: approve the macOS trust dialog) and build**

Run: `macos/make-cert.sh` (the user types their password in the dialog; if `codesign` later asks to use the key, click **Always Allow**).
Expected: last line shows `"xhisper Code Signing"`.

Run: `make && build/Xhisper.app/Contents/MacOS/Xhisper --version && codesign -dv build/Xhisper.app 2>&1 | grep -E 'Identifier|Authority|Signature'`
Expected: `Xhisper 1.4`, `Identifier=io.github.abszar.xhisper`, `Authority=xhisper Code Signing` (or `Signature=adhoc` if the cert step was skipped).

Run: `make check` → `selftest: all passed`.

- [ ] **Step 7: Commit (ask the user first)**

```bash
git add Makefile .gitignore macos/
git commit -m "feat(macos): Swift app skeleton, signing cert, selftest"
```

---

### Task 2: xhisper.sh Darwin core — runtime dir, key loop, paste, window detection, sounds

**Files:**
- Create: `macos/Paste.swift`, `macos/AX.swift` (front only)
- Modify: `macos/main.swift` (paste/front cases), `xhisper.sh` (Darwin branches listed below)

**Interfaces:**
- Consumes: `Runtime`, `spawnDetached` (Task 1).
- Produces:
  - `Xhisper paste [--shift]` → exit 0 on success, 2 when the app lacks Accessibility (nothing posted).
  - `Xhisper front` → one line `bundleId<TAB>appName<TAB>windowTitle` (tabs/newlines in fields replaced by spaces).
  - `enum AXCommand { static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef?; static func element(_ v: CFTypeRef?) -> AXUIElement?; static func front() -> Int32 }`
  - xhisper.sh exports `XHISPER_APP` (absolute path of the app binary, `--local` → `./build/Xhisper.app/...`) and `XHISPER_LEARN` (absolute path).
  - Key loop (darwin) writes `$XHISPER_RUNTIME_DIR/xhisper.listening` = its own pid while it listens, and treats `$XHISPER_RUNTIME_DIR/xhisper.cancel` as Escape (exit 4). Both removed when the loop ends.

- [ ] **Step 1: Prerequisites**

Run: `brew install sox` then `command -v rec`
Expected: `/opt/homebrew/bin/rec`.

USER STEP: `~/.env` must contain `GROQ_API_KEY=...` (the user adds it; never type or echo the key). Check only presence: `grep -c '^GROQ_API_KEY=' ~/.env` → `1`.

USER STEP: copy the config: `mkdir -p ~/.config/xhisper && cp default_xhisperrc ~/.config/xhisper/xhisperrc && cp default_dictionary.txt ~/.config/xhisper/dictionary.txt`, then comment out the four empty `*-sound :` lines in the copy (Task 7 changes the template the same way).

- [ ] **Step 2: Write the failing checks**

Run each and note the current (wrong) result:
- `/bin/bash xhisper.sh --log` → prints `No log file found at /tmp/xhisper/xhisper.log` (expected after the fix: `.../T/xhisper/xhisper.log` under `/var/folders`).
- `/bin/bash xhisper.sh --local --toggle & sleep 2; touch "$(getconf DARWIN_USER_TEMP_DIR)xhisper/xhisper.cancel"; sleep 1; /bin/bash xhisper.sh --log | grep 'Ended because'` → today the key loop dies at once with `cannot read the keyboard (Quartz missing)`; expected after the fix: `Ended because: cancelled (Escape)`.

- [ ] **Step 3: Write `macos/Paste.swift` and `macos/AX.swift`**

`macos/Paste.swift`:

```swift
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
```

`macos/AX.swift`:

```swift
import AppKit
import ApplicationServices

// Accessibility reads: the frontmost app (tone and terminal detection) and,
// for xhisper-learn, the focused text field. Field text goes to stdout only,
// never to argv or a log.
enum AXCommand {
    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// bundleId<TAB>appName<TAB>windowTitle. Bundle id plays the role of the
    /// X11 window class; the title needs Accessibility and is empty without it.
    static func front() -> Int32 {
        let app = NSWorkspace.shared.frontmostApplication
        var title = ""
        if let app = app {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            if let window = element(copy(appElement, kAXFocusedWindowAttribute)) {
                title = (copy(window, kAXTitleAttribute) as? String) ?? ""
            }
        }
        func clean(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        print("\(clean(app?.bundleIdentifier))\t\(clean(app?.localizedName))\t\(clean(title))")
        return 0
    }
}
```

`macos/main.swift`: replace the `front` and `paste` cases:

```swift
case "front": exit(AXCommand.front())
case "paste": exit(Paste.main(rest))
```

- [ ] **Step 4: Edit `xhisper.sh` (each change is Darwin-only)**

4a. After `OS=$(uname)` add:

```bash
# launchd (the hotkey agent) starts us with a bare PATH: rec, ffmpeg and jq
# come from Homebrew.
[ "$OS" = "Darwin" ] && PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
```

4b. Replace the line `RUNTIME_DIR="${XHISPER_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/xhisper}"` with:

```bash
if [ "$OS" = "Darwin" ] && [ -z "$XDG_RUNTIME_DIR" ]; then
  # macOS has no XDG_RUNTIME_DIR; the per-user temp dir is private (0700),
  # unlike /tmp. Xhisper.app computes the same path.
  DARWIN_TMP=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
  RUNTIME_DIR="${XHISPER_RUNTIME_DIR:-${DARWIN_TMP%/}/xhisper}"
else
  RUNTIME_DIR="${XHISPER_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/xhisper}"
fi
```

4c. After the `if [ "$LOCAL_MODE" -eq 1 ]; then … fi` block that sets the binary paths, and **before** `if [ "$HISTORY_MODE" -eq 1 ]`, add:

```bash
# macOS: the overlay, history window, hotkey agent, paste and accessibility
# reads are subcommands of Xhisper.app (macos/); xhisper-learn is shared.
if [ "$OS" = "Darwin" ]; then
  if [ "$LOCAL_MODE" -eq 1 ]; then
    XHISPER_APP="$SCRIPT_DIR/build/Xhisper.app/Contents/MacOS/Xhisper"
  else
    XHISPER_APP="/Applications/Xhisper.app/Contents/MacOS/Xhisper"
    XHISPER_LEARN="$(command -v xhisper-learn || echo /usr/local/bin/xhisper-learn)"
  fi
  export XHISPER_APP XHISPER_LEARN
  [ "$HISTORY_MODE" -eq 1 ] && exec "$XHISPER_APP" history
fi
```

4d. In the defaults block, right after `llm_timeout=30`, add:

```bash
if [ "$OS" = "Darwin" ]; then
  # Cue sounds out of the box on the Mac. A key present in xhisperrc with an
  # empty value still means silent.
  start_sound="/System/Library/Sounds/Tink.aiff"
  stop_sound="/System/Library/Sounds/Pop.aiff"
  cancel_sound="/System/Library/Sounds/Basso.aiff"
fi
```

4e. `instance_alive()` — replace its `/proc` test with:

```bash
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q xhisper || return 1
  elif [ "$OS" = "Darwin" ]; then
    ps -p "$1" -o command= 2>/dev/null | grep -q xhisper || return 1
  fi
```

4f. `now_seconds()` — sub-second timing for bash 3.2 (no `$EPOCHREALTIME`):

```bash
now_seconds() {
  if [ -n "$EPOCHREALTIME" ]; then
    printf '%s' "${EPOCHREALTIME/,/.}"
  elif [ "$OS" = "Darwin" ]; then
    perl -MTime::HiRes=time -e 'printf "%.3f", time'
  else
    date +%s
  fi
}
```

4g. `paste()` — replace the Darwin `if [ "$is_terminal" -eq 1 ] … fi` block with:

```bash
  if [ "$OS" = "Darwin" ]; then
    # Plain Cmd+V everywhere: macOS terminals paste the clipboard with it, and
    # Cmd+Shift+V is "Paste Selection" in Terminal.app.
    if [ -x "$XHISPER_APP" ]; then
      "$XHISPER_APP" paste
      [ $? -eq 2 ] && log_line "Paste: Xhisper.app lacks Accessibility (System Settings > Privacy & Security > Accessibility)"
    else
      osascript -e 'tell application "System Events" to keystroke "v" using command down'
    fi
  else
```

(The Linux `else` branch stays byte-for-byte as it is.) **Before** committing this, verify the claim in Step 6.

4h. `show_status()` — restructure so Darwin uses the app, Linux semantics unchanged:

```bash
show_status() {
  if [ "$OS" = "Darwin" ]; then
    if [ -x "$XHISPER_APP" ]; then
      "$XHISPER_APP" notify "$@" &
    else
      case "$1" in
        recording)    osascript -e 'display notification "Recording..." with title "xhisper"' ;;
        transcribing) osascript -e 'display notification "Transcribing..." with title "xhisper"' ;;
        editing)      osascript -e 'display notification "Editing..." with title "xhisper"' ;;
        done)         osascript -e 'display notification "Done" with title "xhisper"' ;;
        silent)       osascript -e 'display notification "No sound detected" with title "xhisper"' ;;
        cancelled)    osascript -e 'display notification "Cancelled" with title "xhisper"' ;;
        error)        osascript -e 'display notification "Something went wrong" with title "xhisper"' ;;
      esac
    fi
  elif command -v "$XHISPER_NOTIFY" &> /dev/null; then
    "$XHISPER_NOTIFY" "$@" &
  else
    case "$1" in
      recording)    notify-send -a xhisper "xhisper" "Recording..." -t 30000 ;;
      transcribing) notify-send -a xhisper "xhisper" "Transcribing..." -t 30000 ;;
      editing)      notify-send -a xhisper "xhisper" "Editing..." -t 30000 ;;
      done)         notify-send -a xhisper "xhisper" "Done" -t 1000 ;;
      silent)       notify-send -a xhisper "xhisper" "No sound detected" -t 2000 ;;
      cancelled)    notify-send -a xhisper "xhisper" "Cancelled" -t 1200 ;;
      error)        notify-send -a xhisper "xhisper" "Something went wrong — run 'xhisper --log'" -t 4000 ;;
    esac
  fi
}

hide_status() {
  if [ "$OS" = "Darwin" ]; then
    [ -x "$XHISPER_APP" ] && "$XHISPER_APP" notify hide 2>/dev/null
  elif command -v "$XHISPER_NOTIFY" &> /dev/null; then
    "$XHISPER_NOTIFY" hide 2>/dev/null
  fi
}
```

(Until Task 3 lands, `notify` exits 1 with "not built yet" — harmless.)

4i. `get_active_window()` Darwin branch:

```bash
  if [ "$OS" = "Darwin" ]; then
    if [ -x "$XHISPER_APP" ]; then
      local front
      front=$("$XHISPER_APP" front 2>/dev/null)
      wname=$(printf '%s' "$front" | cut -f3)
      [ -z "$wname" ] && wname=$(printf '%s' "$front" | cut -f2)
    else
      wname=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
    fi
    printf '%s' "$wname"
    return
  fi
```

`get_active_window_class()` — replace `[ "$OS" = "Darwin" ] && return 0` with:

```bash
  if [ "$OS" = "Darwin" ]; then
    # The bundle id (com.apple.Terminal, com.googlecode.iterm2) is the class.
    [ -x "$XHISPER_APP" ] && "$XHISPER_APP" front 2>/dev/null | cut -f1
    return 0
  fi
```

4j. Key loop (`wait_for_key_release`), replace the whole `if sys.platform == 'darwin':` branch with:

```python
if sys.platform == 'darwin':
    # macOS: CGEventSourceKeyState through ctypes, so no PyObjC is needed.
    import ctypes
    try:
        CG = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    except OSError:
        finish('cannot read the keyboard (CoreGraphics missing)', 3)
    CG.CGEventSourceKeyState.restype = ctypes.c_bool
    CG.CGEventSourceKeyState.argtypes = [ctypes.c_int32, ctypes.c_uint16]
    HID_STATE = 1  # kCGEventSourceStateHIDSystemState
    ESC = 53
    runtime = os.environ.get('XHISPER_RUNTIME_DIR', '')
    listening = os.path.join(runtime, 'xhisper.listening')
    cancelflag = os.path.join(runtime, 'xhisper.cancel')
    # While this file names us, the hotkey agent swallows Escape and drops
    # the cancel flag instead, so the key does not also reach the focused app
    # (it would interrupt Claude Code) - the X11 branch grabs it for the same reason.
    try:
        os.unlink(cancelflag)
    except OSError:
        pass
    try:
        with open(listening, 'w') as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    def read_keys():
        return {k for k in range(128) if CG.CGEventSourceKeyState(HID_STATE, k)}
    def escape_pressed(keys):
        return ESC in keys or os.path.exists(cancelflag)
    def close():
        for path in (listening, cancelflag):
            try:
                os.unlink(path)
            except OSError:
                pass
```

4k. After `KEY_RC=$?`, the exit-3 message for Darwin becomes:

```bash
    fail "cannot read the keyboard — CoreGraphics is unavailable (see 'xhisper --log')"
```

4l. Dependency check: replace `command -v rec &> /dev/null || MISSING="$MISSING rec(sox)"` with `command -v rec &> /dev/null || MISSING="$MISSING rec(brew install sox)"`.

- [ ] **Step 5: Run the checks from Step 2 again**

Run: `/bin/bash -n xhisper.sh && make && /bin/bash xhisper.sh --log`
Expected: `No log file found at /var/folders/…/T/xhisper/xhisper.log`.

Run (Terminal.app needs Microphone; the Claude app context triggers the mic prompt for its own app — accept it, or run this in Terminal):

```bash
/bin/bash xhisper.sh --local --toggle & sleep 2; touch "$(getconf DARWIN_USER_TEMP_DIR)xhisper/xhisper.cancel"; sleep 1.5; /bin/bash xhisper.sh --log | tail -5
```

Expected: `Ended because: cancelled (Escape)` and `Result: [cancelled]`; Basso plays. Then

```bash
/bin/bash xhisper.sh --local --toggle & sleep 2; /bin/bash xhisper.sh --stop; sleep 3; /bin/bash xhisper.sh --log | grep -E 'Ended because|Result|Time'
```

Expected: `Ended because: stop requested (xhisper --stop or --toggle)`, then either `silent — skipped` (quiet room) or a transcription, and `Time:` values with milliseconds (perl clock). `ls "$(getconf DARWIN_USER_TEMP_DIR)xhisper"` shows no `xhisper.listening` / `xhisper.cancel` left.

Run: `open -a TextEdit; sleep 1; build/Xhisper.app/Contents/MacOS/Xhisper front`
Expected: `com.apple.TextEdit<TAB>TextEdit<TAB>Untitled` (title empty if the running context lacks Accessibility).

- [ ] **Step 6: Verify the terminal paste shortcut before relying on it**

With computer-use (or ask the user): open Terminal.app and iTerm2, open each app's **Edit** menu, screenshot it, and read which item owns ⌘V and ⇧⌘V.
Expected: ⌘V = Paste in both; ⇧⌘V = "Paste Selection" (Terminal.app) / not a clipboard paste. If ⇧⌘V turns out to be a clipboard paste and ⌘V is not, revert 4g to send `--shift` when `$is_terminal` is 1, and note it in CLAUDE.md.

- [ ] **Step 7: Real paste check (Review Focus 1, 4)**

Run in Terminal.app (which needs Accessibility for this manual run): `printf 'pasted text' | pbcopy; open -a TextEdit; sleep 1; build/Xhisper.app/Contents/MacOS/Xhisper paste; echo "rc=$?"`.
Expected: `rc=0` and the clipboard text appears in TextEdit; or `rc=2` when the running context has no Accessibility — then run `/bin/bash xhisper.sh --local --log | tail -3` after a dictation and see the `Paste: Xhisper.app lacks Accessibility` line.

- [ ] **Step 8: Install and update CLAUDE.md**

Run: `make && osascript -e 'do shell script "make -C /Users/abszar/Documents/xhisper install INSTALL_USER=abszar" with administrator privileges'` then `ls -l /usr/local/bin/xhisper* /Applications/Xhisper.app/Contents/MacOS/Xhisper`.
Expected: `xhisper`, `xhisper-learn`, `xhisper-notify`, `xhisper-history`, `xhisper-hotkey` and the app present.

CLAUDE.md, "Syncing changes to the installed binary": add a bullet:
`- macOS: after editing xhisper.sh, xhisper-learn or anything in macos/: make (as the user), then osascript -e 'do shell script "make -C <repo> install INSTALL_USER=<you>" with administrator privileges' (graphical password dialog; sudo has no tty in Claude Code). make install also restarts the hotkey LaunchAgent.`
CLAUDE.md, "Runtime state": add `On macOS (no XDG_RUNTIME_DIR) the default is $(getconf DARWIN_USER_TEMP_DIR)xhisper, per-user and private.` and a line for `xhisper.listening` / `xhisper.cancel` (macOS Escape handshake with the hotkey agent).

- [ ] **Step 9: Commit (ask the user first)**

```bash
git add xhisper.sh macos/ CLAUDE.md
git commit -m "feat(macos): runtime dir, ctypes key loop, native paste, window detection, sounds"
```

---

### Task 3: Overlay pill (`Xhisper notify`)

**Files:**
- Create: `macos/LevelMeter.swift`, `macos/Overlay.swift`
- Modify: `macos/main.swift` (notify case), `Makefile` (`LOGIC_SOURCES += macos/LevelMeter.swift`), `macos/tests/main.swift`

**Interfaces:**
- Consumes: `Runtime`, `readPid`, `writePid`, `isAlive`, `startTime`, `processArgs`, `userProcessIDs`, `spawnDetached` (Task 1); `HistoryStore.defaultPath()` (Task 4 — until then, `Overlay` uses its own private `historyPath()` with the same rule; Task 4 replaces it).
- Produces:
  - `let levelWindowBytes = 1600`, `let levelPushSeconds = 0.045`, `let levelMinSpanDB = 18.0`
  - `func rmsDB(_ data: Data) -> Double?`, `func readTailDB(path: String) -> Double?`
  - `struct LevelMeter { init(bars: Int); private(set) var levels: [Double]; private(set) var level: Double; mutating func push(db: Double) }`
  - `enum Overlay { static func main(_ args: [String]) -> Int32 }` — CLI identical to `xhisper-notify`: `<state> [--timeout MS] [--label TEXT] [--unlearn W,...]`; states recording, transcribing, editing, done, silent, error, cancelled, learned, hide.
  - `func launchHistory()` (Overlay.swift, internal) — opens the history window so it can take focus.

- [ ] **Step 1: Write the failing meter tests** — append to `macos/tests/main.swift` before the final summary lines:

```swift
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
```

Makefile: `LOGIC_SOURCES = macos/Runtime.swift macos/LevelMeter.swift`.

Run: `make check` → FAIL (`cannot find 'rmsDB' in scope`).

- [ ] **Step 2: Write `macos/LevelMeter.swift`**

```swift
import Foundation

// Live level meter for the recording pill, same algorithm as xhisper-notify:
// read the newest 50 ms of the WAV that rec is writing (16-bit mono 16 kHz),
// normalise between a tracked noise floor and a decaying speech peak.
let levelWindowBytes = 1600     // last 50 ms of audio
let levelPushSeconds = 0.045    // one new bar value per ~45 ms, scrolling left
let levelMinSpanDB = 18.0       // quietest dynamic range stretched to full height

/// RMS of little-endian 16-bit samples in dBFS, nil without samples.
func rmsDB(_ data: Data) -> Double? {
    let n = data.count / 2
    guard n > 0 else { return nil }
    var sum = 0.0
    data.withUnsafeBytes { raw in
        for i in 0..<n {
            let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
            sum += s * s
        }
    }
    return 20 * log10(max((sum / Double(n)).squareRoot(), 1.0) / 32768)
}

/// Level of the newest audio in the recording, nil until it holds any.
func readTailDB(path: String) -> Double? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd(), size >= UInt64(44 + levelWindowBytes) else { return nil }
    let offset = max(UInt64(44), (size - UInt64(levelWindowBytes)) & ~UInt64(1))
    guard (try? fh.seek(toOffset: offset)) != nil,
          let data = try? fh.read(upToCount: levelWindowBytes) else { return nil }
    return rmsDB(data.prefix(data.count & ~1))
}

struct LevelMeter {
    private(set) var levels: [Double]
    private(set) var level = 0.0
    private var noiseFloor: Double?
    private var peakDB = 0.0

    init(bars: Int) { levels = Array(repeating: 0, count: bars) }

    /// Push one bar value, normalised so any mic gain fills the pill.
    mutating func push(db: Double) {
        if noiseFloor == nil { noiseFloor = db; peakDB = db + levelMinSpanDB }
        // Floor follows quiet passages down at once and creeps up slowly;
        // the peak jumps up with speech and decays about 7 dB per second.
        let floor = min(db, noiseFloor! + 0.05)
        noiseFloor = floor
        peakDB = max(db, peakDB - 0.3)
        let span = max(peakDB - floor, levelMinSpanDB)
        let target = min(1.0, max(0.0, (db - floor - 3) / span))
        // Fast attack, softer release, so syllables pop and pauses settle.
        level += (target - level) * (target > level ? 0.7 : 0.35)
        levels = Array(levels.dropFirst()) + [level]
    }
}
```

Run: `make check` → `selftest: all passed`.

- [ ] **Step 3: Write `macos/Overlay.swift`**

```swift
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
private let stateLabels = ["recording": "Recording", "transcribing": "Transcribing", "editing": "Editing",
                           "done": "Done", "silent": "No sound", "error": "Failed",
                           "cancelled": "Cancelled", "learned": "Learned"]
private let historyStates: Set<String> = ["recording", "silent"]
private let env = ProcessInfo.processInfo.environment

private func historyPath() -> String {
    if let p = env["XHISPER_HISTORY_FILE"], !p.isEmpty { return p }
    let state = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.local/state")
    return state + "/xhisper/history.jsonl"
}

private func hasHistory() -> Bool {
    ((try? FileManager.default.attributesOfItem(atPath: historyPath())[.size] as? Int) ?? 0) > 0
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
        pill.draw(cg)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { pill.pointerInside = true }
    override func mouseExited(with event: NSEvent) { pill.pointerInside = false; pill.setChipHover(false) }
    override func mouseMoved(with event: NSEvent) { pill.setChipHover(pill.inChip(convert(event.locationInWindow, from: nil))) }
    override func mouseDown(with event: NSEvent) { pill.click(at: convert(event.locationInWindow, from: nil)) }
}

final class Pill {
    let state: String
    var label: String
    let unlearn: [String]
    var showChip: Bool
    let chipLabel: String
    let showWaves: Bool
    let pillHeight: CGFloat, fontSize: CGFloat, chipFontSize: CGFloat, maxBarHeight: CGFloat
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
        let big = state == "learned"
        pillHeight = big ? 60 : 48
        fontSize = big ? 17 : 13
        chipFontSize = big ? 14 : 12
        maxBarHeight = pillHeight - 14
        let waveW = CGFloat(numBars) * barWidth + CGFloat(numBars - 1) * barGap
        let textW: CGFloat = big
            ? (self.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width + 24
            : CGFloat((self.label.count + 3) * 8 + 8)
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

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame  // above the Dock
        target = NSPoint(x: (visible.midX - pillWidth / 2).rounded(), y: visible.minY + 55)
        let size = NSSize(width: pillWidth + 2, height: pillHeight + 4)
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
        case "transcribing", "editing": f = 0.75 + 0.15 * sin(t * 2.5 + CGFloat(i) * 0.35)
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

        let dots = ["recording", "transcribing", "editing"].contains(state) ? String(repeating: ".", count: Int(t * 2) % 4) : ""
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

        killExisting()
        if state == "hide" { return 0 }

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { quit() }
        source.resume()
        termSource = source

        // Register before building the window, so the next overlay can find us.
        writePid(pidFile)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        pill = Pill(state: state, timeoutMs: timeout, label: value("--label"), unlearn: unlearn)
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
```

(The `isOverlay` check inside the wait loop also covers zombies: a reaped-but-not-yet-collected child has no readable argv.)

`macos/main.swift`: `case "notify": exit(Overlay.main(rest))`.

- [ ] **Step 4: Build and look at every state**

Run: `make check && make`
Expected: `selftest: all passed`, build OK.

For each state run and screenshot with computer-use (bottom centre of the screen), then `pkill -f 'Xhisper notify'`:

```bash
B=build/Xhisper.app/Contents/MacOS/Xhisper
$B notify recording &          # sine waves (no WAV) + "Recording..." + History chip if history exists
$B notify transcribing &       # gentler pulse
$B notify done --timeout 1500 &  # bars shrink, fades out after ~1.5 s
$B notify error --timeout 2500 & # red bars, "Failed"
$B notify learned --label "Learned: TOSIAM" --unlearn TOSIAM --timeout 6000 &  # bigger, no waves, Unlearn chip
```

Expected: dark pill slides up 60 pt above the Dock, centred; the focused app keeps focus (type in TextEdit while the pill shows — keys still land there); the pill shows on every Space.

- [ ] **Step 5: Single-overlay rules**

Run: `$B notify recording & sleep 1; $B notify transcribing & sleep 1; pgrep -fl 'Xhisper notify'`
Expected: only the `transcribing` process is listed. Then `$B notify hide; sleep 0.6; pgrep -fl 'Xhisper notify' || echo none` → `none`, and `ls "$(getconf DARWIN_USER_TEMP_DIR)xhisper/xhisper-notify.pid"` → no such file.
Run: `XHISPER_OVERLAY_MAX_SECONDS=2 $B notify editing & sleep 3; pgrep -fl 'Xhisper notify' || echo gone` → `gone`.

- [ ] **Step 6: Live waveform**

Run (Terminal.app with Microphone): `rec -q -c 1 -r 16000 -b 16 /tmp/xhisper-meter.wav & XHISPER_RECORDING=/tmp/xhisper-meter.wav $B notify recording & sleep 1; say "testing the level meter, one two three"; sleep 1; pkill -f 'Xhisper notify'; kill %1; rm -f /tmp/xhisper-meter.wav`
Expected (screenshot during `say`): bars follow the voice, near-flat dots in the pauses.

- [ ] **Step 7: Install, CLAUDE.md, commit (ask the user first)**

Install as in Task 2 Step 8. CLAUDE.md, `xhisper-notify` bullet: append `On macOS the same overlay is Xhisper.app's notify subcommand (macos/Overlay.swift, a non-activating NSPanel); keep both in step when changing states, sizes or timings.`

```bash
git add macos/ Makefile CLAUDE.md
git commit -m "feat(macos): overlay pill with live waveform, History and Unlearn chips"
```

---

### Task 4: History window (`Xhisper history`)

**Files:**
- Create: `macos/HistoryStore.swift`, `macos/History.swift`
- Modify: `macos/main.swift` (history case), `macos/Overlay.swift` (use `HistoryStore.defaultPath()`), `Makefile` (`LOGIC_SOURCES += macos/HistoryStore.swift`), `macos/tests/main.swift`

**Interfaces:**
- Consumes: `Runtime`, `readPid`, `writePid`, `isAlive`, `processArgs` (Task 1).
- Produces:
  - `struct HistoryEntry: Equatable { let time: String; let text: String }`
  - `enum HistoryStore { static func defaultPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String; static func parse(_ line: Substring) -> HistoryEntry?; static func load(_ path: String) -> [HistoryEntry] /* newest first */; static func describe(_ stamp: String, now: Date = Date(), calendar: Calendar = .current) -> String; static func encode(_ e: HistoryEntry) -> String; @discardableResult static func update(_ path: String, entry: HistoryEntry, newText: String) -> Bool }`
  - `enum HistoryApp { static func main(_ args: [String]) -> Int32 }`

- [ ] **Step 1: Write the failing store tests** — append to `macos/tests/main.swift`:

```swift
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
```

Makefile: `LOGIC_SOURCES = macos/Runtime.swift macos/LevelMeter.swift macos/HistoryStore.swift`.

Run: `make check` → FAIL (`cannot find 'HistoryStore' in scope`).

- [ ] **Step 2: Write `macos/HistoryStore.swift`**

```swift
import Foundation

// The dictation history written by xhisper.sh (JSON lines {time, text}, 0600,
// trimmed to history-size). Shared by the overlay and the history window.

struct HistoryEntry: Equatable {
    let time: String
    let text: String
}

enum HistoryStore {
    static func defaultPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["XHISPER_HISTORY_FILE"], !p.isEmpty { return p }
        let state = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.local/state")
        return state + "/xhisper/history.jsonl"
    }

    static func parse(_ line: Substring) -> HistoryEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        return HistoryEntry(time: obj["time"] as? String ?? "", text: text)
    }

    /// Newest first.
    static func load(_ path: String) -> [HistoryEntry] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap(parse).reversed()
    }

    /// "Today 14:03", "Yesterday 09:00", else "01 Oct 08:05" (as xhisper-history).
    static func describe(_ stamp: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        guard let when = parser.date(from: stamp) else { return stamp }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = calendar.timeZone
        out.dateFormat = "HH:mm"
        let clock = out.string(from: when)
        if calendar.isDate(when, inSameDayAs: now) { return "Today " + clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(when, inSameDayAs: yesterday) {
            return "Yesterday " + clock
        }
        out.dateFormat = "dd MMM HH:mm"
        return out.string(from: when)
    }

    /// Same shape as xhisper.sh's `jq -c` line: {"time":...,"text":...}.
    static func encode(_ e: HistoryEntry) -> String {
        func quoted(_ s: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        return "{\"time\":\(quoted(e.time)),\"text\":\(quoted(e.text))}"
    }

    /// Replace one entry's text in place (matched on time and old text):
    /// temp file created 0600, then renamed over the history.
    @discardableResult
    static func update(_ path: String, entry: HistoryEntry, newText: String) -> Bool {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var lines = s.components(separatedBy: "\n")
        guard let i = lines.indices.reversed().first(where: { parse(Substring(lines[$0])) == entry }) else { return false }
        lines[i] = encode(HistoryEntry(time: entry.time, text: newText))
        let tmp = path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return false }
        fchmod(fd, 0o600)
        let bytes = Array(lines.joined(separator: "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == bytes.count, rename(tmp, path) == 0 else { unlink(tmp); return false }
        return true
    }
}
```

Run: `make check` → `selftest: all passed`.

In `macos/Overlay.swift`, delete the private `historyPath()` and change `hasHistory()` to read `HistoryStore.defaultPath()`.

- [ ] **Step 3: Write `macos/History.swift`**

```swift
import AppKit

// Port of xhisper-history: the last dictations, newest first, each with Copy
// and Edit. Edit fixes an entry and learns the corrected words through
// `xhisper-learn diff` (JSON on stdin, never argv). One window at a time: a
// second launch raises the open one.

private let pidFile = Runtime.path("xhisper-history.pid")
private let fadeSeconds = 0.22
private let slidePoints: CGFloat = 24

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

final class HistoryWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class HistoryController: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let path = HistoryStore.defaultPath()
    var window: HistoryWindow!
    let list = NSStackView()
    var entries: [HistoryEntry] = []
    var editing: (entry: HistoryEntry, view: NSTextView)?
    var stale = false
    var fileStamp = ""
    var firstCopy: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        window = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Dictation history"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = rgb(0x1a1a1a)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.onEscape = { [unowned self] in
            if self.editing != nil { self.finishEdit(save: false) } else { self.window.close() }
        }

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 12, right: 12)
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        window.contentView = scroll
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        populate()
        fileStamp = stamp()
        // Live refresh when a new dictation lands while the window is open.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [unowned self] _ in
            let now = self.stamp()
            if now != self.fileStamp { self.fileStamp = now; self.populate() }
        }
        presentAnimated()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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

    func populate() {
        if editing != nil { stale = true; return }  // don't wipe an edit in progress
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        entries = HistoryStore.load(path)
        firstCopy = nil
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No dictations yet")
            empty.textColor = rgb(0x8f8b84)
            list.addArrangedSubview(empty)
        }
        for (index, entry) in entries.enumerated() { list.addArrangedSubview(makeRow(entry, index: index)) }
        // Enter copies the newest dictation.
        firstCopy?.keyEquivalent = "\r"
    }

    func button(_ title: String, _ action: Selector, tag: Int) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.tag = tag
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        return b
    }

    func makeRow(_ entry: HistoryEntry, index: Int) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = rgb(0x262626).cgColor
        row.layer?.cornerRadius = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let when = NSTextField(labelWithString: HistoryStore.describe(entry.time))
        when.font = .systemFont(ofSize: 11)
        when.textColor = rgb(0x8f8b84)
        let body = NSTextField(wrappingLabelWithString: entry.text)
        body.isSelectable = true
        body.textColor = rgb(0xeeeae0)
        body.font = .systemFont(ofSize: 13)
        body.preferredMaxLayoutWidth = 400
        let texts = NSStackView(views: [when, body])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4

        let copy = button("Copy", #selector(copyEntry(_:)), tag: index)
        let edit = button("Edit", #selector(editEntry(_:)), tag: index)
        edit.toolTip = "Fix this dictation; corrected words are learned"
        if firstCopy == nil { firstCopy = copy }
        let buttons = NSStackView(views: [copy, edit])
        buttons.orientation = .vertical
        buttons.spacing = 6

        let content = NSStackView(views: [texts, buttons])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
        ])
        DispatchQueue.main.async { row.widthAnchor.constraint(equalTo: self.list.widthAnchor, constant: -24).isActive = true }
        row.identifier = NSUserInterfaceItemIdentifier("row\(index)")
        return row
    }

    @objc func copyEntry(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[sender.tag].text, forType: .string)
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { sender.title = "Copy" }
    }

    @objc func editEntry(_ sender: NSButton) {
        guard editing == nil, entries.indices.contains(sender.tag),
              let row = list.arrangedSubviews.first(where: { $0.identifier?.rawValue == "row\(sender.tag)" }),
              let content = row.subviews.first as? NSStackView,
              let texts = content.arrangedSubviews.first as? NSStackView,
              let buttons = content.arrangedSubviews.last as? NSStackView else { return }
        let entry = entries[sender.tag]
        firstCopy?.keyEquivalent = ""  // Enter types a newline while editing
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        let view = scroll.documentView as! NSTextView
        view.string = entry.text
        view.backgroundColor = rgb(0x303030)
        view.textColor = rgb(0xeeeae0)
        view.insertionPointColor = rgb(0xeeeae0)
        view.font = .systemFont(ofSize: 13)
        view.delegate = self
        texts.arrangedSubviews.last?.removeFromSuperview()
        texts.addArrangedSubview(scroll)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let save = button("Save", #selector(saveEdit(_:)), tag: sender.tag)
        save.bezelColor = .controlAccentColor
        buttons.addArrangedSubview(save)
        buttons.addArrangedSubview(button("Cancel", #selector(cancelEdit(_:)), tag: sender.tag))
        editing = (entry, view)
        window.makeFirstResponder(view)
    }

    @objc func saveEdit(_ sender: NSButton) { finishEdit(save: true) }
    @objc func cancelEdit(_ sender: NSButton) { finishEdit(save: false) }

    /// Escape inside the editor cancels the edit (NSTextView would autocomplete).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)) {
            finishEdit(save: false)
            return true
        }
        return false
    }

    func finishEdit(save: Bool) {
        guard let (entry, view) = editing else { return }
        editing = nil
        let newText = view.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if save && !newText.isEmpty && newText != entry.text {
            let learned = learnFromEdit(old: entry.text, new: newText)
            HistoryStore.update(path, entry: entry, newText: newText)
            window.subtitle = learned.isEmpty ? "Saved" : "Learned: " + learned.joined(separator: ", ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.window.subtitle = "" }
        }
        stale = false
        populate()
    }

    /// `xhisper-learn diff`, text over stdin; the words it learned.
    func learnFromEdit(old: String, new: String) -> [String] {
        let learn = ProcessInfo.processInfo.environment["XHISPER_LEARN"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/bin/xhisper-learn"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: learn)
        p.arguments = ["diff"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil,
              let body = try? JSONSerialization.data(withJSONObject: ["old": old, "new": new]) else { return [] }
        input.fileHandleForWriting.write(body)
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return [] }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Fade in and rise into place, picking up where the pill left off.
    func presentAnimated() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let target = NSPoint(x: (visible.midX - window.frame.width / 2).rounded(), y: visible.minY + 130)
        window.setFrameOrigin(NSPoint(x: target.x, y: target.y - slidePoints))
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [unowned self] timer in
            let p = min(1, Date().timeIntervalSince(start) / fadeSeconds)
            let eased = 1 - pow(1 - p, 3)
            self.window.alphaValue = eased
            self.window.setFrameOrigin(NSPoint(x: target.x, y: target.y - slidePoints * (1 - eased)))
            if p >= 1 { timer.invalidate() }
        }
    }

    func raise() {
        populate()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        app.delegate = controller
        signal(SIGUSR1, SIG_IGN)
        let raise = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        raise.setEventHandler { controller.raise() }
        raise.resume()
        withExtendedLifetime((controller, raise)) { app.run() }
        return 0
    }
}
```

`macos/main.swift`: `case "history": exit(HistoryApp.main(rest))`.

- [ ] **Step 4: Build and check the window**

Run: `make check && make`

Run: `XHISPER_HISTORY_FILE=/tmp/xhisper-none.jsonl build/Xhisper.app/Contents/MacOS/Xhisper history &` → screenshot: "No dictations yet" (Review Focus 5); press Escape (computer-use) → window closes.

Seed a test file and open it:

```bash
H=$(mktemp -d)/history.jsonl; umask 077
printf '%s\n' '{"time":"2026-10-11T09:00:00+0200","text":"yesterday one"}' '{"time":"'"$(date '+%Y-%m-%dT%H:%M:%S%z')"'","text":"today we deploy to to Ziam"}' > "$H"
XHISPER_HISTORY_FILE="$H" XHISPER_LEARN="$PWD/xhisper-learn" build/Xhisper.app/Contents/MacOS/Xhisper history &
```

Expected (screenshots): newest first ("Today HH:MM" then "Yesterday 09:00"), dark palette; window fades and rises in; pressing Return → `pbpaste` prints `today we deploy to to Ziam`, button reads "Copied" for ~1 s; running the same command again raises the existing window (`pgrep -fl 'Xhisper history'` shows one process); Edit → change "to to Ziam" into "to TOSIAM" → Save → subtitle "Learned: TOSIAM" (only once Task 6's word list fix lands is the darwin result final; `TOSIAM` already passes today), `grep TOSIAM ~/.config/xhisper/dictionary.txt` → found (then remove it: `./xhisper-learn remove TOSIAM`); `stat -f %Lp "$H"` → `600`; append a line to `$H` while open → it appears within ~1 s.

- [ ] **Step 5: Pill → window transition**

With history present: `build/Xhisper.app/Contents/MacOS/Xhisper notify silent --timeout 3500 &`, click the History chip (computer-use) → the pill lifts and fades as the window fades in, and the window is key (press Escape → it closes).
If the window does not become key when opened through `open -n`, record that in the task report; do not silently change the launch path.

- [ ] **Step 6: Install, CLAUDE.md, commit (ask the user first)**

Install as in Task 2 Step 8. CLAUDE.md, `xhisper-history` bullet: append `On macOS: Xhisper.app history (macos/History.swift + HistoryStore.swift), opened from the pill through \`open -n\` so it can take focus; single window via xhisper-history.pid + SIGUSR1.`

```bash
git add macos/ Makefile CLAUDE.md
git commit -m "feat(macos): native history window with Copy and Edit"
```

---

### Task 5: Hotkey agent (`Xhisper hotkey`) and LaunchAgent

**Files:**
- Create: `macos/HotkeyLogic.swift`, `macos/Hotkey.swift`, `macos/io.github.abszar.xhisper.hotkey.plist`
- Modify: `macos/main.swift` (hotkey case), `Makefile` (`LOGIC_SOURCES += macos/HotkeyLogic.swift`; install/uninstall the agent), `macos/tests/main.swift`

**Interfaces:**
- Consumes: `Runtime`, `readPid`, `isAlive`, `processArgs`, `spawnDetached`, `appendLine` (Task 1); key loop's `xhisper.listening` / `xhisper.cancel` (Task 2).
- Produces:
  - `struct ComboDetector { static let leftControl = 59; static let rightControl = 62; mutating func flagsChanged(keycode: Int, option: Bool, control: Bool, command: Bool, shift: Bool) -> Bool }`
  - `func isListener(_ argv: [String]) -> Bool` — true when argv[0]'s basename starts with "python" (case-insensitive): the key loop is `python3 -`, and system python's real binary is `.../Python`.
  - `enum Hotkey { static func main(_ args: [String]) -> Int32 }`

- [ ] **Step 1: Write the failing detector tests** — append to `macos/tests/main.swift`:

```swift
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
```

Makefile: `LOGIC_SOURCES = macos/Runtime.swift macos/LevelMeter.swift macos/HistoryStore.swift macos/HotkeyLogic.swift`.

Run: `make check` → FAIL (`cannot find 'ComboDetector' in scope`).

- [ ] **Step 2: Write `macos/HotkeyLogic.swift`**

```swift
import Foundation

/// Option, then Control: the macOS twin of xhisper-hotkey's X11 grab on
/// Control with Mod1 already down. Fires once per Control press, only when
/// Option was held first and neither Command nor Shift is (Caps Lock is
/// ignored). Control-then-Option never matches. Re-arms only once every
/// Control key is up, so a held key can never toggle twice.
struct ComboDetector {
    static let leftControl = 59
    static let rightControl = 62
    private var controlsDown = Set<Int>()
    private var armed = true

    mutating func flagsChanged(keycode: Int, option: Bool, control: Bool, command: Bool, shift: Bool) -> Bool {
        if !control {
            // No Control held at all: resync, in case an event was missed.
            controlsDown.removeAll()
            armed = true
            return false
        }
        guard keycode == Self.leftControl || keycode == Self.rightControl else { return false }
        if controlsDown.contains(keycode) {
            controlsDown.remove(keycode)
            if controlsDown.isEmpty { armed = true }
            return false
        }
        controlsDown.insert(keycode)
        guard armed, controlsDown.count == 1, option, !command, !shift else { return false }
        armed = false
        return true
    }
}

/// The key loop in xhisper.sh is `python3 -` (system python's real binary is
/// named Python). Anything else holding a recycled pid is not listening.
func isListener(_ argv: [String]) -> Bool {
    guard let first = argv.first else { return false }
    return (first as NSString).lastPathComponent.lowercased().hasPrefix("python")
}
```

Run: `make check` → `selftest: all passed`.

- [ ] **Step 3: Write `macos/Hotkey.swift`**

```swift
import AppKit
import ApplicationServices

// Option then Control toggles dictation: each press runs `xhisper --toggle`
// once (port of xhisper-hotkey). Started at login by the LaunchAgent
// io.github.abszar.xhisper.hotkey; one instance per user (flock).
// While a recording listens it also swallows Escape and drops the cancel flag
// instead, so cancelling does not reach the focused app (X11 grabs it).
enum Hotkey {
    static var detector = ComboDetector()
    static var tap: CFMachPort?
    static var command = "/usr/local/bin/xhisper"
    static var waitingLogged = false
    static var swallowingEscape = false
    static let escapeKey: Int64 = 53

    static func log(_ message: String) { appendLine(Runtime.path("xhisper-hotkey.log"), message) }

    static func main(_ args: [String]) -> Int32 {
        let lock = open(Runtime.path("xhisper-hotkey.lock"), O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return 0 }  // already running
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
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        case .flagsChanged:
            let f = event.flags
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if detector.flagsChanged(keycode: code, option: f.contains(.maskAlternate), control: f.contains(.maskControl),
                                     command: f.contains(.maskCommand), shift: f.contains(.maskShift)) {
                log("Option+Control: \(command) --toggle")
                spawnDetached([command, "--toggle"])
            }
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == escapeKey else { break }
            if type == .keyDown && (swallowingEscape || dictationListening()) {
                if !swallowingEscape {
                    FileManager.default.createFile(atPath: Runtime.path("xhisper.cancel"), contents: nil,
                                                   attributes: [.posixPermissions: 0o600])
                }
                swallowingEscape = true  // its repeats and its key-up are ours too
                return nil
            }
            if type == .keyUp && swallowingEscape {
                swallowingEscape = false
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    static func dictationListening() -> Bool {
        guard let pid = readPid(Runtime.path("xhisper.listening")), isAlive(pid) else { return false }
        return isListener(processArgs(pid))
    }
}
```

`macos/main.swift`: `case "hotkey": exit(Hotkey.main(rest))`.

`macos/io.github.abszar.xhisper.hotkey.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>io.github.abszar.xhisper.hotkey</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/Xhisper.app/Contents/MacOS/Xhisper</string>
		<string>hotkey</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
</dict>
</plist>
```

Makefile Darwin `install`: insert **before** `rm -rf $(APPLICATIONS)/Xhisper.app` (stop the agent before replacing its binary):

```make
	-launchctl bootout gui/$$(id -u $(INSTALL_USER))/$(AGENT) 2>/dev/null
```

and append at the end of `install`:

```make
	install -d -o $(INSTALL_USER) $(INSTALL_HOME)/Library/LaunchAgents
	install -m 644 -o $(INSTALL_USER) macos/$(AGENT).plist $(INSTALL_HOME)/Library/LaunchAgents/$(AGENT).plist
	launchctl bootstrap gui/$$(id -u $(INSTALL_USER)) $(INSTALL_HOME)/Library/LaunchAgents/$(AGENT).plist
```

`uninstall`: prepend

```make
	-launchctl bootout gui/$$(id -u $(INSTALL_USER))/$(AGENT) 2>/dev/null
	rm -f $(INSTALL_HOME)/Library/LaunchAgents/$(AGENT).plist
```

- [ ] **Step 4: Build, install, grant permissions (USER STEP)**

Run: `make check && make` then install as in Task 2 Step 8.
Run: `launchctl print gui/$(id -u)/io.github.abszar.xhisper.hotkey | grep -E 'state|pid'` → `state = running`.
Run: `cat "$(getconf DARWIN_USER_TEMP_DIR)xhisper/xhisper-hotkey.log"` → `starting …` and either `listening` or the `no permission yet` line (Review Focus 4).

USER STEP: System Settings → Privacy & Security → **Accessibility**: enable **Xhisper**; → **Input Monitoring**: enable **Xhisper**. Within 2 s the log shows `listening: press Option, then Control`.

- [ ] **Step 5: Order and debounce, without recording**

```bash
printf '#!/bin/sh\necho "$(date +%%T) $*" >> /tmp/xhisper-hotkey-test.log\n' > /tmp/xhisper-fake && chmod +x /tmp/xhisper-fake
launchctl bootout gui/$(id -u)/io.github.abszar.xhisper.hotkey
XHISPER_CMD=/tmp/xhisper-fake /Applications/Xhisper.app/Contents/MacOS/Xhisper hotkey &
```

Then (computer-use `key` actions, or the user): Option→Control once; Control→Option once; Option→Control held for 3 s; Option+Shift→Control once.
Expected: `/tmp/xhisper-hotkey-test.log` has exactly **two** `--toggle` lines (first and third). Then `kill %1; rm -f /tmp/xhisper-fake /tmp/xhisper-hotkey-test.log` and re-bootstrap the agent: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.abszar.xhisper.hotkey.plist`.

- [ ] **Step 6: Real toggle and Escape**

USER STEP (or `say` through the speakers): press Option→Control, say "testing one two three", press Option→Control. Microphone prompt for **Xhisper** appears the first time: Allow.
Expected: pill sequence Recording → Transcribing → Editing → Done; Tink at start, Pop at stop; text pasted at the cursor in TextEdit; `xhisper --log` shows `Ended because: stop requested`.
Then: Option→Control, press Escape in a TextEdit document with a selection, and in a Claude Code prompt (Terminal.app).
Expected: `Ended because: cancelled (Escape)`, Basso, "Cancelled" pill; the selection in TextEdit is untouched and Claude Code is **not** interrupted. Escape pressed when no recording is live behaves normally in both apps.

- [ ] **Step 7: CLAUDE.md, commit (ask the user first)**

CLAUDE.md, `xhisper-hotkey` bullet: append `On macOS: Xhisper.app hotkey (macos/Hotkey.swift + HotkeyLogic.swift), an active CGEventTap started by the LaunchAgent io.github.abszar.xhisper.hotkey (make install loads it). Same order rule and debounce (ComboDetector, selftested); it also swallows Escape while xhisper.listening names a live python key loop and writes xhisper.cancel. Needs Accessibility + Input Monitoring for Xhisper. XHISPER_CMD works the same way.`

```bash
git add macos/ Makefile CLAUDE.md
git commit -m "feat(macos): Option-then-Control hotkey agent with Escape cancel"
```

---

### Task 6: Word learning and screen context on macOS

**Files:**
- Modify: `macos/AX.swift` (add `ax`), `macos/main.swift` (ax case), `xhisper-learn`, `xhisper.sh` (learn/context gates)
- Create: `tests/test_learn.py`

**Interfaces:**
- Consumes: `AXCommand.copy`, `AXCommand.element` (Task 2), `scalarOffset` (Task 1).
- Produces:
  - `Xhisper ax` → one JSON line `{"role": str, "text": str, "caret": int}` (caret in code points, −1 unknown), `{"role": str}` for a focused element without text, `{}` without a focused element.
  - `Xhisper ax --follow` → resolves the focused element once; for each stdin line prints one JSON line for that element, `{"gone": true}` once it is gone (or none was found); exits on stdin EOF.
  - `xhisper-learn`: `is_english(word, platform=sys.platform, words=None) -> bool`, `english_stems(word) -> list[str]`, `config_value(key, default="") -> str`, `app_binary() -> str`, `open_reader()` returning an object with `attach() -> bool`, `role() -> str`, `read() -> (text, caret) | None`, `before_caret(limit) -> str`, `close()`; classes `AtspiReader`, `AxReader`.

- [ ] **Step 1: Write the failing Python tests** — `tests/test_learn.py`:

```python
"""Tests for xhisper-learn's word rules and field readers.

Run: python3 -m unittest discover -s tests -v   (or: make check)
"""
import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = tempfile.mkdtemp()
os.environ["XDG_CONFIG_HOME"] = CONFIG  # never touch the real dictionary


def load():
    path = os.path.join(HERE, "..", "xhisper-learn")
    loader = importlib.machinery.SourceFileLoader("xhisper_learn", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("xhisper_learn", loader))
    loader.exec_module(module)
    return module


learn = load()


def fixes(old, new):
    return learn.corrections(learn.tokenize(old), learn.tokenize(new))


class Rules(unittest.TestCase):
    """The shared learning rules, against this machine's word list."""

    def test_misheard_name(self):
        self.assertEqual(fixes("we deploy to to Ziam now", "we deploy to TOSIAM now"), ["TOSIAM"])

    def test_lowercase_real_change(self):
        self.assertEqual(fixes("deploy with Qulify today", "deploy with coolify today"), ["coolify"])

    def test_accent_fix_not_learned(self):
        self.assertEqual(fixes("la réunion est reporte", "la réunion est reportée"), [])

    def test_pure_insert_not_learned(self):
        self.assertEqual(fixes("ship it", "ship it TOSIAM"), [])

    def test_glued_slip_rejected(self):
        self.assertEqual(fixes("using QLIFY now", "usingcoolifyY now"), [])

    def test_split_word_joined(self):
        self.assertEqual(fixes("the graph QL api", "the GraphQL api"), ["GraphQL"])

    def test_english_word_not_learned(self):
        self.assertEqual(fixes("the hous is red", "the house is red"), [])

    def test_inflected_english_not_learned(self):
        self.assertEqual(fixes("two question here", "two Questions here"), [])

    def test_casing_fix(self):
        self.assertEqual(fixes("ask tosiam", "ask TOSIAM"), ["TOSIAM"])

    def test_long_rewrite_ignored(self):
        self.assertEqual(fixes("a b", "Alpha Beta Gamma Delta Epsilon"), [])


class English(unittest.TestCase):
    WORDS = {"use", "question", "deploy", "ship", "house", "do", "it", "study", "big", "quick", "can"}

    def test_inflections_on_mac(self):
        for w in ["using", "questions", "deployed", "shipping", "houses", "don't", "it's",
                  "studies", "bigger", "quickly", "can't", "Questions"]:
            self.assertTrue(learn.is_english(w, "darwin", self.WORDS), w)

    def test_not_english_on_mac(self):
        for w in ["coolify", "tosiam", "kubectl", "graphql", "TOSIAM"]:
            self.assertFalse(learn.is_english(w, "darwin", self.WORDS), w)

    def test_linux_uses_the_list_only(self):
        self.assertTrue(learn.is_english("use", "linux", self.WORDS))
        self.assertFalse(learn.is_english("using", "linux", self.WORDS))


class Config(unittest.TestCase):
    def write(self, text):
        os.makedirs(os.path.dirname(learn.CONFIG_FILE), exist_ok=True)
        with open(learn.CONFIG_FILE, "w") as f:
            f.write(text)

    def test_absent_key_gives_default(self):
        self.write("auto-edit : true\n")
        self.assertEqual(learn.config_value("learned-sound", "/x.aiff"), "/x.aiff")

    def test_empty_value_is_silent(self):
        self.write("learned-sound :\n")
        self.assertEqual(learn.config_value("learned-sound", "/x.aiff"), "")

    def test_comment_stripped(self):
        self.write("learned-sound : /y.aiff # why\n")
        self.assertEqual(learn.config_value("learned-sound", "/x.aiff"), "/y.aiff")


FAKE_AX = r'''#!/usr/bin/python3
import json, sys
answers = [{"role": "AXTextArea", "text": "héllo wörld", "caret": 5}, {"gone": True}]
assert sys.argv[1:] == ["ax", "--follow"], sys.argv
for i, _ in enumerate(sys.stdin):
    print(json.dumps(answers[min(i, 1)]), flush=True)
'''


class AxReaderProtocol(unittest.TestCase):
    """AxReader against a fake `Xhisper ax --follow` (runs on any OS)."""

    def setUp(self):
        fd, self.fake = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write(FAKE_AX)
        os.chmod(self.fake, stat.S_IRWXU)
        os.environ["XHISPER_APP"] = self.fake

    def tearDown(self):
        os.unlink(self.fake)
        del os.environ["XHISPER_APP"]

    def test_follow(self):
        reader = learn.AxReader()
        try:
            self.assertTrue(reader.attach())
            self.assertEqual(reader.role(), "AXTextArea")
            self.assertEqual(reader.before_caret(3), "llo")
            self.assertIsNone(reader.read())  # second answer: gone
        finally:
            reader.close()

    def test_missing_app(self):
        os.environ["XHISPER_APP"] = "/nonexistent/Xhisper"
        with self.assertRaises(ImportError):
            learn.AxReader()


if __name__ == "__main__":
    unittest.main()
```

Run: `python3 -m unittest discover -s tests -v`
Expected: FAIL — `AttributeError: module 'xhisper_learn' has no attribute 'is_english'` (and on this Mac `test_glued_slip_rejected` / `test_inflected_english_not_learned` fail on web2).

- [ ] **Step 2: Implement in `xhisper-learn`**

2a. `import signal` with the other imports.

2b. After `english_words()` add:

```python
def english_stems(word):
    """Base forms of an inflected word. macOS's list (web2) holds only base
    forms: use, question, deploy - not using, questions, deployed."""
    w = word.lower().replace("’", "'")
    for suffix in ("n't", "'s", "'re", "'ve", "'ll", "'d", "'m"):
        if w.endswith(suffix) and len(w) > len(suffix):
            base = w[:-len(suffix)]
            return [base, base + "n"] if suffix == "n't" else [base]  # can't -> can
    out = []

    def undouble(s):
        return [s[:-1]] if len(s) >= 3 and s[-1] == s[-2] and s[-1] not in "aeiou" else []

    if w.endswith("ies") and len(w) > 4:
        out.append(w[:-3] + "y")
    if w.endswith("es") and len(w) > 3:
        out.append(w[:-2])
    if w.endswith("s") and not w.endswith("ss") and len(w) > 3:
        out.append(w[:-1])
    for suffix in ("ing", "ed", "er", "est"):
        if w.endswith(suffix) and len(w) - len(suffix) >= 2:
            base = w[:-len(suffix)]
            out += [base, base + "e"] + undouble(base)
            if base.endswith("i"):
                out.append(base[:-1] + "y")  # studied, happier
    if w.endswith("ly") and len(w) > 4:
        base = w[:-2]
        out.append(base)
        if base.endswith("i"):
            out.append(base[:-1] + "y")
    return out


def is_english(word, platform=sys.platform, words=None):
    """An ordinary English word? Linux's list has inflected forms; on macOS
    their stems are looked up too."""
    words = english_words() if words is None else words
    low = word.lower()
    if low in words:
        return True
    return platform == "darwin" and any(s in words for s in english_stems(low))
```

2c. In `is_candidate`: `word.lower() in english_words()` → `is_english(word)`. In `merged`: `r.lower() in english_words()` → `is_english(r)`.

2d. `config_value(key)` → `config_value(key, default="")`, returning `default` (instead of `""`) when no line names the key. Body otherwise unchanged.

2e. After `sibling()` add:

```python
def app_binary():
    """Xhisper.app's binary on macOS (exported by xhisper.sh, --local aware)."""
    return os.environ.get("XHISPER_APP") or "/Applications/Xhisper.app/Contents/MacOS/Xhisper"


DEFAULT_LEARNED_SOUND = "/System/Library/Sounds/Glass.aiff" if sys.platform == "darwin" else ""
```

2f. `play()`: `for player in ("paplay", "pw-play"):` → `for player in (("afplay",) if sys.platform == "darwin" else ("paplay", "pw-play")):`.

2g. `announce()` becomes:

```python
def announce(words):
    """Achievement sound and a "Learned: WORD" pill with an Unlearn button."""
    # Never take over the pill while a dictation is showing its own state.
    if not words or dictation_running():
        return
    play(config_value("learned-sound", DEFAULT_LEARNED_SOUND))
    if sys.platform == "darwin":
        # The pill is Xhisper.app; tell it where we are for its Unlearn button.
        notify, env = [app_binary(), "notify"], dict(os.environ, XHISPER_LEARN=os.path.realpath(sys.argv[0]))
    else:
        notify, env = [sibling("xhisper-notify")], None
    try:
        subprocess.Popen(notify + ["learned", "--label", "Learned: " + ", ".join(words),
                                   "--unlearn", ",".join(words), "--timeout", str(LEARNED_PILL_MS)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, env=env)
    except OSError:
        pass
```

2h. Readers — insert after `focused_text_node()` (which stays as is):

```python
class AtspiReader:
    """The focused text field through AT-SPI (Linux). The calls watch() and
    context() used to make inline, moved here unchanged."""

    def __init__(self):
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
        self.Atspi, self.node = Atspi, None

    def attach(self):
        self.node = focused_text_node(self.Atspi)
        return self.node is not None

    def role(self):
        return self.node.get_role_name()

    def read(self):
        """(text, caret), or None once the field went away."""
        try:
            return (self.Atspi.Text.get_text(self.node, 0, -1),
                    self.Atspi.Text.get_caret_offset(self.node))
        except Exception:
            return None

    def before_caret(self, limit):
        try:
            caret = self.Atspi.Text.get_caret_offset(self.node)
            count = self.Atspi.Text.get_character_count(self.node)
            end = caret if 0 <= caret <= count else count
            return self.Atspi.Text.get_text(self.node, max(0, end - limit), end)
        except Exception:
            return ""

    def close(self):
        pass


class AxReader:
    """The focused text field through the macOS Accessibility API, read by
    `Xhisper ax --follow`: it pins the element and answers one JSON line per
    request. The text comes over the pipe, never argv."""

    def __init__(self):
        if not os.access(app_binary(), os.X_OK):
            raise ImportError("Xhisper.app not found")
        self.proc, self.first = None, {}

    def attach(self):
        try:
            self.proc = subprocess.Popen([app_binary(), "ax", "--follow"], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            return False
        self.first = self._ask() or {}
        return "text" in self.first

    def _ask(self):
        try:
            self.proc.stdin.write(b"\n")
            self.proc.stdin.flush()
            line = self.proc.stdout.readline()
            return json.loads(line.decode("utf-8")) if line else None
        except (OSError, ValueError):
            return None

    def role(self):
        return self.first.get("role") or "text field"

    def read(self):
        snap = self._ask()
        if not snap or snap.get("gone") or "text" not in snap:
            return None
        return snap["text"], snap.get("caret", -1)

    def before_caret(self, limit):
        text, caret = self.first.get("text", ""), self.first.get("caret", -1)
        end = caret if 0 <= caret <= len(text) else len(text)
        return text[max(0, end - limit):end]

    def close(self):
        if self.proc:
            try:
                self.proc.kill()
                self.proc.wait(timeout=1)
            except (OSError, subprocess.SubprocessError):
                pass


READER_UNAVAILABLE = ("Xhisper.app not found, not watching" if sys.platform == "darwin"
                      else "AT-SPI (gir1.2-atspi-2.0) unavailable, not watching")


def open_reader():
    """This platform's reader. Raises ImportError/ValueError when the
    accessibility layer is unavailable."""
    return AxReader() if sys.platform == "darwin" else AtspiReader()
```

2i. `watch()` — replace the import block through the polling `try`:

```python
def watch(pasted):
    target = tokenize(pasted)
    if not target:
        return
    try:
        reader = open_reader()
    except (ImportError, ValueError):
        log(READER_UNAVAILABLE)
        return
    try:
        time.sleep(0.3)  # let the paste land
        if not reader.attach():
            log("no readable text field in the focused window, not watching")
            return
        log("watching a %s for %ds" % (reader.role(), WATCH_SECONDS))
        follow(reader, target)
    finally:
        reader.close()


def follow(reader, target):
    pending, since, seen, done = [], 0.0, 0, set()
    located = False
    deadline = time.time() + WATCH_SECONDS
    while time.time() < deadline:
        time.sleep(POLL_SECONDS)
        got = reader.read()
        if got is None:
            log("field went away")
            return
        text, caret = got
        region = locate(target, text, caret)
        # ... the rest of the original loop body, unchanged, from
        # `if region is None:` down to `pending, seen = [], 0` ...
    log("done watching")
```

(Move the original loop body verbatim; only the two lines that read `text`/`caret` from Atspi change.)

2j. `context()`:

```python
def context():
    """Up to CONTEXT_CHARS of readable text before the caret, or nothing."""
    try:
        reader = open_reader()
    except (ImportError, ValueError):
        return ""
    try:
        text = reader.before_caret(4 * CONTEXT_CHARS) if reader.attach() else ""
    finally:
        reader.close()
    text = CHROME_RE.sub(" ", text)
    text = re.sub(r"[ \t\xa0]+", " ", text)
    text = re.sub(r"\s*\n\s*", "\n", text).strip()
    return text[-CONTEXT_CHARS:]
```

2k. `main()`, `context` command:

```python
    elif cmd == "context":
        if sys.platform == "darwin":
            # No `timeout` binary on macOS: never hold up a dictation over 2 s.
            signal.signal(signal.SIGALRM, lambda *_: os._exit(0))
            signal.alarm(2)
        sys.stdout.write(context())
```

2l. Docstring at the top: "Follows the focused text field through AT-SPI" → "through AT-SPI (Linux) or the Accessibility API (macOS, via Xhisper.app)".

Run: `python3 -m unittest discover -s tests -v` → all OK. Also `python3 -I xhisper-learn list` runs.

- [ ] **Step 3: `Xhisper ax` in `macos/AX.swift`** — add inside `enum AXCommand`:

```swift
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)  // also the default for every element
        if let el = element(copy(system, kAXFocusedUIElementAttribute)) { return el }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return element(copy(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute))
    }

    /// role, text and caret (in code points, like Python indices); nil once
    /// the element is gone.
    static func snapshot(_ el: AXUIElement) -> [String: Any]? {
        guard let role = copy(el, kAXRoleAttribute) as? String else { return nil }
        guard let text = copy(el, kAXValueAttribute) as? String else { return ["role": role] }
        var caret = -1
        if let r = copy(el, kAXSelectedTextRangeAttribute), CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) { caret = scalarOffset(text, utf16: range.location) }
        }
        return ["role": role, "text": text, "caret": caret]
    }

    static func emit(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    /// `ax`: one JSON line. `ax --follow`: pin the element, one line per stdin line.
    static func main(_ args: [String]) -> Int32 {
        let el = focusedElement()
        if args.contains("--follow") {
            while readLine() != nil { emit(el.flatMap(snapshot) ?? ["gone": true]) }
        } else {
            emit(el.flatMap(snapshot) ?? [:])
        }
        return 0
    }
```

`macos/main.swift`: `case "ax": exit(AXCommand.main(rest))`.

- [ ] **Step 4: `xhisper.sh` — enable learning and context on Darwin**

Screen context block: replace

```bash
if [ "$screen_context" = "true" ] && [ "$auto_edit" = "true" ] && [ "$OS" != "Darwin" ] \
   && command -v "$XHISPER_LEARN" > /dev/null; then
  timeout 2 "$XHISPER_LEARN" context < /dev/null > "$CONTEXT_FILE" 2>/dev/null &
  CONTEXT_PID=$!
fi
```

with

```bash
if [ "$screen_context" = "true" ] && [ "$auto_edit" = "true" ] \
   && command -v "$XHISPER_LEARN" > /dev/null; then
  if [ "$OS" = "Darwin" ]; then
    # No `timeout` on macOS: xhisper-learn caps itself at 2 s there.
    "$XHISPER_LEARN" context < /dev/null > "$CONTEXT_FILE" 2>/dev/null &
  else
    timeout 2 "$XHISPER_LEARN" context < /dev/null > "$CONTEXT_FILE" 2>/dev/null &
  fi
  CONTEXT_PID=$!
fi
```

Learn watcher: `if [ "$learn_words" = "true" ] && [ "$OS" != "Darwin" ] && command -v …` → drop `&& [ "$OS" != "Darwin" ]`.

- [ ] **Step 5: Real checks in TextEdit and both terminals**

Run: `make check && make`, install as in Task 2 Step 8.

Context, TextEdit: type `Sarah Lindqvist will review the Claude Code patch` in a document, caret at the end, then (from Terminal.app, which has Accessibility for this manual run, or through `xhisper` launched by the agent) `/Applications/Xhisper.app/Contents/MacOS/Xhisper ax | head -c 200` → `{"role":"AXTextArea","text":"Sarah …","caret":49}` (caret = end). Put an emoji early in the text and confirm the caret still equals `len(text)` in Python: `… ax | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["caret"], len(d["text"]))'` → equal numbers (Review Focus 3).

Repeat `ax` with the caret in a Claude Code prompt in Terminal.app and in iTerm2; record role, whether `caret` is −1, and the last 80 chars of `text` (are they the prompt line?). If a terminal reports no text, learning/context there is unsupported — note it for the README table rather than working around it.

Learning, end to end: set `learn-words : true` and `screen-context : true` in `~/.config/xhisper/xhisperrc`. Dictate (hotkey) "we deploy to TOSIAM tomorrow" into TextEdit; if Whisper writes it differently, fix the misheard word by hand, wait 3 s.
Expected: `xhisper --log` shows `Learn: watching a AXTextArea for 60s`, `Learn: fix seen: …`, `Learn: learned: …`; the larger "Learned: WORD" pill with Glass; click **Unlearn** → "Unlearned: WORD" and `xhisper-learn list` no longer has it. Screen context: `Screen context: N chars` (N > 0) in the log, and a dictation of "sara lindkvist" right after the TextEdit text above comes back as "Sarah Lindqvist".

- [ ] **Step 6: CLAUDE.md, commit (ask the user first)**

CLAUDE.md, `xhisper-learn` bullet: append `On macOS the same rules run on the field read by AxReader (\`Xhisper ax --follow\`, macos/AX.swift, caret converted from UTF-16 to code points); AtspiReader holds the Linux AT-SPI calls unchanged. macOS's word list (web2) has no inflections, so is_english() also tries stems there (english_stems). make check runs tests/test_learn.py.`

```bash
git add xhisper-learn xhisper.sh macos/ tests/ CLAUDE.md
git commit -m "feat(macos): word learning and screen context via Accessibility"
```

---

### Task 7: End-to-end verification and docs

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `default_xhisperrc`

**Interfaces:**
- Consumes: everything above, installed.

- [ ] **Step 1: Full run under the agent (USER STEP: speak, or `say` through the speakers)**

For each target — TextEdit, Terminal.app running `claude`, iTerm2 running `claude` — with `old clipboard` copied first (`printf 'old clipboard' | pbcopy`):
1. Option→Control, dictate "so um I think we should uh ship it on Tuesday, no wait, Wednesday", Option→Control.
2. Expected: `So I think we should ship it on Wednesday.` pasted at the cursor (never `old clipboard` — Review Focus 1); `pbpaste` afterwards prints `old clipboard`; in the terminals the text sits in Claude Code's prompt, not submitted; `xhisper --log`: `Class: [com.apple.Terminal]` / `[com.googlecode.iterm2]` with `Terminal: [1]`, tone line for code; `Time:` values sub-second.
3. Escape mid-recording in each: cancelled, nothing pasted, Claude Code not interrupted.
4. Silent run (Option→Control twice without speaking): "No sound" pill with History chip, stays while hovered.
5. History chip during a recording: recording cancelled (Basso), pill flows into the history window; Return copies the newest entry.
6. Learned pill + Unlearn once more in Terminal.app if Task 6 found it readable.
Screenshot each pill state; collect the log excerpts (no transcripts beyond the test sentences).
If the old clipboard gets pasted (race), raise the Darwin wait before the clipboard restore in `paste()`/main (`sleep 0.1` → `sleep 0.3` under `if [ "$OS" = "Darwin" ]`) and repeat.

- [ ] **Step 2: Linux untouched check**

Run: `git diff e9962b3 -- xhisper-notify xhisper-history xhisper-hotkey xhispertool.c` → empty.
Run: `git diff e9962b3 -- xhisper.sh | grep -E '^[-+]' | grep -v Darwin | head -50` and read every changed line: each one is inside a Darwin branch, or is the `show_status`/`hide_status`/`get_active_window*`/`now_seconds`/`instance_alive` restructure with identical Linux behaviour, or the context/learn gate.
Run: `python3 -m unittest discover -s tests -v` (the Linux machine will rerun it).

- [ ] **Step 3: `default_xhisperrc`**

Replace the four sound lines with:

```
# Sounds. Any file paplay/afplay can play, e.g. /usr/share/sounds/freedesktop/stereo/
# (Linux) or /System/Library/Sounds/ (macOS). Escape cancels a recording.
# Leave a key out for the default (silent on Linux; Tink, Pop, Basso and Glass
# on macOS); set it to an empty value to silence it.
# start-sound   : /System/Library/Sounds/Tink.aiff
# stop-sound    : /System/Library/Sounds/Pop.aiff
# cancel-sound  : /System/Library/Sounds/Basso.aiff
# learned-sound : /System/Library/Sounds/Glass.aiff   # with the "Learned: WORD" pill (see learn-words)
```

In the Learning and Screen context comments, "(Linux accessibility, AT-SPI)" → "(AT-SPI on Linux, the Accessibility API on macOS)".

- [ ] **Step 4: README.md**

- Platform support table: set each macOS cell to what Steps 1 and Task 6 Step 5 actually showed (✅ verified, ⏳ with a reason otherwise). Expected rows: toggle hotkey ✅ (CGEventTap agent), pill ✅ (native panel), history ✅, learning/screen context ✅ in TextEdit, terminal cells per Task 6 findings, `--toggle`/Escape/sounds ✅.
- Features list: "Hands-free toggle (X11)" → "(X11 and macOS)", Option then Control on macOS.
- Replace "Installation on macOS" with:

````markdown
## Installation on macOS

Tested on macOS 26 (Apple Silicon). Needs Xcode or the Command Line Tools (for `swiftc`).

### 1. Install dependencies

```sh
brew install sox ffmpeg jq
```

### 2. Get a Groq API key

```sh
echo 'GROQ_API_KEY=<your_API_key>' >> ~/.env
```

### 3. Build and install

```sh
git clone --depth 1 https://github.com/abszar/xhisper.git
cd xhisper
macos/make-cert.sh   # once: a local signing identity, so permissions survive rebuilds
make
sudo make install    # Xhisper.app, the scripts, and the hotkey LaunchAgent
```

### 4. Grant permissions

System Settings → Privacy & Security, enable **Xhisper** in:
- **Accessibility** — paste (Cmd+V), Escape-to-cancel, reading the text field for learning and screen context
- **Input Monitoring** — the Option-then-Control hotkey
- **Microphone** — asked the first time you dictate

### 5. Dictate

Press **Option**, then **Control**: speak, then Option, Control again to paste.
Escape cancels. `xhisper --history` (or double-clicking Xhisper.app) shows past dictations.
````

- macOS troubleshooting: add "Hotkey does nothing: `cat $(getconf DARWIN_USER_TEMP_DIR)xhisper/xhisper-hotkey.log`; after an unsigned rebuild re-enable Xhisper in Accessibility and Input Monitoring." and "Logs: `xhisper --log` (macOS keeps runtime state in `$(getconf DARWIN_USER_TEMP_DIR)xhisper`)." Remove the Automator/Karabiner shortcut section and the "add your terminal app to Accessibility" step.

- [ ] **Step 5: CLAUDE.md**

- Build section: `make` on macOS now builds `build/Xhisper.app` (swiftc) and signs it; `make check` runs the Swift selftest and `tests/test_learn.py` (Linux: the Python tests only); `sudo make install` on macOS installs the app to /Applications, `xhisper`, `xhisper-learn`, wrapper scripts, and the LaunchAgent.
- "There is no unit-test framework" → mention `make check`.
- Files: add a `macos/` bullet: one Swift binary, subcommand per job, logic files selftested, Info.plist (LSUIElement, mic string), signing via `macos/make-cert.sh`.
- Platform split rule: keep `if [ "$OS" = "Darwin" ]`; Swift lives only in `macos/`.

- [ ] **Step 6: Commit (ask the user first), then report**

```bash
git add README.md CLAUDE.md default_xhisperrc
git commit -m "docs: macOS install, permissions, platform table"
```

Final message ends with the section **`Other platform (Linux)`** (CLAUDE.md parity rule): verdict "Partly / nothing but pull": Linux behaviour unchanged; after `git pull && sudo make install`, run `make check` (new `tests/test_learn.py`); refactors touching Linux: `xhisper-learn` reader split (AtspiReader), `is_english()` (list-only on Linux), `config_value(key, default)`, `xhisper.sh` `show_status`/`hide_status` restructure. Ask the Linux agent to re-run a learning test in Tilix to confirm the AtspiReader move.
