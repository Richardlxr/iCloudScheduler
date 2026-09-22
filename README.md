# iCloudScheduler

<img src="Resources/AppIcon.png" alt="iCloudScheduler 应用图标" width="104">

面向 macOS 的轻量日程助手：通过快捷键输入文字、图片或文件，生成可编辑的日程草稿，按设置自动添加或确认后写入系统日历中的 iCloud 日历。

**轻量、原生、随用随收起。** 使用 SwiftUI、AppKit、EventKit 和系统 SQLite；仅引入 Sparkle 处理自动更新。用户自带模型 API Key，密钥保存在 macOS 钥匙串；MIT 开源。

- **约 10 MB Universal 应用包（含更新组件）**：包含图标与两种 CPU 架构的 Release `.app` 大小；不捆绑浏览器内核、Python 运行时或本地大模型。
- **小窗口、可隐藏菜单栏图标**：登录时静默启动，快捷键呼出，支持记忆窗口位置，提交后可自动收起。
- **按需调用模型**：没有后台模型轮询，失败不自动重试。图片直接交给视觉模型，PDF 在本机按选定页面转图。
- **直接写入系统日历**：前台可选确认，后台直接添加，提醒交给 macOS 日历处理。

包体大小不代表运行内存；内存和处理耗时随输入文字、图片及 PDF 页数变化。

## 下载与安装

前往 [GitHub Releases](https://github.com/Richardlxr/iCloudScheduler/releases/latest) 下载 `iCloudScheduler-0.4.0-macos-universal.dmg`，打开后将 `iCloudScheduler.app` 拖到 `Applications`。也提供 ZIP 压缩包。需要 **macOS 14+，Apple Silicon（M 系列芯片）或 Intel Mac**。

当前下载包使用 ad-hoc 签名，尚未通过 Apple Developer ID 签名与公证，macOS 可能阻止首次打开；更新后可能需要重新授权日历和钥匙串。也可按下面的步骤从源码构建；一个 Universal 安装包同时包含 arm64 与 x86_64 两种架构。

## 构建与运行

要求 macOS 14+，Swift 6.0+，可使用完整 Xcode 或 Command Line Tools。默认构建 Universal 应用；可传入 `./scripts/build-app.sh release arm64` 或 `x86_64` 仅构建指定架构。

```bash
./scripts/build-app.sh
open dist/iCloudScheduler.app
```

脚本生成 `dist/iCloudScheduler.app` 并进行本机 ad-hoc 签名。首次构建会下载锁定版本的 Sparkle 2.9.6；后续复用 SwiftPM 缓存。

## 应用内更新

菜单栏 **“检查更新…”** 或 **“设置 → 软件更新”** 可查看新版本、下载并安装，完成后自动重启。自动检查默认每日一次，发现更新只在菜单栏提示；可关闭自动检查，安装始终由用户发起。

更新清单与安装包均验证 Ed25519 签名，验证通过后才解包。生成日程、写入日历或测试模型时暂缓重启；未完成的附件、编辑以及关闭草稿保留时的输入需先处理，其他可恢复草稿会在重启前保存。更新检查连接 GitHub，不发送日程、附件或 API Key，也不启用系统画像上报。

**0.1.x 需手动安装一次当前版本；0.2.0 及以上可在 App 内更新。** 更新不会替你绕过 macOS 的日历、钥匙串或首次启动权限。发布流程见 [更新维护说明](docs/updating.md)。

## 使用

1. 菜单栏打开输入窗口，默认快捷键为 `⌥ Space`，可在通用设置中修改。
2. 在模型设置选择预设或自定义服务，填写 Key、模型和地址。点击“测试文本”“测试图片”会向当前服务发送合成样本，产生少量 API 费用；保存后结果生效。
3. 在日历设置允许访问，明确选中 `iCloud / 你的日历`，保存默认日历和提前提醒。
4. 输入安排，按提交快捷键生成。默认检查草稿后添加，也可在“日历与提醒”关闭“添加前确认”，让信息完整的日程自动添加。

确认窗口直接显示具体假设和时间冲突。存在冲突时，底部固定显示 **“删除 / 仍然添加”**；“仍然添加”一次完成确认并写入，全部成功后窗口自动收起，记录可在“近期记录”查看；删除仅移除选中的待添加草稿，完成后同样收起窗口。当前输入中的日程全部添加或删除后，会清空原文、附件和草稿，再次呼出直接开始新输入；未选中、尚未处理的草稿保留，失败或结果不确定时仍显示待处理内容。缺少或需要调整信息时，可在卡片内补充一句话，点击“AI 补全”，核对后再添加；也可使用原生日期和时间选择器手动编辑。

模型只返回固定字段的 JSON；没有年份的月日按当前年或下一年展开，只有开始时间且未指定时长时，保存为不占忙碌时间的 1 分钟日历提醒，缺地点留空。默认规则不作为阻塞假设，非必要信息不触发追问；真正缺少具体时刻时仍需补全。

群消息里的催办、办理、缴费一类待办常常只写“尽快”“今晚”“本周内”，没有具体时刻。这类输入模型只判断措辞属于哪一种时限（尽快、今天、今晚、明天、周末、本周、下周、月底），具体时刻由本机按提交时间换算成一个短期提醒：模型不做日期推算，也不会因此追问。确认窗口会写明“原文只写了‘尽快’：已安排在 X 月 X 日 XX:XX 提醒”，可直接修改。同一条消息里点名多人时合并为一条日程，人名写入备注。原文连时限措辞都没有时仍然留空并要求补全，此时卡片上直接提供“尽快 / 今晚 / 明天 / 本周内”四个按钮，在本机换算，不再调用模型。

“通用”可选择 `Enter` 或 `⌘ Enter` 提交，`Shift Enter` 换行。开启“提交后后台运行”会在任务开始后收起窗口；`Esc` 和呼出快捷键只收起，不提交、不取消。生成或添加失败、读回结果不确定时会重新打开窗口并弹窗提示，不自动重试。开启后台运行时直接尝试添加，不再要求确认；只有确认全部添加成功才保持安静。冲突、信息缺失、部分失败或提醒被系统调整都会弹窗。前台确认模式下若手动收起窗口，草稿生成后也会弹窗请求确认。退出应用会中断生成。

拖动窗口后会记住位置，重启后恢复；原显示器不可用时回到可见区域。“日历与提醒”支持自定义全天提醒的提前天数（0–7 天）、小时与分钟，以事件时区计算。

输入窗底部的模型菜单可切换已保存密钥的服务商，并记住选择；菜单中的“管理模型配置”打开设置。文件可以拖进窗口（包括直接拖到输入框）或粘贴，成为附件而不是把路径写进正文；输入法拼音在上屏前也不会与提示文字重叠。

含文字层的 PDF 默认在本机提取所选页面的文字发送，更贴近原文，也不需要图片能力；扫描件按页转图，仍需先通过图片测试，可在附件卡片上切换“按文本/按图片”。图片直接交给视觉模型，不执行本地 OCR。一次最多 5 个附件，单文件 20 MB，总计最多 10 张图片/页面、12 MB 编码图片、2 万字。PDF 默认选前 5 页，可在发送前调整。

## 验证与边界

```bash
swift build --product SchedulerChecks
checks_binary="$(swift build --show-bin-path)/SchedulerChecks"
codesign --force --sign - "$checks_binary"
"$checks_binary"
./dist/iCloudScheduler.app/Contents/MacOS/iCloudScheduler --self-check
./dist/iCloudScheduler.app/Contents/MacOS/iCloudScheduler --workflow-check
```

离线检查覆盖日期/夏令时、缺失信息、提醒、接口地址、模型响应和配置失效，不访问网络、钥匙串或真实日历。

已实现输入、设置、模型请求、日程编辑、指定日历写入、冲突提示、操作记录、恢复核对和有条件撤销。自动找空档、重复规则、DOCX/ICS、上游原生 PDF 上传和流式响应尚未实现。模型失败不自动重试，日历保存成功不代表其他设备已经完成同步。

自动化验收使用合成模型和日历，共 225 项离线检查通过；这些检查不代表六家真实推理、跨设备同步或系统提醒已全部验收。详见 [开发与验证说明](docs/development.md)、[v0.3.0 发布核验](docs/research/release-v0.3.0-validation.md)及 [v0.2.0 更新流程核验](docs/research/release-v0.2.0-validation.md)。

窗口记忆、可选提交快捷键、后台处理和自定义全天提醒的后续验证见 [后台流程验收记录](docs/research/background-validation.md)。输入框、附件读取与短期提醒换算的验证见 [输入与时限验收记录](docs/research/capture-and-timing-validation.md)。

## 方案文档

- [可行性与产品技术方案](docs/feasibility-and-design.md)：技术选型、窗口交互、文件处理、日程生成、EventKit、权限、隐私与数据设计。
- [模型预设与有效性验证](docs/provider-compatibility.md)：六家服务商的当前官方接口、模型候选、能力差异、配置验证及维护规则。
- [实施计划与发布验收](docs/implementation-plan.md)：里程碑、工作量、测试矩阵、性能目标和开源分发。
- [日程草稿示例](docs/examples/event-plan.json)：用于讨论数据契约的示例，不是可直接执行的日历操作。
- [无密钥端点探测记录](docs/research/endpoint-reachability.json)与[官方文档检查记录](docs/research/source-checks.json)。

研究基准日为 2026-09-12。官方文档核对与无密钥探测不代表带 Key 的模型调用已经通过，真实推理、日历写入、跨设备同步和提醒均需在开发阶段验证。

## Buy me a coffee ☕

如果这个小工具帮你省了时间，欢迎请我喝杯咖啡，支持后续维护。

<table>
  <tr>
    <th>支付宝</th>
    <th>微信支付</th>
  </tr>
  <tr>
    <td><img src="docs/assets/alipay.jpg" alt="支付宝收款码" width="240"></td>
    <td><img src="docs/assets/wechat-pay.jpg" alt="微信支付收款码" width="240"></td>
  </tr>
</table>

## 商业合作

联系邮箱：[2323805802l@gmail.com](mailto:2323805802l@gmail.com)
