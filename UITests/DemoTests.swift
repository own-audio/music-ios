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
        let albums = app.buttons["library.albums"]
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

        let green = app.buttons["settings.accent.green"]
        for _ in 0..<8 where !green.isHittable { app.swipeUp() }
        XCTAssertTrue(green.waitForExistence(timeout: 5), "Settings should offer accent colours")
        green.tap()
        XCTAssertTrue(green.isSelected, "the chosen colour should be marked")
        app.buttons["settings.accent.app"].tap()

        for _ in 0..<8 where !app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch.isHittable { app.swipeDown() }
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch.tap()

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
        if cancel.exists { cancel.tap() } else { app.tap() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "cancelling keeps the server")
    }
}
