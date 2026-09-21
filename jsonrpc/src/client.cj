package ystyle::jsonrpc

import jsonvalue.*
import std.collection.concurrent.*
import std.collection.{HashMap, ArrayList}
import std.sync.*
import std.io.*
import stdx.encoding.json.stream.*

public class PendingRequest {
    public let id: RequestId
    private var response: ?Response = None
    // 连接已不可用时的失败原因。与"响应超时"区分开：连接断了要立刻失败，
    // 而不是让调用方干等满 timeout（默认 30s）——那是"挂起"症状的来源。
    private var failure: ?String = None
    private let lock: Mutex = Mutex()
    private let cond: Condition

    public init(id: RequestId) {
        this.id = id
        this.cond = synchronized(this.lock) {
            this.lock.condition()
        }
    }

    public func setResponse(resp: Response): Unit {
        synchronized(this.lock) {
            this.response = resp
            this.cond.notifyAll()
        }
    }

    /** 连接已不可用：立刻唤醒等待者并记录原因（幂等，首个原因保留）。 */
    public func cancel(reason: String): Unit {
        synchronized(this.lock) {
            if (this.response.isNone() && this.failure.isNone()) {
                this.failure = Some(reason)
            }
            this.cond.notifyAll()
        }
    }

    public func failureReason(): ?String {
        synchronized(this.lock) {
            this.failure
        }
    }

    public func waitForResponse(timeout!: Duration = 30 * Duration.second): ?Response {
        synchronized(this.lock) {
            while (this.response.isNone() && this.failure.isNone()) {
                if (!this.cond.wait(timeout: timeout)) {
                    return None
                }
            }
            this.response
        }
    }
}

public type NotificationCallback = (Notification) -> Unit
public type RequestCallback = (Request) -> ?JsonValue

public class JsonRpcClient {
    private let transport: Transport
    private let framing: Framing
    private let pendingRequests: ConcurrentHashMap<RequestId, PendingRequest> = ConcurrentHashMap<RequestId, PendingRequest>()
    private let lock: Mutex = Mutex()
    private var nextId: Int64 = 1
    private var running: Bool = false
    private var receiveThread: ?Future<Unit> = None
    // 通知回调列表（set 覆盖、add 追加；接收循环遍历调用全部）
    private let notificationCbs: ArrayList<NotificationCallback> = ArrayList<NotificationCallback>()
    private let requestHandlers: HashMap<String, RequestCallback> = HashMap<String, RequestCallback>()

    public init(transport: Transport, framing!: Framing = ContentLengthFraming()) {
        this.transport = transport
        this.framing = framing
    }

    /**
     * 设置单个通知回调（覆盖已有回调）
     */
    public func setNotificationCallback(cb: NotificationCallback): Unit {
        synchronized(this.lock) {
            this.notificationCbs.clear()
            this.notificationCbs.add(cb)
        }
    }

    /**
     * 设置多个通知回调（整体覆盖已有回调）
     */
    public func setNotificationCallback(cbs: ArrayList<NotificationCallback>): Unit {
        synchronized(this.lock) {
            this.notificationCbs.clear()
            for (cb in cbs) {
                this.notificationCbs.add(cb)
            }
        }
    }

    /**
     * 追加一个通知回调（保留已有回调）
     */
    public func addNotificationCallback(cb: NotificationCallback): Unit {
        synchronized(this.lock) {
            this.notificationCbs.add(cb)
        }
    }

    public func registerRequestHandler(method: String, handler: RequestCallback): Unit {
        this.requestHandlers.add(method, handler)
    }

    public func sendResponse(id: RequestId, result: JsonValue): Unit {
        let resp = Response(id: Some(id), result: result)
        let bytes = serializeResponse(resp)
        this.transport.send(this.framing.encode(bytes))
    }

    public func start(): Unit {
        this.running = true
        this.receiveThread = spawn {
            => this.receiveLoop()
        }
    }

    public func call<T, R>(method: String, params!: ?T, timeout!: Duration = 30 * Duration.second): Result<R> 
        where T <: JsonSerializable, R <: JsonDeserializable<R> {
        let id = this.generateId()
        let req = Request(id, method, params: this.toJsonValue(params))
        let bytes = serializeRequest(req)
        let pending = PendingRequest(id)
        this.pendingRequests.add(id, pending)
        try {
            this.transport.send(this.framing.encode(bytes))
        } catch (e: Exception) {
            // 送不出去（传输已关闭 / 对端断开 / HTTP 层失败）时必须撤掉在途记录：
            // 留着它既是泄漏，也会让「之后再出现同 id 的响应」投给一个没人等的槽位。
            // 异常照常向调用方冒泡——那才是立刻可见的失败（等待只能等来超时）。
            this.pendingRequests.remove(id)
            throw e
        }

        match (pending.waitForResponse(timeout: timeout)) {
            case Some(resp) =>
                this.pendingRequests.remove(id)
                if (let Some(result) <- resp.result) {
                    try {
                        Result.Ok(JsonValue.toObject<R>(result))
                    } catch (e: Exception) {
                        Result.Err("Failed to parse result: ${e.message}")
                    }
                } else if (let Some(error) <- resp.error) {
                    Result.Err("[${error.code}] ${error.message}")
                } else {
                    Result.Err("Invalid response")
                }
            case None =>
                this.pendingRequests.remove(id)
                // 区分「连接已不可用（立刻失败）」与「真的等满了 timeout」：
                // 后者会把"连接死了"误诊成"对端慢/没回"
                match (pending.failureReason()) {
                    case Some(reason) => Result.Err("Connection unavailable: ${reason}")
                    case None => Result.Err("Request timeout")
                }
        }
    }

    public func call(method: String, timeout!: Duration = 30 * Duration.second): Result<JsonValue> {
        this.call<JsonValue, JsonValue>(method, params: None, timeout: timeout)
    }

    public func notify<T>(method: String, params!: ?T): Unit where T <: JsonSerializable {
        let notif = Notification(method, params: this.toJsonValue(params))
        let bytes = serializeNotification(notif)
        this.transport.send(this.framing.encode(bytes))
    }

    public func notify(method: String): Unit {
        this.notify<JsonValue>(method, params: None)
    }

    public func close(): Unit {
        this.shutdown("client closed")
        if (let Some(thread) <- this.receiveThread) {
            thread.cancel()
        }
    }

    /**
     * 停机：置 running=false + **唤醒全部在途调用** + 关闭传输。
     *
     * 唤醒在途调用是关键：连接已经没了，若只关传输不唤醒，每个调用仍要干等满
     * timeout（默认 30s）才返回——这正是"客户端挂起"的直接来源。
     * 独立于 close() 是为了让 receiveLoop 内部也能调用（不能 cancel 自己）。
     */
    private func shutdown(reason: String): Unit {
        synchronized(this.lock) {
            this.running = false
        }
        for ((_, pending) in this.pendingRequests) {
            pending.cancel(reason)
        }
        this.transport.close()
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            !this.running
        }
    }

    /**
     * 当前在途（已发出、尚未拿到响应或失败）的调用数。
     *
     * 用于诊断与回归：正常收尾后必须回到 0——`send` 失败或响应处理异常时若把它
     * 留在表里，就是一条只增不减的泄漏。
     */
    public func inFlightCount(): Int64 {
        this.pendingRequests.size
    }
    
    private func generateId(): RequestId {
        synchronized(this.lock) {
            let id = this.nextId
            this.nextId++
            RequestId.Int(id)
        }
    }

    private func toJsonValue<T>(params: ?T): ?JsonValue where T <: JsonSerializable {
        match (params) {
            case Some(p) => Some(JsonValue.fromObject(p))
            case None => None
        }
    }

    private func receiveLoop(): Unit {
        let buffer = ByteBuffer()
        while (this.running) {
            try {
                match (this.transport.receive()) {
                    case Some(data) =>
                        buffer.write(data)
                        while (let Some((body, consumed)) <- this.framing.decode(buffer.bytes())) {
                            this.handleMessage(body)
                            buffer.seek(SeekPosition.Current(consumed))
                        }
                    case None =>
                        // 对端关闭：不能只翻 running 标志——必须 shutdown 唤醒在途调用，
                        // 否则它们还要干等满 timeout（默认 30s）
                        eprintln("[jsonrpc] client transport closed by peer")
                        this.shutdown("transport closed by peer")
                }
            } catch (e: Exception) {
                // 连接级异常（对端断开时 socket read 抛 ConnectionException 是常态）：
                // 此前 receiveLoop 没有任何 try —— 异常逃逸直接杀死接收线程，而
                // running 仍为 true、在途调用无人唤醒 → 所有后续调用挂到超时。
                // 记录 + shutdown（唤醒在途）+ 退出循环。
                eprintln("[jsonrpc] client receiveLoop error: " + e.toString())
                this.shutdown("receive loop error: " + e.toString())
            } catch (e: Error) {
                // 系统级错误（如 OOM 的 OutOfMemoryError）与 Exception 平行，同样不许
                // 逃逸杀接收协程；只记录并继续（对齐 server 侧 81f1eed 的取舍）
                eprintln("[jsonrpc] client receiveLoop system error: " + e.toString())
            }
        }
    }

    private func handleMessage(body: Array<Byte>): Unit {
        try {
            match (parseMessage(body)) {
                case Message.SingleResponse(resp) => this.handleResponse(resp)
                case Message.BatchResponse(resps) => for (resp in resps) {
                    this.handleResponse(resp)
                }
                case Message.SingleRequest(req) => this.handleIncomingRequest(req)
                case Message.SingleNotification(notif) =>
                    // 遍历调用全部通知回调（支持多订阅）
                    let cbs = synchronized(this.lock) {
                        ArrayList<NotificationCallback>(this.notificationCbs)
                    }
                    for (cb in cbs) {
                        try {
                            cb(notif)
                        } catch (e: Exception) {
                            // 通知回调抛异常不能静默：那是用户回调的 bug，
                            // 不记录的话表现为"通知收到了但没反应"
                            eprintln("[jsonrpc] notification callback error: " + e.toString())
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            // 单条消息处理异常不该杀接收循环，但也绝不能静默——
            // 协议/解析问题会完全不可见（表现是"请求发出去了没人管"）
            eprintln("[jsonrpc] client handleMessage error: " + e.toString())
        } catch (e: Error) {
            eprintln("[jsonrpc] client handleMessage system error: " + e.toString())
        }
    }

    private func handleIncomingRequest(req: Request): Unit {
        // 异步处理：请求 handler（如宿主转发其他插件的服务）可能阻塞等待
        // 响应；在独立线程执行避免接收线程被占用——否则本连接的其他消息
        // （如事件派发响应）无法读取，跨连接形成死锁
        // （见 harness Phase 2：agent 等待 llm invoke 响应 ↔ 宿主等待
        //   agent 的 dispatch 响应，两个接收线程互相阻塞）。
        let self = this
        spawn {
            try {
                match (self.requestHandlers.get(req.method)) {
                    case Some(handler) =>
                        match (handler(req)) {
                            case Some(result) =>
                                let resp = Response(id: Some(req.id), result: result)
                                let bytes = serializeResponse(resp)
                                self.transport.send(self.framing.encode(bytes))
                            case None => ()
                        }
                    case None =>
                        let error = JsonRpcError(-32601, "Method not found: ${req.method}")
                        let resp = Response(id: Some(req.id), error: error)
                        let bytes = serializeResponse(resp)
                        self.transport.send(self.framing.encode(bytes))
                }
            } catch (e: Exception) {
                let error = JsonRpcError(-32603, "Handler error: ${e.message}")
                let resp = Response(id: Some(req.id), error: error)
                let bytes = serializeResponse(resp)
                self.transport.send(self.framing.encode(bytes))
            }
        }
    }

    private func handleResponse(resp: Response): Unit {
        match (resp.id) {
            case Some(id) => match (this.pendingRequests.get(id)) {
                case Some(pending) => pending.setResponse(resp)
                case None => ()
            }
            case None => () // error response with no id, ignore
        }
    }
}