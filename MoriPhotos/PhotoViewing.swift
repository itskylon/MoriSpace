import SwiftUI
import Photos

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onZoomChanged: ((Bool) -> Void)? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    func makeUIView(context: Context) -> PhotoZoomView { PhotoZoomView() }
    func updateUIView(_ view: PhotoZoomView, context: Context) {
        view.onZoomChanged = onZoomChanged
        view.onPrevious = onPrevious; view.onNext = onNext
        view.show(image)
    }
}

final class PhotoZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onZoomChanged: ((Bool) -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    private var viewport = CGSize.zero
    private var needsImageLayout = true
    private var zoomGestureActive = false

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        accessibilityIdentifier = "photoZoom"
        accessibilityLabel = "照片预览"
        accessibilityHint = "双指缩放，双击放大或还原"
        reportZoom()
    }
    #if targetEnvironment(macCatalyst)
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }
    override var keyCommands: [UIKeyCommand]? {
        let commands = [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previousImage)),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(nextImage)),
         UIKeyCommand(input: "=", modifierFlags: .command, action: #selector(zoomIn)),
         UIKeyCommand(input: "+", modifierFlags: .command, action: #selector(zoomIn)),
         UIKeyCommand(input: "-", modifierFlags: .command, action: #selector(zoomOut)),
         UIKeyCommand(input: "0", modifierFlags: .command, action: #selector(zoomToFit))]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    @objc private func previousImage() { onPrevious?() }
    @objc private func nextImage() { onNext?() }
    @objc private func zoomIn() { setZoomScale(min(maximumZoomScale, zoomScale * 1.4), animated: true) }
    @objc private func zoomOut() { setZoomScale(max(minimumZoomScale, zoomScale / 1.4), animated: true) }
    @objc private func zoomToFit() { setZoomScale(minimumZoomScale, animated: true) }
    #endif
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        // PhotoKit can replace a preview with a higher-resolution image.
        // Keep the user's zoom and position when its aspect ratio is unchanged.
        let previous = imageView.image?.size
        imageView.image = image
        if previous == nil || abs(previous!.width / max(previous!.height, 1) - image.size.width / max(image.size.height, 1)) > 0.001 {
            needsImageLayout = true
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if (viewport != bounds.size || needsImageLayout), let image = imageView.image,
           bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 {
            viewport = bounds.size
            needsImageLayout = false
            setZoomScale(1, animated: false)
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
            contentSize = imageView.frame.size
            centerImage()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            reportZoom()
        } else { centerImage() }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        zoomGestureActive = true
        reportZoom()
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage(); reportZoom() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        zoomGestureActive = false
        reportZoom()
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 { setZoomScale(minimumZoomScale, animated: true) }
        else {
            let scale = min(3, maximumZoomScale)
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
    private func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }
    private func reportZoom() {
        let enlarged = zoomScale > minimumZoomScale + 0.01
        // At fit size, leave one-finger drags to the surrounding page view.
        panGestureRecognizer.isEnabled = enlarged
        accessibilityValue = "\(Int((zoomScale * 100).rounded()))%"
        onZoomChanged?(enlarged || zoomGestureActive)
    }
}

struct LocalPhotoPager: UIViewControllerRepresentable {
    let assets: [PHAsset]
    let library: PhotoLibraryStore
    @Binding var index: Int
    var enabled = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 16])
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .clear
        context.coordinator.pager = pager
        context.coordinator.update(self)
        return pager
    }
    func updateUIViewController(_ pager: UIPageViewController, context: Context) { context.coordinator.update(self) }
    static func dismantleUIViewController(_ pager: UIPageViewController, coordinator: Coordinator) {
        pager.dataSource = nil
        pager.delegate = nil
        coordinator.pages.removeAll()
    }

    final class Page: UIHostingController<AnyView> {
        let assetID: String
        var enlarged = false
        init(assetID: String) { self.assetID = assetID; super.init(rootView: AnyView(EmptyView())) }
        @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func resetZoom() {
            func reset(_ view: UIView) {
                if let image = view as? PhotoZoomView { image.setZoomScale(1, animated: false) }
                else { view.subviews.forEach(reset) }
            }
            if let view = viewIfLoaded { reset(view) }
            enlarged = false
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: LocalPhotoPager
        weak var pager: UIPageViewController?
        var pages: [String: Page] = [:]
        private var transitioning = false
        init(_ parent: LocalPhotoPager) { self.parent = parent }

        func update(_ parent: LocalPhotoPager) {
            self.parent = parent
            guard let pager, !transitioning, parent.assets.indices.contains(parent.index) else { return }
            let target = page(at: parent.index)!
            if (pager.viewControllers?.first as? Page)?.assetID != target.assetID {
                let oldIndex = position(of: pager.viewControllers?.first) ?? parent.index
                target.resetZoom()
                transitioning = true
                pager.setViewControllers([target], direction: parent.index >= oldIndex ? .forward : .reverse, animated: pager.view.window != nil) { [weak self] _ in
                    guard let self else { return }
                    self.transitioning = false
                    self.prune()
                    self.update(self.parent)
                }
            }
            updateScrolling()
        }
        private func page(at index: Int) -> Page? {
            guard parent.assets.indices.contains(index) else { return nil }
            let asset = parent.assets[index]
            if let page = pages[asset.localIdentifier] { return page }
            let page = Page(assetID: asset.localIdentifier)
            page.rootView = AnyView(AssetImage(asset: asset, large: true, onZoomChanged: { [weak self, weak page] enlarged in
                page?.enlarged = enlarged
                self?.updateScrolling()
            }, onPrevious: { [weak self] in
                guard let self, parent.enabled, parent.index > 0 else { return }
                parent.index -= 1
            }, onNext: { [weak self] in
                guard let self, parent.enabled, parent.index + 1 < parent.assets.count else { return }
                parent.index += 1
            }).environmentObject(parent.library))
            page.view.backgroundColor = .clear
            pages[asset.localIdentifier] = page
            return page
        }
        private func position(of controller: UIViewController?) -> Int? {
            guard let page = controller as? Page else { return nil }
            return parent.assets.firstIndex { $0.localIdentifier == page.assetID }
        }
        func pageViewController(_ pager: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
            guard parent.enabled, let index = position(of: controller) else { return nil }
            return page(at: index - 1)
        }
        func pageViewController(_ pager: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
            guard parent.enabled, let index = position(of: controller) else { return nil }
            return page(at: index + 1)
        }
        func pageViewController(_ pager: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { transitioning = true }
        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            if completed, let index = position(of: pager.viewControllers?.first) {
                previousViewControllers.compactMap { $0 as? Page }.forEach { $0.resetZoom() }
                parent.index = index
            }
            prune()
            update(parent)
        }
        private func updateScrolling() {
            guard let pager else { return }
            let enlarged = (pager.viewControllers?.first as? Page)?.enlarged ?? false
            for case let scroll as UIScrollView in pager.view.subviews { scroll.isScrollEnabled = parent.enabled && !enlarged }
        }
        private func prune() {
            guard let current = position(of: pager?.viewControllers?.first) else { return }
            let ids = Set(parent.assets[max(0, current - 1)...min(parent.assets.count - 1, current + 1)].map(\.localIdentifier))
            pages = pages.filter { ids.contains($0.key) }
        }
    }
}
