#!/bin/bash
set -e

# ── Raju — Local Voice Assistant for macOS ────────────────────────────────────
# install.sh — checks and installs all dependencies, then compiles the app

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "   $1"; }

echo ""
echo "══════════════════════════════════════════"
echo "  Raju — Local Voice Assistant — Installer"
echo "══════════════════════════════════════════"
echo ""

# ── 1. macOS check ─────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  fail "Raju requires macOS."
fi
ok "macOS detected ($(sw_vers -productVersion))"

# ── 2. Xcode Command Line Tools (for swiftc) ──────────────────────────────────
if ! command -v swiftc &>/dev/null; then
  warn "Xcode Command Line Tools not found — installing…"
  xcode-select --install
  echo "   Re-run this script after the installation completes."
  exit 1
fi
ok "swiftc $(swiftc --version 2>&1 | head -1 | awk '{print $4}')"

# ── 3. Homebrew ────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  warn "Homebrew not found — installing…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

# ── 4. sox (mic recording) ────────────────────────────────────────────────────
if ! command -v rec &>/dev/null; then
  info "Installing sox…"
  brew install sox
fi
ok "sox (rec at $(which rec))"

# ── 5. llama.cpp ──────────────────────────────────────────────────────────────
LLAMA_DIR="$HOME/local_llms/llama.cpp"
LLAMA_BIN="$LLAMA_DIR/build/bin/llama-server"
if [[ ! -f "$LLAMA_BIN" ]]; then
  warn "llama.cpp not found — building from source with Metal support…"
  mkdir -p "$HOME/local_llms"
  git clone https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
  cmake -B "$LLAMA_DIR/build" -S "$LLAMA_DIR" -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "$LLAMA_DIR/build" --config Release -j4
fi
ok "llama-server at $LLAMA_BIN"

# ── 6. whisper.cpp ────────────────────────────────────────────────────────────
WHISPER_DIR="$HOME/local_llms/whisper.cpp"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-server"
if [[ ! -f "$WHISPER_BIN" ]]; then
  warn "whisper.cpp not found — building from source with Metal support…"
  mkdir -p "$HOME/local_llms"
  git clone https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
  cmake -B "$WHISPER_DIR/build" -S "$WHISPER_DIR" -DGGML_METAL=ON
  cmake --build "$WHISPER_DIR/build" -j4
fi
ok "whisper-server at $WHISPER_BIN"

# ── 7. Whisper model (small, ~466 MB) ─────────────────────────────────────────
WHISPER_MODEL="$WHISPER_DIR/models/ggml-small.bin"
if [[ ! -f "$WHISPER_MODEL" ]]; then
  info "Downloading Whisper small model (~466 MB)…"
  curl -L --progress-bar -o "$WHISPER_MODEL" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
fi
ok "Whisper model at $WHISPER_MODEL"

# ── 8. LLM models ─────────────────────────────────────────────────────────────
MODELS_DIR="$HOME/local_llms/llama.cpp/models"
mkdir -p "$MODELS_DIR"

# Only Qwen2 is pre-installed; other models download on demand via the in-app menu (↓)
QWEN2="$MODELS_DIR/qwen2-1.5b.gguf"
if [[ ! -f "$QWEN2" ]]; then
  info "Downloading Qwen2 1.5B (~940 MB)…"
  curl -L --progress-bar -o "$QWEN2" \
    "https://huggingface.co/Qwen/Qwen2-1.5B-Instruct-GGUF/resolve/main/qwen2-1_5b-instruct-q4_k_m.gguf"
fi
ok "Model: qwen2-1.5b.gguf"

# ── 9. Piper TTS ──────────────────────────────────────────────────────────────
VOICES_DIR="$HOME/.raju/voices"
PIPER_MODEL="$VOICES_DIR/en_US-lessac-medium.onnx"
mkdir -p "$VOICES_DIR"

if ! python3 -c "import piper" &>/dev/null; then
  info "Installing piper-tts via pip3…"
  pip3 install piper-tts 2>&1 | tail -3
fi
ok "piper-tts (python3 -m piper)"

if [[ ! -f "$PIPER_MODEL" ]]; then
  info "Downloading Piper voice model (en_US-lessac-medium, ~60 MB)…"
  curl -L --progress-bar -o "$PIPER_MODEL" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
  curl -L --progress-bar -o "${PIPER_MODEL}.json" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
fi
ok "Piper voice model at $PIPER_MODEL"

# ── 10. Compile + package as .app bundle ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Raju.app"
APP_BIN="$APP/Contents/MacOS/Raju"

info "Compiling Raju…"
swiftc "$SCRIPT_DIR/main.swift" "$SCRIPT_DIR/Models.swift" -o "$SCRIPT_DIR/Raju" -framework Cocoa
ok "Raju compiled"

info "Creating Raju.app bundle in ~/Applications…"
mkdir -p "$APP/Contents/MacOS"
cp "$SCRIPT_DIR/Raju" "$APP_BIN"
chmod +x "$APP_BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Raju</string>
  <key>CFBundleIdentifier</key>        <string>com.raju.app</string>
  <key>CFBundleExecutable</key>        <string>Raju</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSUIElement</key>               <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Raju needs microphone access to hear your voice commands.</string>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST
ok "Raju.app created at $APP"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo -e "${GREEN}  All done!${NC}"
echo ""
echo "  Launch Raju (double-click or run):"
echo "  open ~/Applications/Raju.app"
echo ""
echo "  Then right-click the 🎙️ icon →"
echo "  'Launch at Login' to auto-start."
echo "══════════════════════════════════════════"
echo ""
