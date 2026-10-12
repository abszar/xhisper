# macOS parity — design

Date: 2026-10-12. Status: approved in chat, pending spec review.

## Goal

Same xhisper experience on the Mac (macOS 26.6, Apple M4) as on Ubuntu/GNOME
X11, without changing Linux behaviour. Covers: Option→Control toggle hotkey,
overlay pill (all states, live waveform, History chip, Learned/Unlearn pill),
Escape cancel, sounds, history window, word learning, screen context, install.
Auto-edit stays as is (shared code).

## Decisions (from the user)

- Native parts in **Swift**: one app bundle, no Xcode project, built by `make`.
- Signing: **self-signed "xhisper Code Signing" cert** in the login keychain,
  created once; ad-hoc fallback when absent.
- Audio: keep **sox `rec`** (`brew install sox`).
- Sound defaults on Darwin when the key is absent from xhisperrc: start
  `Tink.aiff`, stop `Pop.aiff`, cancel `Basso.aiff`, learned `Glass.aiff`
  (`/System/Library/Sounds`). A key present with an empty value = silent.
- Test pastes into TextEdit, **Terminal.app and iTerm2** (both running Claude Code).
- **No** forcing of Chrome/Electron accessibility (`AXManualAccessibility`): same
  limitation as Linux.

## Environment found

- system `python3` 3.9.6, no PyObjC → the current Darwin key loop exits 3.
- `/bin/bash` 3.2: no `$EPOCHREALTIME` (whole-second timing), no `timeout`.
- no sox; ffmpeg/jq/curl present. No `~/.env`, no `~/.config/xhisper`.
- no code-signing identity. `/usr/share/dict/words` is web2 (larger than
  Linux's list, so a few more words count as "ordinary English").

## Layout

```
macos/
  Info.plist            bundle id io.github.abszar.xhisper, LSUIElement,
                        NSMicrophoneUsageDescription
  main.swift            subcommand dispatch
  Runtime.swift         runtime dir, pid helpers, spawn-detached, process scan
  Hotkey.swift          `hotkey`
  Overlay.swift         `notify`
  History.swift         `history`
  AX.swift              `ax`, `front`
  Paste.swift           `paste`
  make-cert.sh          creates + trusts the signing cert (one password dialog)
  io.github.abszar.xhisper.hotkey.plist   LaunchAgent template
```

`make` on Darwin: `swiftc -O` all sources → `build/Xhisper.app/Contents/MacOS/Xhisper`,
copies Info.plist, `codesign -s "xhisper Code Signing"` (or `-s -`).

`sudo make install` on Darwin:
- `/Applications/Xhisper.app`
- `/usr/local/bin/xhisper` (script), `/usr/local/bin/xhisper-learn` (shared Python)
- `/usr/local/bin/xhisper-notify`, `xhisper-history`, `xhisper-hotkey`: 2-line
  shell wrappers `exec /Applications/Xhisper.app/Contents/MacOS/Xhisper <sub> "$@"`
- LaunchAgent into `~$SUDO_USER/Library/LaunchAgents/`, owned by that user,
  then `launchctl bootout`/`bootstrap gui/<uid>` so a reinstall restarts the agent.
`sudo make uninstall` reverses all of it. Linux targets unchanged.

`xhisper.sh --local` on Darwin uses `./build/Xhisper.app` and `./xhisper-learn`.

## Swift subcommands

All share the runtime dir rule: `$XHISPER_RUNTIME_DIR`, else
`$XDG_RUNTIME_DIR/xhisper`, else `DARWIN_USER_TEMP_DIR/xhisper` (per-user, 0700).

### `hotkey` (LaunchAgent, KeepAlive, RunAtLoad)

- Active `CGEventTap` (session) on flagsChanged, keyDown, keyUp.
- Fire rule (mirrors the X11 `Mod1Mask` grab): a flagsChanged where Control
  (left 59 or right 62) goes down while Option is already held and no Command
  or Shift; Caps Lock ignored. Control-then-Option never matches.
- Debounce: after firing, re-arm only once both Controls are up. Modifiers do
  not auto-repeat on macOS, but the rule stays explicit.
- Launches `xhisper --toggle` once (posix_spawn, new session, stdio /dev/null).
  `XHISPER_CMD` overrides the command, like Linux.
- Event passes through (listen semantics for modifiers), so Option+Control
  shortcuts still reach apps — they also toggle, as documented for Linux.
- Escape: while `$RUNTIME/xhisper.listening` names a live pid, swallow Escape
  keyDown/keyUp and create `$RUNTIME/xhisper.cancel`. Otherwise pass it through.
- Re-enables the tap on `tapDisabledByTimeout/UserInput`.
- Single instance: `flock` on `$RUNTIME/xhisper-hotkey.lock`.
- No permission: logs to `$RUNTIME/xhisper-hotkey.log`, prompts once via
  `AXIsProcessTrustedWithOptions`, retries tap creation every 2 s.
- LaunchAgent sets `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.

### `notify <state> [--timeout MS] [--label TEXT] [--unlearn W,...]`

Port of `xhisper-notify`, same CLI and states (recording, transcribing,
editing, done, silent, error, cancelled, learned, hide).
- Borderless non-activating `NSPanel`, `canBecomeKey = false`, transparent,
  level `.statusBar`, `.canJoinAllSpaces + .fullScreenAuxiliary`, accessory
  activation policy. Bottom centre of the screen holding the mouse, 55 pt above
  the visible frame bottom, 60 pt slide-up, same fade/slide speeds.
- Same geometry/colours/fonts: 17 bars 5 pt wide, gap 4, pill 48 pt (60 for
  learned), chip 72×28 (92×36), same BASE_HEIGHTS and per-state bar animations.
- Live level meter: same algorithm (last 1600 bytes of the WAV every 45 ms,
  RMS dBFS, noise floor +0.05/tick, peak −0.3/tick, min span 18 dB, attack 0.7,
  release 0.35), sine fallback until audio. Reads `$XHISPER_RECORDING`.
- History chip on recording/silent when the history file is non-empty.
  Click: recording → touch `$XHISPER_HISTORYFLAG`; spawn `xhisper-history`
  detached; 280 ms lift (40 pt) + fade, then exit. Pointer cursor on hover,
  close deferred while the pointer is inside.
- Learned pill: no waves, bigger text, Unlearn chip runs
  `xhisper-learn remove WORD...` (resolved from `$XHISPER_LEARN`, else
  `/usr/local/bin/xhisper-learn`), label "Unlearned: W", closes after 1.4 s.
- Single overlay: claim `xhisper-notify.pid` before building the window;
  kill only *older* overlays (pid slot + scan of processes whose executable is
  this binary with argv[1] == "notify", compared by start time); SIGTERM then
  SIGKILL after 0.5 s; release the slot only if it still names us.
  `XHISPER_OVERLAY_MAX_SECONDS` caps lifetime (default 900).

### `history`

Port of `xhisper-history`: dark window (#1a1a1a, entries #262626 radius 12),
title "Dictation history", newest first, per entry time label (Today/Yesterday
HH:MM, else dd Mon HH:MM), selectable text, Copy and Edit buttons. Copy →
`NSPasteboard` (persists after exit), "Copied" for 1.2 s. Initial focus on the
newest Copy (Enter copies it), Escape cancels an edit or closes. Edit → text
view + Save/Cancel; Save runs `xhisper-learn diff` with `{"old","new"}` on
stdin, rewrites the entry atomically (umask 077, tmp + rename, matched on time
and old text), subtitle "Learned: W" or "Saved" for 3.5 s. Live refresh via a
file-system watch (deferred during an edit). Single window: `xhisper-history.pid`;
a second launch sends SIGUSR1 to raise it and exits. 220 ms fade + 24 pt rise.

### `ax [--follow]`, `front`, `paste [--shift]`

- `ax`: focused UI element of the frontmost app (system-wide
  `AXFocusedUIElement`, messaging timeout 1 s) → one JSON line
  `{"role","text","caret"}` (`AXValue`, `AXSelectedTextRange.location`), or
  `{}` when there is none. Text never goes to argv or the log.
- `ax --follow`: resolves the element once, then answers each stdin line with
  a JSON line for that same element, `{"gone":true}` when it disappears.
- `front`: `bundleId\tappName\twindowTitle` (NSWorkspace + AX `AXFocusedWindow`
  title). Used as class/title for tone and terminal detection.
- `paste`: CGEvent Cmd+V (virtual key `kVK_ANSI_V`, layout position like the
  Linux uinput Ctrl+V), posted at the HID tap. `--shift` adds Shift.

## Script and Python changes (Darwin branches; Linux untouched)

`xhisper.sh`
- Runtime dir default on Darwin: `$(getconf DARWIN_USER_TEMP_DIR)xhisper`.
- Darwin: prepend `/opt/homebrew/bin:/usr/local/bin` to PATH; resolve the app
  binary (installed or `--local`); export `XHISPER_LEARN`.
- Darwin sound defaults (above), applied before the config parse.
- Key loop, darwin branch: CoreGraphics via ctypes (`CGEventSourceKeyState`,
  no PyObjC); writes `xhisper.listening` (its pid) for the loop's duration and
  treats `xhisper.cancel` as Escape (exit 4). Both files cleared by cleanup.
- Paste: `Xhisper paste` (osascript only if the app is missing). Terminals get
  plain Cmd+V on macOS — Cmd+Shift+V is "Paste Selection" in Terminal.app
  (verify in Terminal.app and iTerm2 before changing).
- Window detection via `Xhisper front` → class = bundle id, title = window title.
- `learn-words` / `screen-context` no longer gated off on Darwin; `context`
  runs without the `timeout` binary (xhisper-learn enforces 2 s itself).
- `instance_alive`: when `/proc` is absent, check `ps -p PID -o command=`.
- Missing-dependency message for Darwin names `brew install sox`.

`xhisper-learn`
- Rules (`corrections`, `is_candidate`, `merged`, `locate`, settle/sent logic)
  unchanged and shared.
- Refactor (touches the Linux path, behaviour-preserving): `watch()` and
  `context()` read the field through a reader object with `text_and_caret()`
  and `role()`. `AtspiReader` = the existing AT-SPI code moved verbatim;
  `AxReader` = a `Xhisper ax --follow` coprocess (darwin).
- `play()`: afplay on darwin; `learned-sound` default Glass on darwin when the
  key is absent.
- `dictation_running()` unchanged (pid file).

Python `xhisper-notify`, `xhisper-history`, `xhisper-hotkey`: untouched, Linux only.

## Privacy rules kept

Runtime state in a 0700 per-user dir; dictated text never in argv (stdin /
files in the runtime dir; `ax` output read over a pipe); API keys via
`curl -K -`; history 0600 under 0700; the learn log never contains dictated
text; screen context only logged by length.

## Permissions (Xhisper.app)

- Accessibility: event tap that swallows Escape, posting Cmd+V, reading
  focused fields (learning, screen context, window title).
- Input Monitoring: the keyboard event tap and `CGEventSourceKeyState`.
- Microphone: prompted on first recording (`rec` runs under the agent).
Terminal.app/Claude app need their own grants only when xhisper is run from them.

## Testing

- Rules regression on python 3.9 with the macOS word list (TOSIAM, coolify,
  GraphQL join, glued-word slip, accent fix rejected).
- `bash -n` and a full run under `/bin/bash` 3.2.
- Real, through the LaunchAgent: Option→Control start/stop, Control→Option
  does nothing, holding Control does not double-fire; dictation pasted into
  TextEdit, Terminal.app + Claude Code, iTerm2 + Claude Code; Escape cancels
  without interrupting Claude Code; History chip during recording; silent pill;
  learned pill after a fix in TextEdit and Unlearn; history Copy/Edit;
  `Screen context: N chars` in the log. Screenshots of each pill.
- Linux: no behaviour change; the other machine verifies with a pull and the
  regression set (see CLAUDE.md parity section).
