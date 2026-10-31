# `/mobile/v1` 接口契约

这是 App 与桌面插件之间**唯一的**协议。它由本项目手写维护，不随 DSH 内部接口变化。

- Base URL：`https://<host>/mobile/v1`（局域网可为 `http://<lan-ip>:<port>/mobile/v1`）
- 编码：UTF-8 JSON；时间一律 ISO-8601 UTC 字符串
- 版本策略：`v1` 内只做**向后兼容的增量**（新增字段、新增事件类型）。破坏性变更开 `v2`，App 按 `hello.capabilities` 协商。

## 1. 认证

除 `GET /hello` 与 `POST /pair` 外，所有请求需要：

```
Authorization: Bearer <deviceToken>
```

`deviceToken` 是配对时下发的一次性长期凭据（32 字节随机，base64url）。桌面端可随时吊销。
WebSocket 也接受 `?token=<deviceToken>`（部分客户端无法为握手带 header）。

失败返回 `401 {"error":{"code":"unauthorized"}}`。

## 2. 配对

桌面插件首次启动生成一枚 8 位配对码并打印在 DSH 日志里，同时写入
`$DSH_HOME/mobile-bridge/pairing.json`（10 分钟轮换）。App 扫码或手输。

```
POST /pair
{ "code": "12345678", "deviceName": "Mate 70" }

200 { "deviceId": "dev_xxx", "deviceToken": "...", "serverName": "DESKTOP-5VTUC5R" }
```

- 配对码一次性；同一码可配对多台设备，直到过期。
- 失败：`404 invalid-code`、`429 too-many-attempts`。

## 3. 发现

```
GET /hello
200 {
  "name": "DESKTOP-5VTUC5R",
  "bridgeVersion": "0.1.0",
  "dshVersion": "0.2.1-rc.2",
  "protocol": "v1",
  "capabilities": ["approval", "models", "push"]
}
```

## 4. 会话

### 列表

```
GET /sessions
200 { "sessions": [ Session ] }
```

```ts
Session = {
  id: string
  title: string
  workspace: string
  status: 'idle' | 'running' | 'waiting-approval' | 'error'
  updatedAt: string          // ISO
  preview?: string           // 最后一条消息的纯文本，截断 120 字
  parentId?: string          // subagent 会话
}
```

### 快照（首次进入 / 重连补齐）

```
GET /sessions/{id}?after=<seq>&limit=100
200 {
  "session": Session,
  "items": [ Item ],        // seq > after 的条目，升序
  "cursor": 12345,          // 本页最后一条 seq；无更多时等于服务端最新 seq
  "hasMore": false
}
```

`after` 省略时返回最近 `limit` 条（首屏），`hasMore=true` 表示还能往前翻。
往前翻用 `before=<seq>`。

### 条目模型

```ts
Item =
  | { seq, turn, type: 'user',        text: string, at: string }
  | { seq, turn, type: 'assistant',   markdown: string, at: string }
  | { seq, turn, type: 'thought',     text: string, at: string }
  | { seq, turn, type: 'tool',        callId, name, status: 'running', title?: string, at: string }
  | { seq, turn, type: 'tool-result', callId, status: 'ok'|'error', output?: string, at: string }
```

`tool` 与 `tool-result` 按 `callId` 关联：客户端先渲染运行中的工具行，收到同 `callId` 的
`tool-result` 后更新状态与输出。

- `assistant.markdown` 是原始 Markdown，客户端负责渲染（代码块、表格、列表）。
- `tool-result.output` 服务端截断到 8 KB。

### 发消息

```
POST /sessions/{id}/prompt
{ "text": "...", "images": ["att_xxx"] }

202 { "accepted": true, "turn": 7 }
```

- 会话正忙时返回 `409 session-busy`。
- 图片先 `POST /attachments`（multipart），拿到 `att_xxx` 再引用。

### 打断

```
POST /sessions/{id}/cancel
204
```

### 新建会话

```
POST /sessions
{ "workspace": "E:\\workspace", "text": "..." }
201 { "session": Session }
```

## 5. 模型

```
GET /models
200 {
  "providers": [ { "id": "deepseek-account", "models": [
      { "id": "deepseek-flash", "efforts": ["low","medium","high"] } ] } ],
  "current": { "provider": "deepseek-account", "model": "deepseek-flash", "effort": "high" }
}

POST /sessions/{id}/model
{ "provider": "deepseek-account", "model": "deepseek-flash", "effort": "high" }
204
```

## 6. 审批

审批是桌面侧的 waterfall 事件。插件注册为**第一应答者**，把请求推给手机，
并在超时（默认 15s）后 `next()` 交给桌面 UI —— 所以手机不在线时桌面行为完全不变。

```
GET /approvals
200 { "approvals": [ Approval ] }

Approval = {
  id: string                 // 事件 id
  sessionId: string
  sessionTitle: string
  toolName: string
  reason?: string            // 面向人的解释
  displayReason?: string     // 已本地化文案
  expiresAt: string
}

POST /approvals/{id}
{ "decision": "allow" | "deny" }
204
```

- 决策只有一次性 `allowed-once`，没有“永远允许”。
- 请求过期或被桌面抢先回答后，提交返回 `410 gone`，客户端应关闭弹窗。
- 与审批配套的只读上下文，随 `approval/requested` 事件一起推送（见下）。

## 7. 实时事件（WebSocket）

```
GET /ws  (Upgrade: websocket)
```

服务端推送帧：

```ts
// 建连后第一帧
{ type: 'hello', serverTime: string, cursor: number }

// 会话集合变化
{ type: 'session/upsert', session: Session }
{ type: 'session/removed', id: string }

// 会话增量
{ type: 'items', sessionId: string, items: Item[] }
{ type: 'turn', sessionId: string, phase: 'start' | 'end', stopReason?: string }

// 审批
{ type: 'approval/requested', approval: Approval, context: { recentAssistantText?: string } }
{ type: 'approval/resolved', id: string, decision: 'allow' | 'deny' | 'expired' }

// 心跳（30s）
{ type: 'ping' }
```

客户端断线重连后：先 `GET /sessions`，再对当前打开的会话
`GET /sessions/{id}?after=<本地 cursor>` 补齐，然后恢复 WS 订阅。**不要依赖 WS 重放。**

## 8. 推送（可选）

```
POST /push/register
{ "provider": "harmonyos", "token": "..." }
204
```

未配置 Push Kit 的构建可忽略此接口；插件在没有注册 token 时只发本地通知所需的信号
（`approval/requested` 等事件本身）。

## 9. 错误

```json
{ "error": { "code": "session-busy", "message": "session is running" } }
```

| HTTP | code | 含义 |
|---|---|---|
| 400 | `bad-request` | JSON 形状错误 |
| 401 | `unauthorized` | token 缺失/失效/被吊销 |
| 404 | `not-found` / `invalid-code` | 会话不存在 / 配对码错误 |
| 409 | `session-busy` | 该会话已有进行中的轮次 |
| 410 | `gone` | 审批已过期或被抢先回答 |
| 429 | `too-many-attempts` | 配对/请求限流 |
| 503 | `bridge-not-ready` | 插件尚在初始化 |

## 10. 实现进度

| 接口 | 状态 |
|---|---|
| `GET /hello` | ✅ 已实现并实测 |
| `GET /pair/code`、`POST /pair` | ✅ 已实现并实测（令牌存 SHA-256，可吊销） |
| `GET /sessions` | ✅ 已实测（标题取自 `session/title` 事件，缓存 10 分钟） |
| `GET /sessions/{id}` | ✅ 已实测（`inspect` + 事件映射） |
| `POST /sessions/{id}/prompt` | ⚠️ 已接通 `sessionController.prompt`，待在根会话上验证 |
| `POST /sessions/{id}/cancel` | ⚠️ 已接通，待验证 |
| WebSocket `/ws` | ⏳ 未实现（v1.1） |
| 审批 `/approvals` | ⏳ 未实现（v1.1） |
