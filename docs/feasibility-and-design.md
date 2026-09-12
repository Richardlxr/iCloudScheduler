# iCloudScheduler 可行性与产品技术方案

**建议采用 Swift + SwiftUI + 少量 AppKit，构建 macOS 14 及以上的菜单栏应用；使用 EventKit 接入系统日历，用户自带模型 API Key，首版通过 GitHub Releases 发布签名、公证后的安装包。** 项目不需要自建业务后端，也不需要为了“轻量”先引入 Rust。核心工程投入应放在日期理解、确认体验、日历写入可靠性和模型兼容性上。

当前已经开始实现原生开发预览。本文同时包含公开首版的目标设计，实际完成状态及限制见 [开发与验证说明](development.md)，不能把规划条目理解为已验收。

## 1. 产品定位与可行性

产品定位是“把零散信息变成可信日程的快速入口”。用户用快捷键呼出小窗口，粘贴通知、拖入截图或 PDF，检查提取结果，确认加入日历。日常日历浏览继续交给系统日历；应用提供本次结果、近期导入和必要的冲突提示。

| 需求 | 判断 | 实现路径与边界 |
| --- | --- | --- |
| 轻量常驻 | 可行 | 原生界面；空闲时无轮询、无模型进程、无本地 HTTP 服务 |
| 快捷键呼出小窗口 | 可行 | 全局快捷键注册 + AppKit NSPanel + SwiftUI 内容 |
| 文本、图片、文件输入 | 可行 | 文本直接发送；图片交给视觉模型；PDF 分页转图；明确限制首版格式 |
| 自定义 Base URL/API Key | 可行 | 一个 HTTP 传输层、多个厂商适配器；Keychain 保存 Key |
| 常用模型预设 | 可行但要持续维护 | 官方按量 API 预设；模型、地区、参数及测试状态单独管理 |
| 加入 iCloud 日历并提醒 | 可行 | EventKit 写入用户选择的系统日历；系统负责 iCloud 同步与日历通知 |
| 根据已有日程找空档 | 可行 | 本地读取授权范围内的忙碌区间，确定性算法安排时间 |
| 保证所有设备准时弹窗 | 无法由本应用独立保证 | 受设备联网、iCloud 同步、通知设置、专注模式和设备状态影响 |

EventKit 提供事件、日历、账户来源和提醒的系统接口。iCloud 日历出现在系统日历中后，可由这条路径读写；其他设备需要登录相同 Apple Account 并开启日历同步。[^1][^2]

### 1.1 首个公开版本范围

首版包含：菜单栏入口、用户自定义全局快捷键、小窗口输入、文字/图片/PDF 处理、六家官方模型预设及自定义兼容服务、配置测试、单条或多条日程草稿、编辑与确认、指定目标日历、提前提醒、冲突提示、导入记录和有条件撤销。

日程生成分为两类：从通知中提取已经确定的事件；从“本周找一小时准备演讲”中提取任务约束并推荐一个时间段。后一类首版限制为未来 7 天内、最多 10 个任务、按优先级和截止时间顺序分配，不承诺复杂项目优化。

后续版本再扩展 DOCX/ICS、完整周视图、重复事件编辑、复杂任务拆分、提醒事项 App、快捷指令和本地模型。首版不将软件做成聊天客户端，也不增加账户系统或云端文件库。

## 2. 技术选型：Rust 是否必要

**Rust 不是必要条件。** 这个产品主要执行窗口交互、系统框架调用、少量本地数据处理和远程网络请求。语言性能通常不会成为瓶颈，模型等待和图片处理更值得优化。此判断是基于工作负载的工程建议，尚未经过本项目性能测试。

| 方案 | 优点 | 代价 | 适用判断 |
| --- | --- | --- | --- |
| SwiftUI + AppKit | EventKit、Vision、PDFKit、Keychain 可直接调用；原生输入和无障碍适配路径短 | 需要掌握 AppKit 窗口/焦点；只覆盖 Apple 平台 | **首选** |
| Tauri 2 + Web UI + Rust | Web UI 开发方便；适合计划覆盖 Windows/Linux 的团队 | 仍需处理 macOS 桥接、权限、窗口焦点；增加 WebView 与 IPC 层 | 明确跨平台后再考虑 |
| Swift UI + Rust 核心 | 可以复用复杂解析或排程算法 | FFI、构建与调试成本增加 | 算法确有跨平台需求或性能数据支撑时引入 |
| Electron | Web 生态成熟，桌面跨平台能力完整 | 打包 Chromium/Node；与本项目常驻小工具的资源目标匹配度较低 | 首版不推荐 |

Tauri 使用系统 WebView，Electron 将 Chromium 和 Node.js 打入应用。两者不能仅凭框架宣传的最小包体与实际 Swift 应用比较，应比较完成同样功能后的结果。[^3][^4]

### 2.1 推荐组件

| 层 | 选择 | 原因 |
| --- | --- | --- |
| 应用与设置界面 | SwiftUI | 常规表单、列表、状态绑定 |
| 快速输入窗口 | AppKit NSPanel + NSHostingView | 控制焦点、浮层、关闭行为和 Space 交互 |
| 全局快捷键 | Carbon RegisterEventHotKey + 原生录制控件 | 开发预览无第三方依赖；注册冲突时保留原配置，菜单栏入口仍可用 |
| 日历 | EventKit | 官方系统接口 |
| 网络 | URLSession + Codable + async/await | 六家服务共用传输与错误处理，差异留在适配器 |
| 图片处理 | ImageIO + 上游视觉模型 | 规范方向、缩放与去元数据后直接发送；首批不做 OCR |
| PDF | PDFKit | 选择页码、分页渲染为图片，与原生图片走同一视觉通道 |
| 持久化 | SQLite（系统 C API）+ 原子 JSON 文件 | 开发预览使用 SQLite 写入操作日志，JSON 保存配置和文字草稿；暂不引入第三方存储库 |
| 密钥 | Security/Keychain | 保存 API Key 和敏感自定义请求头 |
| 登录启动 | SMAppService | 由用户开启，适配系统登录项管理 |

以上库与系统能力均有官方或维护者文档；依赖版本在实施时锁定，并确认最低系统版本。[^5][^6][^7][^8][^9][^10]

### 2.2 “轻量”的可验收定义

下列数值是**首轮预算，未实测**，以 Release 构建、Apple Silicon、8 GB 内存设备作为初始基线：安装包不超过 30 MB，菜单栏空闲物理内存占用目标不超过 100 MB，空闲 CPU 五分钟平均低于单核 0.5%，已启动状态下快捷键到可输入的 P95 不超过 200 ms。图片/PDF 处理允许短时峰值，结束后应及时释放。

实现上：设置页延迟加载；不在启动时验证全部 Key；无每秒刷新；不监听整个文件系统；大图先缩放；PDF 逐页处理；避免把原图、Base64、整份请求体同时保留多份；模型请求取消后释放缓冲区。超出预算先测量主因，再决定是否引入 Rust。

## 3. 交互与信息架构

### 3.1 三个入口

1. **快捷输入窗口**：主要工作入口，建议初始 480 × 300 pt。结果出现后最多扩到约 480 × 560 pt；多条事件在内部滚动。
2. **菜单栏菜单**：新建、近期导入、设置、退出；应用未启动时全局快捷键无法工作，因此提供用户可选的登录启动。
3. **独立设置窗口**：约 720 × 520 pt，承载模型服务、日历与提醒、快捷键与通用、隐私与存储。常见设置不用挤进快速窗口。

尺寸是起点，必须验证小屏幕、中文长文本和辅助功能；允许在可用屏幕范围内调整。主界面只保留一个明确主动作。

### 3.2 快速输入窗口示意

~~~text
┌────────────────────────────────────────────┐
│ 新建日程                              设置 │
│                                            │
│ 输入安排，或粘贴图片、拖入文件…            │
│ 明天下午三点开组会                          │
│                                            │
│ [组会通知.png ×]                           │
│                                            │
│ 使用：已配置的模型服务       [分析 ⌘↵]     │
└────────────────────────────────────────────┘

┌────────────────────────────────────────────┐
│ 识别到 2 项安排                      返回 │
│ ☑ 组会                                    │
│   9 月 13 日 周日 15:00–16:00             │
│   提前 15 分钟 · 工作日历                 │
│   时长采用默认值，可修改                  │
│                                            │
│ ☐ 交报告                                  │
│   需要补充截止日期              [补充]    │
│                                            │
│              [添加 1 项到日历 ⌘↵]         │
└────────────────────────────────────────────┘
~~~

示意图中的事件和日期仅展示交互。实际结果必须来自输入；标题、日期、时区、提醒和目标日历均可编辑。未知字段不能用漂亮的完整卡片掩盖。

### 3.3 状态与键盘操作

~~~mermaid
stateDiagram-v2
    [*] --> Input
    Input --> Extracting: 分析
    Extracting --> Clarify: 必要字段缺失
    Extracting --> Review: 得到草稿
    Extracting --> Error: 失败
    Clarify --> Review: 用户补全
    Review --> Writing: 确认选中项
    Writing --> Receipt: 写入并核对
    Writing --> Reconcile: 结果不确定
    Reconcile --> Receipt: 查明结果
    Error --> Input: 保留输入并修改
    Receipt --> Input: 完成
~~~

输入状态 Enter 换行、⌘Enter 分析；审核状态 ⌘Enter 添加选中且有效的项目。中文输入法正在组词时不触发提交。Esc 隐藏窗口并保留草稿；取消分析使用明确按钮。写入已经开始后，隐藏窗口不撤销写入。

避免流式字符改变窗口高度：状态区只显示“识别文件”“分析安排”“校验时间”，收到完整且通过校验的结果后一次展示卡片。首次公开使用时让用户录制快捷键，可建议 ⌥Space，但不抢占 Spotlight 或已有快捷键。[^5]

NSPanel 可使用 nonactivatingPanel 作为起点，但输入焦点、多显示器、全屏应用、Stage Manager、输入法和文件选择弹窗必须真机验证，不能把 styleMask 设置成功当成体验完成。失焦处理需要排除文件选择器和本应用设置窗口，防止误收起或丢失输入。[^11]

### 3.4 首次使用

先展示可编辑的示例输入和菜单栏入口，再引导选择服务商、填写 API Key、运行测试。首次请求前说明哪些文字或图片将发送到哪个域名。用户首次选择目标日历或添加事件时，再请求日历权限。

完全没有 Key 时可以浏览示例、手工填写日程并添加；没有日历权限时可以生成和编辑草稿。每个受阻步骤保留已完成的数据，不把配置错误变成整页报错。

## 4. 参考 CC Switch 的配置体验

借鉴 CC Switch 的“预设选择 → 自动填充端点 → 填写 Key → 选择模型”的流程，以及可搜索预设、获取模型、敏感字段遮罩和高级配置折叠。其供应商添加文档和源码已核对，参考提交固定为 d695a2d77fd9081eafd3e9eedcbf2a97b3410928。[^12]

本产品只需要一个默认分析服务，可选一个图片服务。设置页默认显示六张官方服务卡片与“自定义”，不带编程工具配置、流量代理、故障转移优先级或赞助排序。若存在多个配置，用“服务商 · 模型 · 地区”命名，方便辨认。

普通预设仅要求 Key；服务地址和模型提供可展开的编辑入口。百炼的新专属域名例外，需要地区和业务空间信息，或使用当前仍受支持的公共兼容端点。自定义预设要求完整协议根地址与模型 ID，显示最终请求地址以减少路径拼接错误。

“测试连接”应分项显示：认证/调用、日程结构、图片理解、测试时间；不能只有一个绿色圆点。CC Switch 的端点测速实现测量的是网络请求，而不是本产品的日程输出契约，因此不能直接将其测速成功作为验收。[^13]

CC Switch 使用 MIT 许可。若复用代码或实质性片段，应保留其许可证与版权声明；设计参考与实际复制应在 NOTICE 中区分。首版建议用 Swift 原生组件重建所需流程。[^14]

具体模型、地址与测试要求见[模型预设与有效性验证](provider-compatibility.md)。

## 5. 输入文件与多模态处理

### 5.1 当前输入路线与预算

按 UI 审阅前确认的方向，采用“上游多模态优先”。本地只做解码、方向规范化、缩放和 PDF 渲染，不做 OCR。

| 输入 | 当前处理 | 应用上限 | 失败处理 |
| --- | --- | --- | --- |
| 文字、TXT、MD | UTF-8 解码后直接交给模型 | 合计 2 万字 | 保留输入并提示缩小范围 |
| PNG、JPEG、HEIC、WebP | ImageIO 规范方向与缩略，重新编码 JPEG 后发送 | 单文件 20 MB、原图 8000 万像素；长边最多 2200 像素 | 不支持/超限单项提示 |
| PDF，包括扫描 PDF | PDFKit 将所选页渲染为图片，带文件名与页码共同提交 | 单文件 20 MB；每次最多 10 张图片/页面；初始选择前 5 页并显示页码范围 | 用户修改选页；加密文档要求先解锁 |
| DOCX、XLSX、PPTX、ICS、音视频 | 尚不支持 | — | 改用 PDF/TXT 或截图 |

一次最多 5 个附件；图像重新编码后合计最多 12 MB。上游实际限制可能更低，应以错误提示调整输入。预算属于应用限制，不等于厂商限制。

### 5.2 上游文件支持的边界

原生文件上传仍按服务商分别适配；存在 Files API 不代表任意 Chat Completions 模型都能接受 PDF。开发预览统一采用 PDF 转图，保留逐页视觉上下文。后续可加入已验证的上游 PDF 上传/提取路径，以减少图像成本。

图片与 PDF 在用户运行图片能力验证后才能提交。验证采用合成验证码图片；文字验证通过不自动意味着视觉能力通过。当前图片验证码测试不能替代真实 PDF 日程质量测试。

后续如需纯文本模型兼容、降低费用或离线提取，再考虑 Vision OCR；它不是首批依赖。原 Vision/PDFKit 资料仍作为后续技术参考。[^6][^7]

发送前展示服务名、域名和附件页码。不会暗中切换服务或将既有日历内容发送给模型。文件中的文字仅是数据，不授予模型执行程序、访问网址或写日历的权限。

## 6. 日程分析与排程逻辑

### 6.1 有边界的流水线

~~~mermaid
flowchart LR
    A[文字 图片 文件] --> B[输入规范化与 PDF 转图]
    B --> C[模型提取事件和约束]
    C --> D[结构和日期校验]
    D --> E[本地冲突检测与空档分配]
    E --> F[用户审核与补全]
    F --> G[应用执行日历写入]
    G --> H[本地回执]
    H --> I[系统负责 iCloud 同步]
~~~

模型负责理解语义，本地代码负责时区、约束、空档分配、权限、日历选择和实际写入。首版采用有限步骤的工作流，不需要通用 Agent 框架或 MCP。

请求上下文固定包含 referenceNow、IANA 时区、语言、周起始规则、默认时长、提醒偏好、输入来源时间和用户明确限制。一次分析跨越午夜时，继续使用该次请求冻结的 referenceNow；重新分析才更新时间基准。

### 6.2 日期规则

| 情形 | 规则 |
| --- | --- |
| “明天下午三点” | 以冻结的本地日期和时区解释；审核时显示完整日期与星期 |
| “下周三” | 按明确的周起始规则计算；UI 显示实际日期，允许修改 |
| 截图中的“明天” | 优先使用消息所示发送日期；日期看不清时询问，不默认成导入当天 |
| 只有“9 月 20 日” | 给出候选年份；临近跨年或可能是过去资料时需要确认 |
| “周三 9/18”与实际星期矛盾 | 标记来源冲突，阻止直接提交 |
| “下午开会” | 询问具体时间，不伪造 15:00 |
| 有开始时间、没有结束时间 | 可应用用户默认时长，例如 60 分钟，标记“采用默认时长” |
| 截止日期、没有时刻 | 单独标为截止项；询问具体时间，或由用户选择全天日历标记 |
| 跨午夜、跨时区出行 | 保存明确的出发/到达时区及时间；用真实时间点检查先后 |
| 全天事件 | 使用本地日期、日历时区与不包含结束日的区间，不先转成 UTC 零点 |
| 夏令时跳过/重复时刻 | 使用 Foundation Calendar/TimeZone 解析；不存在或有两种解释的时间必须提示 |
| 农历、法定调休、节假日前一天 | 首版要求确认公历日期；不能靠普通“工作日”规则代替官方调休表 |
| 重复事件 | 首版支持每天/每周、间隔与结束日期/次数；复杂规则暂留草稿 |

日期计算使用 Calendar 和 DateComponents，避免简单按 86400 秒推导“明天”。Apple 的 EventKit 示例也强调了夏令时相关问题。[^1]

缺失信息优先通过一处补充面板集中询问，只补缺失项；已经手工修改的字段不被重跑模型覆盖。模型自报的 confidence 只能作为排序提示，不能被当成准确率或直接落库资格。

### 6.3 固定事件与弹性任务

固定事件：照来源时间生成草稿，读取重叠的现有事件并提示，**不移动用户原有安排**。即使有冲突，用户可明确确认创建重叠事件。

弹性任务：先提取 duration、earliestStart、deadline、preferredWindows、priority、splittable。缺少时长就让用户补充或选择明确的默认值。首版不自动拆分，按截止时间、用户优先级和稳定排序分配空档；预留的缓冲时间可配置。

空档算法在设备上合并所选日历的忙碌区间，再从允许的工作/生活时间窗中扣除，按 15 分钟粒度寻找可容纳的区间。已标记空闲的事件不阻塞；全天事件默认阻塞当天，可由用户更改。无解时显示“本周没有足够空档”，不能偷偷越过截止时间或延长工作时间。

首版模型无需读取既有日历标题和描述，忙碌区间由本地代码处理。若后续引入语义排程，向模型发送日历内容应是单独可选功能。

## 7. 数据契约与应用结构

### 7.1 领域对象

| 对象 | 主要字段与用途 |
| --- | --- |
| InputBundle | app 生成的 ID、输入方式、文件摘要、页码、referenceNow、来源时间 |
| ExtractedItem | kind、标题、日期/时间或任务约束、来源引用、缺失字段、采用的默认值 |
| ResolvedDraft | 解析后的时间、目标日历引用、提醒、冲突、校验结果、revision |
| ImportBatch | 批次 ID、选中项目、确认版本、状态与各项结果 |
| CalendarWriteOperation | 操作 UUID、草稿版本、目标日历、指纹、阶段、写入回执 |
| ProviderConfig | 厂商/协议/地区/Base URL/模型/参数；Key 只存 Keychain 引用 |
| CapabilityRecord | 主机、模型、Key 配置版本、测试项目、结果、时间、适配器版本 |

模型只能返回 ExtractedItem；InputBundle、操作 ID、日历 ID、批准状态和写入状态都由应用产生。模型产出的“已批准”“已写入”字段应拒绝或忽略。

时间内容采用明确的变体：定时事件包含本地时间与 IANA 时区；全天事件包含 startDate/endDateExclusive；弹性任务包含时长与时间窗。解析后再生成内部 UTC 时间点，不允许混用缺少时区的字符串和 UTC。

完整示例见[event-plan.json](examples/event-plan.json)。后续实现应分别建立模型输出 Schema 和内部状态类型，不把整个数据库对象都交给模型填写。

### 7.2 校验层

第一层检查 JSON 完整性、字段类型、枚举、额外字段及数量上限；第二层检查日期、时区、开始/结束顺序、提醒范围和重复规则；第三层检查来源证据和必要字段；第四层检查当前权限、目标日历仍存在且可写、确认的 revision 没有过期。

所有厂商输出走相同的本地校验器。JSON Schema 能约束结构，也不能证明来源日期识别正确。无效输出最多做一次受限修复，再失败就保留原文和错误，不用正则强行截取一个可能不完整的对象。

### 7.3 模块边界

~~~text
App/
  AppLifecycle, MenuBar, Settings
Capture/
  QuickEntryPanel, AttachmentPicker, DraftState
Input/
  TextDecoder, ImageNormalizer, PDFRenderer
LLM/
  HTTPTransport, ProviderAdapter, CapabilityProbe
Domain/
  ScheduleSchema, TemporalResolver, DraftValidator, SlotAllocator
Calendar/
  PermissionService, CalendarRepository, ImportCoordinator
Storage/
  DatabaseMigrations, DraftRepository, OperationJournal, KeychainStore
Tests/
  Fixtures, ProviderContracts, TemporalCases, CalendarFakes
~~~

UI 更新在 MainActor；图像处理、PDF 渲染与网络在异步工作中执行。CalendarRepository 串行管理一个 EKEventStore，向其他模块传递不可变的领域快照，不跨隔离域传递可变 EKEvent。网络取消、草稿更新、确认、写入各有状态检查，防止旧请求结果覆盖新输入。[^1]

## 8. EventKit 与 iCloud 接入

### 8.1 正确连接路径

应用 → EventKit → macOS 系统日历数据库 → 系统账户同步 → iCloud → 用户其他设备。它不是应用自建的 iCloud HTTP API 客户端，也不是把应用数据库放入 CloudKit。

日历授权、账户登录和同步是不同环节。用户在系统设置中登录 Apple Account 并开启日历同步后，应用才能在 EventKit 中看到相关日历。不会要求用户提供 Apple ID 密码、应用专用密码或 iCloud Cookie。[^2]

### 8.2 权限策略

推荐为本产品的完整体验请求 requestFullAccessToEvents，并提供 NSCalendarsFullAccessUsageDescription，清楚说明“用于选择日历、检查时间冲突及撤销本应用创建的日程”。此权限在 macOS 14 起提供；本机 SDK 声明和 Apple 文档均已核对。[^1]

Write-only 无法读取日历列表、已有事件，也不能读取本应用自己添加的事件，因此不足以可靠实现指定 iCloud 日历、冲突检测、读回校验和跨会话撤销。若以后提供极简写入模式，只能面向系统默认日历并明确功能限制；不把它包装成完整模式。[^1]

权限被拒绝或运行中被撤销时，允许继续生成草稿，引导到系统设置，提交按钮显示具体原因。限制状态与普通拒绝状态分别处理。原生 macOS 不能直接套用仅面向 iOS/Mac Catalyst 的 EventKitUI 编辑控制器。[^1]

### 8.3 目标日历选择

使用 calendars(for: .event) 获取日历，按 EKSource 分组，展示来源名称、日历名称、颜色与可写状态。仅允许提交到可修改的事件日历。保存所选 sourceIdentifier/calendarIdentifier，下次使用前重新查找与验证。

不要把 sourceType == CalDAV 当成 iCloud 判断条件，也不要把名称包含“iCloud”作为可靠身份保证；其他服务也可能使用 CalDAV，来源名称可能变更或本地化。让用户在与系统日历一致的来源分组下明确选择目标；必要时对照系统日历确认。

首次可建议用户选择现有 iCloud 日历，或由用户主动创建专用“日程助手”日历。不要自动选择第一个可写日历，也不要在目标失效时静默改写其他日历。公开首版不默认写入多人共享日历。

### 8.4 写入、去重与结果不确定

推荐首版按事件逐条写入，每条独立回执，允许批次部分成功。使用 EventKit 的 save 功能可批量延迟提交，但它和本地 SQLite 之间不存在跨数据库事务，不能据此声称“完全原子、恰好一次”。[^15]

建议流程：

1. 冻结用户确认的草稿 revision、选中项、目标日历和提醒。
2. 在 SQLite 写入 prepared 操作记录和应用生成的 UUID；对同一操作 ID 加唯一约束。
3. 刷新近期事件和目标日历，重新检查冲突/相似事件；影响确认结果的变化回到审核。
4. 每条调用 EventKit 保存；notes 末尾写入短的操作标记，保留用户的会议 URL 不被占用。
5. 保存返回的事件标识并读回，核对标题、起止、日历和提醒，记录 written/verified 或需要核对。
6. 已完成项目不随整批重试；UI 显示“已添加 2 项，1 项需处理”。

崩溃可能发生在“日历已保存、本地回执未保存”的窗口。重启发现 prepared/writing 状态时，先用标识、操作标记和限定时间范围找回事件；结果不唯一或无法确认则提示核对，**不直接重复创建**。来源摘要/规范化内容指纹仅用于相似提示，不可把同名会议一律判重。

日历标识在完整同步后可能失效，Apple 对 calendarItemIdentifier 有明确说明。因此保留多种查找依据，但即使如此也不能保证跨应用编辑后的自动找回。[^16]

### 8.5 撤销与外部变更

撤销只针对本应用该批次创建的项目。删除前重新读取，对比已保存的字段摘要；若用户在系统日历中修改过、事件已进入共享/邀请流程或重复事件关系变化，展示变化后再让用户选择，不无条件删除。

订阅 EKEventStoreChanged 后使相应快照失效，去抖刷新必要的时间范围。通知不代表某个特定事件已经同步到云端。重复事件删除必须明确单次与后续系列范围；首版复杂系列撤销转到系统日历处理。[^17]

## 9. 提醒策略

使用 EKAlarm(relativeOffset:) 设置相对开始时间的提醒，例如提前 15 分钟为 -900 秒。提供“无提醒、开始时、5/10/15/30 分钟、1 小时、1 天、自定义分钟”，全局默认与单事件覆盖分别保存。首版 UI 最多两条提醒；是否成功保存以目标日历读回结果为准。[^18]

提醒优先级为：用户在审核页手动设置 > 来源中的明确要求 > 用户配置的默认值。全日事件单独提供“当天 09:00 / 前一天 18:00 / 自定义”策略，按事件时区计算，并在审核页显示实际提醒时间。

开始时间移动后，相对提醒跟随事件；全天绝对提醒在本应用编辑日期时重新计算。若用户随后在其他客户端修改事件，行为由客户端和日历服务决定，应列入兼容性验证。

事件已接近开始时间而某个提前提醒已在过去时，应提示移除或改为开始时提醒，不声称已经补发提醒。重复规则中的提醒和多个提醒的跨设备表现需要测试。

日程写入后，常规提醒由系统日历承担，应用不需要常驻一个定时器等待提醒，也不需要为同一事件再生成重复的本地通知。应用自己的“分析完成”通知是独立的可选项，只有启用它时才另行请求通知权限。

成功回执写“已添加到系统日历 · iCloud / 工作”，必要时附“跨设备同步由系统完成”；不写“iPhone 已同步”或“所有设备一定会提醒”。测试时应覆盖应用退出、Mac 睡眠、联网恢复及专注模式。

## 10. 隐私、存储与权限边界

### 10.1 数据去向

| 数据 | 默认去向 | 保留建议 |
| --- | --- | --- |
| API Key/敏感请求头 | 当前 Mac 的 Keychain | 删除配置时一并删除；默认不启用跨设备同步 |
| 厂商、模型、Base URL、偏好 | 本地数据库 | 用户可导出，默认排除所有凭证 |
| 原始附件 | 当前任务临时空间 | 任务结束后删除应用创建的副本；保留用户原文件 |
| 未完成草稿 | 本地数据库 | 默认保留 7 天，可选择不保留 |
| 导入回执 | 本地数据库 | 默认保留 30 天；删除后无法依赖记录撤销 |
| 日历事件 | 用户选择的系统日历 | 由该账户与用户自行管理 |
| 发给模型的内容 | 选定服务商 | 适用该服务的数据政策，应用不承诺供应商零留存 |

SQLite 默认不等于应用级加密。Keychain 保护密钥，草稿仍需要最小化保存，公共版隐私说明应明确本地存储与系统磁盘保护的边界。首版不保存完整模型思考内容，不把日历正文、附件和 Key 写入崩溃报告。

### 10.2 自定义端点

URL 使用系统解析器处理，仅支持明确的 HTTP(S) 语义；默认要求 HTTPS。高级设置可允许 loopback HTTP 作为本地模型地址，局域网明文连接需单独显示提醒。拒绝 URL 用户名密码、片段、凭证查询串和无法识别的协议。

API Key 绑定具体配置和主机。更换主机后原验证失效，复用 Key 前显示新目标；带凭证请求不跟随跨主机重定向，不自动降级为 HTTP。TLS 失败不提供“忽略证书”快捷开关。协议路径保留版本与代理前缀，不能统一补一个 /v1。

远程预设更新不应自动修改已有配置的主机，也不能引入脚本、可执行模板或远程提示词。首版将预设随应用发布；社区改动通过 PR 审阅。

### 10.3 系统权限

建议首版从 App Sandbox 与 Hardened Runtime 开始验证：网络出站、用户选择文件只读、日历访问是主要能力。Calendar entitlement 与实际 TCC 授权是两回事，二者都要配置。[^8]

拖入/选择的文件使用平台授予的访问范围；需要跨启动重开才保存安全作用域书签。只读本次选择的内容，不扫描桌面或下载目录。粘贴图片无需屏幕录制权限；主动截屏是后续独立功能，不能因此预先索取权限。

常规快捷键注册无需读全局键盘事件，不要求辅助功能或输入监控权限。应用级按键监听、全盘访问、通讯录和提醒事项权限都不在首版默认范围。[^5]

## 11. 风险、降级与决策

| 风险 | 产品影响 | 处理 |
| --- | --- | --- |
| 视觉识别错误或日期歧义 | 日程时间错误 | 来源定位、必要字段补全、完整日期预览 |
| 模型停止服务/模型名变化 | 用户突然不可用 | 能力记录版本化、失效提示、用户主动切换 |
| API 200 但结构错误 | 无法安全写入 | 结构与业务双重校验；有限修复 |
| 保存成功后进程崩溃 | 重复创建 | 操作日志、事件标记、先核对后决定 |
| 目标日历不可写/被删除 | 提交失败 | 提交前重新验证，保留草稿 |
| iCloud 同步延迟 | 其他设备暂不可见 | 区分本地写入与云端同步状态 |
| 全屏/输入法/多显示器异常 | 快捷入口不可用 | 第一阶段真机验证，菜单栏作为备用入口 |
| 开源安装门槛高 | 普通用户无法顺利运行 | 官方签名、公证 Release；文档提供源码构建路径 |

推荐立即采用的设计决策：macOS 14+、Swift 原生、菜单栏小窗口、BYOK、用户确认后落日历、EventKit 完整权限、六家官方按量 API 预设、上游视觉优先、后续有限排程、GitHub 开源公开发布。尚需开发验证的内容以[实施计划与发布验收](implementation-plan.md)为准。

## 12. 证据范围与来源

研究基准日：2026-09-12。结论区分了系统/厂商文档事实、根据工作负载作出的工程建议和待测指标。当前仓库无应用实现；已核对 Apple 文档及本机 EventKit SDK 声明、CC Switch 固定提交与六家厂商文档，另做了不带凭证的 API 路由探测。尚未请求用户日历权限、读写真实日历、使用付费 Key 推理或测量应用资源占用。

[^1]: Apple，[Discover Calendar and EventKit，WWDC23](https://developer.apple.com/videos/play/wwdc2023/10052/)，2023；框架、权限、时间计算与系统边界。访问于研究基准日。
[^2]: Apple Support，[Set up iCloud for Calendar on all your devices](https://support.apple.com/en-ca/guide/icloud/mme4d73a8727/icloud)，动态文档；账户、系统开关和设备同步条件。访问于研究基准日。
[^3]: Tauri，[What is Tauri?](https://v2.tauri.app/start/)，页面标注更新 2026-07-22；系统 WebView 与技术架构。
[^4]: Electron，[Introduction](https://www.electronjs.org/docs/latest/)，动态文档；打包 Chromium 与 Node.js。
[^5]: Sindre Sorhus，[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)，维护者文档；快捷键录制、权限与公开应用默认快捷键建议。
[^6]: Apple，[VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)，动态 API 文档；图片文字识别，正文通过官方 Markdown 端点核对。
[^7]: Apple，[PDFDocument](https://developer.apple.com/documentation/pdfkit/pdfdocument)，动态 API 文档；PDF 内容与分页。
[^8]: Apple，[Calendars entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars)，动态 API 文档；沙箱/运行时日历能力。
[^9]: Apple，[Keychain services](https://developer.apple.com/documentation/security/keychain-services)；GRDB 维护者，[GRDB.swift](https://github.com/groue/GRDB.swift)，本地密钥与 SQLite 封装的选型依据。
[^10]: Apple，[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)，动态 API 文档；macOS 13+ 服务与登录项管理。
[^11]: Apple，[nonactivatingPanel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)，动态 API 文档；面板不会激活所属应用的样式语义。
[^12]: CC Switch，[添加供应商](https://github.com/farion1231/cc-switch/blob/d695a2d77fd9081eafd3e9eedcbf2a97b3410928/docs/user-manual/zh/2-providers/2.1-add.md)、[ProviderPresetSelector](https://github.com/farion1231/cc-switch/blob/d695a2d77fd9081eafd3e9eedcbf2a97b3410928/src/components/providers/forms/ProviderPresetSelector.tsx)、[ModelInputWithFetch](https://github.com/farion1231/cc-switch/blob/d695a2d77fd9081eafd3e9eedcbf2a97b3410928/src/components/providers/forms/shared/ModelInputWithFetch.tsx)，固定提交源码。
[^13]: CC Switch，[speedtest.rs](https://github.com/farion1231/cc-switch/blob/d695a2d77fd9081eafd3e9eedcbf2a97b3410928/src-tauri/src/services/speedtest.rs)，固定提交源码；端点测速与推理测试的区别。
[^14]: CC Switch，[MIT LICENSE](https://github.com/farion1231/cc-switch/blob/d695a2d77fd9081eafd3e9eedcbf2a97b3410928/LICENSE)，2025 版权声明。
[^15]: Apple，[EKEventStore](https://developer.apple.com/documentation/eventkit/ekeventstore)，动态 API 文档；保存与提交。并核对本机 SDK 的 EKEventStore.h；跨存储事务限制为本方案工程分析。
[^16]: Apple，[calendarItemIdentifier](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier)，动态 API 文档；完整同步可能使本地标识失效。
[^17]: Apple，[EventKit](https://developer.apple.com/documentation/eventkit)，动态 API 文档；变更通知。并核对本机 SDK 的 EKEventStoreChangedNotification 注释。
[^18]: Apple，[EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm)，动态 API 文档；绝对/相对提醒与事件关联。
