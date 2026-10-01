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
    @Namespace private var selectionIndicator
    @State private var keyboardVisible = false
    private let pages: [WorkspacePage] = [.home, .local, .photos, .calendar, .settings]
    private var compact: Bool { state.compact && !voiceOver && !typeSize.isAccessibilitySize }
    private var fullLabels: Bool { voiceOver || typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if !keyboardVisible {
                HStack(spacing: 2) {
                    ForEach(pages) { page in
                        Button {
                            state.expand()
                            selection = page
                        } label: {
                            label(page)
                            .foregroundStyle(Color.primary.opacity(selection == page ? 1 : 0.72))
                            .frame(maxWidth: .infinity).frame(height: fullLabels ? 58 : compact ? 44 : 48)
                            .background {
                                if selection == page {
                                    Capsule().fill(Color.primary.opacity(0.09))
                                        .matchedGeometryEffect(id: "selectedPage", in: selectionIndicator)
                                }
                            }
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
                .padding(compact ? 4 : 6)
                .containerRelativeFrame(.horizontal) { width, _ in
                    compact ? max(240, min(268, width - 76)) : min(360, width - 48)
                }
                .phoneMenuGlass()
                .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("主导航")
                .accessibilityIdentifier("floatingPhoneMenu")
                .accessibilityValue(compact ? "收起" : "展开")
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: compact)
                .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: selection)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false; state.expand() }
    }

    @ViewBuilder private func label(_ page: WorkspacePage) -> some View {
        if fullLabels {
            VStack(spacing: 3) {
                Image(systemName: symbol(page)).font(.system(size: 21, weight: .regular))
                Text(title(page)).font(.caption2.weight(.medium)).lineLimit(1)
            }.accessibilityHidden(true)
        } else {
            HStack(spacing: selection == page && !compact ? 5 : 0) {
                Image(systemName: symbol(page)).font(.system(size: compact ? 19 : 21, weight: .regular))
                Text(title(page)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .fixedSize().frame(width: selection == page && !compact ? nil : 0)
                    .opacity(selection == page && !compact ? 1 : 0).clipped()
            }.accessibilityHidden(true)
        }
    }

    private func title(_ page: WorkspacePage) -> String {
        switch page { case .local: "照片"; case .photos: "存储"; default: page.title }
    }
    private func symbol(_ page: WorkspacePage) -> String {
        switch page {
        case .home: selection == page ? "house.fill" : "house"
        case .local: "photo"
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

private extension View {
    @ViewBuilder func phoneMenuGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}
