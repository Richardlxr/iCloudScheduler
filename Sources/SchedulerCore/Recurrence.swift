import Foundation

/// Only the repeat shapes EventKit can express exactly, so what the card promises is
/// what the calendar stores. Anything else stays a single event.
public struct Recurrence: Sendable, Equatable {
    public enum Rule: String, CaseIterable, Sendable {
        case daily
        case weekdays
        case weekly
        case biweekly
        case monthly
        case yearly
        public var label: String {
            switch self {
            case .daily: "每天"
            case .weekdays: "每个工作日"
            case .weekly: "每周"
            case .biweekly: "每两周"
            case .monthly: "每月"
            case .yearly: "每年"
            }
        }
    }
    public var rule: Rule
    /// 1 = Monday … 7 = Sunday, only meaningful for weekly and biweekly.
    public var days: [Int]
    public var until: String?
    public var count: Int?

    public init(rule: Rule, days: [Int] = [], until: String? = nil, count: Int? = nil) {
        self.rule = rule
        self.days = Array(Set(days.filter { (1...7).contains($0) })).sorted()
        self.until = until
        self.count = count
    }

    public init?(event: ExtractedEvent) {
        guard let raw = event.repeatRule, let rule = Rule(rawValue: raw) else { return nil }
        let until = event.repeatUntil.flatMap { $0.isEmpty ? nil : $0 }
        // A count and an end date together would be ambiguous; the explicit end date wins.
        self.init(rule: rule, days: event.repeatDays ?? [], until: until,
                  count: until == nil ? event.repeatCount : nil)
    }

    private static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    public var label: String {
        var text = rule.label
        if [.weekly, .biweekly].contains(rule), !days.isEmpty {
            // "每周" already carries the 周, so the listed days drop theirs: 每周三、周五.
            let listed = days.map { Self.weekdayNames[$0 - 1] }.joined(separator: "、")
            text = rule == .weekly ? "每" + listed : text + "的" + listed
        }
        if let until { text += " · 到 " + until }
        else if let count { text += " · 共 \(count) 次" }
        else { text += " · 不设结束" }
        return text
    }

    /// Reasons this repeat cannot be stored as described. An empty result means it is writable.
    public func errors(start: String?, timeZone: String) -> [String] {
        var errors: [String] = []
        if let count, !(2...500).contains(count) { errors.append("重复次数应在 2 到 500 之间。") }
        if let until {
            guard let end = try? Temporal.parse(until, timeZone: timeZone, allDay: true) else {
                errors.append("重复结束日期须使用 YYYY-MM-DD。")
                return errors
            }
            if let start, let begin = try? Temporal.parse(String(start.prefix(10)), timeZone: timeZone, allDay: true), end < begin {
                errors.append("重复结束日期早于开始日期。")
            }
        }
        if [.weekly, .biweekly].contains(rule), days.count > 7 { errors.append("每周重复最多选择 7 天。") }
        return errors
    }

    /// Weekday numbers the series actually lands on, Gregorian style (1 = Sunday).
    public var gregorianWeekdays: [Int] {
        switch rule {
        case .weekdays: [2, 3, 4, 5, 6]
        case .weekly, .biweekly: days.map { $0 == 7 ? 1 : $0 + 1 }
        default: []
        }
    }
}
