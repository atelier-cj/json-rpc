package jsonrpc_tests

import ystyle::jsonrpc.*
import jsonvalue.*
import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// ── 服务端「主动请求」（server → client 反向调用）的并发配对回归 ──
//
// 缺陷（修复前）：JsonRpcServer 用**单个** `pendingRequest` 槽承载全部在飞的反向请求，
// 且 `request()` 的 id 恒为 `RequestId.Int(0)`、`handleOutgoingResponse()` **不看 `resp.id`**
// 就投给那唯一一个槽。两个请求同时在飞时：
//   - 后者的槽覆盖前者 → 前者永远收不到响应，只能等到超时；
//   - 先回来的响应投给"当前"那个槽 → 张冠李戴（B 拿到 A 的答案）。
//
// 现实调用方：`acp-cj` 的 9 种反向调用（`session/request_permission` / `fs/*` / `terminal/*` /
// `elicitation/create`）—— 现在靠调用方 `synchronized(clientRequestLock)` 把并发串行化兜住，
// 代价是锁横跨整个往返（`terminalWaitForExit` 超时可到 10 分钟，期间其它反向调用全被堵住）；
// `lsp-cj` 的 `client/registerCapability` / `workspace/applyEdit` / `workspace/configuration`
// 等包装**没有**这把锁。
//
// 修复后：`pendingRequests: HashMap<RequestId, PendingRequest>`，`request()` 自增分配 id，
// `handleOutgoingResponse()` 按 `resp.id` 查表投递、查不到就忽略（迟到的响应自然丢弃）。

@Test
class ServerOutgoingRequestConcurrencyTest {

    // 后发先至：first 先入飞但响应慢，second 后入飞但响应快
    @TestCase
    func testSecondResponseArrivesFirst(): Unit {
        assertBothRequestsPaired(400, 0)
    }

    // 先发先至但槽已被后来者占用：first 的响应先回来，此时槽里是 second
    @TestCase
    func testFirstResponseArrivesWhileSecondInFlight(): Unit {
        assertBothRequestsPaired(300, 600)
    }

    // 两个并发反向请求必须各自拿到自己的响应，与响应回来的先后无关
    private func assertBothRequestsPaired(firstDelayMs: Int64, secondDelayMs: Int64): Unit {
        let (a, b) = BlockingDuplexTransport.pair()
        let client = JsonRpcClient(a, framing: NewlineFraming())
        let server = JsonRpcServer(b, framing: NewlineFraming())
        client.start()
        server.start()

        client.registerRequestHandler("svc/first", { _ =>
            sleep(firstDelayMs * Duration.millisecond)
            Some(JsonValue.String("first"))
        })
        client.registerRequestHandler("svc/second", { _ =>
            sleep(secondDelayMs * Duration.millisecond)
            Some(JsonValue.String("second"))
        })

        let box = OutgoingResultBox()
        spawn {
            box.setFirst(outgoingTextOf(server.request<JsonValue, JsonValue>("svc/first",
                params: None, timeout: 3 * Duration.second)))
        }
        // 让 first 先进入在飞状态
        sleep(50 * Duration.millisecond)
        let second = outgoingTextOf(server.request<JsonValue, JsonValue>("svc/second",
            params: None, timeout: 3 * Duration.second))

        @Expect(second, "second")
        @Expect(box.waitFirst(6000), "first")

        client.close()
        server.close()
    }
}

func outgoingTextOf(r: Result<JsonValue>): String {
    match (r) {
        case Ok(v) => match (v) {
            case JsonValue.String(s) => s
            case _ => "<non-string>"
        }
        case Err(e) => "ERR: " + e
    }
}

// 跨协程收集 first 请求的结果（lambda 不能捕获可变局部变量，用对象字段 + 条件变量）
class OutgoingResultBox {
    private let lock = Mutex()
    private let cond: Condition
    private var first: ?String = None

    public init() {
        this.cond = synchronized(this.lock) {
            this.lock.condition()
        }
    }

    public func setFirst(v: String): Unit {
        synchronized(this.lock) {
            this.first = Some(v)
            this.cond.notifyAll()
        }
    }

    public func waitFirst(timeoutMs: Int64): String {
        synchronized(this.lock) {
            var waited: Int64 = 0
            while (this.first.isNone() && waited < timeoutMs) {
                this.cond.wait(timeout: 100 * Duration.millisecond)
                waited += 100
            }
            match (this.first) {
                case Some(v) => v
                case None => "<no result>"
            }
        }
    }
}

// ── 阻塞式内存传输 ──
// 不复用 tests.cj 的 MemPipe：它空闲 50ms 就 `return None`，而 `JsonRpcServer.receiveLoop`
// 把 `None` 当作「传输已关闭」→ 服务器会在空闲时自己停掉，导致带延迟的用例出现假失败。
// 真实传输（stdio/tcp/http）的 receive 都是阻塞到有数据或 EOF，这里按同样的契约实现。

class BlockingPipe {
    private let buf = ByteBuffer()
    private let lock = Mutex()
    private let cond: Condition
    private var closed = false

    init() {
        this.cond = synchronized(this.lock) {
            this.lock.condition()
        }
    }

    func write(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            this.buf.write(data)
            this.cond.notifyAll()
        }
    }

    func read(): ?Array<Byte> {
        synchronized(this.lock) {
            while (this.buf.remainLength == 0 && !this.closed) {
                this.cond.wait()
            }
            if (this.buf.remainLength == 0) {
                return None
            }
            let size = this.buf.remainLength
            let data = Array<Byte>(size, repeat: 0)
            this.buf.read(data)
            Some(data)
        }
    }

    func close(): Unit {
        synchronized(this.lock) {
            this.closed = true
            this.cond.notifyAll()
        }
    }
}

class BlockingDuplexTransport <: Transport {
    private let out: BlockingPipe
    private let input: BlockingPipe
    private var closed = false

    private init(out: BlockingPipe, input: BlockingPipe) {
        this.out = out
        this.input = input
    }

    static func pair(): (BlockingDuplexTransport, BlockingDuplexTransport) {
        let ab = BlockingPipe()
        let ba = BlockingPipe()
        (BlockingDuplexTransport(ab, ba), BlockingDuplexTransport(ba, ab))
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
