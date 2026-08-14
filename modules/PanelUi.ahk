; Main panel construction, layout, display modes and window behavior.

BuildPanel() {
    global Panel, FileView, RecentLabel, RecentView
    global DisplayButton, WindowModeButton, PinnedDropButton, StatusText
    global ItemCountText
    global ClipboardPinnedButton, RefreshButton, RemovePinnedButton
    global ExpandAllFoldersButton, CollapseAllFoldersButton
    global SettingsButton, TextBlockSearchFrame, TextBlockSearchEdit
    global TextBlockSearchTitleOnlyCheck
    global TransferStatusText
    global APP_VERSION, WorkspaceTabs, WorkspaceMoreButton
    global WorkspaceBottomRule
    global UiScaleFactor, PanelUiScaleFactor
    global PANEL_TAB_HEIGHT_PX, PANEL_TAB_FONT_PX
    global PANEL_TAB_PADDING_X_PX, PANEL_TAB_PADDING_Y_PX
    global FolderDropAddSourceButton, FolderDropPinnedZone
    global ToolbarSeparators

    PanelUiScaleFactor := UiScaleFactor
    Panel := Gui("+Resize +MinSize" PanelScale(660) "x" PanelScale(380),
        "PopDrop v" APP_VERSION)
    Panel.MarginX := PanelScale(12)
    ; The toolbar is a fixed 42-DIP band. Keep the tuned control row one DIP
    ; below the previous centered position, without changing the list boundary.
    Panel.MarginY := PanelScale(7)
    Panel.SetFont("s" Round(9 * UiScaleFactor), "Microsoft YaHei UI")

    ; Navigation owns the top row. The native tab strip preserves keyboard
    ; focus and Windows theming; at most eight workspaces are materialized.
    tabHeight := PanelPixelsToGui(PANEL_TAB_HEIGHT_PX, Panel.Hwnd)
    WorkspaceTabs := Panel.AddTab3(
        "xm ym w" PanelScale(620) " h" tabHeight " -Wrap", [""])
    ; AHK's sNN uses points, not pixels. 14 px at 96 DPI equals 10.5 pt.
    tabPointSize := PANEL_TAB_FONT_PX * 72.0 / 96.0
    WorkspaceTabs.SetFont("s" tabPointSize, "Microsoft YaHei UI")
    ApplyWorkspaceTabPadding()
    EnableWorkspaceTabItemPadding()
    WorkspaceTabs.OnEvent("Change", MainWorkspaceChanged)
    WorkspaceTabs.UseTab()
    WorkspaceMoreButton := AddUiButton(Panel,
        ScalePanelGuiOptions("x640 ym+1 w82"), "更多 ▾",
        PanelUiScaleFactor)
    WorkspaceMoreButton.OnEvent("Click", ShowWorkspaceMoreMenu)

    ; The action rail is intentionally separate from the content ListView so
    ; its hover surface can never cover the native vertical scrollbar.
    RefreshButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-refresh.png", "刷新当前工作区内容", RefreshPanel)
    ExpandAllFoldersButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-expansion.png",
        "展开当前工作区的全部文件夹", ExpandAllFolderGroups)
    CollapseAllFoldersButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-collapse.png",
        "收起当前工作区的全部文件夹（固定项除外）",
        CollapseAllFolderGroups)
    ClipboardPinnedButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-paste.png",
        "将剪贴板文本添加到固定项（文本块工作区）",
        AddClipboardTextToPinned, "",
        "assets\toolbar\btn-paste-gray.png")
    PinnedDropButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-add.png", "添加固定项", AddPinnedFiles)
    RemovePinnedButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-remove.png", "移除所选固定项",
        RemovePinnedFile)
    DisplayButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-eye.png", "显示方式与预览选项",
        ShowDisplayMenu)
    BuildDisplayMenu()
    SettingsButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-setting.png", "打开设置", OpenConfig)
    WindowModeButton := AddPanelIconButton(Panel,
        "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h" PanelPixelsToGui(64, Panel.Hwnd),
        "assets\toolbar\btn-pin-off.png", "窗口置顶：关",
        ToggleWindowMode, "assets\toolbar\btn-pin-on.png")
    ToolbarSeparators := []
    Loop 6
        ToolbarSeparators.Push(AddPanelDashedSeparator(Panel,
            "x0 y0 w" PanelPixelsToGui(64, Panel.Hwnd) " h1"))
    ; Search is a composite field: the border belongs to the full band while
    ; the borderless Edit is physically narrower than the title-only area.
    ; Long input, the caret and selection therefore cannot run under the
    ; checkbox at any DPI or panel width.
    TextBlockSearchFrame := Panel.AddText(
        ScalePanelGuiOptions("x12 y42 w716 h26 Hidden +Border -Tabstop"), "")
    TextBlockSearchEdit := AddUiEdit(Panel,
        ScalePanelGuiOptions("x16 y43 w620 h24 Hidden -Border"), "")
    TextBlockSearchEdit.OnEvent("Change", TextBlockSearchChanged)
    DllCall("user32\SendMessageW", "ptr", TextBlockSearchEdit.Hwnd,
        "uint", 0x1501, "ptr", 1,
        "wstr", "空格分隔多个关键字（AND）", "ptr")
    TextBlockSearchTitleOnlyCheck := Panel.AddCheckBox(
        ScalePanelGuiOptions("x644 y43 w76 h24 Hidden"), "仅标题")
    TextBlockSearchTitleOnlyCheck.OnEvent("Click",
        TextBlockSearchTitleOnlyChanged)
    ; Pre-create the smart drop surfaces. They cover only the top navigation
    ; band; the independent right action rail remains visible.
    FolderDropAddSourceButton := Panel.AddButton(
        ScalePanelGuiOptions("x12 y0 w742 h30 Hidden -Tabstop +0x2000"),
        "+ 松开，将文件添加为来源")
    FolderDropAddSourceButton.Visible := false
    FolderDropPinnedZone := Panel.AddButton(
        ScalePanelGuiOptions("x532 y0 w222 h30 Hidden -Tabstop +0x2000"),
        "⭐ 松开，将文件加入固定项")
    FolderDropPinnedZone.Visible := false

    FileView := CreatePanelFileView()
    
    RecentLabel := Panel.AddText(ScalePanelGuiOptions(
        "x740 y42 w220 h22 +0x200"), "最近打开")
    RecentLabel.SetFont("s" Round(10 * PanelUiScaleFactor) " Bold")
    RecentView := Panel.AddListView(ScalePanelGuiOptions(
        "x740 y68 w220 h466 Report -Hdr -Multi"), ["文件"])
    RecentView.OnEvent("Click", FileViewClick)
    RecentView.OnEvent("DoubleClick", OpenRecentItem)
    RecentView.OnEvent("ContextMenu", RecentContextMenu)
    RecentView.OnEvent("ItemSelect", RecentItemSelect)

    ; The native Tab3 border is theme-dependent and does not reach the action
    ; rail. Draw one explicit divider over the ListView top edge instead.
    ; Lighter divider per review: #b9b9b9. It overlays the selected tab
    ; bottom edge and the file area top border.
    WorkspaceBottomRule := AddPanelSolidRule(Panel,
        "x0 y0 w10 h1",
        0x00B9B9B9)
    StatusText := Panel.AddText(ScalePanelGuiOptions(
        "xm y+0 w604 h42 +0xD +0x100"), "已是最新")
    StatusText.OnEvent("Click", HandleStatusAction)
    ; Keep the count as workspace state only. It is intentionally not a
    ; footer control: long paths and status details own all remaining width.
    ItemCountText := {Text: "共0项"}
    TransferStatusText := Panel.AddText(
        ScalePanelGuiOptions("x+8 yp w84 h42 +0xD +0x100"), "↓下载")
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

CreatePanelFileView(visible := true) {
    global Panel, DropTargetObjects
    ; Multi-select is the native ListView default. In icon view this enables
    ; Ctrl-click, Shift range selection and marquee selection on blank space.
    options := "xm y42 w716 h492 Icon +0x100"
    if !visible
        options .= " Hidden"
    view := Panel.AddListView(ScalePanelGuiOptions(options),
        ["文件", "修改时间"])
    view.OnEvent("Click", FileViewClick)
    view.OnEvent("DoubleClick", OpenFileViewItem)
    view.OnEvent("ContextMenu", FileViewContextMenu)
    view.OnEvent("ItemSelect", FileViewItemSelect)
    ; Preserve the existing buffered/transparent ListView rendering. Group
    ; header clicks are handled by PointerInput because common controls do not
    ; expose the previously assumed LVN_GROUPHEADERCLICK notification.
    DllCall("user32\SendMessageW", "ptr", view.Hwnd, "uint", 0x1036,
        "ptr", 0x410000, "ptr", 0x410000, "ptr")
    ; The first view exists before InitDropTarget. Lazy hot views are children
    ; created later and must join the already registered OLE target explicitly.
    for targetPtr, _ in DropTargetObjects {
        RegisterDropTargetWindow(view.Hwnd, targetPtr)
        break
    }
    return view
}

ApplyFileViewGroupSpacing(hwnd) {
    global FileViewGroupTopSpacing, FileViewGroupBottomSpacing
    global FileViewGroupMetricBases
    if !hwnd
        return false

    ; LVGROUPMETRICS uses native pixels. Capture the control's themed defaults
    ; once per HWND, then add the configured DIP values without compounding on
    ; refresh or settings reload.
    if !FileViewGroupMetricBases.Has(hwnd) {
        current := Buffer(48, 0)
        NumPut("uint", 48, current, 0)
        NumPut("uint", 0x1, current, 4) ; LVGMF_BORDERSIZE
        DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x109C,
            "ptr", 0, "ptr", current.Ptr, "ptr") ; LVM_GETGROUPMETRICS
        FileViewGroupMetricBases[hwnd] := {
            Left: NumGet(current, 8, "uint"),
            Top: NumGet(current, 12, "uint"),
            Right: NumGet(current, 16, "uint"),
            Bottom: NumGet(current, 20, "uint")
        }
    }

    base := FileViewGroupMetricBases[hwnd]
    metrics := Buffer(48, 0)
    NumPut("uint", 48, metrics, 0)
    NumPut("uint", 0x1, metrics, 4) ; LVGMF_BORDERSIZE
    NumPut("uint", base.Left, metrics, 8)
    NumPut("uint", base.Top
        + PanelPhysicalScale(FileViewGroupTopSpacing, hwnd), metrics, 12)
    NumPut("uint", base.Right, metrics, 16)
    NumPut("uint", base.Bottom
        + PanelPhysicalScale(FileViewGroupBottomSpacing, hwnd), metrics, 20)
    DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x109B,
        "ptr", 0, "ptr", metrics.Ptr, "ptr") ; LVM_SETGROUPMETRICS
    return true
}

SyncWorkspaceControls(forceTabRebuild := true, updateTypeUi := true) {
    global WorkspaceTabs, WorkspaceTabIds, WorkspaceMoreButton
    global WorkspaceMoreMenu, WorkspaceOverflowIds
    global WORKSPACE_VISIBLE_TAB_LIMIT
    global Workspaces, ActiveWorkspaceId, SettingsController
    if IsObject(WorkspaceTabs) {
        previousTabIds := WorkspaceTabIds.Clone()
        activeIndex := 0
        for index, workspace in Workspaces {
            if StrLower(workspace.Id) = StrLower(ActiveWorkspaceId)
                activeIndex := index
        }
        visibleIndexes := ResolveWorkspaceTabIndexes(
            Workspaces.Length, activeIndex, WORKSPACE_VISIBLE_TAB_LIMIT)
        WorkspaceTabIds := []
        WorkspaceOverflowIds := []
        names := []
        selected := 1
        for index, workspace in Workspaces {
            if ArrayContainsNumber(visibleIndexes, index) {
                names.Push(workspace.Name)
                WorkspaceTabIds.Push(workspace.Id)
                if index = activeIndex
                    selected := names.Length
            } else {
                WorkspaceOverflowIds.Push(workspace.Id)
            }
        }
        membershipChanged := forceTabRebuild
            || WorkspaceTabIds.Length != previousTabIds.Length
        if !membershipChanged {
            for index, workspaceId in WorkspaceTabIds {
                if StrLower(workspaceId) != StrLower(previousTabIds[index]) {
                    membershipChanged := true
                    break
                }
            }
        }
        if membershipChanged {
            WorkspaceTabs.Delete()
            if names.Length
                WorkspaceTabs.Add(names)
            WorkspaceMoreMenu := BuildWorkspaceMoreMenu()
            WorkspaceMoreButton.Visible := WorkspaceOverflowIds.Length > 0
            ApplyWorkspaceTabPadding()
        }
        if names.Length && WorkspaceTabs.Value != selected
            WorkspaceTabs.Choose(selected)
    }
    if IsObject(SettingsController)
        try RefreshSettingsWorkspaceControls(SettingsController)
    if updateTypeUi
        UpdateWorkspaceTypeUi()
}

ResolveWorkspaceTabIndexes(workspaceCount, activeIndex, visibleLimit := 8) {
    result := []
    visibleCount := Min(Max(0, visibleLimit), Max(0, workspaceCount))
    Loop visibleCount
        result.Push(A_Index)
    ; Keep the active workspace represented by a real selected tab even when
    ; it was originally beyond the first eight entries.
    if activeIndex > visibleLimit && activeIndex <= workspaceCount
        && result.Length
        result[result.Length] := activeIndex
    return result
}

ArrayContainsNumber(values, needle) {
    for value in values {
        if value = needle
            return true
    }
    return false
}

BuildWorkspaceMoreMenu() {
    global WorkspaceOverflowIds
    menuObj := Menu()
    labels := Map()
    for workspaceId in WorkspaceOverflowIds {
        found := FindWorkspace(workspaceId)
        if !IsObject(found)
            continue
        label := found.Value.Name
        baseLabel := label
        suffix := 2
        while labels.Has(StrLower(label)) {
            label := baseLabel " (" suffix ")"
            suffix += 1
        }
        labels[StrLower(label)] := true
        menuObj.Add(label, SelectWorkspaceFromMoreMenu.Bind(workspaceId))
    }
    return menuObj
}

ShowWorkspaceMoreMenu(*) {
    global WorkspaceMoreButton, WorkspaceMoreMenu, WorkspaceOverflowIds
    if !IsObject(WorkspaceMoreButton) || !IsObject(WorkspaceMoreMenu)
        || !WorkspaceOverflowIds.Length
        return
    rect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", WorkspaceMoreButton.Hwnd,
        "ptr", rect.Ptr, "int")
        return
    previousMenuCoordMode := A_CoordModeMenu
    BeginAutoHidePause()
    try {
        CoordMode("Menu", "Screen")
        WorkspaceMoreMenu.Show(
            NumGet(rect, 0, "int"), NumGet(rect, 12, "int"))
    } finally {
        CoordMode("Menu", previousMenuCoordMode)
        EndAutoHidePause()
    }
}

SelectWorkspaceFromMoreMenu(workspaceId, *) {
    QueuePanelWorkspaceSwitch(workspaceId)
}

UpdateWorkspaceTypeUi() {
    global TextBlockSearchFrame, TextBlockSearchEdit
    global TextBlockSearchTitleOnlyCheck
    global RefreshButton, PinnedDropButton
    global ClipboardPinnedButton, RemovePinnedButton, TextBlockSearchQuery
    global WorkspaceTabs, WorkspaceMoreButton, WorkspaceOverflowIds
    global PanelLayoutWidth
    textMode := IsTextWorkspace()
    if IsObject(TextBlockSearchFrame)
        TextBlockSearchFrame.Visible := textMode
    if IsObject(TextBlockSearchEdit) {
        TextBlockSearchEdit.Visible := textMode
        if !textMode {
            TextBlockSearchQuery := ""
            TextBlockSearchEdit.Value := ""
        }
    }
    if IsObject(TextBlockSearchTitleOnlyCheck)
        TextBlockSearchTitleOnlyCheck.Visible := textMode
    if IsObject(ClipboardPinnedButton) {
        ClipboardPinnedButton.Visible := true
        SetPanelIconButtonEnabled(ClipboardPinnedButton, textMode)
    }
    if IsObject(WorkspaceMoreButton)
        WorkspaceMoreButton.Visible := WorkspaceOverflowIds.Length > 0
    LayoutWorkspaceNavigation(PanelLayoutWidth)
    if IsObject(Panel) && Panel.Hwnd
        && DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int")
        RequestNativeLayout()
    UpdateClipboardPinnedButton()
    RedrawPanelToolbar()
}

EnforceWorkspaceSearchVisibility() {
    global TextBlockSearchFrame, TextBlockSearchEdit
    global TextBlockSearchTitleOnlyCheck
    global TextBlockSearchQuery
    global TextBlockSelectFirstPending
    if !IsObject(TextBlockSearchEdit)
        return false
    textMode := IsTextWorkspace()
    changed := TextBlockSearchEdit.Visible != textMode
    if IsObject(TextBlockSearchFrame)
        TextBlockSearchFrame.Visible := textMode
    TextBlockSearchEdit.Visible := textMode
    if IsObject(TextBlockSearchTitleOnlyCheck)
        TextBlockSearchTitleOnlyCheck.Visible := textMode
    if !textMode {
        if TextBlockSearchQuery != ""
            TextBlockSearchQuery := ""
        TextBlockSelectFirstPending := true
        if TextBlockSearchEdit.Value != ""
            TextBlockSearchEdit.Value := ""
    }
    return changed
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
        "int", PanelScale(PANEL_TOOLBAR_HEIGHT),
        "int", dpi, "int", 96, "int")
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
    global WorkspaceTabIds, ActiveWorkspaceId
    global InactiveScanJob
    index := control.Value
    if index < 1 || index > WorkspaceTabIds.Length
        return
    targetId := WorkspaceTabIds[index]
    if StrLower(targetId) = StrLower(ActiveWorkspaceId)
        return
    if IsObject(InactiveScanJob)
        && StrLower(InactiveScanJob.WorkspaceId) = StrLower(targetId)
        CancelInactiveWorkspaceScan(false)
    ; Native tab clicks use the same latest-target dispatcher as keyboard
    ; switching.  Do not run a complete activation synchronously from the
    ; control notification: a second click must be able to replace this one.
    if !QueuePanelWorkspaceSwitch(targetId, 4, "main")
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
    global LastFileWorkspaceId
    global SourceWatcherRecentDirty
    global ContentUpdateMode, CONTENT_UPDATE_ACCURACY
    global CurrentScanComplete
    found := FindWorkspace(workspaceId)
    if !IsObject(found)
        return false
    if StrLower(workspaceId) = StrLower(ActiveWorkspaceId) {
        SyncWorkspaceControls()
        return true
    }
    PreviewSuppress("workspace", false)
    RememberActiveWorkspaceFileView()
    ClearTextBlockSearch(false)
    if !BindRuntimeWorkspace(found.Value)
        return false
    CancelStaleWorkspaceWorker()
    if !ScanResultLoaded
        LoadDiskScanCache()
    StatusKind := "default"
    ; A workspace switch changes several sibling controls and may also rebuild
    ; the native ListView. Always finish it as one visual transaction: even if
    ; rendering raises, the finally block restores the active view geometry,
    ; search visibility and right-rail paint instead of leaving a half-switched
    ; blank panel on screen.
    try {
        hotViewReady := ActivateWorkspaceFileView()
        if !hotViewReady
            PopulatePanel()
    } finally {
        EnforceWorkspaceSearchVisibility()
        CommitWorkspaceSwitchVisuals()
    }
    if PanelVisible && IsObject(FileView) {
        if IsTextWorkspace()
            RestoreTextBlockSearchFocus()
        else
            FileView.Focus()
    }
    ; Persist only after the new workspace has completed its synchronous paint.
    ; The shared timer makes rapid A -> B -> C switching write only C.
    ScheduleActiveWorkspacePersistence(
        ActiveWorkspaceId, LastFileWorkspaceId)
    ; Recent/sidebar maintenance and source reconciliation are not required to
    ; expose an already-rendered hot view.  Queue them after returning to the
    ; message loop so a burst of clicks can commit the next target first.
    QueueWorkspaceActivationMaintenance(ActiveWorkspaceId,
        PanelVisible ? 1 : MainHotkeyDoubleTolerance() + 40)
    return true
}

QueueWorkspaceActivationMaintenance(workspaceId, delayMs := 1) {
    global WorkspaceActivationMaintenanceGeneration
    global WorkspaceActivationMaintenanceWorkspaceId
    generation := ++WorkspaceActivationMaintenanceGeneration
    WorkspaceActivationMaintenanceWorkspaceId := workspaceId
    SetTimer(FinishWorkspaceActivation.Bind(workspaceId, generation),
        -Max(1, delayMs))
    return true
}

FinishWorkspaceActivation(workspaceId, generation) {
    global ActiveWorkspaceId, WorkspaceActivationMaintenanceGeneration
    global WorkspaceActivationMaintenanceWorkspaceId
    global ScanResultLoaded, CurrentScanComplete, ContentUpdateMode
    global CONTENT_UPDATE_ACCURACY, ShowRecentSidebar, SourceWatcherRecentDirty
    if generation != WorkspaceActivationMaintenanceGeneration
        return false
    if StrLower(workspaceId) != StrLower(WorkspaceActivationMaintenanceWorkspaceId)
        return false
    if StrLower(workspaceId) != StrLower(ActiveWorkspaceId)
        return false

    PopulateRecentSidebar()
    ReconcileSourceWatchers()
    refreshKeys := GetWorkspaceRefreshSourceKeys(ActiveWorkspaceId, true)
    needsFullScan := !ScanResultLoaded || !CurrentScanComplete
        || ContentUpdateMode = CONTENT_UPDATE_ACCURACY
    includeRecent := ShowRecentSidebar && (!ScanResultLoaded
        || SourceWatcherRecentDirty)
    if needsFullScan
        StartBackgroundScan(0, "workspace", includeRecent)
    else if refreshKeys.Count || includeRecent
        StartBackgroundScan(refreshKeys, "workspace", includeRecent)
    return true
}

RememberActiveWorkspaceFileView() {
    global ActiveWorkspaceId, FileView, WorkspaceFileViewStates
    global ItemPaths, ItemLabels, ItemFolderPaths, ItemKinds, ItemOpenContexts
    global GroupFolderPaths, GroupDropTargets, SelectedFilePaths
    global ThumbnailImageList, ThumbnailImageListEdge, ThumbnailIconCache
    global ThumbnailEnhanceQueue, ThumbnailEnhanceGeneration
    global PanelRenderSignature, PanelRenderedWorkspaceId
    global TextBlockSearchIndex, TextBlockSearchQueue, TextBlockSearchQuery
    global TextBlockSelectFirstPending, ItemCountText, StatusText, StatusKind
    global CurrentScanResult, CurrentConfigFingerprint, PinnedPaths
    global ViewMode, ThumbnailSize, PanelRenderedScanRevision
    if ActiveWorkspaceId = "" || !IsObject(FileView)
        return false
    SetTimer(EnhanceNextThumbnail, 0)
    SetTimer(BuildNextTextBlockSearchIndex, 0)
    WorkspaceFileViewStates[StrLower(ActiveWorkspaceId)] := {
        Control: FileView,
        ItemPaths: ItemPaths,
        ItemLabels: ItemLabels,
        ItemFolderPaths: ItemFolderPaths,
        ItemKinds: ItemKinds,
        ItemOpenContexts: ItemOpenContexts,
        GroupFolderPaths: GroupFolderPaths,
        GroupDropTargets: GroupDropTargets,
        SelectedFilePaths: SelectedFilePaths,
        ImageList: ThumbnailImageList,
        ImageListEdge: ThumbnailImageListEdge,
        IconCache: ThumbnailIconCache,
        EnhanceQueue: ThumbnailEnhanceQueue,
        EnhanceGeneration: ThumbnailEnhanceGeneration,
        RenderSignature: PanelRenderSignature,
        RenderedWorkspaceId: PanelRenderedWorkspaceId,
        SearchIndex: TextBlockSearchIndex,
        SearchQueue: TextBlockSearchQueue,
        SearchQuery: TextBlockSearchQuery,
        SelectFirstPending: TextBlockSelectFirstPending,
        CountText: IsObject(ItemCountText) ? ItemCountText.Text : "",
        StatusText: IsObject(StatusText) ? StatusText.Text : "",
        StatusKind: StatusKind,
        ScanResult: CurrentScanResult,
        ConfigFingerprint: CurrentConfigFingerprint,
        PinnedPaths: PinnedPaths,
        ViewMode: ViewMode,
        ThumbnailSize: ThumbnailSize,
        RenderRevision: PanelRenderedScanRevision
    }
    return true
}

ActivateWorkspaceFileView() {
    global ActiveWorkspaceId, FileView, WorkspaceFileViewStates
    global ItemPaths, ItemLabels, ItemFolderPaths, ItemKinds, ItemOpenContexts
    global GroupFolderPaths, GroupDropTargets, SelectedFilePaths
    global ThumbnailImageList, ThumbnailImageListEdge, ThumbnailIconCache
    global ThumbnailEnhanceQueue, ThumbnailEnhanceGeneration
    global PanelRenderSignature, PanelRenderedWorkspaceId
    global TextBlockSearchIndex, TextBlockSearchQueue, TextBlockSearchQuery
    global TextBlockSelectFirstPending, TextBlockSearchEdit
    global ItemCountText, StatusText, StatusKind
    global CurrentScanResult, CurrentConfigFingerprint, PinnedPaths
    global ViewMode, ThumbnailSize, CurrentScanComplete
    global CurrentScanRevision, PanelRenderedScanRevision

    oldView := FileView
    key := StrLower(ActiveWorkspaceId)
    if WorkspaceFileViewStates.Has(key) {
        state := WorkspaceFileViewStates[key]
        ; The map owns inactive views only. Once restored, remove this entry so
        ; a later active refresh cannot leave stale maps or a destroyed image
        ; list referenced by cleanup; leaving the workspace saves it anew.
        WorkspaceFileViewStates.Delete(key)
        FileView := state.Control
        ItemPaths := state.ItemPaths
        ItemLabels := state.ItemLabels
        ItemFolderPaths := state.ItemFolderPaths
        ItemKinds := state.ItemKinds
        ItemOpenContexts := state.ItemOpenContexts
        GroupFolderPaths := state.GroupFolderPaths
        GroupDropTargets := state.GroupDropTargets
        SelectedFilePaths := state.SelectedFilePaths
        ThumbnailImageList := state.ImageList
        ThumbnailImageListEdge := state.ImageListEdge
        ThumbnailIconCache := state.IconCache
        ThumbnailEnhanceQueue := state.EnhanceQueue
        ThumbnailEnhanceGeneration := state.EnhanceGeneration
        PanelRenderSignature := state.RenderSignature
        PanelRenderedWorkspaceId := state.RenderedWorkspaceId
        PanelRenderedScanRevision := state.RenderRevision
        TextBlockSearchIndex := state.SearchIndex
        TextBlockSearchQueue := state.SearchQueue
        TextBlockSearchQuery := state.SearchQuery
        TextBlockSelectFirstPending := state.SelectFirstPending
        if IsObject(ItemCountText)
            ItemCountText.Text := state.CountText
        if IsObject(StatusText)
            StatusText.Text := state.StatusText
        StatusKind := state.StatusKind
    } else {
        FileView := CreatePanelFileView(false)
        ItemPaths := Map()
        ItemLabels := Map()
        ItemFolderPaths := Map()
        ItemKinds := Map()
        ItemOpenContexts := Map()
        GroupFolderPaths := Map()
        GroupDropTargets := Map()
        SelectedFilePaths := []
        ThumbnailImageList := 0
        ThumbnailImageListEdge := 0
        ThumbnailIconCache := Map()
        ThumbnailEnhanceQueue := []
        ThumbnailEnhanceGeneration += 1
        PanelRenderSignature := ""
        PanelRenderedWorkspaceId := ""
        PanelRenderedScanRevision := 0
        TextBlockSearchIndex := Map()
        TextBlockSearchQueue := []
        TextBlockSearchQuery := ""
        TextBlockSelectFirstPending := true
    }

    ApplyFileViewGroupSpacing(FileView.Hwnd)
    ; Every cached view follows the active view's current geometry. This keeps
    ; hidden views correct after the panel was resized while another tab was
    ; active, without running the full layout pipeline on the switch path.
    if IsObject(oldView) && oldView.Hwnd != FileView.Hwnd {
        oldView.GetPos(&x, &y, &width, &height)
        FileView.Move(x, y, width, height)
        oldView.Visible := false
    }
    FileView.Visible := true
    if IsObject(TextBlockSearchEdit)
        TextBlockSearchEdit.Value := TextBlockSearchQuery

    ; Constant-time validity check. ComputePanelRenderSignature walks every
    ; scanned row, which would make a supposedly hot switch scale with folder
    ; size. Every content publication advances an explicit revision; unlike
    ; object identity this also detects in-place mutation by partial workers.
    hotViewReady := IsSet(state) && CurrentScanComplete
        && PanelRenderSignature != ""
        && state.ConfigFingerprint = CurrentConfigFingerprint
        && state.RenderRevision = CurrentScanRevision
        && ObjPtr(state.PinnedPaths) = ObjPtr(PinnedPaths)
        && state.ViewMode = ViewMode
        && state.ThumbnailSize = ThumbnailSize
        && state.SearchQuery = TextBlockSearchQuery
    if hotViewReady {
        if ThumbnailEnhanceQueue.Length
            SetTimer(EnhanceNextThumbnail, -1)
        if TextBlockSearchQueue.Length
            SetTimer(BuildNextTextBlockSearchIndex, -1)
    }
    return hotViewReady
}

CommitWorkspaceSwitchVisuals() {
    global Panel, FileView
    if !IsObject(Panel) || !Panel.Hwnd || !IsObject(FileView)
        return false
    panelHwnd := Panel.Hwnd
    if !DllCall("user32\IsWindowVisible", "ptr", panelHwnd, "int")
        return false

    ; PostMessage(WM_SIZE) is intentionally used by ordinary deferred layout,
    ; but it is too late for the end of a workspace switch: focus and another
    ; tab notification can arrive before that message. Send the same native
    ; notification synchronously so AHK performs its normal DPI conversion.
    clientRect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", panelHwnd,
        "ptr", clientRect.Ptr, "int")
        return false
    clientWidth := NumGet(clientRect, 8, "int")
        - NumGet(clientRect, 0, "int")
    clientHeight := NumGet(clientRect, 12, "int")
        - NumGet(clientRect, 4, "int")
    packedSize := (clientWidth & 0xFFFF)
        | ((clientHeight & 0xFFFF) << 16)
    DllCall("user32\SendMessageW", "ptr", panelHwnd, "uint", 0x0005,
        "uptr", 0, "uptr", packedSize, "ptr") ; WM_SIZE
    ; WM_SIZE and a newly created/hot-swapped native ListView are allowed to
    ; change their internal view state independently. Reassert the product view
    ; contract after sizing: text workspaces are always card tiles, while file
    ; workspaces follow the configured thumbnail/list setting.
    ApplyViewMode()
    FileView.Visible := true

    ; Repaint the complete sibling tree after every child has its final bounds.
    ; This covers the independent right rail as well as the top toolbar; the
    ; old toolbar-only invalidation could leave the refresh icon unpainted.
    redrawFlags := 0x0001 | 0x0004 | 0x0080 | 0x0100
        ; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
    DllCall("user32\RedrawWindow", "ptr", panelHwnd, "ptr", 0,
        "ptr", 0, "uint", redrawFlags, "int")
    PreviewRecoverAfterInteraction()
    return true
}

BindRuntimeWorkspace(workspace) {
    global ActiveWorkspaceId, ActiveWorkspaceName, ActiveWorkspaceType
    global LastFileWorkspaceId, WORKSPACE_TYPE_FILES
    global FolderSettings, PinnedPaths, LastValidFolderSettings
    global LastValidWorkspaceId, ConfigErrors, ConfigErrorsShown
    global CurrentConfigFingerprint, CurrentScanResult, ScanResultLoaded
    global CurrentScanComplete, CurrentScanRevision
    global CurrentHiddenBySource, WorkspaceScanSnapshots
    global CacheDir, CacheFilePath
    global PanelRenderSignature, RecentRenderSignature

    if !IsObject(workspace) || workspace.Id = ""
        return false
    DeferPendingCurrentScanCacheWrite()
    RememberCurrentWorkspaceSnapshot()

    previousWorkspaceType := ActiveWorkspaceType
    ActiveWorkspaceId := workspace.Id
    ActiveWorkspaceName := workspace.Name
    ActiveWorkspaceType := workspace.Type
    FolderSettings := workspace.SourceRefs
    PinnedPaths := workspace.PinnedPaths
    if ParseWorkspaceType(workspace.Type) = WORKSPACE_TYPE_FILES
        LastFileWorkspaceId := workspace.Id

    ConfigErrorsShown := false
    ConfigErrors := HasProp(workspace, "RuntimeErrors")
        ? workspace.RuntimeErrors.Clone() : workspace.Errors.Clone()
    if workspace.Valid {
        LastValidFolderSettings := workspace.Sources
        LastValidWorkspaceId := workspace.Id
    } else if !LastValidFolderSettings.Length
        || StrLower(LastValidWorkspaceId) != StrLower(workspace.Id) {
        LastValidFolderSettings := workspace.Sources
        LastValidWorkspaceId := workspace.Id
    }

    CurrentConfigFingerprint := ComputeConfigFingerprint(
        LastValidFolderSettings, workspace.Id, workspace.Type,
        workspace.PinnedPaths)
    CacheFilePath := CacheDir "\workspace-"
        . HashString(StrLower(workspace.Id)) ".ini"
    CurrentHiddenBySource := Map()
    snapshotKey := StrLower(workspace.Id)
    if WorkspaceScanSnapshots.Has(snapshotKey)
        && WorkspaceScanSnapshots[snapshotKey].Fingerprint
            = CurrentConfigFingerprint {
        snapshot := WorkspaceScanSnapshots[snapshotKey]
        CurrentScanResult := snapshot.Result
        ScanResultLoaded := true
        CurrentScanComplete := HasProp(snapshot, "Complete")
            ? snapshot.Complete
            : IsScanResultStructurallyComplete(
                CurrentScanResult, LastValidFolderSettings)
        CurrentScanRevision := HasProp(snapshot, "Revision")
            ? snapshot.Revision : NextScanContentRevision()
    } else {
        CurrentScanResult := {
            Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
        ScanResultLoaded := false
        CurrentScanComplete := false
        CurrentScanRevision := NextScanContentRevision()
    }
    PanelRenderSignature := ""
    RecentRenderSignature := ""
    typeChanged := ParseWorkspaceType(previousWorkspaceType)
        != ParseWorkspaceType(workspace.Type)
    SyncWorkspaceControls(false, typeChanged)
    return true
}

DeferPendingCurrentScanCacheWrite() {
    global ScanCacheWritePending
    global ActiveWorkspaceId, CurrentConfigFingerprint, CurrentScanResult
    if !ScanCacheWritePending || ActiveWorkspaceId = ""
        return false
    ; The existing cache timer uses active globals. Capture the old identity
    ; before rebinding them, then let the exact snapshot write after first
    ; paint instead of performing disk I/O on the switch path.
    SetTimer(FlushPendingScanCacheWrite, 0)
    ScanCacheWritePending := false
    SetTimer(WriteWorkspaceSnapshot.Bind(
        CurrentScanResult, ActiveWorkspaceId, CurrentConfigFingerprint), -1)
    return true
}

CancelStaleWorkspaceWorker() {
    global WorkerRunning, WorkerWorkspaceId, ActiveWorkspaceId
    global WorkerPid, PendingRefresh, PendingFullRefresh
    global PendingScanSourceKeys, PendingIncludeRecent
    global InactiveScanJob
    if IsObject(InactiveScanJob)
        && StrLower(InactiveScanJob.WorkspaceId) = StrLower(ActiveWorkspaceId)
        CancelInactiveWorkspaceScan(false)
    if !WorkerRunning
        return
    if StrLower(WorkerWorkspaceId) = StrLower(ActiveWorkspaceId)
        return
    if WorkerPid && ProcessExist(WorkerPid)
        try ProcessClose(WorkerPid)
    FinishWorker(false)
    PendingRefresh := false
    PendingFullRefresh := false
    PendingScanSourceKeys := Map()
    PendingIncludeRecent := false
}

ScheduleActiveWorkspacePersistence(workspaceId, lastFileWorkspaceId) {
    global PendingActiveWorkspacePersistId
    global PendingLastFileWorkspacePersistId
    global ActiveWorkspacePersistAttempts
    global ACTIVE_WORKSPACE_PERSIST_DELAY_MS
    PendingActiveWorkspacePersistId := workspaceId
    PendingLastFileWorkspacePersistId := lastFileWorkspaceId
    ActiveWorkspacePersistAttempts := 0
    SetTimer(PersistPendingActiveWorkspaceState,
        -ACTIVE_WORKSPACE_PERSIST_DELAY_MS)
}

PersistPendingActiveWorkspaceState(*) {
    global PendingActiveWorkspacePersistId
    global PendingLastFileWorkspacePersistId
    global ActiveWorkspacePersistAttempts
    workspaceId := PendingActiveWorkspacePersistId
    lastFileWorkspaceId := PendingLastFileWorkspacePersistId
    if workspaceId = ""
        return true
    try AtomicConfigEdit(
        WriteActiveWorkspaceState.Bind(workspaceId, lastFileWorkspaceId))
    catch {
        ActiveWorkspacePersistAttempts += 1
        if ActiveWorkspacePersistAttempts < 2
            SetTimer(PersistPendingActiveWorkspaceState, -1000)
        else
            SetBackgroundStatus("工作区已切换，状态保存失败", 3000)
        return false
    }
    if StrLower(PendingActiveWorkspacePersistId) = StrLower(workspaceId)
        && StrLower(PendingLastFileWorkspacePersistId)
            = StrLower(lastFileWorkspaceId) {
        PendingActiveWorkspacePersistId := ""
        PendingLastFileWorkspacePersistId := ""
        ActiveWorkspacePersistAttempts := 0
    }
    return true
}

FlushPendingActiveWorkspacePersistence(throwOnFailure := false) {
    global PendingActiveWorkspacePersistId
    SetTimer(PersistPendingActiveWorkspaceState, 0)
    if PendingActiveWorkspacePersistId = ""
        return true
    saved := PersistPendingActiveWorkspaceState()
    if !saved && throwOnFailure
        throw Error("当前工作区状态尚未写入配置文件。")
    return saved
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
    if QuickViewActive
        QuickPreviewYieldPanelTopmost()
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
    ; The native timer hides first and posts cleanup second. A hotkey may show
    ; the same HWND again before this queued message is dispatched; never let
    ; that stale cleanup tear down the new visible session.
    if Panel.Hwnd && DllCall("user32\IsWindowVisible",
        "ptr", Panel.Hwnd, "int")
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

    activationState := wParam & 0xFFFF
    if activationState != 0 {
        ; A native ListView can return from an external preview with its view
        ; style reset to icon mode. Correct it after activation completes even
        ; when keyboard focus remains in the search Edit.
        SetTimer(EnsureActiveTextBlockCardView.Bind(true), -1)
        return
    }

    if WindowMode != WINDOW_MODE_TEMPORARY
        return

    ; WA_INACTIVE = 0
    CancelUncommittedMainHotkeyGesture()
    CancelFilePointerGesture()
    ScheduleAutoHideCheck(150)
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
    global ActiveHotkey, ActiveHotkeyRelease, ConfiguredHotkey, ConfigPath
    if newHotkey = ActiveHotkey
        return

    ; T2 lets a second physical press enter the lightweight gesture collector
    ; while the first thread is still presenting the native window.
    try Hotkey(newHotkey, HandleMainHotkey, "On T2")
    catch as err {
        ShowPanelMsgBox("快捷键配置无效：" newHotkey "`n已改用 F2。`n`n" err.Message,
            "PopDrop", "Icon!")
        newHotkey := "F2"
        ConfiguredHotkey := newHotkey
        AtomicConfigSetValue("General", "Hotkey", newHotkey)
        Hotkey(newHotkey, HandleMainHotkey, "On T2")
    }

    if ActiveHotkey != ""
        try Hotkey(ActiveHotkey, "Off")
    if ActiveHotkeyRelease != ""
        try Hotkey(ActiveHotkeyRelease, "Off")
    ActiveHotkey := newHotkey
    ActiveHotkeyRelease := MainHotkeyReleaseName(newHotkey)
    if ActiveHotkeyRelease != ""
        Hotkey(ActiveHotkeyRelease, HandleMainHotkeyKeyUp, "On")
}

MainHotkeyReleaseName(hotkeyName) {
    baseKey := MainHotkeyBaseKey(hotkeyName)
    return baseKey = "" ? "" : "~*" baseKey " Up"
}

HandleMainHotkeyKeyUp(*) {
    global MainHotkeyAwaitRelease
    MainHotkeyAwaitRelease := false
    SetTimer(MainHotkeyReleasePoll, 0)
}

HandleMainHotkey(*) {
    global MainHotkeyFirstPressTick, MainHotkeyGestureGeneration
    global MainHotkeyGestureArmed, MainHotkeySecondPressPending
    global MainHotkeyAwaitRelease, MainHotkeyPhysicalKey, ConfiguredHotkey
    global MainHotkeyClosedTick, PanelVisible
    global PanelShowFinishGeneration
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
    tolerance := MainHotkeyDoubleTolerance()
    ; T2 allows this collector to interrupt the first F2 thread. While that
    ; thread is still showing the window FirstPressTick is intentionally zero;
    ; an armed gesture with no tick is therefore an immediate valid second
    ; edge, not a new single press.
    if MainHotkeyGestureArmed {
        elapsed := MainHotkeyFirstPressTick
            ? ElapsedTickMilliseconds(MainHotkeyFirstPressTick, now) : 0
        if !MainHotkeyFirstPressTick || elapsed <= tolerance {
            MainHotkeyGestureArmed := false
            MainHotkeySecondPressPending := true
            MainHotkeyFirstPressTick := 0
            MainHotkeyGestureGeneration += 1
            PanelShowFinishGeneration += 1
            RequestMainHotkeyAction("Text")
            return
        }
        MainHotkeyGestureArmed := false
        MainHotkeySecondPressPending := false
        MainHotkeyFirstPressTick := 0
    }

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
    MainHotkeyGestureGeneration += 1
    MainHotkeyGestureArmed := true
    MainHotkeySecondPressPending := false
    MainHotkeyFirstPressTick := 0
    ; Show the single-press workspace immediately. The armed pair state only
    ; decides whether a second press should redirect to Text; it never delays
    ; the first visible frame.
    PresentMainHotkeyWorkspace("Files")
    ; Start the pair window only after the first action has returned. If a
    ; cold activation briefly occupied the AHK thread, a physical second press
    ; queued during that work must still be accepted as the pair's second edge.
    if MainHotkeySecondPressPending {
        MainHotkeySecondPressPending := false
        return
    }
    MainHotkeyFirstPressTick := A_TickCount
}

MainHotkeyDoubleTolerance() {
    ; Only a deliberate rapid pair is a double shortcut. Once the single
    ; action is committed and the panel appears, a later F2 starts a fresh
    ; single gesture instead of toggling back to Text.
    ; Keyboard pairs need a little more tolerance than mouse double-clicks:
    ; the first press also activates a top-level window and transfers focus.
    ; Single-F2 no longer waits for this value, so 400 ms improves reliability
    ; without making the window appear slower.
    return 400
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
    global MainHotkeyGestureArmed, MainHotkeySecondPressPending
    if !MainHotkeyGestureArmed && !MainHotkeyFirstPressTick
        return
    MainHotkeyGestureArmed := false
    MainHotkeySecondPressPending := false
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
        ShowPanelInstant()
    else {
        QueuePanelShowFinish()
        ActivatePanelWindowSafely(true)
    }
}

ActivatePanelWindowSafely(restore := false) {
    global Panel
    CancelCacheMaintenanceOpportunity()
    if !IsObject(Panel) || !Panel.Hwnd
        return false
    hwnd := Panel.Hwnd
    if !DllCall("user32\IsWindow", "ptr", hwnd, "int")
        return false

    ; Use the HWND directly. AHK's WinActivate performs a fresh window-title
    ; lookup and throws if native auto-hide changes visibility in that small
    ; interval. These HWND operations do not throw, so display completion can
    ; continue even when Windows declines foreground activation.
    if restore && DllCall("user32\IsIconic", "ptr", hwnd, "int")
        DllCall("user32\ShowWindow", "ptr", hwnd, "int", 9) ; SW_RESTORE
    else if !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
        DllCall("user32\ShowWindow", "ptr", hwnd, "int", 5) ; SW_SHOW
    DllCall("user32\BringWindowToTop", "ptr", hwnd, "int")
    DllCall("user32\SetForegroundWindow", "ptr", hwnd, "int")
    return true
}

ShowPanelInstant(*) {
    global Panel, PanelVisible, WindowWidth, WindowHeight
    global WindowMode, WINDOW_MODE_TEMPORARY, AutoHidePauseDepth
    global AutoHidePanelShownTick, AutoHideNativeShownTick
    global PanelShowFinishGeneration
    if !IsObject(Panel)
        return false

    ; Keep the last complete native frame visible. Configuration loading and
    ; refresh checks are deliberately moved to FinishPanelShow().
    PreviewBeginPanelSession()
    ApplyWindowMode()
    ; When the previous session ended in Text, the hidden FileView may still
    ; carry Text's search-band offset. Apply the final geometry while the
    ; window is hidden so the first visible frame is already stable.
    ResizePanel(Panel, 0, PanelScale(WindowWidth), PanelScale(WindowHeight))
    AutoHideNativeShownTick := A_TickCount
    Panel.Show("w" PanelScale(WindowWidth) " h" PanelScale(WindowHeight))
    PanelVisible := true
    AutoHidePauseDepth := 0
    AutoHidePanelShownTick := A_TickCount
    if WindowMode = WINDOW_MODE_TEMPORARY
        StartAutoHideWatchdog()
    QueuePanelShowFinish(MainHotkeyDoubleTolerance() + 40)
    ActivatePanelWindowSafely()
    return true
}

QueuePanelShowFinish(delayMs := 1) {
    global PanelShowFinishGeneration
    generation := ++PanelShowFinishGeneration
    SetTimer(FinishPanelShow.Bind(generation), -Max(1, delayMs))
    return true
}

FinishPanelShow(generation) {
    global Panel, PanelVisible, ConfiguredHotkey, ActiveHotkey
    global ScanResultLoaded, StatusKind, CurrentScanComplete
    global WorkerRunning, ShowRecentSidebar
    global StatusText, PanelShowFinishGeneration
    if generation != PanelShowFinishGeneration || !PanelVisible
        return false

    ; Reloading an unchanged config rebuilds Tab state and synchronously
    ; redraws the toolbar, creating a deterministic flash after every summon.
    ; Internal writers keep LoadedConfigStamp current, so only a genuine
    ; external/config-file change needs the expensive reload path.
    configChanged := ConfigFileChangedSinceLoad()
    if configChanged {
        LoadSettings()
        InstallWorkspaceHotkeys()
        ApplyWindowMode()
        if ConfiguredHotkey != ActiveHotkey {
            InstallHotkey(ConfiguredHotkey)
            BuildTrayMenu()
        }
    }
    if EnforceWorkspaceSearchVisibility()
        RequestNativeLayout()
    if !ScanResultLoaded
        LoadDiskScanCache()
    if !IsPanelRenderCurrent()
        PopulatePanel()
    if !IsRecentRenderCurrent()
        PopulateRecentSidebar()
    SetTimer(UpdateSelectionStatus, 0)
    if ScanResultLoaded && !WorkerRunning {
        StatusKind := "default"
        StatusText.Text := "已是最新"
    }
    RedrawFooterTextControls()
    UpdateWindowModeButton()
    CheckRefreshPolicyOnShow()
    if !CurrentScanComplete && !WorkerRunning
        StartBackgroundScan(0, "incomplete-show", ShowRecentSidebar)
    RestoreTextBlockSearchFocus()
    SetTimer(RequestNativeLayout, -30)
    return true
}

ResetMainHotkeyGesture(clearRequestedAction := true) {
    global MainHotkeyFirstPressTick, MainHotkeyGestureGeneration
    global MainHotkeyGestureArmed, MainHotkeySecondPressPending
    global MainHotkeyRequestedAction
    MainHotkeyGestureArmed := false
    MainHotkeySecondPressPending := false
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
        ActivatePanelWindowSafely(true)
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
        ActivatePanelWindowSafely(true)
        return
    }

    HidePanel()
}

ShowAndRefresh(*) {
    global Panel, PanelVisible, ConfiguredHotkey, ActiveHotkey, WindowWidth, WindowHeight
    global ScanResultLoaded, StatusKind, AutoHidePanelShownTick
    global WindowMode, WINDOW_MODE_TEMPORARY, AutoHidePauseDepth
    global AutoHideNativeShownTick
    global CurrentScanComplete, WorkerRunning, ShowRecentSidebar
    PreviewBeginPanelSession()
    LoadSettings()
    InstallWorkspaceHotkeys()
    ApplyWindowMode()
    if ConfiguredHotkey != ActiveHotkey {
        InstallHotkey(ConfiguredHotkey)
        BuildTrayMenu()
    }
    AutoHideNativeShownTick := A_TickCount
    Panel.Show("w" PanelScale(WindowWidth) " h" PanelScale(WindowHeight))
    PanelVisible := true
    ; A hidden panel has no legitimate modal/menu pause owner. Begin every
    ; visible session clean so no previous session can poison later summons.
    AutoHidePauseDepth := 0
    AutoHidePanelShownTick := A_TickCount
    if WindowMode = WINDOW_MODE_TEMPORARY
        StartAutoHideWatchdog()
    ActivatePanelWindowSafely()

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
    RedrawFooterTextControls()
    UpdateWindowModeButton()
    CheckRefreshPolicyOnShow()
    ; A worker may have been canceled after publishing only part of a cold
    ; scan. Reopening within the same process must actively repair it instead
    ; of waiting for the next daily/consistency calibration.
    if !CurrentScanComplete && !WorkerRunning
        StartBackgroundScan(0, "incomplete-show", ShowRecentSidebar)
    RestoreTextBlockSearchFocus()
    ; First-show stabilization pass: some workspace-dependent controls settle
    ; only after the native window is visible and populated.
    SetTimer(RequestNativeLayout, -30)
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
    ResetPanelIconHover()
    CloseExternalQuickPreview(true, false)
    PreviewPanelHidden()
    CancelAutoHideCheck()
    StopAutoHideWatchdog()
    ResetActiveDropSession(true)
    Panel.Hide()
    PanelVisible := false
    AutoHidePauseDepth := 0
    ResetTextBlockSearchSession(false)
    RunPendingConsistencyCheckAfterHide()
    ScheduleCacheMaintenanceAfterHide()
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
    global TransferStatusText, WorkspaceBottomRule
    global TextBlockSearchFrame, TextBlockSearchEdit
    global TextBlockSearchTitleOnlyCheck
    global ShowRecentSidebar, PanelLayoutWidth
    global PANEL_TOOLBAR_HEIGHT, PANEL_FOOTER_HEIGHT
    global PANEL_SIDE_TOOLBAR_WIDTH, PANEL_SIDE_TOOLBAR_GAP
    global PANEL_SIDE_TOOLBAR_EDGE_GAP, PANEL_CONTENT_TOP_OFFSET_PX
    if minMax = -1
        return
    PreviewSuppress("resize", true)
    PanelLayoutWidth := width
    ResizeFolderDropControls(width)
    LayoutWorkspaceNavigation(width)
    ; Start content at the real visible bottom edge of the cropped Tab3.
    ; This removes the parent-background strip between the tab and ListView.
    ; Keep the tuned tab header fully visible by moving the content band
    ; down as a unit. This shifts the divider and file region together.
    contentTop := GetWorkspaceContentTop()
        + PanelPixelsToGui(PANEL_CONTENT_TOP_OFFSET_PX, guiObj.Hwnd)
    footerHeight := PanelScale(PANEL_FOOTER_HEIGHT)
    outerMargin := PanelScale(12)
    ; ResizePanel width/height are Gui units. Convert the requested visible
    ; pixels first so monitor DPI does not enlarge the rail again.
    sideToolbarWidth := PanelPixelsToGui(
        PANEL_SIDE_TOOLBAR_WIDTH, guiObj.Hwnd)
    sideToolbarGap := PanelPixelsToGui(
        PANEL_SIDE_TOOLBAR_GAP, guiObj.Hwnd)
    sideToolbarEdgeGap := PanelPixelsToGui(
        PANEL_SIDE_TOOLBAR_EDGE_GAP, guiObj.Hwnd)
    contentWidth := Max(PanelScale(200),
        width - outerMargin - sideToolbarWidth - sideToolbarGap
            - sideToolbarEdgeGap)
    contentHeight := Max(PanelScale(160),
        height - contentTop - footerHeight)

    searchVisible := IsTextWorkspace()
        && IsObject(TextBlockSearchEdit) && TextBlockSearchEdit.Visible
    searchHeight := searchVisible ? PanelScale(26) : 0
    contentTopGap := PanelPixelsToGui(
        searchVisible ? 2 : 1, guiObj.Hwnd)
    fileContentTop := contentTop + searchHeight + contentTopGap
    fileContentHeight := Max(PanelScale(100),
        contentHeight - searchHeight - contentTopGap)

    LayoutSideToolbar(width, contentTop, contentHeight)
    fileRight := outerMargin + contentWidth
    if ShowRecentSidebar {
        sidebarWidth := Min(PanelScale(280),
            Max(PanelScale(190), Floor(contentWidth * 0.28)))
        contentGap := PanelScale(12)
        mainWidth := Max(PanelScale(280),
            contentWidth - sidebarWidth - contentGap)
        sidebarX := outerMargin + mainWidth + contentGap
        if searchVisible
            LayoutTextBlockSearchBand(outerMargin,
                contentTop + contentTopGap, mainWidth, searchHeight)
        FileView.Move(outerMargin, fileContentTop,
            mainWidth, fileContentHeight)
        fileRight := outerMargin + mainWidth
        RecentLabel.Move(sidebarX, fileContentTop,
            sidebarWidth, PanelScale(22))
        RecentView.Move(sidebarX, fileContentTop + PanelScale(26),
            sidebarWidth, Max(PanelScale(154),
                fileContentHeight - PanelScale(26)))
        RecentView.ModifyCol(1,
            Max(PanelScale(120), sidebarWidth - PanelScale(8)))
        RecentLabel.Visible := true
        RecentView.Visible := true
    } else {
        if searchVisible
            LayoutTextBlockSearchBand(outerMargin,
                contentTop + contentTopGap, contentWidth, searchHeight)
        FileView.Move(outerMargin, fileContentTop,
            contentWidth, fileContentHeight)
        RecentLabel.Visible := false
        RecentView.Visible := false
    }

    LayoutWorkspaceBottomRule(outerMargin, fileRight - outerMargin, contentTop)


    ; Keep the transfer affordance inside the file region. Its right edge is
    ; exactly the same as FileView's right edge, never under the icon rail.
    transferWidth := PanelScale(84)
    footerTop := height - footerHeight
    footerGap := PanelScale(8)
    transferX := fileRight - transferWidth
    stateWidth := Max(PanelScale(100),
        transferX - footerGap - outerMargin)
    StatusText.Move(outerMargin, footerTop, stateWidth, footerHeight)
    TransferStatusText.Move(transferX,
        footerTop, transferWidth, footerHeight)
}

LayoutTextBlockSearchBand(x, y, width, height) {
    global TextBlockSearchFrame, TextBlockSearchEdit
    global TextBlockSearchTitleOnlyCheck
    if !IsObject(TextBlockSearchFrame) || !IsObject(TextBlockSearchEdit)
        return
    scopeWidth := TextBlockSearchScopeWidth(width)
    dividerX := x + width - scopeWidth
    ; The borderless Edit fills the left compartment. The previous 4-DIP
    ; horizontal and 1-DIP vertical inset left a visible empty strip around
    ; the input; keep separation only at the dedicated divider.
    editWidth := Max(PanelScale(72), dividerX - x)
    TextBlockSearchFrame.Move(x, y, width, height)
    TextBlockSearchEdit.Move(x, y, editWidth, height)
    if IsObject(TextBlockSearchTitleOnlyCheck)
        TextBlockSearchTitleOnlyCheck.Move(
            dividerX + PanelScale(7), y + PanelScale(1),
            Max(PanelScale(68), scopeWidth - PanelScale(9)),
            Max(PanelScale(20), height - PanelScale(2)))
}

TextBlockSearchScopeWidth(width, scaleFactor := 0) {
    global PanelUiScaleFactor
    ; ResizePanel can receive a floating-point Gui width after DPI conversion.
    ; Use regular division and Floor instead of the integer-only // operator,
    ; which rejects a Float such as 640.0 before Min/Max can evaluate it.
    if scaleFactor <= 0 {
        scaleFactor := IsSet(PanelUiScaleFactor) ? PanelUiScaleFactor : 1.0
    }
    minimumWidth := Round(78 * scaleFactor)
    maximumWidth := Round(88 * scaleFactor)
    widthThird := Floor(width / 3)
    return Min(maximumWidth, Max(minimumWidth, widthThird))
}

LayoutWorkspaceBottomRule(fileLeft, fileWidth, contentTop) {
    global Panel, WorkspaceBottomRule
    if !IsObject(Panel) || !IsObject(WorkspaceBottomRule)
        || !Panel.Hwnd || !WorkspaceBottomRule.Hwnd
        return

    ruleHeight := Max(1, PanelPixelsToGui(1, Panel.Hwnd))
    WorkspaceBottomRule.Move(
        fileLeft, contentTop, Max(1, fileWidth), ruleHeight)
    DllCall("user32\SetWindowPos", "ptr", WorkspaceBottomRule.Hwnd,
        "ptr", 0, "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", 0x0013, "int")
    DllCall("user32\InvalidateRect", "ptr", WorkspaceBottomRule.Hwnd,
        "ptr", 0, "int", 1)
    DllCall("user32\UpdateWindow", "ptr", WorkspaceBottomRule.Hwnd)
}

EnableWorkspaceTabItemPadding() {
    global WorkspaceTabs, WorkspaceTabPaintSubclassCallback
    if !IsObject(WorkspaceTabs) || !WorkspaceTabs.Hwnd
        return
    if !WorkspaceTabPaintSubclassCallback
        WorkspaceTabPaintSubclassCallback := CallbackCreate(
            WorkspaceTabItemSubclass, "", 6)
    DllCall("comctl32\SetWindowSubclass",
        "ptr", WorkspaceTabs.Hwnd,
        "ptr", WorkspaceTabPaintSubclassCallback,
        "uptr", 0x50445449,
        "uptr", 0,
        "int")
}

WorkspaceTabItemSubclass(hwnd, msg, wParam, lParam, subclassId, refData) {
    global WorkspaceTabPaintSubclassCallback
    if msg = 0x000F { ; WM_PAINT
        ; Paint exactly once. The previous version let Windows paint first and
        ; then painted a second expanded selected tab on top, creating the
        ; visible double white layer.
        DrawWorkspaceTabItems(hwnd)
        return 0
    }
    if msg = 0x0014 ; WM_ERASEBKGND
        return 1
    if msg = 0x0082 { ; WM_NCDESTROY
        if WorkspaceTabPaintSubclassCallback
            DllCall("comctl32\RemoveWindowSubclass",
                "ptr", hwnd, "ptr", WorkspaceTabPaintSubclassCallback,
                "uptr", subclassId, "int")
    }
    return DllCall("comctl32\DefSubclassProc",
        "ptr", hwnd, "uint", msg, "ptr", wParam, "ptr", lParam, "ptr")
}

DrawWorkspaceTabItems(hwnd) {
    global PANEL_TAB_BOTTOM_MARGIN_PX
    itemCount := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1304, "ptr", 0, "ptr", 0, "ptr") ; TCM_GETITEMCOUNT

    paint := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    hdc := DllCall("user32\BeginPaint", "ptr", hwnd,
        "ptr", paint.Ptr, "ptr")
    if !hdc
        return

    clientRect := Buffer(16, 0)
    DllCall("user32\GetClientRect", "ptr", hwnd, "ptr", clientRect.Ptr)
    backgroundBrush := DllCall("user32\GetSysColorBrush",
        "int", 15, "ptr") ; COLOR_BTNFACE
    DllCall("user32\FillRect", "ptr", hdc,
        "ptr", clientRect.Ptr, "ptr", backgroundBrush)

    if itemCount <= 0 {
        DllCall("user32\EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
        return
    }
    theme := DllCall("uxtheme\OpenThemeData",
        "ptr", hwnd, "wstr", "TAB", "ptr")
    selectedIndex := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x130B, "ptr", 0, "ptr", 0, "int") ; TCM_GETCURSEL

    hFont := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x0031, "ptr", 0, "ptr", 0, "ptr") ; WM_GETFONT
    oldFont := hFont
        ? DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", hFont, "ptr")
        : 0
    oldBkMode := DllCall("gdi32\SetBkMode",
        "ptr", hdc, "int", 1, "int") ; TRANSPARENT
    oldTextColor := DllCall("gdi32\SetTextColor", "ptr", hdc,
        "uint", DllCall("user32\GetSysColor",
            "int", 8, "uint"), "uint") ; COLOR_WINDOWTEXT

    try {
        ; Draw normal items first, selected item last so its native overlap is
        ; preserved exactly like a normal Windows tab strip.
        Loop itemCount {
            itemIndex := A_Index - 1
            if itemIndex != selectedIndex
                DrawWorkspaceTabItem(hwnd, hdc, theme, itemIndex, false)
        }
        if selectedIndex >= 0 && selectedIndex < itemCount
            DrawWorkspaceTabItem(hwnd, hdc, theme, selectedIndex, true)
    } finally {
        if oldFont
            DllCall("gdi32\SelectObject", "ptr", hdc,
                "ptr", oldFont, "ptr")
        DllCall("gdi32\SetBkMode", "ptr", hdc, "int", oldBkMode)
        DllCall("gdi32\SetTextColor", "ptr", hdc, "uint", oldTextColor)
        if theme
            DllCall("uxtheme\CloseThemeData", "ptr", theme)
        DllCall("user32\EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    }
}

DrawWorkspaceTabItem(hwnd, hdc, theme, itemIndex, selected) {
    global PANEL_TAB_BOTTOM_MARGIN_PX
    global PANEL_TAB_TEXT_VERTICAL_EXTRA_PX, PANEL_TAB_TEXT_Y_OFFSET_PX

    itemRect := Buffer(16, 0)
    if !DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x130A, "ptr", itemIndex,
        "ptr", itemRect.Ptr, "ptr") ; TCM_GETITEMRECT
        return

    label := WorkspaceTabLabelAt(itemIndex)
    if label = ""
        return

    left := NumGet(itemRect, 0, "int")
    top := NumGet(itemRect, 4, "int")
    right := NumGet(itemRect, 8, "int")
    bottom := NumGet(itemRect, 12, "int")

    ; Expand the BUTTON itself downward. Padding increases available space;
    ; it never takes space away from the text.
    selectedExpandX := selected ? 2 : 0
	selectedExpandTop := selected ? 2 : 0
	selectedExpandBottom := selected ? 1 : 0

	paintRect := Buffer(16, 0)
	NumPut("int", left - selectedExpandX, paintRect, 0)
	NumPut("int", top - selectedExpandTop, paintRect, 4)
	NumPut("int", right + selectedExpandX, paintRect, 8)
	NumPut("int",
	    bottom + PANEL_TAB_BOTTOM_MARGIN_PX + selectedExpandBottom,
	    paintRect, 12)

    stateId := selected ? 3 : 1 ; TIS_SELECTED / TIS_NORMAL
    if theme {
        DllCall("uxtheme\DrawThemeBackground",
            "ptr", theme, "ptr", hdc,
            "int", 1, "int", stateId,
            "ptr", paintRect.Ptr, "ptr", 0, "int")
    } else {
        brushIndex := selected ? 5 : 15
        brush := DllCall("user32\GetSysColorBrush",
            "int", brushIndex, "ptr")
        DllCall("user32\FillRect", "ptr", hdc,
            "ptr", paintRect.Ptr, "ptr", brush)
    }

    ; Give the label MORE vertical room than the native item, rather than
    ; subtracting top/bottom padding from it. This is the opposite of v5.7.
    textRect := Buffer(16, 0)
    extra := Max(0, PANEL_TAB_TEXT_VERTICAL_EXTRA_PX)
    yOffset := PANEL_TAB_TEXT_Y_OFFSET_PX
    NumPut("int", left + 4, textRect, 0)
    NumPut("int", top - extra + yOffset, textRect, 4)
    NumPut("int", Max(left + 5, right - 4), textRect, 8)
    NumPut("int", bottom + extra + yOffset, textRect, 12)

    drawFlags := 0x0001 | 0x0004 | 0x0020 | 0x0800 | 0x8000
        ; CENTER | VCENTER | SINGLELINE | NOPREFIX | END_ELLIPSIS
    if theme {
        DllCall("uxtheme\DrawThemeText",
            "ptr", theme, "ptr", hdc,
            "int", 1, "int", stateId,
            "wstr", label, "int", -1,
            "uint", drawFlags, "uint", 0,
            "ptr", textRect.Ptr, "int")
    } else {
        DllCall("user32\DrawTextW", "ptr", hdc,
            "wstr", label, "int", -1,
            "ptr", textRect.Ptr, "uint", drawFlags, "int")
    }
}

WorkspaceTabLabelAt(itemIndex) {
    global WorkspaceTabIds, Workspaces
    arrayIndex := itemIndex + 1
    if arrayIndex < 1 || arrayIndex > WorkspaceTabIds.Length
        return ""
    workspaceId := WorkspaceTabIds[arrayIndex]
    for workspace in Workspaces {
        if StrLower(workspace.Id) = StrLower(workspaceId)
            return workspace.Name
    }
    return ""
}

CleanupWorkspaceTabItemPadding() {
    global WorkspaceTabs, WorkspaceTabPaintSubclassCallback
    if WorkspaceTabPaintSubclassCallback {
        if IsObject(WorkspaceTabs) && WorkspaceTabs.Hwnd
            && DllCall("user32\IsWindow", "ptr", WorkspaceTabs.Hwnd, "int")
            DllCall("comctl32\RemoveWindowSubclass",
                "ptr", WorkspaceTabs.Hwnd,
                "ptr", WorkspaceTabPaintSubclassCallback,
                "uptr", 0x50445449, "int")
        CallbackFree(WorkspaceTabPaintSubclassCallback)
    }
    WorkspaceTabPaintSubclassCallback := 0
}

ApplyWorkspaceTabPadding() {
    global WorkspaceTabs
    global PANEL_TAB_PADDING_X_PX, PANEL_TAB_PADDING_Y_PX
    if !IsObject(WorkspaceTabs) || !WorkspaceTabs.Hwnd
        return
    ; TCM_SETPADDING applies to selected and unselected items alike.
    packedPadding := (PANEL_TAB_PADDING_X_PX & 0xFFFF)
        | ((PANEL_TAB_PADDING_Y_PX & 0xFFFF) << 16)
    DllCall("user32\SendMessageW", "ptr", WorkspaceTabs.Hwnd,
        "uint", 0x132B, "ptr", 0, "ptr", packedPadding, "ptr")
    DllCall("user32\SetWindowPos", "ptr", WorkspaceTabs.Hwnd,
        "ptr", 0, "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", 0x0037, "int")
    DllCall("user32\InvalidateRect", "ptr", WorkspaceTabs.Hwnd,
        "ptr", 0, "int", 1)
}

LayoutWorkspaceNavigation(width) {
    global Panel, WorkspaceTabs, WorkspaceMoreButton, TextBlockSearchEdit
    global PANEL_TAB_HEIGHT_PX
    global PANEL_SIDE_TOOLBAR_WIDTH, PANEL_SIDE_TOOLBAR_GAP
    global PANEL_SIDE_TOOLBAR_EDGE_GAP
    if !IsObject(WorkspaceTabs)
        return
    outer := PanelScale(12)
    gap := PanelScale(6)
    ; Lift the tab strip by exactly one visible pixel.
    rowY := PanelScale(6) - PanelPixelsToGui(1, Panel.Hwnd)
    rowHeight := PanelPixelsToGui(PANEL_TAB_HEIGHT_PX, Panel.Hwnd)
    railWidth := PanelPixelsToGui(PANEL_SIDE_TOOLBAR_WIDTH, Panel.Hwnd)
    railGap := PanelPixelsToGui(PANEL_SIDE_TOOLBAR_GAP, Panel.Hwnd)
    railEdgeGap := PanelPixelsToGui(
        PANEL_SIDE_TOOLBAR_EDGE_GAP, Panel.Hwnd)
    right := width - railWidth - railGap - railEdgeGap
    ; Text-block search is laid out inside the file region by ResizePanel.
    if IsObject(WorkspaceMoreButton) && WorkspaceMoreButton.Visible {
        moreWidth := PanelScale(82)
        right -= moreWidth
        WorkspaceMoreButton.Move(right, PanelScale(7),
            moreWidth, PanelScale(26))
        right -= gap
    }
    WorkspaceTabs.Move(outer, rowY,
        Max(PanelScale(180), right - outer), rowHeight)
    ApplyWorkspaceTabPadding()
    FitWorkspaceTabsToHeader()
}

FitWorkspaceTabsToHeader() {
    global WorkspaceTabs, PANEL_TAB_BOTTOM_MARGIN_PX
    if !IsObject(WorkspaceTabs) || !WorkspaceTabs.Hwnd
        return

    ; TCM_ADJUSTRECT(FALSE) gives the first row of the page pane. Cropping at
    ; exactly that boundary preserves the *entire native tab header*, including
    ; its lower themed margin, without exposing the white Tab3 page background.
    displayRect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", WorkspaceTabs.Hwnd,
        "ptr", displayRect.Ptr, "int")
        return
    DllCall("user32\SendMessageW", "ptr", WorkspaceTabs.Hwnd,
        "uint", 0x1328, "ptr", 0, "ptr", displayRect.Ptr, "ptr")
    pageTop := NumGet(displayRect, 4, "int")

    ; Fallback: find the lowest real tab item. The old code only inspected item
    ; 0 and then took Min(pageTop, itemBottom+1), which could cut away the
    ; header's lower margin and make the labels look visually bottom-heavy.
    itemCount := DllCall("user32\SendMessageW", "ptr", WorkspaceTabs.Hwnd,
        "uint", 0x1304, "ptr", 0, "ptr", 0, "ptr") ; TCM_GETITEMCOUNT
    maxItemBottom := 0
    itemRect := Buffer(16, 0)
    Loop itemCount {
        if DllCall("user32\SendMessageW", "ptr", WorkspaceTabs.Hwnd,
            "uint", 0x130A, "ptr", A_Index - 1,
            "ptr", itemRect.Ptr, "ptr") ; TCM_GETITEMRECT
            maxItemBottom := Max(maxItemBottom,
                NumGet(itemRect, 12, "int"))
    }

    ; The themed Tab3 can report pageTop above the visual bottom of the text
    ; row. Keep the lowest real tab item plus an explicit lower breathing room.
    ; This prevents glyph descenders / lower item border from being clipped.
    bottomMargin := Max(0, PANEL_TAB_BOTTOM_MARGIN_PX)
    itemTarget := maxItemBottom > 0
        ? maxItemBottom + bottomMargin : 0
    targetHeight := pageTop > 0
        ? Max(pageTop, itemTarget) : itemTarget
    if targetHeight <= 0
        return

    windowRect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", WorkspaceTabs.Hwnd,
        "ptr", windowRect.Ptr, "int")
        return
    controlWidth := Max(1, NumGet(windowRect, 8, "int")
        - NumGet(windowRect, 0, "int"))

    ; Do not crop at an individual item's bottom. Keep the native lower header
    ; margin, but stop before the white page pane starts.
    DllCall("user32\SetWindowPos", "ptr", WorkspaceTabs.Hwnd, "ptr", 0,
        "int", 0, "int", 0, "int", controlWidth,
        "int", targetHeight, "uint", 0x0016, "int")
}

GetWorkspaceContentTop() {
    global Panel, WorkspaceTabs, PANEL_TOOLBAR_HEIGHT
    fallback := PanelScale(PANEL_TOOLBAR_HEIGHT)
    if !IsObject(Panel) || !IsObject(WorkspaceTabs)
        || !Panel.Hwnd || !WorkspaceTabs.Hwnd
        return fallback

    rect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", WorkspaceTabs.Hwnd,
        "ptr", rect.Ptr, "int")
        return fallback

    ; RECT contains two POINTs. Map them from screen pixels into the panel's
    ; client pixels. MapWindowPoints may validly return zero, so don't treat
    ; its return value as a success/failure flag.
    DllCall("user32\MapWindowPoints", "ptr", 0, "ptr", Panel.Hwnd,
        "ptr", rect.Ptr, "uint", 2)

    bottomPx := NumGet(rect, 12, "int")
    if bottomPx <= 0
        return fallback

    ; RECT.bottom is exclusive. One physical pixel of overlap makes the
    ; Tab3 bottom border and ListView top border occupy the same row.
    return PanelPixelsToGui(Max(0, bottomPx - 1), Panel.Hwnd)
}

LayoutSideToolbar(width, contentTop, contentHeight) {
    global Panel
    global RefreshButton, ExpandAllFoldersButton, CollapseAllFoldersButton
    global ClipboardPinnedButton, PinnedDropButton
    global RemovePinnedButton, DisplayButton, SettingsButton
    global WindowModeButton, ToolbarSeparators
    global PANEL_SIDE_BUTTON_SIZE, PANEL_SIDE_TOOLBAR_EDGE_GAP
    global PANEL_SIDE_BUTTON_GAP, PANEL_SIDE_SEPARATOR_GAP
    global PANEL_SIDE_SEPARATOR_HEIGHT
    if !IsObject(RefreshButton)
        return
    ; Gui.Move is DPI-aware. Convert requested visible pixels to Gui units
    ; first; otherwise Windows scales 64/2/5 a second time.
    railWidth := PanelPixelsToGui(PANEL_SIDE_BUTTON_SIZE, Panel.Hwnd)
    edgeGap := PanelPixelsToGui(PANEL_SIDE_TOOLBAR_EDGE_GAP, Panel.Hwnd)
    buttonGap := PanelPixelsToGui(PANEL_SIDE_BUTTON_GAP, Panel.Hwnd)
    separatorGap := PanelPixelsToGui(PANEL_SIDE_SEPARATOR_GAP, Panel.Hwnd)
    separatorHeight := Max(1, PanelPixelsToGui(
        PANEL_SIDE_SEPARATOR_HEIGHT, Panel.Hwnd))
    topGap := PanelPixelsToGui(2, Panel.Hwnd)
    buttons := [RefreshButton, ClipboardPinnedButton,
        ExpandAllFoldersButton, CollapseAllFoldersButton, PinnedDropButton,
        RemovePinnedButton, DisplayButton, SettingsButton,
        WindowModeButton]
    ; Reference order and groups:
    ; refresh | paste | expand + collapse | add + remove | display | settings | pin
    separatorAfter := Map(1, 1, 2, 2, 4, 3, 6, 4, 7, 5, 8, 6)
    separatorCount := separatorAfter.Count
    plainGapCount := buttons.Length - 1 - separatorCount
    fixedHeight := topGap
        + separatorCount * (separatorGap * 2 + separatorHeight)
        + plainGapCount * buttonGap
    minimumButtonSize := PanelPixelsToGui(24, Panel.Hwnd)
    availableButtonSize := Floor((contentHeight - fixedHeight)
        / buttons.Length)
    buttonSize := Min(railWidth,
        Max(minimumButtonSize, availableButtonSize))
    railX := width - edgeGap - railWidth
    x := railX + Floor((railWidth - buttonSize) / 2)
    y := contentTop + topGap
    for index, control in buttons {
        control.Move(x, y, buttonSize, buttonSize)
        y += buttonSize
        if separatorAfter.Has(index) {
            separator := ToolbarSeparators[separatorAfter[index]]
            y += separatorGap
            separator.Move(railX, y, railWidth, separatorHeight)
            DllCall("user32\InvalidateRect", "ptr", separator.Hwnd,
                "ptr", 0, "int", 1)
            DllCall("user32\UpdateWindow", "ptr", separator.Hwnd)
            y += separatorHeight + separatorGap
        } else if index < buttons.Length {
            y += buttonGap
        }
    }
}

ResizeFolderDropControls(width) {
    global FolderDropAddSourceButton, FolderDropPinnedZone
    global FolderDropUiMode
    global PANEL_SIDE_TOOLBAR_WIDTH, PANEL_SIDE_TOOLBAR_GAP
    global PANEL_SIDE_TOOLBAR_EDGE_GAP
    if !IsObject(FolderDropAddSourceButton)
        return
    panelHwnd := DllCall("user32\GetParent",
        "ptr", FolderDropAddSourceButton.Hwnd, "ptr")
    sideWidth := PanelPixelsToGui(PANEL_SIDE_TOOLBAR_WIDTH, panelHwnd)
    sideGap := PanelPixelsToGui(PANEL_SIDE_TOOLBAR_GAP, panelHwnd)
    edgeGap := PanelPixelsToGui(PANEL_SIDE_TOOLBAR_EDGE_GAP, panelHwnd)
    contentWidth := width - PanelScale(12) - sideWidth - sideGap - edgeGap
    contentWidth := Max(PanelScale(160), contentWidth)
    if FolderDropUiMode = "FoldersSplit" && IsObject(FolderDropPinnedZone) {
        splitGap := PanelPixelsToGui(4, panelHwnd)
        leftWidth := Floor((contentWidth - splitGap) * 0.7)
        rightWidth := contentWidth - splitGap - leftWidth
        FolderDropAddSourceButton.Move(PanelScale(12), 0,
            leftWidth, PanelScale(30))
        FolderDropPinnedZone.Move(PanelScale(12) + leftWidth + splitGap,
            0, rightWidth, PanelScale(30))
    } else {
        FolderDropAddSourceButton.Move(PanelScale(12), 0,
            contentWidth, PanelScale(30))
    }
}

ShowFolderDropMode(mode := "Folders", itemCount := 1,
    workspaceName := "") {
    global FolderDropAddSourceButton, FolderDropPinnedZone
    global FolderDropUiVisible, FolderDropUiMode
    global ActiveWorkspaceName, PanelLayoutWidth
    if !IsObject(FolderDropAddSourceButton)
        return
    if workspaceName = ""
        workspaceName := ActiveWorkspaceName
    if mode = "Files"
        sourceText := "⭐ 松开，将文件加入固定项"
    else
        sourceText := "+ 松开，将文件添加为来源"
    pinnedText := mode = "FoldersSplit"
        ? "⭐ 松开，将文件加入固定项"
        : ""
    ; DragOver can arrive hundreds of times per second. Text assignment on a
    ; native Button invalidates its parent, so do nothing when the complete
    ; overlay state is already current.
    if FolderDropUiVisible && FolderDropUiMode = mode
        && FolderDropAddSourceButton.Text = sourceText
        && (!IsObject(FolderDropPinnedZone)
            || FolderDropPinnedZone.Text = pinnedText)
        return
    FolderDropAddSourceButton.Text := sourceText
    if IsObject(FolderDropPinnedZone)
        FolderDropPinnedZone.Text := pinnedText
    FolderDropUiMode := mode
    ResizeFolderDropControls(PanelLayoutWidth)
    ResetPanelIconHover()
    FolderDropAddSourceButton.Visible := true
    if IsObject(FolderDropPinnedZone)
        FolderDropPinnedZone.Visible := mode = "FoldersSplit"
    ; Never hide the native Tab3: the ListView pages and their registered OLE
    ; targets depend on it remaining visible. Overlay this sibling above the
    ; navigation controls instead, leaving every content drop target alive.
    DllCall("user32\SetWindowPos", "ptr",
        FolderDropAddSourceButton.Hwnd, "ptr", 0,
        "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", 0x0053, "int") ; NOMOVE|NOSIZE|NOACTIVATE|SHOWWINDOW
    if mode = "FoldersSplit" && IsObject(FolderDropPinnedZone)
        DllCall("user32\SetWindowPos", "ptr",
            FolderDropPinnedZone.Hwnd, "ptr", 0,
            "int", 0, "int", 0, "int", 0, "int", 0,
            "uint", 0x0053, "int")
    FolderDropUiVisible := true
}

HideFolderDropMode() {
    global FolderDropAddSourceButton, FolderDropPinnedZone
    global FolderDropUiVisible, FolderDropUiMode
    ; The normal state is already hidden. Avoid rebuilding Tab/status UI on
    ; every DragOver when a visible pinned group is the active drop target.
    if !FolderDropUiVisible
        return
    SetAddSourceDropHover(false)
    SetPinnedDropHover(false)
    if IsObject(FolderDropAddSourceButton)
        FolderDropAddSourceButton.Visible := false
    if IsObject(FolderDropPinnedZone)
        FolderDropPinnedZone.Visible := false
    UpdateWorkspaceTypeUi()
    FolderDropUiVisible := false
    FolderDropUiMode := ""
}

RequestNativeLayout() {
    global WorkspaceTabs
    ; Do not dereference the global Panel object here. During startup/workspace
    ; synchronization this helper can run while that global is still in its
    ; numeric sentinel state. The tab control already exists at every valid
    ; call site, so obtain the owner HWND directly from Win32 instead.
    if !IsObject(WorkspaceTabs) || !WorkspaceTabs.Hwnd
        return
    panelHwnd := DllCall("user32\GetParent",
        "ptr", WorkspaceTabs.Hwnd, "ptr")
    if !panelHwnd
        return
    if !DllCall("user32\IsWindowVisible", "ptr", panelHwnd, "int")
        return

    ; Gui.OnEvent("Size") receives DPI-adjusted coordinates only when AHK
    ; dispatches a real WM_SIZE. Calling ResizePanel directly bypasses that
    ; conversion and makes controls too wide on high-DPI displays.
    clientRect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect",
        "ptr", panelHwnd, "ptr", clientRect.Ptr)
        return
    clientWidth := NumGet(clientRect, 8, "int") - NumGet(clientRect, 0, "int")
    clientHeight := NumGet(clientRect, 12, "int") - NumGet(clientRect, 4, "int")
    packedSize := (clientWidth & 0xFFFF) | ((clientHeight & 0xFFFF) << 16)
    DllCall("user32\PostMessageW", "ptr", panelHwnd, "uint", 0x0005,
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
    if IsObject(WindowModeButton) {
        enabled := WindowMode = WINDOW_MODE_ALWAYS_ON_TOP
        SetPanelIconButtonAlternate(WindowModeButton, enabled)
        SetPanelIconButtonSelected(WindowModeButton, enabled)
        SetPanelIconButtonTooltip(WindowModeButton,
            enabled ? "窗口置顶：开（点击关闭）" : "窗口置顶：关（点击开启）")
    }
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
        FileView.ModifyCol(1, PanelScale(360))
        FileView.ModifyCol(2, PanelScale(132))
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
    ; LVM_SETICONSPACING uses raw pixels, matching the configured thumbnail
    ; edge and ImageList. Windows DPI must not multiply these values again.
    horizontalSpacing := PanelScale(
        ThumbnailSize + ThumbnailHorizontalGap)
    verticalSpacing := PanelScale(
        ThumbnailSize + ThumbnailVerticalGap)
        + GetThumbnailLabelReserve()
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
    lineHeight := PanelScale(20)
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
    maxTextWidth := Max(PanelScale(8), PanelScale(ThumbnailSize - 12))
    measuredWidth := MeasureListViewText(label, hdc)
    if measuredWidth >= 0 && measuredWidth <= maxTextWidth
        return label

    ellipsis := "…"
    ellipsisWidth := MeasureListViewText(ellipsis, hdc)
    if measuredWidth < 0 || ellipsisWidth < 0 {
        ; GetDC is expected to succeed for a live ListView. Keep a conservative
        ; fallback for unusual themes or teardown timing.
        fallbackCharWidth := PanelScale(14)
        fallbackLength := Max(1, Floor(maxTextWidth / fallbackCharWidth))
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
