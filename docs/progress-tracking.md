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
- ✅ FramingTest（编码解码，3个用例）
- ✅ RequestIdTest（ID 类型，3个用例）
- ✅ RequestTest（请求序列化）
- ✅ ResponseTest（响应序列化，2个用例）
- ✅ NotificationTest（通知序列化）
- ✅ ErrorCodesTest（标准错误码）
- ✅ MessageParseTest（消息解析，6个用例）

## 待完成

- [ ] Server 中间件集成测试
- [ ] Client 调用集成测试
- [ ] TCP/Unix 传输层集成测试
- [ ] 错误处理完善
- [ ] 文档完善

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