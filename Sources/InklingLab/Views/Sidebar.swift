import SwiftUI

/// Sol kenar çubuğu: bölümler üstte, sohbetler altta (sabitlenenler, bugün, dün…).
struct Sidebar: View {
    @Environment(LabStore.self) private var store
    @State private var renaming: Conversation?
    @State private var newTitle = ""

    enum Item: Hashable { case mode(LabStore.Mode), chat(UUID) }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(LabStore.Mode.allCases) { m in
                    Label(m.title, systemImage: m.symbol).tag(Item.mode(m))
                }
            }

            let list = store.filteredConversations
            let pinned = list.filter(\.isPinned)
            if !pinned.isEmpty {
                Section("Sabitlenenler") { ForEach(pinned) { row($0) } }
            }
            ForEach(Self.groups(list.filter { !$0.isPinned }), id: \.title) { g in
                Section(g.title) { ForEach(g.items) { row($0) } }
            }
            if list.isEmpty {
                Section {
                    Text(store.historyQuery.isEmpty
                         ? "Sohbetlerin burada birikir. İlk mesajla kaydedilir."
                         : "Bu aramayla eşleşen sohbet yok.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .alert("Sohbeti yeniden adlandır", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Ad", text: $newTitle)
            Button("Kaydet") { if let r = renaming { store.rename(r, to: newTitle) }; renaming = nil }
            Button("Vazgeç", role: .cancel) { renaming = nil }
        }
    }

    private var selection: Binding<Item?> {
        Binding(
            get: {
                if store.mode == .chat { return store.currentID.map(Item.chat) ?? .mode(.chat) }
                return .mode(store.mode)
            },
            set: { item in
                switch item {
                case .mode(.chat): store.newChat(); store.mode = .chat
                case .mode(let m): store.mode = m
                case .chat(let id): if let c = store.conversations.first(where: { $0.id == id }) { store.open(c) }
                case nil: break
                }
            })
    }

    private func row(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if c.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                }
                Text(c.title).lineLimit(1)
            }
            .font(Theme.Font.callout.weight(.medium))
            Text(c.preview.isEmpty ? "\(c.messages.count) mesaj" : c.preview)
                .font(Theme.Font.small)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                if let m = c.model {
                    Text(ModelLibrary.quant(of: m).isEmpty ? m : ModelLibrary.quant(of: m))
                    Text("·")
                }
                Text(c.updated.formatted(Self.isOld(c.updated) ? .dateTime.day().month() : .dateTime.hour().minute()))
            }
            .font(Theme.Font.small)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .tag(Item.chat(c.id))
        .contextMenu {
            Button(c.isPinned ? "Sabitlemeyi kaldır" : "Sabitle", systemImage: c.isPinned ? "pin.slash" : "pin") {
                store.togglePin(c)
            }
            Button("Yeniden adlandır", systemImage: "pencil") { newTitle = c.title; renaming = c }
            Button("Markdown olarak kaydet…", systemImage: "square.and.arrow.down") { store.export(c) }
            Divider()
            Button("Sil", systemImage: "trash", role: .destructive) { store.delete(c) }
        }
    }

    private static func isOld(_ d: Date) -> Bool { !Calendar.current.isDateInToday(d) }

    private struct Group { let title: String; let items: [Conversation] }

    private static func groups(_ list: [Conversation]) -> [Group] {
        let cal = Calendar.current
        var buckets: [(String, [Conversation])] = [("Bugün", []), ("Dün", []), ("Son 7 gün", []), ("Daha eski", [])]
        for c in list {
            let i = cal.isDateInToday(c.updated) ? 0
                : cal.isDateInYesterday(c.updated) ? 1
                : c.updated > Date().addingTimeInterval(-7 * 86_400) ? 2 : 3
            buckets[i].1.append(c)
        }
        return buckets.filter { !$0.1.isEmpty }.map { Group(title: $0.0, items: $0.1) }
    }
}

/// Üst çubuktaki model menüsü: durum, tek tıkla model değiştirme, yükle/kapat.
struct ModelMenu: View {
    @Environment(LabStore.self) private var store

    var body: some View {
        let server = store.server
        let busy = store.isGenerating || store.tests.isRunning
        Menu {
            Section("Bu Mac'teki modeller") {
                ForEach(store.library.models) { m in
                    Button { store.load(m) } label: {
                        let current = m.path == server.config.modelPath
                        Label(Self.label(m), systemImage: current ? "checkmark" : (m.mmproj != nil ? "photo" : "text.alignleft"))
                    }
                    .disabled(busy || server.isBusy)
                }
                if store.library.models.isEmpty {
                    Text("Model bulunamadı. Ayarlar › Modeller'den klasör ekle.")
                }
            }
            Divider()
            switch server.state {
            case .ready, .starting, .external:
                Button("Modeli bellekten kaldır", systemImage: "power") { server.unload() }
                    .disabled(busy)
            case .stopped, .failed:
                Button("Modeli yükle", systemImage: "play.fill") { server.restart() }
            case .switching:
                Text("Model değiştiriliyor…")
            }
            Button("Listeyi yenile", systemImage: "arrow.clockwise") { store.library.scan() }
            Button("Model ayarları…", systemImage: "gearshape") { store.mode = .settings }
        } label: {
            Text(title).lineLimit(1)
        }
        .help("Modeli değiştir, yükle ya da bellekten kaldır")
    }
}

/// Model durumu: menü etiketleri renk taşımadığı için ayrı gösterilir (renk + ikon + ipucu).
struct ModelStatusDot: View {
    @Environment(LabStore.self) private var store

    var body: some View {
        status
            .frame(width: 18)
            .help(help)
            .accessibilityLabel(help)
    }

    private var help: String {
        switch store.server.state {
        case .starting, .switching: "Model yükleniyor"
        case .ready: "Model hazır"
        case .external: "Model hazır (başka bir yerden açılmış sunucu)"
        case .stopped: "Model kapalı"
        case .failed(let m): "Model açılamadı: " + m
        }
    }

    @ViewBuilder private var status: some View {
        switch store.server.state {
        case .starting, .switching: ProgressView().controlSize(.small)
        case .ready, .external: Image(systemName: Theme.Tone.good.symbol).foregroundStyle(Theme.Tone.good.color)
        case .stopped: Image(systemName: "power.circle").foregroundStyle(Theme.Tone.unknown.color)
        case .failed: Image(systemName: Theme.Tone.danger.symbol).foregroundStyle(Theme.Tone.danger.color)
        }
    }
}

extension ModelMenu {
    var title: String {
        let name = store.currentModel.map { "\($0.family) · \($0.quant)" } ?? store.server.modelName
        switch store.server.state {
        case .switching, .starting: return "Yükleniyor: " + name
        case .stopped: return "Model kapalı"
        case .failed: return "Model açılamadı"
        default: return name
        }
    }

    static func label(_ m: ModelLibrary.Model) -> String {
        "\(m.family) · \(m.quant.isEmpty ? m.fileName : m.quant) · \(StatsLine.num(m.sizeGB, 1)) GB" + (m.fileName.contains("-AD-") ? " · Atomic" : "")
    }
}

/// Üst çubuktaki ön ayar menüsü.
struct PresetMenu: View {
    @Environment(LabStore.self) private var store

    var body: some View {
        Menu {
            ForEach(store.presets) { p in
                Button { store.apply(p) } label: {
                    if p.id == store.activePresetID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button(store.showReasoning ? "Düşünmeyi gizle" : "Düşünmeyi göster", systemImage: "brain") {
                store.showReasoning.toggle()
            }
            Button("Ön ayarları düzenle…", systemImage: "slider.horizontal.3") { store.mode = .settings }
        } label: {
            Label(store.paramsModified ? "Özel ayar" : (store.activePreset?.name ?? "Özel ayar"),
                  systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
        }
        .help("Ön ayar: sıcaklık, token sınırı, sistem promptu")
    }
}
