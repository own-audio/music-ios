import XCTest

/// Things a listener isn't meant to do, done anyway: wrong sign-ins, buttons hammered, screens
/// left before they load, odd searches, the server removed or the network gone mid-song, the app
/// killed mid-download. Nothing here checks a feature; each checks the app is still usable after.
///
/// Runs against the same server as `PlaybackSmokeTests` (`SERVER_HOST`, `SERVER_USER`,
/// `SERVER_PASSWORD`, optionally `SERVER_DOWNLOAD_ALBUM`), so once per kind of server.
final class MisuseTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    private static let libraryTab = ["Library", "Knihovna"]
    private static let searchTab = ["Search", "Hledat"]
    private static let homeTab = ["Home", "Domů"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else {
            throw XCTSkip("SERVER_HOST is not set")
        }
    }

    /// Sign-ins that can't work say why and leave the form usable; the right one still works
    /// afterwards, even typed with spaces around the address and a slash after it.
    func testWrongSignIns() throws {
        var app = launch(reset: true)
        let host = env["SERVER_HOST"]!
        let attempts: [(address: String, user: String, password: String)] = [
            ("not a server %% 😀", "someone", "x"),
            ("127.0.0.1:1", "someone", "x"),
            (host, env["SERVER_USER"] ?? "", "certainly-not-the-password"),
            (host, String(repeating: "ž", count: 400), String(repeating: "'\"; --", count: 50)),
        ]
        for (index, attempt) in attempts.enumerated() {
            // Each attempt on a fresh form: editing what the last one left behind is a test of
            // the text field, not of signing in.
            if index > 0 {
                app.terminate()
                app = launch(reset: true)
            }
            fill(app, address: attempt.address, user: attempt.user, password: attempt.password)
            let connect = app.buttons["addServer.connect"]
            connect.tap()
            connect.tap()
            dismissSavePasswordPrompt(app, within: 2)
            let error = app.descendants(matching: .any)["addServer.error"].firstMatch
            XCTAssertTrue(error.waitForExistence(timeout: 45), "attempt \(index) should say what went wrong")
            XCTAssertFalse(app.buttons["home.settings"].exists, "attempt \(index) should not get in")
            screenshot(app, "misuse-signin-\(index)")
        }

        app.terminate()
        app = launch(reset: true)
        fill(app, address: "  \(host)/  ", user: env["SERVER_USER"] ?? "", password: env["SERVER_PASSWORD"] ?? "")
        app.buttons["addServer.connect"].tap()
        dismissSavePasswordPrompt(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 30), "the right sign-in should still work")
    }

    /// Next, previous, play/pause and the position bar hammered faster than anything can load:
    /// afterwards the player still plays, and the position moves.
    func testHammeredPlayer() throws {
        let app = launch(reset: true)
        addServer(app)
        startAlbum(app)
        app.buttons["miniPlayer"].tap()
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))

        let next = app.buttons["player.next"], previous = app.buttons["player.previous"]
        let playPause = app.buttons["player.playPause"]
        for _ in 0..<8 { next.tap() }
        for _ in 0..<8 { previous.tap() }
        for _ in 0..<9 { playPause.tap() }
        for offset in [0.9, 0.1, 0.5, 0.95, 0.0] {
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)))
        }
        for _ in 0..<5 { app.descendants(matching: .any)["player.cover"].firstMatch.swipeLeft() }
        screenshot(app, "misuse-hammered")

        XCTAssertTrue(ensurePlaying(app), "after all that, the player should play again")
        let before = scrubber.value as? String ?? ""
        sleep(4)
        XCTAssertNotEqual(scrubber.value as? String ?? "", before, "and the position should move")
        // At the end of the queue next is greyed out and does nothing.
        for _ in 0..<40 where next.isEnabled { next.tap(); usleep(300_000) }
        XCTAssertFalse(next.isEnabled, "next should grey out on the last song")
        XCTAssertTrue(previous.isEnabled, "previous goes back from the last song")
    }

    /// The ✕ pressed while the next song is still loading: nothing starts playing afterwards
    /// when the load lands.
    func testStopWhileLoading() throws {
        let app = launch(reset: true)
        addServer(app)
        startAlbum(app)
        app.buttons["miniPlayer"].tap()
        let stop = app.buttons["player.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        app.buttons["player.next"].tap()
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !app.buttons["miniPlayer"].exists && !stop.exists }, "stopping should close the player")
        sleep(6)
        XCTAssertFalse(app.buttons["miniPlayer"].exists, "a load that lands after the stop should not start playing")

        // And playing again works as usual.
        startAlbum(app, openFirst: false)
    }

    /// Screens left before they load, tabs switched as fast as they can be tapped, and searches
    /// no music is called: the app keeps answering and an album still opens.
    func testRestlessNavigationAndOddSearches() throws {
        let app = launch(reset: true)
        addServer(app)
        openTab(app, Self.libraryTab)
        let albums = app.buttons["library.albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        let album = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        for _ in 0..<5 {
            album.tap()
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 2) { back.tap() }
        }
        for round in 0..<12 {
            tabButton(app, [Self.homeTab, Self.libraryTab, Self.searchTab][round % 3]).tap()
        }

        openTab(app, Self.searchTab)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let odd = ["%", "' OR 1=1 --", "😀🎵🎸", "<script>alert(1)</script>", "\\", "   ",
                   "a", String(repeating: "Bohemian ", count: 40), "../../etc/passwd", "*?[]{}"]
        for (index, text) in odd.enumerated() {
            // The field's own ✕ empties it wherever the cursor is.
            let clear = search.buttons.firstMatch
            if clear.exists, clear.isHittable { clear.tap() }
            search.tap()
            XCTAssertTrue(waitUntil(timeout: 3) {
                let value = search.value as? String ?? ""
                return value.isEmpty || value == search.placeholderValue
            }, "the search field should be empty before typing, is “\(search.value as? String ?? "")”")
            search.typeText(text)
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "searching for “\(text)” should not end the app")
            if index == 3 { screenshot(app, "misuse-search") }
        }
        // While searching, the keyboard covers the tab bar; iOS 26 leaves search by its Close
        // button beside the field (Cancel before it).
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel", "Zavřít", "Zrušit"])).firstMatch
        if close.exists { close.tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { !app.keyboards.firstMatch.exists }, "closing search should put the keyboard away")

        openTab(app, Self.libraryTab)
        startAlbum(app)
    }

    /// Mid-song: the app sent to the background and back, the network gone, the app killed and
    /// started again, and finally the server removed — which stops what it was playing.
    func testInterruptionsWhilePlaying() throws {
        var app = launch(reset: true)
        addServer(app)
        startAlbum(app)

        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(waitUntil(timeout: 10) { miniPlayPause.exists && miniPlayPause.label == "Pause" }, "back from the background, still playing")

        app.terminate()
        app = launch(reset: false, offline: true)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20), "a start with no network should reach Home")
        openTab(app, Self.libraryTab)
        XCTAssertEqual(app.state, .runningForeground)
        screenshot(app, "misuse-offline-start")

        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20))
        startAlbum(app)

        openServerSettings(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !app.buttons["miniPlayer"].exists }, "removing the server should stop its music")
        XCTAssertTrue(waitUntil(timeout: 15) { app.textFields["addServer.address"].exists || !row.exists }, "and leave no server behind")
        XCTAssertEqual(app.state, .runningForeground)
        screenshot(app, "misuse-server-removed")
    }

    /// The app killed in the middle of downloading an album: started again, the album can be
    /// downloaded to the end, and plays.
    func testKilledMidDownload() throws {
        guard let name = env["SERVER_DOWNLOAD_ALBUM"].flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw XCTSkip("SERVER_DOWNLOAD_ALBUM is not set")
        }
        var app = launch(reset: true)
        addServer(app)
        openAlbum(app, named: name)
        let start = app.buttons["download.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { start.isEnabled })
        start.tap()
        // At once: a small album on a fast server is down in about a second.
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20))
        openAlbum(app, named: name)
        let done = app.buttons["download.done"]
        let again = app.buttons["download.start"]
        XCTAssertTrue(waitUntil(timeout: 20) { done.exists || again.exists || app.buttons["download.progress"].exists },
                      "the album should say where its download stands")
        if again.exists, again.isEnabled { again.tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 300), "the download should finish after the restart")
        let play = app.buttons["detail.play"]
        XCTAssertTrue(waitUntil(timeout: 20) { play.isEnabled }, "Play should enable once the songs load")
        play.tap()
        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(waitUntil(timeout: 20) { miniPlayPause.exists && miniPlayPause.label == "Pause" }, "the downloaded album should play")
    }

    // MARK: - Helpers

    private func launch(reset: Bool, offline: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-uiTestReset"] : []) + (offline ? ["-simulateOffline"] : []) + Self.english
        app.launchChecked()
        return app
    }

    private func fill(_ app: XCUIApplication, address: String, user: String, password: String) {
        for (id, text) in [("addServer.address", address), ("addServer.username", user)] {
            let field = app.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            replace(field, with: text)
        }
        replace(app.secureTextFields["addServer.password"], with: password)
    }

    /// Into an empty field: every form here is a fresh one.
    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        field.typeText(text)
    }

    private func addServer(_ app: XCUIApplication) {
        fill(app, address: env["SERVER_HOST"]!, user: env["SERVER_USER"] ?? "", password: env["SERVER_PASSWORD"] ?? "")
        app.buttons["addServer.connect"].tap()
        dismissSavePasswordPrompt(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20), "Home should open after connecting")
    }

    private func openAlbum(_ app: XCUIApplication, named name: String?) {
        openTab(app, Self.libraryTab)
        let albums = app.buttons["library.albums"]
        // The tab keeps where it was left; back to its first screen.
        for _ in 0..<4 where !albums.waitForExistence(timeout: 3) {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
        }
        if !albums.waitForExistence(timeout: 20) {
            screenshot(app, "misuse-library-not-reached")
            XCTFail("the Library tab should show Albums; on screen: \(app.debugDescription.prefix(3000))")
        }
        albums.tap()
        let album = name.map { app.buttons.containing(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch }
            ?? app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
    }

    /// Opens the server's album (unless already on one) and plays it until there is sound.
    private func startAlbum(_ app: XCUIApplication, openFirst: Bool = true) {
        if openFirst || !app.buttons["detail.play"].exists { openAlbum(app, named: env["SERVER_ALBUM"]) }
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { play.isEnabled }, "Play should enable once the songs load")
        play.tap()
        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(waitUntil(timeout: 30) { miniPlayPause.exists && miniPlayPause.label == "Pause" }, "playback should start")
    }

    /// Waits for loading to settle and presses play if it ended up paused.
    private func ensurePlaying(_ app: XCUIApplication) -> Bool {
        let playPause = app.buttons["player.playPause"]
        // Not `isHittable`: asked mid-animation, XCTest fails the test instead of answering no.
        return waitUntil(timeout: 40) {
            guard playPause.exists, playPause.isEnabled else { return false }
            if playPause.label == "Pause" { return true }
            if playPause.label == "Play" { playPause.tap(); sleep(2) }
            return playPause.label == "Pause"
        }
    }

    /// The tab bar's button for one of `labels`. Other buttons can carry the same label and
    /// sit first in the list off screen, where a tap goes nowhere: the one that can be hit.
    private func tabButton(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label IN %@", labels))
        // With Search open, iOS 26 folds the other tabs into one button; open it out first.
        if !matches.firstMatch.waitForExistence(timeout: 2) {
            let folded = app.tabBars.buttons.matching(NSPredicate(format: "value == 'Collapsed'")).firstMatch
            if folded.exists { folded.tap() }
        }
        _ = matches.firstMatch.waitForExistence(timeout: 10)
        return matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
    }

    private func openTab(_ app: XCUIApplication, _ labels: [String]) {
        for _ in 0..<3 {
            let tab = tabButton(app, labels)
            XCTAssertTrue(tab.exists)
            tab.tap()
            if waitUntil(timeout: 3, { !tab.exists || tab.isSelected }) { return }
        }
    }

    private func openServerSettings(_ app: XCUIApplication) {
        openTab(app, Self.homeTab)
        let servers = app.buttons["settings.servers"]
        for _ in 0..<3 {
            app.buttons["home.settings"].tap()
            if servers.waitForExistence(timeout: 5) { break }
            dismissSavePasswordPrompt(app, within: 3)
        }
        XCTAssertTrue(servers.exists, "Settings should open")
        servers.tap()
    }

    private func dismissSavePasswordPrompt(_ app: XCUIApplication, within seconds: TimeInterval = 10) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Not Now", "Teď ne"]
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            for owner in [app, springboard] {
                let notNow = owner.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
                if notNow.exists {
                    notNow.tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
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
