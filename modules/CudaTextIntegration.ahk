; CudaText uses the Lazarus editor control's internal text-drag path rather
; than consistently exposing/accepting a Windows OLE text IDataObject.
; These narrowly-scoped bridges run only when cudatext.exe is the source or
; destination. Standard OLE remains authoritative for every other editor.

InitCudaTextIntegration() {
    try Hotkey("~LButton", CudaTextPointerDown, "On")
}

IsCudaTextWindow(hwnd) {
    if !hwnd
        return false
    root := DllCall("user32\GetAncestor", "ptr", hwnd,
        "uint", 2, "ptr") ; GA_ROOT
    if !root
        root := hwnd
    try return StrLower(WinGetProcessName("ahk_id " root))
        = "cudatext.exe"
    catch
        return false
}

GetCursorScreenPointAndWindow() {
    point := Buffer(8, 0)
    if !DllCall("user32\GetCursorPos", "ptr", point.Ptr, "int")
        return {X: 0, Y: 0, Hwnd: 0}
    x := NumGet(point, 0, "int")
    y := NumGet(point, 4, "int")
    packed := A_PtrSize = 8
        ? (x & 0xFFFFFFFF) | ((y & 0xFFFFFFFF) << 32)
        : (x & 0xFFFF) | ((y & 0xFFFF) << 16)
    hwnd := DllCall("user32\WindowFromPoint",
        "int64", packed, "ptr")
    return {X: x, Y: y, Hwnd: hwnd}
}

CudaTextPointerDown(*) {
    global PanelVisible, CudaTextDragCapture
    if !PanelVisible || !IsTextWorkspace() || IsObject(CudaTextDragCapture)
        return
    source := WinExist("A")
    if !IsCudaTextWindow(source)
        return
    point := GetCursorScreenPointAndWindow()
    CudaTextDragCapture := {
        SourceWindow: source,
        StartX: point.X,
        StartY: point.Y,
        CapturedText: "",
        SavedClipboard: 0,
        ClipboardChanged: false,
        CaptureAttempts: 0,
        LastCaptureTick: 0,
        Target: 0,
        Paused: true
    }
    BeginAutoHidePause()
    ; Capture before CudaText's internal drag loop fully takes over. Empty
    ; results receive bounded retries after the drag threshold is crossed.
    CaptureCudaTextSelection()
    ; A short interval also keeps the accepted cursor stable against
    ; CudaText's own internal drag loop repeatedly restoring IDC_NO.
    SetTimer(CudaTextDragPoll, 15)
}

CudaTextDragPoll() {
    global CudaTextDragCapture, ActiveDropSession
    if !IsObject(CudaTextDragCapture) {
        SetTimer(CudaTextDragPoll, 0)
        return
    }
    ; If CudaText supplies a real OLE object, the normal drop pipeline owns
    ; the gesture. Never allow the compatibility bridge to duplicate it.
    if IsObject(ActiveDropSession) {
        FinishCudaTextDragCapture(false)
        return
    }
    point := GetCursorScreenPointAndWindow()
    if !GetKeyState("LButton", "P") {
        target := ResolveDropTarget(point.X, point.Y)
        ; Mouse-up ends CudaText's internal drag state. If earlier attempts
        ; were blocked by that state, make one final copy while the original
        ; selection and source focus are still available.
        if CudaTextTextTargetAvailable(target)
            && CudaTextDragCapture.CapturedText = ""
            && CudaTextDragCapture.CaptureAttempts < 4
            CaptureCudaTextSelection()
        shouldSave := CudaTextTextTargetAvailable(target)
            && CudaTextDragCapture.CapturedText != ""
        captureFailed := CudaTextTextTargetAvailable(target)
            && CudaTextDragCapture.CapturedText = ""
        capturedText := CudaTextDragCapture.CapturedText
        FinishCudaTextDragCapture(false)
        if shouldSave {
            try SaveCapturedTextBlock(capturedText, target)
            catch as err
                ShowPanelMsgBox("无法保存 CudaText 选区：`n" err.Message,
                    "文本拖入失败", "Iconx")
        } else if captureFailed {
            ShowPanelMsgBox("未能读取 CudaText 的选中文字。请确认先选中文字，"
                . "再从选区内部开始拖动。", "文本拖入失败", "Icon!")
        }
        return
    }

    thresholdX := DllCall("user32\GetSystemMetrics", "int", 68, "int")
    thresholdY := DllCall("user32\GetSystemMetrics", "int", 69, "int")
    if Abs(point.X - CudaTextDragCapture.StartX) < thresholdX
        && Abs(point.Y - CudaTextDragCapture.StartY) < thresholdY
        return
    if CudaTextDragCapture.CapturedText = ""
        && CudaTextDragCapture.CaptureAttempts < 3
        && ElapsedTickMilliseconds(
            CudaTextDragCapture.LastCaptureTick, A_TickCount) >= 120
        CaptureCudaTextSelection()
    target := ResolveDropTarget(point.X, point.Y)
    if !CudaTextTextTargetAvailable(target) {
        SetDropGroupHighlight(0)
        RestoreCudaTextNoDropCursor()
        CudaTextDragCapture.Target := 0
        return
    }
    CudaTextDragCapture.Target := target
    SetDropGroupHighlight(target.GroupId)
    SetCudaTextCompatibleDropCursor()
}

SetCudaTextCompatibleDropCursor() {
    ; CudaText's internal Lazarus drag loop keeps showing IDC_NO because it
    ; does not know about PopDrop's compatibility target. Re-assert a hand
    ; cursor while our independently validated target is available. This is
    ; deliberately scoped to the active CudaText compatibility gesture.
    static acceptedCursor := DllCall("user32\LoadCursorW", "ptr", 0,
        "ptr", 32649, "ptr") ; IDC_HAND
    OverrideCudaTextNoDropCursor()
    if acceptedCursor
        DllCall("user32\SetCursor", "ptr", acceptedCursor, "ptr")
}

OverrideCudaTextNoDropCursor() {
    global CudaTextSystemCursorOverridden
    if CudaTextSystemCursorOverridden
        return
    accepted := DllCall("user32\LoadCursorW", "ptr", 0,
        "ptr", 32649, "ptr") ; IDC_HAND
    replacement := accepted
        ? DllCall("user32\CopyImage", "ptr", accepted,
            "uint", 2, "int", 0, "int", 0, "uint", 0, "ptr") : 0
    if !replacement
        return
    if DllCall("user32\SetSystemCursor", "ptr", replacement,
        "uint", 32648, "int") ; OCR_NO
        CudaTextSystemCursorOverridden := true
    else
        DllCall("user32\DestroyCursor", "ptr", replacement, "int")
}

RestoreCudaTextNoDropCursor() {
    global CudaTextSystemCursorOverridden
    if !CudaTextSystemCursorOverridden
        return
    ; Reload the user's configured cursor scheme, including custom themes.
    DllCall("user32\SystemParametersInfoW", "uint", 0x0057,
        "uint", 0, "ptr", 0, "uint", 0, "int") ; SPI_SETCURSORS
    CudaTextSystemCursorOverridden := false
}

CudaTextTextTargetAvailable(target) {
    return IsObject(target) && target.Available
        && (target.Type = "TextSource" || target.Type = "TextPinned")
}

CaptureCudaTextSelection() {
    global CudaTextDragCapture, StatusText, StatusKind
    if !IsObject(CudaTextDragCapture)
        return false
    CudaTextDragCapture.CaptureAttempts += 1
    CudaTextDragCapture.LastCaptureTick := A_TickCount
    if !CudaTextDragCapture.ClipboardChanged {
        try CudaTextDragCapture.SavedClipboard := ClipboardAll()
        catch
            CudaTextDragCapture.SavedClipboard := 0
    }
    A_Clipboard := ""
    CudaTextDragCapture.ClipboardChanged := true
    try {
        if !WinActive("ahk_id " CudaTextDragCapture.SourceWindow)
            return false
        SendEvent("^c")
        if !ClipWait(0.35)
            return false
        text := NormalizeCapturedText(A_Clipboard)
        if text = ""
            return false
        CudaTextDragCapture.CapturedText := text
        StatusKind := "user"
        StatusText.Text := "松开鼠标，将 CudaText 选区保存为文本块"
        return true
    } catch
        return false
    return false
}

FinishCudaTextDragCapture(restorePreview := true) {
    global CudaTextDragCapture
    if !IsObject(CudaTextDragCapture)
        return
    state := CudaTextDragCapture
    CudaTextDragCapture := 0
    SetTimer(CudaTextDragPoll, 0)
    SetDropGroupHighlight(0)
    RestoreCudaTextNoDropCursor()
    if state.ClipboardChanged && IsObject(state.SavedClipboard)
        try A_Clipboard := state.SavedClipboard
    if state.Paused
        EndAutoHidePause()
    if restorePreview
        PreviewRecoverAfterInteraction()
}

TryCudaTextPasteDrop(text, dragResult, effect) {
    if dragResult != 0x00040100 || effect
        return false ; not DRAGDROP_S_DROP, or a real target accepted it
    point := GetCursorScreenPointAndWindow()
    if !IsCudaTextWindow(point.Hwnd)
        return false
    try savedClipboard := ClipboardAll()
    catch
        savedClipboard := 0
    try {
        A_Clipboard := text
        if !ClipWait(0.5)
            return false
        root := DllCall("user32\GetAncestor", "ptr", point.Hwnd,
            "uint", 2, "ptr")
        if !root
            root := point.Hwnd
        WinActivate("ahk_id " root)
        if !WinWaitActive("ahk_id " root, , 0.8)
            return false
        previousMode := A_CoordModeMouse
        try {
            CoordMode("Mouse", "Screen")
            Click(point.X, point.Y)
        } finally CoordMode("Mouse", previousMode)
        Send("^v")
        Sleep(60)
        return true
    } finally {
        if IsObject(savedClipboard)
            try A_Clipboard := savedClipboard
    }
}
