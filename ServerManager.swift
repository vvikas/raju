import Foundation

class ServerManager {
    static let shared = ServerManager()

    var llamaProcess: Process?
    var whisperProcess: Process?

    // ── pkill helper ───────────────────────────────────────────────────────────
    func pkillByName(_ pattern: String) {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", pattern]
        k.standardOutput = Pipe()
        k.standardError = Pipe()
        try? k.run()
        k.waitUntilExit()
    }

    func startLlamaServer(modelIndex: Int, completion: @escaping (Bool, String) -> Void) {
        if isLlamaReady() {
            let name = MODELS[modelIndex].name
            log("⚡ llama-server already running on :\(LLAMA_PORT) — \(name)")
            completion(true, name)
            return
        }
        let model = MODELS[modelIndex]
        log("🚀 Starting llama-server (\(model.name)) on :\(LLAMA_PORT)…")
        llamaProcess = Process()
        llamaProcess!.executableURL = URL(fileURLWithPath: LLAMA_SERVER)
        llamaProcess!.arguments = ["-m", model.path, "-ngl", useGPU ? "999" : "0",
                                   "--port", "\(LLAMA_PORT)", "--host", "127.0.0.1",
                                   "-c", "4096", "-n", "400", "--log-disable"]
        llamaProcess!.standardOutput = Pipe()
        llamaProcess!.standardError  = Pipe()
        try? llamaProcess!.run()

        var secs = 0
        while secs < 180 {
            Thread.sleep(forTimeInterval: 2); secs += 2
            if isLlamaReady() {
                log("⚡ llama-server ready after \(secs)s — \(model.name)")
                completion(true, model.name)
                return
            }
            if secs % 20 == 0 { log("⏳ \(model.name) still loading… (\(secs)s)") }
        }
        log("⚠️ llama-server failed to start within 3 min")
        completion(false, model.name)
    }

    func startWhisperServer(completion: @escaping (Bool) -> Void) {
        if isWhisperReady() {
            log("⚡ whisper-server already running on :\(WHISPER_PORT)")
            completion(true)
            return
        }
        log("🚀 Starting whisper-server (small) on :\(WHISPER_PORT)…")
        whisperProcess = Process()
        whisperProcess!.executableURL = URL(fileURLWithPath: WHISPER_SERVER)
        var whisperArgs = ["-m", WHISPER_MODEL, "--port", "\(WHISPER_PORT)", "--host", "127.0.0.1"]
        if !useGPU { whisperArgs.append("--no-gpu") }
        whisperProcess!.arguments = whisperArgs
        whisperProcess!.standardOutput = Pipe()
        whisperProcess!.standardError  = Pipe()
        try? whisperProcess!.run()

        var secs = 0
        while secs < 120 {
            Thread.sleep(forTimeInterval: 2); secs += 2
            if isWhisperReady() {
                log("⚡ whisper-server ready after \(secs)s")
                completion(true)
                return
            }
            if secs % 10 == 0 { log("⏳ Whisper still loading… (\(secs)s)") }
        }
        log("⚠️ whisper-server failed to start")
        completion(false)
    }

    func stopLlamaServer() {
        log("⏹ Stopping llama-server…")
        llamaProcess?.terminate()
        llamaProcess = nil
        pkillByName("llama-server")
    }

    func stopWhisperServer() {
        log("⏹ Stopping whisper-server…")
        whisperProcess?.terminate()
        whisperProcess = nil
        pkillByName("whisper-server")
    }

    func bothReady() -> Bool {
        return isLlamaReady() && isWhisperReady()
    }
}
