# Raju

A fully local, private voice assistant for macOS — no cloud, no API keys, everything runs on your machine.

**Hold** the menubar icon to speak, **release** to get a reply.

---

## How it works

```
Hold icon  →  sox rec (mic → WAV)
Release    →  whisper-server (WAV → text)
              llama-server (text + live system context → reply)
              Piper TTS (reply → speech)  →  speaker
```

All three inference steps use persistent HTTP servers — models stay loaded in RAM. After the first warm-up, each query takes ~10–20 seconds on an Intel Mac.

---

## Requirements

- macOS 12+
- Xcode Command Line Tools (`xcode-select --install`)
- ~5 GB free disk (models)
- ~2 GB RAM headroom

---

## Install

```bash
git clone https://github.com/shubanpandita/raju
cd raju
chmod +x install.sh
./install.sh
```

The installer handles everything:

| Step | What it does |
|------|-------------|
| Homebrew | Installs if missing |
| sox | `brew install sox` (mic recording) |
| llama.cpp | Clone + build with Metal GPU support |
| whisper.cpp | Clone + build with Metal GPU support |
| Whisper model | Downloads `ggml-small.bin` (~466 MB) |
| LLM models | Downloads Qwen2 1.5B, DeepSeek-Coder 1.3B, TinyLlama 1.1B |
| Piper TTS | `pip3 install piper-tts` + downloads `en_US-lessac-medium` voice (~60 MB) |
| Compile | Builds the `Raju` binary |

> First build takes 20–30 minutes (compiling llama.cpp + whisper.cpp from source).

---

## Run

Open a terminal and run:

```bash
~/raju/Raju
```

The 🎙️ icon appears in your menubar. Wait ~60 seconds for models to warm up (⚡ appears next to both LLM and Whisper when ready).

> **Important:** Launch from your own Terminal so macOS can grant microphone access. On first run, approve the mic permission prompt.

---

## Usage

| Action | Effect |
|--------|--------|
| **Hold** 🎙️ (left click) | Start recording |
| **Release** | Stop → transcribe → think → speak |
| **Right-click** icon | Open menu |

### Menu options

- ⚡ LLM ready / Whisper ready — server status
- 🧠 Model selector — switch between LLMs (server restarts automatically)
- Last Q&A shown inline
- 📄 Show Log — open live log in TextEdit
- Quit

### Example queries

- *"How much disk space do I have?"*
- *"What's using the most CPU right now?"*
- *"What's my battery level?"*
- *"Find file named notes.txt"*
- *"What time is it?"*
- *"What's my IP address?"*

---

## Models

Switch anytime via right-click → model submenu. The server restarts with the new model (~20–30s).

| Model | Size | Best for |
|-------|------|----------|
| Qwen2 1.5B | 940 MB | General questions (default) |
| DeepSeek-Coder 1.3B | 833 MB | Code / technical questions |
| TinyLlama 1.1B | 638 MB | Fastest responses |

---

## Dependencies

| Tool | Purpose | How installed |
|------|---------|---------------|
| [sox](https://sox.sourceforge.net) | Mic recording (`rec`) | `brew install sox` |
| [llama.cpp](https://github.com/ggerganov/llama.cpp) | LLM inference server | Built from source by installer |
| [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | Speech-to-text server | Built from source by installer |
| [piper-tts](https://github.com/rhasspy/piper) | Neural text-to-speech | `pip3 install piper-tts` |

> If Piper is not installed, Raju falls back to macOS's built-in `say` command.

---

## File layout

```
~/raju/                     ← this repo
├── main.swift              ← entire app source
├── install.sh              ← dependency installer
├── .gitignore
└── raju.log                ← runtime log (auto-created, gitignored)

~/local_llms/
├── llama.cpp/              ← LLM engine + server binary
│   └── models/             ← qwen2-1.5b.gguf, deepseek-coder-1.3b.gguf, tinyllama.gguf
└── whisper.cpp/            ← Whisper engine + server binary
    └── models/             ← ggml-small.bin

~/.raju/
└── voices/                 ← en_US-lessac-medium.onnx (Piper voice)
```

---

## Logs

```bash
tail -f ~/raju/raju.log
```

Or right-click the icon → **📄 Show Log**.

---

## Privacy

Everything runs 100% locally. No data leaves your machine. No internet required after install.

---

## Tested on

- MacBook Air 2015 (Intel Core i5, 8 GB RAM, macOS 12.7)
