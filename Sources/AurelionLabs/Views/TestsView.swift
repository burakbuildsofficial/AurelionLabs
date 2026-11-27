import SwiftUI

struct TestsView: View {
    @Environment(LabStore.self) private var store
    @State private var filter: TestCategory?
    @State private var expanded: Set<String> = []
    @State private var cardPicks: [UUID] = []
    @State private var cardMessage: String?

    private var runner: TestRunner { store.tests }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                summaryCard
                ForEach(TestCategory.allCases.filter { filter == nil || $0 == filter }) { cat in
                    categorySection(cat)
                }
                if !runner.history.isEmpty { historySection }
            }
            .frame(maxWidth: Theme.Size.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .onAppear { if !runner.isRunning && runner.finished.isEmpty { runner.rebuild() } }
    }

    // MARK: Özet

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(runner.passedCount)/\(runner.tests.count)")
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text(runner.finished.isEmpty ? "Henüz çalıştırılmadı" : "test geçti")
                        .font(Theme.Font.callout).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Theme.Space.s) {
                    if runner.isRunning {
                        PrimaryButton(title: "Durdur", symbol: "stop.fill") { runner.stop() }
                    } else {
                        PrimaryButton(title: filter == nil ? "Tümünü çalıştır" : "Bu kategoriyi çalıştır",
                                      symbol: "play.fill", enabled: store.server.isUsable && !store.isGenerating) {
                            runner.params = store.params
                            runner.presetName = store.paramsModified ? "Özel ayar" : (store.activePreset?.name ?? "Özel ayar")
                            runner.runAll(only: filter)
                        }
                    }
                    Text("Ayarlar: \(store.paramsModified ? "özel ayar" : (store.activePreset?.name ?? "özel ayar")) · \(store.server.modelName)")
                        .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                }
            }

            // Kategori çubukları
            VStack(spacing: 10) {
                ForEach(TestCategory.allCases) { c in
                    let s = runner.score(c)
                    HStack(spacing: 10) {
                        Image(systemName: c.symbol).frame(width: 20).foregroundStyle(Theme.primary)
                        Text(c.title).font(Theme.Font.callout).frame(width: 150, alignment: .leading)
                        ProgressBar(value: s.total == 0 ? 0 : Double(s.passed) / Double(s.total))
                        Text("\(s.passed)/\(s.total)")
                            .font(Theme.Font.stat.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            FlowRow(spacing: Theme.Space.s) {
                Chip(title: "Tümü", selected: filter == nil) { filter = nil }
                ForEach(TestCategory.allCases) { c in
                    Chip(title: c.title, selected: filter == c) { filter = c }
                }
            }
            Text("Kod testlerinde modelin yazdığı Python kodu geçici bir klasörde 10 saniye sınırla çalıştırılır. Uzun bağlam testleri sunucunun bağlam boyutuna göre ölçeklenir.")
                .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
        }
        .card(padding: Theme.Space.l)
    }

    // MARK: Kategoriler

    private func categorySection(_ c: TestCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: c.title)
            VStack(spacing: 0) {
                let list = runner.tests.filter { $0.category == c }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { Divider().overlay(Theme.hairline).padding(.leading, 34) }
                    TestRow(test: t, result: runner.results[t.id],
                            expanded: expanded.contains(t.id),
                            toggle: { if expanded.contains(t.id) { expanded.remove(t.id) } else { expanded.insert(t.id) } },
                            rerun: { runner.params = store.params; runner.runOne(t.id) },
                            canRun: !runner.isRunning && store.server.isUsable)
                }
            }
            .card(padding: Theme.Space.s)
        }
    }

    // MARK: Geçmiş

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Önceki çalıştırmalar", trailing: AnyView(
                SecondaryButton(title: cardPicks.count == 2 ? "2 sonucu karta koy" : "Sonuç kartı",
                                symbol: "photo.on.rectangle", tint: Theme.primary) { makeCard() }
                    .help("Seçili 1–2 çalıştırmayı (seçim yoksa en sonuncuyu) paylaşılabilir PNG yapar ve panoya kopyalar.")
            ))
            Text(cardMessage ?? "Karta koymak istediğin en fazla iki çalıştırmayı soldaki daireden seç.")
                .font(Theme.Font.caption)
                .foregroundStyle(cardMessage == nil ? Theme.textTertiary : Theme.textSecondary)
            VStack(spacing: 0) {
                ForEach(Array(runner.history.prefix(12).enumerated()), id: \.element.id) { i, h in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    HStack(spacing: Theme.Space.m) {
                        let picked = cardPicks.contains(h.id)
                        Button { togglePick(h.id) } label: {
                            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(picked ? Theme.primary : Theme.textTertiary)
                                .frame(width: 28, height: 28)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(picked ? "Karttan çıkar" : "Karta ekle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(ModelLibrary.family(of: h.model)) · \(ModelLibrary.quant(of: h.model))")
                                .font(Theme.Font.callout.weight(.semibold))
                            Text("\(h.date.formatted(date: .abbreviated, time: .shortened)) · \(h.preset) · \(h.contextSize / 1024)K bağlam")
                                .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Text(StatsLine.num(h.avgTokensPerSecond, 1) + " token/sn")
                            .font(Theme.Font.stat).foregroundStyle(Theme.textSecondary)
                        Text("\(h.passed)/\(h.total)")
                            .font(Theme.Font.headline.monospacedDigit())
                            .foregroundStyle(Theme.primary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .padding(.vertical, 10)
                    .help(h.failedTests.isEmpty ? "Hepsi geçti" : "Geçemeyenler: " + h.failedTests.joined(separator: ", "))
                    .contextMenu { Button("Sil", role: .destructive) { runner.deleteHistory(h) } }
                }
            }
            .card()
        }
    }
}

private struct ProgressBar: View {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                Capsule().fill(Theme.primaryGradient).frame(width: max(0, g.size.width * value))
            }
        }
        .frame(height: 8)
        .animation(reduce ? Motion.fade : Motion.fill, value: value)
    }
}

private struct TestRow: View {
    let test: TestCase
    let result: TestRunner.Result?
    let expanded: Bool
    let toggle: () -> Void
    let rerun: () -> Void
    let canRun: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    statusIcon.frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(test.title).font(Theme.Font.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        if let v = result?.verdict {
                            Text(v.detail).font(Theme.Font.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        } else if let e = result?.error {
                            Text(e).font(Theme.Font.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let st = result?.stats {
                        Text(StatsLine.num(st.totalSeconds, 1) + " sn · " + StatsLine.num(st.generatedPerSecond, 1) + " t/sn")
                            .font(Theme.Font.stat).foregroundStyle(Theme.textTertiary)
                    }
                    Image(systemName: "chevron.down")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded { details.padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.s) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch result?.status ?? .idle {
        case .idle: Image(systemName: "circle.dashed").foregroundStyle(Theme.textTertiary).accessibilityLabel("Çalıştırılmadı")
        case .running: ProgressView().controlSize(.small).accessibilityLabel("Çalışıyor")
        case .passed: Image(systemName: Theme.Tone.good.symbol).foregroundStyle(Theme.Tone.good.color).accessibilityLabel("Geçti")
        case .failed: Image(systemName: Theme.Tone.danger.symbol).foregroundStyle(Theme.Tone.danger.color).accessibilityLabel("Geçemedi")
        case .error: Image(systemName: Theme.Tone.caution.symbol).foregroundStyle(Theme.Tone.caution.color).accessibilityLabel("Hata")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                if let make = test.image, let img = make() {
                    Image(nsImage: img).resizable().scaledToFit().frame(width: 160)
                        .clipShape(.rect(cornerRadius: Theme.Radius.tile))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile).stroke(Theme.hairline))
                }
                labeled("İstem", test.category == .longContext
                        ? "[\(test.prompt.count.formatted()) karakterlik dolgu metni] … " + String(test.prompt.suffix(90))
                        : test.prompt)
            }
            if let r = result, r.status != .idle && r.status != .running {
                if !r.toolCalls.isEmpty {
                    labeled("Araç çağrısı", r.toolCalls.map { "\($0.name)(\($0.arguments))" }.joined(separator: "\n"), mono: true)
                }
                if !r.answer.isEmpty { labeled("Cevap", r.answer, mono: test.category == .code) }
                if !r.reasoning.isEmpty { ReasoningPanel(text: r.reasoning) }
            }
            HStack {
                Spacer()
                SecondaryButton(title: "Bu testi çalıştır", symbol: "play.fill", tint: Theme.primary, action: rerun)
                    .disabled(!canRun)
            }
        }
    }

    private func labeled(_ title: String, _ text: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Font.small.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(mono ? Theme.Font.mono : Theme.Font.callout)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension TestsView {
    private func togglePick(_ id: UUID) {
        if let i = cardPicks.firstIndex(of: id) { cardPicks.remove(at: i) }
        else { cardPicks.append(id); if cardPicks.count > 2 { cardPicks.removeFirst() } }
    }

    private func makeCard() {
        let picked = cardPicks.compactMap { id in runner.history.first { $0.id == id } }
        let runs = picked.isEmpty ? Array(runner.history.prefix(1)) : picked
        let dir = URL(fileURLWithPath: store.server.config.modelPath).deletingLastPathComponent()
        if let url = ResultCard.export(runs, modelDir: dir) {
            cardMessage = "Kart panoya kopyalandı ve İndirilenler'e kaydedildi: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            cardMessage = "Kart çizilemedi. Tekrar dene."
        }
    }
}
