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
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
        }
        this.stdout.write(data)
        this.stdout.flush()
    }
    
    public func receive(): ?Array<Byte> {
        // 关闭后必须立刻返回 None：ConsoleReader 上的阻塞读无法被 close() 中断，
        // 不检查标志的话接收循环会永远挂在 read() 上
        synchronized(this.lock) {
            if (this.closed) {
                return None
            }
        }
        let buffer = Array<Byte>(4096, repeat: 0)
        let len = this.stdin.read(buffer)
        if (len <= 0) {
            None
        } else {
            buffer[0..len]
        }
    }
    
    public func close(): Unit {
        // 注意：stdin（ConsoleReader）无法被中断，已阻塞在 read() 上的接收线程不会
        // 因本调用返回；这里只保证后续 receive() 立即返回 None、send() 不再写出。
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