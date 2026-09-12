import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SchedulerCore

// Explicit alias keeps the property wrapper unambiguous with newer SDK State macros.
typealias ViewState<Value> = SwiftUI.State<Value>

struct CaptureView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            header
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
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
                Button { model.setStage(.input) } label: { Image(systemName: "arrow.left") }.buttonStyle(.plain).help("返回输入")
            } else { Image(systemName: "calendar.badge.plus").foregroundStyle(Color.accentColor) }
            Text(title).font(.system(size: 13, weight: .semibold))
            if model.isDemo { Text("界面示例").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            Button { model.setStage(.history) } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(.plain).help("近期记录")
            Button { model.showSettings?() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("设置 ⌘,")
            Button { model.persistDraft(); model.hidePanel?() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起 Esc")
        }.padding(.horizontal, 17).padding(.vertical, 15)
    }
    private var input: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    TextInput(text: $model.text, enterSubmits: model.preferences.enterSubmits, commit: { model.analyze() }, hide: { model.persistDraft(); model.hidePanel?() }, imagePaste: model.addPastedImage)
                        .overlay(alignment: .topLeading) {
                            if model.text.isEmpty { Text("有什么安排？\n粘贴消息，或拖入图片、PDF。")
                                .font(.system(size: 16)).foregroundStyle(.tertiary).padding(.top, 7).padding(.leading, 4).allowsHitTesting(false) }
                        }.frame(height: 130)
                    ForEach($model.attachments) { $attachment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: attachment.kind == "image" ? "photo" : "doc.text").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(attachment.label).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { model.attachments.removeAll { $0.id == attachment.id }; model.inputChanged() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("移除附件")
                            }
                            if attachment.kind == "pdf" {
                                HStack {
                                    Text("发送页码").font(.caption)
                                    TextField("起始", value: $attachment.firstPage, format: .number).frame(width: 45)
                                    Text("至")
                                    TextField("结束", value: $attachment.lastPage, format: .number).frame(width: 45)
                                    Text("最多 10 页").font(.caption2).foregroundStyle(.secondary)
                                }.textFieldStyle(.roundedBorder)
                            }
                        }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(.horizontal, 20).padding(.bottom, 8)
            }
            HStack {
                Button { model.chooseFiles() } label: { Label("添加附件", systemImage: "paperclip") }.buttonStyle(.plain)
                Spacer()
            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
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
            }.font(.caption).padding(13).background(.quaternary.opacity(0.2))
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

struct Notice: View {
    let message: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }.padding(10).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TextInput: NSViewRepresentable {
    @Binding var text: String
    var enterSubmits: Bool
    var commit: () -> Void
    var hide: () -> Void
    var imagePaste: (Data) -> Void
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
        input.delegate = context.coordinator; input.commit = commit; input.hide = hide; input.imagePaste = imagePaste
        input.enterSubmits = enterSubmits
        input.setAccessibilityLabel("日程内容")
        scroll.documentView = input
        DispatchQueue.main.async { input.window?.makeFirstResponder(input) }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = view.documentView as? CaptureTextView else { return }
        if input.string != text && !input.hasMarkedText() { input.string = text }
        input.commit = commit; input.hide = hide; input.imagePaste = imagePaste
        input.enterSubmits = enterSubmits
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
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !hasMarkedText(), [36, 76].contains(event.keyCode), modifiers == (enterSubmits ? [] : .command) { commit?(); return }
        if !hasMarkedText(), [36, 76].contains(event.keyCode), modifiers == .shift { insertNewline(nil); return }
        if !hasMarkedText(), event.keyCode == 53 { hide?(); return }
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) { imagePaste?(data); return }
        super.paste(sender)
    }
}
