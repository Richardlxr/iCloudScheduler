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
            let samples = ["9.14晚上8点班会，提前一小时提醒", "明天开会，地点未定",
                           "@胡家瑜 计科2631  @刘欣睿 计科2631  两位还没有办理团组织关系转入，请尽快办理"]
            for (index, sample) in samples.enumerated() {
                let result = try await client.extract(input: PreparedInput(text: sample), config: config, key: key, now: now, timeZone: "Asia/Shanghai", reminder: 15)
                guard result.events.count == 1, let event = result.events.first, result.questions.isEmpty, event.location.isEmpty else {
                    throw AppError("样本 \(index + 1) 未通过字段/可选信息约束。")
                }
                if index == 0 {
                    guard event.startLocal == "2026-09-14T20:00:00", event.endLocal == nil, event.timeZone == "Asia/Shanghai",
                          event.reminderMinutes == 60, event.missing.isEmpty, event.assumptions.isEmpty else {
                        throw AppError("明确日程仍存在错误时间、默认值或多余追问。")
                    }
                } else if index == 1 {
                    guard event.startLocal == nil, event.endLocal == nil, !event.missing.isEmpty, !event.allDay else {
                        throw AppError("缺失时刻时模型虚构了时间。")
                    }
                } else {
                    // Only "尽快" is given: the model must classify it and let this machine pick the instant.
                    guard let start = event.startLocal, start.hasPrefix("2026-09-12") || start.hasPrefix("2026-09-13"),
                          event.endLocal == nil, !event.allDay, event.reminderMinutes == 0,
                          event.missing.isEmpty, event.assumptions.isEmpty, event.timingNote?.isEmpty == false else {
                        throw AppError("催办待办没有换算成本机的短期提醒。")
                    }
                }
                print("PASS live MiniMax sample \(index + 1): \(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))")
            }
            print("\(samples.count) live model contract checks passed; no calendar writes; no retries.")
            return 0
        } catch { print("FAIL live model contract: \(error.localizedDescription)"); return 1 }
    }
}
