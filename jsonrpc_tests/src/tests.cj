package jsonrpc_tests

import ystyle::jsonrpc.*
import jsonvalue.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class FramingTest {
    @TestCase
    func testEncodeDecodeRoundtrip(): Unit {
        let body = "hello world".toArray()
        let encoded = encode(body)
        let decoded = decode(encoded)
        @Expect(decoded.isSome())
        match (decoded) {
            case Some(d) => @Expect(body.size, d.size)
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
        let resp = Response(RequestId.Int(1), result: Some(JsonValue.parse("{\"ok\":true}")))
        let bytes = serializeResponse(resp)
        let str = String.fromUtf8(bytes)
        @Expect(str.contains("\"result\""))
        @Expect(!str.contains("\"error\""))
    }

    @TestCase
    func testSerializeErrorResponse(): Unit {
        let resp = Response(RequestId.Int(1), error: JsonRpcError(-32601, "Not found"))
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