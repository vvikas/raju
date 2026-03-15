import Cocoa
import Foundation

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

// ── Chat API call via llama-server /v1/chat/completions ───────────────────────
func callLlamaChat(messages: [[String: String]], maxTokens: Int = 200, temperature: Double = 0.7) -> String {
    guard let url = URL(string: "\(LLAMA_URL)/v1/chat/completions") else { return "" }
    let body: [String: Any] = [
        "messages": messages,
        "max_tokens": maxTokens,
        "temperature": temperature,
        "frequency_penalty": 0.0,
        "presence_penalty": 0.0
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
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String {
            result = content.trimmed
        }
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

// ── Truncation detection ──────────────────────────────────────────────────────
func looksLikeTruncated(_ s: String) -> Bool {
    let t = s.trimmed
    if t.isEmpty { return false }
    let lastChar = t.last!
    if "'\"\\|({".contains(lastChar) { return true }
    if t.hasSuffix("| ") { return true }
    if t.hasSuffix("awk") || t.hasSuffix("grep") || t.hasSuffix("sed") { return true }
    return false
}

// ── Strip model-specific prefixes ─────────────────────────────────────────────
func cleanLLMOutput(_ text: String) -> String {
    var t = text.trimmed
    let prefixes = ["A:", "Answer:", "Response:", "Assistant:", "### Response:", "###"]
    for p in prefixes {
        if t.hasPrefix(p) { t = String(t.dropFirst(p.count)).trimmed }
    }
    return t
}

// ── Tool-use LLM (ReAct Loop) ─────────────────────────────────────────────────
func askLLMWithTools(query: String) -> String {
    let timeFmt = DateFormatter()
    timeFmt.dateFormat = "EEEE, MMM d yyyy, HH:mm"
    let now = timeFmt.string(from: Date())

    // Turn 1
    let sys1 = """
    You are Raju, a macOS voice assistant. Machine: \(staticContext). Time: \(now).
    The user's home directory is \(HOME). Always use standard macOS paths (e.g. ~/Downloads, ~/Desktop, ~/Documents). Do NOT invent or hallucinate volumes like /Volumes/downloads/.
    You can run macOS terminal commands to answer technical questions.

    IF YOU NEED TO RUN A COMMAND, output exactly like this and nothing else:
    <bash>
    the command here
    </bash>

    To open a website or video, output ONLY: OPEN: <key>
    Valid keys are ONLY: headspace, lofi
    Do NOT use OPEN: for anything else — all system/terminal tasks must use <bash>.

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
      "remind me in 5 minutes"          -> REMIND: 5 minutes reminder
      "let's meditate"                  -> OPEN: headspace
      "I want to meditate"              -> OPEN: headspace
      "play lofi"                       -> OPEN: lofi
      "capital of France?"              -> Paris is the capital.
    """
    
    let msgs1: [[String: String]] = [
        ["role": "system", "content": sys1],
        ["role": "user", "content": query]
    ]

    var r1 = callLlamaChat(messages: msgs1, maxTokens: 80, temperature: 0.1).trimmed
    if looksLikeTruncated(r1) {
        log("⚠️ Turn 1 looks truncated — retrying with 150 tokens")
        r1 = callLlamaChat(messages: msgs1, maxTokens: 150, temperature: 0.1).trimmed
    }
    r1 = cleanLLMOutput(r1)

    if r1.hasPrefix("REMIND:") { return r1 }

    var cmd = ""
    let bashRegex = #"(?s)<bash>\s*(.*?)\s*</bash>"#
    if let re = try? NSRegularExpression(pattern: bashRegex, options: []),
       let match = re.firstMatch(in: r1, range: NSRange(r1.startIndex..., in: r1)),
       let range = Range(match.range(at: 1), in: r1) {
        cmd = String(r1[range]).trimmed
        log("🔧 <bash> tag detected: \(cmd)")
    } else {
        let firstLine = r1.components(separatedBy: "\n").first?.trimmed ?? ""
        let shellPrefixes = ["ps ", "df ", "vm_stat", "pmset ", "ifconfig", "uptime",
                             "ls ", "du ", "find ", "grep ", "pbpaste", "networksetup", "defaults "]
        if shellPrefixes.contains(where: { firstLine.hasPrefix($0) }) {
            cmd = firstLine
            log("⚠️ LLM skipped <bash> tags — treating as command: \(cmd)")
        }
    }

    guard !cmd.isEmpty else { return r1 }

    log("🔧 Tool call: \(cmd)")
    var toolOut = runTool(cmd)
    log("🔧 Tool output (\(toolOut.count)c): \(toolOut.prefix(200))")

    let usefulLines = toolOut.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }
    if usefulLines.count < 2 || toolOut.trimmed.count < 20 {
        let fallback: String
        if cmd.lowercased().contains("top ") || cmd.lowercased().hasPrefix("top") {
            let sortFlag = cmd.contains("cpu") ? "cpu" : "mem"
            fallback = "top -l 1 -o \(sortFlag) -n 15 -stats pid,command,cpu,mem | tail -n +13"
        } else if cmd.lowercased().contains("ps ") {
            let sortPipe = cmd.contains("nrk4") || cmd.contains("-m") ? "| sort -nrk4" : "| sort -nrk3"
            fallback = "ps -cAxo pid,comm,%cpu,rss \(sortPipe) | head -15"
        } else if cmd.hasPrefix("find ") || cmd.contains(" find ") {
            if let kw = extractFindKeyword(cmd) {
                let folder = extractFindFolder(cmd)
                fallback = "find \(folder) -iname \"*\(kw)*\" 2>/dev/null"
            } else {
                fallback = cmd
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

    let formatted = reformatOutput(toolOut, cmd: cmd)
    if formatted != toolOut {
        log("📊 Formatted (\(formatted.count)c): \(formatted.prefix(300))")
    }

    let allLines = formatted.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }
    let topLines = allLines.prefix(50).enumerated().map { i, line in
        return line.count > 200 ? String(line.prefix(200)) + "..." : line
    }.joined(separator: "\n")
    
    let dataForLLM = topLines.isEmpty
        ? "The command ran but found no matching results / empty output."
        : topLines

    var clipboardNote = ""
    if allLines.count > 4 {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(toolOut, forType: .string)
        }
        clipboardNote = "[The full list (\(allLines.count) items) has been automatically copied to the user's clipboard]\n"
        log("📋 Copied \(allLines.count)-line result to clipboard")
    }

    // Turn 2
    let sys2 = """
    You are Raju, a macOS voice assistant. 
    You executed a bash command to answer the user's question, and the results are provided below.
    Answer in 1-3 short spoken sentences summarizing what the data shows.
    Use ONLY the data — do not invent anything.
    If the data is empty or indicates an error, say clearly what went wrong or that nothing was found.
    """
    
    let usr2 = """
    Question: \(query)
    
    Command executed: `\(cmd)`
    
    Output:
    \(clipboardNote)\(dataForLLM)
    """
    
    let msgs2: [[String: String]] = [
        ["role": "system", "content": sys2],
        ["role": "user", "content": usr2]
    ]
    
    let r2 = cleanLLMOutput(callLlamaChat(messages: msgs2, maxTokens: 150))

    let shellPrefixes = ["ps ", "df ", "vm_stat", "pmset ", "ifconfig", "uptime",
                         "ls ", "du ", "find ", "grep ", "pbpaste", "networksetup", "defaults "]
    let r2LooksLikeShell = shellPrefixes.contains(where: { r2.hasPrefix($0) })
                        || (r2.contains(" | ") && r2.count < 200 && !r2.contains("?"))
                        || r2.hasPrefix("<bash>") || r2.hasSuffix("</bash>")
    if r2LooksLikeShell {
        let rest = r2.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmed
        return rest.isEmpty ? "I ran the command but couldn't summarise the results." : rest
    }

    let refusalPhrases = ["can't assist", "cannot assist", "i'm not able", "i am not able",
                          "i'm unable", "i cannot help", "not able to help", "sorry, but i"]
    let r2Low = r2.lowercased()
    if refusalPhrases.contains(where: { r2Low.contains($0) }) {
        log("⚠️ LLM refused in Turn 2 — returning fallback")
        return "I don't have that data right now."
    }
    return r2
}
