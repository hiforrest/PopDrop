; PopDrop 0.10 file-content preview.
; The UI process owns only hit testing, a generation-checked state machine,
; bounded shared-memory copies and GDI presentation. Shell, WIC, file
; identity, hashing and cache I/O live in PopDropPreview.exe.

global PREVIEW_PROTOCOL_VERSION := 3
global PREVIEW_MAP_BYTES := 4268288
global PREVIEW_PATH_OFFSET := 256
global PREVIEW_PATH_CHARS := 32768
global PREVIEW_CACHE_ROOT_OFFSET := 65792
global PREVIEW_CACHE_ROOT_CHARS := 4096
global PREVIEW_PIXEL_OFFSET := 73984
global PREVIEW_MAX_PIXEL_BYTES := 4194304

global PreviewEnabled := true
global PreviewSide := "Auto"
global PreviewHoverDelayMs := 350
global PreviewSwitchDelayMs := 120
global PreviewLeaveGraceMs := 140
global PreviewKeyboardDelayMs := 250
global PreviewWidthDip := 320
global PreviewCacheEnabled := true
global PreviewCacheStartAfterHiddenSeconds := 10
global PreviewCacheMaxMB := 256
global PreviewCacheMaxItems := 1000
global PreviewCacheItemMaxKB := 2048
global PreviewCacheUnreferencedDays := 7
global PreviewDirectImageMaxFileMB := 64
global PreviewDirectImageMaxEdge := 65535
global PreviewDirectImageMaxPixelsMP := 160
global PreviewDirectImageMaxExpandedMB := 256

global PreviewGeneration := 0
global PreviewListInstance := 0
global PreviewPanelSession := 0
global PreviewRequestSerial := 0
global PreviewInputAuthority := ""
global PreviewSession := {
    State: "Hidden", Path: "", Hwnd: 0, Row: 0,
    Generation: 0, ListInstance: 0, PanelSession: 0,
    RequestId: 0, RequestStarted: 0, VisiblePath: "",
    Side: "", Suppression: "", CacheCommand: false
}
global PreviewNegativeCache := Map()
global PreviewHoverCacheQueue := []
global PreviewVisibleCacheQueue := []
global PreviewCacheCompletedThisHiddenSession := 0
global PreviewCacheActive := false
global PreviewSessionDisabled := false
global PreviewRestartTicks := []

global PreviewMapHandle := 0
global PreviewMapView := 0
global PreviewRequestEvent := 0
global PreviewResponseEvent := 0
global PreviewShutdownEvent := 0
global PreviewHelperPid := 0
global PreviewJobHandle := 0
global PreviewObjectBase := ""

global PreviewWindow := 0
global PreviewCanvasDc := 0
global PreviewCanvasBitmap := 0
global PreviewCanvasOldBitmap := 0
global PreviewCanvasWidth := 0
global PreviewCanvasHeight := 0

LoadPreviewSettings(settingErrors := 0) {
    global ConfigPath
    global PreviewEnabled, PreviewSide, PreviewHoverDelayMs
    global PreviewSwitchDelayMs, PreviewLeaveGraceMs, PreviewKeyboardDelayMs
    global PreviewWidthDip, PreviewCacheEnabled
    global PreviewCacheStartAfterHiddenSeconds, PreviewCacheMaxMB
    global PreviewCacheMaxItems, PreviewCacheItemMaxKB
    global PreviewCacheUnreferencedDays, PreviewDirectImageMaxFileMB
    global PreviewDirectImageMaxEdge, PreviewDirectImageMaxPixelsMP
    global PreviewDirectImageMaxExpandedMB

    PreviewEnabled := PreviewReadBoolean("Enabled", true, settingErrors)
    rawSide := StrLower(Trim(IniRead(ConfigPath, "Preview", "Side", "Auto")))
    if rawSide = "right"
        PreviewSide := "Right"
    else if rawSide = "left"
        PreviewSide := "Left"
    else {
        PreviewSide := "Auto"
        if rawSide != "" && rawSide != "auto" && IsObject(settingErrors)
            settingErrors.Push("[Preview] Side 无效，已使用 Auto。")
    }
    PreviewHoverDelayMs := PreviewReadInteger(
        "HoverDelayMs", 350, 50, 2000, settingErrors)
    PreviewSwitchDelayMs := PreviewReadInteger(
        "SwitchDelayMs", 120, 0, 1000, settingErrors)
    PreviewLeaveGraceMs := PreviewReadInteger(
        "LeaveGraceMs", 140, 0, 1000, settingErrors)
    PreviewKeyboardDelayMs := PreviewReadInteger(
        "KeyboardDelayMs", 250, 50, 2000, settingErrors)
    PreviewWidthDip := PreviewReadInteger(
        "Width", 320, 180, 640, settingErrors)
    PreviewCacheEnabled := PreviewReadBoolean(
        "CacheEnabled", true, settingErrors)
    PreviewCacheStartAfterHiddenSeconds := PreviewReadInteger(
        "CacheStartAfterHiddenSeconds", 10, 3, 300, settingErrors)
    PreviewCacheMaxMB := PreviewReadInteger(
        "CacheMaxMB", 256, 16, 4096, settingErrors)
    PreviewCacheMaxItems := PreviewReadInteger(
        "CacheMaxItems", 1000, 10, 50000, settingErrors)
    PreviewCacheItemMaxKB := PreviewReadInteger(
        "CacheItemMaxKB", 2048, 128, 2048, settingErrors)
    PreviewCacheUnreferencedDays := PreviewReadInteger(
        "CacheUnreferencedDays", 7, 1, 365, settingErrors)
    PreviewDirectImageMaxFileMB := PreviewReadInteger(
        "DirectImageMaxFileMB", 64, 1, 256, settingErrors)
    PreviewDirectImageMaxEdge := PreviewReadInteger(
        "DirectImageMaxEdge", 65535, 1024, 65535, settingErrors)
    PreviewDirectImageMaxPixelsMP := PreviewReadInteger(
        "DirectImageMaxPixelsMP", 160, 1, 500, settingErrors)
    PreviewDirectImageMaxExpandedMB := PreviewReadInteger(
        "DirectImageMaxExpandedMB", 256, 16, 512, settingErrors)
}

PreviewReadBoolean(key, defaultValue, settingErrors := 0) {
    global ConfigPath
    raw := Trim(IniRead(ConfigPath, "Preview", key,
        defaultValue ? "1" : "0"))
    if raw = "0"
        return false
    if raw = "1"
        return true
    if IsObject(settingErrors)
        settingErrors.Push("[Preview] " key " 必须为 0 或 1，已恢复默认值。")
    return defaultValue
}

PreviewReadInteger(key, defaultValue, minimum, maximum, settingErrors := 0) {
    global ConfigPath
    raw := Trim(IniRead(ConfigPath, "Preview", key, defaultValue))
    try value := Integer(raw)
    catch {
        if IsObject(settingErrors)
            settingErrors.Push("[Preview] " key " 不是整数，已恢复默认值。")
        return defaultValue
    }
    if value < minimum || value > maximum {
        if IsObject(settingErrors)
            settingErrors.Push("[Preview] " key " 超出范围，已恢复默认值。")
        return defaultValue
    }
    return value
}

PreviewSettingsChanged() {
    global PreviewEnabled, PreviewCacheEnabled, PreviewGeneration
    global PreviewCacheActive, PreviewSession
    PreviewGeneration += 1
    if !PreviewCacheEnabled {
        PreviewCacheActive := false
        SetTimer(PreviewBeginCachePass, 0)
        SetTimer(PreviewSendNextCacheRequest, 0)
        if PreviewSession.CacheCommand
            SetTimer(PreviewCancelCacheHard.Bind(
                PreviewSession.RequestId), -300)
    }
    if !PreviewEnabled
        PreviewHide("disabled", true)
    else {
        PreviewHide("settings", true)
        PreviewRecoverAfterInteraction()
    }
}

PreviewBeginPanelSession() {
    global PreviewPanelSession, PreviewGeneration, PreviewSession
    global PreviewCacheActive
    PreviewPanelSession += 1
    PreviewGeneration += 1
    PreviewSession.Side := ""
    PreviewCacheActive := false
    SetTimer(PreviewBeginCachePass, 0)
    if PreviewSession.CacheCommand {
        cacheRequestId := PreviewSession.RequestId
        SetTimer(PreviewCancelCacheHard.Bind(cacheRequestId), -300)
    }
    PreviewHide("show", true)
}

PreviewPanelHidden() {
    global PreviewCacheStartAfterHiddenSeconds
    global PreviewCacheCompletedThisHiddenSession
    PreviewHide("panel-hidden", true)
    PreviewCacheCompletedThisHiddenSession := 0
    PreviewBuildVisibleCacheQueue()
    SetTimer(PreviewBeginCachePass,
        -PreviewCacheStartAfterHiddenSeconds * 1000)
}

PreviewInvalidateList(reason := "") {
    global PreviewListInstance, PreviewGeneration
    PreviewListInstance += 1
    PreviewGeneration += 1
    PreviewHide("list-" reason, true)
}

PreviewHandleMouseMove(hwnd, lParam) {
    global PreviewEnabled, PreviewSessionDisabled, PreviewInputAuthority
    global PreviewSession
    if !PreviewEnabled || PreviewSessionDisabled || !IsTrackedFileViewHwnd(hwnd)
        return
    PreviewTrackMouseLeave(hwnd)
    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    row := HitTestListItemBounds(hwnd, x, y)
    candidate := PreviewCandidateForRow(hwnd, row)
    PreviewInputAuthority := "mouse"
    if PreviewSession.State = "Suppressed" {
        PreviewSession.Hwnd := hwnd
        PreviewSession.Row := row
        PreviewSession.Path := IsObject(candidate) ? candidate.Path : ""
        return
    }
    if !IsObject(candidate) {
        PreviewScheduleLeave()
        return
    }
    PreviewArmCandidate(candidate.Path, hwnd, row, "mouse")
}

PreviewTrackMouseLeave(hwnd) {
    size := A_PtrSize = 8 ? 24 : 16
    track := Buffer(size, 0)
    NumPut("uint", size, track, 0)
    NumPut("uint", 0x00000002, track, 4) ; TME_LEAVE
    NumPut("ptr", hwnd, track, 8)
    DllCall("user32\TrackMouseEvent", "ptr", track.Ptr)
}

FileViewMouseLeave(wParam, lParam, msg, hwnd) {
    if IsTrackedFileViewHwnd(hwnd)
        PreviewScheduleLeave()
}

PreviewScheduleLeave() {
    global PreviewLeaveGraceMs
    SetTimer(PreviewLeaveExpired, -PreviewLeaveGraceMs)
}

PreviewLeaveExpired() {
    global PreviewInputAuthority
    if PreviewInputAuthority = "mouse"
        PreviewHide("leave", true)
}

PreviewCandidateForRow(hwnd, row) {
    global FileView, RecentView, ItemPaths, ItemKinds, RecentItemPaths
    if !row
        return 0
    if IsObject(FileView) && hwnd = FileView.Hwnd {
        if !ItemPaths.Has(row) || !ItemKinds.Has(row)
            || ItemKinds[row] != "File"
            return 0
        return {Path: ItemPaths[row], Row: row, Hwnd: hwnd}
    }
    if IsObject(RecentView) && hwnd = RecentView.Hwnd
        && RecentItemPaths.Has(row)
        return {Path: RecentItemPaths[row], Row: row, Hwnd: hwnd}
    return 0
}

PreviewArmCandidate(path, hwnd, row, authority) {
    global PreviewSession, PreviewGeneration, PreviewListInstance
    global PreviewPanelSession, PreviewHoverDelayMs, PreviewSwitchDelayMs
    global PreviewKeyboardDelayMs, PreviewNegativeCache
    if path = ""
        return
    SetTimer(PreviewLeaveExpired, 0)
    if PreviewSession.Path = path
        && PreviewSession.Hwnd = hwnd
        && PreviewSession.State != "Hidden"
        return
    if PreviewNegativeCache.Has(PathKey(path)) {
        failedAt := PreviewNegativeCache[PathKey(path)]
        if ElapsedTickMilliseconds(failedAt, A_TickCount) < 60000
            return
        PreviewNegativeCache.Delete(PathKey(path))
    }
    wasVisible := PreviewSession.State = "Visible"
        || PreviewSession.VisiblePath != ""
    PreviewGeneration += 1
    PreviewSession.State := "Armed"
    PreviewSession.Path := path
    PreviewSession.Hwnd := hwnd
    PreviewSession.Row := row
    PreviewSession.Generation := PreviewGeneration
    PreviewSession.ListInstance := PreviewListInstance
    PreviewSession.PanelSession := PreviewPanelSession
    PreviewSession.CacheCommand := false
    delay := PreviewCandidateDelay(wasVisible, authority)
    SetTimer(PreviewIssueArmedRequest, -Max(1, delay))
    if wasVisible
        SetTimer(PreviewExpireStaleContent, -150)
}

PreviewCandidateDelay(wasVisible, authority) {
    global PreviewHoverDelayMs, PreviewSwitchDelayMs, PreviewKeyboardDelayMs
    return authority = "keyboard"
        ? PreviewKeyboardDelayMs
        : (wasVisible ? PreviewSwitchDelayMs : PreviewHoverDelayMs)
}

PreviewGenerationMatches(generation, listInstance, panelSession) {
    global PreviewGeneration, PreviewListInstance, PreviewPanelSession
    return generation = PreviewGeneration
        && listInstance = PreviewListInstance
        && panelSession = PreviewPanelSession
}

PreviewExpireStaleContent() {
    global PreviewSession
    if PreviewSession.State = "Armed" || PreviewSession.State = "Loading"
        PreviewHideWindowOnly()
}

PreviewIssueArmedRequest() {
    global PreviewSession, PreviewEnabled, PreviewSessionDisabled
    if !PreviewEnabled || PreviewSessionDisabled
        return
    if PreviewSession.State != "Armed"
        return
    PreviewSendRequest(1, PreviewSession.Path)
}

PreviewHandleKeyDown(vk, hwnd) {
    global PreviewInputAuthority
    static navigationKeys := Map(
        0x25, true, 0x26, true, 0x27, true, 0x28, true,
        0x24, true, 0x23, true, 0x21, true, 0x22, true)
    if vk = 0x0D || vk = 0x1B {
        PreviewHide("key-action", true)
        return
    }
    if vk = 0x79 || vk = 0x5D {
        PreviewSuppress("context-menu", false)
        return
    }
    if navigationKeys.Has(vk) {
        PreviewInputAuthority := "keyboard"
        SetTimer(PreviewArmFocusedRow.Bind(hwnd), -1)
    }
}

PreviewArmFocusedRow(hwnd) {
    global FileView, RecentView
    if IsObject(FileView) && hwnd = FileView.Hwnd
        row := FileView.GetNext(0, "F")
    else if IsObject(RecentView) && hwnd = RecentView.Hwnd {
        row := RecentView.GetNext(0, "F")
        if !row
            row := RecentView.GetNext(0)
    } else
        return
    candidate := PreviewCandidateForRow(hwnd, row)
    if IsObject(candidate)
        PreviewArmCandidate(candidate.Path, hwnd, row, "keyboard")
    else
        PreviewHide("keyboard-empty", true)
}

PreviewSuppress(reason, recover := false) {
    global PreviewSession, PreviewGeneration
    PreviewGeneration += 1
    PreviewSession.State := "Suppressed"
    PreviewSession.Suppression := reason
    PreviewSession.Generation := PreviewGeneration
    PreviewHideWindowOnly()
    SetTimer(PreviewIssueArmedRequest, 0)
    if recover
        SetTimer(PreviewRecoverFromCursor, -180)
}

PreviewRecoverAfterInteraction() {
    SetTimer(PreviewRecoverFromCursor, -1)
}

PreviewRecoverFromCursor() {
    global PreviewEnabled, PreviewSessionDisabled, PreviewSession
    global PanelVisible, FileView, RecentView, PreviewInputAuthority
    if !PreviewEnabled || PreviewSessionDisabled || !PanelVisible
        return
    point := Buffer(8, 0)
    if !DllCall("user32\GetCursorPos", "ptr", point.Ptr)
        return
    sx := NumGet(point, 0, "int")
    sy := NumGet(point, 4, "int")
    for list in [FileView, RecentView] {
        if !IsObject(list) || !ScreenPointInWindow(list.Hwnd, sx, sy)
            continue
        clientPoint := ScreenToClientPoint(list.Hwnd, sx, sy)
        row := HitTestListItemBounds(
            list.Hwnd, clientPoint.X, clientPoint.Y)
        candidate := PreviewCandidateForRow(list.Hwnd, row)
        PreviewSession.Suppression := ""
        if IsObject(candidate) {
            PreviewInputAuthority := "mouse"
            PreviewSession.State := "Hidden"
            PreviewArmCandidate(candidate.Path, list.Hwnd, row, "mouse")
        } else
            PreviewHide("recover-empty", true)
        return
    }
    PreviewHide("recover-outside", true)
}

PanelMovingOrSizing(wParam, lParam, msg, hwnd) {
    global Panel
    if IsObject(Panel) && hwnd = Panel.Hwnd
        PreviewSuppress("move-size", false)
}

PanelExitMoveSize(wParam, lParam, msg, hwnd) {
    global Panel, PreviewSide, PreviewSession
    if IsObject(Panel) && hwnd = Panel.Hwnd {
        if PreviewSide = "Auto"
            PreviewSession.Side := ""
        PreviewRecoverAfterInteraction()
    }
}

PreviewHide(reason := "", invalidate := false) {
    global PreviewSession, PreviewGeneration
    SetTimer(PreviewIssueArmedRequest, 0)
    SetTimer(PreviewExpireStaleContent, 0)
    if invalidate
        PreviewGeneration += 1
    PreviewSession.State := "Hidden"
    PreviewSession.Path := ""
    PreviewSession.VisiblePath := ""
    PreviewSession.Generation := PreviewGeneration
    PreviewSession.CacheCommand := false
    PreviewHideWindowOnly()
}

PreviewEnsureHelper() {
    global PreviewMapHandle, PreviewMapView, PreviewRequestEvent
    global PreviewResponseEvent, PreviewShutdownEvent, PreviewObjectBase
    global PreviewHelperPid, PreviewJobHandle, PREVIEW_MAP_BYTES
    global PREVIEW_PROTOCOL_VERSION, PreviewSessionDisabled
    if PreviewSessionDisabled
        return false
    if PreviewHelperPid && ProcessExist(PreviewHelperPid)
        return true
    PreviewCloseHelperObjects(false)
    token := Format("{:08X}{:08X}", A_TickCount,
        DllCall("kernel32\GetCurrentProcessId", "uint"))
    PreviewObjectBase := "Local\PopDropPreview-" token
    PreviewMapHandle := DllCall("kernel32\CreateFileMappingW",
        "ptr", -1, "ptr", 0, "uint", 0x04, "uint", 0,
        "uint", PREVIEW_MAP_BYTES, "wstr", PreviewObjectBase "-Map", "ptr")
    if !PreviewMapHandle
        return false
    PreviewMapView := DllCall("kernel32\MapViewOfFile",
        "ptr", PreviewMapHandle, "uint", 0xF001F, "uint", 0, "uint", 0,
        "uptr", PREVIEW_MAP_BYTES, "ptr")
    PreviewRequestEvent := DllCall("kernel32\CreateEventW",
        "ptr", 0, "int", 0, "int", 0,
        "wstr", PreviewObjectBase "-Request", "ptr")
    PreviewResponseEvent := DllCall("kernel32\CreateEventW",
        "ptr", 0, "int", 0, "int", 0,
        "wstr", PreviewObjectBase "-Response", "ptr")
    PreviewShutdownEvent := DllCall("kernel32\CreateEventW",
        "ptr", 0, "int", 1, "int", 0,
        "wstr", PreviewObjectBase "-Shutdown", "ptr")
    if !PreviewMapView || !PreviewRequestEvent
        || !PreviewResponseEvent || !PreviewShutdownEvent {
        PreviewCloseHelperObjects(false)
        return false
    }
    DllCall("ntdll\RtlZeroMemory", "ptr", PreviewMapView,
        "uptr", PREVIEW_MAP_BYTES)
    NumPut("uint", 0x56504450, PreviewMapView, 0) ; PDPV
    NumPut("uint", PREVIEW_PROTOCOL_VERSION, PreviewMapView, 4)
    helperPath := A_IsCompiled
        ? A_ScriptDir "\PopDropPreview.exe"
        : A_ScriptDir "\native\bin\" (A_PtrSize = 8 ? "x64" : "x86")
            . "\PopDropPreview.exe"
    try Run('"' helperPath '" --shared "' PreviewObjectBase '"',
        A_ScriptDir, "Hide", &PreviewHelperPid)
    catch {
        PreviewCloseHelperObjects(false)
        return false
    }
    PreviewAssignHelperJob()
    return true
}

PreviewAssignHelperJob() {
    global PreviewJobHandle, PreviewHelperPid
    PreviewJobHandle := DllCall("kernel32\CreateJobObjectW",
        "ptr", 0, "ptr", 0, "ptr")
    if !PreviewJobHandle
        return
    size := A_PtrSize = 8 ? 144 : 112
    info := Buffer(size, 0)
    NumPut("uint", 0x2100, info, 16) ; PROCESS_MEMORY | KILL_ON_JOB_CLOSE
    NumPut("uptr", 256 * 1024 * 1024, info, A_PtrSize = 8 ? 112 : 96)
    if !DllCall("kernel32\SetInformationJobObject", "ptr", PreviewJobHandle,
        "int", 9, "ptr", info.Ptr, "uint", size, "int")
        return
    process := DllCall("kernel32\OpenProcess", "uint", 0x0501,
        "int", 0, "uint", PreviewHelperPid, "ptr")
    if process {
        DllCall("kernel32\AssignProcessToJobObject",
            "ptr", PreviewJobHandle, "ptr", process)
        DllCall("kernel32\CloseHandle", "ptr", process)
    }
}

PreviewSendRequest(command, path) {
    global PreviewMapView, PreviewResponseEvent, PreviewRequestEvent
    global PreviewRequestSerial, PreviewSession, PreviewGeneration
    global PreviewListInstance, PreviewPanelSession
    global PREVIEW_PATH_OFFSET, PREVIEW_PATH_CHARS
    global PREVIEW_CACHE_ROOT_OFFSET, PREVIEW_CACHE_ROOT_CHARS
    global PreviewWidthDip, Panel, CacheDir
    global PreviewCacheEnabled, PreviewCacheMaxMB, PreviewCacheMaxItems
    global PreviewCacheItemMaxKB, PreviewCacheUnreferencedDays
    global PreviewDirectImageMaxFileMB, PreviewDirectImageMaxEdge
    global PreviewDirectImageMaxPixelsMP, PreviewDirectImageMaxExpandedMB
    if !PreviewEnsureHelper() {
        PreviewRememberFailure(path)
        return
    }
    requestId := ++PreviewRequestSerial
    dpi := DllCall("user32\GetDpiForWindow", "ptr", Panel.Hwnd, "uint")
    if !dpi
        dpi := 96
    panelRect := Buffer(16, 0)
    DllCall("user32\GetWindowRect", "ptr", Panel.Hwnd, "ptr", panelRect.Ptr)
    panelHeight := Max(180,
        NumGet(panelRect, 12, "int") - NumGet(panelRect, 4, "int"))
    requestedWidth := DllCall("kernel32\MulDiv",
        "int", PreviewWidthDip, "int", dpi, "int", 96, "int")
    NumPut("uint", command, PreviewMapView, 8)
    NumPut("uint", 0, PreviewMapView, 12)
    NumPut("int64", PreviewGeneration, PreviewMapView, 16)
    NumPut("int64", PreviewListInstance, PreviewMapView, 24)
    NumPut("int64", PreviewPanelSession, PreviewMapView, 32)
    NumPut("int64", requestId, PreviewMapView, 40)
    cacheEdge := Min(1024, panelHeight)
    NumPut("uint", command = 2 ? cacheEdge : Min(1024, requestedWidth),
        PreviewMapView, 48)
    NumPut("uint", command = 2 ? cacheEdge : Min(1024, panelHeight),
        PreviewMapView, 52)
    NumPut("uint", PreviewDirectImageMaxFileMB, PreviewMapView, 56)
    NumPut("uint", PreviewDirectImageMaxEdge, PreviewMapView, 60)
    NumPut("uint", PreviewDirectImageMaxPixelsMP, PreviewMapView, 64)
    NumPut("uint", PreviewDirectImageMaxExpandedMB, PreviewMapView, 68)
    NumPut("uint", PreviewCacheEnabled ? 1 : 0, PreviewMapView, 72)
    NumPut("uint", PreviewCacheMaxMB, PreviewMapView, 76)
    NumPut("uint", PreviewCacheMaxItems, PreviewMapView, 80)
    NumPut("uint", PreviewCacheItemMaxKB, PreviewMapView, 84)
    NumPut("uint", PreviewCacheUnreferencedDays, PreviewMapView, 88)
    NumPut("uint", cacheEdge, PreviewMapView, 92)
    StrPut(path, PreviewMapView + PREVIEW_PATH_OFFSET,
        PREVIEW_PATH_CHARS, "UTF-16")
    StrPut(CacheDir "\preview-cache-v1",
        PreviewMapView + PREVIEW_CACHE_ROOT_OFFSET,
        PREVIEW_CACHE_ROOT_CHARS, "UTF-16")
    DllCall("kernel32\ResetEvent", "ptr", PreviewResponseEvent)
    PreviewSession.State := "Loading"
    PreviewSession.RequestId := requestId
    PreviewSession.RequestStarted := A_TickCount
    PreviewSession.Generation := PreviewGeneration
    PreviewSession.ListInstance := PreviewListInstance
    PreviewSession.PanelSession := PreviewPanelSession
    PreviewSession.CacheCommand := command = 2
    DllCall("kernel32\SetEvent", "ptr", PreviewRequestEvent)
    SetTimer(PreviewPollResponse, 15)
}

PreviewPollResponse() {
    global PreviewResponseEvent, PreviewMapView, PreviewSession
    global PreviewGeneration, PreviewListInstance, PreviewPanelSession
    if !PreviewResponseEvent || !PreviewMapView {
        SetTimer(PreviewPollResponse, 0)
        return
    }
    if DllCall("kernel32\WaitForSingleObject",
        "ptr", PreviewResponseEvent, "uint", 0, "uint") = 0 {
        SetTimer(PreviewPollResponse, 0)
        requestId := NumGet(PreviewMapView, 40, "int64")
        generation := NumGet(PreviewMapView, 16, "int64")
        listInstance := NumGet(PreviewMapView, 24, "int64")
        panelSession := NumGet(PreviewMapView, 32, "int64")
        if requestId != PreviewSession.RequestId
            || !PreviewGenerationMatches(
                generation, listInstance, panelSession)
            return
        status := NumGet(PreviewMapView, 12, "uint")
        if PreviewSession.CacheCommand {
            PreviewFinishCacheRequest(status = 2)
            return
        }
        if status != 2 {
            PreviewRememberFailure(PreviewSession.Path)
            PreviewHide("no-content", false)
            return
        }
        width := NumGet(PreviewMapView, 128, "uint")
        height := NumGet(PreviewMapView, 132, "uint")
        stride := NumGet(PreviewMapView, 136, "uint")
        if !width || !height || stride < width * 4
            || stride * height > PREVIEW_MAX_PIXEL_BYTES {
            PreviewRememberFailure(PreviewSession.Path)
            PreviewHide("invalid-result", false)
            return
        }
        sourceKind := NumGet(PreviewMapView, 140, "uint")
        if PreviewPresentPixels(width, height, stride, sourceKind) {
            PreviewSession.State := "Visible"
            PreviewSession.VisiblePath := PreviewSession.Path
            PreviewQueueHoverCache(PreviewSession.Path)
        } else
            PreviewHide("no-space", false)
        return
    }
    if PreviewSession.State = "Loading"
        && ElapsedTickMilliseconds(
            PreviewSession.RequestStarted, A_TickCount) >= 3000 {
        SetTimer(PreviewPollResponse, 0)
        failedPath := PreviewSession.Path
        PreviewTerminateHungHelper()
        PreviewRememberFailure(failedPath)
        PreviewHide("timeout", true)
    }
}

PreviewRememberFailure(path) {
    global PreviewNegativeCache
    if path != ""
        PreviewNegativeCache[PathKey(path)] := A_TickCount
}

PreviewTerminateHungHelper() {
    global PreviewHelperPid, PreviewRestartTicks, PreviewSessionDisabled
    if PreviewHelperPid && ProcessExist(PreviewHelperPid)
        try ProcessClose(PreviewHelperPid)
    now := A_TickCount
    kept := []
    for tick in PreviewRestartTicks {
        if ElapsedTickMilliseconds(tick, now) <= 60000
            kept.Push(tick)
    }
    kept.Push(now)
    PreviewRestartTicks := kept
    PreviewCloseHelperObjects(false)
    if kept.Length > 3
        PreviewSessionDisabled := true
}

PreviewPresentPixels(sourceWidth, sourceHeight, sourceStride, sourceKind := 0) {
    global Panel, PreviewSide, PreviewSession, PreviewWidthDip
    global PreviewMapView, PREVIEW_PIXEL_OFFSET, PreviewWindow
    panelRect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", Panel.Hwnd, "ptr", panelRect.Ptr)
        return false
    panelLeft := NumGet(panelRect, 0, "int")
    panelTop := NumGet(panelRect, 4, "int")
    panelRight := NumGet(panelRect, 8, "int")
    panelBottom := NumGet(panelRect, 12, "int")
    monitor := DllCall("user32\MonitorFromWindow", "ptr", Panel.Hwnd,
        "uint", 2, "ptr")
    info := Buffer(40, 0)
    NumPut("uint", 40, info, 0)
    if !DllCall("user32\GetMonitorInfoW", "ptr", monitor, "ptr", info.Ptr)
        return false
    workLeft := NumGet(info, 20, "int")
    workTop := NumGet(info, 24, "int")
    workRight := NumGet(info, 28, "int")
    workBottom := NumGet(info, 32, "int")
    dpi := DllCall("user32\GetDpiForWindow", "ptr", Panel.Hwnd, "uint")
    if !dpi
        dpi := 96
    gap := DllCall("kernel32\MulDiv", "int", 8, "int", dpi, "int", 96, "int")
    minWidth := DllCall("kernel32\MulDiv",
        "int", 180, "int", dpi, "int", 96, "int")
    targetWidth := DllCall("kernel32\MulDiv",
        "int", PreviewWidthDip, "int", dpi, "int", 96, "int")
    rightAvailable := workRight - panelRight - gap
    leftAvailable := panelLeft - workLeft - gap
    side := PreviewSession.Side
    if side = "" {
        if PreviewSide = "Right"
            side := "Right"
        else if PreviewSide = "Left"
            side := "Left"
        else if rightAvailable >= minWidth
            side := "Right"
        else if leftAvailable >= minWidth
            side := "Left"
        else
            return false
        PreviewSession.Side := side
    }
    available := side = "Right" ? rightAvailable : leftAvailable
    windowWidth := Min(targetWidth, available)
    if windowWidth < minWidth
        return false
    panelHeight := panelBottom - panelTop
    padding := Max(6, DllCall("kernel32\MulDiv",
        "int", 8, "int", dpi, "int", 96, "int"))
    contentMaxWidth := Max(1, windowWidth - padding * 2)
    contentMaxHeight := Max(1, panelHeight - padding * 2)
    ; Shell is the last-resort source. Its cached thumbnail can be much
    ; smaller than the useful preview area, so enlarge that fallback to fit.
    scaleLimit := sourceKind = 2 ? 1000.0 : 1.0
    scale := Min(scaleLimit, contentMaxWidth / sourceWidth,
        contentMaxHeight / sourceHeight)
    drawWidth := Max(1, Floor(sourceWidth * scale))
    drawHeight := Max(1, Floor(sourceHeight * scale))
    windowHeight := Min(panelHeight, drawHeight + padding * 2)
    x := side = "Right" ? panelRight + gap
        : panelLeft - gap - windowWidth
    y := Max(workTop, Min(panelTop, workBottom - windowHeight))
    if !PreviewBuildCanvas(windowWidth, windowHeight, padding,
        drawWidth, drawHeight, sourceWidth, sourceHeight, sourceStride)
        return false
    PreviewEnsureWindow()
    zorder := PreviewIsTopmostMode() ? -1 : -2 ; HWND_TOPMOST / NOTOPMOST
    DllCall("user32\SetWindowPos", "ptr", PreviewWindow.Hwnd,
        "ptr", zorder, "int", x, "int", y, "int", windowWidth,
        "int", windowHeight, "uint", 0x0010 | 0x0040) ; NOACTIVATE|SHOWWINDOW
    DllCall("user32\InvalidateRect", "ptr", PreviewWindow.Hwnd,
        "ptr", 0, "int", 0)
    DllCall("user32\UpdateWindow", "ptr", PreviewWindow.Hwnd)
    return true
}

PreviewBuildCanvas(windowWidth, windowHeight, padding, drawWidth, drawHeight,
    sourceWidth, sourceHeight, sourceStride) {
    global PreviewMapView, PREVIEW_PIXEL_OFFSET
    global PreviewCanvasDc, PreviewCanvasBitmap, PreviewCanvasOldBitmap
    global PreviewCanvasWidth, PreviewCanvasHeight
    PreviewReleaseCanvas()
    screenDc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    PreviewCanvasDc := DllCall("gdi32\CreateCompatibleDC",
        "ptr", screenDc, "ptr")
    PreviewCanvasBitmap := DllCall("gdi32\CreateCompatibleBitmap",
        "ptr", screenDc, "int", windowWidth, "int", windowHeight, "ptr")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !PreviewCanvasDc || !PreviewCanvasBitmap
        return false
    PreviewCanvasOldBitmap := DllCall("gdi32\SelectObject",
        "ptr", PreviewCanvasDc, "ptr", PreviewCanvasBitmap, "ptr")
    PreviewCanvasWidth := windowWidth
    PreviewCanvasHeight := windowHeight
    rect := Buffer(16, 0)
    NumPut("int", windowWidth, rect, 8)
    NumPut("int", windowHeight, rect, 12)
    background := DllCall("gdi32\CreateSolidBrush",
        "uint", 0x00262626, "ptr")
    DllCall("user32\FillRect", "ptr", PreviewCanvasDc,
        "ptr", rect.Ptr, "ptr", background)
    DllCall("gdi32\DeleteObject", "ptr", background)
    imageX := Floor((windowWidth - drawWidth) / 2)
    imageY := Floor((windowHeight - drawHeight) / 2)
    tile := Max(6, Floor(padding))
    row := 0
    while row < drawHeight {
        col := 0
        while col < drawWidth {
            color := (Mod(Floor(row / tile) + Floor(col / tile), 2) = 0)
                ? 0x00D8D8D8 : 0x00B8B8B8
            brush := DllCall("gdi32\CreateSolidBrush", "uint", color, "ptr")
            cell := Buffer(16, 0)
            NumPut("int", imageX + col, cell, 0)
            NumPut("int", imageY + row, cell, 4)
            NumPut("int", imageX + Min(drawWidth, col + tile), cell, 8)
            NumPut("int", imageY + Min(drawHeight, row + tile), cell, 12)
            DllCall("user32\FillRect", "ptr", PreviewCanvasDc,
                "ptr", cell.Ptr, "ptr", brush)
            DllCall("gdi32\DeleteObject", "ptr", brush)
            col += tile
        }
        row += tile
    }
    sourceInfo := Buffer(40, 0)
    NumPut("uint", 40, sourceInfo, 0)
    NumPut("int", sourceWidth, sourceInfo, 4)
    NumPut("int", -sourceHeight, sourceInfo, 8)
    NumPut("ushort", 1, sourceInfo, 12)
    NumPut("ushort", 32, sourceInfo, 14)
    NumPut("uint", 0, sourceInfo, 16)
    sourceDc := DllCall("gdi32\CreateCompatibleDC",
        "ptr", PreviewCanvasDc, "ptr")
    sourceBits := 0
    sourceBitmap := DllCall("gdi32\CreateDIBSection", "ptr", sourceDc,
        "ptr", sourceInfo.Ptr, "uint", 0, "ptr*", &sourceBits,
        "ptr", 0, "uint", 0, "ptr")
    if !sourceBitmap || !sourceBits {
        if sourceDc
            DllCall("gdi32\DeleteDC", "ptr", sourceDc)
        return false
    }
    oldSource := DllCall("gdi32\SelectObject",
        "ptr", sourceDc, "ptr", sourceBitmap, "ptr")
    DllCall("ntdll\RtlMoveMemory", "ptr", sourceBits,
        "ptr", PreviewMapView + PREVIEW_PIXEL_OFFSET,
        "uptr", sourceStride * sourceHeight)
    blend := Buffer(4, 0)
    NumPut("uchar", 0, blend, 0)
    NumPut("uchar", 0, blend, 1)
    NumPut("uchar", 255, blend, 2)
    NumPut("uchar", 1, blend, 3) ; AC_SRC_ALPHA
    blendValue := NumGet(blend, 0, "uint")
    DllCall("msimg32\AlphaBlend", "ptr", PreviewCanvasDc,
        "int", imageX, "int", imageY, "int", drawWidth, "int", drawHeight,
        "ptr", sourceDc, "int", 0, "int", 0,
        "int", sourceWidth, "int", sourceHeight, "uint", blendValue)
    DllCall("gdi32\SelectObject", "ptr", sourceDc, "ptr", oldSource)
    DllCall("gdi32\DeleteObject", "ptr", sourceBitmap)
    DllCall("gdi32\DeleteDC", "ptr", sourceDc)
    border := DllCall("gdi32\CreateSolidBrush",
        "uint", 0x00505050, "ptr")
    DllCall("user32\FrameRect", "ptr", PreviewCanvasDc,
        "ptr", rect.Ptr, "ptr", border)
    DllCall("gdi32\DeleteObject", "ptr", border)
    return true
}

PreviewEnsureWindow() {
    global PreviewWindow, Panel
    if IsObject(PreviewWindow)
        return
    ; WS_EX_TOOLWINDOW is supplied by +ToolWindow. 0x08000000 is
    ; WS_EX_NOACTIVATE, so the preview cannot take keyboard focus.
    PreviewWindow := Gui("-Caption +ToolWindow +Owner" Panel.Hwnd
        . " +E0x08000000", "PopDrop Preview")
    PreviewWindow.MarginX := 0
    PreviewWindow.MarginY := 0
    OnMessage(0x000F, PreviewWindowPaint) ; WM_PAINT
    PreviewApplyWindowMode()
}

PreviewWindowPaint(wParam, lParam, msg, hwnd) {
    global PreviewWindow, PreviewCanvasDc
    global PreviewCanvasWidth, PreviewCanvasHeight
    if !IsObject(PreviewWindow) || hwnd != PreviewWindow.Hwnd
        return
    paint := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    hdc := DllCall("user32\BeginPaint", "ptr", hwnd,
        "ptr", paint.Ptr, "ptr")
    if hdc && PreviewCanvasDc
        DllCall("gdi32\BitBlt", "ptr", hdc, "int", 0, "int", 0,
            "int", PreviewCanvasWidth, "int", PreviewCanvasHeight,
            "ptr", PreviewCanvasDc, "int", 0, "int", 0, "uint", 0x00CC0020)
    DllCall("user32\EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    return 0
}

PreviewIsTopmostMode() {
    global WindowMode, WINDOW_MODE_NORMAL
    return WindowMode != WINDOW_MODE_NORMAL
}

PreviewApplyWindowMode() {
    global PreviewWindow
    if !IsObject(PreviewWindow)
        return
    zorder := PreviewIsTopmostMode() ? -1 : -2
    ; SWP_NOACTIVATE keeps z-order changes from activating the tool window.
    DllCall("user32\SetWindowPos", "ptr", PreviewWindow.Hwnd,
        "ptr", zorder, "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", 0x0001 | 0x0002 | 0x0010) ; NOSIZE|NOMOVE|NOACTIVATE
}

PreviewHideWindowOnly() {
    global PreviewWindow
    if IsObject(PreviewWindow)
        DllCall("user32\ShowWindow", "ptr", PreviewWindow.Hwnd, "int", 0)
}

PreviewReleaseCanvas() {
    global PreviewCanvasDc, PreviewCanvasBitmap, PreviewCanvasOldBitmap
    global PreviewCanvasWidth, PreviewCanvasHeight
    if PreviewCanvasDc && PreviewCanvasOldBitmap
        DllCall("gdi32\SelectObject", "ptr", PreviewCanvasDc,
            "ptr", PreviewCanvasOldBitmap)
    if PreviewCanvasBitmap
        DllCall("gdi32\DeleteObject", "ptr", PreviewCanvasBitmap)
    if PreviewCanvasDc
        DllCall("gdi32\DeleteDC", "ptr", PreviewCanvasDc)
    PreviewCanvasDc := 0
    PreviewCanvasBitmap := 0
    PreviewCanvasOldBitmap := 0
    PreviewCanvasWidth := 0
    PreviewCanvasHeight := 0
}

PreviewQueueHoverCache(path) {
    global PreviewHoverCacheQueue
    if !PreviewLooksLikeImage(path)
        return
    if !ArrayContainsPath(PreviewHoverCacheQueue, path)
        PreviewHoverCacheQueue.Push(path)
}

PreviewLooksLikeImage(path) {
    SplitPath(path, , , &extension)
    return InStr("|jpg|jpeg|jpe|png|gif|bmp|dib|tif|tiff|webp|heic|heif|avif|"
        . "ico|dng|cr2|cr3|nef|arw|rw2|orf|raf|", "|"
        . StrLower(extension) "|")
}

PreviewBuildVisibleCacheQueue() {
    global PreviewVisibleCacheQueue, ItemPaths, ItemKinds
    global RecentItemPaths, PinnedPaths
    PreviewVisibleCacheQueue := []
    for row, path in ItemPaths {
        if ItemKinds.Has(row) && ItemKinds[row] = "File"
            && PreviewLooksLikeImage(path)
            && !ArrayContainsPath(PreviewVisibleCacheQueue, path)
            PreviewVisibleCacheQueue.Push(path)
    }
    for path in PinnedPaths {
        if PreviewLooksLikeImage(path)
            && !ArrayContainsPath(PreviewVisibleCacheQueue, path)
            PreviewVisibleCacheQueue.Push(path)
    }
    for row, path in RecentItemPaths {
        if PreviewLooksLikeImage(path)
            && !ArrayContainsPath(PreviewVisibleCacheQueue, path)
            PreviewVisibleCacheQueue.Push(path)
    }
}

PreviewBeginCachePass() {
    global PanelVisible, PreviewEnabled, PreviewCacheEnabled
    global PreviewCacheActive
    if PanelVisible || !PreviewEnabled || !PreviewCacheEnabled
        return
    ; The helper already runs at IDLE priority and serializes its work. Do not
    ; let a long scan/transfer keep an entire hidden session cache-free.
    PreviewCacheActive := true
    PreviewSendNextCacheRequest()
}

PreviewHasActiveTransfer() {
    global TransferBatches
    for id, batch in TransferBatches {
        if !batch.Completed
            return true
    }
    return false
}

PreviewSendNextCacheRequest() {
    global PreviewCacheActive, PreviewCacheCompletedThisHiddenSession
    global PreviewHoverCacheQueue, PreviewVisibleCacheQueue
    global PanelVisible, PreviewGeneration
    if !PreviewCacheActive || PanelVisible
        return
    if PreviewCacheCompletedThisHiddenSession >= 20 {
        PreviewCacheActive := false
        return
    }
    path := ""
    while PreviewHoverCacheQueue.Length && path = ""
        path := PreviewHoverCacheQueue.RemoveAt(1)
    while path = "" && PreviewVisibleCacheQueue.Length
        path := PreviewVisibleCacheQueue.RemoveAt(1)
    if path = "" {
        PreviewCacheActive := false
        return
    }
    PreviewGeneration += 1
    PreviewSendRequest(2, path)
}

PreviewFinishCacheRequest(success) {
    global PreviewSession, PreviewCacheCompletedThisHiddenSession
    PreviewSession.CacheCommand := false
    PreviewSession.State := "Hidden"
    PreviewCacheCompletedThisHiddenSession += 1
    SetTimer(PreviewSendNextCacheRequest, -200)
}

PreviewCancelCacheHard(requestId) {
    global PreviewSession
    if PreviewSession.RequestId = requestId
        PreviewTerminateHungHelper()
}

PreviewCloseHelperObjects(signalShutdown := true) {
    global PreviewMapHandle, PreviewMapView, PreviewRequestEvent
    global PreviewResponseEvent, PreviewShutdownEvent, PreviewHelperPid
    global PreviewJobHandle
    if signalShutdown && PreviewShutdownEvent
        DllCall("kernel32\SetEvent", "ptr", PreviewShutdownEvent)
    if signalShutdown && PreviewHelperPid {
        process := DllCall("kernel32\OpenProcess",
            "uint", 0x00100000, "int", 0, "uint", PreviewHelperPid, "ptr")
        if process {
            DllCall("kernel32\WaitForSingleObject",
                "ptr", process, "uint", 300, "uint")
            DllCall("kernel32\CloseHandle", "ptr", process)
        }
    }
    if PreviewMapView
        DllCall("kernel32\UnmapViewOfFile", "ptr", PreviewMapView)
    for handle in [PreviewRequestEvent, PreviewResponseEvent,
        PreviewShutdownEvent, PreviewMapHandle, PreviewJobHandle] {
        if handle
            DllCall("kernel32\CloseHandle", "ptr", handle)
    }
    PreviewMapHandle := 0
    PreviewMapView := 0
    PreviewRequestEvent := 0
    PreviewResponseEvent := 0
    PreviewShutdownEvent := 0
    PreviewHelperPid := 0
    PreviewJobHandle := 0
}

CleanupPreview() {
    global PreviewWindow
    SetTimer(PreviewPollResponse, 0)
    SetTimer(PreviewBeginCachePass, 0)
    SetTimer(PreviewSendNextCacheRequest, 0)
    PreviewHideWindowOnly()
    PreviewReleaseCanvas()
    if IsObject(PreviewWindow)
        try PreviewWindow.Destroy()
    PreviewWindow := 0
    PreviewCloseHelperObjects(true)
}

RunPreviewSelfTests() {
    global PreviewGeneration, PreviewListInstance, PreviewPanelSession
    AssertSelfTest(PreviewCandidateDelay(false, "mouse") = 350,
        "预览首次悬浮默认 350ms")
    AssertSelfTest(PreviewCandidateDelay(true, "mouse") = 120,
        "预览切换默认 120ms")
    AssertSelfTest(PreviewCandidateDelay(false, "keyboard") = 250,
        "预览键盘默认 250ms")
    AssertSelfTest(PreviewLooksLikeImage("C:\Temp\photo.JPEG"),
        "图片候选扩展名大小写不敏感")
    AssertSelfTest(!PreviewLooksLikeImage("C:\Temp\document.pdf"),
        "非图片不进入原图缓存生成队列")
    generation := PreviewGeneration
    listInstance := PreviewListInstance
    panelSession := PreviewPanelSession
    AssertSelfTest(PreviewGenerationMatches(
        generation, listInstance, panelSession),
        "预览三重会话身份匹配")
    AssertSelfTest(!PreviewGenerationMatches(
        generation + 1, listInstance, panelSession),
        "旧 Generation 失效")
    AssertSelfTest(!PreviewGenerationMatches(
        generation, listInstance + 1, panelSession),
        "旧列表实例失效")
    AssertSelfTest(!PreviewGenerationMatches(
        generation, listInstance, panelSession + 1),
        "旧面板显示会话失效")
}
