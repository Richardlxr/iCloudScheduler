import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var message: String?
    private(set) var controller: SPUStandardUpdaterController!
    private weak var model: AppModel?
    private var pendingInstall: (() -> Void)?
    private var observations = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
        model.objectWillChange.sink { [weak self] _ in
            // Published notifications precede the mutation. Re-evaluate after the model has changed.
            DispatchQueue.main.async { self?.resumeInstallationIfIdle() }
        }.store(in: &observations)
    }

    func start() {
        do { try controller.updater.start() }
        catch { message = "更新服务无法启动：\(error.localizedDescription)" }
    }
    func check() { message = nil; controller.checkForUpdates(nil) }
    func setAutomaticallyChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }

    // A menu-bar app should indicate scheduled updates without stealing focus.
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { availableVersion = nil }
    func standardUserDriverWillFinishUpdateSession() { availableVersion = nil }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfBusy(installHandler)
    }
    func postponeInstallationIfBusy(_ installHandler: @escaping () -> Void) -> Bool {
        guard model?.updateWorkInProgress == true else { return false }
        pendingInstall = installHandler
        message = "更新已就绪，当前任务结束后安装并重启。"
        return true
    }
    private func resumeInstallationIfIdle() {
        guard model?.updateWorkInProgress == false, let install = pendingInstall else { return }
        pendingInstall = nil; message = nil
        install()
    }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Sparkle asks this before its postponement hook. Let the hook wait for busy work.
        if model?.updateWorkInProgress == true { return true }
        do {
            guard let model else { return false }
            try model.prepareForUpdateRestart()
            return true
        } catch {
            message = error.localizedDescription
            let alert = NSAlert()
            alert.messageText = "暂时无法重启安装"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "返回处理")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        pendingInstall = nil
        // Sparkle owns the interactive error dialog; retain a compact status in Settings too.
        message = (error as NSError).code == SUError.noUpdateError.rawValue ? nil : error.localizedDescription
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text("iCloudScheduler").font(.headline)
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("自动检查更新", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticallyChecks))
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if let version = updater.availableVersion { Text("新版本 \(version) 可用").foregroundStyle(Color.accentColor) }
                            if let date = updater.lastChecked { Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("检查更新…", action: updater.check).buttonStyle(.borderedProminent).disabled(!updater.canCheck)
                    }
                }.padding(8)
            }
            Text("发现新版本后，由你选择下载与安装；安装完成自动重启。自动检查每天最多一次，不上传日程或 API Key。").font(.caption).foregroundStyle(.secondary)
            if let message = updater.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Link("查看全部版本", destination: URL(string: "https://github.com/Richardlxr/iCloudScheduler/releases")!)
        }
    }
}
