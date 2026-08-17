# 性能基准报告：gjson 快速路由 + 流式直连反序列化

> 对应版本：v0.7.0（开发中）｜ 测量日期：2026-08-16 ｜ 工具：`cjpm bench`（std.unittest `@Bench`）

## 1. 背景与动机

JSON-RPC 2.0 的消息信封是固定结构：`jsonrpc/id/method/params`（请求）或 `result/error`（响应）。
服务端**路由只需要 `method`**，但 v0.7.0 之前的实现必须先全量解析 JSON 才能拿到它：

```
parseMessage(body)
  ├─ JsonValue.parse(bytes)             ① stdx JsonReader 递归建全量 DOM（每个字符串/数字/Map 都分配）
  ├─ DOM 上分类（v["method"] / v["id"] ...）
  └─ JsonValue.toObject<Request>(v)     ② DOM → 序列化回字节 → 再流式重解析成类型化对象
                                          params 在 ①② 中被解析了两次
```

即每条消息经历 **3 遍扫描 + 全量 DOM 建树 + 一次序列化往返**。
而 jsonvalue 本身架在 `stdx.encoding.json.stream` 之上，`Request/Response/Notification` 也早已实现
`fromJson(r: JsonReader)` 流式反序列化——问题是用 DOM 绕过了这条现成的流式路径。

**核心结论先行**：收溢不在"取 method 那一下"，而在 **"路由前不再被迫全量解析"**。
之前评估说"没有收溢"，是因为只对比了 DOM 建立之后的字段查找（`v["method"]` vs `gjson.get("method")`），
没有把 `JsonValue.parse` 的建树成本算进去。

## 2. 测试方法

- **环境**：x86_64-unknown-linux-gnu，cjvs 环境（cjc/cjpm 1.1.3），`compile-option = "-O2"`
- **消息样本**：
  | 样本 | 大小 | 形态 |
  |------|------|------|
  | 小请求 | 142 B | `{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{...}}` |
  | 大请求 | 4.8 KB | LSP `initialize` 风格，params 很大（嵌套 capabilities） |
  | 小响应 | 150 B | `{"jsonrpc":"2.0","id":42,"result":{...}}` |
- **对比管线**：
  | 代号 | 说明 |
  |------|------|
  | A 现状 | `parseMessage`（DOM 建树 + 分类 + `toObject` 往返） |
  | B gjson 仅取 method | `getBytes(body, "method")`（浅扫描，零 DOM） |
  | C gjson 完整分类 | `validBytes` + method/id/jsonrpc/result-error 浅扫描（等价 parseMessage 判定） |
  | D 流式直连 | `Request/Response.fromJson(JsonReader(ByteBuffer(bytes)))` |
  | E 分类+流式 | C + D（改造后的完整服务端路径） |
  | F 流式直连序列化 | `JsonWriter(ByteBuffer)` + `toJson` |
- 基准工程为临时目录（依赖 jsonrpc/jsonvalue/gjson 本地路径），测量后已删除；数据均为 **Median**，多次运行取稳定值。

## 3. 结果

### 3.1 读侧（反序列化 / 分类）

| 场景 | A 现状 | B gjson 仅 method | C gjson 完整分类 | D 流式直连 | E 分类+流式 |
|------|--------|-------------------|------------------|------------|-------------|
| 小请求 142 B | 16.2 µs | 0.50 µs | 1.2 µs | 5.3 µs | 6.7 µs |
| 大请求 4.8 KB | 404–462 µs | 0.48 µs | 4.5 µs | 153 µs | 157 µs |
| 响应 150 B | 11.4 µs | — | — | 3.6 µs | — |

相对提速：

| 场景 | A→D 流式直连 | A→C gjson 分类 | A→B 仅路由 |
|------|-------------|----------------|-----------|
| 小请求 | **3.0×** | **13.9×** | **33×** |
| 大请求 | **2.6×** | **~92×** | **~870×** |
| 响应 | **3.2×** | — | — |

> 说明：大请求的 `A 现状` 拆解为 DOM 建树 158 µs + `toObject` 往返 ~250 µs；
> 流式直连（153 µs）里 params 的 JsonValue 建树仍占大头——这是 params 保持 JsonValue 值类型（API 兼容）的固有成本。

### 3.2 写侧（序列化）

| 场景 | 现状（fromObject→DOM→toBytes） | F 流式直连 | 提速 |
|------|-------------------------------|-----------|------|
| 小请求 | 18.9 µs | 8.6 µs | **2.2×** |
| 大请求 | ~500 µs（推估） | 250 µs | ~2× |

### 3.3 未知方法洪水（服务端快速路由）

未注册的方法当前也要全量解析才返回 `-32601`；快速路由用 gjson 浅扫描直接拒绝：

| 场景 | A 现状 | 快速路由（method+id 两次浅扫描） | 提速 |
|------|--------|-------------------------------|------|
| 大请求 4.8 KB，未知方法 | 404–462 µs | **~1 µs** | **~400×** |

### 3.4 gjson-cj 内部对照（gjson-cj 自带 `@Bench`）

| 操作 | 耗时 |
|------|------|
| `parseBytes`（1.5 KB 复杂 JSON） | 1.24 µs |
| `getBytes(..., "tagged")` 浅路径 | 0.21 µs（~6×） |
| `parseBytes`（LSP JSON） | 3.7 µs |
| `getBytes(..., "params.clientInfo.name")` **深路径** | 4.3 µs（深路径无优势） |

> JSON-RPC 路由只用**顶层浅路径**（method/id/jsonrpc/result/error），不受深路径退化影响。

## 4. 结论

1. **读侧 2.6–3.2×、分类 14–92×、未知方法 ~400×、写侧 ~2×**——改造收益来自"去掉 jsonvalue DOM 中转"（3 遍扫描 → 1 遍流式），
   gjson 只承担廉价的信封分类（0.5–4.5 µs）。
2. jsonvalue 降级为 **params/result 的值类型**：协议解析全程至多一次 `json → JsonValue`（仅 params 子树），未知方法**零触碰**。
3. 顺带修复的正确性问题（详见 progress-tracking.md）：
   - 大整数 id（>2⁵³）精度丢失：`9007199254740993` 被解析成 `...992` → 流式直连/raw 重建后原样保留
   - 尾随垃圾（`{"a":1} x`）从静默忽略改为 `-32700`（`validBytes` 严格校验）
   - `method:null` / `method:123` 被 `stdx readValue<String>` 宽容转换为 `"null"` / `"123"`（新旧一致的既有语义，测试固定）

## 5. 复现

基准工程已删除；如需复现，搭建一个临时 cjpm 工程（依赖 `ystyle::jsonrpc`、`gjson`、`jsonvalue`），
在 `@Test` 类中用 `@Bench` 声明上述管线函数，运行：

```shell
eval "$(cjvs env bash)" && eval "$(cjvs stdx-env bash)"
cjpm bench --filter 'BenchCurrent.*|BenchStreamingDirect.*|BenchClassifyAndStream.*'
```
