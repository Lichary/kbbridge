// =====================================================================
//  voltest.cs — 独立的诊断小程序（不属于 KBBridge 本体，build.ps1 不会编译它）
//
//  验证两件事：
//    1) 能不能读到 Windows 默认播放设备的主音量（Core Audio）
//    2) 能不能写回去 —— 这是"音量补偿"方案成立的前提
//
//  编译运行：
//      csc /nologo /target:exe /codepage:65001 /out:voltest.exe voltest.cs
//      voltest.exe
//
//  副作用：会临时把音量 ±2%，最后一定还原成运行前的值。
// =====================================================================

using System;
using System.Runtime.InteropServices;
using System.Threading;

class VolTest
{
    // ---- Core Audio 互操作（只声明需要的方法，但顺序必须和 vtable 一致）----

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
                     [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int access, out IntPtr properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IntPtr notify);
        int UnregisterControlChangeNotify(IntPtr notify);
        int GetChannelCount(out int count);
        int SetMasterVolumeLevel(float level, ref Guid context);
        int SetMasterVolumeLevelScalar(float level, ref Guid context);
        int GetMasterVolumeLevel(out float level);
        int GetMasterVolumeLevelScalar(out float level);
    }

    [DllImport("user32.dll")]
    static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    const int E_RENDER = 0;
    const int CLSCTX_ALL = 23;
    const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    const uint KEYEVENTF_KEYUP = 0x0002;

    static IAudioEndpointVolume Open(int role)
    {
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDevice dev;
        int hr = en.GetDefaultAudioEndpoint(E_RENDER, role, out dev);
        if (hr != 0) throw new Exception("GetDefaultAudioEndpoint(role=" + role + ") hr=0x" + hr.ToString("X8"));
        Guid iid = typeof(IAudioEndpointVolume).GUID;
        object o;
        hr = dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o);
        if (hr != 0) throw new Exception("Activate hr=0x" + hr.ToString("X8"));
        return (IAudioEndpointVolume)o;
    }

    static float Read(IAudioEndpointVolume v)
    {
        float l;
        int hr = v.GetMasterVolumeLevelScalar(out l);
        if (hr != 0) throw new Exception("Get hr=0x" + hr.ToString("X8"));
        return l;
    }

    static void Write(IAudioEndpointVolume v, float l)
    {
        if (l < 0f) l = 0f;
        if (l > 1f) l = 1f;
        Guid ctx = Guid.Empty;
        int hr = v.SetMasterVolumeLevelScalar(l, ref ctx);
        if (hr != 0) throw new Exception("Set hr=0x" + hr.ToString("X8"));
    }

    static string P(float v) { return (v * 100f).ToString("F1") + "%"; }

    static int Main(string[] args)
    {
        IAudioEndpointVolume vol = null;
        float original = 0f;
        try
        {
            vol = Open(1);   // eMultimedia
            original = Read(vol);
            Console.WriteLine("原始主音量 = " + P(original));
        }
        catch (Exception ex)
        {
            Console.WriteLine("打开音频端点失败: " + ex.Message);
            return 2;
        }

        int pass = 0, fail = 0;

        Console.WriteLine();
        Console.WriteLine("=== 测试 1: 能不能写回去（±2%）===");
        try
        {
            float up = Math.Min(1f, original + 0.02f);
            Write(vol, up);
            Thread.Sleep(250);
            float back = Read(vol);
            Console.WriteLine("  写入 " + P(up) + " -> 读回 " + P(back));
            if (Math.Abs(back - up) < 0.001f) { Console.WriteLine("  OK 写入生效"); pass++; }
            else { Console.WriteLine("  FAIL 写入没生效"); fail++; }

            Write(vol, original);
            Thread.Sleep(250);
            float rest = Read(vol);
            Console.WriteLine("  写回 " + P(original) + " -> 读回 " + P(rest));
            if (Math.Abs(rest - original) < 0.001f) { Console.WriteLine("  OK 还原成功"); pass++; }
            else { Console.WriteLine("  FAIL 还原失败"); fail++; }
        }
        catch (Exception ex)
        {
            Console.WriteLine("  FAIL " + ex.Message);
            fail++;
        }

        Console.WriteLine();
        Console.WriteLine("=== 测试 2: 音量键（带扩展键标志）能不能改音量 ===");
        try
        {
            float a = Read(vol);
            keybd_event(0xAF, 0, KEYEVENTF_EXTENDEDKEY, UIntPtr.Zero);
            Thread.Sleep(40);
            keybd_event(0xAF, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, UIntPtr.Zero);
            Thread.Sleep(400);
            float b = Read(vol);
            Console.WriteLine("  按键前 " + P(a) + " -> 按键后 " + P(b) + "   (步进 " + P(b - a) + ")");
            if (b > a + 0.0001f)
            {
                Console.WriteLine("  OK 音量键可用（步进 = " + P(b - a) + "，这个值就是旋钮一格的大小）");
                pass++;
                keybd_event(0xAE, 0, KEYEVENTF_EXTENDEDKEY, UIntPtr.Zero);
                Thread.Sleep(40);
                keybd_event(0xAE, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, UIntPtr.Zero);
                Thread.Sleep(300);
            }
            else
            {
                Console.WriteLine("  （音量键改不动音量 —— 对本方案无影响，我们是用 Core Audio 直接写的）");
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("  异常: " + ex.Message);
        }

        // 兜底还原
        try
        {
            Write(vol, original);
            Thread.Sleep(200);
            Console.WriteLine();
            Console.WriteLine("最终音量 = " + P(Read(vol)) + "（原始 " + P(original) + "）");
        }
        catch (Exception) { }

        Console.WriteLine();
        Console.WriteLine("=== 结论 ===");
        if (fail == 0) Console.WriteLine("  音量补偿方案可行 ✓（能读、能写）");
        else Console.WriteLine("  有 " + fail + " 项失败，方案需要调整");
        return fail == 0 ? 0 : 3;
    }
}
