#if !targetEnvironment(macCatalyst)
import XCTest

final class ShikeUITests: XCTestCase {
    func testCountdownColorPersistsAndCanReturnToPaper() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.tabBars.buttons["倒数日"].isHittable { app.tabBars.buttons["倒数日"].tap() }
        else { app.buttons["倒数日"].firstMatch.tap() }
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        let edit = app.buttons["editCountdown"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let peach = app.buttons["countdownColor-peach"]
        revealInCountdownSheet(peach, app: app); peach.tap()
        XCTAssertEqual(peach.value as? String, "已选择")
        capture("countdown-color-picker", app: app)
        app.buttons["saveCountdown"].tap()
        XCTAssertTrue(app.buttons["saveCountdown"].waitForNonExistence(timeout: 20))
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        capture("countdown-colored-detail", app: app)
        edit.tap(); revealInCountdownSheet(peach, app: app)
        XCTAssertEqual(peach.value as? String, "已选择")
        app.buttons["countdownColor-cream"].tap()
        app.buttons["cancelCountdownEditing"].tap()
        XCTAssertTrue(app.buttons["cancelCountdownEditing"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        revealInCountdownSheet(peach, app: app)
        XCTAssertEqual(peach.value as? String, "已选择", "Cancel must keep the saved color")
        let paper = app.buttons["countdownColor-paper"]
        paper.tap(); app.buttons["saveCountdown"].tap()
        XCTAssertTrue(app.buttons["saveCountdown"].waitForNonExistence(timeout: 20))
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        revealInCountdownSheet(paper, app: app)
        XCTAssertEqual(paper.value as? String, "已选择")
        app.buttons["cancelCountdownEditing"].tap()
    }

    func testLocalBackupPreviewAndMergeRestore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.tabBars.buttons["设置"].tap()
        let disclosure = app.buttons["自动备份"]
        revealForReview(disclosure, app: app); disclosure.tap()
        let backup = app.buttons["backupNow"]
        revealForReview(backup, app: app)
        capture("backup-controls", app: app)
        backup.tap()
        XCTAssertTrue(app.staticTexts["本地备份已保存。"].waitForExistence(timeout: 8))
        let list = app.buttons["showLocalBackups"]
        revealForReview(list, app: app); list.tap()
        XCTAssertTrue(app.buttons["恢复"].firstMatch.waitForExistence(timeout: 5))
        capture("local-backups", app: app)
        app.buttons["恢复"].firstMatch.tap()
        let confirm = app.buttons["confirmDataImport"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture("backup-import-preview", app: app)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["已导入 0 个日子、0 条记录；重复编号保留本机内容。"].waitForExistence(timeout: 8))
        app.tabBars.buttons["倒数日"].tap()
        XCTAssertTrue(app.staticTexts["3 个日子"].exists)
    }
    func testWidgetLinksOpenFilteredListAndHandleDeletedEntry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.open(URL(string: "shike://countdowns?group=00000000-0000-4000-8000-000000000001")!)
        XCTAssertTrue(app.staticTexts["2 个日子"].waitForExistence(timeout: 5))
        app.open(URL(string: "shike://countdowns?group=all&id=00000000-1111-4000-8000-000000000000")!)
        XCTAssertTrue(app.staticTexts["这个日子已被删除。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3 个日子"].exists)
    }
    func testNaturalLanguageCountdownsReviewEditAndBatchSave() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.tabBars.buttons["倒数日"].tap(); app.buttons["addCountdown"].tap()
        let natural = app.buttons["openCountdownNaturalLanguage"]
        revealInCountdownSheet(natural, app: app); natural.tap()
        let input = app.textFields["countdownNaturalText"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("12月1日去看海；2020年5月20日纪念日，每年重复；一次还没确定日期的旅行。")
        app.buttons["收起键盘"].tap()
        let recognize = app.buttons["recognizeCountdowns"]
        revealInCountdownSheet(recognize, app: app); recognize.tap()
        let unknown = app.buttons["editRecognized-等你确定的日子"]
        XCTAssertTrue(unknown.waitForExistence(timeout: 8))
        let saveAll = app.buttons["saveRecognizedCountdowns"]
        revealInCountdownSheet(saveAll, app: app); XCTAssertFalse(saveAll.isEnabled)
        revealInCountdownSheet(unknown, app: app); unknown.tap()
        XCTAssertFalse(app.buttons["reviewSaveCountdown"].isEnabled)
        app.buttons["confirmRecognizedDate"].tap()
        app.buttons["reviewSaveCountdown"].tap()
        revealInCountdownSheet(saveAll, app: app); XCTAssertTrue(saveAll.isEnabled)
        let omit = app.switches["selectRecognized-等你确定的日子"]
        revealInCountdownSheet(omit, app: app); omit.tap()
        let edit = app.buttons["editRecognized-自然语言去看海"]
        revealInCountdownSheet(edit, app: app); edit.tap()
        let title = app.textFields["reviewCountdownTitle"]
        title.tap(); title.typeText("已核对")
        let editedTitle = title.value as? String ?? ""
        XCTAssertTrue(editedTitle.contains("已核对"))
        app.buttons["reviewSaveCountdown"].tap()
        revealInCountdownSheet(saveAll, app: app)
        capture("countdown-natural-review", app: app)
        saveAll.tap()
        XCTAssertTrue(app.buttons["addCountdown"].waitForExistence(timeout: 8))
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-"))
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(app.staticTexts[editedTitle].exists)
        capture("countdown-natural-saved", app: app)
    }
    private func revealInCountdownSheet(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<16 {
            if element.exists && element.isHittable && element.frame.minY > 150 && element.frame.maxY < app.frame.maxY - 24 { break }
            let down = element.exists && element.frame.minY < 150
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: down ? 0.35 : 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: down ? 0.7 : 0.35)))
        }
        XCTAssertTrue(element.isHittable)
    }
    func testCountdownCreateEditCalendarDeleteAndExport() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-calendar-denied-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["倒数日"].tap()
        XCTAssertTrue(app.buttons["addCountdown"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["countdownYearProgress"].exists)
        capture("countdown-empty-year-progress", app: app)
        app.buttons["addCountdown"].tap()
        let title = app.textFields["countdownTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("CountdownMarker")
        app.buttons["saveCountdown"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        capture("countdown-list", app: app)
        card.tap()
        XCTAssertTrue(app.buttons["editCountdown"].waitForExistence(timeout: 5))
        app.buttons["editCountdown"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("Edited")
        app.buttons["saveCountdown"].tap()
        let pin = app.buttons["pinCountdown"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5)); revealForReview(pin, app: app); pin.tap()
        capture("countdown-detail", app: app)
        app.navigationBars["记住这一天"].buttons["完成"].tap()
        app.tabBars.buttons["日历"].tap()
        let event = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendarCountdown-")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5), "Countdown must be visible without EventKit permission")
        XCTAssertTrue(app.buttons["calendarGrantAccess"].exists)
        capture("countdown-calendar", app: app)
        app.buttons["calendarFilters"].tap()
        let showCountdowns = app.switches["showCountdownsInCalendar"]
        XCTAssertTrue(showCountdowns.waitForExistence(timeout: 5)); showCountdowns.tap()
        app.navigationBars["显示哪些日历"].buttons["完成"].tap()
        XCTAssertFalse(event.exists)
        app.buttons["calendarFilters"].tap(); showCountdowns.tap()
        app.navigationBars["显示哪些日历"].buttons["完成"].tap()
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        event.tap()
        let remove = app.buttons["deleteCountdown"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); revealForReview(remove, app: app); remove.tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["calendarFilters"].waitForExistence(timeout: 5))
        XCTAssertFalse(event.exists)
        app.tabBars.buttons["设置"].tap()
        let export = app.buttons["exportAppJSON"]
        revealForReview(export, app: app); XCTAssertTrue(export.isHittable)
        capture("countdown-export-settings", app: app)
        export.tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 8))
        XCTAssertTrue((filename.value as? String)?.hasPrefix("Shike_Export_") == true)
        capture("countdown-json-file-exporter", app: app)
        app.buttons["DOCPicker.actionButton"].tap()
        XCTAssertTrue(app.staticTexts["JSON 文件已导出。请妥善保管其中的个人内容。"].waitForExistence(timeout: 8))
    }

    func testCountdownCategoriesAndReminderEditor() {
        let app = launchExample(); app.tabBars.buttons["倒数日"].tap()
        app.buttons["管理倒数日分类"].tap()
        let field = app.textFields["countdownCategoryName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("CustomCategory")
        app.buttons["添加分类"].tap()
        XCTAssertTrue(app.staticTexts["CustomCategory"].exists)
        app.navigationBars["倒数日分类"].buttons["完成"].tap()
        app.buttons["addCountdown"].tap()
        let title = app.textFields["countdownTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.tap(); title.typeText("ReminderMarker")
        app.buttons["收起键盘"].tap()
        let lunar = app.segmentedControls.buttons["农历"]
        revealForReview(lunar, app: app); lunar.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "对应公历")).firstMatch.exists)
        let day = app.switches["当天"]
        revealForReview(day, app: app)
        XCTAssertEqual(day.value as? String, "0")
        day.tap()
        XCTAssertTrue(app.staticTexts["按倒数日时区提醒。保存时会请求本设备的通知权限。"].exists)
        capture("countdown-editor", app: app)
        app.navigationBars["记下一个日子"].buttons["取消"].tap()
        XCTAssertFalse(app.staticTexts["ReminderMarker"].exists)
    }

    func testCountdownSearchOnlyAppearsAfterPullingDown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.tabBars.buttons["倒数日"].tap()
        XCTAssertTrue(app.buttons["countdownLayout"].waitForExistence(timeout: 8))
        let progress = app.descendants(matching: .any)["countdownYearProgress"]
        XCTAssertTrue(progress.exists)
        XCTAssertTrue(progress.label.contains("全年"))
        let search = app.textFields["searchCountdowns"]
        XCTAssertFalse(search.exists)
        capture("countdown-search-collapsed", app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("看海")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-"))
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(progress.exists)
        capture("countdown-search-expanded", app: app)
        app.buttons["closeCountdownSearch"].tap()
        XCTAssertFalse(search.exists)
        // LazyVGrid does not expose off-screen cells at large accessibility sizes.
        XCTAssertTrue(app.staticTexts["3 个日子"].exists)
    }

    func testCountdownDeepPullOpensNewEntryWithoutSavingUntilConfirmed() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.tabBars.buttons["倒数日"].tap()
        XCTAssertTrue(app.buttons["addCountdown"].waitForExistence(timeout: 8))
        capture("year-progress-empty", app: app)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-"))
        XCTAssertEqual(cards.count, 0)
        for save in [false, true] {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            let title = app.textFields["countdownTitle"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            if save {
                title.tap(); title.typeText("深拉新增的日子")
                app.buttons["saveCountdown"].tap()
            } else { app.navigationBars["记下一个日子"].buttons["取消"].tap() }
            XCTAssertTrue(app.buttons["addCountdown"].waitForExistence(timeout: 5))
            XCTAssertEqual(cards.count, save ? 1 : 0)
        }
        capture("deep-pull-created", app: app)
    }

    func testCountdownLayoutsSecondsMilestonesAndImageExport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch(); app.tabBars.buttons["倒数日"].tap()
        let layout = app.buttons["countdownLayout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 8))
        layout.tap(); app.buttons["countdownLayout-double"].tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "countdown-"))
        XCTAssertGreaterThanOrEqual(cards.count, 2)
        XCTAssertEqual(cards.element(boundBy: 0).frame.minY, cards.element(boundBy: 1).frame.minY, accuracy: 3)
        XCTAssertGreaterThan(cards.element(boundBy: 1).frame.minX, cards.element(boundBy: 0).frame.minX + 100)
        capture("countdown-two-columns", app: app)
        layout.tap(); app.buttons["countdownLayout-strip"].tap()
        XCTAssertGreaterThan(cards.element(boundBy: 1).frame.minY, cards.element(boundBy: 0).frame.minY)
        capture("countdown-strips", app: app)
        app.tabBars.buttons["设置"].tap(); app.tabBars.buttons["倒数日"].tap()
        XCTAssertTrue(layout.label.contains("窄条列表"))
        layout.tap(); app.buttons["countdownLayout-single"].tap()
        cards.firstMatch.tap(); app.buttons["editCountdown"].tap()
        let precise = app.switches["countdownPreciseTime"]
        revealForReview(precise, app: app); precise.tap()
        let seconds = app.buttons["countdownTime-秒"]
        XCTAssertTrue(seconds.exists); revealForReview(seconds, app: app); seconds.tap()
        let second = app.buttons["17秒"]
        for _ in 0..<16 {
            if second.exists && second.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(second.waitForExistence(timeout: 3)); second.tap()
        let inclusive = app.switches["countdownIncludesStart"]
        revealForReview(inclusive, app: app); inclusive.tap()
        capture("countdown-precise-editor", app: app)
        let preset = app.buttons["milestonePreset-520"]
        revealForReview(preset, app: app); preset.tap(); app.buttons["milestonePreset-1314"].tap()
        let milestone = app.textFields["countdownMilestones"]
        XCTAssertTrue((milestone.value as? String)?.contains("520, 1314") == true)
        capture("countdown-milestone-editor", app: app)
        let permission = addUIInterruptionMonitor(withDescription: "Notifications") { alert in
            for label in ["允许", "Allow"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.buttons["saveCountdown"].tap()
        if !app.buttons["exportCountdownImage"].waitForExistence(timeout: 3) { app.tap() }
        removeUIInterruptionMonitor(permission)
        XCTAssertTrue(app.buttons["editCountdown"].waitForExistence(timeout: 8))
        let export = app.buttons["exportCountdownImage"]
        revealForReview(export, app: app); export.tap()
        let share = app.buttons["shareCountdownPNG"]
        XCTAssertTrue(share.waitForExistence(timeout: 8)); capture("countdown-image-preview", app: app)
        XCTAssertFalse(app.buttons["saveCountdownPNG"].exists)
        revealInCountdownSheet(share, app: app); XCTAssertTrue(share.isEnabled)
        app.navigationBars["卡片图片"].buttons["完成"].tap()
        app.buttons["editCountdown"].tap()
        XCTAssertEqual(app.switches["countdownPreciseTime"].value as? String, "1")
        XCTAssertEqual(app.switches["countdownIncludesStart"].value as? String, "1")
        XCTAssertTrue(app.buttons["countdownTime-秒"].label.contains("17"))
        revealForReview(milestone, app: app)
        XCTAssertTrue((milestone.value as? String)?.contains("520, 1314") == true)
        app.navigationBars["编辑倒数日"].buttons["取消"].tap()
    }

    func testCountUpAnniversaryAndCustomIntervalPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-countdown-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.tabBars.buttons["倒数日"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "countdown-", "和你在一起")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8)); revealForReview(card, app: app); card.tap()
        app.buttons["editCountdown"].tap()
        let anniversary = app.switches["countdownAnniversaries"]
        revealInCountdownSheet(anniversary, app: app); anniversary.tap()
        let interval = app.switches["countdownDayIntervalEnabled"]
        revealInCountdownSheet(interval, app: app); interval.tap()
        let picker = app.buttons["countdownDayInterval"]
        revealInCountdownSheet(picker, app: app); picker.tap(); app.buttons["每 500 天"].tap()
        XCTAssertTrue(picker.label.contains("500"))
        picker.tap(); app.buttons["自定义"].tap()
        let field = app.textFields["countdownCustomInterval"]
        revealInCountdownSheet(field, app: app); field.tap(); field.typeText("7")
        let chosen = field.value as? String ?? ""
        XCTAssertNotNil(Int(chosen))
        app.buttons["收起键盘"].tap(); capture("countup-reminder-options", app: app)
        let permission = addUIInterruptionMonitor(withDescription: "Notifications") { alert in
            for label in ["允许", "Allow"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.buttons["saveCountdown"].tap()
        if !app.buttons["editCountdown"].waitForExistence(timeout: 3) { app.tap() }
        removeUIInterruptionMonitor(permission)
        XCTAssertTrue(app.buttons["editCountdown"].waitForExistence(timeout: 8)); app.buttons["editCountdown"].tap()
        revealInCountdownSheet(anniversary, app: app); XCTAssertEqual(anniversary.value as? String, "1")
        revealInCountdownSheet(field, app: app); XCTAssertEqual(field.value as? String, chosen)
        revealInCountdownSheet(interval, app: app); interval.tap()
        revealInCountdownSheet(anniversary, app: app); anniversary.tap()
        app.buttons["saveCountdown"].tap()
        XCTAssertTrue(app.buttons["editCountdown"].waitForExistence(timeout: 8)); app.buttons["editCountdown"].tap()
        revealInCountdownSheet(interval, app: app); XCTAssertEqual(interval.value as? String, "0")
        XCTAssertEqual(anniversary.value as? String, "0")
    }

    func testExpandedSourceEditorKeepsEditsAndSupportsSwipeDismiss() {
        let app = launchExample()
        let source = app.textViews["sourceText"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let original = source.value as? String
        let compactHeight = source.frame.height
        let expand = app.buttons["expand-sourceText"]
        revealForReview(expand, app: app)
        expand.tap()
        let editor = app.textViews["expanded-sourceText"]
        XCTAssertFalse(editor.waitForExistence(timeout: 1), "A single tap must not interrupt normal editing")
        expand.doubleTap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, original)
        editor.tap(); editor.typeText("\nExpandedSourceMarker\nAnother paragraph")
        capture("expanded-source-keyboard", app: app)
        app.buttons["收起键盘"].tap()
        XCTAssertGreaterThan(editor.frame.height, compactHeight + 100)
        capture("expanded-source", app: app)
        app.buttons["collapse-sourceText"].tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue((source.value as? String)?.contains("ExpandedSourceMarker") == true)
        let edited = source.value as? String
        revealForReview(expand, app: app); expand.doubleTap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, edited)
        editor.tap(); editor.typeText(" SwipeDismissMarker")
        app.buttons["收起键盘"].tap()
        let bar = app.navigationBars["原文"]
        let dragStart = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["parseEvents"].waitForExistence(timeout: 5))
        XCTAssertFalse(editor.exists)
        XCTAssertTrue((source.value as? String)?.contains("SwipeDismissMarker") == true)
    }

    func testExpandedPromptEditorsPreserveSaveAndCancelBehavior() {
        let app = launchExample(); app.tabBars.buttons["设置"].tap()
        let prompts = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "自定义识别规则与安排习惯")).firstMatch
        revealForReview(prompts, app: app); prompts.tap()
        for purpose in ["extraction", "planning"] {
            let edit = app.buttons["editPrompt-\(purpose)"]
            revealForReview(edit, app: app); edit.tap()
            let source = app.textViews["promptText"]
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            let original = source.value as? String
            let expand = app.buttons["expand-promptText"]
            revealForReview(expand, app: app); expand.doubleTap()
            let editor = app.textViews["expanded-promptText"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertEqual(editor.value as? String, original)
            editor.tap(); editor.typeText(" ExpandedPrompt-\(purpose)")
            capture("expanded-prompt-\(purpose)", app: app)
            app.buttons["collapse-promptText"].tap()
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue((source.value as? String)?.contains("ExpandedPrompt-\(purpose)") == true)
            // Expanding the draft must not silently save changes to preferences.
            app.buttons["取消"].tap()
            revealForReview(edit, app: app); edit.tap()
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertEqual(source.value as? String, original)
            revealForReview(expand, app: app); expand.doubleTap()
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap(); editor.typeText(" SavedExpanded-\(purpose)")
            app.buttons["collapse-promptText"].tap()
            app.buttons["savePrompt"].tap()
            revealForReview(edit, app: app); edit.tap()
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue((source.value as? String)?.contains("SavedExpanded-\(purpose)") == true)
            app.buttons["取消"].tap()
        }
    }

    func testCollapsibleSettingsAndIndependentPromptEditing() {
        let app = launchExample(); app.tabBars.buttons["设置"].tap()
        let calendar = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "日历偏好")).firstMatch
        let api = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "模型与 API")).firstMatch
        let prompt = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "自定义识别规则与安排习惯")).firstMatch
        let cloud = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "iCloud 同步")).firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        XCTAssertLessThan(calendar.frame.minY, api.frame.minY)
        XCTAssertLessThan(api.frame.minY, prompt.frame.minY)
        XCTAssertLessThan(prompt.frame.minY, cloud.frame.minY)
        XCTAssertFalse(app.switches["categoryRouting"].exists)
        XCTAssertFalse(app.switches["iCloudSettings"].exists)
        capture("settings-collapsed", app: app)
        revealForReview(prompt, app: app); prompt.tap()
        let edit = app.buttons["editPrompt-extraction"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); revealForReview(edit, app: app); edit.tap()
        let text = app.textViews["promptText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText(" CustomPromptMarker")
        app.buttons["savePrompt"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String)?.contains("CustomPromptMarker") == true)
        capture("custom-prompt-editor", app: app)
        app.buttons["取消"].tap()
        let planning = app.buttons["editPrompt-planning"]; revealForReview(planning, app: app); planning.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertFalse((text.value as? String)?.contains("CustomPromptMarker") == true)
        app.buttons["取消"].tap()
        revealForReview(edit, app: app); edit.tap()
        let reset = app.buttons["resetPrompt"]; revealForReview(reset, app: app); reset.tap()
        app.buttons["savePrompt"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertFalse((text.value as? String)?.contains("CustomPromptMarker") == true)
        app.buttons["取消"].tap()
        revealForReview(prompt, app: app); prompt.tap()
        XCTAssertFalse(edit.exists)
    }

    func testPlanningQuestionProposalAndCalendarViews() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-planning-fixture", "-calendar-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let plan = app.buttons["planEvents"]; XCTAssertTrue(plan.waitForExistence(timeout: 10)); plan.tap()
        let start = app.buttons["startPlanning"]; XCTAssertTrue(start.waitForExistence(timeout: 5)); revealForReview(start, app: app); start.tap()
        let option = app.buttons["planningOption-每次 30 分钟，晚上安排"]
        XCTAssertTrue(option.waitForExistence(timeout: 8)); capture("planning-question", app: app); option.tap()
        let event = app.buttons["planning-editEvent-读书与笔记"]
        XCTAssertTrue(event.waitForExistence(timeout: 8)); revealForReview(event, app: app); capture("planning-proposal", app: app)
        app.buttons["closePlanning"].tap()
        revealForReview(plan, app: app); plan.tap()
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        let save = app.buttons["planning-saveEvents"]; revealForReview(save, app: app); save.tap()
        XCTAssertTrue(app.staticTexts["已将 1 个日程加入日历。"].waitForExistence(timeout: 8))
        app.buttons["closePlanning"].tap()
        app.tabBars.buttons["日历"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["calendarTimeline"].firstMatch.waitForExistence(timeout: 8))
        for button in [app.buttons["上一页"], app.buttons["下一页"], app.buttons["calendarToday"]] {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
        }
        capture("calendar-day", app: app)
        app.segmentedControls["calendarRange"].buttons["3 天"].tap(); capture("calendar-three-days", app: app)
        app.segmentedControls["calendarRange"].buttons["7 天"].tap(); capture("calendar-week", app: app)
        let readonly = app.buttons["calendarEvent-demo-2"]
        if readonly.isHittable {
            readonly.tap()
            XCTAssertTrue(app.staticTexts["订阅日历 · 只读"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["editCalendarEvent"].exists)
            app.buttons["完成"].tap()
        }
        app.buttons["calendarFilters"].tap()
        XCTAssertTrue(app.switches["calendarFilter-test-readonly"].waitForExistence(timeout: 5))
        app.switches["calendarFilter-test-readonly"].tap()
        app.buttons["完成"].tap()
        app.tabBars.buttons["设置"].tap(); app.tabBars.buttons["日历"].tap()
        XCTAssertTrue(app.segmentedControls["calendarRange"].buttons["7 天"].isSelected)
    }

    func testPlanningConsentCanDeclineAndResumeWithoutDuplicateAnswer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-consent-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.buttons["planEvents"].tap(); app.buttons["startPlanning"].tap()
        let decline = app.buttons["declineExtraction"]; XCTAssertTrue(decline.waitForExistence(timeout: 5)); revealForReview(decline, app: app); decline.tap()
        XCTAssertTrue(app.buttons["startPlanning"].waitForExistence(timeout: 5)); app.buttons["startPlanning"].tap()
        let allow = app.buttons["allowExtraction"]; XCTAssertTrue(allow.waitForExistence(timeout: 5)); revealForReview(allow, app: app); allow.tap()
        XCTAssertTrue(app.buttons["planningOption-你来决定"].waitForExistence(timeout: 8))
    }

    func testDesktopQuickActionsWarmAndColdClipboardImport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-paste-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); XCTAssertTrue(app.buttons["planEvents"].waitForExistence(timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func shortcut() {
            XCUIDevice.shared.press(.home)
            var icon = springboard.icons.matching(identifier: "拾刻计划").allElementsBoundByIndex.first { $0.isHittable }
            for _ in 0..<5 {
                if icon != nil { break }
                springboard.swipeLeft()
                icon = springboard.icons.matching(identifier: "拾刻计划").allElementsBoundByIndex.first { $0.isHittable }
            }
            XCTAssertNotNil(icon, springboard.debugDescription)
            guard let icon else { return }
            icon.press(forDuration: 1.3)
            let action = springboard.buttons["从剪贴板导入"]
            XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
            let allowPaste = app.buttons["允许粘贴"]
            if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
            XCTAssertTrue(app.textViews["sourceText"].waitForExistence(timeout: 10))
            let filled = NSPredicate(format: "value CONTAINS %@", "三楼会议室")
            expectation(for: filled, evaluatedWith: app.textViews["sourceText"])
            waitForExpectations(timeout: 15)
            XCTAssertFalse(app.buttons["saveEvents"].exists)
        }
        shortcut(); capture("desktop-clipboard-warm", app: app)
        app.terminate(); shortcut(); capture("desktop-clipboard-cold", app: app)
    }

    func testDesktopLatestPhotoImportsOCRWithoutCallingModel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); XCTAssertTrue(app.buttons["planEvents"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var icon = springboard.icons.matching(identifier: "拾刻计划").allElementsBoundByIndex.first { $0.isHittable }
        for _ in 0..<5 {
            if icon != nil { break }
            springboard.swipeLeft()
            icon = springboard.icons.matching(identifier: "拾刻计划").allElementsBoundByIndex.first { $0.isHittable }
        }
        XCTAssertNotNil(icon); guard let icon else { return }
        icon.press(forDuration: 1.3)
        let action = springboard.buttons["从最近一张图片导入"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertTrue(app.textViews["sourceText"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value CONTAINS %@", "READING CLUB"), evaluatedWith: app.textViews["sourceText"])
        waitForExpectations(timeout: 20)
        XCTAssertFalse(app.buttons["saveEvents"].exists)
        capture("desktop-recent-photo", app: app)
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.staticTexts["最近图片"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["文字"].exists, "Previous unfinished input must remain in history")
    }

    func testConsentDeclineAllowReparseAndRevoke() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-consent-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["parseEvents"].tap()
        let decline = app.buttons["declineExtraction"]
        XCTAssertTrue(decline.waitForExistence(timeout: 5))
        capture("privacy-consent", app: app)
        revealForReview(decline, app: app); decline.tap()
        XCTAssertFalse(app.buttons["saveEvents"].exists)
        app.buttons["parseEvents"].tap()
        let allow = app.buttons["allowExtraction"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5)); revealForReview(allow, app: app); allow.tap()
        let first = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        let parse = app.buttons["parseEvents"]; revealForReview(parse, app: app); parse.tap()
        XCTAssertFalse(allow.exists)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        app.tabBars.buttons["设置"].tap()
        let disclosure = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "关于内容与隐私")).firstMatch
        revealForReview(disclosure, app: app); disclosure.tap()
        let revoke = app.buttons["revokeExtractionConsent"]; revealForReview(revoke, app: app); revoke.tap()
        let policy = app.buttons["privacyPolicy"]; revealForReview(policy, app: app); policy.tap()
        XCTAssertTrue(app.navigationBars["隐私政策"].waitForExistence(timeout: 5))
        capture("privacy-policy", app: app)
        app.tabBars.buttons["计划"].tap()
        revealForReview(parse, app: app); parse.tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
    }

    func testAppStoreScreenshots() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-store-screenshots", "-paste-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["parseEvents"].waitForExistence(timeout: 10))
        capture("store-01-import", app: app)
        app.buttons["parseEvents"].tap()
        let first = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        revealForReview(app.buttons["saveEvents"], app: app)
        capture("store-02-results", app: app)
        app.buttons["saveEvents"].tap()
        XCTAssertTrue(app.buttons["confirmReview"].waitForExistence(timeout: 5))
        capture("store-03-review", app: app)
        app.buttons["exitReview"].tap()
        revealForReview(first, app: app); first.tap()
        XCTAssertTrue(app.textFields["eventTitle"].waitForExistence(timeout: 5))
        capture("store-04-editor", app: app)
        app.buttons["取消"].tap()
        app.tabBars.buttons["设置"].tap()
        capture("store-05-settings", app: app)
        app.launchArguments = ["-ui-testing", "-seed-example", "-planning-fixture", "-calendar-fixture", "-store-screenshots", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["planEvents"].tap(); app.buttons["startPlanning"].tap()
        let option = app.buttons["planningOption-每次 30 分钟，晚上安排"]
        XCTAssertTrue(option.waitForExistence(timeout: 8)); option.tap()
        let proposed = app.buttons["planning-editEvent-读书与笔记"]
        XCTAssertTrue(proposed.waitForExistence(timeout: 8)); revealForReview(proposed, app: app)
        capture("store-06-planning", app: app)
        app.buttons["closePlanning"].tap(); app.tabBars.buttons["日历"].tap()
        XCTAssertTrue(app.segmentedControls["calendarRange"].waitForExistence(timeout: 8))
        app.segmentedControls["calendarRange"].buttons["7 天"].tap()
        XCTAssertTrue(app.buttons["calendarEvent-demo-0"].waitForExistence(timeout: 8))
        capture("store-07-calendar", app: app)
        app.launchArguments = ["-ui-testing", "-countdown-fixture", "-store-screenshots", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch(); app.tabBars.buttons["倒数日"].tap()
        XCTAssertTrue(app.buttons["addCountdown"].waitForExistence(timeout: 8))
        capture("store-08-countdowns", app: app)
    }

    private func revealForReview(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<24 {
            let footer = app.buttons["confirmReview"]
            let bottom = footer.exists ? footer.frame.minY - 8 : app.frame.maxY - 95
            if element.exists && element.isHittable && element.frame.minY > 150 && element.frame.maxY < bottom { break }
            let down = element.exists && element.frame.minY < 150
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: 20, dy: down ? 300 : 450))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 20, dy: down ? 450 : 300)))
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func openGuidedReview(_ app: XCUIApplication, prefix: String = "") {
        app.buttons[prefix + "parseEvents"].tap()
        let save = app.buttons[prefix + "saveEvents"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        revealForReview(save, app: app); save.tap()
        XCTAssertTrue(app.buttons["confirmReview"].waitForExistence(timeout: 5))
    }

    func testGuidedReviewExitAndConfirmSavesAllSelected() {
        let app = launchExample()
        openGuidedReview(app)
        XCTAssertTrue(app.navigationBars["核对 1 / 1"].exists)
        XCTAssertEqual(app.buttons["confirmReview"].label, "确认并加入 2 个日程")
        XCTAssertFalse(app.buttons["confirmTime"].exists)
        capture("guided-review", app: app)
        let title = app.textFields["eventTitle"]
        revealForReview(title, app: app); title.tap(); title.typeText("未提交修改")
        capture("guided-review-keyboard", app: app)
        app.buttons["exitReview"].tap()
        let save = app.buttons["saveEvents"]; revealForReview(save, app: app); save.tap()
        XCTAssertTrue(app.buttons["confirmReview"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["eventTitle"].value as? String, "和小林喝咖啡")
        app.buttons["confirmReview"].tap()
        XCTAssertTrue(app.staticTexts["已将 2 个日程加入日历。"].waitForExistence(timeout: 8))
    }

    func testGuidedReviewSkipThenExplicitlySaveRemaining() {
        let app = launchExample()
        openGuidedReview(app)
        app.buttons["skipReview"].tap()
        let save = app.buttons["reviewSaveRemaining"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "加入 1 个日程")
        capture("guided-review-skipped", app: app)
        save.tap()
        XCTAssertTrue(app.staticTexts["已将 1 个日程加入日历。"].waitForExistence(timeout: 8))
    }

    func testGuidedReviewMultipleAndMissingFields() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-example", "-review-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openGuidedReview(app)
        XCTAssertTrue(app.navigationBars["核对 1 / 2"].exists)
        XCTAssertEqual(app.buttons["confirmReview"].label, "确认并继续")
        app.buttons["confirmReview"].tap()
        XCTAssertTrue(app.navigationBars["核对 2 / 2"].waitForExistence(timeout: 5))
        app.buttons["confirmReview"].tap()
        XCTAssertTrue(app.staticTexts["reviewError"].exists)
        capture("guided-review-missing", app: app)
        app.buttons["exitReview"].tap()
        let save = app.buttons["saveEvents"]; revealForReview(save, app: app); save.tap()
        XCTAssertTrue(app.navigationBars["核对 1 / 1"].waitForExistence(timeout: 5))
        let title = app.textFields["eventTitle"]; revealForReview(title, app: app); title.tap(); title.typeText("补充的安排")
        // Submit once to close the keyboard; missing dates still block writing.
        app.buttons["confirmReview"].tap()
        let start = app.buttons["fillStartDate"]; revealForReview(start, app: app); start.tap()
        let end = app.buttons["fillEndDate"]; revealForReview(end, app: app); end.tap()
        let calendar = app.descendants(matching: .any)["draftCalendar"]; revealForReview(calendar, app: app); calendar.tap()
        app.buttons["个人日程（测试日历）"].tap()
        app.buttons["confirmReview"].tap()
        XCTAssertTrue(app.staticTexts["已将 2 个日程加入日历。"].waitForExistence(timeout: 8))
    }

    func testReparseStartsWithoutConfirmation() {
        let app = launchExample()
        app.buttons["parseEvents"].tap()
        let first = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(first.waitForExistence(timeout: 8)); revealForReview(first, app: app); first.tap()
        let title = app.textFields["eventTitle"]; title.tap(); title.typeText("旧草稿")
        app.buttons["finishEditing"].tap()
        let parse = app.buttons["parseEvents"]; revealForReview(parse, app: app); parse.tap()
        XCTAssertFalse(app.buttons["重新提取"].exists)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
    }

    func testGMTSearchAndRestoreSystemTimeZone() {
        let app = launchExample()
        app.buttons["parseEvents"].tap()
        let draft = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(draft.waitForExistence(timeout: 8))
        if !draft.isHittable { app.swipeUp() }
        draft.tap()
        let zone = app.buttons["eventTimeZone"]
        XCTAssertTrue(zone.waitForExistence(timeout: 5)); zone.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("GMT+8")
        let shanghai = app.buttons["timeZone-Asia/Shanghai"]
        XCTAssertTrue(shanghai.waitForExistence(timeout: 5))
        XCTAssertTrue(shanghai.label.contains("上海"))
        capture("timezone-shanghai", app: app)
        shanghai.tap()
        XCTAssertEqual(zone.value as? String, "Asia/Shanghai")
        zone.tap(); search.tap(); search.typeText("GMT+9")
        let tokyo = app.buttons["timeZone-Asia/Tokyo"]
        XCTAssertTrue(tokyo.waitForExistence(timeout: 5), app.debugDescription)
        capture("timezone-search", app: app)
        tokyo.tap()
        XCTAssertEqual(zone.value as? String, "Asia/Tokyo")
        zone.tap()
        app.buttons["useSystemTimeZone"].tap()
        XCTAssertEqual(zone.value as? String, TimeZone.current.identifier)
    }

    func testMaineCoonLongPressRestoresOnRelease() {
        let app = launchExample(); app.tabBars.buttons["设置"].tap()
        let cat = app.buttons["petMaineCoon"]
        XCTAssertTrue(cat.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(cat.value as? String, "普通猫猫")
        capture("settings", app: app)
        // Keep the finger down long enough to inspect the held reaction in the simulator.
        cat.press(forDuration: 3)
        XCTAssertEqual(cat.value as? String, "普通猫猫")
        capture("settings-released", app: app)
        cat.press(forDuration: 0.8)
        XCTAssertEqual(cat.value as? String, "普通猫猫")
        cat.tap()
        XCTAssertEqual(cat.value as? String, "普通猫猫")
        let author = app.staticTexts["作者：Chandler-Lu"]
        for _ in 0..<4 where !author.isHittable || author.frame.maxY > app.frame.maxY - 150 { app.swipeUp() }
        capture("settings-about", app: app)
    }

    func testMultipleProfilesAndStableConnectionButton() {
        let app = launchExample()
        XCTAssertFalse(app.buttons["homeAPIProfile"].exists)
        app.tabBars.buttons["设置"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let api = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "模型与 API")).firstMatch
        func reveal(_ element: XCUIElement) {
            for _ in 0..<24 {
                let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 45 : app.frame.maxY - 140
                let frame = element.frame
                if element.isHittable && frame.minY > 140 && frame.maxY < bottom { break }
                let middle = (140 + bottom) / 2
                let down = frame.minY < 140
                let origin = app.coordinate(withNormalizedOffset: .zero)
                // Drag in the page margin so text fields and editors do not consume the gesture.
                origin.withOffset(CGVector(dx: 20, dy: middle + (down ? -70 : 70)))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 20, dy: middle + (down ? 70 : -70))))
            }
            XCTAssertTrue(element.isHittable, app.debugDescription)
        }
        reveal(api); api.tap()
        func saveProfile(name: String, model: String) {
            let field = app.textFields["apiProfileName"]; reveal(field); field.tap()
            if let existing = field.value as? String, existing != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
            }
            field.typeText(name)
            let url = app.textFields["apiURL"]; reveal(url); url.tap(); url.typeText("https://example.com/custom")
            let modelField = app.textFields["modelName"]; reveal(modelField); modelField.tap(); modelField.typeText(model)
            if app.buttons["收起键盘"].exists { app.buttons["收起键盘"].tap() }
            XCTAssertFalse(app.buttons["saveAPI"].exists)
            XCTAssertFalse(app.segmentedControls["apiFormat"].exists)
        }
        saveProfile(name: "Claude Work", model: "claude-fixture")
        app.tabBars.buttons["计划"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let homeProfile = app.buttons["homeAPIProfile"]
        XCTAssertTrue(homeProfile.waitForExistence(timeout: 5))
        XCTAssertEqual(homeProfile.value as? String, "Claude Work")
        reveal(homeProfile)
        capture("home-api-single", app: app)
        app.tabBars.buttons["设置"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let test = app.buttons["testAPI"]; reveal(test)
        let before = test.frame
        test.tap()
        XCTAssertTrue(app.staticTexts["请先在设置中填写 API Key 和模型名称。"].waitForExistence(timeout: 5))
        XCTAssertEqual(test.frame.minY, before.minY, accuracy: 2, "Result feedback must not move the connection button")
        let picker = app.buttons["apiProfiles"]
        reveal(picker)
        picker.tap(); app.buttons["newAPIProfile"].tap()
        saveProfile(name: "Gemini Backup", model: "gemini-fixture")
        reveal(picker)
        picker.tap(); app.buttons["Claude Work"].tap()
        XCTAssertEqual(app.textFields["apiProfileName"].value as? String, "Claude Work")
        XCTAssertFalse(app.segmentedControls["apiFormat"].exists)
        capture("api-profiles", app: app)
        picker.tap(); app.buttons["duplicateAPIProfile"].tap()
        XCTAssertEqual(app.textFields["apiProfileName"].value as? String, "Claude Work 副本")
        XCTAssertEqual(app.textFields["apiURL"].value as? String, "https://example.com/custom")
        XCTAssertEqual(app.textFields["modelName"].value as? String, "claude-fixture")
        XCTAssertFalse(app.segmentedControls["apiFormat"].exists)
        capture("api-duplicate", app: app)
        picker.tap(); app.buttons["newAPIProfile"].tap()
        XCTAssertEqual(app.textFields["apiProfileName"].value as? String, "新接口")
        XCTAssertEqual(app.textFields["apiURL"].value as? String, app.textFields["apiURL"].placeholderValue)
        XCTAssertEqual(app.textFields["modelName"].value as? String, app.textFields["modelName"].placeholderValue)
        XCTAssertFalse(app.segmentedControls["apiFormat"].exists)
        picker.tap()
        XCTAssertTrue(app.buttons["Claude Work 副本"].exists)
        app.buttons["Claude Work"].tap()
        XCTAssertEqual(app.textFields["modelName"].value as? String, "claude-fixture")
        app.tabBars.buttons["计划"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(homeProfile.waitForExistence(timeout: 5))
        XCTAssertEqual(homeProfile.value as? String, "Claude Work")
        reveal(homeProfile)
        homeProfile.tap(); app.buttons["Gemini Backup"].tap()
        XCTAssertEqual(homeProfile.value as? String, "Gemini Backup")
        capture("home-api", app: app)
        app.tabBars.buttons["设置"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(app.textFields["apiProfileName"].value as? String, "Gemini Backup")
        app.tabBars.buttons["计划"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(homeProfile.value as? String, "Gemini Backup")

        app.tabBars.buttons["设置"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let name = app.textFields["apiProfileName"]; reveal(name)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        name.typeText(" — Long personal calendar connection")
        if app.buttons["收起键盘"].exists { app.buttons["收起键盘"].tap() }
        app.tabBars.buttons["计划"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let fullName = "Gemini Backup — Long personal calendar connection"
        XCTAssertEqual(homeProfile.value as? String, fullName)
        reveal(homeProfile)
        XCTAssertGreaterThanOrEqual(homeProfile.frame.height, 44)
        XCTAssertLessThanOrEqual(homeProfile.frame.width, 140)
        capture("home-api-long", app: app)
        homeProfile.tap()
        XCTAssertTrue(app.buttons[fullName].exists)
        capture("home-api-menu", app: app)
        app.buttons["Claude Work"].tap()
        XCTAssertEqual(homeProfile.value as? String, "Claude Work")
    }

    func testCloudSettingsWithoutAccountShowsActionableMessage() {
        let app = launchExample()
        app.tabBars.buttons["设置"].tap()
        let section = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "iCloud 同步")).firstMatch
        revealForReview(section, app: app); section.tap()
        let toggle = app.switches["iCloudSettings"]
        for _ in 0..<4 where !toggle.isHittable || toggle.frame.maxY > app.frame.maxY - 180 { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts["请先在系统设置登录 iCloud，并开启 iCloud Drive 与密码和钥匙串。"].waitForExistence(timeout: 5), app.debugDescription)
        capture("icloud-settings", app: app)
    }

    func testNativePasteAndSettingsHero() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-paste-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let paste = app.buttons["nativePasteControl"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10), app.debugDescription)
        paste.tap()
        let expected = NSPredicate(format: "value CONTAINS %@", "三楼会议室")
        expectation(for: expected, evaluatedWith: app.textViews["sourceText"])
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["无法读取分享的文字。"].exists)
        capture("paste-after-tap", app: app)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.images["settingsCompanions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["apiURL"].exists)
        capture("settings", app: app)
    }

    func testModelSelectionAndCustomEntry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-model-list-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let api = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "模型与 API")).firstMatch
        if !api.isHittable { app.swipeUp() }
        XCTAssertTrue(api.waitForExistence(timeout: 5), app.debugDescription)
        api.tap()
        let fetch = app.buttons["fetchModels"]
        for _ in 0..<4 where !fetch.isHittable { app.swipeUp() }
        XCTAssertTrue(fetch.isHittable, app.debugDescription)
        fetch.tap()
        let model = app.buttons["model-test-chat-beta"]
        XCTAssertTrue(model.waitForExistence(timeout: 8), app.debugDescription)
        capture("model-list", app: app)
        model.tap()
        let field = app.textFields["modelName"]
        for _ in 0..<3 where !field.isHittable { app.swipeUp() }
        XCTAssertEqual(field.value as? String, "test-chat-beta")
        field.tap(); field.typeText("-custom")
        XCTAssertEqual(field.value as? String, "test-chat-beta-custom")
        app.swipeUp()
        capture("settings-api", app: app)
    }

    func testCategoryCalendarPreferenceRoutesNewDrafts() {
        let app = launchExample()
        app.tabBars.buttons["设置"].tap()
        let section = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "日历偏好")).firstMatch
        revealForReview(section, app: app); section.tap()
        let toggle = app.switches["categoryRouting"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if !toggle.isHittable { app.swipeUp() }
        toggle.tap()
        let category = app.buttons["categoryCalendar-work"]
        if !category.isHittable { app.swipeUp() }
        XCTAssertTrue(category.waitForExistence(timeout: 5), app.debugDescription)
        category.tap()
        app.buttons["工作（测试日历）"].tap()
        capture("calendar-routing", app: app)
        app.tabBars.buttons["计划"].tap()
        app.buttons["parseEvents"].tap()
        let work = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(work.waitForExistence(timeout: 8))
        XCTAssertEqual(work.value as? String, "工作，日历：工作")
        XCTAssertEqual(app.buttons["editEvent-和小林喝咖啡"].value as? String, "生活，日历：个人日程")
    }

    private func launchExample() -> XCUIApplication {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-ui-testing", "-seed-example", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    func testImportReviewSaveAndEditFlow() {
        let app = launchExample()
        let parse = app.buttons["parseEvents"]
        XCTAssertTrue(parse.waitForExistence(timeout: 10))
        parse.tap()
        let first = app.buttons["editEvent-产品设计评审"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.swipeUp()
        let second = app.buttons["editEvent-和小林喝咖啡"]
        if !second.isHittable { app.swipeUp() }
        second.tap()
        let confirm = app.buttons["confirmTime"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        if !confirm.isHittable { app.swipeUp() }
        confirm.tap()
        XCTAssertEqual(confirm.value as? String, "已确认")
        app.buttons["finishEditing"].tap()
        let save = app.buttons["saveEvents"]
        if !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.staticTexts["已将 2 个日程加入日历。"].waitForExistence(timeout: 8))
        app.swipeDown()
        if !first.isHittable { app.swipeDown() }
        first.tap()
        let title = app.textFields["eventTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("（已确认）")
        app.buttons["finishEditing"].tap()
        XCTAssertTrue(app.staticTexts["日历中的日程已更新。"].waitForExistence(timeout: 5))
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.staticTexts["2 个日程，2 个已加入日历"].waitForExistence(timeout: 5))
        capture("history", app: app)
    }

    func testPrimaryScreens() {
        let app = launchExample()
        XCTAssertTrue(app.buttons["parseEvents"].waitForExistence(timeout: 10))
        capture("home-light", app: app)
        app.buttons["parseEvents"].tap()
        XCTAssertTrue(app.buttons["editEvent-产品设计评审"].waitForExistence(timeout: 8))
        app.swipeUp()
        capture("review", app: app)
        app.buttons["editEvent-产品设计评审"].tap()
        capture("editor", app: app)
        app.buttons["取消"].tap()
        app.tabBars.buttons["设置"].tap()
        capture("settings", app: app)
    }

    func testSystemShareExtensionOCRAndCalendarSave() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-integration-testing", "-share-fixture", "-consent-fixture", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["shareFixture"].waitForExistence(timeout: 10))
        app.buttons["shareFixture"].tap()
        let activity = app.cells["拾刻计划"]
        if !activity.waitForExistence(timeout: 5) {
            let more = app.cells.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "更多", "More")).firstMatch
            if more.exists { more.tap() }
        }
        XCTAssertTrue(activity.waitForExistence(timeout: 8), app.debugDescription)
        activity.tap()
        let source = app.textViews["share-sourceText"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let recognized = NSPredicate(format: "value CONTAINS %@", "评审")
        expectation(for: recognized, evaluatedWith: source)
        waitForExpectations(timeout: 20)
        capture("share-ocr", app: app)
        let expand = app.buttons["expand-share-sourceText"]
        revealForReview(expand, app: app); expand.doubleTap()
        let expanded = app.textViews["expanded-share-sourceText"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        XCTAssertTrue((expanded.value as? String)?.contains("评审") == true)
        expanded.tap(); expanded.typeText(" ShareExpandedMarker")
        app.buttons["collapse-share-sourceText"].tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue((source.value as? String)?.contains("ShareExpandedMarker") == true)
        app.buttons["share-parseEvents"].tap()
        let allow = app.buttons["allowExtraction"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        capture("share-privacy-consent", app: app)
        revealForReview(app.buttons["declineExtraction"], app: app); app.buttons["declineExtraction"].tap()
        XCTAssertFalse(app.buttons["share-saveEvents"].exists)
        app.buttons["share-parseEvents"].tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 5)); revealForReview(allow, app: app); allow.tap()
        let save = app.buttons["share-saveEvents"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        revealForReview(save, app: app)
        // The hosted share sheet can still be rebounding after XCTest considers it idle.
        var previousFrame = save.frame
        var stableSince = Date()
        let settled = NSPredicate { _, _ in
            let frame = save.frame
            if frame != previousFrame { previousFrame = frame; stableSince = Date(); return false }
            return Date().timeIntervalSince(stableSince) >= 1 && save.isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 6), .completed)
        XCTAssertTrue(save.isEnabled, app.debugDescription)
        save.tap()
        XCTAssertTrue(app.buttons["confirmReview"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.textFields["eventTitle"].value as? String, "和小林喝咖啡")
        capture("share-guided-review", app: app)
        app.buttons["confirmReview"].tap()
        XCTAssertTrue(app.staticTexts["已将 2 个日程加入日历。"].waitForExistence(timeout: 10), app.debugDescription)
        capture("share-saved", app: app)
        app.navigationBars.buttons["完成"].firstMatch.tap()
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.staticTexts["2 个日程，2 个已加入日历"].firstMatch.waitForExistence(timeout: 8))
    }

    private func capture(_ name: String, app: XCUIApplication) {
        // The accessibility tree can become idle before the system sheet's final frame.
        if name == "editor" || name == "store-04-editor" {
            let settled = NSPredicate { _, _ in app.navigationBars["日程草稿"].frame.minY < 150 }
            let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#endif
