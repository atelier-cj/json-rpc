package ystyle::jsonrpc_unix

import ystyle::jsonrpc.*
import std.net.*
import std.sync.*

public class UnixConnectionTransport <: Transport {
    private let socket: UnixSocket
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    
    public init(socket: UnixSocket) {
        this.socket = socket
    }
    
    public func send(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.socket.write(data)
            }
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

public class UnixServerTransport {
    private let serverSocket: UnixServerSocket
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    
    public init(path: String) {
        this.serverSocket = UnixServerSocket(bindAt: path)
        this.serverSocket.bind()
    }
    
    public func acceptConnection(): ?UnixConnectionTransport {
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        try {
            let clientSocket = this.serverSocket.accept()
            Some(UnixConnectionTransport(clientSocket))
        } catch (e: Exception) {
            None
        }
    }
    
    public func acceptConnection(timeout: Duration): ?UnixConnectionTransport {
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        try {
            let clientSocket = this.serverSocket.accept(timeout: timeout)
            Some(UnixConnectionTransport(clientSocket))
        } catch (e: Exception) {
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
}

public class UnixClientTransport <: Transport {
    private let socket: UnixSocket
    private let lock: Mutex = Mutex()
    private var closed: Bool = false
    
    public init(path: String) {
        let addr = UnixSocketAddress(path.toArray())
        this.socket = UnixSocket(addr)
        this.socket.connect()
    }
    
    public func send(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            if (!this.closed) {
                this.socket.write(data)
            }
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