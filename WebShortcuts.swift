import Foundation
import Cocoa

// ── Custom URL entry ───────────────────────────────────────────────────────────
struct CustomURLEntry: Codable {
    var trigger: String   // phrase the LLM uses, e.g. "headspace"
    var url: String       // destination URL
    var label: String     // spoken label, e.g. "a Headspace meditation"
}

// ── Persistent store ───────────────────────────────────────────────────────────
class CustomURLStore {
    static let shared = CustomURLStore()
    private init() {}

    private let filePath: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".raju")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_urls.json")
    }()

    var entries: [CustomURLEntry] = []

    private let defaults: [CustomURLEntry] = [
        CustomURLEntry(trigger: "headspace",
                       url: "https://www.youtube.com/watch?v=cxmvu25om6I",
                       label: "a Headspace meditation"),
        CustomURLEntry(trigger: "lofi",
                       url: "https://www.youtube.com/watch?v=lTRiuFIWV54",
                       label: "lo-fi music"),
    ]

    func load() {
        if let data = try? Data(contentsOf: filePath),
           let decoded = try? JSONDecoder().decode([CustomURLEntry].self, from: data) {
            entries = decoded
        } else {
            entries = defaults
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: filePath, options: .atomic)
        }
    }

    // Case-insensitive substring match against utterance
    func match(for utterance: String) -> CustomURLEntry? {
        let lower = utterance.lowercased()
        return entries.first { lower.contains($0.trigger.lowercased()) }
    }

    // Comma-separated list of "trigger (label)" for LLM system prompt
    var systemPromptKeys: String {
        entries.map { "\($0.trigger) (\($0.label))" }.joined(separator: ", ")
    }
}

// ── URL opener ────────────────────────────────────────────────────────────────
// Opens URL by trigger key (exact match). Returns spoken label or nil.
func openWebShortcut(_ key: String) -> String? {
    let k = key.lowercased().trimmed
    guard let entry = CustomURLStore.shared.entries.first(where: { $0.trigger.lowercased() == k }) else {
        return nil
    }
    if let url = URL(string: entry.url) {
        NSWorkspace.shared.open(url)
        log("🌐 Opened \(entry.label): \(entry.url)")
    }
    return entry.label
}
