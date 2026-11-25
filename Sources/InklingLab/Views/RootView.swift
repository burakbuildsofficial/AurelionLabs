import SwiftUI

struct RootView: View {
    @Environment(LabStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                switch store.mode {
                case .chat: ChatView()
                case .documents: DocumentsView()
                case .compare: CompareView()
                case .tests: TestsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageBackground()
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.mode == .chat || store.mode == .tests || store.mode == .documents { PresetMenu() }
                    ModelStatusDot()
                    ModelMenu()
                    if store.mode == .chat {
                        Button("Yeni sohbet", systemImage: "square.and.pencil") { store.newChat() }
                            .help("Yeni sohbet (⌘N)")
                    }
                }
            }
        }
        .searchable(text: $store.historyQuery, placement: .sidebar, prompt: "Sohbetlerde ara")
        .id(store.palette)          // renk değişince her şeyi yeni renkle çiz
        .tint(Theme.primary)
        .onAppear { store.appearance.apply() }
    }

    private var title: String {
        switch store.mode {
        case .chat: store.conversations.first { $0.id == store.currentID }?.title ?? "Yeni sohbet"
        default: store.mode.title
        }
    }

    private var subtitle: String {
        switch store.mode {
        case .chat:
            if let c = store.conversations.first(where: { $0.id == store.currentID }) {
                return "\(c.messages.count) mesaj"
            }
            return "Tamamen bu Mac'te, internet yok"
        case .documents: return "Klasör ya da dosyaları özetle, soru sor, kaynağını gör"
        case .compare: return "Aynı soru, iki ön ayar, yan yana"
        case .tests: return "Modelin sınırlarını otomatik testlerle ölç"
        case .settings: return "Modeller, ön ayarlar, sunucu ve görünüm"
        }
    }
}
