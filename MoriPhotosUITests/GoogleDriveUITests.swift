import XCTest
import UIKit

/// These checks cover entry points and local navigation only. Reaching the Google
/// sign-in button does not establish that a real Google account was authorized.
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
