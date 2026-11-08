import XCTest

/// Drives the real app in the Simulator (which uses the simulated camera feed).
final class CaptureFlowTests: XCTestCase {
    /// Override with `TEST_RUNNER_UITEST_PASSWORD=…` on the xcodebuild command line, e.g. to
    /// open a vault of files recorded on Android.
    static let password = ProcessInfo.processInfo.environment["UITEST_PASSWORD"] ?? "uitest-password"

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
        snapshot("camera")
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

    /// Run after handing the app a vault file with `simctl openurl` (see the README);
    /// skipped when no import is waiting.
    @MainActor
    func testPendingImportOpensAndAddsToVault() throws {
        let app = XCUIApplication()
        app.activate()
        let open = app.buttons["Open"]
        guard open.waitForExistence(timeout: 3) else {
            throw XCTSkip("No import pending")
        }
        open.tap()
        unlock(app)
        let add = app.buttons["Add to Vault"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        snapshot("import-viewer")
        add.tap()
        // Files from this vault are already there (identical bytes): no duplicate.
        XCTAssertTrue(app.staticTexts["Added"].waitForExistence(timeout: 15))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Open vault"].waitForExistence(timeout: 10))
    }

    /// Opens the oldest photo in the vault and checks it decrypts. With
    /// `TEST_RUNNER_UITEST_PASSWORD` this checks files imported from Android.
    @MainActor
    func testOldestPhotoOpens() throws {
        let app = XCUIApplication()
        app.launch()
        unlock(app)
        let vaultButton = app.buttons["Open vault"]
        XCTAssertTrue(vaultButton.waitForEnabled(timeout: 15))
        vaultButton.tap()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 10))
        sleep(2)
        snapshot("gallery")
        let photos = app.buttons.matching(identifier: "Photo")
        guard photos.count > 0 else { throw XCTSkip("No photos") }
        photos.element(boundBy: photos.count - 1).tap()
        sleep(4)
        XCTAssertFalse(app.staticTexts["This photo can't be opened."].exists)
        snapshot("photo")
    }

    @MainActor
    func attachTree(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func openSettings(_ app: XCUIApplication) {
        let vaultButton = app.buttons["Open vault"]
        XCTAssertTrue(vaultButton.waitForEnabled(timeout: 15))
        vaultButton.tap()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 10))
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    /// In the system file picker, goes to On My iPhone › AES Camera (where the Files app
    /// shows this app's Documents folder). The picker reopens where it was last, so this
    /// climbs out of an export folder or walks in from On My iPhone as needed.
    @MainActor
    func pickerGoToAppFolder(_ app: XCUIApplication) {
        let pickerBar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let browse = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 30))
        browse.tap()
        let here = app.buttons["AES Camera, Actions Menu"]
        let title = pickerBar.buttons.matching(NSPredicate(format: "label ENDSWITH ', Actions Menu'")).firstMatch
        for step in 0..<3 {
            // The picker's contents reach the accessibility tree a moment after its bar.
            _ = title.waitForExistence(timeout: 30)
            if here.exists { break }
            attachTree(app, "picker-\(step)")
            if title.exists && title.label.hasPrefix("AESCamera-") {
                pickerBar.buttons["BackButton"].tap()
            } else if app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'AES Camera'")).firstMatch.exists {
                app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'AES Camera'")).firstMatch.tap()
            } else {
                app.staticTexts["On My iPhone"].firstMatch.tap()
            }
            sleep(2)
        }
        XCTAssertTrue(here.waitForExistence(timeout: 5), "not in the app folder")
    }

    @MainActor
    func alertMessage(_ app: XCUIApplication, timeout: TimeInterval) -> String {
        let alert = app.alerts["AES Camera"]
        XCTAssertTrue(alert.waitForExistence(timeout: timeout))
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        let attachment = XCTAttachment(string: message)
        attachment.name = "message"
        attachment.lifetime = .keepAlways
        add(attachment)
        return message
    }

    /// Opens Settings › Restore Files… and goes to the newest `AESCamera-…` export folder
    /// in the app's Documents. Returns its files, or nil when there is no such folder.
    @MainActor
    func openRestorePicker(_ app: XCUIApplication) -> XCUIElementQuery? {
        app.buttons["Restore Files…"].tap()
        let pickerBar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let title = pickerBar.buttons.matching(NSPredicate(format: "label ENDSWITH ', Actions Menu'")).firstMatch
        let browse = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 30))
        browse.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        if !title.label.hasPrefix("AESCamera-") {
            pickerGoToAppFolder(app)
            let folders = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'AESCamera-'"))
            guard folders.count > 0 else { return nil }
            folders.element(boundBy: folders.count - 1).tap()
        }
        let files = app.cells.matching(NSPredicate(format: "identifier CONTAINS '.enc'"))
        XCTAssertTrue(files.firstMatch.waitForExistence(timeout: 30))
        return files
    }

    /// Restores every file of the newest `AESCamera-…` export folder in the app's
    /// Documents (put there by hand, e.g. an Android export), one file per pick: the
    /// iOS 26 Simulator's picker offers no multiple selection. Skipped when there is none.
    @MainActor
    func testRestoreExportFolder() throws {
        let app = XCUIApplication()
        app.launch()
        unlock(app)
        openSettings(app)
        guard let first = openRestorePicker(app) else {
            app.buttons["Cancel"].tap()
            throw XCTSkip("No export folder in Documents")
        }
        let names = first.allElementsBoundByIndex.map(\.identifier)
        for (index, name) in names.enumerated() {
            let files = index == 0 ? first : openRestorePicker(app)!
            files.matching(identifier: name).firstMatch.tap()
            let message = alertMessage(app, timeout: 60)
            XCTAssertTrue(message.contains("Restored 1"), "\(name): \(message)")
            app.alerts.buttons["OK"].tap()
        }
        app.navigationBars["Settings"].buttons["BackButton"].tap()
        sleep(3)
        snapshot("gallery")
    }

    /// Exports the vault to the folder the picker opens at: in the Simulator that's its
    /// last location, somewhere under On My iPhone › AES Camera (the app's Documents).
    @MainActor
    func testExportToDocuments() {
        let app = XCUIApplication()
        app.launch()
        unlock(app)
        openSettings(app)
        app.buttons["Export Vault…"].tap()
        let browse = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 30))
        browse.tap()
        let open = app.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        open.tap()
        let message = alertMessage(app, timeout: 60)
        XCTAssertTrue(message.contains("Exported"), message)
        XCTAssertFalse(message.contains("failed"), message)
    }

    /// Plays the oldest video, which a test run seeds with an Android-style MPEG-TS file
    /// (`aescore-tool make-ts`, copied into the vault). Skipped when there is none.
    @MainActor
    func testAndroidVideoPlaysAndSeeks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-no-autoplay"]
        app.launch()
        unlock(app)
        let vaultButton = app.buttons["Open vault"]
        XCTAssertTrue(vaultButton.waitForEnabled(timeout: 15))
        vaultButton.tap()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 10))
        sleep(1)
        let videos = app.buttons.matching(identifier: "Video")
        guard videos.count > 0 else { throw XCTSkip("No videos") }
        videos.element(boundBy: videos.count - 1).tap()

        // Starts paused (no autoplay in UI tests) with the first frame showing.
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 20))
        snapshot("ts-start")

        app.sliders["Position"].adjust(toNormalizedSliderPosition: 0.6)
        sleep(2)
        func seconds(_ label: String) -> Int {
            label.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        }
        let elapsed = app.staticTexts["Elapsed"].label
        let duration = app.staticTexts["Duration"].label
        XCTAssertGreaterThan(seconds(duration), 2, "duration: \(duration)")
        XCTAssertGreaterThanOrEqual(
            seconds(elapsed), seconds(duration) / 2, "position after seeking: \(elapsed) of \(duration)"
        )
        snapshot("ts-seeked")

        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        snapshot("ts-playing")
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
