import XCTest
import Photos
import UIKit
@testable import MoriPhotos

final class PhotoLibraryIntegrationTests: XCTestCase {
    @MainActor
    func testImportFavoriteAndOriginalSize() async throws {
        // Run on an isolated simulator with photos permission granted to the app.
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Grant photos permission on a disposable simulator to run this integration test.")
        }
        let store = PhotoLibraryStore()
        let before = Set(store.assets.map(\.localIdentifier))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format)
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Mori-QA-\(UUID().uuidString).png")
        let sourceData = try XCTUnwrap(image.pngData())
        try sourceData.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await store.save(file: file)
        store.reload()
        let imported = try XCTUnwrap(store.assets.first { !before.contains($0.localIdentifier) })
        XCTAssertEqual(imported.pixelWidth, 120)
        XCTAssertEqual(imported.pixelHeight, 80)
        // Verify both the metadata path and older-iOS streaming fallback against original bytes.
        for useMetadata in [true, false] {
            let size = PhotoFileSizeLoader(useResourceMetadata: useMetadata)
            size.load(asset: imported)
            for _ in 0..<100 where size.state == .loading { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(size.state, .available(Int64(sourceData.count)))
            size.cancel()
        }
        await store.favorite([imported], value: true)
        XCTAssertNil(store.error)
        let favorite = try XCTUnwrap(store.assets.first { $0.localIdentifier == imported.localIdentifier })
        XCTAssertTrue(favorite.isFavorite)
        await store.favorite([favorite], value: false)
        XCTAssertFalse(try XCTUnwrap(store.assets.first { $0.localIdentifier == imported.localIdentifier }).isFavorite)
        // Fixture stays only in the disposable simulator; this test never deletes user photos.
    }
}
