; Optional external Space-key preview integration.
; No keyboard input is synthesized: Seer uses its documented WM_COPYDATA
; protocol and QuickLook receives an absolute path on its desktop CLI.

global QUICK_PREVIEW_OFF := "Off"
global QUICK_PREVIEW_SEER := "Seer"
global QUICK_PREVIEW_QUICKLOOK := "QuickLook"
global ExternalQuickPreviewProvider := "Off"
global SeerIntegrationEnabled := false
global QuickLookPath := ""
global QuickPreviewCapability := false
global QuickViewActive := false
global QuickViewPath := ""
global QuickViewOpenedAt := 0
global QuickPreviewWarningShown := false
global QuickPreviewRaisedWindows := Map()

LoadQuickPreviewSettings(settingErrors := 0) {
    global ConfigPath, ExternalQuickPreviewProvider
    global SeerIntegrationEnabled, QuickLookPath
    raw := StrLower(Trim(IniRead(
        ConfigPath, "QuickPreview", "ExternalQuickPreviewProvider", "Off")))
    if raw = "seer"
        ExternalQuickPreviewProvider := "Seer"
    else if raw = "quicklook"
        ExternalQuickPreviewProvider := "QuickLook"
    else {
        ExternalQuickPreviewProvider := "Off"
        if raw != "" && raw != "off" && IsObject(settingErrors)
            settingErrors.Push(
                "[QuickPreview] ExternalQuickPreviewProvider 无效，已关闭。")
    }
    SeerIntegrationEnabled := Trim(IniRead(
        ConfigPath, "QuickPreview", "SeerIntegrationEnabled", "0")) = "1"
    QuickLookPath := Trim(IniRead(
        ConfigPath, "QuickPreview", "QuickLookPath", ""))
    QuickPreviewRefreshCapability()
}

QuickPreviewRefreshCapability() {
    global ExternalQuickPreviewProvider, QuickPreviewCapability
    global SeerIntegrationEnabled, QuickLookPath
    global QuickViewActive
    if ExternalQuickPreviewProvider = "Seer" {
        QuickPreviewCapability := SeerIntegrationEnabled
            && DllCall("user32\FindWindowW",
                "wstr", "SeerWindowClass", "ptr", 0, "ptr") != 0
    } else if ExternalQuickPreviewProvider = "QuickLook" {
        QuickPreviewCapability := QuickPreviewValidateQuickLookPath(
            QuickLookPath)
    } else
        QuickPreviewCapability := false
    if !QuickPreviewCapability && QuickViewActive
        CloseExternalQuickPreview(false)
    return QuickPreviewCapability
}

QuickPreviewValidateQuickLookPath(path) {
    if path = "" || !RegExMatch(path, "i)^(?:[a-z]:\\|\\\\)")
        return false
    if !FileExist(path) || InStr(FileExist(path), "D")
        return false
    SplitPath(path, &fileName)
    if StrLower(fileName) != "quicklook.exe"
        return false
    product := StrLower(GetExecutableProductName(path))
    return InStr(product, "quicklook") != 0
}

IsPanelQuickPreviewAvailable(*) {
    if !IsPanelFileViewActive()
        return false
    return QuickPreviewRefreshCapability()
}

IsPanelQuickPreviewActive(*) {
    global QuickViewActive
    return QuickViewActive && IsPanelFileViewActive()
}

IsExternalQuickPreviewFocused(*) {
    global QuickViewActive, ExternalQuickPreviewProvider, QuickLookPath
    if !QuickViewActive
        return false
    active := WinExist("A")
    if !active
        return false
    try processName := StrLower(WinGetProcessName("ahk_id " active))
    catch
        return false
    if ExternalQuickPreviewProvider = "Seer"
        return InStr(processName, "seer") != 0
    SplitPath(QuickLookPath, &quickLookName)
    return processName = StrLower(quickLookName)
}

ToggleExternalQuickPreview(*) {
    global QuickViewActive
    if QuickViewActive {
        CloseExternalQuickPreview()
        return
    }
    context := GetActiveSelectionContext()
    if context.Clicked = "" || !FileExist(context.Clicked)
        return
    OpenExternalQuickPreview(context.Clicked)
}

OpenExternalQuickPreview(path) {
    global ExternalQuickPreviewProvider, QuickLookPath
    global QuickViewActive, QuickViewPath, QuickViewOpenedAt
    global QuickPreviewWarningShown
    if !QuickPreviewRefreshCapability()
        return false
    path := NormalizePath(path)
    ignored := 0
    success := ExternalQuickPreviewProvider = "Seer"
        ? QuickPreviewSendSeer(5000, path, &ignored)
        : ShellLaunchExecutableWithArgs(QuickLookPath, [path], "")
    if !success {
        if !QuickPreviewWarningShown {
            QuickPreviewWarningShown := true
            SetUserStatus("外部快速预览不可用，请检查集成设置")
        }
        return false
    }
    if !QuickViewActive
        BeginAutoHidePause()
    QuickViewActive := true
    QuickViewPath := path
    QuickViewOpenedAt := A_TickCount
    QuickPreviewEnsureAbovePanel()
    SetTimer(QuickPreviewHealthCheck, 250)
    return true
}

CloseExternalQuickPreview(sendClose := true) {
    global ExternalQuickPreviewProvider, QuickViewActive, QuickViewPath
    if !QuickViewActive
        return false
    if sendClose {
        if ExternalQuickPreviewProvider = "Seer" {
            ignored := 0
            QuickPreviewSendSeer(5005, "", &ignored)
        }
        else
            QuickPreviewCloseQuickLookWindow()
    }
    QuickPreviewRestoreWindowLevels()
    QuickViewActive := false
    QuickViewPath := ""
    SetTimer(QuickPreviewHealthCheck, 0)
    EndAutoHidePause()
    return true
}

QuickPreviewSendSeer(command, path, &messageResult) {
    seer := DllCall("user32\FindWindowW",
        "wstr", "SeerWindowClass", "ptr", 0, "ptr")
    if !seer
        return false
    payload := path = "" ? 0 : Buffer((StrLen(path) + 1) * 2, 0)
    if IsObject(payload)
        StrPut(path, payload, "UTF-16")
    structSize := A_PtrSize = 8 ? 24 : 12
    copyData := Buffer(structSize, 0)
    NumPut("uptr", command, copyData, 0)
    NumPut("uint", IsObject(payload) ? payload.Size : 0,
        copyData, A_PtrSize)
    NumPut("ptr", IsObject(payload) ? payload.Ptr : 0,
        copyData, A_PtrSize = 8 ? 16 : 8)
    messageResult := 0
    sent := DllCall("user32\SendMessageTimeoutW",
        "ptr", seer, "uint", 0x004A, "ptr", 0, "ptr", copyData.Ptr,
        "uint", 0x0002, "uint", 180, "uptr*", &messageResult, "ptr")
    return sent != 0
}

QuickPreviewCopyData(wParam, lParam, msg, hwnd) {
    global Panel, ExternalQuickPreviewProvider, SeerIntegrationEnabled
    if !IsObject(Panel) || hwnd != Panel.Hwnd
        || ExternalQuickPreviewProvider != "Seer"
        || !SeerIntegrationEnabled
        return
    seer := DllCall("user32\FindWindowW",
        "wstr", "SeerWindowClass", "ptr", 0, "ptr")
    if !seer || wParam != seer
        return
    command := NumGet(lParam, 0, "uptr")
    if command != 4000
        return
    context := GetActiveSelectionContext()
    if context.Clicked != "" {
        ignored := 0
        QuickPreviewSendSeer(4001, NormalizePath(context.Clicked), &ignored)
    }
    return 1
}

QuickPreviewScheduleUpdate() {
    global QuickViewActive
    if QuickViewActive
        SetTimer(QuickPreviewUpdateFocusedSelection, -150)
}

QuickPreviewUpdateFocusedSelection() {
    global QuickViewActive, QuickViewPath
    if !QuickViewActive
        return
    context := GetActiveSelectionContext()
    if context.Clicked = "" || PathsEqual(context.Clicked, QuickViewPath)
        return
    OpenExternalQuickPreview(context.Clicked)
}

QuickPreviewEscape(*) {
    CloseExternalQuickPreview()
}

QuickPreviewCloseQuickLookWindow() {
    hwnd := QuickPreviewFindProviderWindow()
    if hwnd {
        try WinClose("ahk_id " hwnd)
        return true
    }
    return false
}

QuickPreviewHealthCheck() {
    global QuickViewActive, ExternalQuickPreviewProvider, QuickViewOpenedAt
    global QuickLookPath
    if !QuickViewActive {
        SetTimer(QuickPreviewHealthCheck, 0)
        return
    }
    alive := false
    if ExternalQuickPreviewProvider = "Seer" {
        visible := 0
        if QuickPreviewSendSeer(5004, "", &visible)
            alive := visible = 1
    } else {
        alive := QuickPreviewFindProviderWindow() != 0
        ; Give the desktop CLI time to forward the first request.
        if !alive && ElapsedTickMilliseconds(
            QuickViewOpenedAt, A_TickCount) < 2500
            return
    }
    if !alive {
        CloseExternalQuickPreview(false)
        return
    }
    QuickPreviewEnsureAbovePanel()
}

QuickPreviewFindProviderWindow() {
    global ExternalQuickPreviewProvider, QuickLookPath
    if ExternalQuickPreviewProvider = "Seer"
        return DllCall("user32\FindWindowW",
            "wstr", "SeerWindowClass", "ptr", 0, "ptr")
    SplitPath(QuickLookPath, &exeName)
    if exeName = ""
        return 0
    best := 0
    bestArea := 0
    for hwnd in WinGetList("ahk_exe " exeName) {
        if !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
            continue
        rect := Buffer(16, 0)
        if !DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
            continue
        width := Max(0, NumGet(rect, 8, "int") - NumGet(rect, 0, "int"))
        height := Max(0, NumGet(rect, 12, "int") - NumGet(rect, 4, "int"))
        area := width * height
        if area > bestArea {
            best := hwnd
            bestArea := area
        }
    }
    return best
}

QuickPreviewEnsureAbovePanel() {
    global Panel, QuickPreviewRaisedWindows
    if !IsObject(Panel)
        return false
    hwnd := QuickPreviewFindProviderWindow()
    if !hwnd || hwnd = Panel.Hwnd
        return false
    ; Do not repeatedly move an already-correct viewer to the front of the
    ; topmost band. QuickLook's toolbar menus are separate popup windows; a
    ; periodic HWND_TOPMOST call on the main window can otherwise put that
    ; main window back above the popup and make the menu appear to vanish.
    if QuickPreviewIsWindowAbove(hwnd, Panel.Hwnd)
        return true
    if !QuickPreviewRaisedWindows.Has(hwnd) {
        style := A_PtrSize = 8
            ? DllCall("user32\GetWindowLongPtrW",
                "ptr", hwnd, "int", -20, "ptr")
            : DllCall("user32\GetWindowLongW",
                "ptr", hwnd, "int", -20, "int")
        QuickPreviewRaisedWindows[hwnd] := {
            WasTopmost: (style & 0x00000008) != 0
        }
    }
    ; PopDrop can itself be topmost. Put the external viewer at the front of
    ; the topmost band without moving, resizing or activating it.
    return DllCall("user32\SetWindowPos",
        "ptr", hwnd, "ptr", -1,
        "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", 0x0001 | 0x0002 | 0x0010 | 0x0200, "int") != 0
}

QuickPreviewIsWindowAbove(hwnd, otherHwnd) {
    if !hwnd || !otherHwnd
        return false
    current := DllCall("user32\GetTopWindow", "ptr", 0, "ptr")
    ; A defensive bound also prevents a corrupt window chain from hanging
    ; PopDrop's health timer.
    Loop 4096 {
        if !current
            break
        if current = hwnd
            return true
        if current = otherHwnd
            return false
        current := DllCall("user32\GetWindow",
            "ptr", current, "uint", 2, "ptr") ; GW_HWNDNEXT
    }
    return false
}

QuickPreviewRestoreWindowLevels() {
    global QuickPreviewRaisedWindows
    for hwnd, state in QuickPreviewRaisedWindows {
        if state.WasTopmost
            continue
        if !DllCall("user32\IsWindow", "ptr", hwnd, "int")
            continue
        DllCall("user32\SetWindowPos",
            "ptr", hwnd, "ptr", -2,
            "int", 0, "int", 0, "int", 0, "int", 0,
            "uint", 0x0001 | 0x0002 | 0x0010 | 0x0200)
    }
    QuickPreviewRaisedWindows := Map()
}

CleanupQuickPreview() {
    global QuickViewActive
    if QuickViewActive
        CloseExternalQuickPreview(false)
    else
        QuickPreviewRestoreWindowLevels()
    SetTimer(QuickPreviewUpdateFocusedSelection, 0)
    SetTimer(QuickPreviewHealthCheck, 0)
}
