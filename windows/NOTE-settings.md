<#
    设置窗口改动的说明（给 KBBridge.cs / build.ps1 用）：

    这个文件里有两个入口类：
      KBBridge.Program        —— 常驻代理（KBBridge.exe，带托盘图标）
      KBBridge.SettingsApp    —— 设置窗口（KBBridgeSettings.exe）

    两个 exe 用同一套源码、靠 csc 的 /main: 开关选入口，好处是进程名分开：
    「保存并重启」需要 taskkill KBBridge.exe，如果设置窗口也叫 KBBridge 就会把自己杀掉。
#>
