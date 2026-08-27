# ystyle::jsonrpc

JSON-RPC 2.0 通用框架（仓颉语言）

## 安装

```toml
[dependencies]
  "ystyle::jsonrpc" = "0.7.2"
  # 按需选择传输层
  "ystyle::jsonrpc_stdio" = "0.7.2"      # Stdio
  "ystyle::jsonrpc_tcp" = "0.7.2"        # TCP
  "ystyle::jsonrpc_unix" = "0.7.2"       # Unix Socket
  "ystyle::jsonrpc_http" = "0.7.2"       # HTTP POST
  "ystyle::jsonrpc_websocket" = "0.7.2"  # WebSocket
```

## 快速开始

### 服务端

```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_stdio.*

main() {
    let transport = StdioTransport()
    let server = JsonRpcServer(transport)
    
    server.register("echo", { ctx =>
        HandlerResult.ok(ctx.getRawParams() ?? JsonValue.Null)
    })
    
    server.start()
}
```

### 客户端

```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_stdio.*

main() {
    let transport = StdioTransport()
    let client = JsonRpcClient(transport)
    client.start()
    
    let result = client.call<JsonValue, JsonValue>("echo",
        params: Some(JsonValue.Map(HashMap<String, JsonValue>())))
    match (result) {
        case Ok(v) => println(v.stringify())
        case Err(e) => println("错误: ${e}")
    }
    
    client.close()
}
```

## 传输层

| 包 | 类 | 用途 |
|------|------|------|
| jsonrpc_stdio | StdioTransport | LSP、进程管道 |
| jsonrpc_tcp | TcpClientTransport / TcpServerTransport | 网络服务 |
| jsonrpc_unix | UnixClientTransport / UnixServerTransport | 本地高性能通信 |
| jsonrpc_http | HttpClientTransport / HttpRpcHandler / HttpRpcHelper | HTTP POST 短连接 |
| jsonrpc_websocket | WebSocketClientTransport / WebSocketServerHandler | WebSocket 长连接 |

### TCP

服务端：
```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_tcp.*

main() {
    let server = TcpServerTransport(port: 8080)
    while (let Some(conn) <- server.acceptConnection()) {
        let rpc = JsonRpcServer(conn)
        rpc.register("echo", { ctx =>
            HandlerResult.ok(ctx.getRawParams() ?? JsonValue.Null)
        })
        rpc.start()
    }
}
```

客户端：
```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_tcp.*

main() {
    let transport = TcpClientTransport("127.0.0.1", 8080)
    let client = JsonRpcClient(transport)
    client.start()
    
    let result = client.call<JsonValue, JsonValue>("echo",
        params: Some(JsonValue.Map(HashMap<String, JsonValue>())))
    // ...
    client.close()
}
```

### Unix Socket

服务端：
```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_unix.*

main() {
    let server = UnixServerTransport(path: "/tmp/rpc.sock")
    while (let Some(conn) <- server.acceptConnection()) {
        let rpc = JsonRpcServer(conn)
        rpc.register("echo", { ctx =>
            HandlerResult.ok(ctx.getRawParams() ?? JsonValue.Null)
        })
        rpc.start()
    }
}
```

客户端：
```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_unix.*

main() {
    let transport = UnixClientTransport(path: "/tmp/rpc.sock")
    let client = JsonRpcClient(transport)
    client.start()
    // ...
    client.close()
}
```

### HTTP POST

集成到现有 HTTP Server：
```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_http.*
import stdx.net.http.*

let httpServer = ServerBuilder().addr("0.0.0.0").port(8080).build()
let rpcServer = JsonRpcServer(/* transport 由 handler 内部处理 */)
rpcServer.register("echo", { ctx => HandlerResult.ok(ctx.getRawParams() ?? JsonValue.Null) })

httpServer.route("/rpc", HttpRpcHandler(rpcServer))
httpServer.start()
```

客户端（复用现有 HTTP Client）：
```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_http.*
import stdx.net.http.*

let httpClient = ClientBuilder().build()
let transport = HttpClientTransport(httpClient, "http://localhost:8080/rpc")
let rpcClient = JsonRpcClient(transport)
rpcClient.start()
```

### WebSocket 长连接

服务端（集成到现有 HTTP Server）：
```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_websocket.*
import stdx.net.http.*

let httpServer = ServerBuilder().addr("0.0.0.0").port(8080).build()
let rpcServer = JsonRpcServer(/* transport 由 handler 内部处理 */)
rpcServer.register("echo", { ctx => HandlerResult.ok(ctx.getRawParams() ?? JsonValue.Null) })

httpServer.route("/ws", WebSocketServerHandler(rpcServer))
httpServer.start()
```

客户端：
```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_websocket.*
import stdx.net.http.*

let httpClient = ClientBuilder().build()
let transport = WebSocketClientTransport.connect(httpClient, "ws://localhost:8080/ws")
let rpcClient = JsonRpcClient(transport)
rpcClient.start()
```

## API

> API 按源码文件分组，与 `jsonrpc/src/` 一一对应。

### types.cj — 消息类型

- `RequestId` — 请求 id（数字或字符串），实现 `Hashable & Equatable`
- `Request` / `Response` / `Notification` / `JsonRpcError` — 协议消息类型，均实现 `JsonSerializable & JsonDeserializable`，可配合 `serialize*` / `deserialize*` 或 `JsonValue.fromObject` 使用
- `ErrorCodes` — 标准错误码常量（见下方「错误码」）

### message.cj — 消息编解码

| 函数 | 说明 |
|------|------|
| `serializeRequest(req)` / `deserializeRequest(bytes)` | 请求编解码 |
| `serializeResponse(resp)` / `deserializeResponse(bytes)` | 响应编解码 |
| `serializeNotification(notif)` / `deserializeNotification(bytes)` | 通知编解码 |
| `parseMessage(bytes): Message` | 解析任意消息（gjson 快速分类，含批处理） |

`Message` 枚举：

```cangjie
public enum Message {
    | SingleRequest(Request)
    | SingleResponse(Response)
    | SingleNotification(Notification)
    | InvalidRequest(JsonRpcError)
    | BatchRequest(ArrayList<Message>)
    | BatchResponse(ArrayList<Response>)
}
```

### framing.cj — 分帧

```cangjie
public interface Framing {
    func encode(body: Array<Byte>): Array<Byte>
    func decode(data: Array<Byte>): ?(Array<Byte>, Int64)  // (body, consumed)
}
```

实现：
- `ContentLengthFraming` — `Content-Length` 头分帧（默认，LSP 标准）
- `NewlineFraming` — 换行分帧
- 顶层便捷函数 `encode(body)` / `decode(content)` 使用 `ContentLengthFraming`

### transport.cj — 传输接口

```cangjie
public interface Transport <: Resource {
    func send(data: Array<Byte>): Unit
    func receive(): ?Array<Byte>
    func isClosed(): Bool
}
```

具体实现见上方「传输层」各包。

### exception.cj — 异常与结果

- `JsonRpcException` — 协议异常，`code` 携带 JSON-RPC 错误码
- `Result<T>` — `call` / `request` 的返回类型：

```cangjie
public enum Result<T> {
    | Ok(T)
    | Err(String)
}
```

### server.cj — JsonRpcServer

| 方法 | 说明 |
|------|------|
| `init(transport, framing!)` | 构造（默认 ContentLengthFraming） |
| `register(method, handler)` | 注册同步处理器 |
| `registerAsync(method, handler)` | 注册异步处理器：handler 内 spawn 任务后通过 `complete(result)` 回响应，不阻塞接收线程（适合 handler 内再次发起请求的场景） |
| `registerAsyncErr(method, handler)` | 注册异步处理器（带错误回调）：`complete(result)` 成功 / `fail(error)` 返回 JSON-RPC 错误响应 |
| `use(middleware)` | 添加中间件（洋葱模型） |
| `start()` | 启动服务（后台线程，非阻塞） |
| `serve()` | 启动服务（当前线程，阻塞至 close） |
| `notify<T>(method, params)` / `notify(method)` | 向对端发送通知 |
| `request<T, R>(method, params, timeout)` | **服务端主动发起请求**（如 LSP `client/registerCapability`），返回 `Result<R>`；同一时刻仅一个挂起出站请求 |
| `copyHandlersFrom(other)` | 复制另一 server 的处理器 |
| `copyMiddlewaresFrom(other)` | 复制另一 server 的中间件 |
| `getHandlers()` / `getMiddlewares()` | 获取当前注册表 |
| `isClosed()` | 是否已关闭 |

处理器类型别名：

```cangjie
public type Handler = (HandlerContext) -> HandlerResult
public type AsyncHandler = (HandlerContext, (JsonValue) -> Unit) -> Unit
public type AsyncHandlerErr = (HandlerContext, (JsonValue) -> Unit, (JsonRpcError) -> Unit) -> Unit
public type Middleware = (RequestContext, () -> HandlerResult) -> HandlerResult
```

### client.cj — JsonRpcClient

| 方法 | 说明 |
|------|------|
| `init(transport, framing!)` | 构造（默认 ContentLengthFraming） |
| `call<T, R>(method, params, timeout)` | 同步调用，返回 `Result<R>` |
| `call(method, timeout)` | 无参数调用，返回 `Result<JsonValue>` |
| `notify<T>(method, params)` / `notify(method)` | 发送通知（无响应） |
| `setNotificationCallback(cb)` | 设置单个通知回调（覆盖已有） |
| `setNotificationCallback(cbs)` | 设置多个通知回调（整体覆盖） |
| `addNotificationCallback(cb)` | 追加通知回调（保留已有，支持多订阅） |
| `registerRequestHandler(method, handler)` | **处理服务端发来的请求**（双工），handler 返回 `?JsonValue`（None = 不回复） |
| `sendResponse(id, result)` | 显式回复服务端请求 |
| `start()` | 启动接收循环（后台线程） |
| `close()` / `isClosed()` | 关闭 / 查询状态 |

### HandlerContext（server.cj）

| 成员 | 说明 |
|------|------|
| `getParam(key)` | 获取单个参数 |
| `getParamAs<T>(key)` | 获取并转换类型 |
| `getParams<T>()` | 获取整个参数对象 |
| `getRawParams()` | 获取原始 JsonValue |

> `requestId`（v0.7.3）：当前请求 id，仅请求消息有值（通知为 None）。

### HandlerResult（server.cj）

| 方法 | 说明 |
|------|------|
| `ok(value)` | 成功结果（JsonValue） |
| `ok<T>(value)` | 成功结果（自动序列化） |
| `err(code, message)` | 返回错误 |
| `err(code, message, data)` | 返回错误（带 data） |

`RequestContext`（`request` + `transport`，见上方 `Middleware` 别名）与 `PendingRequest`（`setResponse` / `waitForResponse`）为内部组件，通常无需直接使用。

## 双向 RPC（双工）

同一连接上两端都可主动发起请求/通知并回复对方请求（JSON-RPC 2.0 对等模型，如 LSP 的 `client/registerCapability`）。

```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_stdio.*

main() {
    // ── 对等端 A：注册本地服务 + 处理对端请求 + 订阅通知
    let a = JsonRpcClient(StdioTransport())
    a.registerRequestHandler("ping", { req => Some(JsonValue.Bool(true)) })
    a.setNotificationCallback({ notif => println("A got notify: ${notif.method}") })
    a.start()

    // ── 对等端 B：注册本地服务，并主动向 A 发请求 / 通知
    let b = JsonRpcServer(StdioTransport())
    b.register("echo", { ctx => HandlerResult.ok(ctx.getRawParams() ?? JsonValue.Null) })
    b.start()

    // 服务端主动发起请求（B → A）
    let r = b.request<JsonValue, JsonValue>("ping", params: None)
    match (r) {
        case Ok(v) => println("B <- A: ${v.stringify()}")
        case Err(e) => println("请求失败: ${e}")
    }
}
```

## 错误码

| 常量 | 代码 |
|------|------|
| ErrorCodes.PARSE_ERROR | -32700 |
| ErrorCodes.INVALID_REQUEST | -32600 |
| ErrorCodes.METHOD_NOT_FOUND | -32601 |
| ErrorCodes.INVALID_PARAMS | -32602 |
| ErrorCodes.INTERNAL_ERROR | -32603 |

## 文档

- [设计文档](docs/design.md)
- [性能基准报告](docs/performance.md)（gjson 快速路由 + 流式直连反序列化）
- [进度追踪](docs/progress-tracking.md)

## License

MIT