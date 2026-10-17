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
    private func expandSummary(_ app: XCUIApplication) {
        #if !targetEnvironment(macCatalyst)
        let bar = app.navigationBars["日历总结"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        #endif
    }
    func testSearchSettingsAutoSaveAndHomeUnchanged() {
        let app = launch(extra: ["-seed-example"])
        XCTAssertFalse(app.switches["searchEnabled"].exists)
        section(2, name: "设置", app: app)
        let api = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "模型与 API")).firstMatch
        reveal(api, app: app); activate(api)
        let toggle = app.switches["searchEnabled"]
        for _ in 0..<14 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertFalse(app.secureTextFields["searchKey"].exists)
        activate(toggle)
        XCTAssertFalse(app.textFields["searchURL"].exists)
        let key = app.secureTextFields["searchKey"]
        reveal(key, app: app); activate(key); key.typeText("fixture-search-key")
        let hide = app.buttons["收起键盘"]
        if hide.isHittable { activate(hide) }
        let status = app.staticTexts["searchStatus"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "已开启"), evaluatedWith: status)
        waitForExpectations(timeout: 6)
        capture("search-settings-enabled", app: app)
        // Turn off without deleting the configuration, then on again.
        for _ in 0..<8 where !toggle.isHittable { app.swipeDown() }
        activate(toggle)
        XCTAssertFalse(app.secureTextFields["searchKey"].exists)
        activate(toggle)
        XCTAssertTrue(status.label.contains("已开启"))
        if app.buttons["section-0"].isHittable { activate(app.buttons["section-0"]) }
        else { app.tabBars.buttons["计划"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.textViews["sourceText"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["searchEnabled"].exists)
        capture("search-home-unchanged", app: app)
    }

    func testHomeKeyboardKeepsNavigationBarAtTop() {
        let app = launch()
        let source = app.textViews["sourceText"]
        let navigation = app.navigationBars["拾刻计划"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        let originalTop = navigation.frame.minY
        capture("home-before-keyboard", app: app)
        for index in 1...2 {
            activate(source); source.typeText("测试")
            XCTAssertTrue(app.buttons["收起键盘"].waitForExistence(timeout: 5))
            capture("home-keyboard-\(index)", app: app)
            XCTAssertEqual(navigation.frame.minY, originalTop, accuracy: 1, "输入时导航栏不应向下跳动")
            activate(app.buttons["收起键盘"])
            XCTAssertEqual(navigation.frame.minY, originalTop, accuracy: 1)
        }
        XCTAssertEqual(source.value as? String, "测试测试")
        capture("home-after-keyboard", app: app)
    }

    func testSourceTypingAndReferenceDateRefreshKeepInputAfterBackgroundAndExpansion() {
        let app = launch(extra: ["-seed-example", "-store-screenshots"])
        let input = app.textViews["sourceText"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let original = input.value as? String
        let refresh = app.buttons["refreshReferenceDate"]
        let oldReference = refresh.value as? String
        activate(refresh)
        XCTAssertNotEqual(refresh.value as? String, oldReference)
        XCTAssertEqual(input.value as? String, original)
        XCTAssertFalse(app.buttons["allowExtraction"].exists)
        XCTAssertFalse(app.buttons["editEvent-产品设计评审"].exists)
        activate(app.buttons["新建导入"])
        activate(input)
        for (index, text) in ["abc", "def", " 明天下午三点开会"].enumerated() {
            input.typeText(text)
            capture("source-typing-\(index + 1)", app: app)
        }
        XCTAssertEqual(input.value as? String, "abcdef 明天下午三点开会")
        activate(app.buttons["收起键盘"])
        app.buttons["expand-sourceText"].doubleTap()
        let expanded = app.textViews["expanded-sourceText"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        XCTAssertEqual(expanded.value as? String, "abcdef 明天下午三点开会")
        activate(expanded); expanded.typeText("，带笔记")
        activate(app.buttons["collapse-sourceText"])
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "abcdef 明天下午三点开会，带笔记")
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.press(.home); app.activate()
        #endif
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "abcdef 明天下午三点开会，带笔记")
        capture("source-after-resume", app: app)
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

    func testPlanningCalendarSelectionRestartAndSingleKeyboardToolbar() {
        let app = launch(extra: ["-seed-example", "-planning-fixture"])
        let plan = app.buttons["planEvents"]
        XCTAssertTrue(plan.waitForExistence(timeout: 8)); reveal(plan, app: app); activate(plan)
        let range = app.buttons["安排范围与参考日历"]
        XCTAssertTrue(range.waitForExistence(timeout: 5)); activate(range)
        let none = app.buttons["deselectAllCalendars"]
        reveal(none, app: app); activate(none)
        let switches = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendarFilter-"))
        XCTAssertEqual(switches.count, 3)
        for item in switches.allElementsBoundByIndex {
            XCTAssertEqual(item.value as? String, "0")
            XCTAssertGreaterThanOrEqual(item.frame.minX, app.frame.minX + 16)
            XCTAssertLessThanOrEqual(item.frame.maxX, app.frame.maxX - 16)
        }
        capture("planning-calendar-switches", app: app)
        activate(app.buttons["selectAllCalendars"])
        for item in switches.allElementsBoundByIndex { XCTAssertEqual(item.value as? String, "1") }
        activate(none); activate(range)
        let start = app.buttons["startPlanning"]
        reveal(start, app: app); activate(start)
        let option = app.buttons["planningOption-每次 30 分钟，晚上安排"]
        XCTAssertTrue(option.waitForExistence(timeout: 8)); reveal(option, app: app); activate(option)
        let answer = app.textFields["planningAnswer"].exists ? app.textFields["planningAnswer"] : app.textViews["planningAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 8)); reveal(answer, app: app); activate(answer)
        answer.typeText("稍晚一点")
        XCTAssertEqual(app.buttons.matching(identifier: "收起键盘").count, 1)
        capture("planning-single-keyboard-toolbar", app: app)
        activate(app.buttons["收起键盘"])
        activate(app.buttons["restartPlanning"])
        XCTAssertTrue(option.waitForExistence(timeout: 8), "重新安排后应自动从第一个问题开始")
        XCTAssertFalse(app.buttons["planning-editEvent-读书与笔记"].exists)
        XCTAssertFalse(app.staticTexts["前面的问答"].exists)
        XCTAssertFalse(app.textFields["planningGoal"].exists)
        XCTAssertFalse(app.textViews["planningGoal"].exists)
        XCTAssertFalse((answer.value as? String ?? "").contains("稍晚一点"))
        XCTAssertTrue(app.staticTexts["这周想读完一本书，帮我找个安静的时间。"].exists)
        activate(range); reveal(none, app: app)
        for item in switches.allElementsBoundByIndex { XCTAssertEqual(item.value as? String, "0") }
        capture("planning-restarted-with-original-goal", app: app)
    }

    func testSummaryComposerStaysAboveKeyboardWhileTypingAndScrolling() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("Mac 使用硬件键盘，不验证屏幕键盘避让")
        #else
        let app = launch(); section(3, name: "日历", app: app)
        activate(app.buttons["summarizeCalendar"])
        XCTAssertTrue(app.staticTexts["calendarSummaryOverview"].waitForExistence(timeout: 5))
        let input = app.textFields["summaryFollowUpInput"].exists ? app.textFields["summaryFollowUpInput"] : app.textViews["summaryFollowUpInput"]
        let send = app.buttons["sendSummaryFollowUp"]
        let keyboard = app.keyboards.firstMatch
        for index in 1...2 {
            activate(input)
            input.typeText(index == 1 ? "如果明天" : "还有其他安排，应该如何预留休息时间？\n请分上午和下午说明。")
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            capture("summary-keyboard-\(index)", app: app)
            XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY - 4, "输入框必须完整位于键盘上方")
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY - 4, "发送按钮不能被键盘遮挡")
            XCTAssertTrue(send.isHittable)
            let hide = app.buttons["收起键盘"]
            XCTAssertEqual(app.buttons.matching(identifier: "收起键盘").count, 1)
            XCTAssertLessThanOrEqual(hide.frame.maxY, keyboard.frame.minY - 4)
            XCTAssertFalse(hide.frame.intersects(send.frame), "收起键盘不能盖住发送按钮")
            activate(hide)
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
            if index == 1 { app.scrollViews["calendarSummaryScroll"].swipeUp() }
        }
        XCTAssertTrue((input.value as? String)?.contains("请分上午和下午说明") == true)
        activate(input)
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        activate(send)
        XCTAssertTrue(app.staticTexts["summaryQuestion"].waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        #endif
    }

    func testSummaryBannerHidesAndOpensResultAcrossTabsWithFollowUp() {
        let app = launch(extra: ["-summary-delay-fixture", "-summary-routing-fixture"]); section(3, name: "日历", app: app)
        activate(app.buttons["summarizeCalendar"])
        let close = app.buttons["closeCalendarSummary"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        capture("calendar-summary-progress", app: app)
        activate(close)
        section(4, name: "倒数日", app: app)
        let banner = app.buttons["modelJobBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(app.navigationBars["倒数日"].frame.minY, banner.frame.maxY - 1, "提示条不能盖住导航栏")
        #if !targetEnvironment(macCatalyst)
        banner.swipeLeft()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 3))
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "模型结果已就绪"), object: banner)], timeout: 30), .completed)
        activate(banner)
        XCTAssertTrue(app.staticTexts["calendarSummaryOverview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["模型任务"].exists, "直接显示这次总结，不应停在任务列表")
        let question = app.textFields["summaryFollowUpInput"].exists ? app.textFields["summaryFollowUpInput"] : app.textViews["summaryFollowUpInput"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        activate(question); question.typeText("留多久休息？")
        #if !targetEnvironment(macCatalyst)
        XCTAssertEqual(app.buttons.matching(identifier: "收起键盘").count, 1)
        #endif
        activate(app.buttons["sendSummaryFollowUp"])
        XCTAssertTrue(app.staticTexts["pendingSummaryQuestion"].waitForExistence(timeout: 5))
        activate(close)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "模型结果已就绪"), object: banner)], timeout: 30), .completed)
        activate(banner)
        let overview = app.staticTexts["calendarSummaryOverview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertTrue(overview.label.contains("留多久休息？"))
        XCTAssertTrue(app.staticTexts["此前的总结与追问（1）"].exists)
        capture("calendar-summary-followup", app: app)
    }

    func testSummaryReopensWhenCompletedAfterSwipeDismiss() {
        let app = launch(extra: ["-summary-delay-fixture"]); section(3, name: "日历", app: app)
        let summarize = app.buttons["summarizeCalendar"]
        XCTAssertTrue(summarize.waitForExistence(timeout: 8)); activate(summarize)
        let close = app.buttons["closeCalendarSummary"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let bar = app.navigationBars["日历总结"]
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["calendarSummaryOverview"].waitForExistence(timeout: 12))
        expandSummary(app)
        capture("calendar-summary-restored", app: app)
        let plain = app.buttons["copySummaryPlain"].firstMatch; reveal(plain, app: app); activate(plain)
        XCTAssertTrue(app.staticTexts["已复制纯文本"].waitForExistence(timeout: 3))
        activate(app.buttons["copySummaryMarkdown"].firstMatch)
        XCTAssertTrue(app.staticTexts["已复制 Markdown"].waitForExistence(timeout: 3))
        activate(close)
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        XCTAssertTrue(summarize.isHittable)
    }

    func testSummaryOpensDirectlyAndCopiesBothFormats() {
        let app = launch(); section(3, name: "日历", app: app)
        let summarize = app.buttons["summarizeCalendar"]
        XCTAssertTrue(summarize.waitForExistence(timeout: 8)); activate(summarize)
        XCTAssertTrue(app.staticTexts["calendarSummaryOverview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["allowExtraction"].exists)
        capture("calendar-summary-bottom-sheet", app: app)
        expandSummary(app)
        capture("calendar-summary-expanded", app: app)
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
        section(0, name: "计划", app: app)
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
        section(2, name: "设置", app: app); section(0, name: "计划", app: app)
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
    func testCountdownDetailCyclesUnitsAndResetsAfterClosing() {
        let app = launch(); section(4, name: "倒数日", app: app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "countdown-", "下一次，一起去看海")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5)); activate(card)
        let count = app.buttons["cycleCountdownUnit"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "还有 12 天")
        activate(count); XCTAssertEqual(count.label, "还有 1 周 5 天")
        activate(count); XCTAssertEqual(count.label, "还有 0 个月 12 天")
        activate(count); XCTAssertEqual(count.label, "还有 0 年 12 天")
        capture("countdown-detail-years", app: app)
        let share = app.buttons["exportCountdownImage"]; reveal(share, app: app); activate(share)
        let exported = app.descendants(matching: .any)["exportCountdownCount"].firstMatch
        XCTAssertTrue(exported.waitForExistence(timeout: 5))
        XCTAssertEqual(exported.label, "还有 0 年 12 天")
        capture("countdown-export-years", app: app)
        let choose = app.buttons["chooseCountdownArtwork"]; reveal(choose, app: app); activate(choose)
        let cat = app.buttons["countdownArt-cat-01"]; reveal(cat, app: app); activate(cat)
        XCTAssertTrue(exported.waitForExistence(timeout: 5)); XCTAssertEqual(exported.label, "还有 0 年 12 天")
        activate(app.buttons["closeCountdownExport"])
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "还有 0 年 12 天")
        reveal(count, app: app)
        activate(count); XCTAssertEqual(count.label, "还有 12 天")
        activate(count); XCTAssertEqual(count.label, "还有 1 周 5 天")
        activate(app.buttons["closeCountdownDetail"])
        XCTAssertTrue(count.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("12 天")); activate(card)
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "还有 12 天")
    }
    func testHistoryPullSearchAndHoldToDeleteMultipleRecords() {
        #if !targetEnvironment(macCatalyst)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let app = launch(extra: ["-history-fixture"])
        section(1, name: "记录", app: app)
        func card(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "history-", title)).firstMatch
        }
        let first = card("阅读记录"), second = card("旅行记录"), kept = card("保留记录")
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists); XCTAssertTrue(kept.exists)
        let search = app.textFields["historySearch"]
        XCTAssertFalse(search.exists)
        #if targetEnvironment(macCatalyst)
        activate(app.buttons["搜索记录"])
        #else
        let list = app.scrollViews["historyList"]
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).press(forDuration: 0.05,
            thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        #endif
        XCTAssertTrue(search.waitForExistence(timeout: 5)); activate(search); search.typeText("旅行")
        XCTAssertTrue(second.exists); XCTAssertFalse(first.exists); XCTAssertFalse(kept.exists)
        capture("history-pull-search", app: app)
        activate(app.buttons["closeHistorySearch"])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        hold(first, app: app)
        XCTAssertTrue(app.buttons["finishHistorySelection"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["这一页安排"].exists)
        XCTAssertEqual(first.value as? String, "已选择")
        activate(second)
        XCTAssertEqual(app.staticTexts["historySelectionCount"].label, "已选择 2 条记录")
        activate(app.buttons["selectAllHistory"]); activate(kept)
        XCTAssertEqual(app.staticTexts["historySelectionCount"].label, "已选择 2 条记录")
        activate(app.buttons["deleteSelectedHistory"]); activate(app.alerts.buttons["取消"])
        XCTAssertTrue(first.exists); XCTAssertTrue(second.exists)
        capture("history-multiple-selection", app: app)
        activate(app.buttons["deleteSelectedHistory"]); activate(app.alerts.buttons["删除"].firstMatch)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5)); XCTAssertFalse(second.exists); XCTAssertTrue(kept.exists)
        XCTAssertFalse(app.buttons["finishHistorySelection"].exists)
        section(0, name: "计划", app: app); section(1, name: "记录", app: app)
        XCTAssertFalse(first.exists); XCTAssertFalse(second.exists, "删除当前导入后，切换页面不能重新保存该记录")
        hold(kept, app: app); activate(kept)
        XCTAssertEqual(app.staticTexts["historySelectionCount"].label, "已选择 0 条记录")
        XCTAssertFalse(app.buttons["deleteSelectedHistory"].isEnabled)
        activate(app.buttons["finishHistorySelection"])
        activate(kept)
        XCTAssertTrue(app.staticTexts["原文"].waitForExistence(timeout: 5))
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
