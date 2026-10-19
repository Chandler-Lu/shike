import XCTest

final class PlatformWorkspaceUITests: XCTestCase {
    func testExtractionAndReextractionScrollToResultsHeading() {
        let app = launch()
        let parse = app.buttons["parseEvents"]
        reveal(parse, app: app); parse.activateControl()
        let heading = app.staticTexts["importResultsHeading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(heading.isHittable, "无需手动滚动即可看见整理结果")
        XCTAssertLessThan(heading.frame.maxY, app.frame.midY)
        let firstPosition = heading.frame.minY
        capture("extraction-auto-scroll", app)

        reveal(parse, app: app); parse.activateControl()
        XCTAssertTrue(app.buttons["editEvent-产品设计评审"].waitForExistence(timeout: 10))
        XCTAssertTrue(heading.isHittable)
        XCTAssertEqual(heading.frame.minY, firstPosition, accuracy: 4, "重新提取应回到同一标题位置")
        capture("reextraction-auto-scroll", app)
    }

    func testInlineSuccessUsesExistingMessagesWithoutFloatingCard() {
        let app = launch()
        let parse = app.buttons["parseEvents"]; reveal(parse, app: app); parse.activateControl()
        let ignore = app.buttons["取消选择 和小林喝咖啡"]
        XCTAssertTrue(ignore.waitForExistence(timeout: 10)); reveal(ignore, app: app); ignore.activateControl()
        let calendar = app.buttons["saveEvents"]
        reveal(calendar, app: app); calendar.activateControl()
        assertSuccessFeedback("已加入日历", app: app)
        let select = app.buttons["选择 产品设计评审"]
        for _ in 0..<8 where !select.isHittable {
            if select.frame.minY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(select.isHittable); select.activateControl()
        let convert = app.buttons["saveCountdowns"]
        reveal(convert, app: app)
        XCTAssertTrue(app.staticTexts["destinationCompletion"].exists, "继续选择时保留下方已加入数量")
        XCTAssertTrue(convert.isEnabled)
        convert.activateControl()
        assertSuccessFeedback("已加入倒数日", app: app)
        section(4, "倒数日", app: app)
        section(0, "计划", app: app)
        XCTAssertFalse(app.descendants(matching: .any)["importSuccessFeedback"].exists)
    }

    private func assertSuccessFeedback(_ title: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.descendants(matching: .any)["importSuccessFeedback"].exists, "成功反馈应在原提示条内，不出现浮层", file: file, line: line)
        let destination = title == "已加入日历" ? "日历" : "倒数日"
        let message = app.staticTexts["destinationCompletion"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(app.staticTexts.matching(identifier: "destinationCompletion").count, 1, file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any)["statusMessage"].exists, "成功后不能同时出现顶部提示", file: file, line: line)
        // Move only from the test, as a user would; the app must not scroll to feedback itself.
        for _ in 0..<8 where !message.isHittable {
            if message.frame.minY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(message.isHittable, file: file, line: line)
        let text = message.label + message.staticTexts.allElementsBoundByIndex.map(\.label).joined()
        XCTAssertTrue(text.contains(destination), file: file, line: line)
        let frame = message.frame
        capture("inline-success-\(title)", app)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(message.exists, "强调结束后保留提示", file: file, line: line)
        XCTAssertEqual(message.frame.minY, frame.minY, accuracy: 2, "高亮不移动提示条", file: file, line: line)
    }

    func testDraftCardSelectionAndActionsStayIndependent() {
        let app = launch()
        let parse = app.buttons["parseEvents"]; reveal(parse, app: app); parse.activateControl()
        let edit = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); reveal(edit, app: app)
        let selected = app.buttons["取消选择 产品设计评审"]
        let menu = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "eventActions-")).firstMatch
        XCTAssertGreaterThanOrEqual(selected.frame.width, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        XCTAssertLessThanOrEqual(selected.frame.maxX, edit.frame.minX)
        XCTAssertLessThanOrEqual(edit.frame.maxX, menu.frame.minX)
        capture("draft-card-selected", app)

        // Click below the checkbox to exercise the entire selection column.
        let lowerColumn = selected.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        #if targetEnvironment(macCatalyst)
        lowerColumn.click()
        #else
        lowerColumn.tap()
        #endif
        let unselected = app.buttons["选择 产品设计评审"]
        XCTAssertTrue(unselected.waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["eventTitle"].exists)
        capture("draft-card-unselected", app)
        edit.activateControl()
        XCTAssertTrue(app.textFields["eventTitle"].waitForExistence(timeout: 5))
        app.buttons["finishEditing"].activateControl()
        XCTAssertTrue(unselected.waitForExistence(timeout: 5))
        menu.activateControl()
        app.buttons["修改"].activateControl()
        XCTAssertTrue(app.textFields["eventTitle"].waitForExistence(timeout: 5))
        app.buttons["finishEditing"].activateControl()
        XCTAssertTrue(unselected.waitForExistence(timeout: 5))
        menu.activateControl()
        app.buttons["移除草稿"].activateControl()
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["取消选择 和小林喝咖啡"].exists)
    }

    func testDraftCardsShowLongTextAndSeparateReviewIssues() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-review-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let parse = app.buttons["parseEvents"]
        XCTAssertTrue(parse.waitForExistence(timeout: 10)); reveal(parse, app: app); parse.activateControl()
        let edit = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); reveal(edit, app: app); edit.activateControl()
        let suffix = "：讨论跨团队协作方案与下一阶段的日程安排"
        let title = app.textFields["eventTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.activateControl(); title.typeText(suffix)
        let editedTitle = title.value as? String ?? ""
        XCTAssertTrue(editedTitle.contains(suffix))
        app.buttons["finishEditing"].activateControl()
        let longEdit = app.buttons["editEvent-\(editedTitle)"]
        XCTAssertTrue(longEdit.waitForExistence(timeout: 5)); reveal(longEdit, app: app); longEdit.activateControl()
        let location = app.textFields["eventLocation"]
        reveal(location, app: app); location.activateControl(); location.typeText("，靠近东侧入口的项目讨论区，请从访客通道进入")
        app.buttons["finishEditing"].activateControl()
        XCTAssertTrue(longEdit.waitForExistence(timeout: 5)); reveal(longEdit, app: app)
        XCTAssertLessThanOrEqual(longEdit.frame.maxX, app.frame.maxX)
        capture("draft-card-long-text", app)
        let missingCalendar = app.staticTexts["请选择日历"].firstMatch
        reveal(missingCalendar, app: app)
        capture("draft-card-missing-fields", app)
    }

    func testCompletionFooterNamesCountdownAndBothDestinations() {
        let app = launch()
        let parse = app.buttons["parseEvents"]; reveal(parse, app: app); parse.activateControl()
        let convert = app.buttons["saveCountdowns"]
        XCTAssertTrue(convert.waitForExistence(timeout: 10)); reveal(convert, app: app); convert.activateControl()
        let confirmDate = app.buttons["confirmConversionDate"]
        XCTAssertTrue(confirmDate.waitForExistence(timeout: 5)); reveal(confirmDate, app: app); confirmDate.activateControl()
        XCTAssertTrue(confirmDate.waitForNonExistence(timeout: 5))
        assertSuccessFeedback("已加入倒数日", app: app)
        let countdownDone = app.staticTexts["全部日程已加入倒数日。"]
        XCTAssertTrue(countdownDone.waitForExistence(timeout: 5)); reveal(countdownDone, app: app)
        XCTAssertFalse(app.staticTexts["全部日程已加入日历。"].exists)
        capture("completion-countdowns", app)
        for title in ["产品设计评审", "和小林喝咖啡"] {
            let select = app.buttons["选择 \(title)"]
            for _ in 0..<6 where !select.isHittable { app.swipeDown() }
            XCTAssertTrue(select.isHittable); select.activateControl()
        }
        let calendar = app.buttons["saveEvents"]; reveal(calendar, app: app); calendar.activateControl()
        let review = app.buttons["confirmReview"]
        XCTAssertTrue(review.waitForExistence(timeout: 5)); reveal(review, app: app); review.activateControl()
        XCTAssertTrue(review.waitForNonExistence(timeout: 8))
        assertSuccessFeedback("已加入日历", app: app)
        XCTAssertTrue(app.staticTexts["全部日程已加入日历和倒数日。"].waitForExistence(timeout: 8))
    }

    func testCalendarFirstDraftCanBeSelectedAgainForCountdown() {
        let app = launch()
        let parse = app.buttons["parseEvents"]; reveal(parse, app: app); parse.activateControl()
        let ignore = app.buttons["取消选择 和小林喝咖啡"]
        XCTAssertTrue(ignore.waitForExistence(timeout: 10)); reveal(ignore, app: app); ignore.activateControl()
        let calendar = app.buttons["saveEvents"]
        reveal(calendar, app: app); calendar.activateControl()
        XCTAssertTrue(app.staticTexts["已加入日历 1 个。"].waitForExistence(timeout: 8))
        let select = app.buttons["选择 产品设计评审"]
        XCTAssertTrue(select.waitForExistence(timeout: 5)); reveal(select, app: app); select.activateControl()
        let convert = app.buttons["saveCountdowns"]
        reveal(convert, app: app)
        XCTAssertTrue(convert.isEnabled); XCTAssertFalse(calendar.isEnabled)
        XCTAssertEqual(convert.value as? String, "已选择 1 个日程")
        capture("calendar-first-countdown-actions", app)
        convert.activateControl()
        XCTAssertTrue(convert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(select.exists, "加入倒数日后应取消勾选，但仍可再次选择")
        reveal(select, app: app); select.activateControl()
        reveal(convert, app: app)
        XCTAssertFalse(convert.isEnabled); XCTAssertFalse(calendar.isEnabled, "两个位置都已加入时两个按钮均不可重复使用")
        section(4, "倒数日", app: app)
        XCTAssertTrue(app.staticTexts["4 个日子"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "countdown-", "产品设计评审")).firstMatch.exists)
    }

    func testDraftConversionKeepsSelectionIndependentAndUsesQuarterWidthAction() {
        let app = launch()
        XCTAssertTrue(app.buttons["section-0"].exists || app.tabBars.buttons["计划"].exists || app.buttons["计划"].firstMatch.exists)
        let parse = app.buttons["parseEvents"]; reveal(parse, app: app); parse.activateControl()
        let ignore = app.buttons["取消选择 和小林喝咖啡"]
        XCTAssertTrue(ignore.waitForExistence(timeout: 10)); reveal(ignore, app: app); ignore.activateControl()
        let convert = app.buttons["saveCountdowns"], calendar = app.buttons["saveEvents"]
        reveal(convert, app: app)
        XCTAssertEqual(calendar.frame.width / convert.frame.width, 3, accuracy: 0.08)
        XCTAssertGreaterThanOrEqual(convert.frame.height, 44)
        capture("conversion-actions", app)
        convert.activateControl()
        XCTAssertTrue(convert.waitForNonExistence(timeout: 5))
        let select = app.buttons["选择 产品设计评审"]
        reveal(select, app: app); select.activateControl()
        reveal(convert, app: app)
        XCTAssertFalse(convert.isEnabled); XCTAssertTrue(calendar.isEnabled)
        let second = app.buttons["选择 和小林喝咖啡"]
        reveal(second, app: app); second.activateControl()
        reveal(convert, app: app)
        XCTAssertTrue(convert.isEnabled)
        XCTAssertEqual(convert.value as? String, "已选择 1 个日程", "混合选择只处理未加入的项目")
        convert.activateControl()
        let confirm = app.buttons["confirmConversionDate"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); reveal(confirm, app: app); confirm.activateControl()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        reveal(convert, app: app)
        XCTAssertFalse(convert.isEnabled); XCTAssertTrue(calendar.isEnabled)
        XCTAssertTrue(app.buttons["取消选择 产品设计评审"].exists, "跳过的项目保留勾选")
        XCTAssertTrue(second.exists, "新加入的项目取消勾选")
        section(4, "倒数日", app: app)
        XCTAssertTrue(app.staticTexts["5 个日子"].waitForExistence(timeout: 5), "已加入的项目不能重复创建")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "countdown-", "产品设计评审")).firstMatch.exists)
        capture("conversion-countdown", app)
    }

    func testPlanningProposalCanBeAddedToCountdowns() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-planning-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let plan = app.buttons["planEvents"]; XCTAssertTrue(plan.waitForExistence(timeout: 10)); reveal(plan, app: app); plan.activateControl()
        let start = app.buttons["startPlanning"]; XCTAssertTrue(start.waitForExistence(timeout: 5)); reveal(start, app: app); start.activateControl()
        let option = app.buttons["planningOption-每次 30 分钟，晚上安排"]
        XCTAssertTrue(option.waitForExistence(timeout: 10)); reveal(option, app: app); option.activateControl()
        let convert = app.buttons["planning-saveCountdowns"]
        XCTAssertTrue(convert.waitForExistence(timeout: 10)); reveal(convert, app: app); convert.activateControl()
        assertSuccessFeedback("已加入倒数日", app: app)
        XCTAssertTrue(convert.waitForNonExistence(timeout: 5))
        app.buttons["closePlanning"].activateControl()
        section(4, "倒数日", app: app)
        XCTAssertTrue(app.staticTexts["1 个日子"].waitForExistence(timeout: 5))
    }

    func testCountdownConversionReviewConfirmsOnlyDate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-review-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let parse = app.buttons["parseEvents"]; XCTAssertTrue(parse.waitForExistence(timeout: 10)); reveal(parse, app: app); parse.activateControl()
        let ignore = app.buttons["取消选择 "]
        XCTAssertTrue(ignore.waitForExistence(timeout: 10)); reveal(ignore, app: app); ignore.activateControl()
        let convert = app.buttons["saveCountdowns"]; reveal(convert, app: app); convert.activateControl()
        let confirm = app.buttons["confirmConversionDate"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); reveal(confirm, app: app)
        capture("conversion-date-review", app); confirm.activateControl()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        section(4, "倒数日", app: app)
        XCTAssertTrue(app.staticTexts["1 个日子"].waitForExistence(timeout: 5))
    }

    func testCountdownReviewAdvancesBetweenDatesAndKeepsValidationOnCurrentPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-review-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let parse = app.buttons["parseEvents"]
        XCTAssertTrue(parse.waitForExistence(timeout: 10)); reveal(parse, app: app); parse.activateControl()
        let convert = app.buttons["saveCountdowns"]
        XCTAssertTrue(convert.waitForExistence(timeout: 10)); reveal(convert, app: app); convert.activateControl()
        let confirm = app.buttons["confirmConversionDate"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["核对日期 1 / 2"].exists)
        let firstTitle = app.textFields["conversionTitle"]
        firstTitle.activateControl(); firstTitle.typeText("已核对")
        let editedTitle = firstTitle.value as? String ?? ""
        XCTAssertTrue(editedTitle.contains("已核对"))
        reveal(confirm, app: app); confirm.activateControl()
        XCTAssertTrue(app.navigationBars["核对日期 2 / 2"].waitForExistence(timeout: 5))
        XCTAssertFalse((app.textFields["conversionTitle"].value as? String ?? "").contains("已核对"))
        reveal(confirm, app: app); confirm.activateControl()
        XCTAssertTrue(app.staticTexts["请补充开始日期。"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["核对日期 2 / 2"].exists)
        let title = app.textFields["conversionTitle"]
        for _ in 0..<6 where !title.isHittable { app.swipeDown() }
        title.activateControl(); title.typeText("第二个日子")
        let today = app.buttons["conversionUseToday"]
        reveal(today, app: app); today.activateControl()
        reveal(confirm, app: app); confirm.activateControl()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        assertSuccessFeedback("已加入倒数日", app: app)
        section(4, "倒数日", app: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "countdown-", editedTitle)).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "countdown-", "第二个日子")).firstMatch.exists)
    }

    func testConversionActionsFitWithAccessibilityTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let parse = app.buttons["parseEvents"]
        XCTAssertTrue(parse.waitForExistence(timeout: 10)); reveal(parse, app: app); parse.activateControl()
        let edit = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); reveal(edit, app: app)
        XCTAssertLessThanOrEqual(edit.frame.maxX, app.frame.maxX)
        capture("draft-card-accessibility", app)
        let convert = app.buttons["saveCountdowns"], calendar = app.buttons["saveEvents"]
        XCTAssertTrue(convert.waitForExistence(timeout: 10)); reveal(convert, app: app)
        XCTAssertEqual(calendar.frame.width / convert.frame.width, 3, accuracy: 0.08)
        XCTAssertGreaterThanOrEqual(convert.frame.height, 44)
        XCTAssertLessThanOrEqual(convert.frame.maxX, calendar.frame.minX)
        XCTAssertGreaterThanOrEqual(convert.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(calendar.frame.maxX, app.frame.maxX)
        capture("conversion-accessibility-actions", app)
    }

    /// Reproducible, public examples for promotion; never reads personal data or calls an API.
    func testPromotionWorkspace() {
        continueAfterFailure = false
        #if !targetEnvironment(macCatalyst)
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-planning-fixture", "-promotion-search-fixture", "-countdown-fixture", "-promotion-colors", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.textViews["sourceText"].waitForExistence(timeout: 15))
        capture("promotion-home", app)
        let plan = app.buttons["planEvents"]; reveal(plan, app: app); plan.activateControl()
        let start = app.buttons["startPlanning"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); reveal(start, app: app); start.activateControl()
        let sources = app.descendants(matching: .any).matching(identifier: "planningSources").firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 10)); reveal(sources, app: app); sources.activateControl()
        Thread.sleep(forTimeInterval: 0.8)
        capture("promotion-planning", app)
        app.buttons["closePlanning"].activateControl()
        capture("promotion-workspace", app)
        section(4, "倒数日", app: app)
        XCTAssertTrue(app.staticTexts["3 个日子"].waitForExistence(timeout: 5))
        capture("promotion-countdowns", app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.activateControl()
        XCTAssertTrue(app.buttons["editCountdown"].waitForExistence(timeout: 5))
        capture("promotion-detail", app)
    }

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
        else if app.tabBars.buttons[name].isHittable { app.tabBars.buttons[name].activateControl() }
        else { app.buttons[name].firstMatch.activateControl() }
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        #if targetEnvironment(macCatalyst)
        let screenshot = app.windows.firstMatch.screenshot()
        #else
        let screenshot = app.screenshot()
        #endif
        let shot = XCTAttachment(screenshot: screenshot); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        // Allow the host capture script to read the active simulator display.
        // XCTest captures the inactive outer display on folding simulators.
        if name.hasPrefix("promotion-") { Thread.sleep(forTimeInterval: 2) }
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
        if #available(iOS 27.1, *) {
            XCTAssertTrue(app.tabBars.buttons["计划"].isHittable || app.buttons["计划"].firstMatch.isHittable)
        } else {
            if !app.buttons["section-0"].isHittable {
                // Older iPadOS may restore a narrow window with our legacy navigation.
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.025)).doubleTap()
            }
            let sidebar = app.buttons["section-0"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            XCTAssertTrue(sidebar.isHittable)
        }
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

    func testRotationPreservesUnsentPlanningReplyAndCountdownEdit() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-planning-fixture", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let plan = app.buttons["planEvents"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10)); reveal(plan, app: app); plan.tap()
        let start = app.buttons["startPlanning"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); reveal(start, app: app); start.tap()
        let option = app.buttons["planningOption-每次 30 分钟，晚上安排"]
        XCTAssertTrue(option.waitForExistence(timeout: 8)); reveal(option, app: app); option.tap()
        let answer = app.descendants(matching: .any)["planningAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 8)); reveal(answer, app: app); answer.tap(); answer.typeText("duo-unsent-reply")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            // The compositor can still be rotating after accessibility updates.
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue((answer.value as? String ?? "").contains("duo-unsent-reply"))
            XCTAssertEqual(app.buttons.matching(identifier: "收起键盘").count, 1)
            capture("adaptive-planning-\(orientation.rawValue)", app)
        }
        app.buttons["收起键盘"].tap()
        app.buttons["closePlanning"].tap()
        section(4, "倒数日", app: app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        let edit = app.buttons["editCountdown"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let title = app.textFields["countdownTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText(" duo-unsaved-title")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue((title.value as? String ?? "").contains("duo-unsaved-title"))
            capture("adaptive-countdown-editor-\(orientation.rawValue)", app)
        }
        app.buttons["cancelCountdownEditing"].tap()
    }

    func testPlanningReplyFitsCurrentViewportWithKeyboard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-planning-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let plan = app.buttons["planEvents"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10)); reveal(plan, app: app); plan.tap()
        let start = app.buttons["startPlanning"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); reveal(start, app: app); start.tap()
        let answer = app.descendants(matching: .any)["planningAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 8)); reveal(answer, app: app)
        answer.tap(); answer.typeText("viewport-reply")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(keyboard.frame.height, 100)
        XCTAssertLessThan(keyboard.frame.minY, app.frame.maxY)
        let send = app.buttons["sendPlanningAnswer"]
        print("Planning composer bounds: input=\(answer.frame), send=\(send.frame), keyboard=\(keyboard.frame), app=\(app.frame)")
        capture("planning-current-viewport-keyboard", app)
        XCTAssertTrue(send.isHittable)
        XCTAssertLessThanOrEqual(answer.frame.maxY, keyboard.frame.minY + 2)
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 2)
        XCTAssertGreaterThanOrEqual(answer.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(send.frame.maxX, app.frame.maxX)
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
