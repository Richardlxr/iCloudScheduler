# v0.3.1 发布核验

日期：2026-09-15。版本 0.3.1，构建号 6；发布提交 `98c946c406d9bfdbd270de3800cd0fbb4d543190`。

- 设置侧栏标签在完整行尺寸及内边距之后指定矩形点击区域，空白处也能触发按钮；最小行高 40 点。没有新增依赖或后台任务。
- Release Universal 构建成功；DMG 只读挂载检查确认 arm64 / x86_64、版本、应用二进制、Applications 快捷方式及深层签名。
- 81 项核心、26 项原生、77 项工作流检查通过，共 184 项。[CI 34930151991](https://github.com/Richardlxr/iCloudScheduler/actions/runs/34930151991) 全部通过。
- [Release v0.3.1](https://github.com/Richardlxr/iCloudScheduler/releases/tag/v0.3.1) 发布前核对草稿中的 DMG、ZIP、SHA256SUMS、appcast.xml：远程大小及 SHA-256 与本地一致，随后公开为 latest。
- 正式 latest appcast 与本地签名清单逐字节一致，版本 0.3.1 / build 6；公开下载 DMG 的 SHA-256 与本地一致，清单及安装包 Ed25519 验签通过。
- 从已核对公开哈希的 v0.3.0 ZIP 提取独立 bundle ID 副本，使用 Sparkle 2.9.6 官方 CLI `--probe` 成功发现新版本（exit 0）。未请求安装或重启用户正在使用的应用。
- 当前仍为 ad-hoc 签名、未公证；系统权限可能需要重新授权。
- 本次未重新进行原生 GUI 边缘点击、Intel 模式运行、日历写入或模型调用验收；没有将编译和工作流检查当作这些实测的替代。

日志：`dist/validation/release-v0.3.1-*`。清理本次隔离旧版应用、重复下载 DMG 和临时 CLI，保留发布产物、日志及默认共享缓存。
