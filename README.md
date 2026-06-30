<div align="center">
  <h1>xhisper</h1>
  <img src="demo.gif" alt="xhisper demo" width="300">
  <br><br>
</div>

Voice-to-text dictation at cursor for **Linux and macOS**. Based on [imaginalnika/xhisper](https://github.com/imaginalnika/xhisper) with push-to-talk, AI auto-editing, tone adaptation, animated status overlay, keyboard layout compatibility, and clipboard manager integration.

## Features

- **Linux and macOS** — Works on X11, Wayland, and macOS. Key release detection uses XQueryKeymap on X11, evdev on Wayland, and Quartz on macOS
- **Push-to-talk** — Hold your shortcut key to record, release to transcribe. No double-press needed
- **AI auto-editing** — Automatically cleans up grammar, removes filler words (um, uh, like), and fixes punctuation before pasting. Always on by default, can be disabled in config
- **Tone adaptation** — Detects the active window (Slack, Gmail, VS Code, etc.) and adjusts the auto-edit style accordingly — casual for chat, professional for email, concise for code comments
- **Personal dictionary** — Add custom words, names, and technical terms to `~/.config/xhisper/dictionary.txt` to improve Whisper's recognition accuracy
- **Animated status overlay** — A dark pill with animated sound wave bars slides up from the bottom of the screen during recording, transcribing, and editing (falls back to desktop notifications if GTK is unavailable)
- **Smart paste** — Detects the active window and uses the correct paste shortcut (Ctrl+V, Ctrl+Shift+V for terminals on Linux; Cmd+V, Cmd+Shift+V on macOS). Works natively with AZERTY, QWERTZ, or any keyboard layout
- **Multi-language transcription** — Whisper auto-detects the spoken language by default, so you can switch between English, French, Spanish, etc. and each is transcribed in its own script. Set `language : en` (or any ISO 639-1 code) in the config to force a specific language
- **Stability** — PID-file based concurrency control prevents duplicate instances from interfering with each other
- **Custom STT/LLM endpoints** — Use Groq's API by default, or point to any OpenAI-compatible endpoint — local Whisper servers, Ollama, vLLM, or any other provider
- **Clipboard preservation** — Your clipboard content is saved before transcription and restored after pasting
- **Clipboard manager cleanup** — Automatically removes xhisper's temporary clipboard entries from CopyQ history

---

## Installation on Ubuntu

### 1. Install dependencies

```sh
sudo apt update
sudo apt install pipewire jq curl ffmpeg gcc xclip wl-clipboard python3 python3-gi gir1.2-gtk-3.0 bc xdotool
```

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
git clone --depth 1 https://github.com/abszar/xhisper-ubuntu-linux.git
cd xhisper-ubuntu-linux && make
sudo make install
```

### 6. Set up a keyboard shortcut (GNOME)

**Option A: Settings UI (recommended)**

1. Open **Settings → Keyboard → Keyboard Shortcuts → "View and Customize Shortcuts"**
2. Scroll to **Custom Shortcuts** and click **`+`**
3. Fill in:
   - **Name:** `xhisper`
   - **Command:** `/usr/local/bin/xhisper`
   - **Shortcut:** click "Set Shortcut" and press your preferred key
4. Click **Add**. The shortcut takes effect immediately — no logout needed.

> **Pick a combo the focused app won't swallow.** A plain `Alt`+letter is captured by application menu mnemonics and never reaches xhisper, so prefer `Ctrl+Alt`+key (e.g. `Ctrl+Alt+Z`), a `Super` combo, or a dedicated key like `Pause`.

**Option B: Command line**

Run the following in a terminal to bind xhisper to a key. Change `binding` to your preferred shortcut:

```sh
name="xhisper"
binding="Pause"  # Pause/Break key. Other examples: "<Control><Alt>z", "<CTRL><SHIFT>X"
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

> If a shortcut set this way doesn't trigger, set it via **Option A** instead — the Settings UI registers it in a form GNOME always grabs reliably.

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
git clone --depth 1 https://github.com/abszar/xhisper-ubuntu-linux.git
cd xhisper-ubuntu-linux
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

An animated wave pill overlay slides up from the bottom of your screen showing the current state:
- **Recording** — animated wave bars while you hold the key
- **Transcribing** — gentler pulse while Whisper processes your audio
- **Editing** — AI is cleaning up your text
- **Done** — brief confirmation, then fades out

### AI Auto-editing

Every transcription is automatically cleaned up by an AI before pasting:
- Removes filler words (um, uh, like, you know)
- Fixes grammar and punctuation
- Preserves your meaning

Disable it in your config if you want raw transcriptions:
```
auto-edit : false
```

### Tone Adaptation

When auto-editing is on, xhisper detects the active window and adjusts the writing style:

| Window | Tone |
|--------|------|
| Slack, Discord, Telegram | Casual chat |
| Gmail, Outlook, Thunderbird | Professional email |
| VS Code, terminal | Concise technical |
| Google Docs, LibreOffice | Well-structured prose |
| Jira, GitHub | Concise and technical |

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

### View logs

```sh
xhisper --log
```

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

**Wrong text pasted**: If xhisper pastes old clipboard content instead of the transcription, make sure `xclip` is installed (`sudo apt install xclip`).

**Overlay not showing**: Make sure PyGObject is installed (`sudo apt install python3-gi gir1.2-gtk-3.0`). On Wayland, install `gir1.2-gtklayershell-0.1` for the animated overlay — without it, the tool falls back to standard desktop notifications.

### macOS

**No sound detected**: Check that `sox` is installed (`brew install sox`) and your microphone is accessible. Test with `rec test.wav`.

**Paste not working**: Make sure your terminal/automation app has Accessibility permissions (System Settings > Privacy & Security > Accessibility).

**"Not allowed to send keystrokes"**: This means the app running xhisper needs to be added to the Accessibility list in System Settings.

---

<p align="center">
  <em>Push-to-talk voice dictation for Linux and macOS with AI auto-editing and tone adaptation</em>
</p>
