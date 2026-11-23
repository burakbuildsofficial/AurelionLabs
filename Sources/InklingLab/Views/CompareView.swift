import SwiftUI

struct CompareView: View {
    @Environment(LabStore.self) private var store
    @State private var importing = false

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        if store.comparePrompt.isEmpty {
                            Text("Karşılaştırılacak soruyu yaz…")
                                .font(Theme.Font.body).foregroundStyle(Theme.textTertiary)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                        TextEditor(text: $store.comparePrompt)
                            .font(Theme.Font.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 70, maxHeight: 140)
                    }
                    if !store.compareImages.isEmpty {
                        HStack(spacing: Theme.Space.s) {
                            ForEach(store.compareImages) { img in
                                AttachmentThumb(image: img) { store.compareImages.removeAll { $0.id == img.id } }
                            }
                        }
                    }
                    Divider().overlay(Theme.hairline)
                    HStack(spacing: Theme.Space.m) {
                        presetPicker("A", selection: $store.compareA)
                        presetPicker("B", selection: $store.compareB)
                        RoundAction(symbol: "photo.badge.plus", label: "Resim ekle") { importing = true }
                            .disabled(!store.server.imagesAvailable)
                        Spacer()
                        if store.isComparing {
                            PrimaryButton(title: "Durdur", symbol: "stop.fill") { store.stop() }
                        } else {
                            PrimaryButton(title: "Karşılaştır", symbol: "play.fill", enabled: store.canCompare) { store.runCompare() }
                        }
                    }
                    Text("İki cevap sırayla üretilir, böylece hız ölçümleri birbirini etkilemez.")
                        .font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                }
                .card()
                .dropDestination(for: URL.self) { urls, _ in
                    let imgs = urls.compactMap(ImageLoader.attachment(from:))
                    store.compareImages += imgs
                    return !imgs.isEmpty
                }

                HStack(alignment: .top, spacing: Theme.Space.m) {
                    resultColumn(0, label: "A")
                    resultColumn(1, label: "B")
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                store.compareImages += urls.compactMap { url in
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    return ImageLoader.attachment(from: url)
                }
            }
        }
    }

    private func presetPicker(_ label: String, selection: Binding<Preset.ID?>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.Font.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.primary, in: .circle)
            Picker(label, selection: selection) {
                ForEach(store.presets) { p in Text(p.name).tag(Optional(p.id)) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    @ViewBuilder
    private func resultColumn(_ side: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            let name = store.presets.first { $0.id == (side == 0 ? store.compareA : store.compareB) }?.name ?? "-"
            Text("\(label) · \(name)").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            if let result = store.compareResults[side] {
                MessageRow(message: result, showReasoning: store.showReasoning, compact: true)
                    .riseIn()
            } else {
                Text(store.isComparing ? "Sırasını bekliyor…" : "Sonuç burada görünecek.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.textTertiary)
                    .card()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
