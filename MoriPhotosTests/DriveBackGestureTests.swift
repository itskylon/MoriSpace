import XCTest
@testable import MoriPhotos

final class DriveBackGestureTests: XCTestCase {
    func testVerticalAndOutwardPansNeverBeginBackNavigation() {
        XCTAssertFalse(DriveBackGestureDecision.shouldBegin(horizontal: 20, vertical: 100))
        XCTAssertFalse(DriveBackGestureDecision.shouldBegin(horizontal: -100, vertical: 0))
        XCTAssertFalse(DriveBackGestureDecision.shouldBegin(horizontal: 0, vertical: 0))
        XCTAssertTrue(DriveBackGestureDecision.shouldBegin(horizontal: 100, vertical: -30))
    }
    func testShortDragsAndFastJitterCancelWhileAnIntentionalFlickCompletes() {
        XCTAssertFalse(DriveBackGestureDecision.shouldFinish(distance: 28, velocity: 0, width: 400))
        XCTAssertFalse(DriveBackGestureDecision.shouldFinish(distance: 10, velocity: 1200, width: 400))
        XCTAssertTrue(DriveBackGestureDecision.shouldFinish(distance: 30, velocity: 800, width: 400))
        XCTAssertTrue(DriveBackGestureDecision.shouldFinish(distance: 110, velocity: 0, width: 400))
    }
    func testWideAndNarrowWindowsKeepAnAchievableDistanceThreshold() {
        XCTAssertFalse(DriveBackGestureDecision.shouldFinish(distance: 59, velocity: 0, width: 200))
        XCTAssertTrue(DriveBackGestureDecision.shouldFinish(distance: 60, velocity: 0, width: 200))
        XCTAssertTrue(DriveBackGestureDecision.shouldFinish(distance: 121, velocity: 0, width: 1200))
    }
}
