#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off

;@Ahk2Exe-SetMainIcon assets\app.ico
;@Ahk2Exe-AddResource assets\tray.ico, 555
;@Ahk2Exe-SetVersion 0.8.0.0
;@Ahk2Exe-SetName PopDrop

; Worker processes must be routed before any GUI, hotkey, tray or COM setup.
;
; IMPORTANT: All constants that worker functions depend on must be defined
; before this block, because the worker calls ExitApp right after routing.

; ──── 排序模式常量 ────
global SORT_MODIFIED_DESC := "ModifiedDesc"
global SORT_NAME_ASC := "NameAsc"
global APP_VERSION := "0.8.8"
global CONFIG_VERSION := "12"

; ──── 文件夹模式常量 ────
global MODE_FILES := "Files"
global MODE_LAUNCHER := "Launcher"

; ──── v0.7 显示范围与文件夹时间 ────
global SCOPE_FILES_ONLY := "FilesOnly"
global SCOPE_FILES_AND_FOLDERS := "FilesAndFolders"
global SCOPE_RECURSIVE_FILES := "RecursiveFiles"
global FOLDER_TIME_MODIFIED := "DirectoryModified"
global FOLDER_TIME_LATEST_CONTENT := "LatestContent"
global NO_EXTENSION_TOKEN := "<none>"

; ──── 文件激活模式 ────
global OPEN_MODE_DOUBLE := "DoubleClick"
global OPEN_MODE_SINGLE := "SingleClick"
global SOURCE_OPEN_MODE_INHERIT := "Inherit"

; ──── 临时、锁定及系统文件过滤 ────
global NOISE_FILTER_INHERIT := "Inherit"
global NOISE_FILTER_ENABLED := "Enabled"
global NOISE_FILTER_DISABLED := "Disabled"
global NOISE_DIAGNOSTIC_LIMIT := 200

if A_Args.Length && A_Args[1] = "--self-test" {
    RunSelfTests()
    ExitApp
}

if A_Args.Length && A_Args[1] = "--scan-worker" {
    ; #NoTrayIcon 在脚本执行前生效，worker 从一开始就不会创建托盘图标。
    ; WinHide 作为解释器隐藏主窗口的第二层防护保留。
    try WinHide("ahk_id " A_ScriptHwnd)
    RunScanWorkerMode()
    ExitApp
}

; 只有主界面进程拥有托盘图标。必须在 worker 分流之后再打开，
; 才能消除启动和刷新时短命 worker 图标的一闪而过。
A_IconHidden := false

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
global WindowModeButton := 0
global PinnedDropButton := 0
global StatusText := 0
global TransferStatusText := 0
global ItemPaths := Map()
global ItemLabels := Map()
global ItemKinds := Map()
global ItemOpenContexts := Map()
global RecentItemPaths := Map()
global PinnedPaths := []
global FolderSettings := []
global MaxFilesPerFolder := 8
global IncludeSubfolders := false
global ThumbnailSize := 96
global ThumbnailHorizontalGap := 24
global ThumbnailVerticalGap := 4
global ThumbnailTextLines := 2
global ThumbnailImageList := 0
global WindowWidth := 980
global WindowHeight := 620
global ViewMode := "Thumbnail"
global ShowRecentSidebar := true
global RecentFileCount := 12
global ConfiguredHotkey := "F2"
global ActiveHotkey := ""
global PanelVisible := false
global DragPaths := []
global SelectedFilePaths := []
global DragSourceHwnd := 0
global DragStartX := 0
global DragStartY := 0
global DragStarted := false
global DragItemContexts := []
global ActiveInternalDragContext := 0
global PinnedReorderActive := false
global PinnedReorderPath := ""
global DropVTable := 0
global DropCallbacks := []
global DataVTable := 0
global DataCallbacks := []
global DragDataObjects := Map()
global DropTargetVTable := 0
global DropTargetCallbacks := []
global DropTargetObjects := Map()
global DropTargetRegisteredHwnds := Map()
global DropTargetRegistrationErrors := []
global ActiveDropSession := 0
global GroupDropTargets := Map()
global DropFolderValidationCache := Map()
global ActiveDropHighlightedGroup := 0
global PinnedDropDiscoveryActive := false
global ConfigErrors := []
global LastValidFolderSettings := []
global ConfigErrorsShown := false
global ThumbnailPolicy := "Full"
global CachePathSetting := ""
global CacheDir := ""
global CacheFilePath := ""
global CacheWritable := false
global CacheWriteWarningShown := false
global CurrentConfigFingerprint := ""
global CurrentScanResult := {
    Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
global ScanResultLoaded := false
global WorkerRunning := false
global WorkerPid := 0
global WorkerGeneration := ""
global WorkerRequestPath := ""
global WorkerReadyPath := ""
global PendingRefresh := false
global ScanGeneration := 0
global StatusKind := "default"
global StatusTimerToken := 0
global PanelIconHandle := 0
global OpenApps := []
global TransferFavorites := []
global TransferFavoriteLabels := Map()
global RecentTargets := []
global GlobalExcludedFolderNames := []
global GlobalNoiseFilter := {
    Enabled: true,
    HideHidden: true,
    HideSystem: true,
    HideTemporary: false,
    HideIncompleteDownloads: false,
    CustomPatterns: [],
    CustomPatternTexts: [],
    PatternErrors: []
}
global LastOpenProgramDir := ""
global LastTransferTargetDir := ""
global PendingViewRestore := 0
global PendingFileOperationRefresh := false
global FileOperationSinkVTable := 0
global FileOperationSinkCallbacks := []
global FileOperationSinks := Map()
global LastOpenAppUndoState := 0
global CurrentStatusAction := 0
global OpenAppsConfigNeedsMigration := false
global GlobalOpenFileMode := OPEN_MODE_DOUBLE
global SettingsDialog := 0
global EscapeHidesPanel := true

#Include ConfigDocument.ahk
#Include SettingsGui.ahk
#Include ExternalDrop.ahk

; ──── 单击激活手势和重复激活抑制 ────
global FilePointerGesture := 0
global FilePointerGestureSerial := 0
global LastPointerActivationKey := ""
global LastPointerActivationTick := 0

global SortMode := SORT_MODIFIED_DESC

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
ApplyWindowIcon()
ApplyWindowMode()
InstallHotkey(ConfiguredHotkey)
BuildTrayMenu()
InitDropSource()
InitDropTarget()
InitFileOperationProgressSink()
InitExternalDrop()
InstallPanelHotkeys()
OnMessage(0x0201, FileViewLeftButtonDown) ; WM_LBUTTONDOWN
OnMessage(0x0200, FileViewMouseMove)      ; WM_MOUSEMOVE
OnMessage(0x0202, FileViewLeftButtonUp)   ; WM_LBUTTONUP
OnMessage(0x0204, FileViewRightButtonDown) ; WM_RBUTTONDOWN
OnMessage(0x020A, FileViewCancelInteraction) ; WM_MOUSEWHEEL
OnMessage(0x020E, FileViewCancelInteraction) ; WM_MOUSEHWHEEL
OnMessage(0x0114, FileViewCancelInteraction) ; WM_HSCROLL
OnMessage(0x0115, FileViewCancelInteraction) ; WM_VSCROLL
OnMessage(0x001F, FileViewCancelMode)      ; WM_CANCELMODE
OnMessage(0x0215, FileViewCaptureChanged)  ; WM_CAPTURECHANGED
OnMessage(0x0008, FileViewKillFocus)       ; WM_KILLFOCUS
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

SelectPanelFile(options, rootDir := "", title := "", filter := "") {
    global Panel

    BeginAutoHidePause()
    try {
        ; +OwnDialogs is thread-local in AutoHotkey. Apply it immediately
        ; before FileSelect so an always-on-top panel cannot cover the picker.
        if IsObject(Panel)
            && DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int")
            Panel.Opt("+OwnDialogs")
        return FileSelect(options, rootDir, title, filter)
    } finally {
        EndAutoHidePause()
    }
}

EnsureConfig() {
    global ConfigPath, CONFIG_VERSION
    if FileExist(ConfigPath) {
        EnsureConfigEncoding()
        if ConfigLayoutNeedsNormalization()
            AtomicConfigEdit(NormalizeConfigDocument)
        return
    }

    defaultDesktop := GetKnownFolderPath(
        "{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}")
    if defaultDesktop = ""
        defaultDesktop := "%USERPROFILE%\Desktop"
    defaultDownloads := GetKnownFolderPath(
        "{374DE290-123F-4565-9164-39C4925E467B}")
    if defaultDownloads = ""
        defaultDownloads := "%USERPROFILE%\Downloads"

    defaultConfig :=
    (
    "; PopDrop 配置文件`n"
    "; 修改后，在面板中点“刷新”即可重新读取。`n"
    "`n"
    "; <PopDrop:area 1>`n"
    "[General]`n"
    "ConfigVersion=" CONFIG_VERSION "`n"
    "Hotkey=F2`n"
    "; DoubleClick（默认）| SingleClick`n"
    "OpenFileMode=DoubleClick`n"
    "EscapeHidesPanel=1`n"
    "MaxFilesPerFolder=8`n"
    "; FilesOnly | FilesAndFolders | RecursiveFiles`n"
    "DisplayScope=FilesOnly`n"
    "; DirectoryModified | LatestContent`n"
    "FolderTimeMode=DirectoryModified`n"
    "; v0.6 及更早版本兼容项；DisplayScope 存在时优先使用新配置`n"
    "IncludeSubfolders=0`n"
    "ThumbnailSize=96`n"
    "ThumbnailHorizontalGap=24`n"
    "ThumbnailVerticalGap=4`n"
    "ThumbnailTextLines=2`n"
    "WindowWidth=980`n"
    "WindowHeight=620`n"
    "ViewMode=Thumbnail`n"
    "ShowRecentSidebar=1`n"
    "RecentFileCount=12`n"
    "CachePath=`n"
    "ThumbnailPolicy=Full`n"
    "; 窗口模式：always_on_top（默认）| temporary（失焦自动隐藏）| normal（普通窗口）`n"
    "WindowMode=temporary`n"
    "; ModifiedDesc（默认，从新到旧）| NameAsc（文件名自然升序）`n"
    "SortMode=ModifiedDesc`n"
    "; All / Include / Exclude`n"
    "FilterMode=All`n"
    "FileExtensions=`n"
    "LastOpenProgramDir=`n"
    "LastTransferTargetDir=`n"
    "TransferFavoritesInitialized=1`n"
    "GlobalExcludedNamesInitialized=1`n"
    "`n"
    "[NoiseFilter]`n"
    "; <PopDrop:NoiseFilterHelp>`n"
    "; Enabled：总开关；1=排除噪音文件，0=全部显示。`n"
    "; HideHidden：是否排除具有 Hidden 属性的文件。`n"
    "; HideSystem：是否排除具有 System 属性的文件。`n"
    "; HideTemporaryAttribute：是否排除具有 Temporary 属性的文件。`n"
    "; HideIncompleteDownloads：是否排除 *.crdownload、*.part、*.download。`n"
    "; CustomPatternCount：下方 CustomPatternNNN 自定义文件名规则的数量。`n"
    "; 以上选项只影响 PopDrop 显示，不会删除、移动或修改真实文件。`n"
    "Enabled=1`n"
    "HideHidden=1`n"
    "HideSystem=1`n"
    "HideTemporaryAttribute=0`n"
    "HideIncompleteDownloads=0`n"
    "CustomPatternCount=0`n"
    "`n"
    "[ExternalTransfer]`n"
    "; 公开 URL 仅在没有本地文件、虚拟文件和图片数据时兜底`n"
    "EnablePublicUrlFallback=1`n"
    "; HTTP 默认关闭；HTTPS 始终要求有效 TLS 证书`n"
    "AllowHttp=0`n"
    "; 全局后台并发数，范围 1～6`n"
    "MaxConcurrent=3`n"
    "ShowCompletionNotifications=1`n"
    "`n"
    "; <PopDrop:area 2>`n"
    "[Folders]`n"
    "文档=%USERPROFILE%\Documents`n"
    "下载=D:\download`n"
    "`n"
    "[PinnedFiles]`n"
    "`n"
    "; <PopDrop:area 3>`n"
    "[Sources]`n"
    "Order=`n"
    "`n"
    "; <PopDrop:area 4>`n"
    "[OpenApps]`n"
    "; 顺序和稳定 ID，例如：Order=7zip,everedit`n"
    "; 详情保存在 [OpenApp:<ID>]；ID 建议只使用字母、数字、-、_`n"
    "Order=`n"
    "`n"
    "; <PopDrop:area 5>`n"
    "[TransferFavorites]`n"
    "Path001=" defaultDesktop "`n"
    "Path002=" defaultDownloads "`n"
    "; 删除上面任一 Path 行即可从常用位置移除；不会自动恢复`n"
    "; Path003=D:\Projects\Delivery`n"
    "`n"
    "[RecentTargets]`n"
    "`n"
    "; <PopDrop:area 6>`n"
    "[ExcludedFolderNames]`n"
    "Name001=.git`n"
    "Name002=.svn`n"
    "Name003=.hg`n"
    "Name004=node_modules`n"
    "Name005=__pycache__`n"
    )
    ; The layout-aware editor stores one UTF-16LE BOM and CRLF line endings.
    FileAppend(defaultConfig, ConfigPath, "UTF-16")
}

NormalizeConfigDocument(tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    EnsureNoiseFilterConfigComments(doc)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

ConfigLayoutNeedsNormalization() {
    global ConfigPath, CONFIG_VERSION
    doc := OpenPopDropConfig(ConfigPath)
    EnsureNoiseFilterConfigComments(doc)
    return doc.Dirty
        || doc.GetValue("General", "ConfigVersion", "") != CONFIG_VERSION
}

EnsureNoiseFilterConfigComments(doc) {
    doc.EnsureCommentBlock("NoiseFilter", "; <PopDrop:NoiseFilterHelp>", [
        "; Enabled：总开关；1=排除噪音文件，0=全部显示。",
        "; HideHidden：是否排除具有 Hidden 属性的文件。",
        "; HideSystem：是否排除具有 System 属性的文件。",
        "; HideTemporaryAttribute：是否排除具有 Temporary 属性的文件。",
        "; HideIncompleteDownloads：是否排除 *.crdownload、*.part、*.download。",
        "; CustomPatternCount：下方 CustomPatternNNN 自定义文件名规则的数量。",
        "; 以上选项只影响 PopDrop 显示，不会删除、移动或修改真实文件。"
    ], 1)
}

EnsureConfigEncoding() {
    global ConfigPath
    tempPath := ""
    try {
        rawBytes := FileRead(ConfigPath, "RAW")
        if rawBytes.Size >= 2 && NumGet(rawBytes, 0, "ushort") = 0xFEFF
            return
        contents := FileRead(ConfigPath, "UTF-8")
        tempPath := ConfigPath ".encoding-"
            . DllCall("kernel32\GetCurrentProcessId", "uint")
        try FileDelete(tempPath)
        output := FileOpen(tempPath, "w", "UTF-16")
        try output.Write(contents)
        finally output.Close()
        if !DllCall("kernel32\ReplaceFileW", "wstr", ConfigPath,
            "wstr", tempPath, "ptr", 0, "uint", 0x2,
            "ptr", 0, "ptr", 0, "int")
            throw OSError(A_LastError, "无法安全转换配置文件编码")
    } catch {
        if tempPath != ""
            try FileDelete(tempPath)
        throw
    }
}

LoadSettings(*) {
    global ConfigPath, ConfiguredHotkey, MaxFilesPerFolder
    global IncludeSubfolders, ThumbnailSize, ThumbnailHorizontalGap, ThumbnailVerticalGap
    global ThumbnailTextLines
    global FolderSettings, PinnedPaths
    global WindowWidth, WindowHeight, ViewMode, ShowRecentSidebar, RecentFileCount
    global ThumbnailPolicy, CachePathSetting, CacheDir, CacheFilePath, CacheWritable
    global CurrentConfigFingerprint, CurrentScanResult, ScanResultLoaded
    global ConfigErrors, LastValidFolderSettings
    global ConfigErrorsShown
    global WindowMode, WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY, WINDOW_MODE_NORMAL
    global SortMode, SORT_MODIFIED_DESC, SORT_NAME_ASC
    global MODE_FILES, MODE_LAUNCHER
    global SCOPE_FILES_ONLY, SCOPE_RECURSIVE_FILES, FOLDER_TIME_MODIFIED
    global OpenApps, TransferFavorites, TransferFavoriteLabels, RecentTargets
    global GlobalExcludedFolderNames, EscapeHidesPanel
    global LastOpenProgramDir, LastTransferTargetDir
    global OpenAppsConfigNeedsMigration
    global GlobalOpenFileMode, OPEN_MODE_DOUBLE
    global GlobalNoiseFilter, NOISE_FILTER_INHERIT

    settingErrors := []

    ConfiguredHotkey := Trim(IniRead(ConfigPath, "General", "Hotkey", "F2"))
    if ConfiguredHotkey = ""
        ConfiguredHotkey := "F2"

    ; 缺失、空值和未知值都必须保持旧版的双击行为。
    GlobalOpenFileMode := ParseGlobalOpenFileMode(
        IniRead(ConfigPath, "General", "OpenFileMode", OPEN_MODE_DOUBLE))
    EscapeHidesPanel := IniRead(
        ConfigPath, "General", "EscapeHidesPanel", "1") = "1"
    GlobalExcludedFolderNames := LoadGlobalExcludedFolderNames()
    GlobalNoiseFilter := LoadNoiseFilterConfig()
    LoadExternalTransferSettings()
    for patternError in GlobalNoiseFilter.PatternErrors
        settingErrors.Push(patternError)

    ; 读取窗口模式
    rawMode := StrLower(Trim(IniRead(ConfigPath, "General", "WindowMode", "temporary")))
    if rawMode = WINDOW_MODE_ALWAYS_ON_TOP || rawMode = WINDOW_MODE_TEMPORARY || rawMode = WINDOW_MODE_NORMAL {
        WindowMode := rawMode
    } else {
        WindowMode := WINDOW_MODE_TEMPORARY
        settingErrors.Push("WindowMode 配置值无效：" rawMode "，已使用默认模式 temporary。")
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
    try ThumbnailHorizontalGap := Integer(
        IniRead(ConfigPath, "General", "ThumbnailHorizontalGap", "24"))
    catch
        ThumbnailHorizontalGap := 24
    ThumbnailHorizontalGap := Max(0, Min(ThumbnailHorizontalGap, 128))
    try ThumbnailVerticalGap := Integer(
        IniRead(ConfigPath, "General", "ThumbnailVerticalGap", "4"))
    catch
        ThumbnailVerticalGap := 4
    ThumbnailVerticalGap := Max(0, Min(ThumbnailVerticalGap, 128))
    try ThumbnailTextLines := Integer(
        IniRead(ConfigPath, "General", "ThumbnailTextLines", "2"))
    catch
        ThumbnailTextLines := 2
    ThumbnailTextLines := Max(1, Min(ThumbnailTextLines, 2))

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

    ThumbnailPolicy := StrLower(Trim(IniRead(
        ConfigPath, "General", "ThumbnailPolicy", "Full"))) = "full"
        ? "Full" : "Fast"
    CachePathSetting := Trim(IniRead(ConfigPath, "General", "CachePath", ""))
    LastOpenProgramDir := NormalizePath(
        IniRead(ConfigPath, "General", "LastOpenProgramDir", ""))
    LastTransferTargetDir := NormalizePath(
        IniRead(ConfigPath, "General", "LastTransferTargetDir", ""))

    ; 读取全局排序模式
    rawSort := StrLower(Trim(IniRead(ConfigPath, "General", "SortMode", "ModifiedDesc")))
    if rawSort = StrLower(SORT_MODIFIED_DESC)
        SortMode := SORT_MODIFIED_DESC
    else if rawSort = StrLower(SORT_NAME_ASC)
        SortMode := SORT_NAME_ASC
    else
        SortMode := SORT_MODIFIED_DESC

    ; 读取文件夹列表
    FolderSettings := []
    for entry in ReadIniSection("Folders") {
        if entry.Value != ""
            FolderSettings.Push({Name: entry.Key, Path: NormalizePath(entry.Value)})
    }
    try MigrateOpenFileModeConfig(FolderSettings)
    catch as err
        settingErrors.Push("无法迁移文件打开方式配置：" err.Message)

    ; 验证并解析配置，得到每个文件夹的最终设置
    ConfigErrorsShown := false
    result := ValidateConfig()
    if result.Valid {
        LastValidFolderSettings := result.Settings
        ConfigErrors := settingErrors
    } else {
        ConfigErrors := settingErrors.Clone()
        for errorMessage in result.Errors
            ConfigErrors.Push(errorMessage)
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
                    DisplayScope: IncludeSubfolders ? SCOPE_RECURSIVE_FILES : SCOPE_FILES_ONLY,
                    FolderTimeMode: FOLDER_TIME_MODIFIED,
                    MaxFilesPerFolder: MaxFilesPerFolder,
                    SortMode: SortMode,
                    Filter: {Mode: "All", Extensions: []},
                    StripOrderPrefix: 0,
                    HideExtensions: 0,
                    SourceId: ResolveFolderSourceId(f.Name, f.Path),
                    OpenFileMode: "Inherit",
                    NoiseFilterMode: NOISE_FILTER_INHERIT,
                    NoiseFilter: ResolveNoiseFilterForSource(
                        NOISE_FILTER_INHERIT, []),
                    SourceCustomPatternTexts: [],
                    ExcludedPaths: [],
                    AllowedExcludedPaths: []
                })
            }
        }
    }

    PinnedPaths := []
    for entry in ReadIniSection("PinnedFiles") {
        path := NormalizePath(entry.Value)
        if path != "" && !ArrayContainsPath(PinnedPaths, path)
            PinnedPaths.Push(path)
    }

    CacheDir := ResolveCacheDirectory(CachePathSetting)
    CacheFilePath := CacheDir "\scan-cache-v3.ini"
    CacheWritable := EnsureCacheDirectory(CacheDir)
    newFingerprint := ComputeConfigFingerprint(LastValidFolderSettings)
    if CurrentConfigFingerprint != newFingerprint {
        CurrentConfigFingerprint := newFingerprint
        CurrentScanResult := {
            Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
        ScanResultLoaded := false
    }

    OpenApps := LoadOpenApps()
    if OpenAppsConfigNeedsMigration {
        try {
            SaveOpenApps()
            OpenAppsConfigNeedsMigration := false
        } catch as err {
            message := "无法把旧版软件列表迁移到简化格式：" err.Message
            ConfigErrors.Push(message)
        }
    }
    TransferFavorites := LoadTransferFavorites(settingErrors)
    TransferFavoriteLabels := LoadTransferFavoriteLabels(TransferFavorites)
    RecentTargets := LoadPathListSection("RecentTargets", 3)
}

; ──── 配置验证与筛选函数 ────

ParseGlobalOpenFileMode(raw) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE
    value := StrLower(Trim(raw))
    if value = StrLower(OPEN_MODE_SINGLE)
        return OPEN_MODE_SINGLE
    if value = StrLower(OPEN_MODE_DOUBLE)
        return OPEN_MODE_DOUBLE
    return OPEN_MODE_DOUBLE
}

IsRecognizedGlobalOpenFileMode(raw) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE
    value := StrLower(Trim(raw))
    return value = StrLower(OPEN_MODE_DOUBLE)
        || value = StrLower(OPEN_MODE_SINGLE)
}

ParseSourceOpenFileMode(raw) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, SOURCE_OPEN_MODE_INHERIT
    value := StrLower(Trim(raw))
    if value = StrLower(OPEN_MODE_SINGLE)
        return OPEN_MODE_SINGLE
    if value = StrLower(OPEN_MODE_DOUBLE)
        return OPEN_MODE_DOUBLE
    if value = StrLower(SOURCE_OPEN_MODE_INHERIT)
        return SOURCE_OPEN_MODE_INHERIT
    return SOURCE_OPEN_MODE_INHERIT
}

IsRecognizedSourceOpenFileMode(raw) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, SOURCE_OPEN_MODE_INHERIT
    value := StrLower(Trim(raw))
    return value = StrLower(OPEN_MODE_DOUBLE)
        || value = StrLower(OPEN_MODE_SINGLE)
        || value = StrLower(SOURCE_OPEN_MODE_INHERIT)
}

IsSafeSourceId(id) {
    id := Trim(id)
    return id != "" && !RegExMatch(id, "[,\[\]=`r`n]")
}

ParseSourceIdOrder(raw) {
    result := []
    seen := Map()
    for part in StrSplit(raw, ",") {
        id := Trim(part)
        key := StrLower(id)
        if !IsSafeSourceId(id) || seen.Has(key)
            continue
        seen[key] := true
        result.Push(id)
    }
    return result
}

ResolveFolderSourceId(name, path) {
    global ConfigPath
    folderSection := "Folder:" name
    sourceId := Trim(IniRead(ConfigPath, folderSection, "SourceId", ""))
    if IsSafeSourceId(sourceId)
        return sourceId

    sourceIds := ParseSourceIdOrder(
        IniRead(ConfigPath, "Sources", "Order", ""))
    normalizedKey := PathKey(path)

    ; 显示名未改变时优先保持身份，路径修改不会丢失来源设置。
    for id in sourceIds {
        section := "Source:" id
        storedName := Trim(IniRead(ConfigPath, section, "Name", ""))
        if storedName != "" && StrLower(storedName) = StrLower(name)
            return id
    }
    ; 显示名修改时再用规范化路径恢复身份。
    for id in sourceIds {
        section := "Source:" id
        storedPath := NormalizePath(IniRead(ConfigPath, section, "Path", ""))
        if storedPath != "" && PathKey(storedPath) = normalizedKey
            return id
    }

    ; 旧配置无需立即写回；首次从设置窗口保存时持久化此稳定 ID。
    return "source-" HashString(StrLower(name) "|" normalizedKey)
}

ReadFolderOpenFileMode(name, sourceId) {
    global ConfigPath, SOURCE_OPEN_MODE_INHERIT
    raw := IniRead(ConfigPath, "Folder:" name, "OpenFileMode", "")
    if Trim(raw) = ""
        raw := IsSafeSourceId(sourceId)
            ? IniRead(ConfigPath, "Source:" sourceId, "OpenFileMode",
                SOURCE_OPEN_MODE_INHERIT)
            : SOURCE_OPEN_MODE_INHERIT
    return ParseSourceOpenFileMode(raw)
}

MigrateOpenFileModeConfig(folders) {
    global ConfigPath, OPEN_MODE_DOUBLE

    rawGlobal := IniRead(ConfigPath, "General", "OpenFileMode", "")
    try configVersion := Integer(
        IniRead(ConfigPath, "General", "ConfigVersion", "0"))
    catch
        configVersion := 0
    needsMigration := configVersion < 8
        || !IsRecognizedGlobalOpenFileMode(rawGlobal)
    entries := []
    seen := Map()
    configuredIds := ParseSourceIdOrder(
        IniRead(ConfigPath, "Sources", "Order", ""))

    for folder in folders {
        sourceId := MakeUniqueSourceId(
            ResolveFolderSourceId(folder.Name, folder.Path), seen)
        rawFolderId := Trim(IniRead(ConfigPath,
            "Folder:" folder.Name, "SourceId", ""))
        rawMode := IniRead(ConfigPath, "Folder:" folder.Name,
            "OpenFileMode", "")
        if Trim(rawMode) = ""
            rawMode := IniRead(ConfigPath, "Source:" sourceId,
                "OpenFileMode", "")
        storedName := Trim(IniRead(ConfigPath,
            "Source:" sourceId, "Name", ""))
        storedPath := NormalizePath(IniRead(ConfigPath,
            "Source:" sourceId, "Path", ""))
        if rawFolderId != sourceId
            || !IsRecognizedSourceOpenFileMode(rawMode)
            || !ArrayContainsTextInsensitive(configuredIds, sourceId)
            || storedName != folder.Name
            || !PathsEqual(storedPath, folder.Path)
            needsMigration := true
        entries.Push({
            Id: sourceId,
            Name: folder.Name,
            Path: folder.Path,
            Mode: ParseSourceOpenFileMode(rawMode)
        })
    }
    if needsMigration
        AtomicConfigEdit(WriteOpenFileModeSettings.Bind(
            ParseGlobalOpenFileMode(rawGlobal), entries))
}

ValidateConfig() {
    global ConfigPath, ConfigErrors, FolderSettings
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    global MODE_FILES, MODE_LAUNCHER
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    global NOISE_FILTER_INHERIT

    errors := []
    tempGlobalFilter := {Mode: "All", Extensions: []}
    tempGlobalMaxFiles := 8
    tempGlobalIncludeSubfolders := false
    tempGlobalDisplayScope := SCOPE_FILES_ONLY
    tempGlobalFolderTimeMode := FOLDER_TIME_MODIFIED
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
    rawScope := StrLower(Trim(IniRead(ConfigPath, "General", "DisplayScope", "")))
    if rawScope = ""
        tempGlobalDisplayScope := tempGlobalIncludeSubfolders
            ? SCOPE_RECURSIVE_FILES : SCOPE_FILES_ONLY
    else if rawScope = StrLower(SCOPE_FILES_ONLY)
        tempGlobalDisplayScope := SCOPE_FILES_ONLY
    else if rawScope = StrLower(SCOPE_FILES_AND_FOLDERS)
        tempGlobalDisplayScope := SCOPE_FILES_AND_FOLDERS
    else if rawScope = StrLower(SCOPE_RECURSIVE_FILES)
        tempGlobalDisplayScope := SCOPE_RECURSIVE_FILES
    else
        errors.Push("[General] 中 DisplayScope 值无效：" rawScope
            "。允许的值：FilesOnly, FilesAndFolders, RecursiveFiles。")
    tempGlobalIncludeSubfolders := tempGlobalDisplayScope = SCOPE_RECURSIVE_FILES

    rawFolderTime := StrLower(Trim(
        IniRead(ConfigPath, "General", "FolderTimeMode", "DirectoryModified")))
    if rawFolderTime = StrLower(FOLDER_TIME_MODIFIED)
        tempGlobalFolderTimeMode := FOLDER_TIME_MODIFIED
    else if rawFolderTime = StrLower(FOLDER_TIME_LATEST_CONTENT)
        tempGlobalFolderTimeMode := FOLDER_TIME_LATEST_CONTENT
    else
        errors.Push("[General] 中 FolderTimeMode 值无效：" rawFolderTime
            "。允许的值：DirectoryModified, LatestContent。")

    ; ── 解析每个文件夹的独立配置 ──
    resolved := []
    sourceIdsSeen := Map()
    for f in FolderSettings {
        sectionName := "Folder:" f.Name
        sourceId := MakeUniqueSourceId(
            ResolveFolderSourceId(f.Name, f.Path), sourceIdsSeen)
        folderOpenFileMode := ReadFolderOpenFileMode(f.Name, sourceId)

        ; 读取该文件夹的独立配置节
        folderMax := tempGlobalMaxFiles
        folderRecursive := tempGlobalIncludeSubfolders
        folderDisplayScope := tempGlobalDisplayScope
        folderTimeMode := tempGlobalFolderTimeMode
        folderFilter := {Mode: tempGlobalFilter.Mode, Extensions: tempGlobalFilter.Extensions}
        folderSortMode := tempGlobalSortMode
        folderMode := MODE_FILES
        folderStripOrderPrefix := 0
        folderHideExtensions := 0
        folderNoiseFilterMode := NOISE_FILTER_INHERIT
        sourcePatternTexts := LoadIgnorePatternTexts("SourceIgnore:" sourceId)
        legacySubfolderOverride := false

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
                folderDisplayScope := SCOPE_FILES_ONLY
                folderMax := 0  ; 0 = 无限
                folderSortMode := SORT_NAME_ASC
                folderFilter := {Mode: "Include", Extensions: [".lnk", ".url", ".exe"]}
                folderStripOrderPrefix := 1
                folderHideExtensions := 1
            }

            ; ── 读取 MaxFilesPerFolder ──
            rawVal := ""
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
                    legacySubfolderOverride := true
                    if val = "1"
                        folderRecursive := true
                    else if val = "0"
                        folderRecursive := false
                    else
                        errors.Push("[" sectionName "] 中 IncludeSubfolders 只能为 0 或 1，实际值为：" val "。")
                }
            }

            ; DisplayScope 是 v0.7 的权威配置；缺失时迁移旧 IncludeSubfolders 语义。
            try {
                val := StrLower(Trim(IniRead(ConfigPath, sectionName, "DisplayScope", "")))
                if val != "" {
                    if val = StrLower(SCOPE_FILES_ONLY)
                        folderDisplayScope := SCOPE_FILES_ONLY
                    else if val = StrLower(SCOPE_FILES_AND_FOLDERS)
                        folderDisplayScope := SCOPE_FILES_AND_FOLDERS
                    else if val = StrLower(SCOPE_RECURSIVE_FILES)
                        folderDisplayScope := SCOPE_RECURSIVE_FILES
                    else
                        errors.Push("[" sectionName "] 中 DisplayScope 值无效：" val "。")
                } else {
                    if legacySubfolderOverride
                        folderDisplayScope := folderRecursive
                            ? SCOPE_RECURSIVE_FILES : SCOPE_FILES_ONLY
                }
                folderRecursive := folderDisplayScope = SCOPE_RECURSIVE_FILES
            }

            try {
                val := StrLower(Trim(IniRead(ConfigPath, sectionName, "FolderTimeMode", "")))
                if val != "" {
                    if val = StrLower(FOLDER_TIME_MODIFIED)
                        folderTimeMode := FOLDER_TIME_MODIFIED
                    else if val = StrLower(FOLDER_TIME_LATEST_CONTENT)
                        folderTimeMode := FOLDER_TIME_LATEST_CONTENT
                    else if val = "inherit"
                        folderTimeMode := tempGlobalFolderTimeMode
                    else
                        errors.Push("[" sectionName "] 中 FolderTimeMode 值无效：" val "。")
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

        rawNoiseMode := IniRead(ConfigPath, sectionName, "NoiseFilterMode", "")
        if Trim(rawNoiseMode) = ""
            rawNoiseMode := IniRead(ConfigPath, "Source:" sourceId,
                "NoiseFilterMode", NOISE_FILTER_INHERIT)
        if !IsRecognizedNoiseFilterMode(rawNoiseMode)
            errors.Push("[" sectionName "] 中 NoiseFilterMode 值无效："
                rawNoiseMode "。允许的值：Inherit, Enabled, Disabled。")
        folderNoiseFilterMode := ParseNoiseFilterMode(rawNoiseMode)
        resolvedNoiseFilter := ResolveNoiseFilterForSource(
            folderNoiseFilterMode, sourcePatternTexts)
        for patternError in resolvedNoiseFilter.PatternErrors
            errors.Push("来源“" f.Name "”" patternError)

        resolved.Push({
            Name: f.Name,
            Path: f.Path,
            Mode: folderMode,
            IncludeSubfolders: folderRecursive,
            DisplayScope: folderDisplayScope,
            FolderTimeMode: folderTimeMode,
            MaxFilesPerFolder: folderMax,
            SortMode: folderSortMode,
            Filter: folderFilter,
            StripOrderPrefix: folderStripOrderPrefix,
            HideExtensions: folderHideExtensions,
            SourceId: sourceId,
            OpenFileMode: folderOpenFileMode,
            NoiseFilterMode: folderNoiseFilterMode,
            NoiseFilter: resolvedNoiseFilter,
            SourceCustomPatternTexts: sourcePatternTexts,
            ExcludedPaths: LoadConfiguredSourcePaths(
                "SourceExclude:" sourceId, f.Path),
            AllowedExcludedPaths: LoadConfiguredSourcePaths(
                "SourceAllow:" sourceId, f.Path)
        })
    }

    ; ── 检查 [Folder:xxx] 节是否对应存在的文件夹 ──
    knownNames := Map()
    activeSourceIds := Map()
    for f in FolderSettings
        knownNames[f.Name] := true
    for folder in resolved
        activeSourceIds[StrLower(folder.SourceId)] := true
    try {
        Loop Read, ConfigPath {
            if RegExMatch(A_LoopReadLine, "i)^\[Folder:(.+)\]$", &m) {
                folderName := m[1]
                if !knownNames.Has(folderName) {
                    legacySourceId := Trim(IniRead(ConfigPath,
                        "Folder:" folderName, "SourceId", ""))
                    if IsSafeSourceId(legacySourceId)
                        && activeSourceIds.Has(StrLower(legacySourceId))
                        continue
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

MakeUniqueSourceId(sourceId, seen) {
    base := sourceId
    candidate := base
    suffix := 2
    while seen.Has(StrLower(candidate)) {
        candidate := base "-" suffix
        suffix += 1
    }
    seen[StrLower(candidate)] := true
    return candidate
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

LoadNoiseFilterConfig() {
    patternTexts := LoadIgnorePatternTexts("NoiseFilter")
    compiled := CompileIgnorePatterns(patternTexts, "[NoiseFilter]")
    return {
        Enabled: ReadConfigBoolean("NoiseFilter", "Enabled", true),
        HideHidden: ReadConfigBoolean("NoiseFilter", "HideHidden", true),
        HideSystem: ReadConfigBoolean("NoiseFilter", "HideSystem", true),
        HideTemporary: ReadConfigBoolean("NoiseFilter", "HideTemporaryAttribute", false),
        HideIncompleteDownloads: ReadConfigBoolean("NoiseFilter", "HideIncompleteDownloads", false),
        CustomPatterns: compiled.Patterns,
        CustomPatternTexts: compiled.Texts,
        PatternErrors: compiled.Errors
    }
}

ReadConfigBoolean(section, key, defaultValue) {
    global ConfigPath
    raw := Trim(IniRead(ConfigPath, section, key, defaultValue ? "1" : "0"))
    if raw = "1"
        return true
    if raw = "0"
        return false
    return defaultValue
}

LoadIgnorePatternTexts(section) {
    result := []
    for entry in ReadIniSection(section) {
        if RegExMatch(entry.Key, "i)^(?:Custom)?Pattern\d+$")
            result.Push(entry.Value)
    }
    return NormalizeIgnorePatternTexts(result)
}

NormalizeIgnorePatternTextBlock(text) {
    text := StrReplace(text, "`r`n", "`n")
    text := StrReplace(text, "`r", "`n")
    return NormalizeIgnorePatternTexts(StrSplit(text, "`n"))
}

NormalizeIgnorePatternTexts(values) {
    result := []
    seen := Map()
    for value in values {
        pattern := Trim(value)
        folded := StrLower(pattern)
        if pattern = "" || seen.Has(folded)
            continue
        seen[folded] := true
        result.Push(pattern)
    }
    return result
}

CompileIgnorePatterns(patternTexts, context := "") {
    result := []
    texts := []
    errors := []
    for pattern in NormalizeIgnorePatternTexts(patternTexts) {
        regex := WildcardPatternToRegex(pattern)
        if regex = "" {
            errors.Push((context != "" ? context " " : "")
                . "中的忽略规则无法编译，已跳过：" pattern)
            continue
        }
        result.Push({Text: pattern, Regex: regex})
        texts.Push(pattern)
    }
    return {Patterns: result, Texts: texts, Errors: errors}
}

WildcardPatternToRegex(pattern) {
    regex := "i)^"
    special := "\.^$|()[]{}+"
    for char in StrSplit(pattern) {
        if char = "*"
            regex .= ".*"
        else if char = "?"
            regex .= "."
        else {
            if InStr(special, char)
                regex .= "\"
            regex .= char
        }
    }
    regex .= "$"
    try {
        RegExMatch("", regex)
        return regex
    } catch {
        return ""
    }
}

ParseNoiseFilterMode(raw) {
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    folded := StrLower(Trim(raw))
    if folded = StrLower(NOISE_FILTER_ENABLED)
        return NOISE_FILTER_ENABLED
    if folded = StrLower(NOISE_FILTER_DISABLED)
        return NOISE_FILTER_DISABLED
    return NOISE_FILTER_INHERIT
}

IsRecognizedNoiseFilterMode(raw) {
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    folded := StrLower(Trim(raw))
    return folded = StrLower(NOISE_FILTER_INHERIT)
        || folded = StrLower(NOISE_FILTER_ENABLED)
        || folded = StrLower(NOISE_FILTER_DISABLED)
}

ResolveNoiseFilterForSource(mode, sourcePatternTexts) {
    global GlobalNoiseFilter, NOISE_FILTER_DISABLED, NOISE_FILTER_ENABLED
    enabled := mode = NOISE_FILTER_ENABLED
        || (mode != NOISE_FILTER_DISABLED && GlobalNoiseFilter.Enabled)
    sourceCompiled := CompileIgnorePatterns(sourcePatternTexts, "来源附加规则")
    return {
        Enabled: enabled,
        HideHidden: GlobalNoiseFilter.HideHidden,
        HideSystem: GlobalNoiseFilter.HideSystem,
        HideTemporary: GlobalNoiseFilter.HideTemporary,
        HideIncompleteDownloads: GlobalNoiseFilter.HideIncompleteDownloads,
        CustomPatterns: GlobalNoiseFilter.CustomPatterns,
        SourceCustomPatterns: sourceCompiled.Patterns,
        PatternErrors: sourceCompiled.Errors
    }
}

HasDangerousIgnorePattern(patternTexts) {
    for pattern in patternTexts {
        folded := StrLower(Trim(pattern))
        if folded = "*" || folded = "*.*"
            return true
    }
    return false
}

GetFileExtensionType(path) {
    global NO_EXTENSION_TOKEN
    SplitPath(path, &name, , &extension)
    if extension = ""
        return NO_EXTENSION_TOKEN
    return "." StrLower(extension)
}

LoadOpenApps() {
    global ConfigPath, OpenAppsConfigNeedsMigration
    apps := []
    seenIds := Map()
    seenPaths := Map()
    legacyFormat := OpenAppsConfigUsesLegacyFormat(ConfigPath)
    if legacyFormat
        OpenAppsConfigNeedsMigration := true
    sourceIds := ReadOpenAppIdsFrom(ConfigPath)
    reservedIds := Map()
    for sourceId in sourceIds {
        if !IsGuidOpenAppId(sourceId)
            reservedIds[StrLower(sourceId)] := true
    }
    for sourceId in sourceIds {
        section := "OpenApp:" sourceId
        programPath := NormalizePath(IniRead(ConfigPath, section, "Path", ""))
        if programPath = "" || !IsExecutablePath(programPath)
            continue
        id := sourceId
        if legacyFormat && IsGuidOpenAppId(id) {
            id := NewOpenAppIdForApps(programPath, apps, reservedIds)
            OpenAppsConfigNeedsMigration := true
        }
        if seenIds.Has(StrLower(id))
            continue
        programPathKey := PathKey(programPath)
        if seenPaths.Has(programPathKey)
            continue
        seenIds[StrLower(id)] := true
        seenPaths[programPathKey] := true
        name := Trim(IniRead(ConfigPath, section, "Name", ""))
        if name = ""
            name := GetExecutableDisplayName(programPath)
        extensions := NormalizeOpenAppExtensions(
            IniRead(ConfigPath, section, "Extensions", ""))
        enabled := IniRead(ConfigPath, section, "Enabled", "1") != "0"
        icon := NormalizePath(IniRead(ConfigPath, section, "Icon", programPath))
        if icon = ""
            icon := programPath
        apps.Push({
            Id: id,
            Path: programPath,
            Name: name,
            Icon: icon,
            Extensions: extensions,
            Enabled: enabled
        })
    }
    return apps
}

OpenAppsConfigUsesLegacyFormat(path) {
    legacyEntryFound := false
    for entry in ReadIniSectionFrom(path, "OpenApps") {
        if StrLower(entry.Key) = "order"
            return false
        if RegExMatch(entry.Key, "i)^App\d+$")
            legacyEntryFound := true
    }
    return legacyEntryFound
}

ReadOpenAppIdsFrom(path) {
    legacyIds := []
    orderFound := false
    orderValue := ""
    for entry in ReadIniSectionFrom(path, "OpenApps") {
        if StrLower(entry.Key) = "order" {
            orderFound := true
            orderValue := entry.Value
            continue
        }
        ; v0.7 早期格式：App001=<UUID 或自定义 ID>。
        if RegExMatch(entry.Key, "i)^App\d+$") {
            id := Trim(entry.Value)
            if (IsSafeOpenAppId(id)
                && !ArrayContainsTextInsensitive(legacyIds, id))
                legacyIds.Push(id)
        }
    }
    ; 只要存在 Order 键（即使为空），它就是唯一排序来源。
    return orderFound ? ParseOpenAppOrder(orderValue) : legacyIds
}

ParseOpenAppOrder(raw) {
    ids := []
    seen := Map()
    for part in StrSplit(raw, ",") {
        id := Trim(part)
        key := StrLower(id)
        if !IsSafeOpenAppId(id) || seen.Has(key)
            continue
        seen[key] := true
        ids.Push(id)
    }
    return ids
}

IsSafeOpenAppId(id) {
    id := Trim(id)
    return id != "" && !RegExMatch(id, "[,\[\]=`r`n]")
}

IsGuidOpenAppId(id) {
    return RegExMatch(id,
        "i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
}

NormalizeOpenAppExtensions(raw) {
    global NO_EXTENSION_TOKEN
    result := []
    seen := Map()
    for part in StrSplit(raw, ",", " `t") {
        value := StrLower(Trim(part))
        if value = ""
            continue
        if value = StrLower(NO_EXTENSION_TOKEN) || value = "none"
            value := NO_EXTENSION_TOKEN
        else
            value := SubStr(value, 1, 1) = "." ? value : "." value
        if !seen.Has(value) {
            seen[value] := true
            result.Push(value)
        }
    }
    return result
}

GetApplicableOpenApps(filePath) {
    global OpenApps
    extensionType := GetFileExtensionType(filePath)
    exact := []
    generic := []
    for app in OpenApps {
        if !app.Enabled
            continue
        if !app.Extensions.Length {
            generic.Push(app)
            continue
        }
        for extension in app.Extensions {
            if StrLower(extension) = StrLower(extensionType) {
                exact.Push(app)
                break
            }
        }
    }
    for app in generic
        exact.Push(app)
    return exact
}

FindOpenAppById(id) {
    global OpenApps
    for app in OpenApps {
        if StrLower(app.Id) = StrLower(id)
            return app
    }
    return 0
}

FindOpenAppByPath(path) {
    global OpenApps
    for app in OpenApps {
        if PathsEqual(app.Path, path)
            return app
    }
    return 0
}

OpenWithConfiguredApp(appId, filePath, *) {
    app := FindOpenAppById(appId)
    if !IsObject(app)
        return
    if !IsExistingExecutable(app.Path) {
        HandleMissingOpenApp(app)
        return
    }
    if !ShellLaunchExecutable(app.Path, filePath) {
        ShowPanelMsgBox("无法使用 " app.Name " 打开文件。",
            "打开失败", "Iconx")
        return
    }
    SetUserStatus("已用 " app.Name " 打开")
}

AddConfiguredOpenApp(*) {
    global LastOpenProgramDir, OpenApps
    initialDir := DirExist(LastOpenProgramDir)
        ? LastOpenProgramDir : GetProgramFilesDirectory()
    selected := SelectPanelFile("3", initialDir,
        "添加用于打开文件的软件", "应用程序 (*.exe)")
    if selected = ""
        return
    selected := NormalizePath(selected)
    if !IsExistingExecutable(selected) {
        ShowPanelMsgBox("v0.7 仅支持选择现有的 .exe 应用程序。",
            "添加软件", "Icon!")
        return
    }
    existing := FindOpenAppByPath(selected)
    if IsObject(existing) {
        SetUserStatus(existing.Name " 已在软件列表中")
        return
    }
    app := {
        Id: NewOpenAppId(selected),
        Path: selected,
        Name: GetExecutableDisplayName(selected),
        Icon: selected,
        Extensions: [],
        Enabled: true
    }
    OpenApps.Push(app)
    SplitPath(selected, , &LastOpenProgramDir)
    try {
        SaveOpenApps()
        SetUserStatus("已添加 " app.Name "；扩展名留空，适用于所有普通文件")
        OpenConfigFile()
    } catch as err {
        OpenApps.Pop()
        ShowPanelMsgBox("无法保存软件配置：`n" err.Message,
            "添加软件失败", "Iconx")
    }
}

ChooseOtherProgramForFile(filePath, *) {
    global LastOpenProgramDir, OpenApps, LastOpenAppUndoState
    extensionType := GetFileExtensionType(filePath)
    extensionLabel := extensionType = "<none>" ? "无扩展名" : extensionType
    initialDir := DirExist(LastOpenProgramDir)
        ? LastOpenProgramDir : GetProgramFilesDirectory()

    selected := SelectPanelFile("3", initialDir,
        "选择用于打开 " extensionLabel " 文件的程序", "应用程序 (*.exe)")
    if selected = ""
        return
    selected := NormalizePath(selected)
    if !IsExistingExecutable(selected) {
        ShowPanelMsgBox("v0.7 仅支持选择现有的 .exe 应用程序。",
            "无法添加程序", "Icon!")
        return
    }
    if !ShellLaunchExecutable(selected, filePath) {
        ShowPanelMsgBox("无法使用该程序打开文件，未保存到软件列表",
            "打开失败", "Iconx")
        return
    }

    previousState := CloneOpenApps(OpenApps)
    app := FindOpenAppByPath(selected)
    changed := false
    if !IsObject(app) {
        app := {
            Id: NewOpenAppId(selected),
            Path: selected,
            Name: GetExecutableDisplayName(selected),
            Icon: selected,
            Extensions: [extensionType],
            Enabled: true
        }
        OpenApps.Push(app)
        changed := true
    } else if app.Extensions.Length {
        if !ArrayContainsTextInsensitive(app.Extensions, extensionType) {
            app.Extensions.Push(extensionType)
            changed := true
        }
    }
    SplitPath(selected, , &selectedDir)
    LastOpenProgramDir := NormalizePath(selectedDir)
    if changed {
        try SaveOpenApps()
        catch as err {
            OpenApps := previousState
            ShowPanelMsgBox("程序已启动，但无法安全保存软件列表：`n"
                err.Message, "配置保存失败", "Iconx")
            return
        }
        LastOpenAppUndoState := previousState
        SetOpenAppUndoStatus("已用 " app.Name " 打开，并添加为 " extensionLabel
            " 文件的可用程序    撤销")
    } else {
        try SaveOpenApps()
        SetUserStatus("已用 " app.Name " 打开")
    }
}

HandleMissingOpenApp(app) {
    answer := ShowPanelMsgBox("找不到 " app.Name
        "`n`n“是”：重新选择程序`n“否”：从软件列表移除",
        "程序不可用", "YesNoCancel Icon!")
    if answer = "Yes"
        ReselectMissingOpenApp(app)
    else if answer = "No"
        RemoveOpenAppById(app.Id)
}

ReselectMissingOpenApp(app) {
    global LastOpenProgramDir
    initialDir := DirExist(LastOpenProgramDir)
        ? LastOpenProgramDir : GetProgramFilesDirectory()
    selected := SelectPanelFile("3", initialDir,
        "重新选择 " app.Name, "应用程序 (*.exe)")
    if selected = ""
        return
    selected := NormalizePath(selected)
    if !IsExistingExecutable(selected) {
        ShowPanelMsgBox("请选择现有的 .exe 应用程序。",
            "重新选择程序", "Icon!")
        return
    }
    duplicate := FindOpenAppByPath(selected)
    if IsObject(duplicate) && StrLower(duplicate.Id) != StrLower(app.Id) {
        if !app.Extensions.Length
            duplicate.Extensions := []
        else {
            for extension in app.Extensions {
                if duplicate.Extensions.Length
                    && !ArrayContainsTextInsensitive(duplicate.Extensions, extension)
                    duplicate.Extensions.Push(extension)
            }
        }
        RemoveOpenAppById(app.Id, false)
    } else {
        app.Path := selected
        app.Icon := selected
        if app.Name = ""
            app.Name := GetExecutableDisplayName(selected)
    }
    SplitPath(selected, , &LastOpenProgramDir)
    SaveOpenApps()
    SetUserStatus("已更新 " app.Name " 的程序路径")
}

RemoveOpenAppById(id, save := true) {
    global OpenApps
    for index, app in OpenApps {
        if StrLower(app.Id) = StrLower(id) {
            OpenApps.RemoveAt(index)
            if save
                SaveOpenApps()
            SetUserStatus("已从软件列表移除 " app.Name)
            return true
        }
    }
    return false
}

CloneOpenApps(apps) {
    result := []
    for app in apps
        result.Push({
            Id: app.Id, Path: app.Path, Name: app.Name, Icon: app.Icon,
            Extensions: app.Extensions.Clone(), Enabled: app.Enabled
        })
    return result
}

ArrayContainsTextInsensitive(values, target) {
    for value in values {
        if StrLower(value) = StrLower(target)
            return true
    }
    return false
}

HandleStatusAction(*) {
    global LastOpenAppUndoState, OpenApps, CurrentStatusAction
    if IsObject(CurrentStatusAction) {
        action := CurrentStatusAction
        CurrentStatusAction := 0
        action.Call()
        return
    }
    if !IsObject(LastOpenAppUndoState)
        return
    OpenApps := CloneOpenApps(LastOpenAppUndoState)
    LastOpenAppUndoState := 0
    try {
        SaveOpenApps()
        SetUserStatus("已撤销软件列表更改")
    } catch as err {
        ShowPanelMsgBox("无法撤销软件列表更改：`n" err.Message,
            "撤销失败", "Iconx")
    }
}

SetOpenAppUndoStatus(text) {
    global StatusText, StatusKind, CurrentStatusAction
    CurrentStatusAction := 0
    if IsObject(StatusText) {
        StatusKind := "user"
        StatusText.Text := text
    }
}

GetProgramFilesDirectory() {
    path := EnvGet("ProgramFiles")
    return DirExist(path) ? path : "C:\Program Files"
}

NewOpenAppId(executablePath) {
    global OpenApps
    return NewOpenAppIdForApps(executablePath, OpenApps)
}

NewOpenAppIdForApps(executablePath, apps, reservedIds := 0) {
    base := OpenAppIdBase(executablePath)
    candidate := base
    suffix := 2
    while (OpenAppArrayHasId(apps, candidate)
        || (IsObject(reservedIds) && reservedIds.Has(StrLower(candidate)))) {
        candidate := base "-" suffix
        suffix += 1
    }
    return candidate
}

OpenAppArrayHasId(apps, id) {
    for app in apps {
        if StrLower(app.Id) = StrLower(id)
            return true
    }
    return false
}

OpenAppIdBase(executablePath) {
    SplitPath(executablePath, , , , &nameNoExt)
    base := StrLower(Trim(nameNoExt))
    base := RegExReplace(base, "[^a-z0-9_-]+", "-")
    base := Trim(base, "-_")
    return base != "" ? base : "app"
}

GetExecutableDisplayName(path) {
    name := GetExecutableProductName(path)
    if name != ""
        return name
    SplitPath(path, &fileName, , , &nameNoExt)
    return nameNoExt != "" ? nameNoExt : fileName
}

GetExecutableProductName(path) {
    ignored := 0
    size := DllCall("version\GetFileVersionInfoSizeW", "wstr", path,
        "uint*", &ignored, "uint")
    if !size
        return ""
    data := Buffer(size, 0)
    if !DllCall("version\GetFileVersionInfoW", "wstr", path,
        "uint", 0, "uint", size, "ptr", data.Ptr, "int")
        return ""
    translation := 0
    translationLength := 0
    queries := []
    if DllCall("version\VerQueryValueW", "ptr", data.Ptr,
        "wstr", "\VarFileInfo\Translation", "ptr*", &translation,
        "uint*", &translationLength, "int") && translationLength >= 4 {
        language := NumGet(translation, 0, "ushort")
        codePage := NumGet(translation, 2, "ushort")
        queries.Push(Format("\StringFileInfo\{:04X}{:04X}\ProductName",
            language, codePage))
    }
    queries.Push("\StringFileInfo\040904B0\ProductName")
    for query in queries {
        valuePtr := 0
        valueLength := 0
        if DllCall("version\VerQueryValueW", "ptr", data.Ptr,
            "wstr", query, "ptr*", &valuePtr, "uint*", &valueLength, "int")
            && valuePtr && valueLength {
            value := Trim(StrGet(valuePtr))
            if value != ""
                return value
        }
    }
    return ""
}

ShellLaunchExecutable(executablePath, targetPath) {
    global Panel
    executablePath := NormalizePath(executablePath)
    targetPath := NormalizePath(targetPath)
    if !IsExistingExecutable(executablePath)
        return false
    parameters := QuoteWindowsArgument(targetPath)
    infoSize := A_PtrSize = 8 ? 112 : 60
    info := Buffer(infoSize, 0)
    NumPut("uint", infoSize, info, 0)
    NumPut("uint", 0x440, info, 4) ; SEE_MASK_NOCLOSEPROCESS | FLAG_NO_UI
    NumPut("ptr", IsObject(Panel) ? Panel.Hwnd : 0, info, 8)
    NumPut("ptr", StrPtr(executablePath), info, A_PtrSize = 8 ? 24 : 16)
    NumPut("ptr", StrPtr(parameters), info, A_PtrSize = 8 ? 32 : 20)
    NumPut("int", 1, info, A_PtrSize = 8 ? 48 : 28)
    if !DllCall("shell32\ShellExecuteExW", "ptr", info.Ptr, "int")
        return false
    processHandle := NumGet(info, A_PtrSize = 8 ? 104 : 56, "ptr")
    if processHandle
        DllCall("kernel32\CloseHandle", "ptr", processHandle)
    return true
}

IsExecutablePath(path) {
    SplitPath(path, , , &extension)
    return StrLower(extension) = "exe"
}

IsExistingExecutable(path) {
    path := NormalizePath(path)
    attributes := FileExist(path)
    return path != "" && attributes != "" && !InStr(attributes, "D")
        && IsExecutablePath(path)
}

QuoteWindowsArgument(value) {
    ; CommandLineToArgvW-compatible quoting for one argument. lpFile and
    ; lpParameters remain separate SHELLEXECUTEINFO fields.
    result := '"'
    backslashes := 0
    for char in StrSplit(value) {
        if char = "\" {
            backslashes += 1
            continue
        }
        if char = '"' {
            result .= RepeatText("\", backslashes * 2 + 1) '"'
            backslashes := 0
            continue
        }
        result .= RepeatText("\", backslashes) char
        backslashes := 0
    }
    result .= RepeatText("\", backslashes * 2) '"'
    return result
}

RepeatText(text, count) {
    result := ""
    Loop count
        result .= text
    return result
}

SaveOpenApps() {
    AtomicConfigEdit(WriteOpenAppsConfig)
}

WriteOpenAppsConfig(tempPath) {
    global OpenApps, LastOpenProgramDir, CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    activeIds := Map()
    for app in OpenApps
        activeIds[StrLower(app.Id)] := true
    oldIds := ParseOpenAppOrder(doc.GetValue("OpenApps", "Order", ""))
    for entry in doc.GetEntries("OpenApps") {
        if RegExMatch(entry.Key, "i)^App\d+$")
            && !ArrayContainsTextInsensitive(oldIds, entry.Value)
            oldIds.Push(entry.Value)
    }
    for id in oldIds {
        if !activeIds.Has(StrLower(id))
            doc.DeleteSection("OpenApp:" id)
    }
    ids := []
    for app in OpenApps
        ids.Push(app.Id)
    doc.ReplaceSection("OpenApps",
        [{Key: "Order", Value: JoinArray(ids, ",")}], 4)

    for app in OpenApps {
        section := "OpenApp:" app.Id
        entries := [{Key: "Path", Value: app.Path}]
        if app.Name != GetExecutableDisplayName(app.Path)
            entries.Push({Key: "Name", Value: app.Name})
        if !PathsEqual(app.Icon, app.Path)
            entries.Push({Key: "Icon", Value: app.Icon})
        if app.Extensions.Length
            entries.Push({Key: "Extensions",
                Value: JoinArray(app.Extensions, ",")})
        if !app.Enabled
            entries.Push({Key: "Enabled", Value: "0"})
        doc.ReplaceKnownKeys(section, entries,
            ["Path", "Name", "Icon", "Extensions", "Enabled"], 4)
    }
    doc.SetValue("General", "LastOpenProgramDir", LastOpenProgramDir, 1)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
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
    return ReadIniSectionFrom(ConfigPath, sectionName)
}

ReadIniSectionFrom(path, sectionName) {
    result := []
    try raw := IniRead(path, sectionName)
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

LoadPathListSection(sectionName, limit := 0) {
    result := []
    for entry in ReadIniSection(sectionName) {
        if !RegExMatch(entry.Key, "i)^Path\d+$")
            continue
        path := NormalizePath(entry.Value)
        if path != "" && !ArrayContainsPath(result, path) {
            result.Push(path)
            if limit > 0 && result.Length >= limit
                break
        }
    }
    return result
}

LoadTransferFavorites(settingErrors) {
    global ConfigPath

    configured := LoadPathListSection("TransferFavorites", 5)
    initialized := IniRead(ConfigPath, "General",
        "TransferFavoritesInitialized", "0") = "1"
    if initialized
        return configured

    ; One-time migration for v0.7 configs that injected Desktop/Downloads at
    ; menu-build time. Persist them now, while preserving existing custom paths.
    migrated := GetDefaultTransferFavoritePaths()
    for path in configured {
        if migrated.Length >= 5
            break
        if !ArrayContainsPath(migrated, path)
            migrated.Push(path)
    }
    try AtomicConfigEdit(WriteInitialTransferFavoritesConfig.Bind(migrated))
    catch as err
        settingErrors.Push("无法迁移常用位置配置：" err.Message)
    return migrated
}

GetDefaultTransferFavoritePaths() {
    result := []
    desktop := GetKnownFolderPath("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}")
    downloads := GetKnownFolderPath("{374DE290-123F-4565-9164-39C4925E467B}")
    if desktop != ""
        result.Push(desktop)
    if downloads != "" && !ArrayContainsPath(result, downloads)
        result.Push(downloads)
    return result
}

WriteInitialTransferFavoritesConfig(favorites, tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    doc.ReplaceSection("TransferFavorites",
        ConfigEntriesFromValues(favorites, "Path"), 5)
    doc.SetValue("General", "TransferFavoritesInitialized", "1", 1)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

AtomicConfigEdit(editor) {
    global ConfigPath
    tempPath := ConfigPath ".tmp-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount
    try FileDelete(tempPath)
    try {
        configExisted := FileExist(ConfigPath) != ""
        baseline := configExisted ? FileRead(ConfigPath, "RAW") : 0
        if configExisted
            FileCopy(ConfigPath, tempPath, 1)
        else
            FileAppend("", tempPath, "UTF-16")
        editor.Call(tempPath)
        ; The callback edits only the private temporary copy. Re-open it before
        ; replacement so malformed/duplicate sections, wrong layout or BOM
        ; corruption can never reach the live config.
        verified := OpenPopDropConfig(tempPath)
        verified.Save()
        ; Do not silently overwrite a manual edit or another writer that
        ; completed after this transaction copied its baseline.
        if configExisted {
            if !FileExist(ConfigPath)
                throw Error("配置文件在保存期间被删除；已取消本次写入。")
            current := FileRead(ConfigPath, "RAW")
            if !BuffersEqual(baseline, current)
                throw Error("配置文件在保存期间被其他程序修改；"
                    "已保留外部修改并取消本次写入，请刷新后重试。")
        } else if FileExist(ConfigPath) {
            throw Error("配置文件在保存期间由其他程序创建；已取消本次写入。")
        }
        ; ReplaceFileW is atomic on the same volume and preserves metadata.
        replaced := DllCall("kernel32\ReplaceFileW", "wstr", ConfigPath,
            "wstr", tempPath, "ptr", 0, "uint", 0x2,
            "ptr", 0, "ptr", 0, "int")
        if !replaced {
            ; New configurations may not have a destination yet. MoveFileExW
            ; remains a same-volume replace and requests write-through.
            if !DllCall("kernel32\MoveFileExW", "wstr", tempPath,
                "wstr", ConfigPath, "uint", 0x9, "int")
                throw OSError(A_LastError, "无法原子替换配置文件")
        }
    } catch {
        try FileDelete(tempPath)
        throw
    }
}

BuffersEqual(left, right) {
    if left.Size != right.Size
        return false
    Loop left.Size {
        offset := A_Index - 1
        if NumGet(left, offset, "UChar") != NumGet(right, offset, "UChar")
            return false
    }
    return true
}

AtomicConfigSetValue(section, key, value, area := 1) {
    AtomicConfigEdit(WriteSingleConfigValue.Bind(
        section, key, value, area))
}

WriteSingleConfigValue(section, key, value, area, tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    doc.SetValue(section, key, value, area)
    if StrLower(section) != "general" || StrLower(key) != "configversion"
        doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

NormalizePath(path) {
    path := Trim(path, " `t`r`n`"")
    if path = ""
        return ""
    path := StrReplace(path, "/", "\")

    required := DllCall("kernel32\ExpandEnvironmentStringsW", "str", path, "ptr", 0, "uint", 0, "uint")
    if required {
        expanded := Buffer(required * 2, 0)
        DllCall("kernel32\ExpandEnvironmentStringsW", "str", path, "ptr", expanded.Ptr, "uint", required)
        path := StrGet(expanded)
    }

    if !RegExMatch(path, "i)^(?:[A-Z]:\\|\\\\)")
        path := A_ScriptDir "\" path
    required := DllCall("kernel32\GetFullPathNameW", "wstr", path,
        "uint", 0, "ptr", 0, "ptr", 0, "uint")
    if required {
        full := Buffer((required + 1) * 2, 0)
        if DllCall("kernel32\GetFullPathNameW", "wstr", path,
            "uint", required + 1, "ptr", full.Ptr, "ptr", 0, "uint")
            path := StrGet(full)
    }
    if IsPathRoot(path)
        return path
    return RTrim(path, "\")
}

IsPathRoot(path) {
    return RegExMatch(path, "i)^(?:[A-Z]:\\|\\\\[^\\]+\\[^\\]+\\?)$")
}

PathKey(path) {
    path := NormalizePath(path)
    if SubStr(path, 1, 8) = "\\?\UNC\"
        path := "\\" SubStr(path, 9)
    else if SubStr(path, 1, 4) = "\\?\"
        path := SubStr(path, 5)
    if !IsPathRoot(path)
        path := RTrim(path, "\")
    return StrLower(path)
}

PathsEqual(left, right) {
    return PathKey(left) = PathKey(right)
}

GetParentPath(path) {
    path := NormalizePath(path)
    SplitPath(path, , &parent)
    return NormalizePath(parent)
}

IsSameOrDescendantPath(candidate, ancestor) {
    candidateKey := PathKey(candidate)
    ancestorKey := RTrim(PathKey(ancestor), "\")
    return candidateKey = ancestorKey
        || SubStr(candidateKey, 1, StrLen(ancestorKey) + 1) = ancestorKey "\"
}

BuildPanel() {
    global Panel, FileView, RecentLabel, RecentView
    global ViewButton, RecentButton, WindowModeButton, PinnedDropButton, StatusText
    global TransferStatusText
    global APP_VERSION

    Panel := Gui("+Resize +MinSize620x380", "PopDrop v" APP_VERSION)
    Panel.MarginX := 12
    Panel.MarginY := 10
    Panel.SetFont("s9", "Microsoft YaHei UI")

    Panel.AddButton("xm ym w60 h30", "🔄 刷新").OnEvent("Click", RefreshPanel)
    PinnedDropButton := Panel.AddButton("x+6 yp w76 h30", "＋ 固定项")
    PinnedDropButton.OnEvent("Click", AddPinnedFiles)
    Panel.AddButton("x+6 yp w76 h30", "－ 固定项").OnEvent("Click", RemovePinnedFile)
    ViewButton := Panel.AddButton("x+6 yp w80 h30", "视图")
    ViewButton.OnEvent("Click", ToggleViewMode)
    RecentButton := Panel.AddButton("x+6 yp w76 h30", "近期栏")
    RecentButton.OnEvent("Click", ToggleRecentSidebar)
    Panel.AddButton("x+6 yp w60 h30", "⚙️ 配置").OnEvent("Click", OpenConfig)
    WindowModeButton := Panel.AddButton("x+6 yp w76 h30", "置顶：关")
    WindowModeButton.OnEvent("Click", ToggleWindowMode)
    Panel.AddButton("x+6 yp w60 h30", "❌ 关闭").OnEvent("Click", HidePanel)

    ; Multi-select is the native ListView default. In icon view this enables
    ; Ctrl-click, Shift range selection and marquee selection on blank space.
    FileView := Panel.AddListView("xm y+10 w716 h468 Icon +0x100", ["文件", "修改时间"])
    FileView.OnEvent("Click", FileViewClick)
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
    RecentView.OnEvent("Click", FileViewClick)
    RecentView.OnEvent("DoubleClick", OpenRecentItem)
    RecentView.OnEvent("ContextMenu", RecentContextMenu)
    RecentView.OnEvent("ItemSelect", RecentItemSelect)

    StatusText := Panel.AddText("xm y+6 w500 h22 +0x200 +0x100", "就绪")
    StatusText.OnEvent("Click", HandleStatusAction)
    TransferStatusText := Panel.AddText(
        "x+8 yp w208 h22 Right +0x200 +0x100", "↓ 下载")
    TransferStatusText.OnEvent("Click", OpenTransferCenter)
    Panel.OnEvent("Close", HandlePanelClose)
    Panel.OnEvent("Escape", HandlePanelEscape)
    Panel.OnEvent("Size", ResizePanel)
    ; OLE IDropTarget is registered after the panel is built. Do not also
    ; enable WM_DROPFILES: one physical drop must have exactly one owner.
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
    global ActiveHotkey, APP_VERSION
    if A_IsCompiled {
        TraySetIcon(A_ScriptFullPath, -555, true)
    } else {
        TraySetIcon(A_ScriptDir "\assets\tray.ico", 1, true)
    }
    A_TrayMenu.Delete()
    A_TrayMenu.Add("显示/隐藏面板 (" ActiveHotkey ")", TogglePanel)
    A_TrayMenu.Add("刷新并显示", ShowAndRefresh)
    A_TrayMenu.Add()
    A_TrayMenu.Add("添加打开软件…", AddConfiguredOpenApp)
    A_TrayMenu.Add("PopDrop 设置…", OpenConfig)
    A_TrayMenu.Add("传输中心…", OpenTransferCenter)
    A_TrayMenu.Add("高级编辑 config.ini", OpenConfigFile)
    A_TrayMenu.Add("退出", RequestExitPopDrop)
    A_TrayMenu.Default := "显示/隐藏面板 (" ActiveHotkey ")"
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
    UpdateViewButtons()
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
    global Panel, PanelVisible
    CancelFilePointerGesture()
    CancelAutoHideCheck()
    Panel.Hide()
    PanelVisible := false
}

HandlePanelClose(*) {
    HidePanel()
    return true
}

HandlePanelEscape(*) {
    global EscapeHidesPanel
    if EscapeHidesPanel
        HidePanel()
    return true
}

ResizePanel(guiObj, minMax, width, height) {
    global FileView, RecentLabel, RecentView, StatusText, TransferStatusText
    global ShowRecentSidebar
    if minMax = -1
        return
    contentHeight := Max(160, height - 92)
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
    transferWidth := Min(360, Max(150, Floor(width * 0.38)))
    statusWidth := Max(100, width - transferWidth - 32)
    StatusText.Move(12, height - 27, statusWidth, 22)
    TransferStatusText.Move(20 + statusWidth, height - 27,
        transferWidth, 22)
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
    global ViewMode
    ViewMode := ViewMode = "Thumbnail" ? "List" : "Thumbnail"
    AtomicConfigSetValue("General", "ViewMode", ViewMode)
    ApplyViewMode()
    UpdateViewButtons()
}

ToggleRecentSidebar(*) {
    global ShowRecentSidebar
    ShowRecentSidebar := !ShowRecentSidebar
    AtomicConfigSetValue("General", "ShowRecentSidebar",
        ShowRecentSidebar ? "1" : "0")
    if ShowRecentSidebar
        PopulateRecentSidebar()
    UpdateViewButtons()
    RequestNativeLayout()
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
    UpdateViewButtons()
}

UpdateViewButtons() {
    global ViewButton, RecentButton, WindowModeButton
    global ViewMode, ShowRecentSidebar, WindowMode, WINDOW_MODE_ALWAYS_ON_TOP
    if IsObject(ViewButton)
        ViewButton.Text := ViewMode = "Thumbnail" ? "缩略图：开" : "缩略图：关"
    if IsObject(RecentButton)
        RecentButton.Text := ShowRecentSidebar ? "近期栏：开" : "近期栏：关"
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

PopulatePanel() {
    global FileView, ItemPaths, ItemLabels, ItemFolderPaths
    global ItemKinds, ItemOpenContexts
    global PinnedPaths, FolderSettings, StatusText
    global IncludeSubfolders, MaxFilesPerFolder, SortMode
    global ThumbnailSize, ThumbnailImageList, SelectedFilePaths, LastValidFolderSettings, ConfigErrors
    global CurrentScanResult, ScanResultLoaded, StatusKind
    global ConfigErrorsShown, MODE_FILES, GroupFolderPaths, GroupDropTargets
    global SCOPE_FILES_ONLY, SCOPE_RECURSIVE_FILES, FOLDER_TIME_MODIFIED
    global PendingFileOperationRefresh, PendingRefresh
    global NOISE_FILTER_INHERIT

    CancelFilePointerGesture()
    SetDropGroupHighlight(0)
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
    ItemPaths := Map()
    ItemLabels := Map()
    ItemFolderPaths := Map()
    ItemKinds := Map()
    ItemOpenContexts := Map()
    GroupFolderPaths := Map()
    GroupDropTargets := Map()
    displayedCount := 0
    unavailableCount := 0
    groupId := 1

    if PinnedPaths.Length {
        InsertListGroup(groupId, "固定项  (" PinnedPaths.Length ")")
        GroupDropTargets[groupId] := {
            Type: "Pinned", SourceId: "", Name: "固定项",
            Path: "", Mode: "", GroupId: groupId}
        for path in PinnedPaths {
            exists := FileExist(path)
            label := GetFileName(path)
            if !exists
                label .= "  [项目不存在]"
            row := AddFileTile(path, label, "", groupId)
            ItemPaths[row] := path
            ItemKinds[row] := DirExist(path) ? "Folder" : "File"
            ItemOpenContexts[row] := {Area: "Pinned", GroupId: groupId}
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
                DisplayScope: IncludeSubfolders ? SCOPE_RECURSIVE_FILES : SCOPE_FILES_ONLY,
                FolderTimeMode: FOLDER_TIME_MODIFIED,
                MaxFilesPerFolder: MaxFilesPerFolder,
                SortMode: SortMode,
                Filter: {Mode: "All", Extensions: []},
                StripOrderPrefix: 0,
                HideExtensions: 0,
                SourceId: ResolveFolderSourceId(f.Name, f.Path),
                OpenFileMode: "Inherit",
                NoiseFilterMode: NOISE_FILTER_INHERIT,
                NoiseFilter: ResolveNoiseFilterForSource(NOISE_FILTER_INHERIT, []),
                SourceCustomPatternTexts: [],
                ExcludedPaths: [],
                AllowedExcludedPaths: []
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
        groupHeader := folder.Name suffix "  —  " folder.Path
        InsertListGroup(groupId, groupHeader)
        GroupFolderPaths[groupId] := folder.Path
        GroupDropTargets[groupId] := {
            Type: folder.Mode,
            SourceId: folder.SourceId,
            Name: folder.Name,
            Path: folder.Path,
            Mode: folder.Mode,
            GroupId: groupId,
            BaseHeader: groupHeader
        }
        if state = "Unavailable" {
            row := AddPlaceholderTile("目录不可用", groupId)
            ItemPaths[row] := folder.Path
            ItemFolderPaths[row] := folder.Path
            ItemKinds[row] := "Folder"
            ItemOpenContexts[row] := {
                Area: "Source",
                SourceId: folder.SourceId,
                SourcePath: folder.Path,
                SourceMode: folder.Mode,
                GroupId: groupId
            }
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
            ItemKinds[row] := "Folder"
            ItemOpenContexts[row] := {
                Area: "Source",
                SourceId: folder.SourceId,
                SourcePath: folder.Path,
                SourceMode: folder.Mode,
                GroupId: groupId
            }
            groupId += 1
            continue
        }
        for file in files {
            displayName := GetDisplayName(file.Name, folder)
            modifiedText := file.Modified = ""
                ? "" : FormatTime(file.Modified, "yyyy-MM-dd HH:mm")
            if file.IsDirectory && file.TimeKind = "Content"
                modifiedText := "内容更新于 " modifiedText
            row := AddFileTile(file.Path, displayName, modifiedText, groupId)
            ItemPaths[row] := file.Path
            ItemFolderPaths[row] := folder.Path
            ItemKinds[row] := file.IsDirectory ? "Folder" : "File"
            ItemOpenContexts[row] := {
                Area: "Source",
                SourceId: folder.SourceId,
                SourcePath: folder.Path,
                SourceMode: folder.Mode,
                GroupId: groupId
            }
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
    UpdateTransferGroupHeaders()
    status := "共显示 " displayedCount " 个项目"
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

    if PendingFileOperationRefresh && !PendingRefresh
        ApplyPendingViewRestore()
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
    global FileView, ItemLabels
    imageIndex := AddShellThumbnail(path)
    options := imageIndex ? "Icon" imageIndex : ""
    row := FileView.Add(options, label, modifiedText)
    ItemLabels[row] := label
    SetListItemGroup(row, groupId)
    return row
}

AddPlaceholderTile(label, groupId) {
    global FileView, ItemLabels
    row := FileView.Add("", label, "")
    ItemLabels[row] := label
    SetListItemGroup(row, groupId)
    return row
}

AddShellThumbnail(path) {
    global ThumbnailSize, ThumbnailImageList, ThumbnailPolicy
    ; Folders are pinned as single shortcuts. Always use their Shell icon
    ; instead of asking Windows to inspect their contents for a thumbnail.
    if DirExist(path)
        return AddShellFileIcon(path)

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

GetSortedItems(folderPath, limit, displayScope, sortMode, filter, folderTimeMode,
    globalExcludedNames := [], excludedPaths := [], allowedPaths := [],
    noiseFilter := 0, pinnedSet := 0, sourceName := "", diagnostics := 0) {
    global SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_LATEST_CONTENT
    files := []
    stack := [{Path: folderPath, Root: true}]
    while stack.Length {
        current := stack.Pop()
        directory := EnumerateDirectoryForScan(current.Path)
        for entry in directory.Entries {
            if entry.IsDirectory {
                if ShouldSkipScannedFolder(entry.Path, entry.Name,
                    globalExcludedNames, excludedPaths, allowedPaths)
                    continue
                isReparsePoint := InStr(entry.Attributes, "L") != 0
                if current.Root && displayScope = SCOPE_FILES_AND_FOLDERS {
                    modified := entry.Modified
                    timeKind := "Directory"
                    if folderTimeMode = FOLDER_TIME_LATEST_CONTENT
                        && !isReparsePoint {
                        latest := GetLatestDescendantFileTime(entry.Path, filter,
                            globalExcludedNames, excludedPaths, allowedPaths,
                            noiseFilter, pinnedSet, sourceName, diagnostics)
                        if latest != "" {
                            modified := latest
                            timeKind := "Content"
                        }
                    }
                    AddSortedCandidate(&files, {Path: entry.Path,
                        Name: entry.Name, Modified: modified,
                        IsDirectory: true, TimeKind: timeKind}, limit, sortMode)
                }
                if displayScope = SCOPE_RECURSIVE_FILES && !isReparsePoint
                    stack.Push({Path: entry.Path, Root: false})
                continue
            }
            if !current.Root && displayScope != SCOPE_RECURSIVE_FILES
                continue
            visibility := ShouldIncludeEntry(entry.Path, entry.Name,
                entry.Attributes, noiseFilter, directory.FileNames, pinnedSet)
            if !visibility.Include {
                RecordHiddenNoiseItem(diagnostics, entry.Path,
                    entry.Name, sourceName, visibility.Reason)
                continue
            }
            if !ShouldIncludeFile(entry.Name, filter)
                continue
            AddSortedCandidate(&files, {Path: entry.Path, Name: entry.Name,
                Modified: entry.Modified, IsDirectory: false,
                TimeKind: "File"}, limit, sortMode)
        }
    }
    if limit = 0
        SortFileArray(&files, sortMode)
    return files
}

AddSortedCandidate(&files, candidate, limit, sortMode) {
    if limit > 0 {
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

GetLatestDescendantFileTime(folderPath, filter, globalExcludedNames := [],
    excludedPaths := [], allowedPaths := [], noiseFilter := 0,
    pinnedSet := 0, sourceName := "", diagnostics := 0) {
    latest := ""
    stack := [folderPath]
    while stack.Length {
        current := stack.Pop()
        directory := EnumerateDirectoryForScan(current)
        for entry in directory.Entries {
            if entry.IsDirectory {
                if ShouldSkipScannedFolder(entry.Path, entry.Name,
                    globalExcludedNames, excludedPaths, allowedPaths)
                    continue
                if !InStr(entry.Attributes, "L")
                    stack.Push(entry.Path)
                continue
            }
            visibility := ShouldIncludeEntry(entry.Path, entry.Name,
                entry.Attributes, noiseFilter, directory.FileNames, pinnedSet)
            if !visibility.Include {
                RecordHiddenNoiseItem(diagnostics, entry.Path,
                    entry.Name, sourceName, visibility.Reason)
                continue
            }
            if !ShouldIncludeFile(entry.Name, filter)
                continue
            if latest = "" || entry.Modified > latest
                latest := entry.Modified
        }
    }
    return latest
}

EnumerateDirectoryForScan(directoryPath) {
    entries := []
    fileNames := Map()
    try {
        Loop Files, directoryPath "\*", "FD" {
            isDirectory := InStr(A_LoopFileAttrib, "D") != 0
            entry := {Path: A_LoopFileFullPath, Name: A_LoopFileName,
                Modified: A_LoopFileTimeModified, Attributes: A_LoopFileAttrib,
                IsDirectory: isDirectory}
            entries.Push(entry)
            if !isDirectory
                fileNames[StrLower(entry.Name)] := true
        }
    }
    return {Entries: entries, FileNames: fileNames}
}

ShouldIncludeEntry(filePath, fileName, attributes, noiseFilter,
    directoryFileNames, pinnedSet := 0) {
    ; PopDrop-owned incomplete files are never user-visible, independent of
    ; the optional generic incomplete-download filter and pinned overrides.
    if RegExMatch(fileName, "i)\.popdrop-part$")
        return {Include: false, Reason: "PopDropIncompleteTransfer"}
    if IsPathInSet(pinnedSet, filePath)
        return {Include: true, Reason: "PinnedOverride"}
    if !IsObject(noiseFilter) || !noiseFilter.Enabled
        return {Include: true, Reason: ""}
    folded := StrLower(fileName)
    if SubStr(folded, 1, 2) = "~$"
        return {Include: false, Reason: "OfficeOwnerFile"}
    if SubStr(folded, 1, 7) = ".~lock." && SubStr(folded, -1) = "#"
        return {Include: false, Reason: "LibreOfficeLockFile"}
    if folded = "desktop.ini" || folded = "thumbs.db" || folded = "ehthumbs.db"
        return {Include: false, Reason: "WindowsMetadata"}
    if folded = ".ds_store"
        return {Include: false, Reason: "MacMetadata"}
    dot := InStr(fileName, ".",, -1)
    extension := dot > 0 ? StrLower(SubStr(fileName, dot)) : ""
    stem := dot > 0 ? SubStr(fileName, 1, dot - 1) : fileName
    if extension = ".laccdb" && directoryFileNames.Has(StrLower(stem ".accdb"))
        return {Include: false, Reason: "AccessLockFile"}
    if extension = ".ldb" && directoryFileNames.Has(StrLower(stem ".mdb"))
        return {Include: false, Reason: "AccessLockFile"}
    if (extension = ".dwl" || extension = ".dwl2")
        && directoryFileNames.Has(StrLower(stem ".dwg"))
        return {Include: false, Reason: "AutoCADInfoFile"}
    if noiseFilter.HideHidden && InStr(attributes, "H")
        return {Include: false, Reason: "HiddenAttribute"}
    if noiseFilter.HideSystem && InStr(attributes, "S")
        return {Include: false, Reason: "SystemAttribute"}
    if noiseFilter.HideTemporary && InStr(attributes, "T")
        return {Include: false, Reason: "TemporaryAttribute"}
    if noiseFilter.HideIncompleteDownloads
        && (extension = ".crdownload" || extension = ".part" || extension = ".download")
        return {Include: false, Reason: "IncompleteDownload"}
    if MatchesCompiledIgnorePattern(fileName, noiseFilter.CustomPatterns)
        return {Include: false, Reason: "CustomPattern"}
    if MatchesCompiledIgnorePattern(fileName, noiseFilter.SourceCustomPatterns)
        return {Include: false, Reason: "SourceCustomPattern"}
    return {Include: true, Reason: ""}
}

MatchesCompiledIgnorePattern(fileName, patterns) {
    if !IsObject(patterns)
        return false
    for pattern in patterns {
        try {
            if RegExMatch(fileName, pattern.Regex)
                return true
        }
    }
    return false
}

BuildPathSet(paths) {
    result := Map()
    for path in paths
        result[PathKey(path)] := true
    return result
}

IsPathInSet(pathSet, path) {
    return IsObject(pathSet) && pathSet.Has(PathKey(path))
}

RecordHiddenNoiseItem(diagnostics, path, name, sourceName, reason) {
    global NOISE_DIAGNOSTIC_LIMIT
    if !IsObject(diagnostics)
        return
    key := StrLower(sourceName) "|" PathKey(path)
    if diagnostics.Seen.Has(key)
        return
    diagnostics.Seen[key] := true
    diagnostics.Count += 1
    if diagnostics.Items.Length < NOISE_DIAGNOSTIC_LIMIT
        diagnostics.Items.Push({Name: name, Path: path,
            Source: sourceName, Reason: reason})
}

NoiseFilterReasonLabel(reason) {
    labels := Map("OfficeOwnerFile", "Office/WPS 锁定文件",
        "LibreOfficeLockFile", "LibreOffice/OpenOffice 锁定文件",
        "AccessLockFile", "Access 锁定文件",
        "AutoCADInfoFile", "AutoCAD 占用信息文件",
        "WindowsMetadata", "Windows 目录元数据",
        "MacMetadata", "macOS 目录元数据",
        "HiddenAttribute", "Hidden 属性", "SystemAttribute", "System 属性",
        "TemporaryAttribute", "Temporary 属性",
        "IncompleteDownload", "未完成下载",
        "PopDropIncompleteTransfer", "PopDrop 正在接收的临时文件",
        "CustomPattern", "全局自定义规则",
        "SourceCustomPattern", "来源附加规则")
    return labels.Has(reason) ? labels[reason] : reason
}

ShouldSkipScannedFolder(path, name, globalExcludedNames,
    excludedPaths, allowedPaths) {
    for excludedPath in excludedPaths {
        if IsSameOrDescendantPath(path, excludedPath)
            return true
    }
    allowed := false
    for allowedPath in allowedPaths {
        ; Also traverse ancestors of an explicitly allowed path so a nested
        ; override remains reachable.
        if IsSameOrDescendantPath(path, allowedPath)
            || IsSameOrDescendantPath(allowedPath, path) {
            allowed := true
            break
        }
    }
    if allowed
        return false
    for excludedName in globalExcludedNames {
        if StrLower(name) = StrLower(excludedName)
            return true
    }
    return false
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
    ; 自底向上的稳定归并排序，让 Launcher/All 文件夹保持 O(n log n)。
    ; AHK v2.0 没有支持自定义比较器的内置 Array.Sort。
    if files.Length <= 1
        return
    width := 1
    itemCount := files.Length
    while width < itemCount {
        merged := []
        left := 1
        while left <= itemCount {
            middle := Min(left + width, itemCount + 1)
            rightEnd := Min(left + width * 2, itemCount + 1)
            leftIndex := left
            rightIndex := middle
            while leftIndex < middle || rightIndex < rightEnd {
                if rightIndex >= rightEnd
                    || (leftIndex < middle
                        && CompareFiles(files[leftIndex], files[rightIndex], sortMode) <= 0) {
                    merged.Push(files[leftIndex])
                    leftIndex += 1
                } else {
                    merged.Push(files[rightIndex])
                    rightIndex += 1
                }
            }
            left := rightEnd
        }
        files := merged
        width *= 2
    }
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
        diagnostics := {Count: 0, Items: [], Seen: Map()}
        pinnedSet := BuildPathSet(request.PinnedPaths)
        result := {Version: 3, Generation: request.Generation,
            Fingerprint: request.Fingerprint, Folders: [], Recent: [],
            HiddenCount: 0, HiddenItems: []}
        for folder in request.Folders {
            state := DirExist(folder.Path) ? "OK" : "Unavailable"
            files := state = "OK" ? GetSortedItems(folder.Path,
                folder.MaxFilesPerFolder, folder.DisplayScope, folder.SortMode,
                folder.Filter, folder.FolderTimeMode,
                request.GlobalExcludedNames, folder.ExcludedPaths,
                folder.AllowedExcludedPaths, folder.NoiseFilter,
                pinnedSet, folder.Name, diagnostics) : []
            result.Folders.Push({Name: folder.Name, Path: folder.Path,
                State: state, Files: files})
        }
        result.Recent := GetWindowsRecentFiles(request.RecentFileCount)
        result.HiddenCount := diagnostics.Count
        result.HiddenItems := diagnostics.Items
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
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    version := Integer(IniRead(path, "Meta", "Version", "0"))
    if version != 4
        throw Error("unsupported request version")
    request := {Generation: IniRead(path, "Meta", "Generation", ""),
        Fingerprint: IniRead(path, "Meta", "Fingerprint", ""), Folders: [],
        RecentFileCount: Integer(IniRead(path, "Meta", "RecentFileCount", "12")),
        GlobalExcludedNames: [], PinnedPaths: []}
    globalNameCount := Integer(
        IniRead(path, "Meta", "GlobalExcludedNameCount", "0"))
    Loop globalNameCount {
        name := Trim(IniRead(path, "Meta",
            "GlobalExcludedName" Format("{:03}", A_Index), ""))
        if name != ""
            request.GlobalExcludedNames.Push(name)
    }
    pinnedCount := Integer(IniRead(path, "Meta", "PinnedPathCount", "0"))
    Loop pinnedCount {
        pinnedPath := NormalizePath(IniRead(path, "Meta",
            "PinnedPath" Format("{:03}", A_Index), ""))
        if pinnedPath != ""
            request.PinnedPaths.Push(pinnedPath)
    }
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

        rawScope := StrLower(Trim(
            IniRead(path, section, "DisplayScope", "")))
        oldRecursive := IniRead(path, section, "IncludeSubfolders", "0") = "1"
        if rawScope = StrLower(SCOPE_FILES_AND_FOLDERS)
            folderScope := SCOPE_FILES_AND_FOLDERS
        else if rawScope = StrLower(SCOPE_RECURSIVE_FILES)
            folderScope := SCOPE_RECURSIVE_FILES
        else if rawScope = StrLower(SCOPE_FILES_ONLY)
            folderScope := SCOPE_FILES_ONLY
        else
            folderScope := oldRecursive ? SCOPE_RECURSIVE_FILES : SCOPE_FILES_ONLY

        rawFolderTime := StrLower(Trim(
            IniRead(path, section, "FolderTimeMode", "DirectoryModified")))
        folderTimeMode := rawFolderTime = StrLower(FOLDER_TIME_LATEST_CONTENT)
            ? FOLDER_TIME_LATEST_CONTENT : FOLDER_TIME_MODIFIED

        excludedPaths := []
        allowedPaths := []
        excludedCount := Integer(
            IniRead(path, section, "ExcludedPathCount", "0"))
        Loop excludedCount {
            value := NormalizePath(IniRead(path, section,
                "ExcludedPath" Format("{:03}", A_Index), ""))
            if value != ""
                excludedPaths.Push(value)
        }
        allowedCount := Integer(
            IniRead(path, section, "AllowedPathCount", "0"))
        Loop allowedCount {
            value := NormalizePath(IniRead(path, section,
                "AllowedPath" Format("{:03}", A_Index), ""))
            if value != ""
                allowedPaths.Push(value)
        }
        customTexts := []
        customCount := Integer(IniRead(path, section, "CustomPatternCount", "0"))
        Loop customCount
            customTexts.Push(IniRead(path, section,
                "CustomPattern" Format("{:03}", A_Index), ""))
        sourceTexts := []
        sourceCount := Integer(IniRead(path, section, "SourcePatternCount", "0"))
        Loop sourceCount
            sourceTexts.Push(IniRead(path, section,
                "SourcePattern" Format("{:03}", A_Index), ""))
        customCompiled := CompileIgnorePatterns(customTexts, "[" section "]")
        sourceCompiled := CompileIgnorePatterns(sourceTexts, "[" section "] 来源附加规则")
        noiseFilter := {Enabled: IniRead(path, section, "NoiseEnabled", "1") = "1",
            HideHidden: IniRead(path, section, "HideHidden", "1") = "1",
            HideSystem: IniRead(path, section, "HideSystem", "1") = "1",
            HideTemporary: IniRead(path, section, "HideTemporaryAttribute", "0") = "1",
            HideIncompleteDownloads: IniRead(path, section, "HideIncompleteDownloads", "0") = "1",
            CustomPatterns: customCompiled.Patterns,
            SourceCustomPatterns: sourceCompiled.Patterns}
        request.Folders.Push({
            Name: IniRead(path, section, "Name", ""),
            Path: IniRead(path, section, "Path", ""),
            IncludeSubfolders: folderScope = SCOPE_RECURSIVE_FILES,
            DisplayScope: folderScope,
            FolderTimeMode: folderTimeMode,
            MaxFilesPerFolder: folderMax,
            SortMode: folderSort,
            Filter: filter,
            NoiseFilter: noiseFilter,
            ExcludedPaths: excludedPaths,
            AllowedExcludedPaths: allowedPaths
        })
    }
    return request
}

WriteScanResultAtomic(result, readyPath, includeDiagnostics := true) {
    tempPath := readyPath ".writing"
    try FileDelete(tempPath)
    try FileDelete(readyPath)
    IniWrite("3", tempPath, "Meta", "Version")
    IniWrite(result.Generation, tempPath, "Meta", "Generation")
    IniWrite(result.Fingerprint, tempPath, "Meta", "Fingerprint")
    IniWrite(A_Now, tempPath, "Meta", "CompletedAt")
    IniWrite(result.Folders.Length, tempPath, "Meta", "FolderCount")
    IniWrite(result.Recent.Length, tempPath, "Meta", "RecentCount")
    hiddenCount := HasProp(result, "HiddenCount") ? result.HiddenCount : 0
    hiddenItems := includeDiagnostics && HasProp(result, "HiddenItems")
        ? result.HiddenItems : []
    IniWrite(hiddenCount, tempPath, "Meta", "HiddenCount")
    IniWrite(hiddenItems.Length, tempPath, "Meta", "HiddenRecordCount")
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
            IniWrite(item.IsDirectory ? "1" : "0", tempPath, section, key "IsDirectory")
            IniWrite(item.TimeKind, tempPath, section, key "TimeKind")
        }
    }
    for index, item in result.Recent {
        section := "Recent" Format("{:03}", index)
        IniWrite(item.Path, tempPath, section, "Path")
        IniWrite(item.Name, tempPath, section, "Name")
        IniWrite(item.Modified, tempPath, section, "Modified")
    }
    for index, item in hiddenItems {
        section := "Hidden" Format("{:03}", index)
        IniWrite(item.Name, tempPath, section, "Name")
        IniWrite(item.Path, tempPath, section, "Path")
        IniWrite(item.Source, tempPath, section, "Source")
        IniWrite(item.Reason, tempPath, section, "Reason")
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
    global RecentFileCount, GlobalExcludedFolderNames, GlobalNoiseFilter, PinnedPaths
    raw := "v4|recent=" RecentFileCount
        . "|excludedNames=" JoinArray(GlobalExcludedFolderNames, ",")
        . "|noiseEnabled=" (GlobalNoiseFilter.Enabled ? 1 : 0)
        . "|hidden=" (GlobalNoiseFilter.HideHidden ? 1 : 0)
        . "|system=" (GlobalNoiseFilter.HideSystem ? 1 : 0)
        . "|temporary=" (GlobalNoiseFilter.HideTemporary ? 1 : 0)
        . "|downloads=" (GlobalNoiseFilter.HideIncompleteDownloads ? 1 : 0)
        . "|patterns=" JoinArray(GlobalNoiseFilter.CustomPatternTexts, Chr(30))
        . "|pinned=" JoinNormalizedPaths(PinnedPaths)
    for folder in settings {
        raw .= "|" folder.Name "|" StrLower(RTrim(folder.Path, "\"))
        raw .= "|mode=" folder.Mode
        raw .= "|sub=" (folder.IncludeSubfolders ? 1 : 0)
        raw .= "|scope=" folder.DisplayScope
        raw .= "|foldertime=" folder.FolderTimeMode
        raw .= "|max=" folder.MaxFilesPerFolder "|sort=" folder.SortMode
        raw .= "|filter=" folder.Filter.Mode
        raw .= "|ext=" JoinArray(folder.Filter.Extensions, ",")
        raw .= "|excludedPaths=" JoinNormalizedPaths(folder.ExcludedPaths)
        raw .= "|allowedPaths=" JoinNormalizedPaths(folder.AllowedExcludedPaths)
        raw .= "|noiseMode=" folder.NoiseFilterMode
        raw .= "|sourcePatterns=" JoinArray(folder.SourceCustomPatternTexts, Chr(30))
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
        if version != 3
            return 0
        generation := IniRead(path, "Meta", "Generation", "")
        fingerprint := IniRead(path, "Meta", "Fingerprint", "")
        if expectedGeneration != "" && generation != expectedGeneration
            return 0
        if expectedFingerprint != "" && fingerprint != expectedFingerprint
            return 0
        result := {Version: version, Generation: generation, Fingerprint: fingerprint,
            Folders: [], Recent: [], HiddenCount: Integer(
                IniRead(path, "Meta", "HiddenCount", "0")), HiddenItems: []}
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
                    Modified: IniRead(path, section, key "Modified", ""),
                    IsDirectory: IniRead(path, section, key "IsDirectory", "0") = "1",
                    TimeKind: IniRead(path, section, key "TimeKind", "File")})
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
        hiddenRecordCount := Integer(IniRead(path, "Meta", "HiddenRecordCount", "0"))
        if hiddenRecordCount < 0 || hiddenRecordCount > 200
            return 0
        Loop hiddenRecordCount {
            section := "Hidden" Format("{:03}", A_Index)
            itemPath := IniRead(path, section, "Path", "")
            if itemPath != ""
                result.HiddenItems.Push({Name: IniRead(path, section, "Name", GetFileName(itemPath)),
                    Path: itemPath, Source: IniRead(path, section, "Source", ""),
                    Reason: IniRead(path, section, "Reason", "")})
        }
        return result
    } catch {
        return 0
    }
}

WriteScanRequest(path, generation) {
    global LastValidFolderSettings, CurrentConfigFingerprint, RecentFileCount
    global GlobalExcludedFolderNames, PinnedPaths
    try FileDelete(path)
    IniWrite("4", path, "Meta", "Version")
    IniWrite(generation, path, "Meta", "Generation")
    IniWrite(CurrentConfigFingerprint, path, "Meta", "Fingerprint")
    IniWrite(LastValidFolderSettings.Length, path, "Meta", "FolderCount")
    IniWrite(RecentFileCount, path, "Meta", "RecentFileCount")
    IniWrite(GlobalExcludedFolderNames.Length, path,
        "Meta", "GlobalExcludedNameCount")
    for index, name in GlobalExcludedFolderNames
        IniWrite(name, path, "Meta",
            "GlobalExcludedName" Format("{:03}", index))
    IniWrite(PinnedPaths.Length, path, "Meta", "PinnedPathCount")
    for index, pinnedPath in PinnedPaths
        IniWrite(pinnedPath, path, "Meta", "PinnedPath" Format("{:03}", index))
    for index, folder in LastValidFolderSettings {
        section := "Folder" Format("{:03}", index)
        IniWrite(folder.Name, path, section, "Name")
        IniWrite(folder.Path, path, section, "Path")
        IniWrite(folder.IncludeSubfolders ? "1" : "0", path, section, "IncludeSubfolders")
        IniWrite(folder.DisplayScope, path, section, "DisplayScope")
        IniWrite(folder.FolderTimeMode, path, section, "FolderTimeMode")
        IniWrite(folder.MaxFilesPerFolder, path, section, "MaxFilesPerFolder")
        IniWrite(folder.SortMode, path, section, "SortMode")
        IniWrite(folder.Filter.Mode, path, section, "FilterMode")
        IniWrite(JoinArray(folder.Filter.Extensions, ","), path, section, "FileExtensions")
        noise := folder.NoiseFilter
        IniWrite(noise.Enabled ? "1" : "0", path, section, "NoiseEnabled")
        IniWrite(noise.HideHidden ? "1" : "0", path, section, "HideHidden")
        IniWrite(noise.HideSystem ? "1" : "0", path, section, "HideSystem")
        IniWrite(noise.HideTemporary ? "1" : "0", path, section, "HideTemporaryAttribute")
        IniWrite(noise.HideIncompleteDownloads ? "1" : "0", path, section, "HideIncompleteDownloads")
        IniWrite(noise.CustomPatterns.Length, path, section, "CustomPatternCount")
        for patternIndex, pattern in noise.CustomPatterns
            IniWrite(pattern.Text, path, section, "CustomPattern" Format("{:03}", patternIndex))
        IniWrite(noise.SourceCustomPatterns.Length, path, section, "SourcePatternCount")
        for patternIndex, pattern in noise.SourceCustomPatterns
            IniWrite(pattern.Text, path, section, "SourcePattern" Format("{:03}", patternIndex))
        IniWrite(folder.ExcludedPaths.Length, path, section, "ExcludedPathCount")
        for pathIndex, excludedPath in folder.ExcludedPaths
            IniWrite(excludedPath, path, section,
                "ExcludedPath" Format("{:03}", pathIndex))
        IniWrite(folder.AllowedExcludedPaths.Length, path,
            section, "AllowedPathCount")
        for pathIndex, allowedPath in folder.AllowedExcludedPaths
            IniWrite(allowedPath, path, section,
                "AllowedPath" Format("{:03}", pathIndex))
    }
}

StartScanWorkerProcess(requestPath, readyPath) {
    if A_IsCompiled {
        executable := A_ScriptFullPath
        arguments := [A_ScriptFullPath, "--scan-worker", requestPath, readyPath]
    } else {
        executable := A_AhkPath
        arguments := [A_AhkPath, A_ScriptFullPath,
            "--scan-worker", requestPath, readyPath]
    }
    commandLine := ""
    for argument in arguments
        commandLine .= (commandLine = "" ? "" : " ")
            . QuoteWindowsArgument(argument)
    commandBuffer := Buffer((StrLen(commandLine) + 1) * 2, 0)
    StrPut(commandLine, commandBuffer)
    startupInfoSize := A_PtrSize = 8 ? 104 : 68
    startupInfo := Buffer(startupInfoSize, 0)
    NumPut("uint", startupInfoSize, startupInfo, 0)
    processInfo := Buffer(A_PtrSize * 2 + 8, 0)
    if !DllCall("kernel32\CreateProcessW",
        "wstr", executable, "ptr", commandBuffer.Ptr,
        "ptr", 0, "ptr", 0, "int", false,
        "uint", 0x08000000, "ptr", 0, "wstr", A_ScriptDir,
        "ptr", startupInfo.Ptr, "ptr", processInfo.Ptr, "int")
        throw OSError(A_LastError, "无法启动扫描进程")
    processHandle := NumGet(processInfo, 0, "ptr")
    threadHandle := NumGet(processInfo, A_PtrSize, "ptr")
    pid := NumGet(processInfo, A_PtrSize * 2, "uint")
    if threadHandle
        DllCall("kernel32\CloseHandle", "ptr", threadHandle)
    if processHandle
        DllCall("kernel32\CloseHandle", "ptr", processHandle)
    return pid
}

StartBackgroundScan() {
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
        WorkerPid := StartScanWorkerProcess(requestPath, readyPath)
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
    global PendingFileOperationRefresh
    global CacheFilePath, CacheWritable, CacheWriteWarningShown
    global Panel, PanelVisible, StatusKind
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
            if (changed || PendingFileOperationRefresh)
                && IsObject(Panel) && PanelVisible {
                PopulatePanel()
                PopulateRecentSidebar()
                SetTimer(UpdateSelectionStatus, 0)
                StatusKind := "default"
            }
            if CacheWritable {
                try {
                    cacheTemp := CacheFilePath ".writing"
                    WriteScanResultAtomic(result, cacheTemp, false)
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
    StartBackgroundScan()
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
    global ItemPaths, OPEN_MODE_SINGLE
    if !ItemPaths.Has(row)
        return
    path := ItemPaths[row]
    if GetPointerModifierMask() != 0
        return
    ; 文件夹始终保持双击激活，不受单击模式影响。
    if IsListItemFolder(list, row, path) {
        OpenFolderPath(path)
        return
    }
    ; 单击模式的第一次合法释放已经打开；忽略随后产生的双击通知。
    effectiveMode := GetEffectiveOpenMode(
        GetListItemOpenContext(list, row))
    if effectiveMode = OPEN_MODE_SINGLE
        return
    OpenItemWithDefaultApplication(path)
}

OpenRecentItem(list, row) {
    global RecentItemPaths, OPEN_MODE_SINGLE
    if !RecentItemPaths.Has(row)
        return
    if GetPointerModifierMask() != 0
        return
    effectiveMode := GetEffectiveOpenMode(
        GetListItemOpenContext(list, row))
    if effectiveMode = OPEN_MODE_SINGLE
        return
    OpenItemWithDefaultApplication(RecentItemPaths[row])
}

GetListItemOpenContext(list, row) {
    global FileView, RecentView, ItemOpenContexts
    if IsObject(FileView) && list.Hwnd = FileView.Hwnd
        && ItemOpenContexts.Has(row)
        return ItemOpenContexts[row]
    if IsObject(RecentView) && list.Hwnd = RecentView.Hwnd
        return {Area: "Recent"}
    return {Area: "Global"}
}

GetEffectiveOpenMode(itemContext) {
    global GlobalOpenFileMode, LastValidFolderSettings
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE
    global SOURCE_OPEN_MODE_INHERIT

    if IsObject(itemContext) && HasProp(itemContext, "Area")
        && itemContext.Area = "Source"
        && HasProp(itemContext, "SourceId") {
        for folder in LastValidFolderSettings {
            if StrLower(folder.SourceId) != StrLower(itemContext.SourceId)
                continue
            sourceMode := ParseSourceOpenFileMode(folder.OpenFileMode)
            if sourceMode = OPEN_MODE_SINGLE
                return OPEN_MODE_SINGLE
            if sourceMode = OPEN_MODE_DOUBLE
                return OPEN_MODE_DOUBLE
            break
        }
    }
    ; 固定项、最近文件和没有明确来源上下文的项目统一使用全局值。
    return ParseGlobalOpenFileMode(GlobalOpenFileMode)
}

IsListItemFolder(list, row, path := "") {
    global FileView, ItemKinds
    if path != "" && DirExist(path)
        return true
    if IsObject(FileView) && list.Hwnd = FileView.Hwnd
        && ItemKinds.Has(row)
        return ItemKinds[row] = "Folder"
    return false
}

OpenItemWithDefaultApplication(path) {
    if DirExist(path) {
        OpenFolderPath(path)
        return
    }
    if !FileExist(path) {
        ShowPanelMsgBox("文件不存在或当前无法访问：`n" path, "无法打开", "Icon!")
        return false
    }
    try Run(path)
    catch as err {
        ShowPanelMsgBox("无法打开文件：`n" path "`n`n" err.Message, "打开失败", "Iconx")
        return false
    }
    return true
}

InstallPanelHotkeys() {
    HotIf(IsPanelFileViewActive)
    Hotkey("Enter", PanelOpenSelection)
    Hotkey("Delete", PanelDeleteSelection)
    Hotkey("+F10", PanelShowSystemMenu)
    Hotkey("^Enter", PanelRevealSelection)
    Hotkey("^c", PanelCopyFileObjects)
    Hotkey("^+c", PanelCopyPaths)
    HotIf()
}

IsPanelFileViewActive(*) {
    global Panel, PanelVisible, FileView, RecentView
    if !PanelVisible || !IsObject(Panel)
        return false
    focused := DllCall("user32\GetFocus", "ptr")
    return (IsObject(FileView) && focused = FileView.Hwnd)
        || (IsObject(RecentView) && focused = RecentView.Hwnd)
}

GetActiveSelectionContext() {
    global FileView, RecentView, ItemPaths, RecentItemPaths
    focused := DllCall("user32\GetFocus", "ptr")
    if IsObject(FileView) && focused = FileView.Hwnd {
        paths := GetSelectedExistingPaths()
        focusedRow := FileView.GetNext(0, "F")
        clicked := focusedRow && ItemPaths.Has(focusedRow)
            ? ItemPaths[focusedRow] : (paths.Length ? paths[1] : "")
        return {Paths: paths, Clicked: clicked, Hwnd: FileView.Hwnd}
    }
    if IsObject(RecentView) && focused = RecentView.Hwnd {
        row := RecentView.GetNext(0)
        if row && RecentItemPaths.Has(row)
            return {Paths: [RecentItemPaths[row]], Clicked: RecentItemPaths[row],
                Hwnd: RecentView.Hwnd}
    }
    return {Paths: [], Clicked: "", Hwnd: 0}
}

PanelOpenSelection(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length
        OpenSelectedItems(context.Paths)
}

PanelDeleteSelection(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length
        DeletePathsToRecycleBin(context.Paths)
}

PanelShowSystemMenu(*) {
    global Panel
    context := GetActiveSelectionContext()
    if context.Paths.Length
        ShowShellContextMenu(GetShellMenuPaths(context.Paths, context.Clicked),
            Panel.Hwnd, -1, -1)
}

PanelRevealSelection(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length
        RevealPathsInExplorer(context.Paths)
}

PanelCopyFileObjects(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length
        CopyFileObjectsToClipboard(context.Paths)
}

PanelCopyPaths(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length
        CopyPathTextToClipboard(context.Paths)
}

OpenSelectedItems(paths, *) {
    for path in paths {
        OpenItemWithDefaultApplication(path)
    }
}

CanRevealTogether(paths) {
    if !paths.Length
        return false
    parent := GetParentPath(paths[1])
    for path in paths {
        if !FileExist(path) || !PathsEqual(GetParentPath(path), parent)
            return false
    }
    return DirExist(parent) != ""
}

RevealPathsInExplorer(paths, *) {
    if !CanRevealTogether(paths) {
        ShowPanelMsgBox(
            "只能同时定位位于同一父文件夹中的项目；请缩小选择范围后重试。",
            "在文件资源管理器中显示", "Iconi")
        return
    }

    parentPath := GetParentPath(paths[1])
    parentPidl := 0
    fullPidls := []
    try {
        if DllCall("shell32\SHParseDisplayName", "wstr", parentPath,
            "ptr", 0, "ptr*", &parentPidl, "uint", 0, "ptr", 0) != 0
            throw Error("Windows Shell 无法解析父文件夹。")
        childArray := Buffer(paths.Length * A_PtrSize, 0)
        for index, path in paths {
            fullPidl := 0
            if DllCall("shell32\SHParseDisplayName", "wstr", path,
                "ptr", 0, "ptr*", &fullPidl, "uint", 0, "ptr", 0) != 0
                throw Error("Windows Shell 无法解析所选项目。")
            fullPidls.Push(fullPidl)
            childPidl := DllCall("shell32\ILFindLastID", "ptr", fullPidl, "ptr")
            NumPut("ptr", childPidl, childArray, (index - 1) * A_PtrSize)
        }
        hr := DllCall("shell32\SHOpenFolderAndSelectItems", "ptr", parentPidl,
            "uint", paths.Length, "ptr", childArray.Ptr, "uint", 0, "int")
        if hr != 0
            throw Error("资源管理器未接受定位请求（HRESULT "
                Format("0x{:08X}", hr & 0xFFFFFFFF) "）。")
    } catch as err {
        ShowPanelMsgBox("无法在文件资源管理器中显示所选项目：`n"
            err.Message, "定位失败", "Iconx")
    } finally {
        for pidl in fullPidls
            DllCall("ole32\CoTaskMemFree", "ptr", pidl)
        if parentPidl
            DllCall("ole32\CoTaskMemFree", "ptr", parentPidl)
    }
}

CopyFileObjectsToClipboard(paths, *) {
    global Panel
    existing := []
    for path in paths {
        if FileExist(path) && !ArrayContainsPath(existing, path)
            existing.Push(path)
    }
    if !existing.Length {
        ShowPanelMsgBox("所选项目均不存在或当前不可访问。",
            "复制文件", "Icon!")
        return false
    }
    hDrop := CreateHDrop(existing)
    if !hDrop {
        ShowPanelMsgBox("无法创建 Windows 文件剪贴板数据。",
            "复制文件失败", "Iconx")
        return false
    }

    if !DllCall("user32\OpenClipboard", "ptr", Panel.Hwnd, "int") {
        DllCall("kernel32\GlobalFree", "ptr", hDrop)
        ShowPanelMsgBox("剪贴板当前正被其他程序使用，请稍后重试。",
            "复制文件失败", "Icon!")
        return false
    }
    success := false
    try {
        if !DllCall("user32\EmptyClipboard", "int")
            throw Error("无法清空剪贴板。")
        if !DllCall("user32\SetClipboardData", "uint", 15,
            "ptr", hDrop, "ptr")
            throw Error("Windows 拒绝了文件剪贴板数据。")
        ; SetClipboardData 成功后所有权转移给系统。
        hDrop := 0
        success := true
    } catch as err {
        ShowPanelMsgBox(err.Message, "复制文件失败", "Iconx")
    } finally {
        DllCall("user32\CloseClipboard")
        if hDrop
            DllCall("kernel32\GlobalFree", "ptr", hDrop)
    }
    if success
        SetUserStatus("已复制 " existing.Length " 个文件系统项目")
    return success
}

CopyPathTextToClipboard(paths, *) {
    normalized := []
    for path in paths {
        if !ArrayContainsPath(normalized, path)
            normalized.Push(NormalizePath(path))
    }
    if !normalized.Length
        return false
    A_Clipboard := JoinArray(normalized, "`r`n")
    if !ClipWait(1) {
        ShowPanelMsgBox("无法写入文本剪贴板，请稍后重试。",
            "复制路径失败", "Iconx")
        return false
    }
    SetUserStatus("已复制 " normalized.Length " 条完整路径")
    return true
}

SetUserStatus(text) {
    global StatusText, StatusKind, CurrentStatusAction, LastOpenAppUndoState
    if IsObject(StatusText) {
        CurrentStatusAction := 0
        LastOpenAppUndoState := 0
        StatusKind := "user"
        StatusText.Text := text
    }
}

SetActionStatus(text, action) {
    global StatusText, StatusKind, CurrentStatusAction
    CurrentStatusAction := action
    if IsObject(StatusText) {
        StatusKind := "user"
        StatusText.Text := text
    }
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
    CancelFilePointerGesture()
    if !row || !RecentItemPaths.Has(row)
        return
    if !IsListRowSelected(list.Hwnd, row) {
        list.Modify(0, "-Select -Focus")
        list.Modify(row, "Select Focus Vis")
    }
    path := RecentItemPaths[row]
    if !FileExist(path) {
        ShowPanelMsgBox("文件不存在或当前无法访问：`n" path, "右键菜单", "Icon!")
        return
    }
    if GetKeyState("Shift", "P")
        ShowShellContextMenu([path], list.Gui.Hwnd, x, y)
    else
        ShowPopDropContextMenu([path], path, list.Gui.Hwnd, x, y)
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
        StatusText.Text := "已选择 " selectedRows.Length " 个项目；可继续 Ctrl/Shift 选择。"
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
    global PinnedPaths

    try selected := SelectPanelFile("M3", , "选择要加入固定项的文件")
    catch
        return
    if !IsObject(selected)
        return

    newPaths := []
    for path in selected {
        path := NormalizePath(path)
        if path != ""
            && !ArrayContainsPath(PinnedPaths, path)
            && !ArrayContainsPath(newPaths, path)
            newPaths.Push(path)
    }
    if newPaths.Length {
        PrependPinnedPaths(newPaths)
        SavePinnedFiles()
        PopulatePanel()
    }
}

AddSelectionToPinned(paths, *) {
    global PinnedPaths
    additions := []
    for path in paths {
        if FileExist(path) && !ArrayContainsPath(PinnedPaths, path)
            && !ArrayContainsPath(additions, path)
            additions.Push(NormalizePath(path))
    }
    if !additions.Length
        return
    original := PinnedPaths.Clone()
    PrependPinnedPaths(additions)
    try {
        SavePinnedFiles()
        PopulatePanel()
        SetUserStatus("已添加到固定项：" additions.Length " 项")
    } catch as err {
        PinnedPaths := original
        ShowPanelMsgBox("无法保存固定项：`n" err.Message,
            "添加固定项失败", "Iconx")
    }
}

RemoveSelectionFromPinned(paths, *) {
    global PinnedPaths
    original := PinnedPaths.Clone()
    removed := 0
    for path in paths {
        index := FindPathIndex(PinnedPaths, path)
        if index {
            PinnedPaths.RemoveAt(index)
            removed += 1
        }
    }
    if !removed
        return
    try {
        SavePinnedFiles()
        PopulatePanel()
        SetUserStatus("已从固定项移除：" removed " 项")
    } catch as err {
        PinnedPaths := original
        ShowPanelMsgBox("无法保存固定项：`n" err.Message,
            "移除固定项失败", "Iconx")
    }
}

PinDroppedFiles(guiObj, guiCtrlObj, fileArray, x, y) {
    ; WM_DROPFILES arrives immediately after the mouse button is released,
    ; which is also when a pending temporary-mode timer may try to hide the
    ; panel. Pause that timer for the whole save/render operation.
    BeginAutoHidePause()
    try {
        PinDroppedItems(fileArray)
    } finally {
        try {
            ; A successful drop is an interaction with PopDrop. Bring the
            ; panel back if a previously queued timer won the race, then keep
            ; it active so temporary mode does not immediately hide it again.
            KeepTemporaryPanelVisibleAfterDrag()
        } finally {
            EndAutoHidePause()
        }
    }
}

KeepTemporaryPanelVisibleAfterDrag() {
    global Panel, PanelVisible, WindowMode, WINDOW_MODE_TEMPORARY

    if WindowMode != WINDOW_MODE_TEMPORARY || !IsObject(Panel)
        return

    if !DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int")
        try Panel.Show("NA")

    PanelVisible := DllCall(
        "user32\IsWindowVisible",
        "ptr", Panel.Hwnd,
        "int"
    )
    if PanelVisible
        try WinActivate("ahk_id " Panel.Hwnd)
}

PinDroppedItems(fileArray) {
    global PinnedPaths, StatusKind

    originalPinnedPaths := PinnedPaths.Clone()
    newPaths := []
    addedFileCount := 0
    addedFolderCount := 0
    duplicateCount := 0
    unavailableCount := 0

    for droppedPath in fileArray {
        path := NormalizePath(droppedPath)
        if path = "" {
            unavailableCount += 1
            continue
        }

        attributes := FileExist(path)
        if !attributes {
            unavailableCount += 1
            continue
        }
        if IsDuplicatePinnedCandidate(PinnedPaths, newPaths, path) {
            duplicateCount += 1
            continue
        }

        newPaths.Push(path)
        if InStr(attributes, "D")
            addedFolderCount += 1
        else
            addedFileCount += 1
    }

    if newPaths.Length {
        PrependPinnedPaths(newPaths)
        try SavePinnedFiles()
        catch as err {
            PinnedPaths := originalPinnedPaths
            try SavePinnedFiles()
            ShowPanelMsgBox(
                "无法保存拖入的固定项：`n" err.Message,
                "固定项失败",
                "Iconx"
            )
            return {
                Success: 0,
                Failed: newPaths.Length + unavailableCount,
                Skipped: duplicateCount,
                Changed: false
            }
        }
        PopulatePanel()
    }

    message := ""
    if addedFileCount
        message := "已加入固定项：" addedFileCount " 个文件"
    if addedFolderCount {
        if message != ""
            message .= "、"
        else
            message := "已加入固定项："
        message .= addedFolderCount " 个文件夹"
    }
    if message = ""
        message := "没有新增固定项"
    if duplicateCount
        message .= "；" duplicateCount " 个重复项已跳过"
    if unavailableCount
        message .= "；" unavailableCount " 个路径不可用"

    ; A drop result is more important than a previous selection-path message.
    StatusKind := "default"
    SetBackgroundStatus(message, 5000)
    return {
        Success: newPaths.Length,
        Failed: unavailableCount,
        Skipped: duplicateCount,
        Changed: newPaths.Length > 0
    }
}

IsDuplicatePinnedCandidate(existingPaths, pendingPaths, path) {
    return ArrayContainsPath(existingPaths, path)
        || ArrayContainsPath(pendingPaths, path)
}

RemovePinnedFile(*) {
    global FileView, ItemPaths, PinnedPaths
    rows := GetSelectedFileRows()
    if !rows.Length {
        ShowPanelMsgBox("请先在“固定项”分组中选择一个或多个项目。", "移出固定项", "Iconi")
        return
    }

    indexes := []
    for row in rows {
        index := FindPathIndex(PinnedPaths, ItemPaths[row])
        if index
            indexes.Push(index)
    }
    if !indexes.Length {
        ShowPanelMsgBox("选择的项目中没有固定项。", "移出固定项", "Iconi")
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

PrependPinnedPaths(paths) {
    global PinnedPaths
    ; Insert in reverse so the incoming batch keeps its original order.
    Loop paths.Length {
        sourceIndex := paths.Length - A_Index + 1
        PinnedPaths.InsertAt(1, paths[sourceIndex])
    }
}

SavePinnedFiles() {
    AtomicConfigEdit(WritePinnedFilesConfig)
}

WritePinnedFilesConfig(tempPath) {
    global PinnedPaths, CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    doc.ReplaceSection("PinnedFiles",
        ConfigEntriesFromValues(PinnedPaths, "File"), 2)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

ArrayContainsPath(paths, target) {
    return FindPathIndex(paths, target) != 0
}

FindPathIndex(paths, target) {
    target := PathKey(target)
    for index, path in paths {
        if PathKey(path) = target
            return index
    }
    return 0
}

OpenConfigLegacy(*) {
    global Panel, SettingsDialog, LastValidFolderSettings
    global GlobalOpenFileMode, OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE
    global SOURCE_OPEN_MODE_INHERIT

    CancelFilePointerGesture()
    if IsObject(SettingsDialog) {
        try {
            SettingsDialog.Show()
            WinActivate("ahk_id " SettingsDialog.Hwnd)
            return
        }
    }

    BeginAutoHidePause()
    settingsGui := Gui("+Owner" Panel.Hwnd " +MinSize620x500",
        "PopDrop 文件打开设置")
    SettingsDialog := settingsGui
    settingsGui.MarginX := 16
    settingsGui.MarginY := 14
    settingsGui.SetFont("s9", "Microsoft YaHei UI")

    settingsGui.AddText("xm ym w580", "全局打开文件")
        .SetFont("s10 Bold")
    globalDouble := settingsGui.AddRadio(
        "xm y+10 Group " (GlobalOpenFileMode = OPEN_MODE_DOUBLE
            ? "Checked" : ""), "双击（默认）")
    globalSingle := settingsGui.AddRadio(
        "x+28 yp " (GlobalOpenFileMode = OPEN_MODE_SINGLE
            ? "Checked" : ""), "单击")
    settingsGui.AddText("xm y+10 w580 c555555",
        "单击会立即打开文件。按住 Ctrl 或 Shift 可以多选，拖拽不受影响；"
        . "文件夹仍然需要双击打开。")

    settingsGui.AddText("xm y+18 w580", "监控来源")
        .SetFont("s10 Bold")
    sourceList := settingsGui.AddListView(
        "xm y+8 w580 h240 Report -Multi", ["来源", "路径", "打开文件"])
    sourceState := {
        Rows: Map(),
        Modes: Map(),
        Updating: false,
        List: sourceList
    }
    for folder in LastValidFolderSettings {
        mode := ParseSourceOpenFileMode(folder.OpenFileMode)
        row := sourceList.Add("", folder.Name, folder.Path,
            SourceOpenModeLabel(mode))
        sourceState.Rows[row] := {
            Id: folder.SourceId,
            Name: folder.Name,
            Path: folder.Path
        }
        sourceState.Modes[folder.SourceId] := mode
    }
    sourceList.ModifyCol(1, 120)
    sourceList.ModifyCol(2, 300)
    sourceList.ModifyCol(3, 125)

    sourceHint := settingsGui.AddText("xm y+10 w580 c555555",
        "选择一个来源后设置覆盖方式。继承项会随全局设置立即变化。")
    sourceInherit := settingsGui.AddRadio(
        "xm y+8 Group Disabled", "跟随全局设置")
    sourceSingle := settingsGui.AddRadio("x+18 yp Disabled", "单击")
    sourceDouble := settingsGui.AddRadio("x+18 yp Disabled", "双击")
    sourceState.Controls := {
        Inherit: sourceInherit,
        Single: sourceSingle,
        Double: sourceDouble,
        Hint: sourceHint
    }
    sourceList.OnEvent("ItemSelect",
        OpenModeSourceSelected.Bind(sourceState))
    sourceInherit.OnEvent("Click", SetSourceOpenModeFromDialog.Bind(
        sourceState, SOURCE_OPEN_MODE_INHERIT))
    sourceSingle.OnEvent("Click", SetSourceOpenModeFromDialog.Bind(
        sourceState, OPEN_MODE_SINGLE))
    sourceDouble.OnEvent("Click", SetSourceOpenModeFromDialog.Bind(
        sourceState, OPEN_MODE_DOUBLE))

    saveButton := settingsGui.AddButton("xm y+20 w90 Default", "保存")
    cancelButton := settingsGui.AddButton("x+8 yp w90", "取消")
    advancedButton := settingsGui.AddButton("x+8 yp w150",
        "高级编辑 config.ini")
    saveButton.OnEvent("Click", SaveOpenFileSettings.Bind(
        settingsGui, globalDouble, globalSingle, sourceState))
    cancelButton.OnEvent("Click", CloseOpenFileSettings.Bind(settingsGui))
    advancedButton.OnEvent("Click", OpenConfigFile)
    settingsGui.OnEvent("Close", CloseOpenFileSettings.Bind(settingsGui))
    settingsGui.OnEvent("Escape", CloseOpenFileSettings.Bind(settingsGui))
    settingsGui.OnEvent("Size", ResizeOpenFileSettings.Bind(
        sourceList, sourceHint, sourceInherit, sourceSingle, sourceDouble,
        saveButton, cancelButton, advancedButton))
    settingsGui.Show("w620 h520")
}

SourceOpenModeLabel(mode) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, GlobalOpenFileMode
    if mode = OPEN_MODE_SINGLE
        return "单击"
    if mode = OPEN_MODE_DOUBLE
        return "双击"
    actual := ParseGlobalOpenFileMode(GlobalOpenFileMode)
        = OPEN_MODE_SINGLE ? "单击" : "双击"
    return "跟随全局（当前：" actual "）"
}

OpenModeSourceSelected(state, list, row, selected) {
    if !selected || !state.Rows.Has(row)
        return
    state.SelectedRow := row
    sourceId := state.Rows[row].Id
    mode := state.Modes[sourceId]
    controls := state.Controls
    state.Updating := true
    try {
        controls.Inherit.Enabled := true
        controls.Single.Enabled := true
        controls.Double.Enabled := true
        controls.Inherit.Value := mode = "Inherit"
        controls.Single.Value := mode = "SingleClick"
        controls.Double.Value := mode = "DoubleClick"
    } finally {
        state.Updating := false
    }
}

SetSourceOpenModeFromDialog(state, mode, control, *) {
    if state.Updating || !HasProp(state, "SelectedRow")
        return
    row := state.SelectedRow
    if !state.Rows.Has(row)
        return
    sourceId := state.Rows[row].Id
    state.Modes[sourceId] := ParseSourceOpenFileMode(mode)
    state.List.Modify(row, "Col3",
        SourceOpenModeLabel(state.Modes[sourceId]))
}

SaveOpenFileSettings(settingsGui, globalDouble, globalSingle, sourceState, *) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE

    globalMode := globalSingle.Value ? OPEN_MODE_SINGLE : OPEN_MODE_DOUBLE
    entries := []
    for row, folder in sourceState.Rows {
        entries.Push({
            Id: folder.Id,
            Name: folder.Name,
            Path: folder.Path,
            Mode: sourceState.Modes[folder.Id]
        })
    }
    try {
        AtomicConfigEdit(
            WriteOpenFileModeSettings.Bind(globalMode, entries))
        LoadSettings()
        SetUserStatus("文件打开方式已更新")
        CloseOpenFileSettings(settingsGui)
    } catch as err {
        ShowPanelMsgBox("无法保存文件打开设置：`n" err.Message,
            "保存设置失败", "Iconx")
    }
}

WriteOpenFileModeSettings(globalMode, entries, tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    doc.SetValue("General", "OpenFileMode",
        ParseGlobalOpenFileMode(globalMode), 1)
    sourceIds := []
    for entry in entries {
        sourceIds.Push(entry.Id)
        folderSection := "Folder:" entry.Name
        sourceSection := "Source:" entry.Id
        doc.SetValue(folderSection, "SourceId", entry.Id, 2)
        doc.SetValue(folderSection, "OpenFileMode",
            ParseSourceOpenFileMode(entry.Mode), 2)
        doc.SetValue(sourceSection, "Name", entry.Name, 3)
        doc.SetValue(sourceSection, "Path", entry.Path, 3)
        doc.SetValue(sourceSection, "OpenFileMode",
            ParseSourceOpenFileMode(entry.Mode), 3)
    }
    doc.SetValue("Sources", "Order", JoinArray(sourceIds, ","), 3)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

CloseOpenFileSettings(settingsGui, *) {
    global SettingsDialog
    if !IsObject(SettingsDialog)
        return
    CancelFilePointerGesture()
    SettingsDialog := 0
    try settingsGui.Destroy()
    EndAutoHidePause()
}

ResizeOpenFileSettings(sourceList, sourceHint,
    sourceInherit, sourceSingle, sourceDouble,
    saveButton, cancelButton, advancedButton,
    guiObj, minMax, width, height) {
    if minMax = -1
        return
    contentWidth := Max(420, width - 32)
    listHeight := Max(150, height - 280)
    sourceList.Move(, , contentWidth, listHeight)
    sourceHint.Move(, 128 + listHeight, contentWidth)
    radioY := 158 + listHeight
    sourceInherit.Move(, radioY)
    sourceSingle.Move(, radioY)
    sourceDouble.Move(, radioY)
    buttonY := height - 48
    saveButton.Move(, buttonY)
    cancelButton.Move(, buttonY)
    advancedButton.Move(, buttonY)
}

OpenConfigFile(*) {
    global ConfigPath, Panel
    CancelFilePointerGesture()
    result := DllCall("shell32\ShellExecuteW",
        "ptr", IsObject(Panel) ? Panel.Hwnd : 0,
        "wstr", "open", "wstr", ConfigPath,
        "ptr", 0, "wstr", A_ScriptDir, "int", 1, "ptr")
    if result <= 32
        ShowPanelMsgBox("无法打开配置文件。", "打开配置", "Iconx")
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
    CancelFilePointerGesture()
    if !row || !ItemPaths.Has(row)
        return
    if !IsListRowSelected(list.Hwnd, row) {
        list.Modify(0, "-Select -Focus")
        list.Modify(row, "Select Focus Vis")
    } else {
        list.Modify(row, "Focus Vis")
    }
    UpdateSelectionStatus()
    path := ItemPaths[row]
    if !FileExist(path) {
        ShowPanelMsgBox("项目不存在或当前无法访问：`n" path, "右键菜单", "Icon!")
        return
    }
    paths := GetSelectedExistingPaths()
    if !paths.Length
        paths := [path]
    if GetKeyState("Shift", "P")
        ShowShellContextMenu(GetShellMenuPaths(paths, path), list.Gui.Hwnd, x, y)
    else
        ShowPopDropContextMenu(paths, path, list.Gui.Hwnd, x, y)
}

IsListRowSelected(hwnd, row) {
    state := DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x102C,
        "ptr", row - 1, "ptr", 0x2, "uint") ; LVM_GETITEMSTATE / LVIS_SELECTED
    return (state & 0x2) != 0
}

GetSelectedExistingPaths() {
    global ItemPaths
    paths := []
    for row in GetSelectedFileRows() {
        path := ItemPaths[row]
        if FileExist(path) && !ArrayContainsPath(paths, path)
            paths.Push(path)
    }
    return paths
}

GetShellMenuPaths(paths, clickedPath) {
    if paths.Length <= 1
        return [clickedPath]
    parent := GetParentPath(paths[1])
    for path in paths {
        if !PathsEqual(GetParentPath(path), parent)
            return [clickedPath]
    }
    return paths.Clone()
}

ShowPopDropContextMenu(paths, clickedPath, ownerHwnd, x, y) {
    global PinnedPaths

    contextMenu := Menu()
    openText := "打开`tEnter"
    contextMenu.Add(openText, OpenSelectedItems.Bind(paths.Clone()))

    singleFile := paths.Length = 1 && FileExist(paths[1])
        && !InStr(FileExist(paths[1]), "D")
    if singleFile {
        apps := GetApplicableOpenApps(paths[1])
        directCount := Min(5, apps.Length)
        usedLabels := Map()
        Loop directCount {
            app := apps[A_Index]
            label := UniqueOpenAppMenuLabel(app.Name, usedLabels)
            contextMenu.Add(label, OpenWithConfiguredApp.Bind(app.Id, paths[1]))
            try contextMenu.SetIcon(label, app.Icon)
        }
        if apps.Length > 5 {
            moreApps := Menu()
            Loop apps.Length - 5 {
                app := apps[A_Index + 5]
                label := UniqueOpenAppMenuLabel(app.Name, usedLabels)
                moreApps.Add(label, OpenWithConfiguredApp.Bind(app.Id, paths[1]))
                try moreApps.SetIcon(label, app.Icon)
            }
            contextMenu.Add("更多已配置应用…", moreApps)
        }
        contextMenu.Add("选择其他程序…", ChooseOtherProgramForFile.Bind(paths[1]))
    }

    contextMenu.Add()
    revealText := "在文件资源管理器中显示`tCtrl+Enter"
    contextMenu.Add(revealText, RevealPathsInExplorer.Bind(paths.Clone()))
    if !CanRevealTogether(paths)
        contextMenu.Disable(revealText)

    contextMenu.Add()
    copyMenu := BuildTransferTargetMenu("copy", paths)
    moveMenu := BuildTransferTargetMenu("move", paths)
    contextMenu.Add("复制到…", copyMenu)
    contextMenu.Add("移动到…", moveMenu)

    contextMenu.Add()
    copyFilesText := "复制文件`tCtrl+C"
    copyPathsText := "复制路径`tCtrl+Shift+C"
    contextMenu.Add(copyFilesText, CopyFileObjectsToClipboard.Bind(paths.Clone()))
    contextMenu.Add(copyPathsText, CopyPathTextToClipboard.Bind(paths.Clone()))

    contextMenu.Add()
    addCount := 0
    removeCount := 0
    for path in paths {
        if FindPathIndex(PinnedPaths, path)
            removeCount += 1
        else
            addCount += 1
    }
    addText := paths.Length > 1 ? "添加到固定项（" addCount " 项）" : "添加到固定项"
    removeText := paths.Length > 1 ? "从固定项移除（" removeCount " 项）" : "从固定项移除"
    contextMenu.Add(addText, AddSelectionToPinned.Bind(paths.Clone()))
    contextMenu.Add(removeText, RemoveSelectionFromPinned.Bind(paths.Clone()))
    if !addCount
        contextMenu.Disable(addText)
    if !removeCount
        contextMenu.Disable(removeText)

    contextMenu.Add()
    deleteText := "删除`tDelete"
    contextMenu.Add(deleteText,
        DeletePathsToRecycleBin.Bind(paths.Clone()))

    contextMenu.Add()
    systemText := "更多系统操作…`tShift+F10"
    contextMenu.Add(systemText, ShowSystemMenuForSelection.Bind(
        paths.Clone(), clickedPath, ownerHwnd, x, y))

    point := MenuScreenPoint(ownerHwnd, x, y)
    BeginAutoHidePause()
    try {
        ; Menu.Show follows CoordMode("Menu"). The ListView event supplies
        ; client coordinates, which MenuScreenPoint converted to screen pixels.
        CoordMode("Menu", "Screen")
        contextMenu.Show(point.X, point.Y)
    } finally {
        EndAutoHidePause()
    }
}

UniqueOpenAppMenuLabel(name, usedLabels) {
    base := "用 " name " 打开"
    count := usedLabels.Has(base) ? usedLabels[base] + 1 : 1
    usedLabels[base] := count
    return count = 1 ? base : base " (" count ")"
}

MenuScreenPoint(ownerHwnd, x, y) {
    point := Buffer(8, 0)
    if x = -1 || y = -1 {
        DllCall("user32\GetCursorPos", "ptr", point)
    } else {
        NumPut("int", x, point, 0)
        NumPut("int", y, point, 4)
        DllCall("user32\ClientToScreen", "ptr", ownerHwnd, "ptr", point)
    }
    return {X: NumGet(point, 0, "int"), Y: NumGet(point, 4, "int")}
}

ShowSystemMenuForSelection(paths, clickedPath, ownerHwnd, x, y, *) {
    ShowShellContextMenu(GetShellMenuPaths(paths, clickedPath), ownerHwnd, x, y)
}

BuildTransferTargetMenu(operation, paths) {
    global TransferFavorites, RecentTargets
    targetMenu := Menu()
    seen := Map()

    favorites := GetEffectiveTransferFavorites()
    heading := "常用位置"
    targetMenu.Add(heading, NoopMenuAction)
    targetMenu.Disable(heading)
    for target in favorites {
        key := PathKey(target.Path)
        if seen.Has(key)
            continue
        seen[key] := true
        text := target.Label
        targetMenu.Add(text, RunTransferToTarget.Bind(
            operation, paths.Clone(), target.Path))
        if !DirExist(target.Path) {
            targetMenu.Rename(text, text "（不可用）")
            targetMenu.Disable(text "（不可用）")
        }
    }

    recentAdded := 0
    for targetPath in RecentTargets {
        key := PathKey(targetPath)
        if seen.Has(key)
            continue
        if !recentAdded {
            recentHeading := "最近目标"
            targetMenu.Add(recentHeading, NoopMenuAction)
            targetMenu.Disable(recentHeading)
        }
        recentAdded += 1
        seen[key] := true
        text := GetDistinctTargetLabel(targetPath, favorites, RecentTargets)
        targetMenu.Add(text, RunTransferToTarget.Bind(
            operation, paths.Clone(), targetPath))
        if !DirExist(targetPath) {
            targetMenu.Rename(text, text "（不可用）")
            targetMenu.Disable(text "（不可用）")
        }
        if recentAdded >= 3
            break
    }

    targetMenu.Add()
    targetMenu.Add("选择其他文件夹…",
        ChooseTransferFolder.Bind(operation, paths.Clone()))
    targetMenu.Add("管理常用位置…", OpenConfigAtTransferFavorites)
    if HasInvalidTransferTargets()
        targetMenu.Add("移除无效位置…", RemoveInvalidTransferTargets)
    return targetMenu
}

NoopMenuAction(*) {
}

GetEffectiveTransferFavorites() {
    global TransferFavorites, TransferFavoriteLabels
    result := []
    desktop := GetKnownFolderPath("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}")
    downloads := GetKnownFolderPath("{374DE290-123F-4565-9164-39C4925E467B}")
    for path in TransferFavorites {
        if result.Length >= 5
            break
        if ArrayContainsObjectPath(result, path)
            continue
        if TransferFavoriteLabels.Has(PathKey(path))
            && Trim(TransferFavoriteLabels[PathKey(path)]) != ""
            label := TransferFavoriteLabels[PathKey(path)]
        else if desktop != "" && PathsEqual(path, desktop)
            label := "桌面"
        else if downloads != "" && PathsEqual(path, downloads)
            label := "下载"
        else
            label := GetDistinctTargetLabel(path, TransferFavorites, [])
        result.Push({Path: path, Label: label})
    }
    return result
}

ArrayContainsObjectPath(objects, target) {
    for item in objects {
        if PathsEqual(item.Path, target)
            return true
    }
    return false
}

GetDistinctTargetLabel(path, firstList, secondList) {
    name := GetFileName(path)
    duplicate := false
    for list in [firstList, secondList] {
        for other in list {
            otherPath := IsObject(other) ? other.Path : other
            if !PathsEqual(otherPath, path) && GetFileName(otherPath) = name {
                duplicate := true
                break
            }
        }
    }
    return duplicate ? name " — " GetParentPath(path) : name
}

GetKnownFolderPath(guidText) {
    guid := GuidBuffer(guidText)
    resultPath := 0
    hr := DllCall("shell32\SHGetKnownFolderPath", "ptr", guid.Ptr,
        "uint", 0, "ptr", 0, "ptr*", &resultPath, "int")
    if hr != 0 || !resultPath
        return ""
    try return NormalizePath(StrGet(resultPath))
    finally DllCall("ole32\CoTaskMemFree", "ptr", resultPath)
}

HasInvalidTransferTargets() {
    global TransferFavorites, RecentTargets
    for path in TransferFavorites {
        if !DirExist(path)
            return true
    }
    for path in RecentTargets {
        if !DirExist(path)
            return true
    }
    return false
}

ShowShellContextMenu(paths, ownerHwnd, x, y) {
    if !IsObject(paths)
        paths := [paths]
    fullPidls := []
    parentFolder := 0
    contextMenu := 0
    menuHandle := 0

    BeginAutoHidePause()

    try {
        iidShellFolder := GuidBuffer("{000214E6-0000-0000-C000-000000000046}")
        childPidls := []
        for index, path in paths {
            pidl := 0
            if DllCall("shell32\SHParseDisplayName", "wstr", path, "ptr", 0,
                "ptr*", &pidl, "uint", 0, "ptr", 0) != 0
                throw Error("Windows Shell 无法解析此项目。")
            fullPidls.Push(pidl)
            currentParent := 0
            childPidl := 0
            if DllCall("shell32\SHBindToParent", "ptr", pidl,
                "ptr", iidShellFolder.Ptr, "ptr*", &currentParent,
                "ptr*", &childPidl) != 0
                throw Error("无法连接项目所在目录。")
            if index = 1
                parentFolder := currentParent
            else
                ObjRelease(currentParent)
            childPidls.Push(childPidl)
        }

        iidContextMenu := GuidBuffer("{000214E4-0000-0000-C000-000000000046}")
        childArray := Buffer(A_PtrSize * childPidls.Length, 0)
        for index, childPidl in childPidls
            NumPut("ptr", childPidl, childArray, (index - 1) * A_PtrSize)
        hr := ComCall(10, parentFolder, "ptr", ownerHwnd,
            "uint", childPidls.Length, "ptr", childArray.Ptr,
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
        for pidl in fullPidls
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
    global FileView, RecentView, ItemPaths, RecentItemPaths, ItemOpenContexts
    global DragPaths, DragItemContexts, SelectedFilePaths
    global DragSourceHwnd, DragStartX, DragStartY, DragStarted
    global PinnedReorderActive, PinnedReorderPath
    global FilePointerGesture, FilePointerGestureSerial
    global OPEN_MODE_SINGLE

    isMainView := IsObject(FileView) && hwnd = FileView.Hwnd
    if isMainView
        pathMap := ItemPaths
    else if IsObject(RecentView) && hwnd = RecentView.Hwnd
        pathMap := RecentItemPaths
    else
        return
    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    row := HitTestListRow(hwnd, x, y)
    modifiers := GetPointerModifierMask()
    path := row && pathMap.Has(row) ? pathMap[row] : ""
    selectedSnapshot := []
    if isMainView
        selectedSnapshot := SelectedFilePaths.Clone()
    else if row && path != "" && IsListRowSelected(hwnd, row)
        selectedSnapshot.Push(path)

    serial := ++FilePointerGestureSerial
    FilePointerGesture := {
        Serial: serial,
        Active: true,
        Hwnd: hwnd,
        Row: row,
        Path: path,
        Key: path != "" ? GetDisplayedItemActivationKey(hwnd, row, path) : "",
        X: x,
        Y: y,
        DownTick: A_TickCount,
        Selection: selectedSnapshot,
        Modifiers: modifiers,
        OpenRegion: row && path != "",
        ChildControl: false,
        Dragging: false,
        Marquee: !row,
        Cancelled: false
    }

    DragPaths := []
    DragItemContexts := []
    if row && pathMap.Has(row) {
        ; WM_LBUTTONDOWN can collapse a multi-selection before a drag reaches
        ; its movement threshold. Use the snapshot saved after the preceding
        ; Ctrl/Shift/marquee selection instead of querying the live control.
        if isMainView && ArrayContainsPath(SelectedFilePaths, pathMap[row]) {
            DragPaths := SelectedFilePaths.Clone()
        } else {
            DragPaths.Push(pathMap[row])
        }
        DragItemContexts := BuildDragItemContexts(hwnd, row, DragPaths)
    }
    DragSourceHwnd := hwnd
    DragStartX := x
    DragStartY := y
    DragStarted := false
    PinnedReorderActive := false
    PinnedReorderPath := ""
    ; 只根据按下行的显示上下文识别排序手势。相同路径也可能同时出现在
    ; Files 来源中，不能仅凭它存在于 PinnedPaths 就把来源项目当成固定项。
    if isMainView && DragPaths.Length = 1 && row
        && ItemOpenContexts.Has(row)
        && ItemOpenContexts[row].Area = "Pinned"
        && PathsEqual(DragPaths[1], path)
        PinnedReorderPath := DragPaths[1]

    ; 原生 ListView 会在按下已选项时先收敛多选。消息返回后恢复快照，
    ; 因而超过阈值的拖拽仍能显示并发送整组选择；未拖拽的释放再收敛。
    if isMainView && modifiers = 0 && path != ""
        && selectedSnapshot.Length > 1
        && ArrayContainsPath(selectedSnapshot, path)
        && !IsListItemFolder(FileView, row, path)
        && GetEffectiveOpenMode(GetListItemOpenContext(FileView, row))
            = OPEN_MODE_SINGLE {
        SetTimer(RestorePointerSelection.Bind(serial), -1)
    }
}

FileViewMouseMove(wParam, lParam, msg, hwnd) {
    global DragPaths, DragItemContexts, DragSourceHwnd
    global DragStartX, DragStartY, DragStarted, StatusText, StatusKind
    global PinnedReorderActive, PinnedReorderPath
    global FilePointerGesture

    if IsObject(FilePointerGesture) && FilePointerGesture.Active
        && hwnd = FilePointerGesture.Hwnd
        && GetKeyState("LButton", "P") {
        pointerX := SignedMouseCoordinate(lParam & 0xFFFF)
        pointerY := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
        thresholdX := DllCall("user32\GetSystemMetrics",
            "int", 68, "int") ; SM_CXDRAG（已按当前 DPI 虚拟化）
        thresholdY := DllCall("user32\GetSystemMetrics",
            "int", 69, "int") ; SM_CYDRAG
        if Abs(pointerX - FilePointerGesture.X) >= thresholdX
            || Abs(pointerY - FilePointerGesture.Y) >= thresholdY
            FilePointerGesture.Dragging := true
    }

    if !DragPaths.Length || DragStarted || hwnd != DragSourceHwnd || !GetKeyState("LButton", "P")
        return
    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    thresholdX := DllCall("user32\GetSystemMetrics", "int", 68, "int") ; SM_CXDRAG
    thresholdY := DllCall("user32\GetSystemMetrics", "int", 69, "int") ; SM_CYDRAG
    if Abs(x - DragStartX) < thresholdX && Abs(y - DragStartY) < thresholdY
        return

    ; 在整个固定项原生分组矩形内保持排序态。只要求命中某个图块会让
    ; 图块间留白、列表行的非标签区域或快速移动意外切进 OLE，排序因而
    ; 几乎无法触发。进入 Files/Launcher 分组或离开面板时才转为 OLE。
    screenPoint := ClientToScreenPoint(hwnd, x, y)
    reorderDropTarget := PinnedReorderPath != ""
        ? ResolveDropTarget(screenPoint.X, screenPoint.Y) : 0
    if PinnedReorderPath != ""
        && ShouldContinuePinnedReorder(reorderDropTarget) {
        if !PinnedReorderActive {
            PinnedReorderActive := true
            DllCall("user32\SetCapture", "ptr", hwnd, "ptr")
            StatusKind := "user"
            StatusText.Text := "在固定项内拖到另一个项目可调整顺序；拖到来源可复制。"
        }
        return
    }
    if PinnedReorderActive {
        PinnedReorderActive := false
        DllCall("user32\ReleaseCapture")
    }
    PinnedReorderPath := ""

    DragStarted := true
    paths := DragPaths
    itemContexts := DragItemContexts
    DragPaths := []
    DragItemContexts := []
    existingPaths := []
    for path in paths {
        if FileExist(path) && !ArrayContainsPath(existingPaths, path)
            existingPaths.Push(path)
    }
    if existingPaths.Length {
        StatusKind := "user"
        StatusText.Text := "本次拖拽包含 " existingPaths.Length " 个项目。"
        DllCall("user32\UpdateWindow", "ptr", StatusText.Hwnd)
        BeginShellDrag(existingPaths, DragSourceHwnd,
            NormalizeInternalDragItems(existingPaths, itemContexts))
    }
    ; OLE 拖拽返回时原始按键释放通常已被拖放循环消费。
    CancelFilePointerGesture()
}

FileViewLeftButtonUp(wParam, lParam, msg, hwnd) {
    global FileView, ItemPaths, PinnedReorderActive, PinnedReorderPath
    global DragPaths, DragItemContexts, DragStarted, StatusKind, ViewMode

    if !PinnedReorderActive {
        ProcessFilePointerUp(hwnd, lParam)
        DragPaths := []
        DragItemContexts := []
        DragStarted := false
        PinnedReorderPath := ""
        return
    }

    PinnedReorderActive := false
    DllCall("user32\ReleaseCapture")
    CancelFilePointerGesture()
    sourcePath := PinnedReorderPath
    PinnedReorderPath := ""
    DragPaths := []
    DragItemContexts := []
    DragStarted := false
    StatusKind := "default"
    SetBackgroundStatus("固定项顺序未更改", 1500)

    if !IsObject(FileView) || hwnd != FileView.Hwnd
        return

    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    targetRow := HitTestPinnedReorderRow(hwnd, x, y)
    if !targetRow || !ItemPaths.Has(targetRow)
        return

    targetPath := ItemPaths[targetRow]

    placeAfter := false
    itemRect := Buffer(16, 0)
    NumPut("int", 0, itemRect, 0) ; LVIR_BOUNDS
    if DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x100E,
        "ptr", targetRow - 1, "ptr", itemRect.Ptr, "ptr") {
        if ViewMode = "Thumbnail" {
            left := NumGet(itemRect, 0, "int")
            right := NumGet(itemRect, 8, "int")
            placeAfter := x >= Floor((left + right) / 2)
        } else {
            top := NumGet(itemRect, 4, "int")
            bottom := NumGet(itemRect, 12, "int")
            placeAfter := y >= Floor((top + bottom) / 2)
        }
    }

    if ReorderPinnedPath(sourcePath, targetPath, placeAfter) {
        StatusKind := "default"
        SetBackgroundStatus("已保存固定项顺序", 3000)
    }
}

ProcessFilePointerUp(hwnd, lParam) {
    global FilePointerGesture, FileView, RecentView
    if !IsObject(FilePointerGesture) || !FilePointerGesture.Active
        return
    if IsObject(FileView) && hwnd = FileView.Hwnd
        list := FileView
    else if IsObject(RecentView) && hwnd = RecentView.Hwnd
        list := RecentView
    else
        return

    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    row := HitTestListRow(hwnd, x, y)
    ProcessFilePointerRelease(list, row)
}

FileViewClick(list, row, *) {
    ; NM_CLICK 是原生 ListView 在左键释放阶段发出的通知。部分版本会在
    ; WM_LBUTTONUP 回调前先释放捕获，因此这里作为同一状态机的可靠入口。
    ProcessFilePointerRelease(list, row)
}

ProcessFilePointerRelease(list, row) {
    global FilePointerGesture, FileView, RecentView
    global ItemPaths, RecentItemPaths, OPEN_MODE_SINGLE

    if !IsObject(FilePointerGesture) || !FilePointerGesture.Active
        return
    gesture := FilePointerGesture
    ; 先清理，避免打开程序、错误对话框或焦点变化重入本次手势。
    FilePointerGesture := 0

    if gesture.Cancelled || gesture.Dragging || gesture.Marquee
        || gesture.ChildControl || !gesture.OpenRegion
        || list.Hwnd != gesture.Hwnd || gesture.Modifiers != 0
        || GetPointerModifierMask() != 0
        return

    if IsObject(FileView) && list.Hwnd = FileView.Hwnd
        pathMap := ItemPaths
    else if IsObject(RecentView) && list.Hwnd = RecentView.Hwnd
        pathMap := RecentItemPaths
    else
        return
    if !row || !pathMap.Has(row)
        return

    path := pathMap[row]
    releaseKey := GetDisplayedItemActivationKey(list.Hwnd, row, path)
    if releaseKey = "" || releaseKey != gesture.Key
        || !PathsEqual(path, gesture.Path)
        return

    if IsListItemFolder(list, row, path)
        return
    if GetEffectiveOpenMode(GetListItemOpenContext(list, row))
        != OPEN_MODE_SINGLE
        return

    ; 无修饰键释放把此前的多选收敛到当前文件，只激活这一项。
    CollapseListSelectionToRow(list, row)
    if ShouldSuppressRepeatedPointerActivation(releaseKey)
        return
    OpenItemWithDefaultApplication(path)
}

RestorePointerSelection(serial) {
    global FilePointerGesture, FileView, ItemPaths
    if !IsObject(FilePointerGesture) || !FilePointerGesture.Active
        || FilePointerGesture.Serial != serial
        || FilePointerGesture.Hwnd != FileView.Hwnd
        || FilePointerGesture.Modifiers != 0
        || !GetKeyState("LButton", "P")
        return
    snapshot := FilePointerGesture.Selection
    if snapshot.Length <= 1
        return
    FileView.Modify(0, "-Select")
    for row, path in ItemPaths {
        if ArrayContainsPath(snapshot, path)
            FileView.Modify(row, "Select")
    }
    if FilePointerGesture.Row
        FileView.Modify(FilePointerGesture.Row, "Focus Vis")
}

CollapseListSelectionToRow(list, row) {
    list.Modify(0, "-Select -Focus")
    list.Modify(row, "Select Focus Vis")
    SetTimer(UpdateSelectionStatus, -1)
}

GetPointerModifierMask() {
    mask := 0
    if GetKeyState("Ctrl", "P")
        mask |= 0x01
    if GetKeyState("Shift", "P")
        mask |= 0x02
    if GetKeyState("Alt", "P")
        mask |= 0x04
    if GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
        mask |= 0x08
    return mask
}

GetDisplayedItemActivationKey(hwnd, row, path) {
    global FileView, RecentView, ItemOpenContexts
    normalizedKey := PathKey(path)
    if normalizedKey = ""
        return ""
    if IsObject(FileView) && hwnd = FileView.Hwnd {
        if ItemOpenContexts.Has(row) {
            context := ItemOpenContexts[row]
            if context.Area = "Source"
                return "source|" StrLower(context.SourceId)
                    . "|" normalizedKey
            if context.Area = "Pinned"
                return "pinned|" normalizedKey
        }
        return "main|" normalizedKey
    }
    if IsObject(RecentView) && hwnd = RecentView.Hwnd
        return "recent|" normalizedKey
    return ""
}

ShouldSuppressRepeatedPointerActivation(key) {
    global LastPointerActivationKey, LastPointerActivationTick
    now := A_TickCount
    doubleClickTime := DllCall("user32\GetDoubleClickTime", "uint")
    elapsed := LastPointerActivationTick = 0
        ? doubleClickTime + 1
        : ElapsedTickMilliseconds(LastPointerActivationTick, now)
    if key = LastPointerActivationKey && elapsed <= doubleClickTime
        return true
    LastPointerActivationKey := key
    LastPointerActivationTick := now
    return false
}

ElapsedTickMilliseconds(earlier, later) {
    if later >= earlier
        return later - earlier
    return (0xFFFFFFFF - earlier) + later + 1
}

CancelFilePointerGesture(*) {
    global FilePointerGesture, DragPaths, DragItemContexts, DragStarted
    if IsObject(FilePointerGesture)
        FilePointerGesture.Cancelled := true
    FilePointerGesture := 0
    DragPaths := []
    DragItemContexts := []
    DragStarted := false
}

CancelFilePointerGestureForHwnd(hwnd) {
    global FilePointerGesture
    if IsObject(FilePointerGesture)
        && FilePointerGesture.Active
        && FilePointerGesture.Hwnd = hwnd
        CancelFilePointerGesture()
}

IsTrackedFileViewHwnd(hwnd) {
    global FileView, RecentView
    return (IsObject(FileView) && hwnd = FileView.Hwnd)
        || (IsObject(RecentView) && hwnd = RecentView.Hwnd)
}

FileViewRightButtonDown(wParam, lParam, msg, hwnd) {
    if IsTrackedFileViewHwnd(hwnd)
        CancelFilePointerGesture()
}

FileViewCancelInteraction(wParam, lParam, msg, hwnd) {
    if IsTrackedFileViewHwnd(hwnd)
        CancelFilePointerGesture()
}

FileViewCancelMode(wParam, lParam, msg, hwnd) {
    if IsTrackedFileViewHwnd(hwnd)
        CancelFilePointerGestureForHwnd(hwnd)
}

FileViewCaptureChanged(wParam, lParam, msg, hwnd) {
    ; 原生 ListView 在正常释放期间也会发 WM_CAPTURECHANGED。此时物理
    ; 左键已抬起，NM_CLICK/WM_LBUTTONUP 仍需消费手势，不能提前清除。
    ; 只有按键仍按住时的捕获转移才是真正的取消/外部抢占。
    if IsTrackedFileViewHwnd(hwnd) && GetKeyState("LButton", "P")
        CancelFilePointerGestureForHwnd(hwnd)
}

FileViewKillFocus(wParam, lParam, msg, hwnd) {
    if IsTrackedFileViewHwnd(hwnd)
        CancelFilePointerGestureForHwnd(hwnd)
}

SignedMouseCoordinate(value) {
    return value >= 0x8000 ? value - 0x10000 : value
}

PointInsideControl(hwnd, x, y) {
    if x < 0 || y < 0
        return false
    rect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", hwnd, "ptr", rect.Ptr)
        return false
    return x < NumGet(rect, 8, "int") && y < NumGet(rect, 12, "int")
}

HitTestListRow(hwnd, x, y) {
    hitInfo := Buffer(24, 0)
    NumPut("int", x, hitInfo, 0)
    NumPut("int", y, hitInfo, 4)
    zeroBasedRow := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1012, "ptr", 0, "ptr", hitInfo.Ptr, "int") ; LVM_HITTEST
    return zeroBasedRow >= 0 ? zeroBasedRow + 1 : 0
}

HitTestPinnedReorderRow(hwnd, x, y) {
    global FileView, ItemOpenContexts
    if !IsObject(FileView) || hwnd != FileView.Hwnd
        return 0

    row := HitTestListRow(hwnd, x, y)
    if IsPinnedItemRow(row)
        return row

    ; LVM_HITTEST 在图标/标签之外的可见行区域可能返回 -1。使用原生
    ; LVIR_BOUNDS 补充命中，兼容缩略图、列表视图、DPI、缩放和滚动。
    for candidateRow, context in ItemOpenContexts {
        if context.Area != "Pinned"
            continue
        itemRect := GetListItemBounds(hwnd, candidateRow)
        if IsObject(itemRect)
            && x >= itemRect.Left && x < itemRect.Right
            && y >= itemRect.Top && y < itemRect.Bottom
            return candidateRow
    }
    return 0
}

IsPinnedItemRow(row) {
    global ItemOpenContexts
    return row && ItemOpenContexts.Has(row)
        && ItemOpenContexts[row].Area = "Pinned"
}

GetListItemBounds(hwnd, row) {
    if !row
        return 0
    itemRect := Buffer(16, 0)
    NumPut("int", 0, itemRect, 0) ; LVIR_BOUNDS
    if !DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x100E,
        "ptr", row - 1, "ptr", itemRect.Ptr, "ptr")
        return 0
    return {
        Left: NumGet(itemRect, 0, "int"),
        Top: NumGet(itemRect, 4, "int"),
        Right: NumGet(itemRect, 8, "int"),
        Bottom: NumGet(itemRect, 12, "int")
    }
}

BuildDragItemContexts(hwnd, clickedRow, paths) {
    global FileView, RecentView, ItemPaths, ItemOpenContexts, RecentItemPaths
    result := []
    if IsObject(FileView) && hwnd = FileView.Hwnd {
        selectedRows := GetSelectedFileRows()
        useSelected := selectedRows.Length > 1
            && clickedRow && IsListRowSelected(hwnd, clickedRow)
        rows := useSelected ? selectedRows : [clickedRow]
        for row in rows {
            if !ItemPaths.Has(row)
                continue
            context := ItemOpenContexts.Has(row)
                ? CloneDropItemContext(ItemOpenContexts[row])
                : {Area: "Unknown"}
            context.Path := ItemPaths[row]
            result.Push(context)
        }
    } else if IsObject(RecentView) && hwnd = RecentView.Hwnd
        && clickedRow && RecentItemPaths.Has(clickedRow) {
        result.Push({Area: "Recent", Path: RecentItemPaths[clickedRow]})
    }
    return result
}

CloneDropItemContext(context) {
    clone := {Area: HasProp(context, "Area") ? context.Area : "Unknown"}
    for property in ["SourceId", "SourcePath", "SourceMode", "GroupId"] {
        if HasProp(context, property)
            clone.%property% := context.%property%
    }
    return clone
}

NormalizeInternalDragItems(paths, contexts) {
    result := []
    for path in paths {
        item := {Path: path, Area: "Unknown"}
        matching := []
        for context in contexts {
            if HasProp(context, "Path") && PathsEqual(context.Path, path)
                matching.Push(context)
        }
        if matching.Length = 1 {
            item := CloneDropItemContext(matching[1])
            item.Path := path
        } else if matching.Length > 1 {
            first := matching[1]
            uniform := true
            for context in matching {
                if context.Area != first.Area {
                    uniform := false
                    break
                }
                if context.Area = "Source"
                    && (!HasProp(context, "SourceId")
                        || !HasProp(first, "SourceId")
                        || StrLower(context.SourceId) != StrLower(first.SourceId)) {
                    uniform := false
                    break
                }
            }
            if uniform {
                item := CloneDropItemContext(first)
                item.Path := path
            } else
                item := {Path: path, Area: "Mixed"}
        }
        result.Push(item)
    }
    return result
}

ReorderPinnedPath(sourcePath, targetPath, placeAfter) {
    global PinnedPaths

    sourceIndex := FindPathIndex(PinnedPaths, sourcePath)
    targetIndex := FindPathIndex(PinnedPaths, targetPath)
    if !sourceIndex || !targetIndex || sourceIndex = targetIndex
        return false

    originalPaths := PinnedPaths.Clone()
    PinnedPaths.RemoveAt(sourceIndex)
    targetIndex := FindPathIndex(PinnedPaths, targetPath)
    insertAt := targetIndex + (placeAfter ? 1 : 0)
    PinnedPaths.InsertAt(insertAt, sourcePath)

    if PathArraysEqual(PinnedPaths, originalPaths)
        return false

    try SavePinnedFiles()
    catch as err {
        PinnedPaths := originalPaths
        try SavePinnedFiles()
        ShowPanelMsgBox(
            "无法保存固定项顺序：`n" err.Message,
            "固定项排序失败",
            "Iconx"
        )
        return false
    }

    PopulatePanel()
    return true
}

PathArraysEqual(left, right) {
    if left.Length != right.Length
        return false
    for index, path in left {
        if !PathsEqual(path, right[index])
            return false
    }
    return true
}

RunTransferToTarget(operation, paths, targetPath, *) {
    if !DirExist(targetPath) {
        ShowPanelMsgBox("目标文件夹不存在、离线或当前无权访问：`n"
            targetPath, "目标不可用", "Icon!")
        return
    }
    PerformShellFileOperation(operation, paths, targetPath)
}

ChooseTransferFolder(operation, paths, *) {
    global LastTransferTargetDir
    initial := DirExist(LastTransferTargetDir)
        ? LastTransferTargetDir : GetKnownFolderPath(
            "{374DE290-123F-4565-9164-39C4925E467B}")
    selected := SelectPanelFile("D3", initial,
        operation = "copy" ? "选择复制目标文件夹" : "选择移动目标文件夹")
    if selected = ""
        return
    RunTransferToTarget(operation, paths, NormalizePath(selected))
}

OpenConfigAtTransferFavorites(*) {
    OpenConfig()
    SetUserStatus("可在“文件操作”页管理常用位置")
}

RemoveInvalidTransferTargets(*) {
    global TransferFavorites, RecentTargets
    validFavorites := []
    validRecent := []
    for path in TransferFavorites {
        if DirExist(path)
            validFavorites.Push(path)
    }
    for path in RecentTargets {
        if DirExist(path)
            validRecent.Push(path)
    }
    if validFavorites.Length = TransferFavorites.Length
        && validRecent.Length = RecentTargets.Length
        return
    TransferFavorites := validFavorites
    RecentTargets := validRecent
    SaveTransferTargets()
    SetUserStatus("已移除不可用的目标位置")
}

DeletePathsToRecycleBin(paths, *) {
    existing := []
    for path in paths {
        normalized := NormalizePath(path)
        if FileExist(normalized) && !ArrayContainsPath(existing, normalized)
            existing.Push(normalized)
    }
    if !existing.Length {
        ShowPanelMsgBox("所选项目均不存在或当前无法访问。",
            "移入回收站", "Icon!")
        return false
    }
    itemText := existing.Length = 1
        ? "“" GetFileName(existing[1]) "”"
        : existing.Length " 个项目"
    answer := ShowPanelMsgBox(
        "确定要将 " itemText " 移入回收站吗？`n`n"
        . "PopDrop 不会在回收站不可用时改为永久删除。",
        "移入回收站", "YesNo Default2 Icon!")
    if answer != "Yes"
        return false
    return PerformRecycleDelete(existing)
}

PerformRecycleDelete(paths) {
    ; FOFX_RECYCLEONDELETE makes recycling part of the requested Shell
    ; operation. There is deliberately no FileDelete/DirDelete fallback.
    global Panel
    validPaths := []
    skipped := 0
    details := []
    for path in paths {
        path := NormalizePath(path)
        if !FileExist(path) {
            skipped += 1
            details.Push(path "：项目不存在或无法访问")
            continue
        }
        if IsPathRoot(path) {
            skipped += 1
            details.Push(path "：不能将磁盘或共享根目录移入回收站")
            continue
        }
        if !ArrayContainsPath(validPaths, path)
            validPaths.Push(path)
    }
    if !validPaths.Length {
        SetUserStatus("没有可移入回收站的项目")
        return {
            Success: 0, Failed: 0, Skipped: skipped,
            Aborted: false, Changed: false, RefreshQueued: false,
            Details: details
        }
    }

    viewState := CaptureViewState(validPaths)
    state := {
        Operation: "delete",
        Target: "",
        Success: 0,
        Failed: 0,
        Changed: false,
        Mappings: Map(),
        ResultPaths: [],
        PinnedMappingFailures: [],
        DeletedPaths: [],
        Details: details
    }
    sink := CreateFileOperationProgressSink(state)
    fileOperation := 0
    cookie := 0
    queued := 0
    aborted := 0
    performHr := 0x80004005
    try {
        clsid := GuidBuffer("{3AD05575-8857-4850-9277-11B85BDB8E09}")
        iidFileOperation := GuidBuffer(
            "{947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8}")
        hr := DllCall("ole32\CoCreateInstance", "ptr", clsid.Ptr,
            "ptr", 0, "uint", 1, "ptr", iidFileOperation.Ptr,
            "ptr*", &fileOperation, "int")
        if hr != 0 || !fileOperation
            throw Error("无法创建 Windows Shell 回收站操作。")

        ; FOF_ALLOWUNDO | FOF_NOCONFIRMMKDIR |
        ; FOFX_SHOWELEVATIONPROMPT | FOFX_RECYCLEONDELETE |
        ; FOFX_ADDUNDORECORD. Windows 10/11 therefore receives both explicit
        ; Recycle Bin and user-session undo semantics.
        operationFlags := 0x40 | 0x200 | 0x40000 | 0x80000 | 0x20000000
        ComCall(5, fileOperation, "uint", operationFlags)
        ComCall(9, fileOperation, "ptr", Panel.Hwnd)
        hr := ComCall(3, fileOperation, "ptr", sink.Ptr, "uint*", &cookie)
        if hr != 0
            throw Error("无法订阅回收站操作结果。")

        for sourcePath in validPaths {
            sourceItem := CreateShellItem(sourcePath)
            if !sourceItem {
                state.Failed += 1
                state.Details.Push(sourcePath "：Shell 无法解析")
                continue
            }
            try {
                hr := ComCall(18, fileOperation, "ptr", sourceItem,
                    "ptr", 0)
                if HResultSucceeded(hr)
                    queued += 1
                else {
                    state.Failed += 1
                    state.Details.Push(
                        sourcePath "：无法加入回收站操作队列")
                }
            } finally {
                ObjRelease(sourceItem)
            }
        }
        if !queued
            throw Error("没有项目能够加入回收站操作队列。")

        BeginAutoHidePause()
        try performHr := ComCall(21, fileOperation)
        finally EndAutoHidePause()
        ComCall(22, fileOperation, "int*", &aborted)
    } catch as err {
        ShowPanelMsgBox(
            "无法将所选项目移入回收站：`n" err.Message
            . "`n`n未执行永久删除。",
            "删除失败", "Iconx")
    } finally {
        if fileOperation && cookie
            try ComCall(4, fileOperation, "uint", cookie)
        if fileOperation
            ObjRelease(fileOperation)
        ReleaseFileOperationSink(sink)
    }

    refreshQueued := false
    totalFailures := state.Failed + skipped
    if state.Changed {
        try RemoveDeletedPinnedPaths(state.DeletedPaths)
        catch as err
            ShowPanelMsgBox(
                "项目已移入回收站，但固定项配置更新失败：`n"
                . err.Message "`n`n请检查 config.ini。",
                "固定项更新失败", "Icon!")
        QueueSingleRefreshAfterFileOperation(viewState, Map())
        refreshQueued := true
        if totalFailures {
            SetActionStatus(
                "已将 " state.Success " 个项目移入回收站，"
                . totalFailures " 个失败或跳过    查看详情",
                ShowRecycleDeleteDetails.Bind(state.Details.Clone()))
        } else if aborted {
            SetUserStatus("已将 " state.Success
                . " 个项目移入回收站；操作随后被取消")
        } else {
            SetUserStatus("已将 " state.Success " 个项目移入回收站")
        }
    } else if aborted || HResultSucceeded(performHr) {
        SetUserStatus("删除操作已取消，未产生文件变化")
    }
    return {
        Success: state.Success,
        Failed: state.Failed,
        Skipped: skipped,
        Aborted: !!aborted,
        Changed: state.Changed,
        RefreshQueued: refreshQueued,
        Details: state.Details
    }
}

RemoveDeletedPinnedPaths(deletedPaths) {
    global PinnedPaths
    if !deletedPaths.Length
        return
    original := PinnedPaths.Clone()
    remaining := []
    for pinnedPath in PinnedPaths {
        deleted := false
        for deletedPath in deletedPaths {
            if IsSameOrDescendantPath(pinnedPath, deletedPath) {
                deleted := true
                break
            }
        }
        if !deleted
            remaining.Push(pinnedPath)
    }
    if PathArraysEqual(original, remaining)
        return
    PinnedPaths := remaining
    try SavePinnedFiles()
    catch as err {
        PinnedPaths := original
        throw err
    }
}

ShowRecycleDeleteDetails(details, *) {
    message := details.Length
        ? JoinArray(details, "`n") : "没有更多错误详情。"
    ShowPanelMsgBox(
        message "`n`nPopDrop 没有执行永久删除。",
        "回收站操作详情", "Iconi")
}

PerformShellFileOperation(operation, paths, targetPath, operationContext := 0) {
    ; Native IFileOperation pipeline. The advised
    ; IFileOperationProgressSink records actual destination Shell items;
    ; PerformOperations is always followed by GetAnyOperationsAborted.
    global Panel, PinnedPaths
    if operation != "copy" && operation != "move"
        return {Success: 0, Failed: paths.Length, Skipped: 0,
            Aborted: false, Changed: false, RefreshQueued: false}
    targetPath := NormalizePath(targetPath)
    targetName := IsObject(operationContext)
        && HasProp(operationContext, "TargetName")
        && operationContext.TargetName != ""
        ? operationContext.TargetName : GetFileName(targetPath)
    internalItems := IsObject(operationContext)
        && HasProp(operationContext, "InternalItems")
        ? operationContext.InternalItems : []
    targetSourceId := IsObject(operationContext)
        && HasProp(operationContext, "TargetSourceId")
        ? operationContext.TargetSourceId : ""
    suppressFinalStatus := IsObject(operationContext)
        && HasProp(operationContext, "SuppressFinalStatus")
        && operationContext.SuppressFinalStatus
    adoptDirectDrop := IsObject(operationContext)
        && HasProp(operationContext, "FromDrop") && operationContext.FromDrop
        && HasProp(operationContext, "SourceKind")
        && operationContext.SourceKind = "External"
    validPaths := []
    adoptedPaths := []
    skipped := 0
    noOp := 0
    validationDetails := []
    for path in paths {
        path := NormalizePath(path)
        attributes := FileExist(path)
        if !attributes {
            skipped += 1
            validationDetails.Push(path "：项目不存在或无法访问")
            continue
        }
        dropItem := FindDropItemForPath(internalItems, path)
        if IsObject(dropItem)
            && DropItemMatchesTargetSource(
                dropItem, targetPath, targetSourceId) {
            noOp += 1
            validationDetails.Push(path
                "：项目已属于该来源，已按无操作跳过")
            continue
        }
        if InStr(attributes, "D") && IsSameOrDescendantPath(targetPath, path) {
            skipped += 1
            validationDetails.Push(path "：不能复制或移动到自身或后代目录")
            continue
        }
        if PathsEqual(GetParentPath(path), targetPath) {
            if adoptDirectDrop {
                adoptedPaths.Push(path)
                validationDetails.Push(path
                    "：来源已直接保存到目标文件夹，未再次复制")
                continue
            }
            if operation = "move" {
                noOp += 1
                continue
            }
        }
        if !ArrayContainsPath(validPaths, path)
            validPaths.Push(path)
    }
    if !validPaths.Length {
        if adoptedPaths.Length {
            viewState := CaptureViewState(adoptedPaths)
            try RememberSuccessfulTarget(targetPath)
            catch {
                ; The file is already safe in the target. A recent-target
                ; bookkeeping failure must not trigger a second copy.
            }
            QueueSingleRefreshAfterFileOperation(viewState, Map())
            if !suppressFinalStatus
                SetActionStatus(
                    "来源已将 " adoptedPaths.Length
                    . " 个项目直接保存到「" targetName
                    . "」，PopDrop 未重复复制    打开目标文件夹",
                    OpenFolderPath.Bind(targetPath))
            return {
                Success: adoptedPaths.Length,
                Failed: 0,
                Skipped: skipped + noOp,
                Aborted: false,
                Changed: true,
                RefreshQueued: true,
                Details: validationDetails,
                ResultPaths: adoptedPaths.Clone(),
                Adopted: adoptedPaths.Length
            }
        }
        message := noOp
            ? "所选项目已属于该来源或目标与源位置相同，没有需要执行的项目。"
            : "没有可执行的项目；失效路径或文件夹自身/后代目标已跳过。"
        if !suppressFinalStatus
            SetActionStatus(message "    打开目标文件夹",
                OpenFolderPath.Bind(targetPath))
        return {
            Success: 0, Failed: 0, Skipped: skipped + noOp,
            Aborted: false, Changed: false, RefreshQueued: false,
            Details: validationDetails
        }
    }

    viewStatePaths := validPaths.Clone()
    for path in adoptedPaths
        viewStatePaths.Push(path)
    viewState := CaptureViewState(viewStatePaths)
    state := {
        Operation: operation,
        Target: targetPath,
        Success: adoptedPaths.Length,
        Failed: 0,
        Changed: adoptedPaths.Length > 0,
        Mappings: Map(),
        ResultPaths: adoptedPaths.Clone(),
        Adopted: adoptedPaths.Length,
        PinnedMappingFailures: [],
        Details: []
    }
    for detail in validationDetails
        state.Details.Push(detail)
    sink := CreateFileOperationProgressSink(state)
    fileOperation := 0
    destinationItem := 0
    cookie := 0
    queued := 0
    aborted := 0
    performHr := 0x80004005
    try {
        clsid := GuidBuffer("{3AD05575-8857-4850-9277-11B85BDB8E09}")
        iidFileOperation := GuidBuffer("{947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8}")
        hr := DllCall("ole32\CoCreateInstance", "ptr", clsid.Ptr,
            "ptr", 0, "uint", 1, "ptr", iidFileOperation.Ptr,
            "ptr*", &fileOperation, "int")
        if hr != 0 || !fileOperation
            throw Error("无法创建 Windows Shell 文件操作。")

        ; FOF_ALLOWUNDO | FOF_NOCONFIRMMKDIR | FOFX_SHOWELEVATIONPROMPT.
        ; 冲突、文件占用、合并和取消仍交由 Shell 标准界面处理。
        ComCall(5, fileOperation, "uint", 0x40240)
        ComCall(9, fileOperation, "ptr", Panel.Hwnd)
        hr := ComCall(3, fileOperation, "ptr", sink.Ptr, "uint*", &cookie)
        if hr != 0
            throw Error("无法订阅文件操作结果。")

        destinationItem := CreateShellItem(targetPath)
        if !destinationItem
            throw Error("Windows Shell 无法解析目标文件夹。")

        for sourcePath in validPaths {
            sourceItem := CreateShellItem(sourcePath)
            if !sourceItem {
                state.Failed += 1
                state.Details.Push(sourcePath "：Shell 无法解析")
                continue
            }
            try {
                if operation = "copy"
                    hr := ComCall(16, fileOperation, "ptr", sourceItem,
                        "ptr", destinationItem, "ptr", 0, "ptr", 0)
                else
                    hr := ComCall(14, fileOperation, "ptr", sourceItem,
                        "ptr", destinationItem, "ptr", 0, "ptr", 0)
                if HResultSucceeded(hr)
                    queued += 1
                else {
                    state.Failed += 1
                    state.Details.Push(sourcePath "：无法加入操作队列")
                }
            } finally {
                ObjRelease(sourceItem)
            }
        }
        if !queued
            throw Error("没有项目能够加入 Windows Shell 操作队列。")

        BeginAutoHidePause()
        try performHr := ComCall(21, fileOperation)
        finally EndAutoHidePause()
        ComCall(22, fileOperation, "int*", &aborted)
    } catch as err {
        ShowPanelMsgBox("文件操作失败：`n" err.Message,
            operation = "copy" ? "复制到" : "移动到", "Iconx")
    } finally {
        if fileOperation && cookie
            try ComCall(4, fileOperation, "uint", cookie)
        if destinationItem
            ObjRelease(destinationItem)
        if fileOperation
            ObjRelease(fileOperation)
        ReleaseFileOperationSink(sink)
    }

    totalFailures := state.Failed + skipped + noOp
    refreshQueued := false
    if state.Changed {
        pinnedUpdateFailed := false
        if operation = "move" && state.Mappings.Count {
            try UpdatePinnedPathsAfterMove(state.Mappings)
            catch as err {
                pinnedUpdateFailed := true
                ShowPanelMsgBox("文件已移动，但固定项路径保存失败：`n"
                    err.Message "`n`n请立即检查 config.ini。",
                    "固定项更新失败", "Iconx")
            }
        }
        if operation = "move" && state.PinnedMappingFailures.Length {
            pinnedUpdateFailed := true
            ShowPanelMsgBox(
                "以下固定项已移动，但 Windows Shell 未返回可验证的新路径：`n"
                JoinArray(state.PinnedMappingFailures, "`n")
                "`n`n请检查并修正固定项配置。",
                "固定项路径需要检查", "Icon!")
        }
        try RememberSuccessfulTarget(targetPath)
        catch as err
            ShowPanelMsgBox("文件操作已完成，但无法保存最近目标：`n"
                err.Message, "目标记录失败", "Icon!")
        QueueSingleRefreshAfterFileOperation(viewState, state.Mappings)
        refreshQueued := true
        actionText := operation = "copy" ? "复制" : "移动"
        if totalFailures {
            message := "已" actionText " " state.Success " 个项目到「"
                . targetName "」，" totalFailures
                . " 个项目失败或跳过    查看详情"
            if aborted
                message .= "；操作已取消"
        } else if aborted {
            message := "已" actionText " " state.Success
                . " 个项目到「" targetName
                . "」，操作随后被取消    打开目标文件夹"
        } else {
            message := "已将 " state.Success " 个项目" actionText
                . "到「" targetName "」    打开目标文件夹"
        }
        if state.Adopted
            message .= "；其中 " state.Adopted
                . " 项由来源直接保存，未重复复制"
        if IsObject(operationContext)
            && HasProp(operationContext, "FromDrop")
            && operationContext.FromDrop
            && DropTargetMayHideResults(operationContext,
                targetPath, state.ResultPaths)
            message .= "；文件已保存到目标文件夹；"
                . "部分项目因当前显示或筛选规则未显示。"
        if pinnedUpdateFailed
            message .= "；固定项需要检查"
        if !suppressFinalStatus {
            if totalFailures
                SetActionStatus(message, ShowFileOperationDetails.Bind(
                    state.Details.Clone(), targetPath))
            else
                SetActionStatus(message, OpenFolderPath.Bind(targetPath))
        }
    } else if aborted || HResultSucceeded(performHr) {
        if !suppressFinalStatus
            SetUserStatus("操作已取消，未产生文件变化")
    }
    return {
        Success: state.Success,
        Failed: state.Failed,
        Skipped: skipped + noOp,
        Aborted: !!aborted,
        Changed: state.Changed,
        RefreshQueued: refreshQueued,
        Details: state.Details,
        ResultPaths: state.ResultPaths,
        Adopted: state.Adopted
    }
}

DropTargetMayHideResults(operationContext, targetPath, resultPaths) {
    global LastValidFolderSettings
    sourceId := HasProp(operationContext, "TargetSourceId")
        ? operationContext.TargetSourceId : ""
    for folder in LastValidFolderSettings {
        if (sourceId != ""
                && StrLower(folder.SourceId) = StrLower(sourceId))
            || PathsEqual(folder.Path, targetPath)
            return SourceDisplayMayHideDrop(folder, resultPaths)
    }
    return false
}

SourceDisplayMayHideDrop(folder, resultPaths) {
    global SCOPE_FILES_ONLY, SCOPE_RECURSIVE_FILES
    if folder.MaxFilesPerFolder > 0 || folder.Filter.Mode != "All"
        return true
    if HasProp(folder, "NoiseFilter")
        && IsObject(folder.NoiseFilter) && folder.NoiseFilter.Enabled
        return true
    for path in resultPaths {
        if DirExist(path)
            && (folder.DisplayScope = SCOPE_FILES_ONLY
                || folder.DisplayScope = SCOPE_RECURSIVE_FILES)
            return true
        if !ShouldIncludeFile(GetFileName(path), folder.Filter)
            return true
    }
    return false
}

ShowFileOperationDetails(details, targetPath, *) {
    message := details.Length ? JoinArray(details, "`n") : "没有更多错误详情。"
    message .= "`n`n目标文件夹：`n" targetPath
        . "`n`n是否打开目标文件夹？"
    if ShowPanelMsgBox(message, "文件操作详情", "YesNo Iconi") = "Yes"
        OpenFolderPath(targetPath)
}

CreateShellItem(path) {
    iidShellItem := GuidBuffer("{43826D1E-E718-42EE-BC55-A1E261C37BFE}")
    item := 0
    hr := DllCall("shell32\SHCreateItemFromParsingName", "wstr", path,
        "ptr", 0, "ptr", iidShellItem.Ptr, "ptr*", &item, "int")
    return hr = 0 ? item : 0
}

HResultSucceeded(hr) {
    return (hr & 0x80000000) = 0
}

RememberSuccessfulTarget(targetPath) {
    global RecentTargets, LastTransferTargetDir
    targetPath := NormalizePath(targetPath)
    index := FindPathIndex(RecentTargets, targetPath)
    if index
        RecentTargets.RemoveAt(index)
    RecentTargets.InsertAt(1, targetPath)
    while RecentTargets.Length > 3
        RecentTargets.Pop()
    LastTransferTargetDir := targetPath
    SaveTransferTargets()
}

SaveTransferTargets() {
    AtomicConfigEdit(WriteTransferTargetsConfig)
}

WriteTransferTargetsConfig(tempPath) {
    global TransferFavorites, TransferFavoriteLabels
    global RecentTargets, LastTransferTargetDir, CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    doc.ReplaceSection("TransferFavorites",
        ConfigEntriesFromValues(TransferFavorites, "Path"), 5)
    labelEntries := []
    for index, path in TransferFavorites {
        key := PathKey(path)
        if TransferFavoriteLabels.Has(key)
            labelEntries.Push({
                Key: "Path" Format("{:03}", index),
                Value: TransferFavoriteLabels[key]
            })
    }
    doc.ReplaceSection("TransferFavoriteLabels", labelEntries, 5)
    doc.ReplaceSection("RecentTargets",
        ConfigEntriesFromValues(RecentTargets, "Path"), 5)
    doc.SetValue("General", "LastTransferTargetDir",
        LastTransferTargetDir, 1)
    doc.SetValue("General", "TransferFavoritesInitialized", "1", 1)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

UpdatePinnedPathsAfterMove(mappings) {
    global PinnedPaths
    changed := false
    for index, pinnedPath in PinnedPaths {
        key := PathKey(pinnedPath)
        if mappings.Has(key) {
            PinnedPaths[index] := mappings[key].NewPath
            changed := true
        }
    }
    if changed
        SavePinnedFiles()
}

CaptureViewState(operationPaths) {
    global FileView, ItemPaths
    selected := []
    for row in GetSelectedFileRows()
        selected.Push(ItemPaths[row])
    focusedRow := FileView.GetNext(0, "F")
    topIndex := DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
        "uint", 0x1027, "ptr", 0, "ptr", 0, "int") + 1 ; LVM_GETTOPINDEX
    return {
        Selected: selected,
        FocusedPath: focusedRow && ItemPaths.Has(focusedRow)
            ? ItemPaths[focusedRow] : "",
        AnchorRow: focusedRow ? focusedRow : topIndex,
        TopRow: topIndex
    }
}

QueueSingleRefreshAfterFileOperation(viewState, mappings) {
    global PendingViewRestore, PendingFileOperationRefresh
    selected := []
    for path in viewState.Selected {
        key := PathKey(path)
        selected.Push(mappings.Has(key) ? mappings[key].NewPath : path)
    }
    focusPath := viewState.FocusedPath
    focusKey := PathKey(focusPath)
    if focusPath != "" && mappings.Has(focusKey)
        focusPath := mappings[focusKey].NewPath
    PendingViewRestore := {
        Selected: selected,
        FocusedPath: focusPath,
        AnchorRow: viewState.AnchorRow,
        TopRow: viewState.TopRow
    }
    PendingFileOperationRefresh := true
    StartBackgroundScan()
}

ApplyPendingViewRestore() {
    global PendingViewRestore, PendingFileOperationRefresh, FileView, ItemPaths
    if !IsObject(PendingViewRestore)
        return
    restore := PendingViewRestore
    FileView.Modify(0, "-Select -Focus")
    selectedRows := []
    focusRow := 0
    for row, path in ItemPaths {
        if ArrayContainsPath(restore.Selected, path) {
            FileView.Modify(row, "Select")
            selectedRows.Push(row)
        }
        if restore.FocusedPath != "" && PathsEqual(path, restore.FocusedPath)
            focusRow := row
    }
    if !focusRow {
        if selectedRows.Length
            focusRow := selectedRows[1]
        else if ItemPaths.Count
            focusRow := Max(1, Min(restore.AnchorRow, ItemPaths.Count))
    }
    if focusRow {
        FileView.Modify(focusRow, "Focus Vis")
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
            "uint", 0x1013, "ptr", Max(0, restore.TopRow - 1),
            "ptr", 0, "ptr") ; LVM_ENSUREVISIBLE
    }
    PendingViewRestore := 0
    PendingFileOperationRefresh := false
    UpdateSelectionStatus()
}

InitFileOperationProgressSink() {
    global FileOperationSinkVTable, FileOperationSinkCallbacks
    FileOperationSinkCallbacks := [
        CallbackCreate(FileOpSinkQueryInterface, "Fast", 3),
        CallbackCreate(FileOpSinkAddRef, "Fast", 1),
        CallbackCreate(FileOpSinkRelease, "Fast", 1),
        CallbackCreate(FileOpSinkStartOperations, "Fast", 1),
        CallbackCreate(FileOpSinkFinishOperations, "Fast", 2),
        CallbackCreate(FileOpSinkPreRenameItem, "Fast", 4),
        CallbackCreate(FileOpSinkPostRenameItem, "Fast", 6),
        CallbackCreate(FileOpSinkPreMoveItem, "Fast", 5),
        CallbackCreate(FileOpSinkPostMoveItem, "Fast", 7),
        CallbackCreate(FileOpSinkPreCopyItem, "Fast", 5),
        CallbackCreate(FileOpSinkPostCopyItem, "Fast", 7),
        CallbackCreate(FileOpSinkPreDeleteItem, "Fast", 3),
        CallbackCreate(FileOpSinkPostDeleteItem, "Fast", 5),
        CallbackCreate(FileOpSinkPreNewItem, "Fast", 4),
        CallbackCreate(FileOpSinkPostNewItem, "Fast", 8),
        CallbackCreate(FileOpSinkUpdateProgress, "Fast", 3),
        CallbackCreate(FileOpSinkResetTimer, "Fast", 1),
        CallbackCreate(FileOpSinkPauseTimer, "Fast", 1),
        CallbackCreate(FileOpSinkResumeTimer, "Fast", 1)
    ]
    FileOperationSinkVTable := Buffer(
        FileOperationSinkCallbacks.Length * A_PtrSize, 0)
    for index, callback in FileOperationSinkCallbacks
        NumPut("ptr", callback, FileOperationSinkVTable,
            (index - 1) * A_PtrSize)
}

CreateFileOperationProgressSink(state) {
    global FileOperationSinkVTable, FileOperationSinks
    sink := Buffer(A_PtrSize + 8, 0)
    NumPut("ptr", FileOperationSinkVTable.Ptr, sink, 0)
    NumPut("uint", 1, sink, A_PtrSize)
    FileOperationSinks[sink.Ptr] := {Memory: sink, State: state}
    return sink
}

ReleaseFileOperationSink(sink) {
    if IsObject(sink)
        FileOpSinkRelease(sink.Ptr)
}

FileOpSinkQueryInterface(this, iid, objectOut) {
    static iidUnknown := GuidBuffer("{00000000-0000-0000-C000-000000000046}")
    static iidSink := GuidBuffer("{04B0F1A7-9490-44BC-96E1-4296A31252E2}")
    if !GuidPointersEqual(iid, iidUnknown.Ptr)
        && !GuidPointersEqual(iid, iidSink.Ptr) {
        NumPut("ptr", 0, objectOut)
        return 0x80004002
    }
    NumPut("ptr", this, objectOut)
    FileOpSinkAddRef(this)
    return 0
}

FileOpSinkAddRef(this) {
    count := NumGet(this + A_PtrSize, "uint") + 1
    NumPut("uint", count, this + A_PtrSize)
    return count
}

FileOpSinkRelease(this) {
    global FileOperationSinks
    count := NumGet(this + A_PtrSize, "uint")
    if count
        count -= 1
    NumPut("uint", count, this + A_PtrSize)
    if !count && FileOperationSinks.Has(this)
        FileOperationSinks.Delete(this)
    return count
}

FileOpSinkStartOperations(this) {
    return 0
}
FileOpSinkFinishOperations(this, hrResult) {
    return 0
}
FileOpSinkPreRenameItem(this, flags, item, newName) {
    return 0
}
FileOpSinkPostRenameItem(this, flags, item, newName, hr, created) {
    return 0
}
FileOpSinkPreMoveItem(this, flags, item, destination, newName) {
    return 0
}
FileOpSinkPostMoveItem(this, flags, item, destination, newName, hr, created) {
    RecordFileOperationResult(this, item, hr, created)
    return 0
}
FileOpSinkPreCopyItem(this, flags, item, destination, newName) {
    return 0
}
FileOpSinkPostCopyItem(this, flags, item, destination, newName, hr, created) {
    RecordFileOperationResult(this, item, hr, created)
    return 0
}
FileOpSinkPreDeleteItem(this, flags, item) {
    return 0
}
FileOpSinkPostDeleteItem(this, flags, item, hr, created) {
    RecordFileOperationResult(this, item, hr, created)
    return 0
}
FileOpSinkPreNewItem(this, flags, destination, newName) {
    return 0
}
FileOpSinkPostNewItem(this, flags, destination, newName, templateName,
    attributes, hr, created) {
    return 0
}
FileOpSinkUpdateProgress(this, total, completed) {
    return 0
}
FileOpSinkResetTimer(this) {
    return 0
}
FileOpSinkPauseTimer(this) {
    return 0
}
FileOpSinkResumeTimer(this) {
    return 0
}

RecordFileOperationResult(this, originalItem, hr, createdItem) {
    global FileOperationSinks, PinnedPaths
    if !FileOperationSinks.Has(this)
        return
    state := FileOperationSinks[this].State
    originalPath := GetShellItemPath(originalItem)
    if HResultSucceeded(hr) {
        if state.Operation = "delete" {
            state.Success += 1
            state.Changed := true
            if originalPath != ""
                state.DeletedPaths.Push(originalPath)
            return
        }
        newPath := createdItem ? GetShellItemPath(createdItem) : ""
        state.Success += 1
        state.Changed := true
        if newPath != ""
            state.ResultPaths.Push(newPath)
        if state.Operation = "move" && originalPath != "" {
            if newPath != ""
                state.Mappings[PathKey(originalPath)] := {
                    OldPath: originalPath, NewPath: newPath}
            else if FindPathIndex(PinnedPaths, originalPath) {
                state.PinnedMappingFailures.Push(originalPath)
                state.Details.Push(originalPath
                    "：Shell 未返回实际新路径，固定项未自动更新")
            }
        }
        return
    }
    state.Failed += 1
    if originalPath != ""
        state.Details.Push(originalPath "：操作未完成")
}

GetShellItemPath(shellItem) {
    if !shellItem
        return ""
    pathPtr := 0
    hr := ComCall(5, shellItem, "uint", 0x80058000,
        "ptr*", &pathPtr) ; SIGDN_FILESYSPATH
    if hr != 0 || !pathPtr
        return ""
    try return NormalizePath(StrGet(pathPtr))
    finally DllCall("ole32\CoTaskMemFree", "ptr", pathPtr)
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

; ──── OLE IDropTarget ────
; One COM object is registered on the panel and its child HWNDs. Windows routes
; a drag to the deepest registered window under the pointer, so registering
; only the Gui HWND would miss the ListView and toolbar controls.

InitDropTarget() {
    global DropTargetVTable, DropTargetCallbacks, DropTargetObjects
    global Panel
    enterCallback := A_PtrSize = 8
        ? CallbackCreate(DropTargetDragEnter64, "Fast", 5)
        : CallbackCreate(DropTargetDragEnter32, "Fast", 6)
    overCallback := A_PtrSize = 8
        ? CallbackCreate(DropTargetDragOver64, "Fast", 4)
        : CallbackCreate(DropTargetDragOver32, "Fast", 5)
    dropCallback := A_PtrSize = 8
        ? CallbackCreate(DropTargetDrop64, "Fast", 5)
        : CallbackCreate(DropTargetDrop32, "Fast", 6)
    DropTargetCallbacks := [
        CallbackCreate(DropTargetQueryInterface, "Fast", 3),
        CallbackCreate(DropTargetAddRef, "Fast", 1),
        CallbackCreate(DropTargetRelease, "Fast", 1),
        enterCallback,
        overCallback,
        CallbackCreate(DropTargetDragLeave, "Fast", 1),
        dropCallback
    ]
    DropTargetVTable := Buffer(7 * A_PtrSize, 0)
    for index, callbackPtr in DropTargetCallbacks
        NumPut("ptr", callbackPtr, DropTargetVTable, (index - 1) * A_PtrSize)

    target := Buffer(A_PtrSize + 8, 0)
    NumPut("ptr", DropTargetVTable.Ptr, target, 0)
    NumPut("uint", 1, target, A_PtrSize)
    DropTargetObjects[target.Ptr] := {Memory: target}
    RegisterPanelDropTargetWindows(Panel.Hwnd, target.Ptr)
}

RegisterPanelDropTargetWindows(rootHwnd, targetPtr) {
    RegisterDropTargetWindow(rootHwnd, targetPtr)
    RegisterDropTargetChildren(rootHwnd, targetPtr)
}

RegisterDropTargetChildren(parentHwnd, targetPtr) {
    static GW_CHILD := 5
    static GW_HWNDNEXT := 2
    child := DllCall("user32\GetWindow", "ptr", parentHwnd,
        "uint", GW_CHILD, "ptr")
    while child {
        RegisterDropTargetWindow(child, targetPtr)
        RegisterDropTargetChildren(child, targetPtr)
        child := DllCall("user32\GetWindow", "ptr", child,
            "uint", GW_HWNDNEXT, "ptr")
    }
}

RegisterDropTargetWindow(hwnd, targetPtr) {
    global DropTargetRegisteredHwnds, DropTargetRegistrationErrors
    if !hwnd || DropTargetRegisteredHwnds.Has(hwnd)
        return
    hr := DllCall("ole32\RegisterDragDrop", "ptr", hwnd,
        "ptr", targetPtr, "int")
    unsignedHr := hr & 0xFFFFFFFF
    if hr = 0 {
        DropTargetRegisteredHwnds[hwnd] := targetPtr
        return
    }
    if unsignedHr = 0x80040101
        reason := "窗口已由其他 OLE 投放目标注册"
    else
        reason := "RegisterDragDrop HRESULT "
            . Format("0x{:08X}", unsignedHr)
    DropTargetRegistrationErrors.Push({Hwnd: hwnd, Reason: reason})
}

RevokePanelDropTargets() {
    global DropTargetRegisteredHwnds, DropTargetObjects
    for hwnd, targetPtr in DropTargetRegisteredHwnds {
        if DllCall("user32\IsWindow", "ptr", hwnd, "int")
            try DllCall("ole32\RevokeDragDrop", "ptr", hwnd, "int")
    }
    DropTargetRegisteredHwnds := Map()
    baseTargets := []
    for targetPtr, targetState in DropTargetObjects
        baseTargets.Push(targetPtr)
    for targetPtr in baseTargets
        DropTargetRelease(targetPtr)
}

DropTargetQueryInterface(this, iid, objectOut) {
    static iidUnknown := GuidBuffer("{00000000-0000-0000-C000-000000000046}")
    static iidDropTarget := GuidBuffer("{00000122-0000-0000-C000-000000000046}")
    if !GuidPointersEqual(iid, iidUnknown.Ptr)
        && !GuidPointersEqual(iid, iidDropTarget.Ptr) {
        NumPut("ptr", 0, objectOut)
        return 0x80004002
    }
    NumPut("ptr", this, objectOut)
    DropTargetAddRef(this)
    return 0
}

DropTargetAddRef(this) {
    count := NumGet(this + A_PtrSize, "uint") + 1
    NumPut("uint", count, this + A_PtrSize)
    return count
}

DropTargetRelease(this) {
    global DropTargetObjects
    count := NumGet(this + A_PtrSize, "uint")
    if count
        count -= 1
    NumPut("uint", count, this + A_PtrSize)
    if !count && DropTargetObjects.Has(this)
        DropTargetObjects.Delete(this)
    return count
}

DropTargetDragEnter64(this, dataObject, keyState, pointValue, effectPtr) {
    return DropTargetDragEnterCore(dataObject, keyState,
        PointValueX(pointValue), PointValueY(pointValue), effectPtr)
}

DropTargetDragEnter32(this, dataObject, keyState, pointX, pointY, effectPtr) {
    return DropTargetDragEnterCore(dataObject, keyState,
        SignedInt32(pointX), SignedInt32(pointY), effectPtr)
}

DropTargetDragOver64(this, keyState, pointValue, effectPtr) {
    return DropTargetDragOverCore(keyState,
        PointValueX(pointValue), PointValueY(pointValue), effectPtr)
}

DropTargetDragOver32(this, keyState, pointX, pointY, effectPtr) {
    return DropTargetDragOverCore(keyState,
        SignedInt32(pointX), SignedInt32(pointY), effectPtr)
}

DropTargetDrop64(this, dataObject, keyState, pointValue, effectPtr) {
    return DropTargetDropCore(dataObject, keyState,
        PointValueX(pointValue), PointValueY(pointValue), effectPtr)
}

DropTargetDrop32(this, dataObject, keyState, pointX, pointY, effectPtr) {
    return DropTargetDropCore(dataObject, keyState,
        SignedInt32(pointX), SignedInt32(pointY), effectPtr)
}

PointValueX(pointValue) {
    return SignedInt32(pointValue & 0xFFFFFFFF)
}

PointValueY(pointValue) {
    return SignedInt32((pointValue >> 32) & 0xFFFFFFFF)
}

SignedInt32(value) {
    value &= 0xFFFFFFFF
    return value >= 0x80000000 ? value - 0x100000000 : value
}

DropTargetDragEnterCore(dataObject, keyState, screenX, screenY, effectPtr) {
    global ActiveDropSession, ActiveInternalDragContext
    global DropFolderValidationCache
    global DROP_ADAPTER_UNSUPPORTED
    try {
        ResetActiveDropSession(true)
        DropFolderValidationCache := Map()
        allowedEffects := NumGet(effectPtr + 0, "uint") & 0x3
        session := CreateDropSessionState()
        session.DataObject := dataObject
        ObjAddRef(dataObject)
        session.AllowedEffects := allowedEffects
        session.PreviousStatus := CaptureDropStatus()
        session.Paused := true
        BeginAutoHidePause()
        ActiveDropSession := session
        SetPinnedDropDiscovery(true)

        session.Decision := ClassifyDataObject(dataObject)
        session.AsyncInfo := DataObjectAsyncMode(dataObject)
        if session.Decision.Adapter = DROP_ADAPTER_UNSUPPORTED {
            session.Unsupported := true
            SetDropEffect(effectPtr, 0)
            ShowDropFeedback(InvalidDropTarget(
                session.Decision.Reason), 0, 0)
            return 0
        }
        ; DragEnter/DragOver intentionally stop at QueryGetData/EnumFormatEtc.
        ; GetData, file enumeration and all stream/network work happen after
        ; Drop. Internal drags are known to be CF_HDROP and retain their
        ; source context without extracting the payload here.
        session.SourceKind := IsObject(ActiveInternalDragContext)
            ? ClassifyDropSource(ActiveInternalDragContext.Items, true)
            : "External"
        return UpdateDropFeedback(keyState, screenX, screenY, effectPtr)
    } catch {
        SetDropEffect(effectPtr, 0)
        ResetActiveDropSession(true)
        return 0
    }
}

DropTargetDragOverCore(keyState, screenX, screenY, effectPtr) {
    try return UpdateDropFeedback(keyState, screenX, screenY, effectPtr)
    catch {
        SetDropEffect(effectPtr, 0)
        return 0
    }
}

DropTargetDragLeave(this) {
    ResetActiveDropSession(true)
    return 0
}

DropTargetDropCore(dataObject, keyState, screenX, screenY, effectPtr) {
    global ActiveDropSession, DROP_ADAPTER_HDROP
    try {
        if !IsObject(ActiveDropSession) || ActiveDropSession.Unsupported {
            SetDropEffect(effectPtr, 0)
            ResetActiveDropSession(true)
            return 0
        }
        UpdateDropFeedback(keyState, screenX, screenY, effectPtr)
        session := ActiveDropSession
        effect := session.Effect
        target := session.Target
        SetDropEffect(effectPtr, effect)
        if !effect || !IsObject(target) || !target.Available {
            ResetActiveDropSession(true)
            return 0
        }

        ; Detach the state before invoking Shell/UI code to prevent reentrant
        ; DragLeave from clearing the final operation status.
        ActiveDropSession := 0
        ClearDropVisuals()
        try {
            if session.Decision.Adapter = DROP_ADAPTER_HDROP {
                if HDropShouldUseDirectAsyncTakeover(
                    session.SourceKind, target, session.AsyncInfo) {
                    ; Do not pre-read delayed-render CF_HDROP here. Chromium
                    ; may start one source download per GetData call.
                    CreateExternalTransfer(dataObject,
                        session.Decision.Adapter, target)
                } else {
                    session.Paths := ReadHDropPaths(dataObject)
                    if !session.Paths.Length
                        throw Error("拖拽数据中没有有效的本地文件系统项目。")
                    if session.SourceKind = "External"
                        && HasProp(session.Decision, "HasExplicitUrl")
                        && session.Decision.HasExplicitUrl
                        session.Paths := DedupeWebHDropPaths(session.Paths)
                    session.InternalItems := GetActiveInternalDropItems(
                        session.Paths)
                    session.PathInfo := BuildDropPathInfo(session.Paths)
                    session.SourceKind := ClassifyDropSource(
                        session.InternalItems,
                        IsObject(ActiveInternalDragContext))
                    ExecuteLocalDrop(session.Paths, target, effect,
                        session.InternalItems, session.SourceKind)
                }
            } else {
                CreateExternalTransfer(dataObject,
                    session.Decision.Adapter, target)
            }
        } catch as err {
            SetDropEffect(effectPtr, 0)
            ShowPanelMsgBox("无法完成投放：`n" err.Message,
                "投放失败", "Iconx")
        }
        finally {
            if HasProp(session, "DataObject") && session.DataObject
                ObjRelease(session.DataObject)
            KeepTemporaryPanelVisibleAfterDrag()
            if session.Paused
                EndAutoHidePause()
            MarkDropSessionFinished(session, "drop")
        }
        return 0
    } catch {
        SetDropEffect(effectPtr, 0)
        ResetActiveDropSession(true)
        return 0
    }
}

CreateDropSessionState() {
    return {
        DataObject: 0,
        AllowedEffects: 0,
        Paths: [],
        InternalItems: [],
        SourceKind: "External",
        Target: 0,
        Effect: 0,
        SkipCount: 0,
        PathInfo: Map(),
        Decision: {Adapter: "Unsupported", Formats: [], Reason: ""},
        AsyncInfo: {Supported: false, Enabled: false},
        Unsupported: false,
        Paused: false,
        PreviousStatus: 0,
        Completed: false
    }
}

MarkDropSessionFinished(session, outcome) {
    session.Completed := true
    session.Outcome := outcome
    session.Paused := false
    return session
}

ResetActiveDropSession(restoreStatus := true) {
    global ActiveDropSession
    if !IsObject(ActiveDropSession) {
        ClearDropVisuals()
        return
    }
    session := ActiveDropSession
    ActiveDropSession := 0
    ClearDropVisuals()
    if restoreStatus && IsObject(session.PreviousStatus)
        RestoreDropStatus(session.PreviousStatus)
    if HasProp(session, "DataObject") && session.DataObject
        ObjRelease(session.DataObject)
    if session.Paused
        EndAutoHidePause()
    MarkDropSessionFinished(session, "reset")
}

UpdateDropFeedback(keyState, screenX, screenY, effectPtr) {
    global ActiveDropSession, DROP_ADAPTER_HDROP
    if !IsObject(ActiveDropSession) || ActiveDropSession.Unsupported {
        SetDropEffect(effectPtr, 0)
        return 0
    }
    target := ResolveDropTarget(screenX, screenY)
    adapter := ActiveDropSession.Decision.Adapter
    if !ExternalAdapterAllowedAtTarget(adapter, target) {
        target.Available := false
        target.Reason := ExternalAdapterTargetReason(adapter, target)
    }
    effect := ResolveDropEffect(target, keyState,
        ActiveDropSession.AllowedEffects, ActiveDropSession.SourceKind)
    if adapter != DROP_ADAPTER_HDROP && target.Available
        effect := (ActiveDropSession.AllowedEffects & 1) ? 1 : 0
    else if adapter = DROP_ADAPTER_HDROP
        && ActiveDropSession.AsyncInfo.Supported
        && ActiveDropSession.SourceKind = "External"
        && target.Type = "Files"
        effect := (ActiveDropSession.AllowedEffects & 1) ? 1 : 0
    skipCount := GetDropPreviewSkipCount(target, effect,
        ActiveDropSession.Paths, ActiveDropSession.InternalItems,
        ActiveDropSession.PathInfo)
    if effect && ActiveDropSession.Paths.Length
        && skipCount = ActiveDropSession.Paths.Length {
        target.Available := false
        target.Reason := "所有项目都属于该来源、位于目标位置，"
            . "或文件夹目标是其自身/后代。"
        effect := 0
    }
    ActiveDropSession.Target := target
    ActiveDropSession.Effect := effect
    ActiveDropSession.SkipCount := skipCount
    SetDropEffect(effectPtr, effect)
    itemCount := ActiveDropSession.Paths.Length
        ? ActiveDropSession.Paths.Length : 1
    ShowDropFeedback(target, effect, itemCount,
        skipCount)
    return 0
}

SetDropEffect(effectPtr, effect) {
    if effectPtr
        NumPut("uint", effect, effectPtr + 0)
}

DataObjectSupportsHDrop(dataObject) {
    if !dataObject
        return false
    formatSize := A_PtrSize = 8 ? 32 : 20
    formatEtc := Buffer(formatSize, 0)
    FillHDropFormat(formatEtc.Ptr)
    try return HResultSucceeded(
        ComCall(5, dataObject, "ptr", formatEtc.Ptr, "int"))
    catch
        return false
}

ReadHDropPaths(dataObject) {
    paths := []
    formatSize := A_PtrSize = 8 ? 32 : 20
    mediumSize := A_PtrSize = 8 ? 24 : 12
    formatEtc := Buffer(formatSize, 0)
    medium := Buffer(mediumSize, 0)
    FillHDropFormat(formatEtc.Ptr)
    hr := ComCall(3, dataObject, "ptr", formatEtc.Ptr,
        "ptr", medium.Ptr, "int")
    if !HResultSucceeded(hr)
        return paths
    try {
        unionOffset := A_PtrSize = 8 ? 8 : 4
        hDrop := NumGet(medium, unionOffset, "ptr")
        if !hDrop
            return paths
        count := DllCall("shell32\DragQueryFileW", "ptr", hDrop,
            "uint", 0xFFFFFFFF, "ptr", 0, "uint", 0, "uint")
        Loop count {
            index := A_Index - 1
            length := DllCall("shell32\DragQueryFileW", "ptr", hDrop,
                "uint", index, "ptr", 0, "uint", 0, "uint")
            if !length
                continue
            pathBuffer := Buffer((length + 1) * 2, 0)
            if DllCall("shell32\DragQueryFileW", "ptr", hDrop,
                "uint", index, "ptr", pathBuffer.Ptr,
                "uint", length + 1, "uint") {
                path := NormalizePath(StrGet(pathBuffer))
                if path != "" && !ArrayContainsPath(paths, path)
                    paths.Push(path)
            }
        }
    } finally {
        DllCall("ole32\ReleaseStgMedium", "ptr", medium.Ptr)
    }
    return paths
}

GetActiveInternalDropItems(paths) {
    global ActiveInternalDragContext
    if !IsObject(ActiveInternalDragContext)
        return []
    items := []
    for path in paths {
        found := 0
        for context in ActiveInternalDragContext.Items {
            if HasProp(context, "Path") && PathsEqual(context.Path, path) {
                found := CloneDropItemContext(context)
                found.Path := path
                break
            }
        }
        if !IsObject(found)
            found := {Path: path, Area: "Unknown"}
        items.Push(found)
    }
    return items
}

ClassifyDropSource(items, isInternal) {
    if !isInternal
        return "External"
    if !items.Length
        return "InternalUnknown"
    allSource := true
    allPinned := true
    allRecent := true
    for item in items {
        area := HasProp(item, "Area") ? item.Area : "Unknown"
        if area != "Source"
            allSource := false
        if area != "Pinned"
            allPinned := false
        if area != "Recent"
            allRecent := false
    }
    if allSource
        return "Source"
    if allPinned
        return "Pinned"
    if allRecent
        return "Recent"
    return "Mixed"
}

BuildDropPathInfo(paths) {
    info := Map()
    for path in paths {
        attributes := FileExist(path)
        info[PathKey(path)] := {
            Exists: attributes != "",
            IsDirectory: attributes != "" && InStr(attributes, "D")
        }
    }
    return info
}

GetDropPreviewSkipCount(target, effect, paths, internalItems, pathInfo) {
    if !effect || !IsObject(target) || target.Type != "Files"
        return 0
    skipped := 0
    for path in paths {
        key := PathKey(path)
        if !pathInfo.Has(key) || !pathInfo[key].Exists {
            skipped += 1
            continue
        }
        item := FindDropItemForPath(internalItems, path)
        if IsObject(item)
            && DropItemMatchesTargetSource(
                item, target.Path, target.SourceId) {
            skipped += 1
            continue
        }
        if pathInfo[key].IsDirectory
            && IsSameOrDescendantPath(target.Path, path) {
            skipped += 1
            continue
        }
        if effect = 2 && PathsEqual(GetParentPath(path), target.Path)
            skipped += 1
    }
    return skipped
}

ResolveDropEffect(target, keyState, allowedEffects, sourceKind) {
    static DROPEFFECT_NONE := 0
    static DROPEFFECT_COPY := 1
    static DROPEFFECT_MOVE := 2
    if !IsObject(target) || !target.Available
        return DROPEFFECT_NONE
    if target.Type = "Pinned" || target.Type = "Launcher"
        return (allowedEffects & DROPEFFECT_COPY)
            ? DROPEFFECT_COPY : DROPEFFECT_NONE
    if target.Type != "Files"
        return DROPEFFECT_NONE

    ctrl := (keyState & 0x0008) != 0
    shift := (keyState & 0x0004) != 0
    if ctrl
        preferred := DROPEFFECT_COPY
    else if shift
        preferred := DROPEFFECT_MOVE
    else
        preferred := sourceKind = "Source"
            ? DROPEFFECT_MOVE : DROPEFFECT_COPY

    if allowedEffects & preferred
        return preferred
    ; Falling back from a move request to copy is safe. Falling back from a
    ; copy request to move is not: it would remove source data unexpectedly.
    if preferred = DROPEFFECT_MOVE
        && (allowedEffects & DROPEFFECT_COPY)
        return DROPEFFECT_COPY
    return DROPEFFECT_NONE
}

ShouldContinuePinnedReorder(target) {
    ; GroupId=0 表示工具栏上的“＋ 固定项”投放按钮；它接收加入固定项，
    ; 但不是已有固定项的排序区域。
    return IsObject(target)
        && HasProp(target, "Type") && target.Type = "Pinned"
        && HasProp(target, "Available") && target.Available
        && HasProp(target, "GroupId") && target.GroupId != 0
}

ResolveDropTarget(screenX, screenY) {
    global Panel, FileView, RecentView, PinnedDropButton
    global ItemOpenContexts, GroupDropTargets
    if !IsObject(Panel)
        return InvalidDropTarget("PopDrop 面板不可用。")

    if IsObject(PinnedDropButton)
        && ScreenPointInWindow(PinnedDropButton.Hwnd, screenX, screenY)
        return ResolveDropTargetDescriptor({
            Type: "Pinned", SourceId: "", Name: "固定项",
            Path: "", GroupId: 0
        })

    if IsObject(RecentView)
        && ScreenPointInWindow(RecentView.Hwnd, screenX, screenY)
        return InvalidDropTarget("最近文件区域不能接收投放。")

    if IsObject(FileView)
        && ScreenPointInWindow(FileView.Hwnd, screenX, screenY) {
        point := ScreenToClientPoint(FileView.Hwnd, screenX, screenY)
        row := HitTestListRow(FileView.Hwnd, point.X, point.Y)
        if row && ItemOpenContexts.Has(row) {
            context := ItemOpenContexts[row]
            if HasProp(context, "GroupId")
                && GroupDropTargets.Has(context.GroupId)
                return ResolveDropTargetDescriptor(
                    GroupDropTargets[context.GroupId])
        }
        for groupId, descriptor in GroupDropTargets {
            rect := GetListGroupRect(FileView.Hwnd, groupId)
            if IsObject(rect)
                && point.X >= rect.Left && point.X < rect.Right
                && point.Y >= rect.Top && point.Y < rect.Bottom
                return ResolveDropTargetDescriptor(descriptor)
        }
        return InvalidDropTarget("主列表空白区域不能接收投放。")
    }

    if ScreenPointInWindow(Panel.Hwnd, screenX, screenY)
        return InvalidDropTarget("此控件或区域不能接收投放。")
    return InvalidDropTarget("不在 PopDrop 的可投放区域内。")
}

ResolveDropTargetDescriptor(descriptor, folderAvailable := unset,
    folderWritable := unset) {
    type := HasProp(descriptor, "Type") ? descriptor.Type : "Invalid"
    name := HasProp(descriptor, "Name") ? descriptor.Name : ""
    sourceId := HasProp(descriptor, "SourceId") ? descriptor.SourceId : ""
    groupId := HasProp(descriptor, "GroupId") ? descriptor.GroupId : 0
    if type = "Pinned" {
        return {
            Type: "Pinned", SourceId: "", Name: name != "" ? name : "固定项",
            Path: "", Available: true, Reason: "", GroupId: groupId
        }
    }
    if type != "Files" && type != "Launcher"
        return InvalidDropTarget("此区域没有对应的来源文件夹。", groupId)
    path := NormalizePath(HasProp(descriptor, "Path") ? descriptor.Path : "")
    if path = ""
        return InvalidDropTarget("来源路径无法解析。", groupId, type,
            sourceId, name, path)

    if !IsSet(folderAvailable) || !IsSet(folderWritable) {
        availability := ValidateDropFolder(path)
        folderAvailable := availability.Available
        folderWritable := availability.Writable
        reason := availability.Reason
    } else {
        reason := !folderAvailable
            ? "来源不存在、离线或当前无法访问。"
            : (!folderWritable ? "来源当前没有写入权限。" : "")
    }
    return {
        Type: type,
        SourceId: sourceId,
        Name: name != "" ? name : GetFileName(path),
        Path: path,
        Available: !!folderAvailable && !!folderWritable,
        Reason: reason,
        GroupId: groupId
    }
}

InvalidDropTarget(reason, groupId := 0, type := "Invalid",
    sourceId := "", name := "", path := "") {
    return {
        Type: type, SourceId: sourceId, Name: name, Path: path,
        Available: false, Reason: reason, GroupId: groupId
    }
}

ValidateDropFolder(path, force := false) {
    global DropFolderValidationCache
    key := PathKey(path)
    if !force && DropFolderValidationCache.Has(key)
        return DropFolderValidationCache[key]
    if !DirExist(path) {
        result := {Available: false, Writable: false,
            Reason: "来源不存在、离线或当前无法访问。"}
        DropFolderValidationCache[key] := result
        return result
    }
    ; FILE_ADD_FILE on a directory is a non-mutating ACL/share check. Shell
    ; operations revalidate immediately before execution.
    handle := DllCall("kernel32\CreateFileW", "wstr", path,
        "uint", 0x0002, "uint", 0x7, "ptr", 0, "uint", 3,
        "uint", 0x02000000, "ptr", 0, "ptr")
    invalidHandle := -1
    if handle = invalidHandle {
        result := {Available: true, Writable: false,
            Reason: "来源当前没有写入权限，或网络位置拒绝写入。"}
    } else {
        DllCall("kernel32\CloseHandle", "ptr", handle)
        result := {Available: true, Writable: true, Reason: ""}
    }
    DropFolderValidationCache[key] := result
    return result
}

ScreenPointInWindow(hwnd, screenX, screenY) {
    if !hwnd || !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
        return false
    rect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
        return false
    return screenX >= NumGet(rect, 0, "int")
        && screenY >= NumGet(rect, 4, "int")
        && screenX < NumGet(rect, 8, "int")
        && screenY < NumGet(rect, 12, "int")
}

ScreenToClientPoint(hwnd, screenX, screenY) {
    point := Buffer(8, 0)
    NumPut("int", screenX, point, 0)
    NumPut("int", screenY, point, 4)
    DllCall("user32\ScreenToClient", "ptr", hwnd, "ptr", point.Ptr)
    return {X: NumGet(point, 0, "int"), Y: NumGet(point, 4, "int")}
}

ClientToScreenPoint(hwnd, clientX, clientY) {
    point := Buffer(8, 0)
    NumPut("int", clientX, point, 0)
    NumPut("int", clientY, point, 4)
    DllCall("user32\ClientToScreen", "ptr", hwnd, "ptr", point.Ptr)
    return {X: NumGet(point, 0, "int"), Y: NumGet(point, 4, "int")}
}

GetListGroupRect(hwnd, groupId, part := 0) {
    rect := Buffer(16, 0)
    NumPut("int", part, rect, 4) ; RECT.top = LVGGR_GROUP / LVGGR_HEADER
    if !DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x1062,
        "ptr", groupId, "ptr", rect.Ptr, "ptr")
        return 0
    return {
        Left: NumGet(rect, 0, "int"),
        Top: NumGet(rect, 4, "int"),
        Right: NumGet(rect, 8, "int"),
        Bottom: NumGet(rect, 12, "int")
    }
}

CaptureDropStatus() {
    global StatusText, StatusKind, CurrentStatusAction
    return {
        Text: IsObject(StatusText) ? StatusText.Text : "",
        Kind: StatusKind,
        Action: CurrentStatusAction
    }
}

RestoreDropStatus(snapshot) {
    global StatusText, StatusKind, CurrentStatusAction
    if !IsObject(snapshot)
        return
    StatusKind := snapshot.Kind
    CurrentStatusAction := snapshot.Action
    if IsObject(StatusText)
        StatusText.Text := snapshot.Text
}

ShowDropFeedback(target, effect, itemCount, skipCount := 0) {
    global StatusText, StatusKind, CurrentStatusAction
    SetDropGroupHighlight(HasProp(target, "GroupId")
        ? target.GroupId : 0)
    SetPinnedDropHover(target.Type = "Pinned" && target.Available)
    CurrentStatusAction := 0
    StatusKind := "user"
    if !IsObject(StatusText)
        return
    if !target.Available {
        StatusText.Text := target.Reason != ""
            ? "不能投放：" target.Reason : "此处不能投放。"
        return
    }
    if !effect {
        StatusText.Text := "源程序没有提供可安全执行的复制或移动效果。"
        return
    }
    countText := itemCount " 个项目"
    if target.Type = "Pinned"
        StatusText.Text := "添加 " countText " 到固定项"
    else if target.Type = "Launcher"
        StatusText.Text := "在「" target.Name "」中为 "
            . countText " 创建快捷方式"
    else if effect = 2
        StatusText.Text := "移动 " countText " 到「" target.Name "」"
    else
        StatusText.Text := "复制 " countText " 到「" target.Name "」"
    if skipCount
        StatusText.Text .= "；其中 " skipCount " 个项目将跳过"
    DllCall("user32\UpdateWindow", "ptr", StatusText.Hwnd)
}

SetPinnedDropDiscovery(active) {
    global PinnedDropButton, PinnedDropDiscoveryActive
    if !IsObject(PinnedDropButton)
        return
    active := !!active
    if active = PinnedDropDiscoveryActive
        return
    PinnedDropDiscoveryActive := active
    try PinnedDropButton.Opt(active ? "+Default" : "-Default")
    DllCall("user32\InvalidateRect", "ptr", PinnedDropButton.Hwnd,
        "ptr", 0, "int", 1)
}

SetPinnedDropHover(active) {
    global PinnedDropButton
    if IsObject(PinnedDropButton)
        DllCall("user32\SendMessageW", "ptr", PinnedDropButton.Hwnd,
            "uint", 0x00F3, "ptr", active ? 1 : 0, "ptr", 0, "ptr")
}

SetDropGroupHighlight(groupId) {
    global ActiveDropHighlightedGroup, FileView
    if groupId = ActiveDropHighlightedGroup
        return
    if IsObject(FileView) && ActiveDropHighlightedGroup
        SetListGroupSelected(FileView.Hwnd,
            ActiveDropHighlightedGroup, false)
    ActiveDropHighlightedGroup := groupId
    if IsObject(FileView) && groupId
        SetListGroupSelected(FileView.Hwnd, groupId, true)
}

SetListGroupSelected(hwnd, groupId, selected) {
    groupSize := A_PtrSize = 8 ? 152 : 96
    group := Buffer(groupSize, 0)
    stateMaskOffset := A_PtrSize = 8 ? 40 : 28
    stateOffset := A_PtrSize = 8 ? 44 : 32
    NumPut("uint", groupSize, group, 0)
    NumPut("uint", 0x4, group, 4) ; LVGF_STATE
    NumPut("uint", 0x20, group, stateMaskOffset) ; LVGS_SELECTED
    NumPut("uint", selected ? 0x20 : 0, group, stateOffset)
    DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x1093,
        "ptr", groupId, "ptr", group.Ptr, "ptr")
    rect := GetListGroupRect(hwnd, groupId)
    if IsObject(rect) {
        nativeRect := Buffer(16, 0)
        NumPut("int", rect.Left, nativeRect, 0)
        NumPut("int", rect.Top, nativeRect, 4)
        NumPut("int", rect.Right, nativeRect, 8)
        NumPut("int", rect.Bottom, nativeRect, 12)
        DllCall("user32\InvalidateRect", "ptr", hwnd,
            "ptr", nativeRect.Ptr, "int", 1)
    }
}

ClearDropVisuals() {
    SetDropGroupHighlight(0)
    SetPinnedDropHover(false)
    SetPinnedDropDiscovery(false)
}

ExecuteLocalDrop(paths, target, effect, internalItems, sourceKind) {
    validation := target.Type = "Pinned"
        ? {Available: true, Writable: true, Reason: ""}
        : ValidateDropFolder(target.Path, true)
    if !validation.Available || !validation.Writable {
        SetUserStatus("投放失败：「" target.Name "」"
            . (validation.Reason != "" ? validation.Reason : "当前不可用。"))
        return {Success: 0, Failed: paths.Length, Changed: false}
    }
    if target.Type = "Pinned"
        return PinDroppedItems(paths)
    if target.Type = "Launcher"
        return PerformLauncherDrop(paths, target)
    if target.Type != "Files" {
        SetUserStatus("此区域不能接收投放。")
        return {Success: 0, Failed: paths.Length, Changed: false}
    }
    operation := effect = 2 ? "move" : "copy"
    return PerformShellFileOperation(operation, paths, target.Path, {
        TargetName: target.Name,
        TargetSourceId: target.SourceId,
        InternalItems: internalItems,
        SourceKind: sourceKind,
        FromDrop: true
    })
}

DropItemMatchesTargetSource(item, targetPath, targetSourceId := "") {
    if !IsObject(item) || !HasProp(item, "Area")
        || item.Area != "Source"
        return false
    if HasProp(item, "SourcePath")
        && PathsEqual(item.SourcePath, targetPath)
        return true
    return targetSourceId != "" && HasProp(item, "SourceId")
        && StrLower(item.SourceId) = StrLower(targetSourceId)
}

FindDropItemForPath(items, path) {
    if !IsObject(items)
        return 0
    for item in items {
        if HasProp(item, "Path") && PathsEqual(item.Path, path)
            return item
    }
    return 0
}

PerformLauncherDrop(paths, target) {
    linkSources := []
    copySources := []
    invalid := 0
    for path in paths {
        attributes := FileExist(path)
        if !attributes {
            invalid += 1
            continue
        }
        SplitPath(path, , , &extension)
        extension := StrLower(extension)
        if !InStr(attributes, "D")
            && (extension = "lnk" || extension = "url")
            copySources.Push(path)
        else
            linkSources.Push(path)
    }

    linkResult := CreateLauncherShortcuts(linkSources, target.Path)
    copyResult := {
        Success: 0, Failed: 0, Skipped: 0,
        Aborted: false, Changed: false, RefreshQueued: false
    }
    if copySources.Length
        copyResult := PerformShellFileOperation("copy", copySources,
            target.Path, {
                TargetName: target.Name,
                FromDrop: true,
                SuppressFinalStatus: true
            })
    changed := linkResult.Success > 0 || copyResult.Changed
    if linkResult.Success > 0 && !copyResult.RefreshQueued
        StartBackgroundScan()

    success := linkResult.Success + copyResult.Success
    failed := invalid + linkResult.Failed + copyResult.Failed
        + copyResult.Skipped
    cancelled := copyResult.Aborted ? 1 : 0
    message := "已在「" target.Name "」中创建或复制 "
        . success " 个快捷方式"
    if failed || cancelled
        message .= "；" failed " 个失败或跳过"
            . (cancelled ? "，操作已取消" : "")
    resultPaths := linkResult.ResultPaths.Clone()
    if HasProp(copyResult, "ResultPaths") {
        for path in copyResult.ResultPaths
            resultPaths.Push(path)
    }
    if changed && DropTargetMayHideResults(
        {TargetSourceId: target.SourceId}, target.Path, resultPaths)
        message .= "；文件已保存到目标文件夹；"
            . "部分项目因当前显示或筛选规则未显示。"
    message .= "    打开目标文件夹"
    SetActionStatus(message, OpenFolderPath.Bind(target.Path))
    return {
        Success: success, Failed: failed, Skipped: copyResult.Skipped,
        Aborted: copyResult.Aborted, Changed: changed,
        RefreshQueued: copyResult.RefreshQueued || linkResult.Success > 0
    }
}

CreateLauncherShortcuts(paths, targetPath) {
    success := 0
    failed := 0
    details := []
    resultPaths := []
    try shell := ComObject("WScript.Shell")
    catch as err
        return {Success: 0, Failed: paths.Length,
            Details: ["无法创建 Windows Shell 快捷方式对象：" err.Message],
            ResultPaths: []}
    for index, sourcePath in paths {
        finalPath := ""
        tempPath := targetPath "\.~PopDrop-"
            . DllCall("kernel32\GetCurrentProcessId", "uint")
            . "-" A_TickCount "-" index ".lnk"
        try {
            baseName := LauncherShortcutBaseName(sourcePath)
            tempSuffix := 2
            while FileExist(tempPath) {
                tempPath := targetPath "\.~PopDrop-"
                    . DllCall("kernel32\GetCurrentProcessId", "uint")
                    . "-" A_TickCount "-" index "-" tempSuffix++ ".lnk"
            }
            shortcut := shell.CreateShortcut(tempPath)
            shortcut.TargetPath := sourcePath
            if DirExist(sourcePath)
                shortcut.WorkingDirectory := sourcePath
            else
                shortcut.WorkingDirectory := GetParentPath(sourcePath)
            shortcut.Description := "由 PopDrop 创建"
            shortcut.Save()
            if !FileExist(tempPath)
                throw Error("Windows Shell 未生成快捷方式文件。")
            verified := shell.CreateShortcut(tempPath)
            if !PathsEqual(verified.TargetPath, sourcePath)
                throw Error("快捷方式目标校验失败。")
            Loop 20 {
                finalPath := UniqueLauncherShortcutPath(targetPath, baseName)
                if DllCall("kernel32\MoveFileExW", "wstr", tempPath,
                    "wstr", finalPath, "uint", 0, "int")
                    break
                finalPath := ""
            }
            if finalPath = ""
                throw Error("无法以唯一名称保存快捷方式。")
            success += 1
            resultPaths.Push(finalPath)
        } catch as err {
            failed += 1
            details.Push(sourcePath "：" err.Message)
        } finally {
            if FileExist(tempPath)
                try FileDelete(tempPath)
        }
    }
    return {Success: success, Failed: failed,
        Details: details, ResultPaths: resultPaths}
}

LauncherShortcutBaseName(sourcePath) {
    name := GetFileName(sourcePath)
    if !DirExist(sourcePath) {
        SplitPath(name, &nameWithoutExtension)
        if nameWithoutExtension != ""
            name := nameWithoutExtension
    }
    return SanitizeShortcutBaseName(name)
}

SanitizeShortcutBaseName(name) {
    name := RegExReplace(name, "[<>:`"/\\|?*\x00-\x1F]", "_")
    name := RTrim(Trim(name), ". ")
    if name = ""
        name := "快捷方式"
    if RegExMatch(name, "i)^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)")
        name .= "_"
    return RTrim(SubStr(name, 1, 120), ". ")
}

UniqueLauncherShortcutPath(targetPath, baseName) {
    baseName := SanitizeShortcutBaseName(baseName)
    candidate := targetPath "\" baseName ".lnk"
    suffix := 2
    while FileExist(candidate)
        candidate := targetPath "\" baseName " (" suffix++ ").lnk"
    return candidate
}

MakeUniqueShortcutFileName(baseName, existingNames) {
    baseName := SanitizeShortcutBaseName(baseName)
    candidate := baseName ".lnk"
    suffix := 2
    while existingNames.Has(StrLower(candidate))
        candidate := baseName " (" suffix++ ").lnk"
    return candidate
}

BeginShellDrag(paths, ownerHwnd, itemContexts := 0) {
    global ActiveInternalDragContext
    BeginAutoHidePause()

    try {
        ActiveInternalDragContext := {
            Token: A_TickCount "-" DllCall("kernel32\GetCurrentProcessId", "uint"),
            Items: IsObject(itemContexts) ? itemContexts : [],
            Paths: paths.Clone()
        }
        if paths.Length = 1
            BeginSingleShellDrag(paths[1], ownerHwnd)
        else
            BeginMultiShellDrag(paths, ownerHwnd)
    } finally {
        ActiveInternalDragContext := 0
        try {
            ; Completing an outbound drop can transfer focus to the target
            ; application. In temporary mode the user may still want another
            ; item, so restore PopDrop before resuming automatic hiding. The
            ; next explicit click or Alt+Tab away will hide it normally.
            KeepTemporaryPanelVisibleAfterDrag()
        } finally {
            EndAutoHidePause()
        }
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

RunSelfTests() {
    global NO_EXTENSION_TOKEN
    global MODE_FILES, MODE_LAUNCHER, SCOPE_FILES_ONLY, SORT_NAME_ASC
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, SOURCE_OPEN_MODE_INHERIT
    global DROP_ADAPTER_HDROP, DROP_ADAPTER_VIRTUAL, DROP_ADAPTER_PNG
    global DROP_ADAPTER_URL, DROP_ADAPTER_UNSUPPORTED
    global APP_VERSION
    try {
        RunConfigDocumentSelfTests()
        RunNoiseFilterSelfTests()
        AssertSelfTest(ParseGlobalOpenFileMode("") = OPEN_MODE_DOUBLE,
            "缺失全局打开方式回退为双击")
        AssertSelfTest(ParseGlobalOpenFileMode("broken") = OPEN_MODE_DOUBLE,
            "损坏全局打开方式回退为双击")
        AssertSelfTest(ParseGlobalOpenFileMode("singleclick") = OPEN_MODE_SINGLE,
            "全局单击方式大小写不敏感")
        AssertSelfTest(ParseSourceOpenFileMode("") = SOURCE_OPEN_MODE_INHERIT,
            "缺失来源打开方式继承全局")
        AssertSelfTest(ParseSourceOpenFileMode("unknown")
            = SOURCE_OPEN_MODE_INHERIT,
            "损坏来源打开方式继承全局")
        extensions := NormalizeOpenAppExtensions("PDF, .pdf, txt, <none>, none")
        AssertSelfTest(extensions.Length = 3, "扩展名去重")
        AssertSelfTest(extensions[1] = ".pdf", "扩展名小写及点号")
        AssertSelfTest(extensions[3] = NO_EXTENSION_TOKEN, "无扩展名类型")
        AssertSelfTest(GetFileExtensionType("C:\a\README") = NO_EXTENSION_TOKEN,
            "无扩展名识别")
        AssertSelfTest(GetFileExtensionType("C:\a\archive.tar.gz") = ".gz",
            "只取最后扩展名")
        AssertSelfTest(IsExecutablePath("C:\Program Files\7-Zip\7z.exe"),
            "EXE 扩展名识别")
        AssertSelfTest(IsExecutablePath("C:\Tools\APP.EXE"),
            "EXE 扩展名大小写不敏感")
        AssertSelfTest(!IsExecutablePath("C:\Tools\script.cmd"),
            "拒绝脚本型程序")
        appIds := ParseOpenAppOrder("7z, everedit,7Z, guoheview")
        AssertSelfTest(appIds.Length = 3 && appIds[1] = "7z"
            && appIds[3] = "guoheview", "软件顺序解析及 ID 去重")
        AssertSelfTest(OpenAppIdBase(
            "C:\Program Files\7-Zip\7zG.exe") = "7zg",
            "从 EXE 文件名生成可读软件 ID")
        AssertSelfTest(OpenAppIdBase(
            "C:\Tools\My App!.exe") = "my-app",
            "可读软件 ID 字符规范化")
        AssertSelfTest(IsGuidOpenAppId(
            "16e792f3-dc35-422a-b61f-4fb325a2616b"),
            "识别旧版 UUID 软件 ID")
        AssertSelfTest(PathsEqual('"C:/Temp/Folder/"', "c:\temp\folder"),
            "Windows 路径规范比较")
        AssertSelfTest(IsSameOrDescendantPath(
            "C:\Temp\Folder\Child", "c:\temp\folder"),
            "后代路径识别")
        AssertSelfTest(IsSameOrDescendantPath(
            "C:\Temp\Folder", "c:\temp\folder"),
            "文件夹到自身目标识别")
        AssertSelfTest(!IsSameOrDescendantPath(
            "C:\Temp\Folder2", "c:\temp\folder"),
            "路径边界识别")
        dropFilesTarget := {
            Type: "Files", SourceId: "source-target", Name: "目标",
            Path: "C:\Target", Available: true, Reason: "", GroupId: 2}
        dropLauncherTarget := {
            Type: "Launcher", SourceId: "source-tools", Name: "工具",
            Path: "C:\Tools", Available: true, Reason: "", GroupId: 3}
        dropPinnedTarget := {
            Type: "Pinned", SourceId: "", Name: "固定项",
            Path: "", Available: true, Reason: "", GroupId: 1}
        AssertSelfTest(ClassifyDropSource(
            [{Area: "Source"}], true) = "Source"
            && ClassifyDropSource([{Area: "Pinned"}], true) = "Pinned"
            && ClassifyDropSource([{Area: "Recent"}], true) = "Recent"
            && ClassifyDropSource([
                {Area: "Source"}, {Area: "Pinned"}], true) = "Mixed"
            && ClassifyDropSource([], false) = "External",
            "内部与外部来源上下文分类")
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0, 3, "Source") = 2,
            "内部普通来源默认移动")
        for safeKind in ["Pinned", "Recent", "External", "Mixed"] {
            AssertSelfTest(ResolveDropEffect(
                dropFilesTarget, 0, 3, safeKind) = 1,
                safeKind " 默认安全复制")
        }
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0x0008, 3, "Source") = 1,
            "Ctrl 请求复制")
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0x0004, 3, "External") = 2,
            "Shift 请求移动")
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0x0004, 1, "External") = 1,
            "不允许移动时安全回退复制")
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0x0008, 2, "Source") = 0,
            "不允许复制时不能危险回退移动")
        AssertSelfTest(ResolveDropEffect(
            dropLauncherTarget, 0x0004, 3, "Source") = 1,
            "Launcher 始终使用复制效果")
        AssertSelfTest(ResolveDropEffect(
            dropPinnedTarget, 0x0004, 3, "Source") = 1,
            "固定项语义不受 Shift 改变")
        AssertSelfTest(HDropShouldUseDirectAsyncTakeover(
            "External", dropFilesTarget, {Supported: true}),
            "外部异步 HDROP 不依赖 URL 直接接管")
        AssertSelfTest(!HDropShouldUseDirectAsyncTakeover(
            "External", dropFilesTarget, {Supported: false}),
            "同步外部 HDROP 保留本地路径链路")
        AssertSelfTest(!HDropShouldUseDirectAsyncTakeover(
            "Source", dropFilesTarget, {Supported: true}),
            "PopDrop 内部 HDROP 不交给外部 helper")
        AssertSelfTest(ShouldContinuePinnedReorder(dropPinnedTarget),
            "固定项原生分组内保持排序手势")
        AssertSelfTest(!ShouldContinuePinnedReorder({
            Type: "Pinned", Available: true, GroupId: 0}),
            "固定项工具栏按钮不进入内部排序")
        AssertSelfTest(!ShouldContinuePinnedReorder(dropFilesTarget),
            "固定项进入 Files 分组时切换为 OLE 拖放")
        AssertSelfTest(DropItemMatchesTargetSource({
            Area: "Source", SourceId: "source-target",
            SourcePath: "C:\Target"}, "c:\target", "source-other"),
            "同一来源路径识别为无操作")
        AssertSelfTest(DropItemMatchesTargetSource({
            Area: "Source", SourceId: "source-a",
            SourcePath: "C:\Shared"}, "c:\shared", "source-b"),
            "不同来源名称指向同一真实路径仍为无操作")
        AssertSelfTest(!DropItemMatchesTargetSource({
            Area: "Pinned"}, "C:\Target", "source-target"),
            "固定项拖到 Files 不误判为同来源")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Files", SourceId: "s1", Name: "项目",
            Path: "C:\Project", GroupId: 4}, true, true)
        AssertSelfTest(descriptor.Type = "Files" && descriptor.Available
            && descriptor.SourceId = "s1", "Files 目标纯数据解析")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Launcher", SourceId: "s2", Name: "工具",
            Path: "C:\Tools", GroupId: 5}, true, true)
        AssertSelfTest(descriptor.Type = "Launcher" && descriptor.Available,
            "Launcher 目标纯数据解析")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Pinned", Name: "固定项", GroupId: 1})
        AssertSelfTest(descriptor.Type = "Pinned" && descriptor.Available,
            "Pinned 目标纯数据解析")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Files", SourceId: "s3", Name: "离线",
            Path: "C:\Offline", GroupId: 6}, false, false)
        AssertSelfTest(!descriptor.Available && descriptor.Reason != "",
            "不可用来源解析为 Invalid 效果")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Invalid", Name: "状态栏", GroupId: 0})
        AssertSelfTest(descriptor.Type = "Invalid" && !descriptor.Available,
            "Invalid 目标纯数据解析")
        AssertSelfTest(ResolveDropEffect(descriptor, 0, 3, "External") = 0,
            "Invalid 目标返回 DROPEFFECT_NONE")
        badFormat := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
        FillHDropFormat(badFormat.Ptr)
        NumPut("ushort", 13, badFormat, 0)
        AssertSelfTest(!IsHDropFormat(badFormat.Ptr),
            "不支持的数据格式返回 DROPEFFECT_NONE 的前置判断")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "HDrop", true, "Url", true)).Adapter = DROP_ADAPTER_HDROP,
            "格式分类：本地文件优先于 URL")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "FileDescriptor", true, "FileContents", true,
            "Png", true, "Url", true)).Adapter = DROP_ADAPTER_VIRTUAL,
            "格式分类：虚拟文件优先于图片和 URL")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "Png", true, "Url", true)).Adapter = DROP_ADAPTER_PNG,
            "格式分类：图片优先于 URL")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "Url", true)).Adapter = DROP_ADAPTER_URL,
            "格式分类：明确 URL 最后兜底")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "UnicodeText", true)).Adapter = DROP_ADAPTER_UNSUPPORTED,
            "任意 Unicode 文本不会被误判为 URL")
        AssertSelfTest(IsDuplicatePinnedCandidate(
            ["C:\A.txt"], [], "c:\a.txt"),
            "重复固定项按规范路径跳过")
        names := Map("tool.lnk", true, "tool (2).lnk", true)
        AssertSelfTest(MakeUniqueShortcutFileName("tool", names)
            = "tool (3).lnk", "Launcher 快捷方式唯一名称")
        AssertSelfTest(SanitizeShortcutBaseName("CON") = "CON_"
            && SanitizeShortcutBaseName("bad:name. ") = "bad_name",
            "Launcher 快捷方式名称清理")
        session := CreateDropSessionState()
        session.Paused := true
        MarkDropSessionFinished(session, "success")
        AssertSelfTest(session.Completed && !session.Paused
            && session.Outcome = "success", "拖拽成功状态清理")
        for outcome in ["failure", "cancel", "leave"] {
            state := CreateDropSessionState()
            state.Paused := true
            MarkDropSessionFinished(state, outcome)
            AssertSelfTest(state.Completed && !state.Paused,
                "拖拽" outcome "状态清理")
        }
        AssertSelfTest(ShouldSkipScannedFolder(
            "C:\Work\.git", ".git", [".git"], [], []),
            "全局排除名称进入扫描判断")
        AssertSelfTest(!ShouldSkipScannedFolder(
            "C:\Work\.git", ".git", [".git"], [],
            ["C:\Work\.git"]),
            "来源允许路径覆盖全局排除")
        AssertSelfTest(ShouldSkipScannedFolder(
            "C:\Work\build\bin", "bin", [],
            ["C:\Work\build"], []),
            "来源排除路径覆盖其后代")
        launcherSource := {
            Mode: MODE_FILES, IncludeSubfolders: true,
            DisplayScope: "RecursiveFiles", SortMode: "ModifiedDesc",
            Filter: {Mode: "All", Extensions: []},
            StripOrderPrefix: 0, HideExtensions: 0
        }
        ApplyLauncherSourceDefaults(launcherSource)
        AssertSelfTest(!launcherSource.IncludeSubfolders
            && launcherSource.DisplayScope = SCOPE_FILES_ONLY
            && launcherSource.SortMode = SORT_NAME_ASC
            && launcherSource.Filter.Mode = "Include"
            && JoinArray(launcherSource.Filter.Extensions, ",") = ".lnk,.url,.exe"
            && launcherSource.StripOrderPrefix
            && launcherSource.HideExtensions,
            "Launcher 文件夹类型应用完整默认特性")
        FileAppend("PopDrop v" APP_VERSION " self-test: PASS`n", "*")
    } catch as err {
        FileAppend("PopDrop v" APP_VERSION
            " self-test: FAIL - " err.Message "`n", "*")
        ExitApp(1)
    }
}

RunNoiseFilterSelfTests() {
    global GlobalNoiseFilter
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    global SCOPE_FILES_ONLY, SORT_NAME_ASC, FOLDER_TIME_MODIFIED
    compiled := CompileIgnorePatterns(["*.myapp-lock", "__temp__?",
        "*.MYAPP-LOCK", "file[1].*", ""], "self-test")
    AssertSelfTest(compiled.Texts.Length = 3, "忽略规则去空行和去重")
    AssertSelfTest(MatchesCompiledIgnorePattern("STATE.MYAPP-LOCK", compiled.Patterns),
        "星号规则大小写不敏感")
    AssertSelfTest(MatchesCompiledIgnorePattern("__temp__中", compiled.Patterns)
        && !MatchesCompiledIgnorePattern("__temp__两个", compiled.Patterns),
        "问号规则匹配一个 Unicode 字符")
    AssertSelfTest(MatchesCompiledIgnorePattern("file[1].txt", compiled.Patterns),
        "正则特殊字符先转义")
    AssertSelfTest(HasDangerousIgnorePattern(["*"])
        && HasDangerousIgnorePattern(["*.*"]), "过宽规则警告")

    noise := {Enabled: true, HideHidden: true, HideSystem: true,
        HideTemporary: false, HideIncompleteDownloads: false,
        CustomPatterns: [], SourceCustomPatterns: []}
    names := Map()
    for name in ["客户.accdb", "客户.laccdb", "孤立.laccdb",
        "旧库.mdb", "旧库.ldb", "设计图.dwg", "设计图.dwl",
        "设计图.dwl2", "孤立.dwl"]
        names[StrLower(name)] := true
    AssertSelfTest(!ShouldIncludeEntry("C:\x\~$报告.docx", "~$报告.docx",
        "A", noise, names).Include, "Office/WPS 锁定文件隐藏")
    AssertSelfTest(ShouldIncludeEntry("C:\x\~说明.txt", "~说明.txt",
        "A", noise, names).Include, "普通波浪号文件显示")
    AssertSelfTest(!ShouldIncludeEntry("C:\x\.~lock.报告.odt#",
        ".~lock.报告.odt#", "A", noise, names).Include,
        "LibreOffice 锁定文件隐藏")
    for metadata in ["desktop.ini", "Thumbs.db", "ehthumbs.db", ".DS_Store"]
        AssertSelfTest(!ShouldIncludeEntry("C:\x\" metadata, metadata,
            "A", noise, names).Include, "目录元数据隐藏：" metadata)
    AssertSelfTest(!ShouldIncludeEntry("C:\x\客户.laccdb", "客户.laccdb",
        "A", noise, names).Include, "Access 关联文件隐藏")
    AssertSelfTest(ShouldIncludeEntry("C:\x\孤立.laccdb", "孤立.laccdb",
        "A", noise, names).Include, "孤立 Access 文件显示")
    AssertSelfTest(!ShouldIncludeEntry("C:\x\旧库.ldb", "旧库.ldb",
        "A", noise, names).Include, "MDB 关联 LDB 隐藏")
    AssertSelfTest(!ShouldIncludeEntry("C:\x\设计图.dwl2", "设计图.dwl2",
        "A", noise, names).Include, "AutoCAD 关联文件隐藏")
    AssertSelfTest(ShouldIncludeEntry("C:\x\孤立.dwl", "孤立.dwl",
        "A", noise, names).Include, "孤立 AutoCAD 文件显示")
    for recovery in ["设计图.bak", "设计图.sv$", "设计图.ac$", "任意.tmp"]
        AssertSelfTest(ShouldIncludeEntry("C:\x\" recovery, recovery,
            "A", noise, names).Include, "恢复文件默认显示：" recovery)
    AssertSelfTest(!ShouldIncludeEntry("C:\x\隐藏.txt", "隐藏.txt",
        "HA", noise, names).Include, "Hidden 属性过滤")
    AssertSelfTest(!ShouldIncludeEntry("C:\x\系统.txt", "系统.txt",
        "SA", noise, names).Include, "System 属性过滤")
    AssertSelfTest(ShouldIncludeEntry("C:\x\临时.txt", "临时.txt",
        "TA", noise, names).Include, "Temporary 属性默认显示")
    AssertSelfTest(ShouldIncludeEntry("C:\x\属性未知.txt", "属性未知.txt",
        "", noise, names).Include, "属性失败时显示")
    for download in ["a.crdownload", "a.part", "a.download"]
        AssertSelfTest(ShouldIncludeEntry("C:\x\" download, download,
            "A", noise, names).Include, "未完成下载默认显示")
    pinned := BuildPathSet(["C:\x\~$固定.docx"])
    AssertSelfTest(ShouldIncludeEntry("C:\x\~$固定.docx", "~$固定.docx",
        "HS", noise, names, pinned).Include, "固定项目优先")

    GlobalNoiseFilter := {Enabled: true, HideHidden: true, HideSystem: true,
        HideTemporary: false, HideIncompleteDownloads: false,
        CustomPatterns: [], CustomPatternTexts: [], PatternErrors: []}
    AssertSelfTest(ResolveNoiseFilterForSource(NOISE_FILTER_INHERIT, []).Enabled,
        "全局开启加来源继承")
    GlobalNoiseFilter.Enabled := false
    AssertSelfTest(ResolveNoiseFilterForSource(NOISE_FILTER_ENABLED, []).Enabled,
        "全局关闭加来源启用")
    GlobalNoiseFilter.Enabled := true
    AssertSelfTest(!ResolveNoiseFilterForSource(NOISE_FILTER_DISABLED, []).Enabled,
        "全局开启加来源禁用")

    testDir := A_Temp "\PopDrop-noise-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint") . "-" A_TickCount
    try {
        DirCreate(testDir)
        for fileName in ["~$报告.docx", "报告.docx", ".~lock.报告.odt#",
            "desktop.ini", "Thumbs.db", ".DS_Store", "客户.accdb",
            "客户.laccdb", "孤立.laccdb", "设计图.dwg", "设计图.dwl",
            "设计图.dwl2", "孤立.dwl", "设计图.bak", "设计图.sv$"]
            FileAppend("test", testDir "\" fileName, "UTF-8")
        childDir := testDir "\子目录"
        DirCreate(childDir)
        normalPath := childDir "\正常.txt"
        noisePath := childDir "\~$较新.docx"
        FileAppend("normal", normalPath, "UTF-8")
        FileAppend("noise", noisePath, "UTF-8")
        FileSetTime("20240101000000", normalPath, "M")
        FileSetTime("20250101000000", noisePath, "M")
        latestDiag := {Count: 0, Items: [], Seen: Map()}
        latest := GetLatestDescendantFileTime(childDir,
            {Mode: "All", Extensions: []}, [], [], [], noise, Map(),
            "中文测试来源", latestDiag)
        AssertSelfTest(latest = FileGetTime(normalPath, "M"),
            "隐藏文件不参与文件夹最新内容时间")
        diagnostics := {Count: 0, Items: [], Seen: Map()}
        files := GetSortedItems(testDir, 0, SCOPE_FILES_ONLY, SORT_NAME_ASC,
            {Mode: "All", Extensions: []}, FOLDER_TIME_MODIFIED,
            [], [], [], noise, Map(), "中文测试来源", diagnostics)
        for hiddenName in ["~$报告.docx", ".~lock.报告.odt#", "desktop.ini",
            "Thumbs.db", ".DS_Store", "客户.laccdb", "设计图.dwl", "设计图.dwl2"]
            AssertSelfTest(!ScanResultHasName(files, hiddenName), "扫描隐藏：" hiddenName)
        for visibleName in ["报告.docx", "孤立.laccdb", "孤立.dwl",
            "设计图.bak", "设计图.sv$"]
            AssertSelfTest(ScanResultHasName(files, visibleName), "扫描保留：" visibleName)
        AssertSelfTest(diagnostics.Count = 8, "隐藏诊断计数")
    } finally {
        try DirDelete(testDir, true)
    }
}

ScanResultHasName(files, targetName) {
    for file in files {
        if StrLower(file.Name) = StrLower(targetName)
            return true
    }
    return false
}

RunConfigDocumentSelfTests() {
    testPath := A_Temp "\PopDrop-config-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount ".ini"
    try FileDelete(testPath)
    testConfig :=
    (
    "; <PopDrop:area 1>`n"
    "[General]`n"
    "ConfigVersion=11`n"
    "; 人工注释必须保留`n"
    "CustomValue=a=b`n"
    "; <PopDrop:area 2>`n"
    "; [Folder:这里只是注释示例]`n"
    "; <PopDrop:area 3>`n"
    "[Sources]`n"
    "Order=`n"
    "; <PopDrop:area 4>`n"
    "[OpenApps]`n"
    "Order=`n"
    "; <PopDrop:area 5>`n"
    "[TransferFavorites]`n"
    "; <PopDrop:area 6>`n"
    "[ExcludedFolderNames]`n"
    "Name001=.git`n"
    "[PinnedFiles]`n"
    "File001=旧值`n"
    )
    FileAppend(testConfig, testPath, "UTF-16")
    try {
        doc := OpenPopDropConfig(testPath)
        AssertSelfTest(doc.Dirty, "错位配置节应触发布局修复")
        doc.ReplaceSection("PinnedFiles", [
            {Key: "File001", Value: "C:\Temp\$1=a.txt"},
            {Key: "File002", Value: "D:\中文\文件.txt"}
        ], 2)
        doc.SetValue("NoiseFilter", "Enabled", "1", 1)
        doc.SetValue("NoiseFilter", "UnknownNoiseOption", "保留", 1)
        EnsureNoiseFilterConfigComments(doc)
        doc.ReplaceSection("SourceIgnore:test", [
            {Key: "PatternCount", Value: "1"},
            {Key: "Pattern001", Value: "*.lock-marker"}
        ], 6)
        doc.Save()

        raw := FileRead(testPath, "RAW")
        AssertSelfTest(NumGet(raw, 0, "UShort") = 0xFEFF
            && NumGet(raw, 2, "UShort") != 0xFEFF,
            "UTF-16LE 只能有一个 BOM")
        text := FileRead(testPath, "UTF-16")
        AssertSelfTest(InStr(text, "; 人工注释必须保留"),
            "保留人工注释")
        AssertSelfTest(InStr(text, "; [Folder:这里只是注释示例]"),
            "注释节头不能被当成真实配置节")
        AssertSelfTest(InStr(text, "File001=C:\Temp\$1=a.txt"),
            "配置值中的美元符号和等号必须原样保留")
        AssertSelfTest(InStr(text, "`r`n") && !RegExMatch(text, "(?<!\r)\n"),
            "写回统一使用 CRLF")
        area2 := InStr(text, "; <PopDrop:area 2>")
        pinned := InStr(text, "[PinnedFiles]")
        area3 := InStr(text, "; <PopDrop:area 3>")
        AssertSelfTest(area2 < pinned && pinned < area3,
            "错位节必须回到指定区域")
        area1 := InStr(text, "; <PopDrop:area 1>")
        noiseSection := InStr(text, "[NoiseFilter]")
        AssertSelfTest(area1 < noiseSection && noiseSection < area2,
            "NoiseFilter 配置节位于全局区域")
        area6 := InStr(text, "; <PopDrop:area 6>")
        sourceIgnore := InStr(text, "[SourceIgnore:test]")
        AssertSelfTest(area6 < sourceIgnore,
            "来源附加规则配置节位于扫描规则区域")
        AssertSelfTest(InStr(text, "UnknownNoiseOption=保留"),
            "噪音过滤节未知配置项保留")
        AssertSelfTest(InStr(text, "; HideHidden：是否排除具有 Hidden 属性的文件。")
            && InStr(text, "; CustomPatternCount：下方 CustomPatternNNN"),
            "噪音过滤配置项说明写入且可诊断")
    } finally {
        try FileDelete(testPath)
    }
}

AssertSelfTest(condition, name) {
    if !condition
        throw Error("测试失败：" name)
}

Cleanup(*) {
    global DropCallbacks, DataCallbacks, ThumbnailImageList, MainInstanceMutex
    global WorkerRunning, WorkerPid, WorkerRequestPath, WorkerReadyPath, PanelIconHandle
    global FileOperationSinkCallbacks, DropTargetCallbacks
    SetTimer(PollWorkerResult, 0)
    CleanupExternalTransfers()
    if WorkerRunning && WorkerPid && ProcessExist(WorkerPid)
        try ProcessClose(WorkerPid)
    try FileDelete(WorkerRequestPath)
    try FileDelete(WorkerReadyPath)
    try FileDelete(WorkerReadyPath ".writing")
    ResetActiveDropSession(false)
    RevokePanelDropTargets()
    for callbackPtr in DropCallbacks
        CallbackFree(callbackPtr)
    for callbackPtr in DataCallbacks
        CallbackFree(callbackPtr)
    for callbackPtr in FileOperationSinkCallbacks
        CallbackFree(callbackPtr)
    for callbackPtr in DropTargetCallbacks
        CallbackFree(callbackPtr)
    if ThumbnailImageList
        DllCall("comctl32\ImageList_Destroy", "ptr", ThumbnailImageList)
    if PanelIconHandle
        DllCall("user32\DestroyIcon", "ptr", PanelIconHandle)
    if MainInstanceMutex
        DllCall("kernel32\CloseHandle", "ptr", MainInstanceMutex)
    DllCall("ole32\OleUninitialize")
}
