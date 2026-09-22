import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SchedulerCore

// Explicit alias keeps the property wrapper unambiguous with newer SDK State macros.
typealias ViewState<Value> = SwiftUI.State<Value>

struct CaptureView: View {
    @ObservedObject var model: AppModel
    @ViewState private var editorFocused = false
    @ViewState private var composing = false
    @ViewState private var editorDropTarget = false
    @ViewState private var windowDropTarget = false
    private var dropTarget: Bool { editorDropTarget || windowDropTarget }
    var body: some View {
        VStack(spacing: 0) {
            header
            if CommandLine.arguments.contains("--review-fixture") || Bundle.main.bundleIdentifier == "dev.icloudscheduler.update-test" {
                Text("隔离测试 · 不会写入真实日历").font(.headline).foregroundStyle(.orange).padding(10)
            }
            if let message = model.errorMessage { Notice(message: message, dismiss: { model.errorMessage = nil }).padding(.horizontal, 16).padding(.bottom, 8) }
            switch model.stage {
            case .input: input
            case .analyzing: progress
            case .review: DraftReviewView(model: model)
            case .receipt, .history: ReceiptView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.text) { _, _ in model.inputChanged() }
        .onDrop(of: [.fileURL], isTargeted: $windowDropTarget) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.addAttachments([url]) }
                }
            }
            return !providers.isEmpty
        }
    }
    private var title: String {
        switch model.stage { case .input: "新建日程"; case .analyzing: "识别日程"; case .review: "确认日程"; case .receipt: "添加结果"; case .history: "近期记录" }
    }
    private var header: some View {
        HStack(spacing: 9) {
            if model.stage == .review || model.stage == .history || model.stage == .receipt {
                Button { model.setStage(.input) } label: { Image(systemName: "arrow.left") }.buttonStyle(ToolbarIconStyle()).help("返回输入").accessibilityLabel("返回输入").disabled(model.isGenerating)
            } else { Image(systemName: "calendar.badge.plus").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9)) }
            Text(title).font(.system(size: 14, weight: .semibold))
            if model.isDemo { Text("界面示例").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            Button { model.setStage(.history) } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(ToolbarIconStyle()).help("近期记录").accessibilityLabel("近期记录").disabled(model.isGenerating)
            Button { model.showSettings?() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(ToolbarIconStyle()).help("设置 ⌘,").accessibilityLabel("设置")
            Button { model.persistDraft(); model.hidePanel?() } label: { Image(systemName: "xmark") }.buttonStyle(ToolbarIconStyle()).help("收起 Esc").accessibilityLabel("收起窗口")
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    private var input: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 9) {
                        TextInput(text: $model.text, enterSubmits: model.preferences.enterSubmits,
                                  commit: { model.analyze() }, hide: { model.persistDraft(); model.hidePanel?() },
                                  imagePaste: model.addPastedImage, dropFiles: { model.addAttachments($0) },
                                  focusChanged: { editorFocused = $0 }, dropTargeted: { editorDropTarget = $0 },
                                  composingChanged: { composing = $0 })
                            .frame(height: 122)
                            .overlay(alignment: .topLeading) {
                                // Characters an input method is still composing never reach the binding,
                                // so the text view reports them separately.
                                if model.text.isEmpty && !composing {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("有什么安排？").font(.system(size: 16))
                                        Text("粘贴群消息，或拖入截图、PDF。").font(.system(size: 13)).foregroundStyle(.tertiary)
                                    }.foregroundStyle(.placeholder)
                                        .padding(.top, 7).padding(.leading, 5).allowsHitTesting(false)
                                }
                            }
                        Divider().opacity(0.6)
                        HStack(spacing: 10) {
                            Button { model.chooseFiles() } label: { Label("附件", systemImage: "paperclip") }
                                .buttonStyle(.borderless).help("添加图片、PDF 或文本文件")
                            if !model.attachments.isEmpty {
                                Text("\(model.attachments.count)/5").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.preferences.enterSubmits ? "↵ 生成 · ⇧↵ 换行" : "⌘↵ 生成 · ↵ 换行").foregroundStyle(.secondary)
                        }.font(.caption)
                    }.padding(13)
                        .appCard(border: dropTarget ? Color.accentColor : editorFocused ? Color.accentColor.opacity(0.55) : AppStyle.border,
                                 radius: 12, lineWidth: dropTarget || editorFocused ? 1.2 : 0.5)
                        .overlay {
                            if dropTarget {
                                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06))
                                    .overlay { Label("松开以添加附件", systemImage: "arrow.down.doc").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor) }
                                    .allowsHitTesting(false)
                            }
                        }
                    ForEach($model.attachments) { $attachment in
                        AttachmentCard(attachment: $attachment, visionReady: model.activeConfig.imageVerified != nil,
                                       remove: { model.attachments.removeAll { $0.id == attachment.id }; model.inputChanged(); model.resizePanel?() },
                                       changed: { model.inputChanged() })
                    }
                }.padding(.horizontal, 16).padding(.bottom, 14)
            }
            Divider()
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.configuredProviders) { provider in
                        Button { model.activateProvider(provider.id) } label: {
                            if provider.id == model.preferences.activeProvider {
                                Label(provider.name, systemImage: "checkmark")
                            } else { Text(provider.name) }
                        }
                    }
                    if !model.configuredProviders.isEmpty { Divider() }
                    Button("管理模型配置…") { model.settingsPage = .models; model.showSettings?() }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(model.activeConfig.textVerified == nil ? Color.secondary : .green).frame(width: 5, height: 5)
                        Text(model.configuredProviders.isEmpty ? "配置模型" : model.activeConfig.name)
                    }
                }.menuStyle(.borderlessButton).fixedSize().help("切换已配置的服务商")
                Picker("日历", selection: $model.preferences.calendarID) {
                    Text("选择日历…").tag("")
                    ForEach(model.calendars) { Text($0.displayName).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 160)
                .onChange(of: model.preferences.calendarID) { _, _ in model.persistPreferences() }
                Spacer(minLength: 0)
                Button(model.preferences.enterSubmits ? "生成日程 ↵" : "生成日程 ⌘↵") { model.analyze() }.buttonStyle(.borderedProminent).disabled(!model.canAnalyze)
            }.font(.caption).controlSize(.regular).padding(.horizontal, 16).padding(.vertical, 13).background(AppStyle.surface)
        }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack { ProgressView().controlSize(.small); Text(model.statusMessage).font(.callout) }
            Text(model.preferences.confirmBeforeAdding && !model.preferences.runInBackground ? "生成后由你确认，收起窗口仍会继续。" : "信息完整时自动添加，未完成时弹窗提示。") .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消分析") { model.cancelAnalysis() } }
        }.padding(24).frame(maxHeight: .infinity, alignment: .top)
    }
}

struct AttachmentCard: View {
    @Binding var attachment: Attachment
    let visionReady: Bool
    let remove: () -> Void
    let changed: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(attachment.label).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("移除附件").accessibilityLabel("移除 \(attachment.name)")
            }
            if attachment.kind == "pdf" {
                HStack(spacing: 6) {
                    Text("发送第").font(.caption)
                    TextField("起始", value: $attachment.firstPage, format: .number).frame(width: 40)
                    Text("–").font(.caption)
                    TextField("结束", value: $attachment.lastPage, format: .number).frame(width: 40)
                    Text("页，共 \(attachment.pageCount) 页").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if attachment.hasTextLayer {
                        Picker("发送方式", selection: $attachment.sendAsText) {
                            Text("按文本").tag(true)
                            Text("按图片").tag(false)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 124).controlSize(.small)
                            .help("这份 PDF 含可提取文字：按文本发送更准确，也不需要图片能力")
                    }
                }.textFieldStyle(.roundedBorder).onChange(of: attachment.firstPage) { _, _ in changed() }
                    .onChange(of: attachment.lastPage) { _, _ in changed() }
                    .onChange(of: attachment.sendAsText) { _, _ in changed() }
            }
            if attachment.requiresVision && !visionReady {
                Text("需要先在模型设置中通过“测试图片”，才能发送图片页。").font(.caption2).foregroundStyle(.orange)
            }
        }.padding(11).appCard(radius: 10)
    }
    private var thumbnail: some View {
        Group {
            if let preview = attachment.preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: attachment.kind == "pdf" ? "doc.richtext" : "doc.plaintext")
                    .font(.system(size: 15)).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.09))
            }
        }.frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AppStyle.border, lineWidth: 0.5))
    }
}

struct Notice: View {
    let message: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }.padding(12).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TextInput: NSViewRepresentable {
    @Binding var text: String
    var enterSubmits: Bool
    var commit: () -> Void
    var hide: () -> Void
    var imagePaste: (Data) -> Void
    var dropFiles: ([URL]) -> Void
    var focusChanged: (Bool) -> Void
    var dropTargeted: (Bool) -> Void
    var composingChanged: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        let input = CaptureTextView(); input.isRichText = false; input.drawsBackground = false
        input.font = .systemFont(ofSize: 16); input.textColor = .labelColor
        input.isAutomaticQuoteSubstitutionEnabled = false; input.isAutomaticDashSubstitutionEnabled = false
        input.textContainerInset = NSSize(width: 0, height: 7)
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.delegate = context.coordinator
        apply(to: input)
        input.setAccessibilityLabel("日程内容")
        scroll.documentView = input
        DispatchQueue.main.async { input.window?.makeFirstResponder(input) }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = view.documentView as? CaptureTextView else { return }
        if input.string != text && !input.hasMarkedText() { input.string = text }
        apply(to: input)
    }
    private func apply(to input: CaptureTextView) {
        input.commit = commit; input.hide = hide; input.imagePaste = imagePaste; input.dropFiles = dropFiles
        input.focusChanged = focusChanged; input.dropTargeted = dropTargeted
        input.enterSubmits = enterSubmits
        input.compositionChanged = composingChanged
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextInput
        init(_ parent: TextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let input = notification.object as? NSTextView { parent.text = input.string } }
    }
}

final class CaptureTextView: NSTextView {
    var enterSubmits = false
    var commit: (() -> Void)?
    var hide: (() -> Void)?
    var imagePaste: ((Data) -> Void)?
    var dropFiles: (([URL]) -> Void)?
    var focusChanged: ((Bool) -> Void)?
    var dropTargeted: ((Bool) -> Void)?
    var compositionChanged: ((Bool) -> Void)?
    private var reportedComposition = false

    /// Characters an input method is still composing stay inside the text view and never reach the
    /// binding, so composition is reported on its own and the placeholder can account for it.
    func syncComposition() {
        let value = hasMarkedText()
        guard reportedComposition != value else { return }
        reportedComposition = value; compositionChanged?(value)
    }
    override func didChangeText() { super.didChangeText(); syncComposition() }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        syncComposition()
    }
    override func unmarkText() { super.unmarkText(); syncComposition() }
    // Reported on the next turn of the loop: responder changes can land inside a SwiftUI update,
    // where a state write is dropped.
    private func reportFocus(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in self?.focusChanged?(value) }
    }
    override func becomeFirstResponder() -> Bool { let value = super.becomeFirstResponder(); reportFocus(value); return value }
    override func resignFirstResponder() -> Bool { let value = super.resignFirstResponder(); if value { reportFocus(false) }; return value }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !hasMarkedText(), [36, 76].contains(event.keyCode), modifiers == (enterSubmits ? [] : .command) { commit?(); return }
        if !hasMarkedText(), [36, 76].contains(event.keyCode), modifiers == .shift { insertNewline(nil); return }
        if !hasMarkedText(), event.keyCode == 53 { hide?(); return }
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) {
        if let urls = Self.fileURLs(on: NSPasteboard.general), !urls.isEmpty { dropFiles?(urls); return }
        if let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) { imagePaste?(data); return }
        super.paste(sender)
    }
    // A dropped or pasted file must become an attachment; a text view would otherwise insert its path.
    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let urls = Self.fileURLs(on: pasteboard), !urls.isEmpty { dropFiles?(urls); return true }
        return super.readSelection(from: pasteboard)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Self.fileURLs(on: sender.draggingPasteboard) == nil else { dropTargeted?(true); return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Self.fileURLs(on: sender.draggingPasteboard) == nil else { return .copy }
        return super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropTargeted?(false); super.draggingExited(sender) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { dropTargeted?(false); super.draggingEnded(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.fileURLs(on: sender.draggingPasteboard) != nil ? true : super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTargeted?(false)
        guard let urls = Self.fileURLs(on: sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        dropFiles?(urls)
        return true
    }
    /// Returns nil when the pasteboard is ordinary text, so plain pasting keeps its native behaviour.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }
        return files.isEmpty ? nil : files
    }
}
