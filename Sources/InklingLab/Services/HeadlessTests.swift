import AppKit

/// `InklingLab --run-tests [--only <kategori>]`: testleri çalıştırır, sonucu stdout'a yazar, uygulamayı kapatır.
/// Sonuç ayrıca "Önceki çalıştırmalar" listesine kaydedilir (yalnız tüm testler çalıştığında).
@MainActor
enum HeadlessTests {
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("--run-tests") }

    /// `--model <yol>` ve `--ctx <sayı>` yalnız bu çalıştırma için geçerli; sonunda eski ayar geri yüklenir.
    static func applyOverrides(_ server: ServerManager) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
            server.config.modelPath = NSString(string: args[i + 1]).expandingTildeInPath
        }
        if let i = args.firstIndex(of: "--ctx"), i + 1 < args.count, let n = Int(args[i + 1]) {
            server.config.contextSize = n
        }
    }

    static func run(_ store: LabStore, restoring saved: ServerManager.Config) async {
        let args = CommandLine.arguments
        var only: TestCategory?
        if let i = args.firstIndex(of: "--only"), i + 1 < args.count { only = TestCategory(rawValue: args[i + 1]) }

        for _ in 0..<240 where !store.server.isUsable {
            if case .failed(let msg) = store.server.state { print("SUNUCU HATASI: \(msg)"); break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard store.server.isUsable else { print("Sunucu hazır olmadı."); store.server.config = saved; NSApp.terminate(nil); return }

        store.mode = .tests
        let runner = store.tests
        runner.params = store.activePreset?.params ?? .recommended
        runner.presetName = store.activePreset?.name ?? "Önerilen"
        runner.runAll(only: only)
        print("MODEL: \(store.server.modelName) · bağlam \(store.server.runningConfig?.contextSize ?? store.server.config.contextSize)")
        while runner.isRunning { try? await Task.sleep(for: .milliseconds(300)) }

        for t in runner.tests where only == nil || t.category == only {
            guard let r = runner.results[t.id] else { continue }
            let mark = switch r.status {
            case .passed: "GEÇTİ "
            case .failed: "KALDI "
            case .error: "HATA  "
            default: "—     "
            }
            let speed = r.stats.map { String(format: "%5.1fs %5.1f t/s", $0.totalSeconds, $0.generatedPerSecond) } ?? ""
            let detail = r.verdict?.detail ?? r.error ?? ""
            print("\(mark) [\(t.category.title)] \(t.title) · \(speed) · \(detail)")
            if r.status != .passed {
                let ans = r.toolCalls.isEmpty ? r.answer : r.toolCalls.map { "\($0.name)(\($0.arguments))" }.joined(separator: "; ")
                print("        cevap: " + ans.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(300))
            }
        }
        print("TOPLAM: \(runner.passedCount)/\(runner.tests.filter { only == nil || $0.category == only }.count)")
        fflush(stdout)
        store.server.config = saved; NSApp.terminate(nil)
    }
}
