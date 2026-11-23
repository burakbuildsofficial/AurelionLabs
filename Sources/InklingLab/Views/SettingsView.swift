import SwiftUI

struct SettingsView: View {
    @Environment(LabStore.self) private var store
    @State private var savingPreset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                ModelsSection()
                presetsSection
                samplingSection
                systemSection
                ServerSection()
                AppearanceSection()
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.l)
        }
        .sheet(isPresented: $savingPreset) { SavePresetSheet() }
    }

    // MARK: Ön ayarlar

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Ön ayar")
            VStack(alignment: .leading, spacing: 12) {
                FlowRow(spacing: Theme.Space.s) {
                    ForEach(store.presets) { p in
                        let selected = p.id == store.activePresetID
                        Chip(title: p.name, selected: selected, dirty: selected && store.paramsModified) {
                            store.apply(p)
                        }
                        .contextMenu {
                            if !p.builtIn {
                                Button("Sil", role: .destructive) { store.delete(p) }
                            }
                        }
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    SecondaryButton(title: "Yeni olarak kaydet", symbol: "plus") { savingPreset = true }
                    if store.paramsModified, let p = store.activePreset, !p.builtIn {
                        SecondaryButton(title: "Güncelle", symbol: "square.and.arrow.down") { store.updateActivePreset() }
                    }
                }
                if store.paramsModified {
                    Text(store.activePreset == nil ? "Şu an özel ayar kullanılıyor."
                         : "Noktalı ön ayarda değişiklik var. Hazır ön ayarlar değişmez, yenisi olarak kaydedebilirsin.")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .card()
        }
    }

    // MARK: Örnekleme

    private var samplingSection: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Örnekleme", trailing: AnyView(
                Button("Önerilene dön") { store.params = SamplingParams(systemPrompt: store.params.systemPrompt) }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            ))
            VStack(alignment: .leading, spacing: 0) {
                ParamSlider(title: "Sıcaklık", value: $store.params.temperature, range: 0...2, step: 0.05,
                            help: "Düşük: tutarlı ve tekrar eden. Yüksek: yaratıcı ve dağınık. Önerilen 1,0.")
                Divider().overlay(Theme.hairline).padding(.vertical, 10)
                ParamSlider(title: "Top-p", value: $store.params.topP, range: 0.05...1, step: 0.01,
                            help: "Olasılık toplamı bu değere ulaşan kelimeler arasından seçer. 1,0 = kırpma yok.")
                Divider().overlay(Theme.hairline).padding(.vertical, 10)
                ParamSlider(title: "Min-p", value: $store.params.minP, range: 0...0.5, step: 0.01,
                            help: "En olası kelimeye göre bu oranın altındaki kelimeleri eler. 0 = kapalı.")
                Divider().overlay(Theme.hairline).padding(.vertical, 10)
                IntSlider(title: "Top-k", value: $store.params.topK, range: 0...200, step: 1, zeroLabel: "kapalı",
                          help: "Yalnız en olası k kelime arasından seçer. 0 = kapalı.")
                Divider().overlay(Theme.hairline).padding(.vertical, 10)
                IntSlider(title: "En fazla token", value: $store.params.maxTokens, range: 256...32768, step: 256,
                          help: "Düşünme dahil, bir cevapta üretilecek en fazla token.")
                Divider().overlay(Theme.hairline).padding(.vertical, 10)
                Toggle(isOn: $store.showReasoning) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Düşünmeyi göster").font(Theme.Font.callout.weight(.semibold))
                        Text("Modelin cevaptan önceki akıl yürütmesi.").font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.primary)
            }
            .card()
        }
    }

    // MARK: Sistem promptu

    private var systemSection: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Sistem promptu")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ZStack(alignment: .topLeading) {
                    if store.params.systemPrompt.isEmpty {
                        Text("Modelin rolünü ve üslubunu yaz. Örnek: Her zaman Türkçe ve kısa cevap ver.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $store.params.systemPrompt)
                        .font(Theme.Font.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                }
                Text("Bir sonraki mesajdan itibaren geçerli.")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.textTertiary)
            }
            .card()
        }
    }
}

struct ParamSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.Font.callout.weight(.semibold))
                Spacer()
                Text(StatsLine.num(value, 2))
                    .font(Theme.Font.stat.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }
            // `step:` macOS'ta her adıma çentik çizer; yuvarlamayı bağlamada yapıyoruz.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .tint(Theme.primary)
                .accessibilityLabel(title)
            Text(help).font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IntSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    var zeroLabel: String?
    let help: String

    var body: some View {
        ParamSliderInt(title: title, value: $value, range: range, step: step, zeroLabel: zeroLabel, help: help)
    }
}

private struct ParamSliderInt: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    var zeroLabel: String?
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.Font.callout.weight(.semibold))
                Spacer()
                Text(value == 0 && zeroLabel != nil ? zeroLabel! : value.formatted(.number.locale(Locale(identifier: "tr_TR"))))
                    .font(Theme.Font.stat.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }
            Slider(value: Binding(get: { Double(value) },
                                  set: { value = Int(($0 / Double(step)).rounded()) * step }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
                .tint(Theme.primary)
                .accessibilityLabel(title)
            Text(help).font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SavePresetSheet: View {
    @Environment(LabStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Ön ayarı kaydet").font(Theme.Font.title)
            Text("Şu anki sıcaklık, top-p, min-p, top-k, token sınırı ve sistem promptu kaydedilir.")
                .font(Theme.Font.callout).foregroundStyle(Theme.textSecondary)
            TextField("Ad, örneğin: Kısa Türkçe", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                SecondaryButton(title: "Vazgeç") { dismiss() }
                PrimaryButton(title: "Kaydet", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, action: save)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 400)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.saveCurrentAsPreset(named: name)
        dismiss()
    }
}

// MARK: Sunucu

struct ServerSection: View {
    @Environment(LabStore.self) private var store
    @State private var showLog = false

    private let contexts = [4096, 8192, 16384, 32768, 65536]

    var body: some View {
        let server = store.server
        @Bindable var bserver = server
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Sunucu (llama.cpp)")
            VStack(alignment: .leading, spacing: 12) {
                statusRow(server.state)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Bağlam boyutu").font(Theme.Font.callout.weight(.semibold))
                    FlowRow(spacing: 6) {
                        ForEach(contexts, id: \.self) { c in
                            Chip(title: "\(c / 1024)K", selected: server.config.contextSize == c) {
                                bserver.config.contextSize = c
                            }
                        }
                    }
                    Text("Daha uzun bağlam daha çok bellek ister. Model dosyası + bağlam, Mac'in belleğinin yaklaşık dörtte üçünü geçmesin.")
                        .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                }

                let hasVision = store.currentModel?.mmproj != nil
                Toggle(isOn: $bserver.config.imagesEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resim desteği").font(Theme.Font.callout.weight(.semibold))
                        Text(hasVision ? "Modelin resim dosyasını (mmproj) da yükler, biraz ek bellek kullanır."
                                       : "Bu modelin klasöründe resim dosyası (mmproj) yok.")
                            .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.primary)
                .disabled(!hasVision)

                if server.needsRestart {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: Theme.Tone.mild.symbol).foregroundStyle(Theme.Tone.mild.color)
                        Text("Bu değişiklik model yeniden yüklenince geçerli olur.")
                            .font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        SecondaryButton(title: "Şimdi uygula", symbol: "arrow.clockwise", tint: Theme.primary) { server.restart() }
                    }
                }

                HStack(spacing: Theme.Space.s) {
                    switch server.state {
                    case .ready, .starting:
                        SecondaryButton(title: "Yeniden yükle", symbol: "arrow.clockwise") { server.restart() }
                        SecondaryButton(title: "Bellekten kaldır", symbol: "power", tint: Theme.Tone.danger.color) { server.unload() }
                    case .external:
                        SecondaryButton(title: "Devral ve yeniden yükle", symbol: "arrow.clockwise", tint: Theme.primary) { server.restart() }
                        SecondaryButton(title: "Kapat", symbol: "power", tint: Theme.Tone.danger.color) { server.unload() }
                    case .switching:
                        ProgressView().controlSize(.small)
                    case .stopped, .failed:
                        SecondaryButton(title: "Yükle", symbol: "play.fill", tint: Theme.primary) { server.restart() }
                    }
                }

                DisclosureGroup(isExpanded: $showLog) {
                    ScrollView {
                        Text(server.logTail.suffix(60).joined(separator: "\n"))
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .padding(8)
                    .background(Theme.surfaceRaised, in: .rect(cornerRadius: Theme.Radius.tile))
                } label: {
                    Text("Sunucu kaydı").font(Theme.Font.callout.weight(.semibold))
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        PathField(title: "llama-server", path: $bserver.config.serverPath)
                        PathField(title: "Model (.gguf)", path: $bserver.config.modelPath)
                        PathField(title: "Resim (mmproj)", path: $bserver.config.mmprojPath)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Dosya yolları").font(Theme.Font.callout.weight(.semibold))
                }
            }
            .card()
        }
    }

    @ViewBuilder
    private func statusRow(_ state: ServerManager.State) -> some View {
        let (tone, title, detail): (Theme.Tone, String, String) = switch state {
        case .stopped: (.unknown, "Kapalı", "Başlatınca model yaklaşık 10 saniyede yüklenir.")
        case .starting: (.mild, "Model yükleniyor", "Büyüklüğüne göre 5–30 saniye sürer.")
        case .switching: (.mild, "Model değiştiriliyor", "Eski model bellekten çıkarılıyor.")
        case .ready: (.good, "Hazır", "127.0.0.1:\(store.server.config.port) · yalnız bu Mac'ten erişilir")
        case .external: (.good, "Hazır (harici)", "Bu sunucuyu başka bir yer açmış. Model menüsünden seçim yapınca yönetim bu uygulamaya geçer.")
        case .failed(let msg): (.danger, "Çalışmıyor", msg)
        }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.symbol).foregroundStyle(tone.color).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.callout.weight(.semibold))
                Text(detail).font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct PathField: View {
    let title: String
    @Binding var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 6) {
                TextField(title, text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                Image(systemName: FileManager.default.fileExists(atPath: path) ? Theme.Tone.good.symbol : Theme.Tone.danger.symbol)
                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? Theme.Tone.good.color : Theme.Tone.danger.color)
                    .accessibilityLabel(FileManager.default.fileExists(atPath: path) ? "Dosya bulundu" : "Dosya yok")
            }
        }
    }
}
