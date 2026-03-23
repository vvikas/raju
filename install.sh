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

# ── 0. Fix PATH — pick up Homebrew regardless of shell config ─────────────────
for brew_prefix in /opt/homebrew /usr/local; do
  if [[ -x "$brew_prefix/bin/brew" ]]; then
    export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"
    break
  fi
done

# ── 1. macOS check + GPU detection ────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  fail "Raju requires macOS."
fi
ok "macOS detected ($(sw_vers -productVersion))"

ARCH=$(uname -m)
mkdir -p "$HOME/.raju"
if [[ "$ARCH" == "arm64" ]]; then
  ok "Apple Silicon (arm64) — GPU acceleration enabled by default"
  echo "true"  > "$HOME/.raju/use_gpu"
  CMAKE_GPU_FLAGS="-DGGML_METAL=ON"
else
  warn "Intel Mac detected — GPU disabled by default (Metal compatibility issue)"
  echo "false" > "$HOME/.raju/use_gpu"
  CMAKE_GPU_FLAGS="-DGGML_METAL=OFF"
fi

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
  # Re-evaluate PATH so brew is available for the rest of this script
  for brew_prefix in /opt/homebrew /usr/local; do
    if [[ -x "$brew_prefix/bin/brew" ]]; then
      export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"
      break
    fi
  done
fi
ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"

# ── 4. cmake + sox ────────────────────────────────────────────────────────────
if ! command -v cmake &>/dev/null; then
  info "Installing cmake…"
  brew install cmake
fi
ok "cmake $(cmake --version | head -1 | awk '{print $3}')"

if ! command -v rec &>/dev/null; then
  info "Installing sox…"
  brew install sox
fi
ok "sox (rec at $(which rec))"

# ── 5. llama.cpp ──────────────────────────────────────────────────────────────
LLAMA_DIR="$HOME/local_llms/llama.cpp"
LLAMA_BIN="$LLAMA_DIR/build/bin/llama-server"
if [[ ! -f "$LLAMA_BIN" ]]; then
  warn "llama.cpp not found — building from source…"
  mkdir -p "$HOME/local_llms"
  # Remove incomplete clone from a previous failed run
  [[ -d "$LLAMA_DIR" && ! -f "$LLAMA_DIR/.git/HEAD" ]] && rm -rf "$LLAMA_DIR"
  [[ -d "$LLAMA_DIR" ]] || git clone https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
  cmake -B "$LLAMA_DIR/build" -S "$LLAMA_DIR" $CMAKE_GPU_FLAGS -DCMAKE_BUILD_TYPE=Release
  cmake --build "$LLAMA_DIR/build" --config Release -j4
fi
ok "llama-server at $LLAMA_BIN"

# ── 6. whisper.cpp ────────────────────────────────────────────────────────────
WHISPER_DIR="$HOME/local_llms/whisper.cpp"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-server"
if [[ ! -f "$WHISPER_BIN" ]]; then
  warn "whisper.cpp not found — building from source…"
  mkdir -p "$HOME/local_llms"
  # Remove incomplete clone from a previous failed run
  [[ -d "$WHISPER_DIR" && ! -f "$WHISPER_DIR/.git/HEAD" ]] && rm -rf "$WHISPER_DIR"
  [[ -d "$WHISPER_DIR" ]] || git clone https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
  cmake -B "$WHISPER_DIR/build" -S "$WHISPER_DIR" $CMAKE_GPU_FLAGS
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

# Find a python3 that has pip, preferring the one already in PATH
PYTHON3_BIN=""
for candidate in "$(which python3 2>/dev/null)" \
                 /opt/homebrew/bin/python3 \
                 /usr/local/bin/python3 \
                 /usr/bin/python3; do
  if [[ -x "$candidate" ]] && "$candidate" -m pip --version &>/dev/null 2>&1; then
    PYTHON3_BIN="$candidate"
    break
  fi
done

if [[ -z "$PYTHON3_BIN" ]]; then
  warn "No python3 with pip found — Piper TTS unavailable; will use macOS 'say' for speech"
else
  # piper-tts / piper-phonemize has ABI issues with Python 3.12+.
  # Prefer 3.11 if the detected interpreter is 3.12 or newer.
  PY_MINOR=$("$PYTHON3_BIN" -c "import sys; print(sys.version_info.minor)" 2>/dev/null)
  PY_MAJOR=$("$PYTHON3_BIN" -c "import sys; print(sys.version_info.major)" 2>/dev/null)
  if [[ "$PY_MAJOR" == "3" && "$PY_MINOR" -ge 12 ]]; then
    warn "Python 3.$PY_MINOR detected — piper-tts may have ABI issues. Looking for Python 3.11…"
    for alt in /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11; do
      if [[ -x "$alt" ]] && "$alt" -m pip --version &>/dev/null 2>&1; then
        PYTHON3_BIN="$alt"
        ok "Using $PYTHON3_BIN for piper-tts compatibility"
        break
      fi
    done
  fi

  # Install piper-tts and all required dependencies
  if ! "$PYTHON3_BIN" -c "import piper" &>/dev/null 2>&1; then
    info "Installing piper-tts for $PYTHON3_BIN…"
    "$PYTHON3_BIN" -m pip install piper-tts pathvalidate 2>&1 | tail -5
  else
    # Ensure pathvalidate is present even if piper was already installed
    "$PYTHON3_BIN" -m pip install --quiet pathvalidate 2>/dev/null || true
  fi
  if "$PYTHON3_BIN" -c "import piper" &>/dev/null 2>&1; then
    echo "$PYTHON3_BIN" > "$HOME/.raju/python3_bin"
    ok "piper-tts installed ($PYTHON3_BIN)"
  else
    warn "piper-tts install failed — will use macOS 'say' for speech"
    PYTHON3_BIN=""   # clear so smoke test is skipped below
  fi
fi

# Download voice model — need BOTH .onnx and .onnx.json; check both
if [[ ! -f "$PIPER_MODEL" || ! -f "${PIPER_MODEL}.json" ]]; then
  info "Downloading Piper voice model (en_US-lessac-medium, ~60 MB)…"
  curl -L --progress-bar -o "$PIPER_MODEL" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
  curl -L --progress-bar -o "${PIPER_MODEL}.json" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
fi
ok "Piper voice model at $PIPER_MODEL"

# End-to-end smoke test — verifies piper can actually synthesise audio,
# not just that the Python import succeeds. Plays a short test phrase.
if [[ -n "$PYTHON3_BIN" && -f "$PIPER_MODEL" ]]; then
  info "Testing Piper TTS end-to-end (first run may take ~15s to load model)…"
  set +e  # don't abort on piper failure — it's non-fatal
  echo "Raju is ready." | "$PYTHON3_BIN" -m piper \
    --model "$PIPER_MODEL" --output_file /tmp/raju_smoke.wav 2>/dev/null
  SMOKE_EXIT=$?
  set -e
  if [[ $SMOKE_EXIT -eq 0 && -s /tmp/raju_smoke.wav ]]; then
    afplay /tmp/raju_smoke.wav
    rm -f /tmp/raju_smoke.wav
    ok "Piper TTS working — you should have heard the test voice"
  else
    warn "Piper TTS smoke test failed — app will fall back to macOS 'say'"
    warn "Try: brew install python@3.11 and re-run install.sh"
  fi
fi

# ── 10. Compile + package as .app bundle ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Raju.app"
APP_BIN="$APP/Contents/MacOS/Raju"

info "Compiling Raju…"
swiftc "$SCRIPT_DIR/Config.swift" "$SCRIPT_DIR/Utils.swift" "$SCRIPT_DIR/Models.swift" "$SCRIPT_DIR/AudioRecorder.swift" "$SCRIPT_DIR/WhisperClient.swift" "$SCRIPT_DIR/LLMClient.swift" "$SCRIPT_DIR/ShellExecutor.swift" "$SCRIPT_DIR/TTSManager.swift" "$SCRIPT_DIR/ServerManager.swift" "$SCRIPT_DIR/WebShortcuts.swift" "$SCRIPT_DIR/CustomURLsWindowController.swift" "$SCRIPT_DIR/main.swift" -o "$SCRIPT_DIR/Raju" -framework Cocoa
ok "Raju compiled"

info "Creating Raju.app bundle in ~/Applications…"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$SCRIPT_DIR/Raju" "$APP_BIN"
chmod +x "$APP_BIN"

# Bundle app icon if present
ICNS="$SCRIPT_DIR/assets/Raju.icns"
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$APP/Contents/Resources/Raju.icns"
  ok "App icon bundled"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Raju</string>
  <key>CFBundleIdentifier</key>        <string>com.raju.app</string>
  <key>CFBundleExecutable</key>        <string>Raju</string>
  <key>CFBundleIconFile</key>          <string>Raju</string>
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

# Ad-hoc sign the app so macOS can track microphone permission to this bundle.
# Without a signature, TCC cannot reliably associate the mic grant with Raju.app
# and recording silently returns blank audio.
codesign --force --deep --sign - "$APP" 2>/dev/null && ok "Raju.app signed (ad-hoc)" \
  || warn "codesign failed — mic permission prompt may not appear on first launch"

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
