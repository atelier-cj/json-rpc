package jsonrpc_tests

import ystyle::jsonrpc.*
import jsonvalue.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// ── 大整数 id 精度（流式直连修复：不再经 jsonvalue DOM 的 Float64 往返）──

@Test
class LargeIdPrecisionTest {
    @TestCase
    func testParseMessagePreservesLargeIntId(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":9007199254740993,\"method\":\"m\"}"
        match (parseMessage(json.toArray())) {
            case Message.SingleRequest(req) =>
                match (req.id) {
                    case RequestId.Int(i) => @Expect(i, 9007199254740993)
                    case _ => @Fail("expected Int id")
                }
            case _ => @Fail("expected SingleRequest")
        }
    }

    @TestCase
    func testDeserializePreservesLargeIntId(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":9007199254740993,\"method\":\"m\"}"
        let req = deserializeRequest(json.toArray())
        match (req.id) {
            case RequestId.Int(i) => @Expect(i, 9007199254740993)
            case _ => @Fail("expected Int id")
        }
    }

    @TestCase
    func testSerializePreservesLargeIntId(): Unit {
        let req = Request(RequestId.Int(9007199254740993), "m")
        let str = String.fromUtf8(serializeRequest(req))
        @Expect(str.contains("9007199254740993"))
        @Expect(!str.contains("9007199254740992"))
    }
}

// ── 解析错误语义（gjson 分类 + 流式直连后的行为固定）──

@Test
class ParseErrorSemanticsTest {
    @TestCase
    func testMalformedJsonThrowsParseError(): Unit {
        try {
            let _ = parseMessage("{\"jsonrpc\":\"2.0\",".toArray())
            @Fail("expected parse error")
        } catch (e: JsonRpcException) {
            @Expect(e.code, ErrorCodes.PARSE_ERROR)
        }
    }

    @TestCase
    func testTrailingGarbageThrowsParseError(): Unit {
        // 行为收紧：ValidBytes 拒绝合法值后的尾随垃圾（原 jsonvalue 路径会静默忽略）
        try {
            let _ = parseMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"} x".toArray())
            @Fail("expected parse error")
        } catch (e: JsonRpcException) {
            @Expect(e.code, ErrorCodes.PARSE_ERROR)
        }
    }

    @TestCase
    func testNullMethodIsLenientConverted(): Unit {
        // stdx readValue<String> 对 null 宽容转换为 "null"（新旧路径一致的既有语义，予以固定）
        match (parseMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":null}".toArray())) {
            case Message.SingleRequest(req) => @Expect(req.method, "null")
            case _ => @Fail("expected SingleRequest")
        }
    }

    @TestCase
    func testNumberMethodIsLenientConverted(): Unit {
        match (parseMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":123}".toArray())) {
            case Message.SingleRequest(req) => @Expect(req.method, "123")
            case _ => @Fail("expected SingleRequest")
        }
    }

    @TestCase
    func testEmptyBatchIsInvalidRequest(): Unit {
        try {
            let _ = parseMessage("[]".toArray())
            @Fail("expected invalid request")
        } catch (e: JsonRpcException) {
            @Expect(e.code, ErrorCodes.INVALID_REQUEST)
            @Expect(e.message, "Empty batch")
        }
    }

    @TestCase
    func testBatchItemInvalidVersion(): Unit {
        let json = "[{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"a\"}]"
        match (parseMessage(json.toArray())) {
            case Message.BatchRequest(items) =>
                @Expect(items.size, 1)
                match (items[0]) {
                    case Message.InvalidRequest(err) => @Expect(err.code, ErrorCodes.INVALID_REQUEST)
                    case _ => @Fail("expected InvalidRequest")
                }
            case _ => @Fail("expected BatchRequest")
        }
    }

    @TestCase
    func testServerSendsParseErrorForMalformedBody(): Unit {
        let (a, b) = MemDuplexTransport.pair()
        let server = JsonRpcServer(b, framing: NewlineFraming())
        server.start()
        a.send("{\"jsonrpc\":\"2.0\",\n".toArray())
        var got: ?Array<Byte> = None
        for (_ in 0..20) {
            match (a.receive()) {
                case Some(d) => got = Some(d); break
                case None => sleep(20 * Duration.millisecond)
            }
        }
        match (got) {
            case Some(d) => @Expect(String.fromUtf8(d).contains("-32700"))
            case None => @Fail("no response")
        }
        server.close()
    }
}

// ── 快速路由（gjson 提取 method，未知方法不解析完整 JSON）──

@Test
class FastRouteTest {
    private static func makePair(): (JsonRpcClient, JsonRpcServer) {
        let (a, b) = MemDuplexTransport.pair()
        let client = JsonRpcClient(a, framing: NewlineFraming())
        let server = JsonRpcServer(b, framing: NewlineFraming())
        client.start()
        server.start()
        (client, server)
    }

    private static func rawRequest(server: JsonRpcServer, a: MemDuplexTransport, raw: String): ?String {
        a.send(raw.toArray())
        var got: ?Array<Byte> = None
        for (_ in 0..20) {
            match (a.receive()) {
                case Some(d) => got = Some(d); break
                case None => sleep(20 * Duration.millisecond)
            }
        }
        match (got) {
            case Some(d) => Some(String.fromUtf8(d))
            case None => None
        }
    }

    @TestCase
    func testUnknownMethodReturnsMethodNotFound(): Unit {
        let (client, server) = makePair()
        let result = client.call<JsonValue, JsonValue>("no/such/method", params: None)
        match (result) {
            case Err(e) =>
                @Expect(e.contains("-32601"))
                @Expect(e.contains("no/such/method"))
            case Ok(_) => @Fail("expected method-not-found error")
        }
        client.close()
        server.close()
    }

    @TestCase
    func testUnknownMethodStringIdEcho(): Unit {
        let (a, b) = MemDuplexTransport.pair()
        let server = JsonRpcServer(b, framing: NewlineFraming())
        server.start()
        match (rawRequest(server, a, "{\"jsonrpc\":\"2.0\",\"id\":\"req-42\",\"method\":\"no/such\"}\n")) {
            case Some(str) =>
                @Expect(str.contains("\"id\":\"req-42\""))
                @Expect(str.contains("-32601"))
            case None => @Fail("no response received")
        }
        server.close()
    }

    @TestCase
    func testUnknownMethodLargeIntIdEcho(): Unit {
        // 快速拒绝用 gjson raw 重建 id，不能丢精度
        let (a, b) = MemDuplexTransport.pair()
        let server = JsonRpcServer(b, framing: NewlineFraming())
        server.start()
        match (rawRequest(server, a, "{\"jsonrpc\":\"2.0\",\"id\":9007199254740993,\"method\":\"no/such\"}\n")) {
            case Some(str) =>
                @Expect(str.contains("\"id\":9007199254740993"))
                @Expect(str.contains("-32601"))
            case None => @Fail("no response received")
        }
        server.close()
    }

    @TestCase
    func testRegisteredMethodStillWorks(): Unit {
        let (client, server) = makePair()
        server.register("ping", { _ => HandlerResult.ok(JsonValue.String("pong")) })
        let result = client.call<JsonValue, JsonValue>("ping", params: None)
        match (result) {
            case Ok(v) => @Expect(v.asString(), Some("pong"))
            case Err(e) => @Fail("ping failed: ${e}")
        }
        client.close()
        server.close()
    }

    @TestCase
    func testNotificationUnknownMethodNoResponse(): Unit {
        let (a, b) = MemDuplexTransport.pair()
        let server = JsonRpcServer(b, framing: NewlineFraming())
        server.start()
        a.send("{\"jsonrpc\":\"2.0\",\"method\":\"no/such\"}\n".toArray())
        // 通知不应有响应
        match (a.receive()) {
            case Some(_) => @Fail("notification should not produce a response")
            case None => () // 超时无响应，符合预期
        }
        server.close()
    }

    @TestCase
    func testMiddlewareDisablesFastPath(): Unit {
        // 有中间件时必须走完整解析路径，中间件可拦截未知方法
        let (a, b) = MemDuplexTransport.pair()
        let server = JsonRpcServer(b, framing: NewlineFraming())
        server.use({ ctx, next =>
            if (ctx.request.method == "no/such") {
                HandlerResult.ok(JsonValue.String("intercepted"))
            } else {
                next()
            }
        })
        server.start()
        match (rawRequest(server, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"no/such\"}\n")) {
            case Some(str) => @Expect(str.contains("\"result\":\"intercepted\""))
            case None => @Fail("middleware did not intercept")
        }
        server.close()
    }
}
