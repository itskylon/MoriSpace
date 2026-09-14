import XCTest

final class CalendarUITests: XCTestCase {
    func testPublishedHolidaysAndUncollectedYear() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-fixture"]
        app.launch()
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
        app.launch(); app.tabBars.buttons["日历"].tap()
        let lunar = app.staticTexts["calendarSelectedLunarDay"]
        XCTAssertTrue(lunar.waitForExistence(timeout: 10))
        XCTAssertTrue(lunar.label.hasPrefix("农历"))
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
        app.tabBars.buttons["设置"].tap(); app.tabBars.buttons["日历"].tap()
        XCTAssertTrue(lunar.waitForExistence(timeout: 5))
    }

    func testPhoneCalendarFilteringAndStateSurviveTabSwitching() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-live-fixture", "--reset-calendar-live-fixture"]
        app.launch(); app.tabBars.buttons["日历"].tap()
        XCTAssertTrue(app.buttons["calendarNewEvent"].waitForExistence(timeout: 10))
        XCTAssertTrue(row(app, "日历验收·生日").waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["calendarDayCount"].label, "3 项")
        capture(app, "calendar-phone-month")
        app.buttons["calendarSources"].tap()
        let toggle = app.switches["calendarToggle_森空间日历验收（仅模拟器）"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        app.buttons["calendarSourcesDone"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏全部日历"].waitForExistence(timeout: 5))
        app.buttons["显示全部日历"].tap()
        XCTAssertTrue(row(app, "日历验收·生日").waitForExistence(timeout: 5))
        app.buttons["calendarNextMonth"].tap()
        let month = app.staticTexts["calendarMonthTitle"].label
        app.tabBars.buttons["设置"].tap(); app.tabBars.buttons["日历"].tap()
        XCTAssertEqual(app.staticTexts["calendarMonthTitle"].label, month)
        app.buttons["calendarToday"].tap()
        app.segmentedControls["calendarDisplayMode"].buttons["日程"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calendarAgendaList"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "calendar-phone-agenda")
    }

    func testPhoneCreatesUsingSystemEditorAndReadsEventAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--empty-connection-fixture", "--calendar-live-fixture", "--reset-calendar-live-fixture"]
        app.launch(); app.tabBars.buttons["日历"].tap()
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
        app.launch(); app.tabBars.buttons["日历"].tap()
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
        XCTAssertLessThanOrEqual(day.frame.maxX, app.frame.maxX)
        capture(app, "calendar-ipad-wide")
        app.buttons["calendarNextMonth"].tap()
        let title = app.staticTexts["calendarMonthTitle"].label
        app.descendants(matching: .any)["sidebar_settings"].firstMatch.tap()
        entry.tap(); XCTAssertEqual(app.staticTexts["calendarMonthTitle"].label, title)
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
