<p align="center">
  <img src="assets/banner.png" alt="Raju — Your Private AI Voice Assistant for macOS" width="100%">
</p>

Hold the menubar icon → speak → get a real answer. All on your machine. All private. No API keys, no subscriptions, no internet required after install.

| Menu | Live Log |
|:----:|:--------:|
| ![Raju menu](assets/menu.png) | ![Raju log](assets/log.png) |

---

## What makes it different

Siri is smart, but it phones home for everything. Raju runs a local LLM, a local speech-to-text engine, and a local neural voice synthesizer — entirely on your Mac. It doesn't just look things up, it actually runs bash commands against your live system to give you real answers.

| | Siri | Raju |
|---|---|---|
| Works offline | ❌ | ✅ |
| Privacy | Logs to Apple | Zero telemetry |
| Checks your real system | Limited | Full read-only shell access |
| Voices | Fixed | 6 neural voices, swap anytime |
| Models | Fixed | 4 LLMs, swap on the fly |
| Open source | ❌ | ✅ |
| Cost | Apple subscription | Free forever |

---

## How it works

```
Hold icon  →  rec              (mic → WAV)
Release    →  whisper-server   (WAV → text, runs locally)
              llama-server     (text + live system data → reply)
              Piper TTS        (reply → speech, runs locally)  →  speaker
```

All inference runs on persistent local HTTP servers — models stay loaded in RAM so each query after warm-up is fast.

---

## Features

- **Push-to-talk** — hold to record, release to respond
- **Live system queries** — CPU, RAM, disk, battery, network via a two-turn ReAct loop
- **4 LLMs** — switch models on the fly from the menu; new model downloads in-app (~1 GB)
- **6 Piper neural voices** — auto-downloads on first select (~60 MB each)
- **GPU toggle** — right-click → toggle Metal GPU acceleration on/off; auto-detected at first launch (Apple Silicon = on, Intel = off)
- **Intel Mac support** — fully functional on Intel; GPU disabled by default to avoid Metal compatibility issues
- **Stop / Start servers** — toggle LLM or Whisper from the menu without quitting
- **Live log** — streams in Terminal with `tail -f ~/Raju/raju.log`
- **Launch at Login** — one-click LaunchAgent toggle
- **Fully private** — zero network calls during operation

---

## Install

```bash
git clone https://github.com/vvikas/raju
cd raju
chmod +x install.sh
./install.sh
```

The installer handles everything end-to-end:

| Step | What it does |
|------|-------------|
| Homebrew | Installs if missing |
| sox | `brew install sox` — mic recording |
| llama.cpp | Clone + build from source (with Metal GPU acceleration) |
| whisper.cpp | Clone + build from source (with Metal GPU acceleration) |
| Whisper model | Downloads `ggml-small.bin` (~466 MB) |
| LLM model | Downloads Qwen2 1.5B (~940 MB) as the default |
| Piper TTS | `pip3 install piper-tts` + Lessac voice (~60 MB) |
| Compile | Builds `Raju.app` in `~/Applications` |

> First build takes 20–30 minutes (compiling llama.cpp + whisper.cpp from source).
>
> Additional models (Qwen2.5-Coder, SmolLM2, Phi-3.5 Mini) download on demand via the in-app menu — no need to fetch them upfront.

---

## Run

```bash
open ~/Applications/Raju.app
```

The 🎙️ icon appears in your menubar. Wait ~60 seconds for models to warm up — **⚡** appears next to both LLM and Whisper when ready.

> **First run:** launch from your own Terminal so macOS can grant microphone access. Approve the mic permission prompt when it appears.

---

## Usage

| Action | Effect |
|--------|--------|
| **Hold** 🎙️ | Start recording |
| **Release** | Stop → transcribe → think → speak |
| **Right-click** | Open menu |

### What you can ask

**System & Performance**
| Query | What Raju does |
|-------|---------------|
| "What's using the most CPU?" | Runs `ps`, speaks top processes |
| "What's eating my RAM?" | Runs `ps -m`, speaks top memory users |
| "How much disk space do I have?" | Runs `df -h` |
| "What's my battery level?" | Runs `pmset -g batt` |
| "How long has my Mac been on?" | Runs `uptime` |

**Apps & Processes**
| Query | What Raju does |
|-------|---------------|
| "Is Spotify running?" | Checks running processes by name |

**Network**
| Query | What Raju does |
|-------|---------------|
| "What's my IP address?" | Runs `ifconfig en0` |
| "What WiFi network am I on?" | Runs `networksetup -getairportnetwork en0` |

**Files & Search**
| Query | What Raju does |
|-------|---------------|
| "What's the biggest file on my Desktop?" | Runs `ls -lhS ~/Desktop` |
| "What's the newest file in Downloads?" | Runs `ls -lt ~/Downloads` |
| "What's taking up space in my home folder?" | Runs `du -sh ~/*` |
| "Find files I modified today" | Runs `find` with `-mtime 0` |
| "Find a file called notes.txt" | Runs `find ~/` by name |
| "Find files containing 'budget'" | Runs `grep -ril` — full list copied to clipboard |
| "What's the biggest video on my Mac?" | `find` across `~/` for `.mp4/.mov/.mkv/.avi`, sorted by size |
| "What's the biggest image on my Mac?" | `find` across `~/` for `.jpg/.png/.heic`, sorted by size |

**Clipboard**
| Query | What Raju does |
|-------|---------------|
| "What's in my clipboard?" | Reads clipboard via `pbpaste` |

**Reminders**
| Query | What Raju does |
|-------|---------------|
| "Remind me in 10 minutes to check the oven" | Sets a timer — speaks reminder aloud when it fires |
| "Remind me in 2 hours to take a break" | Same, any duration in seconds / minutes / hours |

**General Knowledge**
| Query | What Raju does |
|-------|---------------|
| "What time is it?" / "What day is today?" | Answers directly from system time |
| "How many MB is 2.3 GB?" | LLM computes directly |
| "What's the capital of France?" | LLM answers directly |

> **Tip:** Long results (file lists, process tables) are automatically copied to your clipboard so you can paste them anywhere.

---

## Models

Switch anytime via right-click → 🧠 Model. The old server stops and the new one starts automatically. Models marked ↓ download in-app on first select.

| Model | Size | Best for | Download |
|-------|------|----------|----------|
| Qwen2 1.5B | ~940 MB | General questions — default, pre-installed | install.sh |
| Qwen2.5-Coder 1.5B | ~950 MB | Code, scripting, technical questions | In-app ↓ |
| SmolLM2 1.7B | ~1.1 GB | Fast, capable all-rounder | In-app ↓ |
| Phi-3.5 Mini 3.8B | ~2.2 GB | Best reasoning quality | In-app ↓ |

---

## Voices

Switch anytime via right-click → 🗣 Voice. Voices auto-download on first select (~60 MB each).

| Voice | Accent | Download |
|-------|--------|----------|
| Lessac (US Female) | Default | install.sh |
| Ryan (US Male) | American | In-app ↓ |
| Amy (US Female) | American | In-app ↓ |
| Joe (US Male) | American | In-app ↓ |
| Jenny (GB Female) | British | In-app ↓ |
| Alan (GB Male) | British | In-app ↓ |

Falls back to macOS `say` if Piper is not installed.

---

## How the tool-use loop works

For system queries, Raju uses a two-turn ReAct loop:

**Turn 1** — LLM decides whether to answer directly or generate a shell command:
```xml
<bash>
ps -Axo pid,args,%cpu,%mem -r | head -15
</bash>
```

**Turn 2** — Raju runs the command, safely reads the output using a non-blocking stream to prevent truncation, feeds it back, and the LLM gives a spoken answer:
```
llama-server is using the most CPU at 66%, followed by Claude Helper at 28%.
```

The output reformatter converts raw columnar text (hard for small LLMs to parse) into labeled key=value pairs before Turn 2:
```
Processes sorted by CPU (highest first):
  pid=62840, name=llama-server, cpu=66.6%, ram=6.5%
  pid=42584, name=Claude Helper, cpu=28.7%, ram=6.9%
```

Commands are sandboxed — destructive operations (`rm`, `kill`, `sudo`, `curl`, etc.) are blocked. The LLM only gets read-only shell access.

---

## Requirements

- macOS 12+ (Apple Silicon and Intel — GPU auto-detected)
- Xcode Command Line Tools (`xcode-select --install`)
- ~6 GB free disk (models + compiled binaries)
- ~2 GB RAM headroom (4 GB recommended for Phi-3.5 Mini)

---

## File layout

```
~/Raju/                      ← this repo
├── main.swift               ← entire app (~1100 lines)
├── Models.swift             ← LLM + voice config (edit here to add models)
├── install.sh               ← one-shot dependency installer
├── assets/
│   └── screenshot.png
└── raju.log                 ← runtime log (gitignored)

~/local_llms/
├── llama.cpp/               ← LLM inference engine + server binary
│   └── models/              ← *.gguf model files
└── whisper.cpp/             ← Whisper STT engine + server binary
    └── models/              ← ggml-small.bin

~/.raju/
└── voices/                  ← Piper .onnx voice files
```

---

## Dependencies

| Tool | Purpose |
|------|---------|
| [sox](https://sox.sourceforge.net) | Mic recording (`rec`) |
| [llama.cpp](https://github.com/ggerganov/llama.cpp) | LLM inference server |
| [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | Speech-to-text server |
| [piper-tts](https://github.com/rhasspy/piper) | Neural text-to-speech |

---

## Privacy

Everything runs 100% locally. No data ever leaves your machine. No telemetry, no accounts, no subscriptions.

---

## Tested on

- MacBook Air M2, Apple Silicon, 8 GB RAM, macOS 14.x
- MacBook Air 2015, Intel Core i5, 8 GB RAM, macOS 12.7
