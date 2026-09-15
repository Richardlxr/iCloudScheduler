import Foundation
import EventKit
import CryptoKit
import SchedulerCore

@MainActor
protocol CalendarAccess {
    var hasAccess: Bool { get }
    func requestAccess() async throws
    func calendars() -> [CalendarChoice]
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
    func requestAccess() async throws { guard try await store.requestFullAccessToEvents() else { throw AppError("日历访问未允许。可以继续编辑草稿，稍后在系统设置中授权。") } }
    func calendars() -> [CalendarChoice] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications).map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    func refresh() { if hasAccess { store.refreshSourcesIfNecessary() } }
    private func calendar(_ id: String) throws -> EKCalendar {
        guard hasAccess else { throw AppError("尚未获得日历完整访问权限。") }
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else { throw AppError("目标日历不存在或不可写，请重新选择。") }
        return calendar
    }
    func conflicts(for draft: Draft) throws -> [String] {
        guard hasAccess, !draft.event.isPointReminder else { return [] }
        let interval = try Temporal.interval(draft.event)
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).filter {
            $0.availability != .free && $0.status != .canceled && $0.startDate < interval.end && $0.endDate > interval.start
        }.prefix(8).map { $0.title ?? "已有日程" }
    }
    func save(_ receipt: OperationReceipt, allDayReminder: AllDayReminder) throws -> OperationReceipt {
        let draft = receipt.draft
        let errors = DraftValidator.errors(draft)
        guard errors.isEmpty else { throw AppError(errors.joined(separator: "\n")) }
        let interval = try Temporal.interval(draft.event)
        let target = try calendar(draft.calendarID)
        let event = EKEvent(eventStore: store)
        event.calendar = target; event.title = draft.event.title
        event.startDate = interval.start; event.endDate = interval.end
        if draft.event.isPointReminder { event.availability = .free }
        event.timeZone = TimeZone(identifier: draft.event.timeZone); event.isAllDay = draft.event.allDay
        event.location = draft.event.location
        event.notes = draft.event.notes + (draft.event.notes.isEmpty ? "" : "\n\n") + receipt.marker
        if let minutes = draft.event.reminderMinutes {
            if draft.event.allDay {
                if let date = try Temporal.allDayAlarm(start: interval.start, timeZone: draft.event.timeZone, reminder: allDayReminder) {
                    event.addAlarm(EKAlarm(absoluteDate: date))
                }
            } else { event.addAlarm(EKAlarm(relativeOffset: Double(-minutes * 60))) }
        }
        let intendedAlarms = alarmValues(event)
        try store.save(event, span: .thisEvent, commit: true)
        var result = receipt
        result.eventID = event.eventIdentifier
        guard let identifier = event.eventIdentifier, let saved = store.event(withIdentifier: identifier),
              saved.notes?.contains(receipt.marker) == true,
              saved.calendar.calendarIdentifier == target.calendarIdentifier,
              saved.title == event.title, saved.startDate == interval.start, saved.endDate == interval.end,
              saved.isAllDay == draft.event.allDay else {
            result.status = "uncertain"; result.message = "系统保存已返回，但读回尚未确认；请核对后恢复，不要重复添加。"
            return result
        }
        result.status = "saved"; result.fingerprint = fingerprint(saved)
        let actualAlarms = alarmValues(saved)
        result.message = actualAlarms == intendedAlarms ? "已保存，iCloud 同步由系统完成。" : "已保存，但系统调整了提醒，请在日历中核对。"
        if actualAlarms != intendedAlarms { result.warning = result.message }
        return result
    }
    func reconcile(_ receipt: OperationReceipt) throws -> OperationReceipt {
        guard hasAccess else { throw AppError("需要日历权限才能核对写入结果。") }
        var result = receipt
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
        let matches = try find(receipt)
        guard matches.count == 1, let event = matches.first, !event.hasRecurrenceRules,
              fingerprint(event) == originalFingerprint else { throw AppError("事件已被修改、删除或无法唯一定位，已停止撤销。") }
        _ = try calendar(event.calendar.calendarIdentifier)
        try store.remove(event, span: .thisEvent, commit: true)
        var result = receipt; result.status = "undone"; result.message = "已撤销本应用创建且未被修改的事件。"
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
                               (event.alarms ?? []).map { "\($0.relativeOffset)|\(String(describing: $0.absoluteDate))" }.sorted().joined(separator: ",")]
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func alarmValues(_ event: EKEvent) -> [String] {
        (event.alarms ?? []).map { alarm in
            if let date = alarm.absoluteDate { return "absolute:\(date.timeIntervalSince1970)" }
            return "relative:\(alarm.relativeOffset)"
        }.sorted()
    }
}
