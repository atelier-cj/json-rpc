package ystyle::jsonrpc_websocket

import ystyle::jsonrpc.*
import stdx.net.http.*
import stdx.encoding.url.*
import std.collection.*
import std.sync.*

public class WebSocketClientTransport <: Transport {
    private let ws: WebSocket
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    
    public init(ws: WebSocket) {
        this.ws = ws
    }
    
    public static func connect(client: Client, url: String): WebSocketClientTransport {
        let wsUrl = URL.parse(url)
        let (ws, _) = WebSocket.upgradeFromClient(client, wsUrl)
        WebSocketClientTransport(ws)
    }
    
    public func send(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
        }
        this.ws.write(WebSocketFrameType.BinaryWebFrame, data)
    }
    
    public func receive(): ?Array<Byte> {
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        
        try {
            let frame = this.ws.read()
            if (frame.fin && (frame.frameType == WebSocketFrameType.BinaryWebFrame || 
                              frame.frameType == WebSocketFrameType.TextWebFrame)) {
                Some(frame.payload)
            } else {
                None
            }
        } catch (e: Exception) {
            synchronized(this.lock) {
                this.closed = true
            }
            None
        }
    }
    
    public func close(): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.closed = true
                this.ws.writeCloseFrame()
                this.ws.closeConn()
            }
        }
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed
        }
    }
}

public class WebSocketServerHandler <: HttpRequestHandler {
    private let rpcServer: JsonRpcServer
    private let subProtocols: ArrayList<String>
    
    public init(rpcServer: JsonRpcServer, subProtocols!: ArrayList<String> = ArrayList<String>()) {
        this.rpcServer = rpcServer
        this.subProtocols = subProtocols
    }
    
    public func handle(ctx: HttpContext): Unit {
        try {
            let ws = WebSocket.upgradeFromServer(ctx, subProtocols: this.subProtocols)
            let transport = WebSocketServerTransport(ws)
            let server = JsonRpcServer(transport)
            server.copyHandlersFrom(this.rpcServer)
            server.copyMiddlewaresFrom(this.rpcServer)
            server.start()
        } catch (e: Exception) {
            ()
        }
    }
}

public class WebSocketServerTransport <: Transport {
    private let ws: WebSocket
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    
    public init(ws: WebSocket) {
        this.ws = ws
    }
    
    public func send(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
        }
        this.ws.write(WebSocketFrameType.BinaryWebFrame, data)
    }
    
    public func receive(): ?Array<Byte> {
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        
        try {
            let frame = this.ws.read()
            if (frame.fin && (frame.frameType == WebSocketFrameType.BinaryWebFrame || 
                              frame.frameType == WebSocketFrameType.TextWebFrame)) {
                Some(frame.payload)
            } else {
                None
            }
        } catch (e: Exception) {
            synchronized(this.lock) {
                this.closed = true
            }
            None
        }
    }
    
    public func close(): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.closed = true
                this.ws.writeCloseFrame()
                this.ws.closeConn()
            }
        }
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed
        }
    }
}