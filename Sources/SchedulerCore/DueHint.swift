import Foundation

/// A relative timeframe the model may report instead of inventing a clock time.
/// The model only classifies the wording; this file turns it into one concrete
/// local time, so a short-term reminder never depends on model date arithmetic.
public enum DueHint: String, CaseIterable, Sendable {
    case asap
    case today
    case tonight
    case tomorrow
    case weekend
    case thisWeek = "this_week"
    case nextWeek = "next_week"
    case monthEnd = "month_end"

    public var label: String {
        switch self {
        case .asap: "尽快"
        case .today: "今天"
        case .tonight: "今晚"
        case .tomorrow: "明天"
        case .weekend: "本周末"
        case .thisWeek: "本周内"
        case .nextWeek: "下周"
        case .monthEnd: "本月底"
        }
    }

    /// Only the documented vocabulary is accepted; anything else stays unresolved
    /// so the draft keeps asking for a real time instead of guessing one.
    public static func parse(_ raw: String?) -> DueHint? {
        guard let raw, !raw.isEmpty else { return nil }
        return DueHint(rawValue: raw)
    }

    public func resolve(now: Date, timeZone: String) throws -> ResolvedTiming {
        guard let zone = TimeZone(identifier: timeZone) else { throw AppError("无法识别时区：\(timeZone)") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2 // Monday, matching the extraction context.
        let candidate = try start(now: now, calendar: calendar)
        let start = try firstUsable(candidate, after: now, calendar: calendar, timeZone: timeZone)
        let value = Temporal.format(start, timeZone: timeZone)
        return ResolvedTiming(hint: self, startLocal: value,
                              note: "原文只写了“\(label)”：已安排在 \(Self.describe(start, calendar: calendar)) 提醒，可在卡片内调整。")
    }

    private func start(now: Date, calendar: Calendar) throws -> Date {
        let today = calendar.startOfDay(for: now)
        let hour = calendar.component(.hour, from: now)
        let soon = Self.nextSlot(after: now, calendar: calendar)
        // A slot later today only counts while it stays on today's date and before the cutoff.
        func laterToday(before cutoff: Int) -> Date? {
            guard calendar.isDate(soon, inSameDayAs: now), calendar.component(.hour, from: soon) <= cutoff else { return nil }
            return soon
        }
        let tomorrowMorning = Self.at(hour: 9, day: calendar.date(byAdding: .day, value: 1, to: today) ?? today, calendar: calendar)
        // Shared fallback: early mornings wait for 09:00, late nights move to tomorrow.
        let urgent = hour < 8 ? Self.at(hour: 9, day: today, calendar: calendar) : (laterToday(before: 21) ?? tomorrowMorning)
        switch self {
        case .asap:
            return urgent
        case .today:
            if hour < 8 { return Self.at(hour: 9, day: today, calendar: calendar) }
            return laterToday(before: 22) ?? tomorrowMorning
        case .tonight:
            let evening = Self.at(hour: 20, day: today, calendar: calendar)
            if evening > now.addingTimeInterval(900) { return evening }
            return laterToday(before: 23) ?? tomorrowMorning
        case .tomorrow:
            return tomorrowMorning
        case .weekend:
            switch calendar.component(.weekday, from: now) {
            case 1: return urgent // Sunday is already the end of the weekend.
            case 7:
                let morning = Self.at(hour: 10, day: today, calendar: calendar)
                if morning > now.addingTimeInterval(900) { return morning }
                return Self.at(hour: 10, day: calendar.date(byAdding: .day, value: 1, to: today) ?? today, calendar: calendar)
            default: return try Self.next(weekday: 7, hour: 10, after: now, calendar: calendar)
            }
        case .thisWeek:
            // Friday, Saturday and Sunday leave no room to wait for the end of the week.
            if [1, 6, 7].contains(calendar.component(.weekday, from: now)) { return urgent }
            return try Self.next(weekday: 6, hour: 9, after: now, calendar: calendar)
        case .nextWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
                  let next = calendar.date(byAdding: .day, value: 7, to: week.start) else { throw AppError("无法计算下周的日期。") }
            return Self.at(hour: 9, day: calendar.startOfDay(for: next), calendar: calendar)
        case .monthEnd:
            guard let month = calendar.dateInterval(of: .month, for: now) else { throw AppError("无法计算本月最后一天。") }
            let lastDay = calendar.startOfDay(for: month.end.addingTimeInterval(-1))
            let morning = Self.at(hour: 9, day: lastDay, calendar: calendar)
            return morning > now.addingTimeInterval(12 * 3600) ? morning : urgent
        }
    }

    /// Rounds up to the next half hour at least an hour out, so "尽快" lands on a readable slot.
    private static func nextSlot(after now: Date, calendar: Calendar) -> Date {
        let target = now.addingTimeInterval(3600)
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: target)
        let minute = parts.minute ?? 0
        parts.second = 0
        if minute > 30 { parts.minute = 0; parts.hour = (parts.hour ?? 0) + 1 }
        else if minute > 0 { parts.minute = 30 }
        return calendar.date(from: parts) ?? target
    }

    private static func at(hour: Int, day: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = hour; parts.minute = 0; parts.second = 0
        return calendar.date(from: parts) ?? day
    }

    private static func next(weekday: Int, hour: Int, after now: Date, calendar: Calendar) throws -> Date {
        let match = DateComponents(hour: hour, minute: 0, second: 0, weekday: weekday)
        guard let date = calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime) else {
            throw AppError("无法计算下一个目标日期。")
        }
        return date
    }

    /// Daylight saving can delete or duplicate a local clock time; step forward until the
    /// resolved value is both in the future and accepted by the same parser the writer uses.
    private func firstUsable(_ candidate: Date, after now: Date, calendar: Calendar, timeZone: String) throws -> Date {
        var value = candidate
        for _ in 0..<6 {
            if value > now, let parsed = try? Temporal.parse(Temporal.format(value, timeZone: timeZone), timeZone: timeZone, allDay: false) {
                return parsed
            }
            value = value.addingTimeInterval(3600)
        }
        throw AppError("无法为“\(label)”找到有效的提醒时刻，请手动填写时间。")
    }

    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    private static func describe(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: date)
        let weekday = weekdayNames[max(0, min(6, (parts.weekday ?? 1) - 1))]
        return String(format: "%d月%d日 %@ %02d:%02d", parts.month ?? 1, parts.day ?? 1, weekday, parts.hour ?? 0, parts.minute ?? 0)
    }
}

public struct ResolvedTiming: Sendable, Equatable {
    public let hint: DueHint
    public let startLocal: String
    public let note: String
}

/// Turns the model's relative timeframe into a concrete point reminder on this machine.
public enum TimingResolver {
    // A resolved slot only answers "when"; provenance and contradiction gaps must keep blocking.
    private static let timeWords = ["时间", "时刻", "日期", "几点", "什么时候", "时候", "date", "time"]
    private static let keepWords = ["来源", "出处", "截图", "图片", "附件", "原文", "矛盾", "星期", "周几", "冲突", "无法辨认", "看不清"]

    /// True when a resolved slot fully answers this gap, so the draft no longer needs to block on it.
    private static func answeredByResolution(_ entry: String) -> Bool {
        guard !keepWords.contains(where: { entry.localizedCaseInsensitiveContains($0) }) else { return false }
        return timeWords.contains { entry.localizedCaseInsensitiveContains($0) }
    }

    public static func apply(to extraction: Extraction, now: Date, fallbackTimeZone: String) -> Extraction {
        var result = extraction
        result.events = extraction.events.map { apply(to: $0, now: now, fallbackTimeZone: fallbackTimeZone) }
        return result
    }

    public static func apply(to event: ExtractedEvent, now: Date, fallbackTimeZone: String) -> ExtractedEvent {
        var event = event
        guard let hint = DueHint.parse(event.dueHint) else { event.dueHint = nil; return event }
        // An explicit time always wins; the hint is only a substitute for a missing one.
        guard event.startLocal == nil, !event.allDay else { event.dueHint = nil; return event }
        let zone = TimeZone(identifier: event.timeZone) == nil ? fallbackTimeZone : event.timeZone
        guard let resolved = try? hint.resolve(now: now, timeZone: zone) else { event.dueHint = nil; return event }
        event.timeZone = zone
        event.startLocal = resolved.startLocal
        event.dueHint = nil // Consumed: re-applying the resolver must never move a settled time.
        event.endLocal = nil
        event.reminderMinutes = event.reminderMinutes ?? 0
        event.timingNote = resolved.note
        // The resolved slot answers the time question; other gaps still block the draft.
        event.missing = event.missing.filter { !answeredByResolution($0) }
        return event
    }
}
