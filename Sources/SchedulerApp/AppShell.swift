import AppKit
import SwiftUI
import Carbon
import Combine

@main
enum SchedulerMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--model-contract-check") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await ModelContractChecks.run()) }
            app.run(); return
        }
        if CommandLine.arguments.contains("--workflow-check") {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await WorkflowChecks.run()) }
            app.run(); return
        }
        if CommandLine.arguments.contains("--self-check") {
            app.setActivationPolicy(.prohibited)
            exit(NativeChecks.run())
        }
        let model: AppModel
        if Bundle.main.bundleIdentifier == "dev.icloudscheduler.update-test" {
            let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("update-ui-store")
            model = AppModel(directory: directory, calendar: FixtureCalendar(), readKey: { _ in "" }, integrateSystem: false)
            model.settingsPage = .updates
        } else {
            model = CommandLine.arguments.contains("--review-fixture") ? WorkflowChecks.reviewFixture() : AppModel()
        }
        let delegate = AppDelegate(model: model)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel
    private lazy var updater = AppUpdater(model: model)
    private var updateObserver: AnyCancellable?
    init(model: AppModel) { self.model = model; super.init() }
    private var statusItem: NSStatusItem?
    private var panel: QuickPanel?
    private var settingsWindow: NSWindow?
    private var hotkey: GlobalHotkey?
    private var statusObserver: AnyCancellable?
    private var preferencesObserver: AnyCancellable?
    private var placingPanel = false
    private let positionKey = "capturePanelTopLeft"
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "iCloudScheduler")
        let menu = NSMenu()
        let activityItem = NSMenuItem(title: "准备就绪", action: nil, keyEquivalent: "")
        menu.addItem(activityItem); menu.addItem(.separator())
        menu.addItem(item("新建日程", #selector(showCapture), ""))
        menu.addItem(item("近期记录", #selector(showHistory), ""))
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(showSettings), ","))
        let updateItem = makeUpdateMenuItem()
        menu.addItem(updateItem)
        updateObserver = updater.$availableVersion.sink { version in
            updateItem.title = version.map { "发现新版本 \($0)…" } ?? "检查更新…"
        }
        menu.addItem(.separator())
        menu.addItem(item("退出 iCloudScheduler", #selector(quit), "q"))
        statusItem?.menu = menu
        statusObserver = model.$activityLabel.sink { [weak self] label in
            activityItem.title = label
            self?.statusItem?.button?.toolTip = "iCloudScheduler · \(label)"
        }
        model.showSettings = { [weak self] in self?.showSettings() }
        model.hidePanel = { [weak self] in self?.hideCapture() }
        model.panelIsVisible = { [weak self] in self?.panel?.isVisible == true }
        model.presentFailure = { [weak self] title, message in self?.presentFailure(title: title, message: message) }
        model.resizePanel = { [weak self] in self?.resize() }
        hotkey = GlobalHotkey { [weak self] in self?.toggleCapture() }
        model.registerShortcut = { [weak self] key, modifiers in self?.hotkey?.register(key: key, modifiers: modifiers) ?? false }
        if !model.smokeMode, hotkey?.register(key: model.preferences.shortcutKey, modifiers: model.preferences.shortcutModifiers) != true {
            model.shortcutError = "快捷键无法注册，可能已被其他应用占用。请重新录制。"
            model.errorMessage = "快捷键已被占用。请在“设置 → 通用”录制其他组合键，或从菜单栏打开窗口。"
        }
        preferencesObserver = model.$preferences.map(\.showMenuBar).removeDuplicates().sink { [weak self] visible in
            self?.statusItem?.isVisible = visible
        }
        model.applyAppearance()
        if !Self.isBackgroundLaunch(NSAppleEventManager.shared().currentAppleEvent),
           !CommandLine.arguments.contains("--background") { showCapture() }
        if !model.smokeMode || Bundle.main.bundleIdentifier == "dev.icloudscheduler.update-test" { updater.start() }
        if Bundle.main.bundleIdentifier == "dev.icloudscheduler.update-test" { showSettings() }
    }
    static func isBackgroundLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
    func applicationWillTerminate(_ notification: Notification) { model.persistDraft() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showCapture(); return true }
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(item("设置…", #selector(showSettings), ","))
        appMenu.addItem(makeUpdateMenuItem())
        appMenu.addItem(.separator()); appMenu.addItem(item("退出 iCloudScheduler", #selector(quit), "q"))
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem { let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item }
    private func makeUpdateMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "检查更新…", action: Selector(("checkForUpdates:")), keyEquivalent: "")
        item.target = updater.controller
        return item
    }
    @objc func showCapture() {
        if panel == nil {
            let window = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "iCloudScheduler"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isHidden = true; window.standardWindowButton(.miniaturizeButton)?.isHidden = true; window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isReleasedWhenClosed = false; window.isFloatingPanel = true; window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: CaptureView(model: model))
            window.hide = { [weak self] in self?.hideCapture() }
            window.delegate = self; panel = window
        }
        resize()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
    private func resize() {
        guard let panel else { return }
        placingPanel = true; defer { placingPanel = false }
        let saved = UserDefaults.standard.array(forKey: positionKey) as? [Double]
        let anchor = saved.flatMap { $0.count == 2 ? NSPoint(x: $0[0], y: $0[1]) : nil }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let fallback = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let height: CGFloat = model.stage == .input ? model.inputHeight : model.stage == .analyzing ? 245 : model.stage == .review ? model.reviewHeight : 440
        panel.setContentSize(NSSize(width: 480, height: height))
        panel.setFrame(PanelPlacement.frame(size: panel.frame.size, anchor: anchor, screens: screens, fallback: fallback), display: true)
    }
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, window.isVisible, !placingPanel else { return }
        UserDefaults.standard.set([Double(window.frame.minX), Double(window.frame.maxY)], forKey: positionKey)
    }
    private func hideCapture() {
        guard panel?.attachedSheet == nil else { return }
        model.persistDraft(); panel?.orderOut(nil)
    }
    private func toggleCapture() { if panel?.isVisible == true && panel?.isKeyWindow == true { hideCapture() } else { showCapture() } }
    private func presentFailure(title: String, message: String) {
        showCapture()
        if model.stage == .review && ["发现日程冲突", "冲突已变化"].contains(title) { return }
        guard let panel, panel.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "查看并处理")
        alert.beginSheetModal(for: panel)
    }
    @objc private func showHistory() { model.setStage(.history); showCapture() }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 630), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "iCloudScheduler 设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppSettingsView(model: model, updater: updater))
            window.minSize = NSSize(width: 710, height: 570); window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
        panel?.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender === panel { hideCapture(); return false }; return true }
    @objc private func quit() { NSApp.terminate(nil) }
}

final class QuickPanel: NSPanel {
    var hide: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { hide?() }
}

@MainActor
final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private var current: (UInt32, UInt32)?
    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in hotkey.action() }
            return noErr
        }, 1, &event, pointer, &handler)
    }
    func register(key: UInt32, modifiers: UInt32) -> Bool {
        if let current, current.0 == key, current.1 == modifiers { return true }
        var next: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x49435343, id: 1)
        guard RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &next) == noErr else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next; current = (key, modifiers); return true
    }
    deinit { if let reference { UnregisterEventHotKey(reference) }; if let handler { RemoveEventHandler(handler) } }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(); button.bezelStyle = .rounded
        button.started = { model.shortcutRecording = true }
        button.recorded = { event in
            if event.keyCode == 53 { model.shortcutRecording = false; return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control]).isEmpty else { model.shortcutError = "请包含 Command、Option 或 Control。"; return }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }; if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }; if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            guard model.registerShortcut?(UInt32(event.keyCode), modifiers) == true else { model.shortcutError = "快捷键已被占用，原快捷键保持不变。"; model.shortcutRecording = false; return }
            let label = (flags.contains(.control) ? "⌃ " : "") + (flags.contains(.option) ? "⌥ " : "") + (flags.contains(.shift) ? "⇧ " : "") + (flags.contains(.command) ? "⌘ " : "") + (event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased())
            model.preferences.shortcutKey = UInt32(event.keyCode); model.preferences.shortcutModifiers = modifiers
            model.preferences.shortcutLabel = label; model.shortcutError = ""; model.shortcutRecording = false; model.persistPreferences()
        }
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) { button.title = model.shortcutRecording ? "按下组合键…" : model.preferences.shortcutLabel; button.recording = model.shortcutRecording }
}

final class RecorderButton: NSButton {
    var started: (() -> Void)?
    var recorded: ((NSEvent) -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); started?() }
    override func keyDown(with event: NSEvent) { if recording { recorded?(event) } else { started?() } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { recorded?(event); return true }; return super.performKeyEquivalent(with: event) }
}
