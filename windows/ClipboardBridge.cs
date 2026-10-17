// =====================================================================
//  KBBridge 剪贴板通道（Windows 侧）
//
//  为什么需要它：搜狗的「跨设备复制粘贴」在两台 Mac 之间能原样传文件 URL，
//  但只要对端里有一台 Windows，文件就无法跨平台表示 —— 实测它会降级成一张
//  1024×1024 的图标图片写回 Mac 的剪贴板，0.45 秒内就把 public.file-url 换掉，
//  于是复制文件、粘贴出来是图片。搜狗没有「只发不收」的方向开关。
//
//  所以这里用 KBBridge 自己的 TCP 通道传剪贴板，不经过任何第三方服务：
//    {"t":"clip","kind":"text","b64":"<base64 utf8>"}
//    {"t":"clip","kind":"image","b64":"<base64 png>"}
//    （1.4.1 起不再传文件：文件要落盘、要回执，失败还会留下悬空路径）
//
//  负载一律 base64：JSON 里只剩 [A-Za-z0-9+/=]，两端都能「扫到下一个引号」安全解析。
//
//  回环抑制：应用对端内容后记下剪贴板序列号 + 内容指纹；轮询发现自己刚写的那份
//  就不再回传，避免两端互推。
//
//  线程：Windows 剪贴板只能在 STA 线程访问，所以整个类跑在一个专用 STA 线程上；
//  收到的报文由 ReadLoop 排队，由这个线程负责真正写剪贴板。
//
//  语法：保持 C# 5（系统自带 csc.exe 不支持字符串插值 / ?. / nameof）。
// =====================================================================

using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace KBBridge
{
    static class ClipboardBridge
    {
        [DllImport("user32.dll")]
        static extern uint GetClipboardSequenceNumber();

        const int MaxBytes = 8 * 1024 * 1024;   // 单个文件/图片上限
        const long MaxTotal = 16L * 1024 * 1024; // 一条 files 报文的总量上限
        const int MaxText  = 100000;            // 文本上限（字符）

        static volatile bool _running = false;
        static Thread _thread = null;
        static readonly Queue<string> _inbox = new Queue<string>();
        static readonly object _lock = new object();

        static uint _lastSeq = 0xFFFFFFFF;
        static string _appliedPrint = "";
        static string _sentPrint = "";

        static Action<string> _send = null;
        static Action<string> _log = null;

        public static bool Enabled = true;

        static void Log(string s) { if (_log != null) { try { _log(s); } catch (Exception) { } } }
        static void Send(string s) { if (_send != null) { try { _send(s); } catch (Exception) { } } }

        public static void Start(Action<string> send, Action<string> log)
        {
            if (!Enabled) { return; }
            if (_running) { return; }
            _send = send;
            _log = log;
            _running = true;
            _thread = new Thread(Loop);
            _thread.IsBackground = true;
            _thread.Name = "clipboard";
            try { _thread.SetApartmentState(ApartmentState.STA); }
            catch (Exception) { }
            _thread.Start();
            Log("剪贴板通道已启用（文字/图片/文件，双向）");
        }

        public static void Stop()
        {
            _running = false;
        }

        // 由 ReadLoop 调用：把对端内容排进队列，交给 STA 线程真正写入剪贴板
        public static void Enqueue(string line)
        {
            lock (_lock) { _inbox.Enqueue(line); }
        }

        static void Loop()
        {
            // 对齐一次基线，避免把连接之前就躺在剪贴板里的旧内容推过去
            try { _lastSeq = GetClipboardSequenceNumber(); } catch (Exception) { }
            while (_running)
            {
                try
                {
                    Drain();
                    Poll();
                }
                catch (Exception ex) { Log("剪贴板异常: " + ex.Message); }
                Thread.Sleep(700);
            }
        }

        static void Drain()
        {
            while (true)
            {
                string line = null;
                lock (_lock)
                {
                    if (_inbox.Count > 0) { line = _inbox.Dequeue(); }
                }
                if (line == null) { return; }
                try { Apply(line); }
                catch (Exception ex)
                {
                    // 打点：光有异常消息定位不了问题（这次就是），把报文长度和头部带上
                    Log("clip 应用异常: " + ex.Message
                        + "（长度 " + (line == null ? 0 : line.Length) + "，头部 " + Head(line, 120) + "）");
                }
            }
        }

        // -------------------------------------------------------------
        //  极简 JSON 取值：因为负载全是 base64（只含 [A-Za-z0-9+/=]），
        //  扫到下一个引号就是结尾，不需要处理转义。
        // -------------------------------------------------------------
        static string Field(string s, string key)
        {
            string pat = "\"" + key + "\":\"";
            int i = s.IndexOf(pat, StringComparison.Ordinal);
            if (i < 0) { return null; }
            i += pat.Length;
            int j = s.IndexOf('"', i);
            if (j < 0) { return null; }
            string v = s.Substring(i, j - i);
            // 关键：Apple 的 JSONSerialization 会把 '/' 转义成 "\/"，而 base64 里
            // '/' 极常见（它是字母表的一员），于是每条报文都会带上这个转义。
            // 协议约定"负载必须是纯 base64 字符集"，所以这里做一次还原；
            // 不还原的话 Convert.FromBase64String 必然抛"包含非 base64 字符"。
            if (v.IndexOf('\\') >= 0) { v = v.Replace("\\/", "/"); }
            return v;
        }

        static string Head(string s, int n)
        {
            if (s == null) { return ""; }
            return s.Length <= n ? s : s.Substring(0, n) + "...";
        }

        // 剪贴板是全局独占资源：任何程序 OpenClipboard 期间别人都写不进去。
        // 搜狗这类"跨设备剪贴板"恰恰靠高频轮询实现，所以写入随时可能抛
        // "OpenClipboard 失败"（实测：并发轮询时自测就会偶发失败）。
        // 写操作统一带几次重试，否则一条报文会被静默丢掉。
        static void Retry(Action act)
        {
            for (int i = 0; ; i++)
            {
                try { act(); return; }
                catch (Exception)
                {
                    if (i >= 4) { throw; }
                    Thread.Sleep(40);
                }
            }
        }

        static int IntField(string s, string key, int def)
        {
            string pat = "\"" + key + "\":";
            int i = s.IndexOf(pat, StringComparison.Ordinal);
            if (i < 0) { return def; }
            i += pat.Length;
            int j = i;
            while (j < s.Length && (char.IsDigit(s[j]) || s[j] == '-')) { j++; }
            if (j == i) { return def; }
            int v;
            if (int.TryParse(s.Substring(i, j - i), out v)) { return v; }
            return def;
        }

        static string B64(string s)
        {
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(s));
        }

        
        
        // 内容指纹：判断"剪贴板里是不是我刚写过/刚发过的那份内容"
        static string Fingerprint()
        {
            try
            {
                if (Clipboard.ContainsFileDropList())
                {
                    StringCollection c = Clipboard.GetFileDropList();
                    StringBuilder sb = new StringBuilder("files:");
                    for (int i = 0; i < c.Count; i++)
                    {
                        sb.Append(c[i]).Append('|');
                    }
                    return sb.ToString();
                }
                if (Clipboard.ContainsImage())
                {
                    byte[] dib = null;
                    try
                    {
                        IDataObject o = Clipboard.GetDataObject();
                        if (o != null)
                        {
                            object raw = o.GetData(DataFormats.Dib);
                            dib = raw as byte[];
                            if (dib == null)
                            {
                                // 有时返回的是 MemoryStream 而不是 byte[]
                                MemoryStream ms = raw as MemoryStream;
                                if (ms != null) { dib = ms.ToArray(); }
                            }
                        }
                    }
                    catch (Exception) { }
                    if (dib == null) { return "image:seq" + GetClipboardSequenceNumber(); }
                    return "image:" + dib.Length + ":" + Fnv(dib);
                }
                if (Clipboard.ContainsText())
                {
                    return "text:" + Clipboard.GetText();
                }
            }
            catch (Exception) { }
            return "";
        }

        static ulong Fnv(byte[] d)
        {
            ulong h = 14695981039346656037UL;
            for (int i = 0; i < d.Length; i++)
            {
                h = (h ^ d[i]) * 1099511628211UL;
            }
            return h;
        }

        // -------------------------------------------------------------
        //  应用对端内容
        // -------------------------------------------------------------
        static void Apply(string line)
        {
            string kind = Field(line, "kind");
            bool ok = false;
            string detail = "";

            if (kind == "text")
            {
                string b = Field(line, "b64");
                if (b != null)
                {
                    string s = Encoding.UTF8.GetString(Convert.FromBase64String(b));
                    if (s.Length > 0)
                    {
                        Retry(delegate { Clipboard.SetText(s); });
                        ok = true;
                        detail = "文字 " + s.Length + " 字符";
                    }
                }
            }
            else if (kind == "image")
            {
                string b = Field(line, "b64");
                if (b != null)
                {
                    byte[] d = Convert.FromBase64String(b);
                    using (MemoryStream ms = new MemoryStream(d))
                    using (Image tmp = Image.FromStream(ms))
                    {
                        // 必须复制一份：Image.FromStream 的图依赖那个流，流关掉剪贴板就坏了
                        using (Bitmap copy = new Bitmap(tmp))
                        {
                        // 用 SetDataObject(copy:true)：数据被真正复制进剪贴板，
                        // 之后 dispose 这个 Bitmap 不会让粘贴出来的图变空白。
                        Retry(delegate { Clipboard.SetDataObject(copy, true); });
                        }
                    }
                    ok = true;
                    detail = "图片 " + d.Length + " 字节";
                }
            }
            else if (kind == "files")
            {
                // 1.4.1 起不再支持文件传输：文件要落盘、要回执，失败时还会在剪贴板上
                // 留下指向不存在文件的悬空路径，比不做更糟。这里保留一条明确日志，
                // 方便排查「对端还是旧版本」的情况，但不做任何落盘、不动剪贴板。
                Log("clip：收到文件报文，但本版本不支持文件传输，已忽略");
                return;
            }
            else
            {
                Log("clip：未知 kind=" + (kind == null ? "(空)" : kind));
                return;
            }

            if (ok)
            {
                _appliedPrint = Fingerprint();
                _sentPrint = _appliedPrint;
                _lastSeq = GetClipboardSequenceNumber();
                Log("剪贴板 <- Mac：" + detail);
            }
            else
            {
                Log("clip：应用失败（kind=" + (kind == null ? "(空)" : kind) + "）");
            }
        }

        // -------------------------------------------------------------
        //  轮询本地剪贴板并发送
        // -------------------------------------------------------------
        static void Poll()
        {
            uint seq = GetClipboardSequenceNumber();
            if (seq == _lastSeq) { return; }

            string fp = Fingerprint();
            // 拿不到内容 = 正好撞上"清空之后、写入之前"的瞬时状态，不能记录 seq，
            // 否则真正的内容永远不会被发送 —— 下一轮再看。
            if (fp.Length == 0) { return; }

            _lastSeq = seq;
            if (fp == _appliedPrint) { return; }   // 刚应用的对端内容，不回传
            if (fp == _sentPrint) { return; }      // 同一份内容已经发过

            SendLocal();
        }

        static void SendLocal()
        {
            try
            {
                if (Clipboard.ContainsFileDropList())
                {
                    // 「文件」不在本通道能力范围内（1.4.1 起取消）。整条跳过 ——
                    // 尤其不能退回去发它的图标，那正是当初搜狗那个坑。
                    Log("剪贴板里是文件，本通道不传文件，跳过");
                    return;
                }

                if (Clipboard.ContainsImage())
                {
                    Image img = Clipboard.GetImage();
                    if (img != null)
                    {
                        using (MemoryStream ms = new MemoryStream())
                        {
                            img.Save(ms, ImageFormat.Png);
                            byte[] png = ms.ToArray();
                            if (png.Length <= MaxBytes)
                            {
                                _sentPrint = Fingerprint();
                                Send("{\"t\":\"clip\",\"kind\":\"image\",\"b64\":\""
                                     + Convert.ToBase64String(png) + "\"}");
                                Log("剪贴板 -> Mac：图片 " + png.Length + " 字节");
                                return;
                            }
                        }
                    }
                }

                if (Clipboard.ContainsText())
                {
                    string s = Clipboard.GetText();
                    if (s.Length > 0 && s.Length <= MaxText)
                    {
                        _sentPrint = Fingerprint();
                        Send("{\"t\":\"clip\",\"kind\":\"text\",\"b64\":\"" + B64(s) + "\"}");
                        Log("剪贴板 -> Mac：文字 " + s.Length + " 字符");
                        return;
                    }
                }
            }
            catch (Exception ex)
            {
                Log("剪贴板读取失败: " + ex.Message);
            }
        }
    }
}
