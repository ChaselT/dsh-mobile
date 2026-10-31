# dsh-mobile

> 把 DeepSeek Harness 装进你的口袋：一个原生鸿蒙遥控器 + 一个桌面侧桥接插件。

**DSH Mobile** 让你在手机上查看桌面 Harness 的全部会话、继续对话、处理审批、中断任务。
它不是一个 WebView 套壳 —— 手机端是原生 ArkUI，桌面端是一个约 500 行的 DSH 插件。

```
┌────────────────┐   HTTPS / WSS    ┌──────────────────────┐
│  HarmonyOS App │ ───────────────▶ │  dsh-mobile-bridge   │
│  (ArkTS/ArkUI) │   /mobile/v1/*   │  (DSH host plugin)   │
└────────────────┘                  └──────────┬───────────┘
                                               │ ctx.* / api
                                    ┌──────────▼───────────┐
                                    │   DeepSeek Harness   │
                                    └──────────────────────┘
```

## 为什么需要一个插件

DSH 的 Web GUI 说的是 Typert RPC（生成的描述符 + 逻辑流 + 事件 waterfall），
这套协议随版本演进、没有面向第三方的版本契约。把这段适配放进桌面插件里：

- App 只依赖一份**稳定、手写、有文档**的 JSON / WebSocket 接口（`/mobile/v1`）；
- DSH 升级时只改插件，不要求所有人重装 App；
- 审批这类必须落在 Host 侧的语义（waterfall、超时让位）天然就在正确的进程里。

## 仓库结构

```
packages/bridge/     DSH 插件：认证、配对、/mobile/v1（已可安装）
apps/harmony/        鸿蒙应用：ArkTS / ArkUI，原生（源码 + 接入说明）
apps/web/preview/    设计预览（浏览器里试交互，假数据）
assets/              官方图标
docs/                接口契约、安全说明
```

## 功能范围（遥控器，不做完整复刻）

- 会话列表：工作区、标题、运行状态、未读
- 会话正文：历史分页 + 实时增量（消息 / 思考 / 工具调用折叠）
- 发消息、打断
- 审批：手机优先、超时自动让位给桌面
- 切换模型与思考档位
- 通知：默认长时任务常驻通知；Push Kit 作为可选项

不做：设置面板、插件市场、终端、文件树、任务看板。

## 状态

| 部分 | 状态 |
|---|---|
| `packages/bridge` | ✅ 配对、会话列表、会话详情已实测；prompt/cancel 已接通 |
| `apps/harmony` | 🚧 源码完成（配对 / 列表 / 对话 / 发送），待 DevEco 编译验证 |
| WebSocket 实时推送 | ⏳ v1.1 |
| 审批弹窗 | ⏳ v1.1 |

## 安全模型

一个能指挥 Harness 的客户端等价于这台机器的完整控制权。因此：

- 配对由桌面端发起，一次性配对码，换取长期设备凭据；
- 凭据只存在设备安全存储（HUKS）中，桌面端可随时吊销；
- 公网访问必须走 HTTPS（推荐自己的 Cloudflare 命名隧道），不要裸暴露 HTTP；
- 插件不做遥测、不上报任何会话内容。

详见 [docs/security.md](docs/security.md)。

## 商标与归属

本项目是**非官方**的第三方客户端，与 DeepSeek 官方无隶属关系。

界面中使用的 DeepSeek Harness 图标来自本机安装的桌面客户端
（`resources/icon.png`），版权归 DeepSeek 所有，仅用于个人识别这款应用所连接的宿主。
若你要二次分发或商用，请替换为自行设计的图标。

## License

Apache-2.0
