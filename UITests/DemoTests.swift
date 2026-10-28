import XCTest

/// "Try the Demo Library" on the first screen signs in to the public own.audio demo and plays
/// from it. Needs the network, so only `scripts/test-servers.sh demo` runs it.
final class DemoTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DEMO"] == "1" else {
            throw XCTSkip("DEMO is not set")
        }
    }

    func testTryTheDemoLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchChecked()

        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 30), "Home should open on the demo")

        let library = app.buttons.matching(NSPredicate(format: "label IN %@", ["Library", "Knihovna"])).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        // The iPad's library is a sidebar of cells, shown beside the content in landscape.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let albums = app.descendants(matching: .any).matching(identifier: "library.albums").firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        let album = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20), "the demo should have albums")
        album.tap()

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        let deadline = Date().addingTimeInterval(20)
        while !play.isEnabled, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        let playing = Date().addingTimeInterval(30)
        while !(pause.exists && pause.label == "Pause"), Date() < playing {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(pause.label, "Pause", "playback should start")
    }

    /// After the demo sign-in: the accent colour, the account's listening and the way to delete
    /// it. The dialog is cancelled; the demo refuses deletion anyway.
    func testSettingsOnTheDemo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchChecked()
        app.buttons["addServer.demo"].tap()
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "Home should open on the demo")
        settings.tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let listening = app.buttons["serverDetail.listening"]
        XCTAssertTrue(listening.waitForExistence(timeout: 10))
        listening.tap()
        XCTAssertTrue(app.staticTexts["Listened"].waitForExistence(timeout: 20), "the listening statistics should load")
        app.segmentedControls.buttons["Year"].tap()
        XCTAssertTrue(app.staticTexts["Listened"].waitForExistence(timeout: 20))
        app.navigationBars.buttons.firstMatch.tap()

        let delete = app.buttons["serverDetail.deleteAccount"]
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "an own.audio account can be deleted from the app")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete Your Account?"].waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        // On the iPad the dialog is a popover, closed by tapping beside it.
        if cancel.exists { cancel.tap() } else { app.otherElements["PopoverDismissRegion"].firstMatch.tap() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "cancelling keeps the server")
        app.navigationBars.buttons.firstMatch.tap()

        let green = app.buttons["settings.accent.green"]
        for _ in 0..<8 where !green.isHittable { app.swipeUp() }
        XCTAssertTrue(green.waitForExistence(timeout: 5), "Settings should offer accent colours")
        green.tap()
        XCTAssertTrue(green.isSelected, "the chosen colour should be marked")
        app.buttons["settings.accent.app"].tap()
    }

    /// The iPad's album page: one menu with Favorite and Download in it, not three buttons
    /// folded into the top bar's overflow with the album menu a level below. A download running
    /// while songs change used to crash there.
    func testAlbumMenuOnTheIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchChecked()
        app.buttons["addServer.demo"].tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 30))
        let library = app.buttons.matching(NSPredicate(format: "label IN %@", ["Library", "Knihovna"])).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        // The iPad's library is a sidebar of cells, shown beside the content in landscape.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let albums = app.descendants(matching: .any).matching(identifier: "library.albums").firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        let album = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))

        let more = app.buttons["album.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "the iPad album page has one menu")
        XCTAssertFalse(app.buttons["download.done"].exists || app.buttons["download.progress"].exists)
        more.tap()
        let favorite = app.buttons.matching(NSPredicate(format: "label IN %@", ["Favorite Album", "Unfavorite Album"])).firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5), "Favorite is in the menu")
        XCTAssertTrue(app.buttons["Play Next"].exists, "the album's own entries are in the same menu")
        app.buttons["Download"].tap()

        let deadline = Date().addingTimeInterval(20)
        while !play.isEnabled, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        play.tap()
        let next = app.buttons["miniPlayer.next"]
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            if next.exists, next.isEnabled { next.tap() }
        }
        more.tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 5), "still running, menu still opens")
    }
}
