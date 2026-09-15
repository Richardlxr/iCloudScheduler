import Foundation

public enum Temporal {
    public static func parse(_ value: String, timeZone: String, allDay: Bool) throws -> Date {
        guard let zone = TimeZone(identifier: timeZone) else { throw AppError("无法识别时区：\(timeZone)") }
        let pattern = allDay ? #"^\d{4}-\d{2}-\d{2}$"# : #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw AppError(allDay ? "全天日期须使用 YYYY-MM-DD。" : "时间须使用 YYYY-MM-DDTHH:mm:ss。")
        }
        let parts = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var components = DateComponents(timeZone: zone, year: parts[0], month: parts[1], day: parts[2])
        components.hour = allDay ? 12 : parts[3]
        components.minute = allDay ? 0 : parts[4]; components.second = allDay ? 0 : parts[5]
        guard let result = calendar.date(from: components) else { throw AppError("日期或时间无效。") }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)
        guard roundTrip.year == components.year, roundTrip.month == components.month, roundTrip.day == components.day,
              roundTrip.hour == components.hour, roundTrip.minute == components.minute, roundTrip.second == components.second else {
            throw AppError("日期不存在，或处于夏令时跳过的时段。")
        }
        if allDay { return calendar.startOfDay(for: result) }
        let before = calendar.startOfDay(for: result).addingTimeInterval(-1)
        let match = DateComponents(hour: components.hour, minute: components.minute, second: components.second)
        let first = calendar.nextDate(after: before, matching: match, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: before, matching: match, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard first == last else { throw AppError("这个时间在夏令时切换中出现两次，请改用明确的 UTC 时间。") }
        return result
    }

    public static func format(_ date: Date, timeZone: String, allDay: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        formatter.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    public static func interval(_ event: ExtractedEvent) throws -> DateInterval {
        guard let start = event.startLocal else { throw AppError("请补充开始时间。") }
        let startDate = try parse(start, timeZone: event.timeZone, allDay: event.allDay)
        // EventKit needs an end date; point reminders occupy one minute and are marked free.
        if event.isPointReminder { return DateInterval(start: startDate, duration: 60) }
        guard let end = event.endLocal else { throw AppError("请补充全天结束日期。") }
        let endDate = try parse(end, timeZone: event.timeZone, allDay: event.allDay)
        guard endDate > startDate else { throw AppError("结束时间必须晚于开始时间；全天结束日不包含在日程内。") }
        guard endDate.timeIntervalSince(startDate) <= 366 * 86400 else { throw AppError("单条日程不能超过一年。") }
        return DateInterval(start: startDate, end: endDate)
    }

    public static func allDayAlarm(start: Date, timeZone: String, minutes: Int) throws -> Date? {
        guard [540, -360, -1].contains(minutes) else { throw AppError("全天提醒设置无效。") }
        return try allDayAlarm(start: start, timeZone: timeZone, reminder: AllDayReminder(legacyMinutes: minutes))
    }
    public static func allDayAlarm(start: Date, timeZone: String, reminder: AllDayReminder) throws -> Date? {
        guard reminder.enabled else { return nil }
        guard let zone = TimeZone(identifier: timeZone), reminder.isValid else { throw AppError("全天提醒设置无效。") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.date(byAdding: .day, value: -reminder.daysBefore, to: start)
        guard let day, let result = calendar.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: day) else {
            throw AppError("无法计算全天提醒时间。")
        }
        // Reject a nonexistent clock time rather than silently moving a custom reminder through a DST gap.
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: result)
        guard parts.hour == reminder.hour, parts.minute == reminder.minute,
              calendar.isDate(result, inSameDayAs: day) else { throw AppError("所选全天提醒时刻在当天不存在，请调整提醒时间。"); }
        return result
    }
}

public enum DraftValidator {
    public static func canAddAutomatically(_ drafts: [Draft], questions: [String], now: Date = Date()) -> Bool {
        !drafts.isEmpty && questions.isEmpty && drafts.allSatisfy {
            $0.selected && !$0.reviewed && !$0.conflictAcknowledged && errors($0, now: now).isEmpty
        }
    }
    // Explicit UI confirmation acknowledges visible warnings, but never bypasses missing data or invalid dates.
    public static func errorsAfterReview(_ draft: Draft, now: Date = Date(), requireCalendar: Bool = true) -> [String] {
        var confirmed = draft; confirmed.reviewed = true; confirmed.conflictAcknowledged = true
        return errors(confirmed, now: now, requireCalendar: requireCalendar)
    }
    public static func reviewNotes(_ draft: Draft, now: Date = Date()) -> [String] {
        var notes = draft.event.assumptions
        if let interval = try? Temporal.interval(draft.event) {
            if interval.start < now { notes.append("开始时间已过去。") }
            else if !draft.event.allDay, let minutes = draft.event.reminderMinutes, (0...10080).contains(minutes),
                    interval.start.addingTimeInterval(Double(-minutes * 60)) < now { notes.append("提醒时间已过去，可能无法按原计划提醒。") }
        }
        return notes
    }
    public static func errors(_ draft: Draft, now: Date = Date(), requireCalendar: Bool = true) -> [String] {
        var errors: [String] = []
        let event = draft.event
        if event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || event.title.count > 200 { errors.append("标题不能为空且不能超过 200 字。") }
        if event.location.count > 1000 || event.notes.count > 10000 { errors.append("地点或备注太长。") }
        if requireCalendar && draft.calendarID.isEmpty { errors.append("请选择目标日历。") }
        if !event.missing.isEmpty { errors.append("待补充：" + event.missing.joined(separator: "、")) }
        if let minutes = event.reminderMinutes, !(0...10080).contains(minutes) { errors.append("提醒应在开始前 0–10080 分钟之间。") }
        do {
            let interval = try Temporal.interval(event)
            if interval.start < now && !draft.reviewed { errors.append("开始时间已过去，请核对后确认。") }
            if !event.allDay, let minutes = event.reminderMinutes, (0...10080).contains(minutes),
               interval.start >= now, interval.start.addingTimeInterval(Double(-minutes * 60)) < now, !draft.reviewed {
                errors.append("提醒时间已过去，请修改提醒或核对后确认。")
            }
        } catch { errors.append(error.localizedDescription) }
        if !event.assumptions.isEmpty && !draft.reviewed { errors.append("请核对模型采用的假设。") }
        if !draft.conflicts.isEmpty && !draft.conflictAcknowledged { errors.append("存在时间冲突，请选择仍然添加或修改时间。") }
        return errors
    }
}

public enum ExtractionDecoder {
    public static func decode(_ content: String) throws -> Extraction {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json\n"), text.hasSuffix("```") { text = String(text.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let data = text.data(using: .utf8), data.count <= 256_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["events", "questions"], let events = root["events"] as? [[String: Any]],
              events.count <= 20 else { throw AppError("模型没有返回完整的日程 JSON，或一次超过 20 项。请重试或缩小范围。") }
        let required: Set<String> = ["title", "startLocal", "endLocal", "timeZone", "allDay", "location", "notes", "reminderMinutes", "missing", "assumptions", "source"]
        for event in events where Set(event.keys) != required { throw AppError("模型返回的日程字段不符合契约，请重新分析。") }
        let extraction = try JSONDecoder().decode(Extraction.self, from: data)
        guard (extraction.events.isEmpty || extraction.questions.isEmpty), extraction.questions.count <= 20, extraction.questions.allSatisfy({ $0.count <= 1000 }),
              extraction.events.allSatisfy({ $0.title.count <= 200 && $0.source.count <= 4000 && $0.notes.count <= 10000 && $0.missing.count <= 20 && $0.assumptions.count <= 20 && ($0.missing + $0.assumptions).allSatisfy({ $0.count <= 1000 }) }) else {
            throw AppError("模型输出不符合日程契约：请勿附加对话追问或超长内容。")
        }
        return extraction
    }
}

public enum Endpoint {
    public static func url(base: String, resource: String = "chat/completions") throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme == "https", let host = components.host,
              !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw AppError("请填写 HTTPS 地址；地址不能包含密钥、查询参数或片段。") }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.hasSuffix("/responses"), !path.hasSuffix("/messages") else { throw AppError("目前支持 Chat Completions 协议，请填写对应的 Base URL。") }
        if path.hasSuffix("/chat/completions") { path.removeLast("/chat/completions".count) }
        components.path = path + "/" + resource
        guard let url = components.url else { throw AppError("连接地址无效。") }
        return url
    }
}
