import XCTest

extension XCUIApplication {
    var phoneMenus: XCUIElementQuery {
        descendants(matching: .any).matching(identifier: "floatingPhoneMenu")
    }
}
