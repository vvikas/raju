import Cocoa
import Foundation

// ── Paths & ports ─────────────────────────────────────────────────────────────
let HOME           = FileManager.default.homeDirectoryForCurrentUser.path
let WHISPER_SERVER = "\(HOME)/local_llms/whisper.cpp/build/bin/whisper-server"
let WHISPER_MODEL  = "\(HOME)/local_llms/whisper.cpp/models/ggml-small.bin"
let LLAMA_SERVER   = "\(HOME)/local_llms/llama.cpp/build/bin/llama-server"
let LLAMA_MODEL    = "\(HOME)/local_llms/llama.cpp/models/qwen2-1.5b.gguf"
let REC_BIN        = "/usr/local/bin/rec"
let PYTHON3_BIN    = "/usr/bin/python3"
let PIPER_MODEL    = "\(HOME)/.raju/voices/en_US-lessac-medium.onnx"
let PIPER_OUT      = "/tmp/raju_tts.wav"
let SAY_BIN        = "/usr/bin/say"
let AUDIO_FILE     = "/tmp/raju_input.wav"
let LOG_FILE       = "\(HOME)/Raju/raju.log"
// ── Available LLM models ──────────────────────────────────────────────────────
struct LLMModel {
    let name: String
    let file: String
    var path: String { "\(HOME)/local_llms/llama.cpp/models/\(file)" }
}

let MODELS: [LLMModel] = [
    LLMModel(name: "Qwen2 1.5B",          file: "qwen2-1.5b.gguf"),
    LLMModel(name: "DeepSeek-Coder 1.3B", file: "deepseek-coder-1.3b.gguf"),
    LLMModel(name: "TinyLlama 1.1B",      file: "tinyllama.gguf"),
]

let LLAMA_PORT     = 8080
let WHISPER_PORT   = 8081
let LLAMA_URL      = "http://127.0.0.1:\(LLAMA_PORT)"
let WHISPER_URL    = "http://127.0.0.1:\(WHISPER_PORT)"

// ── Logger ────────────────────────────────────────────────────────────────────
func log(_ msg: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss"
    let line = "[\(fmt.string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: LOG_FILE) {
            if let fh = FileHandle(forWritingAtPath: LOG_FILE) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: LOG_FILE))
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
func speak(_ text: String) {
    let fm = FileManager.default
    if fm.fileExists(atPath: PIPER_MODEL) {
        let piper = Process()
        piper.executableURL = URL(fileURLWithPath: PYTHON3_BIN)
        piper.arguments = ["-m", "piper", "--model", PIPER_MODEL, "--output_file", PIPER_OUT]
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

// ── Static context (gathered once at launch, slow commands ok here) ───────────
var staticContext = ""

func buildStaticContext() {
    var ctx = "=== Machine Info ===\n"

    // macOS + hostname
    let os       = shell("/usr/bin/sw_vers", ["-productVersion"]).trimmed
    let hostname = shell("/bin/hostname", []).trimmed
    ctx += "macOS \(os) — \(hostname)\n"

    // Mac model
    let model    = shell("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmed
    ctx += "Model: \(model)\n"

    // CPU
    let cpuName  = shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmed
    let pCores   = shell("/usr/sbin/sysctl", ["-n", "hw.physicalcpu"]).trimmed
    let lCores   = shell("/usr/sbin/sysctl", ["-n", "hw.logicalcpu"]).trimmed
    ctx += "CPU: \(cpuName) (\(pCores) physical / \(lCores) logical cores)\n"

    // Total RAM
    let ramBytes = Int(shell("/usr/sbin/sysctl", ["-n", "hw.memsize"]).trimmed) ?? 0
    ctx += "Total RAM: \(ramBytes / 1_073_741_824) GB\n"

    // GPU (system_profiler — slow but only runs once)
    let gpuOut = shell("/usr/sbin/system_profiler", ["SPDisplaysDataType"])
    for line in gpuOut.components(separatedBy: "\n") {
        if line.contains("Chipset Model:") {
            ctx += "GPU: \(line.components(separatedBy: ":").last?.trimmed ?? "")\n"
        }
        if line.contains("VRAM") {
            ctx += "VRAM: \(line.trimmed)\n"
        }
    }

    // Disk model
    let diskInfo = shell("/usr/sbin/diskutil", ["info", "/"])
    for line in diskInfo.components(separatedBy: "\n") {
        if line.contains("Device / Media Name:") || line.contains("Media Name:") {
            if let val = line.components(separatedBy: ":").last?.trimmed, !val.isEmpty {
                ctx += "SSD: \(val)\n"; break
            }
        }
    }

    staticContext = ctx
    log("📋 Static context built:\n\(ctx)")
}

// ── Dynamic context (gathered every query, fast commands only) ────────────────
func gatherDynamicContext(query: String) -> String {
    var ctx = staticContext + "\n=== Live Stats ===\n"

    // CPU thermal + load
    let thermal = shell("/usr/sbin/sysctl", ["-n", "machdep.xcpm.cpu_thermal_level"]).trimmed
    ctx += "CPU thermal throttle: \(thermal)/100\n"
    let uptime = shell("/usr/bin/uptime", []).trimmed
    ctx += "Load: \(uptime)\n"

    // RAM — active + wired + compressed = used
    let vmstat = shell("/usr/bin/vm_stat", [])
    var pages: [String: Int] = [:]
    for line in vmstat.components(separatedBy: "\n") {
        for key in ["Pages active", "Pages wired down", "Pages occupied by compressor",
                    "Pages free", "Pages inactive"] {
            if line.contains(key) {
                let num = line.components(separatedBy: ":").last?
                    .trimmed.replacingOccurrences(of: ".", with: "") ?? "0"
                pages[key] = Int(num) ?? 0
            }
        }
    }
    let pg = 4096
    let usedMB  = ((pages["Pages active"] ?? 0) + (pages["Pages wired down"] ?? 0)
                  + (pages["Pages occupied by compressor"] ?? 0)) * pg / 1_048_576
    let freeMB  = ((pages["Pages free"] ?? 0) + (pages["Pages inactive"] ?? 0)) * pg / 1_048_576
    let compMB  = (pages["Pages occupied by compressor"] ?? 0) * pg / 1_048_576
    ctx += "RAM: ~\(usedMB) MB used, ~\(freeMB) MB free, \(compMB) MB compressed\n"

    // Swap
    let swap = shell("/usr/sbin/sysctl", ["-n", "vm.swapusage"]).trimmed
    ctx += "Swap: \(swap)\n"

    // Disk free
    let disk = shell("/bin/df", ["-h", "/"])
    if let diskLine = disk.components(separatedBy: "\n").dropFirst().first {
        let p = diskLine.split(separator: " ", omittingEmptySubsequences: true)
        if p.count >= 4 { ctx += "Disk /: \(p[1]) total, \(p[2]) used, \(p[3]) free\n" }
    }

    // Battery
    let batt = shell("/usr/bin/pmset", ["-g", "batt"])
    for line in batt.components(separatedBy: "\n") {
        if line.contains("%") { ctx += "Battery: \(line.trimmed)\n" }
    }

    // Network — active interface + IP
    let routeOut = shell("/sbin/route", ["get", "default"])
    var iface = "en0"
    for line in routeOut.components(separatedBy: "\n") {
        if line.contains("interface:") {
            iface = line.components(separatedBy: ":").last?.trimmed ?? "en0"
        }
    }
    let ifOut = shell("/sbin/ifconfig", [iface])
    for line in ifOut.components(separatedBy: "\n") {
        if line.contains("inet ") && !line.contains("inet6") {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 2 { ctx += "Network (\(iface)): IP \(p[1])\n" }
        }
    }
    // WiFi SSID
    let wifi = shell("/usr/sbin/networksetup", ["-getairportnetwork", "en0"]).trimmed
    if !wifi.isEmpty { ctx += "\(wifi)\n" }

    // Top 5 processes by CPU
    let topOut = shell("/usr/bin/top", ["-l", "1", "-n", "5", "-o", "cpu",
                                        "-stats", "pid,command,cpu,mem"])
    var topLines: [String] = []
    var pastHeader = false
    for line in topOut.components(separatedBy: "\n") {
        if line.hasPrefix("PID") { pastHeader = true; continue }
        if pastHeader && !line.trimmed.isEmpty { topLines.append(line.trimmed) }
        if topLines.count >= 5 { break }
    }
    if !topLines.isEmpty {
        ctx += "Top processes (CPU): " + topLines.joined(separator: " | ") + "\n"
    }

    // Current time & date (useful for time-aware questions)
    let now = DateFormatter()
    now.dateFormat = "EEEE, MMM d yyyy, HH:mm:ss"
    ctx += "Current time: \(now.string(from: Date()))\n"

    // ── File / text search (Spotlight mdfind — instant) ──────────────────────
    let q = query.lowercased()
    let isFileSearch  = q.contains("find") || q.contains("where is") || q.contains("locate")
    let isTextSearch  = q.contains("search") || q.contains("contains") || q.contains("look for")
                     || q.contains("inside") || q.contains("in files")

    if isFileSearch || isTextSearch {
        // Extract search term: words after the trigger keyword
        let triggers = ["find file", "find", "where is", "locate", "search for",
                        "look for", "containing", "contains", "files with", "in files"]
        var term = ""
        for t in triggers {
            if let r = q.range(of: t) {
                term = String(q[r.upperBound...]).trimmed
                    .components(separatedBy: " ").prefix(4).joined(separator: " ")
                if !term.isEmpty { break }
            }
        }

        if !term.isEmpty {
            var results: [String] = []

            if isFileSearch {
                // Spotlight filename search — instant
                let found = shell("/usr/bin/mdfind", ["-name", term, "-onlyin", HOME])
                results = found.components(separatedBy: "\n")
                    .filter { !$0.isEmpty && !$0.contains("/.") }
                    .prefix(8).map { $0 }
                ctx += results.isEmpty
                    ? "No files named '\(term)' found.\n"
                    : "Files named '\(term)':\n" + results.joined(separator: "\n") + "\n"
            }

            if isTextSearch {
                // Spotlight full-text search — also instant
                let found = shell("/usr/bin/mdfind", [term, "-onlyin", HOME])
                let textResults = found.components(separatedBy: "\n")
                    .filter { !$0.isEmpty && !$0.contains("/.") }
                    .prefix(5).map { $0 }
                ctx += textResults.isEmpty
                    ? "No files containing '\(term)' found.\n"
                    : "Files containing '\(term)':\n" + textResults.joined(separator: "\n") + "\n"
            }
        }
    }

    return ctx
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

// ── LLM via llama-server ──────────────────────────────────────────────────────
func askLLM(query: String, context: String) -> String {
    guard let url = URL(string: "\(LLAMA_URL)/completion") else { return "" }

    let prompt = """
    <|im_start|>system
    You are Raju, a concise macOS system assistant. Answer in 2-3 short sentences. Be direct and factual. Use the system state below to answer accurately. Never make up information.

    \(context)
    <|im_end|>
    <|im_start|>user
    \(query)
    <|im_end|>
    <|im_start|>assistant

    """

    let body: [String: Any] = [
        "prompt": prompt,
        "n_predict": 200,
        "temperature": 0.7,
        "repeat_penalty": 1.1,
        "stop": ["<|im_end|>", "<|endoftext|>", "<|im_start|>"]
    ]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return "" }

    var req = URLRequest(url: url, timeoutInterval: 120)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = jsonData

    var result = ""
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, error in
        if let error = error { log("⚠️ LLM HTTP error: \(error.localizedDescription)") }
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

    let itemLlama   = NSMenuItem(title: "  ⏳ LLM loading…",    action: nil, keyEquivalent: "")
    let itemWhisper = NSMenuItem(title: "  ⏳ Whisper loading…", action: nil, keyEquivalent: "")
    let itemModel   = NSMenuItem(title: "  🧠 Model",            action: nil, keyEquivalent: "")
    let itemHint    = NSMenuItem(title: "  Hold to speak",       action: nil, keyEquivalent: "")
    let itemStatus  = NSMenuItem(title: "",                      action: nil, keyEquivalent: "")
    let itemQuery   = NSMenuItem(title: "",                      action: nil, keyEquivalent: "")
    let itemReply   = NSMenuItem(title: "",                      action: nil, keyEquivalent: "")

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

        menu = NSMenu()
        menu.addItem(NSMenuItem(title: "── Raju ─────────────────", action: nil, keyEquivalent: ""))
        menu.addItem(itemLlama)
        menu.addItem(itemWhisper)
        menu.addItem(itemModel)
        menu.addItem(itemHint)
        menu.addItem(itemStatus)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(itemQuery)
        menu.addItem(itemReply)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "  📄 Show Log", action: #selector(showLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = nil
        refreshUI()

        log("── Raju started ──────────────────────────────")

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
            DispatchQueue.main.async { self.itemLlama.title = "  ⚡ LLM ready (\(name))" }
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
                DispatchQueue.main.async { self.itemLlama.title = "  ⚡ LLM ready (\(model.name))" }
                return
            }
            if secs % 20 == 0 { log("⏳ \(model.name) still loading… (\(secs)s)") }
        }
        log("⚠️ llama-server failed to start within 3 min")
        DispatchQueue.main.async { self.itemLlama.title = "  ❌ \(model.name) failed to load" }
    }

    func startWhisperServer() {
        if isWhisperReady() {
            log("⚡ whisper-server already running on :\(WHISPER_PORT)")
            DispatchQueue.main.async { self.itemWhisper.title = "  ⚡ Whisper ready (small)" }
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
                DispatchQueue.main.async { self.itemWhisper.title = "  ⚡ Whisper ready (small)" }
                return
            }
            if secs % 10 == 0 { log("⏳ Whisper still loading… (\(secs)s)") }
        }
        log("⚠️ whisper-server failed to start")
        DispatchQueue.main.async { self.itemWhisper.title = "  ❌ Whisper failed to load" }
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

    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: LOG_FILE)) }

    @objc func selectModel(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx != currentModelIndex else { return }
        currentModelIndex = idx
        let model = MODELS[idx]

        // Update checkmarks
        modelMenuItems.forEach { $0.state = .off }
        modelMenuItems[idx].state = .on
        itemModel.title = "  🧠 \(model.name)"

        log("🔄 Switching to \(model.name) — restarting llama-server…")
        DispatchQueue.main.async { self.itemLlama.title = "  ⏳ Loading \(model.name)…" }

        llamaProcess?.terminate()
        llamaProcess = nil
        DispatchQueue.global(qos: .background).async { self.startLlamaServer() }
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

            guard !query.isEmpty else {
                log("⚠️ Whisper returned empty — nothing heard (took \(wt)s)")
                self.state = .idle; return
            }
            log("⏳ Whisper done in \(wt)s → \"\(query)\"")
            self.lastQuery = query
            self.setStatus("Heard: \"\(query.prefix(50))\"")

            // Step 2: Dynamic context (fast)
            self.state = .thinking
            log("🔍 Gathering live system context…")
            let ctx = gatherDynamicContext(query: query)
            log("📋 Context ready (\(ctx.count) chars)")

            // Step 3: LLM
            log("🤔 Sending to llama-server…")
            let t1    = Date()
            let reply = askLLM(query: query, context: ctx)
            let lt    = String(format: "%.1f", Date().timeIntervalSince(t1))
            self.lastReply = reply.isEmpty ? "Sorry, I didn't get that." : reply
            log("💬 LLM reply in \(lt)s → \"\(self.lastReply)\"")
            self.setStatus("")

            // Step 4: TTS
            self.state = .speaking
            let ttsEngine = FileManager.default.fileExists(atPath: PIPER_MODEL) ? "Piper" : "say"
            log("🔊 Speaking via \(ttsEngine)…")
            speak(self.lastReply)

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
