import Foundation

/// OpenAI uyumlu llama.cpp uç noktasına akışlı (stream) istek atar.
struct LLMClient {
    enum Event {
        case reasoning(String)
        case content(String)
        case finished(GenStats)
    }

    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let baseURL: URL

    func stream(messages: [ChatMessage], params: SamplingParams) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(messages: messages, params: params, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(messages: [ChatMessage], params: SamplingParams,
                     continuation: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = try JSONSerialization.data(withJSONObject: body(messages: messages, params: params))

        let started = Date()
        var firstToken: Double?
        let (bytes, response) = try await URLSession.shared.bytes(for: req)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw ClientError(message: Self.serverMessage(text) ?? "Sunucu \(http.statusCode) hatası döndü.")
        }

        var stats = GenStats()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let err = obj["error"] as? [String: Any] {
                throw ClientError(message: err["message"] as? String ?? "Sunucu hatası.")
            }
            if let choices = obj["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
                if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                    if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                    continuation.yield(.reasoning(r))
                }
                if let c = delta["content"] as? String, !c.isEmpty {
                    if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                    continuation.yield(.content(c))
                }
            }
            if let t = obj["timings"] as? [String: Any] {
                stats.promptTokens = t["prompt_n"] as? Int ?? stats.promptTokens
                stats.promptPerSecond = t["prompt_per_second"] as? Double ?? stats.promptPerSecond
                stats.generatedTokens = t["predicted_n"] as? Int ?? stats.generatedTokens
                stats.generatedPerSecond = t["predicted_per_second"] as? Double ?? stats.generatedPerSecond
            }
        }
        stats.firstTokenSeconds = firstToken
        stats.totalSeconds = Date().timeIntervalSince(started)
        continuation.yield(.finished(stats))
    }

    // MARK: Tek parça (akışsız) istek — testler için

    struct ToolCall { var id = ""; let name: String; let arguments: String }

    struct Completion {
        var content = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var stats = GenStats()
    }

    func complete(messages: [ChatMessage], params: SamplingParams, toolsJSON: Data? = nil) async throws -> Completion {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 900
        var b = body(messages: messages, params: params)
        b["stream"] = false
        if let toolsJSON, let tools = try? JSONSerialization.jsonObject(with: toolsJSON) { b["tools"] = tools }
        req.httpBody = try JSONSerialization.data(withJSONObject: b)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError(message: Self.serverMessage(text) ?? "Sunucu \(http.statusCode) hatası döndü.")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError(message: "Sunucudan anlaşılmayan cevap geldi.")
        }
        var out = Completion()
        if let msg = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] {
            out.content = msg["content"] as? String ?? ""
            out.reasoning = msg["reasoning_content"] as? String ?? ""
            for call in msg["tool_calls"] as? [[String: Any]] ?? [] {
                if let f = call["function"] as? [String: Any], let name = f["name"] as? String {
                    out.toolCalls.append(ToolCall(id: call["id"] as? String ?? UUID().uuidString, name: name,
                                                  arguments: f["arguments"] as? String ?? ""))
                }
            }
        }
        if let t = obj["timings"] as? [String: Any] {
            out.stats.promptTokens = t["prompt_n"] as? Int ?? 0
            out.stats.promptPerSecond = t["prompt_per_second"] as? Double ?? 0
            out.stats.generatedTokens = t["predicted_n"] as? Int ?? 0
            out.stats.generatedPerSecond = t["predicted_per_second"] as? Double ?? 0
        }
        out.stats.totalSeconds = Date().timeIntervalSince(started)
        return out
    }

    private func body(messages: [ChatMessage], params: SamplingParams) -> [String: Any] {
        var out: [[String: Any]] = []
        let system = params.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { out.append(["role": "system", "content": system]) }

        for m in messages where m.error == nil {
            if m.role == .user, !m.images.isEmpty {
                var parts: [[String: Any]] = m.images.map {
                    ["type": "image_url", "image_url": ["url": $0.dataURL]]
                }
                let t = m.promptText
                if !t.isEmpty { parts.append(["type": "text", "text": t]) }
                out.append(["role": "user", "content": parts])
            } else if m.role == .tool {
                out.append(["role": "tool", "tool_call_id": m.toolCallID ?? "", "content": m.text])
            } else if let calls = m.toolCalls, !calls.isEmpty {
                out.append(["role": "assistant", "content": m.text,
                            "tool_calls": calls.map { ["id": $0.id, "type": "function",
                                                       "function": ["name": $0.name, "arguments": $0.arguments]] }])
            } else {
                out.append(["role": m.role.rawValue, "content": m.promptText])
            }
        }

        return [
            "messages": out,
            "stream": true,
            "temperature": params.temperature,
            "top_p": params.topP,
            "top_k": params.topK,
            "min_p": params.minP,
            "max_tokens": params.maxTokens,
            "timings_per_token": false,
        ]
    }

    private static func serverMessage(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return text.isEmpty ? nil : String(text.prefix(300)) }
        return err["message"] as? String
    }
}
