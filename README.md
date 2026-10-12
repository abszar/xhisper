<div align="center">
  <h1>xhisper</h1>
  <img src="demo.gif" alt="xhisper demo" width="300">
  <br><br>
</div>

Voice-to-text dictation at cursor for **Linux and macOS**. Based on [imaginalnika/xhisper](https://github.com/imaginalnika/xhisper) with push-to-talk, AI auto-editing, tone adaptation, animated status overlay, keyboard layout compatibility, and clipboard manager integration.

## Features

- **Linux and macOS** — Works on X11, Wayland, and macOS. Key release detection uses XQueryKeymap on X11, evdev on Wayland, and Quartz on macOS
- **Push-to-talk** — Hold your shortcut key to record, release to transcribe. No double-press needed. A duplicate invocation while a recording is live is ignored (holding a key auto-repeats, and the desktop relaunches the command on every repeat); `xhisper --stop` ends a recording on purpose and can be bound to a second key
- **Hands-free toggle (X11)** — With `xhisper-hotkey`, press Alt then Ctrl once to start recording and again to stop. No key to hold, and a modifier-only combo that GNOME shortcuts cannot bind
- **Sound cues** — Optional `start-sound`, `stop-sound`, `cancel-sound` and `learned-sound` play when recording starts, stops, is cancelled, or a word is learned
- **Escape to cancel** — Press Escape while recording to throw the recording away (on X11 the key is grabbed, so it does not also reach the focused app)
- **Live waveform** — While recording, the pill's bars follow your voice (they read the level of the audio being recorded), and drop to dots when you pause
- **Learns your words** — Fix a misheard name once ("to Ziam" → "TOSIAM") right where it was pasted, or in the History window, and xhisper adds it to your dictionary. Learned words are sent to Whisper as spelling hints and to the auto-edit model as vocabulary
- **Dictation history** — The last 20 dictations (`history-size`) are kept in a private file. Open them with `xhisper --history`, or with the **History** chip on the Recording / No sound pill; each one has a **Copy** button
- **AI auto-editing** — Removes filler words and stutters, applies spoken self-corrections ("Tuesday, no wait, Wednesday"), turns "new line" into a real line break, and fixes punctuation — without ever rewriting your wording. If the model errors out, times out, or returns something suspicious, the raw transcription is pasted instead, so a bad API response never costs you a dictation
- **Tone adaptation** — Detects the active window (Slack, Gmail, VS Code, etc.) and lets it influence punctuation and formatting — light for chat, full sentences for email, no Markdown in a terminal. It never changes your words or the length
- **Personal dictionary** — Add custom words, names, and technical terms to `~/.config/xhisper/dictionary.txt` (or `xhisper-learn add WORD`) to improve Whisper's recognition accuracy; the auto-edit model gets them too, so near-misses are respelled
- **Animated status overlay** — A dark pill with animated sound wave bars slides up from the bottom of the screen during recording, transcribing, and editing (falls back to desktop notifications if GTK is unavailable)
- **Smart paste** — Detects the active window *class* and uses the correct paste shortcut (Ctrl+V, Ctrl+Shift+V for terminals on Linux; Cmd+V, Cmd+Shift+V on macOS). Works natively with AZERTY, QWERTZ, or any keyboard layout
- **Multi-language transcription** — Whisper auto-detects the spoken language by default, so you can switch between English, French, Spanish, etc. and each is transcribed in its own script. Set `language : en` (or any ISO 639-1 code) in the config to force a specific language
- **Stability** — PID-file based concurrency control prevents duplicate instances from interfering with each other. Recordings are capped by `max-recording-seconds`, and every network call has a timeout
- **Custom STT/LLM endpoints** — Use Groq's API by default, or point to any OpenAI-compatible endpoint — local Whisper servers, Ollama, vLLM, or any other provider
- **Clipboard preservation** — Your clipboard content is saved before transcription and restored after pasting
- **Clipboard manager cleanup** — Automatically removes xhisper's temporary clipboard entries from CopyQ history
- **Private by default** — The recording, the log of everything you dictated, and the request sent to the LLM live in a 0700 directory under `$XDG_RUNTIME_DIR`, never in world-readable `/tmp`. API keys are handed to `curl` over stdin so they never appear in `ps`

---

## Platform support

| Feature | Linux | macOS |
|---|---|---|
| Hold-to-talk dictation, paste at cursor | ✅ | ✅ |
| AI auto-edit, tone adaptation, answer guard | ✅ | ✅ (shared code) |
| Personal dictionary (Whisper hints + auto-edit vocabulary) | ✅ | ✅ (shared code) |
| `--toggle` mode, Escape to cancel, sound cues | ✅ | ⏳ untested since added |
| Alt → Ctrl toggle hotkey (`xhisper-hotkey`) | ✅ X11 | ⏳ needs a CGEventTap agent |
| Overlay pill with live waveform, History chip, Learned/Unlearn pill | ✅ | ⏳ needs a native panel (falls back to notifications) |
| History window (`xhisper-history`) | ✅ | ⏳ needs a native window |
| Learning from corrections (`xhisper-learn`), screen context | ✅ AT-SPI | ⏳ needs the Accessibility API |

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

---

## Installation on macOS

### 1. Install dependencies

```sh
brew install sox ffmpeg jq curl
```

### 2. Get a Groq API key (or use a local server)

Get a free API key from [console.groq.com](https://console.groq.com) and add it to `~/.env`:

```sh
echo 'GROQ_API_KEY=<your_API_key>' >> ~/.env
```

Or skip this step if you'll use a local Whisper/LLM server — see [Custom STT/LLM Endpoints](#custom-sttllm-endpoints).

### 3. Clone and install

```sh
git clone --depth 1 https://github.com/abszar/xhisper.git
cd xhisper
sudo make install
```

### 4. Grant Accessibility permissions

xhisper uses `osascript` to simulate Cmd+V paste. macOS requires Accessibility permissions for this:

1. Open **System Settings > Privacy & Security > Accessibility**
2. Add your terminal app (Terminal.app, iTerm2, etc.) to the list
3. If using Automator or a shortcut app, add that too

### 5. Set up a keyboard shortcut

**Option A: Automator (built-in)**
1. Open **Automator** > New > **Quick Action**
2. Set "Workflow receives" to **no input**
3. Add a **Run Shell Script** action with: `/usr/local/bin/xhisper`
4. Save it (e.g., "xhisper")
5. Go to **System Settings > Keyboard > Keyboard Shortcuts > Services** and assign a key

**Option B: Karabiner-Elements**
1. Install [Karabiner-Elements](https://karabiner-elements.pqrs.org/)
2. Map your preferred key to run `/usr/local/bin/xhisper`

---

## Usage

**Hold** your shortcut key to record, **release** to stop and transcribe. The transcribed text is pasted at your cursor.

To end a recording without releasing the key, run **`xhisper --stop`** — bind it
to a second shortcut if you want a stop key. Pressing the dictation hotkey again
deliberately does nothing: holding a key auto-repeats (X11 defaults to 33
presses per second), and the desktop relaunches the command on every repeat, so
a duplicate invocation cannot be told apart from the press you are still holding.

**Toggle mode (no holding):** with [`xhisper-hotkey`](#alternative-press-alt-then-ctrl--no-holding-x11)
running, press **Alt** then **Ctrl** once to start recording and once more to
stop and transcribe. It runs `xhisper --toggle`, which records until the next
`--toggle` (or `max-recording-seconds`).

**Cancel:** press **Escape** while recording. The recording is discarded and
`cancel-sound` plays.

**History:** `xhisper --history` opens a window with your last dictations
(newest first), each with a **Copy** button. The Recording and No sound pills
also carry a **History** chip: clicking it while recording stops listening (like
a cancel) and the pill slides into the history window. Kept: the last
`history-size` dictations (default 20, `0` keeps none) in
`~/.local/state/xhisper/history.jsonl`, readable only by you. **Edit** fixes a
dictation in place and learns the words you corrected.

**Learning words:** with `learn-words : true`, xhisper follows the field it
pasted into for a minute (through Linux accessibility, AT-SPI). Replace a
misheard word there — say "to Ziam" with "TOSIAM" — and once the fix has sat
for three seconds (or is sent with Enter), the new word is added to your
dictionary. A *Learned: WORD* pill confirms it, with an optional
`learned-sound`; it stays about six seconds (longer while your pointer is on
it) and its **Unlearn** button takes the word back out if the fix was a
mistake. Only words that replace dictated words and are not ordinary
English are learned; an all-lowercase word must also be a real change of word
("Qulify" → "coolify"), so typo and accent fixes teach nothing. It works where the app exposes its text (GTK apps, terminals such as
Tilix/GNOME Terminal, Firefox; Chrome and Electron apps only with accessibility
on). The text is read in memory only; only learned words are stored. Manage
the list with `xhisper-learn list | add WORD | remove WORD`.

An animated wave pill overlay slides up from the bottom of your screen showing the current state:
- **Recording** — wave bars that follow your voice (with an optional `start-sound` cue), plus a **History** chip
- **Transcribing** — gentler pulse while Whisper processes your audio
- **Editing** — AI is cleaning up your text
- **Done** — brief confirmation, then fades out
- **No sound** / **Failed** — nothing was recorded, or a step failed; run `xhisper --log` for the details. No sound keeps the **History** chip, and stays up while your pointer is over it
- **Cancelled** — you pressed Escape
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

The log lives in `$XDG_RUNTIME_DIR/xhisper/xhisper.log` (a 0700 directory), holds
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

**Permission denied on /dev/uinput**: Make sure you completed step 3 (udev rules) and that you're in the `input` group.

**Wrong text pasted**: If xhisper pastes old clipboard content instead of the transcription, make sure the clipboard tool matching your session is installed — `xclip` on X11, `wl-clipboard` on Wayland.

**"Failed" overlay**: A step returned an error. `xhisper --log` prints the API response, the model used, and the timing of each stage.

**Recording stops instantly / always "No sound detected"**: xhisper needs to see when you release the key. On Wayland that means reading `/dev/input`, so your user must be in the `input` group (step 2) — if it can't, it now says so explicitly instead of silently recording nothing.

**Overlay not showing**: Make sure PyGObject is installed (`sudo apt install python3-gi gir1.2-gtk-3.0`). On Wayland, install `gir1.2-gtklayershell-0.1` for the animated overlay — without it, the tool falls back to standard desktop notifications.

### macOS

**No sound detected**: Check that `sox` is installed (`brew install sox`) and your microphone is accessible. Test with `rec test.wav`.

**Paste not working**: Make sure your terminal/automation app has Accessibility permissions (System Settings > Privacy & Security > Accessibility).

**"Not allowed to send keystrokes"**: This means the app running xhisper needs to be added to the Accessibility list in System Settings.

---

<p align="center">
  <em>Push-to-talk voice dictation for Linux and macOS with AI auto-editing and tone adaptation</em>
</p>
