import SwiftUI

/// Cevap metni: düz yazı Markdown olarak, ``` blokları ayrı kod kutusunda.
struct MessageText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let s):
                    Text(MessageRow.markdown(s))
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let lang, let code):
                    CodeBlock(language: lang, code: code)
                }
            }
        }
    }

    enum Segment { case prose(String), code(String, String) }

    /// Akış sırasında kapanmamış blok da kod sayılır, böylece yazılırken kutuda görünür.
    static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var lang = ""
        var inCode = false
        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.isEmpty { out.append(.prose(s)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(lang, code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flushProse()
                    lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { out.append(.code(lang, code.joined(separator: "\n"))) }
        flushProse()
        return out
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "kod" : language)
                    .font(Theme.Font.small.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.Font.small.weight(.semibold))
                        .foregroundStyle(copied ? Theme.Tone.good.color : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kodu kopyala")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider().overlay(Theme.hairline)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.surfaceRaised, in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}
