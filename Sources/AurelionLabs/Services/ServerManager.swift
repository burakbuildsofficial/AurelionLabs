import Darwin
import Foundation
import Observation

/// llama-server sürecini başlatır, durdurur, hazır olmasını izler.
@MainActor
@Observable
final class ServerManager {
    enum State: Equatable {
        case stopped
        case starting
        case switching     // model değişiyor: eski kapanıyor, yenisi yüklenecek
        case ready
        case external      // başka bir yerden açılmış sunucu (bu uygulama durduramaz)
        case failed(String)
    }

    struct Config: Codable, Equatable {
        var serverPath = NSString("~/llama.cpp/build/bin/llama-server").expandingTildeInPath
        var modelPath = NSString("~/models/inkling-2-mini/Inkling-2-Mini-UD-IQ3_XXS.gguf").expandingTildeInPath
        var mmprojPath = NSString("~/models/inkling-2-mini/mmproj-F16.gguf").expandingTildeInPath
        var contextSize = 16384
        var port = 8001
        var imagesEnabled = true
        // Atomic Engine (yalnız adında "-AD-" geçen modellerde). Eski kayıtlar bozulmasın diye isteğe bağlı.
        var atomicServerPath: String?
        var atomicBudgetGiB: Int?

        static let atomicContext = 4096
        var usesAtomic: Bool { URL(fileURLWithPath: modelPath).lastPathComponent.contains("-AD-") }
        var atomicServer: String {
            atomicServerPath ?? NSString("~/atomic-engine/build-metal/bin/llama-server").expandingTildeInPath
        }
        var budgetGiB: Int { atomicBudgetGiB ?? 14 }
        var engineName: String { usesAtomic ? "Atomic Engine" : "llama.cpp" }

        /// Modelin klasöründeki DSpark taslak modeli.
        var draftPath: String? {
            let dir = URL(fileURLWithPath: modelPath).deletingLastPathComponent()
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.first { $0.lastPathComponent.lowercased().hasPrefix("dspark") && $0.pathExtension == "gguf" }?.path
        }
    }

    private(set) var state: State = .stopped
    private(set) var logTail: [String] = []
    private(set) var runningConfig: Config?
    var config: Config { didSet { save() } }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(runningConfig?.port ?? config.port)")! }
    var isUsable: Bool { state == .ready || state == .external }
    var needsRestart: Bool {
        guard var r = runningConfig else { return false }
        r.imagesEnabled = config.imagesEnabled   // mmproj'u olmayan model için kendiliğinden kapanır
        if r.usesAtomic { r.contextSize = config.contextSize }   // Atomic her zaman 4K açılır
        return r != config
    }
    var imagesAvailable: Bool {
        if state == .external { return true }
        return (runningConfig ?? config).imagesEnabled
    }
    var modelName: String {
        URL(fileURLWithPath: (runningConfig ?? config).modelPath).deletingPathExtension().lastPathComponent
    }
    var isBusy: Bool { state == .starting || state == .switching }

    private var process: Process?
    private var bootstrapped = false
    private var watchTask: Task<Void, Never>?
    private static let configKey = "serverConfig"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(Config.self, from: data) {
            config = saved
        } else {
            config = Config()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.configKey) }
    }

    /// Açılışta: önceki oturumdan kalan kendi sunucumuzu kapat; başka biri açtıysa onu kullan, yoksa başlat.
    func bootstrap() async {
        // Yalnız bir kez: pencere görünümü yeniden oluşursa kendi sunucumuzu "artık süreç" sanıp kapatmayalım.
        guard !bootstrapped else { return }
        bootstrapped = true
        await reapLeftover()
        if await Self.health(port: config.port) == .ok {
            state = .external
            append("127.0.0.1:\(config.port) üzerinde çalışan bir sunucu bulundu, o kullanılıyor.")
        } else {
            start()
        }
        watchAlive()
    }

    // MARK: Önceki oturumdan kalan süreç

    private static var pidFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InklingLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("server.pid")
    }

    /// Uygulama kapanırken sunucu yavaş kapanırsa ya da uygulama çökerse kalan süreci temizler.
    private func reapLeftover() async {
        guard let s = try? String(contentsOf: Self.pidFile, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        try? FileManager.default.removeItem(at: Self.pidFile)
        guard Self.isLlamaServer(pid) else { return }
        append("Önceki oturumdan kalan sunucu (pid \(pid)) kapatılıyor.")
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    private static func isLlamaServer(_ pid: pid_t) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.hasSuffix("llama-server")
    }

    /// Harici sunucu kapanırsa durumu güncelle.
    private func watchAlive() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if self.state == .external, await Self.health(port: self.config.port) == .down {
                    self.state = .stopped
                    self.append("Harici sunucu kapandı.")
                }
            }
        }
    }

    func start() {
        guard process == nil else { return }
        let fm = FileManager.default
        if config.usesAtomic { startAtomic(); return }
        guard fm.isExecutableFile(atPath: config.serverPath) else {
            state = .failed("llama-server bulunamadı: \(config.serverPath). Yolu Sunucu bölümünden düzelt.")
            return
        }
        guard fm.fileExists(atPath: config.modelPath) else {
            state = .failed("Model dosyası bulunamadı: \(config.modelPath). Yolu Sunucu bölümünden düzelt.")
            return
        }
        var args = ["-m", config.modelPath,
                    "--jinja", "-ngl", "99",
                    "-c", String(config.contextSize),
                    "-np", "1",
                    "--host", "127.0.0.1", "--port", String(config.port),
                    "--temp", "1.0", "--top-p", "1.0", "--top-k", "0", "--min-p", "0.0"]
        var launched = config
        if config.imagesEnabled {
            if !config.mmprojPath.isEmpty && fm.fileExists(atPath: config.mmprojPath) {
                args += ["--mmproj", config.mmprojPath]
            } else {
                launched.imagesEnabled = false
                append("Bu modelin klasöründe resim dosyası (mmproj) yok; resim desteği kapalı başlatılıyor.")
            }
        }

        launch(executable: config.serverPath, args: args, launched: launched)
    }

    /// Atomic Engine profili (README'deki AD-Q4_K + DSpark-3 komutu): 4K bağlam, bellek bütçesi, taslak model.
    private func startAtomic() {
        let fm = FileManager.default
        let exe = config.atomicServer
        guard fm.isExecutableFile(atPath: exe) else {
            state = .failed("Atomic Engine bulunamadı: \(exe). ~/atomic-engine içinde derlenmesi gerekiyor.")
            return
        }
        guard fm.fileExists(atPath: config.modelPath) else {
            state = .failed("Model dosyası bulunamadı: \(config.modelPath).")
            return
        }
        var launched = config
        launched.contextSize = Config.atomicContext
        launched.imagesEnabled = false
        var args = ["-m", config.modelPath, "--jinja",
                    "--engine-budget-mib", String(config.budgetGiB * 1024 + 100), "-fit", "off",
                    "-c", String(Config.atomicContext), "-b", "1024", "-ub", "1024", "-np", "1",
                    "-fa", "on", "-ctk", "q4_0", "-ctv", "q4_0", "-ngl", "all", "-t", "8", "-tb", "8",
                    "--cache-ram", "0", "--ctx-checkpoints", "0",
                    "--host", "127.0.0.1", "--port", String(config.port)]
        if let draft = config.draftPath {
            args += ["-md", draft, "--spec-type", "draft-dspark", "--spec-draft-n-max", "3", "--spec-draft-n-ubatch", "32",
                     "-ctkd", "q4_0", "-ctvd", "q4_0", "-ngld", "99"]
        } else {
            append("Klasörde DSpark taslak modeli yok; taslaksız çalışılıyor (daha yavaş).")
        }
        launch(executable: exe, args: args, launched: launched)
    }

    private func launch(executable: String, args: [String], launched: Config) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(s) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            let pid = proc.processIdentifier
            Task { @MainActor in self?.processEnded(pid: pid, code: code) }
        }

        logTail.removeAll()
        append("Başlatılıyor (\(launched.engineName)): " + args.joined(separator: " "))
        do {
            try p.run()
        } catch {
            state = .failed("Sunucu başlatılamadı: \(error.localizedDescription)")
            return
        }
        process = p
        try? String(p.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)
        runningConfig = launched
        state = .starting
        watchUntilReady()
    }

    func stop() {
        watchTask?.cancel()
        guard let p = process else { return }
        p.terminate()
        try? FileManager.default.removeItem(at: Self.pidFile)
        process = nil
        runningConfig = nil
        state = .stopped
    }

    func restart() {
        Task { await relaunch() }
    }

    /// Başka bir modele tek tıkla geç: eskisini belleği boşaltana kadar kapatır, yenisini yükler.
    /// Harici bir llama-server bu portu tutuyorsa onu da kapatıp yönetimi devralır.
    func load(modelPath: String, mmprojPath: String?, contextSize: Int? = nil, images: Bool? = nil) {
        config.modelPath = modelPath
        config.mmprojPath = mmprojPath ?? ""
        config.imagesEnabled = (images ?? true) && mmprojPath != nil
        if let contextSize { config.contextSize = contextSize }
        Task { await relaunch() }
    }

    /// Modeli bellekten kaldır (sunucuyu durdur). Harici sunucu da kapatılır.
    func unload() {
        Task {
            if state == .external { await takeOverPort() }
            await stopAndWait()
        }
    }

    private func relaunch() async {
        guard state != .switching else { return }
        state = .switching
        append("Model değiştiriliyor: \(URL(fileURLWithPath: config.modelPath).lastPathComponent)")
        await takeOverPort()
        await stopAndWait()
        state = .stopped
        start()
    }

    /// Süreç gerçekten kapanana (Metal belleği boşalana) kadar bekler, en çok 10 sn.
    private func stopAndWait() async {
        watchTask?.cancel()
        guard let p = process else {
            if state != .switching { state = .stopped }
            return
        }
        process = nil
        p.terminate()
        for _ in 0..<100 where p.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: Self.pidFile)
        runningConfig = nil
        if state != .switching { state = .stopped }
    }

    /// Portu başka bir llama-server tutuyorsa (eski oturum, terminalden açılan) kapatır.
    private func takeOverPort() async {
        guard process == nil, await Self.health(port: config.port) != .down else { return }
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(config.port)", "-sTCP:LISTEN"]
        let out = Pipe()
        lsof.standardOutput = out
        guard (try? lsof.run()) != nil else { return }
        lsof.waitUntilExit()
        let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
        for pid in pids where Self.isLlamaServer(pid) {
            append("Harici sunucu (pid \(pid)) kapatılıyor, yönetim bu uygulamaya geçiyor.")
            kill(pid, SIGTERM)
            for _ in 0..<100 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// Uygulama kapanırken çağrılır.
    nonisolated func terminateSync() {
        MainActor.assumeIsolated {
            guard let p = process, p.isRunning else { return }
            p.terminate()
            // Metal belleğini bırakması birkaç saniye sürebilir; en çok 5 sn bekle, sonra zorla kapat.
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: Self.pidFile)
        }
    }

    private func processEnded(pid: pid_t, code: Int32) {
        // Bilerek durdurulan ya da yerine yenisi açılmış eski süreç: yok say.
        guard let current = process, current.processIdentifier == pid, state != .switching else { return }
        process = nil
        runningConfig = nil
        watchTask?.cancel()
        let last = logTail.suffix(4).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        state = .failed("Sunucu kapandı (kod \(code)). \(last.isEmpty ? "" : "Son kayıt: \(last.suffix(240))")")
    }

    private func watchUntilReady() {
        watchTask?.cancel()
        let port = config.port
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                if await Self.health(port: port) == .ok {
                    await MainActor.run { if self?.state == .starting { self?.state = .ready } }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func append(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            logTail.append(String(line))
        }
        if logTail.count > 300 { logTail.removeFirst(logTail.count - 300) }
    }

    enum Health { case ok, loading, down }

    nonisolated static func health(port: Int) async -> Health {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 1.5
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .down }
        return http.statusCode == 200 ? .ok : .loading
    }
}
