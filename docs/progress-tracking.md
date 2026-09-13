# JSON-RPC 2.0 框架进度追踪

## 组织名配置

所有模块使用 `ystyle` 组织名：
- cjpm.toml: `organization = "ystyle"`
- 源码 package 声明: `package ystyle::jsonrpc`
- 源码 import: `import ystyle::jsonrpc.*`
- 依赖声明: `"ystyle::jsonrpc" = "0.1.0"`

**重要发现**：cjpm 使用 `::` 分隔组织名和包名，源码 package 声明也需使用相同格式（不同于仓颉规范中的 `.` 分隔符）。

## 已完成

### 核心库 (jsonrpc)
- ✅ Request/Response/Notification 类型定义
- ✅ RequestId (Int/String) 类型，支持 Hashable 和 Equatable
- ✅ JsonRpcError 错误类型
- ✅ Message 枚举（单请求/批量请求等）
- ✅ parseMessage 消息解析函数
- ✅ serialize/deserialize 序列化函数
- ✅ Content-Length 分帧编码/解码 (encode/decode)
- ✅ JsonRpcServer 服务器类（中间件洋葱模式）
- ✅ JsonRpcClient 客户端类（异步调用、通知）
- ✅ HandlerContext/HandlerResult 处理器上下文
- ✅ Transport 接口（继承 Resource）
- ✅ JsonRpcException 异常类
- ✅ PendingRequest 等待响应类

### 传输层
- ✅ StdioTransport（标准输入输出）
- ✅ TcpClientTransport（TCP 客户端）
- ✅ TcpServerTransport（TCP 服务端监听）
- ✅ TcpConnectionTransport（TCP 服务端连接）
- ✅ UnixClientTransport（Unix 套接字客户端）
- ✅ UnixServerTransport（Unix 套接字服务端）
- ✅ UnixConnectionTransport（Unix 服务端连接）

### 测试
- ✅ FramingTest（编码解码，3个用例，含 consumed 精确消费）
- ✅ RequestIdTest（ID 类型，3个用例）
- ✅ RequestTest（请求序列化）
- ✅ ResponseTest（响应序列化，2个用例）
- ✅ NotificationTest（通知序列化）
- ✅ ErrorCodesTest（标准错误码）
- ✅ MessageParseTest（消息解析，6个用例）
- ✅ JsonRpcValidationTest（jsonrpc 字段验证，5个用例）
- ✅ BatchInvalidItemTest（批量错误项处理，2个用例）
- ✅ FramingConsumedTest（多帧堆积处理，3个用例）

### 分帧修复
- ✅ decode() 返回 `?(body, consumed)` tuple，支持精确消费
- ✅ server/client receiveLoop 用 ByteBuffer.seek() 替代 clear()
- ✅ stdio 改用原始字节读取替代 readln()
- ✅ 服务端半帧累积不再丢弃

### HTTP 传输重写
- ✅ HttpClientTransport.send() 保存 POST 响应到队列
- ✅ HttpClientTransport.receive() 从队列取出响应
- ✅ 响应用 encode() 重新 Content-Length 分帧

### JSON-RPC 合规修复
- ✅ Request/Response/Notification fromJson 验证 `"jsonrpc": "2.0"`
- ✅ parseMessage 验证 jsonrpc 版本
- ✅ 解析错误返回 -32700，非法请求返回 -32600
- ✅ 批处理无效项返回 InvalidRequest 错误
- ✅ Response.id 改为 ?RequestId 支持 null id
- ✅ Response 构造函数校验 result/error 互斥
- ✅ JsonRpcException 接入解析路径（替代泛型 Exception）
- ✅ Notification 使用 `"__notification__"` 替代 `Int(0)` 避免误导

## 关键经验记录

### 仓颉语法要点
1. `Unit` 类型写法是 `()`，不是 `Unit`
2. 包导入用 `.` 分隔：`std.collection.concurrent.*`
3. Duration 构造：`30 * Duration.second`
4. String 切片用 `[]` 操作符 + Range：`str[16..]`
5. String trim 用 `trimAscii()`
6. Int64.parse 返回 Int64（会抛异常），Int64.tryParse 返回 Option<Int64>
7. ConcurrentHashMap 用 `add()` 替代已废弃的 `put()`
8. Enum 成员名不能和类名冲突（如 Message.Request 和 Request 类）

### Workspace 测试配置
1. workspace 项目测试需要单独的测试包（output-type = "executable")
2. 测试包需要加入 build-members 和 test-members
3. 测试包需要导入 `std.unittest.*` 和 `std.unittest.testmacro.*`
4. 测试文件名需要以 `_test.cj` 结尾

### 编译器限制
1. init 中不能在所有成员初始化前调用成员函数（如 receiveLoop）
2. 需延迟启动接收线程（提供 start() 方法）

### 并发正确性
1. 「**单个槽位 + 固定 id**」是并发双向请求的必炸模式：覆盖式写入会丢响应，按「当前槽」投递会串台。
   正确做法是**按 JSON-RPC id 的等待表**（`HashMap<RequestId, PendingRequest>`）+ 自增 id +
   响应按 id 查表投递。mcp-cj 的 HTTP 传输（2026-09-12，单槽位改按 id 的 FIFO 等待队列）与
   json-rpc 的服务端主动请求（2026-09-13，单挂起槽改等待表）是同一模式的两处修。
2. 调用方为绕开「只能有一个在飞」而加的串行锁，会在长等待时变成吞吐瓶颈（锁横跨整个往返）；
   底层配对修好后应把这类锁撤掉。
## v0.5.0（2026-08-15）

### 新增：通知回调多订阅（JsonRpcClient）
- `setNotificationCallback(cb)` 单回调覆盖（原语义不变，向后兼容）
- `setNotificationCallback(cbs)` 多回调覆盖（重载）
- `addNotificationCallback(cb)` 追加
- 内部改为 `ArrayList<NotificationCallback>`，接收循环遍历调用全部
- 驱动方：cordis-cj 事件总线需要 log 与 events/emit 独立注册（原单回调覆盖导致丢失）

### 发版
- jsonrpc 及 5 个传输包统一 0.5.0，传输包依赖升级到 jsonrpc 0.5.0
- jsonrpc_tests 不发中心仓，改用 path 依赖（引用未发布核心包场景）

### 测试
- 新增 NotificationCallbackSemanticsTest 4 用例（覆盖/多覆盖/追加/同通知全回调）
- 共 39 用例全通过

### 踩坑
- workspace 内跨包版本号依赖：当目标版本未发布到中心仓时，cjpm 测试包解析失败 → jsonrpc_tests 用 path 依赖
- cjpm 本地索引缓存（~/.cjpm/repository）只读时无法刷新新版本 → 需可写环境执行 `cjpm update` 后再发依赖包
- 发版顺序：核心包先发，传输包依赖它 → 必须先发 jsonrpc 再发传输包

## v0.6.0（2026-08-15）

### 新增：异步处理器 registerAsync（JsonRpcServer）
- `registerAsync(method, handler: AsyncHandler)`，`AsyncHandler = (HandlerContext, (JsonValue) -> Unit) -> Unit`
- handler 在接收线程调用但约定**内部 spawn 异步任务后立即返回**；接收线程不阻塞，可处理嵌套请求的响应
- 解决"handler 内再发同步请求（如 @Inject 代理调用远程服务）的单线程事件循环死锁"
- 驱动方：cordis-cj @Inject 宏（服务代理跨插件调用）

### 发版
- jsonrpc 及 5 个传输包统一 0.6.0
- jsonrpc_tests 不发中心仓，path 依赖本地核心包

### 测试
- 新增 AsyncHandlerTest 2 用例（spawn+complete、嵌套请求转发不死锁）
- 共 41 用例全通过
- mcp-cj 集成测试验证：切本地 jsonrpc 后 testclient 全过（零破坏）

### 踩坑
- async handler 的 handleRequest **不能自己 spawn**（那样 handler 仍在接收线程被调用阻塞）——必须约定 handler 内部 spawn 异步任务，handleRequest 直接调用 handler 立即返回
- 测试中 spawn 内 sleep 后 complete 曾偶发超时；嵌套请求用例（client.call）更贴近真实场景且稳定

## v0.7.0（2026-08-16）

### 新增：gjson 快速路由 + 流式直连反序列化
- `message.cj` 重写：
  - `serialize*/deserialize*` 改为 `JsonWriter`/`JsonReader` 流式直连，去掉 jsonvalue DOM 中转
    （原实现是 写→DOM→写 / DOM→序列化→重解析 的 3 遍扫描；实测 4.8KB 消息读侧 404µs→153µs，写侧约 2 倍提速）
  - `parseMessage` 用 gjson 顶层浅扫描分类：`validBytes` 语法校验 + `method`/`id`/`result`/`error` 存在性判定，
    命中类型后直接调现有 `fromJson(JsonReader(ByteBuffer(bytes)))` 流式反序列化，不建 DOM
  - 批量：`parseBytes(bytes).array()` 一次扫描取各元素 raw（避免逐索引重复全量扫描），逐项流式解析
- `server.cj`：
  - `handleMessage` 增加快速路由：**无中间件时**，单条对象消息 method 未注册 → 用 gjson 取 method/id 直接回 -32601，
    不解析完整 JSON（params 零触碰；大整数 id 用 raw 重建，不丢精度）
  - `sendBatchResponse` 改 `JsonWriter` 流式写出（去掉 JsonValue.Array DOM 组装）
- jsonvalue 降级为纯值类型（params/result），协议解析全程至多一次 json→JsonValue（仅 params 子树），未知方法零触碰
- 依赖：jsonrpc 新增 gjson

### 行为变化（有测试固定）
- 尾随垃圾（`{"a":1} x`）从"静默忽略"改为 -32700（validBytes 严格校验）
- 大整数 id（>2^53）精度修复：9007199254740993 不再被解析成 9007199254740992（原 jsonvalue Float64 DOM 往返丢失）
- `method:null` / `method:123` 被 stdx `readValue<String>` 宽容转换为 "null"/"123"（新旧路径一致的既有语义）

### 测试
- 新增 LargeIdPrecisionTest 3 用例、ParseErrorSemanticsTest 6 用例、FastRouteTest 6 用例
- 共 57 用例全通过（41 原有 + 16 新增）

### 踩坑 / 依赖
- **发现 gjson-cj `validBytes` 对多元素数组误判非法**：`validarray` 在 `validcomma` 返回逗号位置后未前进，
  `[1,2]` 被判 false → 已在 gjson-cj 修复（状态机重写）并新增 `valid_test.cj`（9 用例），合入 gjson-cj master
- gjson-cj 发版 1.2.1（bump + tag + 中心仓 publish），jsonrpc 依赖改回注册表 `"gjson" = "1.2.1"`

### 发版
- jsonrpc 及 5 个传输包统一 0.7.0，传输包依赖升级到 jsonrpc 0.7.0
- 全部包补充 authors 字段（此前缺失）
- jsonrpc_tests 不发中心仓，path 依赖本地核心包

## v0.7.1（2026-08-19）

### 修复：JsonRpcClient 请求处理异步化（跨连接死锁）
- `client.cj` 的 `handleIncomingRequest` 由同步执行改为 `spawn` 独立线程：
  - **修复跨连接死锁**：请求 handler（如宿主转发其他插件服务）可能阻塞等待响应，同步执行会占用
    接收线程 → 本连接的其他消息（如事件派发响应）无法读取，两个连接互相等待超时
    （harness Phase 2：agent 等 llm invoke 响应 ↔ 宿主等 agent 的 dispatch 响应）
  - **新增异常响应**：handler 抛异常时回 `-32603 Internal error`（修复前异常被 `handleMessage`
    外层 catch 吞掉，请求方永远等不到响应直接超时）
- 纯内部实现改动，公共 API 无变化（`registerRequestHandler` 签名不变）

### 测试
- 新增 `ClientAsyncHandlerTest` 2 用例：
  - `testHandlerErrorReturnsInternalError`：client 收到请求 handler 抛异常 → server.request 收到 -32603
  - `testNestedCallNoDeadlock`：client 收到请求后 handler 内同连接嵌套 `call` 不死锁
- 共 59 用例全通过（57 原有 + 2 新增）

### 发版
- jsonrpc 及 5 个传输包统一 0.7.1，传输包依赖升级到 jsonrpc 0.7.1
- jsonrpc_tests 不发中心仓，path 依赖本地核心包

### 下游验证（AGENTS.md 新增规范）
- AGENTS.md 新增：**json-rpc 修改（含发版前）必须同时运行 mcp-cj 和 lsp-cj 的测试**
- mcp-cj：path 依赖本地 jsonrpc 编译通过 + test_e2e.sh（stdio 双工交互）CLIENT_EXIT=0
- lsp-cj：4 子包 path 依赖本地 jsonrpc，lsp_tests 34/34 全绿（含 LspServerOutboundRequestTest——client 收到请求的新异步路径）
- 验证后恢复下游 cjpm.toml 注册表依赖（均为 0.4.2）

### 踩坑（E2E 在沙箱环境运行）
- 原 test_e2e.sh 用 FIFO 依赖 /tmp，沙箱下 /tmp 跨命令不隔离 → 改 workspace 内 FIFO
- FIFO 先读先写互相等待会死锁（server `< c2s` 阻塞等写端 ↔ client `< s2c` 阻塞等写端）：
  需先 `exec 8<>s2c` / `exec 9<>c2s` 预打开两端再启动进程
- 调试脚本路径用绝对路径 + `cd`（bash 工具 cwd 不在目标仓库）


## v0.7.4（2026-09-02，忆时塔 OOM 挂起修复）

### 修复：receiveLoop 边界捕获系统级 Error —— OOM 不再杀接收循环协程
- 背景：忆时塔（chronomem）写满 memtable 触发 flush 时 OOM，`OutOfMemoryError` 是
  `Error` 层级（与 `Exception` 平行，非子类），`receiveLoop` 原只 `catch (e: Exception)`
  → Error 逃逸杀接收循环协程 → 所有请求 30s 超时 = MCP 永久挂起（需重启恢复）。
- `server.cj` receiveLoop 两处兜底：
  - `handleMessage` 调用点：`catch (e: Error)` 只打印 `[jsonrpc] handleMessage system error`
    后继续循环（与 Exception 同级语义：坏消息跳过，不杀服务器）
  - 外层 `match transport.receive()`：`catch (e: Error)` 兜底 receive/缓冲写入路径
- 设计取舍：仓颉规范 Error 属系统级、不应被业务层吞掉（runBatch 仍不吞）——但接收循环
  是服务存活性边界，Error 逃逸 = 永久停机，此处只记录不退出（xisp/cjxt 同款先例）。
- 注：OOM 本体由 badger-cj v1.6.13 的 WritePipeline.loop Error 边界 + 忆时塔内存
  优化解决；jsonrpc 本修复保证即便有系统级错误也不致 MCP 挂死。

### 测试
- jsonrpc_tests 61/61 全绿（既有用例，Error 捕获为增量防御，无行为破坏）

### 下游验证
- 本地 path 依赖（chronomem cjpm.toml `[replace]`）验证：chronomem 二进制含
  `receiveLoop system error` 字符串；badger-cj 347/347、mcp-cj 依赖链构建通过

## v0.7.3（2026-08-27，acp-cj 需求驱动）

### 新增：registerAsyncErr —— 异步 handler 支持 JSON-RPC 错误响应
- `server.cj` 新增 `AsyncHandlerErr` 类型与 `registerAsyncErr(method, handler)`：
  - handler 签名 `(HandlerContext, (JsonValue) -> Unit /*complete*/, (JsonRpcError) -> Unit /*fail*/) -> Unit`
  - `complete(result)` 返回成功响应；`fail(error)` 返回 JSON-RPC 错误响应（如 -32602）
- 背景：acp-cj 的 `session/prompt` 是长时异步 handler，未知 sessionId / 无 handler 等错误
  需通过 JSON-RPC error 返回；原 `registerAsync` 的 complete 只支持 result。
- 纯增量 API，不改变现有 `registerAsync` 行为（不破坏性变更）。
- `tryFastRejectUnknownMethod` 同步检查 `asyncErrHandlers`，避免误判未知方法。
- `HandlerContext` 新增公开字段 `requestId: ?RequestId`（请求消息为 Some(id)，通知为 None）：
  - 供 `$/cancel_request` 按请求 id 取消等场景使用；纯增量，`init(params!)` 旧调用不变（requestId 默认 None）

### 测试
- 新增 `testAsyncHandlerErrResponds`：fail(-32602) 路径 + complete 成功路径双验证
- 新增 `HandlerContextRequestIdTest.testHandlerContextHasRequestId`：请求 handler 能拿到 RequestId
- jsonrpc_tests 61/61 全绿（59 原有 + 2 新增）

### 下游验证（AGENTS.md 规范）
- mcp-cj：build success
- lsp-cj：lsp_tests 34/34 全绿
- acp-cj（新增下游）：32/32 全绿，端到端（client ↔ server 代理链 ↔ opencode）通过

### 文档：README API 部分补全（根 README.md，build.cj 自动同步子包）
- 发现近月发版新增 API（v0.5.0 通知多订阅 / v0.6.0 registerAsync / v0.7.3 registerAsyncErr+requestId）
  与双向 RPC 能力（v0.4.x 起 registerRequestHandler/request/notify）从未写入 README API 部分
- 重写 `## API`：按源码文件分组（types/message/framing/transport/exception/server/client），
  类的方法用表格列签名，接口（Transport/Framing）与类型别名（Handler/AsyncHandler/AsyncHandlerErr/Middleware）
  直接贴定义代码，枚举（Message/Result）给定义；字段属协议标准不赘述
- 新增「双向 RPC（双工）」用法示例；安装版本号 0.1.0 → 0.7.2
- 子包 README 为 build.cj `stagePreBuild` 从根目录覆盖生成（.gitignore），只改根 README.md 即可

### 发版
- jsonrpc 及 5 个传输包统一 0.7.3，传输包依赖升级到 jsonrpc 0.7.3
- jsonrpc_tests 不发中心仓，path 依赖本地核心包
- 下游验证（发版前，path 依赖本地 jsonrpc）：mcp-cj build + testclient 端到端全过、lsp-cj 34/34 全绿；验证后恢复下游注册表依赖
- 发布顺序：核心 jsonrpc 先发 → `cjpm update` 刷新缓存 → 再发 5 个传输包

## v0.7.5（2026-09-13，服务端主动请求并发配对修复）

### 修复：`JsonRpcServer.request()` 由「单挂起槽」改为「按 id 的等待表」
- 缺陷：服务端主动请求（server → client 反向调用，如 LSP `client/registerCapability`、
  ACP `session/request_permission` / `fs/*` / `terminal/*`）用**单个** `pendingRequest` 槽承载，
  且 `request()` 的 id 恒为 `RequestId.Int(0)`、`handleOutgoingResponse()` **不看 `resp.id`**：
  - 两个反向请求同时在飞 → 后者的槽覆盖前者 → 前者永远收不到响应，只能等到超时；
  - 先回来的响应按「当前槽」投递 → 张冠李戴（B 拿到 A 的答案）。
- 修复：`pendingRequests: HashMap<RequestId, PendingRequest>` + 自增 id；
  `handleOutgoingResponse()` 按 `resp.id` 查表投递，未知/迟到的 id 直接忽略；无论成功/超时都摘掉等待槽。
- 影响面：acp-cj 此前用一个 `clientRequestLock` 把全部反向调用**串行化**来绕开单槽限制
  （锁横跨整个往返，`terminalWaitForExit` 超时可达 10 分钟 → 期间其它反向调用全被堵住）；
  lsp-cj 的 `registerCapability` / `applyEdit` / `configuration` / `workspaceFolders` 包装没有锁。

### 测试
- 新增 `ServerOutgoingRequestConcurrencyTest`（两例）：两个并发反向请求必须各拿各的响应 ——
  ① 后发先至；② 先发先至但槽已被后来者占用（此例在旧实现下会串台）。
  修复前两例分别 FAILED（首个请求超时）与 FAILED（第二个请求收到 `"first"`）；修复后全过。
- 新增阻塞式内存传输 `BlockingDuplexTransport`：不复用 `tests.cj` 的 `MemPipe`
  （它空闲 50ms 即 `return None`，而 server 把 `None` 当「传输已关闭」→ 带延迟的用例会假失败；
  真实传输 stdio/tcp/http 的 receive 都是阻塞到有数据或 EOF）。
- jsonrpc_tests 63/63 全绿（61 原有 + 2 新增）

### 下游验证（AGENTS.md 规范，均以 path 依赖本地 jsonrpc 跑）
- mcp-cj：3/3 全绿
- chronomem（经 mcp-cj 全链路）：129/129 全绿
- acp-cj（`request()` 的直接使用方）：65/65 全绿
- lsp-cj `lsp_tests`：34/34 全绿。注意：lsp-cj 各包注册表依赖仍是 `jsonrpc 0.4.2`，
  本次只做了本地 path 验证；发版后需另行评估是否升级其依赖

## 未发版（2026-09-13，客户端接收循环 / 连接关闭的失败可见性）

### 背景：此前两类修复只覆盖了 server 侧
- `81f1eed`（receiveLoop 边界捕获系统级 Error）与 `42768e7`（断开时 close）都只改
  `jsonrpc/src/server.cj`；`client.cj` 一行没碰，5 个传输包也只有"用到的那个"被顺带改过。
- 触发线索：一处静默失败的回归用例排查（`pushUpdate` 吞异常）顺着"失败不可见"这条线
  扫到 json-rpc，发现客户端侧是同一族缺陷的完整未修版本。

### 族 1：catch Error / Exception 覆盖
- **`client.receiveLoop` 此前完全没有 `try/catch`**：传输层抛异常（对端断开时 socket read
  抛 `ConnectionException` 是常态）直接逃逸杀死接收线程，而 `running` 仍为 `true`、
  在途调用无人唤醒 → **所有调用干等满 timeout（默认 30s）= 客户端挂起**。
  这正好是 `81f1eed` 提交说明里描述的"生产忆时塔挂起症状"的客户端版本。
- **`client.cj` 全文件没有一处 `catch (e: Error)`**：OOM 这类系统级 Error 同样杀循环。
- 现为：`Exception` → 记录 + shutdown（唤醒在途）+ 退出；`Error` → 记录 + 继续
  （对齐 server 侧 81f1eed 的取舍：OOM 不允许停机）。
- `handleMessage` 的静默 `()`、通知回调的吞异常 → 改为打日志（协议/回调问题不再不可见）。

### 族 2：连接 close
- `close()` 与传输 EOF 此前只翻 `running` 标志，**不唤醒 `pendingRequests`**：
  连接已经没了，每个在途调用仍要干等满 timeout 才返回。
- 现新增私有 `shutdown(reason)`：置标志 + **逐个 cancel 在途请求** + 关闭传输；
  `close()` = `shutdown` + cancel 接收线程（分离是为了让 receiveLoop 内部也能调用而不 cancel 自己）。
- `call()` 区分「连接已不可用（立刻失败，`Connection unavailable: …`）」与「真的超时」，
  不再把前者误诊成后者。

### 传输层（5 个包统一过一遍）
| 包 | 改动 |
|---|---|
| `jsonrpc_stdio` | `receive`/`send` 补 `closed` 检查（关闭后不再挂在阻塞读上；stdin 无法中断已注明） |
| `jsonrpc_http` | `send` 失败不再静默丢请求（丢了调用方只能干等 timeout） |
| `jsonrpc_websocket` | WS 升级/启动失败补日志（此前客户端只看到 socket 被关，服务端零线索） |
| `jsonrpc_tcp` / `jsonrpc_unix` | accept 失败补日志（与「监听已关闭」区分）；closed 时 send 丢弃补日志。**这两个包自初始实现 `c3966d6` 起从未修改过** |

### 测试（63 → 66 全绿）
- 新增 `TransportResilienceTest` 3 例：接收抛异常时在途调用**立刻失败**且文案为
  `Connection unavailable`（timeout 故意给 30s，修复失效即表现为等满 30s 的失败）；
  `close()` 唤醒在途调用；一条坏消息不杀接收循环（之后仍能拿到正常响应）。
- 踩坑记录：写"坏消息不杀循环"用例时起初用 `MemDuplexTransport`，其 `MemPipe` 空闲即
  返回 `None`，被新加的 `case None => shutdown(...)` 当成 EOF → 用例失败。改用
  `BlockingDuplexTransport`（2026-09-13 v0.7.5 那次就是为这个坑加的）。**`Transport.receive()`
  返回 `None` 的语义是「已关闭」，测试桩必须阻塞**。

### 下游验证（AGENTS.md 规范，均以 path 依赖本地 jsonrpc 跑）
- mcp-cj：4/4 全绿
- lsp-cj：34/34 全绿（其注册表依赖仍是 `jsonrpc 0.4.2`，本次是本地 path 验证；
  验证后已把两个 `cjpm.lock` 用 `cjpm update` 重生成回 `0.4.2` 一致状态）

### 遗留（本次未做）
- 5 个传输包在 `jsonrpc_tests` 里**零覆盖**（测试只 import 核心，用内存桩）——
  建议补 tcp/unix loopback 用例，否则"只改了用到的传输"还会再发生。
- `cjpm build -j 16` 在本仓**本来就失败**：`build-members` 含 `jsonrpc_tests`，而它是
  `output-type = "executable"` 却没有 `main` → `error: 'main' is missing`。
  要么把它移出 `build-members`，要么给它加 `main`。当前验证走 `cjpm test`。
