import Foundation

/// Yerel modellerin bozuk araç çağrılarını onarır.
/// 1. Sunucu çağrıyı ayrıştıramayıp metne bıraktıysa (`<tool_call>{…}</tool_call>` ya da ```json bloğu) metinden çıkarır.
/// 2. Argüman JSON'u bozuksa (kod çiti, sondaki virgül, tek tırnak, fazladan metin) düzeltir.
/// 3. Hâlâ geçersizse (bilinmeyen araç, zorunlu argüman eksik) modele ne yanlış olduğunu söyleyen bir hata metni üretir;
///    model bu metni araç sonucu olarak görür ve tekrar dener.
enum ToolRepair {
    /// Araç tanımlarından ad → zorunlu argümanlar.
    static func schema(_ toolsJSON: Data?) -> [String: [String]] {
        guard let d = toolsJSON, let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [:] }
        var out: [String: [String]] = [:]
        for t in arr {
            guard let f = t["function"] as? [String: Any], let n = f["name"] as? String else { continue }
            out[n] = (f["parameters"] as? [String: Any])?["required"] as? [String] ?? []
        }
        return out
    }

    /// Sunucunun `tool_calls` alanı boş ama metinde çağrı varsa onu çıkarır; çıkarılan kısım metinden silinir.
    static func extractFromText(_ content: String, known: Set<String>) -> (calls: [LLMClient.ToolCall], rest: String) {
        guard !known.isEmpty else { return ([], content) }
        var calls: [LLMClient.ToolCall] = []
        var rest = content
        let patterns = [#"<tool_call>\s*([\s\S]*?)\s*</tool_call>"#, #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = rest as NSString
            var spans: [NSRange] = []
            for m in re.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let body = ns.substring(with: m.range(at: 1))
                guard let obj = parseObject(body), let name = obj["name"] as? String, known.contains(name) else { continue }
                let args = obj["arguments"] ?? obj["parameters"] ?? [:]
                calls.append(.init(id: "repair-\(UUID().uuidString.prefix(8))", name: name, arguments: jsonString(args)))
                spans.append(m.range)
            }
            for r in spans.reversed() { rest = (rest as NSString).replacingCharacters(in: r, with: "") }
            if !calls.isEmpty { break }
        }
        return (calls, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Argüman metnini geçerli JSON nesnesine çevirir; olmuyorsa nil.
    static func parseObject(_ raw: String) -> [String: Any]? {
        if let o = decode(raw) { return o }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b { s = String(s[a...b]) }
        if let o = decode(s) { return o }
        s = s.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        if let o = decode(s) { return o }
        if !s.contains("\"") { s = s.replacingOccurrences(of: "'", with: "\"") }
        return decode(s)
    }

    private static func decode(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    static func jsonString(_ v: Any) -> String {
        if let s = v as? String { return parseObject(s).map(jsonString) ?? s }
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Çağrıyı onarır; onarılamıyorsa modele gidecek hata metnini döndürür.
    static func check(_ call: inout ToolCallRecord, schema: [String: [String]]) -> String? {
        guard let required = schema[call.name] else {
            return L("Hata: '\(call.name)' diye bir araç yok. Kullanılabilen araçlar: \(schema.keys.sorted().joined(separator: ", ")).")
        }
        let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let obj: [String: Any]
        if trimmed.isEmpty {
            obj = [:]
        } else if let o = parseObject(trimmed) {
            obj = o
        } else {
            return L("Hata: \(call.name) argümanları geçerli JSON değil. Şu biçimde tekrar çağır: {\"ad\": \"değer\"}. Gelen: \(trimmed.prefix(200))")
        }
        call.arguments = jsonString(obj)
        let missing = required.filter { k in
            guard let v = obj[k] else { return true }
            return (v as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == true
        }
        if !missing.isEmpty {
            return L("Hata: \(call.name) için zorunlu argüman eksik: \(missing.joined(separator: ", ")). Bunlarla tekrar çağır.")
        }
        return nil
    }
}
