# 通用 JSON-RPC 库设计文档（仓颉语言）

## 1. 项目目标

实现一个**轻量、通用、纯仓颉**的 JSON-RPC 2.0 协议库：

- **最小依赖**：仅依赖仓颉标准库和 `jsonvalue` 库
- **按需引入**：使用 workspace 多项目方案，用户只需引入需要的传输层
- **传输无关**：核心库不依赖具体传输层，用户按需选择
- **并发支持**：基于 `spawn` 和 `Future<T>` 提供非阻塞模型

## 2. JSON-RPC 2.0 协议回顾

| 消息类型 | 字段 | 说明 |
|---------|------|------|
| Request | jsonrpc, id, method, params | 有 id，需要响应 |
| Response | jsonrpc, id, result/error | 成功有 result，失败有 error |
| Notification | jsonrpc, method, params | 无 id，无需响应 |
| Batch | 数组形式的 Request/Notification | 批量调用 |

**预定义错误码**：
| 代码 | 含义 |
|------|------|
| -32700 | Parse error |
| -32600 | Invalid Request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |

## 3. Workspace 项目结构

```
json-rpc/
├── cjpm.toml              # workspace 配置
├── jsonrpc/               # 核心库（必须）
│   ├── cjpm.toml
│   └── src/
│       ├── types.cj       # 数据类型
│       ├── transport.cj   # Transport 接口
│       ├── framing.cj     # 消息分帧
│       ├── message.cj     # 序列化
│       ├── client.cj      # 客户端
│       ├── server.cj      # 服务端
│       └── exception.cj   # 异常定义
│
├── jsonrpc_stdio/         # Stdio 传输层（LSP场景）
├── jsonrpc_tcp/           # TCP 传输层（网络场景）
├── jsonrpc_unix/          # Unix Socket 传输层
```

**组织名**：所有模块使用 `ystyle` 组织名，发布到中央仓库后用户引入方式：

```toml
# TCP 场景
[dependencies]
  "ystyle::jsonrpc" = "0.1.0"
  "ystyle::jsonrpc_tcp" = "0.1.0"

# LSP 场景
[dependencies]
  "ystyle::jsonrpc" = "0.1.0"
  "ystyle::jsonrpc_stdio" = "0.1.0"
```

**注意**：cjpm 使用 `::` 分隔组织名和包名，源码 package 声明也需使用相同格式：
```cangjie
package ystyle::jsonrpc        // 核心库
package ystyle::jsonrpc_tcp    // TCP 传输层
import ystyle::jsonrpc.*       // 导入核心库
```

## 4. 核心库模块职责

### 4.1 types.cj - 数据类型

| 类型 | 说明 |
|------|------|
| `enum RequestId` | Int(Int64) \| String(String)，需实现 Hashable、Equatable |
| `class Request` | jsonrpc、id、method、params(?JsonValue) |
| `class Response` | jsonrpc、id、result(?JsonValue)、error(?JsonRpcError) |
| `class Notification` | jsonrpc、method、params(?JsonValue) |
| `class JsonRpcError` | code、message、data(?JsonValue) |

**约束**：所有类型需实现 `JsonSerializable` 和 `JsonDeserializable<T>`。

### 4.2 transport.cj - Transport 接口

```
interface Transport <: Resource {
    func send(data: Array<Byte>): Unit    // 发送数据
    func receive(): ?Array<Byte>          // 接收数据，None 表示连接关闭
    func close(): Unit                    // 关闭连接（继承自 Resource）
    func isClosed(): Bool                 // 检查连接是否关闭
}
```

### 4.3 framing.cj - 消息分帧

LSP 使用的 Content-Length 分帧格式：
```
Content-Length: <len>\r\n\r\n<JSON body>
```

| 函数 | 说明 |
|------|------|
| `encode(body: Array<Byte>): Array<Byte>` | 添加 Content-Length 头 |
| `decode(buffer: ByteBuffer): ?Array<Byte>` | 解析一个完整消息，返回 body |

### 4.4 message.cj - 消息序列化

| 函数 | 说明 |
|------|------|
| `serializeRequest(req: Request): Array<Byte>` | 序列化请求 |
| `deserializeRequest(bytes: Array<Byte>): Request` | 反序列化请求 |
| `serializeResponse(resp: Response): Array<Byte>` | 序列化响应 |
| `serializeNotification(notif: Notification): Array<Byte>` | 序列化通知 |
| `parseMessage(bytes: Array<Byte>): Message` | 解析任意消息（支持 Batch） |

### 4.5 client.cj - 客户端

**职责**：
- 维护 `pendingRequests: ConcurrentHashMap<RequestId, PendingRequest>`
- 后台接收循环线程解析响应
- 生成唯一请求 ID

| 方法 | 说明 |
|------|------|
| `init(transport: Transport)` | 创建客户端 |
| `call<T, R>(method: String, params!: ?T, timeout!: Duration): Result<R>` | 同步调用，T 为参数类型，R 为返回类型 |
| `call(method: String): Result<JsonValue>` | 无参数版本 |
| `notify<T>(method: String, params!: ?T): Unit` | 发送通知 |
| `notify(method: String): Unit` | 无参数通知 |
| `start(): Unit` | 启动接收线程 |
| `close(): Unit` | 关闭客户端 |

**返回值**：`Result<R>` 为枚举类型，`Ok(R)` 表示成功，`Err(String)` 表示错误信息。

### 4.6 server.cj - 服务端

**职责**：
- 注册中间件和方法处理器
- 后台接收循环线程处理请求
- 每个请求在独立线程处理（避免阻塞）

| 方法 | 说明 |
|------|------|
| `init(transport: Transport)` | 创建服务端 |
| `use(middleware: Middleware): Unit` | 注册中间件 |
| `register(method: String, handler: MethodHandler): Unit` | 注册方法 |
| `register(method: String, handler: (HandlerContext) -> HandlerResult): Unit` | 注册 Lambda |
| `start(): Unit` | 启动接收循环 |
| `close(): Unit` | 关闭服务端 |

**中间件设计**：

洋葱模式，通过 `next()` 控制流程：
- 不调用 `next()` = 拦截请求
- 调用 `next()` = 继续执行下一层

**类型别名**（使用仓颉 `type` 语法）：

```
public type Middleware = (RequestContext, () -> HandlerResult) -> HandlerResult
```

| 类型 | 说明 |
|------|------|
| `type Middleware` | 中间件函数类型别名 |
| `class RequestContext` | let request, let transport（只读） |

**中间件示例**：

```
// 日志 - 前后记录
server.use { ctx, next =>
    println("→ ${ctx.request.method}")
    let result = next()
    println("← done")
    return result
}

// 认证 - 拦截非法请求
server.use { ctx, next =>
    if (!validToken(ctx)) {
        return HandlerResult.err(-32600, "Unauthorized")
    }
    return next()
}

// 错误处理 - 捕获异常
server.use { ctx, next =>
    try {
        return next()
    } catch (e: Exception) {
        return HandlerResult.err(-32603, "Internal error")
    }
}
```

**执行顺序**：中间件按注册顺序执行，handler 最后。

**辅助类型**：
| 类型 | 说明 |
|------|------|
| `interface MethodHandler` | `handle(ctx: HandlerContext): HandlerResult` |
| `class HandlerContext` | params(?JsonValue)，提供泛型解析方法 |
| `class HandlerResult` | result/error，ok()/err() 静态方法 |

**HandlerContext 方法**：
| 方法 | 说明 |
|------|------|
| `getParam(key: String): ?JsonValue` | 获取单个参数 |
| `getParam<T>(key: String): ?T where T <: JsonDeserializable<T>` | 获取并解析为类型 T |
| `getParams<T>: ?T where T <: JsonDeserializable<T>` | 解析整个 params 为类型 T |

**HandlerResult 静态方法**：
| 方法 | 说明 |
|------|------|
| `ok(value: JsonValue): HandlerResult` | 返回成功结果 |
| `ok<T>(value: T): HandlerResult where T <: JsonSerializable` | 返回成功结果（泛型） |
| `err(code: Int64, message: String): HandlerResult` | 返回错误 |
| `err(code: Int64, message: String, data!: ?JsonValue): HandlerResult` | 返回错误带数据 |

### 4.7 exception.cj - 异常

```
class JsonRpcException <: Exception {
    let code: Int64    // JSON-RPC 错误码
}
```

## 5. 传输层模块职责

各传输层模块实现 `Transport` 接口：

| 模块 | 依赖 | 适用场景 |
|------|------|---------|
| transport-stdio | jsonrpc, std.console | LSP、命令行工具 |
| transport-tcp | jsonrpc, std.net | 网络通信 |
| transport-unix | jsonrpc, std.net | 本地高性能通信（非 Windows） |

## 6. 并发模型

- `spawn` 创建后台接收线程
- `ConcurrentHashMap` 管理 pending requests
- `Mutex` + `synchronized` 保护共享状态
- 服务端每个请求在独立线程处理

## 7. 用户使用示例

### TCP 客户端

```
// 定义参数类（实现 JsonSerializable）
class AddParams <: JsonSerializable {
    public var a: Int64 = 0
    public var b: Int64 = 0
    
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("a").writeValue(this.a)
        w.writeName("b").writeValue(this.b)
        w.endObject()
    }
}

let transport = TcpTransport("127.0.0.1", 8080)
let client = JsonRpcClient(transport)

// 直接传对象，无需转 JsonValue
let params = AddParams(a: 1, b: 2)
let result = client.call("add", params: params).get()

// 或用 HashMap（标准库已支持）
let logParams = HashMap<String, String>()
logParams["msg"] = "hello"
client.notify("log", params: logParams)

// 无参数调用
client.notify("ping")

client.close()
```

### Stdio 服务端（LSP）

```
let transport = StdioTransport()
let server = JsonRpcServer(transport)

// 中间件：日志
server.use { ctx, next =>
    println("[${ctx.request.method}] start")
    let result = next()
    println("[${ctx.request.method}] done")
    return result
}

// 中间件：错误处理
server.use { ctx, next =>
    try {
        return next()
    } catch (e: Exception) {
        return HandlerResult.err(-32603, "Internal: ${e.message}")
    }
}

// 注册方法
server.register("add") { ctx =>
    let params = ctx.getParams<AddParams>()
    HandlerResult.ok(AddResult(sum: params.a + params.b))
}

server.register("multiply") { ctx =>
    let a = ctx.getParam<Int64>("a") ?? 0
    let b = ctx.getParam<Int64>("b") ?? 0
    HandlerResult.ok(a * b)
}

server.start()
```

## 8. 扩展点

- 压缩：在分帧层增加 Content-Encoding 头
- WebSocket 传输层模块
- HTTP 传输层模块

---

**版本**: 0.1.0  
**状态**: 实现完成  
**依赖**: 仓颉标准库、jsonvalue