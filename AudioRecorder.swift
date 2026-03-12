import Foundation

class AudioRecorder {
    static let shared = AudioRecorder()
    private var recProcess: Process?

    func startRecording() -> Bool {
        log("🔴 Recording started (rec: \(REC_BIN))")
        try? FileManager.default.removeItem(atPath: AUDIO_FILE)

        recProcess = Process()
        recProcess!.executableURL = URL(fileURLWithPath: REC_BIN)
        recProcess!.arguments = ["-b", "16", AUDIO_FILE, "rate", "16000", "channels", "1", "trim", "0", "60"]
        recProcess!.standardOutput = Pipe()
        let recErrPipe = Pipe()
        recProcess!.standardError  = recErrPipe
        
        do {
            try recProcess!.run()
            log("🎤 rec PID \(recProcess!.processIdentifier)")
        } catch {
            log("❌ rec failed to start: \(error)")
            return false
        }

        let pid = recProcess!.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let size = (try? FileManager.default.attributesOfItem(atPath: AUDIO_FILE)[.size] as? Int) ?? 0
            if size == 0 {
                let errData = recErrPipe.fileHandleForReading.availableData
                let errMsg  = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                log("⚠️ rec (PID \(pid)) wrote 0 bytes after 0.5s — mic may be blocked. rec stderr: \(errMsg.isEmpty ? "(none)" : errMsg)")
            }
        }
        return true
    }

    func stopRecording() {
        recProcess?.terminate()
        recProcess = nil
        Thread.sleep(forTimeInterval: 0.2) // Give rec ~200ms to flush header
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: AUDIO_FILE)[.size] as? Int) ?? 0
        log("⏹️  Recording stopped — \(fileSize) bytes — sending to whisper-server")
    }
}
