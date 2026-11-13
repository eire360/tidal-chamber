import XCTest

final class ClockUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure=false }
    private func clock(_ app:XCUIApplication)->XCUIElement { app.descendants(matching:.any).matching(identifier:"clock.time").firstMatch }
    private func settle(_ seconds:TimeInterval=2) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
    private func attach(_ name:String,_ shot:XCUIScreenshot) { let a=XCTAttachment(screenshot:shot);a.name=name;a.lifetime = .keepAlways;add(a) }

    func testSceneAnimatesAndTimeIsReadable() {
        let app=XCUIApplication();app.launchArguments=["-fixture","10:08"];app.launch()
        XCTAssertTrue(clock(app).waitForExistence(timeout:20))
        XCTAssertEqual(clock(app).label,"Local time")
        XCTAssertTrue(String(describing:clock(app).value ?? "").contains("10:08"))
        settle(3);let a=app.screenshot();settle(2);let b=app.screenshot()
        XCTAssertNotEqual(a.pngRepresentation,b.pngRepresentation,"The water scene should actually move")
        attach("day-scene",b)
    }
    func testReduceMotionFreezesScene() {
        let app=XCUIApplication();app.launchArguments=["-fixture","10:08","-reduceMotion"];app.launch()
        XCTAssertTrue(clock(app).waitForExistence(timeout:20));settle(3)
        let a=app.screenshot();settle(2);let b=app.screenshot()
        XCTAssertEqual(a.pngRepresentation,b.pngRepresentation,"Fixed-time Reduce Motion must leave the whole scene stationary")
        attach("reduce-motion",b)
    }
    func testLiveClockReturnsFromBackground() {
        let app=XCUIApplication();app.launch()
        XCTAssertTrue(clock(app).waitForExistence(timeout:20));settle()
        XCUIDevice.shared.press(.home);settle(3);app.activate();settle()
        XCTAssertTrue(clock(app).exists)
        let value=String(describing:clock(app).value ?? "")
        let expected=Date().formatted(.dateTime.hour().minute())
        XCTAssertEqual(value,expected,"On return the time must equal current local time")
        attach("live-after-foreground",app.screenshot())
    }
    func testNightScene() {
        let app=XCUIApplication();app.launchArguments=["-fixture","22:14"];app.launch()
        XCTAssertTrue(clock(app).waitForExistence(timeout:20));settle(3)
        XCTAssertTrue(String(describing:clock(app).value ?? "").contains("10:14") || String(describing:clock(app).value ?? "").contains("22:14"))
        attach("night-scene",app.screenshot())
    }
}
