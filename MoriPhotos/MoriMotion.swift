import SwiftUI

enum MoriMotion {
    static let selection = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let fade = Animation.easeOut(duration: 0.16)
}

/// Uses Button's native pressed state so dragging a list still cancels a tap normally.
struct MoriPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : configuration.isPressed
                       ? .easeOut(duration: 0.09)
                       : .spring(response: 0.30, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

private struct MoriPageActivation: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    private var visible: Bool { active && appeared }

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 6)
            .animation(reduceMotion ? nil : MoriMotion.fade, value: visible)
            // Keep the existing page alive, but remove its interaction immediately.
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
            .onAppear { appeared = true }
    }
}

private struct MoriSelectionBounce: ViewModifier {
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = 0

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, options: .speed(1.5), value: pulse)
            .symbolEffectsRemoved(reduceMotion)
            .onChange(of: selected) { _, next in
                if next && !reduceMotion { pulse += 1 }
            }
    }
}

extension View {
    func moriPageActivation(_ active: Bool) -> some View { modifier(MoriPageActivation(active: active)) }
    func moriSelectionBounce(_ selected: Bool) -> some View { modifier(MoriSelectionBounce(selected: selected)) }
}
