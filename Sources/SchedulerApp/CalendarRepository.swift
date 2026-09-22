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
        return receipt.draft.usesReminders ? try saveReminder(receipt, allDayReminder: allDayReminder)
                                           : try saveEvent(receipt, allDayReminder: allDayReminder)
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
        guard receipt.status == "saved", let originalFingerprint = receipt.fingerprint else { throw AppError("这条记录无法安全自动撤销，请在系统日历处理。") }
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
