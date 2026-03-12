import Foundation

// ── Server health checks ──────────────────────────────────────────────────────
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
