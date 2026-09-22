import Foundation
import EventKit
import CryptoKit
import SchedulerCore

@MainActor
protocol CalendarAccess {
    var hasAccess: Bool { get }
    var hasReminderAccess: Bool { get }
    func requestAccess() async throws
    func requestReminderAccess() async throws
    func calendars() -> [CalendarChoice]
    func reminderLists() -> [CalendarChoice]
    func refresh()
    func conflicts(for draft: Draft) throws -> [String]
    func matches(for draft: Draft, now: Date) throws -> [CalendarMatch]
    func save(_ receipt: OperationReceipt, allDayReminder: AllDayReminder) throws -> OperationReceipt
    func reconcile(_ receipt: OperationReceipt) throws -> OperationReceipt
    func undo(_ receipt: OperationReceipt) throws -> OperationReceipt
}

@MainActor
final class CalendarRepository: CalendarAccess {
    private let store = EKEventStore()
    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var hasReminderAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    func requestAccess() async throws { guard try await store.requestFullAccessToEvents() else { throw AppError("日历访问未允许。可以继续编辑草稿，稍后在系统设置中授权。") } }
    func requestReminderAccess() async throws {
        guard try await store.requestFullAccessToReminders() else { throw AppError("提醒事项访问未允许。待办会继续写入日历，可稍后在系统设置中授权。") }
    }
    func reminderLists() -> [CalendarChoice] {
        guard hasReminderAccess else { return [] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications).map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    func calendars() -> [CalendarChoice] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications).map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    func refresh() { if hasAccess { store.refreshSourcesIfNecessary() } }
    private func calendar(_ id: String, reminders: Bool = false) throws -> EKCalendar {
        if reminders {
            guard hasReminderAccess else { throw AppError("尚未获得提醒事项访问权限。") }
        } else {
            guard hasAccess else { throw AppError("尚未获得日历完整访问权限。") }
        }
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else {
            throw AppError(reminders ? "目标提醒事项清单不存在或不可写，请重新选择。" : "目标日历不存在或不可写，请重新选择。")
        }
        return calendar
    }
    func conflicts(for draft: Draft) throws -> [String] {
        // A reminder occupies no time, and a point reminder is marked free.
        guard hasAccess, !draft.usesReminders, !draft.event.isPointReminder else { return [] }
        let interval = try Temporal.interval(draft.event)
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).filter {
            $0.availability != .free && $0.status != .canceled && $0.startDate < interval.end && $0.endDate > interval.start
        }.prefix(8).map { $0.title ?? "已有日程" }
    }
    func save(_ receipt: OperationReceipt, allDayReminder: AllDayReminder) throws -> OperationReceipt {
        let errors = DraftValidator.errors(receipt.draft)
        guard errors.isEmpty else { throw AppError(errors.joined(separator: "\n")) }
        switch receipt.draft.intent {
        case .add:
            return receipt.draft.usesReminders ? try saveReminder(receipt, allDayReminder: allDayReminder)
                                               : try saveEvent(receipt, allDayReminder: allDayReminder)
        case .update: return try applyUpdate(receipt)
        case .cancel: return try applyCancel(receipt)
        }
    }
    /// Existing events a change message might mean. Titles stay on this machine.
    func matches(for draft: Draft, now: Date) throws -> [CalendarMatch] {
        guard hasAccess, draft.intent.touchesExistingEvent else { return [] }
        let event = draft.event
        let zone = TimeZone(identifier: event.timeZone) ?? .current
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = zone
        let window: DateInterval
        if let anchor = event.targetStartLocal, let day = Self.day(anchor, timeZone: event.timeZone, calendar: gregorian) {
            // The message named the day the original was on, so only that day is searched.
            window = DateInterval(start: day, end: day.addingTimeInterval(86400))
        } else {
            // Otherwise: anything still ahead, plus yesterday for a change that arrives late.
            window = DateInterval(start: gregorian.startOfDay(for: now).addingTimeInterval(-86400),
                                  end: gregorian.startOfDay(for: now).addingTimeInterval(31 * 86400))
        }
        let needle = Self.normalize(event.targetTitle ?? event.title)
        guard !needle.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .filter { candidate in
                let title = Self.normalize(candidate.title ?? "")
                return !title.isEmpty && (title.contains(needle) || needle.contains(title))
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { Self.match($0) }
    }
    private static func day(_ value: String, timeZone: String, calendar: Calendar) -> Date? {
        let text = String(value.prefix(10))
        guard let parsed = try? Temporal.parse(text, timeZone: timeZone, allDay: true) else { return nil }
        return calendar.startOfDay(for: parsed)
    }
    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }
    private static func match(_ event: EKEvent) -> CalendarMatch {
        let zone = event.timeZone?.identifier ?? TimeZone.current.identifier
        var blocked: String?
        if !event.calendar.allowsContentModifications { blocked = "这条日程所在的日历不可修改，请在系统日历处理。" }
        else if event.hasAttendees { blocked = "这条日程有参与者，改动会通知他们，请在系统日历处理。" }
        return CalendarMatch(id: event.eventIdentifier ?? UUID().uuidString,
                             title: event.title ?? "未命名日程",
                             startLocal: Temporal.format(event.startDate, timeZone: zone, allDay: event.isAllDay),
                             endLocal: Temporal.format(event.endDate, timeZone: zone, allDay: event.isAllDay),
                             allDay: event.isAllDay, timeZone: zone,
                             calendarName: event.calendar.title, partOfSeries: event.hasRecurrenceRules,
                             blockedReason: blocked)
    }
    /// Re-checks that the event still looks the way it did when the user confirmed it.
    private func locateTarget(_ receipt: OperationReceipt) throws -> (EKEvent, CalendarMatch) {
        guard hasAccess else { throw AppError("需要日历权限才能修改已有日程。") }
        guard let target = receipt.draft.target else { throw AppError("没有选择要处理的日程。") }
        guard let event = store.event(withIdentifier: target.id), event.status != .canceled else {
            throw AppError("目标日程已不存在，可能已被删除或同步移除，已停止操作。")
        }
        let current = Self.match(event)
        guard current.startLocal == target.startLocal, current.title == target.title else {
            throw AppError("目标日程已变化（现在是 \(current.when)），请重新确认后再操作。")
        }
        if let reason = current.blockedReason { throw AppError(reason) }
        return (event, current)
    }
    private func snapshot(_ event: EKEvent) -> EventSnapshot {
        let zone = event.timeZone?.identifier ?? TimeZone.current.identifier
        return EventSnapshot(title: event.title ?? "",
                             startLocal: Temporal.format(event.startDate, timeZone: zone, allDay: event.isAllDay),
                             endLocal: Temporal.format(event.endDate, timeZone: zone, allDay: event.isAllDay),
                             allDay: event.isAllDay, timeZone: zone,
                             location: event.location ?? "", notes: event.notes ?? "",
                             calendarID: event.calendar.calendarIdentifier, partOfSeries: event.hasRecurrenceRules)
    }
    /// Moves an existing event. Only the time and place change; reminders and everything else stay.
    private func applyUpdate(_ receipt: OperationReceipt) throws -> OperationReceipt {
        let (event, current) = try locateTarget(receipt)
        var result = receipt
        result.previous = snapshot(event)
        result.eventID = current.id
        let draft = receipt.draft
        if draft.event.startLocal != nil {
            let interval = try Temporal.interval(draft.event)
            event.startDate = interval.start; event.endDate = interval.end
            event.isAllDay = draft.event.allDay
            event.timeZone = TimeZone(identifier: draft.event.timeZone)
        }
        let place = draft.event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty { event.location = place }
        // One occurrence of a series moves on its own; the rest of the series is left alone.
        try store.save(event, span: .thisEvent, commit: true)
        guard let saved = store.event(withIdentifier: current.id) ?? store.event(withIdentifier: event.eventIdentifier ?? current.id) else {
            result.status = "uncertain"; result.message = "修改已提交，但读回尚未确认，请在系统日历核对。"
            return result
        }
        result.eventID = saved.eventIdentifier
        let after = Self.match(saved)
        let expected = draft.event.startLocal.map { $0 == after.startLocal } ?? true
        guard expected, (place.isEmpty || saved.location == place) else {
            result.status = "uncertain"; result.message = "修改已提交，但读回的时间或地点与预期不符，请在系统日历核对。"
            return result
        }
        result.status = "saved"; result.fingerprint = fingerprint(saved)
        result.message = "已把〈\(after.title)〉从 \(result.previous?.when ?? "原时间") 改到 \(after.when)。"
            + (current.partOfSeries ? "仅改动了重复日程的这一次。" : "")
        return result
    }
    /// Removes the occurrence a message cancelled, keeping enough to put it back.
    private func applyCancel(_ receipt: OperationReceipt) throws -> OperationReceipt {
        let (event, current) = try locateTarget(receipt)
        var result = receipt
        let previous = snapshot(event)
        result.previous = previous
        result.eventID = current.id
        try store.remove(event, span: .thisEvent, commit: true)
        if let leftover = store.event(withIdentifier: current.id), leftover.status != .canceled,
           Self.match(leftover).startLocal == current.startLocal {
            result.status = "uncertain"; result.message = "取消已提交，但这条日程仍能读到，请在系统日历核对。"
            return result
        }
        result.status = "saved"; result.fingerprint = nil
        result.message = "已取消〈\(previous.title)〉\(previous.when)。"
            + (current.partOfSeries ? "仅取消了重复日程的这一次。" : "可在近期记录中恢复。")
        return result
    }
    private func saveEvent(_ receipt: OperationReceipt, allDayReminder: AllDayReminder) throws -> OperationReceipt {
        let draft = receipt.draft
        let interval = try Temporal.interval(draft.event)
        let target = try calendar(draft.calendarID)
        let event = EKEvent(eventStore: store)
        event.calendar = target; event.title = draft.event.title
        event.startDate = interval.start; event.endDate = interval.end
        if draft.event.isPointReminder { event.availability = .free }
        event.timeZone = TimeZone(identifier: draft.event.timeZone); event.isAllDay = draft.event.allDay
        event.location = draft.event.location
        event.notes = draft.event.notes + (draft.event.notes.isEmpty ? "" : "\n\n") + receipt.marker
        for alarm in try alarms(draft.event, start: interval.start, allDayReminder: allDayReminder, absolute: false) {
            event.addAlarm(alarm)
        }
        let recurrence = draft.event.recurrence
        if let recurrence { event.recurrenceRules = [try Self.rule(recurrence, timeZone: draft.event.timeZone)] }
        let intendedAlarms = alarmValues(event.alarms)
        // A new series must be saved across its future occurrences, not just the first one.
        try store.save(event, span: recurrence == nil ? .thisEvent : .futureEvents, commit: true)
        var result = receipt
        result.eventID = event.eventIdentifier
        guard let identifier = event.eventIdentifier, let saved = store.event(withIdentifier: identifier),
              saved.notes?.contains(receipt.marker) == true,
              saved.calendar.calendarIdentifier == target.calendarIdentifier,
              saved.title == event.title, saved.startDate == interval.start, saved.endDate == interval.end,
              saved.isAllDay == draft.event.allDay,
              saved.hasRecurrenceRules == (recurrence != nil) else {
            result.status = "uncertain"; result.message = "系统保存已返回，但读回尚未确认；请核对后恢复，不要重复添加。"
            return result
        }
        result.status = "saved"; result.fingerprint = fingerprint(saved)
        let actualAlarms = alarmValues(saved.alarms)
        result.message = actualAlarms == intendedAlarms ? "已保存，iCloud 同步由系统完成。" : "已保存，但系统调整了提醒，请在日历中核对。"
        if actualAlarms != intendedAlarms { result.warning = result.message }
        if let recurrence { result.message += "（\(recurrence.label)）" }
        return result
    }
    /// A task written to Reminders stays until it is ticked off, which a calendar event cannot do.
    private func saveReminder(_ receipt: OperationReceipt, allDayReminder: AllDayReminder) throws -> OperationReceipt {
        let draft = receipt.draft
        let interval = try Temporal.interval(draft.event)
        let list = try calendar(draft.calendarID, reminders: true)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list; reminder.title = draft.event.title
        reminder.notes = draft.event.notes + (draft.event.notes.isEmpty ? "" : "\n\n") + receipt.marker
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: draft.event.timeZone) ?? .current
        let fields: Set<Calendar.Component> = draft.event.allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
        reminder.dueDateComponents = gregorian.dateComponents(fields, from: interval.start)
        // Reminders notify from an absolute date; a due date on its own stays silent.
        for alarm in try alarms(draft.event, start: interval.start, allDayReminder: allDayReminder, absolute: true) {
            reminder.addAlarm(alarm)
        }
        let recurrence = draft.event.recurrence
        if let recurrence { reminder.recurrenceRules = [try Self.rule(recurrence, timeZone: draft.event.timeZone)] }
        let intendedAlarms = alarmValues(reminder.alarms)
        try store.save(reminder, commit: true)
        var result = receipt
        result.eventID = reminder.calendarItemIdentifier
        guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder,
              saved.notes?.contains(receipt.marker) == true, saved.title == reminder.title,
              saved.calendar.calendarIdentifier == list.calendarIdentifier,
              saved.dueDateComponents == reminder.dueDateComponents else {
            result.status = "uncertain"; result.message = "提醒事项保存已返回，但读回尚未确认；请核对后恢复，不要重复添加。"
            return result
        }
        result.status = "saved"; result.fingerprint = fingerprint(saved)
        let actualAlarms = alarmValues(saved.alarms)
        result.message = actualAlarms == intendedAlarms ? "已加入提醒事项，完成后可直接勾掉。" : "已加入提醒事项，但系统调整了提醒，请在提醒事项中核对。"
        if actualAlarms != intendedAlarms { result.warning = result.message }
        if let recurrence { result.message += "（\(recurrence.label)）" }
        return result
    }
    private func alarms(_ event: ExtractedEvent, start: Date, allDayReminder: AllDayReminder, absolute: Bool) throws -> [EKAlarm] {
        if event.allDay {
            // An all-day item uses the fixed time from settings; extra offsets do not apply to it.
            guard event.reminderMinutes != nil,
                  let date = try Temporal.allDayAlarm(start: start, timeZone: event.timeZone, reminder: allDayReminder) else { return [] }
            return [EKAlarm(absoluteDate: date)]
        }
        return event.allReminderMinutes.map { minutes in
            absolute ? EKAlarm(absoluteDate: start.addingTimeInterval(Double(-minutes * 60)))
                     : EKAlarm(relativeOffset: Double(-minutes * 60))
        }
    }
    static func rule(_ recurrence: Recurrence, timeZone: String) throws -> EKRecurrenceRule {
        var end: EKRecurrenceEnd?
        if let until = recurrence.until {
            // The end date is inclusive for the user, so the series may still fire on that day.
            let day = try Temporal.parse(until, timeZone: timeZone, allDay: true)
            end = EKRecurrenceEnd(end: day.addingTimeInterval(86399))
        } else if let count = recurrence.count {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }
        let days = recurrence.gregorianWeekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
        switch recurrence.rule {
        case .daily:
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: end)
        case .monthly:
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: end)
        case .yearly:
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: end)
        case .weekdays, .weekly, .biweekly:
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: recurrence.rule == .biweekly ? 2 : 1,
                                    daysOfTheWeek: days.isEmpty ? nil : days, daysOfTheMonth: nil, monthsOfTheYear: nil,
                                    weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
        }
    }
    func reconcile(_ receipt: OperationReceipt) throws -> OperationReceipt {
        var result = receipt
        if receipt.draft.usesReminders {
            guard hasReminderAccess else { throw AppError("需要提醒事项权限才能核对写入结果。") }
            if let id = receipt.eventID, let saved = store.calendarItem(withIdentifier: id) as? EKReminder,
               saved.notes?.contains(receipt.marker) == true {
                result.status = "saved"
                result.message = "已在提醒事项中找到这条待办。恢复记录不提供自动撤销，请自行核对。"
            } else {
                result.status = "uncertain"
                result.message = "暂未在提醒事项中找到这条待办。可能仍在同步，请检查提醒事项；不会自动重建。"
            }
            return result
        }
        guard hasAccess else { throw AppError("需要日历权限才能核对写入结果。") }
        let matches = try find(receipt)
        if matches.count == 1, let event = matches.first {
            result.status = "saved"; result.eventID = event.eventIdentifier
            // An interrupted write cannot establish whether fields were subsequently edited.
            // Keep fingerprint nil: show a receipt, but require manual deletion rather than unsafe undo.
            result.message = "已找到本次事件。恢复记录不提供自动撤销，请到系统日历核对。"
        } else {
            result.status = "uncertain"
            result.message = matches.isEmpty ? "暂未找到事件。可能仍在同步，请检查系统日历；不会自动重建。" : "发现多个同标记事件，请在系统日历核对。"
        }
        return result
    }
    func undo(_ receipt: OperationReceipt) throws -> OperationReceipt {
        guard receipt.status == "saved" else { throw AppError("这条记录无法安全自动撤销，请在系统日历处理。") }
        switch receipt.draft.intent {
        case .update: return try undoUpdate(receipt)
        case .cancel: return try undoCancel(receipt)
        case .add: break
        }
        guard let originalFingerprint = receipt.fingerprint else { throw AppError("这条记录无法安全自动撤销，请在系统日历处理。") }
        if receipt.draft.usesReminders {
            guard hasReminderAccess else { throw AppError("需要提醒事项权限。") }
            guard let id = receipt.eventID, let saved = store.calendarItem(withIdentifier: id) as? EKReminder,
                  saved.notes?.contains(receipt.marker) == true, fingerprint(saved) == originalFingerprint else {
                throw AppError("这条待办已被修改、完成或删除，已停止撤销。")
            }
            _ = try calendar(saved.calendar.calendarIdentifier, reminders: true)
            try store.remove(saved, commit: true)
            var result = receipt; result.status = "undone"; result.message = "已撤销本应用创建且未被修改的待办。"
            return result
        }
        let matches = try find(receipt)
        let series = receipt.draft.event.recurrence != nil
        guard matches.count == 1, let event = matches.first, event.hasRecurrenceRules == series,
              fingerprint(event) == originalFingerprint else { throw AppError("事件已被修改、删除或无法唯一定位，已停止撤销。") }
        _ = try calendar(event.calendar.calendarIdentifier)
        // Removing a series we created takes its future occurrences with it.
        try store.remove(event, span: series ? .futureEvents : .thisEvent, commit: true)
        var result = receipt; result.status = "undone"
        result.message = series ? "已撤销本应用创建的整个重复日程。" : "已撤销本应用创建且未被修改的事件。"
        return result
    }
    /// Puts a moved event back, but only if it is still exactly where this app left it.
    private func undoUpdate(_ receipt: OperationReceipt) throws -> OperationReceipt {
        guard hasAccess else { throw AppError("需要日历权限。") }
        guard let previous = receipt.previous, let id = receipt.eventID, let fingerprint = receipt.fingerprint,
              let event = store.event(withIdentifier: id), event.status != .canceled else {
            throw AppError("找不到被修改的日程，已停止撤销。")
        }
        guard self.fingerprint(event) == fingerprint else { throw AppError("这条日程在修改之后又被改动过，已停止撤销。") }
        _ = try calendar(event.calendar.calendarIdentifier)
        event.startDate = try Temporal.parse(previous.startLocal, timeZone: previous.timeZone, allDay: previous.allDay)
        event.endDate = try Temporal.parse(previous.endLocal, timeZone: previous.timeZone, allDay: previous.allDay)
        event.isAllDay = previous.allDay
        event.timeZone = TimeZone(identifier: previous.timeZone)
        event.location = previous.location.isEmpty ? nil : previous.location
        try store.save(event, span: .thisEvent, commit: true)
        var result = receipt; result.status = "undone"
        result.message = "已把〈\(previous.title)〉改回 \(previous.when)。"
        return result
    }
    /// Recreates a cancelled event from the snapshot taken before it was removed.
    private func undoCancel(_ receipt: OperationReceipt) throws -> OperationReceipt {
        guard hasAccess else { throw AppError("需要日历权限。") }
        guard let previous = receipt.previous else { throw AppError("没有保留原日程内容，无法恢复。") }
        guard !previous.partOfSeries else { throw AppError("重复日程的单次取消无法在这里恢复，请在系统日历处理。") }
        if let id = receipt.eventID, let existing = store.event(withIdentifier: id), existing.status != .canceled {
            throw AppError("这条日程已经存在，无需恢复。")
        }
        let target = try calendar(previous.calendarID)
        let event = EKEvent(eventStore: store)
        event.calendar = target; event.title = previous.title
        event.startDate = try Temporal.parse(previous.startLocal, timeZone: previous.timeZone, allDay: previous.allDay)
        event.endDate = try Temporal.parse(previous.endLocal, timeZone: previous.timeZone, allDay: previous.allDay)
        event.isAllDay = previous.allDay
        event.timeZone = TimeZone(identifier: previous.timeZone)
        event.location = previous.location.isEmpty ? nil : previous.location
        event.notes = previous.notes.isEmpty ? nil : previous.notes
        try store.save(event, span: .thisEvent, commit: true)
        var result = receipt; result.status = "undone"; result.eventID = event.eventIdentifier
        // The restored event is a new entry: alarms and invitees from the original are not recreated.
        result.message = "已按取消前的内容重新建立〈\(previous.title)〉\(previous.when)；提醒等其他设置需要自行核对。"
        return result
    }
    private func find(_ receipt: OperationReceipt) throws -> [EKEvent] {
        guard hasAccess else { throw AppError("需要日历权限。") }
        if let id = receipt.eventID, let event = store.event(withIdentifier: id), event.notes?.contains(receipt.marker) == true { return [event] }
        let interval = try Temporal.interval(receipt.draft.event)
        let predicate = store.predicateForEvents(withStart: interval.start.addingTimeInterval(-86400), end: interval.end.addingTimeInterval(86400), calendars: nil)
        return store.events(matching: predicate).filter { $0.notes?.contains(receipt.marker) == true }
    }
    private func fingerprint(_ event: EKEvent) -> String {
        let values: [String] = [event.calendar.calendarIdentifier, event.title ?? "", String(event.startDate.timeIntervalSince1970),
                               String(event.endDate.timeIntervalSince1970), String(event.isAllDay), event.timeZone?.identifier ?? "",
                               event.location ?? "", event.notes ?? "", event.url?.absoluteString ?? "",
                               String(event.availability.rawValue), String(event.hasRecurrenceRules),
                               String(describing: event.lastModifiedDate),
                               alarmValues(event.alarms).joined(separator: ",")]
        return digest(values)
    }
    private func fingerprint(_ reminder: EKReminder) -> String {
        let values: [String] = [reminder.calendar.calendarIdentifier, reminder.title ?? "",
                               String(describing: reminder.dueDateComponents), String(reminder.isCompleted),
                               reminder.notes ?? "", reminder.url?.absoluteString ?? "",
                               String(reminder.hasRecurrenceRules), String(describing: reminder.lastModifiedDate),
                               alarmValues(reminder.alarms).joined(separator: ",")]
        return digest(values)
    }
    private func digest(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func alarmValues(_ alarms: [EKAlarm]?) -> [String] {
        (alarms ?? []).map { alarm in
            if let date = alarm.absoluteDate { return "absolute:\(date.timeIntervalSince1970)" }
            return "relative:\(alarm.relativeOffset)"
        }.sorted()
    }
}
