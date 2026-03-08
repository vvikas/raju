import Cocoa
import Foundation
import AVFoundation

// ── Paths & ports ─────────────────────────────────────────────────────────────
let HOME           = FileManager.default.homeDirectoryForCurrentUser.path
let WHISPER_SERVER = "\(HOME)/local_llms/whisper.cpp/build/bin/whisper-server"
let WHISPER_MODEL  = "\(HOME)/local_llms/whisper.cpp/models/ggml-small.bin"
let LLAMA_SERVER   = "\(HOME)/local_llms/llama.cpp/build/bin/llama-server"
let LLAMA_MODEL    = "\(HOME)/local_llms/llama.cpp/models/qwen2-1.5b.gguf"
let REC_BIN        = "/usr/local/bin/rec"
let PYTHON3_BIN    = "/usr/local/bin/python3"
let PIPER_OUT      = "/tmp/raju_tts.wav"
let SAY_BIN        = "/usr/bin/say"
let AUDIO_FILE     = "/tmp/raju_input.wav"
let LOG_FILE       = "\(HOME)/Raju/raju.log"
let VOICES_DIR     = "\(HOME)/.raju/voices"

// ── Prompt format — each model family uses different chat tokens ──────────────
enum PromptFormat {
    case chatML  // <|im_start|>system … <|im_end|>   (Qwen2, DeepSeek, TinyLlama)
    case phi3    // <|system|> … <|end|>              (Phi-3 / Phi-3.5)
}

// ── Available LLM models ──────────────────────────────────────────────────────
struct LLMModel {
    let name: String
    let file: String
    let format: PromptFormat
    var path: String { "\(HOME)/local_llms/llama.cpp/models/\(file)" }
}

let MODELS: [LLMModel] = [
    LLMModel(name: "Qwen2 1.5B",          file: "qwen2-1.5b.gguf",                  format: .chatML),
    LLMModel(name: "DeepSeek-Coder 1.3B", file: "deepseek-coder-1.3b.gguf",         format: .chatML),
    LLMModel(name: "TinyLlama 1.1B",      file: "tinyllama.gguf",                   format: .chatML),
    LLMModel(name: "Phi-3.5 Mini 3.8B",   file: "phi-3.5-mini-instruct-q4.gguf",   format: .phi3),
]

// ── Available Piper voices ────────────────────────────────────────────────────
struct PiperVoice {
    let name: String
    let file: String      // e.g. "en_US-lessac-medium.onnx"
    let urlPath: String   // HuggingFace path under piper-voices/main/
    var path: String    { "\(VOICES_DIR)/\(file)" }
    var onnxURL: String { "https://huggingface.co/rhasspy/piper-voices/resolve/main/\(urlPath)/\(file)" }
    var jsonURL: String { "\(onnxURL).json" }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: path) }
}

let VOICES: [PiperVoice] = [
    PiperVoice(name: "Lessac (US Female)",   file: "en_US-lessac-medium.onnx",  urlPath: "en/en_US/lessac/medium"),
    PiperVoice(name: "Ryan (US Male)",       file: "en_US-ryan-medium.onnx",    urlPath: "en/en_US/ryan/medium"),
    PiperVoice(name: "Amy (US Female)",      file: "en_US-amy-medium.onnx",     urlPath: "en/en_US/amy/medium"),
    PiperVoice(name: "Joe (US Male)",        file: "en_US-joe-medium.onnx",     urlPath: "en/en_US/joe/medium"),
    PiperVoice(name: "Jenny (GB Female)",    file: "en_GB-jenny-medium.onnx",   urlPath: "en/en_GB/jenny/medium"),
    PiperVoice(name: "Alan (GB Male)",       file: "en_GB-alan-medium.onnx",    urlPath: "en/en_GB/alan/medium"),
]

let LLAMA_PORT     = 8080
let WHISPER_PORT   = 8081
let LLAMA_URL      = "http://127.0.0.1:\(LLAMA_PORT)"
let WHISPER_URL    = "http://127.0.0.1:\(WHISPER_PORT)"

// ── Logger ────────────────────────────────────────────────────────────────────
// Serial queue keeps concurrent log() calls from interleaving bytes mid–emoji
private let logQueue = DispatchQueue(label: "com.raju.log")

func log(_ msg: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss"
    let line = "[\(fmt.string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    guard let data = line.data(using: .utf8) else { return }
    logQueue.async {
        if FileManager.default.fileExists(atPath: LOG_FILE) {
            if let fh = FileHandle(forWritingAtPath: LOG_FILE) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else {
            // Prepend UTF-8 BOM (EF BB BF) so TextEdit/editors auto-detect UTF-8
            // Without it, macOS defaults to Mac Roman and emoji look like garbage.
            let bom = Data([0xEF, 0xBB, 0xBF])
            try? (bom + data).write(to: URL(fileURLWithPath: LOG_FILE))
        }
    }
}

// ── State ─────────────────────────────────────────────────────────────────────
enum RajuState {
    case idle, recording, transcribing, thinking, speaking
    var icon: String { switch self {
        case .idle:         return "🎙️"
        case .recording:    return "🔴"
        case .transcribing: return "⏳"
        case .thinking:     return "🤔"
        case .speaking:     return "🔊"
    }}
    var hint: String { switch self {
        case .idle:         return "  Click to speak"
        case .recording:    return "  Recording… click to stop"
        case .transcribing: return "  Transcribing…"
        case .thinking:     return "  Thinking…"
        case .speaking:     return "  Speaking…"
    }}
}

// ── TTS — piper (python3 -m piper) if model exists, fallback to say ──────────
func speak(_ text: String, modelPath: String) {
    let fm = FileManager.default
    if fm.fileExists(atPath: modelPath) {
        let piper = Process()
        piper.executableURL = URL(fileURLWithPath: PYTHON3_BIN)
        piper.arguments = ["-m", "piper", "--model", modelPath, "--output_file", PIPER_OUT]
        let inputPipe = Pipe()
        piper.standardInput  = inputPipe
        piper.standardOutput = Pipe()
        piper.standardError  = Pipe()
        try? piper.run()
        inputPipe.fileHandleForWriting.write(text.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        piper.waitUntilExit()
        shell("/usr/bin/afplay", [PIPER_OUT])
    } else {
        // Fallback — macOS built-in TTS
        shell(SAY_BIN, ["-v", "Samantha", text])
    }
}

// ── Shell helper ──────────────────────────────────────────────────────────────
@discardableResult
func shell(_ bin: String, _ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: bin)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError  = Pipe()
    try? task.run(); task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

// ── Static context — one line, built once at launch ───────────────────────────
var staticContext = ""

func buildStaticContext() {
    let os    = shell("/usr/bin/sw_vers", ["-productVersion"]).trimmed
    let model = shell("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmed
    let cpu   = shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmed
    let ramGB = (Int(shell("/usr/sbin/sysctl", ["-n", "hw.memsize"]).trimmed) ?? 0) / 1_073_741_824
    staticContext = "macOS \(os) on \(model) — \(cpu), \(ramGB)GB RAM"
    log("📋 Machine: \(staticContext)")
}

// ── Safe tool runner — LLM can request one bash command per turn ──────────────
func runTool(_ rawCmd: String) -> String {
    // Block destructive / network / privilege operations
    let blocked = ["rm ", "sudo", "curl", "wget", "kill", "pkill", "mv ", "cp ",
                   "launchctl", "chmod", "chown", "> ", ">>", "python", "ruby",
                   "perl", "bash -c", "sh -c", "eval", "exec", "nc ", "osascript"]
    let lower = rawCmd.lowercased()
    for b in blocked where lower.contains(b) {
        return "Error: '\(b)' not permitted"
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", rawCmd]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError  = pipe
    try? task.run()

    // Hard 5-second timeout
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        if task.isRunning { task.terminate() }
    }
    task.waitUntilExit()

    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    // Clean up paths → readable names (e.g. "Claude Code" not "/Applications/Cl…")
    let cleaned = cleanToolOutput(out)
    // Cap at 20 lines so it fits in context
    return cleaned.components(separatedBy: "\n").prefix(20).joined(separator: "\n").trimmed
}

/// Convert absolute paths in tool output to readable names.
/// "/Applications/Claude Code.app/Contents/MacOS/Claude Helper (Renderer) --flags" → "Claude Code"
/// "/usr/local/bin/python3" → "python3"
/// Leaves non-path tokens (numbers, flags, etc.) unchanged.
func cleanToolOutput(_ text: String) -> String {
    var s = text
    // Pass 1 — consume the ENTIRE .app bundle path including the internal binary + its
    // space-separated words (stops at the first -flag so args aren't swallowed).
    // Handles arbitrary parent depth (/Applications/ or /System/Library/CoreServices/)
    // and multi-word binary names (Claude Helper (Renderer)).
    // "/path/App Name.app/Contents/MacOS/Binary Name --flag" → "App Name"
    if let re = try? NSRegularExpression(
            pattern: #"(?:/[^/\n]+)*/([^/\n]+)\.app/[^\s]*(?: [^\s-][^\s]*)*"#) {
        s = re.stringByReplacingMatches(in: s,
            range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }
    // Pass 2 — replace remaining absolute paths (no spaces) with basename: /a/b/foo → foo
    // Requires 2+ components so bare "/24" (CIDR notation) is untouched.
    if let re = try? NSRegularExpression(pattern: #"/(?:[^\s/]+/)+([^\s/]+)"#) {
        s = re.stringByReplacingMatches(in: s,
            range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }
    return s
}

// ── String helper ─────────────────────────────────────────────────────────────
extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var data: Data? { self.data(using: .utf8) }
}
extension Data {
    static func += (lhs: inout Data, rhs: Data?) { if let r = rhs { lhs.append(r) } }
    static func += (lhs: inout Data, rhs: String) { if let d = rhs.data(using: .utf8) { lhs.append(d) } }
}

// ── Server health checks ──────────────────────────────────────────────────────
func isLlamaReady() -> Bool {
    guard let url = URL(string: "\(LLAMA_URL)/health") else { return false }
    var req = URLRequest(url: url, timeoutInterval: 2)
    req.httpMethod = "GET"
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        ok = (resp as? HTTPURLResponse)?.statusCode == 200
        sem.signal()
    }.resume()
    sem.wait()
    return ok
}

func isWhisperReady() -> Bool {
    guard let url = URL(string: "\(WHISPER_URL)/inference") else { return false }
    var req = URLRequest(url: url, timeoutInterval: 1)
    req.httpMethod = "POST"
    var up = false
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        up = resp != nil
        sem.signal()
    }.resume()
    sem.wait()
    return up
}

// ── Transcribe via whisper-server ─────────────────────────────────────────────
func transcribeViaHTTP() -> String {
    guard let url = URL(string: "\(WHISPER_URL)/inference"),
          let audioData = try? Data(contentsOf: URL(fileURLWithPath: AUDIO_FILE)) else { return "" }

    let boundary = "RajuBoundary\(Int.random(in: 10000...99999))"
    var body = Data()
    body += "--\(boundary)\r\n"
    body += "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
    body += "Content-Type: audio/wav\r\n\r\n"
    body += audioData
    body += "\r\n--\(boundary)\r\n"
    body += "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n"
    body += "json\r\n"
    body += "--\(boundary)--\r\n"

    var req = URLRequest(url: url, timeoutInterval: 120)
    req.httpMethod = "POST"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = body

    var result = ""
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, error in
        if let error = error { log("⚠️ Whisper HTTP error: \(error.localizedDescription)") }
        else if let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = json["text"] as? String {
            result = text.trimmed
        }
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

// ── Prompt builder — wraps system+user in the right chat template ─────────────
func buildPrompt(system: String, user: String, format: PromptFormat) -> String {
    switch format {
    case .chatML:
        return "<|im_start|>system\n\(system)\n<|im_end|>\n<|im_start|>user\n\(user)\n<|im_end|>\n<|im_start|>assistant\n\n"
    case .phi3:
        return "<|system|>\n\(system)<|end|>\n<|user|>\n\(user)<|end|>\n<|assistant|>\n"
    }
}

func stopTokens(for format: PromptFormat) -> [String] {
    switch format {
    case .chatML: return ["<|im_end|>", "<|endoftext|>", "<|im_start|>"]
    case .phi3:   return ["<|end|>", "<|endoftext|>", "<|user|>"]
    }
}

// ── Raw llama-server call — send prompt, get completion ───────────────────────
func callLlama(prompt: String, maxTokens: Int = 200, stop: [String] = ["<|im_end|>", "<|endoftext|>", "<|im_start|>"]) -> String {
    guard let url = URL(string: "\(LLAMA_URL)/completion") else { return "" }
    let body: [String: Any] = [
        "prompt": prompt,
        "n_predict": maxTokens,
        "temperature": 0.7,
        "repeat_penalty": 1.1,
        "stop": stop
    ]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return "" }
    var req = URLRequest(url: url, timeoutInterval: 120)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = jsonData
    var result = ""
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, error in
        if let error = error { log("⚠️ LLM error: \(error.localizedDescription)") }
        else if let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let content = json["content"] as? String {
            result = content.trimmed
        }
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

// ── Tool-use LLM — LLM may request one bash command, result fed back ──────────
func askLLMWithTools(query: String, format: PromptFormat = .chatML) -> String {
    let timeFmt = DateFormatter()
    timeFmt.dateFormat = "EEEE, MMM d yyyy, HH:mm"
    let now = timeFmt.string(from: Date())
    let stops = stopTokens(for: format)

    // Turn 1 — ask LLM: answer directly OR emit exactly one TOOL: line
    let sys1 = """
    You are Raju, a macOS voice assistant. Machine: \(staticContext). Time: \(now).
    Use a tool ONLY when the question needs live system or file data. Output ONLY one line:
    TOOL: <bash command>

    System commands:
      ps -Axo pid,args,%cpu,%mem -r | head -8          → most CPU-hungry apps
      ps -Axo pid,args,%cpu,%mem -m | head -8          → most RAM-hungry apps
      df -h /                                          → disk space
      vm_stat                                          → memory/RAM stats
      pmset -g batt                                    → battery level
      ifconfig en0                                     → IP address, network
      uptime                                           → uptime and load

    File commands (use ~/ for home directory):
      ls -lhS ~/Desktop | head -10                          → biggest files on Desktop
      ls -lhS ~/Downloads | head -10                        → biggest files in Downloads
      du -sh ~/Desktop/* | sort -rh | head -5               → folder sizes on Desktop
      find ~/Desktop -maxdepth 1 -name "*.ext"              → find files by extension
      find ~/ -maxdepth 4 -name "filename" 2>/dev/null      → find a file by name
      grep -ril "text" ~/Documents 2>/dev/null | head -20   → files containing text (Documents)
      grep -ril "text" ~/Desktop 2>/dev/null | head -20     → files containing text (Desktop)

    Do NOT use rm, mv, cp, sudo, or any command that modifies files.
    Answer directly (no tool) for: weather, outside temperature, news,
    stock prices, general knowledge, math, or anything not needing live data.
    Answer in 1-3 sentences. Do not mix a TOOL line with other text.
    """
    let p1 = buildPrompt(system: sys1, user: query, format: format)
    let r1 = callLlama(prompt: p1, maxTokens: 60, stop: stops).trimmed

    // Check only the first line — ignore any extra text the model may have generated
    let firstLine = r1.components(separatedBy: "\n").first?.trimmed ?? ""

    // Small models sometimes forget the TOOL: prefix and output a raw shell command.
    // Detect those so we don't accidentally speak a bash one-liner aloud.
    let knownShellCmds = ["ps ", "df ", "vm_stat", "pmset ", "ifconfig", "uptime",
                          "netstat", "iostat", "sw_vers", "sysctl ", "diskutil",
                          "ls ", "du ", "find ", "locate ", "grep "]
    let looksLikeShell = knownShellCmds.contains(where: { firstLine.hasPrefix($0) })
                      || (firstLine.contains(" | ") && !firstLine.hasSuffix("?"))

    guard firstLine.hasPrefix("TOOL:") || looksLikeShell else { return r1 }

    // Strip TOOL: prefix if present; otherwise the line itself is the command
    var cmd: String
    if firstLine.hasPrefix("TOOL:") {
        cmd = String(firstLine.dropFirst(5)).trimmed
    } else {
        log("⚠️ LLM skipped TOOL: prefix — treating as tool call: \(firstLine)")
        cmd = firstLine
    }
    guard !cmd.isEmpty else { return callLlama(prompt: p1, maxTokens: 200).trimmed }

    log("🔧 Tool call: \(cmd)")
    var toolOut = runTool(cmd)
    log("🔧 Tool output (\(toolOut.count)c): \(toolOut.prefix(200))")

    // Retry if the LLM's command produced useless output (e.g. just a header line,
    // or the model added extra awk/sort pipes that ate all the data).
    let usefulLines = toolOut.components(separatedBy: "\n")
        .filter { !$0.trimmed.isEmpty }
    if usefulLines.count < 2 || toolOut.trimmed.count < 20 {
        // Build a known-good fallback: strip extra pipes for non-ps commands,
        // use canonical ps command for process queries.
        let fallback: String
        if cmd.lowercased().contains("ps ") {
            // Preserve the sort flag the LLM picked; fall back to -r if none present
            let sortFlag = cmd.contains("-m") ? "-m" : "-r"
            fallback = "ps -Axo pid,args,%cpu,%mem \(sortFlag) | head -8"
        } else {
            fallback = cmd.components(separatedBy: "|").first?.trimmed ?? cmd
        }
        if fallback != cmd {
            log("⚠️ Sparse output (\(toolOut.count)c) — retrying: \(fallback)")
            toolOut = runTool(fallback)
            log("🔧 Retry output (\(toolOut.count)c): \(toolOut.prefix(200))")
        }
    }

    // Guarantee at least 5 non-empty lines reach the LLM; trim to 20 max to save context.
    let allLines = toolOut.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }
    let topLines = allLines.prefix(20).joined(separator: "\n")
    let dataForLLM = topLines.isEmpty ? "(command returned no output)" : topLines

    // If the result is a list (>4 lines), copy the full output to clipboard so the user
    // can paste it. The LLM is told about this so it can mention it in its reply.
    var clipboardNote = ""
    if allLines.count > 4 {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(toolOut, forType: .string)
        }
        clipboardNote = "The full list (\(allLines.count) items) has been copied to the clipboard.\n"
        log("📋 Copied \(allLines.count)-line result to clipboard")
    }

    // Tell the LLM how the ps data is sorted so it doesn't confuse CPU% with RAM%
    let sortNote: String
    if cmd.contains("-m") {
        sortNote = "sorted by RAM usage (highest first)"
    } else if cmd.contains("-r") {
        sortNote = "sorted by CPU usage (highest first)"
    } else {
        sortNote = ""
    }
    let sortLabel = sortNote.isEmpty ? "" : "Note: list is \(sortNote).\n"

    // Turn 2 — completely fresh prompt so small models don't get confused by conversation history
    let sys2 = """
    You are Raju, a macOS voice assistant. Answer in 1-3 short spoken sentences.
    Use ONLY the data below — do not invent numbers or process names.
    Never refuse. If the data does not answer the question, say: "I don't have that data right now."
    """
    let usr2 = "Live data (from `\(cmd)`):\n\(clipboardNote)\(sortLabel)\(dataForLLM)\n\nQuestion: \(query)"
    let p2 = buildPrompt(system: sys2, user: usr2, format: format)
    let r2 = callLlama(prompt: p2, maxTokens: 150, stop: stops).trimmed

    // Safety net: never speak a TOOL: line or a raw shell command
    let r2LooksLikeShell = knownShellCmds.contains(where: { r2.hasPrefix($0) })
                        || (r2.contains(" | ") && r2.count < 200 && !r2.contains("?"))
    if r2.hasPrefix("TOOL:") || r2LooksLikeShell {
        let rest = r2.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmed
        return rest.isEmpty ? "I ran the command but couldn't summarise the results." : rest
    }

    // Detect refusal phrases ("Sorry, but I can't assist", "I'm not able to", etc.)
    let refusalPhrases = ["can't assist", "cannot assist", "i'm not able", "i am not able",
                          "i'm unable", "i cannot help", "not able to help", "sorry, but i"]
    let r2Low = r2.lowercased()
    if refusalPhrases.contains(where: { r2Low.contains($0) }) {
        log("⚠️ LLM refused in Turn 2 — returning fallback")
        return "I don't have that data right now."
    }
    return r2
}

// ── App ───────────────────────────────────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem:     NSStatusItem!
    var menu:           NSMenu!
    var llamaProcess:   Process?
    var whisperProcess: Process?
    var state: RajuState = .idle { didSet { DispatchQueue.main.async { self.refreshUI() } } }

    var recProcess: Process?
    var lastQuery  = ""
    var lastReply  = ""

    var currentModelIndex = 0
    var modelMenuItems: [NSMenuItem] = []
    var currentVoiceIndex = 0
    var voiceMenuItems: [NSMenuItem] = []

    let itemLlama        = NSMenuItem(title: "  ⏳ LLM loading…",    action: nil,                                    keyEquivalent: "")
    let itemWhisper      = NSMenuItem(title: "  ⏳ Whisper loading…", action: nil,                                    keyEquivalent: "")
    let itemLlamaToggle  = NSMenuItem(title: "  ⏹ Stop LLM",         action: #selector(toggleLlama),                 keyEquivalent: "")
    let itemWhisperToggle = NSMenuItem(title: "  ⏹ Stop Whisper",    action: #selector(toggleWhisper),               keyEquivalent: "")
    let itemModel        = NSMenuItem(title: "  🧠 Model",            action: nil,                                    keyEquivalent: "")
    let itemVoice        = NSMenuItem(title: "  🗣️ Voice",            action: nil,                                    keyEquivalent: "")
    let itemHint         = NSMenuItem(title: "  Hold to speak",       action: nil,                                    keyEquivalent: "")
    let itemStatus       = NSMenuItem(title: "",                      action: nil,                                    keyEquivalent: "")
    let itemQuery        = NSMenuItem(title: "",                      action: nil,                                    keyEquivalent: "")
    let itemReply        = NSMenuItem(title: "",                      action: nil,                                    keyEquivalent: "")
    let itemLaunchAtLogin = NSMenuItem(title: "  Launch at Login",    action: #selector(toggleLaunchAtLogin),         keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "🎙️"
            btn.action = #selector(iconClicked)
            btn.target = self
            btn.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
        }

        // Build model submenu
        let modelSubmenu = NSMenu()
        for (i, model) in MODELS.enumerated() {
            let item = NSMenuItem(title: model.name, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.tag    = i
            item.target = self
            item.state  = (i == 0) ? .on : .off
            modelSubmenu.addItem(item)
            modelMenuItems.append(item)
        }
        itemModel.title   = "  🧠 \(MODELS[0].name)"
        itemModel.submenu = modelSubmenu

        // Build voice submenu
        let voiceSubmenu = NSMenu()
        for (i, voice) in VOICES.enumerated() {
            let item = NSMenuItem(title: voice.name, action: #selector(selectVoice(_:)), keyEquivalent: "")
            item.tag    = i
            item.target = self
            item.state  = (i == 0) ? .on : .off
            if !voice.isDownloaded && i != 0 { item.title = voice.name + "  ↓" }
            voiceSubmenu.addItem(item)
            voiceMenuItems.append(item)
        }
        itemVoice.title   = "  🗣️ \(VOICES[0].name)"
        itemVoice.submenu = voiceSubmenu

        itemLlamaToggle.target   = self
        itemWhisperToggle.target = self
        itemLaunchAtLogin.target = self
        itemLaunchAtLogin.state  = isLaunchAtLoginEnabled() ? .on : .off

        menu = NSMenu()
        menu.addItem(NSMenuItem(title: "── Raju ─────────────────", action: nil, keyEquivalent: ""))
        menu.addItem(itemLlama)
        menu.addItem(itemLlamaToggle)
        menu.addItem(itemWhisper)
        menu.addItem(itemWhisperToggle)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(itemModel)
        menu.addItem(itemVoice)
        menu.addItem(itemHint)
        menu.addItem(itemStatus)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(itemQuery)
        menu.addItem(itemReply)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "  📄 Show Log", action: #selector(showLog), keyEquivalent: "l"))
        menu.addItem(itemLaunchAtLogin)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = nil
        refreshUI()

        log("── Raju started ──────────────────────────────")

        // Request microphone permission immediately — triggers macOS prompt if not yet granted
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log(granted ? "🎤 Microphone access granted" : "⚠️ Microphone access DENIED — recording will be silent. Grant access in System Preferences → Privacy → Microphone.")
        }

        // Build static context + start servers in parallel
        DispatchQueue.global(qos: .background).async { buildStaticContext() }
        DispatchQueue.global(qos: .background).async { self.startLlamaServer() }
        DispatchQueue.global(qos: .background).async { self.startWhisperServer() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("🛑 Raju quitting — killing servers")
        llamaProcess?.terminate()
        whisperProcess?.terminate()
    }

    // ── Server management ──────────────────────────────────────────────────────
    func startLlamaServer() {
        if isLlamaReady() {
            let name = MODELS[currentModelIndex].name
            log("⚡ llama-server already running on :\(LLAMA_PORT) — \(name)")
            DispatchQueue.main.async {
                self.itemLlama.title       = "  ⚡ LLM ready (\(name))"
                self.itemLlamaToggle.title = "  ⏹ Stop LLM"
            }
            return
        }
        let model = MODELS[currentModelIndex]
        log("🚀 Starting llama-server (\(model.name)) on :\(LLAMA_PORT)…")
        llamaProcess = Process()
        llamaProcess!.executableURL = URL(fileURLWithPath: LLAMA_SERVER)
        llamaProcess!.arguments = ["-m", model.path, "-ngl", "999",
                                   "--port", "\(LLAMA_PORT)", "--host", "127.0.0.1",
                                   "-n", "200", "--log-disable"]
        llamaProcess!.standardOutput = Pipe()
        llamaProcess!.standardError  = Pipe()
        try? llamaProcess!.run()

        var secs = 0
        while secs < 180 {
            Thread.sleep(forTimeInterval: 2); secs += 2
            if isLlamaReady() {
                log("⚡ llama-server ready after \(secs)s — \(model.name)")
                DispatchQueue.main.async {
                    self.itemLlama.title       = "  ⚡ LLM ready (\(model.name))"
                    self.itemLlamaToggle.title = "  ⏹ Stop LLM"
                }
                return
            }
            if secs % 20 == 0 { log("⏳ \(model.name) still loading… (\(secs)s)") }
        }
        log("⚠️ llama-server failed to start within 3 min")
        DispatchQueue.main.async {
            self.itemLlama.title       = "  ❌ \(model.name) failed to load"
            self.itemLlamaToggle.title = "  ▶ Start LLM"
        }
    }

    func startWhisperServer() {
        if isWhisperReady() {
            log("⚡ whisper-server already running on :\(WHISPER_PORT)")
            DispatchQueue.main.async {
                self.itemWhisper.title       = "  ⚡ Whisper ready (small)"
                self.itemWhisperToggle.title = "  ⏹ Stop Whisper"
            }
            return
        }
        log("🚀 Starting whisper-server (small) on :\(WHISPER_PORT)…")
        whisperProcess = Process()
        whisperProcess!.executableURL = URL(fileURLWithPath: WHISPER_SERVER)
        whisperProcess!.arguments = ["-m", WHISPER_MODEL,
                                     "--port", "\(WHISPER_PORT)", "--host", "127.0.0.1"]
        whisperProcess!.standardOutput = Pipe()
        whisperProcess!.standardError  = Pipe()
        try? whisperProcess!.run()

        var secs = 0
        while secs < 120 {
            Thread.sleep(forTimeInterval: 2); secs += 2
            if isWhisperReady() {
                log("⚡ whisper-server ready after \(secs)s")
                DispatchQueue.main.async {
                    self.itemWhisper.title       = "  ⚡ Whisper ready (small)"
                    self.itemWhisperToggle.title = "  ⏹ Stop Whisper"
                }
                return
            }
            if secs % 10 == 0 { log("⏳ Whisper still loading… (\(secs)s)") }
        }
        log("⚠️ whisper-server failed to start")
        DispatchQueue.main.async {
            self.itemWhisper.title       = "  ❌ Whisper failed to load"
            self.itemWhisperToggle.title = "  ▶ Start Whisper"
        }
    }

    func bothReady() -> Bool { isLlamaReady() && isWhisperReady() }

    // ── Click handling ─────────────────────────────────────────────────────────
    @objc func iconClicked() {
        let eventType = NSApp.currentEvent?.type

        // Right-click always opens menu regardless of state
        if eventType == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        // While pipeline is running, ignore left clicks
        if state != .idle && state != .recording { return }

        // Push-to-talk: hold = record, release = stop
        if eventType == .leftMouseDown {
            if state == .idle { startRecording() }
        } else if eventType == .leftMouseUp {
            if state == .recording { stopRecording() }
        }
    }

    @objc func showLog() {
        // Write a tiny .command script and open it — macOS runs .command files in
        // Terminal automatically, no Automation entitlement required.
        // This gives live UTF-8 streaming (tail -f) with correct emoji.
        let cmdFile = "/tmp/raju_log_view.command"
        let script = """
        #!/bin/bash
        clear
        echo '── Raju live log (Ctrl+C to close) ──────────────'
        echo ''
        tail -f '\(LOG_FILE)'
        """
        try? script.write(toFile: cmdFile, atomically: true, encoding: .utf8)
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: 0o755)]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: cmdFile)
        NSWorkspace.shared.open(URL(fileURLWithPath: cmdFile))
    }

    // ── pkill helper — used by toggle functions to kill servers by name ───────
    // (bypasses runTool's blocklist since this is direct Swift code, not an LLM tool call)
    func pkillByName(_ pattern: String) {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", pattern]
        k.standardOutput = Pipe(); k.standardError = Pipe()
        try? k.run(); k.waitUntilExit()
    }

    // ── Server toggle (stop / start from menu) ─────────────────────────────────
    @objc func toggleLlama() {
        if isLlamaReady() {
            // Stop: terminate our Process handle (if we launched it) THEN pkill by
            // name so pre-existing servers (llamaProcess == nil) are also killed.
            log("⏹ Stopping llama-server…")
            llamaProcess?.terminate(); llamaProcess = nil
            pkillByName("llama-server")
            // Poll on background thread — update UI only after server is actually down
            DispatchQueue.global(qos: .background).async {
                var waited = 0
                while isLlamaReady() && waited < 10 {
                    Thread.sleep(forTimeInterval: 1); waited += 1
                }
                let still = isLlamaReady()
                log(still ? "⚠️ llama-server still running after 10s" : "⭕ llama-server stopped")
                DispatchQueue.main.async {
                    self.itemLlama.title       = still ? "  ⚠️ LLM won't stop" : "  ⭕ LLM stopped"
                    self.itemLlamaToggle.title = still ? "  ⏹ Stop LLM"        : "  ▶ Start LLM"
                }
            }
        } else {
            // Start: show "Starting…" immediately, then let startLlamaServer()
            // update itemLlama + itemLlamaToggle when the server is actually ready.
            // (Do NOT set toggle title to "⏹ Stop LLM" here — that races with the background task.)
            DispatchQueue.main.async {
                self.itemLlama.title       = "  ⏳ LLM starting…"
                self.itemLlamaToggle.title = "  ⏳ Starting…"
            }
            DispatchQueue.global(qos: .background).async { self.startLlamaServer() }
        }
    }

    @objc func toggleWhisper() {
        if isWhisperReady() {
            log("⏹ Stopping whisper-server…")
            whisperProcess?.terminate(); whisperProcess = nil
            pkillByName("whisper-server")
            DispatchQueue.global(qos: .background).async {
                var waited = 0
                while isWhisperReady() && waited < 10 {
                    Thread.sleep(forTimeInterval: 1); waited += 1
                }
                let still = isWhisperReady()
                log(still ? "⚠️ whisper-server still running after 10s" : "⭕ whisper-server stopped")
                DispatchQueue.main.async {
                    self.itemWhisper.title       = still ? "  ⚠️ Whisper won't stop" : "  ⭕ Whisper stopped"
                    self.itemWhisperToggle.title = still ? "  ⏹ Stop Whisper"        : "  ▶ Start Whisper"
                }
            }
        } else {
            DispatchQueue.main.async {
                self.itemWhisper.title       = "  ⏳ Whisper starting…"
                self.itemWhisperToggle.title = "  ⏳ Starting…"
            }
            DispatchQueue.global(qos: .background).async { self.startWhisperServer() }
        }
    }

    // ── Launch at Login ────────────────────────────────────────────────────────
    func launchAgentPath() -> String {
        "\(HOME)/Library/LaunchAgents/com.raju.app.plist"
    }

    func isLaunchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath())
    }

    @objc func toggleLaunchAtLogin() {
        let path = launchAgentPath()
        if isLaunchAtLoginEnabled() {
            shell("/bin/launchctl", ["unload", path])
            try? FileManager.default.removeItem(atPath: path)
            itemLaunchAtLogin.state = .off
            log("🚫 Removed from launch at login")
        } else {
            // Prefer running the .app bundle so mic permission is tied to it
            let bundleBin = "\(HOME)/Applications/Raju.app/Contents/MacOS/Raju"
            let execPath  = FileManager.default.fileExists(atPath: bundleBin)
                ? bundleBin
                : (Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0])
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.raju.app</string>
                <key>ProgramArguments</key>
                <array><string>\(execPath)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><false/>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(
                atPath: "\(HOME)/Library/LaunchAgents",
                withIntermediateDirectories: true)
            try? xml.write(toFile: path, atomically: true, encoding: .utf8)
            shell("/bin/launchctl", ["load", path])
            itemLaunchAtLogin.state = .on
            log("✅ Added to launch at login — using \(execPath)")
        }
    }

    @objc func selectModel(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx != currentModelIndex else { return }
        currentModelIndex = idx
        let model = MODELS[idx]

        // Update checkmarks
        modelMenuItems.forEach { $0.state = .off }
        modelMenuItems[idx].state = .on
        itemModel.title = "  🧠 \(model.name)"

        log("🔄 Switching to \(model.name) — stopping old server…")
        DispatchQueue.main.async { self.itemLlama.title = "  ⏳ Loading \(model.name)…" }

        llamaProcess?.terminate()
        llamaProcess = nil
        pkillByName("llama-server")   // also kills pre-existing servers we didn't launch

        DispatchQueue.global(qos: .background).async {
            // Wait for the old server to actually stop responding before starting the new one.
            var waited = 0
            while isLlamaReady() && waited < 15 {
                Thread.sleep(forTimeInterval: 1)
                waited += 1
            }
            if waited > 0 { log("⏳ Old server stopped after \(waited)s") }
            self.startLlamaServer()
        }
    }

    @objc func selectVoice(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx != currentVoiceIndex else { return }
        let voice = VOICES[idx]

        if voice.isDownloaded {
            currentVoiceIndex = idx
            voiceMenuItems.forEach { $0.state = .off }
            voiceMenuItems[idx].state = .on
            voiceMenuItems[idx].title = voice.name
            itemVoice.title = "  🗣️ \(voice.name)"
            log("🗣️ Voice switched to \(voice.name)")
        } else {
            // Download then switch
            log("⬇️ Downloading voice: \(voice.name) (~60 MB)…")
            DispatchQueue.main.async {
                self.voiceMenuItems[idx].title = "\(voice.name)  ⏳"
                self.itemVoice.title = "  🗣️ Downloading \(voice.name)…"
            }
            DispatchQueue.global(qos: .background).async {
                try? FileManager.default.createDirectory(atPath: VOICES_DIR,
                    withIntermediateDirectories: true)
                let ok1 = self.downloadFile(from: voice.onnxURL, to: voice.path)
                let ok2 = self.downloadFile(from: voice.jsonURL, to: voice.path + ".json")
                DispatchQueue.main.async {
                    if ok1 && ok2 {
                        self.currentVoiceIndex = idx
                        self.voiceMenuItems.forEach { $0.state = .off }
                        self.voiceMenuItems[idx].state = .on
                        self.voiceMenuItems[idx].title = voice.name
                        self.itemVoice.title = "  🗣️ \(voice.name)"
                        log("✅ Voice ready: \(voice.name)")
                    } else {
                        self.voiceMenuItems[idx].title = "\(voice.name)  ↓"
                        self.itemVoice.title = "  🗣️ \(VOICES[self.currentVoiceIndex].name)"
                        log("❌ Failed to download voice: \(voice.name)")
                    }
                }
            }
        }
    }

    @discardableResult
    func downloadFile(from urlString: String, to dest: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "GET"
        var success = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200 {
                success = (try? data.write(to: URL(fileURLWithPath: dest))) != nil
            }
            sem.signal()
        }.resume()
        sem.wait()
        return success
    }

    // ── Recording ──────────────────────────────────────────────────────────────
    func startRecording() {
        guard bothReady() else {
            log("⚠️ Servers not ready yet — wait for ⚡ on both")
            return
        }
        state = .recording
        log("🔴 Recording started")
        try? FileManager.default.removeItem(atPath: AUDIO_FILE)

        recProcess = Process()
        recProcess!.executableURL = URL(fileURLWithPath: REC_BIN)
        recProcess!.arguments = [AUDIO_FILE, "rate", "16000", "channels", "1", "trim", "0", "60"]
        recProcess!.standardOutput = Pipe()
        recProcess!.standardError  = Pipe()
        try? recProcess!.run()
    }

    func stopRecording() {
        state = .transcribing
        recProcess?.terminate(); recProcess = nil
        log("⏹️  Recording stopped — sending to whisper-server")

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Whisper STT
            let t0    = Date()
            let query = transcribeViaHTTP()
            let wt    = String(format: "%.1f", Date().timeIntervalSince(t0))

            let isBlank = query.isEmpty || query == "[BLANK_AUDIO]"
                       || query.lowercased().contains("blank_audio")
            guard !isBlank else {
                log("⚠️ Blank audio — nothing heard (took \(wt)s). Check mic permission in System Preferences.")
                self.state = .idle; return
            }
            log("⏳ Whisper done in \(wt)s → \"\(query)\"")
            self.lastQuery = query
            self.setStatus("Heard: \"\(query.prefix(50))\"")

            // Step 2: LLM with tool-use (LLM requests a bash command if needed)
            self.state = .thinking
            log("🤔 Asking LLM (tool-use mode)…")
            let t1    = Date()
            let reply = askLLMWithTools(query: query, format: MODELS[self.currentModelIndex].format)
            let lt    = String(format: "%.1f", Date().timeIntervalSince(t1))
            self.lastReply = reply.isEmpty ? "Sorry, I didn't get that." : reply
            log("💬 LLM reply in \(lt)s → \"\(self.lastReply)\"")
            self.setStatus("")

            // Step 4: TTS
            self.state = .speaking
            let voicePath = VOICES[self.currentVoiceIndex].path
            let ttsEngine = FileManager.default.fileExists(atPath: voicePath) ? "Piper (\(VOICES[self.currentVoiceIndex].name))" : "say"
            log("🔊 Speaking via \(ttsEngine)…")
            speak(self.lastReply, modelPath: voicePath)

            log("✅ Done\n")
            self.state = .idle
        }
    }

    // ── UI ─────────────────────────────────────────────────────────────────────
    func setStatus(_ msg: String) {
        DispatchQueue.main.async {
            self.itemStatus.title = msg.isEmpty ? "" : "  ℹ️ \(msg)"
        }
    }

    func refreshUI() {
        statusItem.button?.title = state.icon
        itemHint.title  = state.hint
        itemQuery.title = lastQuery.isEmpty ? "" : "  Q: \(lastQuery.prefix(60))"
        itemReply.title = lastReply.isEmpty ? "" : "  A: \(lastReply.prefix(80))"
    }
}

// ── Single instance guard ─────────────────────────────────────────────────────
NSWorkspace.shared.runningApplications
    .filter { $0.bundleIdentifier == nil && $0.executableURL?.lastPathComponent == "Raju" }
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    .forEach { $0.terminate() }

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
