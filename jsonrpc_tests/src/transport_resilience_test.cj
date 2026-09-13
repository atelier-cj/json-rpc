package jsonrpc_tests

import ystyle::jsonrpc.*
import jsonvalue.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// ── 接收循环/连接的「失败可见性」回归（2026-09-13 修复）──
//
// 修复前的两族缺陷（都只修了 server 侧，client 侧原封不动）：
//
// 族 1（catch Error/Exception 覆盖）：
//   `JsonRpcClient.receiveLoop` **完全没有 try/catch** —— 传输层抛异常（对端断开时
//   socket read 抛 ConnectionException 是常态）直接逃逸杀死接收线程，而 `running`
//   仍为 true、在途调用无人唤醒 → 所有调用只能干等满 timeout（默认 30s）= 客户端挂起。
//   且 `client.cj` 全文件没有一处 `catch (e: Error)` —— OOM 这类系统级错误同样杀循环
//   （server 侧 81f1eed 专门修过这一条）。
//   `handleMessage` 的 `catch { () }` 与通知回调的吞异常也让失败完全不可见。
//
// 族 2（连接 close）：
//   `close()` 与传输 EOF 都只翻 `running` 标志，**不唤醒 `pendingRequests`** →
//   连接已经没了，每个在途调用仍要干等满 timeout 才返回。

/** 接收即抛异常的传输桩：模拟连接级失败（socket read 抛 ConnectionException 的场景） */
class ThrowingTransport <: Transport {
    private let ex: Exception
    private var closed = false

    public init(ex: Exception) {
        this.ex = ex
    }

    public func send(data: Array<Byte>): Unit {}

    public func receive(): ?Array<Byte> {
        throw this.ex
    }

    public func close(): Unit {
        this.closed = true
    }

    public func isClosed(): Bool {
        this.closed
    }
}

/** 永不回应、只能被 close 打断的传输桩（close 前一直阻塞） */
class SilentTransport <: Transport {
    private let lock = Mutex()
    private var closed = false

    public func send(data: Array<Byte>): Unit {}

    public func receive(): ?Array<Byte> {
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

@Test
class TransportResilienceTest {

    // 接收抛异常 → 在途调用必须**立刻**失败并说明原因，而不是等满 timeout。
    // timeout 故意给 30s：若修复失效（异常杀线程、无人唤醒），本用例会等满 30s
    // 且拿到 "Request timeout"（把"挂起"断言成可观测的失败）。
    @TestCase
    func testReceiveExceptionFailsPendingCallFast(): Unit {
        let client = JsonRpcClient(ThrowingTransport(Exception("peer reset")), framing: NewlineFraming())
        client.start()

        let r = client.call<JsonValue, JsonValue>("ping", params: None, timeout: 30 * Duration.second)
        match (r) {
            case Err(msg) => @Expect(msg.contains("Connection unavailable"))
            case Ok(_) => @Fail("expected fast failure, got a response")
        }
        // 连接级异常后客户端应处于已关闭状态（而不是"运行中但已死"）
        @Expect(client.isClosed())
        client.close()
    }

    // close() 必须唤醒在途调用：对端永不回应时，close 应让调用立刻返回，
    // 而不是干等满 timeout（修复前 pendingRequests 从不被唤醒）。
    @TestCase
    func testCloseWakesPendingCall(): Unit {
        let client = JsonRpcClient(SilentTransport(), framing: NewlineFraming())
        client.start()

        let f = spawn {
            sleep(200 * Duration.millisecond)
            client.close()
        }
        let r = client.call<JsonValue, JsonValue>("ping", params: None, timeout: 30 * Duration.second)
        match (r) {
            case Err(msg) => @Expect(msg.contains("Connection unavailable"))
            case Ok(_) => @Fail("expected failure after close")
        }
        let _ = f
    }

    // 一条坏消息不能杀死接收循环：坏消息之后，正常响应仍必须被处理。
    // 注：用 BlockingDuplexTransport 而非 MemDuplexTransport —— 后者的 MemPipe
    // 空闲时返回 None，会被 receiveLoop 当成 EOF（"传输已关闭"）。
    @TestCase
    func testBadMessageDoesNotKillReceiveLoop(): Unit {
        let (a, b) = BlockingDuplexTransport.pair()
        let client = JsonRpcClient(a, framing: NewlineFraming())
        client.start()

        // 1) 先喂一条非 JSON 的坏消息（解析失败，走 handleMessage 的异常分支）
        b.send("not-a-json\n".toArray())
        // 2) 再让对端回应首个真实请求（id 从 1 开始）：拿得到响应 = 循环还活着
        spawn {
            sleep(200 * Duration.millisecond)
            b.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n".toArray())
        }

        let r = client.call<JsonValue, JsonValue>("ping", params: None, timeout: 5 * Duration.second)
        match (r) {
            case Ok(_) => ()
            case Err(msg) => @Fail("receive loop died after a bad message: ${msg}")
        }
        @Expect(!client.isClosed())
        client.close()
    }
}
