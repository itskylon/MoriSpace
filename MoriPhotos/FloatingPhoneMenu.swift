import SwiftUI

@MainActor final class PhoneMenuState: ObservableObject {
    @Published private(set) var compact = false
    private var travel: CGFloat = 0

    func scrolled(from old: CGFloat, to new: CGFloat) {
        let delta = new - old
        guard abs(delta) > 0.5 else { return }
        if (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        if travel > 20 { compact = true; travel = 0 }
        else if travel < -24 { expand() }
    }

    func expand() { compact = false; travel = 0 }
}

struct FloatingPhoneMenu: View {
    @Binding var selection: WorkspacePage
    @ObservedObject var state: PhoneMenuState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var keyboardVisible = false
    private let pages: [WorkspacePage] = [.home, .local, .photos, .calendar, .settings]
    private var compact: Bool { state.compact && !voiceOver && !typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if !keyboardVisible {
                HStack(spacing: 2) {
                    ForEach(pages) { page in
                        Button {
                            state.expand()
                            selection = page
                        } label: {
                            VStack(spacing: compact ? 0 : 3) {
                                Image(systemName: symbol(page)).font(.system(size: compact ? 21 : 23, weight: .medium))
                                    .accessibilityHidden(true)
                                Text(title(page)).font(.caption2.weight(.medium)).lineLimit(1)
                                    .frame(height: compact ? 0 : nil).opacity(compact ? 0 : 1).clipped()
                                    .accessibilityHidden(true)
                            }
                            .foregroundStyle(selection == page ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity).frame(height: compact ? 44 : 54)
                            .background(selection == page ? Color.primary.opacity(0.10) : .clear, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityRepresentation {
                            Button(title(page)) { state.expand(); selection = page }
                                .accessibilityAddTraits(selection == page ? .isSelected : [])
                                .accessibilityIdentifier("phoneMenu_" + page.rawValue)
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: compact ? 290 : 420)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("主导航")
                .accessibilityIdentifier("floatingPhoneMenu")
                .accessibilityValue(compact ? "收起" : "展开")
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: compact)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false; state.expand() }
    }

    private func title(_ page: WorkspacePage) -> String {
        switch page { case .local: "照片"; case .photos: "存储"; default: page.title }
    }
    private func symbol(_ page: WorkspacePage) -> String {
        switch page {
        case .home: "house.fill"
        case .local: "photo.on.rectangle"
        case .photos: "externaldrive"
        case .settings: "slider.horizontal.3"
        default: page.symbol
        }
    }
}

private struct PhoneMenuScrollKey: EnvironmentKey {
    static let defaultValue: ((CGFloat, CGFloat) -> Void)? = nil
}

extension EnvironmentValues {
    var phoneMenuScroll: ((CGFloat, CGFloat) -> Void)? {
        get { self[PhoneMenuScrollKey.self] }
        set { self[PhoneMenuScrollKey.self] = newValue }
    }
}

private struct PhoneMenuScrolling: ViewModifier {
    var active = true
    @Environment(\.phoneMenuScroll) private var report
    @State private var lastTranslation: CGFloat = 0

    @ViewBuilder func body(content: Content) -> some View {
        if report != nil {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        let translation = -value.translation.height
                        defer { lastTranslation = translation }
                        // Only deliberate vertical gestures drive the menu; content/layout changes do not.
                        if active && abs(value.translation.height) > abs(value.translation.width) {
                            report?(lastTranslation, translation)
                        }
                    }
                    .onEnded { _ in lastTranslation = 0 }
            ).onChange(of: active) { _, _ in lastTranslation = 0 }
        } else { content }
    }
}

extension View {
    func phoneMenuScrolling(active: Bool = true) -> some View { modifier(PhoneMenuScrolling(active: active)) }
}
