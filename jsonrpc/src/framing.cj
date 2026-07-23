package ystyle::jsonrpc

import std.convert.*
import std.unicode.*

public func encode(body: Array<Byte>): Array<Byte> {
    let header = "Content-Length: ${body.size}\r\n\r\n"
    let headerBytes = header.toArray()
    let result = Array<Byte>(headerBytes.size + body.size, repeat: 0)
    var idx: Int64 = 0
    for (b in headerBytes) {
        result[idx] = b
        idx++
    }
    for (b in body) {
        result[idx] = b
        idx++
    }
    result
}

public func decode(content: Array<Byte>): ?(Array<Byte>, Int64) {
    let headerEnd = findHeaderEnd(content)
    if (headerEnd < 0) {
        return None
    }
    let header = String.fromUtf8(content[0..headerEnd])
    let length = parseContentLength(header)
    if (length < 0) {
        return None
    }
    let bodyStart = headerEnd + 4
    if (content.size < bodyStart + length) {
        return None
    }
    let body = content[bodyStart..(bodyStart + length)]
    let consumed = bodyStart + length
    Some((body, consumed))
}

private func findHeaderEnd(content: Array<Byte>): Int64 {
    if (content.size < 4) {
        return -1
    }
    var i: Int64 = 0
    let end = content.size - 4
    while (i <= end) {
        let c0 = content[i]
        let c1 = content[i + 1]
        let c2 = content[i + 2]
        let c3 = content[i + 3]
        if (c0 == 13 && c1 == 10 && c2 == 13 && c3 == 10) {
            return i
        }
        i++
    }
    -1
}

private func parseContentLength(header: String): Int64 {
    let lines = header.split('\n')
    for (line in lines) {
        let trimmed = line.trim()
        if (trimmed.startsWith("Content-Length:")) {
            let valueStr = trimmed[16..].trimAscii()
            match (Int64.tryParse(valueStr)) {
                case Some(v) => return v
                case None => return -1
            }
        }
    }
    -1
}
