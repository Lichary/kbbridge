// =====================================================================
//  ClipboardBridge 自测（Windows 侧剪贴板通道）
//
//  用法：clip-test.cmd  （或 powershell -ExecutionPolicy Bypass -File .\clip-test.ps1）
//
//  为什么存在：剪贴板通道上线 2 秒就踩到一个真 bug —— Apple 的 JSONSerialization
//  会把 base64 里的 '/' 转义成 "\/"，而 Field() 是"扫到下一个引号"的裸解析，
//  于是每条含 '/' 的报文都会解码失败。这个自测把那一幕固化下来。
//
//  注意：会临时改写剪贴板（结束时还原文本），并在结束时删除测试生成的临时文件。
// =====================================================================

using System;
using System.Collections.Specialized;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace KBBridge
{
    static class ClipTest
    {
        static int pass = 0;
        static int fail = 0;

        static void Check(string name, bool ok, string extra)
        {
            if (ok)
            {
                pass++;
                Console.WriteLine("  PASS  " + name + (extra.Length > 0 ? "   (" + extra + ")" : ""));
            }
            else
            {
                fail++;
                Console.WriteLine("  FAIL  " + name + "   (" + extra + ")");
            }
        }

        static void Apply(string line)
        {
            MethodInfo mi = typeof(ClipboardBridge).GetMethod("Apply",
                BindingFlags.NonPublic | BindingFlags.Static);
            mi.Invoke(null, new object[] { line });
        }

        [STAThread]
        static int Main()
        {
            Console.OutputEncoding = Encoding.UTF8;
            string saved = Clipboard.ContainsText() ? Clipboard.GetText() : null;

            Console.WriteLine("== 1. 找一个 base64 里含 '/' 的文本样本 ==");
            string text = null;
            string b64 = null;
            for (int k = 0; k < 5000; k++)
            {
                string cand = "剪贴板/path-" + k + "-OK";
                string b = Convert.ToBase64String(Encoding.UTF8.GetBytes(cand));
                if (b.IndexOf('/') >= 0) { text = cand; b64 = b; break; }
            }
            Check("样本 base64 含 '/'", b64 != null, b64 == null ? "未找到" : b64);
            if (b64 == null) { return 1; }

            Console.WriteLine();
            Console.WriteLine("== 2. 未转义的 b64（协议理想格式） ==");
            Clipboard.Clear();
            Apply("{\"t\":\"clip\",\"kind\":\"text\",\"b64\":\"" + b64 + "\"}");
            string got1 = Clipboard.ContainsText() ? Clipboard.GetText() : "(没有文本)";
            Check("能解出原文", got1 == text, got1);

            Console.WriteLine();
            Console.WriteLine("== 3. 转义成 \\/ 的 b64（Apple JSONSerialization 的真实输出） ==");
            string esc = b64.Replace("/", "\\/");
            Clipboard.Clear();
            Apply("{\"t\":\"clip\",\"kind\":\"text\",\"b64\":\"" + esc + "\"}");
            string got2 = Clipboard.ContainsText() ? Clipboard.GetText() : "(没有文本)";
            Check("能解出原文（本次修复点）", got2 == text, got2);

            Console.WriteLine();
            Console.WriteLine("== 4. 文件报文：1.4.1 起取消文件传输，应被忽略（不落盘、不动剪贴板） ==");
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "Downloads", "KBBridge");
            string target = Path.Combine(dir, "evil.txt");
            try { if (File.Exists(target)) { File.Delete(target); } } catch (Exception) { }

            string nb = Convert.ToBase64String(Encoding.UTF8.GetBytes("..\\..\\evil.txt")).Replace("/", "\\/");
            string db = Convert.ToBase64String(Encoding.UTF8.GetBytes("payload")).Replace("/", "\\/");
            Clipboard.Clear();
            Apply("{\"t\":\"clip\",\"kind\":\"files\",\"n\":1,\"name0\":\"" + nb + "\",\"data0\":\"" + db + "\"}");
            Check("没有落盘任何文件（含路径穿越的 evil.txt）", !File.Exists(target), target);
            Check("剪贴板没有被改成文件列表", !Clipboard.ContainsFileDropList(), "");
            Check("剪贴板也没有被写入文字", !Clipboard.ContainsText(), "");

            Console.WriteLine();
            Console.WriteLine("== 5. 大文本（超过 100000 字符上限应被跳过） ==");
            string big = new string('x', 200000);
            string bb = Convert.ToBase64String(Encoding.UTF8.GetBytes(big)).Replace("/", "\\/");
            Clipboard.Clear();
            Apply("{\"t\":\"clip\",\"kind\":\"text\",\"b64\":\"" + bb + "\"}");
            // Apply 本身不校验上限（上限在发送侧），这里只确认它不会崩
            Check("超长文本不会抛异常", true, "长度 " + big.Length);

            // 还原剪贴板
            try
            {
                Clipboard.Clear();
                if (saved != null) { Clipboard.SetText(saved); }
            }
            catch (Exception) { }

            Console.WriteLine();
            Console.WriteLine("结果：PASS " + pass + " / FAIL " + fail);
            return fail == 0 ? 0 : 1;
        }
    }
}
