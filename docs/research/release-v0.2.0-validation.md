# v0.2.0 更新流程验收

日期：2026-09-12。原生 macOS，Universal 架构。测试不使用用户真实模型或日历。

- 核心检查 76、原生检查 25、流程检查 38，共 139 项通过。Intel/Rosetta 模式额外重复流程检查 38 项通过；不等同于实体 Intel Mac 验收。
- Universal 应用约 10 MB，包含 Sparkle 2.9.6 框架、帮助程序及许可证；框架动态链接、内部签名与宿主签名验证通过。
- 更新设置和菜单入口可用，显示当前版本、上次检查时间和自动检查开关。手动检查已是最新版本时给出明确提示。
- 使用隔离 bundle ID `dev.icloudscheduler.update-test`、独立配置目录、合成 CalendarAccess、无密钥读取运行 UI。正式 `/Applications/iCloudScheduler.app` 保持 0.1.1。
- 测试旧应用 build 1 / 0.0.1，目标 build 3 / 0.2.0。用户在隔离窗口执行 Sparkle 安装后，观察到测试应用重新运行，设置显示 0.2.0。实际安装的 Info.plist、可执行文件、CodeResources 与签名目标包一致。
- 通过 Sparkle 2.9.6 的官方 CLI 源码构建测试工具，对带签名的篡改 feed 收到错误 1000；对修改内容但保留原签名的包收到错误 4005。更新被拒绝，接收应用仍为 build 1。
- 应用安装延迟的离线检查覆盖日历写入、模型测试期间等待、任务结束只续接一次、编辑和附件保护、不保留草稿时防止输入丢失、正常保存与重启恢复。
- 发布使用 Universal DMG，ZIP 作为备用下载；生产 appcast 和 DMG 均使用本机钥匙串中的项目专用 Ed25519 密钥签名并验证。测试 feed 只在本机回环地址提供，不进入正式发布包。

测试记录保留在忽略目录 `dist/validation/updater-*.log`、`updater-install-result.txt` 与 `updater-settings.png`。隔离 UI 验证了 ZIP 更新与重启，另外通过官方 Sparkle CLI 完成签名 DMG 从 build 1 到 build 3 的真实下载、验证与安装。正式 DMG 的完整性、挂载内容和深层代码签名也通过检查。

当前仍无 Developer ID 公证，ad-hoc 更新可能重新触发 macOS 日历/钥匙串授权。未验证跨设备 iCloud 同步与实际提醒触发；它们不是更新框架的保证。0.1.x 没有更新入口，首次升级需手动安装 0.2.0。
