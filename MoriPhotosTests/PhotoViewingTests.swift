import XCTest
import UIKit
@testable import MoriPhotos

final class PhotoViewingTests: XCTestCase {
    @MainActor
    func testZoomCentersTheImageAndPreservesZoomDuringHigherResolutionDelivery() {
        func image(_ size: CGSize) -> UIImage {
            UIGraphicsImageRenderer(size: size, format: {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
            }()).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
        let view = PhotoZoomView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.show(image(CGSize(width: 600, height: 400)))
        view.layoutIfNeeded()
        XCTAssertEqual(view.imageView.frame.width, 400, accuracy: 0.1)
        XCTAssertEqual(view.contentInset.top, (600 - 400 / 1.5) / 2, accuracy: 0.1)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)

        view.setZoomScale(3, animated: false)
        XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        XCTAssertEqual(view.accessibilityValue, "300%")
        view.show(image(CGSize(width: 1200, height: 800)))
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 3, accuracy: 0.01)

        view.frame.size = CGSize(width: 600, height: 400)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1, accuracy: 0.01)
        XCTAssertEqual(view.imageView.frame.size.width, 600, accuracy: 0.1)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
    }
}
