import XCTest

/// The duress password end to end: set up in a fresh vault, then unlocking with it wipes
/// that vault and opens the decoy. Uses fresh passwords and the "this vault" scope, so the
/// other tests' vaults are never touched.
final class DuressFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func unlock(_ app: XCUIApplication, _ password: String) {
        let field = app.secureTextFields["Password"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1) { tip.tap() }
        field.typeText(password)
        // Typing into a just-focused field is occasionally dropped: type again.
        let unlockButton = app.buttons["Unlock"]
        if !unlockButton.waitForEnabled(timeout: 2) {
            field.tap()
            field.typeText(password)
        }
        XCTAssertTrue(unlockButton.waitForEnabled(timeout: 5))
        unlockButton.tap()
        // The keyboard slides away over the bottom controls; taps there land on it.
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 30)
        // The camera sits under the unlock screen, so wait for that screen to go.
        XCTAssertTrue(field.waitForNonExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func itemCount(_ app: XCUIApplication, _ step: String) -> Int {
        app.buttons["Open vault"].tap()
        // A tap while the unlock screen is still fading out is lost: tap again.
        if !app.navigationBars["Vault"].waitForExistence(timeout: 3) {
            app.buttons["Open vault"].tap()
        }
        if !app.navigationBars["Vault"].waitForExistence(timeout: 10) {
            attachScreenshot("failed-\(step)")
            XCTFail("No vault screen at \(step)")
        }
        // Thumbnails load a moment after the screen.
        _ = app.buttons.matching(identifier: "Photo").firstMatch.waitForExistence(timeout: 5)
        let count = app.buttons.matching(identifier: "Photo").count + app.buttons.matching(identifier: "Video").count
        return count
    }

    @MainActor
    private func lockFromGallery(_ app: XCUIApplication) {
        app.navigationBars["Vault"].buttons["Lock"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testDuressPasswordWipesTheVaultAndOpensTheDecoy() {
        let run = UUID().uuidString.prefix(8)
        let owner = "owner-\(run)"
        let duress = "duress-\(run)"
        let app = XCUIApplication()
        app.launch()

        // A real vault with one photo.
        unlock(app, owner)
        let shutter = app.buttons["Take photo"]
        XCTAssertTrue(shutter.waitForEnabled(timeout: 15))
        shutter.tap()
        sleep(2)
        XCTAssertTrue(app.buttons["Open vault"].waitForEnabled(timeout: 15))
        XCTAssertEqual(itemCount(app, "owner"), 1)

        // Set up the duress password.
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let setUp = app.buttons["Set Up Duress Password…"]
        app.swipeUp()
        XCTAssertTrue(setUp.waitForExistence(timeout: 5))
        setUp.tap()

        let first = app.secureTextFields["Duress password"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let set = app.navigationBars.buttons["Set"]
        XCTAssertFalse(set.isEnabled, "Set waits for the acknowledgement")
        first.tap()
        first.typeText(duress)
        let second = app.secureTextFields["Repeat the duress password"]
        second.tap()
        second.typeText(duress)
        app.switches["I understand wiped photos and videos can't be recovered"].switches.firstMatch.tap()
        XCTAssertTrue(set.waitForEnabled(timeout: 5))
        set.tap()

        let later = app.alerts["Duress password set"].buttons["Later"]
        XCTAssertTrue(later.waitForExistence(timeout: 30))
        later.tap()
        XCTAssertTrue(app.buttons["Remove Duress Password"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'A duress password is set'")).firstMatch.exists)
        attachScreenshot("settings-duress-set")

        // Add a decoy photo: re-enter the duress password, then pick from the library.
        app.buttons["Add Decoy Photos…"].tap()
        let alert = app.alerts["Enter the duress password"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.secureTextFields.firstMatch.typeText(duress)
        alert.buttons["OK"].tap()
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 20))
        // The picker's first-run banner can sit over the top row.
        let banner = app.buttons["Close"]
        if banner.exists { banner.tap(); sleep(1) }
        for index in 0..<2 {
            photos.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        attachScreenshot("picker")
        app.buttons["Done"].tap()
        let added = app.alerts["AES Camera"]
        XCTAssertTrue(added.waitForExistence(timeout: 30))
        XCTAssertTrue(added.staticTexts["Added 2 photos to the decoy vault. 0 skipped."].exists)
        added.buttons["OK"].tap()

        // Back to the gallery and lock.
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        lockFromGallery(app)

        // The duress password opens the decoy vault, with no duress shown in it.
        unlock(app, duress)
        XCTAssertEqual(itemCount(app, "decoy"), 2)
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["Set Up Duress Password…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Duress Password"].exists)
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        lockFromGallery(app)

        // The real password now opens nothing: its vault was wiped.
        unlock(app, owner)
        XCTAssertEqual(itemCount(app, "wiped"), 0)
    }

    @MainActor
    private func attachTree(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
