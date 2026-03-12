import Cocoa
import Foundation

// ── TTS — piper (python3 -m piper) if model exists, fallback to say ──────────
func speak(_ text: String, modelPath: String) {
    let fm = FileManager.default
    if fm.fileExists(atPath: modelPath) && fm.fileExists(atPath: PYTHON3_BIN) {
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
