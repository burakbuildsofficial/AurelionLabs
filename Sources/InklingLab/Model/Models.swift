import Foundation

/// Örnekleme ayarları. Varsayılanlar Unsloth'un önerisi: sıcaklık 1.0, kırpma yok.
struct SamplingParams: Codable, Equatable, Hashable {
    var temperature: Double = 1.0
    var topP: Double = 1.0
    var topK: Int = 0          // 0 = kapalı
    var minP: Double = 0.0
    var maxTokens: Int = 4096
    var systemPrompt: String = ""

    static let recommended = SamplingParams()
}

struct Preset: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var params: SamplingParams
    var builtIn = false

    static let defaults: [Preset] = [
        Preset(name: "Önerilen", params: .recommended, builtIn: true),
        Preset(name: "Türkçe asistan",
               params: SamplingParams(temperature: 0.7, topP: 0.95, topK: 0, minP: 0.05, maxTokens: 4096,
                                      systemPrompt: "Her zaman akıcı ve doğal bir Türkçeyle, kısa ve net cevap ver."),
               builtIn: true),
        Preset(name: "Kod yardımcısı",
               params: SamplingParams(temperature: 0.3, topP: 0.95, topK: 0, minP: 0.05, maxTokens: 8192,
                                      systemPrompt: "Deneyimli bir yazılımcısın. Çalışan, açıklamalı kod ver; gereksiz laf etme."),
               builtIn: true),
        Preset(name: "Yaratıcı",
               params: SamplingParams(temperature: 1.3, topP: 1.0, topK: 0, minP: 0.02, maxTokens: 4096,
                                      systemPrompt: ""),
               builtIn: true),
    ]
}

/// Bir cevabın ölçümleri (llama.cpp `timings` alanından).
struct GenStats: Codable, Equatable, Hashable {
    var promptTokens: Int = 0
    var promptPerSecond: Double = 0
    var generatedTokens: Int = 0
    var generatedPerSecond: Double = 0
    var firstTokenSeconds: Double?
    var totalSeconds: Double = 0
}

struct ImageAttachment: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    let jpegData: Data
    let pixelSize: CGSize

    var dataURL: String { "data:image/jpeg;base64," + jpegData.base64EncodedString() }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Sohbete eklenen metin, kod ya da PDF dosyasının çıkarılmış içeriği.
struct DocumentAttachment: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    let name: String
    let text: String
    var truncated = false

    /// Kabaca token tahmini (Türkçe/kod için ~3,5 karakter = 1 token).
    var approxTokens: Int { Int(Double(text.count) / 3.5) }
}

/// Modelin istediği araç çağrısı (ajan modu).
struct ToolCallRecord: Codable, Equatable, Hashable {
    var id: String
    var name: String
    var arguments: String
}

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant, tool }

    var id = UUID()
    var role: Role
    var text: String
    var reasoning: String = ""
    var images: [ImageAttachment] = []
    var documents: [DocumentAttachment] = []
    var toolCalls: [ToolCallRecord]?     // asistan: istediği araçlar
    var toolCallID: String?              // araç sonucu: hangi çağrıya ait
    var toolName: String?
    var stats: GenStats?
    var error: String?
    var isStreaming = false
    var presetName: String?
}

extension ChatMessage {
    /// Modele giden metin: ekli dosyalar önce, soru sonra.
    var promptText: String {
        guard !documents.isEmpty else { return text }
        let docs = documents.map { d in
            "<dosya ad=\"\(d.name)\"\(d.truncated ? " kısaltıldı=\"evet\"" : "")>\n\(d.text)\n</dosya>"
        }.joined(separator: "\n\n")
        return docs + "\n\n" + (text.isEmpty ? "Bu dosyayı özetle." : text)
    }
}

/// Kaydedilen sohbet.
struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var created = Date()
    var updated = Date()
    var messages: [ChatMessage]
    var pinned: Bool?
    var model: String?

    var isPinned: Bool { pinned == true }
    var preview: String {
        guard let last = messages.last(where: { !$0.text.isEmpty }) else { return "" }
        return last.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Sohbeti okunur Markdown'a çevirir (dışa aktarma için).
    var markdown: String {
        var out = "# \(title)\n\n"
        if let model { out += "_Model: \(model)_\n\n" }
        for m in messages {
            if m.role == .tool { out += "> 🔧 \(m.toolName ?? "araç") sonucu\n\n"; continue }
            out += m.role == .user ? "## Sen\n\n" : "## Model\n\n"
            for c in m.toolCalls ?? [] { out += "> 🔧 \(c.name)(\(c.arguments))\n\n" }
            for d in m.documents { out += "> 📎 \(d.name)\n\n" }
            if !m.images.isEmpty { out += "> 🖼 \(m.images.count) resim\n\n" }
            out += m.text + "\n\n"
        }
        return out
    }

    static func makeTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "Yeni sohbet" }
        let t = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if !t.isEmpty { return t.count > 48 ? String(t.prefix(48)) + "…" : t }
        if let d = first.documents.first { return d.name }
        return first.images.isEmpty ? "Yeni sohbet" : "Resim sorusu"
    }
}
