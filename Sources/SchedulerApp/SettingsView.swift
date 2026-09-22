import SwiftUI
import AppKit
import SchedulerCore

struct AppSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("设置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold)).padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 17)
                ForEach(SettingsPage.allCases) { page in
                    Button { model.settingsPage = page } label: {
                        Label(page.rawValue, systemImage: page.icon)
                            .font(.system(size: 13, weight: model.settingsPage == page ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .padding(.horizontal, 9)
                            .background(model.settingsPage == page ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            // Plain buttons must include the padded row, not only the label glyphs.
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(model.settingsPage == page ? Color.accentColor : .primary)
                }
                Spacer()
                Text("iCloudScheduler\n\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")").font(.system(size: 10)).foregroundStyle(.secondary).padding(9)
            }.padding(12).frame(width: 164).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if Bundle.main.bundleIdentifier == "dev.icloudscheduler.update-test" {
                        Text("更新隔离测试 · 不读取正式配置或日历").foregroundStyle(.orange).font(.headline)
                    }
                    Text(model.settingsPage.rawValue).font(.system(size: 21, weight: .semibold))
                    if let message = model.errorMessage { Notice(message: message, dismiss: { model.errorMessage = nil }) }
                    switch model.settingsPage {
                    case .models: ModelSettingsView(model: model).onAppear { model.selectProvider(model.selectedPreset) }
                    case .calendar: CalendarSettingsView(model: model)
                    case .general: GeneralSettingsView(model: model)
                    case .privacy: privacy
                    case .updates: UpdateSettingsView(updater: updater)
                    }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 710, idealWidth: 740, maxWidth: .infinity, minHeight: 550, idealHeight: 630, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .groupBoxStyle(SettingsCardStyle())
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("清楚了解哪些内容会离开这台 Mac。").font(.callout).foregroundStyle(.secondary)
            privacyRow("发送给所选模型", "本次输入的文字、图片与选定的 PDF 页面。PDF 在本机转为图片，不运行本地 OCR。", "paperplane")
            privacyRow("已有日程留在本机", "获得授权后，在本机检查时间冲突，不向模型发送日历标题。", "calendar")
            privacyRow("密钥保存在钥匙串", "配置文件和日志不包含 API Key。模型服务的保存政策由对应服务商决定。", "key")
            GroupBox("本机记录") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("保留未完成的文字与日程草稿", isOn: $model.preferences.keepDraft)
                        .onChange(of: model.preferences.keepDraft) { _, _ in model.persistPreferences(); model.persistDraft() }
                    Text("草稿只恢复最近 7 天内容；附件仅保留到本次应用退出。回执保留 30 天，未查明的操作继续保留。").font(.caption).foregroundStyle(.secondary)
                    Text("文件位于本机 Application Support/iCloudScheduler；不额外加密，系统磁盘保护由 macOS 管理。").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
        }
    }
    private func privacyRow(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) { Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20); VStack(alignment: .leading, spacing: 4) { Text(title).font(.callout); Text(detail).font(.caption).foregroundStyle(.secondary) } }
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var showKey = false
    @ViewState private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择服务商，填写开发者 API Key。预设需要用你的账户验证。").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(ProviderPreset.all.filter { $0.id != "custom" }) { preset in
                    Button { model.selectProvider(preset.id) } label: {
                        HStack { Text(String(preset.name.prefix(1))).font(.system(size: 12, weight: .semibold)).frame(width: 23, height: 23).background(.quaternary, in: RoundedRectangle(cornerRadius: 5)); Text(preset.name).font(.system(size: 12)); Spacer(minLength: 0) }
                            .padding(8).background(model.selectedPreset == preset.id ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selectedPreset == preset.id ? Color.accentColor : Color.secondary.opacity(0.2)))
                    }.buttonStyle(.plain)
                }
            }
            HStack { Spacer(); Button("＋ 自定义兼容服务") { model.selectProvider("custom"); advanced = true }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption) }
            Divider()
            HStack { Text(model.configDraft.name).fontWeight(.medium); Spacer(); if model.preferences.activeProvider == model.selectedPreset { Text("当前使用").font(.caption).foregroundStyle(.secondary) } }
            VStack(alignment: .leading, spacing: 6) {
                Text("API Key").font(.caption)
                HStack {
                    if showKey { TextField("粘贴 API Key", text: keyBinding) }
                    else { SecureField("粘贴 API Key", text: keyBinding) }
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }.buttonStyle(.plain).help(showKey ? "隐藏密钥" : "显示密钥")
                }
                Text("点击“保存并使用”后，密钥才写入 macOS 钥匙串。").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("模型 ID").font(.caption)
                HStack {
                    TextField("输入模型 ID", text: configBinding(\.model))
                    Button("获取列表") { model.probe("models") }.disabled(model.testing || model.keyDraft.isEmpty)
                }
                if !model.availableModels.isEmpty {
                    Picker("已获取模型", selection: configBinding(\.model)) { ForEach(model.availableModels, id: \.self) { Text($0).tag($0) } }
                }
            }
            DisclosureGroup("连接地址与高级选项", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Base URL", text: configBinding(\.baseURL))
                    if let url = try? Endpoint.url(base: model.configDraft.baseURL) { Text("请求地址：\(url.absoluteString)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                    Picker("请求超时", selection: Binding(get: { model.configDraft.timeout }, set: { model.configDraft.timeout = $0; model.configChanged() })) {
                        Text("45 秒").tag(45.0); Text("60 秒").tag(60.0); Text("90 秒").tag(90.0); Text("180 秒").tag(180.0)
                    }
                }.padding(.top, 10)
            }.font(.caption)
            if model.selectedPreset == "qwen" { Text("此预设使用北京地域。请使用同地域 API Key，也可填写业务空间专属地址。").font(.caption2).foregroundStyle(.secondary) }
            HStack(spacing: 18) {
                capability("文本日程", date: model.configDraft.textVerified)
                capability("图片", date: model.configDraft.imageVerified)
                Text("PDF：转图后识别").font(.caption2).foregroundStyle(.secondary)
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            if !model.configMessage.isEmpty { Text(model.configMessage).font(.caption).textSelection(.enabled) }
            HStack {
                Button("测试文本") { model.probe("text") }.disabled(model.testing || model.keyDraft.isEmpty)
                Button("测试图片") { model.probe("image") }.disabled(model.testing || model.keyDraft.isEmpty)
                if model.testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("保存并使用") { model.saveProvider() }.buttonStyle(.borderedProminent).disabled(model.testing || model.keyDraft.isEmpty || model.configDraft.model.isEmpty)
            }
            Text("每项测试会向当前服务发送合成样本，产生少量 API 费用；不会发送你的输入或日历。").font(.caption2).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
    private var keyBinding: Binding<String> { Binding(get: { model.keyDraft }, set: { model.keyDraft = $0; model.configChanged() }) }
    private func configBinding(_ keyPath: WritableKeyPath<ProviderConfig, String>) -> Binding<String> {
        Binding(get: { model.configDraft[keyPath: keyPath] }, set: { model.configDraft[keyPath: keyPath] = $0; model.configChanged() })
    }
    private func capability(_ name: String, date: Date?) -> some View {
        Label(date == nil ? "\(name) · 未验证" : "\(name) · 已验证", systemImage: date == nil ? "circle.dotted" : "checkmark.circle.fill")
            .font(.caption2).foregroundStyle(date == nil ? Color.secondary : .green)
            .help(date.map { "验证于 \($0.formatted())" } ?? "需要验证当前模型和密钥")
    }
}

struct CalendarSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选择系统日历中的 iCloud 账户及目标日历。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Image(systemName: model.calendarAuthorized ? "checkmark.circle.fill" : "calendar.badge.exclamationmark").foregroundStyle(model.calendarAuthorized ? .green : .orange)
                Text(model.calendarAuthorized ? "已允许日历访问" : "尚未允许日历访问")
                Spacer()
                Button(model.calendarAuthorized ? "刷新" : "允许访问") { if model.calendarAuthorized { model.calendar.refresh(); model.refreshCalendars() } else { model.authorizeCalendar() } }
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
            if !model.calendarAuthorized {
                Text("需要完整访问来选择日历、检查冲突和核对写入。没有权限时仍可生成、编辑草稿。").font(.caption).foregroundStyle(.secondary)
                Button("打开系统日历权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }.font(.caption)
            }
            GroupBox("日历") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("默认日历", selection: $model.preferences.calendarID) { Text("请选择日历").tag(""); ForEach(model.calendars) { Text($0.displayName).tag($0.id) } }
                    if model.calendarAuthorized && model.calendars.isEmpty { Text("没有可写日历。请在系统设置中启用 iCloud 日历，或在日历 App 中建立日历。").font(.caption).foregroundStyle(.secondary) }
                    Toggle("添加前确认", isOn: $model.preferences.confirmBeforeAdding)
                        .onChange(of: model.preferences.confirmBeforeAdding) { _, _ in model.persistPreferences() }
                        .disabled(model.preferences.runInBackground)
                    if model.preferences.runInBackground { Text("后台运行会直接添加，冲突或未完成时弹窗。").font(.caption2).foregroundStyle(.secondary) }
                    Text("关闭后，信息完整的日程自动添加；缺失信息、冲突或失败会弹窗提示。").font(.caption2).foregroundStyle(.secondary)
                    Toggle("添加前检查时间冲突", isOn: $model.preferences.checkConflicts)
                }.padding(8)
            }
            GroupBox("待办与提醒事项") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("把待办写入提醒事项", isOn: $model.preferences.sendTasksToReminders)
                        .onChange(of: model.preferences.sendTasksToReminders) { _, _ in model.persistPreferences() }
                    Text("办理、缴费、交材料这类待办完成前不该消失。写入提醒事项后可以勾掉、顺延；会议、上课等约定仍然写入日历。").font(.caption2).foregroundStyle(.secondary)
                    if model.preferences.sendTasksToReminders {
                        HStack {
                            Image(systemName: model.remindersAuthorized ? "checkmark.circle.fill" : "checklist.unchecked")
                                .foregroundStyle(model.remindersAuthorized ? .green : .orange)
                            Text(model.remindersAuthorized ? "已允许提醒事项访问" : "尚未允许提醒事项访问")
                            Spacer()
                            Button(model.remindersAuthorized ? "刷新" : "允许访问") {
                                if model.remindersAuthorized { model.refreshCalendars() } else { model.authorizeReminders() }
                            }
                        }
                        Picker("提醒事项清单", selection: Binding(get: { model.preferences.reminderListID ?? "" },
                                                            set: { model.preferences.reminderListID = $0 })) {
                            Text("请选择清单").tag("")
                            ForEach(model.reminderLists) { Text($0.displayName).tag($0.id) }
                        }.disabled(!model.remindersAuthorized)
                        if !model.remindersDestinationReady {
                            Text("未授权或未选择清单时，待办继续写入日历，不会丢失。").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.padding(8)
            }
            GroupBox("默认提醒") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("定时日程提前"); TextField("分钟", value: $model.preferences.reminderMinutes, format: .number).frame(width: 65); Text("分钟").foregroundStyle(.secondary) }
                    Text("0 表示开始时提醒，-1 表示不提醒；最多提前 7 天。").font(.caption2).foregroundStyle(.secondary)
                    Toggle("全天日程提醒", isOn: $model.preferences.allDayReminder.enabled)
                    if model.preferences.allDayReminder.enabled {
                        HStack {
                            Picker("日期", selection: $model.preferences.allDayReminder.daysBefore) {
                                Text("当天").tag(0)
                                ForEach(1...7, id: \.self) { Text("提前 \($0) 天").tag($0) }
                            }
                            Picker("时", selection: $model.preferences.allDayReminder.hour) {
                                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                            }.frame(width: 85)
                            Picker("分", selection: $model.preferences.allDayReminder.minute) {
                                ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                            }.frame(width: 85)
                        }
                    }
                    Text("原文明确指定的定时提醒优先，也可以在日程确认时修改。全天提醒使用本页设置。").font(.caption2).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("时间") {
                TextField("IANA 时区", text: $model.preferences.timeZone).padding(8)
            }
            Button("保存日历设置") {
                guard (-1...10080).contains(model.preferences.reminderMinutes), model.preferences.allDayReminder.isValid, TimeZone(identifier: model.preferences.timeZone) != nil else { model.errorMessage = "请检查提醒范围、自定义全天时刻与 IANA 时区。"; return }
                model.persistPreferences()
                for i in model.drafts.indices where model.drafts[i].calendarID.isEmpty { model.drafts[i].calendarID = model.preferences.calendarID }
                model.refreshConflicts(); model.persistDraft()
            }.buttonStyle(.borderedProminent)
            Text("提醒由系统日历发送，受通知设置、专注模式和 iCloud 同步影响。").font(.caption2).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("随手记下安排，然后回到手头的事。").font(.callout).foregroundStyle(.secondary)
            GroupBox("快捷输入") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("呼出窗口"); Spacer(); ShortcutRecorder(model: model).frame(width: 145, height: 29) }
                    Picker("提交快捷键", selection: $model.preferences.enterSubmits) {
                        Text("⌘ Enter").tag(false); Text("Enter").tag(true)
                    }.onChange(of: model.preferences.enterSubmits) { _, _ in model.persistPreferences() }
                    Toggle("提交后后台运行", isOn: $model.preferences.runInBackground)
                        .onChange(of: model.preferences.runInBackground) { _, _ in model.persistPreferences() }
                    if !model.shortcutError.isEmpty { Text(model.shortcutError).font(.caption).foregroundStyle(.orange) }
                }.padding(8)
            }
            GroupBox("启动") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    Text("登录后静默运行；点击应用或按快捷键打开窗口。").font(.caption).foregroundStyle(.secondary)
                    Toggle("显示菜单栏图标", isOn: $model.preferences.showMenuBar)
                        .onChange(of: model.preferences.showMenuBar) { _, _ in model.persistPreferences() }
                    Toggle("保留未完成的输入", isOn: $model.preferences.keepDraft)
                        .onChange(of: model.preferences.keepDraft) { _, _ in model.persistPreferences(); model.persistDraft() }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("外观") {
                Picker("主题", selection: $model.preferences.appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }.padding(8).onChange(of: model.preferences.appearance) { _, _ in model.persistPreferences() }
            }
            Text("快捷键如已被其他应用占用，会保留原快捷键并提示。隐藏菜单栏图标后，仍可按快捷键或从 Finder 打开应用；⌘ , 打开设置，⌘ Q 退出。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
