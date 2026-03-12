import json
import urllib.request
import re
import os
import argparse
import sys
import subprocess
from datetime import datetime

# We will test the local LLM running on port 8080
LLAMA_URL = "http://127.0.0.1:8080"

USER_HOME = os.path.expanduser("~")


def _shell(cmd, args):
    try:
        out = subprocess.check_output([cmd] + args, stderr=subprocess.DEVNULL)
        return out.decode("utf-8").strip()
    except Exception:
        return ""


def build_machine_context():
    os_ver = _shell("/usr/bin/sw_vers", ["-productVersion"])
    model = _shell("/usr/sbin/sysctl", ["-n", "hw.model"])
    cpu = _shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
    mem_raw = _shell("/usr/sbin/sysctl", ["-n", "hw.memsize"])
    try:
        ram_gb = int(mem_raw) // 1_073_741_824 if mem_raw else 0
    except ValueError:
        ram_gb = 0

    if os_ver and model and cpu and ram_gb:
        return f"macOS {os_ver} on {model} — {cpu}, {ram_gb}GB RAM"
    return "macOS on Mac"


MACHINE_CONTEXT = os.environ.get("RAJU_MACHINE_CONTEXT") or build_machine_context()
NOW_STR = datetime.now().strftime("%A, %b %d %Y, %H:%M")

SYS_PROMPT = f"""
You are Raju, a macOS voice assistant. Machine: {MACHINE_CONTEXT}. Time: {NOW_STR}.
The user's home directory is {USER_HOME}. Always use standard macOS paths (e.g. ~/Downloads, ~/Desktop, ~/Documents). Do NOT invent or hallucinate volumes like /Volumes/downloads/.
You can run macOS terminal commands to answer technical questions.

IF YOU NEED TO RUN A COMMAND, output exactly like this and nothing else:
<bash>
the command here
</bash>

If you can answer without running a command, DO NOT output <bash>. Just answer directly in 1-2 sentences. 
Examples:
  "what's using CPU?" -> <bash>top -l 1 -o cpu -n 10 -stats pid,command,cpu,mem | tail -n +13</bash>
  "what's using RAM?" -> <bash>top -l 1 -o mem -n 10 -stats pid,command,cpu,mem | tail -n +13</bash>
  "disk space?" -> <bash>df -h /</bash>
  "system uptime?" -> <bash>uptime</bash>
  "ping google" -> <bash>ping -c 3 google.com</bash>
  "biggest files in downloads?" -> <bash>ls -lhS ~/Downloads | head -10</bash>
  "find file called budget" -> <bash>find ~/Documents -iname "*budget*" 2>/dev/null | head -15</bash>
  "is safari running?" -> <bash>pgrep -il "safari"</bash>
  "wifi network name?" -> <bash>networksetup -getairportnetwork en0</bash>
  "capital of France?" -> Paris is the capital.

FOR REMINDERS — CRITICAL: Do NOT use osascript, AppleScript, or any bash command.
Always respond with ONLY this exact format (nothing else):
  REMIND: <seconds_or_duration> <message>
Examples:
  "remind me in 5 minutes" -> REMIND: 5 minutes drink water
  "remind me in 5 minutes to drink water" -> REMIND: 5 minutes drink water
  "set a reminder for 30 minutes to take a break" -> REMIND: 30 minutes take a break
  "remind me in 1 hour to call Vikas" -> REMIND: 1 hour call Vikas
  "remind me in 10 seconds" -> REMIND: 10 seconds Time is up
"""

def extract_bash(response):
    match = re.search(r"<bash>\s*(.*?)\s*</bash>", response, re.DOTALL)
    if match:
        return match.group(1).strip()
    return None

def query_llm(query):
    data = {
        "messages": [
            {"role": "system", "content": SYS_PROMPT.strip()},
            {"role": "user", "content": query}
        ],
        "temperature": 0.1,
        "max_tokens": 80,
        "frequency_penalty": 0.0,
        "presence_penalty": 0.0,
    }
    req = urllib.request.Request(
        f"{LLAMA_URL}/v1/chat/completions",
        data=json.dumps(data).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            res = json.loads(response.read().decode('utf-8'))
            return res['choices'][0]['message']['content'].strip()
    except Exception as e:
        return f"ERROR: {e}"

# ── The Test Suite ─────────────────────────────────────────────────────────────
# 30 questions a software engineer would ask Raju.
# Validators check bash command logic — NOT exact string matches.
TEST_CASES = [

    # ── System Performance (5) ────────────────────────────────────────────────
    {
        "query": "which processes are currently hogging the CPU?",
        "validator": lambda cmd: cmd and "top" in cmd and "cpu" in cmd.lower()
    },
    {
        "query": "which apps are taking up the most memory?",
        "validator": lambda cmd: cmd and ("top" in cmd or "ps" in cmd) and ("mem" in cmd.lower() or "rss" in cmd.lower() or "vsz" in cmd.lower())
    },
    {
        "query": "how much unused RAM does this Mac have right now?",
        "validator": lambda cmd: cmd and ("vm_stat" in cmd or "top" in cmd or "memory_pressure" in cmd)
    },
    {
        "query": "how much free space is left on my main disk?",
        "validator": lambda cmd: cmd and "df" in cmd and ("/" in cmd or "-h" in cmd)
    },
    {
        "query": "for how long has this machine been running without a reboot?",
        "validator": lambda cmd: cmd and "uptime" in cmd
    },

    # ── Networking (5) ────────────────────────────────────────────────────────
    {
        "query": "what IP address is this Mac using on my local network?",
        "validator": lambda cmd: cmd and ("ifconfig" in cmd or "ipconfig getifaddr" in cmd)
    },
    {
        "query": "what is my current public IP on the internet?",
        "validator": lambda cmd: cmd and ("curl" in cmd or "wget" in cmd) and ("ifconfig.me" in cmd or "icanhazip" in cmd or "ipify" in cmd or "checkip" in cmd)
    },
    {
        "query": "show me which ports are currently listening on this Mac",
        "validator": lambda cmd: cmd and "lsof" in cmd and ("LISTEN" in cmd or "-P" in cmd)
    },
    {
        "query": "which process is bound to TCP port 3000?",
        "validator": lambda cmd: cmd and ("lsof" in cmd or "netstat" in cmd) and "3000" in cmd
    },
    {
        "query": "list all active network connections on this machine",
        "validator": lambda cmd: cmd and ("lsof" in cmd or "netstat" in cmd)
    },

    # ── Files & Search (5) ────────────────────────────────────────────────────
    {
        "query": "list the largest files sitting in my Downloads directory",
        "validator": lambda cmd: cmd and ("~/Downloads" in cmd or f"{USER_HOME}/Downloads" in cmd) and ("ls" in cmd or "find" in cmd or "du" in cmd) and "/Volumes/" not in cmd
    },
    {
        "query": "search my Mac for any file named config.json",
        "validator": lambda cmd: cmd and "find" in cmd and "config.json" in cmd
    },
    {
        "query": "within my home folder, locate every .env file",
        "validator": lambda cmd: cmd and "find" in cmd and ".env" in cmd
    },
    {
        "query": "show Python source files I've changed in the last few days",
        "validator": lambda cmd: cmd and "find" in cmd and ".py" in cmd and ("mtime" in cmd or "mmin" in cmd)
    },
    {
        "query": "on my Desktop, which file is the largest by size?",
        "validator": lambda cmd: cmd and ("~/Desktop" in cmd or f"{USER_HOME}/Desktop" in cmd) and ("ls" in cmd or "find" in cmd or "du" in cmd)
    },

    # ── Dev Tools (7) ─────────────────────────────────────────────────────────
    {
        "query": "which Python version is installed on this Mac?",
        "validator": lambda cmd: cmd and "python" in cmd.lower() and "--version" in cmd
    },
    {
        "query": "tell me which Node.js version I'm running here",
        "validator": lambda cmd: cmd and "node" in cmd and "--version" in cmd
    },
    {
        "query": "list all Docker containers that are currently running",
        "validator": lambda cmd: cmd and "docker" in cmd and "ps" in cmd
    },
    {
        "query": "which Git branch is this repository currently checked out to?",
        "validator": lambda cmd: cmd and "git" in cmd and ("branch" in cmd or "rev-parse" in cmd)
    },
    {
        "query": "display the most recent 10 Git commits for this repo",
        "validator": lambda cmd: cmd and "git" in cmd and "log" in cmd
    },
    {
        "query": "which Homebrew packages are installed on this system?",
        "validator": lambda cmd: cmd and "brew" in cmd and "list" in cmd
    },
    {
        "query": "print out the current environment variables for this shell",
        "validator": lambda cmd: cmd and ("env" in cmd or "printenv" in cmd)
    },

    # ── Hardware & System Info (4) ────────────────────────────────────────────
    {
        "query": "how many logical CPU cores are available on this Mac?",
        "validator": lambda cmd: cmd and "sysctl" in cmd and ("cpu" in cmd.lower() or "ncpu" in cmd)
    },
    {
        "query": "which macOS version is this machine currently on?",
        "validator": lambda cmd: cmd and ("sw_vers" in cmd or "uname" in cmd or "system_profiler" in cmd)
    },
    {
        "query": "what hostname is this Mac using on the network?",
        "validator": lambda cmd: cmd and "hostname" in cmd
    },
    {
        "query": "roughly what battery percentage is left on this MacBook?",
        "validator": lambda cmd: cmd and "pmset" in cmd and "batt" in cmd
    },

    # ── Process Management (2) ────────────────────────────────────────────────
    {
        "query": "can you check whether the Slack application is running right now?",
        "validator": lambda cmd: cmd and ("pgrep" in cmd or "ps" in cmd) and "slack" in cmd.lower()
    },
    {
        "query": "verify if Xcode is currently running on this Mac",
        "validator": lambda cmd: cmd and ("pgrep" in cmd or "ps" in cmd) and "xcode" in cmd.lower()
    },

    # ── WiFi & Battery (2) ────────────────────────────────────────────────────
    {
        "query": "which Wi‑Fi network is this Mac currently connected to?",
        "validator": lambda cmd: cmd and ("networksetup" in cmd or "airport" in cmd)
    },
    {
        "query": "list all cron jobs that are scheduled for my user account",
        "validator": lambda cmd: cmd and "crontab" in cmd
    },

    # ── Reminders (4) ───────────────────────────────────────────────────
    # These must output REMIND: prefix, NOT osascript/bash.
    # validator receives the extracted bash cmd (None if no <bash> tags).
    # A None cmd means the LLM answered directly — we check the raw response separately.
    {
        "query": "in five minutes, remind me to drink some water",
        "validator": lambda cmd: cmd is None  # must NOT generate a bash command
    },
    {
        "query": "set up a reminder in half an hour so I take a break",
        "validator": lambda cmd: cmd is None
    },
    {
        "query": "an hour from now, remind me to call my manager",
        "validator": lambda cmd: cmd is None
    },
    {
        "query": "ping me in about ten seconds",
        "validator": lambda cmd: cmd is None
    },

]

def run_tests(model_name="Unknown model"):
    print("="*50)
    print(f"  🧪 Raju LLM Test Suite")
    print(f"  Model : {model_name}")
    print(f"  Tests : {len(TEST_CASES)}")
    print("="*50)

    passed = 0
    total = len(TEST_CASES)

    for i, test in enumerate(TEST_CASES, 1):
        query = test["query"]
        validator = test["validator"]

        print(f"\n[Test {i}/{total}] Query: '{query}'")
        raw_response = query_llm(query)

        if raw_response.startswith("ERROR"):
            print("❌ FAIL - Server error or timeout:", raw_response)
            continue

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
            print("❌ FAIL - Command did not meet validator constraints.")
            if cmd:
                print(f"   Cmd: {cmd}")

    print("\n" + "="*50)
    pct = int(round((passed / total) * 100))
    result_icon = "✅" if pct >= 70 else "❌"
    print(f"{result_icon} RESULT [{model_name}]: {passed}/{total} ({pct}%) passed")
    print("="*50)

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
    args = parser.parse_args()
    run_tests(model_name=args.model)
