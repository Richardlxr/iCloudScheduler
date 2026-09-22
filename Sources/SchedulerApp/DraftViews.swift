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
                                    Text(draft.event.title).font(.system(size: 16, weight: .semibold))
                                    Label(displayTime(draft.event), systemImage: draft.event.startLocal == nil ? "clock.badge.questionmark" : "clock")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(draft.event.startLocal == nil ? Color.orange : Color.primary)
                                    HStack(spacing: 10) {
                                        if !draft.event.location.isEmpty { Label(draft.event.location, systemImage: "mappin.and.ellipse") }
                                        if draft.event.allDay { Label("全天提醒按设置", systemImage: "bell") }
                                        else if let reminder = draft.event.reminderMinutes { Label(reminder == 0 ? "开始时提醒" : "提前 \(reminder) 分钟", systemImage: "bell") }
                                        else { Text("不提醒") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                    Text(model.calendars.first { $0.id == draft.calendarID }?.displayName ?? "尚未选择日历").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("手动编辑") { model.editingID = draft.id; model.resizePanel?() }.buttonStyle(.borderless)
                            }
                            if !draft.conflicts.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label("时间冲突", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
                                    Text(draft.conflicts.joined(separator: "、")).font(.caption)
                                }.foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                            }
                            if draft.event.startLocal == nil && !model.isDemo {
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
                            if model.editingID == nil && !model.isDemo {
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
                    Label(model.selectedDrafts.count > 1 ? "删除 \(model.selectedDrafts.count) 项" : "删除", systemImage: "trash")
                        .frame(minWidth: 65)
                }.buttonStyle(.bordered).help("删除选中的待添加草稿，已有日历事件不受影响")
                    .disabled(model.writing || model.isGenerating || model.selectedDrafts.isEmpty)
                Spacer()
                Button(model.reviewActionTitle) { model.confirmAndWriteSelected() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.isDemo || model.writing || model.isGenerating || model.editingID != nil || model.selectedDrafts.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }.padding(14).background(AppStyle.surface)
        }
    }
    private func displayTime(_ event: ExtractedEvent) -> String {
        guard let start = event.startLocal else { return "需要补充开始时间" }
        if event.isPointReminder { return "\(start.prefix(10))  \(start.dropFirst(11).prefix(5)) · 时间点提醒" }
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

/// One tap sets a concrete reminder time on this machine; no model call and no extra cost.
struct QuickTimeRow: View {
    @ObservedObject var model: AppModel
    let draftID: UUID
    private let hints: [DueHint] = [.asap, .tonight, .tomorrow, .thisWeek]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("没有具体时间，先选一个提醒时机：").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ForEach(hints, id: \.self) { hint in
                    Button(hint.label) { model.applyQuickTime(hint, to: draftID) }
                        .buttonStyle(SuggestionStyle()).help("按“\(hint.label)”在本机换算成一个提醒时刻")
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
                            if receipt.status == "saved", receipt.fingerprint != nil { Button("撤销这项添加") { pendingUndo = receipt }.font(.caption) }
                            if ["prepared", "uncertain"].contains(receipt.status) { Button("核对写入结果") { model.reconcile(receipt) }.font(.caption) }
                            if receipt.status == "undoing" { Text("撤销结果不确定，请在系统日历核对；不会自动重试。").font(.caption).foregroundStyle(.orange) }
                        }.padding(15).appCard()
                    }
                }.padding(17)
            }
            Divider()
            HStack { Text("跨设备同步与提醒由系统日历完成").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("再记一件") { model.resetInput() }.buttonStyle(.borderedProminent) }.padding(13).background(AppStyle.surface)
        }
        .confirmationDialog("撤销本应用添加的这项日程？", isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } })) {
            Button("撤销添加", role: .destructive) { if let receipt = pendingUndo { model.undo(receipt) }; pendingUndo = nil }
            Button("取消", role: .cancel) { pendingUndo = nil }
        } message: { Text("仅删除仍与保存时一致的事件；若已被修改，会停止撤销。") }
    }
}
