import AppKit
import SwiftUI

@main
struct InklingLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: LabStore

    init() {
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

    var body: some Scene {
        WindowGroup("Inkling Lab") {
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
                Button("Yeni sohbet") { store.newChat(); store.mode = .chat }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Ayarlar…") { store.mode = .settings }.keyboardShortcut(",")
            }
            CommandMenu("Model") {
                Button("Cevabı durdur") { store.stop() }.keyboardShortcut(".")
                Button("Son cevabı yeniden üret") { store.regenerateLast() }.keyboardShortcut("r")
                Divider()
                Button("Düşünmeyi göster/gizle") { store.showReasoning.toggle() }.keyboardShortcut("t", modifiers: [.command, .shift])
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
