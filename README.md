# iCloudScheduler

<img src="Resources/AppIcon.png" alt="iCloudScheduler 应用图标" width="104">

面向 macOS 的轻量日程助手：通过快捷键输入文字、图片或文件，生成可编辑的日程草稿，按设置自动添加或确认后写入系统日历中的 iCloud 日历。

**轻量、原生、随用随收起。** 使用 SwiftUI、AppKit、EventKit 和系统 SQLite，无第三方包依赖。用户自带模型 API Key，密钥保存在 macOS 钥匙串；MIT 开源。

- **约 6 MB Universal 应用包**：包含图标与两种 CPU 架构的 Release `.app` 大小；不捆绑浏览器内核、Python 运行时或本地大模型。
- **小窗口、菜单栏常驻**：快捷键呼出，支持记忆窗口位置，提交后可自动收起。
- **按需调用模型**：没有后台模型轮询，失败不自动重试。图片直接交给视觉模型，PDF 在本机按选定页面转图。
- **直接写入系统日历**：前台可选确认，后台直接添加，提醒交给 macOS 日历处理。

包体大小不代表运行内存；内存和处理耗时随输入文字、图片及 PDF 页数变化。

## 下载与安装

前往 [GitHub Releases](https://github.com/Richardlxr/iCloudScheduler/releases/latest) 下载 `iCloudScheduler-0.1.0-macos-universal.zip`，解压后将 `iCloudScheduler.app` 拖入“应用程序”目录。需要 **macOS 14+，Apple Silicon（M 系列芯片）或 Intel Mac**。

当前下载包使用 ad-hoc 签名，尚未通过 Apple Developer ID 签名与公证，macOS 可能阻止首次打开。也可按下面的步骤从源码构建；一个 Universal 安装包同时包含 arm64 与 x86_64 两种架构。

## 构建与运行

要求 macOS 14+，Swift 5.10+，可使用完整 Xcode 或 Command Line Tools。默认构建 Universal 应用；可传入 `./scripts/build-app.sh release arm64` 或 `x86_64` 仅构建指定架构。

```bash
./scripts/build-app.sh
open dist/iCloudScheduler.app
```

脚本生成 `dist/iCloudScheduler.app` 并进行本机 ad-hoc 签名。项目没有需要另外下载的 Swift 包依赖。

## 使用

1. 菜单栏打开输入窗口，默认快捷键为 `⌥ Space`，可在通用设置中修改。
2. 在模型设置选择预设或自定义服务，填写 Key、模型和地址。点击“测试文本”“测试图片”会向当前服务发送合成样本，产生少量 API 费用；保存后结果生效。
3. 在日历设置允许访问，明确选中 `iCloud / 你的日历`，保存默认日历和提前提醒。
4. 输入安排，按提交快捷键生成。默认检查草稿后添加，也可在“日历与提醒”关闭“添加前确认”，让信息完整的日程自动添加。

“通用”可选择 `Enter` 或 `⌘ Enter` 提交，`Shift Enter` 换行。开启“提交后后台运行”会在任务开始后收起窗口；`Esc` 和呼出快捷键只收起，不提交、不取消。生成或添加失败、读回结果不确定时会重新打开窗口并弹窗提示，不自动重试。开启后台运行时直接尝试添加，不再要求确认；只有确认全部添加成功才保持安静。冲突、信息缺失、部分失败或提醒被系统调整都会弹窗。前台确认模式下若手动收起窗口，草稿生成后也会弹窗请求确认。退出应用会中断生成。

拖动窗口后会记住位置，重启后恢复；原显示器不可用时回到可见区域。“日历与提醒”支持自定义全天提醒的提前天数（0–7 天）、小时与分钟，以事件时区计算。

输入窗底部的模型菜单可切换已保存密钥的服务商，并记住选择；菜单中的“管理模型配置”打开设置。图片/PDF 需要先通过图片测试；图片直接交给视觉模型，PDF 在本机分页转图，不执行本地 OCR。一次最多 5 个附件，单文件 20 MB，总计最多 10 张图片/页面、12 MB 编码图片、2 万字。PDF 默认选前 5 页，可在发送前调整。

## 验证与边界

```bash
swift run SchedulerChecks
./dist/iCloudScheduler.app/Contents/MacOS/iCloudScheduler --self-check
./dist/iCloudScheduler.app/Contents/MacOS/iCloudScheduler --workflow-check
```

离线检查覆盖日期/夏令时、缺失信息、提醒、接口地址、模型响应和配置失效，不访问网络、钥匙串或真实日历。

已实现输入、设置、模型请求、日程编辑、指定日历写入、冲突提示、操作记录、恢复核对和有条件撤销。自动找空档、重复规则、DOCX/ICS、上游原生 PDF 上传、流式响应和自动更新尚未实现。模型失败不自动重试，日历保存成功不代表其他设备已经完成同步。

自动化验收使用合成模型和日历，共 112 项离线检查通过；这些检查不代表六家真实推理、跨设备同步或系统提醒已全部验收。详见 [开发与验证说明](docs/development.md)及[v0.1.0 发布核验](docs/research/release-v0.1.0-validation.md)。

窗口记忆、可选提交快捷键、后台处理和自定义全天提醒的后续验证见 [后台流程验收记录](docs/research/background-validation.md)。

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
