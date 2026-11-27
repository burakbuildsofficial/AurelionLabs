import Foundation

/// Kullanıcının Beyin kasasına (`beyin serve`, 127.0.0.1:8765) bağlanan araçlar. Sunucu kapalıysa araçlar modele verilmez.
enum BrainClient {
    static let base = URL(string: "http://127.0.0.1:8765")!

    /// Kısa zaman aşımıyla sağlık kontrolü; ajan döngüsü başında bir kez çağrılır.
    static func isUp() async -> Bool {
        var r = URLRequest(url: base.appendingPathComponent("saglik"))
        r.timeoutInterval = 1.5
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    static func run(_ name: String, _ a: [String: String], maxChars: Int) async -> AgentTools.Outcome {
        do {
            let text: String
            switch name {
            case "beyin_baglam":
                text = try await get("baglam", [:])
            case "beyin_ara":
                let data = try await get("ara", ["q": a["sorgu"] ?? "", "limit": "6", "klasor": a["klasor"]])
                let rows = (try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [[String: Any]]) ?? []
                text = rows.isEmpty ? "Sonuç yok." : rows.map {
                    "• \($0["baslik"] as? String ?? "") — \($0["yol"] as? String ?? "")\n  \($0["metin"] as? String ?? "")"
                }.joined(separator: "\n")
            case "beyin_oku":
                text = try await get("oku", ["yol": a["yol"] ?? ""])
            case "beyin_kaydet":
                var body: [String: Any] = ["baslik": a["baslik"] ?? "", "icerik": a["icerik"] ?? "",
                                           "tur": a["tur"] ?? "not", "ajan": "inkling"]
                if let e = a["etiketler"], !e.isEmpty {
                    body["etiketler"] = e.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                text = "Kaydedildi: " + (try await post("kaydet", body))
            case "x_tarzi":
                text = try await get("x/tarz", [:])
            case "x_taslak_koy":
                let tweets = (a["tweetler"] ?? "").components(separatedBy: "---tweet---")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let sources = (a["kaynaklar"] ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let raw = try await post("x/taslak", ["baslik": a["baslik"] ?? "", "tweetler": tweets,
                                                      "kaynaklar": sources, "ajan": "inkling"])
                let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                text = "Kuyruğa kondu, kullanıcı onaylayınca gider.\n" + (obj?["ozet"] as? String ?? raw)
            default:
                return .init(text: "Böyle bir araç yok: \(name)", ok: false)
            }
            return .init(text: text.count > maxChars ? String(text.prefix(maxChars)) + "\n[… kesildi]" : text, ok: true)
        } catch {
            return .init(text: "Beyin'e ulaşılamadı (beyin serve açık mı?): \(error.localizedDescription)", ok: false)
        }
    }

    private static func get(_ path: String, _ q: [String: String?]) async throws -> String {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = q.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : URLQueryItem(name: k, value: $0) } }
        return try await send(URLRequest(url: c.url!))
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> String {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(r)
    }

    private static func send(_ req: URLRequest) async throws -> String {
        var r = req
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: r)
        let s = String(decoding: data, as: UTF8.self)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Beyin", code: 1,
            userInfo: [NSLocalizedDescriptionKey: s]) }
        return s
    }
}
