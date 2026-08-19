package jsonrpc_tests

import ystyle::jsonrpc.*
import jsonvalue.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// ── client 收到请求的异步处理（v0.7.1 修复：handleIncomingRequest 改为 spawn 异步）──
// 修复前：handler 在接收线程同步执行，跨连接死锁；handler 抛异常被外层 catch 吞掉，
//         请求方永远等不到响应（超时）。修复后：独立线程执行 + 异常回 -32603。

@Test
class ClientAsyncHandlerTest {

    @TestCase
    func testHandlerErrorReturnsInternalError(): Unit {
        let (a, b) = MemDuplexTransport.pair()
        let client = JsonRpcClient(a, framing: NewlineFraming())
        let server = JsonRpcServer(b, framing: NewlineFraming())
        client.start()
        server.start()

        // client 收到请求时 handler 抛异常 → 应回 -32603
        // （修复前异常被 handleMessage 外层 catch 吞掉，server.request 直接超时无响应）
        client.registerRequestHandler("boom", { _ =>
            throw Exception("boom exploded")
        })

        let r = server.request<JsonValue, JsonValue>("boom", params: None, timeout: 5 * Duration.second)
        match (r) {
            case Err(msg) => @Expect(msg.contains("-32603"))
            case Ok(_) => @Fail("expected -32603 internal error response")
        }
        client.close()
        server.close()
    }

    @TestCase
    func testNestedCallNoDeadlock(): Unit {
        // 回归：client 收到请求时，handler 内嵌套 call（同一连接同步等待响应）。
        // 修复前 handler 阻塞接收线程 → 嵌套响应无人读取 → pending 超时；
        // 修复后 handler 在独立线程执行，接收线程继续读取嵌套响应。
        let (a, b) = MemDuplexTransport.pair()
        let client = JsonRpcClient(a, framing: NewlineFraming())
        let server = JsonRpcServer(b, framing: NewlineFraming())
        client.start()
        server.start()

        // 对端 server 提供嵌套调用目标
        server.register("svc/calc", { _ =>
            HandlerResult.ok(JsonValue.fromObject(AddResult(7)))
        })
        // client 收到 outer/call 后，同连接内同步调用 svc/calc 并返回结果
        client.registerRequestHandler("outer/call", { req =>
            match (client.call<JsonValue, JsonValue>("svc/calc", params: None)) {
                case Ok(v) => Some(v)
                case Err(e) => Some(JsonValue.fromObject(AddResult(-1)))
            }
        })

        let r = server.request<JsonValue, JsonValue>("outer/call", params: None, timeout: 5 * Duration.second)
        match (r) {
            case Ok(v) =>
                match (v["value"]) {
                    case Some(JsonValue.Number(n)) => @Expect(n, 7.0)
                    case _ => @Fail("expected nested result 7")
                }
            case Err(e) => @Fail("nested call deadlocked/timeout: ${e}")
        }
        client.close()
        server.close()
    }
}
