import SwiftUI

/// Ana düğme: kapsül, ana renk geçişi, beyaz kalın yazı. Ekranda tek tane.
struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(Theme.Font.button)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.Size.primaryButton)
            .background(Theme.primaryGradient.opacity(enabled ? 1 : 0.4), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

/// İkincil düğme: kapsül, yükseltilmiş zemin.
struct SecondaryButton: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(Theme.Font.callout.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 32)
            .background(Theme.surfaceRaised, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
    }
}

/// Yuvarlak yalın ikon düğmesi. Her zaman erişilebilirlik etiketi taşır.
struct RoundAction: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Theme.primary : Theme.textSecondary)
                .frame(width: Theme.Size.roundAction, height: Theme.Size.roundAction)
                .background(active ? Theme.primarySoft : Theme.surface, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Seçim hapı.
struct Chip: View {
    let title: String
    let selected: Bool
    var dirty = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if dirty { Circle().frame(width: 6, height: 6).accessibilityLabel("değiştirildi") }
            }
            .font(Theme.Font.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? .white : Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Theme.primary : Theme.surfaceRaised,
                        in: .rect(cornerRadius: Theme.Radius.chip, style: .continuous))
            .contentShape(.rect(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(PressableStyle())
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            Spacer()
            if let trailing { trailing }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Resim küçük görseli, isteğe bağlı silme düğmesiyle.
struct AttachmentThumb: View {
    let image: ImageAttachment
    var size: CGFloat = Theme.Size.thumb
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let ns = NSImage(data: image.jpegData) {
                Image(nsImage: ns)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: Theme.Radius.tile, style: .continuous))
                    .accessibilityLabel("Eklenen resim")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Resmi kaldır")
            }
        }
    }
}

/// "16,5 token/sn · 318 token" gibi ölçüm satırı.
struct StatsLine: View {
    let stats: GenStats

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Label(Self.num(stats.generatedPerSecond, 1) + " token/sn", systemImage: "speedometer")
            Text("·")
            Text("\(stats.generatedTokens) token")
            if let ft = stats.firstTokenSeconds {
                Text("·")
                Text("ilk token " + Self.num(ft, 1) + " sn")
            }
            if stats.promptTokens > 0 {
                Text("·")
                Text("okuma " + Self.num(stats.promptPerSecond, 0) + " token/sn")
                    .help("\(stats.promptTokens) token istem işlendi")
            }
        }
        .font(Theme.Font.stat)
        .foregroundStyle(Theme.textTertiary)
        .labelStyle(.titleAndIcon)
    }

    static func num(_ v: Double, _ digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "tr_TR")))
    }
}
