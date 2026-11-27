import SwiftUI

/// Sınır testleri: her testin istemi, isteğe bağlı resmi/araçları ve otomatik kontrolü var.
enum TestCategory: String, CaseIterable, Identifiable, Codable {
    case reasoning, instructions, turkish, code, vision, tools, agent, longContext
    var id: String { rawValue }

    var title: String {
        switch self {
        case .reasoning: L("Mantık ve matematik")
        case .instructions: L("Talimata uyma")
        case .turkish: L("Türkçe")
        case .code: L("Kod")
        case .vision: L("Görsel")
        case .tools: L("Araç kullanma")
        case .agent: L("Ajan (çok adımlı)")
        case .longContext: L("Uzun bağlam")
        }
    }

    var symbol: String {
        switch self {
        case .reasoning: "function"
        case .instructions: "list.bullet.clipboard"
        case .turkish: "character.bubble"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .vision: "eye"
        case .tools: "wrench.and.screwdriver"
        case .agent: "point.3.connected.trianglepath.dotted"
        case .longContext: "doc.text.magnifyingglass"
        }
    }
}

struct Verdict: Equatable {
    let passed: Bool
    let detail: String
}

/// Kontrolün gördüğü sonuç.
struct TestOutput {
    let content: String
    let toolCalls: [LLMClient.ToolCall]
    /// Ajan testlerinde: bütün adımlardaki araç çağrıları ve testin geçici çalışma klasörü.
    var allCalls: [LLMClient.ToolCall] = []
    var folder: URL? = nil
}

struct TestCase: Identifiable {
    let id: String
    let category: TestCategory
    let title: String
    let prompt: String
    var image: (@MainActor () -> NSImage?)?
    var usesTools = false
    /// Doluysa ajan testi: bu dosyalar geçici bir çalışma klasörüne yazılır, model gerçek araçlarla çok adımlı çalışır.
    var agentFiles: [String: String]? = nil
    var maxTokens = 3072
    /// Kontrol async olabilir (kod çalıştırma).
    let check: @Sendable (TestOutput) async -> Verdict
}

// MARK: Yardımcı kontroller

enum Checks {
    static func norm(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cevabın son kısmında beklenen sayının geçip geçmediği.
    static func number(_ expected: String) -> @Sendable (TestOutput) async -> Verdict {
        { out in
            let text = out.content
            let pattern = "(?<![0-9.,])" + NSRegularExpression.escapedPattern(for: expected) + "(?![0-9])"
            let ok = text.range(of: pattern, options: .regularExpression) != nil
            return Verdict(passed: ok, detail: ok ? L("Cevapta \(expected) var.") : L("Beklenen \(expected), cevapta yok."))
        }
    }

    static func containsAll(_ needles: [String]) -> @Sendable (TestOutput) async -> Verdict {
        { out in
            let t = norm(out.content)
            let missing = needles.filter { !t.contains(norm($0)) }
            return missing.isEmpty
                ? Verdict(passed: true, detail: L("Beklenen ifadeler var: \(needles.joined(separator: ", "))."))
                : Verdict(passed: false, detail: L("Eksik: \(missing.joined(separator: ", "))."))
        }
    }

    static func containsAny(_ needles: [String]) -> @Sendable (TestOutput) async -> Verdict {
        { out in
            let t = norm(out.content)
            let hit = needles.first { t.contains(norm($0)) }
            return Verdict(passed: hit != nil, detail: hit.map { L("Cevapta “\($0)” var.") }
                           ?? L("Şunlardan hiçbiri yok: \(needles.joined(separator: ", "))."))
        }
    }

    static func extractCode(_ text: String) -> String {
        if let r = text.range(of: "```(?:python|py)?\\s*\\n([\\s\\S]*?)```", options: .regularExpression) {
            var block = String(text[r])
            block = block.replacingOccurrences(of: "^```(?:python|py)?\\s*\\n", with: "", options: .regularExpression)
            block = block.replacingOccurrences(of: "```$", with: "", options: .regularExpression)
            return block
        }
        return text
    }

    /// Modelin yazdığı Python kodunu geçici klasörde, 10 sn sınırla, testlerle birlikte çalıştırır.
    static func python(tests: String) -> @Sendable (TestOutput) async -> Verdict {
        { out in
            let code = extractCode(out.content) + "\n\n# --- AurelionLabs testleri ---\n" + tests + "\nprint('TESTLER_GECTI')\n"
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aurelionlabs-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("cevap.py")
            do { try code.write(to: file, atomically: true, encoding: .utf8) } catch {
                return Verdict(passed: false, detail: "Kod dosyası yazılamadı.")
            }
            return await withCheckedContinuation { cont in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["python3", "-I", file.path]
                p.currentDirectoryURL = dir
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.terminationHandler = { proc in
                    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let ok = proc.terminationStatus == 0 && s.contains("TESTLER_GECTI")
                    let tail = s.split(separator: "\n").suffix(3).joined(separator: " ")
                    cont.resume(returning: Verdict(passed: ok, detail: ok ? "Kod çalıştı, tüm testler geçti."
                                                   : L("Kod testleri geçemedi: \(tail.prefix(240))")))
                }
                do { try p.run() } catch {
                    cont.resume(returning: Verdict(passed: false, detail: "python3 çalıştırılamadı."))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
            }
        }
    }

    static func toolCall(_ name: String, argsContain: [String]) -> @Sendable (TestOutput) async -> Verdict {
        { out in
            guard let call = out.toolCalls.first(where: { $0.name == name }) else {
                let names = out.toolCalls.map(\.name)
                return Verdict(passed: false, detail: names.isEmpty
                               ? "Araç çağırmadı, doğrudan cevap verdi."
                               : L("Yanlış araç çağırdı: \(names.joined(separator: ", "))."))
            }
            let args = norm(call.arguments)
            let missing = argsContain.filter { !args.contains(norm($0)) }
            return missing.isEmpty
                ? Verdict(passed: true, detail: L("\(name)(\(call.arguments)) çağırdı."))
                : Verdict(passed: false, detail: L("\(name) çağırdı ama argüman eksik: \(call.arguments)"))
        }
    }

    /// Ajan testi: belirtilen aracı (adı önekle eşleşebilir) herhangi bir adımda, argümanında ifadelerle çağırdı mı.
    static func called(_ out: TestOutput, _ name: String, argsContain: [String] = []) -> Bool {
        out.allCalls.contains { c in
            c.name == name && argsContain.allSatisfy { norm(c.arguments).contains(norm($0)) }
        }
    }

    static func callList(_ out: TestOutput) -> String {
        out.allCalls.isEmpty ? "hiç araç çağırmadı" : out.allCalls.map(\.name).joined(separator: " → ")
    }

    static func fileText(_ out: TestOutput, _ path: String) -> String? {
        guard let f = out.folder else { return nil }
        return try? String(contentsOf: f.appendingPathComponent(path), encoding: .utf8)
    }
}

// MARK: Test listesi

enum TestSuite {
    nonisolated(unsafe) static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "hava_durumu",
            "description": "Bir şehrin güncel hava durumunu getirir.",
            "parameters": ["type": "object",
                           "properties": ["sehir": ["type": "string", "description": "Şehir adı"]],
                           "required": ["sehir"]]]],
        ["type": "function", "function": [
            "name": "hesapla",
            "description": "Bir matematik ifadesini kesin olarak hesaplar.",
            "parameters": ["type": "object",
                           "properties": ["ifade": ["type": "string", "description": "Örn: 12*(3+4)"]],
                           "required": ["ifade"]]]],
        ["type": "function", "function": [
            "name": "takvime_ekle",
            "description": "Takvime etkinlik ekler.",
            "parameters": ["type": "object",
                           "properties": ["baslik": ["type": "string"],
                                          "tarih": ["type": "string", "description": "YYYY-AA-GG"],
                                          "saat": ["type": "string", "description": "SS:DD"]],
                           "required": ["baslik", "tarih"]]]],
    ]

    /// Uzun bağlam testleri sunucunun bağlam boyutuna göre ölçeklenir.
    static func all(contextSize: Int) -> [TestCase] {
        var t: [TestCase] = []

        // Mantık ve matematik
        t.append(TestCase(id: "r1", category: .reasoning, title: L("Bacak sayısı"),
                          prompt: "Bir çiftlikte 15 tavuk ve 12 inek var. Toplam kaç bacak vardır? Son satırda sadece sayıyı yaz.",
                          check: Checks.number("78")))
        t.append(TestCase(id: "r2", category: .reasoning, title: L("Denklem"),
                          prompt: "Bir sayının 3 katının 7 fazlası 52 ise bu sayı kaçtır? Son satırda sadece sayıyı yaz.",
                          check: Checks.number("15")))
        t.append(TestCase(id: "r3", category: .reasoning, title: L("Saat hesabı"),
                          prompt: "Bir tren 14:35'te kalkıyor ve yolculuk 3 saat 50 dakika sürüyor. Tren saat kaçta varır? Sadece SS:DD biçiminde yaz.",
                          check: Checks.containsAny(["18:25"])))
        t.append(TestCase(id: "r4", category: .reasoning, title: L("Harf sayma"),
                          prompt: "\"mississippi\" kelimesinde kaç tane 's' harfi var? Son satırda sadece sayıyı yaz.",
                          check: Checks.number("4")))
        t.append(TestCase(id: "r5", category: .reasoning, title: L("Takvim"),
                          prompt: "23 Kasım 2026 Pazartesi günüdür. Bu tarihten 100 gün sonra haftanın hangi günüdür? Sadece gün adını yaz.",
                          check: Checks.containsAny(["çarşamba"])))
        t.append(TestCase(id: "r6", category: .reasoning, title: L("Tuzaklı soru"),
                          prompt: "Bir sopa ve bir top birlikte 110 TL. Sopa toptan 100 TL daha pahalı. Top kaç TL? Son satırda sadece sayıyı yaz.",
                          check: Checks.number("5")))

        // Talimata uyma
        t.append(TestCase(id: "i1", category: .instructions, title: L("Tam 3 madde"),
                          prompt: "Sağlıklı uyku için tam olarak 3 öneri yaz. Her satır \"- \" ile başlasın. Başlık, giriş veya kapanış cümlesi yazma.",
                          check: { out in
                              let lines = out.content.split(whereSeparator: \.isNewline)
                                  .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                              let ok = lines.count == 3 && lines.allSatisfy { $0.hasPrefix("- ") }
                              return Verdict(passed: ok, detail: ok ? "Tam 3 madde, fazladan satır yok."
                                             : "\(lines.count) dolu satır var; hepsi \"- \" ile başlamalı ve tam 3 olmalı.")
                          }))
        t.append(TestCase(id: "i2", category: .instructions, title: L("Sadece JSON"),
                          prompt: "Ankara hakkında yalnızca geçerli bir JSON nesnesi döndür. Alanlar: \"sehir\" (metin), \"plaka\" (sayı), \"baskent_mi\" (true/false). Kod bloğu ya da açıklama yazma.",
                          check: { out in
                              let s = out.content.trimmingCharacters(in: .whitespacesAndNewlines)
                              guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
                                  return Verdict(passed: false, detail: "Cevap tek başına geçerli JSON değil.")
                              }
                              let ok = (obj["plaka"] as? Int) == 6 && (obj["baskent_mi"] as? Bool) == true && obj["sehir"] is String
                              return Verdict(passed: ok, detail: ok ? "Geçerli JSON, alanlar doğru."
                                             : "JSON geçerli ama alanlar yanlış: \(s.prefix(160))")
                          }))
        t.append(TestCase(id: "i3", category: .instructions, title: L("Büyük harf"),
                          prompt: "Türkiye'nin başkenti neresidir? Cevabının tamamını BÜYÜK HARFLERLE ve tek kelimeyle yaz.",
                          check: { out in
                              let s = out.content.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                              let ok = s == "ANKARA"
                              return Verdict(passed: ok, detail: ok ? "Tam olarak ANKARA yazdı." : "Beklenen “ANKARA”, gelen “\(s.prefix(60))”.")
                          }))
        t.append(TestCase(id: "i4", category: .instructions, title: L("Kelime sınırı"),
                          prompt: "Yapay zekâyı en fazla 12 kelimeyle tanımla. Tek cümle yaz.",
                          check: { out in
                              let n = out.content.split(whereSeparator: { $0.isWhitespace }).count
                              return Verdict(passed: n > 0 && n <= 12, detail: "\(n) kelime yazdı (en fazla 12).")
                          }))

        // Türkçe
        t.append(TestCase(id: "t1", category: .turkish, title: L("Deyim"),
                          prompt: "\"Etekleri zil çalmak\" deyimi ne anlama gelir? Tek cümleyle açıkla.",
                          check: Checks.containsAny(["sevin", "mutlu", "neşe", "keyif"])))
        t.append(TestCase(id: "t2", category: .turkish, title: L("Çeviri"),
                          prompt: "Translate into natural Turkish, output only the translation: \"The cat is sleeping on the warm windowsill.\"",
                          check: Checks.containsAll(["kedi", "uyu", "pencere"])))
        t.append(TestCase(id: "t3", category: .turkish, title: L("Ünlü uyumu"),
                          prompt: "\"kitap\" kelimesinin çoğul ve belirtme hâli (-ları/-leri) eklenmiş biçimini yaz. Sadece kelimeyi yaz.",
                          check: Checks.containsAny(["kitapları"])))

        // Kod
        t.append(TestCase(id: "c1", category: .code, title: L("Asal sayı"),
                          prompt: "Python'da is_prime(n) fonksiyonu yaz. n tam sayıdır, 2'den küçükse False döner. Sadece kodu bir ```python bloğunda ver.",
                          check: Checks.python(tests: """
                          assert [n for n in range(30) if is_prime(n)] == [2,3,5,7,11,13,17,19,23,29]
                          assert is_prime(7919) and not is_prime(7917) and not is_prime(-7) and not is_prime(1)
                          """)))
        t.append(TestCase(id: "c2", category: .code, title: L("Parantez dengesi"),
                          prompt: "Python'da balanced(s) fonksiyonu yaz: s içindeki (), [], {} parantezleri doğru açılıp kapanıyorsa True döndürsün; diğer karakterleri yok saysın. Sadece kodu bir ```python bloğunda ver.",
                          check: Checks.python(tests: """
                          assert balanced("") and balanced("a(b[c]{d}e)f") and balanced("{[()()]}")
                          assert not balanced("(]") and not balanced("([)]") and not balanced("((") and not balanced(")(")
                          """)))
        t.append(TestCase(id: "c3", category: .code, title: L("Roma rakamı"),
                          prompt: "Python'da to_roman(n) fonksiyonu yaz (1 ≤ n ≤ 3999), Roma rakamını metin olarak döndürsün. Sadece kodu bir ```python bloğunda ver.",
                          check: Checks.python(tests: """
                          assert to_roman(1) == "I" and to_roman(4) == "IV" and to_roman(9) == "IX"
                          assert to_roman(1994) == "MCMXCIV" and to_roman(2026) == "MMXXVI" and to_roman(3999) == "MMMCMXCIX"
                          """)))

        // Görsel (resimler uygulamada çizilir, cevap kesin bilinir)
        t.append(TestCase(id: "v1", category: .vision, title: L("Yazı okuma"),
                          prompt: "Resimdeki etiket kodunu aynen yaz. Sadece kodu yaz.",
                          image: { TestImages.label() },
                          check: Checks.containsAll(["7429", "alfa"])))
        t.append(TestCase(id: "v2", category: .vision, title: L("Sayma"),
                          prompt: "Resimde kaç tane kırmızı daire var? Son satırda sadece sayıyı yaz.",
                          image: { TestImages.shapes() },
                          check: Checks.number("5")))
        t.append(TestCase(id: "v3", category: .vision, title: L("Grafik okuma"),
                          prompt: "Bu çubuk grafikte en yüksek değere sahip ay hangisi? Sadece ay adını yaz.",
                          image: { TestImages.chart() },
                          check: Checks.containsAny(["mart"])))
        t.append(TestCase(id: "v4", category: .vision, title: L("Tablo okuma"),
                          prompt: "Tabloya göre 2 kahve ve 1 poğaçanın toplam fiyatı kaç TL? Son satırda sadece sayıyı yaz.",
                          image: { TestImages.table() },
                          check: Checks.number("115")))

        // Araç kullanma
        t.append(TestCase(id: "a1", category: .tools, title: L("Doğru aracı seçme"),
                          prompt: "İzmir'de şu an hava nasıl?",
                          usesTools: true, check: Checks.toolCall("hava_durumu", argsContain: ["izmir"])))
        t.append(TestCase(id: "a2", category: .tools, title: L("Hesap aracı"),
                          prompt: "48271 ile 9133'ü çarpıp sonuca 17 ekle. Kesin sonuç lazım.",
                          usesTools: true, check: Checks.toolCall("hesapla", argsContain: ["48271", "9133", "17"])))
        t.append(TestCase(id: "a3", category: .tools, title: L("Argüman çıkarma"),
                          prompt: "Bugün 23 Kasım 2026. Yarın öğleden sonra 3'te diş hekimi randevum var, takvimime ekler misin?",
                          usesTools: true, check: Checks.toolCall("takvime_ekle", argsContain: ["2026-11-24", "15:00"])))
        t.append(TestCase(id: "a4", category: .tools, title: L("Gereksiz araç kullanmama"),
                          prompt: "Merhaba! Bana kısa bir günaydın mesajı yazar mısın?",
                          usesTools: true, check: { out in
                              Verdict(passed: out.toolCalls.isEmpty && !out.content.isEmpty,
                                      detail: out.toolCalls.isEmpty ? "Araç çağırmadan cevap verdi."
                                      : "Gereksiz yere \(out.toolCalls.map(\.name).joined(separator: ", ")) çağırdı.")
                          }))

        // Ajan (çok adımlı): gerçek araçlar, geçici klasör. Beyin araçları testte sahte cevap verir, kasaya yazılmaz.
        t.append(TestCase(id: "g1", category: .agent, title: L("Dosyadan bilgi bulma"),
                          prompt: "Çalışma klasöründeki notlar.txt dosyasında toplantı kodu yazıyor. Kod nedir? Sadece kodu yaz.",
                          agentFiles: ["notlar.txt": "Alışveriş: süt, ekmek\nToplantı kodu: KESTANE-42\nAra: Mehmet"],
                          maxTokens: 4096, check: { out in
                              let ok = Checks.called(out, "dosya_oku") && Checks.norm(out.content).contains("kestane-42")
                              return Verdict(passed: ok, detail: ok ? "Dosyayı okudu, kodu buldu." : "Adımlar: \(Checks.callList(out)).")
                          }))
        t.append(TestCase(id: "g2", category: .agent, title: L("Klasörde dosya arama"),
                          prompt: "Çalışma klasöründe projenin ayar dosyası bir yerde duruyor. Bul ve hangi portu kullandığını söyle. Son satırda sadece port numarasını yaz.",
                          agentFiles: ["README.md": "Deneme projesi.", "kaynak/main.py": "print('merhaba')",
                                       "kaynak/ayarlar/sunucu.json": "{\"host\": \"127.0.0.1\", \"port\": 8123}"],
                          maxTokens: 4096, check: { out in
                              let ok = Checks.called(out, "dosya_oku", argsContain: ["sunucu.json"]) && out.content.contains("8123")
                              return Verdict(passed: ok, detail: ok ? "Klasörü gezip ayar dosyasını buldu." : "Adımlar: \(Checks.callList(out)).")
                          }))
        t.append(TestCase(id: "g3", category: .agent, title: L("Oku, hesapla, yaz"),
                          prompt: "satislar.csv dosyasındaki adet sütununun toplamını bul ve sonucu toplam.txt dosyasına sadece sayı olarak yaz.",
                          agentFiles: ["satislar.csv": "urun,adet\nkalem,17\ndefter,42\nsilgi,8\ncetvel,25\n"],
                          maxTokens: 4096, check: { out in
                              let f = Checks.fileText(out, "toplam.txt")?.trimmingCharacters(in: .whitespacesAndNewlines)
                              return Verdict(passed: f == "92", detail: f == nil ? "toplam.txt yazılmadı. Adımlar: \(Checks.callList(out))."
                                             : f == "92" ? "toplam.txt = 92." : "toplam.txt içeriği \"\(f!.prefix(40))\", beklenen 92.")
                          }))
        t.append(TestCase(id: "g4", category: .agent, title: L("Dosya düzenleme"),
                          prompt: "ayar.txt dosyasında tema satırını koyu olarak değiştir. Diğer satırlara dokunma.",
                          agentFiles: ["ayar.txt": "dil=tr\ntema=acik\nboyut=14\n"],
                          maxTokens: 4096, check: { out in
                              let f = Checks.fileText(out, "ayar.txt") ?? ""
                              let lines = f.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                              let ok = lines.contains("tema=koyu") && lines.contains("dil=tr") && lines.contains("boyut=14") && lines.count == 3
                              return Verdict(passed: ok, detail: ok ? "Yalnız tema satırını değiştirdi." : "ayar.txt: \(f.replacingOccurrences(of: "\n", with: " ⏎ "))")
                          }))
        t.append(TestCase(id: "g5", category: .agent, title: L("Adı verilen beceriyi kullanma"),
                          prompt: "scrapling-official becerisinin talimatına bak: bir web sayfasını Markdown dosyasına kaydetmek için hangi komutu, hangi zorunlu seçenekle kullanmalıyım? Tek satır komut yaz.",
                          agentFiles: [:], maxTokens: 6144, check: { out in
                              let used = Checks.called(out, "beceri_oku", argsContain: ["scrapling"])
                              let ok = used && Checks.norm(out.content).contains("--ai-targeted")
                              return Verdict(passed: ok, detail: !used ? "Beceriyi açmadı. Adımlar: \(Checks.callList(out))."
                                             : ok ? "Beceriyi okudu, zorunlu --ai-targeted seçeneğini buldu." : "Beceriyi okudu ama --ai-targeted yok.")
                          }))
        t.append(TestCase(id: "g6", category: .agent, title: L("Uygun beceriyi kendi seçme"),
                          prompt: "Three.js sahnemde gölgelerde çizgili lekeler (shadow acne) çıkıyor. Kurulu becerilerden uygun olanına bakarak nasıl düzelteceğimi kısaca söyle.",
                          agentFiles: [:], maxTokens: 6144, check: { out in
                              let ok = Checks.called(out, "beceri_oku", argsContain: ["threejs-lighting"]) && Checks.norm(out.content).contains("bias")
                              return Verdict(passed: ok, detail: ok ? "threejs-lighting becerisini seçti, bias ayarını söyledi." : "Adımlar: \(Checks.callList(out)).")
                          }))
        t.append(TestCase(id: "g7", category: .agent, title: L("Beyin'den hatırlama"),
                          prompt: "Inkling IQ3_XXS modeli 16K bağlamda testlerde kaç puan almıştı? Benim notlarıma bak.",
                          agentFiles: [:], maxTokens: 4096, check: { out in
                              let ok = Checks.called(out, "beyin_ara") && out.content.contains("25/27")
                              return Verdict(passed: ok, detail: ok ? "Beyin'de aradı, 25/27'yi buldu." : "Adımlar: \(Checks.callList(out)).")
                          }))
        t.append(TestCase(id: "g8", category: .agent, title: L("Beyin'e kaydetme"),
                          prompt: "Bugün Bonsai 2.5 27B modelini indirdim, Q2_0 dosyası 7,67 GB. Bunu notlarıma proje olarak kaydet.",
                          agentFiles: [:], maxTokens: 4096, check: { out in
                              let ok = Checks.called(out, "beyin_kaydet", argsContain: ["bonsai", "7,67"])
                                  || Checks.called(out, "beyin_kaydet", argsContain: ["bonsai", "7.67"])
                              return Verdict(passed: ok, detail: ok ? "beyin_kaydet ile rakamıyla kaydetti." : "Adımlar: \(Checks.callList(out)).")
                          }))

        // Uzun bağlam: samanlıkta iğne
        for (i, frac) in [0.25, 0.5, 0.75].enumerated() {
            let tokens = Int(Double(contextSize) * frac)
            let hay = Haystack.make(approxTokens: tokens, needleAt: [0.2, 0.5, 0.8][i])
            t.append(TestCase(id: "l\(i + 1)", category: .longContext,
                              title: L("Samanlıkta iğne · ~\(tokens / 1000)K token"),
                              prompt: hay.text + "\n\nYukarıdaki metinde gizli kasa şifresi geçiyor. Şifre nedir? Sadece şifreyi yaz.",
                              maxTokens: 4096,
                              check: Checks.containsAll([hay.secret])))
        }
        return t
    }
}

/// Uzun bağlam için dolgu metni ve gizli bilgi.
enum Haystack {
    private static let sentences = [
        "Kasabanın pazarı her salı sabahı erkenden kurulur ve öğlene kadar kalabalık olur.",
        "Dağ yolunda yürüyen gezginler, çam ağaçlarının arasından denizi görebildiklerini anlatır.",
        "Eski kütüphanede tozlu raflar arasında yüzyıllık haritalar saklanmaktadır.",
        "Belediye, nehir kenarındaki parka yeni oturma alanları yapılacağını duyurdu.",
        "Fırıncı her gün dört yüz ekmek pişirir ve ilk tepsi şafak sökmeden çıkar.",
        "Sonbaharda bağlarda üzüm toplanır, akşamları köy meydanında sohbet edilir.",
        "Liman işçileri yükleri gemilere taşırken martılar çevrede dolaşır.",
        "Okulun bahçesindeki çınar ağacı, kasabadaki en yaşlı ağaç olarak bilinir.",
    ]

    static func make(approxTokens: Int, needleAt: Double) -> (text: String, secret: String) {
        let secret = "MAVİ-\(Int.random(in: 1000...9999))-KUŞ"
        let needle = "Not: Gizli kasa şifresi \(secret) olarak belirlendi, kimseyle paylaşma."
        // Türkçe metinde kabaca 1 token ≈ 3,5 karakter.
        let targetChars = Int(Double(approxTokens) * 3.5)
        var parts: [String] = []
        var count = 0, i = 0
        while count < targetChars {
            let s = "\(i + 1). " + sentences[i % sentences.count]
            parts.append(s); count += s.count + 1; i += 1
        }
        parts.insert(needle, at: Int(Double(parts.count) * needleAt))
        return (parts.joined(separator: " "), secret)
    }
}

/// Testlerde kullanılan, cevabı kesin bilinen resimler.
@MainActor
enum TestImages {
    static func render<V: View>(_ v: V, size: CGSize) -> NSImage? {
        let r = ImageRenderer(content: v.frame(width: size.width, height: size.height).background(Color.white))
        r.scale = 2
        return r.nsImage
    }

    static func label() -> NSImage? {
        render(VStack(spacing: 12) {
            Text("Depo etiketi").font(.system(size: 22, weight: .medium)).foregroundStyle(.gray)
            Text("KOD: 7429-ALFA").font(.system(size: 44, weight: .bold, design: .monospaced))
            Text("Raf B3 · Kırılabilir").font(.system(size: 20)).foregroundStyle(.gray)
        }
        .padding(30)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black, lineWidth: 3)), size: CGSize(width: 560, height: 280))
    }

    static func shapes() -> NSImage? {
        let red: [CGPoint] = [.init(x: 70, y: 80), .init(x: 300, y: 60), .init(x: 480, y: 150), .init(x: 160, y: 260), .init(x: 390, y: 300)]
        let blue: [CGPoint] = [.init(x: 200, y: 140), .init(x: 520, y: 290), .init(x: 80, y: 330)]
        let green: [CGPoint] = [.init(x: 320, y: 190), .init(x: 560, y: 60)]
        return render(ZStack(alignment: .topLeading) {
            ForEach(red.indices, id: \.self) { i in Circle().fill(.red).frame(width: 60, height: 60).position(red[i]) }
            ForEach(blue.indices, id: \.self) { i in Rectangle().fill(.blue).frame(width: 55, height: 55).position(blue[i]) }
            ForEach(green.indices, id: \.self) { i in Circle().fill(.green).frame(width: 50, height: 50).position(green[i]) }
        }, size: CGSize(width: 620, height: 400))
    }

    static func chart() -> NSImage? {
        let data: [(String, Double)] = [("Ocak", 42), ("Şubat", 58), ("Mart", 91), ("Nisan", 67), ("Mayıs", 74)]
        return render(VStack(alignment: .leading, spacing: 10) {
            Text("Aylık satış (adet)").font(.system(size: 22, weight: .bold))
            HStack(alignment: .bottom, spacing: 22) {
                ForEach(data, id: \.0) { m in
                    VStack(spacing: 6) {
                        Text("\(Int(m.1))").font(.system(size: 16, weight: .semibold))
                        Rectangle().fill(Color(red: 0.36, green: 0.25, blue: 0.84)).frame(width: 64, height: m.1 * 2.6)
                        Text(m.0).font(.system(size: 16))
                    }
                }
            }
        }.padding(24), size: CGSize(width: 520, height: 380))
    }

    static func table() -> NSImage? {
        let rows = [("Çay", 20), ("Kahve", 45), ("Poğaça", 25), ("Simit", 15)]
        return render(VStack(alignment: .leading, spacing: 0) {
            Text("Kafe fiyat listesi").font(.system(size: 22, weight: .bold)).padding(.bottom, 12)
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).font(.system(size: 20))
                    Spacer()
                    Text("\(r.1) TL").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                }
                .padding(.vertical, 10)
                Divider()
            }
        }.padding(28), size: CGSize(width: 420, height: 330))
    }
}
