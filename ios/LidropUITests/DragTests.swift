import XCTest

final class DragTests: XCTestCase {
    func testDragOffRightEdge() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-connect", "127.0.0.1", "-skipGate", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Connected to'")).firstMatch.waitForExistence(timeout: 15))
        sleep(2)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.3))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(4)
    }
}
