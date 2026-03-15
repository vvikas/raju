import Foundation
import Cocoa

// ── Web shortcuts ─────────────────────────────────────────────────────────────
// Add entries here — Raju picks the right key from what you say.
// Key   = internal name the LLM uses (lowercase, no spaces)
// url   = opens in your default browser
// label = what Raju says when opening it ("Opening a Headspace meditation")
//
// To add more:  "mykey": (url: "https://...", label: "my label"),

let WEB_SHORTCUTS: [String: (url: String, label: String)] = [
    "headspace":   (url: "https://www.youtube.com/watch?v=cxmvu25om6I",
                    label: "a Headspace meditation"),
    "lofi":        (url: "https://www.youtube.com/watch?v=lTRiuFIWV54",
                    label: "lo-fi music"),
    // ── add yours below ───────────────────────────────────────────────────────
    // "news":     (url: "https://news.google.com",    label: "Google News"),
    // "gmail":    (url: "https://mail.google.com",    label: "Gmail"),
]

// ── URL opener ────────────────────────────────────────────────────────────────
// Resolves key → URL, then opens in default browser.
// Returns the spoken label, or nil if the key is unknown.
func openWebShortcut(_ key: String) -> String? {
    let k = key.lowercased().trimmed
    guard let entry = WEB_SHORTCUTS[k] else { return nil }
    if let url = URL(string: entry.url) {
        NSWorkspace.shared.open(url)
        log("🌐 Opened \(entry.label): \(entry.url)")
    }
    return entry.label
}
