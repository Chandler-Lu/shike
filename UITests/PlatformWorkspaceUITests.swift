import XCTest

final class PlatformWorkspaceUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.textViews["sourceText"].waitForExistence(timeout: 15))
        return app
    }
    private func section(_ id: Int, _ name: String, app: XCUIApplication) {
        let sidebar = app.buttons["section-\(id)"]
        if sidebar.isHittable { sidebar.activateControl() }
        else { app.tabBars.buttons[name].activateControl() }
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    func testWorkspaceParseCalendarAndHistory() {
        let app = launch()
        capture("workspace-home", app)
        let parse = app.buttons["parseEvents"]; reveal(parse, app: app); parse.activateControl()
        capture("workspace-after-parse", app)
        XCTAssertTrue(app.buttons["editEvent-产品设计评审"].waitForExistence(timeout: 10))
        capture("workspace-parsed", app)
        section(1, "记录", app: app)
        XCTAssertTrue(app.staticTexts["2 个日程，0 个已加入日历"].waitForExistence(timeout: 5))
        app.staticTexts["2 个日程，0 个已加入日历"].activateControl()
        XCTAssertTrue(app.buttons["editEvent-产品设计评审"].waitForExistence(timeout: 5))
        capture("workspace-history", app)
        section(3, "日历", app: app)
        app.segmentedControls["calendarRange"].buttons["7 天"].activateControl()
        capture("workspace-week", app)
        section(4, "倒数日", app: app)
        XCTAssertTrue(app.staticTexts["3 个日子"].waitForExistence(timeout: 5))
        capture("workspace-countdowns", app)
        section(2, "设置", app: app)
        capture("workspace-settings", app)
    }

    #if !targetEnvironment(macCatalyst)
    func testIPadWideLayout() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad window layout") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        if !app.buttons["section-0"].isHittable {
            // iPadOS windowing may restore a narrow window. Double-tap its title bar.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).doubleTap()
        }
        let sidebar = app.buttons["section-0"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.isHittable)
        capture("ipad-wide-workspace", app)
        section(4, "倒数日", app: app)
        XCTAssertTrue(app.otherElements["countdownDetailPane"].exists || app.staticTexts["选一个日子，慢慢翻看。"].exists)
        capture("ipad-wide-countdowns", app)
    }

    func testIPadRotationKeepsSourceAndUnsavedCountdownEdit() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad rotation test") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        let input = app.textViews["sourceText"]
        input.activateControl(); input.typeText(" rotation-marker")
        // Dismiss before rotating: the system keyboard can briefly expose stale
        // accessibility coordinates while iPadOS animates a window rotation.
        let dismissKeyboard = app.buttons["收起键盘"]
        if dismissKeyboard.isHittable { dismissKeyboard.activateControl() }
        else {
            let hideKeyboard = app.keyboards.buttons["隐藏键盘"].firstMatch
            expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: hideKeyboard)
            waitForExpectations(timeout: 5)
            hideKeyboard.activateControl()
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue((input.value as? String ?? "").contains("rotation-marker"))
        capture("ipad-portrait-input", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("ipad-landscape-input", app)
        section(4, "倒数日", app: app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.activateControl()
        XCTAssertTrue(app.buttons["editCountdown"].waitForExistence(timeout: 5))
        app.buttons["editCountdown"].activateControl()
        let title = app.textFields["countdownTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.activateControl(); title.typeText(" unsaved-marker")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue((title.value as? String ?? "").contains("unsaved-marker"))
        capture("ipad-unsaved-editor-portrait", app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue((title.value as? String ?? "").contains("unsaved-marker"))
        app.buttons["cancelCountdownEditing"].activateControl()
    }
    #else
    func testMacKeyboardNavigationAndFilePicker() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["chooseFiles"].exists)
        XCTAssertFalse(app.buttons["takePhoto"].exists)
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["addCountdown"].waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.textFields["searchCountdowns"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        capture("mac-countdown-editor", app)
        XCTAssertTrue(app.descendants(matching: .any)["countdownTitle"].waitForExistence(timeout: 5))
        app.buttons["cancelCountdownEditing"].activateControl()
        app.typeKey(",", modifierFlags: .command)
        capture("mac-settings", app)
        app.typeKey("o", modifierFlags: .command)
        capture("mac-file-picker", app)
        XCTAssertTrue(app.buttons["打开"].firstMatch.waitForExistence(timeout: 8) || app.dialogs.firstMatch.exists || app.sheets.firstMatch.exists)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Shike-\(UUID().uuidString).txt")
        try "File-import-marker".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(file.path)
        app.typeKey(.return, modifierFlags: [])
        app.windows.buttons["打开"].firstMatch.click()
        let input = app.textViews["sourceText"]
        let imported = NSPredicate(format: "value CONTAINS %@", "File-import-marker")
        expectation(for: imported, evaluatedWith: input)
        waitForExpectations(timeout: 8)
        capture("mac-file-imported", app)
    }

    func testMacResizePreservesSource() {
        let app = launch()
        let input = app.textViews["sourceText"]
        input.click(); input.typeText(" resize-marker")
        let window = app.windows.firstMatch
        let frame = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        let narrow = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 610, dy: 650))
        corner.click(forDuration: 0.2, thenDragTo: narrow)
        XCTAssertLessThan(window.frame.width, frame.width)
        XCTAssertTrue((input.value as? String ?? "").contains("resize-marker"))
        capture("mac-narrow", app)
        let newCorner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        let original = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width - 3, dy: frame.height - 3))
        newCorner.click(forDuration: 0.2, thenDragTo: original)
        XCTAssertTrue((input.value as? String ?? "").contains("resize-marker"))
        capture("mac-wide", app)
    }
    #endif
}

private extension XCUIElement {
    func activateControl() {
        #if targetEnvironment(macCatalyst)
        click()
        #else
        tap()
        #endif
    }
}
