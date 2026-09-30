import XCTest

final class OneDriveUITests: XCTestCase {
    func testBrowsePreviewDownloadAndDisconnectWithOfflineFiles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--onedrive-fixture"]
        app.launch()
        let wide = app.buttons["sidebar_oneDrive"].waitForExistence(timeout: 2)
        if wide { app.buttons["sidebar_oneDrive"].tap() }
        else {
            app.phoneMenus.buttons["存储"].tap()
            app.buttons["storageSourceMenu"].tap()
            app.buttons["storageChooseOneDrive"].tap()
        }
        let photos = app.buttons["oneDriveItem_photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 8))
        capture(app, wide ? "onedrive-ipad-root" : "onedrive-phone-root")
        if wide { photos.doubleTap() } else { photos.tap() }
        XCTAssertTrue(app.buttons["oneDriveItem_sample"].waitForExistence(timeout: 8))
        if wide {
            app.buttons["sidebar_calendar"].tap(); app.buttons["sidebar_oneDrive"].tap()
        } else {
            app.buttons["storageSourceMenu"].tap(); app.buttons["storageChooseNAS"].tap()
            XCTAssertTrue(app.buttons["nasSectionFiles"].waitForExistence(timeout: 4))
            app.buttons["storageSourceMenu"].tap(); app.buttons["storageChooseOneDrive"].tap()
        }
        XCTAssertTrue(app.buttons["oneDriveItem_sample"].waitForExistence(timeout: 5))
        app.buttons["oneDriveRoot"].tap()
        let welcome = app.buttons["oneDriveItem_welcome"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        if wide { welcome.doubleTap() } else { welcome.tap() }
        app.buttons["oneDrivePreview"].tap()
        let quickLook = app.descendants(matching: .any)["oneDriveQuickLook"].firstMatch
        XCTAssertTrue(quickLook.waitForExistence(timeout: 10))
        let previewText = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "欢迎使用森空间 OneDrive")).firstMatch
        XCTAssertTrue(previewText.waitForExistence(timeout: 15), "The file contents must render, not just the Quick Look container")
        capture(app, wide ? "onedrive-ipad-preview" : "onedrive-phone-preview")
        app.buttons["oneDrivePreviewDone"].tap()
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        if wide { welcome.doubleTap() } else { welcome.tap() }
        app.buttons["oneDriveDownload"].tap()
        let state = app.staticTexts["oneDriveDownloadState"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let downloaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已下载"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [downloaded], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["oneDriveExport"].exists)
        capture(app, wide ? "onedrive-ipad-download" : "onedrive-phone-download")
        app.buttons["oneDriveDownloadsDone"].tap()
        app.buttons["oneDriveMore"].tap(); app.buttons["账号设置"].tap()
        app.buttons["oneDriveSignOut"].tap(); app.buttons["退出账号"].tap()
        XCTAssertTrue(app.buttons["connectOneDrive"].waitForExistence(timeout: 8))
        app.buttons["oneDriveOfflineDownloads"].tap()
        XCTAssertTrue(app.buttons["oneDriveOpenDownload"].waitForExistence(timeout: 5))
        app.buttons["oneDriveDownloadsDone"].tap()
        app.buttons["connectOneDrive"].tap()
        let clientID = app.textFields["oneDriveClientID"]
        XCTAssertTrue(clientID.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["oneDriveSignIn"].isEnabled)
        clientID.tap(); clientID.typeText("not-an-application-id")
        XCTAssertFalse(app.buttons["oneDriveSignIn"].isEnabled)
        capture(app, wide ? "onedrive-ipad-connection" : "onedrive-phone-connection")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
