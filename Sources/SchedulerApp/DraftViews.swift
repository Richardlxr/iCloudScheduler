import SwiftUI
import SchedulerCore

struct DraftReviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("\(model.drafts.count) 项安排"); Spacer(); Text(model.preferences.timeZone) }.font(.caption).foregroundStyle(.secondary)
                    if !model.questions.isEmpty {
                        Text(model.questions.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if model.drafts.isEmpty { ContentUnavailableView("没有可添加的日程", systemImage: "calendar.badge.questionmark", description: Text("返回输入，补充具体安排。")) }
                    ForEach($model.drafts) { $draft in
                        VStack(alignment: .leading, spacing: 11) {
                            HStack(alignment: .top, spacing: 10) {
                                if model.drafts.count > 1 || !draft.selected { Toggle("选择 \(draft.event.title)", isOn: $draft.selected).labelsHidden().toggleStyle(.checkbox) }
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(draft.event.title).font(.system(size: 16, weight: .semibold))
                                    Text(displayTime(draft.event)).font(.system(size: 13, weight: .medium))
                                    HStack(spacing: 10) {
                                        if !draft.event.location.isEmpty { Label(draft.event.location, systemImage: "mappin.and.ellipse") }
                                        if draft.event.allDay { Label("全天提醒按设置", systemImage: "bell") }
                                        else if let reminder = draft.event.reminderMinutes { Label("提前 \(reminder) 分钟", systemImage: "bell") }
                                        else { Text("不提醒") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                    Text(model.calendars.first { $0.id == draft.calendarID }?.displayName ?? "尚未选择日历").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("编辑") { model.editingID = draft.id; model.resizePanel?() }.buttonStyle(.borderless)
                            }
                            if !draft.conflicts.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label("时间冲突", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
                                    Text(draft.conflicts.joined(separator: "、")).font(.caption)
                                }.foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                            }
                            let notes = DraftValidator.reviewNotes(draft)
                            if !notes.isEmpty {
                                Text(notes.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            let errors = DraftValidator.errorsAfterReview(draft)
                            if !errors.isEmpty {
                                Text(errors.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                            }
                            if model.editingID == draft.id {
                                Divider()
                                DraftEditor(draft: draft, calendars: model.calendars, save: { value in
                                    if let i = model.drafts.firstIndex(where: { $0.id == value.id }) { model.drafts[i] = value }
                                    model.editingID = nil; model.refreshConflicts(); model.persistDraft(); model.resizePanel?()
                                }, cancel: { model.editingID = nil; model.resizePanel?() })
                            }
                        }.padding(15).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(draft.conflicts.isEmpty ? Color.gray.opacity(0.18) : Color.orange.opacity(0.35)))
                    }
                    if !model.calendarAuthorized && !model.isDemo {
                        Button("允许日历访问") { model.authorizeCalendar() }.font(.caption)
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
                    .disabled(model.writing || model.selectedDrafts.isEmpty)
                Spacer()
                Button(model.reviewActionTitle) { model.confirmAndWriteSelected() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.isDemo || model.writing || model.editingID != nil || model.selectedDrafts.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }.padding(14)
        }
    }
    private func displayTime(_ event: ExtractedEvent) -> String {
        guard let start = event.startLocal, let end = event.endLocal else { return "需要补充时间" }
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

struct DraftEditor: View {
    @ViewState private var value: Draft
    @ViewState private var startDay: String
    @ViewState private var startClock: String
    @ViewState private var endDay: String
    @ViewState private var endClock: String
    @ViewState private var message = ""
    let calendars: [CalendarChoice]
    let save: (Draft) -> Void
    let cancel: () -> Void
    init(draft: Draft, calendars: [CalendarChoice], save: @escaping (Draft) -> Void, cancel: @escaping () -> Void) {
        _value = State(initialValue: draft)
        _startDay = State(initialValue: String((draft.event.startLocal ?? "").prefix(10)))
        _endDay = State(initialValue: String((draft.event.endLocal ?? "").prefix(10)))
        _startClock = State(initialValue: String((draft.event.startLocal ?? "").dropFirst(11).prefix(5)))
        _endClock = State(initialValue: String((draft.event.endLocal ?? "").dropFirst(11).prefix(5)))
        self.calendars = calendars; self.save = save; self.cancel = cancel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            field("标题") { TextField("日程标题", text: $value.event.title) }
            Toggle("全天日程", isOn: $value.event.allDay).font(.caption)
            HStack {
                field("开始日期") { TextField("YYYY-MM-DD", text: $startDay) }
                if !value.event.allDay { field("开始时间") { TextField("HH:mm", text: $startClock) } }
            }
            HStack {
                field(value.event.allDay ? "结束日期（不包含）" : "结束日期") { TextField("YYYY-MM-DD", text: $endDay) }
                if !value.event.allDay { field("结束时间") { TextField("HH:mm", text: $endClock) } }
            }
            field("时区") { TextField("Asia/Shanghai", text: $value.event.timeZone) }
            field("地点") { TextField("添加地点", text: $value.event.location) }
            Picker("目标日历", selection: $value.calendarID) { Text("请选择").tag(""); ForEach(calendars) { Text($0.displayName).tag($0.id) } }
            HStack {
                Toggle("提醒", isOn: Binding(get: { value.event.reminderMinutes != nil }, set: { value.event.reminderMinutes = $0 ? 15 : nil }))
                if value.event.reminderMinutes != nil {
                    TextField("分钟", value: Binding(get: { value.event.reminderMinutes ?? 15 }, set: { value.event.reminderMinutes = $0 }), format: .number).frame(width: 65)
                    Text(value.event.allDay ? "全天提醒使用设置中的时间" : "分钟前").foregroundStyle(.secondary)
                }
            }.font(.caption)
            if !value.event.source.isEmpty { Text("来源：\(value.event.source)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
            if !value.event.assumptions.isEmpty { Text(value.event.assumptions.joined(separator: "\n")).font(.caption).foregroundStyle(.orange) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消", action: cancel); Button("完成") { commit() }.buttonStyle(.borderedProminent) }
        }.textFieldStyle(.roundedBorder)
    }
    private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
    private func commit() {
        var next = value
        next.event.startLocal = value.event.allDay ? startDay : startDay + "T" + startClock + ":00"
        next.event.endLocal = value.event.allDay ? endDay : endDay + "T" + endClock + ":00"
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
                        }.padding(13).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(17)
            }
            Divider()
            HStack { Text("跨设备同步与提醒由系统日历完成").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("再记一件") { model.resetInput() }.buttonStyle(.borderedProminent) }.padding(13)
        }
        .confirmationDialog("撤销本应用添加的这项日程？", isPresented: Binding(get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } })) {
            Button("撤销添加", role: .destructive) { if let receipt = pendingUndo { model.undo(receipt) }; pendingUndo = nil }
            Button("取消", role: .cancel) { pendingUndo = nil }
        } message: { Text("仅删除仍与保存时一致的事件；若已被修改，会停止撤销。") }
    }
}
