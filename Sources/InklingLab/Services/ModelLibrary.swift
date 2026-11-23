import Foundation
import Observation

/// Bu Mac'teki GGUF modelleri: seçilen klasörleri (varsayılan ~/models) alt klasörleriyle tarar.
/// Aynı klasörde `mmproj*.gguf` varsa model resim okuyabilir sayılır.
@MainActor
@Observable
final class ModelLibrary {
    struct Model: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let fileName: String       // uzantısız
        let family: String         // "Inkling 2 Mini"
        let quant: String          // "IQ3_XXS"
        let bytes: Int64
        let mmproj: String?

        var sizeGB: Double { Double(bytes) / 1e9 }
        var folder: String { URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }
        var bits: String? { quant.first(where: \.isNumber).map { "\($0)-bit" } }
    }

    private(set) var models: [Model] = []
    private(set) var folders: [String] { didSet { UserDefaults.standard.set(folders, forKey: "modelFolders") } }

    init() {
        folders = UserDefaults.standard.stringArray(forKey: "modelFolders")
            ?? [NSString("~/models").expandingTildeInPath]
        scan()
    }

    func addFolder(_ path: String) {
        guard !folders.contains(path) else { return }
        folders.append(path)
        scan()
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        scan()
    }

    func model(at path: String) -> Model? { models.first { $0.path == path } }

    func scan() {
        let fm = FileManager.default
        var found: [Model] = []
        var seen = Set<String>()
        for root in folders {
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: root),
                                             includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                // Derleme ve kaynak kodu klasörlerine girme (ör. llama.cpp kopyaları).
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let n = url.lastPathComponent.lowercased()
                    if n.contains("llama.cpp") || n == "build" || n == ".git" || n == "node_modules" { walker.skipDescendants() }
                    continue
                }
                guard url.pathExtension.lowercased() == "gguf" else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                let lower = name.lowercased()
                if lower.hasPrefix("mmproj") || lower.contains("dspark") || lower.hasPrefix("draft") { continue }
                // Parçalı dosyalarda (…-00001-of-00003) yalnız ilk parça listelenir.
                var bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if let r = name.range(of: #"-(\d{5})-of-(\d{5})$"#, options: .regularExpression) {
                    guard name[r].hasPrefix("-00001") else { continue }
                    let stem = String(name[..<r.lowerBound])
                    let siblings = (try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])) ?? []
                    bytes = siblings.filter { $0.lastPathComponent.hasPrefix(stem + "-") && $0.pathExtension == "gguf" }
                        .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                }
                guard bytes > 200_000_000, seen.insert(url.path).inserted else { continue }
                let clean = name.replacingOccurrences(of: #"-\d{5}-of-\d{5}$"#, with: "", options: .regularExpression)
                found.append(Model(path: url.path, fileName: clean, family: Self.family(of: clean),
                                   quant: Self.quant(of: clean), bytes: bytes,
                                   mmproj: Self.mmproj(in: url.deletingLastPathComponent())))
            }
        }
        models = found.sorted { ($0.family, $0.bytes) < ($1.family, $1.bytes) }
    }

    // MARK: Ad çözümleme

    nonisolated private static let quantPattern = #"(?i)[-_.]((?:UD-)?(?:I?Q\d[A-Z0-9_]*|BF16|F16|F32|MXFP4[A-Z0-9_]*))$"#

    /// "Inkling-2-Mini-UD-IQ3_XXS" → "IQ3_XXS"
    nonisolated static func quant(of name: String) -> String {
        guard let r = name.range(of: quantPattern, options: .regularExpression) else { return "" }
        return String(name[r].dropFirst()).replacingOccurrences(of: "UD-", with: "")
    }

    /// "Inkling-2-Mini-UD-IQ3_XXS" → "Inkling 2 Mini"
    nonisolated static func family(of name: String) -> String {
        let base = name.replacingOccurrences(of: quantPattern, with: "", options: .regularExpression)
        let words = base.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        return words.filter { !["GGUF", "gguf", "UD"].contains($0) }.joined(separator: " ")
    }

    private static func mmproj(in dir: URL) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let projs = files.filter { $0.lastPathComponent.lowercased().hasPrefix("mmproj") && $0.pathExtension == "gguf" }
        // Önce F16 (kalite), yoksa ilk bulunan.
        return (projs.first { $0.lastPathComponent.contains("F16") } ?? projs.first)?.path
    }
}
