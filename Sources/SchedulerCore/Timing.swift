import Foundation

/// The day a piece of text points at when it gives no calendar date.
/// The model only classifies the wording; this file picks the instant, so a
/// reminder never depends on model date arithmetic.
public enum DueDay: String, CaseIterable, Sendable {
    case asap
    case today
    case tomorrow
    case dayAfter = "day_after"
    case mon, tue, wed, thu, fri, sat, sun
    case weekend
    case thisWeek = "this_week"
    case nextWeek = "next_week"
    case monthEnd = "month_end"

    public var label: String {
        switch self {
        case .asap: "尽快"
        case .today: "今天"
        case .tomorrow: "明天"
        case .dayAfter: "后天"
        case .mon: "周一"
        case .tue: "周二"
        case .wed: "周三"
        case .thu: "周四"
        case .fri: "周五"
        case .sat: "周六"
        case .sun: "周日"
        case .weekend: "周末"
        case .thisWeek: "本周内"
        case .nextWeek: "下周"
        case .monthEnd: "本月底"
        }
    }
    /// Gregorian weekday number (1 = Sunday) for the cases that name one.
    var weekday: Int? {
        switch self {
        case .mon: 2; case .tue: 3; case .wed: 4; case .thu: 5
        case .fri: 6; case .sat: 7; case .sun: 1
        default: nil
        }
    }
    /// The hour used when the text names a day but no part of the day.
    var defaultHour: Int {
        switch self {
        case .weekend: 10
        default: 9
        }
    }
}

/// Chinese text names a part of the day far more often than a clock time.
public enum DayPart: String, CaseIterable, Sendable {
    case earlyMorning = "early_morning"
    case morning
    case noon
    case afternoon
    case evening

    public var label: String {
        switch self {
        case .earlyMorning: "早上"
        case .morning: "上午"
        case .noon: "中午"
        case .afternoon: "下午"
        case .evening: "晚上"
        }
    }
    public var hour: Int {
        switch self {
        case .earlyMorning: 7
        case .morning: 9
        case .noon: 12
        case .afternoon: 15
        case .evening: 20
        }
    }
}

/// A day and an optional part of it, as reported by the model.
public struct DueWindow: Sendable, Equatable {
    public var day: DueDay?
    public var part: DayPart?
    public init?(day: String?, part: String?) {
        let day = day.flatMap { $0.isEmpty ? nil : DueDay(rawValue: $0) }
        let part = part.flatMap { $0.isEmpty ? nil : DayPart(rawValue: $0) }
        guard day != nil || part != nil else { return nil }
        self.day = day; self.part = part
    }
    public init(day: DueDay?, part: DayPart? = nil) { self.day = day; self.part = part }

    public var label: String {
        switch (day, part) {
        case let (day?, part?): day == .asap ? part.label : day.label + part.label
        case let (day?, nil): day.label
        case let (nil, part?): part.label
        default: ""
        }
    }

    public func resolve(now: Date, timeZone: String) throws -> ResolvedTiming {
        guard let zone = TimeZone(identifier: timeZone) else { throw AppError("无法识别时区：\(timeZone)") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2 // Monday, matching the extraction context.
        let start = try Timing.usableStart(try candidate(now: now, calendar: calendar), after: now,
                                           timeZone: timeZone, label: label)
        return ResolvedTiming(startLocal: Temporal.format(start, timeZone: timeZone),
                              note: "原文只写了“\(label)”：已安排在 \(Timing.describe(start, calendar: calendar)) 提醒，可在卡片内调整。")
    }

    private func candidate(now: Date, calendar: Calendar) throws -> Date {
        let today = calendar.startOfDay(for: now)
        let hour = part?.hour
        // Without a part of day, "尽快" and a late "今天" fall back to the next readable slot.
        let slot = Timing.nextSlot(after: now, calendar: calendar)
        func laterToday(before cutoff: Int) -> Date? {
            guard calendar.isDate(slot, inSameDayAs: now), calendar.component(.hour, from: slot) <= cutoff else { return nil }
            return slot
        }
        func at(_ hour: Int, _ day: Date) -> Date { Timing.at(hour: hour, day: day, calendar: calendar) }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let tomorrowSlot = at(hour ?? 9, tomorrow)
        // Early mornings wait for the working day; late nights move to tomorrow.
        let urgent = calendar.component(.hour, from: now) < 8
            ? at(hour ?? 9, today)
            : (laterToday(before: 21) ?? tomorrowSlot)
        // A named part of the day is a real request: keep it, and only move on once today's slot is gone.
        func partOfDay(_ day: Date, fallback: @autoclosure () -> Date) -> Date {
            guard let hour else { return fallback() }
            let value = at(hour, day)
            return value > now.addingTimeInterval(300) ? value : fallback()
        }
        // A bare part of day names no day, so it may roll to tomorrow; an explicit "今天" may not.
        switch day ?? .asap {
        case .asap:
            return hour == nil ? urgent : partOfDay(today, fallback: partOfDay(tomorrow, fallback: urgent))
        case .today:
            if hour != nil { return partOfDay(today, fallback: urgent) }
            if calendar.component(.hour, from: now) < 8 { return at(9, today) }
            return laterToday(before: 22) ?? tomorrowSlot
        case .tomorrow:
            return at(hour ?? 9, tomorrow)
        case .dayAfter:
            return at(hour ?? 9, calendar.date(byAdding: .day, value: 2, to: today) ?? today)
        case .mon, .tue, .wed, .thu, .fri, .sat, .sun:
            guard let weekday = (day ?? .mon).weekday else { return urgent }
            return try Timing.next(weekday: weekday, hour: hour ?? 9, after: now, calendar: calendar)
        case .weekend:
            switch calendar.component(.weekday, from: now) {
            case 1: return partOfDay(today, fallback: urgent) // Sunday is already the end of the weekend.
            case 7: return partOfDay(today, fallback: at(hour ?? 10, tomorrow))
            default: return try Timing.next(weekday: 7, hour: hour ?? 10, after: now, calendar: calendar)
            }
        case .thisWeek:
            // Friday, Saturday and Sunday leave no room to wait for the end of the week.
            if [1, 6, 7].contains(calendar.component(.weekday, from: now)) { return partOfDay(today, fallback: urgent) }
            return try Timing.next(weekday: 6, hour: hour ?? 9, after: now, calendar: calendar)
        case .nextWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
                  let next = calendar.date(byAdding: .day, value: 7, to: week.start) else { throw AppError("无法计算下周的日期。") }
            return at(hour ?? 9, calendar.startOfDay(for: next))
        case .monthEnd:
            guard let month = calendar.dateInterval(of: .month, for: now) else { throw AppError("无法计算本月最后一天。") }
            let lastDay = calendar.startOfDay(for: month.end.addingTimeInterval(-1))
            let value = at(hour ?? 9, lastDay)
            return value > now.addingTimeInterval(12 * 3600) ? value : urgent
        }
    }
}

public struct ResolvedTiming: Sendable, Equatable {
    public let startLocal: String
    public let note: String
}

public enum Timing {
    /// Rounds up to the next half hour at least an hour out, so "尽快" lands on a readable slot.
    static func nextSlot(after now: Date, calendar: Calendar) -> Date {
        let target = now.addingTimeInterval(3600)
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: target)
        let minute = parts.minute ?? 0
        parts.second = 0
        if minute > 30 { parts.minute = 0; parts.hour = (parts.hour ?? 0) + 1 }
        else if minute > 0 { parts.minute = 30 }
        return calendar.date(from: parts) ?? target
    }

    static func at(hour: Int, day: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = hour; parts.minute = 0; parts.second = 0
        return calendar.date(from: parts) ?? day
    }

    static func next(weekday: Int, hour: Int, after now: Date, calendar: Calendar) throws -> Date {
        let match = DateComponents(hour: hour, minute: 0, second: 0, weekday: weekday)
        guard let date = calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime) else {
            throw AppError("无法计算下一个目标日期。")
        }
        return date
    }

    /// Daylight saving can delete or duplicate a local clock time; step forward until the
    /// value is both in the future and accepted by the same parser the writer uses.
    static func usableStart(_ candidate: Date, after now: Date, timeZone: String, label: String) throws -> Date {
        var value = candidate
        for _ in 0..<6 {
            if value > now, let parsed = try? Temporal.parse(Temporal.format(value, timeZone: timeZone), timeZone: timeZone, allDay: false) {
                return parsed
            }
            value = value.addingTimeInterval(3600)
        }
        throw AppError("无法为“\(label)”找到有效的提醒时刻，请手动填写时间。")
    }

    static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func describe(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: date)
        let weekday = weekdayNames[max(0, min(6, (parts.weekday ?? 1) - 1))]
        return String(format: "%d月%d日 %@ %02d:%02d", parts.month ?? 1, parts.day ?? 1, weekday, parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// A Chinese lunar date, converted on this machine. The model reports the characters it
/// read, never a converted Gregorian date, because lunar arithmetic is where models drift.
public struct LunarDate: Sendable, Equatable {
    public var year: Int?
    public var month: Int
    public var day: Int
    public var isLeapMonth: Bool

    /// Accepts "MM-DD" and "YYYY-MM-DD", with a leading "+" marking a leap month.
    public init?(_ raw: String?) {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        isLeapMonth = text.hasPrefix("+")
        if isLeapMonth { text.removeFirst() }
        let parts = text.split(separator: "-").map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        switch parts.count {
        case 2: year = nil; month = Int(parts[0]) ?? 0; day = Int(parts[1]) ?? 0
        case 3: year = Int(parts[0]); month = Int(parts[1]) ?? 0; day = Int(parts[2]) ?? 0
        default: return nil
        }
        guard (1...12).contains(month), (1...30).contains(day) else { return nil }
    }

    public var label: String {
        let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
        let tens = ["初", "十", "廿", "三"]
        let digits = ["十", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let dayText = day == 10 ? "初十" : day == 20 ? "二十" : day == 30 ? "三十"
            : tens[min(3, (day - 1) / 10)] + digits[day % 10]
        return "农历" + (isLeapMonth ? "闰" : "") + months[month - 1] + "月" + dayText
    }

    /// The first matching day at or after `now`, searched in the Chinese calendar itself so
    /// leap months and the varying month lengths come from the system, not from a table.
    public func gregorianDay(onOrAfter now: Date, timeZone: String) throws -> Date {
        guard let zone = TimeZone(identifier: timeZone) else { throw AppError("无法识别时区：\(timeZone)") }
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = zone
        var chinese = Calendar(identifier: .chinese); chinese.timeZone = zone
        // A named year is searched from its own January: the user asked for that year, even if it has passed.
        var cursor = gregorian.startOfDay(for: now)
        if let year, let january = gregorian.date(from: DateComponents(timeZone: zone, year: year, month: 1, day: 1)) {
            cursor = january
        }
        // A lunar date falls once per lunar year, which can run a few weeks past a Gregorian one.
        let horizon = 400
        for _ in 0...horizon {
            let parts = chinese.dateComponents([.month, .day, .isLeapMonth], from: cursor)
            if parts.month == month, parts.day == day, (parts.isLeapMonth ?? false) == isLeapMonth {
                return cursor
            }
            guard let next = gregorian.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        throw AppError("\(label)在可预期的范围内不存在，请改用公历日期。")
    }
}

/// Turns the model's relative timeframe, lunar date and deadline flag into concrete values.
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
        if TimeZone(identifier: event.timeZone) == nil { event.timeZone = fallbackTimeZone }
        let zone = event.timeZone
        var notes: [String] = []
        if let lunar = LunarDate(event.lunarDate), event.startLocal == nil {
            if let day = try? lunar.gregorianDay(onOrAfter: now, timeZone: zone) {
                let window = DueWindow(day: nil, part: DayPart(rawValue: event.dayPart ?? ""))
                if let hour = window.part?.hour,
                   let instant = try? Timing.usableStart(Self.at(hour: hour, day: day, zone: zone), after: now, timeZone: zone, label: lunar.label) {
                    event.startLocal = Temporal.format(instant, timeZone: zone)
                    event.endLocal = nil; event.allDay = false
                } else {
                    // A lunar date on its own is a date, not an instant: keep it as a whole day.
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: zone) ?? .current
                    event.startLocal = Temporal.format(day, timeZone: zone, allDay: true)
                    event.endLocal = Temporal.format(calendar.date(byAdding: .day, value: 1, to: day) ?? day, timeZone: zone, allDay: true)
                    event.allDay = true
                }
                notes.append("\(lunar.label)已按本机换算为 \(event.startLocal ?? "")\(event.allDay ? "（全天）" : "")。")
            } else {
                event.missing.append("可换算的公历日期")
            }
        }
        event.lunarDate = nil
        if let window = DueWindow(day: event.dueDay, part: event.dayPart), event.startLocal == nil, !event.allDay,
           let resolved = try? window.resolve(now: now, timeZone: zone) {
            event.startLocal = resolved.startLocal
            event.endLocal = nil
            notes.append(resolved.note)
        }
        event.dueDay = nil; event.dayPart = nil
        if event.startLocal != nil {
            // A deadline is the moment work is due, so the alarms belong ahead of it.
            if event.isDeadline == true, !event.allDay {
                let lead = leadTimes(before: event.startLocal, timeZone: zone, now: now)
                event.reminderMinutes = lead.first
                event.extraReminderMinutes = Array(lead.dropFirst())
                notes.append("这是截止时间：" + lead.reversed().map { describe(minutes: $0) }.joined(separator: "、") + "各提醒一次。")
            } else if event.isPointReminder {
                event.reminderMinutes = event.reminderMinutes ?? 0
            }
            event.missing = event.missing.filter { !answeredByResolution($0) }
        }
        event.extraReminderMinutes = event.extraReminderMinutes.map { minutes in
            Array(Set(minutes.filter { (0...10080).contains($0) && $0 != event.reminderMinutes })).sorted().prefix(4).map { $0 }
        }
        if let existing = event.timingNote, !existing.isEmpty { notes.insert(existing, at: 0) }
        event.timingNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
        return event
    }

    private static func at(hour: Int, day: Date, zone: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        return Timing.at(hour: hour, day: day, calendar: calendar)
    }

    /// Two alarms for anything at least a day out, one otherwise: enough warning without noise.
    private static func leadTimes(before startLocal: String?, timeZone: String, now: Date) -> [Int] {
        guard let startLocal, let start = try? Temporal.parse(startLocal, timeZone: timeZone, allDay: false) else { return [0] }
        let available = start.timeIntervalSince(now)
        if available >= 2 * 86400 { return [0, 1440] }
        if available >= 8 * 3600 { return [0, 240] }
        return [0]
    }

    private static func describe(minutes: Int) -> String {
        switch minutes {
        case 0: "截止当时"
        case 1440: "提前一天"
        case 60...: "提前 \(minutes / 60) 小时"
        default: "提前 \(minutes) 分钟"
        }
    }
}
