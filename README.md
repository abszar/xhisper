<div align="center">
  <h1>xhisper</h1>
  <img src="demo.gif" alt="xhisper demo" width="300">
  <br><br>
</div>

Voice-to-text dictation at cursor for **Linux and macOS**. Based on [imaginalnika/xhisper](https://github.com/imaginalnika/xhisper) with push-to-talk, AI auto-editing, tone adaptation, animated status overlay, keyboard layout compatibility, and clipboard manager integration.

## Features

- **Linux and macOS** — Works on X11, Wayland, and macOS. Key release detection uses XQueryKeymap on X11, evdev on Wayland, and CoreGraphics on macOS
- **Push-to-talk** — Hold your shortcut key to record, release to transcribe. No double-press needed. A duplicate invocation while a recording is live is ignored (holding a key auto-repeats, and the desktop relaunches the command on every repeat); `xhisper --stop` ends a recording on purpose and can be bound to a second key
- **Hands-free toggle (X11 and macOS)** — With `xhisper-hotkey` (X11) or Xhisper.app's hotkey agent (macOS), press Alt (Option) then Ctrl once to start recording and again to stop. No key to hold, and a modifier-only combo that GNOME shortcuts and macOS Services cannot bind
- **Sound cues** — Optional `start-sound`, `stop-sound`, `cancel-sound` and `learned-sound` play when recording starts, stops, is cancelled, or a word is learned
- **Escape to cancel** — Press Escape while recording to throw the recording away (the key is swallowed, so it does not also reach the focused app: grabbed on X11, eaten by the hotkey agent on macOS)
- **Live waveform** — While recording, the pill's bars follow your voice (they read the level of the audio being recorded), and drop to dots when you pause
- **Learns your words** — Fix a misheard name once ("to Ziam" → "TOSIAM") right where it was pasted, or in the History window, and xhisper adds it to your dictionary. Learned words are sent to Whisper as spelling hints and to the auto-edit model as vocabulary
- **Dictation history** — The last 20 dictations (`history-size`) are kept in a private file. Open them with `xhisper --history`, or with the **History** chip on the Recording / No sound pill (also Failed / Cancelled on macOS); each one has **Copy** and **Edit** icon buttons, plus **Paste** when a text field had the focus (macOS for now)
- **AI auto-editing** — Removes filler words and stutters, applies spoken self-corrections ("Tuesday, no wait, Wednesday"), turns "new line" into a real line break, and fixes punctuation — without ever rewriting your wording. If the model errors out, times out, or returns something suspicious, the raw transcription is pasted instead, so a bad API response never costs you a dictation
- **Tone adaptation** — Detects the active window (Slack, Gmail, VS Code, etc.) and lets it influence punctuation and formatting — light for chat, full sentences for email, no Markdown in a terminal. It never changes your words or the length
- **Personal dictionary** — Add custom words, names, and technical terms to `~/.config/xhisper/dictionary.txt` (or `xhisper-learn add WORD`) to improve Whisper's recognition accuracy; the auto-edit model gets them too, so near-misses are respelled
- **Animated status overlay** — One dark pill per dictation slides up from the bottom of the screen when you start recording, stays put while it transcribes and edits (same size and place; only its text turns to "Transcribing" and the bars settle into a slow wave, no new pop-up per stage), and fades out once the text is pasted — no separate "Done" pill (falls back to desktop notifications if GTK is unavailable)
- **Smart paste** — Detects the active window *class* and uses the correct paste shortcut (Ctrl+V, Ctrl+Shift+V for terminals on Linux; plain Cmd+V everywhere on macOS, since Cmd+Shift+V is "Paste Selection" in Terminal.app). Works natively with AZERTY, QWERTZ, or any keyboard layout
- **Multi-language transcription** — Whisper auto-detects the spoken language by default, so you can switch between English, French, Spanish, etc. and each is transcribed in its own script. Set `language : en` (or any ISO 639-1 code) in the config to force a specific language
- **Stability** — PID-file based concurrency control prevents duplicate instances from interfering with each other. Recordings are capped by `max-recording-seconds`, and every network call has a timeout. On X11, if a suspend left xhisper's virtual keyboard detached (the text was transcribed but never pasted), the next dictation notices it while you speak and restarts `xhispertoold`
- **Custom STT/LLM endpoints** — Use Groq's API by default, or point to any OpenAI-compatible endpoint — local Whisper servers, Ollama, vLLM, or any other provider
- **Smart spacing** — A dictation pasted right after a word or a full stop gets a leading space, so two dictations in a row never glue together ("goes.Ok"). Only the one character before the cursor is read. Where an app does not expose its text (cmux), xhisper remembers the end of its own last paste into that app for two minutes instead. `smart-spacing : false` turns it off
- **Clipboard preservation** — Your clipboard content is saved before transcription and restored after pasting
- **Clipboard manager cleanup** — Automatically removes xhisper's temporary clipboard entries from CopyQ history
- **Private by default** — The recording, the log of everything you dictated, and the request sent to the LLM live in a 0700 directory under `$XDG_RUNTIME_DIR`, never in world-readable `/tmp`. API keys are handed to `curl` over stdin so they never appear in `ps`

---

## Platform support

| Feature | Linux | macOS |
|---|---|---|
| Hold-to-talk dictation, paste at cursor | ✅ | ✅ toggle (tap Option → Control), native Cmd+V (TextEdit verified); hold-to-talk (keep Control held) ✅ (TextEdit, iTerm2) |
| AI auto-edit, tone adaptation, answer guard | ✅ | ✅ (shared code) |
| Personal dictionary (Whisper hints + auto-edit vocabulary) | ✅ | ✅ (shared code) |
| `--toggle` mode, Escape to cancel, sound cues | ✅ | ✅ (toggle and Escape verified in TextEdit; the agent swallows Escape) |
| Alt → Ctrl toggle hotkey | ✅ X11 (`xhisper-hotkey`) | ✅ Xhisper.app hotkey LaunchAgent |
| Overlay pill with live waveform, History chip, Learned/Unlearn pill | ✅ | ✅ native panel |
| One pill per dictation, updated in place (no per-stage pop-ups, no Done pill) | ✅ (SIGUSR1 hand-off; pill keeps its size and History chip, text turns to "Transcribing"; real dictations 2026-10-14) | ✅ same design (pill keeps its size and History chip, text turns to "Transcribing", bars ease into the wave; real dictations in TextEdit and Chrome 2026-10-14) |
| Upload starts beside the silence check and window lookup; duration read from the WAV header | ✅ (pw-record writes a plain 44-byte header: same duration as ffprobe, after SIGTERM or SIGKILL) | ✅ |
| No pause after the recorder stops or around the paste keystroke; stop-to-paste time logged | ✅ (0.79–0.84 s in a terminal) | ✅ (rec/sox WAV complete right after `wait`: same size and header 0.3 s later; 0.90 s TextEdit, 1.10 s Chrome with a 18 s dictation) |
| History window (Copy, Edit) | ✅ | ✅ native window |
| History: icon buttons, Paste into the field focused before opening | ✅ (2026-10-18: ↩ into GNOME Text Editor, ↩ into Tilix with Ctrl+Shift+V, a click on an older row's Paste in Chrome; never types when the target is no longer the active window) | ✅ (not yet tested by hand) |
| History window redesign (panel, hover actions, edit mode, toasts, live arrival) | ✅ (2026-10-18: hover actions, edit + save learned a word, Learned toast, Unlearn; closes on a click elsewhere and when a dictation starts) | ✅ (not yet tested by hand) |
| Double tap of the hotkey opens History (↩ then pastes the newest) | ✅ (2026-10-18: recording cancelled, pill rises into History, ↩ pastes; `xhisper-hotkey`) | ✅ (not yet tested by hand) |
| Pill redesign (points geometry, in-place Failed/No sound/Cancelled, Editing label) | ✅ (2026-10-18: real dictations; in-place No sound and the refused hand-off checked on a headless X server) | ✅ (not yet tested by hand) |
| Learning from corrections (`xhisper-learn`), screen context | ✅ AT-SPI | ✅ Accessibility API in TextEdit; Terminal.app exposes its text (read check only); iTerm2: screen context ✅, learning watcher attaches (a correction there not yet tested). Chrome/Electron: not forced, same limit as Linux |
| Smart spacing between dictations (`smart-spacing`) | ✅ AT-SPI (GTK field, Tilix, Chrome textarea: empty field, after ".", after a space and "("; a later fix is still learned); last-paste fallback ✅ for unreadable fields (same app within 2 min, not another app, not after 2 min). Chrome ✅ re-tested 2026-10-12 after the stale-document fix: claude.ai composer (one space after "finished?", none on an empty new paragraph or in an empty composer), Gmail body (same three), plain textarea (empty, after "?", new line, after "("); GTK Text Editor and Tilix unchanged ✅ | ✅ TextEdit (empty field, after ".", after a space and "("; a later fix is still learned), Chrome (address bar, claude.ai rich editor: one space after text, none on an empty new line); cmux ✅ via the last-paste fallback (its terminal exposes no text, so no learning there) |
| Silent recordings discarded, even with a hotkey click in them (`min-speech-seconds`) | ✅ real microphone (TONOR, Alt → Ctrl toggle): 5.5 s of silence with the hotkey clicks discarded (Voiced 0.24 s), "yes" kept (0.51 s), a sentence kept (1.41 s); test files ✅ (silence, noise, one or two clicks discarded; speech 30 dB quieter kept) | ⏳ real microphone (TONOR, Option → Control toggle): silence measured 0.00 s (discarded) and 0.30 s (kept: Whisper returned "." and it was pasted); "yes" kept (0.48 s), a sentence kept (1.02 s) |
| Paste and Escape inside Claude Code in Terminal.app / iTerm2 | ✅ | ✅ iTerm2 (tap, hold, Escape not reaching Claude Code); Terminal.app ⏳ untested |
| Top bar button: click to start/stop, middle click or menu to stop and send (Enter after the paste) | ✅ X11 (`xhisper-tray`, 2026-10-18: Tilix, Claude Code prompt sent with the menu and with a middle click) | ⏳ (no menu bar item yet; `--send` logs "not supported") |
| Paste keyboard repaired after a suspend left it detached | ✅ X11 (device floated with `xinput disable`: caught and daemon restarted, 2026-10-16) | — not needed (Cmd+V goes through Xhisper.app, no uinput device) |

Developers and agents: after any change, say whether the other platform needs work (see CLAUDE.md, "Cross-platform parity") and keep this table current.

## Installation on Ubuntu

### 1. Install dependencies

```sh
# X11 (clipboard: xclip)
sudo apt update
sudo apt install pipewire jq curl ffmpeg gcc xclip python3 python3-gi gir1.2-gtk-3.0 xdotool x11-utils

# Wayland: install wl-clipboard instead of xclip
sudo apt install wl-clipboard
```

`xdotool` / `x11-utils` (for `xprop`) are what let xhisper see which window is
focused, which drives tone adaptation and the terminal paste shortcut. Without
them everything still works, just with the default tone and Ctrl+V everywhere.

### 2. Add user to input group

```sh
sudo usermod -aG input $USER
```

Then **log out and log back in** (restart is safer) for the group change to take effect.

Verify by running:

```sh
groups
```

You should see `input` in the output.

### 3. Set up uinput permissions

```sh
echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger /dev/uinput
```

### 4. Get a Groq API key (or use a local server)

Get a free API key from [console.groq.com](https://console.groq.com) and add it to `~/.env`:

```sh
echo 'GROQ_API_KEY=<your_API_key>' >> ~/.env
```

Or skip this step if you'll use a local Whisper/LLM server — see [Custom STT/LLM Endpoints](#custom-sttllm-endpoints).

### 5. Clone, build, and install

```sh
git clone --depth 1 https://github.com/abszar/xhisper.git
cd xhisper && make
sudo make install
```

### 6. Set up a keyboard shortcut (GNOME)

Run the following in a terminal to bind xhisper to a key. Change `binding` to your preferred shortcut:

```sh
name="xhisper"
binding="Pause"  # Pause/Break key. Other examples: "<Alt>d", "<CTRL><SHIFT>X"
action="/usr/local/bin/xhisper"

media_keys=org.gnome.settings-daemon.plugins.media-keys
custom_kbd=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding
kbd_path=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/$name/
new_bindings=$(gsettings get $media_keys custom-keybindings | sed -e"s>'\]>','$kbd_path']>" | sed -e"s>@as \[\]>['$kbd_path']>")
gsettings set $media_keys custom-keybindings "$new_bindings"
gsettings set $custom_kbd:$kbd_path name "$name"
gsettings set $custom_kbd:$kbd_path binding "$binding"
gsettings set $custom_kbd:$kbd_path command "$action"
```

#### Alternative: press Alt, then Ctrl — no holding (X11)

GNOME shortcuts need a regular key, so a modifier-only combo cannot be bound
above. `xhisper-hotkey` (installed by `make install`) fills that gap and works
as a toggle: press **Alt**, then **Ctrl** (left or right) once to start
recording, speak with your hands free, then press Alt then Ctrl again to stop
and transcribe. The order matters: Ctrl then Alt does nothing, and Ctrl alone is
untouched. Start it at every login with:

```sh
cp xhisper-hotkey.desktop ~/.config/autostart/
/usr/local/bin/xhisper-hotkey &   # start it now without logging out
```

Notes:
- X11 only (on Wayland, use a regular shortcut as above).
- It does not fire while another program holds the keyboard — e.g. Deskflow
  while the cursor is on the other machine.
- Alt-first shortcuts like Ctrl+Alt+T still work, but they also toggle
  recording. Press Ctrl first for those.
- Each press runs `xhisper --toggle`. Do not bind `--toggle` to a regular
  desktop shortcut: holding a key auto-repeats, and every repeat would toggle.
- Set `start-sound`, `stop-sound` and `cancel-sound` in `xhisperrc` for audio cues.
- Press Escape to cancel a recording.
- Remove the Pause binding above if you don't want both shortcuts.

#### Alternative: a button in the top bar (X11)

`xhisper-tray` (installed by `make install`) puts the xhisper mark in the top
bar's tray: click it to start dictating, click again to stop. The mark turns
coral while recording and dims while the text is transcribed and pasted.
**Middle-click** it (or right-click → *Stop and send (Enter)*) to stop and press
Enter after the paste, which sends a chat message or a Claude Code prompt
(`xhisper --send` does the same from a script). Tick *Send with Enter every
time* in the right-click menu to make every stop from the button send. Right-click
also opens History.

```sh
cp xhisper-tray.desktop ~/.config/autostart/
/usr/local/bin/xhisper-tray &   # start it now without logging out
```

It needs a tray in the top bar: on Ubuntu the AppIndicators extension shows it
(its legacy tray is on by default). Not a double click to send: GNOME's
microphone indicator appears while recording and moves the tray icons on stop.

---

## Installation on macOS

Tested on macOS 26 (Apple Silicon). Needs Xcode or the Command Line Tools (for `swiftc`).

### 1. Install dependencies

```sh
brew install sox ffmpeg jq
```

### 2. Get a Groq API key (or use a local server)

Get a free API key from [console.groq.com](https://console.groq.com) and add it to `~/.env`:

```sh
echo 'GROQ_API_KEY=<your_API_key>' >> ~/.env
```

Or skip this step if you'll use a local Whisper/LLM server — see [Custom STT/LLM Endpoints](#custom-sttllm-endpoints).

### 3. Build and install

```sh
git clone --depth 1 https://github.com/abszar/xhisper.git
cd xhisper
macos/make-cert.sh   # once: a local signing identity, so permissions survive rebuilds
make
sudo make install    # Xhisper.app, the scripts, and the hotkey LaunchAgent
```

`macos/make-cert.sh` asks for your login password once (it trusts the new certificate for code signing). Without it the app is signed ad hoc and macOS forgets its permissions after every rebuild.

### 4. Grant permissions

System Settings → Privacy & Security, enable **Xhisper** in:
- **Accessibility** — paste (Cmd+V), Escape-to-cancel, reading the text field for learning and screen context
- **Input Monitoring** — the Option-then-Control hotkey
- **Microphone** — asked the first time you dictate

### 5. Dictate

Press **Option**, then **Control**: speak, then Option, Control again to paste. Or hold it: keep Control down (0.4 s or more) while you speak, and the recording stops when you let go.
Escape cancels. `xhisper --history` (or double-clicking Xhisper.app) shows past dictations.

The order matters: Control then Option does nothing. Shortcuts that start with Option (say Ctrl+Opt+arrow pressed Option first) also toggle a recording, so press Control first for those, same as on Linux.

If you run from a checkout inside `~/Documents` (`xhisper.sh --local`), macOS may ask to let Xhisper access Documents; allow it.

---

## Usage

**Hold** your shortcut key to record, **release** to stop and transcribe. The transcribed text is pasted at your cursor. On macOS the same Option → Control combo does both: tap it to toggle, or keep Control held to talk and release to stop.

To end a recording without releasing the key, run **`xhisper --stop`** — bind it
to a second shortcut if you want a stop key. Pressing the dictation hotkey again
deliberately does nothing: holding a key auto-repeats (X11 defaults to 33
presses per second), and the desktop relaunches the command on every repeat, so
a duplicate invocation cannot be told apart from the press you are still holding.

**Toggle mode (no holding):** with [`xhisper-hotkey`](#alternative-press-alt-then-ctrl--no-holding-x11)
running (on macOS, the hotkey agent installed with Xhisper.app; **Option** then **Control**), press **Alt** then **Ctrl** once to start recording and once more to
stop and transcribe. It runs `xhisper --toggle`, which records until the next
`--toggle` (or `max-recording-seconds`).

**Cancel:** press **Escape** while recording. The recording is discarded and
`cancel-sound` plays.

**History:** `xhisper --history` (on macOS also a double tap of the Option→Control hotkey) opens a window with your last dictations
(newest first). **Copy** puts an entry on the clipboard; **Edit** turns it into
a field you fix and save. On macOS, when a text field had the focus as the
window opened, **Paste** closes the window and pastes the entry into that field
(Enter does it for the highlighted entry, ↑/↓ move the highlight); there the
actions show on hover, a saved edit confirms with a toast, and new dictations
appear while the window is open. The Recording and No sound pills (on macOS
also Failed and Cancelled) carry a **History** chip: clicking it while recording
stops listening (like a cancel) and the pill slides into the history window. Kept: the last
`history-size` dictations (default 20, `0` keeps none) in
`~/.local/state/xhisper/history.jsonl`, readable only by you. **Edit** fixes a
dictation in place and learns the words you corrected.

**Learning words:** with `learn-words : true`, xhisper follows the field it
pasted into for a minute (through AT-SPI on Linux or the Accessibility API on macOS). Replace a
misheard word there — say "to Ziam" with "TOSIAM" — and once the fix has sat
for three seconds (or is sent with Enter), the new word is added to your
dictionary. A *Learned: WORD* pill confirms it, with an optional
`learned-sound`; it stays about six seconds (longer while your pointer is on
it) and its **Unlearn** button takes the word back out if the fix was a
mistake. Only words that replace dictated words and are not ordinary
English are learned; an all-lowercase word must also be a real change of word
("Qulify" → "coolify"), so typo and accent fixes teach nothing. It works where the app exposes its text (GTK apps, terminals such as
Tilix/GNOME Terminal, Firefox; on macOS TextEdit and Terminal.app; Chrome and Electron apps only with accessibility
on, which xhisper does not force). The text is read in memory only; only learned words are stored. Manage
the list with `xhisper-learn list | add WORD | remove WORD`.

An animated wave pill overlay slides up from the bottom of your screen showing the current state:
- **Recording** — wave bars that follow your voice (with an optional `start-sound` cue), plus a **History** chip
- **Transcribing** — gentler pulse while Whisper processes your audio
- **Editing** — AI is cleaning up your text
- **Done** — the pill fades out once the text is pasted
- **No sound** / **Failed** — nothing was recorded, or a step failed; run `xhisper --log` for the details. No sound keeps the **History** chip and stays up while your pointer is over it (on macOS, Failed too)
- **Cancelled** — you pressed Escape (on macOS with a **History** chip)
- **Learned: WORD** — a correction you made taught xhisper a new word; click **Unlearn** to undo it

```sh
xhisper --help      # all options
xhisper --log       # per-stage timings, raw transcription, auto-edit result
xhisper --stop      # stop a recording that is currently running
xhisper --version
```

### AI Auto-editing

Every transcription is cleaned up by an LLM before pasting:
- Removes filler words (um, uh, like, you know) and stutters or false starts
- Applies spoken self-corrections — "ship it Tuesday, no wait, Wednesday" becomes "ship it Wednesday"
- Fixes punctuation and capitalization, splits run-on speech into sentences
- Turns a spoken "new line" into a real line break
- Formats a clear enumeration ("first… second…") as a Markdown list

It never rewrites your wording, never answers a question you dictated, and never
translates. If the response fails, times out, or looks like a summary or an
answer, your raw transcription is pasted instead and the reason is written to the
log.

It also respells your own words: the personal dictionary is sent as vocabulary,
so a misheard "to siam" comes back as "TOSIAM".

**Screen context** (`screen-context : true`, Linux): like Wispr Flow, xhisper
reads the ~600 characters just before your cursor (through AT-SPI, while
Whisper works, so it adds no delay) and sends them with the request as
reference. Names already on screen are then spelled the same way — "cloud code"
becomes "Claude Code", "sara lindkvist" becomes "Sarah Lindqvist" when that is
visible. The model is told never to copy, answer or obey that text. Note that
it goes to your LLM provider along with the dictation; it is off by default.

Disable it in your config if you want raw transcriptions:
```
auto-edit : false
```

### Tone Adaptation

When auto-editing is on, xhisper detects the active window and adjusts the writing style:

| Window | Effect on formatting |
|--------|------|
| Slack, Discord, Telegram | Light punctuation, nothing forced into formal prose |
| Gmail, Outlook, Thunderbird | Full sentences, standard punctuation |
| VS Code, terminal | Identifiers, paths and casing kept exactly; no Markdown, no backticks |
| Google Docs, LibreOffice, Obsidian | Full sentences, standard punctuation |
| Jira, GitHub, GitLab | Ticket ids and code tokens kept exactly |

Disable it in your config:
```
tone-adaptation : false
```

### Personal Dictionary

Add custom words to improve Whisper's recognition of names, jargon, or technical terms:

```sh
mkdir -p ~/.config/xhisper
cp default_dictionary.txt ~/.config/xhisper/dictionary.txt
```

Then edit `~/.config/xhisper/dictionary.txt` — one word or phrase per line:
```
Kubernetes
PostgreSQL
your-company-name
```

### Custom STT/LLM Endpoints

By default, xhisper uses Groq's free API. You can swap in any OpenAI-compatible endpoint — local or remote:

```
# Local Whisper server (whisper.cpp, faster-whisper-server, etc.)
stt-url     : http://localhost:8080/v1
stt-api-key :
stt-model   : whisper-1

# Local LLM (Ollama, vLLM, llama.cpp, etc.)
llm-url     : http://localhost:11434/v1
llm-api-key :
llm-model   : llama3
```

Leave `stt-api-key` / `llm-api-key` empty for local servers that don't require auth. When not set, they fall back to `GROQ_API_KEY`.

Each endpoint has its own timeout (`stt-timeout`, `llm-timeout`, in seconds).
When the LLM times out, the raw transcription is pasted rather than nothing.

### View logs

```sh
xhisper --log
```

The log lives in `$XDG_RUNTIME_DIR/xhisper/xhisper.log` (a 0700 directory; on macOS `$(getconf DARWIN_USER_TEMP_DIR)xhisper`), holds
the last few hundred lines, and contains every transcription — so it is kept out
of world-readable `/tmp`.

---

## Configuration

Configuration is read from `~/.config/xhisper/xhisperrc`:

```sh
mkdir -p ~/.config/xhisper
cp default_xhisperrc ~/.config/xhisper/xhisperrc
cp default_dictionary.txt ~/.config/xhisper/dictionary.txt
```

---

## Troubleshooting

### Linux

**No sound detected**: Check that your microphone is working and PipeWire is running (`pw-record --channels=1 test.wav`).
A recording with less than `min-speech-seconds` (0.3 s) of speech-like sound is also discarded as No sound, because Whisper turns a silent recording with just the hotkey click into "Thank you.". `xhisper --log` shows `Voiced: …s` for each recording; lower the value if very short words get dropped, or set it to 0 to turn the check off.

**Permission denied on /dev/uinput**: Make sure you completed step 3 (udev rules) and that you're in the `input` group.

**Wrong text pasted**: If xhisper pastes old clipboard content instead of the transcription, make sure the clipboard tool matching your session is installed — `xclip` on X11, `wl-clipboard` on Wayland.

**"Failed" overlay**: A step returned an error. `xhisper --log` prints the API response, the model used, and the timing of each stage.

**Recording stops instantly / always "No sound detected"**: xhisper needs to see when you release the key. On Wayland that means reading `/dev/input`, so your user must be in the `input` group (step 2) — if it can't, it now says so explicitly instead of silently recording nothing.

**Overlay not showing**: Make sure PyGObject is installed (`sudo apt install python3-gi gir1.2-gtk-3.0`). On Wayland, install `gir1.2-gtklayershell-0.1` for the animated overlay — without it, the tool falls back to standard desktop notifications.

### macOS

**No sound detected**: Check that `sox` is installed (`brew install sox`) and your microphone is accessible. Test with `rec test.wav`.

**Paste not working**: Xhisper needs Accessibility (System Settings > Privacy & Security > Accessibility). `xhisper --log` says so with a `Paste:` line.

**Hotkey does nothing**: Check `cat $(getconf DARWIN_USER_TEMP_DIR)xhisper/xhisper-hotkey.log`. After an unsigned rebuild (no `macos/make-cert.sh`), re-enable Xhisper in Accessibility and Input Monitoring.

**Logs**: `xhisper --log`. macOS keeps runtime state in `$(getconf DARWIN_USER_TEMP_DIR)xhisper`.

---

<p align="center">
  <em>Push-to-talk voice dictation for Linux and macOS with AI auto-editing and tone adaptation</em>
</p>
