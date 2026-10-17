import XCTest

final class CalendarInteractionUITests: XCTestCase {
    private func launchDeletionFixture(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-calendar-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        if app.buttons["section-3"].isHittable { activate(app.buttons["section-3"]) }
        else { activate(app.tabBars.buttons["日历"]) }
        XCTAssertTrue(app.segmentedControls["calendarRange"].waitForExistence(timeout: 8))
        activate(app.segmentedControls["calendarRange"].buttons["当天"])
        return app
    }

    func testDetailDeleteIsLastActionCanCancelAndClosesAfterDeleting() {
        let app = launchDeletionFixture()
        let event = app.buttons["calendarEvent-demo-0"]
        XCTAssertTrue(event.waitForExistence(timeout: 8)); activate(event)
        let delete = app.buttons["deleteCalendarEvent"], convert = app.buttons["calendarEventToCountdown"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(delete.frame.minY, convert.frame.maxY)
        activate(delete)
        let cancel = app.alerts.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); activate(cancel)
        XCTAssertTrue(delete.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "calendar-detail-delete"; shot.lifetime = .keepAlways; add(shot)
        activate(delete); activate(app.alerts.buttons["删除日程"])
        XCTAssertTrue(delete.waitForNonExistence(timeout: 8)); XCTAssertTrue(event.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addCalendarEvent"].isHittable)
    }

    func testReadonlyEventHasNoDeleteAndAllDayEventCanBeDeleted() {
        let app = launchDeletionFixture(["-calendar-all-day-fixture"])
        let allDay = app.buttons["calendarAllDay-all-day-0-0"]
        XCTAssertTrue(allDay.waitForExistence(timeout: 8)); activate(allDay)
        let delete = app.buttons["deleteCalendarEvent"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); activate(delete); activate(app.alerts.buttons["删除日程"])
        XCTAssertTrue(delete.waitForNonExistence(timeout: 8)); XCTAssertTrue(allDay.waitForNonExistence(timeout: 5))
        activate(app.segmentedControls["calendarRange"].buttons["3 天"])
        let readonly = app.buttons["calendarEvent-demo-2"]
        XCTAssertTrue(readonly.waitForExistence(timeout: 8)); activate(readonly)
        XCTAssertTrue(app.buttons["calendarEventToCountdown"].waitForExistence(timeout: 5))
        XCTAssertFalse(delete.exists); XCTAssertFalse(app.buttons["editCalendarEvent"].exists)
    }

    func testDetailDeletionOffersBothRecurringScopesAndKeepsPastEvents() {
        let app = launchDeletionFixture(["-calendar-recurring-fixture"])
        let today = app.buttons["calendarEvent-repeat-0"]
        XCTAssertTrue(today.waitForExistence(timeout: 8)); activate(today)
        activate(app.buttons["deleteCalendarEvent"])
        let current = app.alerts.buttons["仅删除当前这一次"], future = app.alerts.buttons["删除当前及之后"]
        XCTAssertTrue(current.waitForExistence(timeout: 5)); XCTAssertTrue(future.exists)
        activate(future)
        XCTAssertTrue(app.buttons["deleteCalendarEvent"].waitForNonExistence(timeout: 8)); XCTAssertTrue(today.waitForNonExistence(timeout: 5))
        activate(app.buttons["下一页"])
        XCTAssertTrue(app.buttons["calendarEvent-demo-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["calendarEvent-repeat-1"].exists)
        activate(app.buttons["上一页"]); activate(app.buttons["上一页"])
        let previous = app.buttons["calendarEvent-repeat--1"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5)); activate(previous)
        activate(app.buttons["deleteCalendarEvent"]); activate(app.alerts.buttons["仅删除当前这一次"])
        XCTAssertTrue(app.buttons["deleteCalendarEvent"].waitForNonExistence(timeout: 8)); XCTAssertTrue(previous.waitForNonExistence(timeout: 5))
    }

    func testConvertCalendarEventKeepThenDeleteLeavesOneCountdown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-calendar-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.buttons["section-3"].isHittable { activate(app.buttons["section-3"]) }
        else { activate(app.tabBars.buttons["日历"]) }
        activate(app.segmentedControls["calendarRange"].buttons["当天"])
        let event = app.buttons["calendarEvent-demo-0"]
        XCTAssertTrue(event.waitForExistence(timeout: 8)); activate(event)
        let convert = app.buttons["calendarEventToCountdown"]
        XCTAssertTrue(convert.waitForExistence(timeout: 5)); activate(convert)
        let keep = app.buttons["保留日程"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5)); activate(keep)
        XCTAssertTrue(app.staticTexts["倒数日已保存，原日程已保留。"].waitForExistence(timeout: 5))
        activate(convert)
        let delete = app.alerts.buttons["删除日程"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); activate(delete)
        XCTAssertTrue(convert.waitForNonExistence(timeout: 8))
        XCTAssertTrue(event.waitForNonExistence(timeout: 5))
        if app.buttons["section-4"].isHittable { activate(app.buttons["section-4"]) }
        else { activate(app.tabBars.buttons["倒数日"]) }
        XCTAssertTrue(app.staticTexts["1 个日子"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "converted-calendar-countdown"; shot.lifetime = .keepAlways; add(shot)
    }

    func testHorizontalSwipesPageDatesWithoutChangingVerticalScrollBehavior() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-calendar-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sidebar = app.buttons["section-3"]
        if sidebar.isHittable { activate(sidebar) } else { activate(app.tabBars.buttons["日历"]) }
        let timeline = app.scrollViews["calendarTimeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 8))
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyy-MM-dd"
        for (label, days) in [("当天", 1), ("3 天", 3), ("7 天", 7)] {
            activate(app.segmentedControls["calendarRange"].buttons[label])
            let original = try XCTUnwrap(timeline.value as? String)
            let originalEventY = app.buttons["calendarEvent-demo-0"].frame.minY
            let next = format.string(from: try XCTUnwrap(format.date(from: original)).addingTimeInterval(Double(days) * 86400))
            timeline.swipeLeft()
            let paged = NSPredicate { _, _ in timeline.value as? String == next }
            expectation(for: paged, evaluatedWith: timeline); waitForExpectations(timeout: 5)
            timeline.swipeRight()
            let returned = NSPredicate { _, _ in timeline.value as? String == original }
            expectation(for: returned, evaluatedWith: timeline); waitForExpectations(timeout: 5)
            let event = app.buttons["calendarEvent-demo-0"]
            let beforeY = event.frame.minY
            XCTAssertEqual(beforeY, originalEventY, accuracy: 2, "翻页返回后保留纵向滚动位置")
            // Tall iPads can already be at the bottom after the initial 08:00 scroll.
            timeline.swipeDown()
            XCTAssertEqual(timeline.value as? String, original, "上下滚动不能切换日期")
            XCTAssertGreaterThan(event.frame.minY, beforeY + 30, "左右翻页手势不能拦截时间轴的上下滚动")
            timeline.swipeUp()
            XCTAssertEqual(timeline.value as? String, original)
            XCTAssertFalse(app.buttons["finishEditing"].exists, "短滑不能触发新增日程")
        }
        activate(app.buttons["calendarToday"])
        activate(app.segmentedControls["calendarRange"].buttons["当天"])
        let event = app.buttons["calendarEvent-demo-0"]
        for _ in 0..<12 where !event.isHittable {
            let above = event.frame.midY < timeline.frame.midY
            let origin = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.45 : 0.75))
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: above ? 170 : -170)))
        }
        XCTAssertTrue(event.isHittable)
        activate(event)
        XCTAssertTrue(app.navigationBars["日程详情"].waitForExistence(timeout: 5), "翻页后仍可点开日程")
    }

    func testLongHoldAcrossColumnsMovesEventWithoutPaging() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-calendar-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sidebar = app.buttons["section-3"]
        if sidebar.isHittable { activate(sidebar) } else { activate(app.tabBars.buttons["日历"]) }
        activate(app.segmentedControls["calendarRange"].buttons["3 天"])
        let timeline = app.scrollViews["calendarTimeline"]
        let event = app.buttons["calendarEvent-demo-0"]
        XCTAssertTrue(event.waitForExistence(timeout: 8))
        let date = timeline.value as? String, beforeX = event.frame.minX
        let columnWidth = (timeline.frame.width - 42) / 3
        let source = event.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        hold(source, to: source.withOffset(CGVector(dx: columnWidth, dy: 0)))
        let moved = NSPredicate { _, _ in event.exists && event.frame.minX > beforeX + columnWidth * 0.8 }
        expectation(for: moved, evaluatedWith: event); waitForExpectations(timeout: 5)
        XCTAssertEqual(timeline.value as? String, date, "长按拖动已有日程时不能翻页")
        XCTAssertTrue(event.label.contains("10:00"), "横向拖动保留当地时刻")
    }

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
        addUIInterruptionMonitor(withDescription: "Calendar access") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["允许完全访问", "Allow Full Access"])).firstMatch
            if allow.exists { allow.tap(); return true }
            return false
        }
        app.launch()
        let sidebar = app.buttons["section-3"]
        if sidebar.isHittable { activate(sidebar) } else { activate(app.tabBars.buttons["日历"]) }
        if app.buttons["calendarGrantAccess"].isHittable {
            activate(app.buttons["calendarGrantAccess"])
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(
                NSPredicate(format: "label IN %@", ["允许完全访问", "Allow Full Access"])).firstMatch
            if allow.waitForExistence(timeout: 5) { activate(allow) }
            if app.buttons["calendarGrantAccess"].exists { app.tap() }
            XCTAssertTrue(app.buttons["calendarGrantAccess"].waitForNonExistence(timeout: 10), app.debugDescription)
        }
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
