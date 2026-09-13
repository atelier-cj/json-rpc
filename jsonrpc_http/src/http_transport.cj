package ystyle::jsonrpc_http

import ystyle::jsonrpc.*
import jsonvalue.*
import stdx.net.http.*
import std.collection.*
import std.sync.*

public class HttpClientTransport <: Transport {
    private let client: Client
    private let url: String
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    private var responseQueue = ArrayList<Array<Byte>>()
    private var cond: Condition

    public init(client: Client, url: String) {
        this.client = client
        this.url = url
        this.cond = synchronized(this.lock) { this.lock.condition() }
    }
    
    public func send(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
        }
        
        try {
            match (decode(data)) {
                case Some((body, _)) =>
                    let resp = this.client.post(this.url, body)
                    let buf = Array<Byte>(8192, repeat: 0)
                    let len = resp.body.read(buf)
                    if (len > 0) {
                        let framed = encode(buf[0..len])
                        synchronized(this.lock) {
                            this.responseQueue.add(framed)
                            this.cond.notifyAll()
                        }
                    }
                case None => ()
            }
        } catch (e: Exception) {
            // 不能静默：请求根本没发出去，调用方的 pending 只能干等满 timeout
            println("[jsonrpc] http transport send error: " + e.toString())
        }
    }
    
    public func receive(): ?Array<Byte> {
        synchronized(this.lock) {
            while (this.responseQueue.size == 0 && !this.closed) {
                this.cond.wait(timeout: Duration.second)
            }
            if (this.responseQueue.size > 0) {
                Some(this.responseQueue.remove(at: 0))
            } else {
                None
            }
        }
    }
    
    public func close(): Unit {
        synchronized(this.lock) {
            this.closed = true
            this.cond.notifyAll()
        }
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed
        }
    }
}

public class HttpRpcHandler <: HttpRequestHandler {
    private let rpcServer: JsonRpcServer
    
    public init(rpcServer: JsonRpcServer) {
        this.rpcServer = rpcServer
    }
    
    public func handle(ctx: HttpContext): Unit {
        HttpRpcHelper.handle(ctx, this.rpcServer)
    }
}

public class HttpRpcHelper {
    public static func handle(ctx: HttpContext, rpcServer: JsonRpcServer): Unit {
        let req = ctx.request
        
        if (req.method != "POST") {
            HttpRpcHelper.sendError(ctx, HttpStatusCode.STATUS_METHOD_NOT_ALLOWED, "Only POST allowed")
            return
        }
        
        let body = req.body
        try {
            let buffer = Array<Byte>(8192, repeat: 0)
            let len = body.read(buffer)
            if (len <= 0) {
                HttpRpcHelper.sendError(ctx, HttpStatusCode.STATUS_BAD_REQUEST, "Empty body")
                return
            }
            
            let bytes = buffer[0..len]
            let msg = parseMessage(bytes)
            HttpRpcHelper.handleMessage(ctx, rpcServer, msg)
        } catch (e: Exception) {
            HttpRpcHelper.sendError(ctx, HttpStatusCode.STATUS_BAD_REQUEST, "Invalid JSON: ${e.message}")
        }
    }
    
    private static func handleMessage(ctx: HttpContext, rpcServer: JsonRpcServer, msg: Message): Unit {
        match (msg) {
            case Message.SingleRequest(req) =>
                let requestCtx = RequestContext(req, HttpDummyTransport())
                let handlerCtx = HandlerContext(params: req.params)
                let result = rpcServer.executeMiddlewares(requestCtx, handlerCtx, req.method)
                HttpRpcHelper.sendResponse(ctx, Response(id: Some(req.id), result: result.result, error: result.error))
            case Message.BatchRequest(items) =>
                let responses = ArrayList<Response>()
                for (item in items) {
                    match (item) {
                        case Message.SingleRequest(r) =>
                            let requestCtx = RequestContext(r, HttpDummyTransport())
                            let handlerCtx = HandlerContext(params: r.params)
                            let res = rpcServer.executeMiddlewares(requestCtx, handlerCtx, r.method)
                            responses.add(Response(id: Some(r.id), result: res.result, error: res.error))
                        case _ => ()
                    }
                }
                HttpRpcHelper.sendBatchResponse(ctx, responses)
            case _ =>
                HttpRpcHelper.sendError(ctx, HttpStatusCode.STATUS_BAD_REQUEST, "Invalid message type")
        }
    }
    
    private static func sendResponse(ctx: HttpContext, resp: Response): Unit {
        let bytes = serializeResponse(resp)
        let builder = ctx.responseBuilder
        builder.status(HttpStatusCode.STATUS_OK)
        builder.header("Content-Type", "application/json")
        builder.body(bytes)
    }
    
    private static func sendBatchResponse(ctx: HttpContext, responses: ArrayList<Response>): Unit {
        let arr = ArrayList<JsonValue>()
        for (resp in responses) {
            arr.add(JsonValue.fromObject(resp))
        }
        let v = JsonValue.Array(arr)
        let bytes = v.toBytes()
        
        let builder = ctx.responseBuilder
        builder.status(HttpStatusCode.STATUS_OK)
        builder.header("Content-Type", "application/json")
        builder.body(bytes)
    }
    
    private static func sendError(ctx: HttpContext, status: UInt16, message: String): Unit {
        let builder = ctx.responseBuilder
        builder.status(status)
        builder.header("Content-Type", "application/json")
        let resp = Response(id: None, error: JsonRpcError(-32600, message))
        builder.body(serializeResponse(resp))
    }
}

private class HttpDummyTransport <: Transport {
    public func send(data: Array<Byte>): Unit {}
    public func receive(): ?Array<Byte> { None }
    public func close(): Unit {}
    public func isClosed(): Bool { true }
}