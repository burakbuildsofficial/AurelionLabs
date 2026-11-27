import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Belgeler: klasör/dosya ekle, hepsini özetle ya da soru sor (kaynaklı cevap).
struct DocumentsView: View {
    @Environment(LabStore.self) private var store
    @State private var importing = false
    @State private var dropTargeted = false

    private var ws: DocumentWorkspace { store.documents }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                filesCard
                if !ws.docs.isEmpty { actionsCard }
                if ws.isRunning || !ws.output.isEmpty || ws.error != nil { resultCard }
            }
            .frame(maxWidth: Theme.Size.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder, .pdf, .text, .sourceCode, .json, .commaSeparatedText, .rtf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { ws.add(urls) }
        }
    }

    // MARK: Dosyalar

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Belgeler", trailing: ws.docs.isEmpty ? nil : AnyView(
                Button("Hepsini kaldır") { ws.clear() }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .disabled(ws.isRunning)
            ))
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if ws.docs.isEmpty {
                    VStack(spacing: Theme.Space.s) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(Theme.primary)
                        Text("Klasör ya da dosyaları buraya sürükle").font(Theme.Font.headline).foregroundStyle(Theme.textPrimary)
                        Text("PDF, metin, Markdown, kod, CSV, JSON. Klasörün alt klasörleri de okunur. Hiçbir şey bu Mac'ten çıkmaz.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                        SecondaryButton(title: "Klasör ya da dosya seç", symbol: "plus", tint: Theme.primary) { importing = true }
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.l)
                } else {
                    ForEach(Array(ws.docs.prefix(40).enumerated()), id: \.element.id) { i, d in
                        if i > 0 { Divider().overlay(Theme.hairline) }
                        HStack(spacing: 10) {
                            Image(systemName: d.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                                .foregroundStyle(Theme.primary)
                            Text(d.name).font(Theme.Font.callout).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Spacer()
                            Text("~\(d.approxTokens.formatted()) token").font(Theme.Font.stat).foregroundStyle(Theme.textTertiary)
                            Button { ws.remove(d) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                                .disabled(ws.isRunning)
                                .accessibilityLabel("\(d.name) dosyasını kaldır")
                        }
                        .padding(.vertical, 4)
                        .help(d.path)
                    }
                    if ws.docs.count > 40 {
                        Text("ve \(ws.docs.count - 40) dosya daha").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Divider().overlay(Theme.hairline)
                    HStack {
                        Text("\(ws.docs.count) dosya · ~\(ws.totalTokens.formatted()) token")
                            .font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        SecondaryButton(title: "Ekle", symbol: "plus") { importing = true }.disabled(ws.isRunning)
                    }
                }
                if !ws.skipped.isEmpty {
                    Text("Okunamadı: " + ws.skipped.prefix(6).joined(separator: ", ") + (ws.skipped.count > 6 ? " …" : ""))
                        .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                }
            }
            .card()
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.primary, style: StrokeStyle(lineWidth: 2, dash: [6]))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                ws.add(urls); return true
            } isTargeted: { dropTargeted = $0 }
        }
    }

    // MARK: İşlemler

    private var actionsCard: some View {
        @Bindable var ws = ws
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Ne yapalım?")
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    TextField("Belgelere soru sor: ör. sözleşmede fesih süresi kaç gün?", text: $ws.question)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.body)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Theme.surfaceRaised, in: .capsule)
                        .onSubmit { ask() }
                    PrimaryButton(title: "Sor", symbol: "questionmark.bubble",
                                  enabled: canRun && !ws.question.trimmingCharacters(in: .whitespaces).isEmpty) { ask() }
                }
                HStack(spacing: Theme.Space.s) {
                    SecondaryButton(title: "Hepsini özetle", symbol: "text.append", tint: Theme.primary) {
                        ws.summarize(params: store.params)
                    }
                    .disabled(!canRun)
                    Text(estimate).font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                }
                if !store.server.isUsable {
                    Text("Önce üstteki model menüsünden bir model yükle.").font(Theme.Font.small).foregroundStyle(Theme.Tone.caution.color)
                }
            }
            .card()
        }
    }

    private var canRun: Bool { store.server.isUsable && !ws.isRunning && !store.isGenerating && !store.tests.isRunning }

    private func ask() { if canRun { ws.answer(params: store.params) } }

    /// Kabaca süre tahmini: okuma ~250 token/sn, her parça için ~40 sn düşünme+özet.
    private var estimate: String {
        let ctx = store.server.runningConfig?.contextSize ?? store.server.config.contextSize
        let per = max(800, min(9000, ctx - 2600))
        let parts = ws.docs.reduce(0) { $0 + max(1, Int(ceil(Double($1.approxTokens) / Double(per)))) }
        let secs = Double(ws.totalTokens) / 250 + Double(parts) * 40
        let mins = max(1, Int((secs / 60).rounded()))
        return "\(parts) parça · yaklaşık \(mins) dk"
    }

    // MARK: Sonuç

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: resultTitle, trailing: ws.output.isEmpty ? nil : AnyView(
                HStack(spacing: 6) {
                    RoundAction(symbol: "doc.on.doc", label: "Kopyala") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ws.output, forType: .string)
                    }
                    RoundAction(symbol: "square.and.arrow.down", label: "Markdown olarak kaydet") { save() }
                }
            ))
            VStack(alignment: .leading, spacing: 12) {
                if ws.isRunning {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(ws.step).font(Theme.Font.callout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer()
                        if ws.progress.total > 1 {
                            Text("\(ws.progress.done)/\(ws.progress.total)").font(Theme.Font.stat).foregroundStyle(Theme.textTertiary)
                        }
                        SecondaryButton(title: "Durdur", symbol: "stop.fill", tint: Theme.Tone.danger.color) { ws.stop() }
                    }
                    if ws.progress.total > 1 {
                        ProgressView(value: Double(ws.progress.done), total: Double(ws.progress.total)).tint(Theme.primary)
                    }
                }
                if !ws.reasoning.isEmpty && store.showReasoning {
                    ReasoningPanel(text: ws.reasoning, live: ws.isRunning && ws.output.isEmpty)
                }
                if !ws.output.isEmpty { MessageText(text: ws.output) }
                if let e = ws.error {
                    Label(e, systemImage: Theme.Tone.danger.symbol)
                        .font(Theme.Font.callout).foregroundStyle(Theme.Tone.danger.color)
                }
                if !ws.sources.isEmpty {
                    Divider().overlay(Theme.hairline)
                    Text("Kaynaklar").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    ForEach(ws.sources) { c in
                        DisclosureGroup {
                            Text(c.text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Text("[\(c.id)] \(c.docName)" + (c.partCount > 1 ? " · bölüm \(c.part)/\(c.partCount)" : ""))
                                .font(Theme.Font.caption).foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                if let st = ws.stats, !ws.isRunning { StatsLine(stats: st) }
            }
            .card()
        }
    }

    private var resultTitle: String {
        switch ws.running {
        case .summary: "Özet"
        case .answer: "Cevap"
        case nil: ws.sources.isEmpty ? "Özet" : "Cevap"
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (ws.sources.isEmpty ? "Belge özeti" : "Belge cevabı") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ws.output.write(to: url, atomically: true, encoding: .utf8)
    }
}
