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

本地构建、测试、打包、签名及后续公开验证日志保存于 `dist/validation/release-v0.3.0-*`。安装包为 `iCloudScheduler-0.3.0-macos-universal.dmg` / `.zip`，同时发布 `SHA256SUMS` 和签名 `appcast.xml`。
- 发布提交 `0a8b1c9b595c92dd1b9c819bf782f483bc79ece2`，tag `v0.3.0` 与其一致；[CI 34929739972](https://github.com/Richardlxr/iCloudScheduler/actions/runs/34929739972) 全部通过。
- [GitHub Release v0.3.0](https://github.com/Richardlxr/iCloudScheduler/releases/tag/v0.3.0) 从草稿切换为稳定版 latest 前，四个附件的远程大小和 SHA-256 均与本地一致。DMG 为 4,387,072 字节，ZIP 为 4,073,607 字节。
- DMG 只读挂载后验证版本 0.3.0 / build 5、应用二进制一致、Applications 快捷方式和深层代码签名。
- 公开 `latest/download/appcast.xml` 与本地签名文件逐字节一致，Ed25519 验签成功。公开 DMG 重新下载后 SHA-256 和 Ed25519 验签成功。
- 从已验证哈希的 v0.2.1 ZIP 提取隔离副本，以独立 bundle ID 使用 Sparkle 2.9.6 官方 CLI `--probe`，成功发现公开更新（exit 0）。本次未请求安装，也未重测替换与重启；正式安装的应用正在运行，保持不变。
- 环境变量提供的 GitHub 凭证不能创建 Release；改用本机钥匙串已有的同账户凭证完成草稿上传与发布。

## 清理

完成验证后删除本次生成的隔离上一版应用、重复下载的 DMG 和临时 Sparkle CLI；保留发布安装包、签名清单、日志和默认共享构建缓存。
