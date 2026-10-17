// =====================================================================
//  KBBridge — macOS 侧代理  (PROTOCOL.md v1)
//
//  Windows 侧把「吞掉」的按键通过 TCP 发过来，这里用 CGEvent 注入回系统。
//
//  编译:  ./build.sh                      需要 Xcode Command Line Tools
//  手动跑: ~/.kbbridge/bin/kbbridge --port 38471
//  安装:  ./install.sh                    编译 + 写 token + 注册 launchd，不需要 sudo
//  自检:  ~/.kbbridge/bin/kbbridge --check  只打印辅助功能授权状态
//
//  权限: 必须授予「辅助功能」(Accessibility)，否则 CGEventPost 会被系统静默丢弃。
//
//  快捷键: 在转发过来的按键流里识别 Ctrl+Alt+W → 回一条 release 让 Windows
//          把键盘收回去。不需要 Input Monitoring（我们不监听本地键盘）。
// =====================================================================

import Foundation
import CoreGraphics
import ApplicationServices
import Darwin
import CoreAudio
import AppKit

// ---------------------------------------------------------------------
//  配置
// ---------------------------------------------------------------------
struct Options {
    var port: UInt16 = 38471
    var bind: String = "0.0.0.0"
    var token: String = ""
    var tokenFile: String = NSHomeDirectory() + "/.kbbridge/token"
    var releaseKey: UInt16 = 0x57          // Windows VK: 0x57 = 'W'
    var idleCloseSeconds: Double = 15.0    // 这么久没有报文就断开，好让新连接进来
    var stuckReleaseSeconds: Double = 10.0 // 这么久没有报文就释放所有按住的键
    var verbose: Bool = false
    var checkOnly: Bool = false
    var volumeTest: Bool = false
    var gui: Bool = false
    // 实验性：点击重写器。默认关闭；--click-rewrite / KBBRIDGE_CLICK_REWRITE=1 /
    // ~/.kbbridge/click-rewrite 文件，三者任一存在即启用（双击启动没有参数，
    // 所以必须留出后两条路）。
    var clickRewrite: Bool = false
    // 剪贴板通道（默认开）。--no-clip 关闭，用于只想用键盘、不想让剪贴板外发的情况。
    var clipSync: Bool = true
}

func printUsage() {
    print("""
    KBBridge macOS 侧代理

      --port <n>          监听端口（默认 38471）
      --bind <addr>       监听地址（默认 0.0.0.0；配 ssh 隧道时用 127.0.0.1）
      --token <hex>       共享密钥（默认从 ~/.kbbridge/token 读）
      --token-file <path> 密钥文件路径
      --release-key <hex> 交还组合键的主键 Windows VK，默认 57（W）
      --check             只检查辅助功能授权状态然后退出
      --volume-test       只测一下能不能读写系统输出音量（Core Audio）然后退出
      --gui               以菜单栏 App 的形式运行（双击 KBBridge.app 就是这个模式）
      -v, --verbose       打印未映射的按键
      --click-rewrite     实验性：让 Cmd/Shift+点击 生效（需「输入监控」权限）
                          默认关闭；也可用 KBBRIDGE_CLICK_REWRITE=1 或
                          ~/.kbbridge/click-rewrite 文件启用
      --no-clip           关闭剪贴板同步（默认开启：文字/图片/文件 双向同步）
      -h, --help          显示帮助
    """)
}

func parseArgs() -> Options {
    var o = Options()
    let env = ProcessInfo.processInfo.environment
    if let v = env["KBBRIDGE_PORT"], let p = UInt16(v) { o.port = p }
    if let v = env["KBBRIDGE_BIND"] { o.bind = v }
    if let v = env["KBBRIDGE_TOKEN"] { o.token = v }

    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        let a = args[i]
        switch a {
        case "--port":
            if i + 1 < args.count, let p = UInt16(args[i + 1]) { o.port = p; i += 1 }
        case "--bind":
            if i + 1 < args.count { o.bind = args[i + 1]; i += 1 }
        case "--token":
            if i + 1 < args.count { o.token = args[i + 1]; i += 1 }
        case "--token-file":
            if i + 1 < args.count { o.tokenFile = args[i + 1]; i += 1 }
        case "--release-key":
            if i + 1 < args.count, let v = UInt16(args[i + 1], radix: 16) { o.releaseKey = v; i += 1 }
        case "--check":
            o.checkOnly = true
        case "--volume-test":
            o.volumeTest = true
        case "--gui":
            o.gui = true
        case "-v", "--verbose":
            o.verbose = true
        case "--click-rewrite":
            o.clickRewrite = true
        case "--no-clip":
            o.clipSync = false
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            break
        }
        i += 1
    }
    return o
}

// ---------------------------------------------------------------------
//  日志
// ---------------------------------------------------------------------
let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func logLine(_ s: String) {
    print("[" + timeFormatter.string(from: Date()) + "] " + s)
    fflush(stdout)
}

// ---------------------------------------------------------------------
//  权限
// ---------------------------------------------------------------------
// 用字面量键名而不是 kAXTrustedCheckOptionPrompt：后者在不同 SDK 里有
// Unmanaged<CFString>! 和 CFString! 两种导入形态，字面量两边都能编译，
// 而且值就是 "AXTrustedCheckOptionPrompt"。
let kAXTrustedPromptKey = "AXTrustedCheckOptionPrompt"

func accessibilityTrusted(prompt: Bool) -> Bool {
    // 不弹窗时走最朴素的 API，完全不依赖任何常量导入形态
    if !prompt { return AXIsProcessTrusted() }
    let opts = [kAXTrustedPromptKey: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

// ---------------------------------------------------------------------
//  Windows VK → macOS 虚拟键码
//  （macOS 键码是“物理位置”，所以这里只按位置对应，具体字符交给 Mac 的输入法）
// ---------------------------------------------------------------------
let vkToMac: [UInt16: CGKeyCode] = [
    // 字母
    0x41: 0x00, 0x42: 0x0B, 0x43: 0x08, 0x44: 0x02, 0x45: 0x0E, 0x46: 0x03,
    0x47: 0x05, 0x48: 0x04, 0x49: 0x22, 0x4A: 0x26, 0x4B: 0x28, 0x4C: 0x25,
    0x4D: 0x2E, 0x4E: 0x2D, 0x4F: 0x1F, 0x50: 0x23, 0x51: 0x0C, 0x52: 0x0F,
    0x53: 0x01, 0x54: 0x11, 0x55: 0x20, 0x56: 0x09, 0x57: 0x0D, 0x58: 0x07,
    0x59: 0x10, 0x5A: 0x06,
    // 数字
    0x30: 0x1D, 0x31: 0x12, 0x32: 0x13, 0x33: 0x14, 0x34: 0x15,
    0x35: 0x17, 0x36: 0x16, 0x37: 0x1A, 0x38: 0x1C, 0x39: 0x19,
    // 标点
    0xBA: 0x29, 0xBB: 0x18, 0xBC: 0x2B, 0xBD: 0x1B, 0xBE: 0x2F, 0xBF: 0x2C,
    0xC0: 0x32, 0xDB: 0x21, 0xDC: 0x2A, 0xDD: 0x1E, 0xDE: 0x27, 0xE2: 0x0A,
    // 编辑/导航
    0x08: 0x33, 0x09: 0x30, 0x0D: 0x24, 0x1B: 0x35, 0x20: 0x31,
    0x2D: 0x72, 0x2E: 0x75, 0x24: 0x73, 0x23: 0x77, 0x21: 0x74, 0x22: 0x79,
    0x25: 0x7B, 0x26: 0x7E, 0x27: 0x7C, 0x28: 0x7D, 0x14: 0x39,
    // 修饰键（扩展码 = 左右分明的）
    0xA0: 0x38, 0xA1: 0x3C, 0xA2: 0x3B, 0xA3: 0x3E,
    0xA4: 0x3A, 0xA5: 0x3D, 0x5B: 0x37, 0x5C: 0x36,
    // 通用码兜底（VK_SHIFT / VK_CONTROL / VK_MENU）。
    // Windows 低级钩子通常报扩展码（0xA0-0xA5/0x5B/0x5C），但万一报通用码，
    // 没有这几项会被整条丢弃、修饰键静默失效 —— 补上。
    0x10: 0x38, 0x11: 0x3B, 0x12: 0x3A,
    // 功能键
    0x70: 0x7A, 0x71: 0x78, 0x72: 0x63, 0x73: 0x76, 0x74: 0x60, 0x75: 0x61,
    0x76: 0x62, 0x77: 0x64, 0x78: 0x65, 0x79: 0x6D, 0x7A: 0x67, 0x7B: 0x6F,
    0x7C: 0x69, 0x7D: 0x6B, 0x7E: 0x71, 0x7F: 0x6A, 0x80: 0x40, 0x81: 0x4F,
    0x82: 0x50, 0x83: 0x5A,
    // 小键盘
    0x60: 0x52, 0x61: 0x53, 0x62: 0x54, 0x63: 0x55, 0x64: 0x56, 0x65: 0x57,
    0x66: 0x58, 0x67: 0x59, 0x68: 0x5B, 0x69: 0x5C, 0x6A: 0x43, 0x6B: 0x45,
    0x6D: 0x4E, 0x6E: 0x41, 0x6F: 0x4B, 0x90: 0x47, 0x0C: 0x47,
    // 音量
    0xAD: 0x4A, 0xAE: 0x49, 0xAF: 0x48,
]

let modifierKeys: Set<CGKeyCode> = [0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x37, 0x36, 0x39]
let capsLockKey: CGKeyCode = 0x39

// ---------------------------------------------------------------------
//  系统输出音量（Core Audio）
//
//  为什么不用注入音量键：实测注入 keyDown/keyUp 会让 macOS 播放"更改音量"的
//  提示音，但音量本身并不变化 —— 音量键的处理需要 NX_SYSDEFINED 形式的事件。
//  所以这里直接读写输出设备的音量标量：与事件系统无关，而且步进可以精确对齐
//  （Windows 一格 2%，这里就精确 +0.02）。
// ---------------------------------------------------------------------
func defaultOutputDevice() -> AudioDeviceID {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    // mElement 用 0（就是 kAudioObjectPropertyElementMain / 老的 Master）
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0)
    let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &dev)
    if err != noErr { return 0 }
    return dev
}

/// 读当前输出音量（0.0 - 1.0）。主控元素读不到就退回去读左右声道。
func outputVolumeScalar() -> Float32? {
    let dev = defaultOutputDevice()
    if dev == 0 { return nil }
    for element in [UInt32(0), 1, 2] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
        if !AudioObjectHasProperty(dev, &addr) { continue }
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr {
            return vol
        }
    }
    return nil
}

/// 直接设置输出音量（0.0 - 1.0）
func setOutputVolumeScalar(_ level: Float32) -> Bool {
    let dev = defaultOutputDevice()
    if dev == 0 { return false }
    var value = max(0, min(1, level))

    // 主控元素能写就写它
    var master = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: 0)
    if AudioObjectHasProperty(dev, &master) {
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(dev, &master, &settable) == noErr && settable.boolValue {
            if AudioObjectSetPropertyData(dev, &master, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                return true
            }
        }
    }

    // 否则逐个声道写
    var ok = false
    for element in [UInt32(1), 2] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
        if !AudioObjectHasProperty(dev, &addr) { continue }
        var val = value
        if AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                      UInt32(MemoryLayout<Float32>.size), &val) == noErr {
            ok = true
        }
    }
    return ok
}

/// 把音量增减 n 个百分点（n 可以是负数）
func adjustOutputVolume(percent: Int) -> Bool {
    guard let cur = outputVolumeScalar() else { return false }
    return setOutputVolumeScalar(cur + Float32(percent) / 100.0)
}

// ---------------------------------------------------------------------
//  注入状态
// ---------------------------------------------------------------------
var mods: CGEventFlags = []
var injected: Set<CGKeyCode> = []

func setModifier(_ code: CGKeyCode, on: Bool) {
    switch code {
    case 0x38, 0x3C:
        mods = on ? mods.union(.maskShift) : mods.subtracting(.maskShift)
    case 0x3B, 0x3E:
        mods = on ? mods.union(.maskControl) : mods.subtracting(.maskControl)
    case 0x3A, 0x3D:
        mods = on ? mods.union(.maskAlternate) : mods.subtracting(.maskAlternate)
    case 0x37, 0x36:
        mods = on ? mods.union(.maskCommand) : mods.subtracting(.maskCommand)
    default:
        break
    }
}

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    guard let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
    ev.flags = flags
    ev.post(tap: .cghidEventTap)
}

/// 修饰键要用 flagsChanged 事件，这样系统/app 看到的修饰键状态才是对的
func postFlagsChanged(_ code: CGKeyCode, flags: CGEventFlags) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    guard let ev = CGEvent(source: src) else { return }
    ev.type = .flagsChanged
    ev.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
    ev.flags = flags
    ev.post(tap: .cghidEventTap)
}

/// 把当前所有“注入里还按着”的键松开，避免切换后留下卡住的 Cmd/Ctrl
func releaseAllInjected() {
    if injected.isEmpty && mods.isEmpty { return }
    let keys = injected
    injected.removeAll()
    for code in keys {
        if modifierKeys.contains(code) {
            postFlagsChanged(code, flags: [])
        } else {
            postKey(code, down: false, flags: [])
        }
    }
    mods = []
}

func handleKey(vk: UInt16, down: Bool, opts: Options, fd: Int32) {
    guard let code = vkToMac[vk] else {
        if opts.verbose { logLine("未映射的按键 VK=\(vk)") }
        return
    }

    let isModifier = modifierKeys.contains(code)

    // 交还组合键：Control + Option + <releaseKey>，且不带 Cmd/Shift
    if down && !isModifier && vk == opts.releaseKey
        && mods.contains(.maskControl) && mods.contains(.maskAlternate)
        && !mods.contains(.maskCommand) && !mods.contains(.maskShift) {
        logLine("识别到交还组合键 Control+Option+\(vk)，把键盘还给 Windows")
        releaseAllInjected()
        sendLine(fd, ["t": "release", "reason": "hotkey"])
        return
    }

    if isModifier {
        if code == capsLockKey {
            if down {
                mods = mods.contains(.maskAlphaShift)
                    ? mods.subtracting(.maskAlphaShift)
                    : mods.union(.maskAlphaShift)
            }
            postFlagsChanged(code, flags: mods)
        } else if down {
            setModifier(code, on: true)
            postFlagsChanged(code, flags: mods)
        } else {
            // 必须先清本地状态、再用清除后的 flags 发给系统。
            // 原先是反过来的：先拿「还含该修饰键」的 mods 发 flagsChanged，
            // 再只清本地变量、不再补发 —— 系统收到的最后一个 flagsChanged
            // 仍然带着该修饰键，于是它认为这个键一直按着（永久卡住）。
            // 实测：注入 Cmd 按下再抬起后，CGEventSource.flagsState 一直停在
            // maskCommand，导致 Cmd+click 多选失效、Cmd+C/V 行为被污染。
            setModifier(code, on: false)
            postFlagsChanged(code, flags: mods)
        }
        if down { injected.insert(code) } else { injected.remove(code) }
        return
    }

    if down {
        postKey(code, down: true, flags: mods)
        injected.insert(code)
    } else {
        // 不注入“没按过”的抬起：切换瞬间的残留 keyup 会污染目标系统
        guard injected.contains(code) else { return }
        postKey(code, down: false, flags: mods)
        injected.remove(code)
    }
}

// ---------------------------------------------------------------------
//  TCP 服务端
// ---------------------------------------------------------------------
enum ReadResult {
    case line(String)
    case timeout
    case closed
    case error
    case tooLong          // 单行超过上限（防止对端发来一条巨型 JSON 把内存打爆）
}

final class LineReader {
    private let fd: Int32
    private var buf: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
    }

    // 单行上限：文件报文是 n 个文件拼成一行 JSON，对端已把总量压到 16 MiB，
    // 这里留一倍余量。超过就断开，避免被一条巨型报文把内存打爆。
    let maxLineBytes = 32 * 1024 * 1024

    func readLine(timeoutMs: Int32) -> ReadResult {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while true {
            if buf.count > maxLineBytes { return .tooLong }
            if let idx = buf.firstIndex(of: 0x0A) {
                let lineBytes = Array(buf[0..<idx])
                buf.removeFirst(idx + 1)
                var s = String(decoding: lineBytes, as: UTF8.self)
                if s.hasSuffix("\r") { s.removeLast() }
                return .line(s)
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainMs = Int32(max(0.0, deadline.timeIntervalSinceNow * 1000.0))
            let pr = poll(&pfd, 1, remainMs)
            if pr == 0 { return .timeout }
            if pr < 0 {
                if errno == EINTR { continue }
                return .error
            }

            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = recv(fd, &tmp, tmp.count, 0)
            if n == 0 { return .closed }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return .error
            }
            buf.append(contentsOf: tmp[0..<n])
        }
    }
}

@discardableResult
func writeAll(_ fd: Int32, _ s: String) -> Bool {
    let bytes = Array(s.utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Int in
            guard let base = p.baseAddress else { return -1 }
            return Darwin.send(fd, base.advanced(by: off), bytes.count - off, 0)
        }
        if n <= 0 { return false }
        off += n
    }
    return true
}

// 会话线程和菜单线程都会往同一个 fd 写，必须串行，否则两行 JSON 会交错。
let sendLock = NSLock()

@discardableResult
func sendLine(_ fd: Int32, _ obj: [String: Any]) -> Bool {
    // .withoutEscapingSlashes 是必须的：Apple 的 JSONSerialization 默认把 '/' 写成 '\/'
    // （实测：{"b64":"abc\/def=="}），而 base64 字母表里 '/' 极常见。
    // PROTOCOL.md 约定「负载必须是纯 base64」，对端（Windows 侧手写 C# 5 解析）
    // 是按「扫到下一个引号就结束」取值的 —— 被转义过的串会让 Convert.FromBase64String 抛异常。
    // 实测这个 bug 上线 2 秒就复现过，所以从源头保证线上格式严格符合协议。
    let opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: opts),
          let s = String(data: data, encoding: .utf8) else { return false }
    sendLock.lock()
    defer { sendLock.unlock() }
    return writeAll(fd, s + "\n")
}

func parseJSON(_ line: String) -> [String: Any]? {
    guard let d = line.data(using: .utf8) else { return nil }
    guard let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
    return o as? [String: Any]
}

func makeListener(bind: String, port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 {
        logLine("socket() 失败 errno=\(errno)")
        return nil
    }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    if bind.isEmpty || bind == "0.0.0.0" {
        addr.sin_addr.s_addr = INADDR_ANY
    } else {
        addr.sin_addr.s_addr = inet_addr(bind)
    }

    let r = withUnsafePointer(to: &addr) { (p: UnsafePointer<sockaddr_in>) -> Int32 in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { (sp: UnsafePointer<sockaddr>) -> Int32 in
            Darwin.bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if r != 0 {
        logLine("bind \(bind):\(port) 失败 errno=\(errno)")
        close(fd)
        return nil
    }
    if listen(fd, 8) != 0 {
        logLine("listen 失败 errno=\(errno)")
        close(fd)
        return nil
    }
    return fd
}

// ---------------------------------------------------------------------
//  处理一个客户端：握手 + 主循环
// ---------------------------------------------------------------------
// =====================================================================
//  剪贴板通道
//
//  为什么需要它：搜狗的「跨设备复制粘贴」在两台 Mac 之间能原样传文件 URL，
//  但只要对端里有一台 Windows，文件就没法跨平台表示，它会降级成一张图标图片
//  写回本机剪贴板 —— 实测 2 秒内就把你的 public.file-url 换掉，粘贴出来是图片。
//
//  所以这里用 KBBridge 自己的 TCP 通道传剪贴板，不经过任何第三方服务。
//
//  回环抑制：每次应用对端内容后记下 changeCount；轮询发现 changeCount 变了，
//  先比对是不是自己刚写的那次，是就不回传。这样不会出现两端互推的死循环。
//
//  隐私：带 Concealed / Transient 标记的剪贴板（密码管理器、临时内容）一律不同步。
// =====================================================================
let clipMaxBytes = 8 * 1024 * 1024      // 单个文件/图片上限
let clipMaxText  = 100_000              // 文本上限（字符）
var clipSyncEnabled = true
var clipLastChange = -1                 // 上一次看到的 changeCount
var clipAppliedChange = -1              // 最近一次「由对端内容写入」造成的 changeCount
// 内容指纹比 changeCount 可靠：搜狗这类会轮询/触碰剪贴板的程序会让 changeCount
// 无故变化，只看 changeCount 就会把自己刚写的内容当成"本地新内容"回传，形成回环。
var clipAppliedPrint = ""
var clipLastSentPrint = ""
var clipSends = 0
var clipRecvs = 0


func clipIsPrivate(_ pb: NSPasteboard) -> Bool {
    let types = pb.types ?? []
    let blocked: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]
    for t in blocked where types.contains(t) { return true }
    return false
}

// 取剪贴板里的文件 URL 列表。必须用 [NSURL] 接再逐个转 URL ——
// [NSURL] as? [URL] 的桥接并不可靠，实测会静默返回 nil，导致文件复制发不出去。
func clipFileURLs(_ pb: NSPasteboard) -> [URL] {
    guard let objs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] else {
        return []
    }
    return objs.map { $0 as URL }.filter { $0.isFileURL }
}

// 取剪贴板里的图片并统一成 PNG。
// 不能只试 .png：别的程序（比如 Finder、截图工具）可能只放 .tiff，
// 这时 data(forType:.png) 返回 nil，图片就永远发不出去 —— 实测踩到过。
func clipImagePNG(_ pb: NSPasteboard) -> Data? {
    if let d = pb.data(forType: .png) { return d }
    if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
        return rep.representation(using: .png, properties: [:])
    }
    return nil
}

// 内容指纹：判断"剪贴板里是不是我刚写过 / 刚发过的那份内容"
func clipFingerprint(_ pb: NSPasteboard) -> String {
    let urls = clipFileURLs(pb)
    if !urls.isEmpty {
        return "files:" + urls.map { $0.path }.joined(separator: "|")
    }
    if let png = clipImagePNG(pb) {
        var h: UInt64 = 1469598103934665603
        for b in png { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "image:\(png.count):\(h)"
    }
    if let s = pb.string(forType: .string), !s.isEmpty {
        return "text:" + s
    }
    return ""
}

// 把本机剪贴板发给对端
//
// 负载一律 base64：这样 JSON 里只剩下 [A-Za-z0-9+/=]，不会出现引号/换行/反斜杠，
// 两端都能用「扫到下一个引号」的方式安全解析（Windows 侧是手写的 C# 5 解析）。
func sendLocalClipboard(_ pb: NSPasteboard, fd: Int32, opts: Options) {
    let fp = clipFingerprint(pb)
    // 记账放在「确实发出去之后」：原来在开头就记，链路此刻不通的话这份内容
    // 会被标记成已发送，之后再也不会重发 —— 断链期间复制的东西就永久丢了。

    // 「文件」不在本通道的能力范围内（1.4.1 起取消）：文件要落盘、要确认回执，
    // 失败时还会在剪贴板上留下指向不存在文件的悬空路径，比不做更糟。
    // 遇到文件就整条跳过 —— 尤其不能退回去发它的图标，那正是当初搜狗那个坑。
    if !clipFileURLs(pb).isEmpty {
        logLine("剪贴板里是文件，本通道不传文件，跳过")
        return
    }

    // 图片
    if let png = clipImagePNG(pb), png.count <= clipMaxBytes {
        if sendLine(fd, ["t": "clip", "kind": "image", "b64": png.base64EncodedString()]) {
            clipLastSentPrint = fp
            clipSends += 1
            logLine("剪贴板 → Windows：图片 \(png.count) 字节")
        }
        return
    }

    // 纯文本
    if let s = pb.string(forType: .string), !s.isEmpty, s.count <= clipMaxText {
        let b = Data(s.utf8).base64EncodedString()
        if b.count <= clipMaxBytes {
            if sendLine(fd, ["t": "clip", "kind": "text", "b64": b]) {
                clipLastSentPrint = fp
                clipSends += 1
                logLine("剪贴板 → Windows：文字 \(s.count) 字符")
            }
            return
        }
    }
}

// 轮询本机剪贴板，有本地变化就发给对端
func clipPollOnce(fd: Int32, opts: Options) {
    let pb = NSPasteboard.general
    let cc = pb.changeCount
    if cc == clipLastChange { return }

    var fp = clipFingerprint(pb)
    // 拿不到内容说明正好撞上「clearContents 之后、写入之前」的瞬时状态。
    // 这时不能记录 changeCount（否则真正的内容永远不会被发送），也不要干等下一轮
    // （下一轮是 1 秒后，极端情况下会漏掉一次复制）—— 就地短暂重试。
    var tries = 0
    while fp.isEmpty && tries < 4 {
        usleep(40_000)
        fp = clipFingerprint(pb)
        tries += 1
    }
    if fp.isEmpty { return }
    clipLastChange = cc

    if cc == clipAppliedChange || fp == clipAppliedPrint { return }  // 刚应用的对端内容，不回传
    if fp == clipLastSentPrint { return }                            // 同一份内容已经发过
    if clipIsPrivate(pb) {
        if opts.verbose { logLine("剪贴板：带隐私标记，跳过同步") }
        return
    }
    sendLocalClipboard(pb, fd: fd, opts: opts)
}

// 把对端发来的内容写进本机剪贴板
func applyRemoteClipboard(_ m: [String: Any], opts: Options) {
    let kind = (m["kind"] as? String) ?? ""
    let pb = NSPasteboard.general
    var ok = false
    var detail = ""

    switch kind {
    case "text":
        if let b64 = m["b64"] as? String, let d = Data(base64Encoded: b64),
           let s = String(data: d, encoding: .utf8), !s.isEmpty, s.count <= clipMaxText {
            pb.clearContents()
            ok = pb.setString(s, forType: .string)
            detail = "文字 \(s.count) 字符"
        }
    case "image":
        if let b64 = m["b64"] as? String, let d = Data(base64Encoded: b64),
           let img = NSImage(data: d) {
            pb.clearContents()
            ok = pb.writeObjects([img])
            detail = "图片 \(d.count) 字节"
        }
    case "files":
        // 1.4.1 起不再支持文件传输。这里保留一条明确日志，
        // 方便排查「对端还是旧版本」的情况，但不做任何落盘。
        logLine("clip：收到文件报文，但本版本不支持文件传输，已忽略")
        return
    default:
        logLine("clip：未知 kind=\(kind)")
        return
    }

    if ok {
        clipAppliedChange = pb.changeCount
        clipLastChange = pb.changeCount
        clipAppliedPrint = clipFingerprint(pb)
        clipLastSentPrint = clipAppliedPrint
        clipRecvs += 1
        logLine("剪贴板 ← Windows：\(detail)")
    } else {
        logLine("clip：应用失败（kind=\(kind)）")
    }
}

func handleClient(_ fd: Int32, opts: Options) {
    let reader = LineReader(fd: fd)

    // ---- 握手 ----
    var authed = false
    var peerName = "?"
    var peerCaps: [String] = []
    handshake: while true {
        switch reader.readLine(timeoutMs: 5000) {
        case .line(let l):
            guard let m = parseJSON(l), (m["t"] as? String) == "hello" else {
                logLine("握手失败：首行不是 hello")
                sendLine(fd, ["t": "hello_err", "reason": "expected_hello"])
                break handshake
            }
            let token = (m["token"] as? String) ?? ""
            if token != opts.token {
                logLine("握手被拒绝：token 不匹配")
                sendLine(fd, ["t": "hello_err", "reason": "bad_token"])
                break handshake
            }
            peerName = (m["host"] as? String) ?? "?"
            if let cs = m["caps"] as? [String] { peerCaps = cs }
            sendLine(fd, ["t": "hello_ok", "proto": 1, "agent": "mac", "version": "1.4.1",
                          "caps": ["clip"]])
            authed = true
            break handshake
        case .timeout:
            logLine("等待 hello 超时")
            break handshake
        case .closed:
            logLine("连接在握手中断开")
            break handshake
        case .error:
            logLine("握手读取错误 errno=\(errno)")
            break handshake
        case .tooLong:
            logLine("握手读取超长，断开")
            break handshake
        }
    }
    guard authed else { return }

    currentClientFd = fd
    clientConnected = true

    // 连上时先对齐一次基线，避免把连接之前就躺在剪贴板里的旧内容推过去
    // 只在双方都声明了 clip 能力时才同步，避免给老版本客户端发它不认识的报文
    clipSyncEnabled = opts.clipSync && peerCaps.contains("clip")
    clipLastChange = NSPasteboard.general.changeCount
    clipAppliedChange = -1

    let trusted = accessibilityTrusted(prompt: false)
    if trusted {
        logLine("已连接 \(peerName)（辅助功能权限: 已授权）")
    } else {
        logLine("已连接 \(peerName)，但【辅助功能权限未授权】——按键会被系统丢弃！")
        logLine("  去 系统设置 → 隐私与安全性 → 辅助功能 里添加本程序，然后重启本进程")
    }

    // ---- 主循环 ----
    var lastRx = Date()
    var running = true
    while running {
        // 剪贴板同步：readLine 最多阻塞 1 秒，所以这里大约每秒轮询一次
        if clipSyncEnabled { clipPollOnce(fd: fd, opts: opts) }
        switch reader.readLine(timeoutMs: 1000) {
        case .line(let l):
            lastRx = Date()
            guard let m = parseJSON(l), let t = m["t"] as? String else {
                logLine("非法报文: \(l)")
                continue
            }
            switch t {
            case "key":
                guard let rawVk = m["vk"] as? Int, rawVk >= 0, rawVk <= 0xFFFF else {
                    logLine("key 报文缺少合法 vk: \(l)")
                    continue
                }
                handleKey(vk: UInt16(rawVk), down: (m["down"] as? Bool) ?? false, opts: opts, fd: fd)
            case "reset":
                releaseAllInjected()
                if opts.verbose { logLine("reset：已清空注入状态") }
            case "volume":
                // 键盘旋钮的音量：直接改系统输出音量，不走按键注入这条路
                guard let d = m["delta"] as? Int else {
                    logLine("volume 报文缺少 delta: \(l)")
                    continue
                }
                if adjustOutputVolume(percent: d) {
                    if opts.verbose { logLine("音量 " + (d > 0 ? "+" : "") + "\(d)%") }
                } else {
                    logLine("设置音量失败（当前输出设备可能不支持软件调音量）")
                }
            case "state":
                // Windows 端告诉我们键盘现在归谁，菜单里显示用
                if let t = m["target"] as? String { lastClientState = t }
            case "clip":
                applyRemoteClipboard(m, opts: opts)
            case "ping":
                var reply: [String: Any] = ["t": "pong"]
                if let ts = m["ts"] { reply["ts"] = ts }
                sendLine(fd, reply)
            case "bye":
                logLine("客户端 bye")
                running = false
            default:
                logLine("未知报文: \(l)")
            }
        case .timeout:
            let idle = Date().timeIntervalSince(lastRx)
            if idle > opts.stuckReleaseSeconds && (!injected.isEmpty || !mods.isEmpty) {
                logLine("静默 \(Int(idle)) 秒，释放所有按住的键（防止卡住 Cmd/Ctrl）")
                releaseAllInjected()
            }
            if idle > opts.idleCloseSeconds {
                logLine("静默 \(Int(idle)) 秒，关闭连接等待重连")
                running = false
            }
        case .closed:
            logLine("客户端断开")
            running = false
        case .error:
            logLine("读取错误 errno=\(errno)")
            running = false
        case .tooLong:
            logLine("单行报文超过 32 MiB 上限，断开连接")
            running = false
        }
    }

    releaseAllInjected()
    currentClientFd = -1
    clientConnected = false
}

// =====================================================================
//  菜单栏 App（GUI 模式）
//
//  双击 KBBridge.app（= 无参数）进入这个模式；带参数运行则是原来的命令行模式。
//  Agent 服务跑在后台线程，菜单栏只负责显示状态和几个操作 —— 不建任何窗口，
//  这样代码面最小、最不容易出编译问题。
// =====================================================================

var statusItem: NSStatusItem?
var menuStatus: NSMenuItem?
var menuPermission: NSMenuItem?
var menuAutoStart: NSMenuItem?
var guiListenFd: Int32 = -1
var currentClientFd: Int32 = -1
var clientConnected: Bool = false
var lastClientState: String = ""

let APP_LABEL = "com.kbbridge.app"

func kbbridgeDir() -> String {
    return NSHomeDirectory() + "/.kbbridge"
}

func autoStartPlistPath() -> String {
    return NSHomeDirectory() + "/Library/LaunchAgents/" + APP_LABEL + ".plist"
}

func isAutoStartOn() -> Bool {
    return FileManager.default.fileExists(atPath: autoStartPlistPath())
}

@discardableResult
func runTool(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    } catch {
        logLine("执行 " + path + " 失败: " + error.localizedDescription)
        return -1
    }
}

func generateToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let fd = open("/dev/urandom", O_RDONLY)
    if fd >= 0 {
        let n = read(fd, &bytes, bytes.count)
        close(fd)
        if n == bytes.count {
            var s = ""
            for b in bytes { s += String(format: "%02x", b) }
            return s
        }
    }
    return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

func currentToken() -> String {
    if let s = try? String(contentsOfFile: kbbridgeDir() + "/token", encoding: .utf8) {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}

func notifyUser(_ text: String) {
    let a = NSAlert()
    a.messageText = "KBBridge"
    a.informativeText = text
    a.addButton(withTitle: "好")
    a.runModal()
}

func openAccessibilitySettings() {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(u)
    }
}

func setAutoStart(_ on: Bool) {
    let path = autoStartPlistPath()
    let fm = FileManager.default
    if on {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let logs = kbbridgeDir() + "/logs"
        try? fm.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
            "<plist version=\"1.0\">\n<dict>\n" +
            "    <key>Label</key><string>" + APP_LABEL + "</string>\n" +
            "    <key>ProgramArguments</key>\n    <array>\n" +
            "        <string>" + exe + "</string>\n" +
            "        <string>--gui</string>\n" +
            "    </array>\n" +
            "    <key>RunAtLoad</key><true/>\n" +
            "    <key>KeepAlive</key><false/>\n" +
            "    <key>ProcessType</key><string>Interactive</string>\n" +
            "    <key>StandardOutPath</key><string>" + logs + "/app.log</string>\n" +
            "    <key>StandardErrorPath</key><string>" + logs + "/app.err</string>\n" +
            "</dict>\n</plist>\n"
        do {
            try xml.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            notifyUser("写入开机自启配置失败：" + error.localizedDescription)
            return
        }
        let uid = getuid()
        if runTool("/bin/launchctl", ["bootstrap", "gui/\(uid)", path]) != 0 {
            runTool("/bin/launchctl", ["load", "-w", path])
        }
        logLine("已开启开机自启")
    } else {
        let uid = getuid()
        runTool("/bin/launchctl", ["bootout", "gui/\(uid)/" + APP_LABEL])
        try? fm.removeItem(atPath: path)
        logLine("已关闭开机自启")
    }
}

func refreshMenu() {
    let trusted = accessibilityTrusted(prompt: false)
    var s = "服务未启动（检查端口 / Token）"
    if !clientConnected && guiListenFd >= 0 { s = "等待 Windows 连接" }
    if clientConnected {
        if lastClientState == "mac" { s = "键盘 → Mac（正在使用）" }
        else if lastClientState == "windows" { s = "键盘 → Windows" }
        else { s = "已连接 Windows" }
    }
    menuStatus?.title = "状态：" + s
    menuPermission?.title = trusted ? "辅助功能：已授权 ✓" : "辅助功能：未授权 ✗ —— 点这里授权"
    menuAutoStart?.state = isAutoStartOn() ? .on : .off
}

/// 一直 accept 下去（CLI 模式和 GUI 模式共用）
func serveForever(_ opts: Options, listenFd: Int32) {
    while true {
        var caddr = sockaddr()
        var clen = socklen_t(MemoryLayout<sockaddr>.size)
        let cfd = accept(listenFd, &caddr, &clen)
        if cfd < 0 {
            if errno == EINTR { continue }
            logLine("accept 失败 errno=\(errno)")
            continue
        }
        handleClient(cfd, opts: opts)
        close(cfd)
    }
}

final class GuiController: NSObject {
    var opts: Options

    init(opts: Options) {
        self.opts = opts
        super.init()
    }

    @objc func doRelease() {
        if currentClientFd < 0 {
            notifyUser("Windows 端还没连上，暂时没法把键盘接回去。")
            return
        }
        sendLine(currentClientFd, ["t": "release", "reason": "app"])
        logLine("菜单：已请求把键盘接回 Windows")
    }

    @objc func doGrant() {
        if accessibilityTrusted(prompt: true) {
            logLine("辅助功能权限: 已授权")
        } else {
            openAccessibilitySettings()
            notifyUser("请把 KBBridge 勾上／加进「辅助功能」列表（开关要变成蓝色），然后退出并重新打开 KBBridge。")
        }
        refreshMenu()
    }

    @objc func doOpenAccessibilitySettings() {
        openAccessibilitySettings()
    }

    @objc func doCopyToken() {
        let t = currentToken()
        if t.isEmpty {
            notifyUser("还没有 Token，先用「生成新 Token」。")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t, forType: .string)
        notifyUser("Token 已复制到剪贴板（" + String(t.count) + " 个字符）。\n\n把它填到 Windows 侧 kbbridge.ini 的 Token= 后面。")
    }

    @objc func doNewToken() {
        let a = NSAlert()
        a.messageText = "生成新的 Token？"
        a.informativeText = "生成后两边都要更新，否则会连不上：\n· Windows：改 kbbridge.ini 里的 Token= 并重启 KBBridge.exe\n· Mac：本 App 会自动写进 ~/.kbbridge/token（服务需要重启 App 生效）"
        a.addButton(withTitle: "生成")
        a.addButton(withTitle: "取消")
        if a.runModal() != .alertFirstButtonReturn { return }

        let t = generateToken()
        do {
            try FileManager.default.createDirectory(atPath: kbbridgeDir(), withIntermediateDirectories: true)
            try t.write(toFile: opts.tokenFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: opts.tokenFile)
            opts.token = t
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(t, forType: .string)
            notifyUser("新 Token 已生成并复制到剪贴板：\n\n" + t + "\n\n填到 Windows 侧 kbbridge.ini 的 Token= 后面，然后重启 KBBridge.exe；\nMac 这边请退出并重新打开 KBBridge。")
            logLine("已生成新 token（长度 " + String(t.count) + "）")
        } catch {
            notifyUser("写入 token 失败：" + error.localizedDescription)
        }
    }

    @objc func doOpenFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: kbbridgeDir()))
    }

    @objc func doOpenLog() {
        let p = kbbridgeDir() + "/logs/app.log"
        if FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: kbbridgeDir()))
        }
    }

    @objc func doToggleAutoStart() {
        setAutoStart(!isAutoStartOn())
        refreshMenu()
    }

    @objc func doQuit() {
        logLine("菜单：退出")
        NSApplication.shared.terminate(nil)
    }
}

// ---------------------------------------------------------------------
//  点击重写器（--click-rewrite，实验性，默认关闭）
//
//  为什么需要它：键盘接在 Windows，鼠标是 Mac 本地的蓝牙触控板。
//  KBBridge 注入的修饰键只能改「逻辑修饰键状态」—— 实测注入 Cmd 后
//  CGEventSource.flagsState(.combinedSessionState/.hidSystemState) 里确实能看到
//  maskCommand 已置位；但触控板点击是真实 HID 事件，它携带的修饰键来自物理键盘的
//  HID 状态，而这台 Mac 上没有物理键盘。于是点击到达 app 时是「无修饰键」的普通
//  点击，Cmd+click / Shift+click 多选就失效了。
//
//  做法：装一个「活动型」事件 tap 截住鼠标事件。仅当 mods 非空、且事件本身还没带上
//  这些修饰键时，才抑制原事件并按 mods 重投一份。mods 为空时原样放行 —— 也就是说
//  不按修饰键时行为与原来完全一致，风险面很小。
//
//  需要「输入监控」权限；拿不到时 tap 创建失败，只打一行日志，其它功能不受影响。
//  tap 被系统因超时禁用时会在回调里自动重新启用。
// ---------------------------------------------------------------------
let clickRewriteMagic: Int64 = 0x4B424352  // 'KBCR'，给自己的重投事件打标记，防自激
var clickTap: CFMachPort?
var clickRewriteVerbose = false

let clickRewriteCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = clickTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // 自己重投的事件直接放行，避免无限自激
    if event.getIntegerValueField(.eventSourceUserData) == clickRewriteMagic {
        return Unmanaged.passUnretained(event)
    }

    let needed = mods
    if clickRewriteVerbose && (type == .leftMouseDown || type == .rightMouseDown) {
        var names: [String] = []
        if needed.contains(.maskShift) { names.append("Shift") }
        if needed.contains(.maskCommand) { names.append("Cmd") }
        logLine("点击重写：收到 \(type == .leftMouseDown ? "左键" : "右键")按下，mods=[\(names.joined(separator: "+"))]")
    }
    if needed.isEmpty { return Unmanaged.passUnretained(event) }
    if event.flags.contains(needed) { return Unmanaged.passUnretained(event) }

    if let copy = event.copy() {
        copy.flags = event.flags.union(needed)
        copy.setIntegerValueField(.eventSourceUserData, value: clickRewriteMagic)
        copy.post(tap: .cghidEventTap)
        if clickRewriteVerbose { logLine("点击重写：已按 mods 重投该点击") }
    }
    return nil  // 抑制原事件
}

func clickRewriteWanted(_ o: Options) -> Bool {
    if o.clickRewrite { return true }
    if let v = ProcessInfo.processInfo.environment["KBBRIDGE_CLICK_REWRITE"],
       v == "1" || v.lowercased() == "true" {
        return true
    }
    return FileManager.default.fileExists(
        atPath: NSHomeDirectory() + "/.kbbridge/click-rewrite")
}

func startClickRewrite(verbose: Bool) {
    clickRewriteVerbose = verbose
    Thread.detachNewThread {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp,
        ]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1 << t.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: clickRewriteCallback,
            userInfo: nil
        ) else {
            logLine("点击重写：事件 tap 创建失败（缺「输入监控」权限？）—— 已跳过，其它功能不受影响")
            return
        }
        clickTap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logLine("点击重写：已启用 —— Cmd/Shift+点击 会带上修饰键")
        CFRunLoopRun()
    }
}

func runGuiMode(_ options: Options) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)      // 只出现在菜单栏，不占 Dock

    // 防止 launchd 和手动双击撞车
    if let bid = Bundle.main.bundleIdentifier {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bid).count > 1 {
            logLine("已经有一个 KBBridge 在运行了，本次启动退出")
            exit(0)
        }
    }

    var o = options
    if o.token.isEmpty {
        o.token = currentToken()
    }

    let ctl = GuiController(opts: o)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KBBridge") {
        item.button?.image = img
    } else {
        item.button?.title = "⌨"
    }
    item.button?.toolTip = "KBBridge —— 键盘在 Windows / Mac 之间切换"

    let menu = NSMenu()
    let head = NSMenuItem(title: "KBBridge", action: nil, keyEquivalent: "")
    head.isEnabled = false
    menu.addItem(head)

    menuStatus = NSMenuItem(title: "状态：启动中…", action: nil, keyEquivalent: "")
    menuStatus?.isEnabled = false
    menu.addItem(menuStatus!)

    menuPermission = NSMenuItem(title: "辅助功能：检查中…", action: #selector(GuiController.doGrant), keyEquivalent: "")
    menuPermission?.target = ctl
    menu.addItem(menuPermission!)

    menu.addItem(NSMenuItem.separator())

    let miRelease = NSMenuItem(title: "把键盘接回 Windows", action: #selector(GuiController.doRelease), keyEquivalent: "")
    miRelease.target = ctl
    menu.addItem(miRelease)

    let miSettings = NSMenuItem(title: "打开辅助功能设置…", action: #selector(GuiController.doOpenAccessibilitySettings), keyEquivalent: "")
    miSettings.target = ctl
    menu.addItem(miSettings)

    menu.addItem(NSMenuItem.separator())

    let miCopy = NSMenuItem(title: "复制 Token（给 Windows 用）", action: #selector(GuiController.doCopyToken), keyEquivalent: "")
    miCopy.target = ctl
    menu.addItem(miCopy)

    let miNew = NSMenuItem(title: "生成新 Token…", action: #selector(GuiController.doNewToken), keyEquivalent: "")
    miNew.target = ctl
    menu.addItem(miNew)

    let miFolder = NSMenuItem(title: "打开配置文件夹", action: #selector(GuiController.doOpenFolder), keyEquivalent: "")
    miFolder.target = ctl
    menu.addItem(miFolder)

    let miLog = NSMenuItem(title: "打开日志", action: #selector(GuiController.doOpenLog), keyEquivalent: "")
    miLog.target = ctl
    menu.addItem(miLog)

    menu.addItem(NSMenuItem.separator())

    menuAutoStart = NSMenuItem(title: "开机自启", action: #selector(GuiController.doToggleAutoStart), keyEquivalent: "")
    menuAutoStart?.target = ctl
    menu.addItem(menuAutoStart!)

    menu.addItem(NSMenuItem.separator())

    let miQuit = NSMenuItem(title: "退出 KBBridge", action: #selector(GuiController.doQuit), keyEquivalent: "q")
    miQuit.target = ctl
    menu.addItem(miQuit)

    item.menu = menu
    statusItem = item

    if o.token.isEmpty {
        logLine("没有 Token：服务未启动。菜单里「生成新 Token」可以补上。")
    } else if let fd = makeListener(bind: o.bind, port: o.port) {
        guiListenFd = fd
        logLine("监听 \(o.bind):\(o.port)（GUI 模式）")
        Thread.detachNewThread {
            serveForever(o, listenFd: fd)
        }
    } else {
        logLine("监听失败：端口可能被占用")
    }

    if accessibilityTrusted(prompt: false) {
        logLine("辅助功能权限: 已授权")
    } else {
        logLine("辅助功能权限: 未授权 ← 按键注入会被系统丢弃，点菜单栏图标授权")
    }

    if clickRewriteWanted(o) { startClickRewrite(verbose: o.verbose) }

    refreshMenu()

    let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        refreshMenu()
    }
    RunLoop.main.add(timer, forMode: .common)

    app.run()
}

// ---------------------------------------------------------------------
//  入口
// ---------------------------------------------------------------------
// 注意：这里必须是 var —— 下面要根据 token 文件回填 opts.token
var opts = parseArgs()

// 双击 .app 时没有任何参数 —— 那就是 GUI 模式
if CommandLine.arguments.count <= 1 { opts.gui = true }

if opts.gui {
    runGuiMode(opts)
    exit(0)
}

logLine("KBBridge macOS agent 1.4.1")

if clickRewriteWanted(opts) { startClickRewrite(verbose: opts.verbose) }

if opts.checkOnly {
    let t = accessibilityTrusted(prompt: false)
    logLine(t ? "辅助功能权限: 已授权" : "辅助功能权限: 未授权（去 系统设置 → 隐私与安全性 → 辅助功能 添加本程序）")
    exit(t ? 0 : 1)
}

if opts.volumeTest {
    logLine("输出设备 = " + String(defaultOutputDevice()))
    guard let before = outputVolumeScalar() else {
        logLine("读取音量失败：当前输出设备不支持软件调音量（换内置扬声器/耳机再试）")
        exit(4)
    }
    logLine("当前音量 = " + String(format: "%.3f", before))
    let okUp = adjustOutputVolume(percent: 5)
    let mid = outputVolumeScalar()
    let okDown = adjustOutputVolume(percent: -5)
    let after = outputVolumeScalar()
    logLine("+5% -> " + (mid == nil ? "读取失败" : String(format: "%.3f", mid!)) + "   写入成功=" + (okUp ? "是" : "否"))
    logLine("-5% -> " + (after == nil ? "读取失败" : String(format: "%.3f", after!)) + "   写入成功=" + (okDown ? "是" : "否"))
    if let m = mid, m > before + 0.001 {
        logLine("结论：Core Audio 读写可用 ✓（旋钮要用的就是这条通道）")
        exit(0)
    }
    logLine("结论：写入没生效 ✗（把上面几行发给我）")
    exit(5)
}

// token：命令行 > 环境变量 > 文件
if opts.token.isEmpty {
    if let s = try? String(contentsOfFile: opts.tokenFile, encoding: .utf8) {
        opts.token = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
if opts.token.isEmpty {
    logLine("错误：没有 token。用 --token 指定，或把它写进 \(opts.tokenFile)")
    exit(2)
}

// 忽略向已断开 socket 写入导致的 SIGPIPE
signal(SIGPIPE, SIG_IGN)

guard let listenFd = makeListener(bind: opts.bind, port: opts.port) else {
    exit(3)
}
logLine("监听 \(opts.bind):\(opts.port)（token 长度 \(opts.token.count)）")

if accessibilityTrusted(prompt: true) {
    logLine("辅助功能权限: 已授权")
} else {
    logLine("辅助功能权限: 未授权 ← 现在注入会被系统丢弃")
    logLine("  去 系统设置 → 隐私与安全性 → 辅助功能 里添加本程序，然后重启本进程")
}

serveForever(opts, listenFd: listenFd)
