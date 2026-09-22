import AppKit
import SchedulerCore

/// Opt-in live check: three synthetic requests to the saved MiniMax profile. Never writes to a calendar.
@MainActor
enum ModelContractChecks {
    static func run() async -> Int32 {
        do {
            let preferencesURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("iCloudScheduler/preferences.json")
            let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: preferencesURL))
            guard let config = preferences.providers.first(where: { $0.id == "minimax" }) else { throw AppError("没有保存的 MiniMax 配置。") }
            let key = try KeychainStore.read(provider: config.id)
            let now = try Temporal.parse("2026-09-12T18:00:00", timeZone: "Asia/Shanghai", allDay: false)
            let client = LLMClient()
            let samples = ["9.14晚上8点班会，提前一小时提醒",
                           "明天开会，地点未定",
                           "@胡家瑜 计科2631  @刘欣睿 计科2631  两位还没有办理团组织关系转入，请尽快办理",
                           "材料明天下午之前交到教务办",
                           "这学期每周三五上午8点高数课，到1月15日",
                           "原定明天下午的组会改到周四下午三点",
                           "明天的班会取消了"]
            for (index, sample) in samples.enumerated() {
                let result = try await client.extract(input: PreparedInput(text: sample), config: config, key: key, now: now, timeZone: "Asia/Shanghai", reminder: 15)
                guard result.events.count == 1, let event = result.events.first, result.questions.isEmpty else {
                    throw AppError("样本 \(index + 1) 未返回唯一日程。")
                }
                switch index {
                case 0:
                    guard event.startLocal == "2026-09-14T20:00:00", event.endLocal == nil, event.timeZone == "Asia/Shanghai",
                          event.reminderMinutes == 60, event.missing.isEmpty, event.assumptions.isEmpty,
                          event.location.isEmpty, !event.isTask else {
                        throw AppError("明确日程仍存在错误时间、默认值或多余追问。")
                    }
                case 1:
                    // The user thought this was enough: a meeting "tomorrow" gets a time, not a question.
                    guard let start = event.startLocal, start.hasPrefix("2026-09-13"), event.missing.isEmpty,
                          event.timingNote?.isEmpty == false, event.location.isEmpty else {
                        throw AppError("缺时刻的约定没有换算成可添加的时间，或又回头追问。")
                    }
                case 2:
                    guard let start = event.startLocal, start.hasPrefix("2026-09-12") || start.hasPrefix("2026-09-13"),
                          event.endLocal == nil, !event.allDay, event.reminderMinutes == 0, event.isTask,
                          event.missing.isEmpty, event.assumptions.isEmpty, event.timingNote?.isEmpty == false else {
                        throw AppError("催办待办没有换算成本机的短期提醒，或没有判定为待办。")
                    }
                case 3:
                    guard let start = event.startLocal, start.hasPrefix("2026-09-13"), start.contains("T1"),
                          event.allReminderMinutes.count >= 2, event.missing.isEmpty,
                          event.timingNote?.contains("截止") == true else {
                        throw AppError("截止时间没有排在下午，或没有提前提醒。")
                    }
                case 4:
                    guard let recurrence = event.recurrence, recurrence.rule == .weekly, recurrence.days == [3, 5],
                          recurrence.until?.hasSuffix("01-15") == true, event.startLocal?.contains("T08:00") == true else {
                        throw AppError("课表没有变成每周重复规则。")
                    }
                case 5:
                    guard event.intent == .update, event.targetTitle?.contains("组会") == true,
                          event.targetStartLocal?.hasPrefix("2026-09-13") == true,
                          event.startLocal == "2026-09-17T15:00:00" else {
                        throw AppError("改期没有同时给出目标和新时间。")
                    }
                case 6:
                    guard event.intent == .cancel, event.targetTitle?.contains("班会") == true,
                          event.targetStartLocal?.hasPrefix("2026-09-13") == true else {
                        throw AppError("取消没有指向原来的那条日程。")
                    }
                default: break
                }
                print("PASS live MiniMax sample \(index + 1): \(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))")
            }
            print("\(samples.count) live model contract checks passed; no calendar writes; no retries.")
            return 0
        } catch { print("FAIL live model contract: \(error.localizedDescription)"); return 1 }
    }
}
