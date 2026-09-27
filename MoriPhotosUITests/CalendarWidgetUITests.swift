import XCTest

final class CalendarWidgetUITests: XCTestCase {
    private func openWidgetGallery(usage: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-fixture", "--widget-fixture"]
        if usage { app.launchArguments.append("--usage-widget-fixture") }
        app.launch()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func visibleIcon(_ element: XCUIElement) -> Bool {
            let frame = element.frame
            return !frame.isEmpty && springboard.frame.contains(frame)
        }
        var icon = springboard.icons["森空间"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        // Offscreen icons may report hittable despite a zero-size frame on iOS 27.
        if !visibleIcon(icon) {
            XCUIDevice.shared.press(.home)
            for _ in 0..<6 {
                if let visible = springboard.icons.matching(identifier: "森空间").allElementsBoundByIndex.first(where: visibleIcon) {
                    icon = visible
                    break
                }
                springboard.swipeLeft()
            }
        }
        if !visibleIcon(icon) { print(springboard.debugDescription) }
        XCTAssertTrue(visibleIcon(icon))
        icon.press(forDuration: 1.2)
        let edit = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Edit Home Screen", "编辑主屏幕"])).firstMatch
        if !edit.waitForExistence(timeout: 4) { print(springboard.debugDescription) }
        XCTAssertTrue(edit.exists); edit.tap()
        let editMenu = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Edit", "编辑"])).firstMatch
        if editMenu.waitForExistence(timeout: 4) { editMenu.tap() }
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Add Widget", "Add Widgets", "添加小组件"])).firstMatch
        if !addWidget.waitForExistence(timeout: 4) { print(springboard.debugDescription) }
        XCTAssertTrue(addWidget.exists); addWidget.tap()
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("森空间")
        let result = springboard.staticTexts["森空间"].firstMatch
        if !result.waitForExistence(timeout: 8) { print(springboard.debugDescription) }
        XCTAssertTrue(result.exists); result.tap()
        return springboard
    }

    func testWidgetIsAvailableInSystemGallery() {
        let springboard = openWidgetGallery()
        let title = springboard.staticTexts["日历与农历"].firstMatch
        if !title.waitForExistence(timeout: 8) { print(springboard.debugDescription) }
        XCTAssertTrue(title.exists)
        let shot = XCTAttachment(screenshot: springboard.screenshot()); shot.name = "widget-system-gallery"; shot.lifetime = .keepAlways; add(shot)
        springboard.swipeLeft()
        // WidgetKit renders its content in a remote process; SpringBoard does not
        // consistently expose the widget's child labels to XCTest. Keep both
        // family screenshots for visual inspection and verify the system flow.
        XCTAssertTrue(title.exists)
        let preview = springboard.buttons["森空间, 日历与农历"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue((preview.value as? String ?? "").contains("Medium"))
        let medium = XCTAttachment(screenshot: springboard.screenshot()); medium.name = "widget-system-medium"; medium.lifetime = .keepAlways; add(medium)
        let confirm = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH %@ OR label ENDSWITH %@", "Add Widget", "添加小组件")).firstMatch
        XCTAssertTrue(confirm.exists); confirm.tap()
        let done = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertFalse(title.exists)
        let home = XCTAttachment(screenshot: springboard.screenshot()); home.name = "widget-on-home-screen"; home.lifetime = .keepAlways; add(home)
    }

    func testPureLunarCalendarInSystemGallery() {
        let springboard = openWidgetGallery()
        XCTAssertTrue(springboard.staticTexts["日历与农历"].firstMatch.waitForExistence(timeout: 8))
        springboard.swipeLeft()
        springboard.swipeLeft()
        let title = springboard.staticTexts["纯日历 · 农历"].firstMatch
        if !title.waitForExistence(timeout: 8) { print(springboard.debugDescription) }
        XCTAssertTrue(title.exists)
        let preview = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "纯日历 · 农历")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue((preview.value as? String ?? "").contains("Medium"))
        let medium = XCTAttachment(screenshot: springboard.screenshot())
        medium.name = "pure-calendar-medium"; medium.lifetime = .keepAlways; add(medium)
        springboard.swipeLeft()
        XCTAssertTrue((preview.value as? String ?? "").contains("Large"))
        let large = XCTAttachment(screenshot: springboard.screenshot())
        large.name = "pure-calendar-large"; large.lifetime = .keepAlways; add(large)
        let confirm = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH %@ OR label ENDSWITH %@", "Add Widget", "添加小组件")).firstMatch
        XCTAssertTrue(confirm.exists); confirm.tap()
        let done = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertFalse(title.exists)
        let home = XCTAttachment(screenshot: springboard.screenshot())
        home.name = "pure-calendar-home"; home.lifetime = .keepAlways; add(home)
    }

    func testUsageWidgetInSystemGalleryAndOnHomeScreen() {
        let springboard = openWidgetGallery(usage: true)
        let title = springboard.staticTexts["Codex 额度"].firstMatch
        for _ in 0..<7 {
            if title.exists { break }
            springboard.swipeLeft()
        }
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let preview = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Codex 额度")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue((preview.value as? String ?? "").contains("Small"))
        let small = XCTAttachment(screenshot: springboard.screenshot())
        small.name = "usage-widget-small"; small.lifetime = .keepAlways; add(small)
        springboard.swipeLeft()
        XCTAssertTrue((preview.value as? String ?? "").contains("Medium"))
        let medium = XCTAttachment(screenshot: springboard.screenshot())
        medium.name = "usage-widget-medium"; medium.lifetime = .keepAlways; add(medium)
        let confirm = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH %@ OR label ENDSWITH %@", "Add Widget", "添加小组件")).firstMatch
        XCTAssertTrue(confirm.exists); confirm.tap()
        let done = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertFalse(confirm.exists, "The gallery's Add Widget action should disappear after installation")
        let home = XCTAttachment(screenshot: springboard.screenshot())
        home.name = "usage-widget-home"; home.lifetime = .keepAlways; add(home)
    }

    func testUsageDetailsAndWidgetDeepLink() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--usage-widget-fixture"]
        app.launch()
        let settings = app.tabBars.buttons["设置"]
        if settings.exists { settings.tap() } else { app.buttons["sidebar_settings"].tap() }
        let usage = app.buttons["usageSettings"]
        XCTAssertTrue(usage.waitForExistence(timeout: 8)); usage.tap()
        XCTAssertTrue(app.staticTexts["usageRemaining"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["usageUpdatedAt"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "usage-details"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.system.open(URL(string: "morispace://usage")!)
        XCTAssertTrue(app.buttons["dismissUsage"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["usageRemaining"].firstMatch.exists)
        app.buttons["dismissUsage"].tap()
        app.terminate()
        XCUIDevice.shared.system.open(URL(string: "morispace://usage")!)
        XCTAssertTrue(app.buttons["dismissUsage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["usageRefresh"].exists)
        app.buttons["dismissUsage"].tap()
    }

    func testUsageDetailsFitIPadLandscape() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--usage-widget-fixture"]
        app.launch()
        guard app.buttons["sidebar_settings"].waitForExistence(timeout: 8) else {
            throw XCTSkip("Requires the iPad sidebar layout")
        }
        app.buttons["sidebar_settings"].tap()
        let entry = app.buttons["usageSettings"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8)); entry.tap()
        let readings = app.staticTexts.matching(identifier: "usageRemaining")
        XCTAssertTrue(readings.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(readings.count, 2)
        for item in readings.allElementsBoundByIndex {
            XCTAssertTrue(item.isHittable)
            XCTAssertTrue(app.frame.contains(item.frame))
        }
        XCTAssertTrue(app.buttons["usageRefresh"].isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "usage-ipad-landscape"; shot.lifetime = .keepAlways; add(shot)
    }

    func testWidgetLinkOpensRequestedDateFromAnotherTabAndColdLaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-fixture", "--widget-fixture"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        XCUIDevice.shared.system.open(URL(string: "morispace://calendar?date=2026-09-25")!)
        XCTAssertTrue(app.staticTexts["calendarSelectedLunarDay"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarSelectedLunarDay"].label, "农历八月十五 · 中秋")
        XCTAssertTrue(app.tabBars.buttons["日历"].isSelected)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "widget-link-calendar"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        XCUIDevice.shared.system.open(URL(string: "morispace://calendar?date=2026-02-17")!)
        // A system cold launch has no test arguments. The selected date is still shown when
        // the isolated simulator has previously granted calendar access.
        XCTAssertTrue(app.tabBars.buttons["日历"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["日历"].isSelected)
        if app.staticTexts["calendarSelectedLunarDay"].waitForExistence(timeout: 3) {
            XCTAssertEqual(app.staticTexts["calendarSelectedLunarDay"].label, "农历正月初一 · 春节")
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["calendarPermissionView"].firstMatch.exists)
        }
    }
}
