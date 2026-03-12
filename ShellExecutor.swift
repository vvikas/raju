import Foundation

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

// ── Safe tool runner ──────────────────────────────────────────────────────────
func runTool(_ rawCmd: String) -> String {
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
    
    let queue = DispatchQueue(label: "com.raju.pipeReader")
    let ioGroup = DispatchGroup()
    var outputData = Data()
    
    ioGroup.enter()
    pipe.fileHandleForReading.readabilityHandler = { fh in
        let data = fh.availableData
        if data.isEmpty {
            pipe.fileHandleForReading.readabilityHandler = nil
            ioGroup.leave()
        } else {
            queue.async { outputData.append(data) }
        }
    }

    do {
        try task.run()
    } catch {
        return "Error: failed to run bash command."
    }

    let timeoutWorkItem = DispatchWorkItem {
        if task.isRunning {
             task.terminate()
             log("⚠️ Command timed out after 5s.")
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5.0, execute: timeoutWorkItem)

    task.waitUntilExit()
    _ = ioGroup.wait(timeout: .now() + 2.0)
    timeoutWorkItem.cancel()
    
    queue.sync { }

    let out = String(data: outputData, encoding: .utf8) ?? ""
    let cleaned = cleanToolOutput(out)
    return cleaned.components(separatedBy: "\n").prefix(50).joined(separator: "\n").trimmed
}

func cleanToolOutput(_ text: String) -> String {
    var s = text
    if let re = try? NSRegularExpression(
            pattern: #"(?:/[^/\n]+)*/([^/\n]+)\.app/[^\s]*(?: [^\s-][^\s]*)*"#) {
        s = re.stringByReplacingMatches(in: s,
            range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }
    if let re = try? NSRegularExpression(pattern: #"/(?:[^\s/]+/)+([^\s/]+)"#) {
        s = re.stringByReplacingMatches(in: s,
            range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }
    return s
}

func getFullProcessNames() -> [String: String] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", "ps -cAxo pid=,comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let out = String(data: data, encoding: .utf8) else { return [:] }
    
    var dict = [String: String]()
    for line in out.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let spaceRange = trimmed.range(of: " ") else { continue }
        let pid = String(trimmed[..<spaceRange.lowerBound])
        let comm = String(trimmed[spaceRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !pid.isEmpty { dict[pid] = comm }
    }
    return dict
}

func formatTopRAM(_ rawString: String) -> String {
    let lower = rawString.lowercased()
    var valueStr = lower
    var multiplier: Double = 1.0
    
    if valueStr.hasSuffix("g") {
        valueStr.removeLast()
        multiplier = 1024.0
    } else if valueStr.hasSuffix("m") {
        valueStr.removeLast()
        multiplier = 1.0
    } else if valueStr.hasSuffix("k") {
        valueStr.removeLast()
        multiplier = 1.0 / 1024.0
    }
    
    guard let doubleVal = Double(valueStr) else { return rawString }
    let mbVal = doubleVal * multiplier
    return String(format: "%.0f MB", mbVal)
}

func reformatOutput(_ raw: String, cmd: String) -> String {
    let isPS = cmd.lowercased().contains("ps ")
    let isTop = cmd.lowercased().contains("top ") || cmd.lowercased().hasPrefix("top")
    
    if isPS || isTop {
        let lines = raw.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }
        guard !lines.isEmpty else { return raw }
        
        var reformatted = ["Processes (highest usage first):"]
        var startIndex = 0
        if lines[0].contains("PID") || lines[0].contains("COMM") {
            startIndex = 1
        }
        
        let pattern = #"^\s*(\d+)\s+(.+?)\s+([0-9.]+)\s+([0-9.A-Za-z%]+)\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return raw }
        
        let isRSS = cmd.contains(",rss") || cmd.contains(" rss")
        let fullNames = isTop ? getFullProcessNames() : [:]
        
        var transformedAnything = false
        var rank = 1
        for i in startIndex..<lines.count {
            let line = lines[i]
            if let match = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let pid = String(line[Range(match.range(at: 1), in: line)!])
                var name = String(line[Range(match.range(at: 2), in: line)!]).trimmed
                
                if isTop, let realName = fullNames[pid] { name = realName }
                
                let cpu = String(line[Range(match.range(at: 3), in: line)!])
                let ramRaw = String(line[Range(match.range(at: 4), in: line)!])
                
                let ramFormatted: String
                if isRSS, let kb = Double(ramRaw) {
                    ramFormatted = String(format: "%.0f MB", kb / 1024.0)
                } else if isTop {
                    ramFormatted = formatTopRAM(ramRaw)
                } else if ramRaw.last?.isLetter == false && ramRaw.last != "%" {
                    ramFormatted = "\(ramRaw)%"
                } else {
                    ramFormatted = ramRaw
                }
                
                let prefix = rank == 1 ? "🏆 #1 MAXIMUM CONSUMER" : "   #\(rank)"
                reformatted.append("\(prefix): \(name) (PID \(pid)) ---> CPU = \(cpu)%, RAM = \(ramFormatted)")
                transformedAnything = true
                rank += 1
            } else {
                reformatted.append(line)
            }
        }
        return transformedAnything ? reformatted.joined(separator: "\n") : raw
    }
    return raw
}

func extractFindKeyword(_ cmd: String) -> String? {
    let pat = #"-i?name\s+"([^"]+)""#
    guard let re = try? NSRegularExpression(pattern: pat),
          let m  = re.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
          let r  = Range(m.range(at: 1), in: cmd) else { return nil }
    var kw = String(cmd[r])
    kw = kw.trimmingCharacters(in: CharacterSet(charactersIn: "*.? "))
    return kw.isEmpty ? nil : kw
}

func extractFindFolder(_ cmd: String) -> String {
    let parts = cmd.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return "~/" }
    let folder = String(parts[1])
    return (folder.hasPrefix("~") || folder.hasPrefix("/")) ? folder : "~/"
}
