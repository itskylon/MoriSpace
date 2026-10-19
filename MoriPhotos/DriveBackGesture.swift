import SwiftUI
import UIKit

enum DriveBackGestureDecision {
    static func shouldBegin(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        horizontal > 0 && horizontal > abs(vertical) * 1.25
    }
    static func shouldFinish(distance: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        distance >= max(60, min(120, width * 0.25)) || (distance > 20 && velocity > 650)
    }
}

/// Scope a native pan to the leading edge of the browser's visible list bounds.
/// A full-screen SwiftUI drag would compete with vertical scrolling and breadcrumbs.
struct DriveBackGesture: UIViewRepresentable {
    let enabled: Bool
    let rightToLeft: Bool
    let progress: (CGFloat) -> Void
    let finish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        context.coordinator.anchor = view
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.attach() }
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.progress = progress; coordinator.finish = finish
        coordinator.rightToLeft = rightToLeft
        coordinator.enabled = enabled
        coordinator.attach()
    }
    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        view.windowChanged = nil; coordinator.detach()
    }
    final class AnchorView: UIView {
        var windowChanged: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); windowChanged?() }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var anchor: AnchorView?
        private weak var installedWindow: UIWindow?
        private let prioritizedPops = NSHashTable<UIGestureRecognizer>.weakObjects()
        private var recognizer: UIPanGestureRecognizer?
        var enabled = false
        var rightToLeft = false
        var progress: ((CGFloat) -> Void)?
        var finish: ((Bool) -> Void)?
        private var tracking = false

        func attach() {
            guard let window = anchor?.window else { detach(); return }
            if installedWindow !== window {
                detach()
                let recognizer = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
                recognizer.delegate = self
                recognizer.cancelsTouchesInView = true
                recognizer.maximumNumberOfTouches = 1
                window.addGestureRecognizer(recognizer)
                self.recognizer = recognizer; installedWindow = window
            }
            if recognizer?.isEnabled != enabled { recognizer?.isEnabled = enabled }
            if enabled, let recognizer {
                var responder: UIResponder? = anchor
                while let current = responder {
                    if let controller = current as? UIViewController, let navigation = controller.navigationController {
                        var nativePops = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
                        if #available(iOS 26.0, macCatalyst 26.0, *), let contentPop = navigation.interactiveContentPopGestureRecognizer {
                            nativePops.append(contentPop)
                        }
                        for nativePop in nativePops where !prioritizedPops.contains(nativePop) {
                            nativePop.require(toFail: recognizer)
                            prioritizedPops.add(nativePop)
                        }
                        break
                    }
                    responder = current.next
                }
            }
        }
        func detach() {
            if let recognizer { recognizer.isEnabled = false; installedWindow?.removeGestureRecognizer(recognizer) }
            recognizer = nil; installedWindow = nil; prioritizedPops.removeAllObjects()
            if tracking { tracking = false; finish?(false) }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, let anchor, let window = installedWindow else { return false }
            let bounds = anchor.convert(anchor.bounds, to: window)
            let point = touch.location(in: window)
            let edgeDistance = rightToLeft ? window.bounds.maxX - point.x : point.x - window.bounds.minX
            let result = bounds.width > 0 && bounds.height > 0 && bounds.contains(point) && edgeDistance >= 0 && edgeDistance <= 24
            return result
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let recognizer = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = recognizer.velocity(in: installedWindow)
            let result = DriveBackGestureDecision.shouldBegin(horizontal: velocity.x * (rightToLeft ? -1 : 1), vertical: velocity.y)
            return result
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            !prioritizedPops.contains(otherGestureRecognizer)
        }
        @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
            let direction: CGFloat = rightToLeft ? -1 : 1
            let distance = max(0, recognizer.translation(in: installedWindow).x * direction)
            switch recognizer.state {
            case .began: tracking = true; progress?(distance)
            case .changed: progress?(distance)
            case .ended:
                guard tracking else { return }
                tracking = false
                let velocity = recognizer.velocity(in: installedWindow).x * direction
                finish?(DriveBackGestureDecision.shouldFinish(distance: distance, velocity: velocity, width: installedWindow?.bounds.width ?? 0))
            case .cancelled, .failed:
                if tracking { tracking = false; finish?(false) }
            default: break
            }
        }
    }
}
