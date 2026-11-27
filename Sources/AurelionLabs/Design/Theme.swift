import AppKit
import SwiftUI

/// Tek renk / yazı / boşluk kaynağı. Ekranlar sabit değer yazmaz, buradan alır.
/// Kaynak: BugSafe `Design/Theme.swift` (app-ui-base). Ana renk tek satırda değişir.
enum Palette: String, CaseIterable {
    case blue, indigo, coral, forest, teal

    var tones: (primary: Color, light: Color, soft: Color, header: Color) {
        switch self {
        case .blue: (Color(red: 0.22, green: 0.47, blue: 0.96), Color(red: 0.45, green: 0.64, blue: 1.0),
                     Color(red: 0.86, green: 0.91, blue: 1.00), Color(red: 0.80, green: 0.87, blue: 1.0))
        case .indigo: (Color(red: 0.36, green: 0.25, blue: 0.84), Color(red: 0.56, green: 0.45, blue: 0.97),
                       Color(red: 0.91, green: 0.89, blue: 1.00), Color(red: 0.86, green: 0.83, blue: 1.0))
        case .coral: (Color(red: 0.91, green: 0.33, blue: 0.27), Color(red: 1.0, green: 0.55, blue: 0.46),
                      Color(red: 1.00, green: 0.91, blue: 0.89), Color(red: 1.0, green: 0.87, blue: 0.84))
        case .forest: (Color(red: 0.16, green: 0.55, blue: 0.36), Color(red: 0.33, green: 0.73, blue: 0.50),
                       Color(red: 0.86, green: 0.95, blue: 0.90), Color(red: 0.83, green: 0.93, blue: 0.87))
        case .teal: (Color(red: 0.05, green: 0.55, blue: 0.58), Color(red: 0.24, green: 0.73, blue: 0.74),
                     Color(red: 0.85, green: 0.95, blue: 0.96), Color(red: 0.80, green: 0.93, blue: 0.94))
        }
    }

    var title: String {
        switch self {
        case .blue: "Mavi"
        case .indigo: "Çivit"
        case .coral: "Mercan"
        case .forest: "Orman"
        case .teal: "Deniz"
        }
    }

    /// Seçili ana renk (Ayarlar › Görünüm). Değişince kök görünüm yeniden çizilir.
    nonisolated(unsafe) static var current: Palette =
        Palette(rawValue: UserDefaults.standard.string(forKey: "palette") ?? "") ?? .indigo
}

/// Açık / koyu / sistem.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Sistem"
        case .light: "Açık"
        case .dark: "Koyu"
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    /// Açık ve koyu temada ayrı değer alan renk.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

enum Theme {
    static let bg = Color.dynamic(rgb(0.957, 0.965, 0.980), rgb(0.075, 0.078, 0.094))
    static let surface = Color.dynamic(.white, rgb(0.118, 0.122, 0.141))
    static let surfaceRaised = Color.dynamic(rgb(0.937, 0.945, 0.965), rgb(0.165, 0.169, 0.192))
    static let sidebar = Color.dynamic(rgb(0.925, 0.933, 0.953), rgb(0.098, 0.102, 0.118))
    static let hairline = Color.dynamic(rgb(0, 0, 0, 0.07), rgb(1, 1, 1, 0.08))
    static let textPrimary = Color.dynamic(rgb(0.08, 0.09, 0.11), rgb(0.93, 0.93, 0.95))
    static let textSecondary = Color.dynamic(rgb(0.40, 0.42, 0.47), rgb(0.66, 0.68, 0.72))
    static let textTertiary = Color.dynamic(rgb(0.60, 0.62, 0.66), rgb(0.46, 0.48, 0.53))

    static var primary: Color {
        let t = Palette.current.tones
        return .dynamic(NSColor(t.primary), NSColor(t.light))
    }
    static var primaryLight: Color { Palette.current.tones.light }
    static var primarySoft: Color {
        let t = Palette.current.tones
        return .dynamic(NSColor(t.soft), NSColor(t.light).withAlphaComponent(0.20))
    }
    static var headerColor: Color {
        let t = Palette.current.tones
        return .dynamic(NSColor(t.header), NSColor(t.primary).withAlphaComponent(0.16))
    }
    static var headerGradient: LinearGradient {
        LinearGradient(colors: [headerColor, bg], startPoint: .top, endPoint: .bottom)
    }
    static var primaryGradient: LinearGradient {
        LinearGradient(colors: [Palette.current.tones.primary, primaryLight], startPoint: .leading, endPoint: .trailing)
    }

    /// Durum tonları — her zaman renk + ikon birlikte.
    enum Tone {
        case unknown, good, mild, caution, danger

        var color: Color {
            switch self {
            case .unknown: Color(red: 0.52, green: 0.56, blue: 0.62)
            case .good: Color(red: 0.16, green: 0.68, blue: 0.38)
            case .mild: Color(red: 0.88, green: 0.62, blue: 0.05)
            case .caution: Color(red: 0.95, green: 0.45, blue: 0.10)
            case .danger: Color(red: 0.90, green: 0.20, blue: 0.22)
            }
        }

        var symbol: String {
            switch self {
            case .unknown: "questionmark.circle.fill"
            case .good: "checkmark.circle.fill"
            case .mild: "exclamationmark.circle.fill"
            case .caution: "exclamationmark.triangle.fill"
            case .danger: "xmark.octagon.fill"
            }
        }
    }

    enum Radius {
        static let card: CGFloat = 16
        static let tile: CGFloat = 10
        static let chip: CGFloat = 12
        static let photo: CGFloat = 24
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let section: CGFloat = 28
    }

    enum Size {
        static let contentMaxWidth: CGFloat = 860
        static let thumb: CGFloat = 64
        static let roundAction: CGFloat = 36
        static let primaryButton: CGFloat = 44
        static let headerHeight: CGFloat = 320
    }

    enum Font {
        static let hero = SwiftUI.Font.system(.title).weight(.bold)
        static let section = SwiftUI.Font.system(.title2).weight(.bold)
        static let title = SwiftUI.Font.system(.title3).weight(.bold)
        static let headline = SwiftUI.Font.system(.headline)
        static let body = SwiftUI.Font.system(.body)
        static let callout = SwiftUI.Font.system(.subheadline)
        static let caption = SwiftUI.Font.system(.footnote)
        static let small = SwiftUI.Font.system(.caption2)
        static let mono = SwiftUI.Font.system(.caption, design: .monospaced)
        static let stat = SwiftUI.Font.system(.footnote).monospacedDigit()
        static let button = SwiftUI.Font.system(size: 15, weight: .bold)
    }
}

/// Beyaz kart — tüm bloklar aynı yüzeyi kullanır. Kenarlık ve gölge yok.
struct CardBackground: ViewModifier {
    var padding: CGFloat = Theme.Space.m

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = Theme.Space.m) -> some View { modifier(CardBackground(padding: padding)) }

    func pageBackground() -> some View {
        background(alignment: .top) { Theme.headerGradient.frame(height: Theme.Size.headerHeight).ignoresSafeArea() }
            .background(Theme.bg)
    }
}
