# dsh-mobile

> 把 DeepSeek Harness 装进你的口袋：一个原生鸿蒙遥控器 + 一个桌面桥接插件。

在手机上看桌面 Harness 的全部会话、继续对话、处理审批、中断任务、预览产出的图片和视频。
手机端是原生 ArkUI（不是 WebView 套壳），桌面端是一个零依赖的 DSH 插件。

```
┌──────────────────┐    HTTPS     ┌────────────────────────┐
│  HarmonyOS App   │ ───────────▶ │  dsh-mobile-bridge     │
│  (ArkTS / ArkUI) │ /mobile/v1/* │  (DSH host plugin)     │
└──────────────────┘              └───────────┬────────────┘
                                              │ ctx.* 服务
                                  ┌───────────▼────────────┐
                                  │   DeepSeek Harness     │
                                  └────────────────────────┘
```

桌面插件单独开源：**[dsh-mobile-bridge](https://github.com/ChaselT/dsh-mobile-bridge)**

---

## 功能

**会话**
- 按工作区分组的会话列表，第二行显示最后一条消息的预览
- 置顶排序、归档、归档列表恢复、重命名
- 搜索：标题 / 预览 / 工作区名，输入即筛

**对话**
- Markdown 渲染（标题、列表、表格、代码块、引用）
- 思考过程折叠、连续工具调用折叠成「N 个操作」
- 「已编辑 N 个文件」diff 卡片（+N −M）
- 图片直接显示，视频内嵌播放（支持拖动进度）
- 长轮询增量刷新，一轮进行中可看到工具逐条出现
- 发送键内嵌输入框，运行中变 ■ 可随时打断

**控制**
- 权限三档切换：仅可查看 / 工作区内修改 / 完全权限
- 模型与思考档位切换
- 审批弹窗：手机上点「允许一次」或「拒绝」，5 分钟超时自动取消

**账号**
- 余额、今日消耗、峰谷状态（工作日 09:00-12:00 / 14:00-18:00 为高峰）
- 用量页：近 7 天柱状图 + 峰谷说明

**其它**
- 多主机：一个 App 管多台电脑，可切换、改名、删除
- 图片上传：选图 → 存到会话工作区 → 路径插入消息
- 后台提醒：常驻任务 + 通知（审批、任务完成）
- 扫码配对：扫桌面上的二维码自动填地址和配对码

---

## 快速开始

### 1. 桌面：安装桥接插件

```powershell
dsh plugin add github:ChaselT/dsh-mobile-bridge --profile desktop
```

确认 `%USERPROFILE%\.dsh\profiles\desktop\package.json` 的 `dsh.profile.bundles` 里有 `dsh-mobile-bridge`，重启 DSH。

### 2. 桌面：配置地址

设置 → **手机遥控器** → 填地址 → 保存：

- 局域网：`http://192.168.x.x:8867`
- 公网：`https://dsh.example.com`（需自建 Cloudflare 隧道，指向 `127.0.0.1:8848`）

### 3. 手机：配对

App 里点主机名 → **＋ 添加电脑** → **扫码配对**，扫桌面上的二维码。

---

## 编译 App

需要 **DevEco Studio** + HarmonyOS SDK（本项目在 SDK API 26 上开发，真机为 HarmonyOS 7）。

```powershell
# 配置环境
$env:DEVECO_SDK_HOME = "D:\soft\DevEco Studio\sdk"
$env:JAVA_HOME      = "D:\soft\DevEco Studio\jbr"
$env:PATH           = "$env:JAVA_HOME\bin;$env:PATH"

cd apps\harmony
"D:\soft\DevEco Studio\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default assembleHap --no-daemon
```

产物：`apps/harmony/entry/build/default/outputs/default/entry-default-signed.hap`

安装到手机：

```powershell
hdc install -r entry-default-signed.hap
```

App 首次运行需要签名，DevEco 里选「自动签名」用你自己的华为账号即可。

---

## 仓库结构

```
apps/harmony/       鸿蒙 App 源码（ArkTS / ArkUI）
packages/bridge/    桥接插件的副本（主仓库在 dsh-mobile-bridge）
apps/web/preview/   早期设计预览（浏览器里跑，假数据）
docs/               接口契约、安全说明
assets/             图标
```

---

## 接口

手机和桌面之间只有一套 `/mobile/v1` JSON 接口，清单见 [docs/api.md](docs/api.md)。

设计取舍：

- **不直连 Typert**：DSH 的 Web GUI 协议随版本演进、没有第三方版本契约，直连等于把 App 绑死在某个 DSH 版本上
- **稳定契约在插件里**：DSH 升级只改插件，不必让所有人重装 App
- **审批落在 Host 侧**：`approval/request` 是宿主瀑布，超时让位这类语义只有在正确进程里才做对

---

## 安全

一个能指挥 Harness 的客户端等价于这台机器的完整控制权，因此：

- 配对由桌面发起，一次性 8 位配对码（10 分钟）换长期设备令牌
- 令牌在桌面只存 SHA-256 哈希，可随时吊销
- 公网访问必须走 HTTPS（推荐自己的 Cloudflare 命名隧道），不要裸暴露 HTTP
- `/pair/code`、`/pair/qr`、`/pair/uri`、`/config` 只允许本机回环访问
- 插件不做遥测、不上报任何会话内容

详见 [docs/security.md](docs/security.md)。

---

## 已知限制

- **全文搜索未启用**：DSH 的会话索引默认 `openAt: never`，所以搜索只匹配标题 / 预览 / 工作区名
- **图片上传**是「路径注入」而非原生附件：模型需要自己 `read` 那个路径
- **媒体预览**只识别绝对路径，相对路径解析不到
- **删除会话**未实现（避免误删）
- **深色模式**未做
- **权限切换**只对有活动实例的会话生效

---

## 商标与归属

本项目是**非官方**的第三方客户端，与 DeepSeek 官方无隶属关系。

界面中的 DeepSeek Harness 图标取自本机安装的桌面客户端（`resources/icon.png`），版权归 DeepSeek 所有，仅用于标识所连接的宿主。二次分发或商用请替换为自行设计的图标。

---

## License

Apache-2.0
