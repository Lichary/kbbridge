// =====================================================================
//  KBBridge — Windows 侧代理  (PROTOCOL.md v1)
//
//  作用：在这台 Windows 上装一个全局低级键盘钩子。根据“键盘当前归谁”：
//     target = Windows : 原样放行，什么都不做
//     target = Mac     : 吞掉物理按键，通过 TCP 转给 macOS 侧代理注入
//
//  切换： Ctrl+Alt+M       去 Mac            （Windows 本地识别）
//         Ctrl+Alt+W       回 Windows        （在转发的按键流里，由 Mac 侧识别）
//         Ctrl+Alt+Shift+W 强制救援回 Windows （Windows 本地识别，不走网络）
//
//  编译：build.ps1（使用系统自带 .NET Framework 的 csc.exe，无任何外部依赖）
//  注意：保持 C# 5 语法（内置 csc 不支持字符串插值 / ?. / nameof 等）
// =====================================================================

using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace KBBridge
{
    sealed class Config
    {
        public string MacHost = "127.0.0.1";
        public int Port = 38471;
        public string Token = "";
        public bool Beep = true;
        public bool Tray = true;
        public bool LogToFile = true;
        public bool SyncHeldKeys = true;
        public string ToMacHotkey = "Ctrl+Alt+M";
        public string RescueHotkey = "Ctrl+Alt+Shift+W";
        // 诊断用：把每个按键的去向写进日志（日常用关掉，钩子里做文件 IO 会有一点点开销）
        public bool VerboseKeys = false;
        // 键盘旋钮的音量调节是否跟着切换走（见 VolumeBridge.cs）
        public bool VolumeFollow = true;
    }

    sealed class Hotkey
    {
        public bool Ctrl;
        public bool Alt;
        public bool Shift;
        public bool Win;
        public int Vk;
        public string Text = "";

        public bool Matches(int vk, bool ctrl, bool alt, bool shift, bool win)
        {
            return vk == Vk && ctrl == Ctrl && alt == Alt && shift == Shift && win == Win;
        }
    }

    static class Program
    {
        const string Version = "1.3.0";

        // ---- Win32 常量 ----
        const int WH_KEYBOARD_LL = 13;
        const int WM_KEYDOWN = 0x0100;
        const int WM_KEYUP = 0x0101;
        const int WM_SYSKEYDOWN = 0x0104;
        const int WM_SYSKEYUP = 0x0105;
        const uint LLKHF_EXTENDED = 0x01;
        const uint LLKHF_INJECTED = 0x10;

        const int VK_SHIFT = 0x10;
        const int VK_CONTROL = 0x11;
        const int VK_MENU = 0x12;
        const int VK_LWIN = 0x5B;
        const int VK_RWIN = 0x5C;

        delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        struct KBDLLHOOKSTRUCT
        {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")]
        static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
        static extern IntPtr GetModuleHandle(string lpModuleName);
        [DllImport("user32.dll")]
        static extern short GetAsyncKeyState(int vKey);
        [DllImport("kernel32.dll")]
        static extern bool Beep(uint dwFreq, uint dwDuration);
        [DllImport("user32.dll")]
        static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        // ---- 运行状态 ----
        static Config _cfg = new Config();
        static Hotkey _toMac;
        static Hotkey _rescue;
        static LowLevelKeyboardProc _hookProc;          // 必须保持引用，否则会被 GC 回收导致崩溃
        static IntPtr _hook = IntPtr.Zero;
        static readonly bool[] _held = new bool[256];   // 物理按键当前是否按住
        // 「Windows 视角」：只有真的放行给 Windows 的键，才算它见过按下。
        // 用来决定这个键的「抬起」能不能被吞（吞了它就会永远以为键还按着）。
        static readonly bool[] _winDown = new bool[256];
        static volatile bool _linkReady = false;
        static int _target = 0;                         // 0 = Windows, 1 = Mac
        static volatile StreamWriter _writer = null;
        static TcpClient _client = null;
        static BlockingCollection<string> _out =
            new BlockingCollection<string>(new ConcurrentQueue<string>(), 8192);
        static volatile bool _running = true;
        static long _lastRxTicks = 0;
        static long _releaseCount = 0;
        static bool _allowInjectedTest = false;   // 只有 --selftest-hook 时才为 true
        static int _hookedDown = 0;
        static int _hookedForwarded = 0;
        static volatile bool _hookTestDone = false;
        static int _hookTestResult = 0;
        static Mutex _mutex;
        static NotifyIcon _tray;
        static Icon _icoWin;
        static Icon _icoMac;
        static readonly object _logLock = new object();
        static string _logPath = "";
        static string _configPath = "";

        // =================================================================
        //  入口
        // =================================================================
        [STAThread]
        static int Main(string[] args)
        {
            bool selfTest = HasArg(args, "--selftest");

            if (!selfTest)
            {
                bool createdNew;
                _mutex = new Mutex(true, @"Local\KBBridge_Singleton", out createdNew);
                if (!createdNew)
                {
                    Console.WriteLine("KBBridge 已经在运行了（单实例保护）。");
                    return 1;
                }
            }

            try { LoadConfig(args); }
            catch (Exception ex) { Console.WriteLine("读取配置失败: " + ex.Message); return 2; }

            _logPath = Path.Combine(BaseDir(), "kbbridge.log");
            Log("=== KBBridge " + Version + " 启动 ===");
            Log("配置来源: " + (_configPath == null ? "(无，使用默认值)" : _configPath));
            Log("目标: " + _cfg.MacHost + ":" + _cfg.Port + "  token=" + MaskToken(_cfg.Token));
            if (_cfg.Token.Length == 0) Log("警告: Token 为空，Mac 侧会拒绝握手");

            _toMac = ParseHotkey(_cfg.ToMacHotkey);
            _rescue = ParseHotkey(_cfg.RescueHotkey);
            if (_toMac == null) Log("警告: SwitchToMacHotkey=\"" + _cfg.ToMacHotkey + "\" 无法解析，该热键已禁用");
            if (_rescue == null) Log("警告: RescueHotkey=\"" + _cfg.RescueHotkey + "\" 无法解析，救援键已禁用");

            StartThread(new ThreadStart(LinkThread), "link");
            StartThread(new ThreadStart(SenderLoop), "sender");
            StartThread(new ThreadStart(WatchdogLoop), "watchdog");

            if (HasArg(args, "--selftest-hook")) return RunSelfTestHook();
            if (selfTest) return RunSelfTest();

            // 低级键盘钩子必须装在未来会跑消息循环的那个线程上
            _hookProc = HookCallback;
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _hookProc, GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero)
            {
                Log("安装键盘钩子失败，Win32 错误码 " + Marshal.GetLastWin32Error());
                BeepError();
                return 3;
            }
            Log("键盘钩子已安装（状态: 键盘 → Windows）");
            ClearStuckModifiers("启动自愈");

            if (_cfg.VolumeFollow) StartThread(new ThreadStart(VolumeBridge.WatchLoop), "volume");

            if (_cfg.Tray)
            {
                try { InitTray(); }
                catch (Exception ex) { Log("托盘图标初始化失败（不影响功能）: " + ex.Message); }
            }

            Application.Run(new ApplicationContext());
            Cleanup();
            return 0;
        }

        static void StartThread(ThreadStart body, string name)
        {
            Thread t = new Thread(body);
            t.IsBackground = true;
            t.Name = name;
            t.Start();
        }

        static void Cleanup()
        {
            _running = false;
            try { SendRaw("{\"t\":\"bye\"}"); }
            catch (Exception) { }
            Thread.Sleep(150);
            if (_hook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hook);
                _hook = IntPtr.Zero;
            }
            if (_tray != null)
            {
                try { _tray.Visible = false; _tray.Dispose(); }
                catch (Exception) { }
                _tray = null;
            }
            Log("已退出");
        }

        // =================================================================
        //  键盘钩子
        // =================================================================
        static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode < 0) return CallNextHookEx(_hook, nCode, wParam, lParam);

            KBDLLHOOKSTRUCT k;
            try { k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT)); }
            catch (Exception) { return CallNextHookEx(_hook, nCode, wParam, lParam); }

            // 忽略其他程序/AutoHotkey 之类的“注入”事件，避免自激循环。
            // （--selftest-hook 会临时关掉这个过滤，好让 keybd_event 造的测试按键能被钩子看到）
            if ((k.flags & LLKHF_INJECTED) != 0 && !_allowInjectedTest)
                return CallNextHookEx(_hook, nCode, wParam, lParam);

            int msg = wParam.ToInt32();
            bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
            int vk = (int)k.vkCode;

            // 顺序很重要：先更新自己的按键状态表，再用它判断快捷键。
            // 这样即使系统层面的 async key state 因为按键被吞而失真，也不影响判断。
            if (vk >= 0 && vk < 256) _held[vk] = down;

            bool ctrl = HeldCtrl();
            bool alt = HeldAlt();
            bool shift = HeldShift();
            bool win = HeldWin();

            if (down)
            {
                // 1) 救援键：永远本地处理，绝不转发，不依赖网络
                if (_rescue != null && _rescue.Matches(vk, ctrl, alt, shift, win))
                {
                    Log("救援键触发");
                    ForceWindows("rescue_hotkey");
                    return (IntPtr)1;
                }

                // 2) 交给 Mac
                if (_toMac != null && _toMac.Matches(vk, ctrl, alt, shift, win))
                {
                    if (_linkReady) SwitchToMac();
                    else { Log("切换失败: Mac 链路未就绪"); BeepError(); }
                    return (IntPtr)1;
                }
            }

            if (Volatile.Read(ref _target) == 1)
            {
                if (!_linkReady)
                {
                    // 链路掉了：立刻回退到 Windows，并把这个键放行（fail-open，保证不会把键盘卡死）
                    ForceWindows("link_lost");
                }
                else
                {
                    if (down) Interlocked.Increment(ref _hookedDown);
                    Interlocked.Increment(ref _hookedForwarded);
                    if (_cfg.VerboseKeys) Log("→mac vk=" + vk + " scan=" + k.scanCode + (down ? " down" : " up"));
                    SendKey(vk, k.scanCode, down);

                    // 关键修复：如果这个键的「按下」当初是放行给 Windows 的（典型场景——
                    // 你按着 Ctrl+Alt 再按快捷键切到 Mac，Ctrl/Alt 的按下那一刻目标还是
                    // Windows，所以已经进了 Windows），那它的「抬起」也必须放行给 Windows，
                    // 否则 Windows 会永远以为你还按着 Ctrl：表现就是切回 Windows 之后
                    // 每个键都被识别成 Ctrl+某键。
                    // 抬起同时仍然转发给 Mac，免得 Mac 那边卡住修饰键。
                    if (!down && vk >= 0 && vk < 256 && _winDown[vk])
                    {
                        _winDown[vk] = false;
                        if (_cfg.VerboseKeys) Log("  （抬起同时放行给 Windows，清掉它的按键状态）");
                        return CallNextHookEx(_hook, nCode, wParam, lParam);
                    }

                    return (IntPtr)1;   // 吞掉，Windows 不该看到这个键
                }
            }

            // 记下「Windows 视角」：只有真的放行给它的按键，才算它见过按下/抬起
            if (vk >= 0 && vk < 256) _winDown[vk] = down;
            if (_cfg.VerboseKeys) Log("→win vk=" + vk + (down ? " down" : " up"));

            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        // 物理修饰键状态：完全由钩子自己看到的按键事件维护（_held 表）。
        //
        // 这里绝对不能用 GetAsyncKeyState()：被低级钩子吞掉的按键（回调返回 1）不会
        // 更新系统的 async key state。我们吞掉 Ctrl/Alt 的「抬起」事件后，系统会一直
        // 认为它们还按着，于是之后每次敲 M 都会被误判成 Ctrl+Alt+M 这个切换快捷键而
        // 吞掉 —— 症状就是「其他键都正常，只有 M 键失灵」。
        static bool HeldShift() { return _held[0xA0] || _held[0xA1] || _held[VK_SHIFT]; }
        static bool HeldCtrl() { return _held[0xA2] || _held[0xA3] || _held[VK_CONTROL]; }
        static bool HeldAlt() { return _held[0xA4] || _held[0xA5] || _held[VK_MENU]; }
        static bool HeldWin() { return _held[VK_LWIN] || _held[VK_RWIN]; }

        // =================================================================
        //  状态切换
        // =================================================================
        static void SwitchToMac()
        {
            if (!_linkReady)
            {
                Log("切到 Mac 失败: 链路未就绪");
                BeepError();
                return;
            }

            Interlocked.Exchange(ref _target, 1);
            SendRaw("{\"t\":\"reset\"}");   // 先让 Mac 清空按键/修饰键状态

            // 把当前还按住的键补发给 Mac，这样“按着 Ctrl 切过去”手感是连续的
            if (_cfg.SyncHeldKeys)
            {
                int n = 0;
                for (int vk = 0; vk < 256; vk++)
                {
                    if (!_held[vk]) continue;
                    if (_toMac != null && vk == _toMac.Vk) continue;   // 触发键本身不转发
                    SendKey(vk, 0, true);
                    n++;
                }
                if (n > 0) Log("已补发 " + n + " 个按住的键");
            }

            SendRaw("{\"t\":\"state\",\"target\":\"mac\"}");
            Log("→ Mac（键盘已交给 macOS）");
            BeepToMac();
            UpdateTray();
        }

        static void ForceWindows(string reason)
        {
            int prev = Interlocked.Exchange(ref _target, 0);
            if (prev != 1) return;
            Log("→ Windows（原因: " + reason + "）");
            SendRaw("{\"t\":\"state\",\"target\":\"windows\"}");
            SendRaw("{\"t\":\"reset\"}");   // 让 Mac 也清掉它那边注入的修饰键，免得两边有一边卡住
            BeepToWindows();
            UpdateTray();
        }

        // =================================================================
        //  链路：连接 / 发送 / 接收 / 看门狗
        // =================================================================
        static void LinkThread()
        {
            int backoff = 500;
            while (_running)
            {
                TcpClient c = null;
                try
                {
                    c = new TcpClient();
                    c.NoDelay = true;   // 键盘转发必须关掉 Nagle
                    IAsyncResult ar = c.BeginConnect(_cfg.MacHost, _cfg.Port, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(3000, false)) throw new TimeoutException("连接超时");
                    c.EndConnect(ar);

                    _writer = new StreamWriter(c.GetStream(), new UTF8Encoding(false));
                    _writer.NewLine = "\n";
                    _writer.AutoFlush = true;
                    _client = c;
                    backoff = 500;

                    SendRaw("{\"t\":\"hello\",\"proto\":1,\"token\":\"" + JsonEscape(_cfg.Token) +
                            "\",\"client\":\"windows\",\"host\":\"" + JsonEscape(Environment.MachineName) + "\"}");
                    Log("已连接 " + _cfg.MacHost + ":" + _cfg.Port + "，等待 hello_ok");

                    ReadLoop();
                }
                catch (Exception ex)
                {
                    if (_running) Log("链路错误: " + ex.Message);
                }
                finally
                {
                    bool wasReady = _linkReady;
                    _linkReady = false;
                    _writer = null;
                    _client = null;
                    try { if (c != null) c.Close(); } catch (Exception) { }
                    if (Volatile.Read(ref _target) == 1) ForceWindows("link_closed");
                    if (wasReady) UpdateTray();
                }

                if (!_running) break;
                Thread.Sleep(backoff);
                backoff = Math.Min(backoff * 2, 5000);
            }
        }

        static void SenderLoop()
        {
            foreach (string line in _out.GetConsumingEnumerable())
            {
                StreamWriter w = _writer;
                if (w == null) continue;   // 链路断开，直接丢弃
                try { w.WriteLine(line); }
                catch (Exception ex)
                {
                    Log("发送失败: " + ex.Message);
                    _writer = null;
                    try { if (_client != null) _client.Close(); }
                    catch (Exception) { }
                }
            }
        }

        static void ReadLoop()
        {
            TcpClient c = _client;
            if (c == null) return;
            StreamReader reader = new StreamReader(c.GetStream(), new UTF8Encoding(false));
            string line;
            while (_running && (line = reader.ReadLine()) != null)
            {
                Interlocked.Exchange(ref _lastRxTicks, DateTime.UtcNow.Ticks);
                HandleMessage(line);
            }
            if (_running) Log("对端关闭了连接");
        }

        static void HandleMessage(string line)
        {
            if (line.IndexOf("\"hello_ok\"", StringComparison.Ordinal) >= 0)
            {
                _linkReady = true;
                Log("握手成功: " + line);
                // 顺便把「键盘现在归谁」报给 Mac，让它菜单栏显示正确的状态
                SendRaw("{\"t\":\"state\",\"target\":" + (Volatile.Read(ref _target) == 1 ? "\"mac\"" : "\"windows\"") + "}");
                UpdateTray();
                return;
            }
            if (line.IndexOf("\"hello_err\"", StringComparison.Ordinal) >= 0)
            {
                Log("握手被拒绝: " + line + "  <- 检查两端 Token 是否一致");
                _linkReady = false;
                try { if (_client != null) _client.Close(); }
                catch (Exception) { }
                return;
            }
            if (line.IndexOf("\"release\"", StringComparison.Ordinal) >= 0)
            {
                Interlocked.Increment(ref _releaseCount);
                Log("收到 release 指令: " + line);
                ForceWindows("mac_release");
                return;
            }
            if (line.IndexOf("\"pong\"", StringComparison.Ordinal) >= 0) return;
            Log("未知报文: " + line);
        }

        static void WatchdogLoop()
        {
            int tick = 0;
            while (_running)
            {
                Thread.Sleep(1000);
                if (!_running) break;
                tick++;

                if (_linkReady && (tick % 3) == 0)
                    SendRaw("{\"t\":\"ping\",\"ts\":" + DateTime.UtcNow.Ticks + "}");

                if (Volatile.Read(ref _target) == 1)
                {
                    if (!_linkReady) { ForceWindows("link_down"); continue; }
                    long age = DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastRxTicks);
                    if (_lastRxTicks != 0 && age > TimeSpan.TicksPerSecond * 10)
                        ForceWindows("no_pong_10s");
                }
            }
        }

        static void SendRaw(string line)
        {
            BlockingCollection<string> q = _out;
            if (q == null) return;
            try { q.TryAdd(line); }
            catch (Exception) { }
        }

        static void SendKey(int vk, uint scan, bool down)
        {
            BlockingCollection<string> q = _out;
            if (q == null) return;
            string line = "{\"t\":\"key\",\"vk\":" + vk + ",\"scan\":" + scan +
                          ",\"down\":" + (down ? "true" : "false") + "}";
            bool ok;
            try { ok = q.TryAdd(line); }
            catch (Exception) { ok = false; }
            if (!ok) ForceWindows("queue_overflow");
        }

        // =================================================================
        //  自检模式：不起钩子，直接验证 连接/token/协议/状态机
        // =================================================================
        static int RunSelfTest()
        {
            Log("SELFTEST 开始（不安装键盘钩子）");

            Stopwatch sw = Stopwatch.StartNew();
            while (!_linkReady && sw.ElapsedMilliseconds < 10000) Thread.Sleep(50);
            if (!_linkReady)
            {
                Log("SELFTEST handshake=FAIL");
                Console.WriteLine("SELFTEST handshake=FAIL");
                return 2;
            }
            Log("SELFTEST handshake=OK");

            // 模拟“按着左Ctrl和左Shift切到 Mac”
            _held[0xA2] = true;
            _held[0xA0] = true;
            SwitchToMac();

            // 一个普通按键
            SendKey(0x41, 30, true);
            SendKey(0x41, 30, false);

            sw.Restart();
            while (Interlocked.Read(ref _releaseCount) == 0 && sw.ElapsedMilliseconds < 8000) Thread.Sleep(50);

            bool rel = Interlocked.Read(ref _releaseCount) > 0;
            bool back = Volatile.Read(ref _target) == 0;

            Console.WriteLine("SELFTEST handshake=OK release_received=" + (rel ? "YES" : "NO") +
                              " target_back_to_windows=" + (back ? "YES" : "NO"));
            Log("SELFTEST release_received=" + (rel ? "YES" : "NO") + " target=" + Volatile.Read(ref _target));

            SendRaw("{\"t\":\"bye\"}");
            Thread.Sleep(250);
            return rel ? 0 : 4;
        }

        // =================================================================
        //  钩子自检：真的装一次 WH_KEYBOARD_LL，用 keybd_event 造几个无害的
        //  F24，验证「钩子回调 → 目标判断 → 转发给 Mac」整条链路是通的。
        //  只吞掉自己造的 F24，并且 0.5 秒内就把键盘还给 Windows。
        // =================================================================
        static int RunSelfTestHook()
        {
            _allowInjectedTest = true;   // 放行注入事件，否则看不到自己造的测试按键

            _hookProc = HookCallback;
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _hookProc, GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero)
            {
                Console.WriteLine("SELFTEST-HOOK install=FAIL win32err=" + Marshal.GetLastWin32Error());
                return 5;
            }
            Console.WriteLine("SELFTEST-HOOK install=OK");

            StartThread(new ThreadStart(delegate
            {
                Stopwatch sw = Stopwatch.StartNew();
                while (!_linkReady && sw.ElapsedMilliseconds < 10000) Thread.Sleep(50);
                if (!_linkReady)
                {
                    Console.WriteLine("SELFTEST-HOOK handshake=FAIL");
                    _hookTestResult = 6;
                    _hookTestDone = true;
                    return;
                }

                SwitchToMac();
                for (int i = 0; i < 3; i++)
                {
                    keybd_event(0x87, 0, 0x00, UIntPtr.Zero);   // F24 按下
                    Thread.Sleep(25);
                    keybd_event(0x87, 0, 0x02, UIntPtr.Zero);   // F24 抬起（KEYEVENTF_KEYUP）
                    Thread.Sleep(25);
                }
                Thread.Sleep(400);
                ForceWindows("selftest_hook_done");            // 尽快把键盘还给 Windows
                _hookTestDone = true;
            }), "selftest-hook");

            // WinForms Timer 的 Tick 跑在消息循环那个线程上，用它安全地退出消息循环
            System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
            timer.Interval = 150;
            timer.Tick += delegate(object s, EventArgs e)
            {
                if (_hookTestDone)
                {
                    timer.Stop();
                    Application.ExitThread();
                }
            };
            timer.Start();

            Application.Run(new ApplicationContext());

            int seen = _hookedDown;
            int fwd = _hookedForwarded;
            Console.WriteLine("SELFTEST-HOOK downs_seen=" + seen + " forwarded=" + fwd +
                              " target=" + Volatile.Read(ref _target));
            SendRaw("{\"t\":\"bye\"}");
            Thread.Sleep(250);
            if (_hookTestResult != 0) return _hookTestResult;
            return (seen >= 3 && fwd >= 3) ? 0 : 7;
        }

        // =================================================================
        //  托盘图标
        // =================================================================
        static void InitTray()
        {
            _icoWin = MakeDotIcon(Color.FromArgb(70, 140, 255));
            _icoMac = MakeDotIcon(Color.FromArgb(255, 150, 40));

            _tray = new NotifyIcon();
            _tray.Icon = _icoWin;
            _tray.Text = "KBBridge";
            _tray.Visible = true;

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("切换到 Mac（" + HotkeyText(_toMac) + "）", null, new EventHandler(OnTrayToMac));
            menu.Items.Add("切回 Windows（" + HotkeyText(_rescue) + "）", null, new EventHandler(OnTrayToWindows));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("清除卡住的修饰键", null, new EventHandler(OnTrayClearMods));
            menu.Items.Add("设置…", null, new EventHandler(OnTraySettings));
            menu.Items.Add("打开日志", null, new EventHandler(OnTrayOpenLog));
            menu.Items.Add("退出", null, new EventHandler(OnTrayQuit));
            _tray.ContextMenuStrip = menu;

            UpdateTray();
        }

        static void OnTrayToMac(object sender, EventArgs e)
        {
            if (_linkReady) SwitchToMac();
            else { Log("托盘: 链路未就绪，无法切到 Mac"); BeepError(); }
        }

        static void OnTrayToWindows(object sender, EventArgs e)
        {
            bool already = Volatile.Read(ref _target) == 0;
            ForceWindows("tray");
            if (already) Log("托盘: 当前已经在 Windows");
        }

        static void OnTrayClearMods(object sender, EventArgs e)
        {
            ClearStuckModifiers("托盘手动");
            MessageBox.Show(
                "已向 Windows 发送一遍修饰键的「抬起」事件。\r\n\r\n" +
                "如果刚才的表现是「每个键都变成 Ctrl+某键」，现在应该恢复正常了。\r\n" +
                "（按一下 Ctrl 再松开也有同样效果。）",
                "KBBridge", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        static void OnTraySettings(object sender, EventArgs e)
        {
            try
            {
                string p = Path.Combine(ExeDir(), "KBBridgeSettings.exe");
                if (!File.Exists(p))
                {
                    Log("找不到设置程序: " + p);
                    MessageBox.Show("找不到 KBBridgeSettings.exe。\r\n请重新运行 build.ps1，或使用便携包里的完整文件。",
                        "KBBridge", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                Process.Start(p);
            }
            catch (Exception ex) { Log("打开设置失败: " + ex.Message); }
        }

        static void OnTrayOpenLog(object sender, EventArgs e)
        {
            try { Process.Start("notepad.exe", _logPath); }
            catch (Exception ex) { Log("打开日志失败: " + ex.Message); }
        }

        static void OnTrayQuit(object sender, EventArgs e)
        {
            Log("托盘: 用户请求退出");
            Application.ExitThread();
        }

        static void UpdateTray()
        {
            NotifyIcon t = _tray;
            if (t == null) return;
            try
            {
                bool toMac = Volatile.Read(ref _target) == 1;
                t.Icon = toMac ? _icoMac : _icoWin;
                string s = toMac ? "KBBridge: 键盘 → Mac" : "KBBridge: 键盘 → Windows";
                if (!_linkReady) s = s + "（Mac 未连接）";
                if (s.Length > 62) s = s.Substring(0, 62);
                t.Text = s;
            }
            catch (Exception) { }
        }

        static Icon MakeDotIcon(Color c)
        {
            using (Bitmap bmp = new Bitmap(16, 16))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, 1, 1, 13, 13);
                    using (Pen p = new Pen(Color.FromArgb(90, 0, 0, 0))) g.DrawEllipse(p, 1, 1, 13, 13);
                }
                return Icon.FromHandle(bmp.GetHicon());   // HICON 是独立副本，bmp 可以释放
            }
        }

        static string HotkeyText(Hotkey hk)
        {
            return hk == null ? "(未设置)" : hk.Text;
        }

        // =================================================================
        //  给 VolumeBridge 用的小接口（音量补偿）
        // =================================================================
        internal static bool BridgeTargetIsMac
        {
            get { return Volatile.Read(ref _target) == 1; }
        }

        internal static bool BridgeLinkReady
        {
            get { return _linkReady; }
        }

        internal static bool BridgeVolumeFollow
        {
            get { return _cfg.VolumeFollow; }
        }

        /// 把音量的变化量（百分点，可负）发给 Mac，由 Mac 侧用 Core Audio 直接改系统音量。
        /// 不转发音量键：实测注入音量键只会让 macOS 播放"更改音量"提示音，音量并不变化。
        internal static void BridgeSendVolumeDelta(int percent)
        {
            if (percent > 30) percent = 30;
            if (percent < -30) percent = -30;
            SendRaw("{\"t\":\"volume\",\"delta\":" + percent + "}");
        }

        internal static void BridgeLog(string msg)
        {
            Log(msg);
        }

        // =================================================================
        //  清掉 Windows 里可能残留的「按住的修饰键」
        //
        //  为什么需要它：被低级钩子吞掉的按键不会更新 Windows 的按键状态表，所以如果
        //  我们在切换过程中吞掉了 Ctrl/Alt 的「抬起」，Windows 会永远认为它们还按着。
        //  更麻烦的是——这个状态属于 Windows 自己，**进程退出、被强杀都不会清掉**，
        //  只能靠再收到一次真实的「抬起」事件。表现就是每个键都变成 Ctrl+某键。
        //
        //  所以启动时先自愈一次，托盘里也留一个手动开关。
        //  这些是「注入事件」，钩子会忽略它们，不会造成自激。
        // =================================================================
        static void ClearStuckModifiers(string why)
        {
            int[] vks = new int[] { 0xA2, 0xA3, 0xA4, 0xA5, 0x11, 0x12, 0x10, 0x5B, 0x5C };
            foreach (int vk in vks)
            {
                try { keybd_event((byte)vk, 0, 0x0002, UIntPtr.Zero); }
                catch (Exception) { }
            }
            Log("已清一遍修饰键（" + why + "）");
        }

        // =================================================================
        //  提示音（Beep 会阻塞，所以放到线程池）
        // =================================================================
        static void BeepToMac()
        {
            if (!_cfg.Beep) return;
            ThreadPool.QueueUserWorkItem(delegate(object o)
            {
                try { Beep(900, 55); Thread.Sleep(40); Beep(1300, 70); }
                catch (Exception) { }
            });
        }

        static void BeepToWindows()
        {
            if (!_cfg.Beep) return;
            ThreadPool.QueueUserWorkItem(delegate(object o)
            {
                try { Beep(700, 70); Thread.Sleep(40); Beep(500, 90); }
                catch (Exception) { }
            });
        }

        static void BeepError()
        {
            if (!_cfg.Beep) return;
            ThreadPool.QueueUserWorkItem(delegate(object o)
            {
                try { Beep(280, 220); }
                catch (Exception) { }
            });
        }

        // =================================================================
        //  配置
        // =================================================================
        static void LoadConfig(string[] args)
        {
            string explicitPath = ArgValue(args, "--config");
            string exeIni = Path.Combine(ExeDir(), "kbbridge.ini");
            string appIni = Path.Combine(BaseDir(), "kbbridge.ini");

            string used = null;
            if (!string.IsNullOrEmpty(explicitPath) && File.Exists(explicitPath)) used = explicitPath;
            else if (File.Exists(exeIni)) used = exeIni;
            else if (File.Exists(appIni)) used = appIni;

            if (used != null)
            {
                foreach (string raw in File.ReadAllLines(used))
                {
                    string s = raw.Trim();
                    if (s.Length == 0 || s.StartsWith("#") || s.StartsWith(";")) continue;
                    int eq = s.IndexOf('=');
                    if (eq <= 0) continue;
                    ApplySetting(s.Substring(0, eq).Trim(), s.Substring(eq + 1).Trim());
                }
            }
            _configPath = used;

            // 命令行覆盖配置
            string v = ArgValue(args, "--host");
            if (v != null) _cfg.MacHost = v;
            v = ArgValue(args, "--token");
            if (v != null) _cfg.Token = v;
            v = ArgValue(args, "--port");
            if (v != null)
            {
                int p;
                if (int.TryParse(v, out p) && p > 0 && p < 65536) _cfg.Port = p;
            }
            if (HasArg(args, "--no-tray")) _cfg.Tray = false;
            if (HasArg(args, "--no-beep")) _cfg.Beep = false;
        }

        static void ApplySetting(string key, string val)
        {
            switch (key.ToLowerInvariant())
            {
                case "machost": _cfg.MacHost = val; break;
                case "port":
                    {
                        int p;
                        if (int.TryParse(val, out p) && p > 0 && p < 65536) _cfg.Port = p;
                        break;
                    }
                case "token": _cfg.Token = val; break;
                case "beep": _cfg.Beep = ToBool(val, true); break;
                case "tray": _cfg.Tray = ToBool(val, true); break;
                case "log": _cfg.LogToFile = ToBool(val, true); break;
                case "syncheldkeys": _cfg.SyncHeldKeys = ToBool(val, true); break;
                case "switchtomachotkey": _cfg.ToMacHotkey = val; break;
                case "rescuehotkey": _cfg.RescueHotkey = val; break;
                case "verbosekeys": _cfg.VerboseKeys = ToBool(val, false); break;
                case "volumefollow": _cfg.VolumeFollow = ToBool(val, true); break;
            }
        }

        static bool ToBool(string s, bool def)
        {
            string v = s.Trim().ToLowerInvariant();
            if (v == "1" || v == "true" || v == "yes" || v == "on") return true;
            if (v == "0" || v == "false" || v == "no" || v == "off") return false;
            return def;
        }

        static Hotkey ParseHotkey(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            Hotkey hk = new Hotkey();
            hk.Text = s;
            string[] parts = s.Split('+');
            foreach (string raw in parts)
            {
                string t = raw.Trim();
                if (t.Length == 0) continue;
                string u = t.ToUpperInvariant();
                if (u == "CTRL" || u == "CONTROL") { hk.Ctrl = true; continue; }
                if (u == "ALT") { hk.Alt = true; continue; }
                if (u == "SHIFT") { hk.Shift = true; continue; }
                if (u == "WIN" || u == "WINDOWS" || u == "CMD" || u == "META") { hk.Win = true; continue; }
                hk.Vk = KeyTokenToVk(u);
            }
            if (hk.Vk == 0) return null;
            return hk;
        }

        static int KeyTokenToVk(string u)
        {
            if (u.Length == 1)
            {
                char c = u[0];
                if (c >= 'A' && c <= 'Z') return c;
                if (c >= '0' && c <= '9') return c;
                if (c == '`' || c == '~') return 0xC0;
                if (c == '-') return 0xBD;
                if (c == '=') return 0xBB;
                if (c == '[') return 0xDB;
                if (c == ']') return 0xDD;
                if (c == '\\') return 0xDC;
                if (c == ';') return 0xBA;
                if (c == '\'') return 0xDE;
                if (c == ',') return 0xBC;
                if (c == '.') return 0xBE;
                if (c == '/') return 0xBF;
            }
            if (u.Length >= 2 && u[0] == 'F')
            {
                int n;
                if (int.TryParse(u.Substring(1), out n) && n >= 1 && n <= 24) return 0x70 + n - 1;
            }
            switch (u)
            {
                case "ESC": case "ESCAPE": return 0x1B;
                case "TAB": return 0x09;
                case "SPACE": case "SPACEBAR": return 0x20;
                case "ENTER": case "RETURN": return 0x0D;
                case "BACKSPACE": return 0x08;
                case "INSERT": case "INS": return 0x2D;
                case "DELETE": case "DEL": return 0x2E;
                case "HOME": return 0x24;
                case "END": return 0x23;
                case "PAGEUP": case "PGUP": return 0x21;
                case "PAGEDOWN": case "PGDN": return 0x22;
                case "LEFT": return 0x25;
                case "UP": return 0x26;
                case "RIGHT": return 0x27;
                case "DOWN": return 0x28;
            }
            return 0;
        }

        // =================================================================
        //  小工具
        // =================================================================
        static string BaseDir()
        {
            string d = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KBBridge");
            try { Directory.CreateDirectory(d); }
            catch (Exception) { }
            return d;
        }

        static string ExeDir()
        {
            try { return Path.GetDirectoryName(Application.ExecutablePath); }
            catch (Exception) { return AppDomain.CurrentDomain.BaseDirectory; }
        }

        static void Log(string msg)
        {
            string line = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + msg;
            try { Console.WriteLine(line); }
            catch (Exception) { }
            if (!_cfg.LogToFile || _logPath == null || _logPath.Length == 0) return;
            lock (_logLock)
            {
                try
                {
                    FileInfo fi = new FileInfo(_logPath);
                    if (fi.Exists && fi.Length > 1024 * 1024) File.Delete(_logPath);
                    File.AppendAllText(_logPath, line + Environment.NewLine, Encoding.UTF8);
                }
                catch (Exception) { }
            }
        }

        static string MaskToken(string t)
        {
            if (string.IsNullOrEmpty(t)) return "(空)";
            if (t.Length <= 6) return "******";
            return t.Substring(0, 4) + "..." + t.Substring(t.Length - 2);
        }

        static string JsonEscape(string s)
        {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder(s.Length + 8);
            foreach (char c in s)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c == '\n') sb.Append("\\n");
                else if (c == '\r') sb.Append("\\r");
                else if (c == '\t') sb.Append("\\t");
                else if (c < 0x20) sb.Append(' ');
                else sb.Append(c);
            }
            return sb.ToString();
        }

        static bool HasArg(string[] args, string name)
        {
            if (args == null) return false;
            foreach (string a in args)
                if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        static string ArgValue(string[] args, string name)
        {
            if (args == null) return null;
            for (int i = 0; i < args.Length; i++)
            {
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
                    return (i + 1 < args.Length) ? args[i + 1] : null;
                string prefix = name + "=";
                if (args[i].StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    return args[i].Substring(prefix.Length);
            }
            return null;
        }
    }
}
