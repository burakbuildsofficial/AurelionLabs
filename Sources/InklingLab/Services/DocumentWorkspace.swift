import Foundation
import Observation

/// Belge asistanı: klasör/dosya okur, uzun belgeleri bağlama sığan parçalara böler,
/// parça parça özetler (map-reduce) ya da soruya en ilgili parçaları bulup kaynaklı cevap üretir.
@MainActor
@Observable
final class DocumentWorkspace {
    struct Doc: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
        let text: String
        var approxTokens: Int { Int(Double(text.count) / 3.5) }
    }

    struct Chunk: Identifiable, Hashable {
        let id: Int            // kaynak numarası [1], [2]…
        let docName: String
        let part: Int
        let partCount: Int
        let text: String
    }

    enum Job: Equatable { case summary, answer(String) }

    private(set) var docs: [Doc] = []
    private(set) var skipped: [String] = []
    private(set) var running: Job?
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private(set) var step = ""
    private(set) var output = ""
    private(set) var reasoning = ""
    private(set) var sources: [Chunk] = []
    private(set) var error: String?
    private(set) var stats: GenStats?
    private var task: Task<Void, Never>?

    var question = ""
    private let server: ServerManager

    init(server: ServerManager) { self.server = server }

    var totalTokens: Int { docs.reduce(0) { $0 + $1.approxTokens } }
    var isRunning: Bool { running != nil }

    // MARK: Dosyalar

    static let maxFiles = 300
    static let maxCharsPerFile = 2_000_000

    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = walker?.nextObject() as? URL {
                    let n = f.lastPathComponent
                    if ["node_modules", "build", ".build", "Pods", "DerivedData"].contains(n) { walker?.skipDescendants(); continue }
                    if DocumentLoader.canLoad(f) { files.append(f) }
                    if files.count >= Self.maxFiles { break }
                }
            } else {
                files.append(url)
            }
        }
        for f in files where !docs.contains(where: { $0.path == f.path }) {
            if let text = DocumentLoader.loadText(f, maxChars: Self.maxCharsPerFile) {
                docs.append(Doc(name: f.lastPathComponent, path: f.path, text: text))
            } else {
                skipped.append(f.lastPathComponent)
            }
        }
    }

    func remove(_ d: Doc) { docs.removeAll { $0.id == d.id } }

    func clear() {
        stop()
        docs = []; skipped = []; output = ""; reasoning = ""; sources = []; error = nil; stats = nil
    }

    func stop() { task?.cancel() }

    // MARK: Bağlam bütçesi

    /// Açık modelin bağlamı (Atomic'te 4K).
    private var context: Int { server.runningConfig?.contextSize ?? server.config.contextSize }

    /// Tek istekte gönderilecek belge metni (token): düşünme + cevaba yer bırakır.
    private var inputBudget: Int { max(800, min(9000, context - 2600)) }

    private static func chars(_ tokens: Int) -> Int { Int(Double(tokens) * 3.3) }

    /// Metni paragraf sınırlarından, en fazla `maxChars` karakterlik parçalara böler.
    static func split(_ text: String, maxChars: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n") {
            if current.count + para.count + 1 > maxChars, !current.isEmpty {
                parts.append(current); current = ""
            }
            if para.count > maxChars {
                var rest = Substring(para)
                while rest.count > maxChars {
                    parts.append(String(rest.prefix(maxChars)))
                    rest = rest.dropFirst(maxChars)
                }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + para
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        return parts
    }

    // MARK: Özetleme (parça → belge → hepsi)

    func summarize(params: SamplingParams) {
        guard !isRunning, !docs.isEmpty, server.isUsable else { return }
        begin(.summary)
        let docs = self.docs
        let budget = inputBudget
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = docs.map { (doc: $0, parts: Self.split($0.text, maxChars: Self.chars(budget))) }
                let docsNeedingMerge = plan.filter { $0.parts.count > 1 }.count
                self.progress = (0, plan.reduce(0) { $0 + $1.parts.count } + docsNeedingMerge + (docs.count > 1 ? 1 : 0))
                var perDoc: [(String, String)] = []
                for (doc, parts) in plan {
                    var partSummaries: [String] = []
                    for (i, part) in parts.enumerated() {
                        try Task.checkCancellation()
                        self.step = parts.count > 1 ? "\(doc.name) · bölüm \(i + 1)/\(parts.count) özetleniyor" : "\(doc.name) özetleniyor"
                        let s = try await self.ask(
                            "Aşağıdaki metin \"\(doc.name)\" dosyasının \(parts.count > 1 ? "\(i + 1)/\(parts.count). bölümü" : "tamamı"). " +
                            "Önemli bilgileri, sayıları ve adları koruyarak Türkçe ve madde madde özetle. Yalnız metinde olanı yaz.\n\n<metin>\n\(part)\n</metin>",
                            params: params, maxTokens: 2500)
                        partSummaries.append(s)
                        self.progress.done += 1
                    }
                    var summary = partSummaries.first ?? ""
                    if partSummaries.count > 1 {
                        try Task.checkCancellation()
                        self.step = "\(doc.name) · bölüm özetleri birleştiriliyor"
                        summary = try await self.merge(partSummaries, title: doc.name, params: params, budget: budget)
                        self.progress.done += 1
                    }
                    perDoc.append((doc.name, summary))
                    self.output = perDoc.map { "## \($0.0)\n\n\($0.1)" }.joined(separator: "\n\n")
                }
                if perDoc.count > 1 {
                    try Task.checkCancellation()
                    self.step = "Genel özet yazılıyor"
                    let overall = try await self.merge(perDoc.map { "\($0.0): \($0.1)" }, title: "tüm belgeler", params: params, budget: budget)
                    self.progress.done += 1
                    self.output = "## Genel özet\n\n\(overall)\n\n" + perDoc.map { "## \($0.0)\n\n\($0.1)" }.joined(separator: "\n\n")
                }
                self.step = "Bitti"
            } catch is CancellationError {
                self.step = "Durduruldu"
            } catch let e as URLError where e.code == .cancelled {
                self.step = "Durduruldu"
            } catch {
                self.error = error.localizedDescription
            }
            self.running = nil
        }
    }

    /// Özetleri birleştirir; bağlama sığmazsa önce gruplar halinde birleştirir.
    private func merge(_ items: [String], title: String, params: SamplingParams, budget: Int) async throws -> String {
        var level = items
        while true {
            let joined = level.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
            if joined.count <= Self.chars(budget) || level.count == 1 {
                return try await ask(
                    "Aşağıda \"\(title)\" için parça özetleri var. Bunları tekrarsız, düzenli tek bir Türkçe özette birleştir: " +
                    "önce 2-3 cümlelik genel bakış, sonra en önemli maddeler.\n\n\(String(joined.prefix(Self.chars(budget))))",
                    params: params, maxTokens: 3000)
            }
            // Gruplara böl, her grubu ayrı birleştir.
            var groups: [[String]] = [[]]
            for it in level {
                if (groups.last!.joined().count + it.count) > Self.chars(budget), !groups.last!.isEmpty { groups.append([]) }
                groups[groups.count - 1].append(it)
            }
            var next: [String] = []
            for g in groups {
                try Task.checkCancellation()
                next.append(try await ask("Bu özetleri tek bir kısa özette birleştir:\n\n" + g.joined(separator: "\n\n"),
                                          params: params, maxTokens: 2000))
            }
            level = next
        }
    }

    // MARK: Soru-cevap (ilgili parçalar + kaynak)

    func answer(params: SamplingParams) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !docs.isEmpty, !q.isEmpty, server.isUsable else { return }
        begin(.answer(q))
        let budget = inputBudget
        let chunks = Self.chunks(docs, maxChars: 2400)
        let picked = Self.retrieve(q, from: chunks, maxChars: Self.chars(budget) - q.count - 400)
        sources = picked
        step = "\(chunks.count) bölüm içinden en ilgili \(picked.count) tanesi okunuyor"
        progress = (0, 1)
        let client = LLMClient(baseURL: server.baseURL)
        task = Task { [weak self] in
            guard let self else { return }
            let context = picked.map { "[\($0.id)] \($0.docName)" + ($0.partCount > 1 ? " · bölüm \($0.part)/\($0.partCount)" : "") + "\n\($0.text)" }
                .joined(separator: "\n\n")
            let prompt = "Aşağıdaki kaynaklara dayanarak soruyu Türkçe cevapla. Her bilginin sonuna dayandığı kaynağın numarasını " +
                "[1] gibi yaz. Kaynaklarda cevap yoksa bunu açıkça söyle, uydurma.\n\n<kaynaklar>\n\(context)\n</kaynaklar>\n\nSoru: \(q)"
            var p = params
            p.maxTokens = max(p.maxTokens, 3000)
            do {
                for try await event in client.stream(messages: [ChatMessage(role: .user, text: prompt)], params: p) {
                    switch event {
                    case .reasoning(let s): self.reasoning += s
                    case .content(let s): self.output += s
                    case .finished(let st): self.stats = st
                    }
                }
                self.progress.done = 1
                self.step = "Bitti"
                if self.output.isEmpty { self.error = "Cevap boş geldi: token sınırı düşünmeye gitti. Ön ayarda en fazla token'ı artır." }
            } catch is CancellationError {
                self.step = "Durduruldu"
            } catch let e as URLError where e.code == .cancelled {
                self.step = "Durduruldu"
            } catch {
                self.error = error.localizedDescription
            }
            self.running = nil
        }
    }

    static func chunks(_ docs: [Doc], maxChars: Int) -> [Chunk] {
        var out: [Chunk] = []
        var n = 1
        for d in docs {
            let parts = split(d.text, maxChars: maxChars)
            for (i, p) in parts.enumerated() {
                out.append(Chunk(id: n, docName: d.name, part: i + 1, partCount: parts.count, text: p))
                n += 1
            }
        }
        return out
    }

    /// Basit BM25: Türkçe küçük harf, noktalama yok, kelimenin ilk 5 harfi (ek farklarını yutmak için).
    static func retrieve(_ query: String, from chunks: [Chunk], maxChars: Int) -> [Chunk] {
        func terms(_ s: String) -> [String] {
            s.lowercased(with: Locale(identifier: "tr_TR"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
                .map { String($0.prefix(5)) }
        }
        let stop: Set<String> = ["bir", "bu", "ve", "ile", "için", "ne", "nedi", "nasıl", "neden", "hangi", "olan", "gibi", "daha", "kaç", "nerd"]
        let q = Set(terms(query)).subtracting(stop)
        guard !q.isEmpty else { return Array(chunks.prefix(3)) }
        let docs = chunks.map { terms($0.text) }
        let avg = Double(docs.reduce(0) { $0 + $1.count }) / Double(max(docs.count, 1))
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d) where q.contains(t) { df[t, default: 0] += 1 } }
        let N = Double(chunks.count)
        let scored = zip(chunks, docs).map { chunk, words -> (Chunk, Double) in
            var tf: [String: Int] = [:]
            for w in words where q.contains(w) { tf[w, default: 0] += 1 }
            var s = 0.0
            for (t, f) in tf {
                let idf = log(1 + (N - Double(df[t] ?? 0) + 0.5) / (Double(df[t] ?? 0) + 0.5))
                let ff = Double(f)
                s += idf * ff * 2.2 / (ff + 1.2 * (0.25 + 0.75 * Double(words.count) / max(avg, 1)))
            }
            return (chunk, s)
        }
        var picked: [Chunk] = []
        var used = 0
        for (c, s) in scored.sorted(by: { $0.1 > $1.1 }) where s > 0 {
            if used + c.text.count > maxChars { continue }
            picked.append(c); used += c.text.count
        }
        if picked.isEmpty { picked = Array(chunks.prefix(1)) }
        return picked.sorted { $0.id < $1.id }
    }

    // MARK: Yardımcılar

    private func begin(_ job: Job) {
        running = job
        output = ""; reasoning = ""; sources = []; error = nil; stats = nil; step = "Hazırlanıyor"
    }

    private func ask(_ prompt: String, params: SamplingParams, maxTokens: Int) async throws -> String {
        var p = params
        p.maxTokens = maxTokens
        let r = try await LLMClient(baseURL: server.baseURL).complete(messages: [ChatMessage(role: .user, text: prompt)], params: p)
        let text = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw NSError(domain: "Belge", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Model bir bölüm için boş cevap verdi (düşünmesi token sınırını doldurdu). Tekrar dene ya da daha düşük sıcaklıklı bir ön ayar seç."]) }
        return text
    }
}
