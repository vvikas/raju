import json
import urllib.request
import re
import os
import argparse
import subprocess
import sys
import time

# We will test the local LLM running on port 8080
LLAMA_URL = "http://127.0.0.1:8080/v1/chat/completions"
LLAMA_HEALTH = "http://127.0.0.1:8080/health"

MACHINE_CONTEXT = "macOS 14.0 on MacBookPro — Apple M2, 16GB RAM"
USER_HOME = os.path.expanduser("~")

import datetime
NOW = datetime.datetime.now().strftime("%A, %b %-d %Y, %H:%M")

# ── System prompt — must match LLMClient.swift exactly ────────────────────────
SYS_PROMPT = f"""You are Raju, a macOS voice assistant. Machine: {MACHINE_CONTEXT}. Time: {NOW}.
The user's home directory is {USER_HOME}. Always use standard macOS paths (e.g. ~/Downloads, ~/Desktop, ~/Documents). Do NOT invent or hallucinate volumes like /Volumes/downloads/.
You can run macOS terminal commands to answer technical questions.

IF YOU NEED TO RUN A COMMAND, output exactly like this and nothing else:
<bash>
the command here
</bash>

To open a website or video, output ONLY: <open>key</open>
Valid keys are ONLY: headspace, lofi
Do NOT use <open> for anything else — all system/terminal tasks must use <bash>.

To set a reminder, output ONLY: <remind>5 minutes check the oven</remind>
Format: <remind>NUMBER UNIT message</remind> where UNIT is seconds/minutes/hours.

If you can answer without running a command, DO NOT output <bash>. Just answer directly in 1-2 sentences.
Examples:
  "what's using CPU?"               -> <bash>top -l 1 -o cpu -n 10 -stats pid,command,cpu,mem | tail -n +13</bash>
  "what's using RAM?"               -> <bash>top -l 1 -o mem -n 10 -stats pid,command,cpu,mem | tail -n +13</bash>
  "disk space?"                     -> <bash>df -h /</bash>
  "system uptime?"                  -> <bash>uptime</bash>
  "battery level?"                  -> <bash>pmset -g batt</bash>
  "wifi network name?"              -> <bash>networksetup -getairportnetwork en0</bash>
  "my IP address?"                  -> <bash>ipconfig getifaddr en0</bash>
  "public IP?"                      -> <bash>curl -s ifconfig.me</bash>
  "what's on port 3000?"            -> <bash>lsof -i :3000</bash>
  "what ports are listening?"       -> <bash>lsof -i -P | grep LISTEN</bash>
  "biggest files in downloads?"     -> <bash>ls -lhS ~/Downloads | head -10</bash>
  "find file called budget.xlsx"    -> <bash>find ~/ -iname "*budget.xlsx*" 2>/dev/null | head -15</bash>
  "find all .env files"             -> <bash>find ~/ -name ".env" 2>/dev/null | head -15</bash>
  "find python files modified today" -> <bash>find ~/ -name "*.py" -mtime -1 2>/dev/null | head -15</bash>
  "is safari running?"              -> <bash>pgrep -il "safari"</bash>
  "running docker containers?"      -> <bash>docker ps</bash>
  "python version?"                 -> <bash>python3 --version</bash>
  "node version?"                   -> <bash>node --version</bash>
  "my git branch?"                  -> <bash>git rev-parse --abbrev-ref HEAD</bash>
  "recent git commits?"             -> <bash>git log --oneline -10</bash>
  "how many CPU cores?"             -> <bash>sysctl -n hw.logicalcpu</bash>
  "macOS version?"                  -> <bash>sw_vers -productVersion</bash>
  "show environment variables?"     -> <bash>env</bash>
  "installed homebrew packages?"    -> <bash>brew list</bash>
  "my hostname?"                    -> <bash>hostname</bash>
  "cron jobs?"                      -> <bash>crontab -l</bash>
  "all open network connections?"   -> <bash>lsof -i -P -n | grep ESTABLISHED</bash>
  "recent system errors?"           -> <bash>log show --last 1h --level error 2>/dev/null | tail -20</bash>
  "remind me in 5 minutes"          -> <remind>5 minutes reminder</remind>
  "let's meditate"                  -> <open>headspace</open>
  "I want to meditate"              -> <open>headspace</open>
  "play lofi"                       -> <open>lofi</open>
  "capital of France?"              -> Paris is the capital."""


# ── Server restart ─────────────────────────────────────────────────────────────
def restart_server(model_path: str):
    """Kill any running llama-server and start a fresh one with the same
    flags the app uses (matching ServerManager.swift)."""
    print(f"\n🔄 Restarting llama-server with: {os.path.basename(model_path)}")

    # Kill existing instances
    subprocess.run(["pkill", "-f", "llama-server"], capture_output=True)
    time.sleep(2)

    # Detect GPU (Apple Silicon → ngl 999, Intel → 0)
    arch = subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip()
    ngl = "999" if arch == "arm64" else "0"

    llama_bin = os.path.expanduser("~/local_llms/llama.cpp/build/bin/llama-server")
    cmd = [
        llama_bin,
        "-m", model_path,
        "-ngl", ngl,
        "--port", "8080",
        "--host", "127.0.0.1",
        "-c", "4096",
        "-n", "400",
        "--log-disable",
    ]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Wait up to 180s for health
    print("   Waiting for llama-server to be ready", end="", flush=True)
    deadline = time.time() + 180
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(LLAMA_HEALTH, timeout=2) as r:
                if r.status == 200:
                    print(" ✅ ready!")
                    return True
        except Exception:
            pass
        print(".", end="", flush=True)
        time.sleep(3)
    print(" ❌ timed out")
    return False


# ── Tag extractors ─────────────────────────────────────────────────────────────
def extract_bash(response):
    match = re.search(r"<bash>\s*(.*?)\s*</bash>", response, re.DOTALL)
    return match.group(1).strip() if match else None

def extract_open(response):
    """Returns the key inside <open>key</open>, or None."""
    match = re.search(r"<open>\s*(\S+?)\s*</open>", response.strip(), re.IGNORECASE)
    return match.group(1).lower() if match else None

def extract_remind(response):
    """Returns the content inside <remind>...</remind>, or None."""
    match = re.search(r"<remind>\s*(.*?)\s*</remind>", response.strip(), re.IGNORECASE | re.DOTALL)
    return match.group(1).strip() if match else None


# ── LLM call ──────────────────────────────────────────────────────────────────
def query_llm(query):
    data = {
        "messages": [
            {"role": "system", "content": SYS_PROMPT.strip()},
            {"role": "user", "content": query}
        ],
        "temperature": 0.1,
        "max_tokens": 80
    }
    req = urllib.request.Request(
        LLAMA_URL,
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            res = json.loads(response.read().decode("utf-8"))
            return res["choices"][0]["message"]["content"].strip()
    except Exception as e:
        return f"ERROR: {e}"


# ── Test suite ─────────────────────────────────────────────────────────────────
TEST_CASES = [

    # ── System Performance (5) ────────────────────────────────────────────────
    {
        "query": "what's using my CPU right now?",
        "validator": lambda cmd: cmd and "top" in cmd and "cpu" in cmd.lower()
    },
    {
        "query": "what processes are using the most memory?",
        "validator": lambda cmd: cmd and ("top" in cmd or "ps" in cmd) and ("mem" in cmd.lower() or "rss" in cmd.lower() or "vsz" in cmd.lower())
    },
    {
        "query": "how much free RAM do I have?",
        "validator": lambda cmd: cmd and ("vm_stat" in cmd or "top" in cmd or "memory_pressure" in cmd)
    },
    {
        "query": "how full is my main disk?",
        "validator": lambda cmd: cmd and "df" in cmd and ("/" in cmd or "-h" in cmd)
    },
    {
        "query": "how long has my Mac been on?",
        "validator": lambda cmd: cmd and "uptime" in cmd
    },

    # ── Networking (5) ────────────────────────────────────────────────────────
    {
        "query": "what is my local IP address?",
        "validator": lambda cmd: cmd and ("ifconfig" in cmd or "ipconfig getifaddr" in cmd)
    },
    {
        "query": "what's my public IP address?",
        "validator": lambda cmd: cmd and ("curl" in cmd or "wget" in cmd) and ("ifconfig.me" in cmd or "icanhazip" in cmd or "ipify" in cmd or "checkip" in cmd)
    },
    {
        "query": "what ports are listening on my machine?",
        "validator": lambda cmd: cmd and "lsof" in cmd and ("LISTEN" in cmd or "-P" in cmd)
    },
    {
        "query": "what process is running on port 3000?",
        "validator": lambda cmd: cmd and ("lsof" in cmd or "netstat" in cmd) and "3000" in cmd
    },
    {
        "query": "show me all active network connections",
        "validator": lambda cmd: cmd and ("lsof" in cmd or "netstat" in cmd)
    },

    # ── Files & Search (5) ────────────────────────────────────────────────────
    {
        "query": "show me the biggest files in my Downloads folder",
        "validator": lambda cmd: cmd and ("~/Downloads" in cmd or f"{USER_HOME}/Downloads" in cmd) and ("ls" in cmd or "find" in cmd or "du" in cmd) and "/Volumes/" not in cmd
    },
    {
        "query": "find a file called config.json anywhere on my Mac",
        "validator": lambda cmd: cmd and "find" in cmd and "config.json" in cmd
    },
    {
        "query": "find all .env files in my home directory",
        "validator": lambda cmd: cmd and "find" in cmd and ".env" in cmd
    },
    {
        "query": "find all Python files I modified this week",
        "validator": lambda cmd: cmd and "find" in cmd and ".py" in cmd and ("mtime" in cmd or "mmin" in cmd)
    },
    {
        "query": "what's the biggest file on my Desktop?",
        "validator": lambda cmd: cmd and ("~/Desktop" in cmd or f"{USER_HOME}/Desktop" in cmd) and ("ls" in cmd or "find" in cmd or "du" in cmd)
    },

    # ── Dev Tools (7) ─────────────────────────────────────────────────────────
    {
        "query": "what's my Python version?",
        "validator": lambda cmd: cmd and "python" in cmd.lower() and "--version" in cmd
    },
    {
        "query": "what's my Node.js version?",
        "validator": lambda cmd: cmd and "node" in cmd and "--version" in cmd
    },
    {
        "query": "show me the running Docker containers",
        "validator": lambda cmd: cmd and "docker" in cmd and "ps" in cmd
    },
    {
        "query": "what git branch am I on?",
        "validator": lambda cmd: cmd and "git" in cmd and ("branch" in cmd or "rev-parse" in cmd)
    },
    {
        "query": "show me the last 10 git commits",
        "validator": lambda cmd: cmd and "git" in cmd and "log" in cmd
    },
    {
        "query": "what homebrew packages do I have installed?",
        "validator": lambda cmd: cmd and "brew" in cmd and "list" in cmd
    },
    {
        "query": "show me all my environment variables",
        "validator": lambda cmd: cmd and ("env" in cmd or "printenv" in cmd)
    },

    # ── Hardware & System Info (4) ────────────────────────────────────────────
    {
        "query": "how many CPU cores does my Mac have?",
        "validator": lambda cmd: cmd and "sysctl" in cmd and ("cpu" in cmd.lower() or "ncpu" in cmd)
    },
    {
        "query": "what macOS version am I running?",
        "validator": lambda cmd: cmd and ("sw_vers" in cmd or "uname" in cmd or "system_profiler" in cmd)
    },
    {
        "query": "what's my Mac's hostname?",
        "validator": lambda cmd: cmd and "hostname" in cmd
    },
    {
        "query": "how much battery do I have left?",
        "validator": lambda cmd: cmd and "pmset" in cmd and "batt" in cmd
    },

    # ── Process Management (2) ────────────────────────────────────────────────
    {
        "query": "is the Slack app running?",
        "validator": lambda cmd: cmd and ("pgrep" in cmd or "ps" in cmd) and "slack" in cmd.lower()
    },
    {
        "query": "is the Xcode app running?",
        "validator": lambda cmd: cmd and ("pgrep" in cmd or "ps" in cmd) and "xcode" in cmd.lower()
    },

    # ── WiFi & Battery (2) ────────────────────────────────────────────────────
    {
        "query": "what WiFi network am I connected to?",
        "validator": lambda cmd: cmd and ("networksetup" in cmd or "airport" in cmd)
    },
    {
        "query": "show me all scheduled cron jobs",
        "validator": lambda cmd: cmd and "crontab" in cmd
    },

    # ── Web Shortcuts — <open> (4) ────────────────────────────────────────────
    {
        "query": "let's meditate",
        "type": "open",
        "validator": lambda key: key == "headspace"
    },
    {
        "query": "I want to do some meditation",
        "type": "open",
        "validator": lambda key: key == "headspace"
    },
    {
        "query": "play some lofi music",
        "type": "open",
        "validator": lambda key: key == "lofi"
    },
    {
        "query": "put on some chill background music",
        "type": "open",
        "validator": lambda key: key == "lofi"
    },

    # ── Reminders — <remind> (2) ──────────────────────────────────────────────
    {
        "query": "remind me in 5 minutes to take a break",
        "type": "remind",
        "validator": lambda r: r is not None
    },
    {
        "query": "set a reminder for 10 minutes",
        "type": "remind",
        "validator": lambda r: r is not None
    },

]


def run_tests(model_name="Unknown model"):
    print("=" * 50)
    print(f"  🧪 Raju LLM Test Suite")
    print(f"  Model : {model_name}")
    print(f"  Tests : {len(TEST_CASES)}")
    print("=" * 50)

    passed = 0
    total = len(TEST_CASES)

    for i, test in enumerate(TEST_CASES, 1):
        query     = test["query"]
        validator = test["validator"]
        test_type = test.get("type", "bash")  # bash | open | remind

        print(f"\n[Test {i}/{total}] [{test_type.upper()}] Query: '{query}'")
        raw_response = query_llm(query)

        if raw_response.startswith("ERROR"):
            print("❌ FAIL - Server error or timeout:", raw_response)
            continue

        if test_type == "open":
            key = extract_open(raw_response)
            if key is None:
                print(f"⚠️  Warn - No <open> tag. Raw: {raw_response[:120]}")
                is_valid = False
            else:
                print(f"🌐 <open> key: {key}")
                is_valid = validator(key)

        elif test_type == "remind":
            content = extract_remind(raw_response)
            if content is None:
                print(f"⚠️  Warn - No <remind> tag. Raw: {raw_response[:120]}")
                is_valid = False
            else:
                print(f"⏰ <remind>: {content[:80]}")
                is_valid = validator(content)

        else:  # bash
            cmd = extract_bash(raw_response)
            if cmd is None:
                print(f"⚠️  Warn - No <bash> tags. Raw: {raw_response[:120]}")
                is_valid = validator(raw_response)
            else:
                print(f"🔧 Generated: {cmd}")
                is_valid = validator(cmd)

        if is_valid:
            print("✅ PASS")
            passed += 1
        else:
            print("❌ FAIL - Response did not meet validator constraints.")

    print("\n" + "=" * 50)
    pct = int(round((passed / total) * 100))
    result_icon = "✅" if pct >= 70 else "❌"
    print(f"{result_icon} RESULT [{model_name}]: {passed}/{total} ({pct}%) passed")
    print("=" * 50)

    # Write shields.io endpoint JSON for live README badge
    safe_name = model_name.lower().replace(" ", "-").replace(".", "_")
    os.makedirs("ci-results", exist_ok=True)
    color = "brightgreen" if pct >= 80 else "yellow" if pct >= 60 else "red"
    badge = {
        "schemaVersion": 1,
        "label": model_name,
        "message": f"{pct}% ({passed}/{total})",
        "color": color
    }
    badge_path = f"ci-results/{safe_name}.json"
    with open(badge_path, "w") as f:
        json.dump(badge, f)
    print(f"📄 Badge written to {badge_path}")

    if pct < 70:
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Raju LLM test suite")
    parser.add_argument("--model", default="Unknown", help="Model name label for output")
    parser.add_argument("--model-path", default="", help="Path to GGUF model file (required with --restart)")
    parser.add_argument("--restart", action="store_true", help="Kill and restart llama-server before testing")
    args = parser.parse_args()

    if args.restart:
        model_path = args.model_path or os.path.expanduser(
            "~/local_llms/llama.cpp/models/qwen2-1.5b.gguf"
        )
        if not restart_server(model_path):
            print("❌ Could not start llama-server. Aborting.")
            sys.exit(1)

    run_tests(model_name=args.model)
