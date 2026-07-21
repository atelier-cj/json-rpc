package ystyle::jsonrpc_stdio

import ystyle::jsonrpc.*
import std.env.*
import std.sync.*

public class StdioTransport <: Transport {
    private var closed: Bool = false
    private let lock: Mutex = Mutex()
    private let stdout: ConsoleWriter
    private let stdin: ConsoleReader
    
    public init() {
        this.stdout = getStdOut()
        this.stdin = getStdIn()
    }
    
    public func send(data: Array<Byte>): Unit {
        this.stdout.write(data)
        this.stdout.flush()
    }
    
    public func receive(): ?Array<Byte> {
        let buffer = Array<Byte>(4096, repeat: 0)
        let len = this.stdin.read(buffer)
        if (len <= 0) {
            None
        } else {
            buffer[0..len]
        }
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