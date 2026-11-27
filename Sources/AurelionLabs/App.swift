import AppKit
import SwiftUI

@main
struct AurelionLabsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: LabStore

    init() {
        Self.migrateOldDataFolder()
        // Komut satırı testleri her zaman Türkçe koşar; böylece sonuçlar önceki ölçümlerle karşılaştırılabilir kalır.
        if HeadlessTests.isRequested { Lang.current = .tr }
        let server = ServerManager()
        let store = LabStore(server: server)
        AppDelegate.server = server
        _store = State(initialValue: store)
        if HeadlessTests.isRequested {
            let saved = server.config
            HeadlessTests.applyOverrides(server)
            Task { @MainActor in
                await server.bootstrap()
                await HeadlessTests.run(store, restoring: saved)
            }
        }
    }

    /// Eski adla (InklingLab) kaydedilen sohbet, ayar ve test geçmişini yeni klasöre taşır.
    private static func migrateOldDataFolder() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("InklingLab", isDirectory: true)
        let new = support.appendingPathComponent("AurelionLabs", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }
        // Ayarlar eski paket kimliğinin (local.buraktas.inklinglab) alanında kaldı; bir kez buraya kopyalanır.
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromInklingLab") else { return }
        for (k, v) in d.persistentDomain(forName: "local.buraktas.inklinglab") ?? [:]
        where !k.hasPrefix("NS") && d.object(forKey: k) == nil {
            d.set(v, forKey: k)
        }
        d.set(true, forKey: "migratedFromInklingLab")
    }

    var body: some Scene {
        WindowGroup("AurelionLabs") {
            RootView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 660)
                .task {
                    // Test modu pencereye bağlı değil (görünüm yeniden oluşunca .task iptal edilir).
                    guard !HeadlessTests.isRequested else { return }
                    await store.server.bootstrap()
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Yeni sohbet")) { store.newChat(); store.mode = .chat }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("Ayarlar…")) { store.mode = .settings }.keyboardShortcut(",")
            }
            CommandMenu("Model") {
                Button(L("Cevabı durdur")) { store.stop() }.keyboardShortcut(".")
                Button(L("Son cevabı yeniden üret")) { store.regenerateLast() }.keyboardShortcut("r")
                Divider()
                Button(L("Düşünmeyi göster/gizle")) { store.showReasoning.toggle() }.keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var server: ServerManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if HeadlessTests.isRequested {
            // Test modu görünmez çalışır: Dock simgesi ve pencere yok, kullanıcı yanlışlıkla kapatamaz.
            NSApp.setActivationPolicy(.prohibited)
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Test modunda pencere kapanması uygulamayı kapatmaz; testler bitince HeadlessTests kendisi kapatır.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !HeadlessTests.isRequested }

    func applicationWillTerminate(_ notification: Notification) {
        Self.server?.terminateSync()
    }
}
