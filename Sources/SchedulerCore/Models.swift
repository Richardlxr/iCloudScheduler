import Foundation

public struct AppError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ProviderPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let model: String
    public static let all: [Self] = [
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-flash"),
        .init(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/v1", model: "kimi-k2.6"),
        .init(id: "minimax", name: "MiniMax", baseURL: "https://api.minimax.cn/v1", model: "MiniMax-M3"),
        .init(id: "zhipu", name: "智谱", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3-flash"),
        .init(id: "qwen", name: "千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3.8-flash"),
        .init(id: "mimo", name: "小米 MiMo", baseURL: "https://api.xiaomimimo.com/v1", model: "mimo-v2.5"),
        .init(id: "custom", name: "自定义", baseURL: "", model: "")
    ]
}

public struct ProviderConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var baseURL: String
    public var model: String
    public var timeout: Double = 60
    public var credentialVersion = UUID()
    public var textVerified: Date?
    public var imageVerified: Date?
    public init(preset: ProviderPreset) {
        id = preset.id; baseURL = preset.baseURL; model = preset.model
    }
    public var name: String { ProviderPreset.all.first { $0.id == id }?.name ?? "自定义" }
    public mutating func invalidate() {
        credentialVersion = UUID(); textVerified = nil; imageVerified = nil
    }
}

public struct AppPreferences: Codable, Sendable {
    public var providers = ProviderPreset.all.map(ProviderConfig.init)
    public var activeProvider = "kimi"
    public var calendarID = ""
    public var timeZone = TimeZone.current.identifier
    public var reminderMinutes = 15
    public var allDayReminderMinutes = 540
    public var keepDraft = true
    /// Reminders destination for task-shaped drafts; empty until the user picks a list.
    public var reminderListID: String?
    public var tasksToReminders: Bool?
    public var sendTasksToReminders: Bool {
        get { tasksToReminders ?? true }
        set { tasksToReminders = newValue }
    }
    public var checkConflicts = true
    public var appearance = "system"
    public var shortcutKey: UInt32 = 49
    public var shortcutModifiers: UInt32 = 2048 // Carbon optionKey
    public var shortcutLabel = "⌥ Space"
    // Optional storage preserves compatibility with configurations from earlier builds.
    public var confirmationRequired: Bool?
    public var submitWithEnter: Bool?
    public var hideAfterSubmit: Bool?
    public var customAllDayReminder: AllDayReminder?
    public var menuBarVisible: Bool?
    public var showMenuBar: Bool {
        get { menuBarVisible ?? true }
        set { menuBarVisible = newValue }
    }
    public var enterSubmits: Bool {
        get { submitWithEnter ?? false }
        set { submitWithEnter = newValue }
    }
    public var runInBackground: Bool {
        get { hideAfterSubmit ?? false }
        set { hideAfterSubmit = newValue }
    }
    public var allDayReminder: AllDayReminder {
        get { customAllDayReminder ?? AllDayReminder(legacyMinutes: allDayReminderMinutes) }
        set { customAllDayReminder = newValue }
    }
    public var confirmBeforeAdding: Bool {
        get { confirmationRequired ?? true }
        set { confirmationRequired = newValue }
    }
    public init() {}
}

public struct AllDayReminder: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var daysBefore: Int
    public var hour: Int
    public var minute: Int
    public init(enabled: Bool = true, daysBefore: Int = 0, hour: Int = 9, minute: Int = 0) {
        self.enabled = enabled; self.daysBefore = daysBefore; self.hour = hour; self.minute = minute
    }
    public init(legacyMinutes: Int) {
        self.init(enabled: legacyMinutes != -1, daysBefore: legacyMinutes == -360 ? 1 : 0, hour: legacyMinutes == -360 ? 18 : 9)
    }
    public var isValid: Bool { (0...7).contains(daysBefore) && (0...23).contains(hour) && (0...59).contains(minute) }
}

public struct ExtractedEvent: Codable, Equatable, Sendable {
    public var title: String
    public var startLocal: String?
    public var endLocal: String?
    public var timeZone: String
    public var allDay: Bool
    public var location: String
    public var notes: String
    public var reminderMinutes: Int?
    public var missing: [String]
    public var assumptions: [String]
    public var source: String
    // Everything below is optional on the wire and in storage: drafts written by earlier
    // builds keep decoding, and a provider that omits a field is not a contract failure.
    /// Extra alarms in minutes before the start, on top of reminderMinutes.
    public var extraReminderMinutes: [Int]?
    /// "event" goes to the calendar, "task" can go to Reminders where it survives until it is done.
    public var kind: String?
    /// Relative day and part of day, used when the text gives no clock time.
    public var dueDay: String?
    public var dayPart: String?
    /// Chinese lunar date as MM-DD or YYYY-MM-DD, with a leading + for a leap month.
    public var lunarDate: String?
    /// The resolved instant is a deadline, so the reminders are placed ahead of it.
    public var isDeadline: Bool?
    /// Recurrence, expressed in the few shapes EventKit can represent exactly.
    public var repeatRule: String?
    public var repeatDays: [Int]?
    public var repeatUntil: String?
    public var repeatCount: Int?
    /// "add", "update" or "cancel": what the message asks for. Anything else is treated as "add".
    public var action: String?
    /// What the message calls the existing item, and when it says that item was. Matching happens
    /// on this machine: calendar titles are never sent to the model.
    public var targetTitle: String?
    public var targetStartLocal: String?
    /// Filled in locally after a timeframe is resolved; shown as a review note, never sent to the model.
    public var timingNote: String?
    public init(title: String = "新日程", startLocal: String? = nil, endLocal: String? = nil,
                timeZone: String = TimeZone.current.identifier, allDay: Bool = false,
                location: String = "", notes: String = "", reminderMinutes: Int? = 15,
                missing: [String] = [], assumptions: [String] = [], source: String = "手动创建",
                extraReminderMinutes: [Int]? = nil, kind: String? = nil,
                dueDay: String? = nil, dayPart: String? = nil, lunarDate: String? = nil, isDeadline: Bool? = nil,
                repeatRule: String? = nil, repeatDays: [Int]? = nil, repeatUntil: String? = nil, repeatCount: Int? = nil,
                action: String? = nil, targetTitle: String? = nil, targetStartLocal: String? = nil,
                timingNote: String? = nil) {
        self.title = title; self.startLocal = startLocal; self.endLocal = endLocal
        self.timeZone = timeZone; self.allDay = allDay; self.location = location; self.notes = notes
        self.reminderMinutes = reminderMinutes; self.missing = missing
        self.assumptions = assumptions; self.source = source
        self.extraReminderMinutes = extraReminderMinutes; self.kind = kind
        self.dueDay = dueDay; self.dayPart = dayPart; self.lunarDate = lunarDate; self.isDeadline = isDeadline
        self.repeatRule = repeatRule; self.repeatDays = repeatDays
        self.repeatUntil = repeatUntil; self.repeatCount = repeatCount
        self.action = action; self.targetTitle = targetTitle; self.targetStartLocal = targetStartLocal
        self.timingNote = timingNote
    }
}

extension ExtractedEvent {
    public var isPointReminder: Bool { !allDay && endLocal == nil }
    /// Every alarm this event asks for, closest to the start first.
    public var allReminderMinutes: [Int] {
        guard let primary = reminderMinutes else { return [] }
        return Array(Set([primary] + (extraReminderMinutes ?? []))).sorted()
    }
    /// A task is something to finish, not an appointment; it may belong in Reminders.
    public var isTask: Bool { kind == "task" }
    public var intent: EventAction { EventAction(rawValue: action ?? "") ?? .add }
    public var recurrence: Recurrence? { Recurrence(event: self) }
}

public struct Extraction: Codable, Sendable {
    public var events: [ExtractedEvent]
    public var questions: [String]
    public init(events: [ExtractedEvent], questions: [String] = []) { self.events = events; self.questions = questions }
}

/// What a message asks the app to do with an item. Only adding may ever happen unattended.
public enum EventAction: String, CaseIterable, Sendable {
    case add
    case update
    case cancel
    public var label: String {
        switch self {
        case .add: "新增"
        case .update: "改期"
        case .cancel: "取消"
        }
    }
    public var touchesExistingEvent: Bool { self != .add }
}

/// An existing calendar event that a change message might be talking about.
/// Found on this machine; the model never sees these titles.
public struct CalendarMatch: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startLocal: String
    public var endLocal: String?
    public var allDay: Bool
    public var timeZone: String
    public var calendarName: String
    public var partOfSeries: Bool
    /// Set when this event cannot be changed from here; the reason is shown instead of acting.
    public var blockedReason: String?
    public var isEditable: Bool { blockedReason == nil }
    public init(id: String, title: String, startLocal: String, endLocal: String?, allDay: Bool,
                timeZone: String, calendarName: String, partOfSeries: Bool, blockedReason: String? = nil) {
        self.id = id; self.title = title; self.startLocal = startLocal; self.endLocal = endLocal
        self.allDay = allDay; self.timeZone = timeZone; self.calendarName = calendarName
        self.partOfSeries = partOfSeries; self.blockedReason = blockedReason
    }
    public var when: String {
        let day = String(startLocal.prefix(10))
        guard !allDay, startLocal.count > 10 else { return day + " 全天" }
        return day + " " + String(startLocal.dropFirst(11).prefix(5))
    }
    public var display: String { "\(title) · \(when) · \(calendarName)" + (partOfSeries ? " · 重复日程的这一次" : "") }
}

/// Enough of an existing event to put it back the way it was.
public struct EventSnapshot: Codable, Equatable, Sendable {
    public var title: String
    public var startLocal: String
    public var endLocal: String
    public var allDay: Bool
    public var timeZone: String
    public var location: String
    public var notes: String
    public var calendarID: String
    public var partOfSeries: Bool
    public init(title: String, startLocal: String, endLocal: String, allDay: Bool, timeZone: String,
                location: String, notes: String, calendarID: String, partOfSeries: Bool) {
        self.title = title; self.startLocal = startLocal; self.endLocal = endLocal; self.allDay = allDay
        self.timeZone = timeZone; self.location = location; self.notes = notes
        self.calendarID = calendarID; self.partOfSeries = partOfSeries
    }
    public var when: String {
        let day = String(startLocal.prefix(10))
        guard !allDay, startLocal.count > 10 else { return day + " 全天" }
        return day + " " + String(startLocal.dropFirst(11).prefix(5))
    }
}

public struct Draft: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var event: ExtractedEvent
    /// The destination container: a calendar, or a Reminders list when the draft goes there.
    public var calendarID: String
    public var selected = true
    public var reviewed = false
    public var conflictAcknowledged = false
    public var conflicts: [String] = []
    /// Optional so drafts stored by earlier builds keep decoding as calendar events.
    public var toReminders: Bool?
    /// Existing events this change message might mean, and the one the user picked.
    public var matches: [CalendarMatch]?
    public var targetID: String?
    public var intent: EventAction { event.intent }
    public var target: CalendarMatch? { (matches ?? []).first { $0.id == targetID } }
    public var usesReminders: Bool { toReminders == true }
    public init(event: ExtractedEvent, calendarID: String, toReminders: Bool? = nil) {
        self.event = event; self.calendarID = calendarID; self.toReminders = toReminders
    }
}

public struct CalendarChoice: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var source: String
    public var displayName: String { "\(source) / \(title)" }
    public init(id: String, title: String, source: String) { self.id = id; self.title = title; self.source = source }
}

public struct PreparedInput: Sendable {
    public var text: String
    public var images: [ImagePart]
    public init(text: String, images: [ImagePart] = []) { self.text = text; self.images = images }
}

public struct ImagePart: Sendable {
    public var label: String
    public var jpeg: Data
    public init(label: String, jpeg: Data) { self.label = label; self.jpeg = jpeg }
}

public struct OperationReceipt: Codable, Identifiable, Sendable {
    public var id: UUID
    public var batchID: UUID
    public var draft: Draft
    public var createdAt: Date
    public var status: String
    public var eventID: String?
    public var fingerprint: String?
    public var warning: String?
    public var message: String
    /// The state of an existing event before this operation changed or removed it.
    public var previous: EventSnapshot?
    public init(id: UUID = UUID(), batchID: UUID, draft: Draft, status: String = "prepared") {
        self.id = id; self.batchID = batchID; self.draft = draft; self.status = status
        createdAt = Date(); message = ""
    }
    public var marker: String { "[iCloudScheduler:\(id.uuidString)]" }
}
