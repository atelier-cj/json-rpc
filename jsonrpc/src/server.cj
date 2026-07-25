package ystyle::jsonrpc

import jsonvalue.*
import std.collection.*
import std.sync.*
import std.io.*
import std.collection.concurrent.*
import stdx.encoding.json.stream.*

public type Middleware = (RequestContext, () -> HandlerResult) -> HandlerResult
public type Handler = (HandlerContext) -> HandlerResult

public class RequestContext {
    public let request: Request
    public let transport: Transport

    public init(request: Request, transport: Transport) {
        this.request = request
        this.transport = transport
    }
}

public class HandlerContext {
    private let params: ?JsonValue

    public init(params!: ?JsonValue = None) {
        this.params = params
    }

    public func getParam(key: String): ?JsonValue {
        match (this.params) {
            case Some(p) => p[key]
            case None => None
        }
    }

    public func getParamAs<T>(key: String): ?T where T <: JsonDeserializable<T> {
        match (this.getParam(key)) {
            case Some(v) => try {
                Some(JsonValue.toObject<T>(v))
            } catch (e: Exception) {
                None
            }
            case None => None
        }
    }

    public func getParams<T>(): ?T where T <: JsonDeserializable<T> {
        match (this.params) {
            case Some(v) => try {
                Some(JsonValue.toObject<T>(v))
            } catch (e: Exception) {
                None
            }
            case None => None
        }
    }

    public func getRawParams(): ?JsonValue {
        this.params
    }
}

public class HandlerResult {
    public let result: ?JsonValue
    public let error: ?JsonRpcError

    private init(result!: ?JsonValue = None, error!: ?JsonRpcError = None) {
        this.result = result
        this.error = error
    }

    public static func ok(value: JsonValue): HandlerResult {
        HandlerResult(result: value)
    }

    public static func ok<T>(value: T): HandlerResult where T <: JsonSerializable {
        HandlerResult(result: jsonValueOf(value))
    }

    public static func err(code: Int64, message: String): HandlerResult {
        HandlerResult(error: JsonRpcError(code, message))
    }

    public static func err(code: Int64, message: String, data!: ?JsonValue): HandlerResult {
        HandlerResult(error: JsonRpcError(code, message, data: data))
    }
}

private func jsonValueOf<T>(value: T): JsonValue where T <: JsonSerializable {
    JsonValue.fromObject(value)
}

public class JsonRpcServer {
    private let transport: Transport
    private let framing: Framing
    private let middlewares: ArrayList<Middleware> = ArrayList<Middleware>()
    private let handlers: ConcurrentHashMap<String, Handler> = ConcurrentHashMap<String, Handler>()
    private let lock: Mutex = Mutex()
    private var running: Bool = false
    private let recvBuffer = ByteBuffer()

    public init(transport: Transport, framing!: Framing = ContentLengthFraming()) {
        this.transport = transport
        this.framing = framing
    }

    public func use(middleware: Middleware): Unit {
        this.middlewares.add(middleware)
    }

    public func register(method: String, handler: Handler): Unit {
        this.handlers.add(method, handler)
    }

    public func start(): Unit {
        synchronized(this.lock) {
            this.running = true
        }
        spawn {
            => this.receiveLoop()
        }
    }

    public func serve(): Unit {
        synchronized(this.lock) {
            this.running = true
        }
        this.receiveLoop()
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
        synchronized(this.lock) {
            this.running = false
        }
        this.transport.close()
    }
    
    public func copyHandlersFrom(other: JsonRpcServer): Unit {
        let handlers = other.getHandlers()
        for ((method, handler) in handlers) {
            this.handlers.add(method, handler)
        }
    }
    
    public func copyMiddlewaresFrom(other: JsonRpcServer): Unit {
        let mws = other.getMiddlewares()
        for (mw in mws) {
            this.middlewares.add(mw)
        }
    }
    
    public func getHandlers(): HashMap<String, Handler> {
        synchronized(this.lock) {
            HashMap<String, Handler>(this.handlers)
        }
    }
    
    public func getMiddlewares(): ArrayList<Middleware> {
        synchronized(this.lock) {
            ArrayList<Middleware>(this.middlewares)
        }
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            !this.running
        }
    }
    
    private func receiveLoop(): Unit {
        while (this.isRunning()) {
            match (this.transport.receive()) {
                case Some(data) =>
                    recvBuffer.write(data)
                    while (let Some((body, consumed)) <- this.framing.decode(recvBuffer.bytes())) {
                        try {
                            this.handleMessage(body)
                        } catch (e: Exception) {
                            this.close()
                            return
                        }
                        recvBuffer.seek(SeekPosition.Current(consumed))
                    }
                case None => this.close()
            }
        }
    }

    private func isRunning(): Bool {
        synchronized(this.lock) {
            this.running
        }
    }

    private func sendError(id: ?RequestId, code: Int64, message: String): Unit {
        let resp = Response(id: id, error: JsonRpcError(code, message))
        this.sendResponse(resp)
    }

    private func handleMessage(body: Array<Byte>): Unit {
        try {
            match (parseMessage(body)) {
                case Message.SingleRequest(req) => this.handleRequest(req)
                case Message.SingleNotification(notif) => this.handleNotification(notif)
                case Message.BatchRequest(items) => this.handleBatchRequest(items)
                case Message.SingleResponse(resp) => this.handleOutgoingResponse(resp)
                case _ => ()
            }
        } catch (e: JsonRpcException) {
            this.sendError(None, e.code, e.message)
        } catch (e: Exception) {
            let msg = e.message
            if (msg.startsWith("Invalid message") || msg.startsWith("Invalid jsonrpc") || msg.startsWith("Invalid batch") || msg == "Empty batch") {
                this.sendError(None, ErrorCodes.INVALID_REQUEST, msg)
            } else {
                this.sendError(None, ErrorCodes.PARSE_ERROR, "Parse error")
            }
        }
    }

    private func handleRequest(req: Request): Unit {
        let ctx = RequestContext(req, this.transport)
        let handlerCtx = HandlerContext(params: req.params)
        let result = this.executeMiddlewares(ctx, handlerCtx, req.method)
        let resp = Response(id: Some(req.id), result: result.result, error: result.error)
        this.sendResponse(resp)
    }

    private func handleOutgoingResponse(resp: Response): Unit {
        synchronized(this.requestLock) {
            if (let Some(pending) <- this.pendingRequest) {
                pending.setResponse(resp)
            }
        }
    }

    private func handleNotification(notif: Notification): Unit {
        let notifRequest = Request(RequestId.String("__notification__"), notif.method, params: notif.params)
        let ctx = RequestContext(notifRequest, this.transport)
        let handlerCtx = HandlerContext(params: notif.params)
        this.executeMiddlewares(ctx, handlerCtx, notif.method)
    }

    private func handleBatchRequest(items: ArrayList<Message>): Unit {
        let responses = ArrayList<Response>()
        for (item in items) {
            match (item) {
                case Message.SingleRequest(req) =>
                    let ctx = RequestContext(req, this.transport)
                    let handlerCtx = HandlerContext(params: req.params)
                    let result = this.executeMiddlewares(ctx, handlerCtx, req.method)
                    responses.add(Response(id: Some(req.id), result: result.result, error: result.error))
                case Message.SingleNotification(notif) =>
                    let notifRequest = Request(RequestId.String("__notification__"), notif.method, params: notif.params)
                    let ctx = RequestContext(notifRequest, this.transport)
                    let handlerCtx = HandlerContext(params: notif.params)
                    this.executeMiddlewares(ctx, handlerCtx, notif.method)
                case Message.InvalidRequest(err) =>
                    responses.add(Response(id: None, error: err))
                case _ => ()
            }
        }
        if (responses.size > 0) {
            this.sendBatchResponse(responses)
        }
    }

    public func executeMiddlewares(ctx: RequestContext, handlerCtx: HandlerContext, method: String): HandlerResult {
        if (this.middlewares.size == 0) {
            return this.dispatch(method, handlerCtx)
        }

        let finalHandler: () -> HandlerResult = {
            => this.dispatch(method, handlerCtx)
        }

        var next: () -> HandlerResult = finalHandler
        var i = this.middlewares.size - 1
        while (i >= 0) {
            let middleware = this.middlewares[i]
            let currentNext = next
            next = {
                => middleware(ctx, currentNext)
            }
            i--
        }

        next()
    }

    public func dispatch(method: String, ctx: HandlerContext): HandlerResult {
        match (this.handlers.get(method)) {
            case Some(handler) => try {
                handler(ctx)
            } catch (e: Exception) {
                HandlerResult.err(ErrorCodes.INTERNAL_ERROR, "Internal error: ${e.message}")
            }
            case None => HandlerResult.err(ErrorCodes.METHOD_NOT_FOUND, "Method not found: ${method}")
        }
    }

    private func sendResponse(resp: Response): Unit {
        let bytes = serializeResponse(resp)
        this.transport.send(this.framing.encode(bytes))
    }

    private func sendBatchResponse(responses: ArrayList<Response>): Unit {
        let arr = ArrayList<JsonValue>()
        for (resp in responses) {
            arr.add(JsonValue.fromObject(resp))
        }
        let v = JsonValue.Array(arr)
        let bytes = v.toBytes()
        this.transport.send(this.framing.encode(bytes))
    }

    private func toJsonValue<T>(params: ?T): ?JsonValue where T <: JsonSerializable {
        match (params) {
            case Some(p) => Some(JsonValue.fromObject(p))
            case None => None
        }
    }

    // ── Outgoing request support (for server-initiated requests like registerCapability) ──

    private let requestLock: Mutex = Mutex()
    private var pendingRequest: ?PendingRequest = None

    public func request<T, R>(method: String, params!: ?T, timeout!: Duration = 30 * Duration.second): Result<R>
        where T <: JsonSerializable, R <: JsonDeserializable<R> {
        let req = Request(RequestId.Int(0), method, params: match (params) {
            case Some(p) => Some(JsonValue.fromObject(p))
            case None => None
        })
        let bytes = serializeRequest(req)
        let pending = PendingRequest(RequestId.Int(0))
        synchronized(this.requestLock) {
            this.pendingRequest = pending
        }
        this.transport.send(this.framing.encode(bytes))
        match (pending.waitForResponse(timeout: timeout)) {
            case Some(resp) =>
                synchronized(this.requestLock) { this.pendingRequest = None }
                if (let Some(resultVal) <- resp.result) {
                    try { Result.Ok(JsonValue.toObject<R>(resultVal)) }
                    catch (e: Exception) { Result.Err("Failed to parse result: ${e.message}") }
                } else if (let Some(error) <- resp.error) {
                    Result.Err("[${error.code}] ${error.message}")
                } else { Result.Err("Invalid response") }
            case None =>
                synchronized(this.requestLock) { this.pendingRequest = None }
                Result.Err("Request timeout")
        }
    }
}
