# 模型预设与有效性验证

**六家候选服务均具备可接入的官方 API 路径，首版统一支持 OpenAI Chat Completions 兼容协议，并用厂商适配器处理参数差异。** 预设仅代表配置模板，不能代表某个用户的账户余额、模型授权或图片处理已经通过验证。

当前开发预览已实现上述预设编辑、真实文本契约测试与图片验证码测试。模板初始状态均为未验证；本机未提供付费 Key，仍不声称六家推理已实测。PDF 采用本机分页转图，不依赖统一文件上传接口。

## 1. 本次核验结果与证据等级

研究基准日为 2026-09-12。已读取厂商官方文档，并对下列六个 Chat Completions 地址发送不带 API Key、只含合成测试文本的请求。六家均返回 HTTP 401，证明从本次环境能够到达相应 HTTP 鉴权入口；这不能证明模型 ID 有效、付费调用成功或应用输出正确。

| 项目 | 本次完成情况 |
| --- | --- |
| 官方网站与文档地址核对 | 已完成 |
| Base URL、模型候选与图片输入文档核对 | 已完成；部分页面存在旧摘要，以下采用直接读取的正文 |
| 无密钥端点连通探测 | 六家均得到 401，保留原始记录 |
| 带有效 Key 的文本推理 | 未执行 |
| 实际日程 Schema / 图片 / 多页 PDF 场景 | 未执行 |
| 不同地区、套餐和模型可用性 | 需使用对应账户实测 |

证据文件：[endpoint-reachability.json](research/endpoint-reachability.json)、[source-checks.json](research/source-checks.json)。前者记录 2026-09-12 14:18 左右（上海时区）的匿名路由探测；后者记录文档请求地址、重定向结果与正文哈希。哈希仅标识当时获取的字节，不是完整文档归档或推理成功凭据。

## 2. 六家官方预设

以下模型均是**待实测的初始候选**，不是性能排名。官方文档显示支持图片，不等于模型适合中文课表和日期提取；应按第 5 节评测后决定默认模型。

| 服务商 | Base URL | 首选测试模型 | 图片路径 | 关键差异 |
| --- | --- | --- | --- | --- |
| DeepSeek | https://api.deepseek.com | deepseek-flash | 当前 Flash 文档支持图片；直接提交视觉模型 | 当前直读文档已更换 Flash 别名；JSON Object 不等于严格 Schema |
| MiniMax 中国站 | https://api.minimax.cn/v1 | MiniMax-M3 | M3 支持 image_url；不把 M2.x 自动标为支持图片 | 当前文档从旧 minimaxi 站点跳转；thinking 与 reasoning_split 独立 |
| Kimi 中国站 | https://api.moonshot.cn/v1 | kimi-k2.6；kimi-k3 作为另一候选 | 两者官方文档均列为多模态 | K2.6 可关思考；K3 与 K2.6 参数、Schema 能力不同 |
| 智谱 BigModel 中国站 | https://open.bigmodel.cn/api/paas/v4 | glm-5.3-flash | 当前文档支持 image_url、Base64 | 该模型只支持开启思考；不能一律发送 disabled |
| 阿里云百炼北京 | https://dashscope.aliyuncs.com/compatible-mode/v1 | qwen3.8-flash | 当前视觉文档列出支持 | 公共旧域名仍获支持；优先引导填写业务空间专属新域名；Key 与地区匹配 |
| 小米 MiMo | https://api.xiaomimimo.com/v1 | mimo-v2.5 | 官方图片文档支持 URL / Base64 | 官方名称是 MiMo；按量 API 与 Token Plan 是不同入口/Key |

对应官方来源：DeepSeek 首次调用与视觉文档；MiniMax 兼容文档；Kimi 模型、参数与 API 概述；智谱模型与兼容文档；百炼兼容与视觉文档；MiMo 图片与接口文档。[^1][^2][^3][^4][^5][^6][^7][^8][^9][^10][^11][^12][^15]

### 2.1 需要特别防止的过期预设

- **DeepSeek**：搜索摘要仍可能显示 deepseek-v4-flash / deepseek-v4-flash-vision-exp。直接读取的官方首次调用页面改为 deepseek-flash，并说明旧名称被路由到新的 Flash 模型。因此新预设采用当前别名，同时将后台路由可能变化作为维护事项。[^1]
- **MiniMax**：直接打开旧官方文档地址跳转至 platform.minimax.cn，当前兼容示例使用 api.minimax.cn 与 MiniMax-M3。旧 M2.x 的纯文本结论不能套用到 M3；旧 Key 是否可跨新域名使用仍应由用户测试。[^3]
- **Kimi**：当前模型列表明确标记 kimi-k2.5 和 moonshot-v1 系列已于 2026-08-31 下线，不应照抄老教程或参考项目中的旧预设。[^4]
- **智谱**：当前官方索引和模型页面已列出 GLM-5.3-Flash，不应仅凭旧搜索摘要指定 GLM-4.6V；是否保留旧模型由实际可用性决定。[^7]
- **百炼**：北京专属新地址形如 https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1。官方说明现有公共域名仍可使用。本方案用公共地址完成匿名探测；专属域名需要真实业务空间，不把占位符当成开箱即用配置。[^9]

不能把“兼容 OpenAI”解释成“所有参数一致”。它只说明存在可兼容的协议面；模型端的思考参数、图片块、输出约束、错误类型和地区规则仍需适配。

### 2.2 普通 API 与编程套餐

首版官方预设仅面向按量付费的开发者 API。消费端聊天会员、Coding Plan、Token Plan 可能拥有不同 Key、域名、支持工具和适用范围，不预先宣称可以在日程助手中通用。

以小米为例，官方文档区分按量入口 api.xiaomimimo.com 与 Token Plan 入口 token-plan-cn.xiaomimimo.com。技术上可连接不等于套餐允许该应用场景；将套餐纳入预设前需要检查当时的使用说明及实际调用，首版不默认纳入。[^13]

## 3. 预设、配置与能力记录

### 3.1 三类对象分开保存

| 对象 | 内容 | 生命周期 |
| --- | --- | --- |
| ProviderPreset | 厂商 ID、名称、地区、协议、Base URL 模板、候选模型、官方文档 URL、文档核对日期、适配器类型 | 随版本发布，无 Key |
| ProviderConfig | 用户名称、实际地址、选定模型、Keychain 引用、自定义参数、用户选择的图片服务 | 用户控制；升级不覆盖手动值 |
| ValidationResult | 配置版本摘要、模型、主机、测试项目、结果、时间、脱敏错误和适配器版本 | 每次验证产生；配置变更后失效 |

能力采用四态：documented、verified、unsupported、unknown；运行中故障用单独 health 状态记录，不把一次超时永久改成 unsupported。Key 更新、模型切换、主机改变、重要适配器变更时，之前的验证不能继续显示为当前配置有效。

不要保存 Key 明文或可关联的普通 Key 哈希作为检测键。使用本地 credentialVersion UUID；更新 Key 时生成新版本，Keychain 保存实际凭证。

### 3.2 配置面板

默认字段：服务商、API Key、模型、测试按钮。地区字段只在相关服务显示；Base URL、超时和模型参数置于高级设置。列表状态示例：

~~~text
DeepSeek · deepseek-flash
文本日程：通过    图片：未测试
上次测试：今天 14:30    [设为默认] [编辑]

自定义服务 · my-model
调用失败：模型不存在或当前账户未开通
[修改模型] [重新测试]
~~~

“获取模型”调用该预设配置的模型列表端点。如果返回 404/405 或没有兼容结果，继续允许用户填写模型 ID。列表缺失不表示推理端点不可用，列表中出现也不表示账户一定能执行该模型。

### 3.3 URL 拼接规则

存储的 Base URL 是“协议根路径”，只移除末尾多余斜杠，再追加 /chat/completions。不能用绝对路径拼接 API 把代理前缀覆盖掉。

| 输入 | 最终 POST 地址 |
| --- | --- |
| https://api.deepseek.com | https://api.deepseek.com/chat/completions |
| https://api.moonshot.cn/v1/ | https://api.moonshot.cn/v1/chat/completions |
| https://open.bigmodel.cn/api/paas/v4 | https://open.bigmodel.cn/api/paas/v4/chat/completions |
| https://gateway.example.org/team/a/v1 | https://gateway.example.org/team/a/v1/chat/completions |

如果用户粘贴完整的 /chat/completions 地址，UI 识别后展示“将使用此完整地址”或提供清晰的规范化结果，不能再重复追加路径。对 /responses 和 /messages 地址提示当前协议不匹配，而非自动改到另一个接口。

首版自定义兼容协议只承诺 Chat Completions + Bearer；需要原生 Anthropic、Responses、Azure 特殊鉴权的服务放到后续适配器，不用一个“自定义”标签掩盖未支持的协议。

## 4. 请求与响应适配

### 4.1 共用传输层

共用功能：HTTPS、请求取消、超时、响应体大小上限、HTTP 状态归一化、脱敏日志、用量提取与可选 SSE 解析。请求头默认 Content-Type: application/json 和 Authorization: Bearer；MiMo 文档同时提供 api-key 形式，可由专用适配器支持，首版统一 Bearer 即可。[^12]

界面只展示最终日程和简短状态，不展示模型思考过程。若内部采用 SSE，应正确处理跨数据块的 UTF-8、空 choices、单独 usage 块、多个 data 片段与结束标志；未结束或被截断的 JSON 不能变成可提交草稿。

首版可先采用非流式请求跑通契约；只有等待体验或某个模型需要时再使用 SSE。超过合理等待时间显示仍在处理和取消入口，不能把“没有输出 token”直接视为失败。

### 4.2 参数差异

| 适配器 | 初始策略 | 不应采用的统一假设 |
| --- | --- | --- |
| DeepSeek | 对简短日程测试 thinking.disabled；JSON Object；解析最终 content | 将旧模型别名永久写死；把 JSON Mode 当成无空输出保证 |
| MiniMax M3 | 测试 thinking.disabled；reasoning_split 用于分离思考；按文档解析最终答案 | 将 reasoning_split 当成关思考；M2.x 也能关思考或读图片 |
| Kimi K2.6 | 可测试关闭思考；避免覆盖受限 temperature/top_p；简化 Schema | 任意参数都接受；复杂 Schema 在所有模型上同样稳定 |
| Kimi K3 | 单独能力记录，按文档的思考/推理强度规则调用 | 将 K2.6 的 disabled 参数照搬 |
| GLM-5.3-Flash | 保留思考；JSON Object 能否用于该模型以实测为准 | 每个 GLM 都能关思考；Flash 名字意味着不消耗思考 token |
| Qwen | 按确切模型验证 enable_thinking 和 json_schema/json_object | 所有千问或所有地区都支持相同格式 |
| MiMo | 按文档测试 thinking.disabled；结构化输出参数单独验证 | Pro 与多模态型号等价；能接收客户端文件路径 |

DeepSeek 官方 JSON 文档说明可能出现空内容；Kimi 当前文档区分不同模型的 Schema 支持；MiniMax、智谱和 MiMo 对思考的规则也不同。业务校验器应独立于这些差异。[^14][^5][^6][^3][^7][^12]

### 4.3 结构化输出降级

每个模型先选择**文档支持且实测通过**的输出方式：严格 JSON Schema 优先，其次 JSON Object，再其次有限的纯 JSON 提示。模型对工具参数的支持成熟时，可以使用“返回草稿”的工具调用格式，但工具仍只是数据返回协议，不会直接修改日历。

支持矩阵不明时初始状态为 unknown。探测 400 且错误明确指出可选字段不支持，才允许降一级重新测试；401、余额不足、地域错配、无效模型、超时不触发盲目参数降级。

本地对所有返回执行相同 Schema 与日期校验。若第一次结果只有结构错误，最多一次受限修复；不要创建无上限 Agent 循环。一次分析的总请求数上限建议为 3，参数降级、网络重试与结构修复共用这个上限，不能各层分别重试后叠加。跨服务商降级需要用户明确选择，避免输入被发送给用户没有选中的服务。

## 5. “有效性验证”的产品实现

验证按钮应解释“会发送一段测试内容，可能产生少量 API 费用”；只发合成数据，不读取真实日历或附件。默认一次完整文本验证，图片验证为显式的附加测试，最多 3 次模型请求，修复请求计入上限。

### 5.1 分层验证

| 层 | 方法 | 能证明什么 |
| --- | --- | --- |
| L0 配置校验 | URL、模型非空、Key 非空、协议与地区字段 | 配置格式具备发请求条件 |
| L1 网络与 HTTP | 实际推理请求能建立 TLS/HTTP；解析状态 | 到达哪个域名及 HTTP 层错误 |
| L2 带 Key 调用 | 使用所选模型发送固定小任务 | 当前账户当前配置能进行这次调用 |
| L3 日程契约 | 固定 referenceNow，提取指定日期/时区/时长/提醒 | 应用需要的结构与关键语义正确 |
| L4 图片能力 | 合成图片中放置仅图片包含的随机数字与时间，检验提取值 | 目标模型实际接收并理解了本次图片 |
| L5 业务回归 | 多样本中文日程/截图/排程测试 | 对本产品场景的质量与限制有量化证据 |

L1 不另做一轮付费“Hello”，可与 L2/L3 共用请求。HTTP 200 但返回 HTML、空 choices、空 content、finish_reason=length、拒答或不完整 JSON，都不能显示“日程可用”。

文本探测示例：冻结时区 Asia/Shanghai、referenceNow=2026-09-12T10:00:00+08:00，输入“2026 年 9 月 14 日 15:00 到 16:00 组会，提前 10 分钟提醒”。校验标题语义、起止时间和提醒偏移 -600 秒。再用独立回归用例检验“明天”“下周”和歧义，而不是以一个样本推出整体准确。

图片测试不能把答案同时写在文本提示里，否则文本模型也可能“通过”。测试图片包含随机码、日期和时刻；文本只要求提取。预设开箱状态最多是“文档支持图片”，通过对应配置的 L4 后才显示“图片测试通过”。

### 5.2 错误分类与用户动作

| 情形 | 界面信息 | 自动处理 |
| --- | --- | --- |
| 401/403 | 检查 Key、所属地区、账户权限或套餐入口 | 不重试，不自动换域名 |
| 404/模型不存在 | 显示请求地址与模型 ID，提示检查路径/模型授权 | 保留配置，可手填模型 |
| 400/不支持字段 | 标明具体字段和模型 | 明确可选字段兼容问题时，受限降级一次 |
| 余额/配额不足 | 提示在对应服务商控制台处理 | 不做无效重试 |
| 429 | 显示限流，尊重 Retry-After | 在用户请求总时限内最多一次退避重试 |
| 5xx/网络临时异常 | 区分上游错误与本地网络 | 推理最多一次有限重试；提示可能已产生费用 |
| TLS/证书错误 | 提示地址或网络配置问题 | 不关闭证书验证 |
| 200 但结构不符 | “已连通，但日程输出验证未通过” | 最多一次结构修复 |
| 取消/超时 | 保留输入，允许用户稍后重试 | 取消不保证上游未计费 |

HTTP 403 不必然是 Key 错误，404 不必然是 Base URL 错误；读取厂商错误对象并保留脱敏的 request ID。正常操作的日历写入不采用以上网络重试规则，结果不确定时走日历核对流程。

### 5.3 选择默认模型的评测

使用同一套合成/授权脱敏样本、冻结时间与时区；每个候选执行同样配置和样本。记录严格日期正确率、关键字段准确率、应澄清样本命中率、虚构事件率、草稿校验成功率、P50/P95 完整等待时间、实际 token 用量与估算成本。

不按厂商综合排行榜直接选择。普通文本优先比较延迟和关键字段正确率，图片优先比较日期与版式关系正确率；可以一个模型统一处理，也可以用户显式选择第二个图片模型。默认模型必须来自实测；本次提供的是测试顺序和候选，不给未经测量的“最佳”结论。

## 6. 预设持续维护与开源贡献

预设随版本发布，记录 docsCheckedAt、adapterVersion、testedModelId、testedRegion 和 testSuiteVersion。模型列表可手动刷新；不在应用后台定期调用所有用户 Key。

新增服务商 PR 必须附官方文档、协议根地址、候选模型、必要参数、地区/套餐限制、无密钥 fixture 与测试说明。维护者用自己的测试 Key 执行带预算的验收；不得要求贡献者提交 Key、完整账单或真实日历内容。

每次发布前复查六家的官方模型页和升级提示。失效模型从新建列表移除，已有用户配置显示迁移提示，但不自动换厂商、主机或更贵模型。若未来做远程预设更新，需要签名、版本锁定、回滚与主机变更确认；首版不引入此复杂度。

## 7. 成本设计

用户的模型请求直接发往自己配置的服务，费用归对应 API 账户。应用可以根据响应 usage 和日期明确的单价估算，但不能把本地估算当作账单。

通用估算式：单次费用 = 输入 token × 输入单价 / 1,000,000 + 输出 token × 输出单价 / 1,000,000，再按服务商规则计入思考、图片、缓存或其他费用。以“输入 2,000、输出 600，假定每百万分别 1 元和 4 元”为算例，费用为 0.0044 元；这是算术示例，**不是任何厂商报价**。

首版限制请求大小、候选事件数、思考预算和修复次数；复杂文件先让用户选页。默认不启用搜索、代码执行或服务商内置收费工具。显示每次实际返回的 usage；缺失时写“不可用”，不显示为 0。

## 8. 官方来源

以下均于研究基准日核对；动态文档若无明确发布日期，以访问日期为准。部分正文通过官方 .md 端点直接读取，链接同时保留便于人工查看的文档入口。

[^1]: DeepSeek，[Your First API Call](https://api-docs.deepseek.com/)，当前 Flash 别名与协议根地址；直接正文与旧搜索摘要存在版本差异。
[^2]: DeepSeek，[Vision](https://api-docs.deepseek.com/guides/vision/)，当前模型图片能力与内容块格式。
[^3]: MiniMax，[OpenAI SDK](https://platform.minimax.cn/docs/api-reference/text-openai-api)，M3、端点、图片与思考参数；旧官方地址重定向至此。
[^4]: Kimi，[模型列表](https://platform.kimi.com/docs/models)，核对正文 [models.md](https://platform.kimi.com/docs/models.md)；当前模型与下线信息。
[^5]: Kimi，[模型参数参考](https://platform.kimi.com/docs/api/models-overview)，核对正文 [models-overview.md](https://platform.kimi.com/docs/api/models-overview.md)；K3/K2.6 思考与采样限制。
[^6]: Kimi，[使用 response_format 控制模型输出格式](https://platform.kimi.com/docs/guide/response_format)，核对正文 [response_format.md](https://platform.kimi.com/docs/guide/response_format.md)；JSON Object/Schema 与模型差异。
[^7]: 智谱，[GLM-5.3-Flash](https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash)，核对正文 [.md](https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash.md)；模型 ID、多模态与思考规则。
[^8]: 智谱，[OpenAI API 兼容](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction)，核对正文 [.md](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction.md)；协议根地址与认证。
[^9]: 阿里云，[OpenAI Chat 接口兼容](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)，地区、业务空间专属域名与旧域名兼容说明。
[^10]: 阿里云，[视觉理解](https://help.aliyun.com/zh/model-studio/vision-model)、[结构化输出](https://help.aliyun.com/zh/model-studio/qwen-structured-output)，Qwen3.8 与不同模型系列能力。
[^11]: 小米，[图片理解](https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/multimodal-understanding/image-understanding)、[MiMo-V2.5 模型](https://mimo.mi.com/models/zh-CN/mimo-v2.5)，图片传入方式与支持型号。
[^12]: 小米，[OpenAI API](https://mimo.mi.com/docs/zh-CN/api/chat/openai-api)，认证、思考、采样和消息格式。
[^13]: 小米，[工具接入概览](https://mimo.mi.com/docs/en-US/tokenplan/integration/tools-overview)，按量 API 与 Token Plan 的凭证区别；本方案不据此推定所有套餐授权范围。
[^14]: DeepSeek，[JSON Output](https://api-docs.deepseek.com/guides/json_mode/)、[Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)，JSON 模式、空内容限制与参数。
[^15]: Kimi，[API 概述](https://platform.kimi.com/docs/api/overview)，Chat Completions 地址、Bearer 认证和模型列表端点。
