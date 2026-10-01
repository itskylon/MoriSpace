import XCTest

final class HomeOverviewUITests: XCTestCase {
    private let fixtureArguments = [
        "--nas-connection-fixture", "--reset-nas-connection-fixture", "--calendar-fixture",
        "--onedrive-fixture"
    ]

    func testPhoneMenuShrinksWhileBrowsingAndExpandsForNavigation() {
        continueAfterFailure = false
        let app = launch(arguments: fixtureArguments)
        let bar = app.phoneMenus.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        app.phoneMenus.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["newPhotoBackupSettings"].waitForExistence(timeout: 5))
        let expandedWidth = bar.frame.width
        assertMenuLayout(app, selected: "设置", expanded: true)
        capture("phone-menu-expanded")
        app.swipeUp()
        XCTAssertTrue(wait(for: NSPredicate { _, _ in (bar.value as? String) == "收起" }, on: bar))
        XCTAssertLessThan(bar.frame.width, expandedWidth - 40)
        XCTAssertEqual(app.phoneMenus.buttons.count, 5)
        for button in app.phoneMenus.buttons.allElementsBoundByIndex {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        assertMenuLayout(app, selected: "设置", expanded: false)
        capture("phone-menu-scrolling")
        app.swipeDown()
        XCTAssertTrue(wait(for: NSPredicate { _, _ in (bar.value as? String) == "展开" }, on: bar))
        XCTAssertEqual(bar.frame.width, expandedWidth, accuracy: 1)
        capture("phone-menu-restored")
        XCTAssertTrue(app.phoneMenus.buttons["首页"].waitForExistence(timeout: 5))
        app.phoneMenus.buttons["首页"].tap()
        XCTAssertTrue(app.buttons["homeNASFiles"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(wait(for: NSPredicate { _, _ in (bar.value as? String) == "收起" }, on: bar))
        app.phoneMenus.buttons["日历"].tap()
        XCTAssertTrue(app.staticTexts["calendarSelectedDay"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: NSPredicate { _, _ in (bar.value as? String) == "展开" }, on: bar))

        app.phoneMenus.buttons["存储"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "nasPhotoCell").firstMatch.waitForExistence(timeout: 10))
        assertMenuLayout(app, selected: "存储", expanded: true)
        capture("phone-photos-menu-expanded")
        app.swipeUp()
        XCTAssertTrue(wait(for: NSPredicate { _, _ in (bar.value as? String) == "收起" }, on: bar))
        XCTAssertEqual(app.phoneMenus.buttons.allElementsBoundByIndex.map(\.label), ["首页", "照片", "存储", "日历", "设置"])
        capture("phone-photos-menu-compact")
        app.buttons["nasSectionFiles"].tap()
        XCTAssertTrue(app.buttons["nasFolder_测试共享"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: NSPredicate { _, _ in (bar.value as? String) == "展开" }, on: bar))
    }

    private func assertMenuLayout(_ app: XCUIApplication, selected: String, expanded: Bool) {
        let buttons = app.phoneMenus.buttons.allElementsBoundByIndex
        let activeWidth = app.phoneMenus.buttons[selected].frame.width
        let inactive = buttons.filter { $0.label != selected }
        if expanded {
            XCTAssertGreaterThan(activeWidth, inactive[0].frame.width + 16)
        } else {
            XCTAssertEqual(activeWidth, inactive[0].frame.width, accuracy: 1)
        }
        for (index, button) in buttons.enumerated() {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            if index > 0 { XCTAssertGreaterThanOrEqual(button.frame.minX, buttons[index - 1].frame.maxX + 3) }
        }
        for button in inactive { XCTAssertEqual(button.frame.width, inactive[0].frame.width, accuracy: 1) }
    }

    func testPhoneHomeShowsDeviceAndKeepsFileLocationAcrossQuickLinks() {
        continueAfterFailure = false
        let app = launch(arguments: fixtureArguments)
        XCTAssertEqual(app.phoneMenus.buttons.allElementsBoundByIndex.map(\.label), ["首页", "照片", "存储", "日历", "设置"])
        XCTAssertTrue(app.phoneMenus.buttons["首页"].isSelected, "A fresh launch must open the overview")
        assertHomeDevice(app)
        let viewport = CGRect(x: app.frame.minX, y: app.frame.minY, width: app.frame.width,
                              height: app.phoneMenus.firstMatch.frame.minY - app.frame.minY)
        for id in ["homeLocalPhotos", "homeNASPhotos", "homeNASFiles", "homeOneDrive", "homeDevice"] {
            assertVisible(app.buttons[id], in: viewport)
        }
        for id in ["homeCPU", "homeMemory"] { assertVisible(app.staticTexts[id], in: viewport) }
        capture("home-phone-overview")

        app.buttons["homeNASFiles"].tap()
        XCTAssertTrue(app.phoneMenus.buttons["存储"].isSelected)
        let share = app.buttons["nasFolder_测试共享"]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        let file = app.buttons["nasFile_说明 + 中文.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        XCTAssertTrue(file.isHittable)
        capture("home-phone-nas-folder")

        returnToPhoneHome(app)
        app.buttons["homeNASPhotos"].tap()
        XCTAssertTrue(app.phoneMenus.buttons["存储"].isSelected)
        let photo = app.buttons.matching(identifier: "nasPhotoCell").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "The saved files path must not cover the photo shortcut's destination")
        XCTAssertTrue(photo.isHittable)

        returnToPhoneHome(app)
        app.buttons["homeDevice"].tap()
        let cpu = app.staticTexts["monitorCPU"]
        XCTAssertTrue(cpu.waitForExistence(timeout: 10), "Device details must replace the files section even when it has a nested path")
        XCTAssertEqual(cpu.label, "18%")
        XCTAssertTrue(cpu.isHittable)

        returnToPhoneHome(app)
        app.buttons["homeNASFiles"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5), "Opening photos and device status must preserve the independent files navigation path")
        XCTAssertFalse(share.exists, "The shortcut must not silently reset the browser to shared folders")
        XCTAssertTrue(file.isHittable)

        returnToPhoneHome(app)
        revealButton("homeCalendar", in: app).tap()
        XCTAssertTrue(app.phoneMenus.buttons["日历"].isSelected)
        let selectedDay = app.staticTexts["calendarSelectedDay"]
        XCTAssertTrue(selectedDay.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedDay.label, Date().formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_Hans_CN"))))
        XCTAssertTrue(app.buttons["calendarNewEvent"].isHittable)
        returnToPhoneHome(app)
        XCTAssertTrue(app.buttons["homeNASFiles"].exists)
    }

    func testIPadHomeFitsDetailColumnAndRoutesToEachStorageSource() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(arguments: fixtureArguments)
        XCTAssertFalse(app.phoneMenus.firstMatch.exists)
        let home = app.buttons["sidebar_home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.isSelected)
        XCTAssertTrue(wait(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, on: app), "Landscape bounds must settle before inspection")
        assertHomeDevice(app)
        let sidebar = app.descendants(matching: .any)["workspaceSidebar"].firstMatch
        XCTAssertTrue(sidebar.exists)
        let title = app.staticTexts["homeTitle"]
        XCTAssertGreaterThanOrEqual(title.frame.minX, sidebar.frame.maxX, "The overview must use the detail column")
        for id in ["homeLocalPhotos", "homeNASPhotos", "homeNASFiles", "homeOneDrive", "homeDevice"] {
            assertVisible(app.buttons[id], in: app.frame)
        }
        for id in ["homeCPU", "homeMemory"] { assertVisible(app.staticTexts[id], in: app.frame) }
        capture("home-ipad-wide")

        app.buttons["homeNASFiles"].tap()
        XCTAssertTrue(app.buttons["nasFolder_测试共享"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sidebar_files"].isSelected)
        app.buttons["nasFolder_测试共享"].tap()
        let file = app.buttons["nasFile_说明 + 中文.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        home.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["homeNASFiles"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5), "The wide shortcut must retain the files navigation path")
        capture("home-ipad-nas-folder")

        home.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["homeNASPhotos"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "nasPhotoCell").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sidebar_photos"].isSelected)
        home.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["homeOneDrive"].tap()
        XCTAssertTrue(app.buttons["oneDriveItem_photos"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sidebar_oneDrive"].isSelected)
        home.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["homeDevice"].tap()
        XCTAssertTrue(app.staticTexts["monitorCPU"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sidebar_monitor"].isSelected)
        home.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    func testEmptyHomeShowsUnknownDeviceMetricsAndOpensNASConnection() {
        continueAfterFailure = false
        let app = launch(arguments: ["--empty-connection-fixture"])
        XCTAssertTrue(app.phoneMenus.buttons["首页"].isSelected)
        let status = app.staticTexts["homeNASStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("未连接"))
        for id in ["homeCPU", "homeMemory"] {
            let metric = app.staticTexts[id]
            if metric.exists {
                XCTAssertNil(metric.label.range(of: "[0-9]", options: .regularExpression),
                             "An unconnected device must show a missing value, never a fabricated reading such as 0%")
            }
        }
        XCTAssertTrue(app.buttons["homeDevice"].isHittable)
        capture("home-phone-empty")
        app.buttons["homeDevice"].tap()
        XCTAssertTrue(app.phoneMenus.buttons["存储"].isSelected)
        let connect = app.buttons["connectMonitor"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5)); connect.tap()
        XCTAssertTrue(app.textFields["nasAddress"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["loginNAS"].isEnabled, "Opening the connection page must not initiate authentication")
        capture("home-phone-connect-device")
        app.buttons["dismissNASConnection"].tap()
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        returnToPhoneHome(app)
        XCTAssertTrue(status.label.contains("未连接"))
    }

    func testRemovedQuotaEntryAndLinkLeaveCalendarAvailable() {
        continueAfterFailure = false
        let app = launch(arguments: ["--empty-connection-fixture", "--calendar-fixture"])
        XCTAssertFalse(app.buttons["homeUsage"].exists)
        XCTAssertFalse(app.staticTexts["Codex 额度"].exists)
        capture("home-without-quota")
        app.phoneMenus.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["newPhotoBackupSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["usageSettings"].exists)
        app.swipeUp()
        XCTAssertFalse(app.buttons["usageSettings"].exists)
        capture("settings-without-quota")
        XCUIDevice.shared.system.open(URL(string: "morispace://usage")!)
        XCTAssertTrue(app.phoneMenus.buttons["设置"].isSelected)
        XCTAssertFalse(app.buttons["dismissUsage"].exists)
        XCUIDevice.shared.system.open(URL(string: "morispace://calendar?date=2026-09-25")!)
        let lunar = app.staticTexts["calendarSelectedLunarDay"]
        XCTAssertTrue(lunar.waitForExistence(timeout: 10))
        XCTAssertEqual(lunar.label, "农历八月十五 · 中秋")
        XCTAssertTrue(app.phoneMenus.buttons["日历"].isSelected)
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["homeTitle"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["homeUsage"].exists)
        return app
    }

    private func assertHomeDevice(_ app: XCUIApplication) {
        let cpu = app.staticTexts["homeCPU"]
        XCTAssertTrue(cpu.waitForExistence(timeout: 15))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "18%"), on: cpu), "CPU must come from the NAS fixture response")
        XCTAssertEqual(app.staticTexts["homeMemory"].label, "36%")
        XCTAssertTrue(app.staticTexts["homeNASStatus"].exists)
        XCTAssertTrue(app.staticTexts["homeUpdated"].exists)
    }

    private func returnToPhoneHome(_ app: XCUIApplication) {
        app.phoneMenus.buttons["首页"].tap()
        XCTAssertTrue(app.staticTexts["homeTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.phoneMenus.buttons["首页"].isSelected)
    }

    private func revealButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier]
        for _ in 0..<5 {
            if button.exists && button.isHittable { return button }
            app.swipeUp()
        }
        XCTAssertTrue(button.exists, "The Home shortcut \(identifier) must exist")
        XCTAssertTrue(button.isHittable, "The Home shortcut \(identifier) must be reachable by scrolling")
        return button
    }

    private func assertVisible(_ element: XCUIElement, in viewport: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(element.identifier) must be usable without scrolling", file: file, line: line)
        let frame = element.frame
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1, file: file, line: line)
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        // app.screenshot() can retain portrait crop bounds after iPad rotation.
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
