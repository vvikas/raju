import Foundation

// ── Prompt format — each model family uses different chat tokens ──────────────
enum PromptFormat {
    case chatML   // <|im_start|>system … <|im_end|>   (Qwen2, Qwen2.5-Coder, SmolLM2)
    case phi3     // <|system|> … <|end|>              (Phi-3.5)
}

// ── Available LLM models ──────────────────────────────────────────────────────
// Add a new model here to make it appear in the menu.
// Set url to a direct GGUF download link to allow in-app downloading (like voices).
// Set url to nil if the model ships pre-installed (no download needed).
struct LLMModel {
    let name: String
    let file: String
    let format: PromptFormat
    let url: String?   // HuggingFace direct download URL, nil if pre-installed
    var path: String { "\(HOME)/local_llms/llama.cpp/models/\(file)" }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: path) }
}

let MODELS: [LLMModel] = [
    LLMModel(name: "Qwen2 1.5B",
             file: "qwen2-1.5b.gguf",
             format: .chatML,
             url: nil),   // pre-installed by install.sh

    LLMModel(name: "Qwen2.5-Coder 1.5B",
             file: "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf",
             format: .chatML,
             url: "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"),

    LLMModel(name: "SmolLM2 1.7B",
             file: "smollm2-1.7b-instruct-q4_k_m.gguf",
             format: .chatML,
             url: "https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF/resolve/main/smollm2-1.7b-instruct-q4_k_m.gguf"),

    LLMModel(name: "Phi-3.5 Mini 3.8B",
             file: "phi-3.5-mini-instruct-q4.gguf",
             format: .phi3,
             url: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"),
]

// ── Available Piper voices ────────────────────────────────────────────────────
// Add a new voice here to make it appear in the menu.
// All voices are downloaded on demand from HuggingFace.
struct PiperVoice {
    let name: String
    let file: String      // e.g. "en_US-lessac-medium.onnx"
    let urlPath: String   // HuggingFace path under piper-voices/main/
    var path: String    { "\(VOICES_DIR)/\(file)" }
    var onnxURL: String { "https://huggingface.co/rhasspy/piper-voices/resolve/main/\(urlPath)/\(file)" }
    var jsonURL: String { "\(onnxURL).json" }
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: path) }
}

let VOICES: [PiperVoice] = [
    PiperVoice(name: "Lessac (US Female)",   file: "en_US-lessac-medium.onnx",  urlPath: "en/en_US/lessac/medium"),
    PiperVoice(name: "Ryan (US Male)",       file: "en_US-ryan-medium.onnx",    urlPath: "en/en_US/ryan/medium"),
    PiperVoice(name: "Amy (US Female)",      file: "en_US-amy-medium.onnx",     urlPath: "en/en_US/amy/medium"),
    PiperVoice(name: "Joe (US Male)",        file: "en_US-joe-medium.onnx",     urlPath: "en/en_US/joe/medium"),
    PiperVoice(name: "Jenny (GB Female)",    file: "en_GB-jenny-medium.onnx",   urlPath: "en/en_GB/jenny/medium"),
    PiperVoice(name: "Alan (GB Male)",       file: "en_GB-alan-medium.onnx",    urlPath: "en/en_GB/alan/medium"),
]
