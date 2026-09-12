#Requires AutoHotkey v2.0
#SingleInstance Off
; PopDrop 前台文件识别探针（AutoHotkey v2）。
;
; 用途：不启动 PopDrop，单独验证“固定前台文件”的识别链路。
; 用法：双击运行 → 点“确定” → 在 3 秒内切换到目标程序窗口 → 查看结果。
; 结果会同时复制到剪贴板，便于反馈。
;
; 本脚本只包含纯解析器模块，不会修改任何固定项或配置。

#Include %A_ScriptDir%\..\modules\ForegroundFileResolver.ahk

if A_Args.Length >= 3 && A_Args[1] = "--foreground-handle-worker" {
    RunForegroundHandleWorkerMode(A_Args[2], A_Args[3])
    ExitApp
}

RunForegroundFileProbe()
ExitApp

RunForegroundFileProbe() {
    if MsgBox("点击“确定”后，请在 3 秒内切换到正在编辑文件的程序窗口。",
        "PopDrop 前台文件探针", "OKCancel Iconi") != "OK"
        return
    Sleep(3000)
    targetHwnd := DllCall("user32\GetForegroundWindow", "ptr")
    startedTick := A_TickCount
    initialized := DllCall("ole32\CoInitializeEx", "ptr", 0,
        "uint", 0x2, "int") >= 0
    try {
        result := ResolveForegroundEditingFile(targetHwnd)
    } catch as err {
        result := ForegroundFileResultRecord("error", "", "", "", "",
            ForegroundFileShortError(err), "")
    } finally {
        if initialized
            DllCall("ole32\CoUninitialize")
    }
    elapsedMs := A_TickCount - startedTick
    report := "状态：" result.Status
        . "`n路径：" result.Path
        . "`n方法：" result.Method
        . "`n进程：" result.Process
        . "`n标题：" result.Title
        . "`n说明：" result.Message
        . "`n过程：" result.Trace
        . "`n耗时：" elapsedMs " ms"
        . "`nAutoHotkey：" A_AhkVersion (A_PtrSize = 8 ? " 64 位" : " 32 位")
        . "`nWindows：" A_OSVersion
    A_Clipboard := report
    MsgBox(report "`n`n（以上内容已复制到剪贴板）",
        "PopDrop 前台文件探针", result.Status = "ok" ? "Iconi" : "Icon!")
}
