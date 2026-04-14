# ystyle::jsonrpc

JSON-RPC 2.0 通用框架（仓颉语言）

## 安装

```toml
[dependencies]
  "ystyle::jsonrpc" = "0.1.0"
  "ystyle::jsonrpc_stdio" = "0.1.0"   # 或 jsonrpc_tcp / jsonrpc_unix
```

## 快速开始

### 服务端

```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_stdio.*

class EchoResult <: JsonSerializable & JsonDeserializable<EchoResult> {
    public let msg: String
    public init(msg!: String = "") { this.msg = msg }
    public func toJson(w: JsonWriter): Unit {
        w.writeBeginObject()
        w.writeKey("msg")
        w.writeValue(this.msg)
        w.writeEndObject()
    }
    public static func fromJson(r: JsonReader): EchoResult {
        r.readBeginObject()
        var msg = ""
        while (let Some(k) <- r.nextKey()) {
            if (k == "msg") { msg = r.readValue<String>() }
            else { r.skipValue() }
        }
        r.readEndObject()
        EchoResult(msg)
    }
}

main() {
    let transport = StdioTransport()
    let server = JsonRpcServer(transport)
    
    server.register("echo", { ctx =>
        let params = ctx.getParams<EchoResult>() ?? EchoResult()
        HandlerResult.ok(EchoResult(msg: params.msg))
    })
    
    server.start()
}
```

### 客户端

```cangjie
import ystyle::jsonrpc.*
import ystyle::jsonrpc_stdio.*

class EchoParams <: JsonSerializable {
    public let msg: String
    public init(msg: String) { this.msg = msg }
    public func toJson(w: JsonWriter): Unit {
        w.writeBeginObject()
        w.writeKey("msg")
        w.writeValue(this.msg)
        w.writeEndObject()
    }
}

class EchoResult <: JsonSerializable & JsonDeserializable<EchoResult> {
    public let msg: String
    public init(msg!: String = "") { this.msg = msg }
    public func toJson(w: JsonWriter): Unit {
        w.writeBeginObject()
        w.writeKey("msg")
        w.writeValue(this.msg)
        w.writeEndObject()
    }
    public static func fromJson(r: JsonReader): EchoResult {
        r.readBeginObject()
        var msg = ""
        while (let Some(k) <- r.nextKey()) {
            if (k == "msg") { msg = r.readValue<String>() }
            else { r.skipValue() }
        }
        r.readEndObject()
        EchoResult(msg)
    }
}

main() {
    let transport = StdioTransport()
    let client = JsonRpcClient(transport)
    client.start()
    
    let result = client.call<EchoParams, EchoResult>("echo", params: Some(EchoParams("hello")))
    match (result) {
        case Ok(v) => println(v.msg)
        case Err(e) => println("错误: ${e}")
    }
    
    client.notify<EchoParams>("log", params: Some(EchoParams("test")))
    
    client.close()
}
```

## 传输层

| 传输层 | 用途 |
|--------|------|
| StdioTransport | LSP、进程管道 |
| TcpServerTransport / TcpClientTransport | 网络服务 |
| UnixServerTransport / UnixClientTransport | 本地高性能通信 |

## API

### JsonRpcServer

| 方法 | 说明 |
|------|------|
| `register(method, handler)` | 注册方法处理器 |
| `use(middleware)` | 添加中间件 |
| `start()` | 启动服务 |
| `close()` | 关闭服务 |

### JsonRpcClient

| 方法 | 说明 |
|------|------|
| `call<T, R>(method, params)` | 同步调用，返回 `Result<R>` |
| `notify<T>(method, params)` | 发送通知（无响应） |
| `start()` | 启动客户端 |
| `close()` | 关闭客户端 |

### HandlerContext

| 方法 | 说明 |
|------|------|
| `getParam(key)` | 获取单个参数 |
| `getParamAs<T>(key)` | 获取并转换类型 |
| `getParams<T>()` | 获取整个参数对象 |
| `getRawParams()` | 获取原始 JsonValue |

### HandlerResult

| 方法 | 说明 |
|------|------|
| `ok<T>(value)` | 返回成功结果 |
| `err(code, message)` | 返回错误 |

### Result

| 成员 | 说明 |
|------|------|
| `Ok(value)` | 成功结果 |
| `Err(message)` | 错误信息 |

## 错误码

| 常量 | 代码 |
|------|------|
| ErrorCodes.PARSE_ERROR | -32700 |
| ErrorCodes.INVALID_REQUEST | -32600 |
| ErrorCodes.METHOD_NOT_FOUND | -32601 |
| ErrorCodes.INVALID_PARAMS | -32602 |
| ErrorCodes.INTERNAL_ERROR | -32603 |