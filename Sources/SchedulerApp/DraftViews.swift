import SwiftUI
import SchedulerCore

struct DraftReviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("\(model.drafts.count) 项安排").fontWeight(.medium); Spacer(); Label(model.preferences.timeZone, systemImage: "globe") }.font(.caption).foregroundStyle(.secondary)
                    if !model.questions.isEmpty {
                        Text(model.questions.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if model.drafts.isEmpty {
                        Text("补充一句话，继续生成安排。").font(.callout)
                        DraftClarificationView(model: model, draftID: nil)
                    }
                    ForEach($model.drafts) { $draft in
                        VStack(alignment: .leading, spacing: 11) {
                            HStack(alignment: .top, spacing: 10) {
                                if model.drafts.count > 1 || !draft.selected { Toggle("选择 \(draft.event.title)", isOn: $draft.selected).labelsHidden().toggleStyle(.checkbox) }
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 7) {
                                        if draft.intent.touchesExistingEvent {
                                            Text(draft.intent.label).font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(draft.intent == .cancel ? Color.red : Color.orange)
                                                .padding(.horizontal, 7).padding(.vertical, 2)
                                                .background((draft.intent == .cancel ? Color.red : Color.orange).opacity(0.12), in: Capsule())
                                        }
                                        Text(draft.event.title).font(.system(size: 16, weight: .semibold))
                                    }
                                    if draft.intent == .cancel {
                                        Label(draft.target.map { "取消 " + $0.when } ?? "等待选择要取消的日程", systemImage: "calendar.badge.minus")
                                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.red)
                                    } else if draft.intent == .update {
                                        Label(changeTime(draft), systemImage: "calendar.badge.clock")
                                            .font(.system(size: 13, weight: .medium)).foregroundStyle(draft.target == nil ? Color.orange : Color.primary)
                                    } else {
                                        Label(displayTime(draft.event, toReminders: draft.usesReminders),
                                              systemImage: draft.event.startLocal == nil ? "clock.badge.questionmark" : "clock")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(draft.event.startLocal == nil ? Color.orange : Color.primary)
                                    }
                                    if let recurrence = draft.event.recurrence {
                                        Label(recurrence.label, systemImage: "repeat").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                                    }
                                    HStack(spacing: 10) {
                                        if !draft.event.location.isEmpty { Label(draft.event.location, systemImage: "mappin.and.ellipse") }
                                        if !draft.intent.touchesExistingEvent { Label(reminderText(draft.event), systemImage: "bell") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                    if !draft.intent.touchesExistingEvent {
                                    HStack(spacing: 5) {
                                        Image(systemName: draft.usesReminders ? "checklist" : "calendar")
                                        Text(model.destinationName(draft))
                                        if draft.event.isTask && !model.isDemo {
                                            Button(draft.usesReminders ? "改存到日历" : "改存到提醒事项") {
                                                model.setDestination(!draft.usesReminders, for: draft.id)
                                            }.buttonStyle(.link).font(.caption2)
                                        }
                                    }.font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if !draft.intent.touchesExistingEvent {
                                    Button("手动编辑") { model.editingID = draft.id; model.resizePanel?() }.buttonStyle(.borderless)
                                }
                            }
                            if !draft.conflicts.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label("时间冲突", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
                                    Text(draft.conflicts.joined(separator: "、")).font(.caption)
                                }.foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                            }
                            if draft.intent.touchesExistingEvent {
                                ChangeTargetView(model: model, draft: draft)
                            } else if draft.event.startLocal == nil && !model.isDemo {
                                QuickTimeRow(model: model, draftID: draft.id)
                            }
                            let notes = DraftValidator.reviewNotes(draft)
                            if !notes.isEmpty {
                                Text(notes.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            let errors = DraftValidator.errorsAfterReview(draft)
                            if !errors.isEmpty {
                                Text(errors.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                            }
                            // Refining through the model would re-extract the event and could lose
                            // which existing entry the change points at.
                            if model.editingID == nil && !model.isDemo && !draft.intent.touchesExistingEvent {
                                DraftClarificationView(model: model, draftID: draft.id)
                            }
                            if model.editingID == draft.id {
                                Divider()
                                DraftEditor(draft: draft, calendars: model.calendars, save: { value in
                                    if let i = model.drafts.firstIndex(where: { $0.id == value.id }) { model.drafts[i] = value }
                                    model.editingID = nil; model.refreshConflicts(); model.persistDraft(); model.resizePanel?()
                                }, cancel: { model.editingID = nil; model.resizePanel?() })
                            }
                        }.disabled(model.isGenerating).padding(16).appCard(border: draft.conflicts.isEmpty ? AppStyle.border : Color.orange.opacity(0.5))
                    }
                    if !model.calendarAuthorized && !model.isDemo {
                        Button("允许日历访问") { model.authorizeCalendar() }.font(.caption)
                    }
                    if model.isGenerating {
                        HStack { ProgressView().controlSize(.small); Text("正在理解补充…"); Spacer(); Button("取消") { model.cancelAnalysis() } }.font(.caption)
                    }
                    DisclosureGroup("查看原始内容") { Text(model.text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.bottom, 14)
            }
            Divider()
            HStack(spacing: 12) {
                Button(role: .destructive) { model.deleteSelectedDrafts() } label: {
                    Label(model.selectedDrafts.count > 1 ? "丢弃 \(model.selectedDrafts.count) 项" : "丢弃", systemImage: "trash")
                        .frame(minWidth: 65)
                }.buttonStyle(.bordered).help("丢弃选中的草稿，日历中已有的日程不受影响")
                    .disabled(model.writing || model.isGenerating || model.selectedDrafts.isEmpty)
                Spacer()
                Button(model.reviewActionTitle, role: model.selectedIntents == [.cancel] ? .destructive : nil) { model.confirmAndWriteSelected() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.isDemo || model.writing || model.isGenerating || model.editingID != nil || model.selectedDrafts.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }.padding(14).background(AppStyle.surface)
        }
    }
    private func changeTime(_ draft: Draft) -> String {
        guard let target = draft.target else { return "等待选择要改期的日程" }
        guard let start = draft.event.startLocal else { return target.when + " · 只改地点" }
        return target.when + "  →  " + CalendarMatch(id: "", title: "", startLocal: start, endLocal: nil,
                                                     allDay: draft.event.allDay, timeZone: draft.event.timeZone,
                                                     calendarName: "", partOfSeries: false).when
    }
    private func reminderText(_ event: ExtractedEvent) -> String {
        if event.allDay { return "全天提醒按设置" }
        let minutes = event.allReminderMinutes.sorted(by: >)
        guard !minutes.isEmpty else { return "不提醒" }
        // The earliest alarm keeps the 提前, the rest are read against it.
        let parts = minutes.map { value -> String in
            switch value {
            case 0: "开始时"
            case _ where value % 1440 == 0: "\(value / 1440) 天"
            case _ where value % 60 == 0: "\(value / 60) 小时"
            default: "\(value) 分钟"
            }
        }
        return (minutes[0] == 0 ? "" : "提前 ") + parts.joined(separator: "、") + "提醒"
    }
    private func displayTime(_ event: ExtractedEvent, toReminders: Bool = false) -> String {
        guard let start = event.startLocal else { return "需要补充开始时间" }
        if event.isPointReminder {
            return "\(start.prefix(10))  \(start.dropFirst(11).prefix(5)) · " + (toReminders ? "待办到期" : "时间点提醒")
        }
        guard let end = event.endLocal else { return "需要补充结束日期" }
        if event.allDay {
            if let interval = try? Temporal.interval(event) {
                let lastDay = Temporal.format(interval.end.addingTimeInterval(-1), timeZone: event.timeZone, allDay: true)
                return start == lastDay ? "\(start) · 全天" : "\(start) → \(lastDay) · 全天"
            }
            return "\(start) → \(end) · 全天"
        }
        let startDay = String(start.prefix(10)), endDay = String(end.prefix(10))
        let startClock = String(start.dropFirst(11).prefix(5)), endClock = String(end.dropFirst(11).prefix(5))
        return startDay == endDay ? "\(startDay)  \(startClock) – \(endClock)" : "\(startDay) \(startClock) → \(endDay) \(endClock)"
    }
}

/// Changing or removing an existing event always shows which one, and never picks for the user
/// when more than one could be meant.
struct ChangeTargetView: View {
    @ObservedObject var model: AppModel
    let draft: Draft
    private var matches: [CalendarMatch] { draft.matches ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if matches.isEmpty {
                Label("日历里没有找到对应的日程", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
                Text("可能原来的日程不在这台设备上，或标题、日期与消息里的说法不同。").font(.caption2).foregroundStyle(.secondary)
                if draft.intent == .update && !model.isDemo {
                    Button("改为新增日程") { model.convertToAddition(draft.id) }.buttonStyle(SuggestionStyle())
                }
            } else {
                Text(matches.count == 1 ? "将处理日历中的这条日程：" : "有 \(matches.count) 条可能对应，请选择要处理的一条：")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(matches) { match in
                    Button {
                        model.selectTarget(draft.targetID == match.id ? nil : match.id, for: draft.id)
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: draft.targetID == match.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(draft.targetID == match.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.title).font(.system(size: 12, weight: .medium))
                                Text(match.when + " · " + match.calendarName + (match.partOfSeries ? " · 重复日程的这一次" : ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let reason = match.blockedReason {
                                    Text(reason).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isDemo || !match.isEditable)
                }
                if draft.intent == .cancel {
                    Text("确认后会从日历中删除这一条；近期记录里可以恢复。").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("只改动时间和地点，提醒与其他内容保持不变。").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(11).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .disabled(model.isGenerating || model.writing)
    }
}

/// One tap sets a concrete reminder time on this machine; no model call and no extra cost.
struct QuickTimeRow: View {
    @ObservedObject var model: AppModel
    let draftID: UUID
    var title = "没有具体时间，先选一个提醒时机："
    private let windows: [DueWindow] = [
        .init(day: .asap), .init(day: .today, part: .evening),
        .init(day: .tomorrow, part: .morning), .init(day: .tomorrow, part: .afternoon),
        .init(day: .thisWeek)
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(windows, id: \.label) { window in
                    Button(window.label) { model.applyQuickTime(window, to: draftID) }
                        .buttonStyle(SuggestionStyle()).help("按“\(window.label)”在本机换算成一个提醒时刻")
                }
                Spacer(minLength: 0)
            }
        }.disabled(model.isGenerating || model.writing)
    }
}

struct DraftClarificationView: View {
    @ObservedObject var model: AppModel
    let draftID: UUID?
    @ViewState private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("用一句话调整", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
            HStack(alignment: .top, spacing: 8) {
                TextField("如：明天下午3点，提前10分钟提醒", text: $answer, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                Button("AI 补全") { model.refineDraft(draftID, instruction: answer) }.controlSize(.regular)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answer.count > 4000 || model.isGenerating)
            }
            HStack(spacing: 8) {
                ForEach(["明天", "下午3点", "只在开始时提醒"], id: \.self) { suggestion in
                    Button(suggestion) { answer += (answer.isEmpty ? "" : "，") + suggestion }.buttonStyle(SuggestionStyle())
                }
            }.font(.caption)
            Text("补充会发送给当前模型，修改后确认再添加。").font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .disabled(model.isGenerating)
    }
}

struct DraftEditor: View {
    @ViewState private var value: Draft
    @ViewState private var start: Date
    @ViewState private var end: Date
    @ViewState private var hasStart: Bool
    @ViewState private var hasEnd: Bool
    @ViewState private var repeatRule: String
    @ViewState private var hasRepeatEnd: Bool
    @ViewState private var repeatEnd: Date
    @ViewState private var message = ""
    let calendars: [CalendarChoice]
    let save: (Draft) -> Void
    let cancel: () -> Void
    init(draft: Draft, calendars: [CalendarChoice], save: @escaping (Draft) -> Void, cancel: @escaping () -> Void) {
        _value = State(initialValue: draft)
        let parsedStart = draft.event.startLocal.flatMap { try? Temporal.parse($0, timeZone: draft.event.timeZone, allDay: draft.event.allDay) }
        let parsedEnd = draft.event.endLocal.flatMap { try? Temporal.parse($0, timeZone: draft.event.timeZone, allDay: draft.event.allDay) }
        _start = State(initialValue: parsedStart ?? Date())
        _end = State(initialValue: parsedEnd ?? (parsedStart ?? Date()).addingTimeInterval(3600))
        _hasStart = State(initialValue: parsedStart != nil)
        _hasEnd = State(initialValue: draft.event.endLocal != nil)
        let recurrence = draft.event.recurrence
        _repeatRule = State(initialValue: recurrence?.rule.rawValue ?? "")
        _hasRepeatEnd = State(initialValue: recurrence?.until != nil)
        let until = recurrence?.until.flatMap { try? Temporal.parse($0, timeZone: draft.event.timeZone, allDay: true) }
        _repeatEnd = State(initialValue: until ?? (parsedStart ?? Date()).addingTimeInterval(90 * 86400))
        self.calendars = calendars; self.save = save; self.cancel = cancel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            TextField("日程标题", text: $value.event.title)
            Toggle("全天日程", isOn: $value.event.allDay).font(.caption)
                .onChange(of: value.event.allDay) { _, allDay in
                    if allDay {
                        hasEnd = true
                        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: value.event.timeZone) ?? .current
                        end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? end
                    }
                }
            Toggle("设置开始时间", isOn: $hasStart).font(.caption)
            if hasStart {
                DatePicker("开始", selection: $start, displayedComponents: value.event.allDay ? [.date] : [.date, .hourAndMinute])
            }
            if !value.event.allDay {
                Toggle("设置结束时间", isOn: $hasEnd).font(.caption)
                if !hasEnd { Text("仅设开始时间：保存为时间点提醒。日历中显示为 1 分钟，不占用忙碌时间。").font(.caption).foregroundStyle(.secondary) }
            }
            if value.event.allDay || hasEnd {
                DatePicker(value.event.allDay ? "结束日期（不包含）" : "结束", selection: $end, displayedComponents: value.event.allDay ? [.date] : [.date, .hourAndMinute])
            }
            HStack {
                Picker("重复", selection: $repeatRule) {
                    Text("不重复").tag("")
                    ForEach(Recurrence.Rule.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                if !repeatRule.isEmpty { Toggle("设置结束日期", isOn: $hasRepeatEnd).font(.caption) }
            }
            if !repeatRule.isEmpty {
                if hasRepeatEnd { DatePicker("重复到", selection: $repeatEnd, displayedComponents: [.date]) }
                if let days = value.event.repeatDays, !days.isEmpty, ["weekly", "biweekly"].contains(repeatRule) {
                    Text("按原文保留的星期：" + Recurrence(rule: .weekly, days: days).label.replacingOccurrences(of: "每周", with: "").replacingOccurrences(of: " · 不设结束", with: ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            TextField("时区，如 Asia/Shanghai", text: $value.event.timeZone)
            TextField("地点（选填）", text: $value.event.location)
            Picker("目标日历", selection: $value.calendarID) { Text("请选择").tag(""); ForEach(calendars) { Text($0.displayName).tag($0.id) } }
            HStack {
                Toggle("提醒", isOn: Binding(get: { value.event.reminderMinutes != nil }, set: { value.event.reminderMinutes = $0 ? (hasEnd ? 15 : 0) : nil }))
                if value.event.reminderMinutes != nil {
                    TextField("分钟", value: Binding(get: { value.event.reminderMinutes ?? 0 }, set: { value.event.reminderMinutes = $0 }), format: .number).frame(width: 65)
                    Text(value.event.allDay ? "全天提醒使用设置中的时间" : "分钟前（0 为开始时）").foregroundStyle(.secondary)
                }
            }.font(.caption)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消", action: cancel); Button("完成") { commit() }.buttonStyle(.borderedProminent) }
        }.textFieldStyle(.roundedBorder)
            .environment(\.timeZone, TimeZone(identifier: value.event.timeZone) ?? .current)
    }
    private func commit() {
        var next = value
        next.event.startLocal = hasStart ? Temporal.format(start, timeZone: value.event.timeZone, allDay: value.event.allDay) : nil
        next.event.endLocal = value.event.allDay || hasEnd ? Temporal.format(end, timeZone: value.event.timeZone, allDay: value.event.allDay) : nil
        next.event.repeatRule = repeatRule.isEmpty ? nil : repeatRule
        next.event.repeatCount = nil
        next.event.repeatUntil = repeatRule.isEmpty || !hasRepeatEnd ? nil
            : Temporal.format(repeatEnd, timeZone: value.event.timeZone, allDay: true)
        if repeatRule.isEmpty { next.event.repeatDays = nil }
        next.reviewed = true; next.event.missing = []
        next.conflicts = []; next.conflictAcknowledged = false
        let errors = DraftValidator.errors(next, requireCalendar: false)
        guard errors.isEmpty else { message = errors.joined(separator: "\n"); return }
        save(next)
    }
}

struct ReceiptView: View {
    @ObservedObject var model: AppModel
    @ViewState private var pendingUndo: OperationReceipt?
    private var items: [OperationReceipt] { model.stage == .history ? model.receipts : model.batchReceipts }
    private func canUndo(_ receipt: OperationReceipt) -> Bool {
        switch receipt.draft.intent {
        case .add: receipt.fingerprint != nil
        case .update: receipt.fingerprint != nil && receipt.previous != nil
        // A cancelled occurrence of a series cannot be put back from here.
        case .cancel: receipt.previous.map { !$0.partOfSeries } ?? false
        }
    }
    private func undoTitle(_ receipt: OperationReceipt) -> String {
        switch receipt.draft.intent {
        case .add: "撤销这项添加"
        case .update: "改回原来的时间"
        case .cancel: "恢复这条日程"
        }
    }
    private func undoPrompt(_ receipt: OperationReceipt) -> String {
        switch receipt.draft.intent {
        case .add: "撤销本应用添加的这项日程？"
        case .update: "把这条日程改回 \(receipt.previous?.when ?? "原来的时间")？"
        case .cancel: "恢复被取消的〈\(receipt.previous?.title ?? "日程")〉？"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty { ContentUnavailableView("暂无记录", systemImage: "clock", description: Text("确认添加后，结果会保存在这里。")) }
                    ForEach(items) { receipt in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: receipt.status == "saved" ? "checkmark.circle.fill" : receipt.status == "undone" ? "arrow.uturn.backward.circle" : "exclamationmark.circle").foregroundStyle(receipt.status == "saved" ? .green : .orange)
                                Text(receipt.draft.event.title).font(.system(size: 13, weight: .medium)); Spacer()
                                Text(receipt.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(receipt.message.isEmpty ? "上次操作被中断，需要核对结果。" : receipt.message).font(.caption).foregroundStyle(.secondary)
                            if receipt.status == "saved", canUndo(receipt) { Button(undoTitle(receipt)) { pendingUndo = receipt }.font(.caption) }
                            if ["prepared", "uncertain"].contains(receipt.status) { Button("核对写入结果") { model.reconcile(receipt) }.font(.caption) }
                            if receipt.status == "undoing" { Text("撤销结果不确定，请在系统日历核对；不会自动重试。").font(.caption).foregroundStyle(.orange) }
                        }.padding(15).appCard()
                    }
                }.padding(17)
            }
            Divider()
            HStack { Text("跨设备同步与提醒由系统日历完成").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("再记一件") { model.resetInput() }.buttonStyle(.borderedProminent) }.padding(13).background(AppStyle.surface)
        }
        .confirmationDialog(pendingUndo.map { undoPrompt($0) } ?? "撤销这次操作？",
                            isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } })) {
            Button(pendingUndo.map { undoTitle($0) } ?? "撤销", role: .destructive) { if let receipt = pendingUndo { model.undo(receipt) }; pendingUndo = nil }
            Button("取消", role: .cancel) { pendingUndo = nil }
        } message: { Text(pendingUndo?.draft.intent == .cancel
                          ? "会按取消前的内容重新建立一条日程；提醒和参与者等设置需要自行核对。"
                          : "仅处理仍与本应用留下的状态一致的日程；若之后被改动过，会停止撤销。") }
    }
}
