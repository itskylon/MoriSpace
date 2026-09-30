import XCTest

final class CalendarUITests: XCTestCase {
    func testPublishedHolidaysAndUncollectedYear() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["homeTitle"].waitForExistence(timeout: 10), "Calendar links must route away from the new Home landing page")
        for (date, expected) in [("2026-09-20", "国庆节调休上班"), ("2026-09-25", "中秋节放假"), ("2026-10-10", "国庆节调休上班")] {
            XCUIDevice.shared.system.open(URL(string: "morispace://calendar?date=" + date)!)
            let holiday = app.staticTexts["calendarSelectedHoliday"]
            XCTAssertTrue(holiday.waitForExistence(timeout: 8))
            XCTAssertEqual(holiday.label, expected)
            XCTAssertTrue(app.buttons["calendarDay_" + date].label.contains(expected))
            capture(app, "calendar-holiday-" + date)
        }
        XCUIDevice.shared.system.open(URL(string: "morispace://calendar?date=2027-01-01")!)
        let coverage = app.staticTexts["calendarHolidayCoverage"]
        XCTAssertTrue(coverage.waitForExistence(timeout: 8))
        XCTAssertEqual(coverage.label, "2027年放假安排未收录")
        XCTAssertFalse(app.staticTexts["calendarSelectedHoliday"].exists)
    }

    func testPhoneShowsLunarDatesAndUpdatesSelectedDay() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-fixture"]
        app.launch(); openPhoneCalendar(app)
        let lunar = app.staticTexts["calendarSelectedLunarDay"]
        XCTAssertTrue(lunar.waitForExistence(timeout: 10))
        XCTAssertTrue(lunar.label.hasPrefix("农历"))
        let grid = app.descendants(matching: .any)["calendarMonthGrid"].firstMatch
        XCTAssertTrue(grid.exists)
        for id in ["calendarSources", "calendarPreviousMonth", "calendarToday", "calendarNextMonth", "calendarMode_月历", "calendarMode_日程"] {
            let control = app.buttons[id]
            XCTAssertTrue(control.isHittable, "The in-page calendar header must keep \(id) reachable")
            XCTAssertLessThanOrEqual(control.frame.maxY, grid.frame.minY, "Calendar controls belong above the month surface")
        }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        select(tomorrow, in: app)
        let cell = app.buttons["calendarDay_" + formatter.string(from: tomorrow)]
        XCTAssertTrue(cell.isHittable)
        XCTAssertTrue(cell.label.contains(lunar.label), "Day cell and selected-day agenda must show the same lunar date")
        capture(app, "calendar-phone-lunar")
        app.buttons["calendarNextMonth"].tap()
        XCTAssertTrue(lunar.label.hasPrefix("农历"))
        app.tabBars.buttons["设置"].tap(); openPhoneCalendar(app)
        XCTAssertTrue(lunar.waitForExistence(timeout: 5))
    }

    func testPhoneCalendarFilteringAndStateSurviveTabSwitching() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-live-fixture", "--reset-calendar-live-fixture"]
        app.launch(); openPhoneCalendar(app)
        XCTAssertTrue(app.buttons["calendarNewEvent"].waitForExistence(timeout: 10))
        XCTAssertTrue(row(app, "日历验收·生日").waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarDayCount"].label, "3 项")
        XCTAssertTrue(app.buttons["calendarSources"].isHittable)
        XCTAssertTrue(app.buttons["calendarNewEvent"].isHittable)
        capture(app, "calendar-phone-month")
        app.buttons["calendarSources"].tap()
        let toggle = app.switches["calendarToggle_森空间日历验收（仅模拟器）"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["calendarSourcesDone"].isHittable, "The source sheet must restore its native navigation bar")
        app.buttons["calendarSourcesDone"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏全部日历"].waitForExistence(timeout: 5))
        app.buttons["显示全部日历"].tap()
        XCTAssertTrue(row(app, "日历验收·生日").waitForExistence(timeout: 5))
        app.buttons["calendarNextMonth"].tap()
        let month = app.staticTexts["calendarMonthTitle"].label
        app.tabBars.buttons["设置"].tap(); openPhoneCalendar(app)
        XCTAssertEqual(app.staticTexts["calendarMonthTitle"].label, month)
        app.buttons["calendarToday"].tap()
        app.buttons["calendarMode_日程"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calendarAgendaList"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "calendar-phone-agenda")
    }

    func testPhoneCreatesUsingSystemEditorAndReadsEventAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-live-fixture", "--reset-calendar-live-fixture"]
        app.launch(); openPhoneCalendar(app)
        XCTAssertTrue(row(app, "日历验收·生日").waitForExistence(timeout: 10))
        let date = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        select(date, in: app)
        app.buttons["calendarNewEvent"].tap()
        let title = app.textFields.matching(NSPredicate(format: "placeholderValue IN %@ OR label IN %@", ["Title", "标题"], ["Title", "标题"])).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.tap(); title.typeText("Calendar UI acceptance")
        capture(app, "calendar-system-editor")
        let add = app.buttons.matching(NSPredicate(format: "label IN %@", ["Add", "添加", "Done", "完成"])).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        XCTAssertTrue(row(app, "Calendar UI acceptance").waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-live-fixture"]
        app.launch(); openPhoneCalendar(app)
        XCTAssertTrue(app.buttons["calendarToday"].waitForExistence(timeout: 10))
        select(date, in: app)
        let saved = row(app, "Calendar UI acceptance")
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "calendarSheetDone", ["Done", "完成", "Close", "关闭"])).firstMatch
        if !close.waitForExistence(timeout: 8) { print(app.debugDescription) }
        XCTAssertTrue(close.exists)
        capture(app, "calendar-system-event-detail")
        close.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendarNewEvent"].isHittable)
    }

    func testIPadCalendarUsesWideMonthAndDayAgenda() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-fixture"]
        app.launch()
        let entry = app.descendants(matching: .any)["sidebar_calendar"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        XCTAssertTrue(row(app, "周末徒步（示例）").waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let grid = app.descendants(matching: .any)["calendarMonthGrid"].firstMatch
        let day = app.staticTexts["calendarSelectedDay"]
        XCTAssertTrue(app.staticTexts["calendarSelectedLunarDay"].label.hasPrefix("农历"))
        XCTAssertGreaterThan(day.frame.minX, grid.frame.midX)
        XCTAssertGreaterThanOrEqual(day.frame.minX, grid.frame.maxX, "The selected-day agenda must remain beside, not over, the month grid")
        XCTAssertLessThanOrEqual(day.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "The iPad window must finish rotating before visual capture")
        XCTAssertTrue(app.buttons["calendarNextMonth"].isHittable, "Month navigation in the aligned toolbar must stay visible")
        XCTAssertTrue(row(app, "周末徒步（示例）").isHittable, "The selected-day agenda must remain inside the visible window")
        // On rotated iPad simulators, app.screenshot() may crop using stale portrait bounds.
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "calendar-ipad-wide"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["calendarNextMonth"].tap()
        let title = app.staticTexts["calendarMonthTitle"].label
        app.descendants(matching: .any)["sidebar_settings"].firstMatch.tap()
        entry.tap(); XCTAssertEqual(app.staticTexts["calendarMonthTitle"].label, title)
    }

    private func openPhoneCalendar(_ app: XCUIApplication) {
        // Home is now the initial tab. Route explicitly instead of relying on
        // whichever content has finished appearing immediately after launch.
        let calendar = app.tabBars.buttons["日历"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10))
        XCTAssertTrue(calendar.isHittable)
        calendar.tap()
        XCTAssertTrue(calendar.isSelected)
        XCTAssertTrue(app.staticTexts["calendarMonthTitle"].waitForExistence(timeout: 10))
    }

    private func select(_ date: Date, in app: XCUIApplication) {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let button = app.buttons["calendarDay_" + formatter.string(from: date)]
        if !button.waitForExistence(timeout: 2) { app.buttons["calendarNextMonth"].tap() }
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(identifier: "calendarEventRow").matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
