import XCTest

/// The App Store screenshots, taken from real servers. Not a test of behaviour: run it on
/// purpose, on the device sizes the store wants, with a clean status bar (see
/// `scripts/app-store-screenshots.sh`). Use an own.audio server whose music may be shown
/// publicly, signed in as an account that owns it (identifying runs over one's own songs) and
/// is the family's admin.
///
/// `TEST_RUNNER_SCREENSHOT_LANGUAGE` is `en` or `cs`; `TEST_RUNNER_SCREENSHOT_DIR` is where the
/// PNGs go; `TEST_RUNNER_SCREENSHOT_ALBUM` is the album shown and played,
/// `TEST_RUNNER_SCREENSHOT_IDENTIFY_ALBUM` the one identified. With `NAVIDROME_*` and
/// `JELLYFIN_*` set, those servers are added too, so the server menu shows all three kinds.
final class AppStoreScreenshots: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var czech: Bool { env["SCREENSHOT_LANGUAGE"] == "cs" }
    private var iPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil, env["SCREENSHOT_DIR"] != nil, env["SCREENSHOT_LANGUAGE"] != nil else {
            throw XCTSkip("Set SERVER_HOST, SCREENSHOT_DIR and SCREENSHOT_LANGUAGE to take store screenshots")
        }
    }

    /// English or Czech, as the app says it.
    private func t(_ english: String, _ czech: String) -> String { self.czech ? czech : english }

    func testTakeScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestReset", "-AppleLanguages", "(\(env["SCREENSHOT_LANGUAGE"]!))", "-AppleLocale", czech ? "cs_CZ" : "en_US",
        ]
        app.launch()
        let ourName = t("Family Music", "Rodinná hudba")

        // Three servers, one of each kind; own.audio last, so it is the one shown.
        var first = true
        for (prefix, name) in [("NAVIDROME", "Navidrome"), ("JELLYFIN", "Jellyfin")] {
            guard let host = env["\(prefix)_HOST"] else { continue }
            if !first { openAddServer(app) }
            fillServerForm(app, host: host, user: env["\(prefix)_USER"] ?? "", password: env["\(prefix)_PASSWORD"] ?? "", name: name)
            if !first { closeSettings(app) }
            first = false
        }
        if !first { openAddServer(app) }
        fillServerForm(app, host: env["SERVER_HOST"]!, user: env["SERVER_USER"] ?? "", password: env["SERVER_PASSWORD"] ?? "", name: ourName)
        if !first { closeSettings(app) }
        // The server added last is the one shown.
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20))
        let serverMenu = app.buttons["home.serverMenu"]
        sleep(6)

        // The library's albums, with their covers; Home shows up later, behind the server menu.
        openLibraryAlbums(app)
        sleep(4)
        save(app, "1-albums")

        // The album, then the player a little way into its first song.
        let album = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", env["SCREENSHOT_ALBUM"] ?? "The Run")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 15))
        album.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 15) { play.isEnabled })
        sleep(2)
        save(app, "3-album")
        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 20))
        miniPlayer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.scrubber"].firstMatch.waitForExistence(timeout: 10))
        sleep(12)
        save(app, "2-player")

        // The equalizer, on a preset.
        app.buttons[t("EQ", "Ekvalizér")].tap()
        let toggle = app.switches["equalizer.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
        app.buttons["equalizer.preset.Loudness"].tap()
        sleep(1)
        save(app, "8-equalizer")
        app.buttons[t("Reset", "Obnovit")].tap()
        toggle.switches.firstMatch.tap()
        app.buttons[t("Done", "Hotovo")].tap()
        app.buttons["player.close"].tap()

        // Playlists: the server's smart ones at the top, then the household's.
        tab(app, t("Playlists", "Playlisty")).tap()
        sleep(4)
        save(app, "4-playlists")

        // The server menu: own.audio, Navidrome and Jellyfin side by side.
        tab(app, t("Home", "Domů")).tap()
        if serverMenu.waitForExistence(timeout: 5) {
            serverMenu.tap()
            sleep(2)
            save(app, "5-servers")
            // Closed by a tap beside it, which chooses nothing.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
            sleep(1)
        }

        identifyAlbum(app)

        // The family.
        openSettings(app)
        let household = app.buttons["settings.household"]
        XCTAssertTrue(household.waitForExistence(timeout: 10), "an own.audio server signed in through its API has a family")
        household.tap()
        XCTAssertTrue(app.staticTexts[t("Members", "Členové")].waitForExistence(timeout: 15))
        sleep(2)
        sleep(2)
        save(app, "7-family")
    }

    /// Music identification of one song, searched for in your own words: a well-known recording,
    /// whose many releases come with their covers. Cancelled, so the library stays as it was.
    private func identifyAlbum(_ app: XCUIApplication) {
        guard let name = env["SCREENSHOT_IDENTIFY_ALBUM"] else { return }
        openLibraryAlbums(app)
        let album = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 15))
        album.tap()
        let more = app.buttons["song.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "a song row should have a More button")
        more.tap()
        let identify = app.buttons[t("Identify…", "Identifikovat…")]
        XCTAssertTrue(identify.waitForExistence(timeout: 5), "a song of one's own should offer identify")
        identify.tap()
        let words = [
            ("picker.title", env["SCREENSHOT_SEARCH_TITLE"] ?? "Bohemian Rhapsody"),
            ("picker.artist", env["SCREENSHOT_SEARCH_ARTIST"] ?? "Queen"),
            ("picker.album", env["SCREENSHOT_SEARCH_ALBUM"] ?? "A Night at the Opera"),
        ]
        XCTAssertTrue(app.textFields["picker.title"].waitForExistence(timeout: 10))
        for (id, text) in words {
            let clear = app.buttons["\(id).clear"]
            if clear.exists { clear.tap() }
            let field = app.textFields[id]
            field.tap()
            field.typeText(text)
        }
        // Return puts the keyboard away, so the matches fill the screen.
        app.textFields["picker.album"].typeText("\n")
        app.buttons["picker.search"].tap()
        let result = app.buttons["picker.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 40), "MusicBrainz should find the song")
        // The covers in.
        sleep(6)
        save(app, "6-identify")
        app.buttons[t("Cancel", "Zrušit")].firstMatch.tap()
        sleep(1)
    }

    // MARK: - Steps

    private func fillServerForm(_ app: XCUIApplication, host: String, user: String, password: String, name: String) {
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText(host)
        app.textFields["addServer.username"].tap()
        app.textFields["addServer.username"].typeText(user)
        app.secureTextFields["addServer.password"].tap()
        app.secureTextFields["addServer.password"].typeText(password)
        // The library's title is the server's name; a plain one reads better than an address.
        let field = app.textFields["addServer.name"]
        field.tap()
        field.typeText(name)
        app.buttons["addServer.connect"].tap()
        sleep(4)
        dismissSavePasswordPrompt(app)
    }

    private func openSettings(_ app: XCUIApplication) {
        let servers = app.buttons["settings.servers"]
        for _ in 0..<3 where !servers.exists {
            tab(app, t("Home", "Domů")).tap()
            app.buttons["home.settings"].tap()
            if servers.waitForExistence(timeout: 5) { break }
            dismissSavePasswordPrompt(app)
        }
        XCTAssertTrue(servers.exists, "Settings should open")
    }

    private func openAddServer(_ app: XCUIApplication) {
        openSettings(app)
        app.buttons["settings.servers"].tap()
        let add = app.buttons["servers.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
    }

    /// Back out of Settings → Servers and close Settings. Only while inside Settings: once it is
    /// closed, the top-left button is Home's server menu.
    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons["settings.done"]
        for _ in 0..<3 where !done.isHittable && app.buttons["servers.add"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
        if done.waitForExistence(timeout: 5) { done.tap() }
    }

    /// Library → Albums. Right after signing in, a tap can land before the tab bar takes it.
    private func openLibraryAlbums(_ app: XCUIApplication) {
        let albums = app.buttons["library.albums"]
        for _ in 0..<4 where !albums.exists {
            tab(app, t("Library", "Knihovna")).tap()
            _ = albums.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(albums.exists)
        albums.tap()
    }

    private func tab(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: env["SCREENSHOT_DIR"]!)
        try? shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func dismissSavePasswordPrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app, springboard] {
            let notNow = owner.buttons.matching(NSPredicate(
                format: "label IN %@", ["Not Now", "Teď ne", "Jetzt nicht", "Plus tard", "Ahora no"]
            )).firstMatch
            if notNow.waitForExistence(timeout: 3) {
                notNow.tap()
                return
            }
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
}
