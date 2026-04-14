import std.fs.*
import std.process.Process

func copyReadme(): Unit {
    let members = ["jsonrpc", "jsonrpc_stdio", "jsonrpc_tcp", "jsonrpc_unix"]
    for (mem in members) {
        try {
            copy("./README.md", to: "./${mem}/README.md", overwrite: true)
        } catch (e: Exception) {
            println("Warning: failed to copy README to ${mem}: ${e.message}")
        }
    }
    println("README copied to all member modules")
}

func stagePreBuild(): Int64 {
    copyReadme()
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