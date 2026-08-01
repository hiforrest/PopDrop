; Main panel construction, layout, display modes and window behavior.

BuildPanel() {
    global Panel, FileView, RecentLabel, RecentView
    global DisplayButton, WindowModeButton, PinnedDropButton, StatusText
    global TransferStatusText
    global APP_VERSION, WorkspaceSelector
    global ToolbarControls, FolderDropAddSourceButton, FolderDropPinnedButton

    Panel := Gui("+Resize +MinSize760x380", "PopDrop v" APP_VERSION)
    Panel.MarginX := 12
    ; The toolbar is a fixed 42-DIP band. Keep the tuned control row one DIP
    ; below the previous centered position, without changing the list boundary.
    Panel.MarginY := 7
    Panel.SetFont("s9", "Microsoft YaHei UI")

    workspaceLabel := Panel.AddText("xm ym+6 w52 h22 +0x200", "工作区：")
    WorkspaceSelector := AddUiDropDownList(Panel, "x+2 yp-5 w110", [])
    OffsetGuiControlYPhysical(workspaceLabel, -4)
    WorkspaceSelector.OnEvent("Change", MainWorkspaceChanged)
    refreshButton := AddUiButton(Panel, "x+6 yp w52", "刷新")
    refreshButton.OnEvent("Click", RefreshPanel)
    PinnedDropButton := AddUiButton(Panel, "x+4 yp w70", "＋固定项")
    PinnedDropButton.OnEvent("Click", AddPinnedFiles)
    removePinnedButton := AddUiButton(Panel, "x+4 yp w70", "－固定项")
    removePinnedButton.OnEvent("Click", RemovePinnedFile)
    DisplayButton := AddUiButton(Panel, "x+4 yp w72", "显示 ▾")
    DisplayButton.OnEvent("Click", ShowDisplayMenu)
    BuildDisplayMenu()
    settingsButton := AddUiButton(Panel, "x+4 yp w52", "设置")
    settingsButton.OnEvent("Click", OpenConfig)
    WindowModeButton := AddUiButton(Panel, "x+4 yp w72", "置顶：关")
    WindowModeButton.OnEvent("Click", ToggleWindowMode)
    closeButton := AddUiButton(Panel, "x+4 yp w48", "关闭")
    closeButton.OnEvent("Click", HidePanel)
    ToolbarControls := [workspaceLabel, WorkspaceSelector, refreshButton,
        PinnedDropButton, removePinnedButton, DisplayButton,
        settingsButton, WindowModeButton, closeButton]

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

    StatusText := Panel.AddText("xm y+0 w500 h42 +0xD +0x100", "就绪")
    StatusText.OnEvent("Click", HandleStatusAction)
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
}

MainWorkspaceChanged(control, *) {
    global WorkspaceSelectorIds, ActiveWorkspaceId
    index := control.Value
    if index < 1 || index > WorkspaceSelectorIds.Length
        return
    targetId := WorkspaceSelectorIds[index]
    if StrLower(targetId) = StrLower(ActiveWorkspaceId)
        return
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
    global ActiveWorkspaceId, PanelVisible, StatusKind
    found := FindWorkspace(workspaceId)
    if !IsObject(found)
        return false
    if StrLower(workspaceId) = StrLower(ActiveWorkspaceId) {
        SyncWorkspaceControls()
        return true
    }
    try AtomicConfigSetValue("Workspaces", "Active", workspaceId, 3)
    catch as err {
        ShowPanelMsgBox("无法切换工作区：`n" err.Message,
            "工作区切换失败", "Iconx")
        return false
    }
    PreviewSuppress("workspace", false)
    LoadSettings()
    StatusKind := "default"
    PopulatePanel()
    PopulateRecentSidebar()
    StartBackgroundScan()
    return true
}

ApplyWindowMode() {
    global Panel, WindowMode
    global WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY, WINDOW_MODE_NORMAL

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

    if WindowMode != WINDOW_MODE_TEMPORARY
        CancelAutoHideCheck()
}

; ──── 临时面板自动隐藏 ────

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

TryAutoHidePanel() {
    global Panel, PanelVisible, WindowMode, AutoHidePauseDepth
    global WINDOW_MODE_TEMPORARY, QuickViewActive

    if WindowMode != WINDOW_MODE_TEMPORARY
        return

    if !PanelVisible || !IsObject(Panel)
        return

    if AutoHidePauseDepth > 0
        return
    if QuickViewActive
        return

    ; 焦点已经回到主面板
    if WinActive("ahk_id " Panel.Hwnd)
        return

    activeHwnd := WinExist("A")

    ; 当前活动窗口是主面板自己的从属弹窗
    if activeHwnd && IsOwnedByPanel(activeHwnd)
        return

    ; 用户可能正在点击或刚开始拖动，等待物理按键释放
    if GetKeyState("LButton", "P")
        || GetKeyState("RButton", "P")
        || GetKeyState("MButton", "P") {
        ScheduleAutoHideCheck(100)
        return
    }

    HidePanel()
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

    try Hotkey(newHotkey, TogglePanel, "On")
    catch as err {
        ShowPanelMsgBox("快捷键配置无效：" newHotkey "`n已改用 F2。`n`n" err.Message,
            "PopDrop", "Icon!")
        newHotkey := "F2"
        ConfiguredHotkey := newHotkey
        AtomicConfigSetValue("General", "Hotkey", newHotkey)
        Hotkey(newHotkey, TogglePanel, "On")
    }

    if ActiveHotkey != ""
        try Hotkey(ActiveHotkey, "Off")
    ActiveHotkey := newHotkey
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
    global ScanResultLoaded, StatusKind
    PreviewBeginPanelSession()
    LoadSettings()
    ApplyWindowMode()
    if ConfiguredHotkey != ActiveHotkey {
        InstallHotkey(ConfiguredHotkey)
        BuildTrayMenu()
    }
    Panel.Show("w" WindowWidth " h" WindowHeight)
    PanelVisible := true
    WinActivate("ahk_id " Panel.Hwnd)

    if !ScanResultLoaded
        LoadDiskScanCache()
    StatusKind := "default"
    PopulatePanel()
    PopulateRecentSidebar()
    ; 清除 ListView 添加过程中可能因自动选中触发的文件路径更新
    SetTimer(UpdateSelectionStatus, 0)
    StatusKind := "default"
    StatusText.Text := "正在加载…"
    UpdateWindowModeButton()
    StartBackgroundScan()
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
    ShowAndRefresh()
}

HidePanel(*) {
    global Panel, PanelVisible, SourceRemovalDialog
    if IsObject(SourceRemovalDialog) {
        try WinActivate("ahk_id " SourceRemovalDialog.Hwnd)
        return
    }
    CancelFilePointerGesture()
    CloseExternalQuickPreview()
    PreviewPanelHidden()
    CancelAutoHideCheck()
    ResetActiveDropSession(true)
    Panel.Hide()
    PanelVisible := false
}

HandlePanelClose(*) {
    HidePanel()
    return true
}

HandlePanelEscape(*) {
    global EscapeHidesPanel
    if CloseExternalQuickPreview()
        return true
    if EscapeHidesPanel
        HidePanel()
    return true
}

ResizePanel(guiObj, minMax, width, height) {
    global FileView, RecentLabel, RecentView, StatusText, TransferStatusText
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
    StatusText.Move(12, footerTop, statusWidth, PANEL_FOOTER_HEIGHT)
    TransferStatusText.Move(20 + statusWidth, footerTop,
        transferWidth, PANEL_FOOTER_HEIGHT)
}

ResizeFolderDropControls(width) {
    global FolderDropAddSourceButton, FolderDropPinnedButton
    if !IsObject(FolderDropAddSourceButton)
        return
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
    FolderDropPinnedButton.Visible := true
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
