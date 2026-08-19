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

