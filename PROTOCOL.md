# KBBridge 协议 v1

传输：TCP，单向流上按行（`\n`）分隔的 UTF-8 JSON（NDJSON）。
角色：**macOS 侧是服务端（listen + accept）**，**Windows 侧是客户端（connect + 自动重连）**。
默认端口：`38471`。

> 为什么 Mac 是服务端：这样 Windows 侧可以配合 `ssh -L` 隧道把流量加密（见 README「安全」一节），
> 也方便 Mac 侧用 launchd 常驻、Windows 侧断线自愈。

---

## 1. 握手

客户端连接后立刻发送：

```json
{"t":"hello","proto":1,"token":"<共享密钥>","client":"windows","host":"DESKTOP-ABC"}
```

服务端校验 token 后回复其中之一：

```json
{"t":"hello_ok","proto":1,"agent":"mac","version":"1.0.0"}
{"t":"hello_err","reason":"bad_token"}
```

`hello_err` 之后服务端关闭连接；客户端按退避重试（500ms 起，上限 5s）。

## 2. 客户端 → 服务端

| 类型 | 报文 | 说明 |
|---|---|---|
| 按键 | `{"t":"key","vk":65,"scan":30,"down":true}` | `vk` = Windows 虚拟键码，`scan` = 扫描码（备用），`down` = 按下/抬起 |
| 状态 | `{"t":"state","target":"mac"\|"windows"}` | 告诉服务端「键盘现在归谁」，Mac 侧菜单栏用它显示状态（握手成功时也会补发一次） |
| 音量 | `{"t":"volume","delta":2}` | 旋钮音量变化，`delta` 为百分点（可负）。Mac 侧用 Core Audio 直接改系统输出音量，**不走按键注入** —— 实测注入音量键只会让 macOS 播放"更改音量"提示音、音量并不变化 |
| 状态复位 | `{"t":"reset"}` | 要求服务端清空所有修饰键与按键状态（每次切到 Mac 时先发） |
| 保活 | `{"t":"ping","ts":123456}` | 每 3 秒一次 |
| 退出 | `{"t":"bye"}` | 客户端主动退出前发送 |

`key` 事件里**不区分按下/抬起之外的语义**：修饰键也是普通 `key` 事件，
服务端自己从 `vk` 推导 `CGEventFlags`。

## 3. 服务端 → 客户端

| 类型 | 报文 | 说明 |
|---|---|---|
| 握手成功 | `{"t":"hello_ok",...}` | |
| 交还键盘 | `{"t":"release","reason":"hotkey"}` | 服务端在转发的按键流里识别到「交还组合键」时下发，客户端据此把目标切回 Windows |
| 保活回应 | `{"t":"pong","ts":123456}` | |
| 握手失败 | `{"t":"hello_err","reason":"..."}` | |

## 4. 状态机（Windows 侧）

```
target = Windows  --(本地 Ctrl+Alt+M，且链路 ready)-->  target = Mac
target = Mac      --(收到 {"t":"release"})------------>  target = Windows
target = Mac      --(本地 Ctrl+Alt+Shift+W 救援键)---->  target = Windows
target = Mac      --(链路断开 / 10s 无 pong / 队列溢出)->  target = Windows
```

- `target = Windows`：钩子放行，键盘正常工作。
- `target = Mac`：钩子吞掉所有物理按键，逐条转给 macOS 侧注入。
- 切到 Mac 前会先发 `reset`，再补发当前按住的键（`SyncHeldKeys`，默认开），保证 Mac 侧
  修饰键状态与手感一致。
- 救援键与「切回 Windows」都不依赖 Mac 的响应，所以 Mac 睡眠/关机/断网时键盘永远能救回来。

## 5. 组合键

| 组合键 | 在哪生效 | 作用 |
|---|---|---|
| `Ctrl+Alt+M` | Windows 本地 | 键盘交给 Mac |
| `Ctrl+Alt+W` | 转发的按键流里（macOS 侧识别） | 交还 Windows |
| `Ctrl+Alt+Shift+W` | Windows 本地 | 强制救援回 Windows（不走网络） |

三个都可以在 `kbbridge.ini` 里改。
