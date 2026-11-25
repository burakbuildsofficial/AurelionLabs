import Foundation

/// Ajan modunda modele verilen araçlar. Dosya araçları yalnız kullanıcının seçtiği çalışma klasörünün içinde çalışır;
/// yazma ve komut çalıştırma her seferinde kullanıcı onayı ister (onayı LabStore sorar).
enum AgentTools {
    enum Risk { case safe, needsApproval }

    struct Outcome { let text: String; let ok: Bool }

    static func risk(of name: String) -> Risk {
        ["dosya_yaz", "komut_calistir"].contains(name) ? .needsApproval : .safe
    }

    /// OpenAI biçiminde araç tanımları. Çalışma klasörü yoksa dosya/komut araçları verilmez.
    static func definitions(hasFolder: Bool) -> Data {
        var tools: [[String: Any]] = [
            fn("hesapla", "Matematik ifadesini kesin hesaplar. + - * / % ^ ve parantez destekler.",
               ["ifade": "Hesaplanacak ifade, ör. (48271*9133+17)/3"], required: ["ifade"]),
            fn("simdiki_zaman", "Bu Mac'teki güncel tarih, gün ve saati verir.", [:], required: []),
        ]
        if hasFolder {
            tools += [
                fn("dosya_listele", "Çalışma klasöründeki dosya ve klasörleri listeler.",
                   ["klasor": "Çalışma klasörüne göre göreli yol; kök için \".\""], required: []),
                fn("dosya_oku", "Çalışma klasöründeki bir metin, kod ya da PDF dosyasını okur.",
                   ["yol": "Çalışma klasörüne göre göreli dosya yolu"], required: ["yol"]),
                fn("dosya_yaz", "Çalışma klasörüne bir metin dosyası yazar (varsa üzerine yazar). Kullanıcı onaylamalı.",
                   ["yol": "Göreli dosya yolu", "icerik": "Dosyanın tam içeriği"], required: ["yol", "icerik"]),
                fn("komut_calistir", "Çalışma klasöründe bir kabuk (zsh) komutu çalıştırır, çıktısını döndürür. Kullanıcı onaylamalı.",
                   ["komut": "Çalıştırılacak komut, ör. ls -la"], required: ["komut"]),
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: tools)) ?? Data("[]".utf8)
    }

    private static func fn(_ name: String, _ desc: String, _ props: [String: String], required: [String]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": desc,
            "parameters": ["type": "object",
                           "properties": props.mapValues { ["type": "string", "description": $0] },
                           "required": required],
        ]]
    }

    static func args(_ json: String) -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [:] }
        return obj.compactMapValues { v in (v as? String) ?? (v as? NSNumber)?.stringValue }
    }

    /// Onay penceresinde gösterilecek kısa açıklama.
    static func summary(_ call: ToolCallRecord) -> String {
        let a = args(call.arguments)
        switch call.name {
        case "dosya_yaz": return "\(a["yol"] ?? "?") dosyasına \((a["icerik"] ?? "").count) karakter yazılacak."
        case "komut_calistir": return a["komut"] ?? ""
        default: return call.arguments
        }
    }

    // MARK: Çalıştırma

    static func run(_ call: ToolCallRecord, folder: URL?, maxChars: Int) async -> Outcome {
        let a = args(call.arguments)
        switch call.name {
        case "hesapla":
            guard let expr = a["ifade"] else { return Outcome(text: "Hata: ifade verilmedi.", ok: false) }
            do { return Outcome(text: format(try Calculator.evaluate(expr)), ok: true) }
            catch { return Outcome(text: "Hata: \(error.localizedDescription)", ok: false) }

        case "simdiki_zaman":
            let f = DateFormatter()
            f.locale = Locale(identifier: "tr_TR")
            f.dateFormat = "d MMMM yyyy EEEE, HH:mm"
            return Outcome(text: f.string(from: Date()), ok: true)

        case "dosya_listele":
            guard let url = resolve(a["klasor"] ?? ".", in: folder) else { return outside }
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                                       options: [.skipsHiddenFiles])) ?? []
            if items.isEmpty { return Outcome(text: "Klasör boş ya da okunamadı.", ok: true) }
            let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(200).map { u -> String in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return v?.isDirectory == true ? "\(u.lastPathComponent)/" : "\(u.lastPathComponent) (\(v?.fileSize ?? 0) bayt)"
            }
            return Outcome(text: lines.joined(separator: "\n") + (items.count > 200 ? "\n… ve \(items.count - 200) öğe daha" : ""), ok: true)

        case "dosya_oku":
            guard let url = resolve(a["yol"] ?? "", in: folder) else { return outside }
            guard let text = DocumentLoader.loadText(url, maxChars: maxChars + 1) else {
                return Outcome(text: "Dosya okunamadı (yok, boş ya da metin değil).", ok: false)
            }
            return Outcome(text: text.count > maxChars ? String(text.prefix(maxChars)) + "\n[… dosyanın devamı kesildi]" : text, ok: true)

        case "dosya_yaz":
            guard let url = resolve(a["yol"] ?? "", in: folder) else { return outside }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (a["icerik"] ?? "").write(to: url, atomically: true, encoding: .utf8)
                return Outcome(text: "Yazıldı: \(a["yol"] ?? "")", ok: true)
            } catch { return Outcome(text: "Yazılamadı: \(error.localizedDescription)", ok: false) }

        case "komut_calistir":
            guard let folder else { return outside }
            return await shell(a["komut"] ?? "", in: folder, maxChars: maxChars)

        default:
            return Outcome(text: "Böyle bir araç yok: \(call.name)", ok: false)
        }
    }

    private static let outside = Outcome(text: "Hata: yol çalışma klasörünün dışında ya da çalışma klasörü seçilmedi.", ok: false)

    /// Göreli yolu çalışma klasörüne bağlar; klasör dışına (.. ya da sembolik bağla) çıkışı reddeder.
    static func resolve(_ path: String, in folder: URL?) -> URL? {
        guard let folder else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let clean = path.hasPrefix("/") ? path : root + "/" + path
        var url = URL(fileURLWithPath: clean).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) { url = url.resolvingSymlinksInPath() }
        let p = url.path
        return (p == root || p.hasPrefix(root + "/")) ? url : nil
    }

    private static func shell(_ command: String, in folder: URL, maxChars: Int) async -> Outcome {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", command]
            p.currentDirectoryURL = folder
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                cont.resume(returning: Outcome(text: "Çalıştırılamadı: \(error.localizedDescription)", ok: false)); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                var out = String(decoding: data, as: UTF8.self)
                if out.count > maxChars { out = String(out.prefix(maxChars)) + "\n[… çıktı kesildi]" }
                let code = p.terminationStatus
                cont.resume(returning: Outcome(text: "çıkış kodu \(code)\n" + (out.isEmpty ? "(çıktı yok)" : out), ok: code == 0))
            }
        }
    }

    private static func format(_ v: Double) -> String {
        if v.isFinite, v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(v)
    }
}

/// Güvenli dört işlem hesap makinesi (NSExpression hatalı girdide uygulamayı çökertebildiği için).
enum Calculator {
    struct Failure: LocalizedError { let errorDescription: String? }

    static func evaluate(_ s: String) throws -> Double {
        var p = Parser(chars: Array(s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")))
        let v = try p.expr()
        p.skip()
        guard p.i == p.chars.count else { throw Failure(errorDescription: "ifade anlaşılamadı") }
        return v
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }
        mutating func peek() -> Character? { skip(); return i < chars.count ? chars[i] : nil }
        mutating func expr() throws -> Double {
            var v = try term()
            while let c = peek(), c == "+" || c == "-" { i += 1; v = c == "+" ? v + (try term()) : v - (try term()) }
            return v
        }
        mutating func term() throws -> Double {
            var v = try power()
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                let r = try power()
                if c != "*" && r == 0 { throw Failure(errorDescription: "sıfıra bölme") }
                v = c == "*" ? v * r : c == "/" ? v / r : v.truncatingRemainder(dividingBy: r)
            }
            return v
        }
        mutating func power() throws -> Double {
            let b = try unary()
            if peek() == "^" { i += 1; return pow(b, try power()) }
            return b
        }
        mutating func unary() throws -> Double {
            if peek() == "-" { i += 1; return -(try unary()) }
            if peek() == "+" { i += 1; return try unary() }
            return try atom()
        }
        mutating func atom() throws -> Double {
            if peek() == "(" {
                i += 1
                let v = try expr()
                guard peek() == ")" else { throw Failure(errorDescription: "kapanmayan parantez") }
                i += 1
                return v
            }
            skip()
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            guard start < i, let v = Double(String(chars[start..<i])) else { throw Failure(errorDescription: "sayı bekleniyordu") }
            return v
        }
    }
}
