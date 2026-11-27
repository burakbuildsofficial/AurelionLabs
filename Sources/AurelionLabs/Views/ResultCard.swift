import SwiftUI
import AppKit

/// X'te paylaşılacak 1600×900 sonuç kartı: seçilen 1–2 test çalıştırması yan yana.
struct ResultCard: View {
    struct Run {
        let label: String
        let sizeGB: Double?
        let passed: Int
        let total: Int
        let speed: Double
        let categories: [(name: String, passed: Int, total: Int)]
        let failed: [String]
        let contextK: Int
    }

    let runs: [Run]
    let hardware: String
    var family = L("Yerel model")

    var body: some View {
        let best = runs.map(\.passed).max() ?? 0
        let tie = runs.filter { $0.passed == best }.count > 1
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 22) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 92, height: 92)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("\(family), \(Self.memoryGB) GB Mac'te")).font(.system(size: 46, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(runs.count > 1
                         ? L("Aynı \(runs.first?.total ?? 0) otomatik test · tamamen yerel, internet yok")
                         : L("\(runs.first?.total ?? 0) otomatik test · tamamen yerel, internet yok"))
                        .font(.system(size: 24)).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 28) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, r in
                    RunPanel(run: r, best: runs.count > 1 && !tie && r.passed == best)
                }
            }
            HStack {
                Text(hardware + L(" · llama.cpp · \(runs.first?.contextK ?? 16)K bağlam"))
                Spacer()
                Text("AurelionLabs").fontWeight(.semibold).foregroundStyle(Theme.primary)
            }
            .font(.system(size: 19)).foregroundStyle(Theme.textSecondary)
        }
        .padding(56)
        .frame(width: 1600, height: 900, alignment: .topLeading)
        .background(alignment: .top) { Theme.headerGradient.frame(height: 420) }
        .background(Theme.bg)
        .environment(\.colorScheme, .light)
    }

    private struct RunPanel: View {
        let run: Run
        let best: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.label).font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        if let gb = run.sizeGB {
                            Text(StatsLine.num(gb, 1) + " GB").font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    if best {
                        Label(L("en iyi"), systemImage: "checkmark.seal.fill")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.primary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.primarySoft, in: .capsule)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(run.passed)/\(run.total)").font(.system(size: 76, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                        Text(L("test geçti")).font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(StatsLine.num(run.speed, 1)).font(.system(size: 52, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.primary)
                        Text(L("token/sn ort.")).font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
                    }
                }
                VStack(spacing: 11) {
                    ForEach(run.categories, id: \.name) { c in
                        let full = c.passed == c.total
                        HStack(spacing: 12) {
                            Text(c.name).font(.system(size: 18)).foregroundStyle(Theme.textPrimary)
                                .frame(width: 200, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.surfaceRaised)
                                    Capsule().fill(full ? AnyShapeStyle(Theme.primaryGradient)
                                                        : AnyShapeStyle(Theme.primaryLight.opacity(0.7)))
                                        .frame(width: g.size.width * CGFloat(c.passed) / CGFloat(max(c.total, 1)))
                                }
                            }
                            .frame(height: 12)
                            Text("\(c.passed)/\(c.total)").font(.system(size: 18, weight: .semibold).monospacedDigit())
                                .foregroundStyle(full ? Theme.Tone.good.color : Theme.textSecondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    Text(run.failed.isEmpty ? L("Hepsini geçti") : L("Geçemedikleri"))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    if !run.failed.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(run.failed.prefix(4), id: \.self) { f in
                                Text(f).font(.system(size: 18)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Theme.surfaceRaised, in: .rect(cornerRadius: 12, style: .continuous))
                            }
                            if run.failed.count > 4 {
                                Text("+\(run.failed.count - 4)").font(.system(size: 18)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: .rect(cornerRadius: 28, style: .continuous))
        }
    }

    // MARK: Üretim

    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return s.isEmpty ? "Apple Silicon" : s
    }

    /// "Inkling-2-Mini-UD-IQ3_XXS" → "3-bit · IQ3_XXS"
    static func label(for model: String) -> String {
        let q = ModelLibrary.quant(of: model)
        let quant = q.isEmpty ? model : q
        if let d = quant.first(where: \.isNumber) { return "\(d)-bit · \(quant)" }
        return quant
    }

    static func run(from s: TestRunner.RunSummary, modelDir: URL) -> Run {
        let file = modelDir.appendingPathComponent(s.model + ".gguf")
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.doubleValue
        let cats = TestCategory.allCases.compactMap { c -> (String, Int, Int)? in
            guard let v = s.byCategory[c.rawValue], v.count == 2 else { return nil }
            return (c.title, v[0], v[1])
        }
        let failed = s.failedTests.map { $0.replacingOccurrences(of: "Samanlıkta iğne · ", with: "İğne ").replacingOccurrences(of: "Needle in a haystack · ", with: "Needle ") }
        return Run(label: label(for: s.model), sizeGB: bytes.map { $0 / 1e9 }, passed: s.passed, total: s.total,
                   speed: s.avgTokensPerSecond, categories: cats.map { (name: $0.0, passed: $0.1, total: $0.2) },
                   failed: failed, contextK: s.contextSize / 1024)
    }

    /// Kartı çizer; ~/Downloads'a PNG kaydeder ve panoya kopyalar. Kaydedilen dosyayı döndürür.
    @MainActor
    static func export(_ summaries: [TestRunner.RunSummary], modelDir: URL) -> URL? {
        let runs = summaries.prefix(2).map { run(from: $0, modelDir: modelDir) }
        guard !runs.isEmpty else { return nil }
        let families = Set(summaries.prefix(2).map { ModelLibrary.family(of: $0.model) })
        let family = families.count == 1 ? families.first! : families.sorted().joined(separator: " vs ")
        let renderer = ImageRenderer(content: ResultCard(runs: Array(runs), hardware: "\(chip) · \(memoryGB) GB", family: family))
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(L("Sonuç kartı \(stamp).png"))
        do { try png.write(to: url, options: .atomic) } catch { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        return url
    }
}
