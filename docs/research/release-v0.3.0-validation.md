# v0.3.0 发布核验

日期：2026-09-15。展示版本 0.3.0，构建号 5。

## 本地验证

- Release Universal 构建成功，`lipo -archs` 确认 x86_64、arm64 两种架构。
- 核心 81、原生 26、工作流 77 项检查通过，共 184 项。未使用真实模型、日历或模型钥匙串凭证。
- 当前主机执行 Intel 模式返回 `Bad CPU type in executable`，因此没有将本次 Intel/Rosetta 执行标记为通过。
- 使用固定版本 Sparkle 2.9.6 与原 Ed25519 公钥；发布 DMG 和 appcast 使用原项目钥匙串签名能力，密钥不导出。
- 本次沿用 ad-hoc 分发，显式使用 `ALLOW_ADHOC_RELEASE=1` 打包；没有 Developer ID 签名或公证，系统权限可能需要重新授权。

## 界面及功能边界

静默登录启动、开始时间提醒、菜单栏显示开关、自然语言补全及轻量原生样式见 [功能验收](ux-improvements-validation.md) 和 [UI 验收](ui-polish-validation.md)。界面工具故障导致通用设置及深色主题未完成实机视觉复核；真实登录、系统提醒投递及跨设备同步未在本轮重测。

## 发布证据

本地构建、测试、打包、签名及后续公开验证日志保存于 `dist/validation/release-v0.3.0-*`。安装包为 `iCloudScheduler-0.3.0-macos-universal.dmg` / `.zip`，同时发布 `SHA256SUMS` 和签名 `appcast.xml`。公开附件与上一版更新探测结果在完成后补记。
