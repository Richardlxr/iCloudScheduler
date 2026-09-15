# 自动更新维护

应用使用固定版本 Sparkle 2.9.6（MIT，Package.resolved 锁定提交），原生标准更新窗口负责检查、下载、失败提示、验证、安装与重启。设置页面仅绑定 Sparkle 的持久设置，不额外轮询。默认每天检查，关闭系统画像，不允许无人确认的后台安装。

菜单栏应用通过 gentle reminders 显示新版本入口，不主动抢焦点。用户点击入口后显示更新内容与安装按钮。安装等待进行中的模型生成、日历写入及连接测试结束；不可持久化的附件、未完成编辑或不允许保留的输入会阻止重启并提示处理。更新失败由 Sparkle 显示错误，原应用及配置保留。

## 信任与签名

- `SUPublicEDKey` 是公开的 Ed25519 更新公钥；私钥在本机钥匙串的 Sparkle account `dev.icloudscheduler.updates`。不得放进仓库、release、日志或 README。请自行通过安全方式备份钥匙串凭证；丢失此密钥会使已安装版本无法验证未来更新。
- `SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction` 同时开启：清单也签名，包在解包前验证。SHA256SUMS 供用户核对，不替代更新签名。
- 更新源固定为 `https://github.com/Richardlxr/iCloudScheduler/releases/latest/download/appcast.xml`。发布时必须包含名为 `appcast.xml` 的签名附件，且与 DMG 同属一个 release。
- feed 只引用同仓库不可复用的版本 tag 中的 Universal DMG。发布后的包或清单不可手工修改；任何修改必须重新签名。
- ad-hoc 构建为加载官方已签名 Sparkle 框架，单独使用 `iCloudScheduler-adhoc.entitlements` 放开 Library Validation。指定 `SIGNING_IDENTITY` 时使用原权限文件、按内部工具到框架到主应用顺序签名。Sparkle 更新签名不能替代 Apple Developer ID、公证和系统权限。
- 当前 DMG 使用 ad-hoc 签名。签名变化可能导致 macOS 再次要求日历或钥匙串授权。

## 发布步骤

1. 提升 `Resources/Info.plist` 的展示版本和**严格递增**的 `CFBundleVersion`，创建 `docs/releases/v版本.md`。公共更新只发布稳定版本、Universal 架构。
2. `./scripts/build-app.sh release`，运行核心、原生与 workflow 检查。检查失败不发布。
3. `./scripts/package-release.sh` 生成 DMG、ZIP 与 SHA256SUMS。
4. `python3 scripts/generate-update-feed.py` 从钥匙串读取签名能力，验证公钥匹配，签名 DMG 和 `dist/appcast.xml` 并验证两者。私钥不会导出。
5. 创建 Git tag 和**草稿** GitHub Release，一次上传 DMG、ZIP、SHA256SUMS、appcast.xml；核对附件存在且大小/哈希正确后，再公开为 latest。避免让自动更新用户看到尚未上传完的清单。
6. 使用上一版在隔离目录检查真实下载、签名、替换和重启；验证 latest/download/appcast.xml 已指向新 release。不要为测试发布虚假的超高版本或把测试 feed 放进正式包。

首次启用更新的 0.2.0 需由 0.1.x 用户手动安装一次。后续 release 必须继续上传签名 feed；临时补传会出现短暂检查失败，应优先使用草稿发布。

## 上游依据

- [Sparkle 官方接入与签名要求](https://sparkle-project.org/documentation/)
- [程序化初始化和 SwiftUI 设置](https://sparkle-project.org/documentation/programmatic-setup/)
- [更新发布与 appcast 格式](https://sparkle-project.org/documentation/publishing/)
- [后台应用的轻提示](https://sparkle-project.org/documentation/gentle-reminders/)

以上文档核对于 2026-09-12。

## 更新后权限重复请求（2026-09-15）

旧版使用 ad-hoc 签名。macOS 隐私授权和钥匙串访问依赖应用的 designated requirement；ad-hoc 默认要求绑定当前二进制，替换后可能重新请求权限。保持 Bundle ID 或 Sparkle EdDSA 签名本身不足以保留这些授权。

正式分发应持续使用同一开发团队的 Developer ID Application 签名，保持 Bundle ID `dev.icloudscheduler.app` 和钥匙串 service/account 不变，并按正式流程公证。首次从 ad-hoc 迁移到 Developer ID 时仍可能需要再授权一次，不能从应用内迁移或绕过系统授权。

```sh
SIGNING_IDENTITY='Developer ID Application: <name> (<TEAMID>)' ./scripts/build-app.sh release
./scripts/package-release.sh
```

打包脚本现在默认拒绝非 Developer ID 的分发包。本机测试仍允许 ad-hoc 构建；确实需要分发这种包时，必须显式设置 `ALLOW_ADHOC_RELEASE=1`，并接受权限可能再次提示的限制。当前机器仅发现 Apple Development 身份，没有可用的 Developer ID Application，因此尚未验证正式签名升级后的权限连续性。

发布前对比前后两版 `codesign -d -r- <app>` 的要求，并在独立测试用户下完成真实升级，核对日历权限、钥匙串读取和登录项。不要修改 TCC 数据库、关闭系统保护或把钥匙串访问开放给所有应用。

依据：[Apple TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。
