import XCTest
import UIKit

/// Entry-point checks do not establish real Google account authorization. The
/// folder-gesture cases use a simulator-only protocol with no real OAuth or API.
final class GoogleDriveUITests: XCTestCase {
    private let fixtureArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]

    func testPhoneHomeOpensGoogleSignInAndLocalDownloads() throws {
        try requirePhone()
        let app = launch()
        reveal("homeGoogleDrive", in: app).tap()
        assertGoogleSignInEntry(app)
        XCTAssertTrue(app.buttons["storageProviderMenu"].label.contains("Google Drive"))
        capture("google-drive-phone-sign-in-entry")
        checkEmptyDownloadsAndReturn(in: app)
        XCTAssertTrue(app.buttons["connectGoogleDrive"].isHittable)
    }

    func testPhoneChangingStorageProviderRetainsNASFolder() throws {
        try requirePhone()
        let app = launch()
        reveal("homeNASFiles", in: app).tap()
        let share = app.buttons["nasFolder_测试共享"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let file = app.buttons["nasFile_说明 + 中文.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        capture("google-drive-nas-folder-before-provider-change")

        selectProvider("storageProviderGoogleDrive", in: app)
        assertGoogleSignInEntry(app)
        XCTAssertFalse(file.isHittable, "The hidden NAS browser must not accept touches under Google Drive")
        selectProvider("storageProviderSynology", in: app)
        XCTAssertTrue(file.waitForExistence(timeout: 8), "Switching providers must preserve the open NAS folder")
        XCTAssertTrue(file.isHittable)
        XCTAssertFalse(app.buttons["connectGoogleDrive"].isHittable)
        capture("google-drive-nas-folder-restored")
    }

    func testPhoneLargeTextKeepsGoogleConnectionControlsReachable() throws {
        try requirePhone()
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        reveal("homeGoogleDrive", in: app).tap()
        assertGoogleSignInEntry(app)
        let signIn = reveal("connectGoogleDrive", in: app)
        assertInsideHorizontalBounds(signIn, in: app)
        XCTAssertGreaterThanOrEqual(signIn.frame.height, 44)
        XCTAssertTrue(app.buttons["googleDriveDownloads"].isHittable)
        XCTAssertTrue(app.buttons["storageProviderMenu"].isHittable)
        capture("google-drive-phone-large-text")
    }

    func testPhoneDriveEdgeSwipeReturnsExactlyOneFolderAndUpButtonReachesRoot() throws {
        try requirePhone()
        let app = openGestureFixture()
        enterNestedFixtureFolder(in: app)

        edgeDrag(in: app, distance: app.frame.width * 0.72)
        let child = app.buttons["googleDriveFile_fixture-child"]
        XCTAssertTrue(child.waitForExistence(timeout: 8), "A completed edge swipe must return to the immediate parent")
        XCTAssertTrue(app.buttons["googleDriveBreadcrumb_fixture-folder"].exists)
        XCTAssertFalse(app.buttons["googleDriveBreadcrumb_fixture-child"].exists, "One swipe must remove exactly one folder")
        XCTAssertFalse(app.buttons["googleDriveFile_fixture-root-file"].exists)
        capture("google-drive-phone-edge-swipe-parent")

        let up = app.buttons["googleDriveUp"]
        XCTAssertTrue(up.isHittable)
        up.tap()
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-root-file"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["googleDriveBreadcrumb_fixture-folder"].exists)
        capture("google-drive-phone-up-button-root")
    }

    func testPhoneDriveShortEdgeDragAndVerticalScrollingKeepCurrentFolder() throws {
        try requirePhone()
        let app = openGestureFixture()
        enterNestedFixtureFolder(in: app)

        // Releasing a short, slow drag below the commit threshold must cancel.
        edgeDrag(in: app, distance: 28, hold: 0.5)
        XCTAssertTrue(app.buttons["googleDriveBreadcrumb_fixture-child"].exists)
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-child-file-1"].isHittable)
        XCTAssertFalse(app.buttons["googleDriveFile_fixture-root-file"].exists)

        app.swipeUp()
        XCTAssertTrue(app.buttons["googleDriveBreadcrumb_fixture-child"].exists,
                      "Vertical file scrolling must not navigate to the parent")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"),
            object: app.buttons["googleDriveFile_fixture-child-file-1"])], timeout: 5), .completed,
                       "The list must actually scroll while the edge gesture is installed")
        capture("google-drive-phone-scroll-does-not-pop")
    }

    func testPhoneDriveRootEdgeSwipeDoesNotLeaveCloudProvider() throws {
        try requirePhone()
        let app = openGestureFixture()
        edgeDrag(in: app, distance: app.frame.width * 0.72)
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-root-file"].isHittable)
        XCTAssertTrue(app.buttons["storageProviderMenu"].label.contains("Google Drive"))
        XCTAssertFalse(app.buttons["googleDriveBreadcrumb_fixture-folder"].exists)
        XCTAssertFalse(app.buttons["googleDriveUp"].exists)
        capture("google-drive-phone-root-edge-stays-root")
    }

    func testPhoneSettingsDriveEdgeSwipeReturnsFolderBeforePoppingSettings() throws {
        try requirePhone()
        let app = openSettingsGestureFixture()
        enterNestedFixtureFolder(in: app)

        edgeDrag(in: app, distance: app.frame.width * 0.72)
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-child"].waitForExistence(timeout: 8),
                      "The Drive folder gesture must win over the Settings navigation pop")
        XCTAssertTrue(app.buttons["googleDriveBreadcrumb_fixture-folder"].exists)
        XCTAssertFalse(app.buttons["googleDriveBreadcrumb_fixture-child"].exists)
        XCTAssertFalse(app.buttons["googleDriveSettings"].isHittable)
        capture("google-drive-settings-edge-returns-folder")
    }

    func testPhoneHiddenSettingsDriveDoesNotInterceptNASBackSwipe() throws {
        try requirePhone()
        let app = openSettingsGestureFixture()
        enterNestedFixtureFolder(in: app)

        app.buttons["phoneMenu_home"].tap()
        reveal("homeNASFiles", in: app).tap()
        let share = app.buttons["nasFolder_测试共享"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let nasFile = app.buttons["nasFile_说明 + 中文.txt"]
        XCTAssertTrue(nasFile.waitForExistence(timeout: 10))
        edgeDrag(in: app, distance: app.frame.width * 0.72)
        XCTAssertTrue(share.waitForExistence(timeout: 8),
                      "The inactive Settings Drive must not steal the active NAS navigation gesture")
        XCTAssertTrue(share.isHittable)
        XCTAssertFalse(nasFile.isHittable)

        app.buttons["phoneMenu_settings"].tap()
        XCTAssertTrue(app.buttons["googleDriveBreadcrumb_fixture-child"].waitForExistence(timeout: 8),
                      "The hidden Drive folder must retain its previous depth")
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-child-file-1"].isHittable)
        capture("google-drive-hidden-settings-keeps-depth")
    }

    func testPhoneDriveReturningToVisitedFolderRestoresListAnchor() throws {
        try requirePhone()
        let app = openGestureFixture()
        app.buttons["googleDriveFile_fixture-folder"].tap()
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-child"].waitForExistence(timeout: 8))
        app.swipeUp()
        app.swipeUp()
        XCTAssertFalse(app.buttons["googleDriveFile_fixture-travel-1"].isHittable)
        let listTop = app.buttons["googleDriveUp"].frame.maxY + 12
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "googleDriveFile_fixture-travel-"))
            .allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.minY >= listTop }
            .sorted { $0.frame.minY < $1.frame.minY }
        let anchor = try XCTUnwrap(rows.first, "Scrolling must reveal a later travel row")
        let identifier = anchor.identifier
        let originalY = anchor.frame.minY
        capture("google-drive-folder-scroll-before-return")

        app.buttons["googleDriveUp"].tap()
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-root-file"].waitForExistence(timeout: 8))
        app.buttons["googleDriveFile_fixture-folder"].tap()
        let restored = app.buttons[identifier]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: restored)], timeout: 8), .completed,
                       "Re-entering the cached folder must restore the previously visible rows")
        XCTAssertLessThan(abs(restored.frame.minY - originalY), 120,
                          "Restored scrolling may align the row to the top but must remain near the saved position")
        XCTAssertFalse(app.buttons["googleDriveFile_fixture-travel-1"].isHittable)
        capture("google-drive-folder-scroll-restored")
    }

    func testIPadSidebarOpensGoogleDriveAndReturnsToNASFolder() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "This case verifies the iPad sidebar")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        let filesSidebar = app.buttons["sidebar_files"]
        XCTAssertTrue(filesSidebar.waitForExistence(timeout: 15))
        filesSidebar.tap()
        let share = app.buttons["nasFolder_测试共享"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let file = app.buttons["nasFile_说明 + 中文.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))

        let cloudSidebar = app.buttons["sidebar_googleDrive"]
        XCTAssertTrue(cloudSidebar.waitForExistence(timeout: 5))
        cloudSidebar.tap()
        assertGoogleSignInEntry(app)
        XCTAssertTrue(cloudSidebar.isSelected)
        XCTAssertFalse(app.phoneMenus.firstMatch.exists)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        capture("google-drive-ipad-sidebar-entry")
        checkEmptyDownloadsAndReturn(in: app)

        filesSidebar.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 8), "The NAS sidebar must retain its previous folder")
        XCTAssertTrue(file.isHittable)
        capture("google-drive-ipad-nas-folder-retained")
    }

    private func requirePhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "This case verifies the compact iPhone layout")
        XCUIDevice.shared.orientation = .portrait
    }

    private func openGestureFixture() -> XCUIApplication {
        let app = launch(extra: ["--google-drive-fixture"])
        reveal("homeGoogleDrive", in: app).tap()
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-folder"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-root-file"].isHittable)
        XCTAssertFalse(app.buttons["connectGoogleDrive"].exists)
        return app
    }

    private func openSettingsGestureFixture() -> XCUIApplication {
        let app = launch(extra: ["--google-drive-fixture"])
        app.buttons["phoneMenu_settings"].tap()
        reveal("googleDriveSettings", in: app).tap()
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-folder"].waitForExistence(timeout: 10))
        return app
    }

    private func enterNestedFixtureFolder(in app: XCUIApplication) {
        app.buttons["googleDriveFile_fixture-folder"].tap()
        let child = app.buttons["googleDriveFile_fixture-child"]
        XCTAssertTrue(child.waitForExistence(timeout: 8))
        child.tap()
        XCTAssertTrue(app.buttons["googleDriveFile_fixture-child-file-1"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["googleDriveBreadcrumb_fixture-child"].exists)
    }

    private func edgeDrag(in app: XCUIApplication, distance: CGFloat, hold: TimeInterval = 0) {
        // Start inside the screen edge and below the horizontally scrolling
        // breadcrumbs, using real touch coordinates rather than calling goUp.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 2, dy: app.frame.height * 0.6))
        let end = origin.withOffset(CGVector(dx: 2 + distance, dy: app.frame.height * 0.6))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = fixtureArguments + extra
        app.launch()
        return app
    }

    private func assertGoogleSignInEntry(_ app: XCUIApplication) {
        let signIn = app.buttons["connectGoogleDrive"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "The configured app must offer official Google sign-in")
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["googleDriveNeedsConfiguration"].exists)
        XCTAssertTrue(app.buttons["googleDriveDownloads"].isHittable)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "Mori Space must not ask for a Google password in a native app field")
    }

    private func selectProvider(_ identifier: String, in app: XCUIApplication) {
        let menu = app.buttons["storageProviderMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        let option = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    private func checkEmptyDownloadsAndReturn(in app: XCUIApplication) {
        app.buttons["googleDriveDownloads"].tap()
        let filter = app.segmentedControls["googleDriveDownloadsFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["没有下载任务"].waitForExistence(timeout: 5))
        filter.buttons["已下载"].tap()
        XCTAssertTrue(app.staticTexts["还没有已下载文件"].waitForExistence(timeout: 5))
        capture("google-drive-empty-offline-downloads")
        let done = app.navigationBars.buttons["完成"].firstMatch
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(app.buttons["connectGoogleDrive"].waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: filter)], timeout: 5), .completed)
    }

    @discardableResult
    private func reveal(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier]
        for _ in 0..<6 {
            if button.exists && button.isHittable { return button }
            app.swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable, "The control must remain reachable by scrolling")
        return button
    }

    private func assertInsideHorizontalBounds(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
