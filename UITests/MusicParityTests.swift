import XCTest

/// What the music app took over from the books and podcasts apps: Apple and Google sign-in shown
/// only for an own.audio server that takes them, and a Privacy link in Settings. Needs the
/// network, no server of its own.
final class MusicParityTests: XCTestCase {
    private let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"] + english
        app.launchChecked()
        return app
    }

    /// The public canary takes both; an address that isn't own.audio shows neither.
    func testSignInButtonsFollowTheServer() {
        let app = launch()
        let field = app.textFields["addServer.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["addServer.apple"].exists, "nothing typed, no buttons")
        field.tap()
        field.typeText("app-canary.own.audio")
        XCTAssertTrue(app.buttons["addServer.apple"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["addServer.google"].exists)
        // The web app's address with https://, as it is copied from a browser.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "https://app-canary.own.audio")
        XCTAssertTrue(app.buttons["addServer.google"].waitForExistence(timeout: 20), "with https:// too")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "https://example.com")
        XCTAssertTrue(app.buttons["addServer.google"].waitForNonExistence(timeout: 20))
        XCTAssertFalse(app.buttons["addServer.apple"].exists)
    }

    func testPrivacyLinkInSettings() {
        let app = launch()
        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 90), "Home opens on the demo")
        settings.tap()
        let privacy = app.descendants(matching: .any)["settings.privacy"].firstMatch
        for _ in 0..<12 where !privacy.isHittable { app.swipeUp() }
        XCTAssertTrue(privacy.isHittable, "Privacy under About, as in the other apps")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-about"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Download on Wi-Fi Only (on by default) and Keep at Most, kept across a relaunch.
    func testDownloadSettings() {
        var app = launch()
        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 90))
        app.buttons["home.settings"].tap()
        let wifi = app.switches["settings.wifiOnly"].firstMatch
        for _ in 0..<6 where !wifi.isHittable { app.swipeUp() }
        XCTAssertTrue(wifi.exists)
        XCTAssertEqual(wifi.value as? String, "1", "Wi-Fi only by default, as in the other apps")
        wifi.switches.firstMatch.tap()
        XCTAssertEqual(wifi.value as? String, "0")
        let cap = app.buttons["settings.storageCap"].firstMatch
        XCTAssertTrue(cap.exists)
        cap.tap()
        let fiveGB = app.buttons.matching(NSPredicate(format: "label CONTAINS '5 GB'")).firstMatch
        XCTAssertTrue(fiveGB.waitForExistence(timeout: 5))
        fiveGB.tap()
        XCTAssertTrue(cap.label.contains("5 GB") || (cap.value as? String ?? "").contains("5 GB"))

        app.terminate()
        app = XCUIApplication()
        app.launchArguments = english
        app.launchChecked()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 60))
        app.buttons["home.settings"].tap()
        let wifiAgain = app.switches["settings.wifiOnly"].firstMatch
        for _ in 0..<6 where !wifiAgain.isHittable { app.swipeUp() }
        XCTAssertEqual(wifiAgain.value as? String, "0", "kept across a relaunch")
        let capAgain = app.buttons["settings.storageCap"].firstMatch
        XCTAssertTrue(capAgain.label.contains("5 GB") || (capAgain.value as? String ?? "").contains("5 GB"))
    }

    /// The new Settings rows in Czech at the largest text size: there, translated, and reachable.
    func testNewSettingsInCzechAtLargestText() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(cs)", "-AppleLocale", "cs_CZ",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchChecked()
        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 90))
        app.buttons["home.settings"].tap()
        let expected: [(String, String)] = [
            ("settings.wifiOnly", "Stahovat jen přes Wi-Fi"),
            ("settings.storageCap", "Ponechat nejvýše"),
            ("settings.privacy", "Soukromí"),
            ("settings.logs", "Záznamy"),
        ]
        for (identifier, label) in expected {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            for _ in 0..<12 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable, "\(identifier) reachable")
            XCTAssertTrue(element.label.contains(label), "\(identifier): \(element.label)")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "cs-xxxl-settings"
        shot.lifetime = .keepAlways
        add(shot)
        app.descendants(matching: .any)["settings.logs"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Záznamy"].waitForExistence(timeout: 10), "the log opens")
    }

    /// The server list and page open; the screenshots are for a look at their colours.
    func testServerPage() {
        let app = launch()
        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 90))
        app.buttons["home.settings"].tap()
        let info = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'servers.row.'")).firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        attach(app, "settings-servers")
        info.tap()
        XCTAssertTrue(app.buttons["serverDetail.check"].waitForExistence(timeout: 10))
        app.buttons["serverDetail.check"].tap()
        sleep(3)
        attach(app, "server-page")

        // Renamed and removed on its page, as in the podcasts app.
        let name = app.buttons["serverDetail.name"]
        for _ in 0..<4 where !name.isHittable { app.swipeUp() }
        name.tap()
        let field = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "Demo Renamed")
        let save = app.alerts.firstMatch.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.element(boundBy: 1).tap() }
        XCTAssertTrue(app.navigationBars["Demo Renamed"].waitForExistence(timeout: 5), "the page shows the new name")
        let remove = app.buttons["serverDetail.remove"]
        for _ in 0..<8 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        let confirm = app.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "it asks first")
        confirm.tap()
        XCTAssertTrue(app.textFields["addServer.address"].waitForExistence(timeout: 15), "with no server left, the welcome screen")
    }

    /// Settings → Add a Server opens the sign-in sheet, and it stays open. It used to close at
    /// once: the sheet hung on the servers' section, not on the Settings screen.
    func testAddServerSheetStaysOpen() {
        let app = launch()
        let demo = app.buttons["addServer.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 15))
        demo.tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 90))
        app.buttons["home.settings"].tap()
        let add = app.buttons["servers.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "the sign-in sheet opens")
        sleep(3)
        XCTAssertTrue(address.exists, "and stays open")
        address.tap()
        address.typeText("demo.own.audio")
        sleep(2)
        XCTAssertTrue(address.exists, "while typing too")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
