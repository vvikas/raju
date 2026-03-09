import Cocoa
import Foundation
import AVFoundation

// ── Paths & ports ─────────────────────────────────────────────────────────────
let HOME           = FileManager.default.homeDirectoryForCurrentUser.path
let WHISPER_SERVER = "\(HOME)/local_llms/whisper.cpp/build/bin/whisper-server"
let WHISPER_MODEL  = "\(HOME)/local_llms/whisper.cpp/models/ggml-small.bin"
let LLAMA_SERVER   = "\(HOME)/local_llms/llama.cpp/build/bin/llama-server"
let REC_BIN        = "/usr/local/bin/rec"
let PYTHON3_BIN    = "/usr/local/bin/python3"
let PIPER_OUT      = "/tmp/raju_tts.wav"
let SAY_BIN        = "/usr/bin/say"
let AUDIO_FILE     = "/tmp/raju_input.wav"
let LOG_FILE       = "\(HOME)/Raju/raju.log"
let VOICES_DIR     = "\(HOME)/.raju/voices"

// Models.swift — LLMModel, MODELS, PiperVoice, VOICES

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
        return "<|im_start|>system\n\(system)\n<|im_end|>\n<|im_start|>user\n\(user)\n<|im_end|>\n<|im_start|>assistant\n"
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
func callLlama(prompt: String, maxTokens: Int = 200, temperature: Double = 0.7, stop: [String] = ["<|im_end|>", "<|endoftext|>", "<|im_start|>"]) -> String {
    guard let url = URL(string: "\(LLAMA_URL)/completion") else { return "" }
    let body: [String: Any] = [
        "prompt": prompt,
        "n_predict": maxTokens,
        "temperature": temperature,
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


// ── Truncation detection — retry with bigger buffer if output was cut mid-token ──
func looksLikeTruncated(_ s: String) -> Bool {
    let t = s.trimmed
    if t.isEmpty { return false }
    let lastChar = t.last!
    // Ends mid-quote, mid-pipe, mid-paren, or with backslash
    if "'\"\\|({".contains(lastChar) { return true }
    // Ends with pipe-space (command was cut after pipe)
    if t.hasSuffix("| ") { return true }
    // Ends with common partial tokens (command was cut mid-pipe chain)
    if t.hasSuffix("awk") || t.hasSuffix("grep") || t.hasSuffix("sed") { return true }
    return false
}

// ── Strip model-specific output prefixes (A:, Answer:, etc.) ──────────────────
func cleanLLMOutput(_ text: String) -> String {
    var t = text.trimmed
    let prefixes = ["A:", "Answer:", "Response:", "Assistant:", "### Response:", "###"]
    for p in prefixes {
        if t.hasPrefix(p) { t = String(t.dropFirst(p.count)).trimmed }
    }
    return t
}

// ── Reformat raw bash output into clearly labelled lines for Turn 2 ───────────
// Small LLMs struggle with fixed-width column text; named key=value pairs are
// much easier for them to parse correctly.
func reformatOutput(_ raw: String, cmd: String) -> String {
    let lines = raw.components(separatedBy: "\n")

    // ── ps -Axo pid,args,%cpu,%mem ─────────────────────────────────────────────
    if cmd.contains("ps ") && cmd.contains("%cpu") && cmd.contains("%mem") {
        let byRAM = cmd.contains("-m")
        var rows: [String] = [byRAM ? "Processes sorted by RAM (highest first):"
                                    : "Processes sorted by CPU (highest first):"]
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, Int(f[0]) != nil else { continue }   // skip header
            let pid  = String(f[0])
            let ram  = String(f[f.count - 1])
            let cpu  = String(f[f.count - 2])
            let name = f[1 ..< f.count - 2].joined(separator: " ")
            rows.append("  pid=\(pid), name=\(name), cpu=\(cpu)%, ram=\(ram)%")
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : raw
    }

    // ── ls -l (Desktop / Downloads / Documents) ────────────────────────────────
    if cmd.contains("ls -") && (cmd.contains("~/Desktop") || cmd.contains("~/Downloads")
                                 || cmd.contains("~/Documents")) {
        // "-S" may appear as a combined flag like "-lhS", so check for uppercase S
        // in the flags portion (before the first space after "ls")
        let lsFlags = cmd.components(separatedBy: " ").first(where: { $0.hasPrefix("-") }) ?? ""
        let bySize = lsFlags.contains("S")
        var rows: [String] = [bySize ? "Files sorted by size (largest first):"
                                     : "Files sorted by date (newest first):"]
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 9,
                  f[0].hasPrefix("-") || f[0].hasPrefix("d") else { continue }
            let size = String(f[4])
            let name = f[8...].joined(separator: " ")
            rows.append("  size=\(size), file=\(name)")
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : raw
    }

    // ── find -ls (file type searches across device) ────────────────────────────
    // `find -ls` columns: inode blocks perms links owner group size month day time path
    // Sorted by size already (via sort -k7 -rn in the command).
    if cmd.contains("find ") && cmd.contains(" -ls") {
        var rows: [String] = ["Files found (sorted by size, largest first):"]
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 11 else { continue }
            let size = String(f[6])                                // 7th field = size in bytes
            let path = f[10...].joined(separator: " ")             // path (may contain spaces)
            let name = URL(fileURLWithPath: path).lastPathComponent
            // Convert bytes to human-readable
            let bytes = Int(size) ?? 0
            let hr: String
            switch bytes {
            case 1_073_741_824...: hr = String(format: "%.1fG", Double(bytes)/1_073_741_824)
            case 1_048_576...:     hr = String(format: "%.1fM", Double(bytes)/1_048_576)
            case 1_024...:         hr = String(format: "%.0fK", Double(bytes)/1_024)
            default:               hr = "\(bytes)B"
            }
            rows.append("  size=\(hr), file=\(name)")
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : raw
    }

    // ── df -h (disk usage) ─────────────────────────────────────────────────────
    if cmd.hasPrefix("df ") {
        var rows: [String] = ["Disk space:"]
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5, !f[0].hasPrefix("Filesystem") else { continue }
            rows.append("  filesystem=\(f[0]), size=\(f[1]), used=\(f[2]), free=\(f[3]), use%=\(f[4])")
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : raw
    }

    // ── du -sh (folder sizes, tab-separated) ──────────────────────────────────
    if cmd.hasPrefix("du ") {
        var rows: [String] = ["Folder sizes:"]
        for line in lines {
            let f = line.components(separatedBy: "\t")
            if f.count >= 2 { rows.append("  size=\(f[0].trimmed), folder=\(f[1].trimmed)") }
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : raw
    }

    // ── plain find (filename search — one path per line) ─────────────────────
    if cmd.hasPrefix("find ") && !cmd.contains(" -ls") {
        let folder = extractFindFolder(cmd)
        var rows: [String] = ["Files matching search in \(folder):"]
        for line in lines {
            let path = line.trimmed
            guard !path.isEmpty else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            rows.append("  \(name)")
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : raw
    }

    // ── grep -r (content search — one matching file path per line) ────────────
    if cmd.contains("grep ") && cmd.contains("-r") {
        let folder: String
        if      cmd.contains("~/Desktop")   { folder = "~/Desktop"   }
        else if cmd.contains("~/Downloads") { folder = "~/Downloads" }
        else if cmd.contains("~/Documents") { folder = "~/Documents" }
        else                                { folder = "~/"           }
        var rows: [String] = ["Files containing the search term in \(folder):"]
        for line in lines {
            let path = line.trimmed
            guard !path.isEmpty else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            rows.append("  \(name)")
        }
        return rows.count > 1 ? rows.joined(separator: "\n") : raw
    }

    return raw   // all other commands: pass through unchanged
}

// ── find command helpers — extract keyword + folder to rebuild safer fallback ──
/// Returns the raw keyword from a -name/-iname pattern, wildcards/dots stripped.
/// "find ~/Desktop -name \"*.office*\"" → "office"
func extractFindKeyword(_ cmd: String) -> String? {
    let pat = #"-i?name\s+"([^"]+)""#
    guard let re = try? NSRegularExpression(pattern: pat),
          let m  = re.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
          let r  = Range(m.range(at: 1), in: cmd) else { return nil }
    var kw = String(cmd[r])
    kw = kw.trimmingCharacters(in: CharacterSet(charactersIn: "*.? "))
    return kw.isEmpty ? nil : kw
}

/// Returns the folder path from a find command (the first argument after "find").
/// "find ~/Desktop -iname ..." → "~/Desktop"
func extractFindFolder(_ cmd: String) -> String {
    let parts = cmd.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return "~/" }
    let folder = String(parts[1])
    return (folder.hasPrefix("~") || folder.hasPrefix("/")) ? folder : "~/"
}

// ── Tool-use LLM — LLM may request one bash command, result fed back ──────────
func askLLMWithTools(query: String, format: PromptFormat = .chatML) -> String {
    let timeFmt = DateFormatter()
    timeFmt.dateFormat = "EEEE, MMM d yyyy, HH:mm"
    let now = timeFmt.string(from: Date())
    let stops = stopTokens(for: format)

    // Turn 1 — ask LLM to output a bash command or answer directly
    let sys1 = """
    You are Raju, a macOS voice assistant. Machine: \(staticContext). Time: \(now).
    Output a bash command: CMD: <bash command>
    For reminders: REMIND: <number> <seconds|minutes|hours> <message>
    For general knowledge: just answer directly in 1-2 sentences.

    File search rules:
      - File by NAME (called, named): find <folder> -iname "*keyword*" 2>/dev/null
      - File by CONTENT (contains word, has text inside): grep -ril "keyword" <folder> 2>/dev/null | head -20

    Examples:
      "battery left?" → CMD: pmset -g batt
      "disk space?" → CMD: df -h /
      "what's using CPU?" → CMD: ps -Axo pid,args,%cpu,%mem -r | head -8
      "RAM usage?" → CMD: ps -Axo pid,args,%cpu,%mem -m | head -8
      "is Safari running?" → CMD: ps -ax | grep -i Safari | grep -v grep | wc -l
      "biggest file on desktop?" → CMD: ls -lhS ~/Desktop | head -10
      "biggest file in downloads?" → CMD: ls -lhS ~/Downloads | head -10
      "newest file in downloads?" → CMD: ls -lt ~/Downloads | head -5
      "find file called office on desktop?" → CMD: find ~/Desktop -iname "*office*" 2>/dev/null
      "find notes.txt on desktop?" → CMD: find ~/Desktop -iname "*notes.txt*" 2>/dev/null
      "find files containing budget in documents?" → CMD: grep -ril "budget" ~/Documents 2>/dev/null | head -20
      "find file on desktop containing word language?" → CMD: grep -ril "language" ~/Desktop 2>/dev/null | head -20
      "find file in downloads containing word apple?" → CMD: grep -ril "apple" ~/Downloads 2>/dev/null | head -20
      "biggest video on my device?" → CMD: find ~/ -maxdepth 6 \\( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" \\) -ls 2>/dev/null | sort -k7 -rn | head -5
      "biggest image on my device?" → CMD: find ~/ -maxdepth 6 \\( -iname "*.jpg" -o -iname "*.png" -o -iname "*.heic" \\) -ls 2>/dev/null | sort -k7 -rn | head -5
      "remind me in 5 minutes" → REMIND: 5 minutes time to check
      "set a 30 second timer" → REMIND: 30 seconds done
      "capital of France?" → Paris is the capital of France.
    """
    let p1 = buildPrompt(system: sys1, user: query, format: format)
    var r1 = callLlama(prompt: p1, maxTokens: 80, temperature: 0.1, stop: stops).trimmed
    // If output was truncated mid-token, retry with double buffer
    if looksLikeTruncated(r1) {
        log("⚠️ Turn 1 looks truncated (\(r1.suffix(20))) — retrying with 120 tokens")
        r1 = callLlama(prompt: p1, maxTokens: 120, temperature: 0.1, stop: stops).trimmed
    }
    r1 = cleanLLMOutput(r1)

    // Check only the first line
    let firstLine = r1.components(separatedBy: "\n").first?.trimmed ?? ""
    log("📝 Turn 1 raw: \(firstLine)")

    // Pass reminders straight through
    if firstLine.hasPrefix("REMIND:") { return firstLine }

    // Parse CMD: <bash command>
    var cmd = ""
    if firstLine.hasPrefix("CMD:") {
        cmd = String(firstLine.dropFirst(4)).trimmed
        log("🔧 CMD: \(cmd)")
    }

    // Fallback: detect raw shell commands (no CMD: prefix)
    if cmd.isEmpty {
        let shellPrefixes = ["ps ", "df ", "vm_stat", "pmset ", "ifconfig", "uptime",
                             "ls ", "du ", "find ", "grep ", "pbpaste", "networksetup", "defaults "]
        if shellPrefixes.contains(where: { firstLine.hasPrefix($0) }) {
            cmd = firstLine
            log("⚠️ LLM skipped CMD: prefix — treating as command: \(cmd)")
        }
    }

    // If no tool detected, return the direct answer
    guard !cmd.isEmpty else { return r1 }

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
        } else if cmd.hasPrefix("find ") || cmd.contains(" find ") {
            // Rebuild with case-insensitive wildcard to fix "*.X*" style mistakes
            if let kw = extractFindKeyword(cmd) {
                let folder = extractFindFolder(cmd)
                fallback = "find \(folder) -iname \"*\(kw)*\" 2>/dev/null"
            } else {
                fallback = cmd  // keyword not parseable; nothing to improve
            }
        } else {
            fallback = cmd.components(separatedBy: "|").first?.trimmed ?? cmd
        }
        if fallback != cmd {
            log("⚠️ Sparse output (\(toolOut.count)c) — retrying: \(fallback)")
            toolOut = runTool(fallback)
            log("🔧 Retry output (\(toolOut.count)c): \(toolOut.prefix(200))")
        }
    }

    // Reformat raw columnar text into clearly labelled lines for the LLM.
    let formatted = reformatOutput(toolOut, cmd: cmd)
    log("📊 Formatted (\(formatted.count)c): \(formatted.prefix(300))")

    // Trim to 20 non-empty lines max to save context.
    let allLines = formatted.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }
    let topLines = allLines.prefix(20).joined(separator: "\n")
    let dataForLLM = topLines.isEmpty
        ? "The command ran but found no matching results. Tell the user nothing was found."
        : topLines

    // If the result is a list (>4 lines), copy the raw output to clipboard.
    var clipboardNote = ""
    if allLines.count > 4 {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(toolOut, forType: .string)
        }
        clipboardNote = "The full list (\(allLines.count) items) has been copied to the clipboard.\n"
        log("📋 Copied \(allLines.count)-line result to clipboard")
    }

    // Turn 2 — completely fresh prompt so small models don't get confused by conversation history
    let sys2 = """
    You are Raju, a macOS voice assistant. Answer in 1-3 short spoken sentences.
    The data below is the output of a command run to answer the question.
    Report what the data shows. Use ONLY the data — do not invent anything.
    If the data shows no results, say clearly that nothing was found.
    """
    let usr2 = "Command output (from `\(cmd)`):\n\(clipboardNote)\(dataForLLM)\n\nQuestion: \(query)"
    let p2 = buildPrompt(system: sys2, user: usr2, format: format)
    let r2 = cleanLLMOutput(callLlama(prompt: p2, maxTokens: 150, stop: stops))

    // Safety net: never speak a CMD: line or a raw shell command
    let shellPrefixes = ["ps ", "df ", "vm_stat", "pmset ", "ifconfig", "uptime",
                         "ls ", "du ", "find ", "grep ", "pbpaste", "networksetup", "defaults "]
    let r2LooksLikeShell = shellPrefixes.contains(where: { r2.hasPrefix($0) })
                        || (r2.contains(" | ") && r2.count < 200 && !r2.contains("?"))
    if r2.hasPrefix("CMD:") || r2LooksLikeShell {
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
            if !model.isDownloaded && model.url != nil { item.title = model.name + "  ↓" }
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
        let model = MODELS[idx]

        if model.isDownloaded {
            doSelectModel(idx)
        } else if let urlStr = model.url {
            log("⬇️ Downloading model: \(model.name)…")
            DispatchQueue.main.async {
                self.modelMenuItems[idx].title = "\(model.name)  ⏳"
                self.itemModel.title = "  🧠 Downloading \(model.name)…"
            }
            DispatchQueue.global(qos: .background).async {
                let modelsDir = "\(HOME)/local_llms/llama.cpp/models"
                try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
                let ok = self.downloadFile(from: urlStr, to: model.path)
                DispatchQueue.main.async {
                    if ok {
                        self.modelMenuItems[idx].title = model.name
                        log("✅ Model downloaded: \(model.name)")
                        self.doSelectModel(idx)
                    } else {
                        self.modelMenuItems[idx].title = "\(model.name)  ↓"
                        self.itemModel.title = "  🧠 \(MODELS[self.currentModelIndex].name)"
                        log("❌ Failed to download model: \(model.name)")
                    }
                }
            }
        } else {
            log("⚠️ \(model.name) is not downloaded and has no download URL")
        }
    }

    func doSelectModel(_ idx: Int) {
        currentModelIndex = idx
        let model = MODELS[idx]
        modelMenuItems.forEach { $0.state = .off }
        modelMenuItems[idx].state = .on
        itemModel.title = "  🧠 \(model.name)"
        log("🔄 Switching to \(model.name) — stopping old server…")
        DispatchQueue.main.async { self.itemLlama.title = "  ⏳ Loading \(model.name)…" }
        llamaProcess?.terminate()
        llamaProcess = nil
        pkillByName("llama-server")
        DispatchQueue.global(qos: .background).async {
            var waited = 0
            while isLlamaReady() && waited < 15 { Thread.sleep(forTimeInterval: 1); waited += 1 }
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
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "GET"
        var success = false
        let sem = DispatchSemaphore(value: 0)
        // Use downloadTask to stream to disk (not RAM) — models can be 1GB+
        URLSession.shared.downloadTask(with: req) { tempURL, resp, _ in
            if let tempURL = tempURL, (resp as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.removeItem(atPath: dest)
                success = ((try? FileManager.default.moveItem(at: tempURL,
                    to: URL(fileURLWithPath: dest))) != nil)
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

            // Handle reminder requests — LLM returns "REMIND: <number> <unit> <message>"
            // Unit may be seconds/minutes/hours (or absent, meaning seconds).
            if self.lastReply.hasPrefix("REMIND:") {
                let raw    = String(self.lastReply.dropFirst("REMIND:".count)).trimmed
                let tokens = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                var secs   = 60.0
                var msgIdx = 0
                if let num = tokens.first.flatMap({ Double($0) }) {
                    secs   = num
                    msgIdx = 1
                    if tokens.count > 1 {
                        switch tokens[1].lowercased() {
                        case let u where u.hasPrefix("min"):  secs = num * 60;   msgIdx = 2
                        case let u where u.hasPrefix("hour"): secs = num * 3600; msgIdx = 2
                        case let u where u.hasPrefix("sec"):  secs = num;        msgIdx = 2
                        default: break
                        }
                    }
                }
                secs = max(5.0, secs)
                let msgText = tokens.dropFirst(msgIdx).joined(separator: " ").trimmed
                let message = msgText.isEmpty ? "Time's up!" : msgText
                let secsInt = Int(secs)
                let timeDesc: String
                if secsInt >= 3600 {
                    let h = secsInt / 3600; timeDesc = "\(h) hour\(h == 1 ? "" : "s")"
                } else if secsInt >= 60 {
                    let m = secsInt / 60;   timeDesc = "\(m) minute\(m == 1 ? "" : "s")"
                } else {
                    timeDesc = "\(secsInt) second\(secsInt == 1 ? "" : "s")"
                }
                log("⏰ Reminder set: \(secsInt)s — \(message)")
                DispatchQueue.global().asyncAfter(deadline: .now() + secs) {
                    log("⏰ Firing reminder: \(message)")
                    speak(message, modelPath: voicePath)
                }
                self.lastReply = "Okay, I'll remind you in \(timeDesc)."
            }
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
