// =====================================================================
//  音量桥 —— 让键盘旋钮的音量调节「跟着切换走」
//
//  背景：三模键盘的音量旋钮通常走 HID 消费者控制集合，Windows 在键盘钩子
//  「下面」就直接把它处理掉了 —— 所以 WH_KEYBOARD_LL 既看不到也拦不住
//  （实测：270 个按键事件里音量键 0 个）。
//
//  做法（与传输通道无关）：
//      轮询 Windows 默认播放设备的主音量；
//      · 键盘在 Windows 上 -> 只更新基线，什么都不做
//      · 键盘在 Mac 上     -> 一旦发现音量被改了，就把 Windows 的音量写回原值，
//                            同时把音量指令转给 Mac
//
//  代价：转旋钮时 Windows 可能闪一下音量条（数值不变），因为系统已经先弹了 OSD。
//
//  互操作顺序说明：COM 接口只声明需要用到的方法，但**顺序必须和 vtable 一致**。
// =====================================================================

using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace KBBridge
{
    static class VolumeBridge
    {
        // ---------------- Core Audio 互操作 ----------------

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

        const int E_RENDER = 0;
        const int E_MULTIMEDIA = 1;
        const int CLSCTX_ALL = 23;
        const int VK_VOLUME_DOWN = 0xAE;
        const int VK_VOLUME_UP = 0xAF;

        // ---------------- 状态 ----------------

        static IAudioEndpointVolume _vol;
        static float _baseline;
        static bool _haveBaseline;
        static int _consecutiveErrors;

        static IAudioEndpointVolume OpenDefault()
        {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev;
            int hr = en.GetDefaultAudioEndpoint(E_RENDER, E_MULTIMEDIA, out dev);
            if (hr != 0) throw new Exception("GetDefaultAudioEndpoint hr=0x" + hr.ToString("X8"));
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object o;
            hr = dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o);
            if (hr != 0) throw new Exception("Activate hr=0x" + hr.ToString("X8"));
            return (IAudioEndpointVolume)o;
        }

        static float ReadMaster()
        {
            float l;
            int hr = _vol.GetMasterVolumeLevelScalar(out l);
            if (hr != 0) throw new Exception("GetMasterVolumeLevelScalar hr=0x" + hr.ToString("X8"));
            return l;
        }

        static void WriteMaster(float level)
        {
            if (level < 0f) level = 0f;
            if (level > 1f) level = 1f;
            Guid ctx = Guid.Empty;
            int hr = _vol.SetMasterVolumeLevelScalar(level, ref ctx);
            if (hr != 0) throw new Exception("SetMasterVolumeLevelScalar hr=0x" + hr.ToString("X8"));
        }

        // ---------------- 主循环 ----------------

        public static void WatchLoop()
        {
            Program.BridgeLog("音量桥已启动（轮询 Windows 主音量，键盘在 Mac 上时改由 Mac 调音量）");

            while (true)
            {
                Thread.Sleep(80);
                try
                {
                    if (_vol == null)
                    {
                        _vol = OpenDefault();
                        _haveBaseline = false;
                        _consecutiveErrors = 0;
                    }

                    float cur = ReadMaster();

                    if (!_haveBaseline)
                    {
                        _baseline = cur;
                        _haveBaseline = true;
                        continue;
                    }

                    float delta = cur - _baseline;
                    if (Math.Abs(delta) < 0.0005f) continue;   // 没变化

                    bool follow = Program.BridgeTargetIsMac
                                  && Program.BridgeLinkReady
                                  && Program.BridgeVolumeFollow;

                    if (!follow)
                    {
                        _baseline = cur;                        // 键盘在 Windows：只跟基线
                        continue;
                    }

                    // 键盘在 Mac 上：撤销 Windows 这边的改动，并把「变化了多少个百分点」转给 Mac
                    float oldValue = _baseline;
                    int percent = (int)Math.Round(delta * 100f);
                    if (percent == 0) percent = (delta > 0f) ? 1 : -1;

                    WriteMaster(oldValue);
                    _baseline = oldValue;                       // 先钉住基线，免得自己触发自己

                    Program.BridgeSendVolumeDelta(percent);

                    Program.BridgeLog("旋钮 -> Mac：音量 " + (percent > 0 ? "+" : "") + percent + "%"
                        + "（Windows 音量保持在 " + (oldValue * 100f).ToString("F0") + "%）");
                }
                catch (Exception ex)
                {
                    _consecutiveErrors++;
                    if (_consecutiveErrors <= 3)
                    {
                        Program.BridgeLog("音量桥出错（第 " + _consecutiveErrors + " 次）: " + ex.Message);
                    }
                    _vol = null;          // 设备可能被换掉了，下次重开
                    _haveBaseline = false;
                    Thread.Sleep(1000);
                }
            }
        }
    }
}
