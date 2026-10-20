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
}
