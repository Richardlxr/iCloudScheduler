import Foundation
import SchedulerCore

var passed = 0
var failed = 0
func check(_ name: String, _ operation: () throws -> Bool) {
    do { if try operation() { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") } }
    catch { failed += 1; print("FAIL \(name): \(error.localizedDescription)") }
}
func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
let zone = "Asia/Shanghai"
let event = ExtractedEvent(title: "会议", startLocal: "2030-06-18T14:00:00", endLocal: "2030-06-18T15:00:00", timeZone: zone)
let draft = Draft(event: event, calendarID: "test-only")
let now = Date(timeIntervalSince1970: 1893456000)

check("valid time interval") { try Temporal.interval(event).duration == 3600 }
check("start-only reminder is valid and stores one minute") {
    var reminder = event; reminder.endLocal = nil; reminder.reminderMinutes = 0
    return try Temporal.interval(reminder).duration == 60 && DraftValidator.errors(Draft(event: reminder, calendarID: "test"), now: now).isEmpty
}
check("start-only still rejects invalid dates") {
    var reminder = event; reminder.endLocal = nil; reminder.startLocal = "2030-02-30T14:00:00"
    return rejects { _ = try Temporal.interval(reminder) }
}
check("explicit end before start is not converted to a reminder") {
    var reminder = event; reminder.endLocal = "2030-06-18T13:00:00"
    return rejects { _ = try Temporal.interval(reminder) }
}
check("all-day missing end still blocks") {
    var reminder = event; reminder.allDay = true; reminder.startLocal = "2030-06-18"; reminder.endLocal = nil
    return rejects { _ = try Temporal.interval(reminder) }
}
check("menu bar preference survives relaunch") {
    var preferences = AppPreferences(); preferences.showMenuBar = false
    return try !JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).showMenuBar
}
check("invalid leap day") { rejects { _ = try Temporal.parse("2025-02-29T12:00:00", timeZone: zone, allDay: false) } }
check("valid leap day") { _ = try Temporal.parse("2028-02-29T12:00:00", timeZone: zone, allDay: false); return true }
check("invalid month") { rejects { _ = try Temporal.parse("2026-13-01T12:00:00", timeZone: zone, allDay: false) } }
check("invalid hour") { rejects { _ = try Temporal.parse("2026-09-12T24:00:00", timeZone: zone, allDay: false) } }
check("invalid time zone") { rejects { _ = try Temporal.parse("2026-09-12T12:00:00", timeZone: "not/a-zone", allDay: false) } }
check("DST nonexistent local time") { rejects { _ = try Temporal.parse("2026-03-08T02:30:00", timeZone: "America/New_York", allDay: false) } }
check("DST repeated local time") { rejects { _ = try Temporal.parse("2026-11-01T01:30:00", timeZone: "America/New_York", allDay: false) } }
check("DST normal local time") { _ = try Temporal.parse("2026-11-01T03:30:00", timeZone: "America/New_York", allDay: false); return true }
check("all-day DST day is 23 hours") {
    let start = try Temporal.parse("2026-03-08", timeZone: "America/New_York", allDay: true)
    let end = try Temporal.parse("2026-03-09", timeZone: "America/New_York", allDay: true)
    return end.timeIntervalSince(start) == 23 * 3600
}
check("all-day end is exclusive") { var e = event; e.allDay = true; e.startLocal = "2030-06-18"; e.endLocal = "2030-06-18"; return rejects { _ = try Temporal.interval(e) } }
check("all-day alarm keeps 9am across spring DST") {
    let start = try Temporal.parse("2026-03-08", timeZone: "America/New_York", allDay: true)
    let alarm = try Temporal.allDayAlarm(start: start, timeZone: "America/New_York", minutes: 540)!
    return Temporal.format(alarm, timeZone: "America/New_York") == "2026-03-08T09:00:00" && alarm.timeIntervalSince(start) == 8 * 3600
}
check("all-day previous-day alarm crosses DST correctly") {
    let start = try Temporal.parse("2026-03-09", timeZone: "America/New_York", allDay: true)
    let alarm = try Temporal.allDayAlarm(start: start, timeZone: "America/New_York", minutes: -360)!
    return Temporal.format(alarm, timeZone: "America/New_York") == "2026-03-08T18:00:00"
}
check("all-day disabled alarm stays disabled") { try Temporal.allDayAlarm(start: now, timeZone: zone, minutes: -1) == nil }
check("past reminder on future event requires review") {
    let shortlyBefore = try Temporal.interval(event).start.addingTimeInterval(-60)
    return !DraftValidator.errors(draft, now: shortlyBefore).isEmpty
}
check("missing time blocks") { var d = draft; d.event.startLocal = nil; return !DraftValidator.errors(d, now: now).isEmpty }
check("title blocks") { var d = draft; d.event.title = " "; return !DraftValidator.errors(d, now: now).isEmpty }
check("calendar required") { var d = draft; d.calendarID = ""; return !DraftValidator.errors(d, now: now).isEmpty }
check("manual editing does not require calendar yet") { var d = draft; d.calendarID = ""; return DraftValidator.errors(d, now: now, requireCalendar: false).isEmpty }
check("missing fields block") { var d = draft; d.event.missing = ["来源日期"]; return !DraftValidator.errors(d, now: now).isEmpty }
check("unreviewed assumptions block") { var d = draft; d.event.assumptions = ["采用默认时长"]; return !DraftValidator.errors(d, now: now).isEmpty }
check("reviewed assumptions accepted") { var d = draft; d.event.assumptions = ["采用默认时长"]; d.reviewed = true; return DraftValidator.errors(d, now: now).isEmpty }
check("negative reminder rejected") { var d = draft; d.event.reminderMinutes = -5; return !DraftValidator.errors(d, now: now).isEmpty }
check("oversized reminder rejected") { var d = draft; d.event.reminderMinutes = 10081; return !DraftValidator.errors(d, now: now).isEmpty }
check("untrusted integer extremes cannot overflow reminder math") { var d = draft; d.event.reminderMinutes = Int.max; return !DraftValidator.errors(d, now: now).isEmpty }
check("no reminder accepted") { var d = draft; d.event.reminderMinutes = nil; return DraftValidator.errors(d, now: now).isEmpty }
check("conflict requires acknowledgment") { var d = draft; d.conflicts = ["已有会议"]; return !DraftValidator.errors(d, now: now).isEmpty }
check("conflict explicitly acknowledged") { var d = draft; d.conflicts = ["已有会议"]; d.conflictAcknowledged = true; return DraftValidator.errors(d, now: now).isEmpty }
check("past date requires review") { !DraftValidator.errors(draft, now: Date(timeIntervalSince1970: 2208988800)).isEmpty }

check("explicit review accepts assumptions and conflict without hiding the underlying conditions") {
    var d = draft; d.event.assumptions = ["采用默认时长"]; d.conflicts = ["已有会议"]
    return DraftValidator.errorsAfterReview(d, now: now).isEmpty && !DraftValidator.errors(d, now: now).isEmpty && DraftValidator.reviewNotes(d, now: now) == d.event.assumptions
}
check("explicit review cannot bypass invalid dates or missing fields") {
    var d = draft; d.event.startLocal = nil
    var missing = draft; missing.event.missing = ["日期矛盾"]
    return !DraftValidator.errorsAfterReview(d, now: now).isEmpty && !DraftValidator.errorsAfterReview(missing, now: now).isEmpty
}
check("past reminder is visible as a concrete review note") {
    let shortlyBefore = try Temporal.interval(event).start.addingTimeInterval(-60)
    return !DraftValidator.reviewNotes(draft, now: shortlyBefore).isEmpty && DraftValidator.errorsAfterReview(draft, now: shortlyBefore).isEmpty
}
check("base prefix is preserved") { try Endpoint.url(base: "https://example.com/team/v1/").absoluteString == "https://example.com/team/v1/chat/completions" }
check("full endpoint not doubled") { try Endpoint.url(base: "https://example.com/v1/chat/completions").absoluteString == "https://example.com/v1/chat/completions" }
check("model discovery from full endpoint") { try Endpoint.url(base: "https://example.com/v1/chat/completions", resource: "models").absoluteString == "https://example.com/v1/models" }
for base in ["http://example.com", "https://user:secret@example.com/v1", "https://example.com/v1?api_key=secret", "https://example.com/v1#fragment", "https://example.com/v1/responses", "https://example.com/v1/messages", "garbage"] {
    check("unsafe/unsupported endpoint rejected: \(base.components(separatedBy: "?")[0])") { rejects { _ = try Endpoint.url(base: base) } }
}
for preset in ProviderPreset.all where preset.id != "custom" { check("preset endpoint: \(preset.name)") { _ = try Endpoint.url(base: preset.baseURL); return !preset.model.isEmpty } }

let validJSON = #"{"events":[{"title":"会议","startLocal":"2030-06-18T14:00:00","endLocal":"2030-06-18T15:00:00","timeZone":"Asia/Shanghai","allDay":false,"location":"","notes":"","reminderMinutes":15,"missing":[],"assumptions":[],"source":"会议"}],"questions":[]}"#
check("strict extraction decoded") { try ExtractionDecoder.decode(validJSON).events.count == 1 }
check("event response rejects extra conversational questions") { rejects { _ = try ExtractionDecoder.decode(validJSON.replacingOccurrences(of: "\"questions\":[]", with: "\"questions\":[\"线上还是线下？\"]")) } }
check("fenced JSON decoded without arbitrary slicing") { try ExtractionDecoder.decode("```json\n" + validJSON + "\n```").events.count == 1 }
check("surrounding prose rejected") { rejects { _ = try ExtractionDecoder.decode("Here's your plan: " + validJSON) } }
check("extra action field rejected") { rejects { _ = try ExtractionDecoder.decode(validJSON.replacingOccurrences(of: "\"questions\":[]", with: "\"questions\":[],\"writeCalendar\":true")) } }
check("item calendar injection rejected") { rejects { _ = try ExtractionDecoder.decode(validJSON.replacingOccurrences(of: "\"title\":", with: "\"calendarID\":\"attacker\",\"title\":")) } }
check("truncated JSON rejected") { rejects { _ = try ExtractionDecoder.decode(String(validJSON.dropLast())) } }
check("nullable fields preserved") { try ExtractionDecoder.decode(validJSON.replacingOccurrences(of: "\"2030-06-18T14:00:00\"", with: "null")).events.first?.startLocal == nil }
check("200 HTML is not a successful model response") { rejects { _ = try LLMClient.responseContent(Data("<html>login</html>".utf8)) } }
check("empty model content rejected") { rejects { _ = try LLMClient.responseContent(Data(#"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#.utf8)) } }
check("truncated model content rejected") { rejects { _ = try LLMClient.responseContent(Data(#"{"choices":[{"message":{"content":"{}"},"finish_reason":"length"}]}"#.utf8)) } }
check("final answer decoded") { try LLMClient.responseContent(Data(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#.utf8)) == "ok" }
check("config mutation invalidates all capabilities") { var c = ProviderConfig(preset: ProviderPreset.all[0]); let before = c.credentialVersion; c.textVerified = Date(); c.imageVerified = Date(); c.invalidate(); return c.textVerified == nil && c.imageVerified == nil && c.credentialVersion != before }
check("operation identity is app generated") { OperationReceipt(batchID: UUID(), draft: draft).marker.hasPrefix("[iCloudScheduler:") }
check("old preferences keep explicit submission and confirmation defaults") {
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences())) as! [String: Any]
    for key in ["confirmationRequired", "submitWithEnter", "hideAfterSubmit", "customAllDayReminder", "menuBarVisible"] { old.removeValue(forKey: key) }
    old["activeProvider"] = "minimax"; old["allDayReminderMinutes"] = -360
    let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: old))
    return restored.showMenuBar && restored.confirmBeforeAdding && !restored.enterSubmits && !restored.runInBackground && restored.activeProvider == "minimax" && restored.allDayReminder == AllDayReminder(daysBefore: 1, hour: 18)
}
check("new workflow settings and custom reminder survive relaunch") {
    var p = AppPreferences(); p.confirmBeforeAdding = false; p.enterSubmits = true; p.runInBackground = true
    p.allDayReminder = AllDayReminder(daysBefore: 3, hour: 7, minute: 23)
    let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(p))
    return !restored.confirmBeforeAdding && restored.enterSubmits && restored.runInBackground && restored.allDayReminder == p.allDayReminder
}
check("old disabled all-day reminders remain disabled") { !AllDayReminder(legacyMinutes: -1).enabled }
check("complete unambiguous batch can be added automatically") { DraftValidator.canAddAutomatically([draft], questions: [], now: now) }
check("empty extraction cannot silently succeed") { !DraftValidator.canAddAutomatically([], questions: [], now: now) }
check("unanswered extraction question blocks automatic batch") { !DraftValidator.canAddAutomatically([draft], questions: ["哪一天？"], now: now) }
check("one incomplete item blocks the entire automatic batch") { var bad = draft; bad.event.startLocal = nil; return !DraftValidator.canAddAutomatically([draft, bad], questions: [], now: now) }
check("automatic path does not approve assumptions") { var d = draft; d.event.assumptions = ["默认时长"]; return !DraftValidator.canAddAutomatically([d], questions: [], now: now) }
check("automatic path does not approve calendar conflicts") { var d = draft; d.conflicts = ["已有安排"]; return !DraftValidator.canAddAutomatically([d], questions: [], now: now) }
check("custom all-day reminder supports arbitrary minute and days") {
    let start = try Temporal.parse("2030-06-18", timeZone: zone, allDay: true)
    let alarm = try Temporal.allDayAlarm(start: start, timeZone: zone, reminder: AllDayReminder(daysBefore: 3, hour: 7, minute: 23))!
    return Temporal.format(alarm, timeZone: zone) == "2030-06-15T07:23:00"
}
check("previous-day 23:59 is distinct from disabled") {
    let start = try Temporal.parse("2030-06-18", timeZone: zone, allDay: true)
    let alarm = try Temporal.allDayAlarm(start: start, timeZone: zone, reminder: AllDayReminder(daysBefore: 1, hour: 23, minute: 59))!
    return Temporal.format(alarm, timeZone: zone) == "2030-06-17T23:59:00"
}
check("custom clock time stays local across DST") {
    let start = try Temporal.parse("2026-03-09", timeZone: "America/New_York", allDay: true)
    let alarm = try Temporal.allDayAlarm(start: start, timeZone: "America/New_York", reminder: AllDayReminder(daysBefore: 1, hour: 7, minute: 23))!
    return Temporal.format(alarm, timeZone: "America/New_York") == "2026-03-08T07:23:00"
}
check("nonexistent custom reminder clock time is not silently shifted") {
    let start = try Temporal.parse("2026-03-08", timeZone: "America/New_York", allDay: true)
    return rejects { _ = try Temporal.allDayAlarm(start: start, timeZone: "America/New_York", reminder: AllDayReminder(hour: 2, minute: 30)) }
}
check("invalid custom reminder cannot overflow date arithmetic") {
    rejects { _ = try Temporal.allDayAlarm(start: now, timeZone: zone, reminder: AllDayReminder(daysBefore: Int.max)) }
}
print("\n\(passed) passed, \(failed) failed. Offline checks only; no API keys or calendars accessed.")
if failed > 0 { exit(1) }
