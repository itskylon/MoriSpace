import SwiftUI

enum MoriMotion {
    static let selection = Animation.spring(response: 0.42, dampingFraction: 0.62)
    static let fade = Animation.easeOut(duration: 0.22)
    static let page = Animation.spring(response: 0.40, dampingFraction: 0.86)
}

/// Uses Button's native pressed state so dragging a list still cancels a tap normally.
struct MoriPressStyle: ButtonStyle {
    var scale: CGFloat = 0.90
    var tilt: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .rotationEffect(.degrees(configuration.isPressed && !reduceMotion ? tilt : 0))
            .opacity(configuration.isPressed ? 0.88 : 1)
            // Keep the touch target at its resting size while the label compresses.
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : configuration.isPressed
                       ? .easeOut(duration: 0.08)
                       : .spring(response: 0.42, dampingFraction: 0.48), value: configuration.isPressed)
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
            .offset(y: visible || reduceMotion ? 0 : 22)
            .animation(reduceMotion ? nil : MoriMotion.page, value: visible)
            // Keep the existing page alive, but remove its interaction immediately.
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
            .onAppear { appeared = true }
    }
}

private struct MoriSymbolFrame {
    var scale: CGFloat = 1
    var lift: CGFloat = 0
    var tilt: Double = 0
}

private struct MoriSelectionBounce: ViewModifier {
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: MoriSymbolFrame(), trigger: pulse) { icon, frame in
                icon.scaleEffect(reduceMotion ? 1 : frame.scale)
                    .offset(y: reduceMotion ? 0 : frame.lift)
                    .rotationEffect(.degrees(reduceMotion ? 0 : frame.tilt))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.26, duration: 0.13)
                    CubicKeyframe(0.94, duration: 0.17)
                    CubicKeyframe(1, duration: 0.16)
                }
                KeyframeTrack(\.lift) {
                    CubicKeyframe(-5, duration: 0.13)
                    CubicKeyframe(1, duration: 0.17)
                    CubicKeyframe(0, duration: 0.16)
                }
                KeyframeTrack(\.tilt) {
                    CubicKeyframe(-8, duration: 0.13)
                    CubicKeyframe(4, duration: 0.17)
                    CubicKeyframe(0, duration: 0.16)
                }
            }
            .onChange(of: selected) { _, next in
                if next && !reduceMotion { pulse += 1 }
            }
    }
}

extension View {
    func moriPageActivation(_ active: Bool) -> some View { modifier(MoriPageActivation(active: active)) }
    func moriSelectionBounce(_ selected: Bool) -> some View { modifier(MoriSelectionBounce(selected: selected)) }
}
