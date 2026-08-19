; PopDrop native settings UI (AutoHotkey v2).
; All controls edit an isolated draft. Disk and runtime state are touched only
; by SaveSettingsDraft().

OpenConfig(*) {
    OpenSettingsGui()
}

OpenAboutPopDrop(*) {
    c := OpenSettingsGui()
    if IsObject(c)
        ShowSettingsPage(c, 7)
}

OpenAboutUrl(url, *) {
    try Run(url)
    catch as err {
        global SettingsController
        if IsObject(SettingsController)
            SettingsMessage(SettingsController,
                "无法打开链接：`n" url "`n`n" err.Message,
                "打开链接失败", "Icon!")
    }
}

OpenFileManagerSettings() {
    c := OpenSettingsGui()
    if !IsObject(c)
        return false
    ShowSettingsPage(c, 2)
    try c.FileManagerProvider.Focus()
    return true
}

OpenSourceSettings(workspaceId, sourceId) {
    c := OpenSettingsGui()
    if !IsObject(c)
        return false
    if IsObject(c.Child) {
        try WinActivate("ahk_id " c.Child.Hwnd)
        SettingsMessage(c,
            "请先完成或关闭当前设置子窗口，然后再定位来源。",
            "无法定位来源", "Icon!")
        return false
    }
    target := ResolveDraftSourceNavigation(
        c.Draft, workspaceId, sourceId)
    if !target.WorkspaceFound {
        SettingsMessage(c, "目标工作区已经不存在。",
            "无法定位来源", "Icon!")
        return false
    }
    if SettingsDraftHasChanges(c) {
        answer := SettingsMessage(c,
            "设置尚未保存。`n`n"
            . "“是”：保存草稿后定位来源`n"
            . "“否”：放弃草稿后定位来源`n"
            . "“取消”：保持当前页面和选择",
            "设置此来源", "YesNoCancel Icon!")
        action := ResolveSettingsConflictAction(answer)
        if action = "Cancel"
            return false
        if action = "Save" {
            if !SaveSettingsDraftCore(c, false)
                return false
        } else {
            ReloadSettingsDraft(c)
        }
        target := ResolveDraftSourceNavigation(
            c.Draft, workspaceId, sourceId)
        if !target.WorkspaceFound {
            SettingsMessage(c, "目标工作区已经不存在。",
                "无法定位来源", "Icon!")
            return false
        }
    }
    if StrLower(c.Draft.CurrentWorkspaceId)
        != StrLower(workspaceId) {
        if !ActivateWorkspace(workspaceId)
            return false
        ReloadSettingsDraft(c)
    } else {
        ; Selecting another source is lossless inside the same isolated
        ; draft. Commit the currently visible controls before changing rows.
        CommitCurrentSourceControlsToDraft(c)
    }
    return NavigateSettingsToSource(c, workspaceId, sourceId)
}

ResolveDraftSourceNavigation(draft, workspaceId, sourceId) {
    result := {
        WorkspaceFound: false,
        SourceFound: false,
        WorkspaceIndex: 0,
        SourceIndex: 0
    }
    for workspaceIndex, workspace in draft.Workspaces {
        if StrLower(workspace.Id) != StrLower(workspaceId)
            continue
        result.WorkspaceFound := true
        result.WorkspaceIndex := workspaceIndex
        for sourceIndex, source in workspace.Sources {
            if StrLower(source.SourceId) = StrLower(sourceId) {
                result.SourceFound := true
                result.SourceIndex := sourceIndex
                break
            }
        }
        break
    }
    return result
}

ShowSettingsPage(c, page) {
    if c.NavItems.Has(page)
        c.Navigation.Modify(c.NavItems[page], "Select Vis")
    c.Tab.Choose(page)
}

NavigateSettingsToSource(c, workspaceId, sourceId) {
    if StrLower(c.Draft.CurrentWorkspaceId)
        != StrLower(workspaceId)
        return false
    target := ResolveDraftSourceNavigation(
        c.Draft, workspaceId, sourceId)
    ShowSettingsPage(c, 6)
    RefreshSourceList(c, sourceId, false)
    if !target.SourceFound {
        c.SourceStatus.Text := "目标来源已经不存在。"
        SetUserStatus("目标来源已经不存在")
        return false
    }
    try c.SourceList.Focus()
    return StrLower(c.SelectedSourceId) = StrLower(sourceId)
}

OpenSettingsGui() {
    global Panel, SettingsDialog, SettingsController, UiScaleFactor

    CancelFilePointerGesture()
    PreviewSuppress("settings", false)
    if IsObject(SettingsDialog) {
        try {
            WinRestore("ahk_id " SettingsDialog.Hwnd)
            SettingsDialog.Show()
            WinActivate("ahk_id " SettingsDialog.Hwnd)
            return SettingsController
        }
    }
    ; A destroyed Gui object remains an object, but reading Hwnd throws. Clear
    ; any stale publication before constructing the replacement controller.
    if IsObject(SettingsController) && HasProp(SettingsController, "Ready")
        SettingsController.Ready := false
    SettingsDialog := 0
    SettingsController := 0

    BeginAutoHidePause()
    try {
    draft := LoadSettingsIntoDraft()
    guiObj := Gui("+Owner" Panel.Hwnd " -MaximizeBox -MinimizeBox",
        "PopDrop 设置")
    guiObj.MarginX := 14
    guiObj.MarginY := 12
    guiObj.SetFont("s" Round(9 * UiScaleFactor), "Microsoft YaHei UI")
    controller := {
        Gui: guiObj,
        Draft: draft,
        OriginalSignature: SettingsDraftSignature(draft),
        Ready: false,
        Loading: false,
        SelectedSourceId: "",
        SourceRows: Map(),
        SelectedAppId: "",
        AppRows: Map(),
        SelectedTargetId: "",
        TargetRows: Map(),
        Child: 0,
        ClosingAfterSave: false
    }
    navigation := guiObj.AddTreeView("xm ym w156 h752 +0x20")
    sharedRoot := navigation.Add("共享设置", 0, "Expand")
    navGeneral := navigation.Add("通用", sharedRoot)
    navOperations := navigation.Add("文件打开与操作", sharedRoot)
    navDisplay := navigation.Add("文件显示与过滤", sharedRoot)
    navInterface := navigation.Add("界面设置", sharedRoot)
    navContentUpdate := navigation.Add("内容更新方式", sharedRoot)
    workspaceRoot := navigation.Add("工作区设置", 0, "Expand")
    navWorkspace := navigation.Add("当前工作区", workspaceRoot)
    navAbout := navigation.Add("关于 PopDrop")
    controller.Navigation := navigation
    controller.NavPages := Map(
        navGeneral, 1, navOperations, 2, navDisplay, 3, navInterface, 4,
        navContentUpdate, 5, navWorkspace, 6, navAbout, 7)
    controller.NavItems := Map(
        1, navGeneral, 2, navOperations, 3, navDisplay, 4, navInterface,
        5, navContentUpdate, 6, navWorkspace, 7, navAbout)
    ; Tab3 remains the native page host, but its duplicate tab strip is placed
    ; above the client area. The TreeView is the only visible page navigation.
    tabs := guiObj.AddTab3("x184 y-26 w852 h790 -Tabstop",
        ["共享设置 · 通用", "共享设置 · 文件打开与操作",
         "共享设置 · 文件显示与过滤", "共享设置 · 界面设置",
         "共享设置 · 内容更新方式", "当前工作区", "关于 PopDrop"])
    controller.Tab := tabs
    BuildGeneralSettingsPage(controller, tabs)
    BuildSourcesSettingsPage(controller, tabs)
    BuildOperationsSettingsPage(controller, tabs)
    BuildDisplaySettingsPage(controller, tabs)
    BuildInterfaceSettingsPage(controller, tabs)
    BuildContentUpdateSettingsPage(controller, tabs)
    BuildAboutSettingsPage(controller, tabs)
    tabs.UseTab()

    ; Tab3's hidden header otherwise leaves its white page background touching
    ; the title bar. This native, non-focusable spacer restores the same top
    ; margin as the navigation TreeView and keeps the exposed area gray.
    guiObj.AddProgress(
        "x184 y0 w852 h12 -Smooth -Theme BackgroundF0F0F0 cF0F0F0", 100)

    ; Footer controls must use an absolute Y below the Tab3 rectangle.
    ; A relative y+ value would be based on the last control created on the
    ; active tab page, placing the footer underneath Tab3 where it is visible
    ; but cannot receive mouse input.
    advanced := AddUiButton(guiObj, "x184 y776 w112", "高级设置…")
    guiObj.AddText("x+8 yp+7 w400 c666666",
        "直接编辑 config.ini，适合高级用户。")
    save := AddUiButton(guiObj, "x860 yp-7 w78 Default", "保存")
    cancel := AddUiButton(guiObj, "x+8 yp w78", "取消")
    advanced.OnEvent("Click", AdvancedSettingsClicked.Bind(controller))
    cancel.OnEvent("Click", RequestCloseSettings.Bind(controller))
    save.OnEvent("Click", SaveSettingsDraft.Bind(controller))
    navigation.OnEvent(
        "ItemSelect", SettingsNavigationSelected.Bind(controller))
    tabs.OnEvent("Change", SettingsTabChanged.Bind(controller))
    guiObj.OnEvent("Close", RequestCloseSettings.Bind(controller))
    guiObj.OnEvent("Escape", RequestCloseSettings.Bind(controller))

    RefreshSourceList(controller)
    RefreshApplicationList(controller)
    RefreshDestinationList(controller)
    RefreshExcludedNameList(controller)
    LoadGeneralControls(controller)
    LoadDisplayControls(controller)
    LoadInterfaceControls(controller)
    LoadContentUpdateControls(controller)
    navigation.Modify(navGeneral, "Select Vis")
    guiObj.Show("w1050 h820")
    ; Do not publish a partially constructed controller. Panel timers and
    ; toolbar state synchronization can interrupt GUI construction on Windows;
    ; exposing the controller earlier lets them call handlers whose controls
    ; do not exist yet.
    controller.Ready := true
    SettingsController := controller
    SettingsDialog := guiObj
    return controller
    } catch as err {
        SettingsDialog := 0
        SettingsController := 0
        if IsSet(controller) && IsObject(controller)
            controller.Ready := false
        if IsSet(guiObj)
            try guiObj.Destroy()
        try EndAutoHidePause()
        try PreviewRecoverAfterInteraction()
        throw err
    }
}

SettingsControllerIsReady(c) {
    if !IsObject(c) || !HasProp(c, "Ready") || !c.Ready
        return false
    try return c.Gui.Hwnd != 0
    catch
        return false
}

SettingsNavigationSelected(c, tree, item) {
    if !c.NavPages.Has(item)
        return
    CommitCurrentSourceControlsToDraft(c)
    c.Tab.Choose(c.NavPages[item])
}

LoadSettingsIntoDraft() {
    global GlobalOpenFileMode, ConfiguredHotkey, DoubleHotkeyWorkspaceId
    global LastFileWorkspaceId
    global WindowMode, EscapeHidesPanel
    global DefaultContextMenu
    global ShowRecentSidebar, RecentFileCount, MaxFilesPerFolder, SortMode
    global LastValidFolderSettings, OpenApps, TransferFavorites, RecentTargets
    global TransferFavoriteLabels, GlobalExcludedFolderNames
    global GlobalNoiseFilter, Workspaces, ActiveWorkspaceId
    global TransferUrlFallbackEnabled, TransferAllowHttp
    global TransferMaxConcurrent, TransferShowNotifications
    global FileManagerProvider, FileManagerExecutable
    global PreviewEnabled, PreviewSide, PreviewCacheEnabled
    global PreviewDocumentEnabled, PreviewPdfEnabled
    global PreviewShowFileInfo
    global ContentUpdateMode
    global UiScaleMode, ThumbnailSize, ThumbnailHorizontalGap
    global ThumbnailVerticalGap, ThumbnailTextLines
    global FileViewGroupTopSpacing, FileViewGroupBottomSpacing
    global WindowWidth, WindowHeight
    global TextBlockCardWidth, TextBlockCardHeight
    global ThumbnailPolicy
    global ExternalQuickPreviewProvider
    global SeerIntegrationEnabled, QuickLookPath

    workspaceDrafts := []
    activeSources := []
    for workspace in Workspaces {
        sources := []
        for source in workspace.Sources
            sources.Push(CloneSettingsSource(source))
        workspaceDraft := {
            Id: workspace.Id,
            Name: workspace.Name,
            Type: workspace.Type,
            Hotkey: workspace.Hotkey,
            Sources: sources,
            PinnedPaths: workspace.PinnedPaths.Clone()
        }
        workspaceDrafts.Push(workspaceDraft)
        if StrLower(workspace.Id) = StrLower(ActiveWorkspaceId)
            activeSources := sources
    }
    apps := []
    for app in OpenApps
        apps.Push(CloneSettingsApplication(app))
    destinations := []
    for path in TransferFavorites {
        key := PathKey(path)
        label := TransferFavoriteLabels.Has(key)
            ? TransferFavoriteLabels[key] : GetFileName(path)
        if label = ""
            label := path
        destinations.Push({
            Id: "destination-" HashString(key),
            Name: label,
            Path: NormalizePath(path)
        })
    }
    return {
        General: {
            OpenFileMode: ParseGlobalOpenFileMode(GlobalOpenFileMode),
            DefaultContextMenu: ParseDefaultContextMenu(DefaultContextMenu),
            Hotkey: ConfiguredHotkey,
            StartupEnabled: ReadStartupEnabled(),
            DoubleHotkeyWorkspaceId: DoubleHotkeyWorkspaceId,
            LastFileWorkspaceId: LastFileWorkspaceId,
            WindowMode: WindowMode,
            EscapeHidesPanel: EscapeHidesPanel,
            ShowRecentSidebar: ShowRecentSidebar,
            RecentFileCount: RecentFileCount,
            MaxFilesPerFolder: MaxFilesPerFolder,
            SortMode: SortMode,
            EnablePublicUrlFallback: TransferUrlFallbackEnabled,
            AllowHttp: TransferAllowHttp,
            TransferMaxConcurrent: TransferMaxConcurrent,
            ShowCompletionNotifications: TransferShowNotifications,
            FileManagerProvider: ParseFileManagerProvider(
                FileManagerProvider),
            FileManagerExecutable: FileManagerExecutable,
            PreviewEnabled: PreviewEnabled,
            PreviewSide: PreviewSide,
            PreviewCacheEnabled: PreviewCacheEnabled,
            PreviewDocumentEnabled: PreviewDocumentEnabled,
            PreviewPdfEnabled: PreviewPdfEnabled,
            PreviewShowFileInfo: PreviewShowFileInfo,
            QuickPreviewProvider: ExternalQuickPreviewProvider,
            SeerIntegrationEnabled: SeerIntegrationEnabled,
            QuickLookPath: QuickLookPath,
            ContentUpdateMode: ContentUpdateMode,
            UiScaleMode: UiScaleMode,
            WindowWidth: WindowWidth,
            WindowHeight: WindowHeight,
            ThumbnailPolicy: ThumbnailPolicy,
            ThumbnailSize: ThumbnailSize,
            ThumbnailHorizontalGap: ThumbnailHorizontalGap,
            ThumbnailVerticalGap: ThumbnailVerticalGap,
            FileViewGroupTopSpacing: FileViewGroupTopSpacing,
            FileViewGroupBottomSpacing: FileViewGroupBottomSpacing,
            ThumbnailTextLines: ThumbnailTextLines,
            TextBlockCardWidth: TextBlockCardWidth,
            TextBlockCardHeight: TextBlockCardHeight,
            DefaultDisplayScope: ReadGlobalDisplayScopeForDraft(),
            DefaultFolderTimeMode: ReadGlobalFolderTimeForDraft(),
            DefaultFilter: ReadGlobalFilterForDraft(),
            NoiseFilter: {Enabled: GlobalNoiseFilter.Enabled,
                HideHidden: GlobalNoiseFilter.HideHidden,
                HideSystem: GlobalNoiseFilter.HideSystem,
                HideTemporary: GlobalNoiseFilter.HideTemporary,
                HideIncompleteDownloads: GlobalNoiseFilter.HideIncompleteDownloads,
                CustomPatternTexts: GlobalNoiseFilter.CustomPatternTexts.Clone()}
        },
        Workspaces: workspaceDrafts,
        CurrentWorkspaceId: ActiveWorkspaceId,
        Sources: activeSources,
        Applications: apps,
        CommonDestinations: destinations,
        RecentDestinations: RecentTargets.Clone(),
        GlobalExcludedNames: GlobalExcludedFolderNames.Clone()
    }
}

FindDraftWorkspace(c, workspaceId := "") {
    if workspaceId = ""
        workspaceId := c.Draft.CurrentWorkspaceId
    for index, workspace in c.Draft.Workspaces {
        if StrLower(workspace.Id) = StrLower(workspaceId)
            return {Index: index, Value: workspace}
    }
    return 0
}

ReadGlobalDisplayScopeForDraft() {
    global ConfigPath, SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS
    global SCOPE_RECURSIVE_FILES
    raw := StrLower(Trim(IniRead(ConfigPath,
        "General", "DisplayScope", SCOPE_FILES_ONLY)))
    if raw = StrLower(SCOPE_FILES_AND_FOLDERS)
        return SCOPE_FILES_AND_FOLDERS
    if raw = StrLower(SCOPE_RECURSIVE_FILES)
        return SCOPE_RECURSIVE_FILES
    return SCOPE_FILES_ONLY
}

ReadGlobalFolderTimeForDraft() {
    global ConfigPath, FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    raw := StrLower(Trim(IniRead(ConfigPath,
        "General", "FolderTimeMode", FOLDER_TIME_MODIFIED)))
    return raw = StrLower(FOLDER_TIME_LATEST_CONTENT)
        ? FOLDER_TIME_LATEST_CONTENT : FOLDER_TIME_MODIFIED
}

ReadGlobalFilterForDraft() {
    global ConfigPath
    mode := StrLower(Trim(IniRead(ConfigPath,
        "General", "FilterMode", "All")))
    extensions := IniRead(ConfigPath, "General", "FileExtensions", "")
    parsed := ParseFilterSettings(mode, extensions, "[General]")
    if HasProp(parsed, "Error")
        return {Mode: "All", Extensions: []}
    return {Mode: parsed.Mode, Extensions: parsed.Extensions.Clone()}
}

LoadGlobalExcludedFolderNames() {
    global ConfigPath
    result := []
    seen := Map()
    for entry in ReadIniSection("ExcludedFolderNames") {
        if !RegExMatch(entry.Key, "i)^Name\d+$")
            continue
        name := Trim(entry.Value)
        key := StrLower(name)
        if name != "" && !InStr(name, "\") && !InStr(name, "/")
            && !seen.Has(key) {
            seen[key] := true
            result.Push(name)
        }
    }
    initialized := IniRead(ConfigPath, "General",
        "GlobalExcludedNamesInitialized", "0") = "1"
    ; Existing configurations predate this setting. Seed only the migration
    ; default; once the settings page has been saved, an intentionally empty
    ; list remains empty because the initialized marker is persisted.
    if !initialized && !seen.Has(".git")
        result.InsertAt(1, ".git")
    return result
}

LoadConfiguredSourcePaths(section, sourceRoot) {
    result := []
    for entry in ReadIniSection(section) {
        if !RegExMatch(entry.Key, "i)^Path\d+$")
            continue
        raw := Trim(entry.Value)
        if raw = ""
            continue
        path := RegExMatch(raw, "i)^(?:[A-Z]:\\|\\\\)")
            ? NormalizePath(raw) : NormalizePath(sourceRoot "\" raw)
        if !PathsEqual(path, sourceRoot)
            && IsSameOrDescendantPath(path, sourceRoot)
            && !ArrayContainsPath(result, path)
            result.Push(path)
    }
    return result
}

LoadTransferFavoriteLabels(paths) {
    labels := Map()
    configured := ReadIniSection("TransferFavoriteLabels")
    for index, path in paths {
        keyName := "Path" Format("{:03}", index)
        label := ""
        for entry in configured {
            if StrLower(entry.Key) = StrLower(keyName) {
                label := Trim(entry.Value)
                break
            }
        }
        if label != ""
            labels[PathKey(path)] := label
    }
    return labels
}

CloneSettingsSource(source) {
    return {
        Name: source.Name,
        OriginalName: HasProp(source, "OriginalName")
            ? source.OriginalName : source.Name,
        Path: NormalizePath(source.Path),
        Mode: source.Mode,
        IncludeSubfolders: source.IncludeSubfolders,
        DisplayScope: source.DisplayScope,
        FolderTimeMode: source.FolderTimeMode,
        MaxFilesPerFolder: source.MaxFilesPerFolder,
        MaxFilesPerFolderInherited:
            HasProp(source, "MaxFilesPerFolderInherited")
                ? source.MaxFilesPerFolderInherited : false,
        SortMode: source.SortMode,
        Filter: {
            Mode: source.Filter.Mode,
            Extensions: source.Filter.Extensions.Clone()
        },
        StripOrderPrefix: source.StripOrderPrefix,
        HideExtensions: source.HideExtensions,
        SourceId: source.SourceId,
        OpenFileMode: ParseSourceOpenFileMode(source.OpenFileMode),
        NoiseFilterMode: ParseNoiseFilterMode(source.NoiseFilterMode),
        SourceCustomPatternTexts: source.SourceCustomPatternTexts.Clone(),
        ExcludedPaths: HasProp(source, "ExcludedPaths")
            ? source.ExcludedPaths.Clone() : [],
        AllowedExcludedPaths: HasProp(source, "AllowedExcludedPaths")
            ? source.AllowedExcludedPaths.Clone() : []
    }
}

CloneSettingsApplication(app) {
    actions := []
    for action in app.Actions
        actions.Push(CloneOpenAppAction(action))
    return {
        Id: app.Id,
        Path: NormalizePath(app.Path),
        Name: app.Name,
        Icon: app.Icon,
        Extensions: app.Extensions.Clone(),
        Enabled: app.Enabled,
        ShowInOpenMenu: app.ShowInOpenMenu,
        Actions: actions
    }
}

BuildGeneralSettingsPage(c, tabs) {
    tabs.UseTab(1)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h126", "打开文件 · 应用于所有工作区")
    c.GlobalDouble := g.AddRadio("x220 y58 Group", "双击（默认）")
    c.GlobalSingle := g.AddRadio("x350 yp", "单击")
    g.AddText("x220 y94 w770 h48 c555555",
        "单击会立即打开文件。按住 Ctrl 或 Shift 可以多选，拖拽不受影响；"
        . "文件夹仍然需要双击打开。"
        . "`n可在「当前工作区」页中为每个来源单独配置打开方式。")

    g.AddGroupBox("x200 y165 w818 h82", "快捷键 · 应用于所有工作区")
    g.AddText("x220 y196 w150", "呼出/隐藏 PopDrop：")
    c.Hotkey := g.AddHotkey("x375 yp-4 w220 h26")
    g.AddText("x615 yp+4 w86", "默认文本区：")
    c.DoubleHotkeyWorkspace := AddUiDropDownList(
        g, "x700 yp-4 w280", ["关闭"])
    g.AddText("x220 y224 w760 h18 c555555",
        "面板隐藏时：单击进入最近文件区，快速双击进入默认文本区；面板显示时：主快捷键只关闭。")

    g.AddGroupBox("x200 y257 w818 h104", "窗口 · 应用于所有工作区")
    g.AddText("x220 y288 w150", "窗口显示方式：")
    c.WindowMode := AddUiDropDownList(g, "x375 yp-4 w260 Choose1",
        ["始终置顶", "临时置顶（失去焦点后隐藏）", "普通窗口"])
    c.EscapeHide := g.AddCheckBox("x220 y326",
        "按 Esc 隐藏 PopDrop")

    g.AddGroupBox("x200 y371 w818 h126", "右键菜单 · 应用于所有工作区")
    c.ContextMenuPopDrop := g.AddRadio(
        "x220 y400 Group", "PopDrop 快捷菜单（推荐）")
    c.ContextMenuSystem := g.AddRadio(
        "x500 yp", "Windows 系统菜单")
    c.ContextMenuDescription := g.AddText(
        "x220 y434 w770 h48 c555555", "")

    g.AddGroupBox("x200 y507 w818 h126", "下载 · 应用于所有工作区")
    c.EnableUrlFallback := g.AddCheckBox("x220 y536",
        "允许公开 HTTPS 文件 URL 作为最后兜底")
    c.AllowHttp := g.AddCheckBox("x580 yp",
        "允许不加密 HTTP（不推荐）")
    g.AddText("x220 y576 w118", "后台最大并发：")
    c.TransferMax := AddUiEdit(g, "x340 yp-4 w62 Number")
    g.AddText("x410 yp+4 w100 c666666", "（1–6）")
    c.TransferNotify := g.AddCheckBox("x580 yp",
        "面板隐藏时显示批次完成通知")

    g.AddGroupBox("x200 y647 w818 h90", "开机启动")
    c.StartupEnabled := g.AddCheckBox("x220 y676",
        "登录 Windows 后自动启动 PopDrop")
    g.AddText("x500 y680 w480 h36 c666666",
        "通过当前用户的启动文件夹创建快捷方式；关闭后会自动移除。")

    c.GlobalDouble.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.GlobalSingle.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.Hotkey.OnEvent("Change", GeneralControlChanged.Bind(c))
    c.DoubleHotkeyWorkspace.OnEvent(
        "Change", GeneralControlChanged.Bind(c))
    c.WindowMode.OnEvent("Change", GeneralControlChanged.Bind(c))
    c.EscapeHide.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.ContextMenuPopDrop.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.ContextMenuSystem.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.EnableUrlFallback.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.AllowHttp.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.TransferMax.OnEvent("Change", GeneralControlChanged.Bind(c))
    c.TransferNotify.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.StartupEnabled.OnEvent("Click", GeneralControlChanged.Bind(c))
}

BuildSourcesSettingsPage(c, tabs) {
    tabs.UseTab(6)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h66", "当前工作区")
    g.AddText("x220 y54 w86", "当前工作区：")
    c.WorkspaceDropDown := AddUiDropDownList(g, "x310 yp-4 w110", [])
    c.WorkspaceManage := AddUiButton(g, "x+10 yp w130", "管理工作区…")
    c.WorkspaceScopeHint := g.AddText("x580 yp+4 w120 c555555", "")
    g.AddText("x710 yp w74", "单次直达键：")
    c.WorkspaceHotkey := g.AddHotkey("x790 yp-4 w195 h26")
    c.SourceList := g.AddListView(
        "x200 y106 w818 h110 Report -Multi NoSortHdr",
        ["来源", "路径", "状态"])
    c.SourceList.ModifyCol(1, 155)
    c.SourceList.ModifyCol(2, 510)
    c.SourceList.ModifyCol(3, 125)
    c.SourceAdd := AddUiButton(g, "x200 y226 w88", "添加来源")
    c.SourceRemove := AddUiButton(g, "x+7 yp w72", "移除")
    c.SourceUp := AddUiButton(g, "x+7 yp w72", "上移")
    c.SourceDown := AddUiButton(g, "x+7 yp w72", "下移")

    g.AddGroupBox("x200 y264 w818 h362", "来源设置")
    g.AddText("x220 y299 w70", "名称：")
    c.SourceName := AddUiEdit(g, "x292 yp-4 w300")
    g.AddText("x620 yp+4 w90", "文件夹类型：")
    c.SourceType := AddUiDropDownList(g, "x710 yp-4 w275",
        ["普通文件夹（Files）", "启动器文件夹（Launcher）"])
    g.AddText("x220 y337 w70", "文件夹：")
    c.SourcePath := AddUiEdit(g, "x292 yp-4 w532")
    c.SourceBrowse := AddUiButton(g, "x+7 yp w70", "浏览…")
    c.SourceOpen := AddUiButton(g, "x+7 yp w62", "打开")
    g.AddText("x220 y375 w100", "显示内容：")
    c.SourceScope := AddUiDropDownList(g, "x324 yp-4 w420",
        ["仅当前文件夹中的文件",
         "当前文件夹中的文件和子文件夹",
         "包含所有子文件夹中的文件，并平铺显示"])
    g.AddText("x220 y413 w100", "打开文件：")
    c.SourceOpenMode := AddUiDropDownList(g, "x324 yp-4 w420",
        ["使用共享默认值（当前：双击）", "单击", "双击"])
    g.AddText("x220 y451 w100", "文件夹排序：")
    c.SourceFolderTime := AddUiDropDownList(g, "x324 yp-4 w250",
        ["文件夹修改时间", "文件夹内最新内容时间"])
    c.SourceFolderTimeHint := g.AddText("x590 yp+4 w330 c666666",
        "仅在直接显示子文件夹时生效")
    g.AddText("x220 y489 w100", "显示数量：")
    c.SourceMaxMode := AddUiDropDownList(g, "x324 yp-4 w210",
        ["继承全局（当前：" c.Draft.General.MaxFilesPerFolder "）",
         "自定义数量", "显示全部"])
    c.SourceMax := AddUiEdit(g, "x544 yp w72 Number")
    g.AddText("x630 yp+4 w70", "排序：")
    c.SourceSort := AddUiDropDownList(g, "x700 yp-4 w220",
        ["修改时间（最新在前）", "名称（升序）", "智能优先"])
    g.AddText("x220 y527 w100", "排除噪音文件：")
    c.SourceNoiseMode := AddUiDropDownList(g, "x324 yp-4 w250",
        ["使用共享默认值", "启用", "禁用"])
    c.SourceNoiseRules := AddUiButton(g, "x590 yp w132", "附加忽略规则…")
    c.SourceNoiseRuleCount := g.AddText("x735 yp+4 w180 c666666", "0 条附加规则")
    c.ExcludedCount := g.AddText("x220 y565 w190", "排除子文件夹：0 个")
    c.ManageExcluded := AddUiButton(g, "x410 yp-5 w82", "管理…")
    c.AllowedCount := g.AddText("x560 yp+5 w220", "允许覆盖共享排除：0 个")
    c.ManageAllowed := AddUiButton(g, "x788 yp-5 w82", "管理…")
    c.SourceStatus := g.AddText("x220 y600 w760 h18 c666666", "")

    c.WorkspaceDropDown.OnEvent(
        "Change", SettingsWorkspaceChanged.Bind(c))
    c.WorkspaceManage.OnEvent(
        "Click", OpenWorkspaceManager.Bind(c))
    c.WorkspaceHotkey.OnEvent(
        "Change", WorkspaceHotkeyChanged.Bind(c))
    c.SourceList.OnEvent("ItemSelect", SourceSelected.Bind(c))
    c.SourceAdd.OnEvent("Click", AddSourceToDraft.Bind(c))
    c.SourceRemove.OnEvent("Click", RemoveSourceFromDraft.Bind(c))
    c.SourceUp.OnEvent("Click", MoveSourceInDraft.Bind(c, -1))
    c.SourceDown.OnEvent("Click", MoveSourceInDraft.Bind(c, 1))
    c.SourceBrowse.OnEvent("Click", BrowseSourcePath.Bind(c))
    c.SourceOpen.OnEvent("Click", OpenSelectedSourcePath.Bind(c))
    c.ManageExcluded.OnEvent("Click",
        OpenSourcePathManager.Bind(c, "ExcludedPaths"))
    c.ManageAllowed.OnEvent("Click",
        OpenSourcePathManager.Bind(c, "AllowedExcludedPaths"))
    c.SourceNoiseRules.OnEvent("Click", OpenSourceIgnoreRules.Bind(c))
    c.SourceType.OnEvent("Change", SourceTypeChanged.Bind(c))
    for ctrl in [c.SourceName, c.SourcePath, c.SourceScope,
        c.SourceOpenMode, c.SourceFolderTime, c.SourceMaxMode,
        c.SourceMax, c.SourceSort,
        c.SourceNoiseMode]
        ctrl.OnEvent("Change", SourceControlChanged.Bind(c))
    RefreshSettingsWorkspaceControls(c)
}

RefreshSettingsWorkspaceControls(c) {
    global WORKSPACE_TYPE_TEXT
    if !HasProp(c, "WorkspaceDropDown")
        return
    c.WorkspaceIds := []
    names := []
    selected := 1
    for index, workspace in c.Draft.Workspaces {
        names.Push(workspace.Name)
        c.WorkspaceIds.Push(workspace.Id)
        if StrLower(workspace.Id)
            = StrLower(c.Draft.CurrentWorkspaceId)
            selected := index
    }
    c.Loading := true
    try {
        ReplaceUiDropDownItems(c.WorkspaceDropDown, names)
        if names.Length
            c.WorkspaceDropDown.Choose(selected)
        found := FindDraftWorkspace(c)
        if IsObject(found) {
            c.Draft.Sources := found.Value.Sources
            c.WorkspaceScopeHint.Text := ParseWorkspaceType(found.Value.Type)
                = WORKSPACE_TYPE_TEXT ? "文本块工作区" : "文件工作区"
            c.WorkspaceHotkey.Value := found.Value.Hotkey
        }
    } finally c.Loading := false
    c.SelectedSourceId := ""
    RefreshSourceList(c)
    UpdateWorkspaceSourceControls(c)
}

WorkspaceHotkeyChanged(c, *) {
    if c.Loading
        return
    found := FindDraftWorkspace(c)
    if IsObject(found)
        found.Value.Hotkey := Trim(c.WorkspaceHotkey.Value)
}

UpdateWorkspaceSourceControls(c) {
    global WORKSPACE_TYPE_TEXT
    found := FindDraftWorkspace(c)
    textMode := IsObject(found)
        && ParseWorkspaceType(found.Value.Type) = WORKSPACE_TYPE_TEXT
    if HasProp(c, "SourceType")
        c.SourceType.Enabled := !textMode && c.SelectedSourceId != ""
    if HasProp(c, "SourceScope")
        c.SourceScope.Enabled := !textMode && c.SelectedSourceId != ""
    if HasProp(c, "SourceSort")
        c.SourceSort.Enabled := c.SelectedSourceId != ""
}

SettingsWorkspaceChanged(c, control, *) {
    if c.Loading
        return
    index := control.Value
    if index < 1 || index > c.WorkspaceIds.Length
        return
    targetId := c.WorkspaceIds[index]
    if !RequestSettingsWorkspaceSwitch(c, targetId, "settings")
        RefreshSettingsWorkspaceControls(c)
}

RequestSettingsWorkspaceSwitch(c, workspaceId, origin := "settings") {
    if StrLower(workspaceId) = StrLower(c.Draft.CurrentWorkspaceId)
        return true
    if SettingsDraftHasChanges(c) {
        answer := SettingsMessage(c,
            "设置尚未保存。`n`n"
            . "“是”：保存并切换`n"
            . "“否”：放弃修改并切换`n"
            . "“取消”：留在当前工作区",
            "切换工作区", "YesNoCancel Icon!")
        action := ResolveSettingsConflictAction(answer)
        if action = "Cancel"
            return false
        if action = "Save" {
            if !SaveSettingsDraftCore(c, false)
                return false
        } else {
            ReloadSettingsDraft(c)
        }
    }
    if !ActivateWorkspace(workspaceId)
        return false
    ReloadSettingsDraft(c)
    return true
}

ResolveSettingsConflictAction(answer) {
    if answer = "Yes"
        return "Save"
    if answer = "No"
        return "Discard"
    return "Cancel"
}

PrepareSettingsForExternalSourceRemoval(workspaceId, sourceId) {
    global SettingsController
    if !IsObject(SettingsController)
        return {Allowed: true, SyncState: 0}
    c := SettingsController
    if IsObject(c.Child) {
        try WinActivate("ahk_id " c.Child.Hwnd)
        SettingsMessage(c,
            "请先完成或关闭当前设置子窗口，再移除来源。",
            "无法移除来源", "Icon!")
        return {Allowed: false, SyncState: 0}
    }
    if SettingsDraftHasChanges(c) {
        answer := SettingsMessage(c,
            "设置尚未保存。`n`n"
            . "“是”：保存草稿后继续移除`n"
            . "“否”：放弃草稿后继续移除`n"
            . "“取消”：取消移除来源",
            "移除来源", "YesNoCancel Icon!")
        action := ResolveSettingsConflictAction(answer)
        if action = "Cancel"
            return {Allowed: false, SyncState: 0}
        if action = "Save" {
            if !SaveSettingsDraftCore(c, false)
                return {Allowed: false, SyncState: 0}
        } else {
            ReloadSettingsDraft(c)
        }
    }
    return {
        Allowed: true,
        SyncState: CaptureSettingsSourceSyncState(
            c, workspaceId, sourceId)
    }
}

CaptureSettingsSourceSyncState(c, workspaceId, sourceId) {
    target := ResolveDraftSourceNavigation(
        c.Draft, workspaceId, sourceId)
    return {
        Controller: c,
        ControllerHwnd: c.Gui.Hwnd,
        WorkspaceId: workspaceId,
        RemovedSourceId: sourceId,
        RemovedIndex: target.SourceIndex,
        SelectedSourceId: c.SelectedSourceId
    }
}

SyncSettingsAfterExternalSourceRemoval(state) {
    global SettingsController
    if !IsObject(state) || !IsObject(SettingsController)
        return
    c := SettingsController
    if c.Gui.Hwnd != state.ControllerHwnd
        return
    ReloadSettingsDraft(c)
    if StrLower(c.Draft.CurrentWorkspaceId)
        != StrLower(state.WorkspaceId)
        return
    preferredId := ""
    if state.SelectedSourceId != ""
        && StrLower(state.SelectedSourceId)
            != StrLower(state.RemovedSourceId) {
        selected := ResolveDraftSourceNavigation(
            c.Draft, state.WorkspaceId, state.SelectedSourceId)
        if selected.SourceFound
            preferredId := state.SelectedSourceId
    }
    if preferredId = "" && c.Draft.Sources.Length
        && state.RemovedIndex {
        adjacentIndex := Min(state.RemovedIndex, c.Draft.Sources.Length)
        preferredId := c.Draft.Sources[adjacentIndex].SourceId
    }
    RefreshSourceList(c, preferredId, preferredId != "")
    if !c.Draft.Sources.Length
        c.SourceStatus.Text := "当前工作区还没有来源。"
}

ReloadSettingsDraft(c) {
    c.Draft := LoadSettingsIntoDraft()
    c.OriginalSignature := SettingsDraftSignature(c.Draft)
    c.SelectedSourceId := ""
    c.SelectedAppId := ""
    c.SelectedTargetId := ""
    LoadGeneralControls(c)
    LoadDisplayControls(c)
    LoadInterfaceControls(c)
    LoadContentUpdateControls(c)
    RefreshSettingsWorkspaceControls(c)
    RefreshApplicationList(c)
    RefreshDestinationList(c)
    RefreshExcludedNameList(c)
}

OpenWorkspaceManager(c, *) {
    if IsObject(c.Child)
        return
    if SettingsDraftHasChanges(c) {
        answer := SettingsMessage(c,
            "设置尚未保存。`n`n"
            . "“是”：保存后管理工作区`n"
            . "“否”：放弃修改后管理工作区`n"
            . "“取消”：返回设置",
            "管理工作区", "YesNoCancel Icon!")
        if answer = "Cancel"
            return
        if answer = "Yes" {
            if !SaveSettingsDraftCore(c, false)
                return
        } else {
            ReloadSettingsDraft(c)
        }
    }
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox",
        "管理工作区")
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 14
    child.MarginY := 12
    child.AddText("xm ym w570",
        "工作区只保存文件来源及来源专属设置；其他设置应用于所有工作区。")
    list := child.AddListView("xm y+10 w570 h250 Report -Multi NoSortHdr",
        ["工作区", "类型", "来源数量", "状态"])
    list.ModifyCol(1, 230)
    list.ModifyCol(2, 100)
    list.ModifyCol(3, 90)
    list.ModifyCol(4, 120)
    add := AddUiButton(child, "xm y+10 w92", "新建工作区")
    copy := AddUiButton(child, "x+7 yp w112", "复制当前工作区")
    rename := AddUiButton(child, "x+7 yp w72", "重命名")
    remove := AddUiButton(child, "x+7 yp w72", "删除")
    up := AddUiButton(child, "x+7 yp w48", "上移")
    down := AddUiButton(child, "x+7 yp w48", "下移")
    close := AddUiButton(child, "x500 yp w70 Default", "关闭")
    manager := {List: list, Up: up, Down: down}
    refresh := (*) => RefreshWorkspaceManagerList(c, manager)
    add.OnEvent("Click", CreateWorkspaceFromManager.Bind(c, manager))
    copy.OnEvent("Click", CopyWorkspaceFromManager.Bind(c, manager))
    rename.OnEvent("Click", RenameWorkspaceFromManager.Bind(c, manager))
    remove.OnEvent("Click", DeleteWorkspaceFromManager.Bind(c, manager))
    up.OnEvent("Click", MoveWorkspaceFromManager.Bind(c, manager, -1))
    down.OnEvent("Click", MoveWorkspaceFromManager.Bind(c, manager, 1))
    list.OnEvent("ItemSelect",
        UpdateWorkspaceManagerMoveButtons.Bind(c, manager))
    close.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    refresh()
    c.Gui.Opt("+Disabled")
    child.Show("w598 h346")
}

RefreshWorkspaceManagerList(c, manager, preferredWorkspaceId := "") {
    global WORKSPACE_TYPE_TEXT
    list := manager.List
    if preferredWorkspaceId = "" {
        previousRow := list.GetNext(0, "F")
        if !previousRow
            previousRow := list.GetNext()
        if previousRow && previousRow <= c.Draft.Workspaces.Length
            preferredWorkspaceId := c.Draft.Workspaces[previousRow].Id
    }
    if preferredWorkspaceId = ""
        preferredWorkspaceId := c.Draft.CurrentWorkspaceId
    list.Delete()
    selected := 0
    for index, workspace in c.Draft.Workspaces {
        current := StrLower(workspace.Id)
            = StrLower(c.Draft.CurrentWorkspaceId)
        row := list.Add("", workspace.Name,
            ParseWorkspaceType(workspace.Type) = WORKSPACE_TYPE_TEXT
                ? "文本块" : "文件",
            workspace.Sources.Length,
            current ? "当前工作区" : "")
        if StrLower(workspace.Id) = StrLower(preferredWorkspaceId)
            selected := row
    }
    if selected
        list.Modify(selected, "Select Focus Vis")
    UpdateWorkspaceManagerMoveButtons(c, manager)
}

SelectedWorkspaceManagerRow(c, manager) {
    row := manager.List.GetNext(0, "F")
    if !row
        row := manager.List.GetNext()
    return row && row <= c.Draft.Workspaces.Length ? row : 0
}

UpdateWorkspaceManagerMoveButtons(c, manager, *) {
    row := SelectedWorkspaceManagerRow(c, manager)
    manager.Up.Enabled := row > 1
    manager.Down.Enabled := row > 0
        && row < c.Draft.Workspaces.Length
}

MoveWorkspaceOrderItem(workspaces, index, offset) {
    target := index + offset
    if index < 1 || index > workspaces.Length
        || target < 1 || target > workspaces.Length
        return 0
    workspace := workspaces.RemoveAt(index)
    workspaces.InsertAt(target, workspace)
    return target
}

MoveWorkspaceFromManager(c, manager, offset, *) {
    row := SelectedWorkspaceManagerRow(c, manager)
    if !row
        return
    selectedId := c.Draft.Workspaces[row].Id
    originalOrder := c.Draft.Workspaces.Clone()
    if !MoveWorkspaceOrderItem(c.Draft.Workspaces, row, offset) {
        UpdateWorkspaceManagerMoveButtons(c, manager)
        return
    }
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, manager, selectedId)
        SetUserStatus("工作区顺序已更新")
    } else {
        c.Draft.Workspaces := originalOrder
        RefreshWorkspaceManagerList(c, manager, selectedId)
    }
}

ValidateWorkspaceNameForDraft(c, name, ignoredId := "") {
    name := Trim(name)
    if !IsSafeWorkspaceName(name)
        return "名称不能为空、不能超过 80 个字符，也不能包含 [ ] = , 或换行。"
    for workspace in c.Draft.Workspaces {
        if workspace.Id != ignoredId
            && StrLower(workspace.Name) = StrLower(name)
            return "工作区名称已存在（名称不区分大小写）。"
    }
    return ""
}

PromptWorkspaceName(c, title, initial := "", ignoredId := "") {
    if IsObject(c.Child)
        c.Child.Opt("+OwnDialogs")
    else
        c.Gui.Opt("+OwnDialogs")
    result := InputBox("请输入工作区名称：", title,
        "w430 h140", initial)
    if result.Result != "OK"
        return ""
    name := Trim(result.Value)
    errorText := ValidateWorkspaceNameForDraft(c, name, ignoredId)
    if errorText != "" {
        SettingsMessage(c, errorText, "工作区名称无效", "Icon!")
        return ""
    }
    return name
}

CreateWorkspaceFromManager(c, manager, *) {
    global WORKSPACE_TYPE_FILES, WORKSPACE_TYPE_TEXT
    name := PromptWorkspaceName(c, "新建工作区")
    if name = ""
        return
    typeAnswer := SettingsMessage(c,
        "请选择工作区类型：`n`n"
        . "“是”：文本块工作区`n"
        . "“否”：文件工作区`n"
        . "“取消”：不创建",
        "新建工作区", "YesNoCancel Icon!")
    if typeAnswer = "Cancel"
        return
    workspaceType := typeAnswer = "Yes"
        ? WORKSPACE_TYPE_TEXT : WORKSPACE_TYPE_FILES
    current := FindDraftWorkspace(c)
    sources := []
    pinnedPaths := []
    canCopy := IsObject(current)
        && ParseWorkspaceType(current.Value.Type) = workspaceType
    copyCurrent := canCopy && SettingsMessage(c,
        "是否复制当前工作区的来源与固定项？",
        "新建工作区", "YesNo Icon?") = "Yes"
    if copyCurrent {
        for source in current.Value.Sources {
            clone := CloneSettingsSource(source)
            clone.SourceId := NewStableId("source")
            clone.OriginalName := clone.Name
            sources.Push(clone)
        }
        pinnedPaths := current.Value.PinnedPaths.Clone()
    }
    workspace := {Id: NewStableId("workspace"),
        Name: name, Type: workspaceType, Hotkey: "",
        Sources: sources, PinnedPaths: pinnedPaths}
    c.Draft.Workspaces.Push(workspace)
    c.Draft.CurrentWorkspaceId := workspace.Id
    c.Draft.Sources := workspace.Sources
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, manager, workspace.Id)
    }
}

CopyWorkspaceFromManager(c, manager, *) {
    current := FindDraftWorkspace(c)
    if !IsObject(current)
        return
    baseName := current.Value.Name " 副本"
    suffix := 2
    name := baseName
    while ValidateWorkspaceNameForDraft(c, name) != ""
        name := baseName " " suffix++
    sources := []
    for source in current.Value.Sources {
        clone := CloneSettingsSource(source)
        clone.SourceId := NewStableId("source")
        clone.OriginalName := clone.Name
        sources.Push(clone)
    }
    pinnedPaths := current.Value.PinnedPaths.Clone()
    workspace := {Id: NewStableId("workspace"),
        Name: name, Type: current.Value.Type, Hotkey: "",
        Sources: sources, PinnedPaths: pinnedPaths}
    c.Draft.Workspaces.Push(workspace)
    c.Draft.CurrentWorkspaceId := workspace.Id
    c.Draft.Sources := workspace.Sources
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, manager, workspace.Id)
    }
}

RenameWorkspaceFromManager(c, manager, *) {
    row := SelectedWorkspaceManagerRow(c, manager)
    if !row
        return
    target := c.Draft.Workspaces[row]
    name := PromptWorkspaceName(c, "重命名工作区",
        target.Name, target.Id)
    if name = ""
        return
    target.Name := name
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, manager, target.Id)
    }
}

DeleteWorkspaceFromManager(c, manager, *) {
    if c.Draft.Workspaces.Length <= 1 {
        SettingsMessage(c, "至少需要保留一个工作区，不能删除最后一个工作区。",
            "无法删除", "Icon!")
        return
    }
    row := SelectedWorkspaceManagerRow(c, manager)
    if !row
        return
    target := c.Draft.Workspaces[row]
    current := StrLower(target.Id)
        = StrLower(c.Draft.CurrentWorkspaceId)
    nextWorkspace := 0
    if current {
        nextWorkspace := row = 1
            ? c.Draft.Workspaces[2] : c.Draft.Workspaces[1]
        message := "要删除当前工作区“" target.Name "”吗？`n`n"
            . "删除后将切换到“" nextWorkspace.Name "”。"
    } else {
        message := "要删除工作区“" target.Name "”吗？"
    }
    message .= "`n`n这不会删除任何真实文件或共享设置；"
        . "只会移除该工作区的来源和固定项记录。"
    if SettingsMessage(c, message, "删除工作区",
        "YesNo Icon!") != "Yes"
        return
    c.Draft.Workspaces.RemoveAt(row)
    if current {
        c.Draft.CurrentWorkspaceId := nextWorkspace.Id
        c.Draft.Sources := nextWorkspace.Sources
    }
    preferredId := current ? nextWorkspace.Id
        : (row <= c.Draft.Workspaces.Length
            ? c.Draft.Workspaces[row].Id
            : c.Draft.Workspaces[c.Draft.Workspaces.Length].Id)
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, manager, preferredId)
    }
}

BuildOperationsSettingsPage(c, tabs) {
    tabs.UseTab(2)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h190",
        "文件管理器 · 应用于所有工作区")
    g.AddText("x220 y57 w120", "默认文件管理器：")
    c.FileManagerProvider := AddUiDropDownList(
        g, "x345 yp-4 w270 Choose1",
        ["跟随 Windows 系统行为", "Directory Opus", "Total Commander",
            "XYplorer", "Double Commander", "Files", "FreeCommander XE"])
    c.FileManagerPathLabel := g.AddText(
        "x220 y94 w120", "程序路径：")
    c.FileManagerPath := AddUiEdit(g, "x345 yp-4 w430")
    c.FileManagerBrowse := AddUiButton(
        g, "x+7 yp w78", "浏览…")
    c.FileManagerAutoFind := AddUiButton(
        g, "x+7 yp w92", "自动查找")
    c.FileManagerPathStatus := g.AddText(
        "x345 y126 w620 h20 c666666", "")
    c.FileManagerTestFolder := AddUiButton(
        g, "x220 y153 w130", "测试打开文件夹")
    c.FileManagerTestReveal := AddUiButton(
        g, "x+8 yp w130", "测试定位文件")
    c.FileManagerCapability := g.AddText(
        "x510 y147 w480 h38 c7A4E00", "")
    c.FileManagerTestStatus := g.AddText(
        "x220 y187 w770 h18 c666666", "")
    c.FileManagerThirdPartyControls := [
        c.FileManagerPathLabel, c.FileManagerPath,
        c.FileManagerBrowse, c.FileManagerAutoFind,
        c.FileManagerPathStatus
    ]

    g.AddGroupBox("x200 y230 w818 h185",
        "应用与工具操作 · 应用于所有工作区")
    c.AppList := g.AddListView("x220 y257 w778 h94 Report -Multi NoSortHdr",
        ["名称", "程序", "打开方式", "动作", "状态"])
    c.AppList.ModifyCol(1, 120)
    c.AppList.ModifyCol(2, 330)
    c.AppList.ModifyCol(3, 145)
    c.AppList.ModifyCol(4, 60)
    c.AppList.ModifyCol(5, 100)
    c.AppAdd := AddUiButton(g, "x220 y361 w88", "添加应用")
    c.AppEdit := AddUiButton(g, "x+7 yp w78", "编辑应用")
    c.AppActions := AddUiButton(g, "x+7 yp w92", "管理动作…")
    c.AppRemove := AddUiButton(g, "x+7 yp w72", "移除")
    c.AppUp := AddUiButton(g, "x+7 yp w72", "上移")
    c.AppDown := AddUiButton(g, "x+7 yp w72", "下移")

    g.AddGroupBox("x200 y426 w818 h200",
        "复制和移动的常用位置 · 应用于所有工作区")
    c.TargetList := g.AddListView("x220 y453 w778 h105 Report -Multi NoSortHdr",
        ["名称", "路径", "状态"])
    c.TargetList.ModifyCol(1, 165)
    c.TargetList.ModifyCol(2, 505)
    c.TargetList.ModifyCol(3, 105)
    c.TargetAdd := AddUiButton(g, "x220 y568 w88", "添加位置")
    c.TargetEdit := AddUiButton(g, "x+7 yp w72", "编辑")
    c.TargetRemove := AddUiButton(g, "x+7 yp w72", "移除")
    c.TargetUp := AddUiButton(g, "x+7 yp w72", "上移")
    c.TargetDown := AddUiButton(g, "x+7 yp w72", "下移")
    c.RecentTargetCount := g.AddText("x725 yp+7 w145",
        "最近目标：0 个")
    c.ClearRecentTargets := AddUiButton(g, "x875 yp w98", "清空记录")

    c.FileManagerProvider.OnEvent(
        "Change", FileManagerControlChanged.Bind(c))
    c.FileManagerPath.OnEvent(
        "Change", FileManagerControlChanged.Bind(c))
    c.FileManagerBrowse.OnEvent(
        "Click", BrowseFileManagerExecutable.Bind(c))
    c.FileManagerAutoFind.OnEvent(
        "Click", AutoFindFileManagerExecutable.Bind(c))
    c.FileManagerTestFolder.OnEvent(
        "Click", TestFileManagerOpenFolder.Bind(c))
    c.FileManagerTestReveal.OnEvent(
        "Click", TestFileManagerRevealItem.Bind(c))
    c.AppList.OnEvent("ItemSelect", ApplicationSelected.Bind(c))
    c.AppAdd.OnEvent("Click", OpenApplicationEditor.Bind(c, 0))
    c.AppEdit.OnEvent("Click", EditSelectedApplication.Bind(c))
    c.AppActions.OnEvent("Click", ManageSelectedApplicationActions.Bind(c))
    c.AppRemove.OnEvent("Click", RemoveSelectedApplication.Bind(c))
    c.AppUp.OnEvent("Click", MoveSelectedApplication.Bind(c, -1))
    c.AppDown.OnEvent("Click", MoveSelectedApplication.Bind(c, 1))
    c.TargetList.OnEvent("ItemSelect", DestinationSelected.Bind(c))
    c.TargetAdd.OnEvent("Click", OpenDestinationEditor.Bind(c, 0))
    c.TargetEdit.OnEvent("Click", EditSelectedDestination.Bind(c))
    c.TargetRemove.OnEvent("Click", RemoveSelectedDestination.Bind(c))
    c.TargetUp.OnEvent("Click", MoveSelectedDestination.Bind(c, -1))
    c.TargetDown.OnEvent("Click", MoveSelectedDestination.Bind(c, 1))
    c.ClearRecentTargets.OnEvent("Click", ClearRecentTargetsDraft.Bind(c))
}

FileManagerProviderToIndex(provider) {
    global FILE_MANAGER_DIRECTORY_OPUS, FILE_MANAGER_TOTAL_COMMANDER
    global FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    provider := ParseFileManagerProvider(provider)
    if provider = FILE_MANAGER_DIRECTORY_OPUS
        return 2
    if provider = FILE_MANAGER_TOTAL_COMMANDER
        return 3
    if provider = FILE_MANAGER_XYPLORER
        return 4
    if provider = FILE_MANAGER_DOUBLE_COMMANDER
        return 5
    if provider = FILE_MANAGER_FILES
        return 6
    if provider = FILE_MANAGER_FREE_COMMANDER
        return 7
    return 1
}

FileManagerIndexToProvider(index) {
    global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_DIRECTORY_OPUS
    global FILE_MANAGER_TOTAL_COMMANDER, FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    if index = 2
        return FILE_MANAGER_DIRECTORY_OPUS
    if index = 3
        return FILE_MANAGER_TOTAL_COMMANDER
    if index = 4
        return FILE_MANAGER_XYPLORER
    if index = 5
        return FILE_MANAGER_DOUBLE_COMMANDER
    if index = 6
        return FILE_MANAGER_FILES
    if index = 7
        return FILE_MANAGER_FREE_COMMANDER
    return FILE_MANAGER_WINDOWS_SHELL
}

LoadFileManagerControls(c) {
    d := c.Draft.General
    c.FileManagerProvider.Choose(
        FileManagerProviderToIndex(d.FileManagerProvider))
    c.FileManagerPath.Value := d.FileManagerExecutable
    UpdateFileManagerControlState(c)
}

FileManagerSettingsFromControls(c) {
    return {
        Provider: FileManagerIndexToProvider(
            Max(1, c.FileManagerProvider.Value)),
        Executable: Trim(c.FileManagerPath.Value)
    }
}

FileManagerControlChanged(c, *) {
    if c.Loading
        return
    settings := FileManagerSettingsFromControls(c)
    c.Draft.General.FileManagerProvider := settings.Provider
    c.Draft.General.FileManagerExecutable := settings.Executable
    c.FileManagerTestStatus.Text := ""
    UpdateFileManagerControlState(c)
}

UpdateFileManagerControlState(c) {
    global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_TOTAL_COMMANDER
    global FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    settings := FileManagerSettingsFromControls(c)
    thirdParty := settings.Provider != FILE_MANAGER_WINDOWS_SHELL
    for ctrl in c.FileManagerThirdPartyControls {
        ctrl.Visible := thirdParty
        ctrl.Enabled := thirdParty
    }
    c.FileManagerCapability.Text :=
        settings.Provider = FILE_MANAGER_TOTAL_COMMANDER
        ? "受 Total Commander 对外接口限制，PopDrop 暂不支持在其中自动选中文件；"
            . "“在文件管理器中显示”将改为打开文件所在文件夹。"
        : settings.Provider = FILE_MANAGER_XYPLORER
            || settings.Provider = FILE_MANAGER_FILES
        ? FileManagerProviderDisplayName(settings.Provider)
            . " 支持精确定位单个项目；多选时将按文件所在文件夹去重后打开。"
        : settings.Provider = FILE_MANAGER_DOUBLE_COMMANDER
            || settings.Provider = FILE_MANAGER_FREE_COMMANDER
        ? FileManagerProviderDisplayName(settings.Provider)
            . " 支持精确定位单个文件；文件夹将直接打开，"
            . "多选时按文件所在文件夹去重后打开。"
        : ""
    if !thirdParty
        return
    executable := settings.Provider = "DirectoryOpus"
        ? ResolveDirectoryOpusRuntimePath(settings.Executable)
        : NormalizePath(settings.Executable)
    validation := ValidateFileManagerExecutable(
        settings.Provider, executable)
    c.FileManagerPathStatus.Text := "路径检测："
        . validation.Message
}

BrowseFileManagerExecutable(c, *) {
    settings := FileManagerSettingsFromControls(c)
    if settings.Provider = "WindowsShell"
        return
    root := settings.Executable
    if root != "" {
        SplitPath(NormalizePath(root), , &root)
    }
    title := settings.Provider = "DirectoryOpus"
        ? "选择 dopusrt.exe 或 dopus.exe"
        : settings.Provider = "TotalCommander"
        ? "选择 TOTALCMD64.EXE 或 TOTALCMD.EXE"
        : settings.Provider = "XYplorer"
        ? "选择 XYplorer.exe"
        : settings.Provider = "DoubleCommander"
        ? "选择 doublecmd.exe"
        : settings.Provider = "Files"
        ? "选择 Files 启动程序或官方启动别名"
        : "选择 FreeCommander.exe"
    selected := SelectPanelFile(
        "1", root, title, "程序 (*.exe)")
    if selected = ""
        return
    selected := NormalizeFileManagerExecutableForSave(
        settings.Provider, selected)
    c.FileManagerPath.Value := selected
    FileManagerControlChanged(c)
}

AutoFindFileManagerExecutable(c, *) {
    settings := FileManagerSettingsFromControls(c)
    if settings.Provider = "WindowsShell"
        return
    found := FindFileManagerExecutable(settings.Provider)
    if found = "" {
        c.FileManagerPathStatus.Text :=
            "路径检测：自动查找未发现程序，可使用“浏览…”选择便携版。"
        SettingsMessage(c,
            "未在常用安装位置或系统注册信息中找到 "
                . FileManagerProviderDisplayName(settings.Provider)
                . "。`n`n可以使用“浏览…”手动选择程序；"
                . "PopDrop 不会扫描整个磁盘。",
            "自动查找", "Iconi")
        return
    }
    c.FileManagerPath.Value := found
    FileManagerControlChanged(c)
}

TestFileManagerOpenFolder(c, *) {
    settings := FileManagerSettingsFromControls(c)
    FileManagerControlChanged(c)
    c.FileManagerTestStatus.Text := "正在测试打开文件夹…"
    result := FileManagerRouter.OpenFolder(A_Temp, settings)
    HandleFileManagerTestResult(
        c, result, "已发送打开测试文件夹的命令。")
}

TestFileManagerRevealItem(c, *) {
    settings := FileManagerSettingsFromControls(c)
    FileManagerControlChanged(c)
    c.FileManagerTestStatus.Text := "正在测试定位文件…"
    result := FileManagerRouter.RevealItems(
        [A_ScriptFullPath], settings)
    HandleFileManagerTestResult(
        c, result, "测试定位文件命令已发送。")
}

HandleFileManagerTestResult(c, result, successText) {
    if result.Success {
        c.FileManagerTestStatus.Text := successText
        SetUserStatus(successText)
        return true
    }
    c.FileManagerTestStatus.Text := "测试失败；请查看错误详情并检查程序路径。"
    SettingsMessage(c, result.Message,
        "文件管理器测试失败", "Iconx")
    return false
}

BuildDisplaySettingsPage(c, tabs) {
    tabs.UseTab(3)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h190", "共享排除的文件夹名称")
    c.ExcludedNameList := g.AddListView(
        "x220 y56 w410 h112 Report -Multi NoSortHdr", ["文件夹名称"])
    c.ExcludedNameList.ModifyCol(1, 385)
    c.ExcludedNameAdd := AddUiButton(g, "x650 y56 w88", "添加")
    c.ExcludedNameRemove := AddUiButton(g, "xp y+8 w88", "移除")
    c.ExcludedNameRestore := AddUiButton(g, "xp y+8 w112", "恢复推荐值")
    g.AddText("x780 y56 w215 h112 c555555",
        "匹配的文件夹及其内容不会显示。明确添加为监控来源的文件夹"
        . "不受此规则影响。只支持精确文件夹名称，不使用通配符。")

    g.AddGroupBox("x200 y230 w818 h206",
        "显示 · 应用于所有工作区")
    g.AddText("x220 y265 w150", "每个来源最多显示：")
    c.GlobalMax := AddUiEdit(g, "x380 yp-4 w82 Number")
    g.AddText("x470 yp+4 w150 c666666", "个项目（1–100）")
    g.AddText("x220 y303 w150", "文件排序：")
    c.GlobalSort := AddUiDropDownList(g, "x380 yp-4 w245",
        ["修改时间（最新在前）", "名称（升序）"])
    c.ShowRecent := g.AddCheckBox("x220 y345", "显示最近文件区域")
    g.AddText("x420 yp+3 w86", "显示数量：")
    c.RecentCount := AddUiEdit(g, "x508 yp-4 w82 Number")
    g.AddText("x600 yp+4 w120 c666666", "（1–100）")
    c.NoiseFilterEnabled := g.AddCheckBox("x220 y384",
        "隐藏常见临时、锁定及系统文件（推荐）")
    c.ManageNoiseRules := AddUiButton(g, "x820 yp-5 w138", "管理忽略规则…")
    g.AddText("x240 y411 w555 c666666",
        "自动隐藏 Office 锁定文件、系统目录信息等通常不需要显示的文件。")
    c.HiddenNoiseCount := g.AddText("x800 y414 w130 c666666 Right", "本次共隐藏 0 个")
    c.ViewHiddenNoise := AddUiButton(g, "x940 y407 w55", "查看…")

    g.AddGroupBox("x200 y445 w818 h145",
        "文件内容预览 · 应用于所有工作区")
    c.PreviewEnabled := g.AddCheckBox("x220 y470", "文件预览")
    c.PreviewDocumentEnabled := g.AddCheckBox("x320 yp", "文档预览")
    c.PreviewPdfEnabled := g.AddCheckBox("x420 yp", "PDF 预览")
    c.PreviewShowFileInfo := g.AddCheckBox("x755 y493", "显示文件名、大小和修改时间")
    g.AddText("x535 y473 w76", "预览位置：")
    c.PreviewSide := AddUiDropDownList(g, "x615 y469 w120",
        ["自动", "右侧", "左侧"])
    c.PreviewCacheEnabled := g.AddCheckBox("x755 y470",
        "后台生成静态快照")
    ; Keep the secondary preview integrations clear of the file-info option.
    ; Both rows move together so their established spacing remains unchanged.
    g.AddText("x220 y523 w100", "PDFium 组件：")
    c.PdfiumStatus := g.AddText("x320 yp w440 c666666", "")
    c.PdfiumInstall := AddUiButton(g, "x820 yp-5 w160", "下载组件")
    g.AddText("x220 y563 w120", "空格键快速预览：")
    c.QuickPreviewProvider := AddUiDropDownList(g, "x345 yp-4 w130",
        ["不启用", "使用 Seer", "使用 QuickLook"])
    c.QuickLookPath := AddUiEdit(g, "x490 yp w390")
    c.QuickLookBrowse := AddUiButton(g, "x890 yp-1 w90", "浏览…")

    c.ExcludedNameAdd.OnEvent("Click", AddExcludedName.Bind(c))
    c.ExcludedNameRemove.OnEvent("Click", RemoveExcludedName.Bind(c))
    c.ExcludedNameRestore.OnEvent("Click", RestoreExcludedNames.Bind(c))
    c.GlobalMax.OnEvent("Change", DisplayControlChanged.Bind(c))
    c.GlobalSort.OnEvent("Change", DisplayControlChanged.Bind(c))
    c.ShowRecent.OnEvent("Click", DisplayControlChanged.Bind(c))
    c.RecentCount.OnEvent("Change", DisplayControlChanged.Bind(c))
    c.NoiseFilterEnabled.OnEvent("Click", DisplayControlChanged.Bind(c))
    c.ManageNoiseRules.OnEvent("Click", OpenNoiseFilterManager.Bind(c))
    c.ViewHiddenNoise.OnEvent("Click", OpenHiddenNoiseItems.Bind(c))
    c.PreviewEnabled.OnEvent("Click", DisplayControlChanged.Bind(c))
    c.PreviewSide.OnEvent("Change", DisplayControlChanged.Bind(c))
    c.PreviewCacheEnabled.OnEvent("Click", DisplayControlChanged.Bind(c))
    c.PreviewDocumentEnabled.OnEvent("Click", DisplayControlChanged.Bind(c))
    c.PreviewPdfEnabled.OnEvent(
        "Click", PdfiumPreviewSettingClicked.Bind(c))
    c.PreviewShowFileInfo.OnEvent("Click", DisplayControlChanged.Bind(c))
    c.PdfiumInstall.OnEvent("Click", PdfiumInstallClicked.Bind(c))
    c.QuickPreviewProvider.OnEvent(
        "Change", DisplayControlChanged.Bind(c))
    c.QuickLookPath.OnEvent("Change", DisplayControlChanged.Bind(c))
    c.QuickLookBrowse.OnEvent("Click", BrowseQuickLookPath.Bind(c))
}

BuildInterfaceSettingsPage(c, tabs) {
    tabs.UseTab(4)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h145", "界面缩放 · 应用于所有工作区")
    g.AddText("x224 y66 w92", "主面板缩放：")
    c.UiScale := AddUiDropDownList(g, "x320 yp-4 w150",
        ["100%", "125%", "150%", "175%", "200%"])
    c.UiScaleHint := g.AddText("x490 yp+4 w480 c666666",
        "窗口、控件、文字、图标与间距按比例同步放大。")
    g.AddText("x224 y111 w744 c666666",
        "当前应用于 PopDrop 主面板；保存后需重新启动才能生效。")

    g.AddGroupBox("x200 y190 w818 h246", "文件图标与分栏 · 应用于所有工作区")
    g.AddText("x224 y228 w92", "图标质量：")
    c.ThumbnailPolicy := AddUiDropDownList(g, "x320 yp-4 w150",
        ["快速", "完整"])
    g.AddText("x224 y272 w92", "图标大小：")
    c.ThumbnailSize := AddUiEdit(g, "x320 yp-4 w72 Number")
    g.AddText("x404 yp+4 w110 c666666", "48–256")
    g.AddText("x224 y316 w92", "横向间距：")
    c.ThumbnailHorizontalGap := AddUiEdit(g, "x320 yp-4 w72 Number")
    g.AddText("x460 yp+4 w92", "纵向间距：")
    c.ThumbnailVerticalGap := AddUiEdit(g, "x556 yp-4 w72 Number")
    g.AddText("x224 y360 w92", "分栏上间距：")
    c.FileViewGroupTopSpacing := AddUiEdit(g, "x320 yp-4 w72 Number")
    g.AddText("x404 yp+4 w72 c666666", "0–32")
    g.AddText("x500 yp w92", "分栏下间距：")
    c.FileViewGroupBottomSpacing := AddUiEdit(g, "x596 yp-4 w72 Number")
    g.AddText("x680 yp+4 w72 c666666", "0–32")
    g.AddText("x224 y404 w92", "文件名行数：")
    c.ThumbnailTextLines := AddUiDropDownList(g, "x320 yp-4 w150",
        ["1 行", "2 行"])

    g.AddGroupBox("x200 y452 w818 h128", "文本块 · 应用于所有工作区")
    g.AddText("x224 y487 w92", "卡片宽度：")
    c.TextBlockCardWidth := AddUiEdit(g, "x320 yp-4 w72 Number")
    g.AddText("x404 yp+4 w110 c666666", "140–640")
    g.AddText("x540 yp w92", "卡片高度：")
    c.TextBlockCardHeight := AddUiEdit(g, "x636 yp-4 w72 Number")
    g.AddText("x720 yp+4 w110 c666666", "48–320")
    g.AddText("x224 y535 w744 c666666",
        "宽度和高度用于调整文本块工作区中的卡片尺寸。")

    g.AddGroupBox("x200 y596 w818 h120", "窗口尺寸 · 主面板")
    g.AddText("x224 y630 w92", "窗口宽度：")
    c.WindowWidth := AddUiEdit(g, "x320 yp-4 w82 Number")
    g.AddText("x414 yp+4 w100 c666666", "660–980")
    g.AddText("x540 yp w92", "窗口高度：")
    c.WindowHeight := AddUiEdit(g, "x636 yp-4 w82 Number")
    g.AddText("x730 yp+4 w120 c666666", "380–2000")
    g.AddText("x224 y674 w744 c666666",
        "保存后用于主面板下次显示；窗口仍可手动拖动调整。")

    c.UiScale.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.ThumbnailPolicy.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.ThumbnailSize.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.ThumbnailHorizontalGap.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.ThumbnailVerticalGap.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.FileViewGroupTopSpacing.OnEvent(
        "Change", InterfaceControlChanged.Bind(c))
    c.FileViewGroupBottomSpacing.OnEvent(
        "Change", InterfaceControlChanged.Bind(c))
    c.ThumbnailTextLines.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.TextBlockCardWidth.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.TextBlockCardHeight.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.WindowWidth.OnEvent("Change", InterfaceControlChanged.Bind(c))
    c.WindowHeight.OnEvent("Change", InterfaceControlChanged.Bind(c))
}

BuildAboutSettingsPage(c, tabs) {
    global APP_VERSION
    tabs.UseTab(7)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h520", "关于 PopDrop")

    title := g.AddText("x232 y68 w520 h42", "PopDrop")
    title.SetFont("s22 Bold", "Microsoft YaHei UI")
    tagline := g.AddText("x235 y116 w520 h30", "需要时就在手边")
    tagline.SetFont("s11", "Microsoft YaHei UI")
    version := g.AddText("x235 y158 w320 h26", "版本 v" APP_VERSION)
    version.SetFont("s10 c666666", "Microsoft YaHei UI")

    g.AddText("x235 y205 w180 h24", "项目链接")
    project := AddUiButton(g, "x235 y237 w130", "项目主页")
    releases := AddUiButton(g, "x375 y237 w130", "检查更新")
    project.OnEvent("Click", OpenAboutUrl.Bind(
        "https://u.nu/popdrop-github-from-app"))
    releases.OnEvent("Click", OpenAboutUrl.Bind(
        "https://u.nu/popdrop-github-release-from-app"))

    g.AddText("x235 y292 w180 h24", "作者")
    author := AddUiButton(g, "x235 y324 w130", "作者主页")
    author.OnEvent("Click", OpenAboutUrl.Bind("https://s.ee/katt"))
    g.AddText("x385 y330 w440 h24 c666666",
        "先让几件小事顺手一点。")

    g.AddText("x235 y389 w180 h24", "打赏")
    g.AddText("x235 y421 w650 h44",
        "如果你喜欢 PopDrop，或者它帮你提高了效率，欢迎把这份好心情也传递给我！")
    donate := AddUiButton(g, "x235 y477 w130", "打赏链接")
    donate.OnEvent("Click", OpenAboutUrl.Bind(
        "https://fs.to/support-popdrop"))
}

BuildContentUpdateSettingsPage(c, tabs) {
    tabs.UseTab(5)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h300", "内容更新方式 · 应用于所有工作区")
    c.ContentUpdateFast := g.AddRadio("x224 y68 Group", "极速显示（默认推荐）")
    g.AddText("x244 y101 w744 h32 c555555",
        "日常首选，极致轻快的使用体验")
    c.ContentUpdateAccuracy := g.AddRadio("x224 y178", "准确优先")
    g.AddText("x244 y211 w744 h32 c555555",
        "保障内容正确，仅限极速模式异常时使用")
    c.ContentUpdateHint := g.AddText("x224 y278 w744 h36 c666666",
        "当前设置会在保存后立即应用。")
    c.ContentUpdateFast.OnEvent(
        "Click", ContentUpdateControlChanged.Bind(c, "Fast"))
    c.ContentUpdateAccuracy.OnEvent(
        "Click", ContentUpdateControlChanged.Bind(c, "Accuracy"))
}

ContentUpdateControlChanged(c, selectedMode := "", *) {
    global CONTENT_UPDATE_FAST, CONTENT_UPDATE_ACCURACY
    if c.Loading
        return
    ; The explanatory text between the two controls prevents Windows from
    ; reliably treating them as one native radio group. Enforce exclusivity
    ; explicitly and use the clicked control as the source of truth.
    if selectedMode = "Accuracy" {
        c.ContentUpdateAccuracy.Value := true
        c.ContentUpdateFast.Value := false
        c.Draft.General.ContentUpdateMode := CONTENT_UPDATE_ACCURACY
    } else {
        if selectedMode = "Fast" {
            c.ContentUpdateFast.Value := true
            c.ContentUpdateAccuracy.Value := false
            c.Draft.General.ContentUpdateMode := CONTENT_UPDATE_FAST
        }
    }
}

LoadContentUpdateControls(c) {
    global CONTENT_UPDATE_FAST, CONTENT_UPDATE_ACCURACY
    c.Loading := true
    try {
        mode := c.Draft.General.ContentUpdateMode
        c.ContentUpdateFast.Value := mode != CONTENT_UPDATE_ACCURACY
        c.ContentUpdateAccuracy.Value := mode = CONTENT_UPDATE_ACCURACY
    } finally c.Loading := false
}

LoadGeneralControls(c) {
    global OPEN_MODE_SINGLE
    global CONTEXT_MENU_SYSTEM
    c.Loading := true
    try {
        d := c.Draft.General
        c.GlobalDouble.Value := d.OpenFileMode != OPEN_MODE_SINGLE
        c.GlobalSingle.Value := d.OpenFileMode = OPEN_MODE_SINGLE
        c.Hotkey.Value := d.Hotkey
        RefreshDoubleHotkeyWorkspaceChoices(c)
        c.WindowMode.Choose(WindowModeToIndex(d.WindowMode))
        c.EscapeHide.Value := d.EscapeHidesPanel
        c.ContextMenuPopDrop.Value :=
            d.DefaultContextMenu != CONTEXT_MENU_SYSTEM
        c.ContextMenuSystem.Value :=
            d.DefaultContextMenu = CONTEXT_MENU_SYSTEM
        UpdateContextMenuDescription(c)
        c.EnableUrlFallback.Value := d.EnablePublicUrlFallback
        c.AllowHttp.Value := d.AllowHttp
        c.TransferMax.Value := d.TransferMaxConcurrent
        c.TransferNotify.Value := d.ShowCompletionNotifications
        c.StartupEnabled.Value := d.StartupEnabled
        LoadFileManagerControls(c)
    } finally c.Loading := false
}

LoadInterfaceControls(c) {
    global UI_SCALE_100, UI_SCALE_125
    global UI_SCALE_150, UI_SCALE_175, UI_SCALE_200
    c.Loading := true
    try {
        d := c.Draft.General
        scaleIndex := d.UiScaleMode = UI_SCALE_125 ? 2
            : d.UiScaleMode = UI_SCALE_150 ? 3
            : d.UiScaleMode = UI_SCALE_175 ? 4
            : d.UiScaleMode = UI_SCALE_200 ? 5 : 1
        c.UiScale.Choose(scaleIndex)
        c.ThumbnailPolicy.Choose(d.ThumbnailPolicy = "Full" ? 2 : 1)
        c.ThumbnailSize.Value := d.ThumbnailSize
        c.ThumbnailHorizontalGap.Value := d.ThumbnailHorizontalGap
        c.ThumbnailVerticalGap.Value := d.ThumbnailVerticalGap
        c.FileViewGroupTopSpacing.Value := d.FileViewGroupTopSpacing
        c.FileViewGroupBottomSpacing.Value := d.FileViewGroupBottomSpacing
        c.ThumbnailTextLines.Choose(d.ThumbnailTextLines = 1 ? 1 : 2)
        c.TextBlockCardWidth.Value := d.TextBlockCardWidth
        c.TextBlockCardHeight.Value := d.TextBlockCardHeight
        c.WindowWidth.Value := d.WindowWidth
        c.WindowHeight.Value := d.WindowHeight
    } finally c.Loading := false
}

InterfaceControlChanged(c, *) {
    global UI_SCALE_100, UI_SCALE_125
    global UI_SCALE_150, UI_SCALE_175, UI_SCALE_200
    if c.Loading
        return
    scales := [UI_SCALE_100, UI_SCALE_125, UI_SCALE_150,
        UI_SCALE_175, UI_SCALE_200]
    c.Draft.General.UiScaleMode := scales[Max(1, c.UiScale.Value)]
    c.Draft.General.ThumbnailPolicy := c.ThumbnailPolicy.Value = 2
        ? "Full" : "Fast"
    c.Draft.General.ThumbnailSize := Trim(c.ThumbnailSize.Value)
    c.Draft.General.ThumbnailHorizontalGap := Trim(
        c.ThumbnailHorizontalGap.Value)
    c.Draft.General.ThumbnailVerticalGap := Trim(
        c.ThumbnailVerticalGap.Value)
    c.Draft.General.FileViewGroupTopSpacing := Trim(
        c.FileViewGroupTopSpacing.Value)
    c.Draft.General.FileViewGroupBottomSpacing := Trim(
        c.FileViewGroupBottomSpacing.Value)
    c.Draft.General.ThumbnailTextLines := c.ThumbnailTextLines.Value = 1 ? 1 : 2
    c.Draft.General.TextBlockCardWidth := Trim(c.TextBlockCardWidth.Value)
    c.Draft.General.TextBlockCardHeight := Trim(c.TextBlockCardHeight.Value)
    c.Draft.General.WindowWidth := Trim(c.WindowWidth.Value)
    c.Draft.General.WindowHeight := Trim(c.WindowHeight.Value)
}

GeneralControlChanged(c, *) {
    global OPEN_MODE_SINGLE, OPEN_MODE_DOUBLE
    global WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY, WINDOW_MODE_NORMAL
    global CONTEXT_MENU_POPDROP, CONTEXT_MENU_SYSTEM
    if c.Loading
        return
    d := c.Draft.General
    d.OpenFileMode := c.GlobalSingle.Value ? OPEN_MODE_SINGLE : OPEN_MODE_DOUBLE
    d.Hotkey := Trim(c.Hotkey.Value)
    if HasProp(c, "DoubleHotkeyWorkspace") {
        index := c.DoubleHotkeyWorkspace.Value - 1
        d.DoubleHotkeyWorkspaceId := index >= 1
            && index <= c.DoubleHotkeyWorkspaceIds.Length
            ? c.DoubleHotkeyWorkspaceIds[index] : ""
    }
    d.WindowMode := [WINDOW_MODE_ALWAYS_ON_TOP,
        WINDOW_MODE_TEMPORARY, WINDOW_MODE_NORMAL][Max(1, c.WindowMode.Value)]
    d.EscapeHidesPanel := !!c.EscapeHide.Value
    d.DefaultContextMenu := c.ContextMenuSystem.Value
        ? CONTEXT_MENU_SYSTEM : CONTEXT_MENU_POPDROP
    UpdateContextMenuDescription(c)
    d.EnablePublicUrlFallback := !!c.EnableUrlFallback.Value
    d.AllowHttp := !!c.AllowHttp.Value
    d.TransferMaxConcurrent := Trim(c.TransferMax.Value)
    d.ShowCompletionNotifications := !!c.TransferNotify.Value
    d.StartupEnabled := !!c.StartupEnabled.Value
    RefreshInheritedOpenModeLabels(c)
}

RefreshDoubleHotkeyWorkspaceChoices(c) {
    global WORKSPACE_TYPE_TEXT
    if !HasProp(c, "DoubleHotkeyWorkspace")
        return
    names := ["关闭（不设置默认文本区）"]
    c.DoubleHotkeyWorkspaceIds := []
    selected := 1
    for workspace in c.Draft.Workspaces {
        if ParseWorkspaceType(workspace.Type) != WORKSPACE_TYPE_TEXT
            continue
        names.Push(workspace.Name "（默认文本区）")
        c.DoubleHotkeyWorkspaceIds.Push(workspace.Id)
        if StrLower(workspace.Id)
            = StrLower(c.Draft.General.DoubleHotkeyWorkspaceId)
            selected := names.Length
    }
    ReplaceUiDropDownItems(c.DoubleHotkeyWorkspace, names)
    c.DoubleHotkeyWorkspace.Choose(selected)
}

UpdateContextMenuDescription(c) {
    global CONTEXT_MENU_SYSTEM
    mode := c.ContextMenuSystem.Value
        ? CONTEXT_MENU_SYSTEM : c.Draft.General.DefaultContextMenu
    if mode = CONTEXT_MENU_SYSTEM {
        c.ContextMenuDescription.Text :=
            "右键打开 Windows 系统菜单；按住 Shift 右键或按 Shift + F10 "
            . "打开 PopDrop 快捷菜单。"
    } else {
        c.ContextMenuDescription.Text :=
            "右键打开 PopDrop 快捷菜单；按住 Shift 右键或按 Shift + F10 "
            . "打开 Windows 系统菜单。"
    }
}

WindowModeToIndex(mode) {
    global WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY
    if mode = WINDOW_MODE_ALWAYS_ON_TOP
        return 1
    if mode = WINDOW_MODE_TEMPORARY
        return 2
    return 3
}

LoadDisplayControls(c) {
    global SORT_MODIFIED_DESC
    global CurrentScanResult
    c.Loading := true
    try {
        d := c.Draft.General
        c.GlobalMax.Value := d.MaxFilesPerFolder
        c.GlobalSort.Choose(d.SortMode = SORT_MODIFIED_DESC ? 1 : 2)
        c.ShowRecent.Value := d.ShowRecentSidebar
        c.RecentCount.Value := d.RecentFileCount
        c.RecentCount.Enabled := !!d.ShowRecentSidebar
        c.NoiseFilterEnabled.Value := d.NoiseFilter.Enabled
        c.PreviewEnabled.Value := d.PreviewEnabled
        sideIndex := StrLower(d.PreviewSide) = "right" ? 2
            : StrLower(d.PreviewSide) = "left" ? 3 : 1
        c.PreviewSide.Choose(sideIndex)
        c.PreviewCacheEnabled.Value := d.PreviewCacheEnabled
        c.PreviewDocumentEnabled.Value := d.PreviewDocumentEnabled
        c.PreviewPdfEnabled.Value := d.PreviewPdfEnabled
        c.PreviewShowFileInfo.Value := d.PreviewShowFileInfo
        providerIndex := StrLower(d.QuickPreviewProvider) = "seer" ? 2
            : StrLower(d.QuickPreviewProvider) = "quicklook" ? 3 : 1
        c.QuickPreviewProvider.Choose(providerIndex)
        c.QuickLookPath.Value := d.QuickLookPath
        UpdateQuickPreviewControlState(c)
        UpdatePdfiumComponentState(c)
        hiddenCount := IsObject(CurrentScanResult) && HasProp(CurrentScanResult, "HiddenCount")
            ? CurrentScanResult.HiddenCount : 0
        c.HiddenNoiseCount.Text := "本次共隐藏 " hiddenCount " 个"
        c.ViewHiddenNoise.Enabled := IsObject(CurrentScanResult)
            && HasProp(CurrentScanResult, "HiddenItems")
            && CurrentScanResult.HiddenItems.Length > 0
    } finally c.Loading := false
}

SyncSettingsDisplayStateFromRuntime() {
    global SettingsController, ShowRecentSidebar, PreviewEnabled
    if !SettingsControllerIsReady(SettingsController)
        return
    c := SettingsController
    if !HasProp(c, "ShowRecent") || !HasProp(c, "PreviewEnabled")
        return

    ; Preserve unrelated unsaved settings. If the dialog was clean, the
    ; already-persisted toolbar change becomes its new clean baseline.
    DisplayControlChanged(c)
    wasDirty := SettingsDraftSignature(c.Draft) != c.OriginalSignature
    c.Draft.General.ShowRecentSidebar := !!ShowRecentSidebar
    c.Draft.General.PreviewEnabled := !!PreviewEnabled
    c.Loading := true
    try {
        c.ShowRecent.Value := !!ShowRecentSidebar
        c.RecentCount.Enabled := !!ShowRecentSidebar
        c.PreviewEnabled.Value := !!PreviewEnabled
    } finally c.Loading := false
    if !wasDirty
        c.OriginalSignature := SettingsDraftSignature(c.Draft)
}

DisplayControlChanged(c, *) {
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    if c.Loading || !HasProp(c, "GlobalMax")
        return
    d := c.Draft.General
    d.MaxFilesPerFolder := Trim(c.GlobalMax.Value)
    RefreshInheritedSourceMaximums(c)
    d.SortMode := c.GlobalSort.Value = 2 ? SORT_NAME_ASC : SORT_MODIFIED_DESC
    d.ShowRecentSidebar := !!c.ShowRecent.Value
    d.RecentFileCount := Trim(c.RecentCount.Value)
    c.RecentCount.Enabled := d.ShowRecentSidebar
    d.NoiseFilter.Enabled := !!c.NoiseFilterEnabled.Value
    d.PreviewEnabled := !!c.PreviewEnabled.Value
    d.PreviewSide := ["Auto", "Right", "Left"][Max(1, c.PreviewSide.Value)]
    d.PreviewCacheEnabled := !!c.PreviewCacheEnabled.Value
    d.PreviewDocumentEnabled := !!c.PreviewDocumentEnabled.Value
    d.PreviewPdfEnabled := !!c.PreviewPdfEnabled.Value
    d.PreviewShowFileInfo := !!c.PreviewShowFileInfo.Value
    d.QuickPreviewProvider := ["Off", "Seer", "QuickLook"][
        Max(1, c.QuickPreviewProvider.Value)]
    d.SeerIntegrationEnabled := d.QuickPreviewProvider = "Seer"
    if d.QuickPreviewProvider = "QuickLook" {
        if c.QuickLookPath.Value = "无需配置，保持 Seer 运行即可"
            c.QuickLookPath.Value := d.QuickLookPath
        d.QuickLookPath := Trim(c.QuickLookPath.Value)
    }
    UpdateQuickPreviewControlState(c)
}

RefreshInheritedSourceMaximums(c) {
    for workspace in c.Draft.Workspaces {
        for source in workspace.Sources {
            if HasProp(source, "MaxFilesPerFolderInherited")
                && source.MaxFilesPerFolderInherited
                source.MaxFilesPerFolder := c.Draft.General.MaxFilesPerFolder
        }
    }
    if HasProp(c, "SourceMaxMode") {
        selected := c.SourceMaxMode.Value
        if selected = 1
            c.SourceMax.Value := c.Draft.General.MaxFilesPerFolder
        ReplaceUiDropDownItems(c.SourceMaxMode,
            ["继承全局（当前：" c.Draft.General.MaxFilesPerFolder "）",
             "自定义数量", "显示全部"])
        c.SourceMaxMode.Choose(selected ? selected : 1)
    }
}

PdfiumComponentArchitecture() {
    return A_PtrSize = 8 ? "x64" : "x86"
}

PdfiumComponentDllPath() {
    if A_IsCompiled
        return A_ScriptDir "\pdfium.dll"
    return A_ScriptDir "\native\bin\" PdfiumComponentArchitecture()
        . "\pdfium.dll"
}

PdfiumComponentInstalled() {
    path := PdfiumComponentDllPath()
    if !FileExist(path)
        return false
    try return FileGetSize(path) >= 1024 * 1024
    catch
        return false
}

PdfiumComponentInstallerPath() {
    sourcePath := A_ScriptDir "\native\install-pdfium.ps1"
    if FileExist(sourcePath)
        return sourcePath
    return A_ScriptDir "\install-pdfium.ps1"
}

UpdatePdfiumComponentState(c) {
    installed := PdfiumComponentInstalled()
    c.PdfiumStatus.Text := installed
        ? "已安装（" PdfiumComponentArchitecture() "）"
        : "未安装；启用 PDF 预览需要下载约 6–7 MB"
    c.PdfiumInstall.Text := installed ? "组件已安装" : "下载组件…"
    c.PdfiumInstall.Enabled := !installed
        && !(HasProp(c, "PdfiumInstallPid") && c.PdfiumInstallPid)
}

PdfiumPreviewSettingClicked(c, *) {
    if c.Loading
        return
    if !c.PreviewPdfEnabled.Value {
        DisplayControlChanged(c)
        return
    }
    if PdfiumComponentInstalled() {
        DisplayControlChanged(c)
        return
    }
    c.PreviewPdfEnabled.Value := 0
    c.Draft.General.PreviewPdfEnabled := false
    if SettingsMessage(c,
        "可靠的 PDF 预览需要下载 PDFium 组件（约 6–7 MB）。`n`n"
        . "组件会按当前程序架构下载到 Helper 所在目录，"
        . "并在安装前校验 SHA-256。是否现在下载？",
        "启用 PDF 预览", "YesNo Icon!") = "Yes"
        StartPdfiumComponentInstall(c)
}

PdfiumInstallClicked(c, *) {
    if SettingsMessage(c,
        "将下载与当前程序架构匹配的 PDFium 组件（约 6–7 MB），"
        . "并校验 SHA-256。是否继续？",
        "下载 PDF 预览组件", "YesNo Icon!") = "Yes"
        StartPdfiumComponentInstall(c)
}

StartPdfiumComponentInstall(c) {
    if HasProp(c, "PdfiumInstallPid") && c.PdfiumInstallPid
        return
    installer := PdfiumComponentInstallerPath()
    if !FileExist(installer) {
        SettingsMessage(c, "找不到 PDFium 组件安装脚本：`n" installer,
            "无法下载组件", "Iconx")
        return
    }
    command := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'
        . installer '" -Architecture ' PdfiumComponentArchitecture()
    if A_IsCompiled
        command .= ' -DestinationDirectory "' A_ScriptDir '"'
    try Run(command, A_ScriptDir, "Hide", &pid)
    catch as err {
        SettingsMessage(c, "无法启动组件下载：`n" err.Message,
            "无法下载组件", "Iconx")
        return
    }
    c.PdfiumInstallPid := pid
    c.PdfiumStatus.Text := "正在下载并校验组件…"
    c.PdfiumInstall.Enabled := false
    callback := PollPdfiumComponentInstall.Bind(c, pid)
    c.PdfiumInstallPoll := callback
    SetTimer(callback, 500)
}

PollPdfiumComponentInstall(c, pid) {
    global SettingsController
    if ProcessExist(pid)
        return
    if HasProp(c, "PdfiumInstallPoll")
        SetTimer(c.PdfiumInstallPoll, 0)
    c.PdfiumInstallPid := 0
    if !IsObject(SettingsController)
        || SettingsController.Gui.Hwnd != c.Gui.Hwnd
        return
    if PdfiumComponentInstalled() {
        c.PreviewPdfEnabled.Value := 1
        c.Draft.General.PreviewPdfEnabled := true
        UpdatePdfiumComponentState(c)
        SettingsMessage(c,
            "PDFium 组件安装完成，PDF 预览已勾选。请保存设置后生效。",
            "组件安装完成", "Iconi")
    } else {
        UpdatePdfiumComponentState(c)
        SettingsMessage(c,
            "组件下载或校验失败。请检查网络、组件清单和下载地址。",
            "组件安装失败", "Iconx")
    }
}

UpdateQuickPreviewControlState(c) {
    quickLook := c.QuickPreviewProvider.Value = 3
    if c.QuickPreviewProvider.Value = 2 {
        if c.QuickLookPath.Value != "无需配置，保持 Seer 运行即可"
            c.Draft.General.QuickLookPath := Trim(c.QuickLookPath.Value)
        c.QuickLookPath.Value := "无需配置，保持 Seer 运行即可"
    } else if quickLook
        c.QuickLookPath.Value := c.Draft.General.QuickLookPath
    else
        c.QuickLookPath.Value := c.Draft.General.QuickLookPath
    c.QuickLookPath.Enabled := quickLook
    c.QuickLookBrowse.Enabled := quickLook
}

BrowseQuickLookPath(c, *) {
    try selected := SelectPanelFile(
        "1", , "选择 QuickLook 桌面版或便携版程序",
        "QuickLook.exe (QuickLook.exe)")
    catch
        return
    if IsObject(selected)
        selected := selected.Length ? selected[1] : ""
    if selected != "" {
        c.QuickLookPath.Value := selected
        DisplayControlChanged(c)
    }
}

RefreshSourceList(c, preferredId := "", selectFirst := true) {
    if preferredId = ""
        preferredId := c.SelectedSourceId
    c.Loading := true
    try {
        c.SourceList.Opt("-Redraw")
        c.SourceList.Delete()
        c.SourceRows := Map()
        selectRow := 0
        for source in c.Draft.Sources {
            row := c.SourceList.Add("", source.Name, source.Path,
                GetSourceDraftStatus(source, c.Draft.Sources))
            c.SourceRows[row] := source.SourceId
            if preferredId != ""
                && StrLower(source.SourceId) = StrLower(preferredId)
                selectRow := row
        }
        c.SourceList.Opt("+Redraw")
        if !selectRow && selectFirst && c.Draft.Sources.Length
            selectRow := 1
        if selectRow {
            c.SourceList.Modify(selectRow, "Select Focus Vis")
            c.SelectedSourceId := c.SourceRows[selectRow]
            LoadSelectedSourceToControls(c)
        } else {
            c.SelectedSourceId := ""
            SetSourceControlsEnabled(c, false)
        }
    } finally c.Loading := false
}

GetSourceDraftStatus(source, allSources) {
    if source.Name = "" || source.Path = ""
        return "配置错误"
    for other in allSources {
        if other.SourceId != source.SourceId
            && PathsEqual(source.Path, other.Path)
            return "配置错误"
    }
    for other in allSources {
        if other.SourceId = source.SourceId
            continue
        if IsSameOrDescendantPath(source.Path, other.Path)
            || IsSameOrDescendantPath(other.Path, source.Path)
            return DirExist(source.Path) ? "路径重叠" : "不可用/重叠"
    }
    return DirExist(source.Path) ? "正常" : "路径不可用"
}

SourceSelected(c, list, row, selected) {
    if c.Loading || !selected || !c.SourceRows.Has(row)
        return
    CommitCurrentSourceControlsToDraft(c)
    c.SelectedSourceId := c.SourceRows[row]
    LoadSelectedSourceToControls(c)
}

FindDraftSource(c, sourceId := "") {
    if sourceId = ""
        sourceId := c.SelectedSourceId
    for index, source in c.Draft.Sources {
        if StrLower(source.SourceId) = StrLower(sourceId)
            return {Index: index, Value: source}
    }
    return 0
}

LoadSelectedSourceToControls(c) {
    global MODE_LAUNCHER
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS
    global FOLDER_TIME_MODIFIED, OPEN_MODE_SINGLE, OPEN_MODE_DOUBLE
    global SORT_MODIFIED_DESC
    global NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    found := FindDraftSource(c)
    if !IsObject(found) {
        SetSourceControlsEnabled(c, false)
        return
    }
    s := found.Value
    c.Loading := true
    try {
        SetSourceControlsEnabled(c, true)
        c.SourceName.Value := s.Name
        c.SourcePath.Value := s.Path
        c.SourceType.Choose(s.Mode = MODE_LAUNCHER ? 2 : 1)
        c.SourceScope.Choose(s.DisplayScope = SCOPE_FILES_ONLY ? 1
            : s.DisplayScope = SCOPE_FILES_AND_FOLDERS ? 2 : 3)
        RefreshInheritedOpenModeLabels(c)
        c.SourceOpenMode.Choose(s.OpenFileMode = OPEN_MODE_SINGLE ? 2
            : s.OpenFileMode = OPEN_MODE_DOUBLE ? 3 : 1)
        c.SourceFolderTime.Choose(s.FolderTimeMode = FOLDER_TIME_MODIFIED ? 1 : 2)
        c.SourceMaxMode.Choose(s.MaxFilesPerFolderInherited ? 1
            : s.MaxFilesPerFolder = 0 ? 3 : 2)
        c.SourceMax.Value := s.MaxFilesPerFolder
        c.SourceSort.Choose(s.SortMode = SORT_MODIFIED_DESC ? 1
            : s.SortMode = SORT_NAME_ASC ? 2 : 3)
        c.SourceNoiseMode.Choose(s.NoiseFilterMode = NOISE_FILTER_ENABLED ? 2
            : s.NoiseFilterMode = NOISE_FILTER_DISABLED ? 3 : 1)
        c.SourceNoiseRuleCount.Text := s.SourceCustomPatternTexts.Length " 条附加规则"
        c.ExcludedCount.Text := "排除子文件夹：" s.ExcludedPaths.Length " 个"
        c.AllowedCount.Text := "允许覆盖共享排除："
            . s.AllowedExcludedPaths.Length " 个"
        UpdateSourceControlState(c)
        UpdateWorkspaceSourceControls(c)
    } finally c.Loading := false
}

SetSourceControlsEnabled(c, enabled) {
    for ctrl in [c.SourceName, c.SourceType, c.SourcePath, c.SourceBrowse, c.SourceOpen,
        c.SourceScope, c.SourceOpenMode, c.SourceFolderTime,
        c.SourceMaxMode, c.SourceMax,
        c.SourceSort, c.SourceNoiseMode, c.SourceNoiseRules,
        c.ManageExcluded, c.ManageAllowed]
        ctrl.Enabled := enabled
    if !enabled {
        c.SourceName.Value := ""
        c.SourcePath.Value := ""
        c.SourceStatus.Text := "请选择一个来源。"
        c.ExcludedCount.Text := "排除子文件夹：0 个"
        c.AllowedCount.Text := "允许覆盖共享排除：0 个"
        c.SourceNoiseRuleCount.Text := "0 条附加规则"
    }
}

RefreshInheritedOpenModeLabels(c) {
    global OPEN_MODE_SINGLE
    label := c.Draft.General.OpenFileMode = OPEN_MODE_SINGLE ? "单击" : "双击"
    try {
        selected := c.SourceOpenMode.Value
        ReplaceUiDropDownItems(c.SourceOpenMode,
            ["使用共享默认值（当前：" label "）", "单击", "双击"])
        c.SourceOpenMode.Choose(selected ? selected : 1)
    }
}

UpdateSourceControlState(c) {
    scope := c.SourceScope.Value
    c.SourceFolderTime.Enabled := scope = 2
    c.SourceFolderTimeHint.Enabled := scope = 2
    maxMode := c.SourceMaxMode.Value
    c.SourceMax.Enabled := maxMode = 2
    found := FindDraftSource(c)
    if IsObject(found)
        c.SourceStatus.Text := GetSourceDraftStatus(
            found.Value, c.Draft.Sources) "；完整路径保存在草稿中。"
}

SourceControlChanged(c, *) {
    if c.Loading
        return
    CommitCurrentSourceControlsToDraft(c)
    UpdateSourceControlState(c)
    RefreshSourceListRow(c)
}

SourceTypeChanged(c, *) {
    global MODE_FILES, MODE_LAUNCHER
    if c.Loading
        return
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    source := found.Value
    newMode := c.SourceType.Value = 2 ? MODE_LAUNCHER : MODE_FILES
    changed := source.Mode != newMode
    source.Mode := newMode
    if changed {
        if newMode = MODE_LAUNCHER
            ApplyLauncherSourceDefaults(source)
        else
            ApplyFilesSourceDefaults(c, source)
    }
    LoadSelectedSourceToControls(c)
    RefreshSourceListRow(c)
}

ApplyLauncherSourceDefaults(source) {
    global SCOPE_FILES_ONLY, SORT_NAME_ASC
    source.IncludeSubfolders := false
    source.DisplayScope := SCOPE_FILES_ONLY
    source.SortMode := SORT_NAME_ASC
    source.Filter := {Mode: "Include", Extensions: [".lnk", ".url", ".exe"]}
    source.StripOrderPrefix := 1
    source.HideExtensions := 1
}

ApplyFilesSourceDefaults(c, source) {
    global SCOPE_RECURSIVE_FILES, SORT_MODIFIED_DESC
    source.DisplayScope := c.Draft.General.DefaultDisplayScope
    source.IncludeSubfolders :=
        source.DisplayScope = SCOPE_RECURSIVE_FILES
    source.SortMode := SORT_MODIFIED_DESC
    source.Filter := {
        Mode: c.Draft.General.DefaultFilter.Mode,
        Extensions: c.Draft.General.DefaultFilter.Extensions.Clone()
    }
    source.StripOrderPrefix := 0
    source.HideExtensions := 0
}

ApplyTextBlockSourceDefaults(source, preserveSort := false) {
    global MODE_FILES, SCOPE_RECURSIVE_FILES, SORT_SMART
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    source.Mode := MODE_FILES
    source.IncludeSubfolders := true
    source.DisplayScope := SCOPE_RECURSIVE_FILES
    if !preserveSort || !ValueInArray(source.SortMode,
        [SORT_SMART, SORT_MODIFIED_DESC, SORT_NAME_ASC])
        source.SortMode := SORT_SMART
    source.Filter := {Mode: "Include", Extensions: [".md", ".txt"]}
    source.StripOrderPrefix := 0
    source.HideExtensions := 1
}

CommitCurrentSourceControlsToDraft(c) {
    global MODE_FILES, MODE_LAUNCHER
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    global SOURCE_OPEN_MODE_INHERIT, OPEN_MODE_SINGLE, OPEN_MODE_DOUBLE
    global SORT_MODIFIED_DESC, SORT_NAME_ASC, SORT_SMART
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    global WORKSPACE_TYPE_TEXT
    if c.Loading
        return
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    s := found.Value
    s.Name := Trim(c.SourceName.Value)
    s.Path := NormalizePath(c.SourcePath.Value)
    s.Mode := c.SourceType.Value = 2 ? MODE_LAUNCHER : MODE_FILES
    scopes := [SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES]
    s.DisplayScope := scopes[Max(1, c.SourceScope.Value)]
    s.IncludeSubfolders := s.DisplayScope = SCOPE_RECURSIVE_FILES
    modes := [SOURCE_OPEN_MODE_INHERIT, OPEN_MODE_SINGLE, OPEN_MODE_DOUBLE]
    s.OpenFileMode := modes[Max(1, c.SourceOpenMode.Value)]
    s.FolderTimeMode := c.SourceFolderTime.Value = 2
        ? FOLDER_TIME_LATEST_CONTENT : FOLDER_TIME_MODIFIED
    s.MaxFilesPerFolderInherited := c.SourceMaxMode.Value = 1
    s.MaxFilesPerFolder := s.MaxFilesPerFolderInherited
        ? c.Draft.General.MaxFilesPerFolder
        : c.SourceMaxMode.Value = 3 ? 0 : Trim(c.SourceMax.Value)
    s.SortMode := c.SourceSort.Value = 2 ? SORT_NAME_ASC
        : c.SourceSort.Value = 3 ? SORT_SMART : SORT_MODIFIED_DESC
    noiseModes := [NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED]
    s.NoiseFilterMode := noiseModes[Max(1, c.SourceNoiseMode.Value)]
    workspace := FindDraftWorkspace(c)
    if IsObject(workspace) && ParseWorkspaceType(workspace.Value.Type)
        = WORKSPACE_TYPE_TEXT
        ApplyTextBlockSourceDefaults(s, true)
}

RefreshSourceListRow(c) {
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    for row, id in c.SourceRows {
        if id = c.SelectedSourceId {
            s := found.Value
            c.SourceList.Modify(row, "", s.Name, s.Path,
                GetSourceDraftStatus(s, c.Draft.Sources))
            return
        }
    }
}

AddSourceToDraft(c, *) {
    global WORKSPACE_TYPE_TEXT
    path := SelectPanelFile("D3", "", "选择监控来源")
    if path = ""
        return
    path := NormalizePath(path)
    for source in c.Draft.Sources {
        if PathsEqual(source.Path, path) {
            RefreshSourceList(c, source.SourceId)
            SettingsMessage(c, "该文件夹已经是监控来源。", "添加来源", "Icon!")
            return
        }
    }
    overlaps := FindSourceOverlap(c.Draft.Sources, path)
    if overlaps != "" {
        answer := SettingsMessage(c,
            "该来源与“" overlaps "”存在父子路径重叠。仍要添加吗？",
            "来源路径重叠", "YesNo Icon!")
        if answer != "Yes"
            return
    }
    name := MakeUniqueSourceName(DefaultSourceNameForPath(path),
        c.Draft.Sources)
    id := NewStableId("source")
    source := CreateDefaultSourceDraft(name, path, id, c.Draft.General)
    workspace := FindDraftWorkspace(c)
    if IsObject(workspace) && ParseWorkspaceType(workspace.Value.Type)
        = WORKSPACE_TYPE_TEXT
        ApplyTextBlockSourceDefaults(source)
    c.Draft.Sources.Push(source)
    RefreshSourceList(c, id)
}

CreateDefaultSourceDraft(name, path, id, general) {
    global MODE_FILES, SCOPE_RECURSIVE_FILES
    global SORT_MODIFIED_DESC, SOURCE_OPEN_MODE_INHERIT
    global NOISE_FILTER_INHERIT
    return {
        Name: SanitizeSourceName(name),
        OriginalName: SanitizeSourceName(name),
        Path: NormalizePath(path),
        Mode: MODE_FILES,
        IncludeSubfolders:
            general.DefaultDisplayScope = SCOPE_RECURSIVE_FILES,
        DisplayScope: general.DefaultDisplayScope,
        FolderTimeMode: general.DefaultFolderTimeMode,
        MaxFilesPerFolder: general.MaxFilesPerFolder,
        MaxFilesPerFolderInherited: true,
        SortMode: SORT_MODIFIED_DESC,
        Filter: {
            Mode: general.DefaultFilter.Mode,
            Extensions: general.DefaultFilter.Extensions.Clone()
        },
        StripOrderPrefix: 0,
        HideExtensions: 0,
        SourceId: id,
        OpenFileMode: SOURCE_OPEN_MODE_INHERIT,
        NoiseFilterMode: NOISE_FILTER_INHERIT,
        SourceCustomPatternTexts: [],
        ExcludedPaths: [],
        AllowedExcludedPaths: []
    }
}

SourceConfigEntries(source, workspaceId) {
    return [
        {Key: "WorkspaceId", Value: workspaceId},
        {Key: "Name", Value: source.Name},
        {Key: "Path", Value: source.Path},
        {Key: "Mode", Value: source.Mode},
        {Key: "MaxFilesPerFolder", Value:
            source.MaxFilesPerFolderInherited
                ? "Inherit" : source.MaxFilesPerFolder},
        {Key: "IncludeSubfolders",
            Value: source.DisplayScope = "RecursiveFiles" ? "1" : "0"},
        {Key: "DisplayScope", Value: source.DisplayScope},
        {Key: "FolderTimeMode", Value: source.FolderTimeMode},
        {Key: "SortMode", Value: source.SortMode},
        {Key: "FilterMode", Value: source.Filter.Mode},
        {Key: "FileExtensions",
            Value: JoinArray(source.Filter.Extensions, ",")},
        {Key: "StripOrderPrefix",
            Value: source.StripOrderPrefix ? "1" : "0"},
        {Key: "HideExtensions",
            Value: source.HideExtensions ? "1" : "0"},
        {Key: "OpenFileMode",
            Value: ParseSourceOpenFileMode(source.OpenFileMode)},
        {Key: "NoiseFilterMode",
            Value: ParseNoiseFilterMode(source.NoiseFilterMode)}
    ]
}

SourceConfigKnownKeys() {
    return ["WorkspaceId", "Name", "Path", "Mode",
        "MaxFilesPerFolder", "IncludeSubfolders", "DisplayScope",
        "FolderTimeMode", "SortMode", "FilterMode",
        "FileExtensions", "StripOrderPrefix", "HideExtensions",
        "OpenFileMode", "NoiseFilterMode"]
}

MakeUniqueDraftSourceId(sources, base) {
    id := base
    suffix := 2
    Loop {
        exists := false
        for source in sources {
            if StrLower(source.SourceId) = StrLower(id) {
                exists := true
                break
            }
        }
        if !exists
            return id
        id := base "-" suffix++
    }
}

FindSourceOverlap(sources, path, ignoredId := "") {
    for source in sources {
        if source.SourceId = ignoredId
            continue
        if IsSameOrDescendantPath(path, source.Path)
            || IsSameOrDescendantPath(source.Path, path)
            return source.Name
    }
    return ""
}

RemoveSourceFromDraft(c, *) {
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    s := found.Value
    answer := SettingsMessage(c,
        "要从 PopDrop 中移除来源“" s.Name "”吗？`n`n"
        . "这只会停止显示该文件夹中的内容，不会删除任何本地文件。",
        "移除来源", "YesNo Icon!")
    if answer != "Yes"
        return
    c.Draft.Sources.RemoveAt(found.Index)
    c.SelectedSourceId := ""
    RefreshSourceList(c)
}

MoveSourceInDraft(c, delta, *) {
    CommitCurrentSourceControlsToDraft(c)
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    target := found.Index + delta
    if target < 1 || target > c.Draft.Sources.Length
        return
    c.Draft.Sources.RemoveAt(found.Index)
    c.Draft.Sources.InsertAt(target, found.Value)
    RefreshSourceList(c, found.Value.SourceId)
}

BrowseSourcePath(c, *) {
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    selected := SelectPanelFile("D3", found.Value.Path, "选择监控来源")
    if selected = ""
        return
    c.SourcePath.Value := NormalizePath(selected)
    CommitCurrentSourceControlsToDraft(c)
    RefreshSourceList(c, c.SelectedSourceId)
}

OpenSelectedSourcePath(c, *) {
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    if !DirExist(found.Value.Path) {
        SettingsMessage(c, "文件夹不存在或当前无法访问：`n"
            . found.Value.Path, "无法打开", "Icon!")
        return
    }
    OpenFolderInFileManager(found.Value.Path)
}

OpenSourcePathManager(c, field, *) {
    if IsObject(c.Child) {
        try WinActivate("ahk_id " c.Child.Hwnd)
        return
    }
    CommitCurrentSourceControlsToDraft(c)
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    source := found.Value
    localPaths := source.%field%.Clone()
    title := field = "ExcludedPaths"
        ? "排除的子文件夹" : "允许覆盖共享排除"
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox", title)
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 14
    child.MarginY := 12
    description := field = "ExcludedPaths"
        ? "这些子文件夹及其内容不会显示。"
        : "即使名称命中共享排除，这些路径仍允许扫描。"
    child.AddText("xm ym w500", description)
    list := child.AddListView("xm y+10 w500 h240 Report -Multi NoSortHdr",
        ["路径", "状态"])
    list.ModifyCol(1, 385)
    list.ModifyCol(2, 90)
    refresh := (*) => RefreshManagedPathList(list, localPaths)
    add := AddUiButton(child, "xm y+10 w78", "添加…")
    remove := AddUiButton(child, "x+7 yp w72", "移除")
    ok := AddUiButton(child, "x344 yp w72 Default", "确定")
    cancel := AddUiButton(child, "x+8 yp w72", "取消")
    add.OnEvent("Click", AddManagedSourcePath.Bind(
        c, source, localPaths, list))
    remove.OnEvent("Click", RemoveManagedSourcePath.Bind(localPaths, list))
    ok.OnEvent("Click", AcceptManagedSourcePaths.Bind(
        c, source.SourceId, field, localPaths, child))
    cancel.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    refresh()
    c.Gui.Opt("+Disabled")
    child.Show("w528 h330")
}

RefreshManagedPathList(list, paths) {
    list.Delete()
    for path in paths
        list.Add("", path, DirExist(path) ? "正常" : "路径不存在")
}

AddManagedSourcePath(c, source, paths, list, *) {
    selected := SelectPanelFile("D3", source.Path, "选择来源内的子文件夹")
    if selected = ""
        return
    selected := NormalizePath(selected)
    if PathsEqual(selected, source.Path)
        return SettingsMessage(c, "请选择来源根目录下面的子文件夹。",
            "路径无效", "Icon!")
    if !IsSameOrDescendantPath(selected, source.Path)
        return SettingsMessage(c, "所选文件夹必须位于当前来源之下。",
            "路径无效", "Icon!")
    if ArrayContainsPath(paths, selected)
        return
    paths.Push(selected)
    RefreshManagedPathList(list, paths)
}

RemoveManagedSourcePath(paths, list, *) {
    row := list.GetNext(0, "F")
    if !row
        row := list.GetNext()
    if !row
        return
    paths.RemoveAt(row)
    RefreshManagedPathList(list, paths)
}

AcceptManagedSourcePaths(c, sourceId, field, paths, child, *) {
    found := FindDraftSource(c, sourceId)
    if IsObject(found)
        found.Value.%field% := paths.Clone()
    CloseSettingsChild(c, child)
    LoadSelectedSourceToControls(c)
}

CloseSettingsChild(c, child, *) {
    try c.Gui.Opt("-Disabled")
    c.Child := 0
    try child.Destroy()
    try WinActivate("ahk_id " c.Gui.Hwnd)
}

OpenNoiseFilterManager(c, *) {
    if IsObject(c.Child)
        return
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox", "管理忽略规则")
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 16
    child.MarginY := 14
    n := c.Draft.General.NoiseFilter
    child.AddGroupBox("xm ym w600 h142", "文件属性与下载状态")
    hideHidden := child.AddCheckBox("x34 y48", "隐藏具有 Hidden 属性的文件")
    hideSystem := child.AddCheckBox("x320 yp", "隐藏具有 System 属性的文件")
    hideTemporary := child.AddCheckBox("x34 y82", "隐藏具有 Temporary 属性的文件")
    hideDownloads := child.AddCheckBox("x320 yp", "隐藏未完成的下载文件")
    hideHidden.Value := n.HideHidden
    hideSystem.Value := n.HideSystem
    hideTemporary.Value := n.HideTemporary
    hideDownloads.Value := n.HideIncompleteDownloads
    child.AddText("x34 y116 w545 c666666",
        "未完成下载规则：*.crdownload、*.part、*.download（默认关闭）。")
    child.AddGroupBox("xm y166 w600 h310", "自定义忽略规则")
    child.AddText("x34 y194 w548 c555555",
        "每行一条，只匹配文件名；* 匹配任意数量字符，? 匹配一个字符，不区分大小写。")
    patterns := AddUiEdit(child, "x34 y230 w548 h205 Multi VScroll -Wrap")
    patterns.Value := JoinArray(n.CustomPatternTexts, "`r`n")
    child.AddText("x34 y445 w548 c666666",
        "空行会忽略，重复规则只保留一条。规则不会删除或修改文件。")
    ok := AddUiButton(child, "x438 y494 w78 Default", "确定")
    cancel := AddUiButton(child, "x+8 yp w78", "取消")
    ok.OnEvent("Click", AcceptNoiseFilterManager.Bind(c, hideHidden,
        hideSystem, hideTemporary, hideDownloads, patterns, child))
    cancel.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    c.Gui.Opt("+Disabled")
    child.Show("w632 h542")
}

AcceptNoiseFilterManager(c, hideHidden, hideSystem, hideTemporary,
    hideDownloads, patterns, child, *) {
    compiled := CompileIgnorePatterns(NormalizeIgnorePatternTextBlock(patterns.Value),
        "自定义忽略规则")
    if compiled.Errors.Length {
        message := "以下规则无效，将不会保存：`n`n"
        for item in compiled.Errors
            message .= "• " item "`n"
        return SettingsMessage(c, message, "忽略规则无效", "Iconx")
    }
    n := c.Draft.General.NoiseFilter
    n.HideHidden := !!hideHidden.Value
    n.HideSystem := !!hideSystem.Value
    n.HideTemporary := !!hideTemporary.Value
    n.HideIncompleteDownloads := !!hideDownloads.Value
    n.CustomPatternTexts := compiled.Texts
    CloseSettingsChild(c, child)
}

OpenSourceIgnoreRules(c, *) {
    if IsObject(c.Child)
        return
    found := FindDraftSource(c)
    if !IsObject(found)
        return
    source := found.Value
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox", "来源附加忽略规则")
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 16
    child.MarginY := 14
    child.AddText("xm ym w548 h66", "这些规则只应用于来源“" source.Name
        "”，匹配的文件名将不会在 PopDrop 中显示。"
        . "`n每行一条：* 表示任意多个字符，? 表示任意一个字符；匹配不区分大小写。"
        . "`n例如：*.myapp-lock 会隐藏 report.myapp-lock。")
    patterns := AddUiEdit(child, "xm y+10 w548 h230 Multi VScroll -Wrap")
    patterns.Value := JoinArray(source.SourceCustomPatternTexts, "`r`n")
    child.AddText("xm y+8 w548 c666666",
        "来源选择“禁用”时，内置、共享和这些附加规则均不应用。")
    ok := AddUiButton(child, "x402 y386 w78 Default", "确定")
    cancel := AddUiButton(child, "x+8 yp w78", "取消")
    ok.OnEvent("Click", AcceptSourceIgnoreRules.Bind(c, source.SourceId, patterns, child))
    cancel.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    c.Gui.Opt("+Disabled")
    child.Show("w580 h434")
}

AcceptSourceIgnoreRules(c, sourceId, patterns, child, *) {
    compiled := CompileIgnorePatterns(NormalizeIgnorePatternTextBlock(patterns.Value),
        "来源附加规则")
    if compiled.Errors.Length {
        message := "以下规则无效，将不会保存：`n`n"
        for item in compiled.Errors
            message .= "• " item "`n"
        return SettingsMessage(c, message, "忽略规则无效", "Iconx")
    }
    found := FindDraftSource(c, sourceId)
    if IsObject(found)
        found.Value.SourceCustomPatternTexts := compiled.Texts
    CloseSettingsChild(c, child)
    LoadSelectedSourceToControls(c)
}

OpenHiddenNoiseItems(c, *) {
    global CurrentScanResult
    if IsObject(c.Child)
        return
    if !IsObject(CurrentScanResult) || !HasProp(CurrentScanResult, "HiddenItems")
        || !CurrentScanResult.HiddenItems.Length
        return SettingsMessage(c, "当前没有可查看的诊断记录。请刷新 PopDrop 后再试。",
            "已隐藏项目", "Iconi")
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox", "本次已隐藏项目")
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 14
    child.MarginY := 12
    total := HasProp(CurrentScanResult, "HiddenCount")
        ? CurrentScanResult.HiddenCount : CurrentScanResult.HiddenItems.Length
    child.AddText("xm ym w820", "本次共隐藏 " total " 个项目；诊断列表最多保留 200 条。")
    list := child.AddListView("xm y+10 w820 h360 Report -Multi NoSortHdr",
        ["文件名", "来源", "原因", "完整路径"])
    list.ModifyCol(1, 175)
    list.ModifyCol(2, 120)
    list.ModifyCol(3, 170)
    list.ModifyCol(4, 330)
    for item in CurrentScanResult.HiddenItems
        list.Add("", item.Name, item.Source, NoiseFilterReasonLabel(item.Reason), item.Path)
    close := AddUiButton(child, "x756 y414 w78 Default", "关闭")
    close.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    c.Gui.Opt("+Disabled")
    child.Show("w848 h460")
}

RefreshApplicationList(c, preferredId := "") {
    if preferredId = ""
        preferredId := c.SelectedAppId
    c.AppList.Delete()
    c.AppRows := Map()
    selectRow := 0
    for app in c.Draft.Applications {
        applicable := !app.ShowInOpenMenu ? "不显示"
            : (app.Extensions.Length
                ? JoinArray(app.Extensions, " ") : "所有文件")
        status := !app.Enabled ? "已禁用"
            : (IsExistingExecutable(app.Path)
                ? ApplicationDraftStatus(app) : "程序不存在")
        row := c.AppList.Add("", app.Name, app.Path, applicable,
            app.Actions.Length, status)
        c.AppRows[row] := app.Id
        if app.Id = preferredId
            selectRow := row
    }
    if selectRow
        c.AppList.Modify(selectRow, "Select Focus Vis")
}

ApplicationDraftStatus(app) {
    for action in app.Actions {
        validation := ValidateOpenAppAction(action, app, false)
        if !action.Valid || validation.Errors.Length
            return "参数有误"
        executable := action.Executable != ""
            ? action.Executable : app.Path
        if action.Enabled && !IsExistingExecutable(executable)
            return "动作程序不存在"
    }
    return "正常"
}

ApplicationSelected(c, list, row, selected) {
    if selected && c.AppRows.Has(row)
        c.SelectedAppId := c.AppRows[row]
}

FindDraftApplication(c, id := "") {
    if id = ""
        id := c.SelectedAppId
    for index, app in c.Draft.Applications {
        if app.Id = id
            return {Index: index, Value: app}
    }
    return 0
}

EditSelectedApplication(c, *) {
    found := FindDraftApplication(c)
    if IsObject(found)
        OpenApplicationEditor(c, found.Value)
}

OpenApplicationEditor(c, existing, *) {
    if IsObject(c.Child) {
        try WinActivate("ahk_id " c.Child.Hwnd)
        return
    }
    isEdit := IsObject(existing)
    app := isEdit ? CloneSettingsApplication(existing)
        : {Id: "", Path: "", Name: "", Icon: "", Extensions: [],
            Enabled: true, ShowInOpenMenu: true, Actions: []}
    app.OriginalPath := isEdit ? existing.Path : ""
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox",
        isEdit ? "编辑软件" : "添加软件")
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 14
    child.MarginY := 12
    child.AddText("xm ym+4 w100", "名称：")
    name := AddUiEdit(child, "x90 yp-4 w390", app.Name)
    child.AddText("xm y+18 w70", "程序：")
    path := AddUiEdit(child, "x90 yp-4 w310", app.Path)
    browse := AddUiButton(child, "x+8 yp w72", "浏览…")
    enabled := child.AddCheckBox("xm y+18 Checked" (app.Enabled ? "1" : "0"),
        "启用此应用")
    showOpen := child.AddCheckBox("xm y+10 Checked"
        (app.ShowInOpenMenu ? "1" : "0"), "显示在“打开方式”菜单中")
    allFiles := child.AddRadio("xm y+16 Group", "所有文件")
    specified := child.AddRadio("xm y+12", "指定扩展名：")
    extensions := AddUiEdit(child, "x120 yp-4 w360",
        JoinArray(app.Extensions, ", "))
    hint := child.AddText("x120 y+2 w360 cGray", "多个扩展名用 , 分割")
    allFiles.Value := app.Extensions.Length = 0
    specified.Value := app.Extensions.Length > 0
    updateOpenControls := UpdateApplicationOpenMenuControls.Bind(
        showOpen, allFiles, specified, extensions, hint)
    allFiles.OnEvent("Click", updateOpenControls)
    specified.OnEvent("Click", updateOpenControls)
    showOpen.OnEvent("Click", updateOpenControls)
    updateOpenControls()
    browse.OnEvent("Click", BrowseExecutableForEditor.Bind(path, name))
    manageActions := AddUiButton(child, "xm y+20 w100", "管理动作…")
    manageActions.OnEvent("Click", OpenNestedActionManager.Bind(
        c, app, child, name, path))
    ok := AddUiButton(child, "x320 yp w72 Default", "确定")
    cancel := AddUiButton(child, "x+8 yp w72", "取消")
    ok.OnEvent("Click", AcceptApplicationEditor.Bind(
        c, app, isEdit, name, path, enabled, showOpen,
        specified, extensions, child))
    cancel.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    c.Gui.Opt("+Disabled")
    child.Show("w508 h346")
}

UpdateApplicationOpenMenuControls(
    showOpen, allFiles, specified, extensions, hint, *
) {
    enabled := !!showOpen.Value
    allFiles.Enabled := enabled
    specified.Enabled := enabled
    extensions.Enabled := enabled && specified.Value
    hint.Enabled := enabled
}

BrowseExecutableForEditor(pathControl, nameControl, *) {
    selected := SelectPanelFile("1", "", "选择程序", "程序 (*.exe)")
    if selected = ""
        return
    pathControl.Value := NormalizePath(selected)
    if Trim(nameControl.Value) = ""
        nameControl.Value := GetExecutableDisplayName(selected)
}

NormalizeSettingsExtensions(raw) {
    raw := RegExReplace(raw, "[;\s]+", ",")
    return NormalizeOpenAppExtensions(raw)
}

AcceptApplicationEditor(c, app, isEdit, nameCtrl, pathCtrl,
    enabledCtrl, showOpenCtrl, specifiedCtrl, extCtrl, child, *) {
    name := Trim(nameCtrl.Value)
    path := NormalizePath(pathCtrl.Value)
    if name = ""
        return SettingsMessage(c, "软件名称不能为空。", "输入有误", "Icon!")
    if !IsExecutablePath(path)
        return SettingsMessage(c, "程序路径必须以 .exe 结尾。", "输入有误", "Icon!")
    if (!isEdit || !PathsEqual(path, app.OriginalPath))
        && !IsExistingExecutable(path)
        return SettingsMessage(c, "请选择一个存在的 .exe 程序。",
            "输入有误", "Icon!")
    for other in c.Draft.Applications {
        if other.Id != app.Id && PathsEqual(other.Path, path)
            return SettingsMessage(c, "该程序已经在软件列表中。",
                "重复程序", "Icon!")
    }
    extensions := specifiedCtrl.Value
        ? NormalizeSettingsExtensions(extCtrl.Value) : []
    if specifiedCtrl.Value && !extensions.Length
        return SettingsMessage(c, "请填写至少一个扩展名，或选择“所有文件”。",
            "输入有误", "Icon!")
    app.Path := path
    app.Name := name
    app.Icon := path
    app.Extensions := extensions
    app.Enabled := !!enabledCtrl.Value
    app.ShowInOpenMenu := !!showOpenCtrl.Value
    if !isEdit {
        app.Id := MakeDraftOpenAppId(c.Draft.Applications, path)
        c.Draft.Applications.Push(app)
    } else {
        found := FindDraftApplication(c, app.Id)
        if IsObject(found)
            c.Draft.Applications[found.Index] := app
    }
    c.SelectedAppId := app.Id
    CloseSettingsChild(c, child)
    RefreshApplicationList(c, app.Id)
}

MakeDraftOpenAppId(apps, path) {
    base := OpenAppIdBase(path)
    id := base
    suffix := 2
    Loop {
        exists := false
        for app in apps {
            if StrLower(app.Id) = StrLower(id) {
                exists := true
                break
            }
        }
        if !exists
            return id
        id := base "-" suffix++
    }
}

RemoveSelectedApplication(c, *) {
    found := FindDraftApplication(c)
    if !IsObject(found)
        return
    c.Draft.Applications.RemoveAt(found.Index)
    c.SelectedAppId := ""
    RefreshApplicationList(c)
}

MoveSelectedApplication(c, delta, *) {
    found := FindDraftApplication(c)
    if !IsObject(found)
        return
    target := found.Index + delta
    if target < 1 || target > c.Draft.Applications.Length
        return
    c.Draft.Applications.RemoveAt(found.Index)
    c.Draft.Applications.InsertAt(target, found.Value)
    RefreshApplicationList(c, found.Value.Id)
}

ManageSelectedApplicationActions(c, *) {
    found := FindDraftApplication(c)
    if IsObject(found)
        OpenActionManager(c, found.Value, c.Gui, false)
}

OpenNestedActionManager(c, app, parent, nameCtrl, pathCtrl, *) {
    name := Trim(nameCtrl.Value)
    path := NormalizePath(pathCtrl.Value)
    if name != ""
        app.Name := name
    if path != "" {
        app.Path := path
        app.Icon := path
    }
    OpenActionManager(c, app, parent, true)
}

OpenActionManager(c, app, parent, nested := false) {
    if !nested && IsObject(c.Child)
        return
    manager := Gui("+Owner" parent.Hwnd " -MaximizeBox -MinimizeBox",
        "管理动作 · " (app.Name != "" ? app.Name : "新应用"))
    state := {
        Gui: manager,
        App: app,
        Parent: parent,
        Nested: nested,
        SelectedId: "",
        Rows: Map()
    }
    if !nested
        c.Child := manager
    manager.SetFont("s9", "Microsoft YaHei UI")
    manager.MarginX := 14
    manager.MarginY := 12
    try manager.AddPicture("xm ym w32 h32 Icon1", app.Icon)
    manager.AddText("x58 ym w650", "应用：" (app.Name != "" ? app.Name : "新应用"))
    manager.AddText("x58 y+4 w650 c666666", "主程序：" app.Path)
    list := manager.AddListView("xm y+14 w760 h300 Report -Multi NoSortHdr",
        ["动作名称", "适用对象", "文件类型", "执行模式", "状态"])
    state.List := list
    list.ModifyCol(1, 230)
    list.ModifyCol(2, 100)
    list.ModifyCol(3, 190)
    list.ModifyCol(4, 120)
    list.ModifyCol(5, 95)
    add := AddUiButton(manager, "xm y+10 w82", "添加动作")
    edit := AddUiButton(manager, "x+7 yp w72", "编辑")
    copy := AddUiButton(manager, "x+7 yp w82", "复制动作")
    remove := AddUiButton(manager, "x+7 yp w72", "移除")
    up := AddUiButton(manager, "x+7 yp w72", "上移")
    down := AddUiButton(manager, "x+7 yp w72", "下移")
    close := AddUiButton(manager, "x704 yp w70 Default", "关闭")
    list.OnEvent("ItemSelect", ActionManagerSelected.Bind(state))
    add.OnEvent("Click", OpenActionEditor.Bind(c, state, 0))
    edit.OnEvent("Click", EditSelectedAction.Bind(c, state))
    copy.OnEvent("Click", CopySelectedAction.Bind(state))
    remove.OnEvent("Click", RemoveSelectedAction.Bind(state))
    up.OnEvent("Click", MoveSelectedAction.Bind(state, -1))
    down.OnEvent("Click", MoveSelectedAction.Bind(state, 1))
    close.OnEvent("Click", CloseActionManager.Bind(c, state))
    manager.OnEvent("Close", CloseActionManager.Bind(c, state))
    manager.OnEvent("Escape", CloseActionManager.Bind(c, state))
    RefreshActionManagerList(state)
    parent.Opt("+Disabled")
    manager.Show("w788 h410")
}

CloseActionManager(c, state, *) {
    try state.Parent.Opt("-Disabled")
    if !state.Nested
        c.Child := 0
    try state.Gui.Destroy()
    try WinActivate("ahk_id " state.Parent.Hwnd)
    RefreshApplicationList(c, state.App.Id)
}

RefreshActionManagerList(state, preferredId := "") {
    if preferredId = ""
        preferredId := state.SelectedId
    state.List.Delete()
    state.Rows := Map()
    selectedRow := 0
    for action in state.App.Actions {
        extensions := action.Extensions.Length
            ? JoinArray(action.Extensions, " ") : "所有文件"
        row := state.List.Add("", action.Name,
            ActionTargetTypesLabel(action.TargetTypes),
            extensions,
            ActionExecutionModeLabel(action.ExecutionMode),
            ActionDraftStatus(state.App, action))
        state.Rows[row] := action.Id
        if action.Id = preferredId
            selectedRow := row
    }
    if selectedRow
        state.List.Modify(selectedRow, "Select Focus Vis")
}

ActionManagerSelected(state, list, row, selected) {
    if selected && state.Rows.Has(row)
        state.SelectedId := state.Rows[row]
}

FindDraftAction(state, id := "") {
    if id = ""
        id := state.SelectedId
    for index, action in state.App.Actions {
        if action.Id = id
            return {Index: index, Value: action}
    }
    return 0
}

EditSelectedAction(c, state, *) {
    found := FindDraftAction(state)
    if IsObject(found)
        OpenActionEditor(c, state, found.Value)
}

CopySelectedAction(state, *) {
    found := FindDraftAction(state)
    if !IsObject(found)
        return
    action := CloneOpenAppAction(found.Value)
    action.Id := MakeDraftOpenAppActionId(
        state.App.Actions, action.Name "-copy")
    action.Name := action.Name " - 副本"
    state.App.Actions.InsertAt(found.Index + 1, action)
    state.SelectedId := action.Id
    RefreshActionManagerList(state, action.Id)
}

RemoveSelectedAction(state, *) {
    found := FindDraftAction(state)
    if !IsObject(found)
        return
    state.App.Actions.RemoveAt(found.Index)
    state.SelectedId := ""
    RefreshActionManagerList(state)
}

MoveSelectedAction(state, delta, *) {
    found := FindDraftAction(state)
    if !IsObject(found)
        return
    target := found.Index + delta
    if target < 1 || target > state.App.Actions.Length
        return
    state.App.Actions.RemoveAt(found.Index)
    state.App.Actions.InsertAt(target, found.Value)
    RefreshActionManagerList(state, found.Value.Id)
}

ActionTargetTypesLabel(value) {
    global ACTION_TARGET_FILES, ACTION_TARGET_FOLDERS
    return value = ACTION_TARGET_FILES ? "仅文件"
        : (value = ACTION_TARGET_FOLDERS ? "仅文件夹" : "文件和文件夹")
}

ActionExecutionModeLabel(value) {
    global ACTION_EXECUTION_PER_ITEM
    return value = ACTION_EXECUTION_PER_ITEM
        ? "逐个串行" : "一次传入全部"
}

ActionDraftStatus(app, action) {
    if !action.Enabled
        return "已禁用"
    validation := ValidateOpenAppAction(action, app, false)
    if !action.Valid || validation.Errors.Length
        return "参数有误"
    executable := action.Executable != "" ? action.Executable : app.Path
    return IsExistingExecutable(executable) ? "正常" : "程序不存在"
}

MakeDraftOpenAppActionId(actions, seed) {
    return NewOpenAppActionIdForActions(actions, seed)
}

OpenActionEditor(c, state, existing, *) {
    global ACTION_TARGET_FILES, ACTION_TARGET_FOLDERS, ACTION_TARGET_BOTH
    global ACTION_EXECUTION_PER_ITEM, ACTION_EXECUTION_BATCH
    global ACTION_WORKDIR_FOLDER, ACTION_WORKDIR_PROGRAM
    global ACTION_WORKDIR_CUSTOM
    isEdit := IsObject(existing)
    action := isEdit ? CloneOpenAppAction(existing) : {
        Id: "", Name: "", Executable: "",
        TargetTypes: ACTION_TARGET_FILES,
        ExecutionMode: ACTION_EXECUTION_PER_ITEM,
        Extensions: [], RequireCommonFolder: false,
        WorkingDirectoryMode: ACTION_WORKDIR_FOLDER,
        WorkingDirectory: "", Confirm: false, Enabled: true,
        Args: [], Valid: true, ValidationError: ""
    }
    editor := Gui("+Owner" state.Gui.Hwnd " -MaximizeBox -MinimizeBox",
        isEdit ? "编辑动作" : "添加动作")
    editor.SetFont("s9", "Microsoft YaHei UI")
    editor.MarginX := 14
    editor.MarginY := 12
    controls := {Gui: editor, Action: action, App: state.App}

    editor.AddGroupBox("xm ym w820 h58", "基本信息")
    editor.AddText("x30 y34 w76", "动作名称：")
    controls.Name := AddUiEdit(editor, "x112 yp-4 w400", action.Name)
    controls.Enabled := editor.AddCheckBox("x540 yp+2 Checked"
        (action.Enabled ? "1" : "0"), "启用此动作")
    controls.Confirm := editor.AddCheckBox("x660 yp Checked"
        (action.Confirm ? "1" : "0"), "执行前确认")

    editor.AddGroupBox("xm y78 w820 h134", "显示条件")
    editor.AddText("x30 y102 w76", "适用对象：")
    controls.Target := AddUiDropDownList(editor, "x112 yp-5 w190",
        ["仅文件", "仅文件夹", "文件和文件夹"])
    controls.Target.Choose(action.TargetTypes = ACTION_TARGET_FOLDERS
        ? 2 : (action.TargetTypes = ACTION_TARGET_BOTH ? 3 : 1))
    editor.AddText("x330 yp+5 w76", "执行模式：")
    controls.ExecutionMode := AddUiDropDownList(
        editor, "x412 yp-5 w190",
        ["逐个项目串行执行", "一次传入全部项目"])
    controls.ExecutionMode.Choose(
        action.ExecutionMode = ACTION_EXECUTION_BATCH ? 2 : 1)
    controls.RequireFolder := editor.AddCheckBox("x630 yp+3 Checked"
        (action.RequireCommonFolder ? "1" : "0"),
        "必须位于同一文件夹")
    controls.AllFiles := editor.AddRadio("x30 y138 Group", "所有文件")
    controls.SpecifiedFiles := editor.AddRadio(
        "x30 y170", "指定扩展名：")
    controls.Extensions := AddUiEdit(editor, "x140 yp-4 w630",
        JoinArray(action.Extensions, ", "))
    editor.AddText("x140 y+2 w630 c666666",
        "不区分大小写；自动补全 .；支持 <none> 和 .tar.gz。文件夹不参与扩展名判断。")
    controls.AllFiles.Value := action.Extensions.Length = 0
    controls.SpecifiedFiles.Value := action.Extensions.Length > 0

    editor.AddGroupBox("xm y220 w820 h278", "执行设置")
    editor.AddText("x30 y246 w76", "执行程序：")
    controls.InheritExe := editor.AddRadio(
        "x112 yp Group", "跟随应用主程序")
    controls.OtherExe := editor.AddRadio("x280 yp", "使用其他 EXE")
    controls.Executable := AddUiEdit(editor, "x410 yp-4 w280",
        action.Executable)
    controls.BrowseExe := AddUiButton(editor, "x+8 yp w72", "浏览…")
    controls.InheritExe.Value := action.Executable = ""
    controls.OtherExe.Value := action.Executable != ""
    editor.AddText("x30 y282 w76", "参数模板：")
    controls.Args := editor.AddEdit(
        "x112 yp-4 w460 h140 Multi WantTab",
        JoinArray(action.Args, "`r`n"))
    controls.ArgsHelp := editor.AddText("x112 y+3 w460 c666666",
        "每行表示一个参数；{items} 必须单独占一行。")
    editor.AddText("x590 y282 w100", "插入变量：")
    controls.VariableButtons := Map()
    tokens := ["{item}", "{items}", "{folder}", "{parent}",
        "{name}", "{stem}", "{ext}", "{date}", "{time}",
        "{index}", "{count}", "{size}"]
    for index, token in tokens {
        column := Mod(index - 1, 3)
        row := Floor((index - 1) / 3)
        button := AddUiButton(editor,
            "x" (590 + column * 76) " y" (306 + row * 30) " w70",
            token)
        controls.VariableButtons[token] := button
        button.OnEvent("Click", InsertActionVariable.Bind(
            controls.Args, token, () => UpdateActionEditorControls(controls)))
    }
    editor.AddText("x30 y464 w76", "工作目录：")
    controls.WorkingMode := AddUiDropDownList(editor, "x112 yp-5 w190",
        ["所选项目所在文件夹", "程序所在文件夹", "自定义目录"])
    controls.WorkingMode.Choose(
        action.WorkingDirectoryMode = ACTION_WORKDIR_PROGRAM ? 2
        : (action.WorkingDirectoryMode = ACTION_WORKDIR_CUSTOM ? 3 : 1))
    controls.WorkingDirectory := AddUiEdit(editor, "x310 yp w380",
        action.WorkingDirectory)
    controls.BrowseDirectory := AddUiButton(editor, "x+8 yp w72", "浏览…")

    editor.AddGroupBox("xm y506 w820 h104", "检查与预览")
    controls.Check := editor.AddText("x30 y528 w760 h22 c666666", "")
    controls.Preview := editor.AddEdit(
        "x30 y552 w760 h54 ReadOnly Multi -Wrap", "")
    ok := AddUiButton(editor, "x646 y614 w72 Default", "确定")
    cancel := AddUiButton(editor, "x+8 yp w72", "取消")

    refresh := (*) => UpdateActionEditorControls(controls)
    for control in [controls.Name, controls.Target, controls.ExecutionMode,
        controls.Extensions, controls.Executable,
        controls.Args, controls.WorkingMode, controls.WorkingDirectory]
        control.OnEvent("Change", refresh)
    for control in [controls.Enabled, controls.Confirm,
        controls.RequireFolder, controls.AllFiles,
        controls.SpecifiedFiles, controls.InheritExe, controls.OtherExe]
        control.OnEvent("Click", refresh)
    controls.BrowseExe.OnEvent("Click",
        BrowseActionExecutable.Bind(controls.Executable, controls.OtherExe,
            refresh))
    controls.BrowseDirectory.OnEvent("Click",
        BrowseActionWorkingDirectory.Bind(
            controls.WorkingDirectory, controls.WorkingMode, refresh))
    ok.OnEvent("Click", AcceptActionEditor.Bind(
        c, state, action, isEdit, controls, editor))
    cancel.OnEvent("Click", CloseActionEditor.Bind(state, editor))
    editor.OnEvent("Close", CloseActionEditor.Bind(state, editor))
    editor.OnEvent("Escape", CloseActionEditor.Bind(state, editor))
    state.Gui.Opt("+Disabled")
    UpdateActionEditorControls(controls)
    editor.Show("w848 h650")
}

InsertActionVariable(control, token, refresh, *) {
    current := control.Value
    control.Value := current = "" ? token : current "`r`n" token
    control.Focus()
    refresh.Call()
}

BrowseActionExecutable(control, radio, refresh, *) {
    selected := SelectPanelFile("1", "", "选择动作执行程序", "程序 (*.exe)")
    if selected = ""
        return
    control.Value := NormalizePath(selected)
    radio.Value := 1
    refresh.Call()
}

BrowseActionWorkingDirectory(control, dropdown, refresh, *) {
    selected := SelectPanelFile("D1", "", "选择自定义工作目录")
    if selected = ""
        return
    control.Value := NormalizePath(selected)
    dropdown.Choose(3)
    refresh.Call()
}

CaptureActionEditorDraft(controls) {
    global ACTION_TARGET_FILES, ACTION_TARGET_FOLDERS, ACTION_TARGET_BOTH
    global ACTION_EXECUTION_PER_ITEM, ACTION_EXECUTION_BATCH
    global ACTION_WORKDIR_FOLDER, ACTION_WORKDIR_PROGRAM
    global ACTION_WORKDIR_CUSTOM
    action := CloneOpenAppAction(controls.Action)
    action.Name := Trim(controls.Name.Value)
    action.Enabled := !!controls.Enabled.Value
    action.Confirm := !!controls.Confirm.Value
    action.TargetTypes := controls.Target.Value = 2
        ? ACTION_TARGET_FOLDERS
        : (controls.Target.Value = 3
            ? ACTION_TARGET_BOTH : ACTION_TARGET_FILES)
    action.ExecutionMode := controls.ExecutionMode.Value = 2
        ? ACTION_EXECUTION_BATCH : ACTION_EXECUTION_PER_ITEM
    action.Extensions := controls.SpecifiedFiles.Value
        ? NormalizeActionExtensions(controls.Extensions.Value) : []
    action.RequireCommonFolder := !!controls.RequireFolder.Value
    action.Executable := controls.OtherExe.Value
        ? NormalizePath(controls.Executable.Value) : ""
    action.Args := ActionArgsFromEditor(controls.Args.Value)
    action.WorkingDirectoryMode :=
        controls.WorkingMode.Value = 2
            ? ACTION_WORKDIR_PROGRAM
            : (controls.WorkingMode.Value = 3
                ? ACTION_WORKDIR_CUSTOM : ACTION_WORKDIR_FOLDER)
    action.WorkingDirectory := action.WorkingDirectoryMode
        = ACTION_WORKDIR_CUSTOM ? Trim(controls.WorkingDirectory.Value) : ""
    action.Valid := true
    action.ValidationError := ""
    return action
}

ActionArgsFromEditor(text) {
    text := StrReplace(text, "`r`n", "`n")
    text := StrReplace(text, "`r", "`n")
    return text = "" ? [] : StrSplit(text, "`n")
}

UpdateActionEditorControls(controls) {
    global ACTION_EXECUTION_BATCH, ACTION_WORKDIR_CUSTOM
    controls.Extensions.Enabled := controls.SpecifiedFiles.Value
    controls.Executable.Enabled := controls.OtherExe.Value
    controls.BrowseExe.Enabled := controls.OtherExe.Value
    action := CaptureActionEditorDraft(controls)
    controls.VariableButtons["{items}"].Enabled :=
        action.ExecutionMode = ACTION_EXECUTION_BATCH
    controls.ArgsHelp.Text := action.ExecutionMode = ACTION_EXECUTION_BATCH
        ? "每行表示一个参数；{items} 必须单独占一行。"
        : "每行表示一个参数；逐个执行不能使用 {items}。"
    custom := action.WorkingDirectoryMode = ACTION_WORKDIR_CUSTOM
    controls.WorkingDirectory.Enabled := custom
    controls.BrowseDirectory.Enabled := custom
    validation := ValidateOpenAppAction(action, controls.App, false)
    if controls.SpecifiedFiles.Value && !action.Extensions.Length
        validation.Errors.Push("指定扩展名时至少填写一个有效扩展名")
    if controls.SpecifiedFiles.Value {
        for item in ValidateActionExtensionInput(controls.Extensions.Value)
            validation.Errors.Push(item)
    }
    if action.Executable != "" && !IsExistingExecutable(action.Executable)
        validation.Warnings.Push("覆盖执行程序当前不存在")
    if validation.Errors.Length {
        controls.Check.Text := "配置有误：" JoinArray(validation.Errors, "；")
        controls.Check.SetFont("cB00020")
    } else if validation.Warnings.Length {
        controls.Check.Text := "需要注意：" JoinArray(validation.Warnings, "；")
        controls.Check.SetFont("c9A5A00")
    } else {
        controls.Check.Text := "配置检查：正常"
        controls.Check.SetFont("c287A28")
    }
    controls.Preview.Value := BuildActionEditorPreview(
        controls.App, action)
}

BuildActionEditorPreview(app, action) {
    global ACTION_EXECUTION_BATCH
    executable := action.Executable != "" ? action.Executable : app.Path
    paths := [
        "C:\示例 图片\旅行照片 (1).jpg",
        "C:\示例 图片\海报 & 插图.png"
    ]
    stamp := A_Now
    if action.ExecutionMode = ACTION_EXECUTION_BATCH {
        variables := BuildOpenAppActionVariables(
            paths[1], 1, paths.Length, stamp)
        variables.Size := "15KB"
        command := BuildActionEditorPreviewCommand(
            action, executable, paths, variables)
        return "[一次传入全部] " command.Command
            . "`r`n工作目录：" command.WorkingDirectory
            . "`r`n所选项目：" paths.Length " 个"
    }
    lines := []
    for index, path in paths {
        variables := BuildOpenAppActionVariables(
            path, index, paths.Length, stamp)
        variables.Size := index = 1 ? "15KB" : "2.4MB"
        command := BuildActionEditorPreviewCommand(
            action, executable, [path], variables)
        lines.Push("[" index "/" paths.Length "] " command.Command)
        lines.Push("    工作目录：" command.WorkingDirectory)
    }
    return JoinArray(lines, "`r`n")
}

BuildActionEditorPreviewCommand(action, executable, paths, variables) {
    global ACTION_WORKDIR_FOLDER, ACTION_WORKDIR_PROGRAM
    args := []
    for template in action.Args {
        if StrLower(template) = "{items}" {
            for path in paths
                args.Push(path)
        } else
            args.Push(ReplaceOpenAppActionVariables(template, variables))
    }
    preview := QuoteWindowsArgument(executable)
    parameters := BuildWindowsParameterString(args)
    if parameters != ""
        preview .= " " parameters
    if action.WorkingDirectoryMode = ACTION_WORKDIR_FOLDER
        workDir := variables.Folder
    else if action.WorkingDirectoryMode = ACTION_WORKDIR_PROGRAM
        SplitPath(executable, , &workDir)
    else
        workDir := ReplaceOpenAppActionVariables(
            action.WorkingDirectory, variables)
    return {Command: preview, WorkingDirectory: workDir}
}

AcceptActionEditor(c, state, original, isEdit, controls, editor, *) {
    action := CaptureActionEditorDraft(controls)
    validation := ValidateOpenAppAction(action, state.App, false)
    if controls.SpecifiedFiles.Value && !action.Extensions.Length
        validation.Errors.Push("指定扩展名时至少填写一个有效扩展名")
    if controls.SpecifiedFiles.Value {
        for item in ValidateActionExtensionInput(controls.Extensions.Value)
            validation.Errors.Push(item)
    }
    if action.Executable != "" && !IsExistingExecutable(action.Executable)
        validation.Errors.Push("请选择一个存在的 .exe 覆盖程序")
    if validation.Errors.Length
        return SettingsMessage(c, "请修正动作配置：`n`n"
            JoinArray(validation.Errors, "`n"), "无法保存动作", "Iconx")
    if !isEdit {
        action.Id := MakeDraftOpenAppActionId(
            state.App.Actions, action.Name)
        state.App.Actions.Push(action)
    } else {
        action.Id := original.Id
        found := FindDraftAction(state, original.Id)
        if IsObject(found)
            state.App.Actions[found.Index] := action
    }
    state.SelectedId := action.Id
    CloseActionEditor(state, editor)
    RefreshActionManagerList(state, action.Id)
}

CloseActionEditor(state, editor, *) {
    try state.Gui.Opt("-Disabled")
    try editor.Destroy()
    try WinActivate("ahk_id " state.Gui.Hwnd)
}

RefreshDestinationList(c, preferredId := "") {
    if preferredId = ""
        preferredId := c.SelectedTargetId
    c.TargetList.Delete()
    c.TargetRows := Map()
    selectRow := 0
    for target in c.Draft.CommonDestinations {
        row := c.TargetList.Add("", target.Name, target.Path,
            DirExist(target.Path) ? "正常" : "路径不可用")
        c.TargetRows[row] := target.Id
        if target.Id = preferredId
            selectRow := row
    }
    c.RecentTargetCount.Text := "最近目标："
        . c.Draft.RecentDestinations.Length " 个"
    if selectRow
        c.TargetList.Modify(selectRow, "Select Focus Vis")
}

DestinationSelected(c, list, row, selected) {
    if selected && c.TargetRows.Has(row)
        c.SelectedTargetId := c.TargetRows[row]
}

FindDraftDestination(c, id := "") {
    if id = ""
        id := c.SelectedTargetId
    for index, target in c.Draft.CommonDestinations {
        if target.Id = id
            return {Index: index, Value: target}
    }
    return 0
}

EditSelectedDestination(c, *) {
    found := FindDraftDestination(c)
    if IsObject(found)
        OpenDestinationEditor(c, found.Value)
}

OpenDestinationEditor(c, existing, *) {
    if IsObject(c.Child) {
        try WinActivate("ahk_id " c.Child.Hwnd)
        return
    }
    isEdit := IsObject(existing)
    target := isEdit
        ? {Id: existing.Id, Name: existing.Name, Path: existing.Path,
            OriginalPath: existing.Path}
        : {Id: "", Name: "", Path: "", OriginalPath: ""}
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox",
        isEdit ? "编辑常用位置" : "添加常用位置")
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 14
    child.MarginY := 12
    child.AddText("xm ym+4 w70", "名称：")
    name := AddUiEdit(child, "x90 yp-4 w390", target.Name)
    child.AddText("xm y+18 w70", "文件夹：")
    path := AddUiEdit(child, "x90 yp-4 w310", target.Path)
    browse := AddUiButton(child, "x+8 yp w72", "浏览…")
    browse.OnEvent("Click", BrowseFolderForEditor.Bind(path, name))
    ok := AddUiButton(child, "x320 y+24 w72 Default", "确定")
    cancel := AddUiButton(child, "x+8 yp w72", "取消")
    ok.OnEvent("Click", AcceptDestinationEditor.Bind(
        c, target, isEdit, name, path, child))
    cancel.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    c.Gui.Opt("+Disabled")
    child.Show("w508 h188")
}

BrowseFolderForEditor(pathControl, nameControl, *) {
    selected := SelectPanelFile("D3", pathControl.Value, "选择文件夹")
    if selected = ""
        return
    pathControl.Value := NormalizePath(selected)
    if Trim(nameControl.Value) = ""
        nameControl.Value := GetFileName(selected)
}

AcceptDestinationEditor(c, target, isEdit, nameCtrl, pathCtrl, child, *) {
    name := Trim(nameCtrl.Value)
    path := NormalizePath(pathCtrl.Value)
    if name = ""
        return SettingsMessage(c, "位置名称不能为空。", "输入有误", "Icon!")
    if (!isEdit || !PathsEqual(path, target.OriginalPath))
        && !DirExist(path)
        return SettingsMessage(c, "新增常用位置必须是存在的文件夹。",
            "输入有误", "Icon!")
    for other in c.Draft.CommonDestinations {
        if other.Id != target.Id && PathsEqual(other.Path, path)
            return SettingsMessage(c, "该文件夹已经在常用位置中。",
                "重复路径", "Icon!")
    }
    target.Name := name
    target.Path := path
    if !isEdit {
        target.Id := "destination-" HashString(PathKey(path))
        c.Draft.CommonDestinations.Push(target)
    } else {
        found := FindDraftDestination(c, target.Id)
        if IsObject(found)
            c.Draft.CommonDestinations[found.Index] := target
    }
    c.SelectedTargetId := target.Id
    CloseSettingsChild(c, child)
    RefreshDestinationList(c, target.Id)
}

RemoveSelectedDestination(c, *) {
    found := FindDraftDestination(c)
    if !IsObject(found)
        return
    c.Draft.CommonDestinations.RemoveAt(found.Index)
    c.SelectedTargetId := ""
    RefreshDestinationList(c)
}

MoveSelectedDestination(c, delta, *) {
    found := FindDraftDestination(c)
    if !IsObject(found)
        return
    targetIndex := found.Index + delta
    if targetIndex < 1 || targetIndex > c.Draft.CommonDestinations.Length
        return
    c.Draft.CommonDestinations.RemoveAt(found.Index)
    c.Draft.CommonDestinations.InsertAt(targetIndex, found.Value)
    RefreshDestinationList(c, found.Value.Id)
}

ClearRecentTargetsDraft(c, *) {
    if !c.Draft.RecentDestinations.Length
        return
    if SettingsMessage(c, "要清空复制和移动菜单中的最近目标记录吗？",
        "清空记录", "YesNo Icon!") != "Yes"
        return
    c.Draft.RecentDestinations := []
    RefreshDestinationList(c)
}

RefreshExcludedNameList(c) {
    c.ExcludedNameList.Delete()
    for name in c.Draft.GlobalExcludedNames
        c.ExcludedNameList.Add("", name)
}

AddExcludedName(c, *) {
    if IsObject(c.Child) {
        try WinActivate("ahk_id " c.Child.Hwnd)
        return
    }
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox",
        "添加排除名称")
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 16
    child.MarginY := 14
    child.AddText("xm ym w390", "请输入要共享排除的文件夹名称：")
    nameEdit := AddUiEdit(child, "xm y+10 w390")
    ok := AddUiButton(child, "x238 y+16 w74 Default", "确定")
    cancel := AddUiButton(child, "x+8 yp w74", "取消")
    ok.OnEvent("Click",
        AcceptExcludedName.Bind(c, nameEdit, child))
    cancel.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    c.Gui.Opt("+Disabled")
    child.Show("w422 h142")
    try WinActivate("ahk_id " child.Hwnd)
    nameEdit.Focus()
}

AcceptExcludedName(c, nameEdit, child, *) {
    name := Trim(nameEdit.Value)
    if name = "" || InStr(name, "\") || InStr(name, "/")
        return MsgBox("请输入单个文件夹名称，不能包含路径分隔符。",
            "名称无效", "Icon! Owner" child.Hwnd)
    for existing in c.Draft.GlobalExcludedNames {
        if StrLower(existing) = StrLower(name) {
            CloseSettingsChild(c, child)
            return
        }
    }
    c.Draft.GlobalExcludedNames.Push(name)
    CloseSettingsChild(c, child)
    RefreshExcludedNameList(c)
}

RemoveExcludedName(c, *) {
    row := c.ExcludedNameList.GetNext(0, "F")
    if !row
        row := c.ExcludedNameList.GetNext()
    if !row
        return
    c.Draft.GlobalExcludedNames.RemoveAt(row)
    RefreshExcludedNameList(c)
}

RestoreExcludedNames(c, *) {
    if SettingsMessage(c,
        "要把共享排除名称恢复为推荐值吗？此操作只修改草稿。",
        "恢复推荐值", "YesNo Icon!") != "Yes"
        return
    c.Draft.GlobalExcludedNames := [
        ".git", ".svn", ".hg", "node_modules", "__pycache__"]
    RefreshExcludedNameList(c)
}

SettingsTabChanged(c, *) {
    CommitCurrentSourceControlsToDraft(c)
    try {
        if c.NavItems.Has(c.Tab.Value)
            c.Navigation.Modify(c.NavItems[c.Tab.Value], "Select Vis")
    }
}

SettingsDraftSignature(draft) {
    parts := []
    g := draft.General
    parts.Push(g.OpenFileMode, g.DefaultContextMenu, g.Hotkey,
        g.DoubleHotkeyWorkspaceId, g.WindowMode,
        g.EscapeHidesPanel ? "1" : "0",
        g.UiScaleMode,
        g.WindowWidth "", g.WindowHeight "",
        g.ThumbnailPolicy,
        g.ThumbnailSize "", g.ThumbnailHorizontalGap "",
        g.ThumbnailVerticalGap "", g.FileViewGroupTopSpacing "",
        g.FileViewGroupBottomSpacing "", g.ThumbnailTextLines "",
        g.TextBlockCardWidth "", g.TextBlockCardHeight "",
        g.ContentUpdateMode,
        g.ShowRecentSidebar ? "1" : "0",
        g.RecentFileCount "", g.MaxFilesPerFolder "", g.SortMode,
        ParseFileManagerProvider(g.FileManagerProvider),
        PathKey(g.FileManagerExecutable),
        g.EnablePublicUrlFallback ? "1" : "0",
        g.AllowHttp ? "1" : "0", g.TransferMaxConcurrent "",
        g.ShowCompletionNotifications ? "1" : "0",
        g.PreviewEnabled ? "1" : "0", g.PreviewSide,
        g.PreviewCacheEnabled ? "1" : "0",
        g.PreviewDocumentEnabled ? "1" : "0",
        g.PreviewPdfEnabled ? "1" : "0",
        g.QuickPreviewProvider,
        g.SeerIntegrationEnabled ? "1" : "0",
        PathKey(g.QuickLookPath))
    n := g.NoiseFilter
    parts.Push("N", n.Enabled ? "1" : "0", n.HideHidden ? "1" : "0",
        n.HideSystem ? "1" : "0", n.HideTemporary ? "1" : "0",
        n.HideIncompleteDownloads ? "1" : "0",
        JoinArray(n.CustomPatternTexts, Chr(30)))
    parts.Push("CW", draft.CurrentWorkspaceId)
    for workspace in draft.Workspaces {
        parts.Push("W", workspace.Id, workspace.Name,
            workspace.Type, workspace.Hotkey)
        parts.Push("P", workspace.Id,
            JoinNormalizedPaths(workspace.PinnedPaths))
        for s in workspace.Sources {
            parts.Push("S", workspace.Id, s.SourceId, s.Name,
                PathKey(s.Path), s.Mode, s.DisplayScope,
                s.FolderTimeMode, s.MaxFilesPerFolder "",
                HasProp(s, "MaxFilesPerFolderInherited")
                    && s.MaxFilesPerFolderInherited ? "1" : "0",
                s.SortMode, s.Filter.Mode,
                JoinArray(s.Filter.Extensions, ","),
                s.StripOrderPrefix "", s.HideExtensions "",
                s.OpenFileMode, s.NoiseFilterMode,
                JoinArray(s.SourceCustomPatternTexts, Chr(30)),
                JoinNormalizedPaths(s.ExcludedPaths),
                JoinNormalizedPaths(s.AllowedExcludedPaths))
        }
    }
    for app in draft.Applications {
        parts.Push("A", app.Id, app.Name, PathKey(app.Path),
            JoinArray(app.Extensions, ","), app.Enabled ? "1" : "0",
            app.ShowInOpenMenu ? "1" : "0")
        for action in app.Actions {
            parts.Push("AA", app.Id, action.Id, action.Name,
                PathKey(action.Executable), action.TargetTypes,
                action.ExecutionMode, JoinArray(action.Extensions, ","),
                action.RequireCommonFolder ? "1" : "0",
                action.WorkingDirectoryMode, action.WorkingDirectory,
                action.Confirm ? "1" : "0",
                action.Enabled ? "1" : "0",
                JoinArray(action.Args, Chr(29)))
        }
    }
    for target in draft.CommonDestinations
        parts.Push("T", target.Id, target.Name, PathKey(target.Path))
    parts.Push("R", JoinNormalizedPaths(draft.RecentDestinations))
    names := []
    for name in draft.GlobalExcludedNames
        names.Push(StrLower(name))
    parts.Push("E", JoinArray(names, ","))
    return HashString(JoinArray(parts, Chr(30)))
}

JoinNormalizedPaths(paths) {
    result := []
    for path in paths
        result.Push(PathKey(path))
    return JoinArray(result, "|")
}

SettingsDraftHasChanges(c) {
    global CONTENT_UPDATE_ACCURACY
    if !SettingsControllerIsReady(c)
        return false
    CommitCurrentSourceControlsToDraft(c)
    GeneralControlChanged(c)
    DisplayControlChanged(c)
    InterfaceControlChanged(c)
    ContentUpdateControlChanged(c,
        c.Draft.General.ContentUpdateMode = CONTENT_UPDATE_ACCURACY
            ? "Accuracy" : "Fast")
    FileManagerControlChanged(c)
    return SettingsDraftSignature(c.Draft) != c.OriginalSignature
}

RequestCloseSettings(c, *) {
    if IsObject(c.Child)
        return
    if !c.ClosingAfterSave && SettingsDraftHasChanges(c) {
        answer := SettingsMessage(c,
            "设置尚未保存。要放弃这些更改吗？",
            "放弃更改", "YesNo Icon!")
        if answer != "Yes"
            return
    }
    DestroySettingsGui(c)
}

DestroySettingsGui(c) {
    global SettingsDialog, SettingsController
    CancelFilePointerGesture()
    if IsObject(c) && HasProp(c, "Ready")
        c.Ready := false
    SettingsDialog := 0
    SettingsController := 0
    if IsObject(c) && HasProp(c, "PdfiumInstallPoll")
        try SetTimer(c.PdfiumInstallPoll, 0)
    try c.Gui.Destroy()
    try EndAutoHidePause()
    try PreviewRecoverAfterInteraction()
}

ValidateSettingsDraft(c) {
    global MODE_FILES, MODE_LAUNCHER
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, SOURCE_OPEN_MODE_INHERIT
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    global SORT_MODIFIED_DESC, SORT_NAME_ASC, SORT_SMART
    global WORKSPACE_TYPE_FILES, WORKSPACE_TYPE_TEXT
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    global CONTEXT_MENU_POPDROP, CONTEXT_MENU_SYSTEM
    global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_DIRECTORY_OPUS
    global FILE_MANAGER_TOTAL_COMMANDER, FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    errors := []
    warnings := []
    d := c.Draft
    if d.General.OpenFileMode != OPEN_MODE_DOUBLE
        && d.General.OpenFileMode != OPEN_MODE_SINGLE
        errors.Push("共享默认打开文件方式无效。")
    if d.General.DefaultContextMenu != CONTEXT_MENU_POPDROP
        && d.General.DefaultContextMenu != CONTEXT_MENU_SYSTEM
        errors.Push("默认右键菜单设置无效。")
    provider := d.General.FileManagerProvider
    if !IsRecognizedFileManagerProvider(provider)
        errors.Push("默认文件管理器设置无效。")
    else if provider != FILE_MANAGER_WINDOWS_SHELL {
        executable := NormalizeFileManagerExecutableForSave(
            provider, d.General.FileManagerExecutable)
        if executable = "" {
            errors.Push(FileManagerProviderDisplayName(provider)
                . " 的程序路径不能为空。")
        } else {
            SplitPath(executable, &fileName)
            fileName := StrLower(fileName)
            if provider = FILE_MANAGER_DIRECTORY_OPUS
                && fileName != "dopusrt.exe"
                errors.Push("Directory Opus 的程序路径必须指向 dopusrt.exe；"
                    . "也可以选择同目录中的 dopus.exe 自动转换。")
            else if provider = FILE_MANAGER_TOTAL_COMMANDER
                && fileName != "totalcmd64.exe"
                && fileName != "totalcmd.exe"
                errors.Push("Total Commander 的程序路径必须指向 "
                    . "TOTALCMD64.EXE 或 TOTALCMD.EXE。")
            else if provider = FILE_MANAGER_XYPLORER
                && fileName != "xyplorer.exe"
                errors.Push("XYplorer 的程序路径必须指向 XYplorer.exe。")
            else if provider = FILE_MANAGER_DOUBLE_COMMANDER
                && fileName != "doublecmd.exe"
                errors.Push("Double Commander 的程序路径必须指向 "
                    . "doublecmd.exe。")
            else if provider = FILE_MANAGER_FILES
                && !IsFilesExecutableName(fileName)
                errors.Push("Files 的程序路径必须指向 Files.exe，或 "
                    . "files-stable.exe、files-preview.exe、"
                    . "files-dev.exe 官方启动别名。")
            else if provider = FILE_MANAGER_FREE_COMMANDER
                && fileName != "freecommander.exe"
                errors.Push("FreeCommander XE 的程序路径必须指向 "
                    . "FreeCommander.exe。")
            else if !IsExistingExecutable(executable)
                warnings.Push(FileManagerProviderDisplayName(provider)
                    . " 的程序当前不存在：" executable)
        }
    }
    if Trim(d.General.Hotkey) = ""
        errors.Push("呼出/隐藏快捷键不能为空。")
    if !IsIntegerText(d.General.MaxFilesPerFolder, 1, 100)
        errors.Push("每个来源最多显示数量必须是 1–100 的整数。")
    if !IsIntegerText(d.General.RecentFileCount, 1, 100)
        errors.Push("最近文件显示数量必须是 1–100 的整数。")
    if !IsIntegerText(d.General.TransferMaxConcurrent, 1, 6)
        errors.Push("外部传输最大并发数必须是 1–6 的整数。")
    if !ValueInArray(d.General.UiScaleMode,
        ["100", "125", "150", "175", "200"])
        errors.Push("界面缩放设置无效。")
    if !IsIntegerText(d.General.WindowWidth, 660, 980)
        errors.Push("窗口宽度必须是 660–980 的整数。")
    if !IsIntegerText(d.General.WindowHeight, 380, 2000)
        errors.Push("窗口高度必须是 380–2000 的整数。")
    if !ValueInArray(d.General.ThumbnailPolicy, ["Fast", "Full"])
        errors.Push("图标质量设置无效。")
    if !IsIntegerText(d.General.ThumbnailSize, 48, 256)
        errors.Push("图标大小必须是 48–256 的整数。")
    if !IsIntegerText(d.General.ThumbnailHorizontalGap, 0, 128)
        errors.Push("图标横向间距必须是 0–128 的整数。")
    if !IsIntegerText(d.General.ThumbnailVerticalGap, 0, 128)
        errors.Push("图标纵向间距必须是 0–128 的整数。")
    if !IsIntegerText(d.General.FileViewGroupTopSpacing, 0, 32)
        errors.Push("分栏上间距必须是 0–32 的整数。")
    if !IsIntegerText(d.General.FileViewGroupBottomSpacing, 0, 32)
        errors.Push("分栏下间距必须是 0–32 的整数。")
    if !IsIntegerText(d.General.ThumbnailTextLines, 1, 2)
        errors.Push("文件名行数必须是 1 或 2。")
    if !IsIntegerText(d.General.TextBlockCardWidth, 140, 640)
        errors.Push("文本块宽度必须是 140–640 的整数。")
    if !IsIntegerText(d.General.TextBlockCardHeight, 48, 320)
        errors.Push("文本块高度必须是 48–320 的整数。")
    if !ValueInArray(d.General.QuickPreviewProvider,
        ["Off", "Seer", "QuickLook"])
        errors.Push("空格键快速预览提供程序无效。")
    else if d.General.QuickPreviewProvider = "QuickLook"
        && !QuickPreviewValidateQuickLookPath(d.General.QuickLookPath)
        warnings.Push("QuickLook 路径未通过桌面版命令行能力校验；"
            . "保存后不会拦截空格键。")

    if !d.Workspaces.Length
        errors.Push("至少需要保留一个工作区。")
    workspaceNames := Map()
    workspaceIds := Map()
    configuredHotkeys := Map(StrLower(Trim(d.General.Hotkey)), "主快捷键")
    allSourceIds := Map()
    activeFound := false
    for workspace in d.Workspaces {
        if !IsSafeStableId(workspace.Id)
            errors.Push("工作区 ID 无效：" workspace.Id)
        if workspaceIds.Has(StrLower(workspace.Id))
            errors.Push("工作区 ID 重复：" workspace.Id)
        else
            workspaceIds[StrLower(workspace.Id)] := true
        if !IsSafeWorkspaceName(workspace.Name)
            errors.Push("工作区名称无效：“" workspace.Name "”。")
        if workspaceNames.Has(StrLower(workspace.Name))
            errors.Push("工作区名称重复：“" workspace.Name "”。")
        else
            workspaceNames[StrLower(workspace.Name)] := true
        if !ValueInArray(Trim(workspace.Type),
            [WORKSPACE_TYPE_FILES, WORKSPACE_TYPE_TEXT])
            errors.Push("工作区类型无效：“" workspace.Name "”。")
        workspaceHotkey := StrLower(Trim(workspace.Hotkey))
        if workspaceHotkey != "" {
            if configuredHotkeys.Has(workspaceHotkey)
                errors.Push("快捷键重复：“" workspace.Hotkey "”（"
                    configuredHotkeys[workspaceHotkey] "与工作区“"
                    workspace.Name "”）。")
            else
                configuredHotkeys[workspaceHotkey] := "工作区“" workspace.Name "”"
        }
        if StrLower(workspace.Id) = StrLower(d.CurrentWorkspaceId)
            activeFound := true
        names := Map()
        paths := Map()
        sourceIds := Map()
        for s in workspace.Sources {
        if !IsSafeSourceId(s.SourceId)
            errors.Push("工作区“" workspace.Name "”包含无效来源 ID。")
        if sourceIds.Has(StrLower(s.SourceId))
            errors.Push("工作区“" workspace.Name "”来源 ID 重复：" s.SourceId)
        else
            sourceIds[StrLower(s.SourceId)] := true
        if allSourceIds.Has(StrLower(s.SourceId))
            errors.Push("不同工作区不能共用来源身份：" s.SourceId)
        else
            allSourceIds[StrLower(s.SourceId)] := true
        if Trim(s.Name) = ""
            errors.Push("存在名称为空的监控来源。")
        else if !IsSafeSourceName(s.Name)
            errors.Push("来源名称包含 INI 不支持的字符：“" s.Name "”。")
        nameKey := StrLower(Trim(s.Name))
        if names.Has(nameKey)
            errors.Push("监控来源名称重复：“" s.Name "”。")
        else
            names[nameKey] := true
        if s.Path = ""
            errors.Push("来源“" s.Name "”的路径为空。")
        normalizedPathKey := PathKey(s.Path)
        if paths.Has(normalizedPathKey)
            errors.Push("监控来源路径重复：“" s.Path "”。")
        else
            paths[normalizedPathKey] := s.Name
        if !DirExist(s.Path)
            warnings.Push("来源“" s.Name "”当前不可访问：" s.Path)
        if !ValueInArray(s.Mode, [MODE_FILES, MODE_LAUNCHER])
            errors.Push("来源“" s.Name "”的文件夹类型无效。")
        if !ValueInArray(s.DisplayScope,
            [SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES])
            errors.Push("来源“" s.Name "”的显示内容设置无效。")
        if !ValueInArray(s.OpenFileMode,
            [SOURCE_OPEN_MODE_INHERIT, OPEN_MODE_SINGLE, OPEN_MODE_DOUBLE])
            errors.Push("来源“" s.Name "”的打开文件设置无效。")
        if !ValueInArray(s.NoiseFilterMode,
            [NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED])
            errors.Push("来源“" s.Name "”的临时及系统文件过滤设置无效。")
        if !ValueInArray(s.FolderTimeMode,
            [FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT])
            errors.Push("来源“" s.Name "”的文件夹排序设置无效。")
        allowedSorts := ParseWorkspaceType(workspace.Type) = WORKSPACE_TYPE_TEXT
            ? [SORT_SMART, SORT_MODIFIED_DESC, SORT_NAME_ASC]
            : [SORT_MODIFIED_DESC, SORT_NAME_ASC]
        if !ValueInArray(s.SortMode, allowedSorts)
            errors.Push("来源“" s.Name "”的排序设置无效。")
        if !(HasProp(s, "MaxFilesPerFolderInherited")
            && s.MaxFilesPerFolderInherited)
            && !IsIntegerText(s.MaxFilesPerFolder, 0, 999999)
            errors.Push("来源“" s.Name "”的显示数量必须是非负整数。")
        for path in s.ExcludedPaths {
            if PathsEqual(path, s.Path)
                || !IsSameOrDescendantPath(path, s.Path)
                errors.Push("来源“" s.Name "”的排除路径不在来源内部：" path)
        }
        for path in s.AllowedExcludedPaths {
            if PathsEqual(path, s.Path)
                || !IsSameOrDescendantPath(path, s.Path)
                errors.Push("来源“" s.Name "”的允许路径不在来源内部：" path)
        }
        sourcePatterns := CompileIgnorePatterns(s.SourceCustomPatternTexts,
            "来源“" s.Name "”")
        for item in sourcePatterns.Errors
            errors.Push(item)
        }
        Loop workspace.Sources.Length {
        left := workspace.Sources[A_Index]
        index := A_Index + 1
        while index <= workspace.Sources.Length {
            right := workspace.Sources[index]
            if IsSameOrDescendantPath(left.Path, right.Path)
                || IsSameOrDescendantPath(right.Path, left.Path)
                warnings.Push("来源“" left.Name "”与“" right.Name
                    "”存在父子路径重叠。")
            index += 1
        }
    }
    }
    if !activeFound
        errors.Push("当前工作区不在工作区列表中。")
    if d.General.DoubleHotkeyWorkspaceId != "" {
        defaultTextFound := false
        for workspace in d.Workspaces {
            if StrLower(workspace.Id)
                = StrLower(d.General.DoubleHotkeyWorkspaceId) {
                defaultTextFound := ParseWorkspaceType(workspace.Type)
                    = WORKSPACE_TYPE_TEXT
                break
            }
        }
        if !defaultTextFound
            errors.Push("默认文本区不存在或不是文本块工作区。")
    }
    fileWorkspaceCount := 0
    for workspace in d.Workspaces {
        if ParseWorkspaceType(workspace.Type) = WORKSPACE_TYPE_FILES
            fileWorkspaceCount += 1
    }
    if !fileWorkspaceCount
        errors.Push("至少需要保留一个文件工作区，供主快捷键进入文件模式。")

    appPaths := Map()
    for app in d.Applications {
        if Trim(app.Name) = ""
            errors.Push("软件列表中存在空名称。")
        if !IsExecutablePath(app.Path)
            errors.Push("软件“" app.Name "”的路径不是 .exe：" app.Path)
        if appPaths.Has(PathKey(app.Path))
            errors.Push("软件路径重复：" app.Path)
        else
            appPaths[PathKey(app.Path)] := true
        if !IsExistingExecutable(app.Path)
            warnings.Push("软件“" app.Name "”当前不存在：" app.Path)
        actionIds := Map()
        for action in app.Actions {
            if !IsSafeOpenAppActionId(action.Id)
                errors.Push("应用“" app.Name "”包含无效动作 ID："
                    action.Id)
            if actionIds.Has(StrLower(action.Id))
                errors.Push("应用“" app.Name "”动作 ID 重复："
                    action.Id)
            else
                actionIds[StrLower(action.Id)] := true
            actionValidation := ValidateOpenAppAction(
                action, app, false)
            for item in actionValidation.Errors
                errors.Push("应用“" app.Name "”的动作“"
                    action.Name "”：" item)
            executable := action.Executable != ""
                ? action.Executable : app.Path
            if !IsExistingExecutable(executable)
                warnings.Push("应用“" app.Name "”的动作“"
                    action.Name "”执行程序不存在：" executable)
        }
    }
    targetPaths := Map()
    if d.CommonDestinations.Length > 5
        errors.Push("常用位置最多可配置 5 个。")
    for target in d.CommonDestinations {
        if Trim(target.Name) = ""
            errors.Push("常用位置中存在空名称。")
        if target.Path = ""
            errors.Push("常用位置“" target.Name "”的路径为空。")
        if targetPaths.Has(PathKey(target.Path))
            errors.Push("常用位置路径重复：" target.Path)
        else
            targetPaths[PathKey(target.Path)] := true
        if !DirExist(target.Path)
            warnings.Push("常用位置“" target.Name "”当前不可访问：" target.Path)
    }
    excluded := Map()
    for name in d.GlobalExcludedNames {
        if Trim(name) = "" || InStr(name, "\") || InStr(name, "/")
            errors.Push("共享排除项必须是单个文件夹名称：“" name "”。")
        key := StrLower(Trim(name))
        if excluded.Has(key)
            errors.Push("共享排除名称重复：“" name "”。")
        else
            excluded[key] := true
    }
    globalPatterns := CompileIgnorePatterns(d.General.NoiseFilter.CustomPatternTexts,
        "共享自定义忽略规则")
    for item in globalPatterns.Errors
        errors.Push(item)
    return {Errors: errors, Warnings: warnings}
}

IsIntegerText(value, minimum, maximum) {
    value := Trim(value "")
    if !RegExMatch(value, "^\d+$")
        return false
    try number := Integer(value)
    catch
        return false
    return number >= minimum && number <= maximum
}

ValueInArray(value, values) {
    for item in values {
        if value = item
            return true
    }
    return false
}

SaveSettingsDraft(c, *) {
    return SaveSettingsDraftCore(c, true)
}

SaveSettingsDraftCore(c, closeAfter) {
    global ConfigPath, ConfiguredHotkey, ActiveHotkey
    global SettingsDialog

    CommitCurrentSourceControlsToDraft(c)
    GeneralControlChanged(c)
    DisplayControlChanged(c)
    InterfaceControlChanged(c)
    FileManagerControlChanged(c)
    c.Draft.General.FileManagerExecutable :=
        NormalizeFileManagerExecutableForSave(
            c.Draft.General.FileManagerProvider,
            c.Draft.General.FileManagerExecutable)
    c.FileManagerPath.Value :=
        c.Draft.General.FileManagerExecutable
    UpdateFileManagerControlState(c)
    validation := ValidateSettingsDraft(c)
    if validation.Errors.Length {
        message := "请先修正以下问题：`n`n"
        for index, item in validation.Errors
            message .= index ". " item "`n"
        SettingsMessage(c, message, "无法保存设置", "Iconx")
        return false
    }
    if validation.Warnings.Length {
        message := "以下项目当前不可用或存在重叠：`n`n"
        for index, item in validation.Warnings
            message .= index ". " item "`n"
        message .= "`n仍要保存吗？"
        if SettingsMessage(c, message, "保存设置警告",
            "YesNo Icon!") != "Yes"
            return false
    }
    dangerous := HasDangerousIgnorePattern(c.Draft.General.NoiseFilter.CustomPatternTexts)
    if !dangerous {
        for workspace in c.Draft.Workspaces {
            for source in workspace.Sources {
                if HasDangerousIgnorePattern(source.SourceCustomPatternTexts) {
                    dangerous := true
                    break
                }
            }
            if dangerous
                break
        }
    }
    if dangerous && SettingsMessage(c,
        "规则 * 或 *.* 可能隐藏来源中的绝大多数文件。`n`n是否仍要保存？",
        "忽略规则范围过宽", "YesNo Icon!") != "Yes"
        return false
    newHotkey := Trim(c.Draft.General.Hotkey)
    if !CanRegisterSettingsHotkey(newHotkey, ConfiguredHotkey) {
        SettingsMessage(c, "快捷键“" newHotkey
            "”无法注册。原快捷键不会被覆盖。",
            "快捷键不可用", "Iconx")
        return false
    }
    for workspace in c.Draft.Workspaces {
        workspaceHotkey := Trim(workspace.Hotkey)
        if workspaceHotkey != ""
            && !CanRegisterWorkspaceHotkey(workspaceHotkey, workspace.Id) {
            SettingsMessage(c, "工作区“" workspace.Name "”的快捷键“"
                workspaceHotkey "”无法注册。原快捷键不会被覆盖。",
                "快捷键不可用", "Iconx")
            return false
        }
    }

    oldHotkey := ConfiguredHotkey
    wroteConfig := false
    try {
        CreateConfigBackup()
        AtomicConfigEdit(WriteSettingsDraft.Bind(c.Draft))
        ApplyStartupShortcut(c.Draft.General.StartupEnabled)
        wroteConfig := true
        LoadSettings()
        ApplyWindowMode()
        if ConfiguredHotkey != oldHotkey
            InstallHotkey(ConfiguredHotkey)
        InstallWorkspaceHotkeys()
        BuildTrayMenu()
        PopulatePanel()
        PopulateRecentSidebar()
        StartBackgroundScan()
        SetUserStatus("设置已保存")
        c.OriginalSignature := SettingsDraftSignature(c.Draft)
        if closeAfter {
            c.ClosingAfterSave := true
            DestroySettingsGui(c)
        }
        return true
    } catch as err {
        if wroteConfig {
            try {
                AtomicConfigEdit(RestoreConfigBackupToTemp)
                LoadSettings()
                ApplyWindowMode()
                InstallHotkey(ConfiguredHotkey)
                BuildTrayMenu()
            }
        }
        ; Applying settings repopulates the native view before all subsequent
        ; operations have completed. If a later operation fails, rebuild from
        ; the restored runtime state so the user is not left with an empty
        ; panel after the rollback.
        try SyncWorkspaceControls()
        try PopulatePanel()
        try PopulateRecentSidebar()
        try StartBackgroundScan(0, "settings-rollback", true)
        SettingsMessage(c, "无法保存设置：`n" err.Message,
            "保存设置失败", "Iconx")
        return false
    }
}

CanRegisterSettingsHotkey(candidate, current) {
    candidate := Trim(candidate)
    if candidate = ""
        return false
    if StrLower(candidate) = StrLower(current)
        return true
    try {
        Hotkey(candidate, SettingsHotkeyProbe, "On")
        Hotkey(candidate, "Off")
        return true
    } catch {
        try Hotkey(candidate, "Off")
        return false
    }
}

CanRegisterWorkspaceHotkey(candidate, workspaceId) {
    global ActiveWorkspaceHotkeys
    candidate := Trim(candidate)
    if candidate = ""
        return true
    for activeHotkey, activeWorkspaceId in ActiveWorkspaceHotkeys {
        if StrLower(activeHotkey) = StrLower(candidate)
            return StrLower(activeWorkspaceId) = StrLower(workspaceId)
    }
    try {
        Hotkey(candidate, SettingsHotkeyProbe, "On")
        Hotkey(candidate, "Off")
        return true
    } catch {
        try Hotkey(candidate, "Off")
        return false
    }
}

SettingsHotkeyProbe(*) {
}

CreateConfigBackup() {
    global ConfigPath
    if FileExist(ConfigPath)
        FileCopy(ConfigPath, ConfigPath ".bak", 1)
}

RestoreConfigBackupToTemp(tempPath) {
    global ConfigPath
    backupPath := ConfigPath ".bak"
    if !FileExist(backupPath)
        throw Error("配置备份不存在，无法回滚。")
    FileDelete(tempPath)
    FileCopy(backupPath, tempPath, 1)
}

WriteSettingsDraft(draft, tempPath) {
    global OPEN_MODE_DOUBLE, CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    g := draft.General
    doc.SetValue("General", "OpenFileMode",
        ParseGlobalOpenFileMode(g.OpenFileMode), 1)
    doc.SetValue("General", "DefaultContextMenu",
        ParseDefaultContextMenu(g.DefaultContextMenu), 1)
    doc.SetValue("General", "Hotkey", g.Hotkey, 1)
    doc.SetValue("General", "StartupEnabled", g.StartupEnabled ? "1" : "0", 1)
    doc.SetValue("General", "DoubleHotkeyWorkspaceId",
        g.DoubleHotkeyWorkspaceId, 1)
    doc.SetValue("General", "LastFileWorkspaceId",
        ResolveFileWorkspaceId(
            g.LastFileWorkspaceId, draft.Workspaces,
            draft.CurrentWorkspaceId), 1)
    doc.SetValue("General", "WindowMode", g.WindowMode, 1)
    doc.SetValue("General", "EscapeHidesPanel",
        g.EscapeHidesPanel ? "1" : "0", 1)
    doc.SetValue("General", "MaxFilesPerFolder", g.MaxFilesPerFolder, 1)
    doc.SetValue("General", "SortMode", g.SortMode, 1)
    doc.SetValue("General", "ShowRecentSidebar",
        g.ShowRecentSidebar ? "1" : "0", 1)
    doc.SetValue("General", "ContentUpdateMode",
        g.ContentUpdateMode, 1)
    doc.SetValue("General", "UiScale", g.UiScaleMode, 1)
    doc.SetValue("General", "WindowWidth", g.WindowWidth, 1)
    doc.SetValue("General", "WindowHeight", g.WindowHeight, 1)
    doc.SetValue("General", "ThumbnailPolicy", g.ThumbnailPolicy, 1)
    doc.SetValue("General", "ThumbnailSize", g.ThumbnailSize, 1)
    doc.SetValue("General", "ThumbnailHorizontalGap",
        g.ThumbnailHorizontalGap, 1)
    doc.SetValue("General", "ThumbnailVerticalGap",
        g.ThumbnailVerticalGap, 1)
    doc.SetValue("General", "FileViewGroupTopSpacing",
        g.FileViewGroupTopSpacing, 1)
    doc.SetValue("General", "FileViewGroupBottomSpacing",
        g.FileViewGroupBottomSpacing, 1)
    doc.SetValue("General", "ThumbnailTextLines",
        g.ThumbnailTextLines, 1)
    doc.SetValue("General", "TextBlockCardWidth",
        g.TextBlockCardWidth, 1)
    doc.SetValue("General", "TextBlockCardHeight",
        g.TextBlockCardHeight, 1)
    doc.SetValue("General", "RecentFileCount", g.RecentFileCount, 1)
    doc.SetValue("ExternalTransfer", "EnablePublicUrlFallback",
        g.EnablePublicUrlFallback ? "1" : "0", 1)
    doc.SetValue("ExternalTransfer", "AllowHttp",
        g.AllowHttp ? "1" : "0", 1)
    doc.SetValue("ExternalTransfer", "MaxConcurrent",
        g.TransferMaxConcurrent, 1)
    doc.SetValue("ExternalTransfer", "ShowCompletionNotifications",
        g.ShowCompletionNotifications ? "1" : "0", 1)
    doc.SetValue("FileManager", "Provider",
        ParseFileManagerProvider(g.FileManagerProvider), 1)
    doc.SetValue("FileManager", "Executable",
        NormalizeFileManagerExecutableForSave(
            g.FileManagerProvider, g.FileManagerExecutable), 1)
    doc.SetValue("Preview", "Enabled",
        g.PreviewEnabled ? "1" : "0", 1)
    doc.SetValue("Preview", "Side", g.PreviewSide, 1)
    doc.SetValue("Preview", "CacheEnabled",
        g.PreviewCacheEnabled ? "1" : "0", 1)
    doc.SetValue("Preview", "DocumentEnabled",
        g.PreviewDocumentEnabled ? "1" : "0", 1)
    doc.SetValue("Preview", "PdfEnabled",
        g.PreviewPdfEnabled ? "1" : "0", 1)
    doc.SetValue("Preview", "ShowFileInfo",
        g.PreviewShowFileInfo ? "1" : "0", 1)
    doc.SetValue("QuickPreview", "ExternalQuickPreviewProvider",
        g.QuickPreviewProvider, 1)
    doc.SetValue("QuickPreview", "SeerIntegrationEnabled",
        g.SeerIntegrationEnabled ? "1" : "0", 1)
    doc.SetValue("QuickPreview", "QuickLookPath",
        g.QuickLookPath, 1)
    noise := g.NoiseFilter
    EnsureNoiseFilterConfigComments(doc)
    noiseEntries := [{Key: "Enabled", Value: noise.Enabled ? "1" : "0"},
        {Key: "HideHidden", Value: noise.HideHidden ? "1" : "0"},
        {Key: "HideSystem", Value: noise.HideSystem ? "1" : "0"},
        {Key: "HideTemporaryAttribute", Value: noise.HideTemporary ? "1" : "0"},
        {Key: "HideIncompleteDownloads", Value: noise.HideIncompleteDownloads ? "1" : "0"},
        {Key: "CustomPatternCount", Value: noise.CustomPatternTexts.Length}]
    noiseKnownKeys := ["Enabled", "HideHidden", "HideSystem",
        "HideTemporaryAttribute", "HideIncompleteDownloads", "CustomPatternCount"]
    for entry in doc.GetEntries("NoiseFilter") {
        if RegExMatch(entry.Key, "i)^CustomPattern\d+$")
            noiseKnownKeys.Push(entry.Key)
    }
    for index, pattern in noise.CustomPatternTexts {
        key := "CustomPattern" Format("{:03}", index)
        noiseEntries.Push({Key: key, Value: pattern})
        if !ValueInArray(key, noiseKnownKeys)
            noiseKnownKeys.Push(key)
    }
    doc.ReplaceKnownKeys("NoiseFilter", noiseEntries, noiseKnownKeys, 1)

    oldWorkspaceIds := ParseStableIdOrder(
        doc.GetValue("Workspaces", "Order", ""))
    oldSourceIds := []
    for workspaceId in oldWorkspaceIds {
        for sourceId in ParseStableIdOrder(doc.GetValue(
            "Workspace:" workspaceId, "SourceOrder", "")) {
            if !ArrayContainsTextInsensitive(oldSourceIds, sourceId)
                oldSourceIds.Push(sourceId)
        }
    }
    workspaceIds := []
    activeSourceIds := Map()
    for workspace in draft.Workspaces {
        workspaceIds.Push(workspace.Id)
        sourceIds := []
        for source in workspace.Sources {
            sourceIds.Push(source.SourceId)
            activeSourceIds[StrLower(source.SourceId)] := true
            sourceSection := "Source:" source.SourceId
            doc.ReplaceKnownKeys(sourceSection,
                SourceConfigEntries(source, workspace.Id),
                SourceConfigKnownKeys(), 3)
            WriteIgnorePatternSection(doc,
                "SourceIgnore:" source.SourceId,
                source.SourceCustomPatternTexts)
            WriteSourcePathSection(doc,
                "SourceExclude:" source.SourceId,
                source.Path, source.ExcludedPaths)
            WriteSourcePathSection(doc,
                "SourceAllow:" source.SourceId,
                source.Path, source.AllowedExcludedPaths)
        }
        doc.ReplaceKnownKeys("Workspace:" workspace.Id, [
            {Key: "Name", Value: workspace.Name},
            {Key: "Type", Value: ParseWorkspaceType(workspace.Type)},
            {Key: "Hotkey", Value: Trim(workspace.Hotkey)},
            {Key: "SourceOrder", Value: JoinArray(sourceIds, ",")}
        ], ["Name", "Type", "Hotkey", "SourceOrder"], 3)
        WritePinnedPathsToDocument(doc,
            "WorkspacePinned:" workspace.Id, workspace.PinnedPaths, 3)
    }
    doc.ReplaceKnownKeys("Workspaces", [
        {Key: "Order", Value: JoinArray(workspaceIds, ",")},
        {Key: "Active", Value: draft.CurrentWorkspaceId},
        {Key: "PinnedScopeVersion", Value: "1"}
    ], ["Order", "Active", "PinnedScopeVersion"], 3)
    for workspaceId in oldWorkspaceIds {
        if !ArrayContainsTextInsensitive(workspaceIds, workspaceId) {
            doc.DeleteSection("Workspace:" workspaceId)
            doc.DeleteSection("WorkspacePinned:" workspaceId)
        }
    }
    for sourceId in oldSourceIds {
        if !activeSourceIds.Has(StrLower(sourceId)) {
            doc.DeleteSection("Source:" sourceId)
            doc.DeleteSection("SourceExclude:" sourceId)
            doc.DeleteSection("SourceAllow:" sourceId)
            doc.DeleteSection("SourceIgnore:" sourceId)
        }
    }

    WriteOpenAppsToDocument(doc, draft.Applications)

    favoriteEntries := []
    labelEntries := []
    for index, target in draft.CommonDestinations {
        key := "Path" Format("{:03}", index)
        favoriteEntries.Push({Key: key, Value: target.Path})
        labelEntries.Push({Key: key, Value: target.Name})
    }
    doc.ReplaceSection("TransferFavorites", favoriteEntries, 5)
    doc.ReplaceSection("TransferFavoriteLabels", labelEntries, 5)
    doc.SetValue("General", "TransferFavoritesInitialized", "1", 1)
    doc.ReplaceSection("RecentTargets",
        ConfigEntriesFromValues(draft.RecentDestinations, "Path"), 5)
    doc.ReplaceSection("ExcludedFolderNames",
        ConfigEntriesFromValues(draft.GlobalExcludedNames, "Name"), 6)
    doc.SetValue("General", "GlobalExcludedNamesInitialized", "1", 1)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

WriteIgnorePatternSection(doc, section, patternTexts) {
    if !patternTexts.Length {
        doc.DeleteSection(section)
        return
    }
    entries := [{Key: "PatternCount", Value: patternTexts.Length}]
    for index, pattern in patternTexts
        entries.Push({Key: "Pattern" Format("{:03}", index), Value: pattern})
    doc.ReplaceSection(section, entries, 6)
}

WriteSourcePathSection(doc, section, sourceRoot, paths) {
    if !paths.Length {
        doc.DeleteSection(section)
        return
    }
    entries := []
    for index, path in paths
        entries.Push({
            Key: "Path" Format("{:03}", index),
            Value: GetRelativeSourcePath(path, sourceRoot)
        })
    doc.ReplaceSection(section, entries, 6)
}

GetRelativeSourcePath(path, root) {
    path := NormalizePath(path)
    root := RTrim(NormalizePath(root), "\")
    if !IsSameOrDescendantPath(path, root) || PathsEqual(path, root)
        return path
    return SubStr(path, StrLen(root) + 2)
}

AdvancedSettingsClicked(c, *) {
    if SettingsDraftHasChanges(c) {
        answer := SettingsMessage(c,
            "设置中有未保存修改。`n`n"
            . "“是”：保存后打开；“否”：放弃修改后打开；“取消”：返回设置。",
            "高级设置", "YesNoCancel Icon!")
        if answer = "Cancel"
            return
        if answer = "Yes" {
            if !SaveSettingsDraft(c)
                return
        } else {
            c.ClosingAfterSave := true
            DestroySettingsGui(c)
        }
    } else {
        c.ClosingAfterSave := true
        DestroySettingsGui(c)
    }
    try CreateConfigBackup()
    OpenConfigFile()
}

SettingsMessage(c, text, title := "PopDrop 设置", options := "") {
    ownerHwnd := 0
    try {
        if IsObject(c) && HasProp(c, "Child") && IsObject(c.Child)
            ownerHwnd := c.Child.Hwnd
    }
    if !ownerHwnd {
        try {
            if IsObject(c) && HasProp(c, "Gui")
                ownerHwnd := c.Gui.Hwnd
        }
    }
    opts := Trim(options (ownerHwnd ? " Owner" ownerHwnd : ""))
    return MsgBox(text, title, opts)
}
