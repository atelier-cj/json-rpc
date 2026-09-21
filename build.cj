import std.fs.*
import std.process.Process

func copySharedFiles(): Unit {
    let members = ["jsonrpc", "jsonrpc_stdio", "jsonrpc_tcp", "jsonrpc_unix", "jsonrpc_http", "jsonrpc_websocket"]
    // README/LICENSE 是仓根一份、成员各带一份：中心仓制品要求成员目录自带，
    // 而成员目录里的这两份是构建期拷进来的（不入库，见 .gitignore）
    for (mem in members) {
        for (file in ["README.md", "LICENSE"]) {
            try {
                copy("./${file}", to: "./${mem}/${file}", overwrite: true)
            } catch (e: Exception) {
                println("Warning: failed to copy ${file} to ${mem}: ${e.message}")
            }
        }
    }
    println("README/LICENSE copied to all member modules")
}

func stagePreBuild(): Int64 {
    copySharedFiles()
    0
}

func stagePreClean(): Int64 {
    0
}

main(): Int64 {
    match (Process.current.arguments[0]) {
        case "pre-build" => stagePreBuild()
        case "pre-clean" => stagePreClean()
        case _ => 0
    }
}