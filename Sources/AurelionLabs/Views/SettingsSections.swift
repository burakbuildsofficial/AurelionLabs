import AppKit
import SwiftUI

/// Ayarlar › Modeller: bu Mac'teki GGUF dosyaları, tek tıkla yükleme, taranan klasörler.
struct ModelsSection: View {
    @Environment(LabStore.self) private var store

    var body: some View {
        let lib = store.library
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L("Modeller"), trailing: AnyView(
                Button(L("Yenile")) { lib.scan() }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            ))
            VStack(alignment: .leading, spacing: 0) {
                if lib.models.isEmpty {
                    Text(L("Taranan klasörlerde .gguf model yok. Aşağıdan modellerinin olduğu klasörü ekle."))
                        .font(Theme.Font.callout).foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 6)
                }
                ForEach(Array(lib.models.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    row(m).padding(.vertical, 10)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L("Taranan klasörler")).font(Theme.Font.callout.weight(.semibold))
                ForEach(lib.folders, id: \.self) { f in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.textTertiary)
                        Text(f.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(Theme.Font.mono).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button { lib.removeFolder(f) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel(L("Klasörü listeden çıkar"))
                    }
                }
                SecondaryButton(title: L("Klasör ekle"), symbol: "plus") { addFolder() }
                Text(L("Alt klasörler de taranır. Aynı klasörde mmproj dosyası olan model resim de okuyabilir."))
                    .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
            }
            .card()
        }
    }

    private func row(_ m: ModelLibrary.Model) -> some View {
        let server = store.server
        let current = m.path == server.config.modelPath
        let ramGB = Double(ResultCard.memoryGB)
        let heavy = m.sizeGB > ramGB * 0.7
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: m.mmproj != nil ? "photo.on.rectangle" : "text.bubble")
                .font(.system(size: 18))
                .foregroundStyle(current ? Theme.primary : Theme.textTertiary)
                .frame(width: 28)
                .help(m.mmproj != nil ? L("Resim okuyabilir") : L("Yalnız metin"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.family).font(Theme.Font.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    if m.fileName.contains("-AD-") {
                        Label(L("Atomic Engine"), systemImage: "bolt.fill")
                            .font(Theme.Font.small.weight(.semibold))
                            .foregroundStyle(Theme.Tone.mild.color)
                            .help(L("Bu model Atomic Engine ile açılır: bellek bütçesi + DSpark taslak model, 4K bağlam"))
                    }
                    if !m.quant.isEmpty {
                        Text(m.bits.map { "\($0) · \(m.quant)" } ?? m.quant)
                            .font(Theme.Font.small.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.primarySoft, in: .capsule)
                    }
                }
                HStack(spacing: 4) {
                    Text(StatsLine.num(m.sizeGB, 1) + " GB")
                    Text("·")
                    Text(m.folder)
                    if heavy {
                        Text("·")
                        Label(L("bu Mac için ağır"), systemImage: Theme.Tone.caution.symbol)
                            .foregroundStyle(Theme.Tone.caution.color)
                    }
                }
                .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if current && server.isBusy {
                ProgressView().controlSize(.small)
                Text(L("Yükleniyor")).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            } else if current && server.isUsable {
                Label(L("Yüklü"), systemImage: Theme.Tone.good.symbol)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Tone.good.color)
                SecondaryButton(title: L("Kaldır"), symbol: "power") { server.unload() }
            } else {
                SecondaryButton(title: L("Yükle"), symbol: "arrow.down.circle", tint: Theme.primary) { store.load(m) }
                    .disabled(store.isGenerating || store.tests.isRunning || server.isBusy)
            }
        }
        .help(m.path)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Ekle")
        panel.message = L("GGUF modellerinin bulunduğu klasörü seç")
        if panel.runModal() == .OK, let url = panel.url { store.library.addFolder(url.path) }
    }
}

/// Ayarlar › Görünüm: tema ve ana renk.
struct AppearanceSection: View {
    @Environment(LabStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L("Görünüm"))
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Dil")).font(Theme.Font.callout.weight(.semibold))
                    HStack(spacing: Theme.Space.s) {
                        ForEach(Lang.allCases) { l in
                            Chip(title: l.title, selected: store.language == l) { store.language = l }
                        }
                    }
                    Text(L("Arayüzün dili. Test istemleri Türkçe kalır, çünkü ölçümün kendisi onlar."))
                        .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                }
                Divider().overlay(Theme.hairline)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Tema")).font(Theme.Font.callout.weight(.semibold))
                    HStack(spacing: Theme.Space.s) {
                        ForEach(Appearance.allCases) { a in
                            Button { store.appearance = a } label: {
                                Label(a.title, systemImage: a.symbol)
                                    .font(Theme.Font.callout.weight(store.appearance == a ? .semibold : .regular))
                                    .foregroundStyle(store.appearance == a ? .white : Theme.textPrimary)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(store.appearance == a ? Theme.primary : Theme.surfaceRaised,
                                                in: .rect(cornerRadius: Theme.Radius.chip, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
                Divider().overlay(Theme.hairline)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Ana renk")).font(Theme.Font.callout.weight(.semibold))
                    HStack(spacing: 14) {
                        ForEach(Palette.allCases, id: \.self) { p in
                            Button { store.palette = p } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(LinearGradient(colors: [p.tones.primary, p.tones.light],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            if store.palette == p {
                                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                            }
                                        }
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(store.palette == p ? p.tones.primary : .clear, lineWidth: 2))
                                    Text(p.title).font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(L("Ana renk: \(p.title)"))
                        }
                    }
                }
            }
            .card()
        }
    }
}
