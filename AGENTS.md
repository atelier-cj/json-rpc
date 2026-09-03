# json-rpc 实现仓颉的通用json-rpc 2.0协议框架

## 仓颉语言
- 在上下文压缩后，如果没有仓颉语法相关的，需要马上使用`cangjie_mem_list`工具加载所有仓颉语言级记忆
- 在仓颉api和手册可以使用`cangjie_docs`相关工具查找，在`cangjie-mem`没有的直接在文档里查找，不要猜api和语法
- 在提示语法错误时重新使用 `cangjie-mem` 加载语言级记忆
- match 的 case 后不能接`{}`, case后直接写多行列表式而不需要`{}`

## 任务指南
- **不要考虑时间，不要简化算法，不要简化测试，这项目是自己的产品，按最好的来搞**
- 在实现功能总结后，需要更新`progress-tracking.md`项目进度, 并把值得注意的内容总结的记录到`cangjie-mem`项目级记忆里
- 新功能、新特性一定要写单元测试
- 不要在项目外创建仓颉单文件测试，非cjpm项目没法导入当前项目
- 新功能需要做好，且有单元测试后提交, 以仓颉单元测试为主
- 测试发现的新问题需要解决，且要添加新用例到仓颉的单元测试里
- 测试出现语法问题不通过时，可以使用`cangjie_docs`相关工具在手册或lib std/stdx查找解决方法
- **json-rpc 修改（含发版前）必须同时运行依赖它的下游仓库测试**：`mcp-cj` 和 `lsp-cj` 的 `cjpm test` 必须通过。修改了 jsonrpc 行为/API 后，先在本地用 path 依赖或已验证的版本号跑通这两个下游仓库的测试，再发版

## 发布约定（中心仓）

- 只发布**库包**：`jsonrpc`（核心）+ 5 个传输包 `jsonrpc_websocket` / `jsonrpc_http` / `jsonrpc_unix` / `jsonrpc_tcp` / `jsonrpc_stdio`，各包版本号保持一致
- **测试包不需要发布到中心仓**：`jsonrpc_tests` 仅用于本地构建与集成验证（`cjpm test`），不进发版清单、不做 bundle/publish
- 发版顺序：核心 `jsonrpc` 先发（含 registry 索引同步），5 个传输包依赖核心随后发；`cjpm.toml` 里传输包对核心的依赖在核心发布后从 path 切回 registry 版本号

## 常用命令
```shell
# 编译
cjpm build -j 16

# 运行
./target/release/bin/main

# 运行所有测试(-j并发测试)
cjpm test -j 16 --no-progress

# 运行指定测试
cjpm test --show-all-output --filter 'ParserTest.testParseRestParameter'
cjpm test --show-all-output --filter 'ParserTest.*'
# Config(dir: "/tmp/badger_db_test5", memTableSize: 64 * 1024u64) 单元测试要减少memTableSize的测试，需要能cjpm test能通过不报内存溢出

# 基准测试
cjpm bench

# 清理构建缓存 
cjpm clean
```

#### 关于lsp报错
如果代码看起来没错，但lsp报错
- 如果是源码文件, 执行`cjpm build`编译
- 如果是测试文件，执行`cjpm test --no-run`编译

### 创建独立可执行程序
1. 在`src/examples`添加一个包，创建main入口
2. 在`cjpm.toml`添加配置

