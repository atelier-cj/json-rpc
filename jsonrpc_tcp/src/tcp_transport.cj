package ystyle::jsonrpc_tcp

import ystyle::jsonrpc.*
import std.net.*
import std.sync.*

public class TcpConnectionTransport <: Transport {
    private let socket: TcpSocket
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    
    public init(socket: TcpSocket) {
        this.socket = socket
    }
    
    public func send(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                // 静默丢包会让调用方干等满 timeout，且毫无线索
                println("[jsonrpc] tcp send on closed transport dropped")
                return
            }
            this.socket.write(data)
        }
    }
    
    public func receive(): ?Array<Byte> {
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        let buffer = Array<Byte>(4096, repeat: 0)
        let len = this.socket.read(buffer)
        if (len <= 0) {
            synchronized(this.lock) {
                this.closed = true
            }
            None
        } else {
            buffer[0..len]
        }
    }
    
    public func close(): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.closed = true
                this.socket.close()
            }
        }
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed || this.socket.isClosed()
        }
    }
}

public class TcpServerTransport {
    private let serverSocket: TcpServerSocket
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    
    public init(port: UInt16) {
        this.serverSocket = TcpServerSocket(bindAt: port)
        this.serverSocket.bind()
    }
    
    public init(address: SocketAddress) {
        this.serverSocket = TcpServerSocket(bindAt: address)
        this.serverSocket.bind()
    }
    
    public func acceptConnection(): ?TcpConnectionTransport {
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        try {
            let clientSocket = this.serverSocket.accept()
            Some(TcpConnectionTransport(clientSocket))
        } catch (e: Exception) {
            // accept 失败（含超时）与「监听已关闭」必须能区分：静默返回 None 会让
            // 调用方以为监听正常结束，实际是出错
            println("[jsonrpc] tcp accept error: " + e.toString())
            None
        }
    }
    
    public func acceptConnection(timeout: Duration): ?TcpConnectionTransport {
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        try {
            let clientSocket = this.serverSocket.accept(timeout: timeout)
            Some(TcpConnectionTransport(clientSocket))
        } catch (e: Exception) {
            // accept 失败（含超时）与「监听已关闭」必须能区分：静默返回 None 会让
            // 调用方以为监听正常结束，实际是出错
            println("[jsonrpc] tcp accept error: " + e.toString())
            None
        }
    }
    
    public func close(): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.closed = true
                this.serverSocket.close()
            }
        }
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed || this.serverSocket.isClosed()
        }
    }
    
    public func localPort(): UInt16 {
        let addr = this.serverSocket.localAddress
        match (addr) {
            case ipAddr: IPSocketAddress => ipAddr.port
            case _ => 0
        }
    }
}

public class TcpClientTransport <: Transport {
    private let socket: TcpSocket
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    
    public init(address: String, port: UInt16) {
        this.socket = TcpSocket(address, port)
        this.socket.connect()
    }
    
    public func send(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                // 静默丢包会让调用方干等满 timeout，且毫无线索
                println("[jsonrpc] tcp send on closed transport dropped")
                return
            }
            this.socket.write(data)
        }
    }
    
    public func receive(): ?Array<Byte> {
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        let buffer = Array<Byte>(4096, repeat: 0)
        let len = this.socket.read(buffer)
        if (len <= 0) {
            synchronized(this.lock) {
                this.closed = true
            }
            None
        } else {
            buffer[0..len]
        }
    }
    
    public func close(): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.closed = true
                this.socket.close()
            }
        }
    }
    
    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed || this.socket.isClosed()
        }
    }
}