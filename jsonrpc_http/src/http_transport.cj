package ystyle::jsonrpc_http

import ystyle::jsonrpc.*
import jsonvalue.*
import stdx.net.http.*
import std.collection.*
import std.sync.*
import std.io.InputStream

/**
 * 响应体是否像一条 JSON-RPC 消息（首个非空白字节为 `{` 或 `[`）。
 *
 * 用于把两类非 2xx 分开：规范允许的「4xx/5xx + JSON-RPC 错误体」是协议消息，
 * 要照常投递；网关/框架自己的 `text/plain`、HTML 错误页不是。
 */
func looksLikeJsonMessage(body: Array<Byte>): Bool {
    for (b in body) {
        if (b == 32 || b == 9 || b == 10 || b == 13) {
            continue
        }
        return b == 123 || b == 91
    }
    false
}

/** 错误体摘要的字节上限（超出即截断）。 */
const HTTP_ERROR_SNIPPET_BYTES: Int64 = 200

/** HTTP 失败的异常文本：状态码 + 端点 + 服务端原文（截断后）。 */
func httpFailureText(status: UInt16, url: String, body: Array<Byte>): String {
    let detail = bodySnippet(body)
    if (detail == "") {
        return "HTTP ${status} from ${url}"
    }
    "HTTP ${status} from ${url}: ${detail}"
}

/** 错误体摘要：折叠控制字符、按上限截断（不切断多字节字符）。 */
func bodySnippet(body: Array<Byte>): String {
    if (body.size == 0) {
        return ""
    }
    let flat = ArrayList<Byte>()
    for (b in body) {
        if (b < 32 || b == 127) {
            flat.add(32)          // 换行/制表/其它控制字符折叠成空格
        } else {
            flat.add(b)
        }
    }
    var cut = flat.size
    if (cut > HTTP_ERROR_SNIPPET_BYTES) {
        cut = HTTP_ERROR_SNIPPET_BYTES
        // UTF-8 续字节形如 10xxxxxx（0x80..0xBF）：回退到字符边界，别切出半个字
        while (cut > 0 && flat[cut] >= 128 && flat[cut] < 192) {
            cut--
        }
    }
    let raw = Array<Byte>(cut, repeat: 0)
    for (i in 0..cut) {
        raw[i] = flat[i]
    }
    String.fromUtf8(raw).trimAscii()
}

/** 读满输入流：一次 read 只能拿到缓冲那么多，截断的 JSON 同样只会变成解析错。 */
func readAll(body: InputStream): Array<Byte> {
    let buf = Array<Byte>(8192, repeat: 0)
    let total = ArrayList<Byte>()
    while (true) {
        let n: Int64
        try {
            n = body.read(buf)
        } catch (_: Exception) {
            break
        }
        if (n <= 0) {
            break
        }
        total.add(all: buf[0..n])
    }
    total.toArray()
}

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
                    let bytes = readAll(resp.body)
                    if (resp.status < 200 || resp.status >= 300) {
                        if (!looksLikeJsonMessage(bytes)) {
                            // HTTP 层的失败不是协议消息：原样投递只会得到一句
                            // "Parse error"，服务端真正说的话被丢掉，在途调用还要
                            // 干等满 timeout
                            throw Exception(httpFailureText(resp.status, this.url, bytes))
                        }
                    } else if (bytes.size == 0) {
                        // 2xx 却是空体：喂给解析器同样只会得到 "Parse error"
                        eprintln("[jsonrpc] http transport: empty body from ${this.url} (status ${resp.status})")
                        return
                    }
                    let framed = encode(bytes)
                    synchronized(this.lock) {
                        this.responseQueue.add(framed)
                        this.cond.notifyAll()
                    }
                case None => ()
            }
        } catch (e: Exception) {
            // 不能只记日志：请求根本没发出去、或对端回了 HTTP 层失败时，调用方的
            // 在途请求只能干等满 timeout（默认 30s）——那正是「客户端挂起」的来源。
            // 抛出去，让 call() 撤掉在途记录并把原因立刻交给调用方。
            eprintln("[jsonrpc] http transport send error: " + e.toString())
            throw e
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