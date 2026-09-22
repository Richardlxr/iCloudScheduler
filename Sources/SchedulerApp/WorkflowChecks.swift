import AppKit
import SchedulerCore

@MainActor
final class FixtureCalendar: CalendarAccess {
    var hasAccess = true
    var accessRequests = 0
    var saveCount = 0
    var outcome = "saved"
    var conflictTitles: [String] = []
    var reminder: AllDayReminder?
    func requestAccess() async throws { accessRequests += 1; hasAccess = true }
    func calendars() -> [CalendarChoice] { [.init(id: "fixture-calendar", title: "测试日历", source: "本地测试")] }
    func refresh() {}
    func conflicts(for draft: Draft) throws -> [String] { conflictTitles }
    func save(_ receipt: OperationReceipt, allDayReminder: AllDayReminder) throws -> OperationReceipt {
        saveCount += 1; reminder = allDayReminder
        if outcome == "throw" { throw AppError("Synthetic calendar failure") }
        var result = receipt; result.status = outcome == "savedWarning" ? "saved" : outcome; result.message = "Synthetic \(outcome)"
        if outcome == "savedWarning" { result.warning = "Synthetic alarm mismatch" }
        return result
    }
    func reconcile(_ receipt: OperationReceipt) throws -> OperationReceipt { receipt }
    func undo(_ receipt: OperationReceipt) throws -> OperationReceipt { receipt }
}

@MainActor
private final class FixtureRequest {
    var calls = 0
    var response = Extraction(events: [.init(title: "Synthetic meeting", startLocal: "2035-06-18T14:00:00", endLocal: "2035-06-18T15:00:00", timeZone: "Asia/Shanghai")])
    var error: Error?
    var gate: CheckedContinuation<Void, Never>?
    func run() async throws -> Extraction {
        calls += 1
        await withCheckedContinuation { gate = $0 }
        if let error { throw error }
        return response
    }
    func finish() { gate?.resume(); gate = nil }
}

@MainActor
enum WorkflowChecks {
    static func reviewFixture() -> AppModel {
        let calendar = FixtureCalendar(); calendar.conflictTitles = ["已有安排 · 20:00 – 21:00"]
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/validation/ui-fixtures/\(UUID().uuidString)")
        let model = AppModel(directory: root, calendar: calendar, readKey: { _ in "fixture" }, extractor: { _, _, _, _, _, _ in
            Extraction(events: [.init(title: "班会", startLocal: "2035-09-14T20:00:00", endLocal: "2035-09-14T21:00:00", timeZone: "Asia/Shanghai", reminderMinutes: 60, assumptions: ["采用 60 分钟时长，请核对。"], source: "9.14晚上8点班会")])
        }, integrateSystem: false)
        model.calendarAuthorized = true; model.calendars = calendar.calendars(); model.preferences.calendarID = "fixture-calendar"
        model.text = "9.14晚上8点班会，提前1小时提醒"
        model.preferences.runInBackground = true
        return model
    }
    static func run() async -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") }
        }
        func settle(_ predicate: () -> Bool) async {
            for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/validation/workflow-fixtures/\(UUID().uuidString)")
        for scenario in ["confirm", "automatic", "requestFailure", "saveFailure", "uncertain", "permission", "cancel", "settingChange", "empty", "missing", "confirmConflict", "automaticConflict", "backgroundConfirmation", "savedWarning"] {
            let calendar = FixtureCalendar(), request = FixtureRequest()
            let model = AppModel(directory: root.appendingPathComponent(scenario), calendar: calendar,
                                 readKey: { _ in "synthetic-not-a-key" }, extractor: { _, _, _, _, _, _ in try await request.run() }, integrateSystem: false)
            model.text = "Synthetic input"; model.preferences.calendarID = "fixture-calendar"
            model.preferences.confirmBeforeAdding = ["confirm", "confirmConflict", "backgroundConfirmation"].contains(scenario)
            model.preferences.runInBackground = !["confirm", "confirmConflict", "settingChange"].contains(scenario)
            model.preferences.allDayReminder = AllDayReminder(daysBefore: 2, hour: 8, minute: 17)
            if scenario == "requestFailure" { request.error = URLError(.timedOut) }
            if scenario == "saveFailure" { calendar.outcome = "throw" }
            if scenario == "uncertain" { calendar.outcome = "uncertain" }
            if scenario == "savedWarning" { calendar.outcome = "savedWarning" }
            if scenario == "permission" { calendar.hasAccess = false }
            if scenario == "empty" { request.response = Extraction(events: []) }
            if scenario == "missing" { request.response.events[0].startLocal = nil }
            if scenario.hasSuffix("Conflict") { calendar.conflictTitles = ["Synthetic existing meeting"] }
            var hides = 0, alerts = 0
            model.hidePanel = { hides += 1 }
            model.panelIsVisible = { hides == 0 }
            model.presentFailure = { _, _ in alerts += 1 }
            model.analyze()
            await settle { request.gate != nil }
            if scenario == "confirm" { model.hidePanel?() }
            if scenario == "automatic" { model.analyze() }
            if scenario == "cancel" { model.cancelAnalysis() }
            if scenario == "settingChange" { model.preferences.confirmBeforeAdding = true }
            request.finish()
            await settle { !model.isGenerating }
            // Allow a cancelled task to unwind and exercise its stale-result guard.
            await Task.yield()
            switch scenario {
            case "confirm": check("manual hide preserves generation and alerts when confirmation is still required", model.stage == .review && hides == 1 && calendar.saveCount == 0 && alerts == 1)
            case "backgroundConfirmation": check("background submission overrides foreground confirmation preference", hides == 1 && calendar.saveCount == 1 && alerts == 0 && model.stage == .input && model.text.isEmpty)
            case "automatic":
                check("background submit hides and writes exactly once", hides == 1 && calendar.saveCount == 1 && request.calls == 1 && alerts == 0 && model.stage == .input && model.text.isEmpty && model.drafts.isEmpty && model.batchReceipts.isEmpty)
                check("custom all-day schedule reaches calendar writer", calendar.reminder == model.preferences.allDayReminder)
            case "requestFailure": check("background model failure raises alert and preserves input without retry", alerts == 1 && hides == 1 && request.calls == 1 && calendar.saveCount == 0 && model.text == "Synthetic input" && model.stage == .input)
            case "saveFailure": check("calendar exception raises alert and retains uncertain journal receipt", alerts == 1 && calendar.saveCount == 1 && model.batchReceipts.first?.status == "uncertain")
            case "uncertain": check("unconfirmed readback raises alert even without thrown error", alerts == 1 && calendar.saveCount == 1 && model.batchReceipts.first?.status == "uncertain")
            case "savedWarning": check("saved event with altered reminder still raises attention alert", alerts == 1 && calendar.saveCount == 1 && model.batchReceipts.first?.warning != nil)
            case "permission": check("revoked calendar permission alerts without writing", alerts == 1 && calendar.saveCount == 0 && !model.drafts.isEmpty)
            case "cancel": check("explicit cancellation neither writes nor raises failure alert", alerts == 0 && calendar.saveCount == 0 && model.stage == .input)
            case "settingChange": check("enabling confirmation during request prevents automatic write", alerts == 0 && calendar.saveCount == 0 && model.stage == .review)
            case "empty": check("empty extraction cannot fail silently in background", alerts == 1 && calendar.saveCount == 0)
            case "confirmConflict", "automaticConflict": check("conflict raises alert in \(scenario) mode and prevents writing", alerts == 1 && calendar.saveCount == 0 && model.stage == .review && model.drafts.first?.conflictAcknowledged == false)
            default: check("incomplete extraction opens attention path without partial writes", alerts == 1 && calendar.saveCount == 0 && model.stage == .review)
            }
            if ["saveFailure", "uncertain", "savedWarning"].contains(scenario) {
                check("\(scenario) retains input and result for attention", model.text == "Synthetic input" && !model.drafts.isEmpty && model.stage == .receipt)
            }
            if scenario == "automatic" {
                model.persistDraft() // Closing/reopening or quitting must not resurrect completed input.
                let reopened = AppModel(directory: root.appendingPathComponent(scenario), calendar: calendar, integrateSystem: false)
                check("background success remains blank after restart while history survives", reopened.text.isEmpty && reopened.drafts.isEmpty && reopened.stage == .input && reopened.receipts.count == 1)
            }
        }
        let calendar = FixtureCalendar()
        let model = AppModel(directory: root.appendingPathComponent("reviewActions"), calendar: calendar, integrateSystem: false)
        var draft = Draft(event: .init(title: "班会", startLocal: "2035-09-14T20:00:00", endLocal: "2035-09-14T21:00:00", timeZone: "Asia/Shanghai", assumptions: ["具体地点未提供", "按上下文推断年份"]), calendarID: "fixture-calendar")
        calendar.conflictTitles = ["已有安排"]; draft.conflicts = calendar.conflictTitles
        var closes = 0; model.hidePanel = { closes += 1 }
        model.text = "Synthetic completed input"
        model.attachments = [Attachment(name: "synthetic.txt", data: Data("fixture".utf8), kind: "txt")]
        model.questions = ["Synthetic question"]
        model.drafts = [draft]; model.stage = .review; model.persistDraft()
        check("conflict plus model assumptions expose one actionable confirmation", model.reviewActionTitle == "仍然添加" && !model.canWrite)
        model.confirmAndWriteSelected()
        check("one explicit confirmation acknowledges visible assumptions and conflicts and saves", calendar.saveCount == 1 && model.receipts.first?.status == "saved")
        check("successful explicit confirmation closes the window", closes == 1)
        check("successful confirmation clears the complete capture session", model.stage == .input && model.text.isEmpty && model.attachments.isEmpty && model.drafts.isEmpty && model.questions.isEmpty && model.batchReceipts.isEmpty && model.editingID == nil)
        model.persistDraft()
        let afterAdd = AppModel(directory: root.appendingPathComponent("reviewActions"), calendar: calendar, integrateSystem: false)
        check("confirmed add cannot reappear after restart and retains history", afterAdd.stage == .input && afterAdd.text.isEmpty && afterAdd.drafts.isEmpty && afterAdd.receipts.count == 1)
        model.confirmAndWriteSelected()
        check("repeated explicit confirmation does not duplicate a saved event", calendar.saveCount == 1)
        var incomplete = draft; incomplete.id = UUID(); incomplete.event.startLocal = nil
        model.drafts = [incomplete]; model.stage = .review
        model.confirmAndWriteSelected()
        check("incomplete schedule opens editor instead of leaving a disabled button", model.editingID == incomplete.id && calendar.saveCount == 1)
        model.editingID = nil; draft.id = UUID(); model.drafts = [draft]
        calendar.conflictTitles = ["刚刚新增的安排"]
        var alerts = 0; model.presentFailure = { _, _ in alerts += 1 }
        model.confirmAndWriteSelected()
        check("conflict changed since display requires a fresh explicit choice", alerts == 1 && calendar.saveCount == 1 && model.drafts[0].conflicts == calendar.conflictTitles)
        model.confirmAndWriteSelected()
        check("updated conflict can be added with next explicit choice", calendar.saveCount == 2)
        var keep = draft; keep.id = UUID(); keep.selected = false
        var remove = draft; remove.id = UUID()
        model.text = "Synthetic pending input"
        model.attachments = [Attachment(name: "synthetic.txt", data: Data("fixture".utf8), kind: "txt")]
        model.drafts = [keep, remove]; model.questions = ["Synthetic pending question"]; model.stage = .review
        let closesBeforeDeletion = closes
        model.deleteSelectedDrafts()
        check("delete removes only selected pending drafts without touching calendar", model.drafts.map(\.id) == [keep.id] && calendar.saveCount == 2)
        check("deleting selected drafts closes the window even with unselected drafts remaining", closes == closesBeforeDeletion + 1)
        check("partial deletion preserves unfinished input and attachments", model.stage == .review && model.text == "Synthetic pending input" && model.attachments.count == 1 && model.questions.count == 1)
        model.deleteSelectedDrafts()
        check("deleting with no selection does not finish another operation", closes == closesBeforeDeletion + 1 && model.drafts.map(\.id) == [keep.id])
        model.drafts[0].selected = true; model.deleteSelectedDrafts()
        check("deleting final pending draft returns to input", model.stage == .input && model.drafts.isEmpty && calendar.saveCount == 2)
        check("deleting final pending draft closes the window", closes == closesBeforeDeletion + 2)
        check("final deletion clears text attachments and prior results", model.text.isEmpty && model.attachments.isEmpty && model.questions.isEmpty && model.batchReceipts.isEmpty)
        model.persistDraft()
        let afterDelete = AppModel(directory: root.appendingPathComponent("reviewActions"), calendar: calendar, integrateSystem: false)
        check("deleted session cannot reappear after restart and history is retained", afterDelete.stage == .input && afterDelete.text.isEmpty && afterDelete.drafts.isEmpty && afterDelete.receipts.count == 2)

        let partialDirectory = root.appendingPathComponent("partialAdd")
        let partial = AppModel(directory: partialDirectory, calendar: FixtureCalendar(), integrateSystem: false)
        partial.preferences.checkConflicts = false; partial.text = "Synthetic two-event input"
        partial.drafts = [remove, keep]; partial.stage = .review
        partial.refreshConflicts(notify: false)
        partial.confirmAndWriteSelected()
        check("partial add removes only completed drafts and keeps unfinished review", partial.stage == .review && partial.drafts.map(\.id) == [keep.id] && partial.text == "Synthetic two-event input" && partial.batchReceipts.isEmpty && partial.receipts.count == 1)
        let afterPartial = AppModel(directory: partialDirectory, calendar: FixtureCalendar(), integrateSystem: false)
        check("restart restores only unprocessed drafts after partial add", afterPartial.drafts.map(\.id) == [keep.id] && afterPartial.stage == .review)
        do {
            let legacyDirectory = root.appendingPathComponent("completedRecovery")
            let local = try LocalStore(directory: legacyDirectory)
            var completedReceipt = OperationReceipt(batchID: UUID(), draft: remove); completedReceipt.status = "saved"
            try local.record(completedReceipt)
            try local.saveDraft(.init(text: "Synthetic previously completed input", drafts: [remove], questions: []))
            let recovered = AppModel(directory: legacyDirectory, calendar: FixtureCalendar(), integrateSystem: false)
            let saved = try local.loadDraft()
            check("journal recovery clears completed input left by older versions or interrupted cleanup", recovered.stage == .input && recovered.text.isEmpty && recovered.drafts.isEmpty && saved == nil && recovered.receipts.count == 1)
        } catch { check("journal recovery clears completed input left by older versions or interrupted cleanup", false) }
        calendar.hasAccess = false; model.drafts = [draft]; model.stage = .review
        check("missing permission gives the primary button a concrete authorization action", model.reviewActionTitle == "允许日历访问")
        model.confirmAndWriteSelected()
        await settle { calendar.accessRequests == 1 }
        check("permission request refreshes calendars without silently adding the draft", calendar.accessRequests == 1 && model.calendarAuthorized && calendar.saveCount == 2)
        let updateDirectory = root.appendingPathComponent("updateRestart")
        let updateModel = AppModel(directory: updateDirectory, calendar: FixtureCalendar(), integrateSystem: false)
        func restartRejected() -> Bool {
            do { try updateModel.prepareForUpdateRestart(); return false } catch { return true }
        }
        updateModel.text = "Synthetic unsent input"; updateModel.preferences.keepDraft = false
        check("update cannot discard input when draft retention is disabled", restartRejected())
        updateModel.preferences.keepDraft = true
        updateModel.attachments = [Attachment(name: "synthetic.txt", data: Data("fixture".utf8), kind: "txt")]
        check("update cannot discard an unprocessed attachment", restartRejected())
        updateModel.attachments = []; updateModel.editingID = UUID()
        check("update cannot interrupt an open event editor", restartRejected())
        updateModel.editingID = nil; updateModel.writing = true
        check("update restart is blocked during calendar write", restartRejected())
        let updater = AppUpdater(model: updateModel)
        var installs = 0
        check("Sparkle installation is deferred while app work is active", updater.postponeInstallationIfBusy { installs += 1 } && installs == 0)
        updateModel.writing = false; updateModel.testing = true
        await Task.yield()
        check("deferred update still waits for model connection testing", installs == 0)
        updateModel.testing = false
        await settle { installs == 1 }
        updateModel.activityLabel = "idle"
        await Task.yield()
        check("deferred install resumes exactly once after work finishes", installs == 1)
        do {
            try updateModel.prepareForUpdateRestart()
            let reopened = AppModel(directory: updateDirectory, calendar: FixtureCalendar(), integrateSystem: false)
            check("update persists and restores unfinished text", reopened.text == "Synthetic unsent input" && reopened.preferences.keepDraft)
        } catch { check("update persists and restores unfinished text", false) }
        updateModel.preferences.keepDraft = false; updateModel.text = ""; updateModel.drafts = []
        check("idle update respects disabled draft retention", !restartRejected())
        for scenario in ["success", "failure", "cancel", "multiple", "missing", "emptyInput", "reset"] {
            let request = FixtureRequest(), calendar = FixtureCalendar()
            var capturedInput = ""
            let model = AppModel(directory: root.appendingPathComponent("refine-" + scenario), calendar: calendar,
                readKey: { _ in "fixture" }, extractor: { input, _, _, _, _, _ in
                    capturedInput = input.text; return try await request.run()
                }, integrateSystem: false)
            let original = Draft(event: .init(title: "待补充安排", timeZone: "Asia/Shanghai", missing: ["具体时间"]), calendarID: "fixture-calendar")
            let other = Draft(event: .init(title: "无关安排", startLocal: "2035-06-19T14:00:00", endLocal: "2035-06-19T15:00:00", timeZone: "Asia/Shanghai"), calendarID: "other-calendar")
            model.drafts = [original, other]; model.text = "两条原始安排"; model.stage = .review
            model.preferences.runInBackground = true; model.preferences.confirmBeforeAdding = false
            if scenario == "failure" { request.error = URLError(.timedOut) }
            if scenario == "multiple" { request.response.events.append(request.response.events[0]) }
            if scenario == "missing" { request.response.events[0].startLocal = nil; request.response.events[0].missing = ["日期"] }
            if scenario == "emptyInput" { model.drafts = []; model.questions = ["请补充安排"] }
            model.refineDraft(scenario == "emptyInput" ? nil : original.id, instruction: "2035年6月18日下午2点提醒我")
            await settle { request.gate != nil }
            check("refinement blocks writes while active \(scenario)", model.isGenerating && !model.canWrite)
            if scenario == "cancel" { model.cancelAnalysis() }
            if scenario == "reset" { model.resetInput() }
            request.finish(); await settle { !model.isGenerating }; await Task.yield()
            check("refinement never writes automatically \(scenario)", calendar.saveCount == 0)
            if scenario == "reset" {
                check("reset discards stale refinement response", model.drafts.isEmpty && model.text.isEmpty && model.stage == .input)
            } else if scenario == "emptyInput" {
                check("empty extraction can be completed in place", model.drafts.count == 1 && model.questions.isEmpty && model.stage == .review)
            } else {
                check("refinement preserves unrelated draft and excludes it from model context \(scenario)", model.drafts[1] == other && !capturedInput.contains("无关安排"))
                if ["failure", "cancel", "multiple"].contains(scenario) {
                    check("unsuccessful refinement retains original \(scenario)", model.drafts[0] == original && model.stage == .review)
                } else {
                    check("refinement preserves draft identity and destination \(scenario)", model.drafts[0].id == original.id && model.drafts[0].calendarID == original.calendarID && !model.drafts[0].reviewed)
                    if scenario == "missing" { check("unresolved refinement remains blocked", !model.canWrite) }
                }
            }
        }
        // A group-chat chase-up carries no clock time: the timeframe is resolved locally and stays addable.
        for mode in ["background", "confirm"] {
            let hintCalendar = FixtureCalendar()
            var calls = 0, hides = 0, hintAlerts = 0
            let hintModel = AppModel(directory: root.appendingPathComponent("dueHint-" + mode), calendar: hintCalendar,
                                     readKey: { _ in "fixture" }, extractor: { _, _, _, now, zone, _ in
                calls += 1
                // Mirrors LLMClient.extract, which resolves the timeframe against the same reference clock.
                return TimingResolver.apply(to: Extraction(events: [.init(title: "办理团组织关系转入", startLocal: nil, endLocal: nil,
                                                                         timeZone: zone, reminderMinutes: 0, missing: ["具体时间"],
                                                                         source: "请尽快办理", dueHint: "asap")]),
                                            now: now, fallbackTimeZone: zone)
            }, integrateSystem: false)
            hintModel.preferences.calendarID = "fixture-calendar"
            hintModel.preferences.runInBackground = mode == "background"
            hintModel.preferences.confirmBeforeAdding = mode == "confirm"
            hintModel.hidePanel = { hides += 1 }; hintModel.panelIsVisible = { hides == 0 }
            hintModel.presentFailure = { _, _ in hintAlerts += 1 }
            hintModel.text = "@胡家瑜 计科2631 @刘欣睿 计科2631 两位还没有办理团组织关系转入，请尽快办理"
            hintModel.analyze()
            await settle { !hintModel.isGenerating && (hintCalendar.saveCount > 0 || hintModel.stage == .review) }
            await Task.yield()
            if mode == "background" {
                check("a chase-up with only 尽快 is added from one model call", hintCalendar.saveCount == 1 && calls == 1 && hintAlerts == 0 && hintModel.stage == .input)
            } else {
                check("a resolved timeframe reaches confirmation with its origin visible",
                      hintModel.stage == .review && hintCalendar.saveCount == 0 && hintModel.canWrite
                      && DraftValidator.reviewNotes(hintModel.drafts[0]).contains { $0.contains("尽快") })
            }
        }
        let quickModel = AppModel(directory: root.appendingPathComponent("quickTime"), calendar: FixtureCalendar(), integrateSystem: false)
        quickModel.preferences.calendarID = "fixture-calendar"
        quickModel.preferences.checkConflicts = false
        let undated = Draft(event: .init(title: "交材料", startLocal: nil, timeZone: "Asia/Shanghai", reminderMinutes: nil, missing: ["具体时间"]), calendarID: "fixture-calendar")
        quickModel.drafts = [undated]; quickModel.stage = .review
        quickModel.applyQuickTime(.tomorrow, to: undated.id)
        check("one tap fills a missing time locally and leaves the draft addable",
              quickModel.drafts[0].event.startLocal != nil && quickModel.drafts[0].event.missing.isEmpty
              && quickModel.drafts[0].event.isPointReminder && quickModel.canWrite && !quickModel.drafts[0].reviewed)
        check("the local timing choice explains itself in the review note",
              DraftValidator.reviewNotes(quickModel.drafts[0]).contains { $0.contains("明天") })
        let filled = quickModel.drafts[0].event
        quickModel.isDemo = true
        quickModel.applyQuickTime(.asap, to: undated.id)
        check("the interface example cannot be edited by the timing shortcuts", quickModel.drafts[0].event == filled)
        quickModel.isDemo = false
        let attachmentModel = AppModel(directory: root.appendingPathComponent("visionGate"), calendar: FixtureCalendar(),
                                       readKey: { _ in "fixture" }, extractor: { _, _, _, _, _, _ in Extraction(events: []) }, integrateSystem: false)
        attachmentModel.text = "看附件"
        let noticeView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        noticeView.string = "教务通知：请各班在本周内完成学业指导会的报名登记，逾期不再受理。"
        attachmentModel.attachments = [Attachment(name: "notice.pdf", data: noticeView.dataWithPDF(inside: noticeView.bounds),
                                                  kind: "pdf", pageCount: 1, firstPage: 1, lastPage: 1,
                                                  hasTextLayer: true, sendAsText: true)]
        var gateAlerts: [String] = []
        attachmentModel.presentFailure = { title, _ in gateAlerts.append(title) }
        attachmentModel.analyze()
        await settle { !attachmentModel.isGenerating }
        check("a text PDF does not require a verified vision model", !gateAlerts.contains("无法开始生成"))
        attachmentModel.attachments[0].sendAsText = false
        gateAlerts = []
        attachmentModel.analyze()
        await settle { !attachmentModel.isGenerating }
        check("a rasterized PDF still requires a verified vision model", gateAlerts == ["无法开始生成"])
        print("\n\(passed) workflow checks passed, \(failed) failed. Injected model and calendar only; no network, Keychain or real calendar access.")
        return failed == 0 ? 0 : 1
    }
}
