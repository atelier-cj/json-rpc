package ystyle::jsonrpc

import jsonvalue.*
import std.collection.*

public func serializeRequest(req: Request): Array<Byte> {
    JsonValue.fromObject(req).toBytes()
}

public func deserializeRequest(bytes: Array<Byte>): Request {
    JsonValue.toObject<Request>(JsonValue.parse(bytes))
}

public func serializeResponse(resp: Response): Array<Byte> {
    JsonValue.fromObject(resp).toBytes()
}

public func deserializeResponse(bytes: Array<Byte>): Response {
    JsonValue.toObject<Response>(JsonValue.parse(bytes))
}

public func serializeNotification(notif: Notification): Array<Byte> {
    JsonValue.fromObject(notif).toBytes()
}

public func deserializeNotification(bytes: Array<Byte>): Notification {
    JsonValue.toObject<Notification>(JsonValue.parse(bytes))
}

public enum Message {
    | SingleRequest(Request)
    | SingleResponse(Response)
    | SingleNotification(Notification)
    | BatchRequest(ArrayList<Message>)
    | BatchResponse(ArrayList<Response>)
}

public func parseMessage(bytes: Array<Byte>): Message {
    let v = JsonValue.parse(bytes)
    if (v.isArray()) {
        let arr = v.asArray().getOrThrow()
        if (arr.size == 0) {
            throw Exception("Empty batch")
        }
        let first = arr[0]
        if (first.isMap()) {
            if (first["method"].isSome()) {
                let items = ArrayList<Message>()
                for (item in arr) {
                    if (item["method"].isSome()) {
                        if (item["id"].isSome()) {
                            items.add(Message.SingleRequest(JsonValue.toObject<Request>(item)))
                        } else {
                            items.add(Message.SingleNotification(JsonValue.toObject<Notification>(item)))
                        }
                    }
                }
                Message.BatchRequest(items)
            } else if (first["result"].isSome() || first["error"].isSome()) {
                let items = ArrayList<Response>()
                for (item in arr) {
                    items.add(JsonValue.toObject<Response>(item))
                }
                Message.BatchResponse(items)
            } else {
                throw Exception("Invalid batch: first element must have method or result/error")
            }
        } else {
            throw Exception("Invalid batch: first element must be object")
        }
    } else if (v.isMap()) {
        if (v["method"].isSome()) {
            if (v["id"].isSome()) {
                Message.SingleRequest(JsonValue.toObject<Request>(v))
            } else {
                Message.SingleNotification(JsonValue.toObject<Notification>(v))
            }
        } else if (v["result"].isSome() || v["error"].isSome()) {
            Message.SingleResponse(JsonValue.toObject<Response>(v))
        } else {
            throw Exception("Invalid message: missing method or result/error")
        }
    } else {
        throw Exception("Invalid message: must be object or array")
    }
}
