import Foundation

/// Claude Code becerileri (~/.claude/skills/**/SKILL.md). Ajan modunda modele kısa bir katalog verilir;
/// model bir beceriyi `beceri_oku` aracıyla açar, ek dosyalarını da (references/…) aynı araçla okur.
/// Yalnız okuma yapılır; beceri klasörünün dışına çıkılmaz.
enum SkillLibrary {
    struct Skill { let name: String; let summary: String; let folder: URL }

    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")

    /// Diskte her çağrıda yeniden taranır: yeni kurulan beceri uygulamayı yeniden başlatmadan görünür.
    static func all() -> [Skill] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var seen = Set<String>(), out: [Skill] = []
        for case let url as URL in e {
            if e.level > 4 { e.skipDescendants(); continue }
            guard url.lastPathComponent == "SKILL.md",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let folder = url.deletingLastPathComponent()
            let meta = frontmatter(text)
            let name = meta["name"] ?? folder.lastPathComponent
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(Skill(name: name, summary: shorten(meta["description"] ?? ""), folder: folder))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Araç tanımına konan katalog: ad + kısa açıklama, satır başına bir beceri.
    static func catalog(_ skills: [Skill]) -> String {
        skills.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
    }

    static func read(name: String, file: String?, maxChars: Int) -> AgentTools.Outcome {
        guard let s = all().first(where: { $0.name == name }) else {
            return .init(text: L("Böyle bir beceri yok: \(name). Var olanlar: ") + all().map(\.name).joined(separator: ", "), ok: false)
        }
        let rel = (file?.isEmpty == false) ? file! : "SKILL.md"
        guard let url = AgentTools.resolve(rel, in: s.folder) else {
            return .init(text: L("Hata: yol beceri klasörünün dışında."), ok: false)
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
            return .init(text: items.joined(separator: "\n"), ok: true)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .init(text: L("Okunamadı: \(rel)"), ok: false)
        }
        let head = rel == "SKILL.md"
            ? L("Beceri klasörü: \(s.folder.path)\nİçindeki dosyalar: \(listing(s.folder))\n\n") : ""
        let body = text.count > maxChars ? String(text.prefix(maxChars)) + L("\n[… devamı kesildi]") : text
        return .init(text: head + body, ok: true)
    }

    private static func listing(_ folder: URL) -> String {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted().joined(separator: ", ")
    }

    /// YAML başlığından düz `anahtar: değer` satırlarını alır (çok satırlı değerler için `>`/`|` desteklenir).
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:], key: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let k = key, line.hasPrefix(" ") || line.hasPrefix("\t") {
                out[k, default: ""] += (out[k]!.isEmpty ? "" : " ") + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<c]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(v) { v = "" }
            if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            out[k] = v
            key = k
        }
        return out
    }

    /// Küçük bağlamda yer kaplamasın: açıklamanın ilk cümlesi, en fazla 160 karakter.
    private static func shorten(_ s: String) -> String {
        var t = s
        if let r = t.range(of: ". ") { t = String(t[..<r.lowerBound]) + "." }
        return t.count > 160 ? String(t.prefix(157)) + "…" : t
    }
}
