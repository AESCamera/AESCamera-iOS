import XCTest

/// Drives the real app in the Simulator (which uses the simulated camera feed).
final class CaptureFlowTests: XCTestCase {
    static let password = "uitest-password"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func unlock(_ app: XCUIApplication, password: String = CaptureFlowTests.password) {
        let field = app.secureTextFields["Password"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1) { tip.tap() }
        field.typeText(password)
        app.buttons["Unlock"].tap()
    }

    @MainActor
    func testPhotoAndVideoCapture() {
        let app = XCUIApplication()
        app.launch()
        unlock(app)

        let shutter = app.buttons["Take photo"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        shutter.tap()
        // Normal mode disables the controls until the save completes.
        let toVideo = app.buttons["Switch to video"]
        XCTAssertTrue(toVideo.waitForEnabled(timeout: 10))
        toVideo.tap()

        let record = app.buttons["Start recording"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        record.tap()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        sleep(4)
        stop.tap()
        XCTAssertTrue(app.buttons["Start recording"].waitForEnabled(timeout: 15))

        app.buttons["Open vault"].tap()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 10))
        sleep(2)
        snapshot("gallery")

        // The newest item is the video just recorded.
        let video = app.buttons.matching(identifier: "Video").firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        video.tap()
        XCTAssertTrue(app.staticTexts["Checking video…"].waitForNonExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["This video can't be opened."].exists)
        sleep(2)
        snapshot("video")

        app.swipeLeft()
        sleep(2)
        snapshot("photo")
    }

    @MainActor
    func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testMoveVaultAndBack() {
        let app = XCUIApplication()
        app.launch()
        unlock(app)
        let shutter = app.buttons["Take photo"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        shutter.tap()
        XCTAssertTrue(app.buttons["Open vault"].waitForEnabled(timeout: 10))
        app.buttons["Open vault"].tap()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 10))
        sleep(2)

        let count = app.buttons.matching(identifier: "Photo").count + app.buttons.matching(identifier: "Video").count
        XCTAssertGreaterThan(count, 0)

        for target in ["Files app", "Private"] {
            app.buttons["More"].tap()
            app.buttons["Settings"].tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Vault location")).firstMatch.tap()
            app.buttons[target].tap()
            app.buttons["Move"].tap()
            XCTAssertTrue(app.staticTexts["Moving vault…"].waitForNonExistence(timeout: 30))
            snapshot("settings-\(target)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(2)
            let after = app.buttons.matching(identifier: "Photo").count + app.buttons.matching(identifier: "Video").count
            XCTAssertEqual(after, count, "items after moving to \(target)")
        }
    }

    @MainActor
    func testLocksWhenBackgrounded() {
        let app = XCUIApplication()
        app.launch()
        unlock(app)
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 15))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
    }
}

extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
