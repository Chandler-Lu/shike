import XCTest

final class CalendarInteractionUITests: XCTestCase {
    func testNativeCreateAllDayThenDeleteInSystemEditorReturnsToCalendar() {
        nativeCreateAndDelete(allDay: true)
    }
    func testNativeCreateTimedEventThenDeleteInSystemEditorReturnsToCalendar() {
        nativeCreateAndDelete(allDay: false)
    }
    private func nativeCreateAndDelete(allDay isAllDay: Bool) {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-native-calendar-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sidebar = app.buttons["section-3"]
        if sidebar.isHittable { activate(sidebar) } else { activate(app.tabBars.buttons["日历"]) }
        if app.buttons["calendarGrantAccess"].isHittable { activate(app.buttons["calendarGrantAccess"]) }
        activate(app.segmentedControls["calendarRange"].buttons["当天"])
        activate(app.buttons["addCalendarEvent"])
        let title = (isAllDay ? "全天删除回归 " : "定时删除回归 ") + UUID().uuidString.prefix(6)
        let field = app.descendants(matching: .any)["eventTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); activate(field); field.typeText(title)
        if isAllDay {
            let allDay = app.switches["全天"]
            allDay.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertEqual(allDay.value as? String, "1")
        }
        activate(app.buttons["finishEditing"])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        let event = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", isAllDay ? "calendarAllDay-" : "calendarEvent-", title)).firstMatch
        let exists = event.waitForExistence(timeout: 8)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = isAllDay ? "native-all-day-created" : "native-timed-created"; shot.lifetime = .keepAlways; add(shot)
        if !exists { print(app.debugDescription) }
        XCTAssertTrue(exists)
        activate(event); activate(app.buttons["editCalendarEvent"])
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); activate(cancel)
        let edit = app.buttons["editCalendarEvent"]
        let returned = NSPredicate { _, _ in edit.isHittable }
        expectation(for: returned, evaluatedWith: edit); waitForExpectations(timeout: 5)
        activate(edit)
        let delete = app.buttons.matching(NSPredicate(format: "label IN %@", ["删除日程", "删除事件", "Delete Event"])).firstMatch
        for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable); activate(delete)
        let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["删除日程", "删除事件", "Delete Event"])).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); activate(confirm)
        let closed = app.buttons["editCalendarEvent"].waitForNonExistence(timeout: 8)
        let deletionShot = XCTAttachment(screenshot: app.screenshot()); deletionShot.name = "native-after-delete"; deletionShot.lifetime = .keepAlways; add(deletionShot)
        XCTAssertTrue(closed)
        XCTAssertTrue(event.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["addCalendarEvent"].isHittable)
        activate(app.buttons["addCalendarEvent"])
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        activate(app.buttons["cancelEditing"])
        #endif
    }
    func testHoldBlankCreatesEventAndHoldEventMovesItsTime() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-calendar-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sidebar = app.buttons["section-3"]
        if sidebar.isHittable { activate(sidebar) } else { activate(app.tabBars.buttons["日历"]) }
        activate(app.segmentedControls["calendarRange"].buttons["当天"])
        let event = app.buttons["calendarEvent-demo-0"]
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        XCTAssertTrue(event.label.contains("10:00"), event.label)
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "calendar-before-drag"; before.lifetime = .keepAlways; add(before)
        let source = event.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = source.withOffset(CGVector(dx: 0, dy: 58))
        hold(source, to: destination)
        let movedShot = XCTAttachment(screenshot: app.screenshot()); movedShot.name = "calendar-drag-result"; movedShot.lifetime = .keepAlways; add(movedShot)
        let moved = NSPredicate { _, _ in event.exists && event.label.contains("11:00") && event.label.contains("12:30") }
        expectation(for: moved, evaluatedWith: event); waitForExpectations(timeout: 8)
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "calendar-after-drag"; after.lifetime = .keepAlways; add(after)
        let blank = event.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 40))
        hold(blank, to: nil)
        let title = app.descendants(matching: .any)["eventTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        activate(title); title.typeText("长按新增验证")
        activate(app.buttons["finishEditing"])
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        let created = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "calendarEvent-", "长按新增验证")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 8))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "calendar-hold-created"; shot.lifetime = .keepAlways; add(shot)
    }

    #if targetEnvironment(macCatalyst)
    func testSidebarBlankAreaSwitchesSection() {
        let app = XCUIApplication(); app.launchArguments = ["-ui-testing"]; app.launch()
        let calendar = app.buttons["section-3"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10))
        calendar.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).click()
        XCTAssertTrue(app.segmentedControls["calendarRange"].waitForExistence(timeout: 5))
        app.buttons["section-2"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["日历偏好"].waitForExistence(timeout: 5))
    }
    #endif
    private func activate(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }
    private func hold(_ source: XCUICoordinate, to destination: XCUICoordinate?) {
        #if targetEnvironment(macCatalyst)
        if let destination { source.click(forDuration: 0.7, thenDragTo: destination) }
        else { source.click(forDuration: 0.7, thenDragTo: source) }
        #else
        if let destination { source.press(forDuration: 0.7, thenDragTo: destination) }
        else { source.press(forDuration: 0.7) }
        #endif
    }
}
