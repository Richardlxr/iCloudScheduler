import AppKit
import SchedulerCore

@MainActor
private final class FixtureCalendar: CalendarAccess {
    var hasAccess = true
    var saveCount = 0
    var outcome = "saved"
    var conflictTitles: [String] = []
    var reminder: AllDayReminder?
    func requestAccess() async throws {}
    func calendars() -> [CalendarChoice] { [] }
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
            case "backgroundConfirmation": check("background submission overrides foreground confirmation preference", hides == 1 && calendar.saveCount == 1 && alerts == 0 && model.stage == .receipt)
            case "automatic":
                check("background submit hides and writes exactly once", hides == 1 && calendar.saveCount == 1 && request.calls == 1 && alerts == 0 && model.stage == .receipt)
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
        }
        print("\n\(passed) workflow checks passed, \(failed) failed. Injected model and calendar only; no network, Keychain or real calendar access.")
        return failed == 0 ? 0 : 1
    }
}
