import Foundation

// ── Paths & ports ─────────────────────────────────────────────────────────────
let HOME           = FileManager.default.homeDirectoryForCurrentUser.path
let WHISPER_SERVER = "\(HOME)/local_llms/whisper.cpp/build/bin/whisper-server"
let WHISPER_MODEL  = "\(HOME)/local_llms/whisper.cpp/models/ggml-small.bin"
let LLAMA_SERVER   = "\(HOME)/local_llms/llama.cpp/build/bin/llama-server"
let REC_BIN: String = {
    for p in ["/opt/homebrew/bin/rec", "/usr/local/bin/rec"] {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return "/usr/local/bin/rec"
}()
let PYTHON3_BIN: String = {
    let configPath = "\(HOME)/.raju/python3_bin"
    if let path = try? String(contentsOfFile: configPath, encoding: .utf8)
                            .trimmingCharacters(in: .whitespacesAndNewlines),
       !path.isEmpty, FileManager.default.fileExists(atPath: path) { return path }
    for p in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return "/usr/local/bin/python3"
}()
let PIPER_OUT      = "/tmp/raju_tts.wav"
let SAY_BIN        = "/usr/bin/say"
let AUDIO_FILE     = "/tmp/raju_input.wav"
let LOG_FILE       = "\(HOME)/.raju/raju.log"
let VOICES_DIR     = "\(HOME)/.raju/voices"

let LLAMA_PORT     = 8080
let WHISPER_PORT   = 8081
let LLAMA_URL      = "http://127.0.0.1:\(LLAMA_PORT)"
let WHISPER_URL    = "http://127.0.0.1:\(WHISPER_PORT)"

// ── GPU preference ────────────────────────────────────────────────────────────
var useGPU: Bool {
    get {
        if let pref = UserDefaults.standard.object(forKey: "useGPU") as? Bool { return pref }
        if let val = try? String(contentsOfFile: "\(HOME)/.raju/use_gpu", encoding: .utf8)
                             .trimmingCharacters(in: .whitespacesAndNewlines) { return val == "true" }
        return shell("/usr/bin/uname", ["-m"]).trimmed == "arm64"
    }
    set { UserDefaults.standard.set(newValue, forKey: "useGPU") }
}

// ── Logger ────────────────────────────────────────────────────────────────────
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
            let bom = Data([0xEF, 0xBB, 0xBF])
            try? (bom + data).write(to: URL(fileURLWithPath: LOG_FILE))
        }
    }
}

// ── Static context ───────────────────────────────────────────────────────────
var staticContext = ""

func buildStaticContext() {
    let os    = shell("/usr/bin/sw_vers", ["-productVersion"]).trimmed
    let model = shell("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmed
    let cpu   = shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmed
    let ramGB = (Int(shell("/usr/sbin/sysctl", ["-n", "hw.memsize"]).trimmed) ?? 0) / 1_073_741_824
    staticContext = "macOS \(os) on \(model) — \(cpu), \(ramGB)GB RAM"
    log("📋 Machine: \(staticContext)")
}
