; Panel integration for the "固定前台文件" toolbar action. The resolver lives in
; ForegroundFileResolver.ahk and runs in a short-lived worker process; this
; module picks the target window, launches the worker, polls its result file
; and pins the resolved document to the workspace that was active on click.

PinForegroundEditingFile(*) {
    global ForegroundFileJob

    if IsObject(ForegroundFileJob) {
        SetUserStatus("正在识别前台文件，请稍候…")
        return
    }
    targetHwnd := FindForegroundFileTargetWindow()
    if !targetHwnd {
        ShowPanelMsgBox("没有找到可识别的程序窗口。`n"
            . "请先切换到正在编辑文件的程序，再点击“固定前台文件”。",
            "固定前台文件", "Icon!")
        return
    }
    started := false
    try started := StartForegroundFileWorker(targetHwnd)
    if !started {
        ShowPanelMsgBox("无法启动前台文件识别进程，请稍后重试。",
            "固定前台文件", "Iconx")
        return
    }
    SetUserStatus("正在识别前台程序正在编辑的文件…")
}

; Clicking the rail activates PopDrop, so the foreground window is normally
; PopDrop itself. The window the user was editing in is then the highest
; normal (non-topmost) application window in the z-order that belongs to
; another process: activation raises a window to the top of its band.
FindForegroundFileTargetWindow() {
    ownProcessId := DllCall("kernel32\GetCurrentProcessId", "uint")
    foreground := DllCall("user32\GetForegroundWindow", "ptr")
    if IsForegroundFileCandidateWindow(foreground, ownProcessId, true)
        return foreground
    hwnd := DllCall("user32\GetTopWindow", "ptr", 0, "ptr")
    Loop 1024 {
        if !hwnd
            break
        if IsForegroundFileCandidateWindow(hwnd, ownProcessId, false)
            return hwnd
        hwnd := DllCall("user32\GetWindow", "ptr", hwnd,
            "uint", 2, "ptr") ; GW_HWNDNEXT
    }
    return 0
}

IsForegroundFileCandidateWindow(hwnd, ownProcessId, allowTopmost) {
    static shellClasses := Map("Shell_TrayWnd", true,
        "Shell_SecondaryTrayWnd", true, "Progman", true, "WorkerW", true)
    if !hwnd || !DllCall("user32\IsWindow", "ptr", hwnd, "int")
        return false
    if !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
        || DllCall("user32\IsIconic", "ptr", hwnd, "int")
        return false
    if DllCall("user32\GetAncestor", "ptr", hwnd, "uint", 2, "ptr") != hwnd
        return false ; GA_ROOT: top-level windows only
    windowProcessId := 0
    DllCall("user32\GetWindowThreadProcessId", "ptr", hwnd,
        "uint*", &windowProcessId, "uint")
    if !windowProcessId || windowProcessId = ownProcessId
        return false
    if IsOwnedByPanel(hwnd)
        return false
    exStyle := 0
    windowClass := ""
    title := ""
    try {
        exStyle := WinGetExStyle("ahk_id " hwnd)
        windowClass := WinGetClass("ahk_id " hwnd)
        title := WinGetTitle("ahk_id " hwnd)
    } catch {
        return false
    }
    if (exStyle & 0x80) && !(exStyle & 0x40000)
        return false ; WS_EX_TOOLWINDOW without WS_EX_APPWINDOW
    if exStyle & 0x08000000
        return false ; WS_EX_NOACTIVATE (IME, overlays)
    if !allowTopmost && (exStyle & 0x8)
        return false ; WS_EX_TOPMOST band sits above the last active app
    if shellClasses.Has(windowClass) || Trim(title) = ""
        return false
    cloaked := Buffer(4, 0)
    if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd,
        "uint", 14, "ptr", cloaked.Ptr, "uint", 4, "int") = 0
        && NumGet(cloaked, 0, "uint")
        return false ; DWMWA_CLOAKED: other virtual desktop / hidden UWP
    return true
}

StartForegroundFileWorker(targetHwnd) {
    global ForegroundFileJob, ForegroundFileGeneration
    global CacheDir, CacheWritable, ActiveWorkspaceId

    ipcDir := CacheWritable ? CacheDir : A_Temp "\PopDrop"
    try DirCreate(ipcDir)
    ForegroundFileGeneration += 1
    resultPath := ipcDir "\fgfile-" Format("{:08X}-{:04X}",
        A_TickCount & 0xFFFFFFFF, ForegroundFileGeneration) ".result"
    try FileDelete(resultPath)
    try FileDelete(resultPath ".writing")
    try {
        child := ForegroundLaunchSelf(
            ["--foreground-file-worker", targetHwnd, resultPath])
    } catch {
        return false
    }
    if !IsObject(child) || !child.Pid
        return false
    ForegroundFileJob := {
        Pid: child.Pid,
        ResultPath: resultPath,
        WorkspaceId: ActiveWorkspaceId,
        StartedTick: A_TickCount
    }
    SetTimer(PollForegroundFileWorker, 100)
    return true
}

PollForegroundFileWorker() {
    global ForegroundFileJob
    if !IsObject(ForegroundFileJob) {
        SetTimer(PollForegroundFileWorker, 0)
        return
    }
    job := ForegroundFileJob
    ready := FileExist(job.ResultPath) != ""
    running := ProcessExist(job.Pid)
    ; Worker budget: Office <1 s, handle child 3 s, UI Automation 2.5 s.
    timedOut := A_TickCount - job.StartedTick > 12000
    if !ready && running && !timedOut
        return

    SetTimer(PollForegroundFileWorker, 0)
    ForegroundFileJob := 0
    if !ready && running
        try ProcessClose(job.Pid)

    result := 0
    if ready {
        try result := ParseForegroundFileResult(
            FileRead(job.ResultPath, "UTF-8"))
    }
    try FileDelete(job.ResultPath)
    try FileDelete(job.ResultPath ".writing")

    if !IsObject(result) || result.Status = "" {
        SetUserStatus("未能固定前台文件")
        ShowPanelMsgBox(timedOut
            ? "前台文件识别超时，请稍后重试。"
            : "前台文件识别进程意外退出，请稍后重试。",
            "固定前台文件", "Icon!")
        return
    }
    ApplyForegroundFileResult(result, job.WorkspaceId)
}

ApplyForegroundFileResult(result, workspaceId) {
    global PinnedPaths, ActiveWorkspaceId

    if result.Status != "ok" || !ForegroundPathIsUsable(result.Path) {
        SetUserStatus("未能固定前台文件")
        ShowPanelMsgBox(ForegroundFileFailureMessage(result),
            "固定前台文件", "Iconi")
        return
    }
    ; Never pin into a different workspace than the one that was clicked.
    if StrLower(workspaceId) != StrLower(ActiveWorkspaceId) {
        SetUserStatus("工作区已切换，未固定前台文件")
        return
    }
    path := NormalizePath(result.Path)
    if path = "" {
        SetUserStatus("未能固定前台文件")
        ShowPanelMsgBox("识别到的路径无效，未加入固定项。",
            "固定前台文件", "Icon!")
        return
    }
    ; Same rule as "添加固定项": text workspaces accept text-block files only.
    if IsTextWorkspace() && !IsTextBlockPath(path) {
        SetUserStatus("未能固定前台文件")
        ShowPanelMsgBox("当前是文本块工作区，只能固定 .md / .txt 文本块文件。`n`n"
            . "识别到的文件：" path, "固定前台文件", "Iconi")
        return
    }
    if ArrayContainsPath(PinnedPaths, path) {
        SetUserStatus("已在固定项中：" GetFileName(path))
        return
    }
    original := PinnedPaths.Clone()
    PrependPinnedPaths([path])
    try {
        SavePinnedFiles()
        PopulatePanel()
    } catch as err {
        RestoreActivePinnedPaths(original)
        try PopulatePanel()
        ShowPanelMsgBox("无法保存固定项：`n" err.Message,
            "固定前台文件失败", "Iconx")
        return
    }
    SetUserStatus("已固定前台文件：" GetFileName(path))
}

ForegroundFileFailureMessage(result) {
    detail := Trim(result.Message "")
    if detail = ""
        detail := "未能识别前台程序正在编辑的文件。"
    text := detail
    if Trim(result.Process "") != ""
        text .= "`n前台程序：" result.Process
    if result.Status = "not-found" {
        text .= "`n`n提示：请确认文档已保存到磁盘；部分程序不公开当前文档路径。"
            . "`n仍可将文件拖入 PopDrop，或使用“添加固定项”手动选择。"
    }
    return text
}
