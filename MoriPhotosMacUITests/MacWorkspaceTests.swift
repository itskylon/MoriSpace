import XCTest

final class MacWorkspaceTests: XCTestCase {
    func testDesktopBrowsingKeyboardAndPersistentNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--nas-connection-fixture", "--reset-nas-connection-fixture"]
        app.launch()
        let photos = app.buttons.matching(identifier: "nasPhotoCell")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        capture(app, "36-mac-photos")
        photos.firstMatch.click()
        let zoom = app.scrollViews["photoZoom"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "100%"), object: zoom).waitForFulfillment(timeout: 5))
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "100%"), object: zoom).waitForFulfillment(timeout: 5))
        app.typeKey(.rightArrow, modifierFlags: [])
        let position = app.staticTexts["nasPhotoPosition"]
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "2 / 12"), object: position).waitForFulfillment(timeout: 5))
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1 / 12"), object: position).waitForFulfillment(timeout: 5))
        capture(app, "37-mac-photo-preview")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("3", modifierFlags: .command)
        let share = app.staticTexts["nasFolder_测试共享"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.doubleClick()
        let file = app.staticTexts["nasFile_说明 + 中文.txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        capture(app, "38-mac-file-table")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(file.waitForExistence(timeout: 5), "Switching sidebar sections must keep the current folder")
        file.doubleClick()
        XCTAssertTrue(app.buttons["downloadFile"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["downloadFile"].label, "下载到 Mac")
        app.buttons["downloadFile"].click()
        app.buttons["完成"].firstMatch.click()
        app.typeKey("4", modifierFlags: .command)
        app.descendants(matching: .any)["已下载"].firstMatch.click()
        XCTAssertTrue(app.buttons["exportFile"].waitForExistence(timeout: 10))
        app.buttons["exportFile"].click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5) || app.sheets.firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["monitorCPU"].waitForExistence(timeout: 10))
        capture(app, "39-mac-nas-status")
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(app.buttons["chooseBackupFolder"].waitForExistence(timeout: 5))
        app.buttons["chooseBackupFolder"].click()
        XCTAssertTrue(app.buttons["backupFolder_测试共享"].waitForExistence(timeout: 10))
        capture(app, "40-mac-backup-folder")
        app.buttons["cancelBackupFolder"].click()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Mac 照片图库"].firstMatch.waitForExistence(timeout: 5))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
private extension XCTestExpectation {
    func waitForFulfillment(timeout: TimeInterval) -> Bool { XCTWaiter.wait(for: [self], timeout: timeout) == .completed }
}
