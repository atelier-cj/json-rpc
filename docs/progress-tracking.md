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
