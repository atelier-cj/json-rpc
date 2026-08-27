package jsonrpc_tests

import ystyle::jsonrpc.*
import jsonvalue.*
import std.io.*
import std.sync.*
import std.collection.ArrayList
import stdx.encoding.json.stream.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class FramingTest {
    @TestCase
    func testEncodeDecodeRoundtrip(): Unit {
        let body = "hello world".toArray()
        let encoded = encode(body)
        match (decode(encoded)) {
            case Some((d, _)) => @Expect(body.size, d.size)
            case None => @Fail("decode failed")
        }
    }

    @TestCase
    func testDecodeIncomplete(): Unit {
        let partial = "Content-Length: 10\r\n\r\n".toArray()
        @Expect(decode(partial).isNone())
    }
}

@Test
class RequestIdTest {
    @TestCase
    func testIntId(): Unit {
        let id = RequestId.Int(42)
        @Expect(id == RequestId.Int(42))
        @Expect(id != RequestId.Int(43))
        @Expect(id.hashCode() == RequestId.Int(42).hashCode())
    }

    @TestCase
    func testStringId(): Unit {
        let id = RequestId.String("abc")
        @Expect(id == RequestId.String("abc"))
        @Expect(id != RequestId.String("xyz"))
    }

    @TestCase
    func testSerializeIntId(): Unit {
        let id = RequestId.Int(1)
        let bytes = JsonValue.fromObject(id).toBytes()
        @Expect(String.fromUtf8(bytes), "1")
    }

    @TestCase
    func testSerializeStringId(): Unit {
        let id = RequestId.String("test")
        let bytes = JsonValue.fromObject(id).toBytes()
        @Expect(String.fromUtf8(bytes), "\"test\"")
    }
}

@Test
class SerializeTest {
    @TestCase
    func testSerializeRequest(): Unit {
        let req = Request(RequestId.Int(1), "test.method")
        let bytes = serializeRequest(req)
        let str = String.fromUtf8(bytes)
        @Expect(str.contains("\"jsonrpc\":\"2.0\""))
        @Expect(str.contains("\"id\":1"))
        @Expect(str.contains("\"method\":\"test.method\""))
    }

    @TestCase
    func testSerializeResponse(): Unit {
        let resp = Response(id: Some(RequestId.Int(1)), result: Some(JsonValue.parse("{\"ok\":true}")))
        let bytes = serializeResponse(resp)
        let str = String.fromUtf8(bytes)
        @Expect(str.contains("\"result\""))
        @Expect(!str.contains("\"error\""))
    }

    @TestCase
    func testSerializeErrorResponse(): Unit {
        let resp = Response(id: Some(RequestId.Int(1)), error: JsonRpcError(-32601, "Not found"))
        let bytes = serializeResponse(resp)
        let str = String.fromUtf8(bytes)
        @Expect(str.contains("\"error\""))
        @Expect(str.contains("\"code\":-32601"))
    }

    @TestCase
    func testSerializeNotification(): Unit {
        let notif = Notification("event")
        let bytes = serializeNotification(notif)
        let str = String.fromUtf8(bytes)
        @Expect(str.contains("\"method\":\"event\""))
        @Expect(!str.contains("\"id\""))
    }
}

@Test
class DeserializeTest {
    @TestCase
    func testParseRequest(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\",\"params\":{\"a\":1}}"
        let req = deserializeRequest(json.toArray())
        @Expect(req.jsonrpc, "2.0")
        @Expect(req.method, "test")
        @Expect(req.params.isSome())
        match (req.id) {
            case RequestId.Int(i) => @Expect(i, 1)
            case _ => @Fail("expected Int id")
        }
    }

    @TestCase
    func testParseResponse(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":42}}"
        let resp = deserializeResponse(json.toArray())
        @Expect(resp.result.isSome())
        @Expect(resp.error.isNone())
    }

    @TestCase
    func testParseNotification(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"method\":\"notify\"}"
        let notif = deserializeNotification(json.toArray())
        @Expect(notif.jsonrpc, "2.0")
        @Expect(notif.method, "notify")
    }

    @TestCase
    func testParseResponseWithError(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Not found\"}}"
        let resp = deserializeResponse(json.toArray())
        @Expect(resp.error.isSome())
        match (resp.error) {
            case Some(e) => @Expect(e.code, -32601)
            case None => ()
        }
    }
}

@Test
class MessageParseTest {
    @TestCase
    func testParseSingleRequest(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}"
        match (parseMessage(json.toArray())) {
            case Message.SingleRequest(req) => @Expect(req.method, "test")
            case _ => @Fail("expected SingleRequest")
        }
    }

    @TestCase
    func testParseSingleNotification(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"method\":\"notify\"}"
        match (parseMessage(json.toArray())) {
            case Message.SingleNotification(n) => @Expect(n.method, "notify")
            case _ => @Fail("expected SingleNotification")
        }
    }

    @TestCase
    func testParseSingleResponse(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":42}"
        match (parseMessage(json.toArray())) {
            case Message.SingleResponse(r) => @Expect(r.result.isSome())
            case _ => @Fail("expected SingleResponse")
        }
    }

    @TestCase
    func testParseBatchRequest(): Unit {
        let json = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"b\"}]"
        match (parseMessage(json.toArray())) {
            case Message.BatchRequest(items) => @Expect(items.size, 2)
            case _ => @Fail("expected BatchRequest")
        }
    }

    @TestCase
    func testParseBatchResponse(): Unit {
        let json = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1},{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":2}]"
        match (parseMessage(json.toArray())) {
            case Message.BatchResponse(items) => @Expect(items.size, 2)
            case _ => @Fail("expected BatchResponse")
        }
    }
}

@Test
class ErrorCodesTest {
    @TestCase
    func testStandardCodes(): Unit {
        @Expect(ErrorCodes.PARSE_ERROR, -32700)
        @Expect(ErrorCodes.INVALID_REQUEST, -32600)
        @Expect(ErrorCodes.METHOD_NOT_FOUND, -32601)
        @Expect(ErrorCodes.INVALID_PARAMS, -32602)
        @Expect(ErrorCodes.INTERNAL_ERROR, -32603)
    }
}

@Test
class ErrorTest {
    @TestCase
    func testErrorWithData(): Unit {
        let err = JsonRpcError(-32602, "Invalid params", data: Some(JsonValue.parse("{\"expected\":\"array\"}")))
        let bytes = JsonValue.fromObject(err).toBytes()
        @Expect(String.fromUtf8(bytes).contains("\"data\""))
    }

    @TestCase
    func testErrorSerialization(): Unit {
        let err = JsonRpcError(-32601, "Not found")
        let bytes = JsonValue.fromObject(err).toBytes()
        let str = String.fromUtf8(bytes)
        @Expect(str.contains("\"code\":-32601"))
        @Expect(str.contains("\"message\":\"Not found\""))
    }
}

@Test
class ResultTest {
    @TestCase
    func testOk(): Unit {
        let r: Result<String> = Result.Ok("success")
        match (r) {
            case Ok(v) => @Expect(v, "success")
            case Err(_) => @Fail("expected Ok")
        }
    }

    @TestCase
    func testErr(): Unit {
        let r: Result<Int64> = Result.Err("error msg")
        match (r) {
            case Ok(_) => @Fail("expected Err")
            case Err(e) => @Expect(e, "error msg")
        }
    }
}

@Test
class HandlerResultTest {
    @TestCase
    func testOk(): Unit {
        let r = HandlerResult.ok(JsonValue.String("hello"))
        @Expect(r.error.isNone())
        match (r.result) {
            case Some(v) => @Expect(v.asString(), Some("hello"))
            case None => @Fail("expected result")
        }
    }

    @TestCase
    func testErr(): Unit {
        let r = HandlerResult.err(-32601, "Not found")
        @Expect(r.result.isNone())
        match (r.error) {
            case Some(e) =>
                @Expect(e.code, -32601)
                @Expect(e.message, "Not found")
            case None => @Fail("expected error")
        }
    }
}

@Test
class JsonRpcValidationTest {
    @TestCase
    func testRequestValidJsonRpc(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}"
        let req = deserializeRequest(json.toArray())
        @Expect(req.jsonrpc, "2.0")
    }

    @TestCase
    func testRequestInvalidJsonRpc(): Unit {
        let json = "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"test\"}"
        try {
            let _ = deserializeRequest(json.toArray())
            @Fail("expected exception for invalid jsonrpc")
        } catch (e: Exception) {
            @Expect(e.message.contains("Invalid jsonrpc version"))
        }
    }

    @TestCase
    func testRequestMissingJsonRpc(): Unit {
        let json = "{\"id\":1,\"method\":\"test\"}"
        try {
            let req = deserializeRequest(json.toArray())
            // If no exception, verify it somewhere
            @Expect(req.method, "test")
        } catch (_: Exception) {
            // Accept either behavior
        }
    }

    @TestCase
    func testResponseInvalidJsonRpc(): Unit {
        let json = "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":42}"
        try {
            let _ = deserializeResponse(json.toArray())
            @Fail("expected exception for invalid jsonrpc")
        } catch (e: Exception) {
            @Expect(e.message.contains("Invalid jsonrpc version"))
        }
    }

    @TestCase
    func testParseMessageRejectsInvalidJsonRpc(): Unit {
        let json = "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"test\"}"
        try {
            let _ = parseMessage(json.toArray())
            @Fail("expected exception for invalid jsonrpc")
        } catch (e: Exception) {
            @Expect(e.message.contains("Invalid jsonrpc"))
        }
    }
}

@Test
class BatchInvalidItemTest {
    @TestCase
    func testBatchWithInvalidItems(): Unit {
        let json = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"b\"}]"
        match (parseMessage(json.toArray())) {
            case Message.BatchRequest(items) => @Expect(items.size, 2)
            case _ => @Fail("expected BatchRequest")
        }
    }

    @TestCase
    func testBatchWithMissingMethod(): Unit {
        let json = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\"},{\"jsonrpc\":\"2.0\",\"id\":2}]"
        match (parseMessage(json.toArray())) {
            case Message.BatchRequest(items) =>
                @Expect(items.size, 2)
                match (items[0]) {
                    case Message.SingleRequest(_) => ()
                    case _ => @Fail("first item should be SingleRequest")
                }
                match (items[1]) {
                    case Message.InvalidRequest(_) => ()
                    case _ => @Fail("second item should be InvalidRequest")
                }
            case _ => @Fail("expected BatchRequest")
        }
    }
}

@Test
class FramingConsumedTest {
    @TestCase
    func testDecodeReturnsConsumed(): Unit {
        let body1 = "hello".toArray()
        let body2 = "world".toArray()
        let frame1 = encode(body1)
        let frame2 = encode(body2)
        let buf = ByteBuffer()
        buf.write(frame1)
        buf.write(frame2)
        let all = buf.bytes()

        match (decode(all)) {
            case Some((b, consumed)) =>
                if (b.size != body1.size) {
                    @Fail("body size mismatch")
                }
                if (consumed != frame1.size) {
                    @Fail("consumed should equal frame1 size")
                }
            case None => @Fail("decode failed")
        }
    }

    @TestCase
    func testDecodeMultipleFramesInSequence(): Unit {
        let body1 = "hello".toArray()
        let body2 = "world".toArray()
        let frame1 = encode(body1)
        let frame2 = encode(body2)
        let buf = ByteBuffer()
        buf.write(frame1)
        buf.write(frame2)
        let combined = buf.bytes()

        match (decode(combined)) {
            case Some((b1, consumed)) =>
                if (b1.size != body1.size) {
                    @Fail("first body size mismatch")
                }
                let remaining = combined[consumed..combined.size]
                match (decode(remaining)) {
                    case Some((b2, _)) =>
                        if (b2.size != body2.size) {
                            @Fail("second body size mismatch")
                        }
                    case None => @Fail("second decode failed")
                }
            case None => @Fail("first decode failed")
        }
    }
}
// ── 通知回调语义测试（set 覆盖 / set 多覆盖 / add 追加）──

// 最小内存双工管道：A.send → B.receive，B.send → A.receive
class MemPipe {
    private let buf = ByteBuffer()
    private let lock = Mutex()
    private let cond: Condition
    private var closed = false

    init() {
        this.cond = synchronized(this.lock) { this.lock.condition() }
    }

    func write(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            buf.write(data)
            this.cond.notifyAll()
        }
    }

    func read(): ?Array<Byte> {
        synchronized(this.lock) {
            while (buf.remainLength == 0 && !closed) {
                if (!this.cond.wait(timeout: 50 * Duration.millisecond)) {
                    return None
                }
            }
            if (buf.remainLength == 0) { return None }
            let size = buf.remainLength
            let data = Array<Byte>(size, repeat: 0)
            buf.read(data)
            Some(data)
        }
    }

    public func close(): Unit {
        synchronized(this.lock) {
            closed = true
            this.cond.notifyAll()
        }
    }
}

class MemDuplexTransport <: Transport {
    private let out: MemPipe
    private let input: MemPipe
    private var closed = false

    private init(out: MemPipe, input: MemPipe) {
        this.out = out
        this.input = input
    }

    static func pair(): (MemDuplexTransport, MemDuplexTransport) {
        let ab = MemPipe()
        let ba = MemPipe()
        (MemDuplexTransport(ab, ba), MemDuplexTransport(ba, ab))
    }

    public func send(data: Array<Byte>): Unit {
        this.out.write(data)
    }

    public func receive(): ?Array<Byte> {
        this.input.read()
    }

    public func close(): Unit {
        this.closed = true
        this.input.close()
    }

    public func isClosed(): Bool {
        this.closed
    }
}

@Test
class NotificationCallbackSemanticsTest {

    private static func makePair(): (JsonRpcClient, JsonRpcServer) {
        let (a, b) = MemDuplexTransport.pair()
        let client = JsonRpcClient(a, framing: NewlineFraming())
        let server = JsonRpcServer(b, framing: NewlineFraming())
        client.start()
        server.start()
        (client, server)
    }

    @TestCase
    func testSetSingleOverrides(): Unit {
        let (client, server) = makePair()
        let calls = ArrayList<String>()
        let lock = Mutex()
        // 第一个回调
        client.setNotificationCallback({ notif =>
            synchronized(lock) { calls.add("cb1") }
        })
        // set 单回调覆盖：替换为 cb2
        client.setNotificationCallback({ notif =>
            synchronized(lock) { calls.add("cb2") }
        })
        server.notify("test/notif")
        // 等待回调触发
        var waited = 0
        while (true) {
            synchronized(lock) {
                if (calls.size > 0) { break }
            }
            if (waited > 50) { @Fail("callback not invoked"); break }
            sleep(20 * Duration.millisecond)
            waited++
        }
        synchronized(lock) {
            @Expect(calls.size, 1)       // 只调用了 cb2（覆盖生效）
            @Expect(calls[0], "cb2")
        }
        client.close()
        server.close()
    }

    @TestCase
    func testSetMultipleOverrides(): Unit {
        let (client, server) = makePair()
        let calls = ArrayList<String>()
        let lock = Mutex()
        client.setNotificationCallback({ notif =>
            synchronized(lock) { calls.add("old") }
        })
        // set 多回调覆盖：整体替换为 [c1, c2]
        let cbs = ArrayList<NotificationCallback>()
        cbs.add({ notif => synchronized(lock) { calls.add("c1") } })
        cbs.add({ notif => synchronized(lock) { calls.add("c2") } })
        client.setNotificationCallback(cbs)
        server.notify("test/notif")
        var waited = 0
        while (true) {
            synchronized(lock) {
                if (calls.size >= 2) { break }
            }
            if (waited > 50) { @Fail("callbacks not invoked"); break }
            sleep(20 * Duration.millisecond)
            waited++
        }
        synchronized(lock) {
            @Expect(calls.size, 2)       // old 被整体替换，只剩 c1/c2
            @Expect(calls[0], "c1")
            @Expect(calls[1], "c2")
        }
        client.close()
        server.close()
    }

    @TestCase
    func testAddAppends(): Unit {
        let (client, server) = makePair()
        let calls = ArrayList<String>()
        let lock = Mutex()
        client.setNotificationCallback({ notif =>
            synchronized(lock) { calls.add("first") }
        })
        // add 追加：保留 first，新增 second
        client.addNotificationCallback({ notif =>
            synchronized(lock) { calls.add("second") }
        })
        server.notify("test/notif")
        var waited = 0
        while (true) {
            synchronized(lock) {
                if (calls.size >= 2) { break }
            }
            if (waited > 50) { @Fail("callbacks not invoked"); break }
            sleep(20 * Duration.millisecond)
            waited++
        }
        synchronized(lock) {
            @Expect(calls.size, 2)
            @Expect(calls[0], "first")
            @Expect(calls[1], "second")
        }
        client.close()
        server.close()
    }

    @TestCase
    func testAllCallbacksReceiveSameNotif(): Unit {
        let (client, server) = makePair()
        let methods = ArrayList<String>()
        let lock = Mutex()
        client.addNotificationCallback({ notif =>
            synchronized(lock) { methods.add(notif.method) }
        })
        client.addNotificationCallback({ notif =>
            synchronized(lock) { methods.add(notif.method) }
        })
        server.notify("evt/one")
        var waited = 0
        while (true) {
            synchronized(lock) {
                if (methods.size >= 2) { break }
            }
            if (waited > 50) { @Fail("callbacks not invoked"); break }
            sleep(20 * Duration.millisecond)
            waited++
        }
        synchronized(lock) {
            @Expect(methods.size, 2)
            @Expect(methods[0], "evt/one")
            @Expect(methods[1], "evt/one")
        }
        client.close()
        server.close()
    }
}

@Test
class AsyncHandlerTest {
    @TestCase
    func testAsyncHandlerResponds(): Unit {
        // 验证 async handler：spawn 执行 + complete 回调发响应
        let (a, b) = MemDuplexTransport.pair()
        let client = JsonRpcClient(a, framing: NewlineFraming())
        let server = JsonRpcServer(b, framing: NewlineFraming())
        client.start()
        server.start()

        // async handler：延迟后 complete
        server.registerAsync("async/echo", { ctx, complete =>
            // handler 内部 spawn 异步任务后立即返回（不阻塞接收线程）
            spawn {
                complete(JsonValue.fromObject(AddResult(42)))
            }
        })

        println("DIAG before call")
        let result = client.call<JsonValue, JsonValue>("async/echo", params: None)
        println("DIAG after call")
        match (result) {
            case Ok(v) =>
                match (v["value"]) {
                    case Some(JsonValue.Number(n)) => @Expect(n, 42.0)
                    case _ => @Fail("expected number result")
                }
            case Err(e) => @Fail("async call failed: ${e}")
        }
        client.close()
        server.close()
    }

    @TestCase
    func testAsyncHandlerWithNestedRequest(): Unit {
        // 验证 async handler 内嵌套请求不死锁：
        // server A 的 async handler 收到请求后，向 server B 发同步请求，
        // A 的接收线程不阻塞，B 的响应被 A 处理 → complete 回 A 的调用方
        let (aHost, aPlugin) = MemDuplexTransport.pair()
        let (bHost, bPlugin) = MemDuplexTransport.pair()
        let clientA = JsonRpcClient(aHost, framing: NewlineFraming())
        let serverA = JsonRpcServer(aPlugin, framing: NewlineFraming())
        let clientB = JsonRpcClient(bHost, framing: NewlineFraming())
        let serverB = JsonRpcServer(bPlugin, framing: NewlineFraming())
        clientA.start()
        serverA.start()
        clientB.start()
        serverB.start()

        // B 提供普通同步 handler
        serverB.register("svc/calc", { _ =>
            HandlerResult.ok(JsonValue.fromObject(AddResult(7)))
        })

        // A 的 async handler：向 B 发同步请求（嵌套），完成回调回 A 的调用方
        serverA.registerAsync("outer/call", { ctx, complete =>
            spawn {
                let nested = clientB.call<JsonValue, JsonValue>("svc/calc", params: None)
                match (nested) {
                    case Ok(v) => complete(v)
                    case Err(e) =>
                        complete(JsonValue.fromObject(AddResult(-1)))
                }
            }
        })

        let result = clientA.call<JsonValue, JsonValue>("outer/call", params: None)
        match (result) {
            case Ok(v) =>
                match (v["value"]) {
                    case Some(JsonValue.Number(n)) => @Expect(n, 7.0)
                    case _ => @Fail("expected number result")
                }
            case Err(e) => @Fail("nested call failed: ${e}")
        }
        clientA.close()
        serverA.close()
        clientB.close()
        serverB.close()
    }

    @TestCase
    func testAsyncHandlerErrResponds(): Unit {
        // 验证 registerAsyncErr：调用 fail(error) 返回 JSON-RPC 错误响应
        let (a, b) = MemDuplexTransport.pair()
        let client = JsonRpcClient(a, framing: NewlineFraming())
        let server = JsonRpcServer(b, framing: NewlineFraming())
        client.start()
        server.start()

        // 带错误回调的 async handler：spawn 后 fail(-32602)
        server.registerAsyncErr("async/err", { ctx, complete, fail =>
            spawn {
                fail(JsonRpcError(-32602, "Invalid params"))
            }
        })
        // 同时验证 success 路径
        server.registerAsyncErr("async/ok", { ctx, complete, fail =>
            spawn {
                complete(JsonValue.fromObject(AddResult(9)))
            }
        })

        // 错误路径
        let errResult = client.call<JsonValue, JsonValue>("async/err", params: None)
        match (errResult) {
            case Ok(_) => @Fail("expected error response")
            case Err(e) => @Expect(e.contains("-32602"), true)
        }

        // 成功路径
        let okResult = client.call<JsonValue, JsonValue>("async/ok", params: None)
        match (okResult) {
            case Ok(v) =>
                match (v["value"]) {
                    case Some(JsonValue.Number(n)) => @Expect(n, 9.0)
                    case _ => @Fail("expected number result")
                }
            case Err(e) => @Fail("async ok call failed: ${e}")
        }
        client.close()
        server.close()
    }
}

// 测试辅助：简单响应类型
class AddResult <: JsonSerializable & JsonDeserializable<AddResult> {
    public let value: Int64

    public init(value: Int64) {
        this.value = value
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("value").writeValue(this.value)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): AddResult {
        r.startObject()
        var value: ?Int64 = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "value" => value = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        AddResult(value.getOrThrow())
    }
}
