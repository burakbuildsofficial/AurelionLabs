import Foundation
import Observation

/// Sınır testlerini sırayla çalıştırır, sonuçları model adıyla kaydeder.
@MainActor
@Observable
final class TestRunner {
    enum Status: Equatable { case idle, running, passed, failed, error }

    struct Result: Identifiable {
        let id: String
        var status: Status = .idle
        var answer = ""
        var reasoning = ""
        var toolCalls: [LLMClient.ToolCall] = []
        var verdict: Verdict?
        var error: String?
        var stats: GenStats?
    }

    /// Kaydedilen özet: hangi modelde kaç test geçti.
    struct RunSummary: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let model: String
        let contextSize: Int
        let preset: String
        let passed: Int
        let total: Int
        let byCategory: [String: [Int]]   // kategori: [geçen, toplam]
        let avgTokensPerSecond: Double
        let failedTests: [String]
    }

    private let server: ServerManager
    private(set) var tests: [TestCase] = []
    private(set) var results: [String: Result] = [:]
    private(set) var isRunning = false
    private(set) var currentID: String?
    private(set) var history: [RunSummary] = []
    var params = SamplingParams.recommended
    var presetName = "Önerilen"
    /// Uzun düşünen modeller için: her testin çıktı sınırı en az bu kadar olur (0 = testin kendi sınırı).
    var minTokens = 0
    private var task: Task<Void, Never>?

    init(server: ServerManager) {
        self.server = server
        rebuild()
        history = (try? Data(contentsOf: Self.historyURL))
            .flatMap { try? Self.decoder.decode([RunSummary].self, from: $0) } ?? []
    }

    func rebuild() {
        guard !isRunning else { return }
        // Resim desteği olmayan modelde (ör. Atomic Engine) görsel testler haksız "kaldı" sayılmasın diye atlanır.
        tests = TestSuite.all(contextSize: server.runningConfig?.contextSize ?? server.config.contextSize)
            .filter { $0.image == nil || server.imagesAvailable }
        results = Dictionary(uniqueKeysWithValues: tests.map { ($0.id, Result(id: $0.id)) })
    }

    var finished: [Result] { results.values.filter { [.passed, .failed, .error].contains($0.status) } }
    var passedCount: Int { results.values.filter { $0.status == .passed }.count }

    func score(_ c: TestCategory) -> (passed: Int, done: Int, total: Int) {
        let ids = tests.filter { $0.category == c }.map(\.id)
        let rs = ids.compactMap { results[$0] }
        return (rs.filter { $0.status == .passed }.count,
                rs.filter { [.passed, .failed, .error].contains($0.status) }.count, ids.count)
    }

    // MARK: Çalıştırma

    func runAll(only category: TestCategory? = nil) {
        guard !isRunning, server.isUsable else { return }
        rebuild()
        let list = tests.filter { category == nil || $0.category == category }
        start(list, recordSummary: category == nil)
    }

    func runOne(_ id: String) {
        guard !isRunning, server.isUsable, let t = tests.first(where: { $0.id == id }) else { return }
        start([t], recordSummary: false)
    }

    func stop() { task?.cancel() }

    private func start(_ list: [TestCase], recordSummary: Bool) {
        isRunning = true
        let client = LLMClient(baseURL: server.baseURL)
        let base = params
        task = Task { [weak self] in
            for t in list {
                guard let self, !Task.isCancelled else { break }
                await self.execute(t, client: client, base: base)
            }
            guard let self else { return }
            self.currentID = nil
            self.isRunning = false
            if recordSummary && !Task.isCancelled { self.saveSummary() }
        }
    }

    private func execute(_ t: TestCase, client: LLMClient, base: SamplingParams) async {
        currentID = t.id
        results[t.id] = Result(id: t.id, status: .running)
        var p = base
        p.maxTokens = max(t.maxTokens, minTokens)
        var images: [ImageAttachment] = []
        if let make = t.image, let img = make(), let att = ImageLoader.attachment(from: img) { images = [att] }
        if t.image != nil && images.isEmpty {
            results[t.id]?.status = .error
            results[t.id]?.error = L("Test resmi oluşturulamadı.")
            return
        }
        if t.image != nil && !server.imagesAvailable {
            results[t.id]?.status = .error
            results[t.id]?.error = L("Resim desteği kapalı. Sunucu bölümünden açıp yeniden başlat.")
            return
        }
        if let files = t.agentFiles {
            await executeAgent(t, files: files, client: client, params: p)
            return
        }
        let msg = ChatMessage(role: .user, text: t.prompt, images: images)
        do {
            let toolsJSON = t.usesTools ? try? JSONSerialization.data(withJSONObject: TestSuite.tools) : nil
            let out = try await client.complete(messages: [msg], params: p, toolsJSON: toolsJSON)
            var r = Result(id: t.id, answer: out.content, reasoning: out.reasoning, toolCalls: out.toolCalls, stats: out.stats)
            var verdict = await t.check(TestOutput(content: out.content, toolCalls: out.toolCalls))
            // Cevap boşsa ve token sınırı dolduysa sebep büyük ihtimalle uzun düşünmedir; bunu açıkça söyle.
            if !verdict.passed && out.content.isEmpty && out.toolCalls.isEmpty && out.stats.generatedTokens >= p.maxTokens - 1 {
                verdict = Verdict(passed: false, detail: L("Cevap boş: \(p.maxTokens) token'lık sınırın tamamı düşünmeye gitti."))
            }
            r.verdict = verdict
            r.status = verdict.passed ? .passed : .failed
            results[t.id] = r
        } catch is CancellationError {
            results[t.id] = Result(id: t.id)
        } catch let e as URLError where e.code == .cancelled {
            results[t.id] = Result(id: t.id)
        } catch {
            results[t.id]?.status = .error
            results[t.id]?.error = error.localizedDescription
        }
    }

    // MARK: Ajan testi

    static let agentMaxSteps = 8

    /// Uygulamadaki ajan döngüsünün aynısı, ama geçici klasörde ve onaysız: dosya yazma serbest (klasör testin),
    /// komut çalıştırma kapalı, Beyin araçları sahte cevap verir (gerçek kasaya yazılmaz).
    private func executeAgent(_ t: TestCase, files: [String: String], client: LLMClient, params: SamplingParams) async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurelionlabs-test-\(t.id)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            for (path, text) in files {
                let u = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: u, atomically: true, encoding: .utf8)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            results[t.id]?.status = .error; results[t.id]?.error = L("Test klasörü kurulamadı: \(error.localizedDescription)"); return
        }
        let ctx = server.runningConfig?.contextSize ?? server.config.contextSize
        let maxChars = max(1500, min(20_000, Int(Double(ctx) * 3.3 * 0.35)))
        let tools = AgentTools.definitions(hasFolder: true, hasBrain: true)
        var messages = [ChatMessage(role: .user, text: t.prompt)]
        var all: [LLMClient.ToolCall] = []
        var total = GenStats()
        var decodeSeconds = 0.0
        var repairs = 0
        var final = ""
        var reasoning = ""
        do {
            for _ in 1...Self.agentMaxSteps {
                let r = try await client.complete(messages: messages, params: params, toolsJSON: tools)
                total.generatedTokens += r.stats.generatedTokens
                total.totalSeconds += r.stats.totalSeconds
                if r.stats.generatedPerSecond > 0 { decodeSeconds += Double(r.stats.generatedTokens) / r.stats.generatedPerSecond }
                reasoning += r.reasoning
                if r.toolCalls.isEmpty { final = r.content; break }
                all += r.toolCalls
                var ask = ChatMessage(role: .assistant, text: r.content)
                ask.toolCalls = r.toolCalls.map { ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments) }
                messages.append(ask)
                let schema = ToolRepair.schema(tools)
                for var c in ask.toolCalls! {
                    let out: String
                    if let problem = ToolRepair.check(&c, schema: schema) { out = problem; repairs += 1 }
                    else { out = await Self.testTool(c, folder: folder, maxChars: maxChars) }
                    var m = ChatMessage(role: .tool, text: out)
                    m.toolCallID = c.id; m.toolName = c.name
                    messages.append(m)
                }
            }
            if decodeSeconds > 0 { total.generatedPerSecond = Double(total.generatedTokens) / decodeSeconds }
            let verdict = await t.check(TestOutput(content: final, toolCalls: all, allCalls: all, folder: folder))
            var res = Result(id: t.id, answer: final, reasoning: reasoning, toolCalls: all, stats: total)
            res.verdict = final.isEmpty && !verdict.passed
                ? Verdict(passed: false, detail: verdict.detail + L(" (\(Self.agentMaxSteps) adımda son cevap gelmedi)")) : verdict
            if repairs > 0 { res.verdict = Verdict(passed: res.verdict!.passed, detail: res.verdict!.detail + L(" · \(repairs) bozuk çağrı geri çevrildi")) }
            res.status = verdict.passed ? .passed : .failed
            results[t.id] = res
        } catch is CancellationError {
            results[t.id] = Result(id: t.id)
        } catch let e as URLError where e.code == .cancelled {
            results[t.id] = Result(id: t.id)
        } catch {
            results[t.id]?.status = .error
            results[t.id]?.error = error.localizedDescription
        }
    }

    private static func testTool(_ c: ToolCallRecord, folder: URL, maxChars: Int) async -> String {
        let a = AgentTools.args(c.arguments)
        switch c.name {
        case "komut_calistir":
            return "Testte komut çalıştırma kapalı. Dosya araçlarıyla devam et."
        case "beyin_baglam":
            return "Kullanıcı: yapay zeka videoları ve yerel model denemeleri. Son iş: AurelionLabs."
        case "beyin_ara":
            return "• AurelionLabs — Projeler/inkling-lab.md\n  16K bağlam: IQ3_XXS testlerin 25/27'si, 17–21 t/s; IQ4_XS 24/27, 10–14 t/s."
        case "beyin_oku":
            return "# AurelionLabs\n16K bağlam: IQ3_XXS testlerin 25/27'si, 17–21 t/s; IQ4_XS 24/27, 10–14 t/s."
        case "beyin_kaydet":
            return "Kaydedildi: Projeler/\(a["baslik"] ?? "not").md (test, kasaya yazılmadı)"
        case "x_tarzi":
            return "Türkçe flood, her tweet ≤280, rakamlar ölçümden."
        case "x_taslak_koy":
            return "Kuyruğa kondu (test, kaydedilmedi)."
        default:
            return await AgentTools.run(c, folder: folder, maxChars: maxChars).text
        }
    }

    // MARK: Geçmiş

    private func saveSummary() {
        var byCat: [String: [Int]] = [:]
        for c in TestCategory.allCases {
            let s = score(c)
            if s.total > 0 { byCat[c.rawValue] = [s.passed, s.total] }
        }
        let speeds = results.values.compactMap { $0.stats?.generatedPerSecond }.filter { $0 > 0 }
        let summary = RunSummary(
            date: Date(),
            model: server.modelName,
            contextSize: server.runningConfig?.contextSize ?? server.config.contextSize,
            preset: presetName,
            passed: passedCount,
            total: tests.count,
            byCategory: byCat,
            avgTokensPerSecond: speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count),
            failedTests: tests.filter { results[$0.id]?.status != .passed }.map(\.title))
        history.insert(summary, at: 0)
        if let data = try? Self.encoder.encode(history) { try? data.write(to: Self.historyURL, options: .atomic) }
    }

    func deleteHistory(_ s: RunSummary) {
        history.removeAll { $0.id == s.id }
        if let data = try? Self.encoder.encode(history) { try? data.write(to: Self.historyURL, options: .atomic) }
    }

    private static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AurelionLabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test-history.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
