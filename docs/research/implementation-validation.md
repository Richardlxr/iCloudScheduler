# 开发预览验收记录

日期：2026-09-12。范围：本机原生开发预览，不代表公开发行或真实服务联调已通过。

## 构建结果

- 环境：Apple Silicon、macOS 26.6.2、Swift 6.4 Command Line Tools。
- 最低部署目标 macOS 14；本次实际构建为 arm64，未在 Intel 或 macOS 14 真机运行。
- `./scripts/build-app.sh release` 成功，生成 `dist/iCloudScheduler.app`，包体约 2.1 MB。
- `codesign --verify --strict --verbose=2 dist/iCloudScheduler.app` 通过。本机 ad-hoc 签名，未做 Developer ID 签名、公证或发布。
- 动态依赖仅为系统库/框架；启动交付应用不依赖 SwiftPM 构建缓存。
- 最终应用已用普通启动方式运行，进程存在；普通启动后的日历权限与模型流程未继续操作。

## 离线验证

| 检查 | 结果 | 覆盖 |
| --- | --- | --- |
| `swift run SchedulerChecks` | 58 通过，0 失败 | 时间/时区、夏令时重复和不存在时间、全天提醒、缺失信息、假设确认、数值边界、URL 规则、严格 JSON、能力失效 |
| `dist/iCloudScheduler.app/Contents/MacOS/iCloudScheduler --self-check` | 17 通过，0 失败 | SQLite 重开、草稿和设置、文件权限、记录保留、图像编码、透明白底、PDF 选页/旋转、附件预算及异常文件 |
| 静态检查 | 通过 | plist、shell 语法、Markdown 本地链接、文档 JSON、空白错误 |

本机原始输出保留在 `dist/validation/core-checks.log` 和 `dist/validation/native-checks.log`。合成数据库、PDF 与渲染图片保留在 `dist/validation/native-fixtures/`。`dist/` 不加入版本控制，可用上述命令重新生成。

PDF 选页及旋转输出已实际查看，字符与方向正确。合成 PDF 构造过程产生 CoreGraphics 图像方向警告，检查未失败；不能将此次结果描述为完全无警告。

## 原生界面检查

使用 `--ui-smoke` 模式检查了实际 macOS 窗口：

1. 输入窗、附件入口、手动填写及空输入时禁用的分析按钮。
2. 示例日程审核、明确的示例标记、禁用的真实写入按钮。
3. 原生日程编辑表单；结束时间早于开始时间时，完成操作被校验拦截。
4. 独立模型设置窗口，六家预设、空密钥状态、未验证提示及测试入口。

后续 Computer Use 连接关闭，重连未恢复。最终小窗高度和快捷键冲突提示调整后，完成重新编译与普通进程启动；未再次通过该工具核对最终外观。此前连接中断时应用进程仍在，不能据此判断应用崩溃。

## 尚未验收

- 未填入真实 API Key，未执行付费推理；六家预设是可配置候选，不是已通过付费调用的承诺。
- 未授权或操作真实日历；EventKit 写入、冲突读取、恢复核对、撤销及权限异常需要专用测试日历联调。
- iCloud 跨设备同步、退出应用后的系统提醒、系统权限连续性尚未验证。
- 全局快捷键冲突、全屏/多屏/Spaces、中文输入法和登录启动仍需完整人工检查。
- CI 工作流已写入，未推送到 GitHub，也未观察远端运行。

自动找空档、重复日程执行、原始 PDF 上游上传、DOCX/ICS、流式响应和自动更新不在当前实现中。后续受控验收步骤见 [开发与验证说明](../development.md)。
