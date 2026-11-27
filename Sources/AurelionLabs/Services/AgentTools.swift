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
    static func definitions(hasFolder: Bool, hasBrain: Bool = false) -> Data {
        var tools: [[String: Any]] = [
            fn("hesapla", L("Matematik ifadesini kesin hesaplar. + - * / % ^ ve parantez destekler."),
               ["ifade": L("Hesaplanacak ifade, ör. (48271*9133+17)/3")], required: ["ifade"]),
            fn("simdiki_zaman", L("Bu Mac'teki güncel tarih, gün ve saati verir."), [:], required: []),
        ]
        if hasBrain {
            tools += [
                fn("beyin_baglam", L("Kullanıcının Beyin'inden özet: kim olduğu, son günlerin işleri, açık görevler. Sohbetin başında bir kez çağır."),
                   [:], required: []),
                fn("beyin_ara", L("Kullanıcının Beyin'inde (notlar, kararlar, projeler, video stili) anlamca arar. Bir şeyi hatırlaman gerekince önce bunu kullan."),
                   ["sorgu": L("Aranacak konu"), "klasor": L("İsteğe bağlı: Kararlar, Projeler, Notlar, Video, Gorevler…")], required: ["sorgu"]),
                fn("beyin_oku", L("Beyin'deki bir notun tamamını okur."), ["yol": L("Notun yolu, ör. Kararlar/x.md")], required: ["yol"]),
                fn("beyin_kaydet", L("Kalıcı bilgiyi Beyin'e yazar: biten iş, karar, ölçüm sonucu, ders. Sohbetin tamamını değil özünü yaz."),
                   ["baslik": L("Kısa başlık"), "icerik": L("Öz bilgi; rakamlar ölçümden"),
                    "tur": "not | karar | gorev | kaynak | ders | kisi | proje", "etiketler": L("Virgülle ayrılmış, ör. inkling,x-paylasim")],
                   required: ["baslik", "icerik"]),
                fn("x_tarzi", L("Kullanıcının X paylaşım tarzı kuralları. X taslağı yazmadan önce oku."), [:], required: []),
                fn("x_taslak_koy", L("X flood taslağını kullanıcının onay kuyruğuna koyar; GÖNDERMEZ, gönderimi kullanıcı yapar. ")
                   + L("Rakamları yalnız Beyin notlarından al."),
                   ["baslik": L("Taslağın konusu"),
                    "tweetler": L("Tweetler sırayla; aralarına tek başına bir satırda ---tweet--- koy. Her biri en fazla 280 karakter."),
                    "kaynaklar": L("Rakamların geldiği Beyin not yolları, virgülle ayrılmış")],
                   required: ["baslik", "tweetler"]),
            ]
        }
        let skills = SkillLibrary.all()
        if !skills.isEmpty {
            tools.append(fn("beceri_oku",
                L("Bir beceriyi (adım adım talimat paketi) açar. İş aşağıdaki becerilerden birine uyuyorsa önce bunu çağır, ")
                + L("sonra talimatlara uy. Becerinin ek dosyaları için `dosya` ver (ör. references/x.md). Beceriler:\n")
                + SkillLibrary.catalog(skills),
                ["ad": L("Becerinin adı, ör. hyperframes"), "dosya": L("İsteğe bağlı: beceri klasörüne göre göreli dosya; boşsa SKILL.md")],
                required: ["ad"]))
        }
        if hasFolder {
            tools += [
                fn("dosya_listele", L("Çalışma klasöründeki dosya ve klasörleri listeler."),
                   ["klasor": L("Çalışma klasörüne göre göreli yol; kök için \".\"")], required: []),
                fn("dosya_oku", L("Çalışma klasöründeki bir metin, kod ya da PDF dosyasını okur."),
                   ["yol": L("Çalışma klasörüne göre göreli dosya yolu")], required: ["yol"]),
                fn("dosya_yaz", L("Çalışma klasörüne bir metin dosyası yazar (varsa üzerine yazar). Kullanıcı onaylamalı."),
                   ["yol": L("Göreli dosya yolu"), "icerik": L("Dosyanın tam içeriği")], required: ["yol", "icerik"]),
                fn("komut_calistir", L("Çalışma klasöründe bir kabuk (zsh) komutu çalıştırır, çıktısını döndürür. Kullanıcı onaylamalı."),
                   ["komut": L("Çalıştırılacak komut, ör. ls -la")], required: ["komut"]),
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
        case "dosya_yaz": return L("\(a["yol"] ?? "?") dosyasına \((a["icerik"] ?? "").count) karakter yazılacak.")
        case "komut_calistir": return a["komut"] ?? ""
        default: return call.arguments
        }
    }

    // MARK: Çalıştırma

    static func run(_ call: ToolCallRecord, folder: URL?, maxChars: Int) async -> Outcome {
        let a = args(call.arguments)
        switch call.name {
        case "hesapla":
            guard let expr = a["ifade"] else { return Outcome(text: L("Hata: ifade verilmedi."), ok: false) }
            do { return Outcome(text: format(try Calculator.evaluate(expr)), ok: true) }
            catch { return Outcome(text: L("Hata: \(error.localizedDescription)"), ok: false) }

        case "simdiki_zaman":
            let f = DateFormatter()
            f.locale = Locale(identifier: "tr_TR")
            f.dateFormat = "d MMMM yyyy EEEE, HH:mm"
            return Outcome(text: f.string(from: Date()), ok: true)

        case "beyin_baglam", "beyin_ara", "beyin_oku", "beyin_kaydet", "x_tarzi", "x_taslak_koy":
            return await BrainClient.run(call.name, a, maxChars: maxChars)

        case "beceri_oku":
            return SkillLibrary.read(name: a["ad"] ?? "", file: a["dosya"], maxChars: maxChars)

        case "dosya_listele":
            guard let url = resolve(a["klasor"] ?? ".", in: folder) else { return outside }
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                                       options: [.skipsHiddenFiles])) ?? []
            if items.isEmpty { return Outcome(text: L("Klasör boş ya da okunamadı."), ok: true) }
            let lines = items.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(200).map { u -> String in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return v?.isDirectory == true ? "\(u.lastPathComponent)/" : L("\(u.lastPathComponent) (\(v?.fileSize ?? 0) bayt)")
            }
            return Outcome(text: lines.joined(separator: "\n") + (items.count > 200 ? L("\n… ve \(items.count - 200) öğe daha") : ""), ok: true)

        case "dosya_oku":
            guard let url = resolve(a["yol"] ?? "", in: folder) else { return outside }
            guard let text = DocumentLoader.loadText(url, maxChars: maxChars + 1) else {
                return Outcome(text: L("Dosya okunamadı (yok, boş ya da metin değil)."), ok: false)
            }
            return Outcome(text: text.count > maxChars ? String(text.prefix(maxChars)) + L("\n[… dosyanın devamı kesildi]") : text, ok: true)

        case "dosya_yaz":
            guard let url = resolve(a["yol"] ?? "", in: folder) else { return outside }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (a["icerik"] ?? "").write(to: url, atomically: true, encoding: .utf8)
                return Outcome(text: L("Yazıldı: \(a["yol"] ?? "")"), ok: true)
            } catch { return Outcome(text: L("Yazılamadı: \(error.localizedDescription)"), ok: false) }

        case "komut_calistir":
            guard let folder else { return outside }
            return await shell(a["komut"] ?? "", in: folder, maxChars: maxChars)

        default:
            return Outcome(text: L("Böyle bir araç yok: \(call.name)"), ok: false)
        }
    }

    private static let outside = Outcome(text: L("Hata: yol çalışma klasörünün dışında ya da çalışma klasörü seçilmedi."), ok: false)

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
                cont.resume(returning: Outcome(text: L("Çalıştırılamadı: \(error.localizedDescription)"), ok: false)); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                var out = String(decoding: data, as: UTF8.self)
                if out.count > maxChars { out = String(out.prefix(maxChars)) + L("\n[… çıktı kesildi]") }
                let code = p.terminationStatus
                cont.resume(returning: Outcome(text: L("çıkış kodu \(code)\n") + (out.isEmpty ? L("(çıktı yok)") : out), ok: code == 0))
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
        guard p.i == p.chars.count else { throw Failure(errorDescription: L("ifade anlaşılamadı")) }
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
                if c != "*" && r == 0 { throw Failure(errorDescription: L("sıfıra bölme")) }
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
                guard peek() == ")" else { throw Failure(errorDescription: L("kapanmayan parantez")) }
                i += 1
                return v
            }
            skip()
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            guard start < i, let v = Double(String(chars[start..<i])) else { throw Failure(errorDescription: L("sayı bekleniyordu")) }
            return v
        }
    }
}
