; Main panel construction, layout, display modes and window behavior.

BuildPanel() {
    global Panel, FileView, RecentLabel, RecentView
    global DisplayButton, WindowModeButton, PinnedDropButton, StatusText
    global ItemCountText
    global ClipboardPinnedButton, RefreshButton, RemovePinnedButton
    global PinnedGroupLeftSeparator, PinnedGroupRightSeparator
    global SettingsButton, CloseButton, TextBlockSearchEdit
    global TransferStatusText
    global APP_VERSION, WorkspaceSelector, UiScaleFactor
    global ToolbarControls, FolderDropAddSourceButton, FolderDropPinnedButton

    Panel := Gui("+Resize +MinSize760x380", "PopDrop v" APP_VERSION)
    Panel.MarginX := 12
    ; The toolbar is a fixed 42-DIP band. Keep the tuned control row one DIP
    ; below the previous centered position, without changing the list boundary.
    Panel.MarginY := 7
    Panel.SetFont("s" Round(9 * UiScaleFactor), "Microsoft YaHei UI")

    workspaceLabel := Panel.AddText("xm ym+6 w52 h22 +0x200", "工作区：")
    WorkspaceSelector := AddUiDropDownList(Panel, "x+2 yp-5 w110", [])
    OffsetGuiControlYPhysical(workspaceLabel, -4)
    WorkspaceSelector.OnEvent("Change", MainWorkspaceChanged)
    RefreshButton := AddUiButton(Panel, "x+6 yp w52", "刷新")
    RefreshButton.OnEvent("Click", RefreshPanel)
    PinnedGroupLeftSeparator := Panel.AddText(
        "x+7 yp+3 w2 h20 +0x11", "") ; SS_ETCHEDVERT
    PinnedDropButton := AddUiButton(Panel, "x+7 yp-3 w70", "＋固定项")
    PinnedDropButton.OnEvent("Click", AddPinnedFiles)
    RemovePinnedButton := AddUiButton(Panel, "x+4 yp w70", "－固定项")
    RemovePinnedButton.OnEvent("Click", RemovePinnedFile)
    ClipboardPinnedButton := AddUiButton(
        Panel, "x+4 yp w42 Hidden Disabled", "📋+")
    ClipboardPinnedButton.OnEvent("Click", AddClipboardTextToPinned)
    PinnedGroupRightSeparator := Panel.AddText(
        "x+7 yp+3 w2 h20 +0x11", "") ; SS_ETCHEDVERT
    DisplayButton := AddUiButton(Panel, "x+7 yp-3 w56", "显示 ▾")
    DisplayButton.OnEvent("Click", ShowDisplayMenu)
    BuildDisplayMenu()
    SettingsButton := AddUiButton(Panel, "x+4 yp w52", "设置")
    SettingsButton.OnEvent("Click", OpenConfig)
    WindowModeButton := AddUiButton(Panel, "x+4 yp w72", "置顶：关")
    WindowModeButton.OnEvent("Click", ToggleWindowMode)
    CloseButton := AddUiButton(Panel, "x+4 yp w48", "关闭")
    CloseButton.OnEvent("Click", HidePanel)
    ToolbarControls := [workspaceLabel, WorkspaceSelector, RefreshButton,
        PinnedGroupLeftSeparator, PinnedDropButton, RemovePinnedButton,
        ClipboardPinnedButton, PinnedGroupRightSeparator, DisplayButton,
        SettingsButton, WindowModeButton, CloseButton]

    TextBlockSearchEdit := AddUiEdit(Panel,
        "x184 y8 w196 h26 Hidden", "")
    TextBlockSearchEdit.OnEvent("Change", TextBlockSearchChanged)
    DllCall("user32\SendMessageW", "ptr", TextBlockSearchEdit.Hwnd,
        "uint", 0x1501, "ptr", 1, "wstr", "直接输入以筛选文本块", "ptr")
    ToolbarControls.Push(TextBlockSearchEdit)

    ; Pre-create the compact folder-only drop surface. It occupies the same
    ; toolbar band and never changes the ListView geometry.
    FolderDropAddSourceButton := Panel.AddButton(
        "x12 y4 w510 h36 Hidden -Tabstop +0x2000",
        "＋ 添加为来源`n当前工作区")
    FolderDropPinnedButton := Panel.AddButton(
        "x530 y4 w224 h36 Hidden -Tabstop +0x2000",
        "☆ 加入固定项`n不会移动文件夹")
    FolderDropAddSourceButton.Visible := false
    FolderDropPinnedButton.Visible := false

    ; Multi-select is the native ListView default. In icon view this enables
    ; Ctrl-click, Shift range selection and marquee selection on blank space.
    FileView := Panel.AddListView("xm y42 w716 h492 Icon +0x100", ["文件", "修改时间"])
    FileView.OnEvent("Click", FileViewClick)
    FileView.OnEvent("DoubleClick", OpenFileViewItem)
    FileView.OnEvent("ContextMenu", FileViewContextMenu)
    FileView.OnEvent("ItemSelect", FileViewItemSelect)
    ; LVS_EX_DOUBLEBUFFER | LVS_EX_GROUPHEADERCLICK reduces flicker and
    ; enables clicking group headers to open folders.
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1036,
        "ptr", 0x410000, "ptr", 0x410000, "ptr")
    
    RecentLabel := Panel.AddText("x740 y42 w220 h22 +0x200", "最近打开")
    RecentLabel.SetFont("s10 Bold")
    RecentView := Panel.AddListView("x740 y68 w220 h466 Report -Hdr -Multi", ["文件"])
    RecentView.OnEvent("Click", FileViewClick)
    RecentView.OnEvent("DoubleClick", OpenRecentItem)
    RecentView.OnEvent("ContextMenu", RecentContextMenu)
    RecentView.OnEvent("ItemSelect", RecentItemSelect)

    StatusText := Panel.AddText("xm y+0 w372 h42 +0xD +0x100", "已是最新")
    StatusText.OnEvent("Click", HandleStatusAction)
    ItemCountText := Panel.AddText("x+8 yp w112 h42 +0xD +0x100", "共0项")
    TransferStatusText := Panel.AddText(
        "x+8 yp w208 h42 +0xD +0x100", "↓ 下载")
    TransferStatusText.OnEvent("Click", OpenTransferCenter)
    Panel.OnEvent("Close", HandlePanelClose)
    Panel.OnEvent("Escape", HandlePanelEscape)
    Panel.OnEvent("Size", ResizePanel)
    ; OLE IDropTarget is registered after the panel is built. Do not also
    ; enable WM_DROPFILES: one physical drop must have exactly one owner.
    UpdateWindowModeButton()
    SyncWorkspaceControls()
    UpdateWorkspaceTypeUi()
}

SyncWorkspaceControls() {
    global WorkspaceSelector, WorkspaceSelectorIds
    global Workspaces, ActiveWorkspaceId, SettingsController
    if IsObject(WorkspaceSelector) {
        WorkspaceSelectorIds := []
        names := []
        selected := 1
        for index, workspace in Workspaces {
            names.Push(workspace.Name)
            WorkspaceSelectorIds.Push(workspace.Id)
            if StrLower(workspace.Id) = StrLower(ActiveWorkspaceId)
                selected := index
        }
        ReplaceUiDropDownItems(WorkspaceSelector, names)
        if names.Length
            WorkspaceSelector.Choose(selected)
    }
    if IsObject(SettingsController)
        try RefreshSettingsWorkspaceControls(SettingsController)
    UpdateWorkspaceTypeUi()
}

UpdateWorkspaceTypeUi() {
    global TextBlockSearchEdit, RefreshButton, PinnedDropButton
    global ClipboardPinnedButton, RemovePinnedButton, TextBlockSearchQuery
    global PinnedGroupLeftSeparator, PinnedGroupRightSeparator
    global DisplayButton, SettingsButton, WindowModeButton, CloseButton
    textMode := IsTextWorkspace()
    if IsObject(TextBlockSearchEdit) {
        TextBlockSearchEdit.Visible := textMode
        if textMode
            TextBlockSearchEdit.Move(184, 7, 122, 26)
        if !textMode {
            TextBlockSearchQuery := ""
            TextBlockSearchEdit.Value := ""
        }
    }
    if IsObject(RefreshButton)
        RefreshButton.Visible := !textMode
    if IsObject(PinnedGroupLeftSeparator) {
        PinnedGroupLeftSeparator.Visible := true
        PinnedGroupLeftSeparator.Move(textMode ? 312 : 242, 10, 2, 20)
    }
    if IsObject(PinnedDropButton) {
        PinnedDropButton.Visible := true
        PinnedDropButton.Text := "＋固定项"
        PinnedDropButton.Move(textMode ? 320 : 250, 7,
            textMode ? 72 : 70, 26)
    }
    if IsObject(RemovePinnedButton)
        RemovePinnedButton.Visible := !textMode
    if IsObject(RemovePinnedButton) && !textMode
        RemovePinnedButton.Move(324, 7, 70, 26)
    if IsObject(ClipboardPinnedButton) {
        ClipboardPinnedButton.Visible := textMode
        if textMode
            ClipboardPinnedButton.Move(396, 7, 42, 26)
    }
    if IsObject(PinnedGroupRightSeparator) {
        PinnedGroupRightSeparator.Visible := true
        PinnedGroupRightSeparator.Move(textMode ? 444 : 400, 10, 2, 20)
    }
    if IsObject(DisplayButton)
        DisplayButton.Move(textMode ? 452 : 408, 7, 56, 26)
    if IsObject(SettingsButton)
        SettingsButton.Move(textMode ? 512 : 468, 7, 52, 26)
    if IsObject(WindowModeButton)
        WindowModeButton.Move(textMode ? 568 : 524, 7, 72, 26)
    if IsObject(CloseButton)
        CloseButton.Move(textMode ? 644 : 600, 7, 48, 26)
    UpdateClipboardPinnedButton()
    RedrawPanelToolbar()
}

RedrawPanelToolbar() {
    global Panel, PANEL_TOOLBAR_HEIGHT
    if !IsObject(Panel)
        return
    hwnd := Panel.Hwnd
    if !hwnd || !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
        return

    ; Moving and hiding sibling controls invalidates each child, but Windows
    ; does not reliably erase their former parent-background rectangles in the
    ; same event turn. That leaves old button frames visible until WM_MOUSEMOVE
    ; causes piecemeal painting. Invalidate the toolbar band on the parent and
    ; synchronously redraw every child only after the final layout is in place.
    clientRect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", hwnd,
        "ptr", clientRect.Ptr, "int")
        return
    dpi := DllCall("user32\GetDpiForWindow", "ptr", hwnd, "uint")
    if !dpi
        dpi := A_ScreenDPI
    toolbarBottom := DllCall("kernel32\MulDiv",
        "int", PANEL_TOOLBAR_HEIGHT, "int", dpi, "int", 96, "int")
    NumPut("int", 0, clientRect, 0)
    NumPut("int", 0, clientRect, 4)
    NumPut("int", Max(0, NumGet(clientRect, 8, "int")), clientRect, 8)
    NumPut("int", Max(1, toolbarBottom), clientRect, 12)
    flags := 0x0001 | 0x0004 | 0x0080 | 0x0100
        ; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
    DllCall("user32\RedrawWindow", "ptr", hwnd, "ptr", clientRect.Ptr,
        "ptr", 0, "uint", flags, "int")
}

MainWorkspaceChanged(control, *) {
    global WorkspaceSelectorIds, ActiveWorkspaceId
    global InactiveScanJob
    index := control.Value
    if index < 1 || index > WorkspaceSelectorIds.Length
        return
    targetId := WorkspaceSelectorIds[index]
    if StrLower(targetId) = StrLower(ActiveWorkspaceId)
        return
    if IsObject(InactiveScanJob)
        && StrLower(InactiveScanJob.WorkspaceId) = StrLower(targetId)
        CancelInactiveWorkspaceScan(false)
    if !RequestActivateWorkspace(targetId, "main")
        SyncWorkspaceControls()
}

RequestActivateWorkspace(workspaceId, origin := "main") {
    global SettingsController
    if IsObject(SettingsController)
        return RequestSettingsWorkspaceSwitch(
            SettingsController, workspaceId, origin)
    return ActivateWorkspace(workspaceId)
}

ActivateWorkspace(workspaceId) {
    global ActiveWorkspaceId, PanelVisible, StatusKind, FileView
    global LastFileWorkspaceId, WORKSPACE_TYPE_FILES
    global SourceWatcherRecentDirty
    global ContentUpdateMode, CONTENT_UPDATE_ACCURACY
    found := FindWorkspace(workspaceId)
    if !IsObject(found)
        return false
    if StrLower(workspaceId) = StrLower(ActiveWorkspaceId) {
        SyncWorkspaceControls()
        return true
    }
    nextLastFileId := LastFileWorkspaceId
    if ParseWorkspaceType(found.Value.Type) = WORKSPACE_TYPE_FILES
        nextLastFileId := found.Value.Id
    try AtomicConfigEdit(
        WriteActiveWorkspaceState.Bind(workspaceId, nextLastFileId))
    catch as err {
        ShowPanelMsgBox("无法切换工作区：`n" err.Message,
            "工作区切换失败", "Iconx")
        return false
    }
    PreviewSuppress("workspace", false)
    ClearTextBlockSearch(false)
    LoadSettings()
    if !ScanResultLoaded
        LoadDiskScanCache()
    InstallWorkspaceHotkeys()
    StatusKind := "default"
    PopulatePanel()
    PopulateRecentSidebar()
    if PanelVisible && IsObject(FileView) {
        if IsTextWorkspace()
            RestoreTextBlockSearchFocus()
        else
            FileView.Focus()
    }
    ReconcileSourceWatchers()
    refreshKeys := GetWorkspaceRefreshSourceKeys(ActiveWorkspaceId, true)
    needsFullScan := !ScanResultLoaded
        || ContentUpdateMode = CONTENT_UPDATE_ACCURACY
    includeRecent := ShowRecentSidebar && (!ScanResultLoaded
        || SourceWatcherRecentDirty)
    if needsFullScan
        StartBackgroundScan(0, "workspace", includeRecent)
    else if refreshKeys.Count || includeRecent
        StartBackgroundScan(refreshKeys, "workspace", includeRecent)
    return true
}

WriteActiveWorkspaceState(workspaceId, lastFileWorkspaceId, tempPath) {
    doc := OpenPopDropConfig(tempPath)
    doc.SetValue("Workspaces", "Active", workspaceId, 3)
    doc.SetValue("General", "LastFileWorkspaceId",
        lastFileWorkspaceId, 1)
    doc.Save()
}

ApplyWindowMode() {
    global Panel, WindowMode, PanelVisible
    global WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY, WINDOW_MODE_NORMAL
    global AutoHideNativeTemporaryEnabled

    if !IsObject(Panel)
        return

    switch WindowMode {
        case WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY:
            Panel.Opt("+AlwaysOnTop")

        case WINDOW_MODE_NORMAL:
            Panel.Opt("-AlwaysOnTop")

        default:
            Panel.Opt("+AlwaysOnTop")
    }
    PreviewApplyWindowMode()
    AutoHideNativeTemporaryEnabled := WindowMode = WINDOW_MODE_TEMPORARY

    if WindowMode = WINDOW_MODE_TEMPORARY && PanelVisible
        StartAutoHideWatchdog()
    else
        StopAutoHideWatchdog()
    if WindowMode != WINDOW_MODE_TEMPORARY
        CancelAutoHideCheck()
}

; ──── 临时面板自动隐藏 ────

InitAutoHideNativeWatchdog() {
    global Panel, AutoHideNativeTimerId, AutoHideNativeTimerCallback
    global AutoHideNativePanelHwnd, AUTO_HIDE_NATIVE_HIDDEN_MESSAGE
    if AutoHideNativeTimerId || !IsObject(Panel)
        return !!AutoHideNativeTimerId
    AutoHideNativePanelHwnd := Panel.Hwnd
    OnMessage(AUTO_HIDE_NATIVE_HIDDEN_MESSAGE, AutoHideNativeHidden)
    AutoHideNativeTimerCallback := CallbackCreate(
        AutoHideNativeTimerProc, "Fast", 4)
    ; A Win32 TimerProc remains installed for the process lifetime. Unlike
    ; AHK SetTimer it is never stopped when the panel hides, so a corrupt
    ; PanelVisible flag or a terminated AHK timer cannot disable this guard.
    AutoHideNativeTimerId := DllCall("user32\SetTimer",
        "ptr", 0, "uptr", 0, "uint", 100,
        "ptr", AutoHideNativeTimerCallback, "uptr")
    return !!AutoHideNativeTimerId
}

CleanupAutoHideNativeWatchdog() {
    global AutoHideNativeTimerId, AutoHideNativeTimerCallback
    global AutoHideNativePanelHwnd, AUTO_HIDE_NATIVE_HIDDEN_MESSAGE
    if AutoHideNativeTimerId
        DllCall("user32\KillTimer", "ptr", 0,
            "uptr", AutoHideNativeTimerId, "int")
    AutoHideNativeTimerId := 0
    OnMessage(AUTO_HIDE_NATIVE_HIDDEN_MESSAGE, AutoHideNativeHidden, 0)
    if AutoHideNativeTimerCallback
        CallbackFree(AutoHideNativeTimerCallback)
    AutoHideNativeTimerCallback := 0
    AutoHideNativePanelHwnd := 0
}

AutoHideNativeTimerProc(hwnd, message, timerId, tick) {
    global AutoHideNativePanelHwnd, AutoHideNativeTemporaryEnabled
    global AutoHideNativeShownTick
    global AUTO_HIDE_NATIVE_HIDDEN_MESSAGE
    panelHwnd := AutoHideNativePanelHwnd
    if !AutoHideNativeTemporaryEnabled || !panelHwnd
        || !DllCall("user32\IsWindowVisible", "ptr", panelHwnd, "int")
        return
    if AutoHideNativeShownTick
        && ElapsedTickMilliseconds(AutoHideNativeShownTick, tick) < 300
        return
    ; Mouse-up precedes IDropTarget::Drop. The source application is still
    ; foreground while PopDrop reads IDataObject and saves the payload, so
    ; foreground ownership alone is not evidence that the user left.
    if IncomingDropProtectsAutoHide(tick)
        return
    foreground := DllCall("user32\GetForegroundWindow", "ptr")
    if !foreground || foreground = panelHwnd
        return
    if QuickPreviewNativeProtectsAutoHide(foreground, tick)
        return
    ; Same-process popups and any window explicitly owned by the panel are
    ; legitimate menus/dialogs, not evidence that the user left PopDrop.
    processId := 0
    DllCall("user32\GetWindowThreadProcessId", "ptr", foreground,
        "uint*", &processId, "uint")
    if processId = DllCall("kernel32\GetCurrentProcessId", "uint")
        return
    owner := foreground
    Loop 16 {
        owner := DllCall("user32\GetWindow", "ptr", owner,
            "uint", 4, "ptr") ; GW_OWNER
        if !owner
            break
        if owner = panelHwnd
            return
    }
    ; Do not tear down the drag source/target while a physical gesture is in
    ; progress. The next 100 ms tick after release makes the final decision.
    if (DllCall("user32\GetAsyncKeyState", "int", 1, "short") & 0x8000)
        || (DllCall("user32\GetAsyncKeyState", "int", 2, "short") & 0x8000)
        || (DllCall("user32\GetAsyncKeyState", "int", 4, "short") & 0x8000)
        return
    ; Hide the real HWND first. Internal cleanup is deliberately a second
    ; phase, so the user's visible result does not depend on any AHK state.
    DllCall("user32\ShowWindow", "ptr", panelHwnd, "int", 0)
    DllCall("user32\PostMessageW", "ptr", A_ScriptHwnd,
        "uint", AUTO_HIDE_NATIVE_HIDDEN_MESSAGE,
        "ptr", foreground, "ptr", 0, "int")
}

AutoHideNativeHidden(wParam, lParam, msg, hwnd) {
    global Panel, PanelVisible
    if !IsObject(Panel)
        return
    ; Synchronize AHK-owned preview, drag and selection state after the native
    ; guard has already made the panel invisible.
    if PanelVisible
        HidePanel()
    else {
        CancelAutoHideCheck()
        StopAutoHideWatchdog()
        PreviewPanelHidden()
    }
}

InitAutoHideForegroundHook() {
    global AutoHideForegroundHook, AutoHideForegroundCallback
    global AUTO_HIDE_FOREGROUND_MESSAGE
    if AutoHideForegroundHook
        return true
    OnMessage(AUTO_HIDE_FOREGROUND_MESSAGE,
        AutoHideExternalForegroundChanged)
    if !AutoHideForegroundCallback
        AutoHideForegroundCallback := CallbackCreate(
            AutoHideForegroundWinEvent, "Fast", 7)
    ; EVENT_SYSTEM_FOREGROUND, WINEVENT_OUTOFCONTEXT | SKIPOWNPROCESS.
    ; This receives a signal for a real switch to another application even
    ; when WM_ACTIVATE was swallowed by OLE, a menu loop or rapid hotkey work.
    AutoHideForegroundHook := DllCall("user32\SetWinEventHook",
        "uint", 0x0003, "uint", 0x0003, "ptr", 0,
        "ptr", AutoHideForegroundCallback, "uint", 0, "uint", 0,
        "uint", 0x0000 | 0x0002, "ptr")
    return !!AutoHideForegroundHook
}

CleanupAutoHideForegroundHook() {
    global AutoHideForegroundHook, AutoHideForegroundCallback
    global AUTO_HIDE_FOREGROUND_MESSAGE
    if AutoHideForegroundHook
        DllCall("user32\UnhookWinEvent",
            "ptr", AutoHideForegroundHook, "int")
    AutoHideForegroundHook := 0
    OnMessage(AUTO_HIDE_FOREGROUND_MESSAGE,
        AutoHideExternalForegroundChanged, 0)
    if AutoHideForegroundCallback
        CallbackFree(AutoHideForegroundCallback)
    AutoHideForegroundCallback := 0
}

AutoHideForegroundWinEvent(hook, event, hwnd, objectId, childId,
    eventThread, eventTime) {
    global AUTO_HIDE_FOREGROUND_MESSAGE
    if hwnd
        DllCall("user32\PostMessageW", "ptr", A_ScriptHwnd,
            "uint", AUTO_HIDE_FOREGROUND_MESSAGE,
            "ptr", hwnd, "ptr", 0, "int")
}

AutoHideExternalForegroundChanged(wParam, lParam, msg, hwnd) {
    global Panel, PanelVisible, WindowMode, WINDOW_MODE_TEMPORARY
    if WindowMode != WINDOW_MODE_TEMPORARY
        || !PanelVisible || !IsObject(Panel)
        return
    foreground := AutoHideForegroundWindow()
    if !foreground || foreground = Panel.Hwnd
        || IsOwnedByPanel(foreground)
        return
    if QuickPreviewSessionOwnsWindow(foreground) {
        StartAutoHideWatchdog()
        return
    }
    CancelUncommittedMainHotkeyGesture()
    CancelFilePointerGesture()
    ; Repair a watchdog that an earlier hide/drag race may have stopped, then
    ; independently queue the decisive foreground check.
    StartAutoHideWatchdog()
    ScheduleAutoHideCheck(30)
}

AutoHideForegroundWindow() {
    return DllCall("user32\GetForegroundWindow", "ptr")
}

PanelActivationChanged(wParam, lParam, msg, hwnd) {
    global Panel, WindowMode
    global WINDOW_MODE_TEMPORARY

    if !IsSet(Panel) || !IsObject(Panel) || hwnd != Panel.Hwnd
        return

    if WindowMode != WINDOW_MODE_TEMPORARY
        return

    activationState := wParam & 0xFFFF

    ; WA_INACTIVE = 0
    if activationState = 0 {
        CancelUncommittedMainHotkeyGesture()
        CancelFilePointerGesture()
        ScheduleAutoHideCheck(150)
    }
}

ScheduleAutoHideCheck(delayMs := 150) {
    global WindowMode, PanelVisible
    global WINDOW_MODE_TEMPORARY

    if WindowMode != WINDOW_MODE_TEMPORARY || !PanelVisible
        return

    SetTimer(TryAutoHidePanel, -Abs(delayMs))
}

CancelAutoHideCheck() {
    SetTimer(TryAutoHidePanel, 0)
}

StartAutoHideWatchdog() {
    SetTimer(AutoHideWatchdog, 100)
}

StopAutoHideWatchdog() {
    SetTimer(AutoHideWatchdog, 0)
}

AutoHideWatchdog() {
    global Panel, PanelVisible, WindowMode, WINDOW_MODE_TEMPORARY
    global CudaTextDragCapture, ActiveDropSession
    if WindowMode != WINDOW_MODE_TEMPORARY
        || !PanelVisible || !IsObject(Panel) {
        StopAutoHideWatchdog()
        return
    }

    ; Never infer OLE completion from mouse-up alone: Windows releases the
    ; button before calling IDropTarget::Drop. Only reap a genuinely abandoned
    ; hover session after its bounded dispatch lease expires.
    buttonsDown := GetKeyState("LButton", "P")
        || GetKeyState("RButton", "P") || GetKeyState("MButton", "P")
    if !buttonsDown {
        if IsObject(CudaTextDragCapture)
            try FinishCudaTextDragCapture(false)
        if IsObject(ActiveDropSession)
            && !IncomingDropProtectsAutoHide()
            try ResetActiveDropSession(true)
    }

    if IncomingDropProtectsAutoHide()
        return

    activeHwnd := AutoHideForegroundWindow()
    if activeHwnd = Panel.Hwnd
        || (activeHwnd && IsOwnedByPanel(activeHwnd))
        return
    if QuickPreviewSessionOwnsWindow(activeHwnd)
        return
    ; This independent path does not rely on WM_ACTIVATE arriving. A short
    ; one-shot delay retains the existing protection for an in-progress click.
    ScheduleAutoHideCheck(60)
}

TryAutoHidePanel() {
    global Panel, PanelVisible, WindowMode, AutoHidePauseDepth
    global WINDOW_MODE_TEMPORARY, QuickViewActive, AutoHidePanelShownTick

    if WindowMode != WINDOW_MODE_TEMPORARY
        return

    if !PanelVisible || !IsObject(Panel)
        return

    if AutoHidePanelShownTick
        && ElapsedTickMilliseconds(AutoHidePanelShownTick, A_TickCount) < 300 {
        ScheduleAutoHideCheck(100)
        return
    }

    if IncomingDropProtectsAutoHide() {
        ScheduleAutoHideCheck(100)
        return
    }

    ; Check actual foreground ownership before consulting pause bookkeeping.
    ; A menu or owned dialog naturally keeps the panel alive without relying
    ; on a fragile counter.
    activeHwnd := AutoHideForegroundWindow()
    if activeHwnd = Panel.Hwnd
        return
    if activeHwnd && IsOwnedByPanel(activeHwnd)
        return

    ; 用户可能正在点击或刚开始拖动，等待物理按键释放
    if GetKeyState("LButton", "P")
        || GetKeyState("RButton", "P")
        || GetKeyState("MButton", "P") {
        ScheduleAutoHideCheck(100)
        return
    }

    ; Only the actual external preview window may retain PopDrop. A stale
    ; QuickViewActive flag must never protect an unrelated foreground app.
    if QuickViewActive && QuickPreviewSessionOwnsWindow(activeHwnd) {
        ScheduleAutoHideCheck(100)
        return
    }
    ; A same-process menu or modal GUI can legitimately own a pause. Once a
    ; different process is truly foreground and mouse buttons are up, the
    ; user's intent to leave PopDrop is authoritative and stale bookkeeping
    ; cannot veto temporary-mode hiding.
    if AutoHidePauseDepth > 0
        && AutoHideForegroundBelongsToCurrentProcess(activeHwnd)
        && AutoHidePauseHasLiveOwner() {
        ScheduleAutoHideCheck(100)
        return
    }
    ; No live modal/drag owner remains: repair a stale counter rather than
    ; allowing it to permanently disable the product's core temporary mode.
    if AutoHidePauseDepth > 0
        AutoHidePauseDepth := 0

    HidePanel()
}

AutoHideForegroundBelongsToCurrentProcess(hwnd) {
    if !hwnd
        return false
    processId := 0
    DllCall("user32\GetWindowThreadProcessId", "ptr", hwnd,
        "uint*", &processId, "uint")
    return processId
        && processId = DllCall("kernel32\GetCurrentProcessId", "uint")
}

AutoHidePauseHasLiveOwner() {
    global SettingsController, SettingsDialog, SourceRemovalDialog
    global ActiveDropSession, CudaTextDragCapture, QuickViewActive
    global ActiveInternalDragContext
    global ContextMenuDispatchActive, SourceMenuDispatchActive
    return AutoHideGuiOwnerAlive(SettingsController)
        || AutoHideGuiOwnerAlive(SettingsDialog)
        || AutoHideGuiOwnerAlive(SourceRemovalDialog)
        || IsObject(ActiveDropSession)
        || IsObject(CudaTextDragCapture)
        || IsObject(ActiveInternalDragContext)
        || ContextMenuDispatchActive || SourceMenuDispatchActive
        || QuickViewActive
}

AutoHideGuiOwnerAlive(value) {
    if !IsObject(value)
        return false
    candidate := HasProp(value, "Gui") ? value.Gui : value
    if !IsObject(candidate) || !HasProp(candidate, "Hwnd")
        return false
    return candidate.Hwnd
        && DllCall("user32\IsWindow", "ptr", candidate.Hwnd, "int")
        && DllCall("user32\IsWindowVisible",
            "ptr", candidate.Hwnd, "int")
}

IsOwnedByPanel(hwnd) {
    global Panel

    if !hwnd || !IsObject(Panel)
        return false

    if hwnd = Panel.Hwnd
        return true

    static GW_OWNER := 4
    current := hwnd

    ; 设置上限，避免异常窗口关系造成无限循环
    Loop 16 {
        current := DllCall(
            "user32\GetWindow",
            "ptr", current,
            "uint", GW_OWNER,
            "ptr"
        )

        if !current
            return false

        if current = Panel.Hwnd
            return true
    }

    return false
}

; ──── 自动隐藏暂停机制 ────

BeginAutoHidePause() {
    global AutoHidePauseDepth

    AutoHidePauseDepth += 1
    CancelAutoHideCheck()
}

EndAutoHidePause() {
    global AutoHidePauseDepth

    AutoHidePauseDepth := Max(0, AutoHidePauseDepth - 1)

    if AutoHidePauseDepth = 0
        ScheduleAutoHideCheck(100)
}

BuildTrayMenu() {
    global ActiveHotkey, APP_VERSION
    if A_IsCompiled {
        TraySetIcon(A_ScriptFullPath, -555, true)
    } else {
        TraySetIcon(A_ScriptDir "\assets\tray.ico", 1, true)
    }
    A_TrayMenu.Delete()
    A_TrayMenu.Add("显示/隐藏面板（" ActiveHotkey "）", TogglePanel)
    A_TrayMenu.Add()
    A_TrayMenu.Add("设置", OpenConfig)
    A_TrayMenu.Add("高级设置", OpenConfigFile)
    A_TrayMenu.Add()
    A_TrayMenu.Add("关于 PopDrop", OpenAboutPopDrop)
    A_TrayMenu.Add()
    A_TrayMenu.Add("退出", RequestExitPopDrop)
    A_TrayMenu.Default := "显示/隐藏面板（" ActiveHotkey "）"
    A_IconTip := "PopDrop v" APP_VERSION
}

RequestExitPopDrop(*) {
    if PrepareExitWithTransfers()
        ExitApp()
}

InstallHotkey(newHotkey) {
    global ActiveHotkey, ConfiguredHotkey, ConfigPath
    if newHotkey = ActiveHotkey
        return

    try Hotkey(newHotkey, HandleMainHotkey, "On")
    catch as err {
        ShowPanelMsgBox("快捷键配置无效：" newHotkey "`n已改用 F2。`n`n" err.Message,
            "PopDrop", "Icon!")
        newHotkey := "F2"
        ConfiguredHotkey := newHotkey
        AtomicConfigSetValue("General", "Hotkey", newHotkey)
        Hotkey(newHotkey, HandleMainHotkey, "On")
    }

    if ActiveHotkey != ""
        try Hotkey(ActiveHotkey, "Off")
    ActiveHotkey := newHotkey
}

HandleMainHotkey(*) {
    global MainHotkeyFirstPressTick, MainHotkeyGestureGeneration
    global MainHotkeyAwaitRelease, MainHotkeyPhysicalKey, ConfiguredHotkey
    global MainHotkeyClosedTick, PanelVisible
    if MainHotkeyAwaitRelease
        return

    ; Suppress keyboard auto-repeat. A held F2 must never be interpreted as a
    ; double press; a new gesture is accepted only after the physical key-up.
    MainHotkeyPhysicalKey := MainHotkeyBaseKey(ConfiguredHotkey)
    if MainHotkeyPhysicalKey != ""
        && GetKeyState(MainHotkeyPhysicalKey, "P") {
        MainHotkeyAwaitRelease := true
        SetTimer(MainHotkeyReleasePoll, 5)
    }

    now := A_TickCount
    ; Gesture routing only exists while the panel is hidden. Once PopDrop is
    ; visible, the main shortcut has one unambiguous job: close it. Suppress a
    ; rapid second press so double-F2 on an open panel cannot reopen or switch.
    if PanelVisible {
        ResetMainHotkeyGesture()
        MainHotkeyClosedTick := now
        HidePanel()
        return
    }
    if MainHotkeyClosedTick {
        sinceClose := ElapsedTickMilliseconds(MainHotkeyClosedTick, now)
        if sinceClose <= 400
            return
        MainHotkeyClosedTick := 0
    }
    tolerance := MainHotkeyDoubleTolerance()
    elapsed := MainHotkeyFirstPressTick
        ? ElapsedTickMilliseconds(MainHotkeyFirstPressTick, now)
        : tolerance + 1
    if MainHotkeyFirstPressTick && elapsed <= tolerance {
        ; The pair has exactly one terminal meaning, independent of the
        ; current workspace and whether the panel is visible or hidden.
        MainHotkeyFirstPressTick := 0
        MainHotkeyGestureGeneration += 1
        RequestMainHotkeyAction("Text")
        return
    }

    MainHotkeyFirstPressTick := now
    MainHotkeyGestureGeneration += 1
    generation := MainHotkeyGestureGeneration
    ; The single action waits only for the rapid-pair window. Once committed,
    ; the gesture is closed before the panel is shown.
    SetTimer(MainHotkeyCommitSingle.Bind(generation), -tolerance)
}

MainHotkeyDoubleTolerance() {
    ; Only a deliberate rapid pair is a double shortcut. Once the single
    ; action is committed and the panel appears, a later F2 starts a fresh
    ; single gesture instead of toggling back to Text.
    return 240
}

MainHotkeyBaseKey(hotkeyName) {
    key := RegExReplace(Trim(hotkeyName), "i)\s+Up$")
    return RegExReplace(key, "^[~*$<>^!+#]+")
}

MainHotkeyReleasePoll() {
    global MainHotkeyAwaitRelease, MainHotkeyPhysicalKey
    if MainHotkeyPhysicalKey != ""
        && GetKeyState(MainHotkeyPhysicalKey, "P")
        return
    MainHotkeyAwaitRelease := false
    SetTimer(MainHotkeyReleasePoll, 0)
}

MainHotkeyCommitSingle(generation) {
    global MainHotkeyGestureGeneration, MainHotkeyFirstPressTick
    global PanelVisible, Panel
    if generation != MainHotkeyGestureGeneration
        || !MainHotkeyFirstPressTick
        return
    ; Commit closes the gesture before any potentially slow UI work begins.
    ; A press after the window appears can therefore never complete this pair.
    MainHotkeyFirstPressTick := 0
    ; When the panel is already active in Files, the committed single action
    ; is already satisfied. Avoid a redundant WinActivate that could race
    ; with the user's next click into another application.
    if PanelVisible && !IsTextWorkspace()
        && WinActive("ahk_id " Panel.Hwnd)
        return
    RequestMainHotkeyAction("Files")
}

CancelUncommittedMainHotkeyGesture() {
    global MainHotkeyFirstPressTick, MainHotkeyGestureGeneration
    if !MainHotkeyFirstPressTick
        return
    MainHotkeyFirstPressTick := 0
    MainHotkeyGestureGeneration += 1
}

RequestMainHotkeyAction(action) {
    global MainHotkeyRequestedAction
    ; Text has priority if the second press arrives while Files is loading.
    if action = "Text" || MainHotkeyRequestedAction = ""
        MainHotkeyRequestedAction := action
    SetTimer(ProcessMainHotkeyAction, -1)
}

ProcessMainHotkeyAction() {
    global MainHotkeyRequestedAction, MainHotkeyActionRunning
    if MainHotkeyActionRunning
        return
    MainHotkeyActionRunning := true
    try {
        Loop 4 {
            action := MainHotkeyRequestedAction
            MainHotkeyRequestedAction := ""
            if action = ""
                break
            PresentMainHotkeyWorkspace(action)
        }
    } finally {
        MainHotkeyActionRunning := false
        if MainHotkeyRequestedAction != ""
            SetTimer(ProcessMainHotkeyAction, -1)
    }
}

PresentMainHotkeyWorkspace(action) {
    global PanelVisible, Panel, DoubleHotkeyWorkspaceId
    if !PanelVisible
        CaptureTextBlockReturnTarget()
    if action = "Text" {
        found := FindWorkspace(DoubleHotkeyWorkspaceId)
        if IsObject(found)
            ActivateWorkspace(found.Value.Id)
        else
            ActivateMainFileWorkspace()
    } else
        ActivateMainFileWorkspace()
    if !PanelVisible
        ShowAndRefresh()
    else {
        try WinRestore("ahk_id " Panel.Hwnd)
        WinActivate("ahk_id " Panel.Hwnd)
    }
}

ResetMainHotkeyGesture(clearRequestedAction := true) {
    global MainHotkeyFirstPressTick, MainHotkeyGestureGeneration
    global MainHotkeyRequestedAction
    MainHotkeyFirstPressTick := 0
    MainHotkeyGestureGeneration += 1
    if clearRequestedAction
        MainHotkeyRequestedAction := ""
}

ActivateMainFileWorkspace() {
    global LastFileWorkspaceId, Workspaces, ActiveWorkspaceId
    targetId := ResolveFileWorkspaceId(
        LastFileWorkspaceId, Workspaces, ActiveWorkspaceId)
    if targetId = ""
        return false
    if StrLower(targetId) = StrLower(ActiveWorkspaceId)
        return true
    return ActivateWorkspace(targetId)
}

InstallWorkspaceHotkeys() {
    global ActiveWorkspaceHotkeys, Workspaces, ConfiguredHotkey
    global WorkspaceHotkeyPressed
    ; Workspace activation reloads config synchronously. Do not tear down and
    ; recreate the hotkey whose callback is still processing this key press.
    if WorkspaceHotkeyPressed.Count {
        SetTimer(InstallWorkspaceHotkeysAfterRelease, -20)
        return
    }
    for hotkeyName, workspaceId in ActiveWorkspaceHotkeys
        try Hotkey(hotkeyName, "Off")
    ActiveWorkspaceHotkeys := Map()
    for workspace in Workspaces {
        hotkeyName := Trim(workspace.Hotkey)
        if hotkeyName = ""
            continue
        if StrLower(hotkeyName) = StrLower(ConfiguredHotkey)
            continue
        try {
            Hotkey(hotkeyName,
                HandleWorkspaceHotkey.Bind(workspace.Id, hotkeyName), "On")
            ActiveWorkspaceHotkeys[hotkeyName] := workspace.Id
        }
    }
}

InstallWorkspaceHotkeysAfterRelease() {
    global WorkspaceHotkeyPressed
    if WorkspaceHotkeyPressed.Count {
        SetTimer(InstallWorkspaceHotkeysAfterRelease, -20)
        return
    }
    InstallWorkspaceHotkeys()
}

HandleWorkspaceHotkey(workspaceId, hotkeyName, *) {
    global WorkspaceHotkeyPressed, WorkspaceHotkeyLastDispatch
    key := StrLower(Trim(hotkeyName))
    baseKey := MainHotkeyBaseKey(hotkeyName)
    now := A_TickCount
    ; Also reject already-queued repeat callbacks which can run just after the
    ; physical key was released and therefore no longer satisfy GetKeyState.
    if WorkspaceHotkeyLastDispatch.Has(key)
        && ElapsedTickMilliseconds(
            WorkspaceHotkeyLastDispatch[key], now) < 350
        return
    if baseKey != "" && GetKeyState(baseKey, "P") {
        ; Auto-repeat and callbacks queued before InstallWorkspaceHotkeys()
        ; rebinds the current hotkey belong to the same physical press.
        if WorkspaceHotkeyPressed.Has(key)
            return
        WorkspaceHotkeyPressed[key] := baseKey
        SetTimer(WorkspaceHotkeyReleasePoll, 10)
    }
    WorkspaceHotkeyLastDispatch[key] := now
    ShowWorkspaceByHotkey(workspaceId)
}

WorkspaceHotkeyReleasePoll() {
    global WorkspaceHotkeyPressed
    released := []
    for hotkeyName, baseKey in WorkspaceHotkeyPressed {
        if !GetKeyState(baseKey, "P")
            released.Push(hotkeyName)
    }
    for hotkeyName in released
        WorkspaceHotkeyPressed.Delete(hotkeyName)
    if !WorkspaceHotkeyPressed.Count
        SetTimer(WorkspaceHotkeyReleasePoll, 0)
}

ShowWorkspaceByHotkey(workspaceId, *) {
    global PanelVisible, ActiveWorkspaceId, Panel
    ResetMainHotkeyGesture()
    if !PanelVisible
        CaptureTextBlockReturnTarget()
    if StrLower(workspaceId) != StrLower(ActiveWorkspaceId)
        ActivateWorkspace(workspaceId)
    if !PanelVisible
        ShowAndRefresh()
    else {
        WinActivate("ahk_id " Panel.Hwnd)
        if IsTextWorkspace()
            RestoreTextBlockSearchFocus()
    }
}

TogglePanel(*) {
    global PanelVisible, Panel, WindowMode
    global WINDOW_MODE_NORMAL

    if !PanelVisible {
        ShowAndRefresh()
        return
    }

    ; 普通窗口模式：面板被覆盖或最小化时，第一次按快捷键应恢复并带到前台
    if WindowMode = WINDOW_MODE_NORMAL
        && !WinActive("ahk_id " Panel.Hwnd) {
        try WinRestore("ahk_id " Panel.Hwnd)
        WinActivate("ahk_id " Panel.Hwnd)
        return
    }

    HidePanel()
}

ShowAndRefresh(*) {
    global Panel, PanelVisible, ConfiguredHotkey, ActiveHotkey, WindowWidth, WindowHeight
    global ScanResultLoaded, StatusKind, AutoHidePanelShownTick
    global WindowMode, WINDOW_MODE_TEMPORARY, AutoHidePauseDepth
    global AutoHideNativeShownTick
    PreviewBeginPanelSession()
    LoadSettings()
    InstallWorkspaceHotkeys()
    ApplyWindowMode()
    if ConfiguredHotkey != ActiveHotkey {
        InstallHotkey(ConfiguredHotkey)
        BuildTrayMenu()
    }
    AutoHideNativeShownTick := A_TickCount
    Panel.Show("w" WindowWidth " h" WindowHeight)
    PanelVisible := true
    ; A hidden panel has no legitimate modal/menu pause owner. Begin every
    ; visible session clean so no previous session can poison later summons.
    AutoHidePauseDepth := 0
    AutoHidePanelShownTick := A_TickCount
    if WindowMode = WINDOW_MODE_TEMPORARY
        StartAutoHideWatchdog()
    WinActivate("ahk_id " Panel.Hwnd)

    if !ScanResultLoaded
        LoadDiskScanCache()
    if !IsPanelRenderCurrent()
        PopulatePanel()
    if !IsRecentRenderCurrent()
        PopulateRecentSidebar()
    ; 清除 ListView 添加过程中可能因自动选中触发的文件路径更新
    SetTimer(UpdateSelectionStatus, 0)
    if ScanResultLoaded && !WorkerRunning {
        StatusKind := "default"
        StatusText.Text := "已是最新"
    }
    UpdateWindowModeButton()
    CheckRefreshPolicyOnShow()
    RestoreTextBlockSearchFocus()
}

ApplyWindowIcon() {
    global Panel, PanelIconHandle
    ; 编译版已经使用 Ahk2Exe 嵌入的主图标。源码模式只加载一次 .ico；
    ; 旧实现每次刷新都重新 LoadImage，造成图标句柄泄漏。
    if A_IsCompiled || PanelIconHandle
        return
    iconPath := A_ScriptDir "\assets\app.ico"
    if !FileExist(iconPath)
        return
    hIcon := DllCall("LoadImageW", "ptr", 0, "str", iconPath,
        "uint", 1, "int", 0, "int", 0, "uint", 0x10, "ptr") ; IMAGE_ICON, LR_LOADFROMFILE
    if hIcon {
        PanelIconHandle := hIcon
        ; The GUI is still hidden here. AutoHotkey's SendMessage window lookup
        ; ignores hidden windows by default, so address the HWND directly.
        DllCall("user32\SendMessageW", "ptr", Panel.Hwnd,
            "uint", 0x80, "ptr", 0, "ptr", hIcon, "ptr") ; WM_SETICON, ICON_SMALL
        DllCall("user32\SendMessageW", "ptr", Panel.Hwnd,
            "uint", 0x80, "ptr", 1, "ptr", hIcon, "ptr") ; WM_SETICON, ICON_BIG
    }
}

RefreshPanel(*) {
    global ShowRecentSidebar
    StartBackgroundScan(0, "manual", ShowRecentSidebar)
}

HidePanel(*) {
    global Panel, PanelVisible, SourceRemovalDialog, AutoHidePauseDepth
    if AutoHideGuiOwnerAlive(SourceRemovalDialog) {
        try WinActivate("ahk_id " SourceRemovalDialog.Hwnd)
        return
    }
    ; A failed/destroyed confirmation callback must not permanently turn the
    ; panel into an unhideable topmost window.
    if IsObject(SourceRemovalDialog)
        SourceRemovalDialog := 0
    CancelFilePointerGesture()
    CloseExternalQuickPreview(true, false)
    PreviewPanelHidden()
    CancelAutoHideCheck()
    StopAutoHideWatchdog()
    ResetActiveDropSession(true)
    Panel.Hide()
    PanelVisible := false
    AutoHidePauseDepth := 0
    ClearTextBlockSearch(false)
    RunPendingConsistencyCheckAfterHide()
}

HandlePanelClose(*) {
    HidePanel()
    return true
}

HandlePanelEscape(*) {
    global EscapeHidesPanel
    if CloseExternalQuickPreview()
        return true
    if ClearTextBlockSearch()
        return true
    if EscapeHidesPanel
        HidePanel()
    return true
}

ResizePanel(guiObj, minMax, width, height) {
    global FileView, RecentLabel, RecentView, StatusText, ItemCountText
    global TransferStatusText
    global ShowRecentSidebar, PanelLayoutWidth
    global PANEL_TOOLBAR_HEIGHT, PANEL_FOOTER_HEIGHT
    if minMax = -1
        return
    PreviewSuppress("resize", true)
    PanelLayoutWidth := width
    ResizeFolderDropControls(width)
    ; Reserve exactly 42 DIPs at each edge. The list owns every DIP between
    ; those bands, which keeps the file-manager content area as large as
    ; possible without making either control band feel cramped.
    contentHeight := Max(160,
        height - PANEL_TOOLBAR_HEIGHT - PANEL_FOOTER_HEIGHT)
    if ShowRecentSidebar {
        sidebarWidth := Min(280, Max(190, Floor(width * 0.28)))
        mainWidth := Max(280, width - sidebarWidth - 36)
        sidebarX := 24 + mainWidth
        FileView.Move(12, PANEL_TOOLBAR_HEIGHT, mainWidth, contentHeight)
        RecentLabel.Move(sidebarX, PANEL_TOOLBAR_HEIGHT, sidebarWidth, 22)
        RecentView.Move(sidebarX, PANEL_TOOLBAR_HEIGHT + 26,
            sidebarWidth, Max(154, contentHeight - 26))
        RecentView.ModifyCol(1, Max(120, sidebarWidth - 8))
        RecentLabel.Visible := true
        RecentView.Visible := true
    } else {
        FileView.Move(12, PANEL_TOOLBAR_HEIGHT,
            Max(200, width - 24), contentHeight)
        RecentLabel.Visible := false
        RecentView.Visible := false
    }
    ; Keep the transfer affordance compact so long selected paths get most of
    ; the footer. Both controls occupy the same 42-DIP band and start at the
    ; same Y coordinate. Their shared owner-draw path centers a two-line text
    ; block and uses DT_EDITCONTROL to suppress a partially visible third line.
    transferWidth := Min(220, Max(140, Floor(width * 0.22)))
    statusWidth := Max(100, width - transferWidth - 32)
    footerTop := height - PANEL_FOOTER_HEIGHT
    countWidth := 112
    stateWidth := Max(100, statusWidth - countWidth - 8)
    StatusText.Move(12, footerTop, stateWidth, PANEL_FOOTER_HEIGHT)
    ItemCountText.Move(20 + stateWidth, footerTop, countWidth,
        PANEL_FOOTER_HEIGHT)
    TransferStatusText.Move(20 + statusWidth, footerTop,
        transferWidth, PANEL_FOOTER_HEIGHT)
}

ResizeFolderDropControls(width) {
    global FolderDropAddSourceButton, FolderDropPinnedButton
    if !IsObject(FolderDropAddSourceButton)
        return
    if IsTextWorkspace() {
        FolderDropAddSourceButton.Move(12, 4, Max(160, width - 24), 36)
        return
    }
    gap := 8
    available := Max(300, width - 24 - gap)
    primaryWidth := Floor(available * 0.7)
    secondaryWidth := available - primaryWidth
    FolderDropAddSourceButton.Move(12, 4, primaryWidth, 36)
    FolderDropPinnedButton.Move(
        12 + primaryWidth + gap, 4, secondaryWidth, 36)
}

ShowFolderDropMode() {
    global ToolbarControls, FolderDropAddSourceButton, FolderDropPinnedButton
    global FolderDropUiVisible, ActiveWorkspaceName, PanelLayoutWidth
    if !IsObject(FolderDropAddSourceButton)
        return
    FolderDropAddSourceButton.Text := "＋ 添加为来源`n当前工作区："
        . ActiveWorkspaceName
    FolderDropPinnedButton.Text := "☆ 加入固定项`n不会移动文件夹"
    ResizeFolderDropControls(PanelLayoutWidth)
    if FolderDropUiVisible
        return
    for control in ToolbarControls
        control.Visible := false
    FolderDropAddSourceButton.Visible := true
    FolderDropPinnedButton.Visible := !IsTextWorkspace()
    FolderDropUiVisible := true
}

HideFolderDropMode() {
    global ToolbarControls, FolderDropAddSourceButton, FolderDropPinnedButton
    global FolderDropUiVisible
    SetAddSourceDropHover(false)
    SetPinnedDropHover(false)
    if IsObject(FolderDropAddSourceButton)
        FolderDropAddSourceButton.Visible := false
    if IsObject(FolderDropPinnedButton)
        FolderDropPinnedButton.Visible := false
    for control in ToolbarControls
        control.Visible := true
    UpdateWorkspaceTypeUi()
    FolderDropUiVisible := false
}

RequestNativeLayout() {
    global Panel
    ; Gui.OnEvent("Size") receives DPI-adjusted coordinates only when AHK
    ; dispatches a real WM_SIZE.  Calling ResizePanel directly bypasses that
    ; conversion and makes controls too wide on high-DPI displays.
    clientRect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", Panel.Hwnd, "ptr", clientRect.Ptr)
        return
    clientWidth := NumGet(clientRect, 8, "int") - NumGet(clientRect, 0, "int")
    clientHeight := NumGet(clientRect, 12, "int") - NumGet(clientRect, 4, "int")
    packedSize := (clientWidth & 0xFFFF) | ((clientHeight & 0xFFFF) << 16)
    DllCall("user32\PostMessageW", "ptr", Panel.Hwnd, "uint", 0x0005,
        "uptr", 0, "uptr", packedSize) ; WM_SIZE
}

BuildDisplayMenu() {
    global DisplayMenu
    DisplayMenu := Menu()
    DisplayMenu.Add("缩略图", SetDisplayViewFromMenu.Bind("Thumbnail"), "Radio")
    DisplayMenu.Add("列表", SetDisplayViewFromMenu.Bind("List"), "Radio")
    DisplayMenu.Add()
    DisplayMenu.Add("文件预览", ToggleFilePreviewFromMenu)
    DisplayMenu.Add("近期栏", ToggleRecentSidebarFromMenu)
}

SetMenuChecked(menuObj, itemName, isChecked) {
    if isChecked
        menuObj.Check(itemName)
    else
        menuObj.Uncheck(itemName)
}

SyncDisplayMenuState() {
    global DisplayMenu, ViewMode, PreviewEnabled, ShowRecentSidebar
    if !IsObject(DisplayMenu)
        return
    SetMenuChecked(DisplayMenu, "缩略图", ViewMode = "Thumbnail")
    SetMenuChecked(DisplayMenu, "列表", ViewMode = "List")
    SetMenuChecked(DisplayMenu, "文件预览", PreviewEnabled)
    SetMenuChecked(DisplayMenu, "近期栏", ShowRecentSidebar)
}

ShowDisplayMenu(*) {
    global DisplayButton, DisplayMenu
    if !IsObject(DisplayButton) || !IsObject(DisplayMenu)
        return

    SyncDisplayMenuState()
    buttonRect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", DisplayButton.Hwnd,
        "ptr", buttonRect.Ptr)
        return
    menuX := NumGet(buttonRect, 0, "int")
    menuY := NumGet(buttonRect, 12, "int")
    previousMenuCoordMode := A_CoordModeMenu
    BeginAutoHidePause()
    PreviewSuppress("display-menu", false)
    try {
        ; GetWindowRect and Menu Screen coordinates are both physical screen
        ; pixels in this per-monitor-DPI-aware process. Using client values
        ; here would make AutoHotkey scale the horizontal offset a second time.
        CoordMode("Menu", "Screen")
        ; Native menus automatically keep themselves inside the active
        ; monitor's work area, including negative-coordinate monitors.
        DisplayMenu.Show(menuX, menuY)
    } catch as err {
        ShowPanelMsgBox(
            "无法打开显示菜单：`n" err.Message,
            "显示菜单",
            "Iconx"
        )
    } finally {
        CoordMode("Menu", previousMenuCoordMode)
        PreviewRecoverAfterInteraction()
        EndAutoHidePause()
    }
}

SetDisplayViewFromMenu(mode, *) {
    try SetViewMode(mode)
    catch as err
        ShowPanelMsgBox("无法切换视图：`n" err.Message, "显示菜单", "Iconx")
}

ToggleFilePreviewFromMenu(*) {
    global PreviewEnabled
    try SetFilePreviewEnabled(!PreviewEnabled)
    catch as err
        ShowPanelMsgBox("无法切换文件预览：`n" err.Message, "显示菜单", "Iconx")
}

ToggleRecentSidebarFromMenu(*) {
    global ShowRecentSidebar
    try SetRecentSidebarVisible(!ShowRecentSidebar)
    catch as err
        ShowPanelMsgBox("无法切换近期栏：`n" err.Message, "显示菜单", "Iconx")
}

SetViewMode(mode, persist := true) {
    global ViewMode, FileView
    normalized := StrLower(Trim(mode)) = "list" ? "List" : "Thumbnail"
    if normalized = ViewMode
        return false

    previous := ViewMode
    if persist
        AtomicConfigSetValue("General", "ViewMode", normalized)
    try {
        PreviewSuppress("view", true)
        ViewMode := normalized
        if IsObject(FileView)
            ApplyViewMode()
    } catch {
        ViewMode := previous
        if persist
            try AtomicConfigSetValue("General", "ViewMode", previous)
        if IsObject(FileView)
            try ApplyViewMode()
        throw
    }
    return true
}

SetFilePreviewEnabled(enabled, persist := true) {
    global PreviewEnabled
    enabled := !!enabled
    if enabled = PreviewEnabled
        return false

    previous := PreviewEnabled
    if persist
        AtomicConfigSetValue("Preview", "Enabled", enabled ? "1" : "0")
    try {
        PreviewEnabled := enabled
        ; This is the existing central shutdown/restart path. Disabling
        ; invalidates the generation, cancels pending work and hides the GUI.
        PreviewSettingsChanged()
    } catch {
        PreviewEnabled := previous
        if persist
            try AtomicConfigSetValue("Preview", "Enabled", previous ? "1" : "0")
        try PreviewSettingsChanged()
        throw
    }
    try SyncSettingsDisplayStateFromRuntime()
    return true
}

SetRecentSidebarVisible(enabled, persist := true) {
    global ShowRecentSidebar, RecentView, Panel
    enabled := !!enabled
    if enabled = ShowRecentSidebar
        return false

    previous := ShowRecentSidebar
    if persist
        AtomicConfigSetValue("General", "ShowRecentSidebar", enabled ? "1" : "0")
    try {
        PreviewSuppress("recent", true)
        ShowRecentSidebar := enabled
        if enabled && IsObject(RecentView)
            PopulateRecentSidebar()
        if IsObject(Panel)
            RequestNativeLayout()
    } catch {
        ShowRecentSidebar := previous
        if persist
            try AtomicConfigSetValue("General", "ShowRecentSidebar",
                previous ? "1" : "0")
        if previous && IsObject(RecentView)
            try PopulateRecentSidebar()
        if IsObject(Panel)
            try RequestNativeLayout()
        throw
    }
    try SyncSettingsDisplayStateFromRuntime()
    if persist {
        ReconcileSourceWatchers(true)
        if enabled
            StartBackgroundScan(Map(), "recent-toggle", true)
    }
    return true
}

ToggleWindowMode(*) {
    global WindowMode
    global WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY

    previousMode := WindowMode
    WindowMode := WindowMode = WINDOW_MODE_ALWAYS_ON_TOP
        ? WINDOW_MODE_TEMPORARY
        : WINDOW_MODE_ALWAYS_ON_TOP

    try AtomicConfigSetValue("General", "WindowMode", WindowMode)
    catch as err {
        WindowMode := previousMode
        ShowPanelMsgBox(
            "无法保存窗口模式：`n" err.Message,
            "切换置顶模式失败",
            "Iconx"
        )
        return
    }

    ApplyWindowMode()
    UpdateWindowModeButton()
}

UpdateWindowModeButton() {
    global WindowModeButton
    global WindowMode, WINDOW_MODE_ALWAYS_ON_TOP
    if IsObject(WindowModeButton)
        WindowModeButton.Text := WindowMode = WINDOW_MODE_ALWAYS_ON_TOP
            ? "置顶：开"
            : "置顶：关"
}

ApplyViewMode() {
    global FileView, ViewMode
    if IsTextWorkspace() {
        ApplyTextBlockCardView()
        return
    }
    if ViewMode = "List" {
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x108E,
            "ptr", 1, "ptr", 0, "ptr") ; LVM_SETVIEW, LV_VIEW_DETAILS
        FileView.ModifyCol(1, 360)
        FileView.ModifyCol(2, 132)
        ApplyFileViewLabels(false)
    } else {
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x108E,
            "ptr", 0, "ptr", 0, "ptr") ; LVM_SETVIEW, LV_VIEW_ICON
        ApplyThumbnailLayout()
        ApplyFileViewLabels(true)
    }
}

ApplyThumbnailLayout() {
    global FileView, ThumbnailSize, ThumbnailHorizontalGap, ThumbnailVerticalGap
    global ThumbnailTextLines

    ; LVM_SETICONSPACING expects the distance from one icon origin to the next,
    ; not the amount of blank space. Reserve the configured number of label
    ; lines separately so a small gap cannot clip or distort square images.
    ; LVS_NOLABELWRAP makes the one-line setting control actual label wrapping,
    ; instead of merely reducing the reserved height and clipping line two.
    FileView.Opt(ThumbnailTextLines = 1 ? "+0x80" : "-0x80")
    horizontalSpacing := ThumbnailSize + ThumbnailHorizontalGap
    verticalSpacing := ThumbnailSize + GetThumbnailLabelReserve()
        + ThumbnailVerticalGap
    horizontalSpacing := Max(4, Min(horizontalSpacing, 0xFFFF))
    verticalSpacing := Max(4, Min(verticalSpacing, 0xFFFF))
    packedSpacing := (horizontalSpacing & 0xFFFF)
        | ((verticalSpacing & 0xFFFF) << 16)

    FileView.ModifyCol(1, horizontalSpacing)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1035,
        "ptr", 0, "ptr", packedSpacing, "ptr") ; LVM_SETICONSPACING
}

GetThumbnailLabelReserve() {
    global FileView, ThumbnailTextLines

    ; Use the ListView's real font metrics so the safety reserve also follows
    ; Windows DPI/font scaling. The fallback matches the 9 pt UI font.
    lineHeight := 20
    hdc := DllCall("user32\GetDC", "ptr", FileView.Hwnd, "ptr")
    if hdc {
        hFont := DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
            "uint", 0x31, "ptr", 0, "ptr", 0, "ptr") ; WM_GETFONT
        oldFont := hFont
            ? DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", hFont, "ptr")
            : 0
        metrics := Buffer(64, 0)
        if DllCall("gdi32\GetTextMetricsW", "ptr", hdc, "ptr", metrics.Ptr, "int")
            lineHeight := Max(1, NumGet(metrics, 0, "int")
                + NumGet(metrics, 16, "int"))
        if oldFont
            DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldFont, "ptr")
        DllCall("user32\ReleaseDC", "ptr", FileView.Hwnd, "ptr", hdc)
    }
    return lineHeight * ThumbnailTextLines + Max(8, Round(lineHeight * 0.4))
}

ApplyFileViewLabels(thumbnailMode) {
    global FileView, ItemLabels, ThumbnailTextLines

    shortenLabels := thumbnailMode && ThumbnailTextLines = 1
    hdc := 0
    oldFont := 0
    if shortenLabels {
        hdc := DllCall("user32\GetDC", "ptr", FileView.Hwnd, "ptr")
        if hdc {
            hFont := DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
                "uint", 0x31, "ptr", 0, "ptr", 0, "ptr") ; WM_GETFONT
            if hFont
                oldFont := DllCall("gdi32\SelectObject",
                    "ptr", hdc, "ptr", hFont, "ptr")
        }
    }

    try {
        for row, fullLabel in ItemLabels {
            visibleLabel := shortenLabels
                ? FitThumbnailLabel(fullLabel, hdc)
                : fullLabel
            FileView.Modify(row, "", visibleLabel)
        }
    } finally {
        if hdc {
            if oldFont
                DllCall("gdi32\SelectObject",
                    "ptr", hdc, "ptr", oldFont, "ptr")
            DllCall("user32\ReleaseDC", "ptr", FileView.Hwnd, "ptr", hdc)
        }
    }
}

FitThumbnailLabel(label, hdc) {
    global ThumbnailSize

    ; Native icon labels add a small horizontal margin around the measured
    ; text. Leave six pixels on each side so the complete painted label stays
    ; within the square thumbnail width and cannot touch a neighbouring item.
    maxTextWidth := Max(8, ThumbnailSize - 12)
    measuredWidth := MeasureListViewText(label, hdc)
    if measuredWidth >= 0 && measuredWidth <= maxTextWidth
        return label

    ellipsis := "…"
    ellipsisWidth := MeasureListViewText(ellipsis, hdc)
    if measuredWidth < 0 || ellipsisWidth < 0 {
        ; GetDC is expected to succeed for a live ListView. Keep a conservative
        ; fallback for unusual themes or teardown timing.
        fallbackLength := Max(1, Floor(maxTextWidth / 14))
        return StrLen(label) <= fallbackLength
            ? label
            : SubStr(label, 1, Max(0, fallbackLength - 1)) ellipsis
    }
    if ellipsisWidth > maxTextWidth
        return ellipsis

    low := 0
    high := StrLen(label)
    while low < high {
        middle := Ceil((low + high) / 2)
        candidate := SubStr(label, 1, middle) ellipsis
        if MeasureListViewText(candidate, hdc) <= maxTextWidth
            low := middle
        else
            high := middle - 1
    }
    return SubStr(label, 1, low) ellipsis
}

MeasureListViewText(text, hdc) {
    if !hdc
        return -1
    size := Buffer(8, 0)
    if !DllCall("gdi32\GetTextExtentPoint32W", "ptr", hdc, "wstr", text,
        "int", StrLen(text), "ptr", size.Ptr, "int")
        return -1
    return NumGet(size, 0, "int")
}
