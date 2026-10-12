import XCTest

/// own.audio's "identify library": reach it from the server's page, start a run, look at it,
/// delete it. Needs an own.audio server that offers it and an account that may start a run:
///
/// ```
/// TEST_RUNNER_IDENTIFY_HOST=https://… TEST_RUNNER_IDENTIFY_EMAIL=… TEST_RUNNER_IDENTIFY_PASSWORD=… \
/// xcodebuild test … -only-testing:OwnAudioMusicUITests/IdentifyTests
/// ```
///
/// The run is deleted at the end; nothing it proposed is accepted.
final class IdentifyTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["IDENTIFY_HOST"] != nil else { throw XCTSkip("IDENTIFY_HOST is not set") }
    }

    func testStartReviewAndDeleteARun() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + Self.english + (env["IDENTIFY_LANGUAGE"].map { ["-AppleLanguages", "(\($0))"] } ?? [])
        app.launch()

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

        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Home should open after connecting")
        let servers = app.buttons["settings.servers"]
        // Right after Home appears a tap can land before the toolbar takes it.
        for _ in 0..<3 where !servers.exists {
            settings.tap()
            _ = servers.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(servers.exists)
        servers.tap()
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.info.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()

        let identify = app.buttons["serverDetail.identify"]
        // Further down the page; a list makes its rows only when they scroll into view.
        XCTAssertTrue(app.buttons["serverDetail.check"].waitForExistence(timeout: 10))
        for _ in 0..<4 where !identify.exists {
            app.swipeUp()
            _ = identify.waitForExistence(timeout: 3)
        }
        let offered = identify.exists
        screenshot(app, "identify-01-server")
        XCTAssertTrue(offered, "The server should offer identify")
        identify.tap()

        let start = app.buttons["identify.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        sleep(1)
        screenshot(app, "identify-02-runs")
        start.tap()
        // A server that charges asks first, when the run would cost anything.
        let confirm = app.buttons["Start"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }

        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 15), "The new run should open")
        sleep(8)
        screenshot(app, "identify-03-run")

        more.tap()
        app.buttons["Delete Run"].firstMatch.tap()
        let delete = app.buttons.matching(NSPredicate(format: "label == 'Delete Run'")).element(boundBy: 0)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Deleting goes back to the runs")
        screenshot(app, "identify-04-deleted")
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
