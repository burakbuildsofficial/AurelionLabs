import SwiftUI

/// Hareket sistemi — tek yay ailesi. Animasyon sonucu asla geciktirmez.
enum Motion {
    static let flow = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.30, dampingFraction: 0.82)
    static let fill = Animation.spring(response: 0.70, dampingFraction: 0.90)
    static let stagger: Double = 0.06
    static let fade = Animation.easeInOut(duration: 0.2)

    static func flow(_ reduce: Bool) -> Animation { reduce ? fade : flow }
    static func snappy(_ reduce: Bool) -> Animation { reduce ? fade : snappy }
}

/// Aşağıdan yükselerek giriş; Reduce Motion'da yalnız solma.
struct RiseIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 18)
            .onAppear {
                withAnimation(Motion.snappy(reduce).delay(reduce ? 0 : Double(min(index, 6)) * Motion.stagger)) {
                    shown = true
                }
            }
    }
}

extension View {
    func riseIn(index: Int = 0) -> some View { modifier(RiseIn(index: index)) }
}

/// Basılınca hafifçe çöken buton stili.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduce ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.snappy(reduce), value: configuration.isPressed)
    }
}
