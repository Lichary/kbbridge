// =====================================================================
//  KBBridge 设置窗口
//
//  这个文件编译成单独的 KBBridgeSettings.exe（用 csc 的 /main:KBBridge.SettingsApp）。
//  故意和常驻代理分开进程名：「保存并重启」需要结束 KBBridge.exe，
//  如果设置窗口也叫 KBBridge，就会把自己也杀掉。
//
//  保持 C# 5 语法（系统自带的 csc.exe 不支持字符串插值 / ?. / nameof）
// =====================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace KBBridge
{
    // -----------------------------------------------------------------
    //  简单的 ini 读写：保留原文件的注释和顺序，只更新已知的键
    // -----------------------------------------------------------------
    sealed class IniFile
    {
        public string Path;
        private readonly List<string> _lines = new List<string>();
        private readonly Dictionary<string, string> _values =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly List<string> _order = new List<string>();

        public static IniFile Load(string path)
        {
            IniFile f = new IniFile();
            f.Path = path;
            if (path != null && File.Exists(path))
            {
                foreach (string raw in File.ReadAllLines(path))
                {
                    f._lines.Add(raw);
                    string s = raw.Trim();
                    if (s.Length == 0 || s.StartsWith("#") || s.StartsWith(";")) continue;
                    int eq = s.IndexOf('=');
                    if (eq <= 0) continue;
                    string k = s.Substring(0, eq).Trim();
                    if (!f._values.ContainsKey(k)) f._order.Add(k);
                    f._values[k] = s.Substring(eq + 1).Trim();
                }
            }
            else
            {
                f._lines.Add("# KBBridge 配置（Windows 侧）");
                f._lines.Add("# 改完在设置窗口里点「保存并重启服务」生效");
                f._lines.Add("");
            }
            return f;
        }

        public string Get(string key, string def)
        {
            string v;
            return _values.TryGetValue(key, out v) ? v : def;
        }

        public bool GetBool(string key, bool def)
        {
            string v = Get(key, null);
            if (v == null) return def;
            v = v.Trim().ToLowerInvariant();
            if (v == "1" || v == "true" || v == "yes" || v == "on") return true;
            if (v == "0" || v == "false" || v == "no" || v == "off") return false;
            return def;
        }

        public void Set(string key, string value)
        {
            if (!_values.ContainsKey(key)) _order.Add(key);
            _values[key] = value;
        }

        public void Save()
        {
            HashSet<string> written = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            List<string> outp = new List<string>();
            foreach (string raw in _lines)
            {
                string s = raw.Trim();
                string k = null;
                if (s.Length > 0 && !s.StartsWith("#") && !s.StartsWith(";"))
                {
                    int eq = s.IndexOf('=');
                    if (eq > 0) k = s.Substring(0, eq).Trim();
                }
                if (k != null && _values.ContainsKey(k))
                {
                    outp.Add(k + "=" + _values[k]);
                    written.Add(k);
                }
                else
                {
                    outp.Add(raw);
                }
            }
            foreach (string k in _order)
            {
                if (written.Contains(k)) continue;
                outp.Add(k + "=" + _values[k]);
            }
            string dir = System.IO.Path.GetDirectoryName(Path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllLines(Path, outp.ToArray(), new UTF8Encoding(true));
        }
    }

    // -----------------------------------------------------------------
    //  入口（csc /main:KBBridge.SettingsApp）
    // -----------------------------------------------------------------
    static class SettingsApp
    {
        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                Application.Run(new SettingsForm());
            }
            catch (Exception ex)
            {
                MessageBox.Show("设置窗口启动失败：" + ex.Message, "KBBridge",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            return 0;
        }
    }

    // -----------------------------------------------------------------
    //  设置窗口
    // -----------------------------------------------------------------
    sealed class SettingsForm : Form
    {
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "KBBridge";

        private readonly string _iniPath;
        private readonly IniFile _ini;

        private TextBox txtHost;
        private TextBox txtPort;
        private TextBox txtToken;
        private TextBox txtToMac;
        private TextBox txtRescue;
        private CheckBox chkShow;
        private CheckBox chkBeep;
        private CheckBox chkTray;
        private CheckBox chkSync;
        private CheckBox chkAuto;
        private CheckBox chkVerbose;
        private CheckBox chkVolume;
        private Label lblTest;
        private Label lblStatus;

        public SettingsForm()
        {
            Text = "KBBridge 设置 —— 一把键盘在两台机器间切换";
            ClientSize = new Size(548, 494);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            try { Font = new Font("Microsoft YaHei UI", 9F); }
            catch (Exception) { }

            _iniPath = FindIni();
            _ini = IniFile.Load(_iniPath);

            BuildUi();
            LoadValues();
            RefreshStatus();
        }

        // ---------------- 路径 ----------------
        private static string ExeDir()
        {
            return Path.GetDirectoryName(Application.ExecutablePath);
        }

        private static string AgentExePath()
        {
            return Path.Combine(ExeDir(), "KBBridge.exe");
        }

        // 与常驻代理的查找顺序一致：exe 同目录优先（便携模式），否则 %LOCALAPPDATA%\KBBridge
        private static string FindIni()
        {
            string beside = Path.Combine(ExeDir(), "kbbridge.ini");
            if (File.Exists(beside)) return beside;
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "KBBridge", "kbbridge.ini");
        }

        private static string LogPath()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "KBBridge", "kbbridge.log");
        }

        // ---------------- 界面 ----------------
        private Label MakeLabel(string text, int x, int y, int w, int h)
        {
            Label l = new Label();
            l.Text = text;
            l.Location = new Point(x, y);
            l.Size = new Size(w, h);
            l.AutoSize = false;
            l.TextAlign = ContentAlignment.MiddleLeft;
            return l;
        }

        private TextBox MakeText(int x, int y, int w)
        {
            TextBox t = new TextBox();
            t.Location = new Point(x, y);
            t.Size = new Size(w, 23);
            return t;
        }

        private CheckBox MakeCheck(string text, int x, int y)
        {
            CheckBox c = new CheckBox();
            c.Text = text;
            c.Location = new Point(x, y);
            c.AutoSize = true;
            return c;
        }

        private Button MakeButton(string text, int x, int y, int w, int h, EventHandler onClick)
        {
            Button b = new Button();
            b.Text = text;
            b.Location = new Point(x, y);
            b.Size = new Size(w, h);
            b.Click += onClick;
            return b;
        }

        private static GroupBox MakeGroup(string text, int x, int y, int w, int h)
        {
            GroupBox g = new GroupBox();
            g.Text = text;
            g.Location = new Point(x, y);
            g.Size = new Size(w, h);
            return g;
        }

        private void BuildUi()
        {
            // ---- Mac 连接 ----
            GroupBox gConn = MakeGroup("Mac 连接", 12, 10, 524, 140);
            gConn.Controls.Add(MakeLabel("Mac 地址或主机名", 14, 30, 112, 20));
            txtHost = MakeText(128, 27, 200);
            gConn.Controls.Add(txtHost);
            gConn.Controls.Add(MakeLabel("端口", 340, 30, 34, 20));
            txtPort = MakeText(378, 27, 60);
            gConn.Controls.Add(txtPort);

            gConn.Controls.Add(MakeLabel("共享 Token", 14, 62, 112, 20));
            txtToken = MakeText(128, 59, 260);
            txtToken.UseSystemPasswordChar = true;
            gConn.Controls.Add(txtToken);
            chkShow = MakeCheck("显示", 396, 61);
            chkShow.CheckedChanged += delegate(object s, EventArgs e)
            {
                txtToken.UseSystemPasswordChar = !chkShow.Checked;
            };
            gConn.Controls.Add(chkShow);

            Button btnTest = MakeButton("测试连接", 128, 92, 100, 26, new EventHandler(OnTest));
            gConn.Controls.Add(btnTest);
            lblTest = MakeLabel("（会临时重启一次服务再握手，约 3 秒）", 232, 88, 288, 48);
            lblTest.TextAlign = ContentAlignment.TopLeft;
            lblTest.ForeColor = Color.DimGray;
            gConn.Controls.Add(lblTest);
            Controls.Add(gConn);

            // ---- 快捷键 ----
            // 注意：加到 GroupBox 里的控件，坐标是「相对分组框」的，不再是相对窗体！
            GroupBox gKey = MakeGroup("快捷键", 12, 158, 524, 92);
            gKey.Controls.Add(MakeLabel("切到 Mac", 14, 22, 92, 20));
            txtToMac = MakeText(110, 19, 150);
            gKey.Controls.Add(txtToMac);
            gKey.Controls.Add(MakeLabel("默认 Ctrl+Alt+M（Windows 本地识别）", 270, 22, 250, 20));
            gKey.Controls.Add(MakeLabel("救援回 Windows", 14, 54, 92, 20));
            txtRescue = MakeText(110, 51, 150);
            gKey.Controls.Add(txtRescue);
            gKey.Controls.Add(MakeLabel("默认 Ctrl+Alt+Shift+W（不走网络）", 270, 54, 250, 20));
            Controls.Add(gKey);

            // ---- 选项 ----
            GroupBox gOpt = MakeGroup("选项", 12, 258, 524, 132);
            chkBeep = MakeCheck("切换时蜂鸣提示", 14, 24);
            gOpt.Controls.Add(chkBeep);
            chkTray = MakeCheck("显示托盘图标（右键可手动切换）", 14, 50);
            gOpt.Controls.Add(chkTray);
            chkSync = MakeCheck("切到 Mac 时补发按住的修饰键", 14, 76);
            gOpt.Controls.Add(chkSync);
            chkAuto = MakeCheck("开机自启（写当前用户的 Run 项，不需要管理员）", 14, 102);
            gOpt.Controls.Add(chkAuto);
            chkVerbose = MakeCheck("逐键日志（诊断用，日常请关闭）", 286, 24);
            gOpt.Controls.Add(chkVerbose);
            chkVolume = MakeCheck("音量旋钮跟随切换", 286, 50);
            gOpt.Controls.Add(chkVolume);
            Controls.Add(gOpt);

            // ---- 状态 ----
            lblStatus = MakeLabel("", 12, 396, 524, 48);
            lblStatus.TextAlign = ContentAlignment.TopLeft;
            Controls.Add(lblStatus);

            // ---- 按钮 ----
            Controls.Add(MakeButton("打开日志", 12, 452, 100, 30, new EventHandler(OnOpenLog)));
            Controls.Add(MakeButton("保存并重启服务", 296, 452, 140, 30, new EventHandler(OnSave)));
            Controls.Add(MakeButton("关闭", 448, 452, 88, 30, new EventHandler(OnClose)));
        }

        // ---------------- 数据 ----------------
        private void LoadValues()
        {
            txtHost.Text = _ini.Get("MacHost", "");
            txtPort.Text = _ini.Get("Port", "38471");
            txtToken.Text = _ini.Get("Token", "");
            txtToMac.Text = _ini.Get("SwitchToMacHotkey", "Ctrl+Alt+M");
            txtRescue.Text = _ini.Get("RescueHotkey", "Ctrl+Alt+Shift+W");
            chkBeep.Checked = _ini.GetBool("Beep", true);
            chkTray.Checked = _ini.GetBool("Tray", true);
            chkSync.Checked = _ini.GetBool("SyncHeldKeys", true);
            chkVerbose.Checked = _ini.GetBool("VerboseKeys", false);
            chkVolume.Checked = _ini.GetBool("VolumeFollow", true);
            chkAuto.Checked = AutostartPresent();
        }

        private bool SaveValues(bool complain)
        {
            string host = txtHost.Text.Trim();
            if (host.Length == 0)
            {
                if (complain) MessageBox.Show(this, "请填写 Mac 的地址或主机名。", "KBBridge",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            int port;
            if (!int.TryParse(txtPort.Text.Trim(), out port) || port < 1 || port > 65535)
            {
                if (complain) MessageBox.Show(this, "端口必须是 1-65535 之间的数字。", "KBBridge",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            string token = txtToken.Text.Trim();
            if (token.Length == 0)
            {
                if (complain) MessageBox.Show(this,
                    "Token 不能为空。它必须和 Mac 上 ~/.kbbridge/token 的内容完全一致。",
                    "KBBridge", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }

            _ini.Set("MacHost", host);
            _ini.Set("Port", port.ToString());
            _ini.Set("Token", token);
            _ini.Set("SwitchToMacHotkey", txtToMac.Text.Trim());
            _ini.Set("RescueHotkey", txtRescue.Text.Trim());
            _ini.Set("Beep", chkBeep.Checked ? "true" : "false");
            _ini.Set("Tray", chkTray.Checked ? "true" : "false");
            _ini.Set("SyncHeldKeys", chkSync.Checked ? "true" : "false");
            _ini.Set("VerboseKeys", chkVerbose.Checked ? "true" : "false");
            _ini.Set("VolumeFollow", chkVolume.Checked ? "true" : "false");

            try
            {
                _ini.Save();
            }
            catch (Exception ex)
            {
                if (complain) MessageBox.Show(this, "写入配置失败：" + ex.Message + "\n\n路径：" + _iniPath,
                    "KBBridge", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }

            SetAutostart(chkAuto.Checked);
            return true;
        }

        private void RefreshStatus()
        {
            bool running = AgentRunning();
            lblStatus.Text = "服务状态：" + (running ? "运行中 ✓" : "未运行（双击 KBBridge.exe 启动）")
                + "\r\n配置文件：" + _iniPath
                + "\r\n日志文件：" + LogPath();
        }

        // ---------------- 进程 / 自启 ----------------
        private static bool AgentRunning()
        {
            try { return Process.GetProcessesByName("KBBridge").Length > 0; }
            catch (Exception) { return false; }
        }

        private static void StopAgent()
        {
            foreach (Process p in Process.GetProcessesByName("KBBridge"))
            {
                try { p.Kill(); }
                catch (Exception) { }
            }
            Thread.Sleep(400);
        }

        private static void StartAgent()
        {
            try
            {
                string exe = AgentExePath();
                if (File.Exists(exe)) Process.Start(exe);
            }
            catch (Exception) { }
        }

        private static bool AutostartPresent()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                {
                    if (k != null && k.GetValue(RunValueName) != null) return true;
                }
            }
            catch (Exception) { }
            try
            {
                string lnk = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Startup), "KBBridge.lnk");
                return File.Exists(lnk);
            }
            catch (Exception) { return false; }
        }

        private static void SetAutostart(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKeyPath))
                {
                    if (on) k.SetValue(RunValueName, "\"" + AgentExePath() + "\"");
                    else k.DeleteValue(RunValueName, false);
                }
            }
            catch (Exception) { }

            // 清掉早期版本用的「启动」文件夹快捷方式，避免两处同时自启
            try
            {
                string startup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
                string lnk = Path.Combine(startup, "KBBridge.lnk");
                if (File.Exists(lnk)) File.Delete(lnk);
                string exeCopy = Path.Combine(startup, "KBBridge.exe");
                if (File.Exists(exeCopy)) File.Delete(exeCopy);
            }
            catch (Exception) { }
        }

        // ---------------- 握手测试 ----------------
        private static string Esc(string s)
        {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder(s.Length + 8);
            foreach (char c in s)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c < 0x20) sb.Append(' ');
                else sb.Append(c);
            }
            return sb.ToString();
        }

        private static string TestHandshake(string host, int port, string token)
        {
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    c.NoDelay = true;
                    c.ReceiveTimeout = 4000;
                    c.SendTimeout = 4000;
                    IAsyncResult ar = c.BeginConnect(host, port, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(4000, false))
                        return "连接超时：地址/网段不对，或 Mac 防火墙挡住了，或 Mac 侧代理没在跑。";
                    c.EndConnect(ar);

                    NetworkStream ns = c.GetStream();
                    StreamWriter w = new StreamWriter(ns, new UTF8Encoding(false));
                    w.NewLine = "\n";
                    w.AutoFlush = true;
                    StreamReader r = new StreamReader(ns, new UTF8Encoding(false));

                    w.WriteLine("{\"t\":\"hello\",\"proto\":1,\"token\":\"" + Esc(token) +
                                "\",\"client\":\"settings\",\"host\":\"" + Esc(Environment.MachineName) + "\"}");

                    string line = r.ReadLine();
                    if (line == null) return "连上了，但 Mac 没有回应（Mac 侧可能正忙）。";
                    if (line.IndexOf("\"hello_ok\"", StringComparison.Ordinal) >= 0)
                        return "成功：端口通、Token 正确、Mac 侧已授权 ✓";
                    if (line.IndexOf("\"hello_err\"", StringComparison.Ordinal) >= 0)
                        return "被拒绝：" + line + "（多半是两边 Token 不一致）";
                    return "意外回应：" + line;
                }
            }
            catch (Exception ex)
            {
                return "失败：" + ex.Message;
            }
        }

        // ---------------- 事件 ----------------
        private void OnTest(object sender, EventArgs e)
        {
            if (!SaveValues(true)) return;

            Cursor = Cursors.WaitCursor;
            lblTest.ForeColor = Color.DimGray;
            lblTest.Text = "测试中…";
            Application.DoEvents();

            // Mac 侧一次只服务一个连接：正在运行时先让它让开，测完再拉起来
            bool wasRunning = AgentRunning();
            if (wasRunning) StopAgent();

            int port;
            int.TryParse(txtPort.Text.Trim(), out port);
            string result = TestHandshake(txtHost.Text.Trim(), port, txtToken.Text.Trim());

            if (wasRunning) StartAgent();

            Cursor = Cursors.Default;
            lblTest.Text = result;
            lblTest.ForeColor = (result.Length > 1 && result.Substring(0, 2) == "成功")
                ? Color.ForestGreen : Color.Firebrick;
            RefreshStatus();
        }

        private void OnSave(object sender, EventArgs e)
        {
            if (!SaveValues(true)) return;

            bool wasRunning = AgentRunning();
            if (wasRunning)
            {
                StopAgent();
                StartAgent();
            }
            RefreshStatus();
            MessageBox.Show(this,
                wasRunning
                    ? "已保存，服务已重启。\r\n\r\n托盘图标会重新出现，键盘状态回到「Windows」。"
                    : "已保存。服务当前没有运行。\r\n\r\n双击 KBBridge.exe 可以启动它。",
                "KBBridge", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void OnOpenLog(object sender, EventArgs e)
        {
            try
            {
                string p = LogPath();
                if (!File.Exists(p))
                {
                    MessageBox.Show(this, "还没有日志文件：\r\n" + p, "KBBridge",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Process.Start("notepad.exe", p);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "打开日志失败：" + ex.Message, "KBBridge",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OnClose(object sender, EventArgs e)
        {
            Close();
        }
    }
}
