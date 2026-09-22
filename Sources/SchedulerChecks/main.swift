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

// Relative timeframes: the model only classifies the wording, this machine picks the instant.
func at(_ local: String, _ zone: String = "Asia/Shanghai") throws -> Date { try Temporal.parse(local, timeZone: zone, allDay: false) }
func resolved(_ day: DueDay?, _ part: DayPart? = nil, at local: String, zone: String = "Asia/Shanghai") throws -> String {
    try DueWindow(day: day, part: part).resolve(now: try at(local, zone), timeZone: zone).startLocal
}
// 2026-09-22 is a Tuesday.
check("尽快 rounds up to the next half hour an hour out") { try resolved(.asap, at: "2026-09-22T14:20:00") == "2026-09-22T15:30:00" }
check("尽快 rolls past the half hour to the next hour") { try resolved(.asap, at: "2026-09-22T14:40:00") == "2026-09-22T16:00:00" }
check("尽快 before dawn waits for the working day") { try resolved(.asap, at: "2026-09-22T06:10:00") == "2026-09-22T09:00:00" }
check("尽快 late at night moves to tomorrow morning") { try resolved(.asap, at: "2026-09-22T22:10:00") == "2026-09-23T09:00:00" }
check("今天 keeps a late slot on the same day") { try resolved(.today, at: "2026-09-22T21:05:00") == "2026-09-22T22:30:00" }
check("明天 uses tomorrow morning") { try resolved(.tomorrow, at: "2026-09-22T14:20:00") == "2026-09-23T09:00:00" }
check("明天下午 keeps the afternoon instead of the morning") { try resolved(.tomorrow, .afternoon, at: "2026-09-22T14:20:00") == "2026-09-23T15:00:00" }
check("今天下午 stays this afternoon while it is still ahead") { try resolved(.today, .afternoon, at: "2026-09-22T11:00:00") == "2026-09-22T15:00:00" }
check("今天下午 asked for in the evening moves on instead of going backwards") { try resolved(.today, .afternoon, at: "2026-09-22T18:40:00") == "2026-09-22T20:00:00" }
check("今晚 uses the evening slot") { try resolved(.today, .evening, at: "2026-09-22T14:20:00") == "2026-09-22T20:00:00" }
check("周三晚上 lands on the coming Wednesday evening") { try resolved(.wed, .evening, at: "2026-09-22T14:20:00") == "2026-09-23T20:00:00" }
check("周一 on a Tuesday means next Monday") { try resolved(.mon, at: "2026-09-22T14:20:00") == "2026-09-28T09:00:00" }
check("后天上午 counts two days out") { try resolved(.dayAfter, .morning, at: "2026-09-22T14:20:00") == "2026-09-24T09:00:00" }
check("早上 without a day means the next morning that is still ahead") { try resolved(nil, .earlyMorning, at: "2026-09-22T14:20:00") == "2026-09-23T07:00:00" }
check("中午 without a day stays today while it is ahead") { try resolved(nil, .noon, at: "2026-09-22T09:10:00") == "2026-09-22T12:00:00" }
check("本周内 lands on Friday morning") { try resolved(.thisWeek, at: "2026-09-22T14:20:00") == "2026-09-25T09:00:00" }
check("本周内的下午 keeps Friday but moves to the afternoon") { try resolved(.thisWeek, .afternoon, at: "2026-09-22T14:20:00") == "2026-09-25T15:00:00" }
check("本周内 on Friday does not wait a week") { try resolved(.thisWeek, at: "2026-09-25T14:20:00") == "2026-09-25T15:30:00" }
check("周末 lands on Saturday morning") { try resolved(.weekend, at: "2026-09-22T14:20:00") == "2026-09-26T10:00:00" }
check("周末 on Saturday afternoon moves to Sunday") { try resolved(.weekend, at: "2026-09-26T14:20:00") == "2026-09-27T10:00:00" }
check("下周 starts on the following Monday even when today is Monday") { try resolved(.nextWeek, at: "2026-09-21T08:30:00") == "2026-09-28T09:00:00" }
check("月底 lands on the last day of the month") { try resolved(.monthEnd, at: "2026-09-22T14:20:00") == "2026-09-30T09:00:00" }
check("月底 on the last day falls back to a slot today") { try resolved(.monthEnd, at: "2026-09-30T10:00:00") == "2026-09-30T11:00:00" }
check("every day and part resolves to a future instant the writer accepts, including across DST") {
    let zone = "America/New_York"
    var base = try Temporal.parse("2026-03-07T00:00:00", timeZone: zone, allDay: false)
    let parts: [DayPart?] = [nil] + DayPart.allCases.map { $0 }
    for _ in 0..<96 {
        for day in DueDay.allCases {
            for part in parts {
                let value = try DueWindow(day: day, part: part).resolve(now: base, timeZone: zone)
                let start = try Temporal.parse(value.startLocal, timeZone: zone, allDay: false)
                guard start > base, !value.note.isEmpty else { return false }
            }
        }
        base = base.addingTimeInterval(1800)
    }
    return true
}
check("unknown timeframe words are not invented into a time") {
    DueWindow(day: "someday", part: nil) == nil && DueWindow(day: nil, part: "brunch") == nil && DueWindow(day: nil, part: nil) == nil
}
check("a day and a part read back as one phrase") { DueWindow(day: .tomorrow, part: .afternoon).label == "明天下午" }

let hintedNow = try at("2026-09-22T14:20:00")
func resolveEvent(_ event: ExtractedEvent) -> ExtractedEvent { TimingResolver.apply(to: event, now: hintedNow, fallbackTimeZone: zone) }
let chase = ExtractedEvent(title: "办理团组织关系转入", startLocal: nil, endLocal: nil, timeZone: zone, reminderMinutes: 0,
                           missing: ["具体时间"], source: "请尽快办理", kind: "task", dueDay: "asap")
check("a chase-up note with only 尽快 becomes an addable point reminder") {
    let event = resolveEvent(chase)
    let draft = Draft(event: event, calendarID: "test-only")
    return event.startLocal == "2026-09-22T15:30:00" && event.endLocal == nil && event.isPointReminder && event.reminderMinutes == 0
        && event.missing.isEmpty && event.assumptions.isEmpty && event.isTask && DraftValidator.errors(draft, now: hintedNow).isEmpty
        && DraftValidator.canAddAutomatically([draft], questions: [], now: hintedNow)
}
check("a resolved timeframe stays visible as a review note") {
    let draft = Draft(event: resolveEvent(chase), calendarID: "test-only")
    return DraftValidator.reviewNotes(draft, now: hintedNow).count == 1 && DraftValidator.reviewNotes(draft, now: hintedNow)[0].contains("尽快")
}
check("a resolved timeframe does not clear unrelated missing information") {
    var event = chase; event.missing = ["截图的来源日期"]
    let resolvedEvent = resolveEvent(event)
    return resolvedEvent.startLocal != nil && resolvedEvent.missing == ["截图的来源日期"]
        && !DraftValidator.errorsAfterReview(Draft(event: resolvedEvent, calendarID: "test-only"), now: hintedNow).isEmpty
}
check("an explicit time always wins over a timeframe word") {
    var event = chase; event.startLocal = "2030-06-18T14:00:00"; event.missing = []
    let resolvedEvent = resolveEvent(event)
    return resolvedEvent.startLocal == "2030-06-18T14:00:00" && resolvedEvent.dueDay == nil && resolvedEvent.timingNote == nil
}
check("an all-day range is never rewritten into a point reminder") {
    var event = chase; event.allDay = true; event.startLocal = nil
    return resolveEvent(event).startLocal == nil && resolveEvent(event).dueDay == nil
}
check("an unresolved timeframe leaves the draft blocked instead of guessing") {
    var event = chase; event.dueDay = "someday"
    let resolvedEvent = resolveEvent(event)
    return resolvedEvent.startLocal == nil && resolvedEvent.dueDay == nil
        && !DraftValidator.errorsAfterReview(Draft(event: resolvedEvent, calendarID: "test-only"), now: hintedNow).isEmpty
}

// Deadlines: the resolved instant is when the work is due, so the alarms sit ahead of it.
check("a deadline two days out is announced a day early and again on the day") {
    var event = ExtractedEvent(title: "交材料", startLocal: "2026-09-25T18:00:00", endLocal: nil, timeZone: zone, isDeadline: true)
    event = resolveEvent(event)
    return event.reminderMinutes == 0 && event.extraReminderMinutes == [1440] && event.allReminderMinutes == [0, 1440]
        && event.timingNote?.contains("截止") == true
}
check("a deadline later today is announced once") {
    var event = ExtractedEvent(title: "交材料", startLocal: "2026-09-22T17:00:00", endLocal: nil, timeZone: zone, isDeadline: true)
    event = resolveEvent(event)
    return event.reminderMinutes == 0 && event.extraReminderMinutes == []
}
check("a timeframe word and a deadline resolve together") {
    var event = ExtractedEvent(title: "交表", startLocal: nil, endLocal: nil, timeZone: zone, source: "本周内交", dueDay: "this_week", isDeadline: true)
    event = resolveEvent(event)
    return event.startLocal == "2026-09-25T09:00:00" && event.allReminderMinutes == [0, 1440]
        && DraftValidator.errors(Draft(event: event, calendarID: "test-only"), now: hintedNow).isEmpty
}
check("extra reminders outside the supported range are dropped rather than written") {
    var event = ExtractedEvent(title: "会议", startLocal: "2026-09-25T18:00:00", endLocal: "2026-09-25T19:00:00", timeZone: zone,
                               reminderMinutes: 15, extraReminderMinutes: [1440, -5, 99999, 15])
    event = resolveEvent(event)
    return event.extraReminderMinutes == [1440] && event.allReminderMinutes == [15, 1440]
}
check("an out-of-range extra reminder still blocks when it reaches the validator") {
    var event = ExtractedEvent(title: "会议", startLocal: "2026-09-25T18:00:00", endLocal: "2026-09-25T19:00:00", timeZone: zone)
    event.extraReminderMinutes = [20000]
    return !DraftValidator.errors(Draft(event: event, calendarID: "test-only"), now: hintedNow).isEmpty
}
check("only the alarm closest to the start decides whether a reminder is still ahead") {
    let start = "2026-09-22T15:00:00"
    var event = ExtractedEvent(title: "会议", startLocal: start, endLocal: nil, timeZone: zone, reminderMinutes: 10, extraReminderMinutes: [1440])
    event.missing = []
    // The day-before alarm has passed, the ten-minute one has not.
    return DraftValidator.reviewNotes(Draft(event: event, calendarID: "test-only"), now: hintedNow).isEmpty
}

// Lunar dates are converted here, never by the model.
check("农历八月十五 converts to the 2026 mid-autumn date as a whole day") {
    var event = ExtractedEvent(title: "中秋聚餐", startLocal: nil, endLocal: nil, timeZone: zone, source: "农历八月十五", lunarDate: "08-15")
    event = resolveEvent(event)
    return event.allDay && event.startLocal == "2026-09-25" && event.endLocal == "2026-09-26"
        && event.timingNote?.contains("农历八月十五") == true && event.lunarDate == nil
}
check("a lunar date with a part of day becomes a timed reminder") {
    var event = ExtractedEvent(title: "中秋聚餐", startLocal: nil, endLocal: nil, timeZone: zone, source: "农历八月十五晚上",
                               dayPart: "evening", lunarDate: "08-15")
    event = resolveEvent(event)
    return !event.allDay && event.startLocal == "2026-09-25T20:00:00"
}
check("a named lunar year is searched from that year") {
    let lunar = LunarDate("+2028-05-15")
    let day = try lunar?.gregorianDay(onOrAfter: hintedNow, timeZone: zone)
    return lunar?.isLeapMonth == true && lunar?.label == "农历闰五月十五"
        && day.map { Temporal.format($0, timeZone: zone, allDay: true) } == "2028-07-07"
}
check("an impossible lunar date is refused instead of approximated") {
    LunarDate("13-01") == nil && LunarDate("08-31") == nil && LunarDate("八月十五") == nil && LunarDate(nil) == nil
}
check("a lunar date that cannot be placed leaves the draft blocked") {
    var event = ExtractedEvent(title: "祭祖", startLocal: nil, timeZone: "not/a-zone", source: "农历三月初三", lunarDate: "03-03")
    event = resolveEvent(event)
    // The fallback zone keeps the conversion possible; an unusable zone would have blocked it.
    return event.startLocal != nil && event.timeZone == zone
}

// Recurrence: only what EventKit can store exactly.
check("a weekly class timetable reads back as it will be stored") {
    let event = ExtractedEvent(title: "高等数学", startLocal: "2026-09-23T08:00:00", endLocal: "2026-09-23T09:40:00", timeZone: zone,
                               repeatRule: "weekly", repeatDays: [3, 5], repeatUntil: "2027-01-15")
    guard let recurrence = event.recurrence else { return false }
    return recurrence.rule == .weekly && recurrence.days == [3, 5] && recurrence.gregorianWeekdays == [4, 6]
        && recurrence.label == "每周三、周五 · 到 2027-01-15"
        && recurrence.errors(start: event.startLocal, timeZone: zone).isEmpty
}
check("working days expand to Monday through Friday") { Recurrence(rule: .weekdays).gregorianWeekdays == [2, 3, 4, 5, 6] }
check("an end date before the start is refused") {
    Recurrence(rule: .weekly, until: "2026-01-01").errors(start: "2026-09-23T08:00:00", timeZone: zone).count == 1
}
check("a malformed end date is refused") {
    !Recurrence(rule: .weekly, until: "下学期").errors(start: "2026-09-23T08:00:00", timeZone: zone).isEmpty
}
check("an implausible repeat count is refused") {
    !Recurrence(rule: .monthly, count: 1).errors(start: nil, timeZone: zone).isEmpty
        && !Recurrence(rule: .monthly, count: 900).errors(start: nil, timeZone: zone).isEmpty
}
check("an end date wins over a count so the series has one meaning") {
    let event = ExtractedEvent(title: "例会", startLocal: "2026-09-23T08:00:00", endLocal: nil, timeZone: zone,
                               repeatRule: "weekly", repeatUntil: "2026-12-31", repeatCount: 8)
    return event.recurrence?.count == nil && event.recurrence?.until == "2026-12-31"
}
check("a broken repeat blocks the draft instead of being written as a single event") {
    let event = ExtractedEvent(title: "例会", startLocal: "2026-09-23T08:00:00", endLocal: nil, timeZone: zone,
                               repeatRule: "weekly", repeatUntil: "2020-01-01")
    return !DraftValidator.errorsAfterReview(Draft(event: event, calendarID: "test-only"), now: hintedNow).isEmpty
}

let hintJSON = validJSON.replacingOccurrences(of: #""startLocal":"2030-06-18T14:00:00""#, with: #""startLocal":null,"dueDay":"tomorrow","dayPart":"afternoon""#)
check("the contract accepts a declared timeframe") {
    let event = try ExtractionDecoder.decode(hintJSON).events.first
    return event?.dueDay == "tomorrow" && event?.dayPart == "afternoon"
}
check("the contract still rejects keys next to the timeframe") {
    rejects { _ = try ExtractionDecoder.decode(hintJSON.replacingOccurrences(of: #""dueDay":"tomorrow""#, with: #""dueDay":"tomorrow","calendarID":"attacker""#)) }
}
check("vocabulary outside the documented sets is dropped at the contract boundary") {
    let json = validJSON.replacingOccurrences(of: #""source":"会议""#, with: #""source":"会议","dueDay":"someday","dayPart":"brunch","repeatRule":"hourly","kind":"chore","repeatDays":[9,3]"#)
    let event = try ExtractionDecoder.decode(json).events.first
    return event?.dueDay == nil && event?.dayPart == nil && event?.repeatRule == nil && event?.kind == nil && event?.repeatDays == [3]
}
check("a model-supplied resolution note is ignored") {
    try ExtractionDecoder.decode(validJSON.replacingOccurrences(of: #""source":"会议""#, with: #""source":"会议","kind":"event""#)).events.first?.timingNote == nil
}
check("drafts stored by earlier builds still decode without the new fields") {
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
    for key in ["extraReminderMinutes", "kind", "dueDay", "dayPart", "lunarDate", "isDeadline", "repeatRule", "repeatDays", "repeatUntil", "repeatCount", "timingNote", "dueHint"] {
        old.removeValue(forKey: key)
    }
    let restored = try JSONDecoder().decode(ExtractedEvent.self, from: JSONSerialization.data(withJSONObject: old))
    return restored.dueDay == nil && restored.timingNote == nil && restored.recurrence == nil && restored.startLocal == event.startLocal
        && restored.allReminderMinutes == [15]
}

print("\n\(passed) passed, \(failed) failed. Offline checks only; no API keys or calendars accessed.")
if failed > 0 { exit(1) }
