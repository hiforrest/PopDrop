; PopDrop native settings UI (AutoHotkey v2).
; All controls edit an isolated draft. Disk and runtime state are touched only
; by SaveSettingsDraft().

OpenConfig(*) {
    OpenSettingsGui()
}

OpenSettingsGui() {
    global Panel, SettingsDialog, SettingsController

    CancelFilePointerGesture()
    if IsObject(SettingsDialog) {
        try {
            SettingsDialog.Show()
            WinActivate("ahk_id " SettingsDialog.Hwnd)
            return
        }
    }

    BeginAutoHidePause()
    draft := LoadSettingsIntoDraft()
    guiObj := Gui("+Owner" Panel.Hwnd " -MaximizeBox -MinimizeBox",
        "PopDrop 设置")
    guiObj.MarginX := 14
    guiObj.MarginY := 12
    guiObj.SetFont("s9", "Microsoft YaHei UI")
    controller := {
        Gui: guiObj,
        Draft: draft,
        OriginalSignature: SettingsDraftSignature(draft),
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
    SettingsController := controller
    SettingsDialog := guiObj

    navigation := guiObj.AddTreeView("xm ym w156 h636 +0x20")
    sharedRoot := navigation.Add("共享设置", 0, "Expand")
    navGeneral := navigation.Add("通用", sharedRoot)
    navOperations := navigation.Add("打开与文件操作", sharedRoot)
    navDisplay := navigation.Add("显示与过滤", sharedRoot)
    workspaceRoot := navigation.Add("工作区设置", 0, "Expand")
    navWorkspace := navigation.Add("当前工作区", workspaceRoot)
    controller.Navigation := navigation
    controller.NavPages := Map(
        navGeneral, 1, navWorkspace, 2, navOperations, 3, navDisplay, 4)
    controller.NavItems := Map(
        1, navGeneral, 2, navWorkspace, 3, navOperations, 4, navDisplay)
    ; Tab3 remains the native page host, but its duplicate tab strip is placed
    ; above the client area. The TreeView is the only visible page navigation.
    tabs := guiObj.AddTab3("x184 y-26 w852 h674 -Tabstop",
        ["共享设置 · 通用", "当前工作区",
         "共享设置 · 打开与文件操作", "共享设置 · 显示与过滤"])
    controller.Tab := tabs
    BuildGeneralSettingsPage(controller, tabs)
    BuildSourcesSettingsPage(controller, tabs)
    BuildOperationsSettingsPage(controller, tabs)
    BuildDisplaySettingsPage(controller, tabs)
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
    advanced := AddUiButton(guiObj, "x184 y660 w112", "高级设置…")
    guiObj.AddText("x+8 yp+7 w400 c666666",
        "直接编辑 config.ini，适合高级用户。")
    cancel := AddUiButton(guiObj, "x860 yp-7 w78", "取消")
    save := AddUiButton(guiObj, "x+8 yp w78 Default", "保存")
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
    navigation.Modify(navGeneral, "Select Vis")
    guiObj.Show("w1050 h704")
}

SettingsNavigationSelected(c, tree, item) {
    if !c.NavPages.Has(item)
        return
    CommitCurrentSourceControlsToDraft(c)
    c.Tab.Choose(c.NavPages[item])
}

LoadSettingsIntoDraft() {
    global GlobalOpenFileMode, ConfiguredHotkey, WindowMode, EscapeHidesPanel
    global DefaultContextMenu
    global ShowRecentSidebar, RecentFileCount, MaxFilesPerFolder, SortMode
    global LastValidFolderSettings, OpenApps, TransferFavorites, RecentTargets
    global TransferFavoriteLabels, GlobalExcludedFolderNames
    global GlobalNoiseFilter, Workspaces, ActiveWorkspaceId
    global TransferUrlFallbackEnabled, TransferAllowHttp
    global TransferMaxConcurrent, TransferShowNotifications

    workspaceDrafts := []
    activeSources := []
    for workspace in Workspaces {
        sources := []
        for source in workspace.Sources
            sources.Push(CloneSettingsSource(source))
        workspaceDraft := {
            Id: workspace.Id,
            Name: workspace.Name,
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
    return {
        Id: app.Id,
        Path: NormalizePath(app.Path),
        Name: app.Name,
        Icon: app.Icon,
        Extensions: app.Extensions.Clone(),
        Enabled: app.Enabled
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
    g.AddText("x615 yp+4 w360 c666666",
        "保存时会先验证新快捷键是否可注册。")

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

    c.GlobalDouble.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.GlobalSingle.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.Hotkey.OnEvent("Change", GeneralControlChanged.Bind(c))
    c.WindowMode.OnEvent("Change", GeneralControlChanged.Bind(c))
    c.EscapeHide.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.ContextMenuPopDrop.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.ContextMenuSystem.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.EnableUrlFallback.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.AllowHttp.OnEvent("Click", GeneralControlChanged.Bind(c))
    c.TransferMax.OnEvent("Change", GeneralControlChanged.Bind(c))
    c.TransferNotify.OnEvent("Click", GeneralControlChanged.Bind(c))
}

BuildSourcesSettingsPage(c, tabs) {
    tabs.UseTab(2)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h66", "当前工作区")
    g.AddText("x220 y54 w86", "当前工作区：")
    c.WorkspaceDropDown := AddUiDropDownList(g, "x310 yp-4 w110", [])
    c.WorkspaceManage := AddUiButton(g, "x+10 yp w130", "管理工作区…")
    c.WorkspaceScopeHint := g.AddText("x580 yp+4 w405 c555555", "")
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
    c.SourceMax := AddUiEdit(g, "x324 yp-4 w90 Number")
    g.AddText("x420 yp+4 w190 c666666", "0 表示显示全部")
    g.AddText("x630 yp+4 w70", "排序：")
    c.SourceSort := AddUiDropDownList(g, "x700 yp-4 w220",
        ["修改时间（最新在前）", "名称（升序）"])
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
        c.SourceOpenMode, c.SourceFolderTime, c.SourceMax, c.SourceSort,
        c.SourceNoiseMode]
        ctrl.OnEvent("Change", SourceControlChanged.Bind(c))
    RefreshSettingsWorkspaceControls(c)
}

RefreshSettingsWorkspaceControls(c) {
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
            c.WorkspaceScopeHint.Text := "以下修改只影响“"
                . found.Value.Name "”。"
        }
    } finally c.Loading := false
    c.SelectedSourceId := ""
    RefreshSourceList(c)
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
        if answer = "Cancel"
            return false
        if answer = "Yes" {
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

ReloadSettingsDraft(c) {
    c.Draft := LoadSettingsIntoDraft()
    c.OriginalSignature := SettingsDraftSignature(c.Draft)
    c.SelectedSourceId := ""
    c.SelectedAppId := ""
    c.SelectedTargetId := ""
    LoadGeneralControls(c)
    LoadDisplayControls(c)
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
        ["工作区", "来源数量", "状态"])
    list.ModifyCol(1, 300)
    list.ModifyCol(2, 100)
    list.ModifyCol(3, 130)
    add := AddUiButton(child, "xm y+10 w92", "新建工作区")
    copy := AddUiButton(child, "x+7 yp w112", "复制当前工作区")
    rename := AddUiButton(child, "x+7 yp w72", "重命名")
    remove := AddUiButton(child, "x+7 yp w72", "删除")
    close := AddUiButton(child, "x500 yp w70 Default", "关闭")
    refresh := (*) => RefreshWorkspaceManagerList(c, list)
    add.OnEvent("Click", CreateWorkspaceFromManager.Bind(c, list))
    copy.OnEvent("Click", CopyWorkspaceFromManager.Bind(c, list))
    rename.OnEvent("Click", RenameWorkspaceFromManager.Bind(c, list))
    remove.OnEvent("Click", DeleteWorkspaceFromManager.Bind(c, list))
    close.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    refresh()
    c.Gui.Opt("+Disabled")
    child.Show("w598 h346")
}

RefreshWorkspaceManagerList(c, list) {
    list.Delete()
    selected := 0
    for index, workspace in c.Draft.Workspaces {
        current := StrLower(workspace.Id)
            = StrLower(c.Draft.CurrentWorkspaceId)
        row := list.Add("", workspace.Name, workspace.Sources.Length,
            current ? "当前工作区" : "")
        if current
            selected := row
    }
    if selected
        list.Modify(selected, "Select Focus Vis")
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

CreateWorkspaceFromManager(c, list, *) {
    name := PromptWorkspaceName(c, "新建工作区")
    if name = ""
        return
    answer := SettingsMessage(c,
        "如何创建“" name "”？`n`n"
        . "“是”：复制当前工作区（推荐）`n"
        . "“否”：创建空白工作区`n"
        . "“取消”：不创建",
        "新建工作区", "YesNoCancel Icon!")
    if answer = "Cancel"
        return
    current := FindDraftWorkspace(c)
    sources := []
    pinnedPaths := []
    if answer = "Yes" && IsObject(current) {
        for source in current.Value.Sources {
            clone := CloneSettingsSource(source)
            clone.SourceId := NewStableId("source")
            clone.OriginalName := clone.Name
            sources.Push(clone)
        }
        pinnedPaths := current.Value.PinnedPaths.Clone()
    }
    workspace := {Id: NewStableId("workspace"),
        Name: name, Sources: sources, PinnedPaths: pinnedPaths}
    c.Draft.Workspaces.Push(workspace)
    c.Draft.CurrentWorkspaceId := workspace.Id
    c.Draft.Sources := workspace.Sources
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, list)
    }
}

CopyWorkspaceFromManager(c, list, *) {
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
        Name: name, Sources: sources, PinnedPaths: pinnedPaths}
    c.Draft.Workspaces.Push(workspace)
    c.Draft.CurrentWorkspaceId := workspace.Id
    c.Draft.Sources := workspace.Sources
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, list)
    }
}

RenameWorkspaceFromManager(c, list, *) {
    row := list.GetNext(0, "F")
    if !row
        row := list.GetNext()
    if !row || row > c.Draft.Workspaces.Length
        return
    target := c.Draft.Workspaces[row]
    name := PromptWorkspaceName(c, "重命名工作区",
        target.Name, target.Id)
    if name = ""
        return
    target.Name := name
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, list)
    }
}

DeleteWorkspaceFromManager(c, list, *) {
    if c.Draft.Workspaces.Length <= 1 {
        SettingsMessage(c, "至少需要保留一个工作区，不能删除最后一个工作区。",
            "无法删除", "Icon!")
        return
    }
    row := list.GetNext(0, "F")
    if !row
        row := list.GetNext()
    if !row || row > c.Draft.Workspaces.Length
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
    if SaveSettingsDraftCore(c, false) {
        ReloadSettingsDraft(c)
        RefreshWorkspaceManagerList(c, list)
    }
}

BuildOperationsSettingsPage(c, tabs) {
    tabs.UseTab(3)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h270",
        "打开文件的软件 · 应用于所有工作区")
    c.AppList := g.AddListView("x220 y56 w778 h174 Report -Multi NoSortHdr",
        ["名称", "程序", "适用文件", "状态"])
    c.AppList.ModifyCol(1, 135)
    c.AppList.ModifyCol(2, 400)
    c.AppList.ModifyCol(3, 135)
    c.AppList.ModifyCol(4, 100)
    c.AppAdd := AddUiButton(g, "x220 y240 w88", "添加软件")
    c.AppEdit := AddUiButton(g, "x+7 yp w72", "编辑")
    c.AppRemove := AddUiButton(g, "x+7 yp w72", "移除")
    c.AppUp := AddUiButton(g, "x+7 yp w72", "上移")
    c.AppDown := AddUiButton(g, "x+7 yp w72", "下移")

    g.AddGroupBox("x200 y312 w818 h272",
        "复制和移动的常用位置 · 应用于所有工作区")
    c.TargetList := g.AddListView("x220 y339 w778 h153 Report -Multi NoSortHdr",
        ["名称", "路径", "状态"])
    c.TargetList.ModifyCol(1, 165)
    c.TargetList.ModifyCol(2, 505)
    c.TargetList.ModifyCol(3, 105)
    c.TargetAdd := AddUiButton(g, "x220 y502 w88", "添加位置")
    c.TargetEdit := AddUiButton(g, "x+7 yp w72", "编辑")
    c.TargetRemove := AddUiButton(g, "x+7 yp w72", "移除")
    c.TargetUp := AddUiButton(g, "x+7 yp w72", "上移")
    c.TargetDown := AddUiButton(g, "x+7 yp w72", "下移")
    c.RecentTargetCount := g.AddText("x725 yp+7 w145",
        "最近目标：0 个")
    c.ClearRecentTargets := AddUiButton(g, "x875 yp w98", "清空记录")

    c.AppList.OnEvent("ItemSelect", ApplicationSelected.Bind(c))
    c.AppAdd.OnEvent("Click", OpenApplicationEditor.Bind(c, 0))
    c.AppEdit.OnEvent("Click", EditSelectedApplication.Bind(c))
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

BuildDisplaySettingsPage(c, tabs) {
    tabs.UseTab(4)
    g := c.Gui
    g.AddGroupBox("x200 y29 w818 h330", "共享排除的文件夹名称")
    c.ExcludedNameList := g.AddListView(
        "x220 y56 w410 h238 Report -Multi NoSortHdr", ["文件夹名称"])
    c.ExcludedNameList.ModifyCol(1, 385)
    c.ExcludedNameAdd := AddUiButton(g, "x650 y56 w88", "添加")
    c.ExcludedNameRemove := AddUiButton(g, "xp y+8 w88", "移除")
    c.ExcludedNameRestore := AddUiButton(g, "xp y+8 w112", "恢复推荐值")
    g.AddText("x650 y188 w325 h88 c555555",
        "匹配的文件夹及其内容不会显示。明确添加为监控来源的文件夹"
        . "不受此规则影响。只支持精确文件夹名称，不使用通配符。")

    g.AddGroupBox("x200 y372 w818 h206",
        "显示 · 应用于所有工作区")
    g.AddText("x220 y407 w150", "每个来源最多显示：")
    c.GlobalMax := AddUiEdit(g, "x380 yp-4 w82 Number")
    g.AddText("x470 yp+4 w150 c666666", "个项目（1–100）")
    g.AddText("x220 y445 w150", "文件排序：")
    c.GlobalSort := AddUiDropDownList(g, "x380 yp-4 w245",
        ["修改时间（最新在前）", "名称（升序）"])
    c.ShowRecent := g.AddCheckBox("x220 y487", "显示最近文件区域")
    g.AddText("x420 yp+3 w86", "显示数量：")
    c.RecentCount := AddUiEdit(g, "x508 yp-4 w82 Number")
    g.AddText("x600 yp+4 w120 c666666", "（1–100）")
    c.NoiseFilterEnabled := g.AddCheckBox("x220 y526",
        "隐藏常见临时、锁定及系统文件（推荐）")
    c.ManageNoiseRules := AddUiButton(g, "x820 yp-5 w138", "管理忽略规则…")
    g.AddText("x240 y553 w555 c666666",
        "自动隐藏 Office 锁定文件、系统目录信息等通常不需要显示的文件。")
    c.HiddenNoiseCount := g.AddText("x800 y556 w130 c666666 Right", "本次共隐藏 0 个")
    c.ViewHiddenNoise := AddUiButton(g, "x940 y549 w55", "查看…")

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
    } finally c.Loading := false
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
    RefreshInheritedOpenModeLabels(c)
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
        hiddenCount := IsObject(CurrentScanResult) && HasProp(CurrentScanResult, "HiddenCount")
            ? CurrentScanResult.HiddenCount : 0
        c.HiddenNoiseCount.Text := "本次共隐藏 " hiddenCount " 个"
        c.ViewHiddenNoise.Enabled := IsObject(CurrentScanResult)
            && HasProp(CurrentScanResult, "HiddenItems")
            && CurrentScanResult.HiddenItems.Length > 0
    } finally c.Loading := false
}

DisplayControlChanged(c, *) {
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    if c.Loading
        return
    d := c.Draft.General
    d.MaxFilesPerFolder := Trim(c.GlobalMax.Value)
    d.SortMode := c.GlobalSort.Value = 2 ? SORT_NAME_ASC : SORT_MODIFIED_DESC
    d.ShowRecentSidebar := !!c.ShowRecent.Value
    d.RecentFileCount := Trim(c.RecentCount.Value)
    c.RecentCount.Enabled := d.ShowRecentSidebar
    d.NoiseFilter.Enabled := !!c.NoiseFilterEnabled.Value
}

RefreshSourceList(c, preferredId := "") {
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
            if source.SourceId = preferredId
                selectRow := row
        }
        c.SourceList.Opt("+Redraw")
        if !selectRow && c.Draft.Sources.Length
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
        if source.SourceId = sourceId
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
        c.SourceMax.Value := s.MaxFilesPerFolder
        c.SourceSort.Choose(s.SortMode = SORT_MODIFIED_DESC ? 1 : 2)
        c.SourceNoiseMode.Choose(s.NoiseFilterMode = NOISE_FILTER_ENABLED ? 2
            : s.NoiseFilterMode = NOISE_FILTER_DISABLED ? 3 : 1)
        c.SourceNoiseRuleCount.Text := s.SourceCustomPatternTexts.Length " 条附加规则"
        c.ExcludedCount.Text := "排除子文件夹：" s.ExcludedPaths.Length " 个"
        c.AllowedCount.Text := "允许覆盖共享排除："
            . s.AllowedExcludedPaths.Length " 个"
        UpdateSourceControlState(c)
    } finally c.Loading := false
}

SetSourceControlsEnabled(c, enabled) {
    for ctrl in [c.SourceName, c.SourceType, c.SourcePath, c.SourceBrowse, c.SourceOpen,
        c.SourceScope, c.SourceOpenMode, c.SourceFolderTime, c.SourceMax,
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

CommitCurrentSourceControlsToDraft(c) {
    global MODE_FILES, MODE_LAUNCHER
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    global SOURCE_OPEN_MODE_INHERIT, OPEN_MODE_SINGLE, OPEN_MODE_DOUBLE
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
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
    s.MaxFilesPerFolder := Trim(c.SourceMax.Value)
    s.SortMode := c.SourceSort.Value = 2 ? SORT_NAME_ASC : SORT_MODIFIED_DESC
    noiseModes := [NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED]
    s.NoiseFilterMode := noiseModes[Max(1, c.SourceNoiseMode.Value)]
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
    global MODE_FILES, SCOPE_RECURSIVE_FILES
    global SORT_MODIFIED_DESC, SOURCE_OPEN_MODE_INHERIT
    global NOISE_FILTER_INHERIT
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
    name := GetFileName(path)
    if name = ""
        name := path
    id := NewStableId("source")
    c.Draft.Sources.Push({
        Name: name, OriginalName: name, Path: path, Mode: MODE_FILES,
        IncludeSubfolders:
            c.Draft.General.DefaultDisplayScope = SCOPE_RECURSIVE_FILES,
        DisplayScope: c.Draft.General.DefaultDisplayScope,
        FolderTimeMode: c.Draft.General.DefaultFolderTimeMode,
        MaxFilesPerFolder: c.Draft.General.MaxFilesPerFolder,
        SortMode: SORT_MODIFIED_DESC,
        Filter: {
            Mode: c.Draft.General.DefaultFilter.Mode,
            Extensions: c.Draft.General.DefaultFilter.Extensions.Clone()
        },
        StripOrderPrefix: 0, HideExtensions: 0,
        SourceId: id, OpenFileMode: SOURCE_OPEN_MODE_INHERIT,
        NoiseFilterMode: NOISE_FILTER_INHERIT, SourceCustomPatternTexts: [],
        ExcludedPaths: [], AllowedExcludedPaths: []
    })
    RefreshSourceList(c, id)
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
    try Run(found.Value.Path)
    catch as err
        SettingsMessage(c, "无法打开文件夹：`n" err.Message,
            "打开失败", "Iconx")
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
        applicable := app.Extensions.Length
            ? JoinArray(app.Extensions, " ") : "所有文件"
        status := IsExistingExecutable(app.Path) ? "正常" : "程序不存在"
        row := c.AppList.Add("", app.Name, app.Path, applicable, status)
        c.AppRows[row] := app.Id
        if app.Id = preferredId
            selectRow := row
    }
    if selectRow
        c.AppList.Modify(selectRow, "Select Focus Vis")
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
        : {Id: "", Path: "", Name: "", Icon: "", Extensions: [], Enabled: true}
    app.OriginalPath := isEdit ? existing.Path : ""
    child := Gui("+Owner" c.Gui.Hwnd " -MaximizeBox -MinimizeBox",
        isEdit ? "编辑软件" : "添加软件")
    c.Child := child
    child.SetFont("s9", "Microsoft YaHei UI")
    child.MarginX := 14
    child.MarginY := 12
    child.AddText("xm ym+4 w70", "名称：")
    name := AddUiEdit(child, "x90 yp-4 w390", app.Name)
    child.AddText("xm y+18 w70", "程序：")
    path := AddUiEdit(child, "x90 yp-4 w310", app.Path)
    browse := AddUiButton(child, "x+8 yp w72", "浏览…")
    allFiles := child.AddRadio("xm y+22 Group", "所有文件")
    specified := child.AddRadio("xm y+12", "指定扩展名：")
    extensions := AddUiEdit(child, "x120 yp-4 w360",
        JoinArray(app.Extensions, ", "))
    hint := child.AddText("x120 y+2 w360 cGray", "多个扩展名用 , 分割")
    allFiles.Value := app.Extensions.Length = 0
    specified.Value := app.Extensions.Length > 0
    extensions.Enabled := specified.Value
    allFiles.OnEvent("Click", (*) => extensions.Enabled := false)
    specified.OnEvent("Click", (*) => extensions.Enabled := true)
    browse.OnEvent("Click", BrowseExecutableForEditor.Bind(path, name))
    ok := AddUiButton(child, "x320 y+24 w72 Default", "确定")
    cancel := AddUiButton(child, "x+8 yp w72", "取消")
    ok.OnEvent("Click", AcceptApplicationEditor.Bind(
        c, app, isEdit, name, path, specified, extensions, child))
    cancel.OnEvent("Click", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Close", CloseSettingsChild.Bind(c, child))
    child.OnEvent("Escape", CloseSettingsChild.Bind(c, child))
    c.Gui.Opt("+Disabled")
    child.Show("w508 h262")
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
    specifiedCtrl, extCtrl, child, *) {
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
    parts.Push(g.OpenFileMode, g.DefaultContextMenu, g.Hotkey, g.WindowMode,
        g.EscapeHidesPanel ? "1" : "0",
        g.ShowRecentSidebar ? "1" : "0",
        g.RecentFileCount "", g.MaxFilesPerFolder "", g.SortMode,
        g.EnablePublicUrlFallback ? "1" : "0",
        g.AllowHttp ? "1" : "0", g.TransferMaxConcurrent "",
        g.ShowCompletionNotifications ? "1" : "0")
    n := g.NoiseFilter
    parts.Push("N", n.Enabled ? "1" : "0", n.HideHidden ? "1" : "0",
        n.HideSystem ? "1" : "0", n.HideTemporary ? "1" : "0",
        n.HideIncompleteDownloads ? "1" : "0",
        JoinArray(n.CustomPatternTexts, Chr(30)))
    parts.Push("CW", draft.CurrentWorkspaceId)
    for workspace in draft.Workspaces {
        parts.Push("W", workspace.Id, workspace.Name)
        parts.Push("P", workspace.Id,
            JoinNormalizedPaths(workspace.PinnedPaths))
        for s in workspace.Sources {
            parts.Push("S", workspace.Id, s.SourceId, s.Name,
                PathKey(s.Path), s.Mode, s.DisplayScope,
                s.FolderTimeMode, s.MaxFilesPerFolder "",
                s.SortMode, s.Filter.Mode,
                JoinArray(s.Filter.Extensions, ","),
                s.StripOrderPrefix "", s.HideExtensions "",
                s.OpenFileMode, s.NoiseFilterMode,
                JoinArray(s.SourceCustomPatternTexts, Chr(30)),
                JoinNormalizedPaths(s.ExcludedPaths),
                JoinNormalizedPaths(s.AllowedExcludedPaths))
        }
    }
    for app in draft.Applications
        parts.Push("A", app.Id, app.Name, PathKey(app.Path),
            JoinArray(app.Extensions, ","), app.Enabled ? "1" : "0")
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
    CommitCurrentSourceControlsToDraft(c)
    GeneralControlChanged(c)
    DisplayControlChanged(c)
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
    SettingsDialog := 0
    SettingsController := 0
    try c.Gui.Destroy()
    EndAutoHidePause()
}

ValidateSettingsDraft(c) {
    global MODE_FILES, MODE_LAUNCHER
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, SOURCE_OPEN_MODE_INHERIT
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    global CONTEXT_MENU_POPDROP, CONTEXT_MENU_SYSTEM
    errors := []
    warnings := []
    d := c.Draft
    if d.General.OpenFileMode != OPEN_MODE_DOUBLE
        && d.General.OpenFileMode != OPEN_MODE_SINGLE
        errors.Push("共享默认打开文件方式无效。")
    if d.General.DefaultContextMenu != CONTEXT_MENU_POPDROP
        && d.General.DefaultContextMenu != CONTEXT_MENU_SYSTEM
        errors.Push("默认右键菜单设置无效。")
    if Trim(d.General.Hotkey) = ""
        errors.Push("呼出/隐藏快捷键不能为空。")
    if !IsIntegerText(d.General.MaxFilesPerFolder, 1, 100)
        errors.Push("每个来源最多显示数量必须是 1–100 的整数。")
    if !IsIntegerText(d.General.RecentFileCount, 1, 100)
        errors.Push("最近文件显示数量必须是 1–100 的整数。")
    if !IsIntegerText(d.General.TransferMaxConcurrent, 1, 6)
        errors.Push("外部传输最大并发数必须是 1–6 的整数。")

    if !d.Workspaces.Length
        errors.Push("至少需要保留一个工作区。")
    workspaceNames := Map()
    workspaceIds := Map()
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
        if RegExMatch(s.Name, "[\[\]=`r`n]")
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
        if !ValueInArray(s.SortMode, [SORT_MODIFIED_DESC, SORT_NAME_ASC])
            errors.Push("来源“" s.Name "”的排序设置无效。")
        if !IsIntegerText(s.MaxFilesPerFolder, 0, 999999)
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

    oldHotkey := ConfiguredHotkey
    wroteConfig := false
    try {
        CreateConfigBackup()
        AtomicConfigEdit(WriteSettingsDraft.Bind(c.Draft))
        wroteConfig := true
        LoadSettings()
        ApplyWindowMode()
        if ConfiguredHotkey != oldHotkey
            InstallHotkey(ConfiguredHotkey)
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
    doc.SetValue("General", "WindowMode", g.WindowMode, 1)
    doc.SetValue("General", "EscapeHidesPanel",
        g.EscapeHidesPanel ? "1" : "0", 1)
    doc.SetValue("General", "MaxFilesPerFolder", g.MaxFilesPerFolder, 1)
    doc.SetValue("General", "SortMode", g.SortMode, 1)
    doc.SetValue("General", "ShowRecentSidebar",
        g.ShowRecentSidebar ? "1" : "0", 1)
    doc.SetValue("General", "RecentFileCount", g.RecentFileCount, 1)
    doc.SetValue("ExternalTransfer", "EnablePublicUrlFallback",
        g.EnablePublicUrlFallback ? "1" : "0", 1)
    doc.SetValue("ExternalTransfer", "AllowHttp",
        g.AllowHttp ? "1" : "0", 1)
    doc.SetValue("ExternalTransfer", "MaxConcurrent",
        g.TransferMaxConcurrent, 1)
    doc.SetValue("ExternalTransfer", "ShowCompletionNotifications",
        g.ShowCompletionNotifications ? "1" : "0", 1)
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
            sourceEntries := [
                {Key: "WorkspaceId", Value: workspace.Id},
                {Key: "Name", Value: source.Name},
                {Key: "Path", Value: source.Path},
                {Key: "Mode", Value: source.Mode},
                {Key: "MaxFilesPerFolder",
                    Value: source.MaxFilesPerFolder},
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
            sourceKnown := ["WorkspaceId", "Name", "Path", "Mode",
                "MaxFilesPerFolder", "IncludeSubfolders", "DisplayScope",
                "FolderTimeMode", "SortMode", "FilterMode",
                "FileExtensions", "StripOrderPrefix", "HideExtensions",
                "OpenFileMode", "NoiseFilterMode"]
            doc.ReplaceKnownKeys(sourceSection, sourceEntries,
                sourceKnown, 3)
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
            {Key: "SourceOrder", Value: JoinArray(sourceIds, ",")}
        ], ["Name", "SourceOrder"], 3)
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

    appIds := []
    activeAppIds := Map()
    for app in draft.Applications
        activeAppIds[StrLower(app.Id)] := true
    oldAppIds := ParseOpenAppOrder(doc.GetValue("OpenApps", "Order", ""))
    for entry in doc.GetEntries("OpenApps") {
        if RegExMatch(entry.Key, "i)^App\d+$")
            && !ArrayContainsTextInsensitive(oldAppIds, entry.Value)
            oldAppIds.Push(entry.Value)
    }
    for id in oldAppIds {
        if !activeAppIds.Has(StrLower(id))
            doc.DeleteSection("OpenApp:" id)
    }
    for app in draft.Applications {
        appIds.Push(app.Id)
        section := "OpenApp:" app.Id
        doc.ReplaceKnownKeys(section, [
            {Key: "Path", Value: app.Path},
            {Key: "Name", Value: app.Name},
            {Key: "Icon", Value: app.Path},
            {Key: "Extensions", Value: JoinArray(app.Extensions, ",")},
            {Key: "Enabled", Value: app.Enabled ? "1" : "0"}
        ], ["Path", "Name", "Icon", "Extensions", "Enabled"], 4)
    }
    doc.ReplaceSection("OpenApps",
        [{Key: "Order", Value: JoinArray(appIds, ",")}], 4)

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
    ownerHwnd := IsObject(c.Child) ? c.Child.Hwnd : c.Gui.Hwnd
    opts := Trim(options " Owner" ownerHwnd)
    return MsgBox(text, title, opts)
}
