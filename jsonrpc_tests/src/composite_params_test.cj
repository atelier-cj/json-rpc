package jsonrpc_tests

import ystyle::jsonrpc.*
import jsonvalue.*
import std.unittest.*
import std.unittest.testmacro.*

// 复合 params（对象/数组）的解析回归：ACP 一类协议的请求参数几乎都是对象，
// 且参数内部还会嵌套对象/数组。这些形状必须与 stdx JsonReader 的版本演进无关地稳定解析：
// 既不能抛「Commas are required ...」，也不能吃掉外层对象的闭合。
@Test
class CompositeParamsTest {
    // 复合 params 作为最后一个成员（最常见的 ACP initialize 形状）
    @TestCase
    func testObjectParamsLastMember(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"," +
            "\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":true}}}}"
        match (parseMessage(json.toArray())) {
            case Message.SingleRequest(req) =>
                @Expect(req.method, "initialize")
                let params = req.params.getOrThrow()
                match (params) {
                    case JsonValue.Map(m) =>
                        @Expect(m.contains("protocolVersion"), true)
                        @Expect(m.contains("clientCapabilities"), true)
                    case _ => @Fail("params 应为对象")
                }
            case _ => @Fail("应为 SingleRequest")
        }
    }

    // 复合 params 后面还有其他成员（afterRead 状态机最容易错乱的形状）
    @TestCase
    func testObjectParamsFollowedByOtherMembers(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"params\":{\"a\":{\"b\":[1,2]}},\"id\":7,\"method\":\"m\"}"
        match (parseMessage(json.toArray())) {
            case Message.SingleRequest(req) =>
                @Expect(req.method, "m")
                match (req.params.getOrThrow()) {
                    case JsonValue.Map(m) => @Expect(m.contains("a"), true)
                    case _ => @Fail("params 应为对象")
                }
            case _ => @Fail("应为 SingleRequest")
        }
    }

    // 数组 params
    @TestCase
    func testArrayParams(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"sum\",\"params\":[1,2,3]}"
        match (parseMessage(json.toArray())) {
            case Message.SingleRequest(req) =>
                match (req.params.getOrThrow()) {
                    case JsonValue.Array(a) => @Expect(a.size, 3)
                    case _ => @Fail("params 应为数组")
                }
            case _ => @Fail("应为 SingleRequest")
        }
    }

    // 通知（无 id）同样带复合 params
    @TestCase
    func testNotificationWithObjectParams(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"method\":\"notify\",\"params\":{\"k\":{\"n\":1}}}"
        match (parseMessage(json.toArray())) {
            case Message.SingleNotification(n) =>
                @Expect(n.method, "notify")
                match (n.params.getOrThrow()) {
                    case JsonValue.Map(m) => @Expect(m.contains("k"), true)
                    case _ => @Fail("params 应为对象")
                }
            case _ => @Fail("应为 SingleNotification")
        }
    }

    // 响应的复合 result
    @TestCase
    func testResponseWithObjectResult(): Unit {
        let json = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true,\"items\":[{\"x\":1}]}}"
        match (parseMessage(json.toArray())) {
            case Message.SingleResponse(resp) =>
                match (resp.result.getOrThrow()) {
                    case JsonValue.Map(m) => @Expect(m.contains("ok"), true)
                    case _ => @Fail("result 应为对象")
                }
            case _ => @Fail("应为 SingleResponse")
        }
    }
}
