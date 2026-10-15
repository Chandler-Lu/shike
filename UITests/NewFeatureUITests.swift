import XCTest

final class NewFeatureUITests: XCTestCase {
    private func launch(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-calendar-fixture", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch(); return app
    }
    private func activate(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }
    private func section(_ id: Int, name: String, app: XCUIApplication) {
        let sidebar = app.buttons["section-\(id)"]
        if sidebar.isHittable { activate(sidebar) } else { activate(app.tabBars.buttons[name]) }
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testAPIStreamingDiagnosticsAndCancellation() {
        let app = launch(extra: ["-api-stream-fixture"])
        func show(_ element: XCUIElement) {
            for _ in 0..<20 {
                let frame = element.frame
                if element.isHittable && frame.minY > 140 && frame.maxY < app.frame.maxY - 145 { return }
                let down = frame.minY < 140
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: down ? 0.3 : 0.7))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: down ? 0.7 : 0.3))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("Control not visible: " + element.identifier + "\n" + app.debugDescription)
        }
        section(2, name: "设置", app: app)
        let api = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "模型与 API")).firstMatch
        show(api); activate(api)
        let test = app.buttons["testAPI"]
        show(test); activate(test)
        XCTAssertTrue(app.staticTexts["连接成功，模型已返回可读取的日程。"].waitForExistence(timeout: 8))
        let diagnostics = app.buttons["apiDiagnostics"]
        show(diagnostics); capture("api-diagnostics-collapsed", app: app); activate(diagnostics)
        let copy = app.buttons["copyAPIDiagnostics"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3), app.debugDescription)
        show(copy); activate(copy)
        capture("api-streaming-diagnostics", app: app)
        // Collapse before retesting so the test button remains visible on a compact screen.
        show(diagnostics); activate(diagnostics)
        show(test); activate(test)
        XCTAssertEqual(test.label, "取消测试")
        activate(test)
        XCTAssertTrue(app.staticTexts["已取消测试。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["apiDiagnostics"].exists)
    }

    func testSummaryOpensDirectlyAndCopiesBothFormats() {
        let app = launch(); section(3, name: "日历", app: app)
        let summarize = app.buttons["summarizeCalendar"]
        XCTAssertTrue(summarize.waitForExistence(timeout: 8)); activate(summarize)
        XCTAssertTrue(app.staticTexts["calendarSummaryOverview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["allowExtraction"].exists)
        capture("calendar-summary-bottom-sheet", app: app)
        let plain = app.buttons["copySummaryPlain"].firstMatch; reveal(plain, app: app); activate(plain)
        XCTAssertTrue(app.staticTexts["已复制纯文本"].waitForExistence(timeout: 3))
        activate(app.buttons["copySummaryMarkdown"].firstMatch)
        XCTAssertTrue(app.staticTexts["已复制 Markdown"].waitForExistence(timeout: 3))
    }
    private func hold(_ element: XCUIElement, app: XCUIApplication) {
        reveal(element, app: app)
        #if targetEnvironment(macCatalyst)
        let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        coordinate.click(forDuration: 0.8, thenDragTo: coordinate)
        #else
        element.press(forDuration: 0.8)
        #endif
    }
    func testInlineVoiceAppendsWithoutAutomaticallyParsingAndKeepsEdits() {
        let app = launch(extra: ["-seed-example", "-voice-fixture"])
        let input = app.textViews["sourceText"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let original = input.value as? String ?? ""
        let mic = app.buttons["voiceInput"]
        let expand = app.buttons["expand-sourceText"]
        XCTAssertLessThan(mic.frame.midX, expand.frame.midX)
        XCTAssertEqual(mic.frame.midY, expand.frame.midY, accuracy: 2)
        activate(mic)
        let transcribed = NSPredicate { _, _ in (input.value as? String ?? "").contains("明天下午三点开会，地点在三楼。") }
        expectation(for: transcribed, evaluatedWith: input); waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, original + "\n\n明天下午三点开会，地点在三楼。")
        XCTAssertEqual(mic.label, "停止语音输入")
        XCTAssertFalse(app.buttons["parseEvents"].isEnabled)
        XCTAssertFalse(app.textViews["voiceTranscript"].exists)
        XCTAssertFalse(app.buttons["editEvent-产品设计评审"].exists)
        capture("inline-voice-recording", app: app)
        activate(mic)
        XCTAssertTrue(app.staticTexts["voiceInputStatus"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(input.isEnabled)
        activate(input); input.typeText("补充备注")
        let edited = input.value as? String
        if app.buttons["收起键盘"].isHittable { activate(app.buttons["收起键盘"]) }
        section(2, name: "设置", app: app)
        XCTAssertTrue(app.staticTexts["日历偏好"].waitForExistence(timeout: 5))
        section(0, name: "导入", app: app)
        XCTAssertEqual(input.value as? String, edited)
        let extract = app.buttons["parseEvents"]; reveal(extract, app: app); activate(extract)
        XCTAssertTrue(app.buttons["editEvent-产品设计评审"].waitForExistence(timeout: 8))
    }
    func testInlineVoiceFromEmptyInputStopsWhenLeavingPage() {
        let app = launch(extra: ["-voice-fixture"])
        let input = app.textViews["sourceText"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["parseEvents"].isEnabled)
        activate(app.buttons["voiceInput"])
        let transcribed = NSPredicate { _, _ in (input.value as? String ?? "").contains("地点在三楼") }
        expectation(for: transcribed, evaluatedWith: input); waitForExpectations(timeout: 5)
        section(2, name: "设置", app: app); section(0, name: "导入", app: app)
        XCTAssertEqual(app.buttons["voiceInput"].label, "语音输入")
        XCTAssertEqual(input.value as? String, "明天下午三点开会，地点在三楼。")
        XCTAssertFalse(app.staticTexts["voiceInputStatus"].exists)
        XCTAssertFalse(app.buttons["editEvent-产品设计评审"].exists)
        let plan = app.buttons["planEvents"]; reveal(plan, app: app); activate(plan)
        XCTAssertTrue(app.buttons["startPlanning"].waitForExistence(timeout: 5))
    }
    func testUsageTipsLivesAbovePrivacyAndOpensShortcutGuide() {
        let app = launch()
        XCTAssertTrue(app.textViews["sourceText"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["voiceInput"].exists)
        XCTAssertFalse(app.buttons["shortcutGuide"].exists)
        section(2, name: "设置", app: app)
        let tips = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "使用技巧")).firstMatch
        reveal(tips, app: app)
        let privacy = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "关于内容与隐私")).firstMatch
        XCTAssertTrue(privacy.exists)
        XCTAssertLessThan(tips.frame.minY, privacy.frame.minY)
        activate(tips)
        XCTAssertTrue(app.staticTexts["sharingTip"].waitForExistence(timeout: 5))
        let guide = app.buttons["shortcutGuide"]; reveal(guide, app: app)
        capture("settings-usage-tips", app: app); activate(guide)
        XCTAssertTrue(app.staticTexts["把当前页面，变成安排"].waitForExistence(timeout: 5))
    }
    func testShortcutInputAutomaticallyExtractsIntoReviewableDrafts() {
        let app = launch(extra: ["-shortcut-fixture"])
        XCTAssertTrue(app.buttons["editEvent-产品设计评审"].waitForExistence(timeout: 12))
        section(1, name: "记录", app: app)
        XCTAssertTrue(app.staticTexts["2 个日程，0 个已加入日历"].waitForExistence(timeout: 5))
    }
    func testSharingCardSelectsCatArtwork() {
        let app = launch(); section(4, name: "倒数日", app: app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5)); activate(card)
        let share = app.buttons["exportCountdownImage"]; reveal(share, app: app); activate(share)
        let choose = app.buttons["chooseCountdownArtwork"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); reveal(choose, app: app)
        XCTAssertFalse(app.buttons["saveCountdownPNG"].exists)
        XCTAssertFalse(app.staticTexts["选择插画"].exists)
        capture("countdown-tap-illustration", app: app); activate(choose)
        XCTAssertEqual(app.segmentedControls.count, 0)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "原图")).firstMatch.exists)
        let cat = app.buttons["countdownArt-cat-01"]
        reveal(cat, app: app); capture("countdown-artwork-picker", app: app); activate(cat)
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertTrue(choose.label.contains("缅因猫"), choose.label)
        capture("countdown-card-selected-artwork", app: app)
    }
    func testCountdownHoldSelectsMultipleAndMovesThenDeletesOnlySelection() {
        let app = launch(); section(4, name: "倒数日", app: app)
        func card(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "countdown-", title)).firstMatch
        }
        let first = card("下一次，一起去看海"), second = card("每年的小小纪念")
        XCTAssertTrue(first.waitForExistence(timeout: 5)); hold(first, app: app)
        XCTAssertTrue(app.buttons["finishCountdownSelection"].waitForExistence(timeout: 5))
        XCTAssertEqual(first.value as? String, "已选择")
        reveal(second, app: app); activate(second)
        XCTAssertEqual(app.staticTexts["countdownSelectionCount"].label, "已选择 2 个日子")
        activate(app.buttons["moveSelectedCountdowns"]); activate(app.buttons["工作"].firstMatch)
        XCTAssertTrue(app.buttons["finishCountdownSelection"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(first.label.contains("工作")); XCTAssertTrue(second.label.contains("工作"))
        // Select from the current scroll position, then select all and deselect one.
        hold(second, app: app)
        activate(app.buttons["selectAllCountdowns"])
        let untouched = card("和你在一起的日子"); reveal(untouched, app: app); activate(untouched)
        XCTAssertEqual(app.staticTexts["countdownSelectionCount"].label, "已选择 2 个日子")
        activate(app.buttons["deleteSelectedCountdowns"])
        activate(app.alerts.buttons["取消"])
        XCTAssertTrue(first.exists); XCTAssertTrue(second.exists)
        capture("countdown-multiple-selection", app: app)
        activate(app.buttons["deleteSelectedCountdowns"])
        activate(app.alerts.buttons["删除"].firstMatch)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertFalse(second.exists); XCTAssertTrue(untouched.exists)
        XCTAssertFalse(app.buttons["finishCountdownSelection"].exists)
        for layout in ["double", "strip"] {
            let menu = app.buttons["countdownLayout"]; reveal(menu, app: app); activate(menu)
            activate(app.buttons["countdownLayout-\(layout)"])
            hold(untouched, app: app)
            XCTAssertEqual(untouched.value as? String, "已选择")
            activate(untouched)
            XCTAssertEqual(app.staticTexts["countdownSelectionCount"].label, "已选择 0 个日子")
            XCTAssertFalse(app.buttons["deleteSelectedCountdowns"].isEnabled)
            activate(app.buttons["finishCountdownSelection"])
        }
    }
    func testAllDayEventsRemainVisibleAcrossRangesAndScroll() {
        let app = launch(extra: ["-calendar-all-day-fixture"]); section(3, name: "日历", app: app)
        let range = app.segmentedControls["calendarRange"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        for title in ["当天", "3 天", "7 天"] {
            activate(range.buttons[title])
            for index in 0..<2 {
                let event = app.buttons["calendarAllDay-all-day-\(index)-0"]
                XCTAssertTrue(event.waitForExistence(timeout: 5)); XCTAssertTrue(event.isHittable)
            }
            if title != "当天" {
                XCTAssertTrue(app.buttons["calendarAllDay-all-day-0-1"].exists)
                XCTAssertFalse(app.buttons["calendarAllDay-all-day-0-2"].exists)
            }
            capture("all-day-\(title)", app: app)
        }
        activate(range.buttons["当天"])
        let allDayArea = app.scrollViews["calendarAllDayEvents"]
        XCTAssertLessThanOrEqual(allDayArea.frame.height, 60)
        activate(app.buttons["expandAllDayEvents"])
        let fourth = app.buttons["calendarAllDay-all-day-3-0"]
        XCTAssertTrue(fourth.isHittable); activate(fourth)
        XCTAssertTrue(app.staticTexts["第四条全天日程"].waitForExistence(timeout: 5))
    }
    func testDraggingSecondAllDayEventMovesOnlyThatEvent() {
        let app = launch(extra: ["-calendar-all-day-fixture"]); section(3, name: "日历", app: app)
        activate(app.segmentedControls["calendarRange"].buttons["3 天"])
        let original = app.buttons["calendarAllDay-all-day-1-0"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let nextColumn = app.buttons["calendarAllDay-all-day-0-1"]
        let source = original.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = source.withOffset(CGVector(dx: nextColumn.frame.midX - original.frame.midX, dy: 0))
        #if targetEnvironment(macCatalyst)
        source.click(forDuration: 0.7, thenDragTo: target)
        #else
        source.press(forDuration: 0.7, thenDragTo: target)
        #endif
        XCTAssertTrue(app.buttons["calendarAllDay-all-day-1-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(original.exists)
        XCTAssertTrue(app.buttons["calendarAllDay-all-day-0-0"].exists)
        XCTAssertTrue(app.buttons["calendarAllDay-all-day-2-0"].exists)
        capture("all-day-second-row-moved", app: app)
    }
}
