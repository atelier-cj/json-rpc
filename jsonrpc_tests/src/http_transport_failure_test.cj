package jsonrpc_tests

// HTTP 传输的失败可见性（与 mcp-cj 的 http_failure 同一口径）：
//
//  ① 送不出去的调用不能把在途记录留在表里，也不能只打日志——调用方要么立刻拿到
//     原因，要么干等满 timeout（默认 30s），后者正是「客户端挂起」的来源；
//  ② HTTP 层的失败（网关/框架给的 text/plain、HTML）不是协议消息：原样投给解析器
//     只会得到一句 "Parse error"，服务端真正说的话被丢掉；
//  ③ 规范允许的「4xx/5xx + JSON-RPC 错误体」仍要照常投递；
//  ④ 响应体可能远超一次 read 的缓冲，读不满同样只会变成解析错。

import ystyle::jsonrpc.*
import ystyle::jsonrpc_http.*
import jsonvalue.*
import stdx.net.http.*
import std.collection.{ArrayList, HashMap}
import std.sync.*
import std.io.InputStream
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

/** 送不出去的传输桩：模拟连接抖动 / HTTP 层失败。 */
class FailingSendTransport <: Transport {
    private let lock = Mutex()
    private var closed = false

    public func send(data: Array<Byte>): Unit {
        throw Exception("boom on send")
    }

    public func receive(): ?Array<Byte> {
        // 不主动 EOF：让「接收循环因对端关闭而唤醒在途调用」这条路径不干扰本用例
        while (true) {
            synchronized(this.lock) {
                if (this.closed) {
                    return None
                }
            }
            sleep(10 * Duration.millisecond)
        }
        None
    }

    public func close(): Unit {
        synchronized(this.lock) {
            this.closed = true
        }
    }

    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed
        }
    }
}

class FailureServerPortHolder {
    var value: UInt16 = 0
}

/** 固定回一个 HTTP 状态 + 给定响应体的假服务端。 */
class FailureServer {
    let server: Server
    let url: String

    init(status: UInt16, contentType: String, respond: (Array<Byte>) -> Array<Byte>) {
        let portLock = Mutex()
        let portCond = synchronized(portLock) { portLock.condition() }
        let holder = FailureServerPortHolder()
        let server = ServerBuilder().addr("127.0.0.1").port(0).build()
        server.distributor.register("/rpc", { ctx =>
            let buf = Array<Byte>(8192, repeat: 0)
            let total = ArrayList<Byte>()
            while (true) {
                let len = ctx.request.body.read(buf)
                if (len <= 0) { break }
                total.add(all: buf[0..len])
            }
            let out = respond(total.toArray())
            ctx.responseBuilder.status(status)
                .header("content-type", contentType)
                .body(out)
        })
        server.afterBind({ =>
            synchronized(portLock) {
                holder.value = server.port
                portCond.notifyAll()
            }
        })
        spawn {
            => server.serve()
        }
        synchronized(portLock) {
            while (holder.value == 0) {
                portCond.wait(timeout: 5 * Duration.second)
            }
        }
        this.server = server
        this.url = "http://127.0.0.1:${holder.value}/rpc"
    }

    func close(): Unit {
        this.server.close()
    }
}

/** 回纯文本错误体的服务端（模拟 Go 侧 `Invalid session ID`）。 */
func plainErrorServer(status: UInt16, text: String): FailureServer {
    FailureServer(status, "text/plain; charset=utf-8", { _ => text.toArray() })
}

/** 回 JSON-RPC 错误响应的服务端，id 照抄请求。 */
func jsonErrorServer(status: UInt16, code: Int64, message: String): FailureServer {
    FailureServer(status, "application/json", { body =>
        let id = match (parseMessage(body)) {
            case Message.SingleRequest(req) => req.id
            case _ => RequestId.Int(1)
        }
        serializeResponse(Response(id: Some(id), error: JsonRpcError(code, message)))
    })
}

/** 回一个超大 result 的服务端：验证响应体读满（一次 read 只能拿 8KB）。 */
func largeResultServer(payloadSize: Int64): FailureServer {
    FailureServer(UInt16(200), "application/json", { body =>
        let id = match (parseMessage(body)) {
            case Message.SingleRequest(req) => req.id
            case _ => RequestId.Int(1)
        }
        let sb = StringBuilder()
        for (_ in 0..payloadSize) {
            sb.append("x")
        }
        serializeResponse(Response(id: Some(id), result: Some(JsonValue.String(sb.toString()))))
    })
}

/** 发起一次调用，返回 (是否抛异常, 消息/结果描述, 耗时毫秒)。 */
func callOutcome(transport: Transport, timeoutSeconds: Int64): (Bool, String, Int64) {
    let client = JsonRpcClient(transport)
    client.start()
    let start = MonoTime.now()
    var threw = false
    var message = ""
    try {
        match (client.call<JsonValue, JsonValue>("ping", params: None,
            timeout: Duration.second * timeoutSeconds)) {
            case Result.Ok(_) => message = "ok"
            case Result.Err(reason) => message = reason
        }
    } catch (e: Exception) {
        threw = true
        message = e.message
    }
    let elapsed = (MonoTime.now() - start).toMilliseconds()
    client.close()
    (threw, message, elapsed)
}

@Test
class ClientSendFailureTest {

    // send 抛异常 → 调用必须立刻拿到异常（而不是干等满 timeout），且不留残余在途记录
    @TestCase
    func testSendFailurePropagatesAndClearsPending(): Unit {
        let client = JsonRpcClient(FailingSendTransport())
        client.start()
        @Expect(client.inFlightCount(), 0)

        var threw = false
        var message = ""
        try {
            client.call<JsonValue, JsonValue>("ping", params: None, timeout: 30 * Duration.second)
        } catch (e: Exception) {
            threw = true
            message = e.message
        }
        if (!threw) {
            @Fail("expected the send failure to propagate instead of waiting for the timeout")
        }
        @Expect(message, "boom on send")
        @Expect(client.inFlightCount(), 0)

        // 再来一次仍然不累积（修复前每次失败都会留下一条只增不减的记录）
        try {
            client.call<JsonValue, JsonValue>("ping", params: None, timeout: 30 * Duration.second)
        } catch (_: Exception) {
        }
        @Expect(client.inFlightCount(), 0)
        client.close()
    }
}

@Test
class HttpTransportFailureTest {

    @TestCase
    func testPlainTextHttpErrorIsSurfaced(): Unit {
        let server = plainErrorServer(UInt16(400), "Invalid session ID")
        let client = ClientBuilder().build()
        let (threw, message, elapsed) = callOutcome(HttpClientTransport(client, server.url), 5)
        server.close()

        if (!threw) {
            @Fail("HTTP failure must surface as an error, got: ${message}")
        }
        if (!message.contains("HTTP 400")) {
            @Fail("message should carry the status code, got: ${message}")
        }
        if (!message.contains("Invalid session ID")) {
            @Fail("message should carry the server's own words, got: ${message}")
        }
        // 立刻失败，而不是干等满 5s 才报「请求超时」
        if (elapsed >= 3000) {
            @Fail("the failure must come back at once, waited ${elapsed}ms")
        }
    }

    @TestCase
    func testJsonRpcErrorBodyIsStillDelivered(): Unit {
        // 规范允许 4xx/5xx 携带 JSON-RPC 错误体：那是协议消息，调用方要拿得到 code/message
        let server = jsonErrorServer(UInt16(400), -32000, "session expired")
        let client = ClientBuilder().build()
        let (threw, message, elapsed) = callOutcome(HttpClientTransport(client, server.url), 5)
        server.close()

        if (threw) {
            @Fail("a JSON-RPC error body is a protocol message, not a transport failure: ${message}")
        }
        if (!message.contains("session expired")) {
            @Fail("caller should see the server's error message, got: ${message}")
        }
        if (elapsed >= 3000) {
            @Fail("the error response should be delivered at once, waited ${elapsed}ms")
        }
    }

    @TestCase
    func testLargeResponseBodyIsReadWhole(): Unit {
        // 一次 read 只能拿 8KB：读不满就被当成坏 JSON，表现为莫名其妙的解析错
        let server = largeResultServer(40000)
        let client = ClientBuilder().build()
        let (threw, message, _) = callOutcome(HttpClientTransport(client, server.url), 10)
        server.close()

        if (threw) {
            @Fail("large response should be delivered, got: ${message}")
        }
        @Expect(message, "ok")
    }
}
