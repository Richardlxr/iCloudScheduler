import AppKit
import Combine
import EventKit
import ServiceManagement
import SchedulerCore

enum CaptureStage { case input, analyzing, review, receipt, history }
enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "通用", models = "模型配置", calendar = "日历与提醒", privacy = "隐私与数据"
    var id: String { rawValue }
    var icon: String { switch self { case .general: "slider.horizontal.3"; case .models: "cpu"; case .calendar: "calendar"; case .privacy: "checkmark.shield" } }
}

@MainActor
final class AppModel: ObservableObject {
    typealias Extractor = (PreparedInput, ProviderConfig, String, Date, String, Int) async throws -> Extraction
    @Published var preferences = AppPreferences()
    @Published var text = ""
    @Published var attachments: [Attachment] = []
    @Published var drafts: [Draft] = []
    @Published var questions: [String] = []
    @Published var stage = CaptureStage.input
    @Published var errorMessage: String?
    @Published var statusMessage = ""
    @Published var calendars: [CalendarChoice] = []
    @Published var calendarAuthorized = false
    @Published var settingsPage = SettingsPage.models
    @Published var selectedPreset = "kimi"
    @Published var configDraft = ProviderConfig(preset: ProviderPreset.all[1])
    @Published var keyDraft = ""
    @Published var configMessage = ""
    @Published var testing = false
    @Published var availableModels: [String] = []
    @Published private var configuredProviderIDs: Set<String> = []
    @Published var writing = false
    @Published private(set) var isGenerating = false
    @Published var activityLabel = "准备就绪"
    @Published var receipts: [OperationReceipt] = []
    @Published var batchReceipts: [OperationReceipt] = []
    @Published var editingID: UUID?
    @Published var isDemo = false
    @Published var loginEnabled = false
    @Published var shortcutRecording = false
    @Published var shortcutError = ""
    var showSettings: (() -> Void)?
    var hidePanel: (() -> Void)?
    var resizePanel: (() -> Void)?
    var presentFailure: ((String, String) -> Void)?
    var panelIsVisible: () -> Bool = { true }
    var registerShortcut: ((UInt32, UInt32) -> Bool)?
    private var store: LocalStore?
    let calendar: any CalendarAccess
    private let readKey: (String) throws -> String
    private let extract: Extractor
    private let client = LLMClient()
    private var generation: Task<Void, Never>?
    private var revision = UUID()
    private var configRevision = UUID()
    private var configTask: Task<Void, Never>?
    private var storeObserver: NSObjectProtocol?
    let smokeMode: Bool

    init(directory: URL? = nil, calendar: (any CalendarAccess)? = nil,
         readKey: @escaping (String) throws -> String = { try KeychainStore.read(provider: $0) },
         extractor: Extractor? = nil, integrateSystem: Bool = true) {
        self.calendar = calendar ?? CalendarRepository(); self.readKey = readKey
        self.extract = extractor ?? { input, config, key, now, zone, reminder in
            try await LLMClient().extract(input: input, config: config, key: key, now: now, timeZone: zone, reminder: reminder)
        }
        smokeMode = !integrateSystem || CommandLine.arguments.contains("--ui-smoke")
        do {
            let local = try LocalStore(directory: directory); store = local
            preferences = try local.loadPreferences()
            try local.prune(); receipts = try local.receipts()
            if preferences.keepDraft, let saved = try local.loadDraft() {
                text = saved.text
                // Never restore a consumed draft: the journal is authoritative after a crash.
                let consumed = Set(receipts.map { $0.draft.id })
                drafts = saved.drafts.filter { !consumed.contains($0.id) }
                questions = saved.questions
                if !drafts.isEmpty { stage = .review }
            }
        } catch { errorMessage = error.localizedDescription; store = nil }
        selectedPreset = preferences.activeProvider
        configDraft = preferences.providers.first { $0.id == selectedPreset } ?? ProviderConfig(preset: ProviderPreset.all[1])
        if !smokeMode {
            configuredProviderIDs = Set(preferences.providers.filter { KeychainStore.contains(provider: $0.id) }.map(\.id))
        }
        if !smokeMode { refreshCalendars() }
        loginEnabled = !smokeMode && SMAppService.mainApp.status == .enabled
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendars(); self?.refreshConflicts() }
        }
    }
    var activeConfig: ProviderConfig { preferences.providers.first { $0.id == preferences.activeProvider } ?? configDraft }
    var configuredProviders: [ProviderConfig] {
        preferences.providers.filter { configuredProviderIDs.contains($0.id) && !$0.model.isEmpty && !$0.baseURL.isEmpty }
    }
    func activateProvider(_ id: String) {
        guard stage != .analyzing, !writing, configuredProviders.contains(where: { $0.id == id }) else { return }
        do {
            guard let store else { throw AppError("本机配置存储不可用。") }
            var updated = preferences; updated.activeProvider = id
            try store.savePreferences(updated); preferences = updated
        } catch { errorMessage = error.localizedDescription }
    }
    var canAnalyze: Bool { !writing && !isGenerating && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }
    var selectedDrafts: [Draft] { drafts.filter(\.selected) }
    var canWrite: Bool {
        !isDemo && !writing && editingID == nil && !selectedDrafts.isEmpty &&
        selectedDrafts.allSatisfy { DraftValidator.errors($0).isEmpty }
    }
    var reviewNeedsAcknowledgment: Bool {
        !questions.isEmpty || selectedDrafts.contains { !$0.conflicts.isEmpty || !DraftValidator.reviewNotes($0).isEmpty }
    }
    var reviewActionTitle: String {
        if writing { return "正在添加…" }
        if !calendar.hasAccess { return "允许日历访问" }
        if editingID != nil { return "请先完成编辑" }
        if selectedDrafts.contains(where: { !DraftValidator.errorsAfterReview($0).isEmpty }) { return "补全后添加" }
        if reviewNeedsAcknowledgment { return selectedDrafts.count == 1 ? "仍然添加" : "仍然添加 \(selectedDrafts.count) 项" }
        return selectedDrafts.count == 1 ? "添加到日历" : "添加 \(selectedDrafts.count) 项到日历"
    }
    func confirmAndWriteSelected() {
        guard !writing, editingID == nil, !selectedDrafts.isEmpty else { return }
        guard calendar.hasAccess else { authorizeCalendar(); return }
        if let incomplete = selectedDrafts.first(where: { !DraftValidator.errorsAfterReview($0).isEmpty }) {
            editingID = incomplete.id; resizePanel?()
            return
        }
        // Refresh before acknowledging. If the conflict changed since it was shown, display it first.
        let previous = selectedDrafts.map { $0.conflicts }
        refreshConflicts(notify: false)
        guard previous == selectedDrafts.map({ $0.conflicts }) else {
            reportFailure("冲突已变化", "请检查更新后的冲突，再选择仍然添加。"); return
        }
        for i in drafts.indices where drafts[i].selected {
            drafts[i].reviewed = true; drafts[i].conflictAcknowledged = true
        }
        writeSelected()
    }
    func deleteSelectedDrafts() {
        guard !writing else { return }
        drafts.removeAll(where: \.selected); editingID = nil
        if drafts.isEmpty { questions = []; errorMessage = nil; activityLabel = "已删除待添加日程"; setStage(.input) }
        else { resizePanel?() }
        persistDraft()
    }
    var reviewHeight: CGFloat {
        let cardHeight = drafts.reduce(CGFloat(0)) { height, draft in
            height + 150 + CGFloat(DraftValidator.reviewNotes(draft).joined().count / 46 + (DraftValidator.reviewNotes(draft).isEmpty ? 0 : 1)) * 20
                + CGFloat(draft.conflicts.isEmpty ? 0 : 52) + CGFloat(DraftValidator.errorsAfterReview(draft).isEmpty ? 0 : 45)
        }
        return min(660, max(320, 170 + cardHeight + (editingID == nil ? 0 : 330) + CGFloat(questions.isEmpty ? 0 : 50)))
    }
    func inputChanged() {
        generation?.cancel(); revision = UUID(); isGenerating = false; drafts = []; questions = []; isDemo = false
        if stage == .analyzing { stage = .input; resizePanel?() }
        persistDraft()
    }
    func persistPreferences() {
        do { guard let store else { throw AppError("存储不可用，设置未保存。") }; try store.savePreferences(preferences) }
        catch { errorMessage = error.localizedDescription }
        applyAppearance()
    }
    func persistDraft() {
        guard let store, !isDemo else { return }
        do {
            if preferences.keepDraft { try store.saveDraft(.init(text: text, drafts: drafts, questions: questions)) }
            else { try store.clearDraft() }
        } catch { errorMessage = "草稿保存失败：\(error.localizedDescription)" }
    }
    func applyAppearance() {
        NSApp.appearance = preferences.appearance == "light" ? NSAppearance(named: .aqua) : preferences.appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
    func setStage(_ newStage: CaptureStage) { if newStage == .input { editingID = nil }; stage = newStage; resizePanel?() }
    private func reportFailure(_ title: String, _ message: String) {
        errorMessage = stage == .review && ["发现日程冲突", "冲突已变化"].contains(title) ? nil : message; activityLabel = title
        presentFailure?(title, message)
    }
    func analyze() {
        guard canAnalyze else { return }
        guard store != nil else { reportFailure("无法开始生成", "请先解决本机存储错误。"); return }
        let config = activeConfig
        let key: String
        do { key = try readKey(config.id); guard !key.isEmpty else { throw AppError("先在设置中保存 API Key，再生成日程。") } }
        catch { reportFailure("无法开始生成", error.localizedDescription); return }
        if attachments.contains(where: { $0.kind == "image" || $0.kind == "pdf" }) && config.imageVerified == nil {
            reportFailure("无法开始生成", "当前配置的图片能力尚未验证。请在模型设置中运行“测试图片”，通过后可处理图片和 PDF。")
            return
        }
        generation?.cancel(); let token = UUID(); revision = token
        let inputText = text, files = attachments, now = Date(), zone = preferences.timeZone, reminder = preferences.reminderMinutes
        let targetCalendar = preferences.calendarID, background = preferences.runInBackground
        let automatic = background || !preferences.confirmBeforeAdding
        isGenerating = true; activityLabel = "正在生成日程…"
        errorMessage = nil; statusMessage = "正在准备输入…"; isDemo = false; setStage(.analyzing)
        generation = Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "完成用户提交的日程生成")
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                if revision == token { isGenerating = false }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) { try AttachmentProcessor.prepare(text: inputText, attachments: files) }
                let input = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard revision == token else { return }
                statusMessage = "\(config.name) 正在理解安排…"
                let result = try await extract(input, config, key, now, zone, reminder)
                try Task.checkCancellation(); guard revision == token else { return }
                drafts = result.events.map { Draft(event: $0, calendarID: targetCalendar) }
                questions = result.questions
                refreshConflicts(); persistDraft(); setStage(.review)
                guard !drafts.isEmpty else {
                    reportFailure("未生成可添加的日程", questions.isEmpty ? "没有识别到日程，请补充安排后重新提交。" : questions.joined(separator: "\n")); return
                }
                if drafts.contains(where: { !$0.conflicts.isEmpty }) {
                    reportFailure("发现日程冲突", "新日程与已有安排重叠。请在窗口中选择“仍然添加”或“删除”。")
                    return
                }
                if automatic && (background || !preferences.confirmBeforeAdding) {
                    guard DraftValidator.canAddAutomatically(drafts, questions: questions) else {
                        reportFailure("日程需要你处理", "时间、模型假设或冲突仍需核对，尚未自动添加。草稿已保留，请打开日程检查。"); return
                    }
                    writeSelected()
                } else {
                    activityLabel = "\(drafts.count) 项日程待确认"
                    if !panelIsVisible() { reportFailure("日程待确认", "已生成 \(drafts.count) 项日程，尚未添加。请检查后确认添加。") }
                }
            } catch {
                guard revision == token else { return }
                setStage(.input)
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    reportFailure("日程生成失败", error.localizedDescription + "\n输入已保留，没有自动重试。")
                } else { activityLabel = "已取消生成" }
            }
        }
        if preferences.runInBackground { hidePanel?() }
    }
    func cancelAnalysis() { generation?.cancel(); revision = UUID(); isGenerating = false; activityLabel = "已取消生成"; setStage(.input) }
    func addAttachments(_ urls: [URL]) {
        inputChanged()
        for url in urls {
            guard attachments.count < 5 else { errorMessage = "一次最多添加 5 个附件。"; break }
            do { attachments.append(try AttachmentProcessor.load(url: url)) }
            catch { errorMessage = error.localizedDescription }
        }
        resizePanel?()
    }
    func addPastedImage(_ data: Data) {
        guard attachments.count < 5, data.count <= 20 * 1024 * 1024 else { errorMessage = "图片超过 20 MB 或附件超过 5 个。"; return }
        inputChanged(); attachments.append(.init(name: "粘贴的图片", data: data, kind: "image")); resizePanel?()
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .pdf, .plainText]
        if panel.runModal() == .OK { addAttachments(panel.urls) }
    }
    func refreshCalendars() {
        calendarAuthorized = calendar.hasAccess
        calendars = calendar.calendars()
    }
    func authorizeCalendar() {
        Task {
            do { try await calendar.requestAccess(); refreshCalendars(); refreshConflicts() }
            catch { reportFailure("无法访问日历", error.localizedDescription) }
        }
    }
    func refreshConflicts(notify: Bool = true) {
        guard !writing else { return }
        var newConflict = false
        for i in drafts.indices {
            let old = drafts[i].conflicts
            let next = preferences.checkConflicts ? (try? calendar.conflicts(for: drafts[i])) ?? [] : []
            drafts[i].conflicts = next
            if old != next {
                drafts[i].conflictAcknowledged = false
                if drafts[i].selected && !next.isEmpty { newConflict = true }
            }
        }
        if notify && newConflict && stage == .review {
            reportFailure("发现日程冲突", "日历中的安排发生变化，请重新检查冲突后修改时间，或明确选择仍然添加。")
        }
    }
    func addManual() {
        isDemo = false; questions = []
        drafts.append(Draft(event: .init(timeZone: preferences.timeZone, reminderMinutes: preferences.reminderMinutes < 0 ? nil : preferences.reminderMinutes), calendarID: preferences.calendarID))
        editingID = drafts.last?.id; setStage(.review)
    }
    func showExample() {
        cancelAnalysis(); isDemo = true
        let zone = preferences.timeZone
        let start = Date().addingTimeInterval(2 * 86400)
        drafts = [.init(event: .init(title: "产品评审", startLocal: Temporal.format(start, timeZone: zone), endLocal: Temporal.format(start.addingTimeInterval(3600), timeZone: zone), timeZone: zone, location: "会议室 A301", source: "界面示例"), calendarID: "")]
        questions = []; setStage(.review)
    }
    func resetInput() {
        generation?.cancel(); revision = UUID(); isGenerating = false; activityLabel = "准备就绪"; text = ""; attachments = []; drafts = []; questions = []; editingID = nil
        batchReceipts = []; isDemo = false; errorMessage = nil; setStage(.input); persistDraft()
    }
    func writeSelected() {
        guard canWrite else { reportFailure("日程尚未添加", "请补全日程并核对时间与冲突后再添加。"); return }
        guard let store else { reportFailure("日程添加失败", "本机存储不可用，草稿仍保留在窗口中。"); return }
        guard calendar.hasAccess else { reportFailure("日程尚未添加", "请在设置中允许日历访问，并选择目标日历。草稿已保留。"); return }
        refreshConflicts(notify: false)
        guard canWrite else { reportFailure("发现日程冲突", "日历发生变化，请重新核对冲突。"); return }
        let batchID = UUID(), selected = selectedDrafts
        writing = true; batchReceipts = []; errorMessage = nil; activityLabel = "正在添加日程…"
        defer {
            writing = false; persistDraft(); setStage(.receipt)
            let saved = batchReceipts.filter { $0.status == "saved" }.count
            if errorMessage != nil || batchReceipts.contains(where: { $0.status != "saved" || $0.warning != nil }) || saved != selected.count {
                let detail = errorMessage ?? batchReceipts.compactMap(\.warning).first ?? batchReceipts.first(where: { $0.status != "saved" })?.message ?? "部分日程尚未完成。"
                reportFailure("日程添加未全部完成", "已确认添加 \(saved)/\(selected.count) 项。\n\(detail)\n请在结果或近期记录中核对，不会自动重试。")
            } else {
                activityLabel = "已添加 \(saved) 项日程"
                if panelIsVisible() { hidePanel?() }
            }
        }
        for draft in selected {
            if receipts.contains(where: { $0.draft.id == draft.id && !["failed", "undone"].contains($0.status) }) {
                errorMessage = "这条草稿已有写入记录，请在近期记录中核对。"; continue
            }
            var receipt = OperationReceipt(batchID: batchID, draft: draft)
            do { try store.record(receipt) }
            catch { errorMessage = error.localizedDescription; break }
            // A durable prepared record exists before calling EventKit. Unknown outcomes are never retried.
            do { receipt = try calendar.save(receipt, allDayReminder: preferences.allDayReminder) }
            catch { receipt.status = "uncertain"; receipt.message = "保存结果需核对：\(error.localizedDescription)" }
            do { try store.record(receipt) }
            catch { errorMessage = error.localizedDescription }
            receipts.insert(receipt, at: 0); batchReceipts.append(receipt)
            if let index = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[index].selected = false }
            if errorMessage != nil { break }
        }
    }
    func reconcile(_ receipt: OperationReceipt) {
        guard let store else { return }
        do { let updated = try calendar.reconcile(receipt); try store.record(updated); updateReceipt(updated) }
        catch { errorMessage = error.localizedDescription }
    }
    func undo(_ receipt: OperationReceipt) {
        guard let store else { return }
        do {
            var prepared = receipt; prepared.status = "undoing"; try store.record(prepared)
            do { let updated = try calendar.undo(receipt); try store.record(updated); updateReceipt(updated) }
            catch { prepared.message = "撤销未完成，请在系统日历核对：\(error.localizedDescription)"; try store.record(prepared); updateReceipt(prepared); throw error }
        } catch { errorMessage = error.localizedDescription }
    }
    private func updateReceipt(_ value: OperationReceipt) {
        if let i = receipts.firstIndex(where: { $0.id == value.id }) { receipts[i] = value }
        if let i = batchReceipts.firstIndex(where: { $0.id == value.id }) { batchReceipts[i] = value }
    }
    func selectProvider(_ id: String) {
        configTask?.cancel(); configRevision = UUID(); testing = false; selectedPreset = id
        configDraft = preferences.providers.first { $0.id == id } ?? .init(preset: ProviderPreset.all[1])
        keyDraft = ""; configMessage = ""; availableModels = []
        guard !smokeMode else { return }
        do { keyDraft = try KeychainStore.read(provider: id) } catch { configMessage = error.localizedDescription }
    }
    func configChanged() {
        configTask?.cancel(); configRevision = UUID(); testing = false
        configDraft.invalidate(); configMessage = "配置已修改，需要重新验证。"
    }
    func saveProvider() {
        do {
            guard let store else { throw AppError("本机配置存储不可用。") }
            _ = try Endpoint.url(base: configDraft.baseURL)
            guard !configDraft.model.isEmpty, !keyDraft.isEmpty else { throw AppError("请填写模型和 API Key。") }
            // Invalidate the persisted capability before replacing a credential, so a crash cannot preserve stale verification.
            var safe = preferences
            guard let i = safe.providers.firstIndex(where: { $0.id == configDraft.id }) else { throw AppError("未知服务商。") }
            safe.providers[i].invalidate(); try store.savePreferences(safe); preferences = safe
            try KeychainStore.save(keyDraft, provider: configDraft.id)
            safe.providers[i] = configDraft; safe.activeProvider = configDraft.id
            try store.savePreferences(safe); preferences = safe
            configuredProviderIDs.insert(configDraft.id)
            configMessage = "已保存并使用 \(configDraft.name)。"; errorMessage = nil
        } catch { configMessage = error.localizedDescription }
    }
    func probe(_ kind: String) {
        guard !testing else { return }
        configTask?.cancel(); let token = UUID(); configRevision = token
        let config = configDraft, key = keyDraft
        testing = true; configMessage = kind == "models" ? "正在读取模型列表…" : "正在验证真实内容…"
        configTask = Task {
            do {
                if kind == "text" { try await client.testText(config: config, key: key) }
                else if kind == "image" {
                    let code = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
                    let image = try AttachmentProcessor.probeImage(code: code)
                    try await client.testImage(config: config, key: key, jpeg: image, expected: code)
                } else { availableModels = try await client.models(config: config, key: key) }
                guard configRevision == token else { return }
                if kind == "text" { configDraft.textVerified = Date() }
                if kind == "image" { configDraft.imageVerified = Date() }
                configMessage = kind == "models" ? "已读取模型列表，选择或手动输入均可。" : "验证通过。保存配置后生效。"
            } catch {
                guard configRevision == token else { return }
                configMessage = error.localizedDescription
                if kind == "text" { configDraft.textVerified = nil }; if kind == "image" { configDraft.imageVerified = nil }
            }
            if configRevision == token { testing = false }
        }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled }
        catch { errorMessage = "登录启动未更新：\(error.localizedDescription)"; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}
