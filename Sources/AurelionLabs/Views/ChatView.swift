import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(LabStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                        if store.messages.isEmpty {
                            EmptyChat()
                        }
                        ForEach(Array(store.messages.enumerated()), id: \.element.id) { i, m in
                            MessageRow(message: m,
                                       isLast: i == store.messages.count - 1,
                                       showReasoning: store.showReasoning)
                                .id(m.id)
                                .riseIn()
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: Theme.Size.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                }
                .scrollIndicators(.automatic)
                .onChange(of: store.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Composer()
                .frame(maxWidth: Theme.Size.contentMaxWidth)
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.m)
        }
        .sheet(item: Binding(get: { store.pendingApproval }, set: { if $0 == nil { store.resolveApproval(false) } })) { a in
            ApprovalSheet(approval: a)
        }
    }
}

private struct EmptyChat: View {
    @Environment(LabStore.self) private var store

    private let suggestions = [
        "Kendini iki cümleyle tanıt.",
        "Bu resimde ne görüyorsun?",
        "Bir SwiftUI sayacı yaz, açıklamalı olsun.",
        "Kuantum dolanıklığını 10 yaşındaki birine anlat.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Bir şey sor, resim ya da dosya sürükle")
                .font(Theme.Font.section)
                .foregroundStyle(Theme.textPrimary)
            Text("Model tamamen bu Mac'te çalışır, hiçbir şey dışarı gitmez. Modeli ve ön ayarı üstteki menülerden tek tıkla değiştirebilirsin.")
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.textSecondary)
            FlowRow(spacing: Theme.Space.s) {
                ForEach(suggestions, id: \.self) { s in
                    Chip(title: s, selected: false) { store.draft = s }
                }
            }
            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Kullanım modu").font(Theme.Font.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                HStack(spacing: Theme.Space.s) {
                    ForEach(LabStore.UseMode.allCases) { mode in
                        let selected = store.currentUseMode == mode
                        Button { store.activate(mode) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(mode.title, systemImage: mode.symbol)
                                    .font(Theme.Font.callout.weight(.semibold))
                                    .foregroundStyle(selected ? Theme.primary : Theme.textPrimary)
                                Text(store.detail(for: mode))
                                    .font(Theme.Font.small)
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(selected ? Theme.primarySoft : Theme.surfaceRaised,
                                        in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(store.server.isBusy || store.model(for: mode) == nil)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                if store.server.isBusy {
                    Label("Model değiştiriliyor…", systemImage: "hourglass")
                        .font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .card(padding: Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .riseIn()
    }
}

/// Basit akış yerleşimi (çipler satıra sığmazsa alta geçer).
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

struct MessageRow: View {
    @Environment(LabStore.self) private var store
    let message: ChatMessage
    var isLast = false
    var showReasoning = true
    var compact = false

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant:
            if let calls = message.toolCalls, !calls.isEmpty { ToolStepRow(message: message, calls: calls, showReasoning: showReasoning) }
            else { assistantCard }
        case .tool: ToolResultRow(message: message)
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: Theme.Space.s) {
                if !message.images.isEmpty {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(message.images) { AttachmentThumb(image: $0, size: 120) }
                    }
                }
                ForEach(message.documents) { DocumentChip(doc: $0) }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.primarySoft, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
        }
    }

    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showReasoning && !message.reasoning.isEmpty {
                ReasoningPanel(text: message.reasoning,
                               live: message.isStreaming && message.text.isEmpty)
            }

            if message.text.isEmpty && message.isStreaming && message.reasoning.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("İstem işleniyor…").font(Theme.Font.callout).foregroundStyle(Theme.textSecondary)
                }
            } else if !message.text.isEmpty {
                MessageText(text: message.text)
            }

            if let error = message.error {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: Theme.Tone.danger.symbol).foregroundStyle(Theme.Tone.danger.color)
                    Text(error).font(Theme.Font.callout).foregroundStyle(Theme.textPrimary)
                }
            }

            if !message.isStreaming {
                Divider().overlay(Theme.hairline)
                HStack(spacing: Theme.Space.s) {
                    if let stats = message.stats { StatsLine(stats: stats) }
                    if let p = message.presetName {
                        Text(p)
                            .font(Theme.Font.small.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.primarySoft, in: .capsule)
                    }
                    Spacer()
                    if !compact {
                        if isLast {
                            RoundAction(symbol: "arrow.clockwise", label: "Yeniden üret") { store.regenerateLast() }
                        }
                        RoundAction(symbol: "doc.on.doc", label: "Kopyala") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                    }
                }
            }
        }
        .card()
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Modelin cevaptan önceki düşünmesi: açılır kapanır panel.
struct ReasoningPanel: View {
    let text: String
    var live = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                withAnimation(Motion.snappy(reduce)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text(live ? "Düşünüyor…" : "Düşündü")
                        .fontWeight(.semibold)
                    Text("· \(text.count.formatted()) karakter")
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded || live ? 180 : 0))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Düşünmeyi gizle" : "Düşünmeyi göster")

            if expanded || live {
                Text(text)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(live ? 8 : nil)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(Theme.surfaceRaised, in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

struct Composer: View {
    @Environment(LabStore.self) private var store
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var attachNote: String?
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            if !store.draftImages.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    ForEach(store.draftImages) { img in
                        AttachmentThumb(image: img) { store.draftImages.removeAll { $0.id == img.id } }
                    }
                }
            }
            if !store.draftDocuments.isEmpty {
                FlowRow(spacing: Theme.Space.s) {
                    ForEach(store.draftDocuments) { d in
                        DocumentChip(doc: d) { store.draftDocuments.removeAll { $0.id == d.id } }
                    }
                }
                if store.draftContextShare > 0.75 {
                    ModeHint(text: "Dosyalar bağlamın %\(Int(store.draftContextShare * 100))'ini dolduruyor, cevap kesilebilir.",
                             mode: store.currentUseMode == .long ? nil : .long)
                }
            }
            if !store.draftImages.isEmpty && !store.server.imagesAvailable {
                ModeHint(text: "Açık model resim okuyamıyor.", mode: store.model(for: .general)?.mmproj != nil ? .general : nil)
            }
            if let step = store.agentStep {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(step).font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
                }
            }
            if let attachNote {
                Text(attachNote).font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
            }
            ZStack(alignment: .topLeading) {
                if store.draft.isEmpty {
                    Text(placeholder)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $store.draft)
                    .font(Theme.Font.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 22, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        store.send()
                        return .handled
                    }
            }
            HStack(spacing: Theme.Space.s) {
                RoundAction(symbol: "paperclip", label: "Dosya ya da resim ekle") { importing = true }
                ToolsToggle()
                Text(hint)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if store.isGenerating {
                    PrimaryButton(title: "Durdur", symbol: "stop.fill") { store.stop() }
                } else {
                    PrimaryButton(title: "Gönder", symbol: "arrow.up", enabled: store.canSend) { store.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.card + 4, style: .continuous))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous)
                    .strokeBorder(Theme.primary, style: StrokeStyle(lineWidth: 2, dash: [6]))
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
        .dropDestination(for: URL.self) { urls, _ in
            let skipped = store.attach(urls)
            attachNote = skipped.isEmpty ? nil : "Eklenemedi: " + skipped.joined(separator: ", ")
            return skipped.count < urls.count
        } isTargeted: { dropTargeted = $0 }
        .onPasteCommand(of: [.fileURL, .image, .png, .tiff, .jpeg]) { _ in
            let imgs = ImageLoader.fromPasteboard()
            if imgs.isEmpty, let s = NSPasteboard.general.string(forType: .string) {
                store.draft += s
            } else {
                store.draftImages += imgs
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.image, .pdf, .text, .sourceCode, .json, .commaSeparatedText, .rtf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let skipped = store.attach(urls)
                attachNote = skipped.isEmpty ? nil : "Eklenemedi: " + skipped.joined(separator: ", ")
            }
        }
        .onAppear { focused = true }
    }

    private var placeholder: String {
        store.server.isUsable ? "Bir şey sor…" : "Model yüklenince yazabilirsin. Üstteki model menüsünden seç."
    }

    private var hint: String {
        store.server.imagesAvailable
            ? "Enter gönderir · Shift+Enter yeni satır · resim, PDF ya da kod dosyası sürükle"
            : "Enter gönderir · PDF ya da kod dosyası sürükle (resim desteği kapalı)"
    }
}

/// Eklenen belgenin küçük kartı: ad, yaklaşık token, isteğe bağlı silme.
struct DocumentChip: View {
    let doc: DocumentAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: doc.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                .font(.system(size: 18))
                .foregroundStyle(Theme.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.name).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("~\(doc.approxTokens.formatted()) token" + (doc.truncated ? " · kısaltıldı" : ""))
                    .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dosyayı kaldır")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Theme.surfaceRaised, in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
        .help(doc.truncated ? "Dosya uzun olduğu için ilk \(DocumentLoader.maxChars.formatted()) karakteri gönderilecek." : doc.name)
    }
}

/// Ekli içerik açık modele uymuyorsa uyarı + tek tıkla uygun moda geçiş.
struct ModeHint: View {
    @Environment(LabStore.self) private var store
    let text: String
    let mode: LabStore.UseMode?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: Theme.Tone.caution.symbol).foregroundStyle(Theme.Tone.caution.color)
            Text(text).font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
            if let mode {
                Button("\(mode.title) moduna geç") { store.activate(mode) }
                    .buttonStyle(.plain)
                    .font(Theme.Font.small.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .disabled(store.server.isBusy || store.isGenerating)
            }
        }
    }
}

/// Ajan modu düğmesi: araçları aç/kapat, çalışma klasörünü seç.
struct ToolsToggle: View {
    @Environment(LabStore.self) private var store

    var body: some View {
        Menu {
            Toggle("Araçları kullan (ajan modu)", isOn: Binding(get: { store.toolsEnabled }, set: { store.toolsEnabled = $0 }))
            Divider()
            Text(store.agentFolder.map { "Çalışma klasörü: \($0.lastPathComponent)" } ?? "Çalışma klasörü yok: hesap, saat, beceriler ve Beyin")
            Button("Çalışma klasörü seç…", systemImage: "folder") { store.chooseAgentFolder() }
            if store.agentFolder != nil {
                Button("Klasörü kaldır", systemImage: "folder.badge.minus") { store.agentFolder = nil }
            }
            Divider()
            Text("Dosya yazma ve komut çalıştırma her seferinde onayını ister")
        } label: {
            Label(store.toolsEnabled ? "Ajan açık" : "Ajan", systemImage: "wrench.and.screwdriver")
                .font(Theme.Font.small.weight(.semibold))
                .foregroundStyle(store.toolsEnabled ? Theme.primary : Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(store.toolsEnabled ? Theme.primarySoft : Theme.surfaceRaised, in: .capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(store.isGenerating)
        .help("Modele hesap makinesi, saat, dosya okuma/yazma ve terminal ver")
    }
}

/// Modelin araç istediği ara adım.
struct ToolStepRow: View {
    let message: ChatMessage
    let calls: [ToolCallRecord]
    var showReasoning = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showReasoning && !message.reasoning.isEmpty { ReasoningPanel(text: message.reasoning) }
            if !message.text.isEmpty {
                Text(message.text).font(Theme.Font.callout).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            }
            ForEach(calls, id: \.id) { c in
                Label {
                    Text("\(c.name)").font(Theme.Font.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    + Text("  " + String(AgentTools.summary(c).prefix(160))).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                } icon: {
                    Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.primary)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Aracın döndürdüğü sonuç (kapalı başlar).
struct ToolResultRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                Text(message.text).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        } label: {
            Text("\(message.toolName ?? "araç") sonucu · " + String(message.text.prefix(80)).replacingOccurrences(of: "\n", with: " "))
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.surfaceRaised, in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
        .padding(.leading, 28)
    }
}

/// Dosya yazma ya da komut çalıştırma için onay.
struct ApprovalSheet: View {
    @Environment(LabStore.self) private var store
    let approval: LabStore.Approval

    private var isCommand: Bool { approval.call.name == "komut_calistir" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(isCommand ? "Model bir komut çalıştırmak istiyor" : "Model bir dosya yazmak istiyor",
                  systemImage: Theme.Tone.caution.symbol)
                .font(Theme.Font.headline).foregroundStyle(Theme.textPrimary)
            Text("Klasör: " + (store.agentFolder?.path ?? "-")).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            ScrollView {
                Text(isCommand ? approval.summary : preview)
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(maxHeight: 260)
            .background(Theme.surfaceRaised, in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
            HStack {
                Spacer()
                Button("Reddet", role: .cancel) { store.resolveApproval(false) }.keyboardShortcut(.cancelAction)
                Button(isCommand ? "Çalıştır" : "Yaz") { store.resolveApproval(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 520)
    }

    private var preview: String {
        let a = AgentTools.args(approval.call.arguments)
        return "\(a["yol"] ?? "?")\n\n" + String((a["icerik"] ?? "").prefix(4000))
    }
}
