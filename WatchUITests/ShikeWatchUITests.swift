import XCTest

final class ShikeWatchUITests: XCTestCase {
    func testGroupSelectionPersistsAndDetailsOpenOffline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-watch-fixture", "-watch-reset-group", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["下一次，一起去看海"].waitForExistence(timeout: 10))
        capture("watch-all", app: app)
        app.descendants(matching: .any)["watchCountdownGroup"].firstMatch.tap()
        let category = app.buttons["纪念日"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        if !category.isHittable { app.swipeUp() }
        category.tap()
        XCTAssertTrue(app.staticTexts["和你在一起的日子"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["下一次，一起去看海"].exists)
        app.launchArguments.removeAll { $0 == "-watch-reset-group" }
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["和你在一起的日子"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["下一次，一起去看海"].exists)
        capture("watch-group", app: app)
        app.staticTexts["和你在一起的日子"].tap()
        XCTAssertTrue(app.staticTexts["记下的日子"].waitForExistence(timeout: 5))
        capture("watch-detail", app: app)
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
