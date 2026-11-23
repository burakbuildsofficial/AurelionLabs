// Test sonuçlarından paylaşılabilir sonuç kartı üretir (1600×900 PNG).
// swift scripts/result-card.swift <çıktı.png> <ikon.png> <ad|sonuç.txt|model.gguf> [<ad|sonuç.txt|model.gguf> ...]
// Sonuç dosyası: InklingLab --run-tests çıktısı.
import AppKit
import SwiftUI

struct Category { let name: String; var passed = 0; var total = 0 }

struct Run {
    let label: String
    let sizeGB: Double
    var passed = 0
    var total = 0
    var categories: [Category] = []
    var speeds: [Double] = []
    var failed: [String] = []
    var avgSpeed: Double { speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count) }

    init(label: String, file: String, model: String) {
        self.label = label
        let size = (try? FileManager.default.attributesOfItem(atPath: model)[.size] as? Int) ?? 0
        sizeGB = Double(size) / 1e9
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let re = try! NSRegularExpression(pattern: #"^(GEÇTİ|KALDI|HATA)\s+\[(.+?)\] (.+?) ·\s+(?:([\d.]+)s\s+([\d.]+) t/s|·)"#)
        for line in text.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let ok = ns.substring(with: m.range(at: 1)) == "GEÇTİ"
            let cat = ns.substring(with: m.range(at: 2))
            if m.range(at: 5).location != NSNotFound, let s = Double(ns.substring(with: m.range(at: 5))), s > 0 { speeds.append(s) }
            if !ok { failed.append(ns.substring(with: m.range(at: 3)).replacingOccurrences(of: "Samanlıkta iğne · ", with: "İğne ")) }
            if let i = categories.firstIndex(where: { $0.name == cat }) {
                categories[i].total += 1; if ok { categories[i].passed += 1 }
            } else {
                categories.append(Category(name: cat, passed: ok ? 1 : 0, total: 1))
            }
            total += 1; if ok { passed += 1 }
        }
    }
}

let indigo = Color(red: 0.36, green: 0.25, blue: 0.84)
let indigoLight = Color(red: 0.56, green: 0.45, blue: 0.97)
let soft = Color(red: 0.91, green: 0.89, blue: 1.0)
let header = Color(red: 0.86, green: 0.83, blue: 1.0)
let bg = Color(red: 0.957, green: 0.965, blue: 0.980)
let raised = Color(red: 0.937, green: 0.945, blue: 0.965)
let ink = Color(red: 0.08, green: 0.09, blue: 0.11)
let sub = Color(red: 0.40, green: 0.42, blue: 0.47)
let good = Color(red: 0.16, green: 0.68, blue: 0.38)

func tr(_ v: Double, _ d: Int) -> String {
    v.formatted(.number.precision(.fractionLength(d)).locale(Locale(identifier: "tr_TR")))
}

struct RunCard: View {
    let run: Run
    let best: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.label).font(.system(size: 30, weight: .bold)).foregroundStyle(ink)
                    Text("\(tr(run.sizeGB, 1)) GB").font(.system(size: 20)).foregroundStyle(sub)
                }
                Spacer()
                if best {
                    Label("en iyi", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(indigo)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(soft, in: Capsule())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(run.passed)/\(run.total)").font(.system(size: 76, weight: .bold).monospacedDigit()).foregroundStyle(ink)
                    Text("test geçti").font(.system(size: 20)).foregroundStyle(sub)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr(run.avgSpeed, 1)).font(.system(size: 52, weight: .bold).monospacedDigit()).foregroundStyle(indigo)
                    Text("token/sn ort.").font(.system(size: 20)).foregroundStyle(sub)
                }
            }
            VStack(spacing: 11) {
                ForEach(run.categories, id: \.name) { c in
                    HStack(spacing: 12) {
                        Text(c.name).font(.system(size: 18)).foregroundStyle(ink).frame(width: 200, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(raised)
                                Capsule().fill(LinearGradient(colors: c.passed == c.total ? [indigo, indigoLight] : [indigoLight.opacity(0.7), indigoLight.opacity(0.7)],
                                                              startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * CGFloat(c.passed) / CGFloat(max(c.total, 1)))
                            }
                        }.frame(height: 12)
                        Text("\(c.passed)/\(c.total)").font(.system(size: 18, weight: .semibold).monospacedDigit())
                            .foregroundStyle(c.passed == c.total ? good : sub).frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                Text(run.failed.isEmpty ? "Hepsini geçti" : "Geçemedikleri")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(sub)
                if !run.failed.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(run.failed, id: \.self) { f in
                            Text(f).font(.system(size: 18)).foregroundStyle(ink)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct ResultCard: View {
    let runs: [Run]
    let icon: NSImage?

    var body: some View {
        let bestScore = runs.map(\.passed).max() ?? 0
        let tie = runs.filter { $0.passed == bestScore }.count > 1
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 22) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 92, height: 92) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inkling 2 Mini, 24 GB MacBook'ta").font(.system(size: 46, weight: .bold)).foregroundStyle(ink)
                    Text("Aynı \(runs.first?.total ?? 0) otomatik test · tamamen yerel, internet yok")
                        .font(.system(size: 24)).foregroundStyle(sub)
                }
            }
            HStack(spacing: 28) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, r in
                    RunCard(run: r, best: !tie && r.passed == bestScore && runs.count > 1)
                }
            }
            HStack {
                Text("Apple M5 Pro · 24 GB · llama.cpp · Unsloth GGUF · 16K bağlam")
                Spacer()
                Text("Inkling Lab")
                    .fontWeight(.semibold).foregroundStyle(indigo)
            }
            .font(.system(size: 19)).foregroundStyle(sub)
        }
        .padding(56)
        .frame(width: 1600, height: 900, alignment: .topLeading)
        .background(alignment: .top) { LinearGradient(colors: [header, bg], startPoint: .top, endPoint: .bottom).frame(height: 420) }
        .background(bg)
        .environment(\.colorScheme, .light)
    }
}

let a = CommandLine.arguments
guard a.count >= 6, (a.count - 3) % 3 == 0 else {
    print("kullanım: result-card.swift cikti.png ikon.png <ad> <sonuc.txt> <model.gguf> [...]"); exit(1)
}
var runs: [Run] = []
var i = 3
while i + 2 < a.count { runs.append(Run(label: a[i], file: a[i + 1], model: a[i + 2])); i += 3 }

MainActor.assumeIsolated {
    let r = ImageRenderer(content: ResultCard(runs: runs, icon: NSImage(contentsOfFile: a[2])))
    r.scale = 1
    guard let cg = r.cgImage else { print("çizilemedi"); exit(1) }
    try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
    print("yazıldı: \(a[1]) · " + runs.map { "\($0.label) \($0.passed)/\($0.total) \(tr($0.avgSpeed, 1)) t/s" }.joined(separator: " | "))
}
