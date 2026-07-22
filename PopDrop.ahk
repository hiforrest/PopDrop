#Requires AutoHotkey v2.0
#SingleInstance Off

;@Ahk2Exe-SetMainIcon assets\app.ico
;@Ahk2Exe-AddResource assets\tray.ico, 555

; Worker processes must be routed before any GUI, hotkey, tray or COM setup.
;
; IMPORTANT: All constants that worker functions depend on must be defined
; before this block, because the worker calls ExitApp right after routing.

; ──── 排序模式常量 ────
global SORT_MODIFIED_DESC := "ModifiedDesc"
global SORT_NAME_ASC := "NameAsc"

; ──── 文件夹模式常量 ────
global MODE_FILES := "Files"
global MODE_LAUNCHER := "Launcher"

if A_Args.Length && A_Args[1] = "--scan-worker" {
    ; 纯后台扫描进程：立即隐藏窗口和托盘图标，避免任务栏闪烁
    A_IconHidden := true
    try WinHide("ahk_id " A_ScriptHwnd)
    RunScanWorkerMode()
    ExitApp
}

; #SingleInstance cannot distinguish the worker from the main process. Keep a
; small named mutex for the main UI instead, while allowing worker instances.
global MainInstanceMutex := 0
MainInstanceMutex := DllCall("kernel32\CreateMutexW", "ptr", 0, "int", 0,
    "wstr", "Local\PopDrop.Main", "ptr")
if !MainInstanceMutex || DllCall("kernel32\GetLastError") = 183
    ExitApp

; PopDrop - a topmost recent-file panel for Windows.
; The program intentionally uses only AutoHotkey v2 and Windows Shell APIs.

Persistent
SetWorkingDir A_ScriptDir
DllCall("ole32\OleInitialize", "ptr", 0)
OnExit(Cleanup)

global ConfigPath := A_ScriptDir "\config.ini"
global Panel := 0
global FileView := 0
global RecentLabel := 0
global RecentView := 0
global ViewButton := 0
global RecentButton := 0
global StatusText := 0
global ItemPaths := Map()
global RecentItemPaths := Map()
global PinnedPaths := []
global FolderSettings := []
global MaxFilesPerFolder := 8
global IncludeSubfolders := false
global ThumbnailSize := 96
global ThumbnailImageList := 0
global WindowWidth := 980
global WindowHeight := 620
global ViewMode := "Thumbnail"
global ShowRecentSidebar := true
global RecentFileCount := 12
global ConfiguredHotkey := "F3"
global ActiveHotkey := ""
global PanelVisible := false
global DragPaths := []
global SelectedFilePaths := []
global DragSourceHwnd := 0
global DragStartX := 0
global DragStartY := 0
global DragStarted := false
global DropVTable := 0
global DropCallbacks := []
global DataVTable := 0
global DataCallbacks := []
global DragDataObjects := Map()
global FilterMode := "All"
global FileExtensions := ""
global ConfigErrors := []
global LastValidFolderSettings := []
global ConfigErrorsShown := false
global ThumbnailPolicy := "Fast"
global CachePathSetting := ""
global CacheDir := ""
global CacheFilePath := ""
global CacheWritable := false
global CacheWriteWarningShown := false
global CurrentConfigFingerprint := ""
global CurrentScanResult := {Folders: [], Recent: []}
global ScanResultLoaded := false
global LastRenderedFingerprint := ""
global WorkerRunning := false
global WorkerPid := 0
global WorkerGeneration := ""
global WorkerRequestPath := ""
global WorkerReadyPath := ""
global PendingRefresh := false
global ScanGeneration := 0
global StatusKind := "default"
global StatusTimerToken := 0

global SortMode := SORT_MODIFIED_DESC

; ──── 文件夹级显示属性 ────
global StripOrderPrefix := 0
global HideExtensions := 0

; ──── 每个行对应的分组文件夹路径（双击分组标题使用） ────
global ItemFolderPaths := Map()
global GroupFolderPaths := Map()

; ──── 窗口模式 ────
global WINDOW_MODE_ALWAYS_ON_TOP := "always_on_top"
global WINDOW_MODE_TEMPORARY     := "temporary"
global WINDOW_MODE_NORMAL        := "normal"

global WindowMode := WINDOW_MODE_ALWAYS_ON_TOP
global AutoHidePauseDepth := 0

EnsureConfig()
LoadSettings()
BuildPanel()
ApplyWindowMode()
InstallHotkey(ConfiguredHotkey)
BuildTrayMenu()
InitDropSource()
OnMessage(0x0201, FileViewLeftButtonDown) ; WM_LBUTTONDOWN
OnMessage(0x0200, FileViewMouseMove)      ; WM_MOUSEMOVE
OnMessage(0x0006, PanelActivationChanged) ; WM_ACTIVATE
OnMessage(0x004E, FileViewNotify)         ; WM_NOTIFY (group header click)

; 用 Owner 模式弹出 MsgBox，确保弹窗保持在置顶主面板之上
ShowPanelMsgBox(Text, Title?, Options?) {
    global Panel

    BeginAutoHidePause()

    try {
        ; 仅当面板可见时指定 Owner
        if IsObject(Panel)
            && DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int") {
            opts := Trim(Options " Owner" Panel.Hwnd)
            return MsgBox(Text, Title?, opts)
        }
        return MsgBox(Text, Title?, Options?)
    } finally {
        EndAutoHidePause()
    }
}

EnsureConfig() {
    global ConfigPath
    if FileExist(ConfigPath) {
        EnsureConfigEncoding()
        return
    }

    defaultConfig :=
    (
    "; PopDrop 配置文件`n"
    "; 修改后，在面板中点“刷新”即可重新读取。`n"
    "`n"
    "[General]`n"
    "Hotkey=F3`n"
    "MaxFilesPerFolder=8`n"
    "IncludeSubfolders=0`n"
    "ThumbnailSize=96`n"
    "WindowWidth=980`n"
    "WindowHeight=620`n"
    "ViewMode=Thumbnail`n"
    "ShowRecentSidebar=1`n"
    "RecentFileCount=12`n"
    "CachePath=`n"
    "ThumbnailPolicy=Fast`n"
    "; 窗口模式：always_on_top（默认）| temporary（失焦自动隐藏）| normal（普通窗口）`n"
    "WindowMode=always_on_top`n"
    "; ModifiedDesc（默认，从新到旧）| NameAsc（文件名自然升序）`n"
    "SortMode=ModifiedDesc`n"
    "; All / Include / Exclude`n"
    "FilterMode=All`n"
    "FileExtensions=`n"
    "`n"
    "[Folders]`n"
    "文档=%USERPROFILE%\Documents`n"
    "下载=D:\download`n"
    "`n"
    "[PinnedFiles]`n"
    )
    ; IniRead/IniWrite use the Windows profile API, which requires UTF-16 for
    ; reliable Chinese text on every system locale.
    FileAppend(defaultConfig, ConfigPath, "UTF-16")
}

EnsureConfigEncoding() {
    global ConfigPath
    try {
        rawBytes := FileRead(ConfigPath, "RAW")
        if rawBytes.Size >= 2 && NumGet(rawBytes, 0, "ushort") = 0xFEFF
            return
        contents := FileRead(ConfigPath, "UTF-8")
        output := FileOpen(ConfigPath, "w", "UTF-16")
        output.Write(contents)
        output.Close()
    }
}

LoadSettings(*) {
    global ConfigPath, ConfiguredHotkey, MaxFilesPerFolder
    global IncludeSubfolders, ThumbnailSize, FolderSettings, PinnedPaths
    global WindowWidth, WindowHeight, ViewMode, ShowRecentSidebar, RecentFileCount
    global ThumbnailPolicy, CachePathSetting, CacheDir, CacheFilePath, CacheWritable
    global CurrentConfigFingerprint, CurrentScanResult, ScanResultLoaded
    global FilterMode, FileExtensions, ConfigErrors, LastValidFolderSettings
    global ConfigErrorsShown
    global WindowMode, WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY, WINDOW_MODE_NORMAL
    global SortMode, SORT_MODIFIED_DESC, SORT_NAME_ASC
    global MODE_FILES, MODE_LAUNCHER

    ConfiguredHotkey := Trim(IniRead(ConfigPath, "General", "Hotkey", "F3"))
    if ConfiguredHotkey = ""
        ConfiguredHotkey := "F3"

    ; 读取窗口模式
    rawMode := StrLower(Trim(IniRead(ConfigPath, "General", "WindowMode", "always_on_top")))
    if rawMode = WINDOW_MODE_ALWAYS_ON_TOP || rawMode = WINDOW_MODE_TEMPORARY || rawMode = WINDOW_MODE_NORMAL {
        WindowMode := rawMode
    } else {
        WindowMode := WINDOW_MODE_ALWAYS_ON_TOP
        ConfigErrors.Push("WindowMode 配置值无效：" rawMode "，已使用默认模式 always_on_top。")
    }

    try MaxFilesPerFolder := Integer(IniRead(ConfigPath, "General", "MaxFilesPerFolder", "8"))
    catch
        MaxFilesPerFolder := 8
    MaxFilesPerFolder := Max(1, Min(MaxFilesPerFolder, 100))
    IncludeSubfolders := IniRead(ConfigPath, "General", "IncludeSubfolders", "0") = "1"
    try ThumbnailSize := Integer(IniRead(ConfigPath, "General", "ThumbnailSize", "96"))
    catch
        ThumbnailSize := 96
    ThumbnailSize := Max(48, Min(ThumbnailSize, 256))

    try WindowWidth := Integer(IniRead(ConfigPath, "General", "WindowWidth", "980"))
    catch
        WindowWidth := 980
    try WindowHeight := Integer(IniRead(ConfigPath, "General", "WindowHeight", "620"))
    catch
        WindowHeight := 620
    WindowWidth := Max(620, Min(WindowWidth, 3000))
    WindowHeight := Max(380, Min(WindowHeight, 2000))

    configuredView := StrLower(Trim(IniRead(ConfigPath, "General", "ViewMode", "Thumbnail")))
    ViewMode := configuredView = "list" ? "List" : "Thumbnail"
    ShowRecentSidebar := IniRead(ConfigPath, "General", "ShowRecentSidebar", "1") = "1"
    try RecentFileCount := Integer(IniRead(ConfigPath, "General", "RecentFileCount", "12"))
    catch
        RecentFileCount := 12
    RecentFileCount := Max(1, Min(RecentFileCount, 100))

    ThumbnailPolicy := StrLower(Trim(IniRead(ConfigPath, "General", "ThumbnailPolicy", "Fast"))) = "full"
        ? "Full" : "Fast"
    CachePathSetting := Trim(IniRead(ConfigPath, "General", "CachePath", ""))

    ; 读取全局排序模式
    rawSort := StrLower(Trim(IniRead(ConfigPath, "General", "SortMode", "ModifiedDesc")))
    if rawSort = StrLower(SORT_MODIFIED_DESC)
        SortMode := SORT_MODIFIED_DESC
    else if rawSort = StrLower(SORT_NAME_ASC)
        SortMode := SORT_NAME_ASC
    else
        SortMode := SORT_MODIFIED_DESC

    ; 读取全局筛选设置
    FilterMode := StrLower(Trim(IniRead(ConfigPath, "General", "FilterMode", "All")))
    FileExtensions := Trim(IniRead(ConfigPath, "General", "FileExtensions", ""))

    ; 读取文件夹列表
    FolderSettings := []
    for entry in ReadIniSection("Folders") {
        if entry.Value != ""
            FolderSettings.Push({Name: entry.Key, Path: NormalizePath(entry.Value)})
    }

    ; 验证并解析配置，得到每个文件夹的最终设置
    ConfigErrorsShown := false
    result := ValidateConfig()
    if result.Valid {
        LastValidFolderSettings := result.Settings
        ConfigErrors := []
    } else {
        ConfigErrors := result.Errors
        ; 有错误时，如果上次有效设置存在则继续使用，否则使用 result.Settings（含默认值）
        if LastValidFolderSettings.Length {
            ; 保留 LastValidFolderSettings
        } else {
            ; 使用安全默认值
            LastValidFolderSettings := []
            for f in FolderSettings {
                LastValidFolderSettings.Push({
                    Name: f.Name,
                    Path: f.Path,
                    Mode: MODE_FILES,
                    IncludeSubfolders: IncludeSubfolders,
                    MaxFilesPerFolder: MaxFilesPerFolder,
                    SortMode: SortMode,
                    Filter: {Mode: "All", Extensions: []},
                    StripOrderPrefix: 0,
                    HideExtensions: 0
                })
            }
        }
    }

    CacheDir := ResolveCacheDirectory(CachePathSetting)
    CacheFilePath := CacheDir "\scan-cache-v2.ini"
    CacheWritable := EnsureCacheDirectory(CacheDir)
    newFingerprint := ComputeConfigFingerprint(LastValidFolderSettings)
    if CurrentConfigFingerprint != newFingerprint {
        CurrentConfigFingerprint := newFingerprint
        CurrentScanResult := {Folders: [], Recent: []}
        ScanResultLoaded := false
    }

    PinnedPaths := []
    for entry in ReadIniSection("PinnedFiles") {
        path := NormalizePath(entry.Value)
        if path != "" && !ArrayContainsPath(PinnedPaths, path)
            PinnedPaths.Push(path)
    }
}

; ──── 配置验证与筛选函数 ────

ValidateConfig() {
    global ConfigPath, ConfigErrors, FilterMode, FileExtensions, FolderSettings
    global MaxFilesPerFolder, IncludeSubfolders, LastValidFolderSettings
    global ConfigErrorsShown, SortMode, SORT_MODIFIED_DESC, SORT_NAME_ASC
    global MODE_FILES, MODE_LAUNCHER

    errors := []
    tempGlobalFilter := {Mode: "All", Extensions: []}
    tempGlobalMaxFiles := 8
    tempGlobalIncludeSubfolders := false
    tempGlobalSortMode := SORT_MODIFIED_DESC

    ; ── 解析全局排序 ──
    rawSort := StrLower(Trim(IniRead(ConfigPath, "General", "SortMode", "ModifiedDesc")))
    if rawSort = StrLower(SORT_MODIFIED_DESC)
        tempGlobalSortMode := SORT_MODIFIED_DESC
    else if rawSort = StrLower(SORT_NAME_ASC)
        tempGlobalSortMode := SORT_NAME_ASC
    else
        errors.Push("[General] 中 SortMode 值无效：" rawSort "。允许的值：ModifiedDesc, NameAsc。")

    ; ── 解析全局筛选 ──
    rawMode := StrLower(Trim(IniRead(ConfigPath, "General", "FilterMode", "All")))
    rawExt := Trim(IniRead(ConfigPath, "General", "FileExtensions", ""))
    if rawMode = "inherit"
        errors.Push("[General] 中 FilterMode 不能为 Inherit（只有文件夹级才支持 Inherit）。")
    gf := ParseFilterSettings(rawMode, rawExt, "[General]")
    if HasProp(gf, "Error")
        errors.Push(gf.Error)
    else
        tempGlobalFilter := gf

    ; ── 解析全局数值 ──
    try tempGlobalMaxFiles := Integer(IniRead(ConfigPath, "General", "MaxFilesPerFolder", "8"))
    catch
        tempGlobalMaxFiles := 8
    tempGlobalMaxFiles := Max(1, Min(tempGlobalMaxFiles, 100))

    tempGlobalIncludeSubfolders := IniRead(ConfigPath, "General", "IncludeSubfolders", "0") = "1"

    ; ── 解析每个文件夹的独立配置 ──
    resolved := []
    folderNames := Map()
    for f in FolderSettings {
        folderNames[f.Name] := true
        sectionName := "Folder:" f.Name

        ; 读取该文件夹的独立配置节
        folderMax := tempGlobalMaxFiles
        folderRecursive := tempGlobalIncludeSubfolders
        folderFilter := {Mode: tempGlobalFilter.Mode, Extensions: tempGlobalFilter.Extensions}
        folderSortMode := tempGlobalSortMode
        folderMode := MODE_FILES
        folderStripOrderPrefix := 0
        folderHideExtensions := 0

        ; 检查是否有独立配置节
        sectionExists := false
        try {
            raw := IniRead(ConfigPath, sectionName)
            if raw != ""
                sectionExists := true
        }
        catch
            sectionExists := false

        if sectionExists {
            ; ── 读取 Mode ──
            rawModeV := StrLower(Trim(IniRead(ConfigPath, sectionName, "Mode", "Files")))
            if rawModeV = "files"
                folderMode := MODE_FILES
            else if rawModeV = "launcher"
                folderMode := MODE_LAUNCHER
            else if rawModeV != ""
                errors.Push("[" sectionName "] 中 Mode 值无效：" rawModeV "。允许的值：Files, Launcher。")

            ; ── 应用 Launcher 默认值 ──
            if folderMode = MODE_LAUNCHER {
                ; 为 Launcher 设置默认值，用户显式配置会覆盖
                folderRecursive := false
                folderMax := 0  ; 0 = 无限
                folderSortMode := SORT_NAME_ASC
                folderFilter := {Mode: "Include", Extensions: [".lnk", ".url", ".exe"]}
                folderStripOrderPrefix := 1
                folderHideExtensions := 1
            }

            ; ── 读取 MaxFilesPerFolder ──
            try {
                val := Trim(IniRead(ConfigPath, sectionName, "MaxFilesPerFolder", ""))
                if val != "" {
                    rawVal := val
                    if StrLower(val) = "all" || val = "0" {
                        folderMax := 0
                    } else {
                        folderMax := Integer(val)
                        if folderMax < 1
                            folderMax := 1
                    }
                }
            }
            catch
                errors.Push("[" sectionName "] 中 MaxFilesPerFolder 值无效：" rawVal "。")

            ; ── 读取 IncludeSubfolders ──
            try {
                val := IniRead(ConfigPath, sectionName, "IncludeSubfolders", "")
                if val != "" {
                    if val = "1"
                        folderRecursive := true
                    else if val = "0"
                        folderRecursive := false
                    else
                        errors.Push("[" sectionName "] 中 IncludeSubfolders 只能为 0 或 1，实际值为：" val "。")
                }
            }

            ; ── 读取 SortMode ──
            try {
                val := Trim(IniRead(ConfigPath, sectionName, "SortMode", ""))
                if val != "" {
                    rawSortV := StrLower(val)
                    if rawSortV = StrLower(SORT_MODIFIED_DESC)
                        folderSortMode := SORT_MODIFIED_DESC
                    else if rawSortV = StrLower(SORT_NAME_ASC)
                        folderSortMode := SORT_NAME_ASC
                    else if rawSortV = "inherit"
                        folderSortMode := tempGlobalSortMode
                    else
                        errors.Push("[" sectionName "] 中 SortMode 值无效：" val "。")
                }
            }

            ; ── 读取筛选模式 FileExtensions ──
            rawMode := StrLower(Trim(IniRead(ConfigPath, sectionName, "FilterMode", "")))
            rawExt := Trim(IniRead(ConfigPath, sectionName, "FileExtensions", ""))
            filterExplicit := rawMode != "" || rawExt != ""

            if folderMode = MODE_LAUNCHER {
                ; Launcher 模式特殊筛选逻辑
                if rawMode = "inherit" {
                    ; 继承全局
                    folderFilter := {Mode: tempGlobalFilter.Mode, Extensions: tempGlobalFilter.Extensions}
                } else if rawMode = "all" {
                    folderFilter := {Mode: "All", Extensions: []}
                } else if rawMode = "include" || rawMode = "exclude" {
                    pf := ParseFilterSettings(rawMode, rawExt, "[" sectionName "]")
                    if HasProp(pf, "Error")
                        errors.Push(pf.Error)
                    else
                        folderFilter := pf
                } else if rawMode = "" && rawExt != "" {
                    ; 仅填写 FileExtensions 时自动使用 Include
                    pf := ParseFilterSettings("include", rawExt, "[" sectionName "]")
                    if HasProp(pf, "Error")
                        errors.Push(pf.Error)
                    else
                        folderFilter := pf
                } else {
                    ; 未配置筛选，使用 Launcher 默认（已在上面设置）
                }
            } else {
                ; Files 模式
                if rawMode = "inherit" || rawMode = "" {
                    ; 整体继承全局筛选
                    folderFilter := {Mode: tempGlobalFilter.Mode, Extensions: tempGlobalFilter.Extensions}
                } else {
                    pf := ParseFilterSettings(rawMode, rawExt, "[" sectionName "]")
                    if HasProp(pf, "Error")
                        errors.Push(pf.Error)
                    else
                        folderFilter := pf
                }
            }

            ; ── 读取 StripOrderPrefix ──
            try {
                val := Trim(IniRead(ConfigPath, sectionName, "StripOrderPrefix", ""))
                if val != "" {
                    if val = "1"
                        folderStripOrderPrefix := 1
                    else if val = "0"
                        folderStripOrderPrefix := 0
                    else
                        errors.Push("[" sectionName "] 中 StripOrderPrefix 只能为 0 或 1，实际值为：" val "。")
                }
            }

            ; ── 读取 HideExtensions ──
            try {
                val := Trim(IniRead(ConfigPath, sectionName, "HideExtensions", ""))
                if val != "" {
                    if val = "1"
                        folderHideExtensions := 1
                    else if val = "0"
                        folderHideExtensions := 0
                    else
                        errors.Push("[" sectionName "] 中 HideExtensions 只能为 0 或 1，实际值为：" val "。")
                }
            }
        }

        resolved.Push({
            Name: f.Name,
            Path: f.Path,
            Mode: folderMode,
            IncludeSubfolders: folderRecursive,
            MaxFilesPerFolder: folderMax,
            SortMode: folderSortMode,
            Filter: folderFilter,
            StripOrderPrefix: folderStripOrderPrefix,
            HideExtensions: folderHideExtensions
        })
    }

    ; ── 检查 [Folder:xxx] 节是否对应存在的文件夹 ──
    knownNames := Map()
    for f in FolderSettings
        knownNames[f.Name] := true
    try {
        Loop Read, ConfigPath {
            if RegExMatch(A_LoopReadLine, "i)^\[Folder:(.+)\]$", &m) {
                folderName := m[1]
                if !knownNames.Has(folderName) {
                    errors.Push("配置节 [Folder:" folderName "] 引用了不存在的文件夹名称，[Folders] 中未定义。")
                }
            }
        }
    }

    if errors.Length {
        ConfigErrors := errors
        return {Valid: false, Errors: errors, Settings: resolved}
    }

    ; 验证通过，返回设置
    return {Valid: true, Settings: resolved}
}

ParseFilterSettings(mode, rawExtensions, context) {
    ; mode: 小写，已 trim
    ; 返回 {Mode: "...", Extensions: [...], Error: ""} 或 {Error: "..."}

    if mode = "" || mode = "all"
        return {Mode: "All", Extensions: []}

    if mode = "include" || mode = "exclude" {
        if rawExtensions = "" {
            return {Error: context " 中 FilterMode=" mode " 但 FileExtensions 为空。请提供至少一个扩展名。"}
        }
        exts := NormalizeExtensionList(rawExtensions)
        invalid := []
        for ext in exts {
            if RegExMatch(ext, "[*?\\/]") {
                invalid.Push(ext)
            }
        }
        if invalid.Length {
            return {Error: context " 中 FileExtensions 包含非法字符（* ? \ /）：" JoinArray(invalid, ", ")}
        }
        return {Mode: mode, Extensions: exts}
    }

    if mode = "inherit"
        return {Mode: "Inherit", Extensions: []}

    return {Error: context " 中 FilterMode 值无效：" mode "。允许的值：All, Include, Exclude（文件夹级还支持 Inherit）。"}
}

NormalizeExtensionList(raw) {
    ; 解析逗号分隔的扩展名列表
    ; 返回规范化后的小写扩展名数组（含 . 前缀），去重
    if raw = ""
        return []

    seen := Map()
    result := []
    parts := StrSplit(raw, ",", " `t")

    for part in parts {
        p := Trim(part)
        if p = ""
            continue

        ; 确保以 . 开头
        ext := SubStr(p, 1, 1) = "." ? p : "." p
        ext := StrLower(ext)

        if seen.Has(ext)
            continue
        seen[ext] := true
        result.Push(ext)
    }
    return result
}

ShouldIncludeFile(filename, filter) {
    ; filter: {Mode: "All"|"Include"|"Exclude", Extensions: [...]}
    if filter.Mode = "All"
        return true

    if filter.Mode = "Include" {
        if !filter.Extensions.Length
            return true ; 无扩展名列表则通过（防御性）
        for ext in filter.Extensions {
            if StrLower(SubStr(filename, -StrLen(ext))) = ext
                return true
        }
        return false
    }

    if filter.Mode = "Exclude" {
        if !filter.Extensions.Length
            return true ; 无扩展名列表则不排除
        for ext in filter.Extensions {
            if StrLower(SubStr(filename, -StrLen(ext))) = ext
                return false
        }
        return true
    }

    return true ; 未知模式，安全通过
}

JoinArray(arr, sep) {
    s := ""
    for i, v in arr {
        if i > 1
            s .= sep
        s .= v
    }
    return s
}

ShowConfigErrorDialog() {
    global ConfigErrors, ConfigErrorsShown
    if ConfigErrors.Length && !ConfigErrorsShown {
        msg := "配置有 " ConfigErrors.Length " 处问题，已继续使用上一次有效设置。`n`n"
        msg .= "详细错误信息：`n"
        for i, err in ConfigErrors
            msg .= "  " i ". " err "`n"
        ShowPanelMsgBox(msg, "PopDrop 配置错误", "Icon!")
        ConfigErrorsShown := true
    }
}

ReadIniSection(sectionName) {
    global ConfigPath
    result := []
    try raw := IniRead(ConfigPath, sectionName)
    catch
        return result

    for line in StrSplit(raw, "`n", "`r") {
        equalPos := InStr(line, "=")
        if !equalPos
            continue
        key := Trim(SubStr(line, 1, equalPos - 1))
        value := Trim(SubStr(line, equalPos + 1))
        if key != ""
            result.Push({Key: key, Value: value})
    }
    return result
}

NormalizePath(path) {
    path := Trim(path, " `t`r`n`"")
    if path = ""
        return ""

    required := DllCall("kernel32\ExpandEnvironmentStringsW", "str", path, "ptr", 0, "uint", 0, "uint")
    if required {
        expanded := Buffer(required * 2, 0)
        DllCall("kernel32\ExpandEnvironmentStringsW", "str", path, "ptr", expanded.Ptr, "uint", required)
        path := StrGet(expanded)
    }

    if !RegExMatch(path, "i)^(?:[A-Z]:\\|\\\\)")
        path := A_ScriptDir "\" path
    if RegExMatch(path, "i)^[A-Z]:\\$")
        return path
    return RTrim(path, "\")
}

BuildPanel() {
    global Panel, FileView, RecentLabel, RecentView, ViewButton, RecentButton, StatusText

    Panel := Gui("+Resize +MinSize620x380", "PopDrop")
    Panel.MarginX := 12
    Panel.MarginY := 10
    Panel.SetFont("s9", "Microsoft YaHei UI")

    Panel.AddButton("xm ym w68 h30", "🔄 刷新").OnEvent("Click", RefreshPanel)
    Panel.AddButton("x+6 yp w100 h30", "📌 添加固定文件").OnEvent("Click", AddPinnedFiles)
    Panel.AddButton("x+6 yp w70 h30", "取消固定").OnEvent("Click", RemovePinnedFile)
    ViewButton := Panel.AddButton("x+6 yp w95 h30", "视图")
    ViewButton.OnEvent("Click", ToggleViewMode)
    RecentButton := Panel.AddButton("x+6 yp w90 h30", "近期栏")
    RecentButton.OnEvent("Click", ToggleRecentSidebar)
    Panel.AddButton("x+6 yp w65 h30", "⚙️ 配置").OnEvent("Click", OpenConfig)
    Panel.AddButton("x+6 yp w68 h30", "❌ 关闭").OnEvent("Click", HidePanel)

    ; Multi-select is the native ListView default. In icon view this enables
    ; Ctrl-click, Shift range selection and marquee selection on blank space.
    FileView := Panel.AddListView("xm y+10 w716 h468 Icon +0x100", ["文件", "修改时间"])
    FileView.OnEvent("DoubleClick", OpenFileViewItem)
    FileView.OnEvent("ContextMenu", FileViewContextMenu)
    FileView.OnEvent("ItemSelect", FileViewItemSelect)
    ; LVS_EX_DOUBLEBUFFER | LVS_EX_GROUPHEADERCLICK reduces flicker and
    ; enables clicking group headers to open folders.
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1036,
        "ptr", 0x410000, "ptr", 0x410000, "ptr")
    
    RecentLabel := Panel.AddText("x740 y50 w220 h22 +0x200", "最近打开")
    RecentLabel.SetFont("s10 Bold")
    RecentView := Panel.AddListView("x740 y76 w220 h442 Report -Hdr -Multi", ["文件"])
    RecentView.OnEvent("DoubleClick", OpenRecentItem)
    RecentView.OnEvent("ContextMenu", RecentContextMenu)
    RecentView.OnEvent("ItemSelect", RecentItemSelect)

    StatusText := Panel.AddText("xm y+8 w716 h22 +0x200", "就绪")
    Panel.OnEvent("Close", HandlePanelClose)
    Panel.OnEvent("Escape", HandlePanelClose)
    Panel.OnEvent("Size", ResizePanel)
    UpdateViewButtons()
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
    if activationState = 0
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

TryAutoHidePanel() {
    global Panel, PanelVisible, WindowMode, AutoHidePauseDepth
    global WINDOW_MODE_TEMPORARY

    if WindowMode != WINDOW_MODE_TEMPORARY
        return

    if !PanelVisible || !IsObject(Panel)
        return

    if AutoHidePauseDepth > 0
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
    global ActiveHotkey
    if A_IsCompiled {
        TraySetIcon(A_ScriptFullPath, -555, true)
    } else {
        TraySetIcon(A_ScriptDir "\assets\tray.ico", 1, true)
    }
    A_TrayMenu.Delete()
    A_TrayMenu.Add("显示/隐藏面板 (" ActiveHotkey ")", TogglePanel)
    A_TrayMenu.Add("刷新并显示", ShowAndRefresh)
    A_TrayMenu.Add()
    A_TrayMenu.Add("打开配置", OpenConfig)
    A_TrayMenu.Add("退出", (*) => ExitApp())
    A_TrayMenu.Default := "显示/隐藏面板 (" ActiveHotkey ")"
    A_IconTip := "PopDrop"
}

InstallHotkey(newHotkey) {
    global ActiveHotkey, ConfiguredHotkey, ConfigPath
    if newHotkey = ActiveHotkey
        return

    try Hotkey(newHotkey, TogglePanel, "On")
    catch as err {
        ShowPanelMsgBox("快捷键配置无效：" newHotkey "`n已改用 F3。`n`n" err.Message,
            "PopDrop", "Icon!")
        newHotkey := "F3"
        ConfiguredHotkey := newHotkey
        IniWrite(newHotkey, ConfigPath, "General", "Hotkey")
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

ShowAndRefresh(forceRefresh := false, *) {
    global Panel, PanelVisible, ConfiguredHotkey, ActiveHotkey, WindowWidth, WindowHeight
    global ScanResultLoaded, CurrentScanResult, LastRenderedFingerprint, StatusKind
    global SortMode
    LoadSettings()
    ApplyWindowMode()
    if ConfiguredHotkey != ActiveHotkey {
        InstallHotkey(ConfiguredHotkey)
        BuildTrayMenu()
    }
    Panel.Show("w" WindowWidth " h" WindowHeight)
    PanelVisible := true
    ApplyWindowIcon()
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
    UpdateViewButtons()
    LastRenderedFingerprint := CurrentConfigFingerprint
    StartBackgroundScan(forceRefresh)
}

ApplyWindowIcon() {
    global Panel
    iconPath := A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\assets\app.ico"
    hIcon := DllCall("LoadImageW", "ptr", 0, "str", iconPath,
        "uint", 1, "int", 0, "int", 0, "uint", 0x10, "ptr") ; IMAGE_ICON, LR_LOADFROMFILE
    if hIcon {
        SendMessage(0x80, 0, hIcon, , "ahk_id " Panel.Hwnd) ; WM_SETICON, ICON_SMALL
        SendMessage(0x80, 1, hIcon, , "ahk_id " Panel.Hwnd) ; WM_SETICON, ICON_BIG
        ; The window takes ownership of the icon handle; do not destroy.
    }
}

RefreshPanel(*) {
    ShowAndRefresh(true)
}

HidePanel(*) {
    global Panel, PanelVisible
    CancelAutoHideCheck()
    Panel.Hide()
    PanelVisible := false
}

HandlePanelClose(*) {
    HidePanel()
    return true
}

ResizePanel(guiObj, minMax, width, height) {
    global FileView, RecentLabel, RecentView, StatusText, ShowRecentSidebar
    if minMax = -1
        return
    contentHeight := Max(180, height - 92)
    if ShowRecentSidebar {
        sidebarWidth := Min(280, Max(190, Floor(width * 0.28)))
        mainWidth := Max(280, width - sidebarWidth - 36)
        sidebarX := 24 + mainWidth
        FileView.Move(12, 50, mainWidth, contentHeight)
        RecentLabel.Move(sidebarX, 50, sidebarWidth, 22)
        RecentView.Move(sidebarX, 76, sidebarWidth, Max(154, contentHeight - 26))
        RecentView.ModifyCol(1, Max(120, sidebarWidth - 8))
        RecentLabel.Visible := true
        RecentView.Visible := true
    } else {
        FileView.Move(12, 50, Max(200, width - 24), contentHeight)
        RecentLabel.Visible := false
        RecentView.Visible := false
    }
    StatusText.Move(, height - 27, Max(200, width - 24))
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

ToggleViewMode(*) {
    global ViewMode, ConfigPath
    ViewMode := ViewMode = "Thumbnail" ? "List" : "Thumbnail"
    IniWrite(ViewMode, ConfigPath, "General", "ViewMode")
    ApplyViewMode()
    UpdateViewButtons()
}

ToggleRecentSidebar(*) {
    global ShowRecentSidebar, ConfigPath
    ShowRecentSidebar := !ShowRecentSidebar
    IniWrite(ShowRecentSidebar ? "1" : "0", ConfigPath, "General", "ShowRecentSidebar")
    if ShowRecentSidebar
        PopulateRecentSidebar()
    UpdateViewButtons()
    RequestNativeLayout()
}

UpdateViewButtons() {
    global ViewButton, RecentButton, ViewMode, ShowRecentSidebar
    if IsObject(ViewButton)
        ViewButton.Text := ViewMode = "Thumbnail" ? "👀 缩略图：开" : "👀 缩略图：关"
    if IsObject(RecentButton)
        RecentButton.Text := ShowRecentSidebar ? "🕒 近期栏：开" : "🕒 近期栏：关"
}

ApplyViewMode() {
    global FileView, ViewMode, ThumbnailSize
    if ViewMode = "List" {
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x108E,
            "ptr", 1, "ptr", 0, "ptr") ; LVM_SETVIEW, LV_VIEW_DETAILS
        FileView.ModifyCol(1, 360)
        FileView.ModifyCol(2, 132)
    } else {
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x108E,
            "ptr", 0, "ptr", 0, "ptr") ; LVM_SETVIEW, LV_VIEW_ICON
        FileView.ModifyCol(1, ThumbnailSize + 32)
        spacing := (ThumbnailSize + 24) | ((ThumbnailSize + 96) << 16)
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1035,
            "ptr", 0, "ptr", spacing, "ptr")
    }
}

PopulatePanel() {
    global FileView, ItemPaths, ItemFolderPaths, PinnedPaths, FolderSettings, StatusText
    global ThumbnailSize, ThumbnailImageList, SelectedFilePaths, LastValidFolderSettings, ConfigErrors
    global CurrentScanResult, ScanResultLoaded, StatusKind
    global ConfigErrorsShown, MODE_FILES, GroupFolderPaths

    SelectedFilePaths := []
    FileView.Opt("-Redraw")
    FileView.Delete()
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x10A0,
        "ptr", 0, "ptr", 0, "ptr") ; LVM_REMOVEALLGROUPS
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x109D,
        "ptr", 1, "ptr", 0, "ptr") ; LVM_ENABLEGROUPVIEW

    newImageList := DllCall("comctl32\ImageList_Create", "int", ThumbnailSize,
        "int", ThumbnailSize, "uint", 0x21, "int", 24, "int", 12, "ptr")
    if !newImageList
        throw Error("无法创建缩略图列表。")
    oldImageList := FileView.SetImageList(newImageList, 0)
    ThumbnailImageList := newImageList
    if oldImageList && oldImageList != newImageList
        DllCall("comctl32\ImageList_Destroy", "ptr", oldImageList)
    spacing := (ThumbnailSize + 24) | ((ThumbnailSize + 96) << 16)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1035,
        "ptr", 0, "ptr", spacing, "ptr") ; LVM_SETICONSPACING

    ItemPaths := Map()
    ItemFolderPaths := Map()
    GroupFolderPaths := Map()
    displayedCount := 0
    unavailableCount := 0
    groupId := 1

    if PinnedPaths.Length {
        InsertListGroup(groupId, "固定文件  (" PinnedPaths.Length ")")
        for path in PinnedPaths {
            exists := FileExist(path)
            label := GetFileName(path)
            if !exists
                label .= "  [文件不存在]"
            row := AddFileTile(path, label, "", groupId)
            ItemPaths[row] := path
            displayedCount += 1
        }
        groupId += 1
    }

    ; 使用验证后的文件夹设置。目录扫描已经由 worker 完成；此处只渲染
    ; 已准备好的结果，避免 UI 路径再次枚举目录。
    folderSettings := LastValidFolderSettings.Length ? LastValidFolderSettings : FolderSettings
    ; 如果没有验证过的设置，为每个文件夹构建默认设置
    if !LastValidFolderSettings.Length {
        folderSettings := []
        for f in FolderSettings {
            folderSettings.Push({
                Name: f.Name,
                Path: f.Path,
                Mode: MODE_FILES,
                IncludeSubfolders: IncludeSubfolders,
                MaxFilesPerFolder: MaxFilesPerFolder,
                SortMode: SortMode,
                Filter: {Mode: "All", Extensions: []},
                StripOrderPrefix: 0,
                HideExtensions: 0
            })
        }
    }

    for index, folder in folderSettings {
        scan := FindFolderScanResult(CurrentScanResult.Folders, folder.Path, folder.Name, index)
        state := IsObject(scan) ? scan.State : "Pending"
        files := IsObject(scan) ? scan.Files : []
        filterMode := folder.Filter.Mode
        if state = "Unavailable"
            suffix := " [目录不可用]"
        else if state = "Pending"
            suffix := ""
        else if files.Length = 0 && filterMode != "All"
            suffix := " [没有符合筛选条件的文件]"
        else
            suffix := " (" files.Length ")"
        InsertListGroup(groupId, folder.Name suffix "  —  " folder.Path)
        GroupFolderPaths[groupId] := folder.Path
        if state = "Unavailable" {
            row := AddPlaceholderTile("目录不可用", groupId)
            ItemPaths[row] := folder.Path
            ItemFolderPaths[row] := folder.Path
            unavailableCount += 1
            groupId += 1
            continue
        }
        if state != "Pending" && !files.Length {
            if filterMode != "All"
                row := AddPlaceholderTile("没有符合筛选条件的文件", groupId)
            else
                row := AddPlaceholderTile("暂无文件", groupId)
            ItemPaths[row] := folder.Path
            ItemFolderPaths[row] := folder.Path
            groupId += 1
            continue
        }
        for file in files {
            displayName := GetDisplayName(file.Name, folder)
            modifiedText := FormatTime(file.Modified, "yyyy-MM-dd HH:mm")
            row := AddFileTile(file.Path, displayName, modifiedText, groupId)
            ItemPaths[row] := file.Path
            ItemFolderPaths[row] := folder.Path
            displayedCount += 1
        }
        groupId += 1
    }

    if !PinnedPaths.Length && !FolderSettings.Length {
        InsertListGroup(groupId, "提示")
        AddPlaceholderTile("请先打开 config.ini 配置文件夹", groupId)
    }

    ApplyViewMode()
    FileView.Opt("+Redraw")
    status := "共显示 " displayedCount " 个文件"
    if unavailableCount
        status .= "；" unavailableCount " 个目录不可用"
    if ConfigErrors.Length
        status .= "。配置有 " ConfigErrors.Length " 处问题"
    if !ScanResultLoaded
        status := "正在加载文件…"
    StatusKind := "default"
    StatusText.Text := status

    ; 在 GUI 完全更新后显示错误对话框
    if ConfigErrors.Length
        SetTimer(ShowConfigErrorDialog, -100)
}

InsertListGroup(groupId, header) {
    global FileView
    groupSize := A_PtrSize = 8 ? 152 : 96
    group := Buffer(groupSize, 0)
    NumPut("uint", groupSize, group, 0)
    NumPut("uint", 0x11, group, 4) ; LVGF_HEADER | LVGF_GROUPID
    NumPut("ptr", StrPtr(header), group, 8)
    NumPut("int", groupId, group, A_PtrSize = 8 ? 36 : 24)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1091,
        "ptr", -1, "ptr", group.Ptr, "ptr") ; LVM_INSERTGROUPW
}

SetListItemGroup(row, groupId) {
    global FileView
    item := Buffer(A_PtrSize = 8 ? 88 : 60, 0)
    NumPut("uint", 0x100, item, 0) ; LVIF_GROUPID
    NumPut("int", row - 1, item, 4)
    NumPut("int", groupId, item, A_PtrSize = 8 ? 52 : 40)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x104C,
        "ptr", 0, "ptr", item.Ptr, "ptr") ; LVM_SETITEMW
}

AddFileTile(path, label, modifiedText, groupId) {
    global FileView
    imageIndex := AddShellThumbnail(path)
    options := imageIndex ? "Icon" imageIndex : ""
    row := FileView.Add(options, label, modifiedText)
    SetListItemGroup(row, groupId)
    return row
}

AddPlaceholderTile(label, groupId) {
    global FileView
    row := FileView.Add("", label, "")
    SetListItemGroup(row, groupId)
    return row
}

AddShellThumbnail(path) {
    global ThumbnailSize, ThumbnailImageList, ThumbnailPolicy
    factory := 0
    bitmap := 0
    try {
        iidImageFactory := GuidBuffer("{BCC18B79-BA16-442F-80C4-8A59C30C463B}")
        if DllCall("shell32\SHCreateItemFromParsingName", "wstr", path, "ptr", 0,
            "ptr", iidImageFactory.Ptr, "ptr*", &factory) = 0 {
            requestedSize := (ThumbnailSize & 0xFFFFFFFF) | (ThumbnailSize << 32)
            ; SIIGBF_INCACHEONLY (0x10) prevents an uncached thumbnail from
            ; triggering synchronous decoding on the UI thread.
            imageFlags := 0x20 | (ThumbnailPolicy = "Fast" ? 0x10 : 0)
            try ComCall(3, factory, "int64", requestedSize, "uint", imageFlags,
                "ptr*", &bitmap)
        }
    } finally {
        if factory
            ObjRelease(factory)
    }

    if bitmap {
        imageIndex := DllCall("comctl32\ImageList_Add", "ptr", ThumbnailImageList,
            "ptr", bitmap, "ptr", 0, "int")
        DllCall("gdi32\DeleteObject", "ptr", bitmap)
        if imageIndex >= 0
            return imageIndex + 1
    }
    return AddShellFileIcon(path)
}

AddShellFileIcon(path) {
    global ThumbnailImageList
    infoSize := A_PtrSize = 8 ? 696 : 692
    info := Buffer(infoSize, 0)
    attributes := FileExist(path) ? 0 : 0x80 ; FILE_ATTRIBUTE_NORMAL
    flags := 0x100 ; SHGFI_ICON | SHGFI_LARGEICON
    if !FileExist(path)
        flags |= 0x10 ; SHGFI_USEFILEATTRIBUTES
    if !DllCall("shell32\SHGetFileInfoW", "wstr", path, "uint", attributes,
        "ptr", info.Ptr, "uint", infoSize, "uint", flags, "uptr")
        return 0
    icon := NumGet(info, 0, "ptr")
    if !icon
        return 0
    imageIndex := DllCall("comctl32\ImageList_ReplaceIcon", "ptr", ThumbnailImageList,
        "int", -1, "ptr", icon, "int")
    DllCall("user32\DestroyIcon", "ptr", icon)
    return imageIndex >= 0 ? imageIndex + 1 : 0
}

PopulateRecentSidebar() {
    global RecentView, RecentLabel, RecentItemPaths, ShowRecentSidebar, CurrentScanResult
    RecentView.Opt("-Redraw")
    RecentView.Delete()
    RecentItemPaths := Map()
    if !ShowRecentSidebar {
        RecentView.Opt("+Redraw")
        return
    }

    recentFiles := CurrentScanResult.Recent
    for file in recentFiles {
        row := RecentView.Add("", file.Name)
        RecentItemPaths[row] := file.Path
    }
    if !recentFiles.Length
        RecentView.Add("", "暂无系统近期记录")
    RecentLabel.Text := "最近打开  (" recentFiles.Length ")"
    RecentView.ModifyCol(1, 230)
    RecentView.Modify(0, "-Select -Focus")
    RecentView.Opt("+Redraw")
}

GetWindowsRecentFiles(limit) {
    recentDir := A_AppData "\Microsoft\Windows\Recent"
    links := []
    if !DirExist(recentDir)
        return links

    ; Keep extra shortcuts before resolving because stale Recent entries are
    ; common and should not consume visible slots.
    candidateLimit := Max(limit * 5, 60)
    try {
        Loop Files, recentDir "\*.lnk", "F" {
            candidate := {Path: A_LoopFileFullPath, Modified: A_LoopFileTimeModified}
            insertAt := 1
            while insertAt <= links.Length && links[insertAt].Modified >= candidate.Modified
                insertAt += 1
            links.InsertAt(insertAt, candidate)
            if links.Length > candidateLimit
                links.Pop()
        }
    }

    results := []
    seen := Map()
    try shell := ComObject("WScript.Shell")
    catch
        return results
    for link in links {
        try target := Trim(shell.CreateShortcut(link.Path).TargetPath)
        catch
            continue
        attributes := target != "" ? FileExist(target) : ""
        if !attributes || InStr(attributes, "D")
            continue
        key := StrLower(target)
        if seen.Has(key)
            continue
        seen[key] := true
        results.Push({Path: target, Name: GetFileName(target), Modified: link.Modified})
        if results.Length >= limit
            break
    }
    return results
}

GetSortedFiles(folderPath, limit, recursive, sortMode, filter?) {
    files := []
    try {
        mode := recursive ? "FR" : "F"
        Loop Files, folderPath "\*", mode {
            if IsSet(filter) && !ShouldIncludeFile(A_LoopFileName, filter)
                continue
            candidate := {
                Path: A_LoopFileFullPath,
                Name: A_LoopFileName,
                Modified: A_LoopFileTimeModified
            }
            if limit > 0 {
                ; 有界模式：保持排序的候选列表，超过时移除最不合适的
                insertAt := 1
                while insertAt <= files.Length
                    && CompareFiles(candidate, files[insertAt], sortMode) > 0
                    insertAt += 1
                files.InsertAt(insertAt, candidate)
                if files.Length > limit
                    files.Pop()
            } else {
                files.Push(candidate)
            }
        }
        ; 无限模式：收集完毕后统一排序
        if limit = 0 && files.Length > 0 {
            sorted := []
            for f in files {
                pos := 1
                while pos <= sorted.Length
                    && CompareFiles(f, sorted[pos], sortMode) > 0
                    pos += 1
                sorted.InsertAt(pos, f)
            }
            files := sorted
        }
    }
    return files
}

; ──── 自然排序 (StrCmpLogicalW) ────

StrCmpLogicalW(a, b) {
    result := DllCall("shlwapi\StrCmpLogicalW", "wstr", a, "wstr", b, "int")
    return result
}

CompareFiles(a, b, sortMode) {
    global SORT_MODIFIED_DESC, SORT_NAME_ASC

    if sortMode = SORT_NAME_ASC {
        cmp := StrCmpLogicalW(a.Name, b.Name)
        if cmp != 0
            return cmp
        ; 名称相同，按路径确定性排序
        return StrCompare(a.Path, b.Path, true)
    }

    ; ModifiedDesc
    if sortMode = SORT_MODIFIED_DESC {
        if a.Modified < b.Modified
            return 1
        if a.Modified > b.Modified
            return -1
        ; 修改时间相同，按自然文件名升序
        cmp := StrCmpLogicalW(a.Name, b.Name)
        if cmp != 0
            return cmp
        ; 仍相同，按路径确定性排序
        return StrCompare(a.Path, b.Path, true)
    }

    return 0
}

SortFileArray(&files, sortMode) {
    ; AHK v2.0 的 Array.Sort 不支持自定义比较函数。
    ; 使用稳定插入排序。对于 PopDrop 的文件数量（通常 < 1000）性能足够。
    if files.Length <= 1
        return
    sorted := []
    for f in files {
        insertAt := 1
        while insertAt <= sorted.Length
            && CompareFiles(f, sorted[insertAt], sortMode) > 0
            insertAt += 1
        sorted.InsertAt(insertAt, f)
    }
    files := sorted
}

CompareFilesForSort(sortMode, a, b) {
    return CompareFiles(a, b, sortMode)
}

; ──── 显示名称处理 ────

GetDisplayName(originalName, folder) {
    name := originalName

    ; 1. 如果 HideExtensions=1，移除最后一个扩展名
    if folder.HideExtensions {
        dotPos := InStr(name, ".",, -1) ; 从末尾搜索最后一个 .
        if dotPos > 1
            name := SubStr(name, 1, dotPos - 1)
    }

    ; 2. 如果 StripOrderPrefix=1，移除数字前缀（^\d+[ \t]+）
    if folder.StripOrderPrefix {
        name := RegExReplace(name, "^\d+[ \t]+")
    }

    ; 3. Trim
    name := Trim(name)

    ; 4. 如果结果为空，回退到原始名称
    if name = ""
        name := originalName

    return name
}

OpenFolderPath(folderPath) {
    if !DirExist(folderPath) {
        ShowPanelMsgBox("文件夹不存在或当前无法访问：`n" folderPath, "无法打开", "Icon!")
        return
    }
    try Run(folderPath)
    catch as err
        ShowPanelMsgBox("无法打开文件夹：`n" folderPath "`n`n" err.Message, "打开失败", "Iconx")
}

; ──── 后台扫描、缓存与 worker IPC ────

RunScanWorkerMode() {
    if A_Args.Length < 3
        return
    requestPath := A_Args[2]
    readyPath := A_Args[3]
    try {
        request := ReadWorkerRequest(requestPath)
        result := {Version: 2, Generation: request.Generation,
            Fingerprint: request.Fingerprint, Folders: [], Recent: []}
        for folder in request.Folders {
            state := DirExist(folder.Path) ? "OK" : "Unavailable"
            files := state = "OK" ? GetSortedFiles(folder.Path,
                folder.MaxFilesPerFolder, folder.IncludeSubfolders, folder.SortMode, folder.Filter) : []
            result.Folders.Push({Name: folder.Name, Path: folder.Path,
                State: state, Files: files})
        }
        result.Recent := GetWindowsRecentFiles(request.RecentFileCount)
        WriteScanResultAtomic(result, readyPath)
    } catch as err {
        try {
            logPath := A_ScriptDir "\worker-error.txt"
            FileAppend("Worker error at " A_Now "`n"
                . "  Message: " err.Message "`n"
                . "  What: " err.What "`n"
                . "  Extra: " err.Extra "`n"
                . "  File: " err.File "`n"
                . "  Line: " err.Line "`n`n", logPath)
        }
        try FileDelete(readyPath ".writing")
    }
}

ReadWorkerRequest(path) {
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    version := Integer(IniRead(path, "Meta", "Version", "0"))
    if version != 1 && version != 2
        throw Error("unsupported request version")
    request := {Generation: IniRead(path, "Meta", "Generation", ""),
        Fingerprint: IniRead(path, "Meta", "Fingerprint", ""), Folders: [],
        RecentFileCount: Integer(IniRead(path, "Meta", "RecentFileCount", "12"))}
    count := Integer(IniRead(path, "Meta", "FolderCount", "0"))
    Loop count {
        section := "Folder" Format("{:03}", A_Index)
        mode := StrLower(Trim(IniRead(path, section, "FilterMode", "All")))
        ext := IniRead(path, section, "FileExtensions", "")
        filter := ParseFilterSettings(mode, ext, "[" section "]")
        if HasProp(filter, "Error")
            throw Error(filter.Error)

        ; 读取 MaxFilesPerFolder（支持 0 = 无限）
        rawMax := IniRead(path, section, "MaxFilesPerFolder", "8")
        folderMax := 8
        if rawMax = "0" || StrLower(Trim(rawMax)) = "all"
            folderMax := 0
        else
            folderMax := Max(1, Min(Integer(rawMax), 999999))

        ; 读取 SortMode
        rawSort := StrLower(Trim(IniRead(path, section, "SortMode", "ModifiedDesc")))
        folderSort := SORT_MODIFIED_DESC
        if rawSort = StrLower(SORT_MODIFIED_DESC)
            folderSort := SORT_MODIFIED_DESC
        else if rawSort = StrLower(SORT_NAME_ASC)
            folderSort := SORT_NAME_ASC

        request.Folders.Push({
            Name: IniRead(path, section, "Name", ""),
            Path: IniRead(path, section, "Path", ""),
            IncludeSubfolders: IniRead(path, section, "IncludeSubfolders", "0") = "1",
            MaxFilesPerFolder: folderMax,
            SortMode: folderSort,
            Filter: filter
        })
    }
    return request
}

WriteScanResultAtomic(result, readyPath) {
    tempPath := readyPath ".writing"
    try FileDelete(tempPath)
    try FileDelete(readyPath)
    IniWrite("2", tempPath, "Meta", "Version")
    IniWrite(result.Generation, tempPath, "Meta", "Generation")
    IniWrite(result.Fingerprint, tempPath, "Meta", "Fingerprint")
    IniWrite(A_Now, tempPath, "Meta", "CompletedAt")
    IniWrite(result.Folders.Length, tempPath, "Meta", "FolderCount")
    IniWrite(result.Recent.Length, tempPath, "Meta", "RecentCount")
    for index, folder in result.Folders {
        section := "Folder" Format("{:03}", index)
        IniWrite(folder.Name, tempPath, section, "Name")
        IniWrite(folder.Path, tempPath, section, "Path")
        IniWrite(folder.State, tempPath, section, "State")
        IniWrite(folder.Files.Length, tempPath, section, "ItemCount")
        for itemIndex, item in folder.Files {
            key := "Item" Format("{:03}", itemIndex)
            IniWrite(item.Path, tempPath, section, key "Path")
            IniWrite(item.Name, tempPath, section, key "Name")
            IniWrite(item.Modified, tempPath, section, key "Modified")
        }
    }
    for index, item in result.Recent {
        section := "Recent" Format("{:03}", index)
        IniWrite(item.Path, tempPath, section, "Path")
        IniWrite(item.Name, tempPath, section, "Name")
        IniWrite(item.Modified, tempPath, section, "Modified")
    }
    FileMove(tempPath, readyPath, 1)
}

ResolveCacheDirectory(setting) {
    setting := NormalizePath(setting)
    return setting = "" ? A_ScriptDir "\cache" : setting
}

EnsureCacheDirectory(path) {
    try {
        if !DirExist(path)
            DirCreate(path)
        probe := path "\.write-test-" A_TickCount
        FileAppend("1", probe, "UTF-8")
        FileDelete(probe)
        return true
    } catch {
        return false
    }
}

ComputeConfigFingerprint(settings) {
    global RecentFileCount
    raw := "v2|recent=" RecentFileCount
    for folder in settings {
        raw .= "|" folder.Name "|" StrLower(RTrim(folder.Path, "\"))
        raw .= "|mode=" folder.Mode
        raw .= "|sub=" (folder.IncludeSubfolders ? 1 : 0)
        raw .= "|max=" folder.MaxFilesPerFolder "|sort=" folder.SortMode
        raw .= "|filter=" folder.Filter.Mode
        raw .= "|ext=" JoinArray(folder.Filter.Extensions, ",")
    }
    return HashString(raw)
}

HashString(text) {
    hash := 2166136261
    for char in StrSplit(text) {
        hash := (hash ^ Ord(char)) * 16777619
        hash := hash & 0xFFFFFFFF
    }
    return Format("{:08X}", hash)
}

LoadDiskScanCache() {
    global CacheFilePath, CurrentConfigFingerprint, CurrentScanResult, ScanResultLoaded
    if !FileExist(CacheFilePath)
        return false
    result := ReadScanResult(CacheFilePath, "", CurrentConfigFingerprint)
    if !IsObject(result)
        return false
    CurrentScanResult := result
    ScanResultLoaded := true
    return true
}

ReadScanResult(path, expectedGeneration := "", expectedFingerprint := "") {
    try {
        version := Integer(IniRead(path, "Meta", "Version", "0"))
        if version != 1 && version != 2
            return 0
        generation := IniRead(path, "Meta", "Generation", "")
        fingerprint := IniRead(path, "Meta", "Fingerprint", "")
        if expectedGeneration != "" && generation != expectedGeneration
            return 0
        if expectedFingerprint != "" && fingerprint != expectedFingerprint
            return 0
        result := {Version: version, Generation: generation, Fingerprint: fingerprint,
            Folders: [], Recent: []}
        folderCount := Integer(IniRead(path, "Meta", "FolderCount", "0"))
        if folderCount < 0 || folderCount > 1000
            return 0
        Loop folderCount {
            section := "Folder" Format("{:03}", A_Index)
            itemCount := Integer(IniRead(path, section, "ItemCount", "0"))
            folder := {Name: IniRead(path, section, "Name", ""),
                Path: IniRead(path, section, "Path", ""),
                State: IniRead(path, section, "State", "Unavailable"), Files: []}
            if folder.Path = "" || (folder.State != "OK" && folder.State != "Unavailable")
                return 0
            ; v1 cache had a 100-item limit. v2 allows any count.
            ; Keep a defensive sanity check against malicious/corrupt cache (10000).
            if itemCount < 0 || itemCount > 10000
                return 0
            Loop itemCount {
                key := "Item" Format("{:03}", A_Index)
                itemPath := IniRead(path, section, key "Path", "")
                if itemPath = ""
                    return 0
                folder.Files.Push({Path: itemPath,
                    Name: IniRead(path, section, key "Name", GetFileName(itemPath)),
                    Modified: IniRead(path, section, key "Modified", "")})
            }
            result.Folders.Push(folder)
        }
        recentCount := Integer(IniRead(path, "Meta", "RecentCount", "0"))
        if recentCount < 0 || recentCount > 1000
            return 0
        Loop recentCount {
            section := "Recent" Format("{:03}", A_Index)
            itemPath := IniRead(path, section, "Path", "")
            if itemPath != ""
                result.Recent.Push({Path: itemPath,
                    Name: IniRead(path, section, "Name", GetFileName(itemPath)),
                    Modified: IniRead(path, section, "Modified", "")})
        }
        return result
    } catch {
        return 0
    }
}

WriteScanRequest(path, generation) {
    global LastValidFolderSettings, CurrentConfigFingerprint, RecentFileCount
    try FileDelete(path)
    IniWrite("2", path, "Meta", "Version")
    IniWrite(generation, path, "Meta", "Generation")
    IniWrite(CurrentConfigFingerprint, path, "Meta", "Fingerprint")
    IniWrite(LastValidFolderSettings.Length, path, "Meta", "FolderCount")
    IniWrite(RecentFileCount, path, "Meta", "RecentFileCount")
    for index, folder in LastValidFolderSettings {
        section := "Folder" Format("{:03}", index)
        IniWrite(folder.Name, path, section, "Name")
        IniWrite(folder.Path, path, section, "Path")
        IniWrite(folder.IncludeSubfolders ? "1" : "0", path, section, "IncludeSubfolders")
        IniWrite(folder.MaxFilesPerFolder, path, section, "MaxFilesPerFolder")
        IniWrite(folder.SortMode, path, section, "SortMode")
        IniWrite(folder.Filter.Mode, path, section, "FilterMode")
        IniWrite(JoinArray(folder.Filter.Extensions, ","), path, section, "FileExtensions")
    }
}

QuoteCommandArg(value) {
    return '"' StrReplace(value, '"', '\"') '"'
}

BuildWorkerCommand(requestPath, readyPath) {
    if A_IsCompiled
        executable := QuoteCommandArg(A_ScriptFullPath)
    else
        executable := QuoteCommandArg(A_AhkPath) " " QuoteCommandArg(A_ScriptFullPath)
    return executable " --scan-worker " QuoteCommandArg(requestPath) " " QuoteCommandArg(readyPath)
}

StartBackgroundScan(force := false) {
    global WorkerRunning, PendingRefresh, ScanGeneration, WorkerGeneration
    global WorkerRequestPath, WorkerReadyPath, WorkerPid, CacheDir, CacheWritable
    if WorkerRunning {
        PendingRefresh := true
        return
    }
    ipcDir := CacheWritable ? CacheDir : A_Temp "\PopDrop"
    try DirCreate(ipcDir)
    generation := Format("{:016X}-{:08X}", A_TickCount, ++ScanGeneration)
    requestPath := ipcDir "\request-" generation ".ini"
    readyPath := ipcDir "\ready-" generation ".ini"
    try FileDelete(requestPath)
    try FileDelete(readyPath)
    try {
        WriteScanRequest(requestPath, generation)
        Run(BuildWorkerCommand(requestPath, readyPath), , "Hide", &WorkerPid)
    } catch {
        SetBackgroundStatus("更新失败，正在显示上次结果")
        return
    }
    WorkerRunning := true
    PendingRefresh := false
    WorkerGeneration := generation
    WorkerRequestPath := requestPath
    WorkerReadyPath := readyPath
    SetBackgroundStatus(ScanResultLoaded ? "正在更新" : "正在加载")
    SetTimer(PollWorkerResult, 100)
}

PollWorkerResult() {
    global WorkerRunning, WorkerPid, WorkerReadyPath, WorkerRequestPath, WorkerGeneration
    global PendingRefresh, CurrentConfigFingerprint, CurrentScanResult, ScanResultLoaded
    global CacheFilePath, CacheWritable, CacheWriteWarningShown
    if !WorkerRunning {
        SetTimer(PollWorkerResult, 0)
        return
    }
    if FileExist(WorkerReadyPath) {
        result := ReadScanResult(WorkerReadyPath, WorkerGeneration, CurrentConfigFingerprint)
        if IsObject(result) {
            changed := !ScanResultsEqual(CurrentScanResult, result)
            CurrentScanResult := result
            ScanResultLoaded := true
            if changed && IsObject(Panel) && PanelVisible {
                PopulatePanel()
                PopulateRecentSidebar()
                SetTimer(UpdateSelectionStatus, 0)
                StatusKind := "default"
            }
            if CacheWritable {
                try {
                    cacheTemp := CacheFilePath ".writing"
                    FileCopy(WorkerReadyPath, cacheTemp, 1)
                    FileMove(cacheTemp, CacheFilePath, 1)
                } catch {
                    CacheWritable := false
                }
            }
            if !CacheWritable && !CacheWriteWarningShown {
                CacheWriteWarningShown := true
                SetBackgroundStatus("无法保存缓存，本次将仅使用内存缓存")
            } else if changed
                SetBackgroundStatus("已更新", 500)
            else
                SetBackgroundStatus("已是最新", 200)
        } else {
            SetBackgroundStatus("更新失败，正在显示上次结果")
        }
        FinishWorker()
        return
    }
    if WorkerPid && !ProcessExist(WorkerPid) {
        SetBackgroundStatus("更新失败，正在显示上次结果")
        FinishWorker()
    }
}

FinishWorker() {
    global WorkerRunning, WorkerPid, WorkerRequestPath, WorkerReadyPath, PendingRefresh
    SetTimer(PollWorkerResult, 0)
    try FileDelete(WorkerRequestPath)
    try FileDelete(WorkerReadyPath)
    try FileDelete(WorkerReadyPath ".writing")
    WorkerRunning := false
    WorkerPid := 0
    if PendingRefresh {
        PendingRefresh := false
        SetTimer(StartPendingRefresh, -50)
    }
}

StartPendingRefresh() {
    StartBackgroundScan(true)
}

ScanResultsEqual(left, right) {
    return ResultSignature(left) = ResultSignature(right)
}

ResultSignature(result) {
    if !IsObject(result)
        return ""
    signature := ""
    for folder in result.Folders {
        signature .= "F|" folder.Path "|" folder.State "|"
        for item in folder.Files
            signature .= item.Path "@" item.Modified "|"
    }
    for item in result.Recent
        signature .= "R|" item.Path "@" item.Modified "|"
    return signature
}

FindFolderScanResult(results, folderPath, folderName := "", index := 0) {
    ; 优先使用索引匹配（worker 结果顺序与文件夹配置顺序一致）
    if index > 0 && index <= results.Length {
        result := results[index]
        ; 验证名称和路径都匹配
        if StrLower(result.Name) = StrLower(folderName)
            && StrLower(RTrim(result.Path, "\")) = StrLower(RTrim(folderPath, "\")) {
            return result
        }
    }

    ; 回退：Name + Path 联合匹配
    key := StrLower(RTrim(folderPath, "\"))
    for result in results {
        if StrLower(result.Name) = StrLower(folderName) {
            if StrLower(RTrim(result.Path, "\")) = key
                return result
        }
    }
    return 0
}

SetBackgroundStatus(text, duration := 0) {
    global StatusText, StatusKind, StatusTimerToken
    if !IsObject(StatusText) || StatusKind = "user"
        return
    StatusKind := "background"
    StatusText.Text := text
    if duration {
        token := ++StatusTimerToken
        SetTimer(() => RestoreDefaultStatus(token), -duration)
    }
}

RestoreDefaultStatus(token) {
    global StatusText, StatusKind, StatusTimerToken
    if token != StatusTimerToken || StatusKind = "user"
        return
    StatusKind := "default"
    if IsObject(StatusText)
        StatusText.Text := "已是最新"
}

GetFileName(path) {
    SplitPath(path, &name)
    return name != "" ? name : path
}

OpenFileViewItem(list, row) {
    global ItemPaths, ItemFolderPaths
    if !ItemPaths.Has(row)
        return
    path := ItemPaths[row]
    ; 占位行（目录路径本身）或目录 → 打开分组文件夹
    if ItemFolderPaths.Has(row) && DirExist(path) {
        OpenFolderPath(path)
        return
    }
    OpenFilePath(path)
}

OpenRecentItem(list, row) {
    global RecentItemPaths
    if RecentItemPaths.Has(row)
        OpenFilePath(RecentItemPaths[row])
}

OpenFilePath(path) {
    if !FileExist(path) {
        ShowPanelMsgBox("文件不存在或当前无法访问：`n" path, "无法打开", "Icon!")
        return
    }
    try Run(path)
    catch as err
        ShowPanelMsgBox("无法打开文件：`n" path "`n`n" err.Message, "打开失败", "Iconx")
}

RecentItemSelect(list, row, selected) {
    global RecentItemPaths, StatusText, StatusKind
    if selected && RecentItemPaths.Has(row) {
        StatusKind := "user"
        StatusText.Text := RecentItemPaths[row]
    }
}

RecentContextMenu(list, row, isRightClick, x, y) {
    global RecentItemPaths
    if !row || !RecentItemPaths.Has(row)
        return
    list.Modify(row, "Select Focus Vis")
    path := RecentItemPaths[row]
    if !FileExist(path) {
        ShowPanelMsgBox("文件不存在或当前无法访问：`n" path, "右键菜单", "Icon!")
        return
    }
    ShowShellContextMenu(path, list.Gui.Hwnd, x, y)
}

FileViewItemSelect(list, row, selected) {
    ; A range or marquee selection emits several ItemSelect events. Defer the
    ; summary until the control has finished updating the full selection.
    SetTimer(UpdateSelectionStatus, -1)
}

UpdateSelectionStatus() {
    global FileView, ItemPaths, StatusText, SelectedFilePaths, StatusKind
    selectedRows := GetSelectedFileRows()
    SelectedFilePaths := []
    for row in selectedRows
        SelectedFilePaths.Push(ItemPaths[row])
    if selectedRows.Length = 1 {
        StatusKind := "user"
        StatusText.Text := ItemPaths[selectedRows[1]]
    } else if selectedRows.Length > 1 {
        StatusKind := "user"
        StatusText.Text := "已选择 " selectedRows.Length " 个文件；可继续 Ctrl/Shift 选择。"
    } else if StatusKind = "user" {
        StatusKind := "default"
    }
}

GetSelectedFileRows() {
    global FileView, ItemPaths
    rows := []
    row := 0
    while row := FileView.GetNext(row) {
        if ItemPaths.Has(row)
            rows.Push(row)
    }
    return rows
}

AddPinnedFiles(*) {
    global PinnedPaths, Panel

    BeginAutoHidePause()
    try {
        if Panel && Panel.Hwnd
            Panel.Opt("+OwnDialogs")
        try selected := FileSelect("M3", , "选择要固定显示的文件")
        catch
            return
        if !IsObject(selected)
            return
    } finally {
        EndAutoHidePause()
    }

    added := 0
    for path in selected {
        path := NormalizePath(path)
        if path != "" && !ArrayContainsPath(PinnedPaths, path) {
            PinnedPaths.Push(path)
            added += 1
        }
    }
    if added {
        SavePinnedFiles()
        PopulatePanel()
    }
}

RemovePinnedFile(*) {
    global FileView, ItemPaths, PinnedPaths
    rows := GetSelectedFileRows()
    if !rows.Length {
        ShowPanelMsgBox("请先在“固定文件”分组中选择一个或多个文件。", "取消固定", "Iconi")
        return
    }

    indexes := []
    for row in rows {
        index := FindPathIndex(PinnedPaths, ItemPaths[row])
        if index
            indexes.Push(index)
    }
    if !indexes.Length {
        ShowPanelMsgBox("选择的文件中没有固定文件。", "取消固定", "Iconi")
        return
    }
    ; Remove from the end so earlier array indexes remain valid.
    Loop indexes.Length {
        largestPosition := 1
        for position, index in indexes {
            if index > indexes[largestPosition]
                largestPosition := position
        }
        PinnedPaths.RemoveAt(indexes[largestPosition])
        indexes.RemoveAt(largestPosition)
    }
    SavePinnedFiles()
    PopulatePanel()
}

SavePinnedFiles() {
    global ConfigPath, PinnedPaths
    try IniDelete(ConfigPath, "PinnedFiles")
    for index, path in PinnedPaths
        IniWrite(path, ConfigPath, "PinnedFiles", "File" Format("{:03}", index))
}

ArrayContainsPath(paths, target) {
    return FindPathIndex(paths, target) != 0
}

FindPathIndex(paths, target) {
    target := StrLower(RTrim(target, "\"))
    for index, path in paths {
        if StrLower(RTrim(path, "\")) = target
            return index
    }
    return 0
}

OpenConfig(*) {
    global ConfigPath
    try Run('notepad.exe "' ConfigPath '"')
    catch
        Run(ConfigPath)
}

FileViewNotify(wParam, lParam, msg, hwnd) {
    global FileView, GroupFolderPaths
    ; NMHDR structure: hwndFrom, idFrom, code
    if !IsSet(FileView) || !IsObject(FileView)
        return
    hwndFrom := NumGet(lParam + 0, "ptr")
    if hwndFrom != FileView.Hwnd
        return

    ; NMHDR structure: hwndFrom, idFrom, code
    code := NumGet(lParam + 0, A_PtrSize * 2, "int")
    ; LVN_GROUPHEADERCLICK = -150 (0xFFFFFF6A)
    if code != -150
        return

    ; NMLVGROUP: nmhdr (hwndFrom + idFrom + code), mask (4), iGroupId (4)
    ; NMHDR size = A_PtrSize * 2 + 4
    groupId := NumGet(lParam + A_PtrSize * 2 + 8, "int")
    if GroupFolderPaths.Has(groupId) {
        folderPath := GroupFolderPaths[groupId]
        if DirExist(folderPath)
            SetTimer(() => OpenFolderPath(folderPath), -10)
    }
}

FileViewContextMenu(list, row, isRightClick, x, y) {
    global ItemPaths
    if !row || !ItemPaths.Has(row)
        return
    list.Modify(row, "Select Focus Vis")
    path := ItemPaths[row]
    if !FileExist(path) {
        ShowPanelMsgBox("文件不存在或当前无法访问：`n" path, "右键菜单", "Icon!")
        return
    }
    ShowShellContextMenu(path, list.Gui.Hwnd, x, y)
}

ShowShellContextMenu(path, ownerHwnd, x, y) {
    pidl := 0
    parentFolder := 0
    contextMenu := 0
    menuHandle := 0

    BeginAutoHidePause()

    try {
        if DllCall("shell32\SHParseDisplayName", "wstr", path, "ptr", 0, "ptr*", &pidl,
            "uint", 0, "ptr", 0) != 0
            throw Error("Windows Shell 无法解析此文件。")

        iidShellFolder := GuidBuffer("{000214E6-0000-0000-C000-000000000046}")
        childPidl := 0
        if DllCall("shell32\SHBindToParent", "ptr", pidl, "ptr", iidShellFolder.Ptr,
            "ptr*", &parentFolder, "ptr*", &childPidl) != 0
            throw Error("无法连接文件所在目录。")

        iidContextMenu := GuidBuffer("{000214E4-0000-0000-C000-000000000046}")
        childArray := Buffer(A_PtrSize, 0)
        NumPut("ptr", childPidl, childArray)
        hr := ComCall(10, parentFolder, "ptr", ownerHwnd, "uint", 1, "ptr", childArray.Ptr,
            "ptr", iidContextMenu.Ptr, "ptr", 0, "ptr*", &contextMenu)
        if hr != 0
            throw Error("无法创建系统文件菜单。")

        menuHandle := DllCall("user32\CreatePopupMenu", "ptr")
        ; CMF_EXPLORE | CMF_EXTENDEDVERBS | CMF_SYNCCASCADEMENU exposes the
        ; complete classic menu and asks extensions to build cascades now.
        hr := ComCall(3, contextMenu, "ptr", menuHandle, "uint", 0, "uint", 1,
            "uint", 0x7FFF, "uint", 0x1104)
        if hr < 0
            throw Error("系统文件菜单加载失败。")

        if x = -1 || y = -1 {
            point := Buffer(8, 0)
            DllCall("user32\GetCursorPos", "ptr", point)
            x := NumGet(point, 0, "int")
            y := NumGet(point, 4, "int")
        } else {
            ; AutoHotkey supplies GUI-client coordinates; TrackPopupMenuEx
            ; requires screen coordinates.
            point := Buffer(8, 0)
            NumPut("int", x, point, 0)
            NumPut("int", y, point, 4)
            DllCall("user32\ClientToScreen", "ptr", ownerHwnd, "ptr", point)
            x := NumGet(point, 0, "int")
            y := NumGet(point, 4, "int")
        }
        DllCall("user32\SetForegroundWindow", "ptr", ownerHwnd)
        command := DllCall("user32\TrackPopupMenuEx", "ptr", menuHandle,
            "uint", 0x0102, "int", x, "int", y, "ptr", ownerHwnd, "ptr", 0, "uint")
        if command {
            ciSize := A_PtrSize = 8 ? 56 : 36
            invokeInfo := Buffer(ciSize, 0)
            NumPut("uint", ciSize, invokeInfo, 0)
            NumPut("ptr", ownerHwnd, invokeInfo, 8)
            NumPut("ptr", command - 1, invokeInfo, A_PtrSize = 8 ? 16 : 12)
            NumPut("int", 1, invokeInfo, A_PtrSize = 8 ? 40 : 24) ; SW_SHOWNORMAL
            ComCall(4, contextMenu, "ptr", invokeInfo.Ptr)
        }
        DllCall("user32\PostMessageW", "ptr", ownerHwnd, "uint", 0, "ptr", 0, "ptr", 0)
    } catch as err {
        ShowPanelMsgBox("无法显示系统右键菜单：`n" err.Message, "右键菜单", "Iconx")
    } finally {
        EndAutoHidePause()
        if menuHandle
            DllCall("user32\DestroyMenu", "ptr", menuHandle)
        if contextMenu
            ObjRelease(contextMenu)
        if parentFolder
            ObjRelease(parentFolder)
        if pidl
            DllCall("ole32\CoTaskMemFree", "ptr", pidl)
    }
}

GuidBuffer(text) {
    guid := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", text, "ptr", guid.Ptr) != 0
        throw Error("GUID 解析失败：" text)
    return guid
}

FileViewLeftButtonDown(wParam, lParam, msg, hwnd) {
    global FileView, RecentView, ItemPaths, RecentItemPaths
    global DragPaths, SelectedFilePaths, DragSourceHwnd, DragStartX, DragStartY, DragStarted
    isMainView := IsObject(FileView) && hwnd = FileView.Hwnd
    if isMainView
        pathMap := ItemPaths
    else if IsObject(RecentView) && hwnd = RecentView.Hwnd
        pathMap := RecentItemPaths
    else
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    hitInfo := Buffer(24, 0)
    NumPut("int", x, hitInfo, 0)
    NumPut("int", y, hitInfo, 4)
    zeroBasedRow := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1012, "ptr", 0, "ptr", hitInfo.Ptr, "int") ; LVM_HITTEST
    row := zeroBasedRow >= 0 ? zeroBasedRow + 1 : 0
    DragPaths := []
    if row && pathMap.Has(row) {
        ; WM_LBUTTONDOWN can collapse a multi-selection before a drag reaches
        ; its movement threshold. Use the snapshot saved after the preceding
        ; Ctrl/Shift/marquee selection instead of querying the live control.
        if isMainView && ArrayContainsPath(SelectedFilePaths, pathMap[row]) {
            DragPaths := SelectedFilePaths.Clone()
        } else {
            DragPaths.Push(pathMap[row])
        }
    }
    DragSourceHwnd := hwnd
    DragStartX := x
    DragStartY := y
    DragStarted := false
}

FileViewMouseMove(wParam, lParam, msg, hwnd) {
    global DragPaths, DragSourceHwnd, DragStartX, DragStartY, DragStarted, StatusText, StatusKind
    if !DragPaths.Length || DragStarted || hwnd != DragSourceHwnd || !GetKeyState("LButton", "P")
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    thresholdX := DllCall("user32\GetSystemMetrics", "int", 68, "int") ; SM_CXDRAG
    thresholdY := DllCall("user32\GetSystemMetrics", "int", 69, "int") ; SM_CYDRAG
    if Abs(x - DragStartX) < thresholdX && Abs(y - DragStartY) < thresholdY
        return

    DragStarted := true
    paths := DragPaths
    DragPaths := []
    existingPaths := []
    for path in paths {
        if FileExist(path) && !ArrayContainsPath(existingPaths, path)
            existingPaths.Push(path)
    }
    if existingPaths.Length {
        StatusKind := "user"
        StatusText.Text := "本次拖拽包含 " existingPaths.Length " 个文件。"
        DllCall("user32\UpdateWindow", "ptr", StatusText.Hwnd)
        BeginShellDrag(existingPaths, DragSourceHwnd)
    }
}

InitDropSource() {
    global DropVTable, DropCallbacks, DataVTable, DataCallbacks
    DropCallbacks := [
        CallbackCreate(DropQueryInterface, "Fast", 3),
        CallbackCreate(DropAddRef, "Fast", 1),
        CallbackCreate(DropRelease, "Fast", 1),
        CallbackCreate(DropQueryContinue, "Fast", 3),
        CallbackCreate(DropGiveFeedback, "Fast", 2)
    ]
    DropVTable := Buffer(5 * A_PtrSize, 0)
    for index, callbackPtr in DropCallbacks
        NumPut("ptr", callbackPtr, DropVTable, (index - 1) * A_PtrSize)

    ; Minimal IDataObject used for a multi-file CF_HDROP payload. Unlike an
    ; IShellFolder child array, CF_HDROP can contain paths from any number of
    ; directories and drives.
    DataCallbacks := [
        CallbackCreate(DataQueryInterface, "Fast", 3),
        CallbackCreate(DataAddRef, "Fast", 1),
        CallbackCreate(DataRelease, "Fast", 1),
        CallbackCreate(DataGetData, "Fast", 3),
        CallbackCreate(DataGetDataHere, "Fast", 3),
        CallbackCreate(DataQueryGetData, "Fast", 2),
        CallbackCreate(DataGetCanonicalFormatEtc, "Fast", 3),
        CallbackCreate(DataSetData, "Fast", 4),
        CallbackCreate(DataEnumFormatEtc, "Fast", 3),
        CallbackCreate(DataDAdvise, "Fast", 5),
        CallbackCreate(DataDUnadvise, "Fast", 2),
        CallbackCreate(DataEnumDAdvise, "Fast", 2)
    ]
    DataVTable := Buffer(12 * A_PtrSize, 0)
    for index, callbackPtr in DataCallbacks
        NumPut("ptr", callbackPtr, DataVTable, (index - 1) * A_PtrSize)
}

BeginShellDrag(paths, ownerHwnd) {
    BeginAutoHidePause()

    try {
        if paths.Length = 1
            BeginSingleShellDrag(paths[1], ownerHwnd)
        else
            BeginMultiShellDrag(paths, ownerHwnd)
    } finally {
        EndAutoHidePause()
    }
}

BeginSingleShellDrag(path, ownerHwnd) {
    global DropVTable
    fullPidl := 0
    parentFolder := 0
    dataObject := 0
    try {
        if DllCall("shell32\SHParseDisplayName", "wstr", path, "ptr", 0, "ptr*", &fullPidl,
            "uint", 0, "ptr", 0) != 0
            return

        ; ILCloneFull is an SDK macro rather than a reliably exported DLL
        ; function. Bind to the parent Shell folder and ask it directly for
        ; the file's IDataObject instead; this works across Windows 10/11.
        iidShellFolder := GuidBuffer("{000214E6-0000-0000-C000-000000000046}")
        childPidl := 0
        if DllCall("shell32\SHBindToParent", "ptr", fullPidl, "ptr", iidShellFolder.Ptr,
            "ptr*", &parentFolder, "ptr*", &childPidl) != 0
            return

        children := Buffer(A_PtrSize, 0)
        NumPut("ptr", childPidl, children)
        iidDataObject := GuidBuffer("{0000010E-0000-0000-C000-000000000046}")
        hr := ComCall(10, parentFolder, "ptr", ownerHwnd, "uint", 1,
            "ptr", children.Ptr, "ptr", iidDataObject.Ptr, "ptr", 0,
            "ptr*", &dataObject)
        if hr != 0 || !dataObject
            return

        dropSource := Buffer(A_PtrSize + 8, 0)
        NumPut("ptr", DropVTable.Ptr, dropSource, 0)
        NumPut("uint", 1, dropSource, A_PtrSize)
        effect := 0
        ; COPY | MOVE | LINK. The target application chooses the actual effect.
        DllCall("ole32\DoDragDrop", "ptr", dataObject, "ptr", dropSource.Ptr,
            "uint", 0x7, "uint*", &effect)
    } finally {
        if dataObject
            ObjRelease(dataObject)
        if parentFolder
            ObjRelease(parentFolder)
        if fullPidl
            DllCall("ole32\CoTaskMemFree", "ptr", fullPidl)
    }
}

BeginMultiShellDrag(paths, ownerHwnd) {
    global DropVTable, DataVTable, DragDataObjects
    dataObject := Buffer(A_PtrSize + 8, 0)
    NumPut("ptr", DataVTable.Ptr, dataObject, 0)
    NumPut("uint", 1, dataObject, A_PtrSize)
    ; Keep the backing Buffer alive for as long as any drop target retains an
    ; IDataObject reference (some targets finish transfer asynchronously).
    DragDataObjects[dataObject.Ptr] := {Memory: dataObject, Paths: paths}

    dropSource := Buffer(A_PtrSize + 8, 0)
    NumPut("ptr", DropVTable.Ptr, dropSource, 0)
    NumPut("uint", 1, dropSource, A_PtrSize)
    effect := 0
    try {
        ; COPY | MOVE | LINK. The target chooses the effect exactly as it does
        ; for a multi-file drag initiated by Explorer.
        DllCall("ole32\DoDragDrop", "ptr", dataObject.Ptr, "ptr", dropSource.Ptr,
            "uint", 0x7, "uint*", &effect)
    } finally {
        DataRelease(dataObject.Ptr)
    }
}

DataQueryInterface(this, iid, objectOut) {
    static iidUnknown := GuidBuffer("{00000000-0000-0000-C000-000000000046}")
    static iidDataObject := GuidBuffer("{0000010E-0000-0000-C000-000000000046}")
    if !GuidPointersEqual(iid, iidUnknown.Ptr) && !GuidPointersEqual(iid, iidDataObject.Ptr) {
        NumPut("ptr", 0, objectOut)
        return 0x80004002 ; E_NOINTERFACE
    }
    NumPut("ptr", this, objectOut)
    DataAddRef(this)
    return 0 ; S_OK
}

DataAddRef(this) {
    count := NumGet(this + A_PtrSize, "uint") + 1
    NumPut("uint", count, this + A_PtrSize)
    return count
}

DataRelease(this) {
    global DragDataObjects
    count := NumGet(this + A_PtrSize, "uint")
    if count
        count -= 1
    NumPut("uint", count, this + A_PtrSize)
    if !count && DragDataObjects.Has(this)
        DragDataObjects.Delete(this)
    return count
}

DataGetData(this, formatEtc, medium) {
    global DragDataObjects
    if !DragDataObjects.Has(this) || !IsHDropFormat(formatEtc)
        return 0x80040064 ; DV_E_FORMATETC

    hDrop := CreateHDrop(DragDataObjects[this].Paths)
    if !hDrop
        return 0x8007000E ; E_OUTOFMEMORY
    NumPut("uint", 1, medium, 0) ; TYMED_HGLOBAL
    unionOffset := A_PtrSize = 8 ? 8 : 4
    releaseOffset := A_PtrSize = 8 ? 16 : 8
    NumPut("ptr", hDrop, medium, unionOffset)
    NumPut("ptr", 0, medium, releaseOffset)
    return 0 ; S_OK; the recipient owns hDrop via ReleaseStgMedium
}

DataGetDataHere(this, formatEtc, medium) {
    return 0x80004001 ; E_NOTIMPL
}

DataQueryGetData(this, formatEtc) {
    return IsHDropFormat(formatEtc) ? 0 : 0x80040064 ; S_OK / DV_E_FORMATETC
}

DataGetCanonicalFormatEtc(this, formatIn, formatOut) {
    ptdOffset := A_PtrSize = 8 ? 8 : 4
    NumPut("ptr", 0, formatOut, ptdOffset)
    return 0x00040130 ; DATA_S_SAMEFORMATETC
}

DataSetData(this, formatEtc, medium, release) {
    return 0x80004001 ; E_NOTIMPL
}

DataEnumFormatEtc(this, direction, enumOut) {
    if direction != 1 { ; DATADIR_GET
        NumPut("ptr", 0, enumOut)
        return 0x80004001 ; E_NOTIMPL
    }
    formatSize := A_PtrSize = 8 ? 32 : 20
    formatEtc := Buffer(formatSize, 0)
    FillHDropFormat(formatEtc.Ptr)
    enumerator := 0
    hr := DllCall("shell32\SHCreateStdEnumFmtEtc", "uint", 1,
        "ptr", formatEtc.Ptr, "ptr*", &enumerator, "int")
    NumPut("ptr", enumerator, enumOut)
    return hr
}

DataDAdvise(this, formatEtc, flags, adviseSink, connectionOut) {
    if connectionOut
        NumPut("uint", 0, connectionOut)
    return 0x80040003 ; OLE_E_ADVISENOTSUPPORTED
}

DataDUnadvise(this, connection) {
    return 0x80040003 ; OLE_E_ADVISENOTSUPPORTED
}

DataEnumDAdvise(this, enumOut) {
    NumPut("ptr", 0, enumOut)
    return 0x80040003 ; OLE_E_ADVISENOTSUPPORTED
}

IsHDropFormat(formatEtc) {
    if !formatEtc
        return false
    aspectOffset := A_PtrSize = 8 ? 16 : 8
    indexOffset := A_PtrSize = 8 ? 20 : 12
    tymedOffset := A_PtrSize = 8 ? 24 : 16
    clipFormat := NumGet(formatEtc + 0, "ushort")
    aspect := NumGet(formatEtc + aspectOffset, "uint")
    itemIndex := NumGet(formatEtc + indexOffset, "int")
    supportedMediums := NumGet(formatEtc + tymedOffset, "uint")
    return clipFormat = 15 && aspect = 1 && itemIndex = -1
        && (supportedMediums & 1)
}

FillHDropFormat(formatEtc) {
    aspectOffset := A_PtrSize = 8 ? 16 : 8
    indexOffset := A_PtrSize = 8 ? 20 : 12
    tymedOffset := A_PtrSize = 8 ? 24 : 16
    NumPut("ushort", 15, formatEtc, 0) ; CF_HDROP
    NumPut("uint", 1, formatEtc, aspectOffset) ; DVASPECT_CONTENT
    NumPut("int", -1, formatEtc, indexOffset)
    NumPut("uint", 1, formatEtc, tymedOffset) ; TYMED_HGLOBAL
}

CreateHDrop(paths) {
    characterCount := 1 ; final extra NUL terminator
    for path in paths
        characterCount += StrLen(path) + 1
    byteCount := 20 + characterCount * 2 ; DROPFILES + UTF-16 path list
    hGlobal := DllCall("kernel32\GlobalAlloc", "uint", 0x0042,
        "uptr", byteCount, "ptr") ; GMEM_MOVEABLE | GMEM_ZEROINIT
    if !hGlobal
        return 0
    memory := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
    if !memory {
        DllCall("kernel32\GlobalFree", "ptr", hGlobal)
        return 0
    }

    NumPut("uint", 20, memory, 0) ; DROPFILES.pFiles
    NumPut("int", 1, memory, 16) ; DROPFILES.fWide
    cursor := memory + 20
    for path in paths {
        DllCall("kernel32\lstrcpyW", "ptr", cursor, "wstr", path)
        cursor += (StrLen(path) + 1) * 2
    }
    ; GMEM_ZEROINIT already supplies the second terminating NUL.
    DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
    ; Validate the packed list with the same Shell API used by drop targets.
    packedCount := DllCall("shell32\DragQueryFileW", "ptr", hGlobal,
        "uint", 0xFFFFFFFF, "ptr", 0, "uint", 0, "uint")
    if packedCount != paths.Length {
        DllCall("kernel32\GlobalFree", "ptr", hGlobal)
        return 0
    }
    return hGlobal
}

DropQueryInterface(this, iid, objectOut) {
    static iidUnknown := GuidBuffer("{00000000-0000-0000-C000-000000000046}")
    static iidDropSource := GuidBuffer("{00000121-0000-0000-C000-000000000046}")
    if !GuidPointersEqual(iid, iidUnknown.Ptr) && !GuidPointersEqual(iid, iidDropSource.Ptr) {
        NumPut("ptr", 0, objectOut)
        return 0x80004002 ; E_NOINTERFACE
    }
    NumPut("ptr", this, objectOut)
    DropAddRef(this)
    return 0 ; S_OK
}

GuidPointersEqual(left, right) {
    Loop 4 {
        offset := (A_Index - 1) * 4
        if NumGet(left + offset, "uint") != NumGet(right + offset, "uint")
            return false
    }
    return true
}

DropAddRef(this) {
    count := NumGet(this + A_PtrSize, "uint") + 1
    NumPut("uint", count, this + A_PtrSize)
    return count
}

DropRelease(this) {
    count := Max(0, NumGet(this + A_PtrSize, "uint") - 1)
    NumPut("uint", count, this + A_PtrSize)
    return count
}

DropQueryContinue(this, escapePressed, keyState) {
    if escapePressed
        return 0x00040101 ; DRAGDROP_S_CANCEL
    if !(keyState & 0x0001) ; MK_LBUTTON
        return 0x00040100 ; DRAGDROP_S_DROP
    return 0 ; S_OK
}

DropGiveFeedback(this, effect) {
    return 0x00040102 ; DRAGDROP_S_USEDEFAULTCURSORS
}

Cleanup(*) {
    global DropCallbacks, DataCallbacks, ThumbnailImageList, MainInstanceMutex
    for callbackPtr in DropCallbacks
        CallbackFree(callbackPtr)
    for callbackPtr in DataCallbacks
        CallbackFree(callbackPtr)
    if ThumbnailImageList
        DllCall("comctl32\ImageList_Destroy", "ptr", ThumbnailImageList)
    if MainInstanceMutex
        DllCall("kernel32\CloseHandle", "ptr", MainInstanceMutex)
    DllCall("ole32\OleUninitialize")
}
