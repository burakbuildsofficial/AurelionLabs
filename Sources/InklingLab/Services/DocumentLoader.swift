import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Sürüklenen ya da seçilen dosyanın metnini çıkarır: PDF, düz metin, Markdown, kod, JSON, CSV…
enum DocumentLoader {
    /// 16K bağlamda soruya ve cevaba da yer kalsın diye üst sınır (~13K token).
    static let maxChars = 45_000

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "log", "html", "htm", "css",
        "swift", "kt", "kts", "java", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm",
        "rb", "php", "sh", "zsh", "sql", "gradle", "plist", "ini", "env", "srt", "vtt",
    ]

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    static func canLoad(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || textExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .text) ?? false
    }

    /// Dosyanın tam metni (belge asistanı için, üst sınır yüksek).
    static func loadText(_ url: URL, maxChars: Int) -> String? {
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ext == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if ext == "rtf" {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else if canLoad(url) {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        guard let body = text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        return body.count > maxChars ? String(body.prefix(maxChars)) : body
    }

    static func load(_ url: URL) -> DocumentAttachment? {
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ext == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if ext == "rtf" {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else if canLoad(url) {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        guard var body = text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        var truncated = false
        if body.count > maxChars {
            body = String(body.prefix(maxChars))
            truncated = true
        }
        return DocumentAttachment(name: url.lastPathComponent, text: body, truncated: truncated)
    }
}
