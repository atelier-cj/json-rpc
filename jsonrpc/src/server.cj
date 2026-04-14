package ystyle::jsonrpc

import jsonvalue.*
import std.collection.*
import std.sync.*
import std.collection.concurrent.*
import stdx.encoding.json.stream.*

public type Middleware = (RequestContext, () -> HandlerResult) -> HandlerResult

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
        HandlerResult(result: JsonValue.fromObject(value))
    }

    public static func err(code: Int64, message: String): HandlerResult {
        HandlerResult(error: JsonRpcError(code, message))
    }

    public static func err(code: Int64, message: String, data!: ?JsonValue): HandlerResult {
        HandlerResult(error: JsonRpcError(code, message, data: data))
    }
}

public interface MethodHandler {
    func handle(ctx: HandlerContext): HandlerResult
}

public class JsonRpcServer {
    private let transport: Transport
    private let middlewares: ArrayList<Middleware> = ArrayList<Middleware>()
    private let handlers: ConcurrentHashMap<String, MethodHandler> = ConcurrentHashMap<String, MethodHandler>()
    private let lock: Mutex = Mutex()
    private var running: Bool = false

    public init(transport: Transport) {
        this.transport = transport
    }

    public func use(middleware: Middleware): Unit {
        this.middlewares.add(middleware)
    }

    public func register(method: String, handler: MethodHandler): Unit {
        this.handlers.add(method, handler)
    }

    public func register(method: String, handler: (HandlerContext) -> HandlerResult): Unit {
        this.handlers.add(method, LambdaHandler(handler))
    }

    public func start(): Unit {
        synchronized(this.lock) {
            this.running = true
        }
        spawn {
            => this.receiveLoop()
        }
    }

public func close(): Unit {
        synchronized(this.lock) {
            this.running = false
        }
        this.transport.close()
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            !this.running
        }
    }
    
    private func receiveLoop(): Unit {
        while (this.isRunning()) {
            match (this.transport.receive()) {
                case Some(data) => match (decode(data)) {
                    case Some(body) => spawn {
                        => this.handleMessage(body)
                    }
                    case None => ()
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

    private func handleMessage(body: Array<Byte>): Unit {
        try {
            match (parseMessage(body)) {
                case Message.SingleRequest(req) => this.handleRequest(req)
                case Message.SingleNotification(notif) => this.handleNotification(notif)
                case Message.BatchRequest(items) => this.handleBatchRequest(items)
                case _ => ()
            }
        } catch (e: Exception) {
            ()
        }
    }

    private func handleRequest(req: Request): Unit {
        let ctx = RequestContext(req, this.transport)
        let handlerCtx = HandlerContext(params: req.params)
        let result = this.executeMiddlewares(ctx, handlerCtx, req.method)
        let resp = Response(req.id, result: result.result, error: result.error)
        this.sendResponse(resp)
    }

    private func handleNotification(notif: Notification): Unit {
        let dummyRequest = Request(RequestId.Int(0), notif.method, params: notif.params)
        let ctx = RequestContext(dummyRequest, this.transport)
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
                    responses.add(Response(req.id, result: result.result, error: result.error))
                case Message.SingleNotification(notif) =>
                    let dummyRequest = Request(RequestId.Int(0), notif.method, params: notif.params)
                    let ctx = RequestContext(dummyRequest, this.transport)
                    let handlerCtx = HandlerContext(params: notif.params)
                    this.executeMiddlewares(ctx, handlerCtx, notif.method)
                case _ => ()
            }
        }
        if (responses.size > 0) {
            this.sendBatchResponse(responses)
        }
    }

    private func executeMiddlewares(ctx: RequestContext, handlerCtx: HandlerContext, method: String): HandlerResult {
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

    private func dispatch(method: String, ctx: HandlerContext): HandlerResult {
        match (this.handlers.get(method)) {
            case Some(handler) => try {
                handler.handle(ctx)
            } catch (e: Exception) {
                HandlerResult.err(ErrorCodes.INTERNAL_ERROR, "Internal error: ${e.message}")
            }
            case None => HandlerResult.err(ErrorCodes.METHOD_NOT_FOUND, "Method not found: ${method}")
        }
    }

    private func sendResponse(resp: Response): Unit {
        let bytes = serializeResponse(resp)
        let framed = encode(bytes)
        this.transport.send(framed)
    }

    private func sendBatchResponse(responses: ArrayList<Response>): Unit {
        let arr = ArrayList<JsonValue>()
        for (resp in responses) {
            arr.add(JsonValue.fromObject(resp))
        }
        let v = JsonValue.Array(arr)
        let bytes = v.toBytes()
        let framed = encode(bytes)
        this.transport.send(framed)
    }
}

private class LambdaHandler <: MethodHandler {
    private let handlerFunc: (HandlerContext) -> HandlerResult

    public init(handler: (HandlerContext) -> HandlerResult) {
        this.handlerFunc = handler
    }

    public func handle(ctx: HandlerContext): HandlerResult {
        this.handlerFunc(ctx)
    }
}
