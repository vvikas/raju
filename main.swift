import Cocoa
import Foundation
import AVFoundation

// ── App ───────────────────────────────────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem:     NSStatusItem!
    var menu:           NSMenu!
    var state: RajuState = .idle { didSet { DispatchQueue.main.async { self.refreshUI() } } }

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
    let itemGPUToggle    = NSMenuItem(title: "  ⚡ GPU: On",           action: #selector(toggleGPU),                   keyEquivalent: "")
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
        itemGPUToggle.target     = self
        itemGPUToggle.title      = useGPU ? "  ⚡ GPU: On" : "  ⚪ GPU: Off"
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
        menu.addItem(itemGPUToggle)
        menu.addItem(itemHint)
        menu.addItem(itemStatus)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(itemQuery)
        menu.addItem(itemReply)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "  📄 Show Log", action: #selector(showLog), keyEquivalent: "l"))
        let customURLsItem = NSMenuItem(title: "  🔗 Custom URLs…", action: #selector(showCustomURLs), keyEquivalent: "")
        customURLsItem.target = self
        menu.addItem(customURLsItem)
        menu.addItem(itemLaunchAtLogin)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = nil
        refreshUI()

        CustomURLStore.shared.load()

        log("── Raju started ──────────────────────────────")

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log(granted ? "🎤 Microphone access granted" : "⚠️ Microphone access DENIED — recording will be silent.")
        }

        DispatchQueue.global(qos: .background).async { buildStaticContext() }
        DispatchQueue.global(qos: .background).async { self.doStartLlama() }
        DispatchQueue.global(qos: .background).async { self.doStartWhisper() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("🛑 Raju quitting — killing servers")
        ServerManager.shared.stopLlamaServer()
        ServerManager.shared.stopWhisperServer()
    }

    // ── Click handling ─────────────────────────────────────────────────────────
    @objc func iconClicked() {
        let eventType = NSApp.currentEvent?.type
        if eventType == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        if state != .idle && state != .recording { return }

        if eventType == .leftMouseDown {
            if state == .idle { doStartRecording() }
        } else if eventType == .leftMouseUp {
            if state == .recording { doStopRecording() }
        }
    }

    @objc func showLog() {
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

    @objc func showCustomURLs() {
        CustomURLsWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── Server toggle ──────────────────────────────────────────────────────────
    @objc func toggleLlama() {
        if isLlamaReady() {
            ServerManager.shared.stopLlamaServer()
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
            DispatchQueue.main.async {
                self.itemLlama.title       = "  ⏳ LLM starting…"
                self.itemLlamaToggle.title = "  ⏳ Starting…"
            }
            DispatchQueue.global(qos: .background).async { self.doStartLlama() }
        }
    }

    @objc func toggleWhisper() {
        if isWhisperReady() {
            ServerManager.shared.stopWhisperServer()
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
            DispatchQueue.global(qos: .background).async { self.doStartWhisper() }
        }
    }

    func doStartLlama() {
        ServerManager.shared.startLlamaServer(modelIndex: currentModelIndex) { [weak self] ready, name in
            DispatchQueue.main.async {
                if ready {
                    self?.itemLlama.title       = "  ⚡ LLM ready (\(name))"
                    self?.itemLlamaToggle.title = "  ⏹ Stop LLM"
                } else {
                    self?.itemLlama.title       = "  ❌ \(name) failed to load"
                    self?.itemLlamaToggle.title = "  ▶ Start LLM"
                }
            }
        }
    }

    func doStartWhisper() {
        ServerManager.shared.startWhisperServer { [weak self] ready in
            DispatchQueue.main.async {
                if ready {
                    self?.itemWhisper.title       = "  ⚡ Whisper ready (small)"
                    self?.itemWhisperToggle.title = "  ⏹ Stop Whisper"
                } else {
                    self?.itemWhisper.title       = "  ❌ Whisper failed to load"
                    self?.itemWhisperToggle.title = "  ▶ Start Whisper"
                }
            }
        }
    }

    // ── GPU toggle ─────────────────────────────────────────────────────────────
    @objc func toggleGPU() {
        useGPU = !useGPU
        itemGPUToggle.title = useGPU ? "  ⚡ GPU: On" : "  ⚪ GPU: Off"
        log("🖥️ GPU acceleration \(useGPU ? "enabled" : "disabled") — restarting servers…")
        DispatchQueue.main.async {
            self.itemLlama.title   = "  ⏳ LLM restarting…"
            self.itemWhisper.title = "  ⏳ Whisper restarting…"
        }
        ServerManager.shared.stopWhisperServer()
        ServerManager.shared.stopLlamaServer()
        DispatchQueue.global(qos: .background).async {
            Thread.sleep(forTimeInterval: 1)
            self.doStartWhisper()
        }
        DispatchQueue.global(qos: .background).async {
            Thread.sleep(forTimeInterval: 1)
            self.doStartLlama()
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
        ServerManager.shared.stopLlamaServer()
        DispatchQueue.global(qos: .background).async {
            var waited = 0
            while isLlamaReady() && waited < 15 { Thread.sleep(forTimeInterval: 1); waited += 1 }
            if waited > 0 { log("⏳ Old server stopped after \(waited)s") }
            self.doStartLlama()
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
    func doStartRecording() {
        guard ServerManager.shared.bothReady() else {
            log("⚠️ Servers not ready yet — wait for ⚡ on both")
            return
        }
        if AudioRecorder.shared.startRecording() {
            state = .recording
        }
    }

    func doStopRecording() {
        state = .transcribing
        AudioRecorder.shared.stopRecording()

        DispatchQueue.global(qos: .userInitiated).async {
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

            self.state = .thinking
            log("🤔 Asking LLM (tool-use mode)…")
            let t1    = Date()
            let reply = askLLMWithTools(query: query)
            let lt    = String(format: "%.1f", Date().timeIntervalSince(t1))
            self.lastReply = reply.isEmpty ? "Sorry, I didn't get that." : reply
            log("💬 LLM reply in \(lt)s → \"\(self.lastReply)\"")
            self.setStatus("")

            self.state = .speaking
            let voicePath = VOICES[self.currentVoiceIndex].path

            if let urlMatch = self.lastReply.range(of: #"<url>\s*(.*?)\s*</url>"#, options: .regularExpression) {
                let inner = self.lastReply[urlMatch]
                let key = inner
                    .replacingOccurrences(of: #"</?url>"#, with: "", options: .regularExpression)
                    .trimmed
                if let label = openWebShortcut(key) {
                    self.lastReply = "Opening \(label)."
                } else if key.contains(" ") || key.contains("|") || key.contains("/") {
                    // Model misused <url> as a bash wrapper — run it as a shell command
                    log("⚠️ <url> misuse — running as bash: \(key)")
                    let out = runTool(key).trimmed
                    self.lastReply = out.isEmpty ? "Done." : out
                } else {
                    self.lastReply = "Sorry, I don't have a shortcut for \(key)."
                    log("⚠️ Unknown <url> key: \(key)")
                }
            }

            if let remindMatch = self.lastReply.range(of: #"<remind>\s*(.*?)\s*</remind>"#, options: .regularExpression) {
                let inner = self.lastReply[remindMatch]
                let raw = inner
                    .replacingOccurrences(of: #"</?remind>"#, with: "", options: .regularExpression)
                    .trimmed
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
