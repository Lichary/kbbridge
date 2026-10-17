# KBBridge —— 把一把键盘用软件"桥"到两台主机上

一台三模键盘（档位：有线 / 2.4G / 蓝牙）通常只能同时连一台主机，
切换靠机身顶部的拨动开关。**这个开关是键盘 MCU 的硬件电路选择，
主机侧任何软件都拨不动它**（详见文末「为什么不能直接切档位」）。

KBBridge 换了个思路：**键盘永远插在 Windows 上，档位永远不用再动**。
Windows 侧用一个全局低级键盘钩子把按键"截下来"，当键盘该归 Mac 时，
通过局域网把这些按键转给 Mac 侧的代理，由它用 `CGEvent` 注入回 macOS。
想切回来时按一个键就行。

```
                   ┌──────────────────────── Windows ────────────────────────┐
   狼途 LT75 Pro   │  KBBridge.exe                                           │
   有线 ──────────►│   WH_KEYBOARD_LL 钩子                                   │
   （档位固定=有线）│     ├─ 目标=Windows → 放行，什么都不做                    │
                   │     └─ 目标=Mac     → 吞掉 → TCP 127.0.0.1:38471 ──┐    │
                   │   托盘图标 / 蜂鸣提示 / 救援键                        │    │
                   └──────────────────────────────────────────────────────┼────┘
                                                   局域网 (NDJSON 协议)   │
                   ┌──────────────────────── macOS ───────────────────────┼────┐
                   │  kbbridge (launchd 常驻)                             │    │
                   │   TCP 服务端 38471 ◄─────────────────────────────────┘    │
                   │     └─ CGEventPost 注入按键（需要「辅助功能」权限）        │
                   └──────────────────────────────────────────────────────────┘
```

- 协议：`PROTOCOL.md`（TCP + 按行 JSON，握手带共享 token）
- Windows 侧：C#，用系统自带 `csc.exe` 编译成**单个 exe，零依赖、不用装运行时**
- macOS 侧：Swift，`swiftc` 编译成单个可执行文件，**不需要 sudo、不装任何东西**

---

## 一、三个快捷键

| 按键 | 在哪生效 | 作用 |
|---|---|---|
| `Ctrl + Alt + M` | Windows 本地 | 键盘交给 Mac |
| `Ctrl + Alt + W` | 在转发过去的按键流里（Mac 侧识别） | 交还 Windows |
| `Ctrl + Alt + Shift + W` | Windows 本地 | **强制救援回 Windows** |

救援键是关键设计：它**不依赖网络、不依赖 Mac 活着**。所以哪怕 Mac 蓝屏、
睡眠、拔网线、断 WiFi，键盘永远能一键回到 Windows，不会出现"键盘卡在对面"。

另外切换时会用蜂鸣提示（去 Mac 是两声上行音，回 Windows 是两声下行音），
托盘图标也有颜色区分：🔵 = 键盘在 Windows，🟠 = 键盘在 Mac。

---

### 旋钮音量也会跟着切换（1.2.0+）

键盘的音量旋钮走的是 **HID 消费者控制集合**，Windows 在键盘钩子「下面」就直接处理它了
（实测：270 个按键事件里音量键 **0** 个），所以拦不住、也转发不了。

KBBridge 改用**补偿**方案：轮询 Windows 默认播放设备的主音量，当键盘在 Mac 上时，
把 Windows 的音量写回原值，并把变化量（百分点）转给 Mac，由 Mac 侧用 **Core Audio
直接设置系统输出音量**。

- Windows 侧不需要能"触发"音量变化，只需要能读写 —— 已经实测验证
- Mac 侧不走音量键路径，因为实测**注入音量键只会播放提示音、音量并不变化**
- 副作用 1：转旋钮时 Windows 可能闪一下音量条（数值立刻被写回，不变）
- 副作用 2：~~Mac 侧因此不会有 macOS 的"更改音量"提示音~~ **1.4.2 起已解决**：改完音量后补发 NX_SYSDEFINED，HUD 和提示音都会出现（见下面「音量 HUD 与提示音」）
- 副作用 3：键盘在 Mac 上时，**任何来源**的 Windows 音量改动都会被撤销（补偿方案的固有特性）
- 不想要这个行为：设置窗口里取消「音量旋钮跟随切换」，或 ini 里 `VolumeFollow=false`

### 剪贴板：Windows ↔ Mac 直接互传（1.4.0+）

**为什么加这个**：搜狗输入法的「跨设备复制粘贴」在两台 Mac 之间能原样传文件 URL，
但只要互传范围里有一台 Windows，文件就没法跨平台表示 —— 实测它会**降级成一张
1024×1024 的图标图片写回 Mac 的剪贴板，0.45 秒内就把 `public.file-url` 换掉**，
于是你复制文件、粘贴出来是图片。搜狗只提供「每台设备开/关」，**没有"只发不收"的方向开关**。

KBBridge 于是自己传剪贴板，不经过任何第三方服务：

| 支持 | 说明 |
|---|---|
| 文字 | 双向，UTF-8 |
| 图片 | 双向，PNG |

- 上限：单张图片 8 MiB，文本 10 万字符；超限跳过，不报错
- **不传文件**（1.4.1 起）：跨机器只能传内容、必须落盘，落盘失败会在剪贴板上留下悬空路径。复制文件时本通道整条跳过
- 自动同步（约每 0.7 秒检查一次），不需要按任何快捷键
- **回环抑制**：应用对端内容后记下序列号 + 内容指纹，不会把自己刚写的内容再推回去
  （这一点很重要 —— 搜狗这类会轮询剪贴板的程序会让序列号无故变化）
- 只在双方握手都声明 `caps:["clip"]` 时才启用，老版本客户端不会收到不认识的报文
- macOS 侧跳过带 `ConcealedType`/`TransientType` 标记的剪贴板（密码管理器、临时内容）
- 关闭：macOS 加 `--no-clip`；Windows ini 里 `ClipSync=false`

> **如果你还在用搜狗的跨设备复制粘贴**：请把 Windows 那台从「互传范围」里去掉，
> 或者干脆关掉那个功能。否则搜狗依然会在 0.45 秒内把 KBBridge 刚写好的文件 URL 覆盖成图片，
> 而且它会把剪贴板内容同步到搜狗服务器。两套机制同时开着只会互相打架。

### 音量 HUD 与提示音（1.4.2+）

1.2.0 起音量是直接写 Core Audio 标量的（因为实测注入普通 keyDown/keyUp 只会响一声、
音量并不动），代价是**没有 HUD、没有提示音**。

1.4.2 补上了这一块：改完音量后补发一个 `NX_SYSDEFINED` 形式的媒体键事件
（subtype 8、`data1 = (key << 16) | 0x0A00/0x0B00`），系统就会弹出音量 HUD 并播放提示音。

**但有个坑**：实测这个事件**自己也会把音量挪一格**（连发 3 次 up：64 -> 81；
3 次 down：81 -> 63，约每格 5.7%），而且系统是**异步**应用那格变化的 ——
单次写回会被它盖掉，连续下调几次音量就会越来越低。

所以实现是：**先写目标值 -> 发 HUD -> 在接下来 0.4 秒里反复写回目标值**
（放后台线程，不阻塞按键循环）。

**还有一个更隐蔽的坑（1.4.3 修）**：macOS 的音量是**固定的 16 级**
（0/6/13/19/25/31/38/44/50/56/63/69/75/81/88/94/100），HUD 就是按这 16 格画的。
如果往里写连续的百分比标量（2%、4%、6%…），就会出现「HUD 显示一格、实际音量是 6%」
这种对不上的情况 —— 用户一眼就能看出来。所以现在把音量**量化到 1/16 的整数倍**：

- 每格旋钮 = 一格 macOS 音量（`volumeDetentPercent = 2` 与 Windows 侧 delta 对齐）
- 实测序列：50 -> 56 -> 63 -> 69 -> 75 -> 81 -> 88 再原路返回，与 macOS 原生完全一致
- 这样「旋转格数 = HUD 格数 = 实际音量」三者用同一套刻度

不想要 HUD：`--no-volume-hud`，回到只改音量、不弹提示不响提示音的行为。

## 二、安装

### 1. macOS 侧：装成一个菜单栏 App（推荐）

1. 把 `kbbridge-mac.tar.gz` 传到 Mac（`scp` 或微信），**在 Finder 里双击解压**
   —— 会得到一个 `KBBridge-mac` 文件夹
2. **双击里面的 `安装 KBBridge.command`** —— 它会自动编译、组装出 `KBBridge.app`、
   装进「应用程序」、生成或沿用 Token、然后启动 App。菜单栏出现一个键盘图标。

菜单里能做的事：状态（键盘现在归哪台、辅助功能是否已授权）、**一键去授权**、
把键盘接回 Windows、复制 / 生成 Token、打开配置文件夹与日志、开机自启、退出。

首次使用要在「系统设置 → 隐私与安全性 → 辅助功能」里把 **KBBridge** 打开（点菜单里的
「辅助功能：未授权 ✗」会直接跳到那个面板），改完**退出 App 再重新打开一次**。

> 如果双击 `.command` 提示"无法验证开发者"（微信/浏览器下载会带隔离标记）：
> **右键点它 → 打开 → 再点"打开"** 即可；用 `scp` 传的不会有这个问题。

> 为什么还要在 Mac 上编译一次：`.app` 是 macOS 二进制，在 Windows 上生成不了。但只需要
> 这一次；之后它就是一个普通 App，可以直接复制、备份、拖进「应用程序」，重装系统后拷回来就能用。

诊断命令（安装脚本会在 `~/.kbbridge/bin/` 放一份同样的二进制副本）：

```bash
~/.kbbridge/bin/kbbridge --check          # 看辅助功能授权状态
~/.kbbridge/bin/kbbridge --volume-test    # 测旋钮音量通道（Core Audio）
```

### 1b. macOS 侧：纯命令行方式（备选，调试用）

（以下为原来的命令行安装方式；App 方式更省事，两者不要同时用 —— 
`install-app.sh` 会自动清理命令行方式注册的 launchd 服务。）

```bash
cd kbbridge/mac
chmod +x build.sh install.sh uninstall.sh
./install.sh                 # 会自动生成 32 位 token 并打印出来
```

`install.sh` 做四件事：编译 → 把可执行文件放到 `~/.kbbridge/bin/kbbridge`
→ 把 token 写进 `~/.kbbridge/token`（权限 600）→ 注册 launchd
开机自启（`~/Library/LaunchAgents/com.kbbridge.agent.plist`）。**全程不需要 sudo。**

> token 故意不写进 plist：命令行参数在 `ps aux` 里别的用户能看到，从文件读更安全。

**然后把打印出来的 token 记下来，下一步要用。**

### 2. 给 mac 侧授予「辅助功能」权限（必须做，最容易漏）

没有这个权限，`CGEventPost` 会被系统**静默丢弃**——现象就是"Windows 那边看起来一切正常、
按键也发出去了，但 Mac 毫无反应"，而且没有任何报错。这是本方案 90% 的失败原因。

最省事的顺序：

```bash
# 1) 先在终端手动跑一次，系统会弹出授权请求
~/.kbbridge/bin/kbbridge --port 38471
#    Ctrl+C 结束

# 2) 如果没弹窗，手动去「系统设置 → 隐私与安全性 → 辅助功能」，
#    点 + 号添加这个文件（选择框里按 Cmd+Shift+G 可直接粘路径）：
#        ~/.kbbridge/bin/kbbridge

# 3) 重启服务
launchctl kickstart -k gui/$(id -u)/com.kbbridge.agent

# 4) 确认
~/.kbbridge/bin/kbbridge --check          # 输出「已授权」才算成功
tail -f ~/.kbbridge/logs/agent.log
```

> 授权是按**二进制路径**记录的：以后重新编译（路径不变但文件内容变了）通常需要重新授权一次。

### 3. 查 Mac 的 IP，放开 Mac 防火墙

```bash
ipconfig getifaddr en0        # 有线是 en0，WiFi 也可能是 en1
```

macOS 自带防火墙如果开着，需要允许它接入：

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add ~/.kbbridge/bin/kbbridge
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp ~/.kbbridge/bin/kbbridge
```
（或者到「系统设置 → 网络 → 防火墙 → 选项」里允许。）

### 4. Windows 侧

直接双击 `windows\install.cmd`，或者在 PowerShell 里：

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -MacHost 192.168.1.50 -Token <Mac 打印的那串>
```

> ⚠️ 你这台机器的 PowerShell 执行策略是 **Restricted**，所以上面这个
> `-ExecutionPolicy Bypass` 不能省，双击 `.cmd` 是等价的。

`install.ps1` 会：编译 exe 到 `%LOCALAPPDATA%\KBBridge` → 写 `kbbridge.ini`
→ 在「启动」文件夹建快捷方式实现开机自启 → 立刻运行。

然后托盘里应该出现一个**蓝色圆点**，说明它在跑。

### 5. 联调自检（可选，但强烈建议第一次跑一下）

Windows 侧提供两种不带副作用的自检：

```powershell
$dir = "$env:LOCALAPPDATA\KBBridge"
# 编译一个控制台版方便看输出
powershell -ExecutionPolicy Bypass -File .\windows\build.ps1 -Console -OutDir $dir

# A) 只测协议和状态机（不装键盘钩子）
& "$dir\KBBridge-console.exe" --selftest --host 192.168.1.50 --port 38471 --token <token>

# B) 真装一次键盘钩子，用无害的 F24 验证「拦截 → 转发」整条链路
& "$dir\KBBridge-console.exe" --selftest-hook --host 192.168.1.50 --port 38471 --token <token>
```

期望输出：

```
SELFTEST handshake=OK release_received=YES target_back_to_windows=YES     ← A 通过
SELFTEST-HOOK install=OK downs_seen=3 forwarded=6 target=0                ← B 通过
```

Mac 侧此时会在 `~/.kbbridge/logs/agent.log` 里打印收到 `vk=135` 的按键。

---

## 二之二、设置窗口与便携包（重装/换机不再重配）

### 图形设置窗口 `KBBridgeSettings.exe`

托盘图标右键 → **设置…** 也能打开它。

- **状态**：服务运行中/未运行、当前配置文件与日志的路径
- **连接**：Mac 地址、端口、Token（可显示/隐藏）
- **测试连接**：就地做一次真实握手，直接告诉你是「端口不通 / Token 不对 / 没授权」哪一关没过
  （Mac 侧同一时刻只服务一个连接，所以测试会先停一下服务、测完自动拉起来，约 3 秒）
- **快捷键**：切到 Mac、救援回 Windows 都可改
- **选项**：蜂鸣、托盘图标、补发按住的修饰键、开机自启、逐键日志（诊断用）

「开机自启」写的是当前用户的 `HKCU\...\Run` 项，**不需要管理员**；并且会自动清掉早期版本放在
「启动」文件夹里的快捷方式，避免两处同时启动。

### 便携包

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\make-portable.ps1
# 指定位置 / 生成不含 Token 的版本：
powershell -ExecutionPolicy Bypass -File .\windows\make-portable.ps1 -OutDir D:\Backup\KBBridge -NoToken
```

产物 `kbbridge-portable\`：

```
KBBridge.exe / KBBridgeSettings.exe   两个程序（零依赖，双击即用）
kbbridge.ini                          配置，和 exe 同目录 = 便携模式
重装速查.txt                           五步走完的恢复说明
src\                                  源码 + 编译/安装脚本（要重编译时用）
```

**为什么这样就"不用重配"**：常驻代理查找配置的顺序是 **`exe 同目录\kbbridge.ini` 优先于**
`%LOCALAPPDATA%\KBBridge\kbbridge.ini`。所以只要把一整个文件夹放在你会备份的地方
（D 盘、网盘、移动硬盘），重装系统后双击 exe 就是完整已配好的状态；唯一要重做的是
「开机自启」（设置窗口里勾一下）。

换 Mac 或 Mac 重装：把 `src\mac` 拷过去重新编译安装，**辅助功能授权必须重新点一次**
（TCC 跟着系统和用户走，任何软件都一样）。

> ⚠️ `kbbridge.ini` 里含共享 Token（相当于钥匙）。放进云盘/共享目录前请自行取舍，
> 或用 `-NoToken` 生成不含 Token 的版本。
> 仓库已经配好 `.gitignore`（排除编译产物、日志、`kbbridge.ini`、token）和 `.gitattributes`
> （强制 `*.sh` 用 LF，避免在 Windows 上 clone 后 shell 脚本跑不了），装好 git 后
> 在 `kbbridge\` 目录里 `git init` 即可。

### 两个 macOS 上的隐蔽坑（实战踩过，务必知道）

**坑 1：`open KBBridge.app` 报 `-10825`，而且「辅助功能」里死活加不进去 —— 两者是同一个根因。**

`swiftc` 不指定 `-target` 时，二进制的 `LC_BUILD_VERSION.minos` 会跟随这套 CLT 的**默认部署目标**
（实测某套 CLT 是 `arm64-apple-macosx28.0`）。只要这个值**高于当前系统版本**，就会：

- LaunchServices 拒绝启动：`kLSIncompatibleSystemVersionErr (-10825)`，`open` 报 `-10825`
- `tccd` 解析不到这个 bundle（`failed to find an Application URL for bundle ID`），
  于是**辅助功能面板里怎么都加不进去**（`tccutil` 会报 `-10814 kLSApplicationNotFoundErr`）

`make-app.sh` / `build.sh` 现在都会显式传 `-target "$(uname -m)-apple-macosx11.0"`，
并且 `make-app.sh` 会用 `vtool -show-build` **自检 minos 是否高于本机**，超了就报错退出。

> 注意：`MACOSX_DEPLOYMENT_TARGET=11.0` 对 `swiftc` **无效**，必须用 `-target`。

**坑 2：ad-hoc 签名下，重编译会让辅助功能授权失效。**

ad-hoc 签名（`codesign --sign -`）时 TCC 用 **cdhash** 记录授权，重编译就掉，得重新授权。
解决办法是建一张**自签名代码签名证书**并用它签：TCC 会记 **certificate leaf**，
之后改源码、重编译、重装都**不掉授权**（已实测：cdhash 变了，`--check` 仍是「已授权」）。

```bash
cd mac && ./make-cert.sh      # 跑一次即可；install-app.sh 会自动调用它
```

`make-cert.sh` 里三个必须照做的细节（都是实测踩出来的）：

1. `openssl pkcs12` **必须**带 `-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`。
   OpenSSL 3.x 默认的 AES-256-CBC/SHA-256 格式 macOS 的 `security` 验不过，会报
   `MAC verification failed during PKCS12 import` —— **看着像密码错，其实是算法不兼容**。
2. `security add-trusted-cert` **不加 `-d`、不用 sudo**，只写用户信任域、只 `-p codeSign`。
   用户信任域**不需要密码、命令立即返回**；只有误加 `-d`（写 admin 域）才会要求输入登录密码
   —— 所以整个设计的要点就是**别加 `-d`**。
3. `security import` 要带 `-T /usr/bin/codesign`，否则签名时弹不出可用私钥。

`make-app.sh` 会自动优先使用名字里带 `KBBridge` 的自签名证书（也可用
`KBBRIDGE_SIGN_ID` 显式指定），找不到才回退 ad-hoc；签名失败时**不再吞掉 codesign 的报错**。

**坑 3：macOS 自带的是 bash 3.2，变量展开后紧跟中文全角标点会被当成变量名的一部分。**

```bash
echo "要求 macOS $MINOS_ACTUAL，但本机是 $HOST_VER"
#     line 73: MINOS_ACTUAL（: unbound variable     ← bash 把「，」当成了变量名的一部分
```

凡是 `$VAR` 后面**紧跟非 ASCII 字符**的地方，一律写成 `${VAR}` 再跟标点。
本仓库的 shell 脚本已全部按这个规则检查过（`${ARCH}`、`${MINOS}`、`${MINOS_ACTUAL}`、`${SIGN_ID}` …）。

**坑 4：中文输入源会把注入的字母当拼音吃掉。**

`CGEventPost(.cghidEventTap)` 是在 HID 层注入，事件会走**完整的输入管线**（输入法 + 自动大写），
这正是"像真实键盘"该有的行为；但也意味着**输入源是中文时，字母会被拼音吞掉**：

| 输入源 | 注入 `mabc123` 实际得到 |
|---|---|
| 搜狗拼音 | `漫长23` ← 字母被当拼音吃了 |
| ABC / US English | `mabc123` ✓ |

**所以打字验收前必须先确认输入源是 ABC / US English，否则结果完全不可信，会把人引向不存在的注入 bug。**

**坑 5：别用空文档做首字符判定。**

TextEdit / 备忘录对**空文档的第一个字符**会自动大写（`NSAutomaticCapitalizationEnabled`），
于是注入了 `m` 却看到 `M`，很容易误判成"Shift 卡住"。正确做法是用**位置对照**：

```text
敲 "1m"  →  出 1m  = 位置相关（自动大写），正常
            出 1M  = 与位置无关，才需要查注入
```

### 打字/旋钮验收规程（照做，否则结果不可信）

1. **先确认输入源 = ABC / US English**（中文态下字母会被拼音吃掉，见坑 4）
2. **不要用空文档做首字符判定**（自动大写会污染第一个字符，见坑 5）；用 `1m` 这种位置对照
3. **旋钮验收不要从音量 100 开始**（已经最大，往上转不会有任何变化）；从中间往下转
4. 判据：Mac 音量每格变化与 Windows 一格相同（默认 2%），且 **Windows 音量保持不变**

## 三、安全：请读这一段

协议本身**没有加密**。按键（包括你敲的密码）会以明文经过局域网。
家里/自己工位的有线局域网通常可以接受，但要知道这件事。三个选择：

1. **接受**（默认）：至少把 token 保持随机 32 位，并且**只在可信局域网使用**。
2. **走 SSH 隧道**（推荐，且不需要改代码）：
   Mac 侧改成只监听本地，Windows 侧开一条隧道再连本地端口。

   macOS 侧 `~/.kbbridge/bin/kbbridge --bind 127.0.0.1`（或改 plist 里的 `--bind`），
   并在「系统设置 → 通用 → 共享」里打开**远程登录**。然后 Windows 侧：

   ```powershell
   ssh -N -L 38471:127.0.0.1:38471 你的用户名@192.168.1.50
   ```
   再让 KBBridge 连 `127.0.0.1`（把 `kbbridge.ini` 里的 `MacHost` 改成 `127.0.0.1`）。
   流量全程加密，token 还可作为第二道门槛。

3. 上网环境/公共 WiFi：**别用**，直接用回物理档位。

另外：token 是唯一的鉴权手段（长度、比较都是定长的），不要把端口暴露到公网。

---

## 四、已验证 / 未验证（说实话）

**已经在本机实测验证的（Windows 侧）**

| 项目 | 结果 |
|---|---|
| `csc.exe` 编译（Windows 11 25H2 / PowerShell 5.1） | ✅ 22 KB 单文件 exe |
| 没有服务端时握手失败并正确返回 | ✅ `handshake=FAIL`，退出码 2 |
| **客户端先启动、服务端 3 秒后才起来** | ✅ 指数退避自动重连后握手成功 |
| 握手 / token 校验 / 收发 JSON 报文 | ✅ 见 mock 端收到的原始流水 |
| 切到 Mac 时补发按住的修饰键 | ✅ 收到 `LShift down` + `LCtrl down` |
| 收到 `release` 后切回 Windows | ✅ `target_back_to_windows=YES` |
| **真装 `WH_KEYBOARD_LL` 钩子并拦截转发** | ✅ `install=OK`，6 个 F24 事件全被转发 |
| 托盘图标、蜂鸣、日志、自启 | ✅ 编译并启动正常 |

测试工具：`tools/mock_mac_server.py`（假扮 Mac 侧，你也可以拿来当"对端不存在时"的调试工具）

```bash
python tools/mock_mac_server.py --port 38471 --token testtoken --release-after 4
```

**未验证的部分（我摸不到那台 Mac，必须由你实测）**

1. **Swift 代码没有在本机编译过**——这里没有 macOS/Swift 工具链。
   语法是按 Swift 5 保守写法来的，但第一次 `swiftc` 可能会报错。
   如果报错，把错误贴给我，我直接改。
2. **按键注入的实际效果**（`CGEventPost` + 辅助功能权限）需要你在 Mac 上试：
   先在 Mac 上打开「文本编辑」，按 `Ctrl+Alt+M` 把键盘交给 Mac，然后打字。
3. **launchd 自启、TCC 授权流程**同上，属于必须在真机上走一遍的部分。

---

## 五、故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 托盘是蓝点，但按 `Ctrl+Alt+M` 没反应（响一声低音） | Mac 链路没连上。看日志 `%LOCALAPPDATA%\KBBridge\kbbridge.log`：<br>· `连接超时` → Mac 的 IP 不对 / 不在同一网段<br>· `握手被拒绝` → 两边 token 不一致<br>· Mac 防火墙挡了 38471 |
| 日志显示握手成功，但 Mac 上打字没反应 | **辅助功能权限没给**。跑 `kbbridge --check`，去设置里加 `~/.kbbridge/bin/kbbridge`，然后 `launchctl kickstart -k` |
| 键盘"卡"在 Mac 上回不来 | 按 `Ctrl+Alt+Shift+W`（本地救援键，不需要网络）。或者在 Windows 上右键托盘 → 「切回 Windows」 |
| Mac 上出现"粘住"的 Cmd/Ctrl | 已有多重防护：切到 Mac 前发 `reset`、Mac 静默 10 秒自动释放、断开连接时释放。若仍复现，按一下那些修饰键即可 |
| **只有个别键失灵（尤其 `M`）** | 1.0.0 的 bug：被钩子吞掉的按键不更新系统 async key state，导致切换后系统仍认为 Ctrl/Alt 按着，于是每次敲 `M` 都被误判成 `Ctrl+Alt+M` 而吞掉。1.0.1 改成用钩子自己的按键状态表判断，已修。确认日志首行是 `KBBridge 1.1.1 启动` |
| **切回 Windows 后每个键都变成 `Ctrl+某键`** | 1.1.0 及更早的 bug：切到 Mac 之前 Windows 已经收到了 Ctrl/Alt 的**按下**（那一刻目标还是 Windows），切过去之后它们的**抬起**被吞掉，Windows 便永远认为 Ctrl 按着。1.1.1 会把这些「Windows 见过按下」的键的抬起放行给它，并让 Mac 侧同时 `reset`。临时自救：在 Windows 上按一下 Ctrl 再松开即可清掉。确认日志首行是 `KBBridge 1.1.1 启动` |
| `Ctrl+Alt+W` 在 Mac 上被当成普通快捷键 | 它就是被拦下来当开关用的，不会传给 Mac。不想要这个行为就改 `main.swift` 里 `--release-key` 或直接改判定条件 |
| UAC 弹窗 / 锁屏界面时按键跑去了 Windows | 低级钩子在安全桌面/提权窗口前拦截不到，这是 Windows 的设计。这类场景请用物理档位 |
| 在提权（管理员）窗口里打字时按键漏到 Windows | 非提权进程的钩子看不到发往提权窗口的输入（UIPI）。需要就"以管理员身份运行"那个 exe（自启则需改用计划任务） |
| 某些游戏仍然响应键盘 | 独占/原始输入（Raw Input、DirectInput）可能绕过钩子。这类场景用物理档位 |
| 非 QWERTY 布局下字符不对 | 映射是按**物理键位**做的（这正是保留 Mac 输入法正常工作的原因）。布局差异大时需要改 `vkToMac` 表 |
| 中文输入法 | 注入的是物理键码，所以 Mac 侧的输入法（拼音等）照常工作，候选框也在 Mac 上 |
| 重编译后自启失效 | 「启动」文件夹里是快捷方式，指向 `%LOCALAPPDATA%\KBBridge\KBBridge.exe`，重编译覆盖它即可；若是回退成了复制 exe，需要重新跑一次 `install.ps1` |

日志位置：
- Windows：`%LOCALAPPDATA%\KBBridge\kbbridge.log`（UTF-8；托盘右键「打开日志」）
- macOS：`~/.kbbridge/logs/agent.log`、`agent.err`

---

## 六、已知限制（设计上做不到的）

1. **BIOS/启动菜单、Windows 登录界面、FileVault 解锁界面**：这些场景下钩子和注入都不成立，必须用物理档位。收到输入的那一侧根本还没有"软件"在跑。
2. **`Ctrl+Alt+Del`** 永远归 Windows（系统保留，拒绝被钩子拦截）。
3. **Windows 必须开机且已登录**，Mac 才有键盘用（Mac 不会自己"接管"一把插在别人身上的键盘）。
4. **鼠标没有做**。协议里留了 `type` 字段，加鼠标（`WH_MOUSE_LL` + `CGEvent` 鼠标事件）是同一套结构的自然扩展，需要的话可以加。
5. **剪贴板共享没做**（Deskflow 那类工具的重点功能之一）。

---

## 七、文件清单

```
kbbridge/
├── README.md                      ← 你正在看的
├── PROTOCOL.md                    协议与状态机定义
├── windows/
│   ├── KBBridge.cs                Windows 侧全部源码（C# 5，一个文件）
│   ├── KBBridgeSettings.cs        图形设置窗口（单独编译成 KBBridgeSettings.exe）
│   ├── app.manifest               视觉样式 + DPI 感知
│   ├── build.ps1 / build.cmd      编译（用系统自带 csc.exe，产出两个 exe）
│   ├── install.ps1 / install.cmd  安装 + 开机自启
│   ├── uninstall.ps1              卸载
│   └── make-portable.ps1          打便携包（重装系统用）
├── mac/
│   ├── main.swift                 macOS 侧全部源码（菜单栏 App + 命令行模式，一个文件）
│   ├── make-cert.sh               建本地自签名代码签名证书（让辅助功能授权不因重编译失效）
│   ├── make-app.sh                组装 KBBridge.app（手工拼 bundle + Info.plist + 证书签名）
│   ├── install-app.sh             构建 + 装到「应用程序」+ 迁移旧服务 + 启动
│   ├── 安装 KBBridge.command       双击入口：在 Finder 里双击它就完成安装
│   ├── build.sh                   编译（swiftc，命令行模式用）
│   ├── install.sh                 命令行安装 + launchd 自启（备选路径）
│   └── uninstall.sh               卸载
└── tools/
    └── mock_mac_server.py         假扮 Mac 侧，用来在没 Mac 时验证 Windows 侧
```

---

## 八、为什么不能直接切档位（附：为什么替代方案也不行）

狼途 LT75Pro 的三模开关在机身顶部（[拆解/评测](https://game.3loumao.org/408476704)），
它选的是 **有线 / 2.4G / 蓝牙**。想"写个插件去拨它"，会撞上三堵墙：

1. **档位是 MCU 的一个 GPIO 电平**，拨动时**不产生任何 USB 报文**——没有可逆向的
   "切换命令"存在。用 USBPcap/Wireshark 也抓不到，因为事件压根不经过 USB。
2. **Fn 组合键在键盘 MCU 内部就被消化了**。`Fn` 永远不进入主机的 HID 流，
   所以主机**发不出** `Fn+1/2/3` 这类组合（AutoHotkey / Karabiner 都做不到）。
3. **就算存在私有 HID 命令也没用**：切到蓝牙的那一瞬间 USB 通道自己就断了，
   下命令的链路会切断自己。2.4G dongle 也救不了，因为档位不经过 dongle。

顺带排除过的其他路子：

- **官方驱动**：只能做灯效/宏，而且它靠 USB HID 通信，切到蓝牙档位后连都连不上（[狼途驱动说明](https://www.160.com/article/13111.html)）。
- **微软 Mouse Without Borders**：不支持 macOS。
- **macOS Universal Control**：不支持 Windows。
- **AutoHotkey / Karabiner**：只能改**本机**按键，跨不了主机。

本机实测到的接口形态（`pnputil` + 注册表枚举）：这把键盘（或另一个键盘形态的复合设备）
确实暴露了 **vendor-defined HID 集合**，也就是厂商私有通道——但那是给灯效/屏幕/宏用的，
里面没有"切连接模式"这条命令。

**真的想自动化"拨那个开关"，只剩硬件一条路**：USB 继电器 / 舵机压住拨杆，
或者拆机把开关的两个位置引出到继电器上，然后用脚本（甚至 HomeKit/快捷指令）控制。
十块钱的成本，但要动烙铁、失去保修。
