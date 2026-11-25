import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Sohbet, ayarlar, ön ayarlar ve karşılaştırma durumu.
@MainActor
@Observable
final class LabStore {
    enum Mode: String, CaseIterable, Identifiable {
        case chat, documents, compare, tests, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chat: "Yeni sohbet"
            case .documents: "Belgeler"
            case .compare: "Karşılaştır"
            case .tests: "Testler"
            case .settings: "Ayarlar"
            }
        }
        var symbol: String {
            switch self {
            case .chat: "square.and.pencil"
            case .documents: "doc.on.doc"
            case .compare: "rectangle.split.2x1"
            case .tests: "checkmark.seal"
            case .settings: "gearshape"
            }
        }
    }

    let server: ServerManager
    let tests: TestRunner
    let documents: DocumentWorkspace

    let library = ModelLibrary()

    var mode: Mode = .chat
    var showReasoning = true
    var appearance: Appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance"); appearance.apply() }
    }
    var palette: Palette = Palette.current {
        didSet { Palette.current = palette; UserDefaults.standard.set(palette.rawValue, forKey: "palette") }
    }

    // Sohbet
    var messages: [ChatMessage] = []
    var draft = ""
    var draftImages: [ImageAttachment] = []
    var draftDocuments: [DocumentAttachment] = []
    var params = SamplingParams.recommended { didSet { saveParams() } }
    var activePresetID: Preset.ID?
    private(set) var isGenerating = false
    private var generation: Task<Void, Never>?

    // Ajan (araçlar)
    var toolsEnabled = UserDefaults.standard.bool(forKey: "toolsEnabled") {
        didSet { UserDefaults.standard.set(toolsEnabled, forKey: "toolsEnabled") }
    }
    var agentFolder: URL? = UserDefaults.standard.string(forKey: "agentFolder").map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(agentFolder?.path, forKey: "agentFolder") }
    }
    struct Approval: Identifiable {
        let id = UUID()
        let call: ToolCallRecord
        let summary: String
        let resume: (Bool) -> Void
    }
    private(set) var pendingApproval: Approval?
    private(set) var agentStep: String?
    static let maxAgentSteps = 8

    // Sohbet geçmişi
    private(set) var conversations: [Conversation] = []
    private(set) var currentID: Conversation.ID?
    var historyQuery = ""

    // Ön ayarlar
    private(set) var presets: [Preset] = []

    // Karşılaştırma
    var comparePrompt = ""
    var compareImages: [ImageAttachment] = []
    var compareA: Preset.ID?
    var compareB: Preset.ID?
    var compareResults: [ChatMessage?] = [nil, nil]
    private(set) var isComparing = false
    private var compareTask: Task<Void, Never>?

    init(server: ServerManager) {
        self.server = server
        self.tests = TestRunner(server: server)
        self.documents = DocumentWorkspace(server: server)
        loadPresets()
        loadConversations()
        if let data = UserDefaults.standard.data(forKey: "params"),
           let p = try? JSONDecoder().decode(SamplingParams.self, from: data) {
            params = p
        }
        compareA = presets.first?.id
        compareB = presets.dropFirst().first?.id
    }

    var activePreset: Preset? { presets.first { $0.id == activePresetID } }
    var paramsModified: Bool { activePreset.map { $0.params != params } ?? true }

    // MARK: Sohbet

    var canSend: Bool {
        server.isUsable && !isGenerating && !tests.isRunning &&
            (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty || !draftDocuments.isEmpty)
    }

    func send() {
        guard canSend else { return }
        let user = ChatMessage(role: .user, text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                               images: draftImages, documents: draftDocuments)
        draft = ""
        draftImages = []
        draftDocuments = []
        messages.append(user)
        saveCurrent()
        if toolsEnabled { runAgent() } else { runAssistant() }
    }

    /// Taslaktaki dosyaların bağlamın ne kadarını dolduracağı (0…1+).
    var draftContextShare: Double {
        let tokens = draftDocuments.reduce(0) { $0 + $1.approxTokens }
        let ctx = server.runningConfig?.contextSize ?? server.config.contextSize
        return Double(tokens) / Double(max(ctx, 1))
    }

    /// Sürüklenen/seçilen dosyaları resim ya da belge olarak taslağa ekler. Eklenemeyenlerin adını döndürür.
    @discardableResult
    func attach(_ urls: [URL]) -> [String] {
        var skipped: [String] = []
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if DocumentLoader.isImage(url) {
                if server.imagesAvailable, let img = ImageLoader.attachment(from: url) { draftImages.append(img) }
                else { skipped.append(url.lastPathComponent) }
            } else if let doc = DocumentLoader.load(url) {
                draftDocuments.append(doc)
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        return skipped
    }

    func regenerateLast() {
        guard !isGenerating, let last = messages.last, last.role == .assistant else { return }
        messages.removeLast()
        if toolsEnabled { runAgent() } else { runAssistant() }
    }

    func stop() {
        resolveApproval(false)
        generation?.cancel()
        compareTask?.cancel()
    }

    func newChat() {
        stop()
        saveCurrent()
        messages.removeAll()
        currentID = nil
        draft = ""
        draftImages = []
        draftDocuments = []
    }

    // MARK: Sohbet geçmişi

    var filteredConversations: [Conversation] {
        let q = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return conversations }
        return conversations.filter { c in
            c.title.localizedCaseInsensitiveContains(q) ||
                c.messages.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    func open(_ c: Conversation) {
        guard !isGenerating, c.id != currentID else { return }
        saveCurrent()
        messages = c.messages
        currentID = c.id
        draft = ""
        draftImages = []
        draftDocuments = []
        mode = .chat
    }

    func togglePin(_ c: Conversation) {
        guard let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
        conversations[i].pinned = conversations[i].isPinned ? nil : true
        write(conversations[i])
    }

    /// Sohbeti Markdown dosyası olarak kaydet.
    func export(_ c: Conversation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = c.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? c.markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Modeller

    var currentModel: ModelLibrary.Model? { library.model(at: server.config.modelPath) }

    func load(_ m: ModelLibrary.Model, contextSize: Int? = nil, images: Bool? = nil) {
        guard !isGenerating, !tests.isRunning else { return }
        server.load(modelPath: m.path, mmprojPath: m.mmproj, contextSize: contextSize, images: images)
        restorePreset(for: m.path)
    }

    // MARK: Kullanım modları (tek tıkla model + bağlam + resim)

    enum UseMode: String, CaseIterable, Identifiable {
        case fast, general, long
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fast: "Hızlı sohbet"
            case .general: "Genel"
            case .long: "Uzun metin"
            }
        }
        var symbol: String {
            switch self {
            case .fast: "bolt.fill"
            case .general: "photo"
            case .long: "doc.text"
            }
        }
    }

    /// Bu Mac'teki modellerden moda en uygun olanı: hızlıda Atomic (AD) dosyası, diğerlerinde en küçük llama.cpp modeli.
    func model(for mode: UseMode) -> ModelLibrary.Model? {
        let plain = library.models.filter { !$0.fileName.contains("-AD-") }.sorted { $0.bytes < $1.bytes }
        switch mode {
        case .fast: return library.models.first { $0.fileName.contains("-AD-") } ?? plain.first
        case .general: return plain.first { $0.mmproj != nil } ?? plain.first
        case .long: return plain.first
        }
    }

    func detail(for mode: UseMode) -> String {
        guard let m = model(for: mode) else { return "Uygun model yok" }
        let q = m.quant.isEmpty ? m.fileName : m.quant
        switch mode {
        case .fast: return m.fileName.contains("-AD-") ? "\(q) · Atomic · 4K · resim yok" : "\(q) · 16K"
        case .general: return "\(q) · 16K" + (m.mmproj != nil ? " · resim okur" : "")
        case .long: return "\(q) · 32K · resim kapalı"
        }
    }

    func activate(_ mode: UseMode) {
        guard let m = model(for: mode) else { return }
        switch mode {
        case .fast: load(m, contextSize: 16384, images: true)
        case .general: load(m, contextSize: 16384, images: true)
        case .long: load(m, contextSize: 32768, images: false)
        }
    }

    /// Şu an açık ayarın hangi moda karşılık geldiği (menüde işaret için).
    var currentUseMode: UseMode? {
        let c = server.config
        for mode in UseMode.allCases {
            guard let m = model(for: mode), m.path == c.modelPath else { continue }
            switch mode {
            case .fast where c.usesAtomic: return .fast
            case .long where c.contextSize >= 32768 && !c.imagesEnabled: return .long
            case .general where c.contextSize < 32768: return .general
            default: continue
            }
        }
        return nil
    }

    // MARK: Modele göre ön ayar

    /// Model yolu → son kullanılan ön ayarın adı (hazır ön ayarların kimliği her açılışta yenilenir). Model değişince o modelin ön ayarı geri gelir.
    private var modelPresets: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "modelPresets") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "modelPresets") }
    }

    private func restorePreset(for path: String) {
        guard let name = modelPresets[path], let p = presets.first(where: { $0.name == name }) else { return }
        activePresetID = p.id
        params = p.params
    }

    /// Ön ayarı bu model için hatırlanan ön ayar yapar.
    var rememberedPresetName: String? {
        guard let name = modelPresets[server.config.modelPath] else { return nil }
        return presets.contains { $0.name == name } ? name : nil
    }

    func rename(_ c: Conversation, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
        conversations[i].title = t
        write(conversations[i])
    }

    func delete(_ c: Conversation) {
        if c.id == currentID {
            stop()
            messages.removeAll()
            currentID = nil
        }
        conversations.removeAll { $0.id == c.id }
        try? FileManager.default.removeItem(at: Self.conversationsDir.appendingPathComponent("\(c.id).json"))
    }

    /// Açık sohbeti diske yazar; ilk mesajda geçmişe ekler.
    private func saveCurrent() {
        guard !messages.isEmpty else { return }
        var clean = messages
        for i in clean.indices { clean[i].isStreaming = false }
        if let id = currentID, let i = conversations.firstIndex(where: { $0.id == id }) {
            conversations[i].messages = clean
            conversations[i].updated = Date()
            conversations[i].model = server.modelName
            let c = conversations.remove(at: i)
            conversations.insert(c, at: 0)
            write(c)
        } else {
            var c = Conversation(title: Conversation.makeTitle(from: clean), messages: clean)
            c.model = server.modelName
            currentID = c.id
            conversations.insert(c, at: 0)
            write(c)
        }
    }

    private static var conversationsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InklingLab/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ c: Conversation) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(c) {
            try? data.write(to: Self.conversationsDir.appendingPathComponent("\(c.id).json"), options: .atomic)
        }
    }

    private func loadConversations() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.conversationsDir, includingPropertiesForKeys: nil)) ?? []
        conversations = files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? dec.decode(Conversation.self, from: $0) } }
            .sorted { $0.updated > $1.updated }
    }

    private func runAssistant() {
        let history = messages
        let paramsNow = params
        var reply = ChatMessage(role: .assistant, text: "", isStreaming: true)
        reply.presetName = paramsModified ? nil : activePreset?.name
        messages.append(reply)
        let index = messages.count - 1
        isGenerating = true
        let client = LLMClient(baseURL: server.baseURL)
        let convID = currentID

        generation = Task { [weak self] in
            do {
                for try await event in client.stream(messages: history, params: paramsNow) {
                    guard let self, self.currentID == convID else { break }
                    switch event {
                    case .reasoning(let s): self.messages[index].reasoning += s
                    case .content(let s): self.messages[index].text += s
                    case .finished(let st): self.messages[index].stats = st
                    }
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                self?.messages[index].error = Self.describe(error)
            }
            guard let self else { return }
            guard self.currentID == convID else { self.isGenerating = false; return }
            if index < self.messages.count {
                self.messages[index].isStreaming = false
                if self.messages[index].text.isEmpty && self.messages[index].reasoning.isEmpty
                    && self.messages[index].error == nil {
                    self.messages[index].error = "Cevap durduruldu."
                }
            }
            self.isGenerating = false
            self.saveCurrent()
        }
    }

    // MARK: Ajan döngüsü

    /// Model araç istedikçe çalıştırıp sonucu geri verir; araç istemeyen ilk cevap son cevaptır.
    private func runAgent() {
        isGenerating = true
        agentStep = "Düşünüyor…"
        let convID = currentID
        let p = params
        let client = LLMClient(baseURL: server.baseURL)
        let folder = agentFolder
        let tools = AgentTools.definitions(hasFolder: folder != nil)
        let ctx = server.runningConfig?.contextSize ?? server.config.contextSize
        let maxChars = max(1500, min(20_000, Int(Double(ctx) * 3.3 * 0.35)))

        generation = Task { [weak self] in
            guard let self else { return }
            var finished = false
            do {
                for step in 1...Self.maxAgentSteps {
                    try Task.checkCancellation()
                    guard self.currentID == convID else { break }
                    self.agentStep = step == 1 ? "Düşünüyor…" : "Adım \(step): sonuçlara bakıyor…"
                    let r = try await client.complete(messages: self.messages, params: p, toolsJSON: tools)
                    guard self.currentID == convID else { break }
                    if r.toolCalls.isEmpty {
                        var reply = ChatMessage(role: .assistant, text: r.content.trimmingCharacters(in: .whitespacesAndNewlines))
                        reply.reasoning = r.reasoning
                        reply.stats = r.stats
                        reply.presetName = self.paramsModified ? nil : self.activePreset?.name
                        if reply.text.isEmpty { reply.error = "Cevap boş geldi: token sınırı düşünmeye gitti. Ön ayarda en fazla token'ı artır." }
                        self.messages.append(reply)
                        finished = true
                        break
                    }
                    let calls = r.toolCalls.map { ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments) }
                    var ask = ChatMessage(role: .assistant, text: r.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    ask.reasoning = r.reasoning
                    ask.toolCalls = calls
                    ask.stats = r.stats
                    self.messages.append(ask)
                    for call in calls {
                        try Task.checkCancellation()
                        var result: AgentTools.Outcome
                        if AgentTools.risk(of: call.name) == .needsApproval {
                            self.agentStep = "Onayını bekliyor: \(call.name)"
                            let ok = await self.requestApproval(call)
                            result = ok ? AgentTools.Outcome(text: "", ok: true) : AgentTools.Outcome(text: "Kullanıcı bu işlemi reddetti.", ok: false)
                            if ok {
                                self.agentStep = "\(call.name) çalışıyor"
                                result = await AgentTools.run(call, folder: folder, maxChars: maxChars)
                            }
                        } else {
                            self.agentStep = "\(call.name) çalışıyor"
                            result = await AgentTools.run(call, folder: folder, maxChars: maxChars)
                        }
                        var t = ChatMessage(role: .tool, text: result.text)
                        t.toolCallID = call.id
                        t.toolName = call.name
                        self.messages.append(t)
                    }
                    self.saveCurrent()
                }
                if !finished && self.currentID == convID {
                    var m = ChatMessage(role: .assistant, text: "")
                    m.error = "\(Self.maxAgentSteps) adımda bitiremedim. Görevi daha küçük parçalara bölüp tekrar dene."
                    self.messages.append(m)
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                var m = ChatMessage(role: .assistant, text: "")
                m.error = Self.describe(error)
                self.messages.append(m)
            }
            self.agentStep = nil
            self.isGenerating = false
            self.saveCurrent()
        }
    }

    private func requestApproval(_ call: ToolCallRecord) async -> Bool {
        await withCheckedContinuation { cont in
            pendingApproval = Approval(call: call, summary: AgentTools.summary(call)) { cont.resume(returning: $0) }
        }
    }

    func resolveApproval(_ ok: Bool) {
        guard let a = pendingApproval else { return }
        pendingApproval = nil
        a.resume(ok)
    }

    func chooseAgentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Seç"
        panel.message = "Modelin okuyup yazabileceği çalışma klasörünü seç. Model bu klasörün dışına çıkamaz."
        if panel.runModal() == .OK, let url = panel.url { agentFolder = url }
    }

    // MARK: Ön ayarlar

    func apply(_ preset: Preset) {
        activePresetID = preset.id
        params = preset.params
        modelPresets[server.config.modelPath] = preset.name
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let p = Preset(name: trimmed, params: params)
        presets.append(p)
        activePresetID = p.id
        savePresets()
    }

    func updateActivePreset() {
        guard let i = presets.firstIndex(where: { $0.id == activePresetID }), !presets[i].builtIn else { return }
        presets[i].params = params
        savePresets()
    }

    func delete(_ preset: Preset) {
        guard !preset.builtIn else { return }
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = nil }
        savePresets()
    }

    private var presetsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InklingLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    private func loadPresets() {
        let custom = (try? Data(contentsOf: presetsURL)).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
        presets = Preset.defaults + custom.filter { !$0.builtIn }
        activePresetID = presets.first?.id
    }

    private func savePresets() {
        let custom = presets.filter { !$0.builtIn }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(custom) { try? data.write(to: presetsURL, options: .atomic) }
    }

    private func saveParams() {
        if let data = try? JSONEncoder().encode(params) { UserDefaults.standard.set(data, forKey: "params") }
    }

    // MARK: Karşılaştırma

    var canCompare: Bool {
        server.isUsable && !isComparing && !isGenerating && compareA != nil && compareB != nil &&
            (!comparePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !compareImages.isEmpty)
    }

    /// Aynı soruyu iki ön ayarla sırayla çalıştırır (hız ölçümü adil kalsın diye aynı anda değil).
    func runCompare() {
        guard canCompare else { return }
        let ids = [compareA, compareB]
        let user = ChatMessage(role: .user, text: comparePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                               images: compareImages)
        compareResults = [nil, nil]
        isComparing = true
        let client = LLMClient(baseURL: server.baseURL)

        compareTask = Task { [weak self] in
            for side in 0..<2 {
                guard let self, !Task.isCancelled,
                      let preset = self.presets.first(where: { $0.id == ids[side] }) else { break }
                var reply = ChatMessage(role: .assistant, text: "", isStreaming: true)
                reply.presetName = preset.name
                self.compareResults[side] = reply
                do {
                    for try await event in client.stream(messages: [user], params: preset.params) {
                        switch event {
                        case .reasoning(let s): self.compareResults[side]?.reasoning += s
                        case .content(let s): self.compareResults[side]?.text += s
                        case .finished(let st): self.compareResults[side]?.stats = st
                        }
                    }
                } catch is CancellationError {
                } catch let e as URLError where e.code == .cancelled {
                } catch {
                    self.compareResults[side]?.error = Self.describe(error)
                }
                self.compareResults[side]?.isStreaming = false
            }
            self?.isComparing = false
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return "Sunucuya bağlanılamadı. Sunucu bölümünden başlatıp tekrar dene."
            case .timedOut:
                return "Sunucu zamanında cevap vermedi. Tekrar dene ya da en fazla token sayısını düşür."
            default: break
            }
        }
        return error.localizedDescription
    }
}
