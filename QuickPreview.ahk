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
global QuickViewRequestedAt := 0
global QuickPreviewRequestedPath := ""
global QuickPreviewPendingSeerPath := ""
global QuickPreviewSeerLastInvokeAt := 0
global QuickPreviewSpacePressed := false
global QuickPreviewProviderWasVisible := false
global QuickPreviewWarningShown := false
global QuickPreviewRaisedWindows := Map()
global QuickPreviewProviderWindows := Map()
global QuickPreviewProviderPids := Map()
global QuickPreviewReturnFocusHwnd := 0

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
    if !IsPopDropPanelActive()
        return false
    ; A focused text-block search box owns Space for text/IME input even when
    ; the pointer is still resting on a file card.  This check must remain in
    ; the HotIf criterion: rejecting Space after the hotkey has fired would
    ; swallow the physical key instead of returning it to the Edit control.
    if IsTextBlockSearchActive()
        return false
    ; Space belongs to a focused toolbar control unless the pointer is
    ; explicitly over a file. This still supports hover-without-selection.
    if !IsPanelFileViewActive() && QuickPreviewHoveredPath() = ""
        return false
    return QuickPreviewRefreshCapability()
}

IsPanelQuickPreviewActive(*) {
    global QuickViewActive
    return QuickViewActive && IsPanelFileViewActive()
}

IsExternalQuickPreviewFocused(*) {
    QuickPreviewRegisterProviderWindows()
    return QuickPreviewSessionOwnsWindow(
        DllCall("user32\GetForegroundWindow", "ptr"))
}

IsSeerMainPreviewFocused(*) {
    global ExternalQuickPreviewProvider, QuickViewActive
    if !QuickViewActive || ExternalQuickPreviewProvider != "Seer"
        return false
    seer := DllCall("user32\FindWindowW",
        "wstr", "SeerWindowClass", "ptr", 0, "ptr")
    if !seer || DllCall("user32\GetForegroundWindow", "ptr") != seer
        return false
    ; Do not steal Space from a Seer menu or an active owned popup/dialog.
    popup := DllCall("user32\GetLastActivePopup", "ptr", seer, "ptr")
    if popup != seer && DllCall("user32\IsWindowVisible", "ptr", popup, "int")
        return false
    threadId := DllCall("user32\GetWindowThreadProcessId",
        "ptr", seer, "ptr", 0, "uint")
    info := Buffer(8 + 6 * A_PtrSize + 16, 0)
    NumPut("uint", info.Size, info, 0)
    if DllCall("user32\GetGUIThreadInfo", "uint", threadId,
        "ptr", info.Ptr, "int") {
        flags := NumGet(info, 4, "uint")
        if flags & (0x0004 | 0x0008 | 0x0010)
            return false
    }
    return true
}

CloseSeerQuickPreviewFromSpace(*) {
    if !QuickPreviewAcceptSpaceEdge()
        return
    CloseExternalQuickPreview()
}

HandlePanelQuickPreviewSpace(*) {
    if !QuickPreviewAcceptSpaceEdge()
        return
    ToggleExternalQuickPreview()
}

QuickPreviewAcceptSpaceEdge() {
    global QuickPreviewSpacePressed
    if QuickPreviewSpacePressed
        return false
    QuickPreviewSpacePressed := true
    SetTimer(QuickPreviewSpaceReleasePoll, -20)
    return true
}

QuickPreviewSpaceReleasePoll() {
    global QuickPreviewSpacePressed
    if GetKeyState("Space", "P") {
        SetTimer(QuickPreviewSpaceReleasePoll, -20)
        return
    }
    QuickPreviewSpacePressed := false
}

ToggleExternalQuickPreview(*) {
    global QuickViewActive
    if QuickViewActive {
        CloseExternalQuickPreview()
        return
    }
    path := QuickPreviewHoveredPath()
    if path = "" {
        context := GetActiveSelectionContext()
        path := context.Clicked
    }
    if path = "" || !FileExist(path)
        return
    OpenExternalQuickPreview(path)
}

QuickPreviewHoveredPath() {
    global FileView, RecentView
    point := Buffer(8, 0)
    if !DllCall("user32\GetCursorPos", "ptr", point.Ptr)
        return ""
    sx := NumGet(point, 0, "int"), sy := NumGet(point, 4, "int")
    for list in [FileView, RecentView] {
        if !IsObject(list) || !ScreenPointInWindow(list.Hwnd, sx, sy)
            continue
        cp := ScreenToClientPoint(list.Hwnd, sx, sy)
        row := HitTestListItemBounds(list.Hwnd, cp.X, cp.Y)
        candidate := PreviewCandidateForRow(list.Hwnd, row)
        if IsObject(candidate)
            return candidate.Path
    }
    return ""
}

OpenExternalQuickPreview(path) {
    global ExternalQuickPreviewProvider, QuickLookPath
    global QuickViewActive, QuickViewPath, QuickViewOpenedAt
    global QuickViewRequestedAt, QuickPreviewRequestedPath
    global QuickPreviewWarningShown, QuickPreviewProviderWasVisible
    if !QuickPreviewRefreshCapability()
        return false
    path := NormalizePath(path)
    if path = "" || !FileExist(path)
        return false
    if QuickViewActive && PathsEqual(path, QuickViewPath)
        && QuickViewRequestedAt && ElapsedTickMilliseconds(
            QuickViewRequestedAt, A_TickCount) < 500
        return true
    ; Lock the exact candidate before Seer can synchronously request a path.
    ; Never re-resolve selection state during this request.
    QuickPreviewRequestedPath := path
    newSession := !QuickViewActive
    if newSession {
        ; Discard ItemSelect work queued before Space fixed the candidate.
        SetTimer(QuickPreviewUpdateFocusedSelection, 0)
        QuickPreviewBeginSession()
        BeginAutoHidePause()
        QuickViewActive := true
        QuickViewOpenedAt := A_TickCount
        QuickPreviewProviderWasVisible := false
    }
    ignored := 0
    requestTick := A_TickCount
    success := ExternalQuickPreviewProvider = "Seer"
        ? QuickPreviewInvokeSeer(path)
        : ShellLaunchExecutableWithArgs(QuickLookPath, [path], "")
    if !success {
        if newSession {
            QuickViewActive := false
            QuickViewOpenedAt := 0
            QuickViewRequestedAt := 0
            QuickPreviewRequestedPath := ""
            QuickPreviewResetSessionTracking()
            EndAutoHidePause()
        }
        if !QuickPreviewWarningShown {
            QuickPreviewWarningShown := true
            SetUserStatus("外部快速预览不可用，请检查集成设置")
        }
        return false
    }
    QuickViewPath := path
    QuickViewRequestedAt := requestTick
    QuickPreviewRegisterProviderWindows()
    QuickPreviewEnsureAbovePanel()
    SetTimer(QuickPreviewHealthCheck, 250)
    return true
}

CloseExternalQuickPreview(sendClose := true, restoreFocus := true) {
    global ExternalQuickPreviewProvider, QuickViewActive, QuickViewPath
    global QuickViewOpenedAt, QuickViewRequestedAt
    global QuickPreviewRequestedPath, QuickPreviewPendingSeerPath
    global QuickPreviewProviderWasVisible
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
    QuickViewOpenedAt := 0
    QuickViewRequestedAt := 0
    QuickPreviewRequestedPath := ""
    QuickPreviewPendingSeerPath := ""
    QuickPreviewProviderWasVisible := false
    SetTimer(QuickPreviewFlushSeerInvoke, 0)
    SetTimer(QuickPreviewHealthCheck, 0)
    if restoreFocus
        QuickPreviewRestorePanelFocus()
    QuickPreviewResetSessionTracking()
    EndAutoHidePause()
    return true
}

QuickPreviewBeginSession() {
    global Panel, FileView, RecentView, QuickPreviewReturnFocusHwnd
    QuickPreviewResetSessionTracking()
    QuickPreviewReturnFocusHwnd := DllCall("user32\GetFocus", "ptr")
    point := Buffer(8, 0)
    if DllCall("user32\GetCursorPos", "ptr", point.Ptr) {
        sx := NumGet(point, 0, "int"), sy := NumGet(point, 4, "int")
        for list in [FileView, RecentView] {
            if IsObject(list) && ScreenPointInWindow(list.Hwnd, sx, sy) {
                QuickPreviewReturnFocusHwnd := list.Hwnd
                break
            }
        }
    }
    if !IsObject(Panel) || !QuickPreviewReturnFocusHwnd
        return
    if QuickPreviewReturnFocusHwnd != Panel.Hwnd
        && !DllCall("user32\IsChild", "ptr", Panel.Hwnd,
            "ptr", QuickPreviewReturnFocusHwnd, "int")
        QuickPreviewReturnFocusHwnd := 0
}

QuickPreviewResetSessionTracking() {
    global QuickPreviewProviderWindows, QuickPreviewProviderPids
    global QuickPreviewReturnFocusHwnd
    QuickPreviewProviderWindows := Map()
    QuickPreviewProviderPids := Map()
    QuickPreviewReturnFocusHwnd := 0
}

QuickPreviewRegisterWindow(hwnd) {
    global QuickPreviewProviderWindows, QuickPreviewProviderPids
    if !hwnd || !DllCall("user32\IsWindow", "ptr", hwnd, "int")
        return false
    QuickPreviewProviderWindows[hwnd] := true
    processId := 0
    DllCall("user32\GetWindowThreadProcessId", "ptr", hwnd,
        "uint*", &processId, "uint")
    if processId
        QuickPreviewProviderPids[processId] := true
    return true
}

QuickPreviewRegisterProviderWindows() {
    global ExternalQuickPreviewProvider, QuickLookPath, QuickViewActive
    if !QuickViewActive
        return
    if ExternalQuickPreviewProvider = "Seer" {
        QuickPreviewRegisterWindow(DllCall("user32\FindWindowW",
            "wstr", "SeerWindowClass", "ptr", 0, "ptr"))
        ; Seer feature dialogs may be hosted by a separately named helper.
        ; Register only visible Seer-family executables during an active Seer
        ; session; the native watchdog later consumes the captured PIDs.
        try {
            for hwnd in WinGetList() {
                if !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
                    continue
                processName := WinGetProcessName("ahk_id " hwnd)
                if RegExMatch(processName,
                    "i)^seer(?:[-_].*)?\.exe$")
                    QuickPreviewRegisterWindow(hwnd)
            }
        }
        return
    }
    SplitPath(QuickLookPath, &exeName)
    if exeName = ""
        return
    try {
        for hwnd in WinGetList("ahk_exe " exeName)
            QuickPreviewRegisterWindow(hwnd)
    }
}

QuickPreviewAnyProviderWindowVisible() {
    global QuickPreviewProviderPids
    if !QuickPreviewProviderPids.Count
        return false
    try {
        for hwnd in WinGetList() {
            if !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
                continue
            processId := 0
            DllCall("user32\GetWindowThreadProcessId", "ptr", hwnd,
                "uint*", &processId, "uint")
            if processId && QuickPreviewProviderPids.Has(processId) {
                QuickPreviewRegisterWindow(hwnd)
                return true
            }
        }
    }
    return false
}

QuickPreviewSessionOwnsWindow(hwnd, allowLaunchGrace := true,
    nowTick := 0) {
    global QuickViewActive, QuickViewOpenedAt
    global QuickPreviewProviderWindows, QuickPreviewProviderPids
    if !QuickViewActive || !hwnd
        return false
    if nowTick = 0
        nowTick := A_TickCount
    ; The QuickLook CLI forwards to its UI asynchronously.  Protect the launch
    ; hand-off before the first provider HWND can be enumerated; this closes the
    ; race where the native 100-ms watchdog used to hide both applications.
    if allowLaunchGrace && !QuickPreviewProviderPids.Count && QuickViewOpenedAt
        && ElapsedTickMilliseconds(QuickViewOpenedAt, nowTick) < 3000
        return true
    current := hwnd
    Loop 16 {
        if QuickPreviewProviderWindows.Has(current)
            return true
        processId := 0
        DllCall("user32\GetWindowThreadProcessId", "ptr", current,
            "uint*", &processId, "uint")
        if processId && QuickPreviewProviderPids.Has(processId)
            return true
        current := DllCall("user32\GetWindow", "ptr", current,
            "uint", 4, "ptr") ; GW_OWNER
        if !current
            break
    }
    return false
}

QuickPreviewNativeProtectsAutoHide(hwnd, tick) {
    ; Native TimerProc calls this path.  Keep it limited to stable in-memory
    ; session data and direct Win32 queries; do not enumerate windows here.
    return QuickPreviewSessionOwnsWindow(hwnd, true, tick)
}

QuickPreviewRestorePanelFocus() {
    global Panel, PanelVisible, QuickPreviewReturnFocusHwnd
    if !PanelVisible || !IsObject(Panel)
        return false
    if !DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int")
        return false
    try WinRestore("ahk_id " Panel.Hwnd)
    try WinActivate("ahk_id " Panel.Hwnd)
    focusHwnd := QuickPreviewReturnFocusHwnd
    if focusHwnd && DllCall("user32\IsWindow", "ptr", focusHwnd, "int")
        && (focusHwnd = Panel.Hwnd
            || DllCall("user32\IsChild", "ptr", Panel.Hwnd,
                "ptr", focusHwnd, "int"))
        DllCall("user32\SetFocus", "ptr", focusHwnd, "ptr")
    SetTimer(QuickPreviewRestoreControlFocus.Bind(focusHwnd), -50)
    return true
}

QuickPreviewRestoreControlFocus(focusHwnd) {
    global Panel, PanelVisible
    if !PanelVisible || !IsObject(Panel)
        return
    if DllCall("user32\GetForegroundWindow", "ptr") != Panel.Hwnd
        return
    if focusHwnd && DllCall("user32\IsWindow", "ptr", focusHwnd, "int")
        && (focusHwnd = Panel.Hwnd
            || DllCall("user32\IsChild", "ptr", Panel.Hwnd,
                "ptr", focusHwnd, "int"))
        DllCall("user32\SetFocus", "ptr", focusHwnd, "ptr")
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
        "uint", 0x0002, "uint", 250, "uptr*", &messageResult, "ptr")
    return sent != 0
}

QuickPreviewInvokeSeer(path) {
    global QuickPreviewPendingSeerPath, QuickPreviewSeerLastInvokeAt
    ; Seer documents a minimum 200 ms interval for SEER_INVOKE_W32 (5000).
    ; Coalesce rapid selection/navigation changes and dispatch only the newest
    ; absolute path after a small safety margin.
    static minimumIntervalMs := 220
    if QuickPreviewSeerLastInvokeAt {
        elapsed := ElapsedTickMilliseconds(
            QuickPreviewSeerLastInvokeAt, A_TickCount)
        if elapsed < minimumIntervalMs {
            QuickPreviewPendingSeerPath := path
            SetTimer(QuickPreviewFlushSeerInvoke,
                -(minimumIntervalMs - elapsed))
            return true
        }
    }
    QuickPreviewPendingSeerPath := ""
    QuickPreviewSeerLastInvokeAt := A_TickCount
    ignored := 0
    return QuickPreviewSendSeer(5000, path, &ignored)
}

QuickPreviewFlushSeerInvoke() {
    global ExternalQuickPreviewProvider, QuickViewActive
    global QuickPreviewPendingSeerPath, QuickPreviewSeerLastInvokeAt
    global QuickViewRequestedAt
    if !QuickViewActive || ExternalQuickPreviewProvider != "Seer" {
        QuickPreviewPendingSeerPath := ""
        return
    }
    path := QuickPreviewPendingSeerPath
    QuickPreviewPendingSeerPath := ""
    if path = "" || !FileExist(path)
        return
    QuickPreviewSeerLastInvokeAt := A_TickCount
    ignored := 0
    if QuickPreviewSendSeer(5000, path, &ignored)
        QuickViewRequestedAt := A_TickCount
    else
        CloseExternalQuickPreview(false)
}

QuickPreviewCopyData(wParam, lParam, msg, hwnd) {
    global Panel, ExternalQuickPreviewProvider, SeerIntegrationEnabled
    global QuickPreviewRequestedPath, QuickViewPath
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
    ; Compatibility for installations that registered PopDrop as a custom
    ; explorer. Reply only with the path locked by this preview session; a
    ; late 4000 request must never substitute another selected item.
    path := QuickPreviewRequestedPath != ""
        ? QuickPreviewRequestedPath : QuickViewPath
    if path != "" && FileExist(path) {
        ignored := 0
        QuickPreviewSendSeer(4001, path, &ignored)
    }
    return 1
}

QuickPreviewScheduleUpdate() {
    global QuickViewActive
    if QuickViewActive
        SetTimer(QuickPreviewUpdateFocusedSelection, -220)
}

QuickPreviewUpdateFocusedSelection() {
    global QuickViewActive, QuickViewPath
    ; A queued ItemSelect from before the viewer was activated must not replace
    ; a hover-opened file with a stale selected row.
    if !QuickViewActive || !IsPopDropPanelActive()
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
    global QuickViewRequestedAt, QuickLookPath
    global QuickPreviewProviderWasVisible
    if !QuickViewActive {
        SetTimer(QuickPreviewHealthCheck, 0)
        return
    }
    QuickPreviewRegisterProviderWindows()
    alive := false
    if ExternalQuickPreviewProvider = "Seer" {
        visible := 0
        if QuickPreviewSendSeer(5004, "", &visible)
            alive := visible = 1
        if !alive
            alive := QuickPreviewAnyProviderWindowVisible()
    } else {
        alive := QuickPreviewFindProviderWindow() != 0
    }
    if alive
        QuickPreviewProviderWasVisible := true
    if !alive {
        ; A successful IPC/CLI hand-off can precede the first visible frame.
        ; Keep a bounded provider-specific launch grace only until a preview
        ; window has actually been observed; later closes remain immediate.
        graceMs := ExternalQuickPreviewProvider = "Seer" ? 2000 : 5000
        if !QuickPreviewProviderWasVisible && QuickViewRequestedAt
            && ElapsedTickMilliseconds(QuickViewRequestedAt,
                A_TickCount) < graceMs
            return
        CloseExternalQuickPreview(false)
        return
    }
    QuickPreviewEnsureAbovePanel()
}

QuickPreviewFindProviderWindow() {
    global ExternalQuickPreviewProvider, QuickLookPath
    if ExternalQuickPreviewProvider = "Seer" {
        hwnd := DllCall("user32\FindWindowW",
            "wstr", "SeerWindowClass", "ptr", 0, "ptr")
        QuickPreviewRegisterWindow(hwnd)
        return hwnd
    }
    SplitPath(QuickLookPath, &exeName)
    if exeName = ""
        return 0
    best := 0
    bestArea := 0
    for hwnd in WinGetList("ahk_exe " exeName) {
        QuickPreviewRegisterWindow(hwnd)
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
    mainHwnd := QuickPreviewFindProviderWindow()
    if !mainHwnd || mainHwnd = Panel.Hwnd
        return false
    foreground := DllCall("user32\GetForegroundWindow", "ptr")
    ; A provider-owned settings page, dialog or feature window takes priority
    ; over the main viewer.  Raising only the main HWND can otherwise cover an
    ; unowned same-process dialog when PopDrop itself occupies the topmost band.
    hwnd := QuickPreviewSessionOwnsWindow(foreground, false)
        ? foreground : mainHwnd
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
    ; the topmost band without moving, resizing or activating it. Provider
    ; popups are raised only while they are the actual foreground window.
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
    global QuickViewActive, QuickPreviewSpacePressed
    if QuickViewActive
        CloseExternalQuickPreview(false, false)
    else
        QuickPreviewRestoreWindowLevels()
    SetTimer(QuickPreviewUpdateFocusedSelection, 0)
    SetTimer(QuickPreviewFlushSeerInvoke, 0)
    SetTimer(QuickPreviewSpaceReleasePoll, 0)
    QuickPreviewSpacePressed := false
    SetTimer(QuickPreviewHealthCheck, 0)
}
