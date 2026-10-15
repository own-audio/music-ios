import XCTest

/// Add a server, open an album, play it, skip a track: the path every listener takes first.
///
/// Needs a real server with at least one album of two or more tracks:
///
/// ```
/// TEST_RUNNER_SERVER_HOST=localhost:4533 TEST_RUNNER_SERVER_USER=… TEST_RUNNER_SERVER_PASSWORD=… \
/// xcodebuild test …   # optionally TEST_RUNNER_SERVER_ALBUM="<name>"
/// ```
///
/// `TEST_RUNNER_SCREENSHOT_DIR` saves a screenshot of each step there as well as in the result.
final class PlaybackSmokeTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The tests find some controls by their English label, and the simulator may be set to
    /// another language the app is translated into.
    private static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SERVER_HOST"] != nil else {
            throw XCTSkip("SERVER_HOST is not set")
        }
    }

    func testAddServerPlayAlbumAndSkip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()

        addServer(app)
        openAlbum(app, named: env["SERVER_ALBUM"])

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { play.isEnabled }, "Play should enable once the songs load")
        screenshot(app, "04-album")
        play.tap()

        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15), "the mini player should appear once playback starts")
        // A spinner stands where the button goes until the first audio arrives.
        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(waitUntil(timeout: 30) { miniPlayPause.exists && miniPlayPause.label == "Pause" }, "playback should start")
        screenshot(app, "05-mini-player")
        miniPlayer.tap()

        let title = app.descendants(matching: .any)["player.title"].firstMatch
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        let firstTitle = title.label
        let firstPosition = scrubber.value as? String ?? ""
        sleep(3)
        XCTAssertNotEqual(scrubber.value as? String ?? "", firstPosition, "the position should advance while playing")
        screenshot(app, "06-player")

        app.buttons["player.next"].tap()
        XCTAssertTrue(waitUntil(timeout: 30) { title.exists && title.label != firstTitle }, "next should change the track")
        sleep(1)
        screenshot(app, "07-next-track")

        // Star the playing song and put it back, so the library ends as it began.
        let star = app.buttons["player.star"]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        let before = star.label
        star.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { star.label != before }, "the star should flip")
        screenshot(app, "08-starred")
        star.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { star.label == before }, "the star should flip back")

        app.buttons["player.playPause"].tap()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(waitUntil(timeout: 5) { playPause.exists && playPause.label == "Play" }, "pause should pause")
    }

    /// On mobile data with 128 kbps chosen, a server that transcodes (Jellyfin) makes an MP3 on the
    /// fly; one that doesn't sends the original. Either way it has to play.
    func testSmallerStreamOnMobileDataPlays() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-simulateMobileData", "-mobileBitrate", "128000"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openAlbum(app, named: env["SERVER_ALBUM"], screenshots: false)
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { play.isEnabled })
        play.tap()
        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(
            waitUntil(timeout: 30) { miniPlayPause.exists && miniPlayPause.label == "Pause" },
            "the transcoded stream should start"
        )
        app.buttons["miniPlayer"].tap()
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        let first = scrubber.value as? String ?? ""
        sleep(4)
        XCTAssertNotEqual(scrubber.value as? String ?? "", first, "the transcoded stream should keep playing")
        screenshot(app, "16-mobile-data-player")
    }

    /// Dragging the position: the player stays as it was (cover, format, times) while the song
    /// moves there, and the bar doesn't spring back. The ✕ stops playback and closes the player.
    func testSeekThenStop() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openAlbum(app, named: env["SERVER_ALBUM"], screenshots: false)
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { play.isEnabled })
        play.tap()
        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(waitUntil(timeout: 30) { miniPlayPause.exists && miniPlayPause.label == "Pause" })
        app.buttons["miniPlayer"].tap()
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        sleep(3)
        screenshot(app, "23a-before-seek")

        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        screenshot(app, "23b-just-after-seek")
        sleep(1)
        screenshot(app, "23c-a-second-after")
        // Read as "1:23 of 3:20": the position should be past the middle, not back at the start.
        XCTAssertTrue(waitUntil(timeout: 30) {
            let parts = (scrubber.value as? String ?? "").components(separatedBy: " of ")
            guard parts.count == 2, let at = Self.seconds(parts[0]), let of = Self.seconds(parts[1]), of > 0 else { return false }
            return Double(at) / Double(of) > 0.5
        }, "the song should move to where the bar was dragged, is \(scrubber.value as? String ?? "")")
        XCTAssertTrue(waitUntil(timeout: 15) { miniPlayPause.exists || app.buttons["player.stop"].exists })

        app.buttons["player.stop"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !scrubber.exists }, "stopping should close the player")
        XCTAssertFalse(app.buttons["miniPlayer"].exists, "nothing should be left playing")
    }

    /// What a listener feels, timed: from launch to the library, from Play to sound, a seek,
    /// opening an album — and memory and CPU while playing. Written to perf.txt beside the
    /// screenshots; the limits are generous, to catch something gone wrong, not to rank.
    func testPerformance() throws {
        var lines: [String] = []
        func note(_ name: String, _ seconds: Double, limit: Double) {
            lines.append(String(format: "%@: %.2f s (limit %.0f s)", name, seconds, limit))
            XCTAssertLessThan(seconds, limit, name)
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)

        // A cold launch with a server set up, to a library that can be used.
        app.terminate()
        app.launchArguments = Self.english
        var start = Date()
        app.launch()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 30))
        note("launch to Home", Date().timeIntervalSince(start), limit: 6)

        start = Date()
        openTab(app, Self.libraryTab)
        let albums = app.buttons["library.albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        XCTAssertTrue(app.scrollViews.buttons.firstMatch.waitForExistence(timeout: 20))
        note("Library to the album grid", Date().timeIntervalSince(start), limit: 6)

        start = Date()
        app.scrollViews.buttons.firstMatch.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { play.isEnabled })
        note("open an album", Date().timeIntervalSince(start), limit: 6)

        start = Date()
        play.tap()
        let pause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(waitUntil(timeout: 30) { pause.exists && pause.label == "Pause" })
        note("Play to sound", Date().timeIntervalSince(start), limit: 8)

        app.buttons["miniPlayer"].tap()
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        sleep(2)
        start = Date()
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        XCTAssertTrue(waitUntil(timeout: 30) {
            let parts = (scrubber.value as? String ?? "").components(separatedBy: " of ")
            guard parts.count == 2, let at = Self.seconds(parts[0]), let of = Self.seconds(parts[1]), of > 0 else { return false }
            return Double(at) / Double(of) > 0.45
        })
        note("seek to the middle", Date().timeIntervalSince(start), limit: 15)

        // Memory and CPU while the player plays.
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            sleep(8)
        }

        let report = lines.joined(separator: "\n")
        print("PERF\n" + report)
        if let dir = env["SCREENSHOT_DIR"] {
            try? report.write(toFile: dir + "/perf.txt", atomically: true, encoding: .utf8)
        }
    }

    /// "1:23" or "1:02:03" as seconds.
    static func seconds(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Settings → Servers → the server's connection: it ends up connected through one of its
    /// addresses (on a Jellyfin or own.audio server reached from its own network, the home
    /// address it named itself).
    func testServerConnectionDetail() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openServerSettings(app)
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.info.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        screenshot(app, "16-servers")
        info.tap()
        let status = app.descendants(matching: .any)["serverDetail.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil(timeout: 20) { status.label.contains("Connected") },
            "the server should be reached through one of its addresses, got \(status.label)"
        )
        // Check Now says what it found.
        app.buttons["serverDetail.check"].tap()
        let result = app.descendants(matching: .any)["serverDetail.checkResult"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "Check Now should say what it found")
        XCTAssertTrue(result.label.contains("accepts the sign-in"), "got \(result.label)")
        screenshot(app, "17-server-connection")
        let talks = app.descendants(matching: .any)["serverDetail.protocol"].firstMatch
        for _ in 0..<4 where !talks.isHittable { app.swipeUp() }
        XCTAssertTrue(talks.exists, "the detail should say how the app talks to the server")
        screenshot(app, "17c-server-protocol")
        for _ in 0..<4 where !app.buttons["serverDetail.signInAgain"].isHittable { app.swipeDown() }

        // Signing in again keeps the server: its detail screen, connected, afterwards.
        let again = app.buttons["serverDetail.signInAgain"]
        for _ in 0..<3 where !again.isHittable { app.swipeUp() }
        again.tap()
        let password = app.secureTextFields["signInAgain.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        screenshot(app, "17a-sign-in-again")
        XCTAssertFalse((app.textFields["signInAgain.username"].value as? String ?? "").isEmpty, "the username should be filled in")
        password.tap()
        password.typeText(env["SERVER_PASSWORD"] ?? "")
        app.buttons["signInAgain.submit"].tap()
        dismissSavePasswordPrompt(app)
        XCTAssertTrue(waitUntil(timeout: 30) { !password.exists }, "signing in again should close the sheet")
        XCTAssertTrue(waitUntil(timeout: 20) { status.exists && status.label.contains("Connected") }, "still connected, got \(status.label)")
        screenshot(app, "17b-signed-in-again")
    }

    /// A playlist made, opened (it is the account's own, so it can be edited) and deleted; then
    /// a search that finds the download album. On own.audio both go through its own API.
    func testPlaylistLifeAndSearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openTab(app, Self.playlistsTab)
        let new = app.buttons["playlists.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        new.tap()
        // Sorted first, so it is on screen however many playlists the server has.
        let name = "000 UI Test \(Int.random(in: 1000...9999))"
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        app.alerts.buttons["Create"].tap()
        let row = app.staticTexts[name]
        // A server may list a new playlist a moment late; pull to refresh until it does.
        XCTAssertTrue(waitUntil(timeout: 40) {
            if row.waitForExistence(timeout: 5) { return true }
            app.swipeDown()
            return false
        }, "the new playlist should be listed")
        row.tap()
        let edit = app.buttons["Edit Playlist"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15), "the account's own playlist should offer editing")
        screenshot(app, "20-playlist")
        edit.tap()
        let delete = app.buttons["Delete Playlist"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete Playlist'"))
        XCTAssertTrue(waitUntil(timeout: 5) { confirm.count > 0 && confirm.element(boundBy: confirm.count - 1).isHittable })
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !app.staticTexts[name].exists }, "the deleted playlist should be gone")

        guard let album = env["SERVER_DOWNLOAD_ALBUM"].flatMap({ $0.isEmpty ? nil : $0 }) else { return }
        openTab(app, Self.searchTab)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(album)
        let hit = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", album)).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 20), "searching for \(album) should find it")
        screenshot(app, "21-search")
    }

    /// Smart playlists, where the server has them (own.audio from 1.0.0-beta.13): a ready-made
    /// one opened, a rule made in the editor (the songs that fit counted as it goes), saved,
    /// played and deleted. Needs `SERVER_SMART_GENRE`, a genre with a few songs.
    func testSmartPlaylists() throws {
        guard let genre = env["SERVER_SMART_GENRE"].flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw XCTSkip("SERVER_SMART_GENRE is not set")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openTab(app, Self.playlistsTab)
        let newSmart = app.buttons["playlists.newSmart"]
        guard newSmart.waitForExistence(timeout: 20) else { throw XCTSkip("this server has no smart playlists") }
        screenshot(app, "22-smart-list")

        let preset = app.buttons["playlists.preset.new-in-the-library"]
        XCTAssertTrue(preset.waitForExistence(timeout: 10))
        preset.tap()
        // Play is on only when there are songs (the summary under them can be off screen).
        let play = app.buttons["detail.play"]
        XCTAssertTrue(waitUntil(timeout: 20) { play.exists && play.isEnabled }, "a ready-made one lists songs")
        screenshot(app, "23-smart-preset")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(newSmart.waitForExistence(timeout: 10))
        newSmart.tap()
        let name = "000 Smart \(Int.random(in: 1000...9999))"
        let field = app.textFields["smartEditor.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(name)
        app.buttons["smartEditor.genres"].tap()
        let choice = app.buttons[genre]
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "the library's genres should be listed")
        choice.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let matching = app.staticTexts["smartEditor.matching"]
        XCTAssertTrue(waitUntil(timeout: 20) { matching.exists && matching.label.contains("fit") }, "the editor should count the songs that fit")
        if let expected = env["SERVER_SMART_GENRE_COUNT"].flatMap(Int.init) {
            XCTAssertTrue(waitUntil(timeout: 10) { matching.label.hasPrefix("\(expected) ") }, "\(expected) songs of \(genre), got \(matching.label)")
        }
        screenshot(app, "24-smart-editor")
        app.buttons["smartEditor.save"].tap()

        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the saved smart playlist should be listed")
        row.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { play.exists && play.isEnabled }, "the saved one lists songs")
        screenshot(app, "25-smart-playlist")
        app.buttons["smart.actions"].tap()
        let delete = app.buttons["Delete Smart Playlist"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete Smart Playlist'"))
        XCTAssertTrue(waitUntil(timeout: 5) { confirm.count > 0 && confirm.element(boundBy: confirm.count - 1).isHittable })
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !app.staticTexts[name].exists }, "the deleted smart playlist should be gone")
    }

    /// Download an album, then start the app with every server unreachable and play it from
    /// Downloads. `TEST_RUNNER_SERVER_DOWNLOAD_ALBUM` picks a small album; without it, the
    /// first one.
    func testDownloadAlbumAndPlayOffline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openAlbum(app, named: env["SERVER_DOWNLOAD_ALBUM"].flatMap { $0.isEmpty ? nil : $0 }, screenshots: false)

        let download = app.buttons["download.start"]
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { download.isEnabled }, "Download should enable once the songs load")
        download.tap()
        let done = app.buttons["download.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 300), "the album should finish downloading")
        screenshot(app, "10-downloaded")

        app.terminate()
        app.launchArguments = ["-simulateOffline"] + Self.english
        app.launch()

        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        sleep(2)
        screenshot(app, "11-offline-home")
        openTab(app, Self.libraryTab)
        let downloadsLink = app.buttons["library.downloads"]
        XCTAssertTrue(downloadsLink.waitForExistence(timeout: 10))
        downloadsLink.tap()

        let collection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'downloads.album.'")).firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 20), "the downloaded album should be listed offline")
        screenshot(app, "12-downloads")
        collection.tap()

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()

        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(
            waitUntil(timeout: 15) { miniPlayPause.exists && miniPlayPause.label == "Pause" },
            "a downloaded album should play with no server"
        )
        app.buttons["miniPlayer"].tap()
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        let firstPosition = scrubber.value as? String ?? ""
        sleep(3)
        XCTAssertNotEqual(scrubber.value as? String ?? "", firstPosition, "offline playback should advance")
        screenshot(app, "13-offline-player")
    }

    /// The case that used to hang: an album with only some songs downloaded, played with no
    /// network. Downloads the second song alone, goes offline, opens the album from the offline
    /// library and taps Play: the first song is passed over and the downloaded one plays.
    func testPartlyDownloadedAlbumPlaysOffline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openTab(app, Self.libraryTab)
        let albums = app.buttons["library.albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()

        // The first album with at least two songs.
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'album.song.'"))
        var found = false
        for index in 0..<8 {
            let tile = app.scrollViews.buttons.element(boundBy: index)
            XCTAssertTrue(tile.waitForExistence(timeout: 20))
            tile.tap()
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
            if rows.count >= 2 { found = true; break }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(found, "no album with two or more songs among the first eight")
        let second = rows.element(boundBy: 1)
        let secondTitle = String(second.identifier.dropFirst("album.song.".count))
        second.press(forDuration: 1.0)
        // The menu's Download, not the toolbar's whole-album one.
        let download = app.buttons.matching(NSPredicate(format: "label == 'Download' AND identifier != 'download.start'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(
            waitUntil(timeout: 120) { second.label.contains("Downloaded") },
            "the second song should finish downloading"
        )

        app.terminate()
        app.launchArguments = ["-simulateOffline"] + Self.english
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["offline.banner"].waitForExistence(timeout: 15))
        screenshot(app, "14-offline-home")
        openAlbum(app, named: nil, screenshots: false)

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 10) { play.isEnabled })
        screenshot(app, "15-offline-album")
        play.tap()

        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(
            waitUntil(timeout: 15) { miniPlayPause.exists && miniPlayPause.label == "Pause" },
            "the downloaded song should play with no server"
        )
        XCTAssertTrue(app.buttons["miniPlayer"].label.contains(secondTitle), "playback should start at the downloaded song")
    }

    /// An own.audio server's household: Settings → Household lists its members. Other servers
    /// have no household, and no such row.
    func testHousehold() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        let household = app.buttons["settings.household"]
        for _ in 0..<3 {
            app.buttons["home.settings"].tap()
            if app.buttons["settings.servers"].waitForExistence(timeout: 5) { break }
            dismissSavePasswordPrompt(app, within: 3)
        }
        guard household.waitForExistence(timeout: 5) else { throw XCTSkip("this server has no family") }
        household.tap()
        XCTAssertTrue(app.staticTexts["Members"].waitForExistence(timeout: 15), "the members should be listed")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label ENDSWITH '(you)'")).firstMatch.exists, "the listener should be among them")
        screenshot(app, "22-family")
    }

    /// The catalogue reaches the phone after adding a server; offline, with Whole Library on,
    /// the albums list shows albums that were never opened or downloaded, and one opens with
    /// its songs.
    func testWholeLibraryOffline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openServerSettings(app)
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.info.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()
        let catalogue = app.descendants(matching: .any)["serverDetail.catalogue"].firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 180) {
                if !catalogue.exists { app.swipeUp() }
                return catalogue.exists
            },
            "the catalogue should be synced after adding the server"
        )
        screenshot(app, "18-catalogue")

        app.terminate()
        app.launchArguments = ["-simulateOffline", "-offlineShowsWholeLibrary", "YES"] + Self.english
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["offline.banner"].waitForExistence(timeout: 15))
        openTab(app, Self.libraryTab)
        let albums = app.buttons["library.albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        let tile = app.scrollViews.buttons.element(boundBy: 1)
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "offline, the whole library's albums should be listed")
        tile.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'album.song.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "an album never opened should open offline from the catalogue")
        screenshot(app, "19-offline-catalogue-album")
    }

    /// Needs an album whose first song has ReplayGain tags (track gain -6.5 dB) and synced
    /// lyrics: `TEST_RUNNER_SERVER_LYRICS_ALBUM`. Skipped without it; the real servers used for
    /// testing have neither, so this runs against a local Navidrome with a generated album.
    func testLyricsReplayGainAndEqualizer() throws {
        guard let albumName = env["SERVER_LYRICS_ALBUM"], !albumName.isEmpty else {
            throw XCTSkip("SERVER_LYRICS_ALBUM is not set")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english
        app.launch()
        addServer(app, screenshots: false)
        openAlbum(app, named: albumName, screenshots: false)

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { play.isEnabled })
        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let gain = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '-6.5 dB'")).firstMatch
        XCTAssertTrue(gain.waitForExistence(timeout: 15), "the player should show the ReplayGain it applies")
        screenshot(app, "20-replaygain")

        app.buttons["Lyrics"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["lyrics.synced"].waitForExistence(timeout: 10), "synced lyrics should load")
        XCTAssertTrue(app.staticTexts["The first line arrives"].waitForExistence(timeout: 5))
        sleep(6)
        screenshot(app, "21-lyrics")
        app.buttons["Done"].tap()

        app.buttons["EQ"].tap()
        let toggle = app.switches["equalizer.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
        app.buttons["equalizer.preset.Bass Boost"].tap()
        sleep(1)
        screenshot(app, "22-equalizer")
        // Back to flat and off, so other runs start clean.
        app.buttons["Reset"].tap()
        toggle.switches.firstMatch.tap()
        app.buttons["Done"].tap()
    }

    /// Walks the main screens in Czech and saves screenshots, to catch untranslated or
    /// clipped text. Finds everything by identifier, so it doesn't depend on the language.
    func testCzechScreens() throws {
        try walkMainScreens(
            prefix: "cs", arguments: ["-AppleLanguages", "(cs)", "-AppleLocale", "cs_CZ"]
        )
    }

    /// The same screens at the largest accessibility text size.
    func testLargeTextScreens() throws {
        try walkMainScreens(
            prefix: "xxl", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] + Self.english
        )
    }

    private func walkMainScreens(prefix: String, arguments: [String]) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + arguments
        app.launch()
        let address = app.textFields["addServer.address"]
        sleep(2)
        screenshot(app, "\(prefix)-01-onboarding")
        // At large text sizes the form's fields start below the screen, and a form only
        // creates the rows it shows.
        for _ in 0..<4 where !address.exists { app.swipeUp() }
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(env["SERVER_HOST"]!)
        app.textFields["addServer.username"].tap()
        app.textFields["addServer.username"].typeText(env["SERVER_USER"] ?? "")
        app.secureTextFields["addServer.password"].tap()
        app.secureTextFields["addServer.password"].typeText(env["SERVER_PASSWORD"] ?? "")
        let connect = app.buttons["addServer.connect"]
        for _ in 0..<4 where !connect.isHittable { app.swipeUp() }
        connect.tap()
        sleep(4)
        dismissSavePasswordPrompt(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        sleep(2)
        screenshot(app, "\(prefix)-02-home")
        openTab(app, Self.libraryTab)
        let albums = app.buttons["library.albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 15))
        screenshot(app, "\(prefix)-02-library")

        albums.tap()
        let album = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { play.isEnabled })
        screenshot(app, "\(prefix)-03-album")
        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 20))
        miniPlayer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.scrubber"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        screenshot(app, "\(prefix)-04-player")
        app.buttons["player.close"].tap()

        openTab(app, Self.homeTab)
        app.buttons["home.settings"].tap()
        sleep(1)
        screenshot(app, "\(prefix)-05-settings")
        app.buttons["settings.done"].tap()
    }

    private func addServer(_ app: XCUIApplication, screenshots: Bool = true) {
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        if screenshots { screenshot(app, "01-onboarding") }
        address.tap()
        address.typeText(env["SERVER_HOST"]!)
        app.textFields["addServer.username"].tap()
        app.textFields["addServer.username"].typeText(env["SERVER_USER"] ?? "")
        app.secureTextFields["addServer.password"].tap()
        app.secureTextFields["addServer.password"].typeText(env["SERVER_PASSWORD"] ?? "")
        app.buttons["addServer.connect"].tap()

        dismissSavePasswordPrompt(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15), "Home should open after connecting")
        sleep(2)
        if screenshots { screenshot(app, "02-home") }
    }

    /// Without a name, the first album in the grid.
    private func openAlbum(_ app: XCUIApplication, named name: String?, screenshots: Bool = true) {
        openTab(app, Self.libraryTab)
        let albums = app.buttons["library.albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        albums.tap()
        let album = name.map {
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch
        } ?? app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        sleep(1)
        if screenshots { screenshot(app, "03-albums") }
        album.tap()
    }

    static let homeTab = ["Home", "Domů"]
    static let libraryTab = ["Library", "Knihovna"]
    static let playlistsTab = ["Playlists", "Playlisty"]
    static let searchTab = ["Search", "Hledat"]

    /// Tabs can't carry identifiers, so they are found by their label in either language.
    private func openTab(_ app: XCUIApplication, _ labels: [String]) {
        let tab = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        // Right after the first screen gives way to the tabs, a tap can land before the tab bar
        // takes it; try again until the tab reports itself selected.
        for _ in 0..<3 {
            tab.tap()
            // The search tab turns into the search field once open: gone means it opened.
            if waitUntil(timeout: 3, { !tab.exists || tab.isSelected }) { return }
        }
    }

    /// Settings → Servers. iOS's offer to save the password can come late and swallow the tap on
    /// Settings, so the tap is tried again once the offer is out of the way.
    private func openServerSettings(_ app: XCUIApplication) {
        let servers = app.buttons["settings.servers"]
        for _ in 0..<3 {
            app.buttons["home.settings"].tap()
            if servers.waitForExistence(timeout: 5) { break }
            dismissSavePasswordPrompt(app, within: 3)
        }
        XCTAssertTrue(servers.exists, "Settings should open")
        servers.tap()
    }

    /// iOS offers to save the password after a sign-in form. It's the system's sheet, in the
    /// system's language, so it is found by position: "Not Now" is the first of its two buttons.
    private func dismissSavePasswordPrompt(_ app: XCUIApplication, within seconds: TimeInterval = 10) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Not Now", "Teď ne", "Jetzt nicht", "Plus tard", "Ahora no"]
        // Either may show it, and over the internet it can come several seconds after signing in.
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
