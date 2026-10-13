import XCTest

/// own.audio's "identify library", end to end: find it in the Library, identify one album from
/// its menu, accept
/// the sure matches, undo one song, accept and reject by swiping, look at another edition, undo
/// and delete the run. Needs an own.audio server that offers it and an account whose library
/// has songs to identify:
///
/// ```
/// TEST_RUNNER_IDENTIFY_HOST=https://… TEST_RUNNER_IDENTIFY_EMAIL=… TEST_RUNNER_IDENTIFY_PASSWORD=… \
/// xcodebuild test … -only-testing:OwnAudioMusicUITests/IdentifyTests
/// ```
///
/// Whatever the run accepts is undone before it is deleted, so the library ends as it began.
final class IdentifyTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["IDENTIFY_HOST"] != nil else { throw XCTSkip("IDENTIFY_HOST is not set") }
    }

    func testIdentifyAnAlbumFromStartToUndo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        signIn(app)

        // The Library offers identify.
        openTab(app, ["Library", "Knihovna"])
        let albums = app.buttons["library.albums"]
        let libraryShown = albums.waitForExistence(timeout: 20)
        if !libraryShown { screenshot(app, "identify-00-library-missing") }
        XCTAssertTrue(libraryShown)
        XCTAssertTrue(app.buttons["library.identify"].waitForExistence(timeout: 15), "The Library should offer identify")
        screenshot(app, "identify-01-library")

        // Identify one album from its menu: a run of seconds rather than a whole library.
        albums.tap()
        let named = env["IDENTIFY_ALBUM"].map { app.buttons.containing(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch }
        let album = named ?? app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
        let more = app.navigationBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let identifyAlbum = app.buttons["Identify Album"]
        XCTAssertTrue(identifyAlbum.waitForExistence(timeout: 5), "The album menu should offer identify")
        screenshot(app, "identify-02-album-menu")
        identifyAlbum.tap()
        let confirm = app.buttons["Start"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }

        // The new run opens in a sheet; wait for it to finish looking things up.
        let status = app.staticTexts["identify.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "The new run should open")
        XCTAssertTrue(waitUntil(timeout: 180) { status.label == "Ready" }, "The run should finish, is \(status.label)")
        screenshot(app, "identify-04-ready")

        // Accept every sure match.
        tapSegment(app, "Sure")
        let acceptSure = app.buttons["identify.acceptSure"]
        if acceptSure.waitForExistence(timeout: 8) {
            acceptSure.tap()
            sleep(3)
        }

        // Undo one accepted song on the Done tab.
        tapSegment(app, "Done")
        let doneRow = app.descendants(matching: .any)["identify.proposal"].firstMatch
        if doneRow.waitForExistence(timeout: 8) {
            doneRow.swipeLeft()
            let undo = app.buttons["Undo"]
            XCTAssertTrue(undo.waitForExistence(timeout: 5), "An accepted song can be undone")
            undo.tap()
            sleep(3)
            screenshot(app, "identify-05-undone")
        }

        // Accept one proposal to review by swiping right, reject the next by swiping left.
        tapSegment(app, "To Review")
        let proposals = app.descendants(matching: .any).matching(identifier: "identify.proposal")
        let first = proposals.element(boundBy: 0)
        if first.waitForExistence(timeout: 8) {
            first.swipeRight()
            let accept = app.buttons["Accept"]
            if accept.waitForExistence(timeout: 3) { accept.tap(); sleep(3) }
            let next = proposals.element(boundBy: 0)
            if next.waitForExistence(timeout: 5) {
                next.swipeLeft()
                let reject = app.buttons["Reject"]
                if reject.waitForExistence(timeout: 3) { reject.tap(); sleep(3) }
            }
            screenshot(app, "identify-06-decided")

            // Another edition of an album.
            let albumActions = app.buttons["Album Actions"].firstMatch
            if albumActions.waitForExistence(timeout: 5) {
                albumActions.tap()
                let otherEdition = app.buttons["Other Edition…"]
                XCTAssertTrue(otherEdition.waitForExistence(timeout: 5))
                otherEdition.tap()
                let done = app.buttons["Done"]
                XCTAssertTrue(done.waitForExistence(timeout: 10), "The editions sheet should open")
                sleep(2)
                screenshot(app, "identify-07-editions")
                done.tap()
            }
        }

        // Undo the whole run, then delete it.
        let runMore = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(runMore.waitForExistence(timeout: 5))
        runMore.tap()
        let undoRun = app.buttons["Undo Run"].firstMatch
        if undoRun.waitForExistence(timeout: 3) {
            undoRun.tap()
            let confirmUndo = app.buttons.matching(NSPredicate(format: "label == 'Undo Run'")).element(boundBy: 0)
            XCTAssertTrue(confirmUndo.waitForExistence(timeout: 5))
            confirmUndo.tap()
            sleep(3)
            runMore.tap()
        }
        app.buttons["Delete Run"].firstMatch.tap()
        let confirmDelete = app.buttons.matching(NSPredicate(format: "label == 'Delete Run'")).element(boundBy: 0)
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Deleting closes the run and goes back to the album")
        screenshot(app, "identify-08-deleted")
    }

    /// One song in your own words: the tags are wrong, so the search is typed over and a
    /// recording picked. Needs a server from 1.0.0-beta.14; leaves the song as it was.
    func testIdentifyOneSongInYourOwnWords() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        signIn(app)
        openTab(app, ["Library", "Knihovna"])
        let albums = app.buttons["library.albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        let named = env["IDENTIFY_ALBUM"].map { app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", $0)).firstMatch }
        let album = named ?? app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
        let song = app.cells.firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 15))
        // Playing it first: a 22 kHz mono FLAC streamed into the player used to take the app down.
        song.tap()
        sleep(4)
        XCTAssertEqual(app.state, .runningForeground, "Playing a song should not end the app")
        let more = app.buttons["song.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "A song row should have a More button")
        more.tap()
        let identify = app.buttons["Identify…"]
        let offered = identify.waitForExistence(timeout: 5)
        screenshot(app, "identify-09-song-menu")
        XCTAssertTrue(offered, "A song's menu should offer Identify…")
        identify.tap()

        let title = app.textFields["picker.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        title.typeText("Yesterday")
        let artist = app.textFields["picker.artist"]
        artist.tap()
        artist.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        artist.typeText("The Beatles")
        app.buttons["picker.search"].tap()
        let result = app.buttons["picker.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "MusicBrainz should find Yesterday")
        screenshot(app, "identify-10-own-words")
        result.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !title.exists }, "Choosing closes the picker")

        // Put it back.
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let undo = app.buttons["Undo Identify…"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Undo Identify'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        sleep(2)
        screenshot(app, "identify-11-put-back")
    }

    /// The More menus on an artist and an album start a run (or say why not).
    func testMoreMenusStartARun() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        signIn(app)
        openTab(app, ["Library", "Knihovna"])
        let albums = app.buttons["library.albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        let card = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        sleep(2)
        screenshot(app, "more-01-opened")
        let more = app.navigationBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "No More button")
        more.tap()
        sleep(1)
        screenshot(app, "more-02-menu")
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Identify'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No Identify item in the menu")
        item.tap()
        sleep(4)
        screenshot(app, "more-03-after")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return condition()
    }

    private func signIn(_ app: XCUIApplication) {
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(env["IDENTIFY_HOST"]!)
        app.textFields["addServer.username"].tap()
        app.textFields["addServer.username"].typeText(env["IDENTIFY_EMAIL"] ?? "")
        app.secureTextFields["addServer.password"].tap()
        app.secureTextFields["addServer.password"].typeText(env["IDENTIFY_PASSWORD"] ?? "")
        app.buttons["addServer.connect"].tap()
        dismissSavePasswordPrompt(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20), "Home should open after connecting")
    }

    /// The run's tabs are a segmented picker; its segments are buttons with the tab's name.
    private func tapSegment(_ app: XCUIApplication, _ label: String) {
        let segment = app.segmentedControls.buttons[label]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "No \(label) tab")
        segment.tap()
        sleep(2)
    }

    private func openTab(_ app: XCUIApplication, _ labels: [String]) {
        let tab = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        // Right after Home appears a tap can land before the tab bar takes it; try until the
        // tab says it is selected.
        for _ in 0..<5 {
            tab.tap()
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !tab.isSelected { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            if tab.isSelected { return }
        }
    }

    private func dismissSavePasswordPrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Not Now", "Teď ne"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for owner in [app, springboard] {
                let notNow = owner.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
                if notNow.exists {
                    notNow.tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = env["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
