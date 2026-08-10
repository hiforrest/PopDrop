#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off

;@Ahk2Exe-SetMainIcon assets\app.ico
;@Ahk2Exe-AddResource assets\tray.ico, 555
;@Ahk2Exe-AddResource assets\icon-lnk.ico, 556
;@Ahk2Exe-AddResource assets\pin.ico, 557
;@Ahk2Exe-AddResource assets\empty-folder.ico, 558
;@Ahk2Exe-AddResource assets\unknown-file.ico, 559
;@Ahk2Exe-SetVersion 1.1.2.0
;@Ahk2Exe-SetName PopDrop

; Worker processes must be routed before any GUI, hotkey, tray or COM setup.
;
; IMPORTANT: All constants that worker functions depend on must be defined
; before this block, because the worker calls ExitApp right after routing.

; ──── 排序模式常量 ────
global SORT_MODIFIED_DESC := "ModifiedDesc"
global SORT_NAME_ASC := "NameAsc"
global SORT_SMART := "Smart"
global APP_VERSION := "1.1.2"
global CONFIG_VERSION := "29"
global CONTENT_UPDATE_FAST := "Fast"
global CONTENT_UPDATE_ACCURACY := "Accuracy"
global UI_SCALE_100 := "100"
global UI_SCALE_125 := "125"
global UI_SCALE_150 := "150"
global UI_SCALE_175 := "175"
global UI_SCALE_200 := "200"
; Available in --self-test mode as well as the main UI. A config transaction
; must never be re-entered by another AutoHotkey thread while its baseline is
; being compared and atomically replaced.
global ConfigEditInProgress := false
global ConfigEditSerial := 0
global LoadedConfigStamp := ""

; ──── 工作区类型 ────
global WORKSPACE_TYPE_FILES := "Files"
global WORKSPACE_TYPE_TEXT := "Text"

; ──── 文件管理器适配器 ────
global FILE_MANAGER_WINDOWS_SHELL := "WindowsShell"
global FILE_MANAGER_DIRECTORY_OPUS := "DirectoryOpus"
global FILE_MANAGER_TOTAL_COMMANDER := "TotalCommander"
global FILE_MANAGER_XYPLORER := "XYplorer"
global FILE_MANAGER_DOUBLE_COMMANDER := "DoubleCommander"
global FILE_MANAGER_FILES := "Files"
global FILE_MANAGER_FREE_COMMANDER := "FreeCommander"

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
global ACTION_TARGET_FILES := "Files"
global ACTION_TARGET_FOLDERS := "Folders"
global ACTION_TARGET_BOTH := "Both"
global ACTION_EXECUTION_PER_ITEM := "PerItem"
global ACTION_EXECUTION_BATCH := "Batch"
global ACTION_WORKDIR_FOLDER := "Folder"
global ACTION_WORKDIR_PROGRAM := "ProgramDirectory"
global ACTION_WORKDIR_CUSTOM := "Custom"
global ACTION_COMMAND_LINE_LIMIT := 32760

; ──── 文件激活模式 ────
global OPEN_MODE_DOUBLE := "DoubleClick"
global OPEN_MODE_SINGLE := "SingleClick"
global SOURCE_OPEN_MODE_INHERIT := "Inherit"

; ──── 默认右键菜单 ────
global CONTEXT_MENU_POPDROP := "PopDrop"
global CONTEXT_MENU_SYSTEM := "System"

; ──── 临时、锁定及系统文件过滤 ────
global NOISE_FILTER_INHERIT := "Inherit"
global NOISE_FILTER_ENABLED := "Enabled"
global NOISE_FILTER_DISABLED := "Disabled"
global NOISE_DIAGNOSTIC_LIMIT := 200

; External-drop adapter constants are needed by --self-test before the
; included integration module's top-level initialization would run.
global DROP_ADAPTER_HDROP := "HDrop"
global DROP_ADAPTER_VIRTUAL := "VirtualFiles"
global DROP_ADAPTER_PNG := "Png"
global DROP_ADAPTER_DIBV5 := "DibV5"
global DROP_ADAPTER_DIB := "Dib"
global DROP_ADAPTER_URL := "Url"
global DROP_ADAPTER_TEXT := "Text"
global DROP_ADAPTER_UNSUPPORTED := "Unsupported"

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

global DataRootDir := ResolvePopDropDataRoot()
global ConfigPath := DataRootDir "\config.ini"
global Panel := 0
global FileView := 0
; A visited workspace keeps its populated native ListView and row metadata.
; Switching back can therefore show the existing HWND instead of rebuilding
; every group, item and image like the original single-view implementation.
global WorkspaceFileViewStates := Map()
global RecentLabel := 0
global RecentView := 0
global DisplayButton := 0
global DisplayMenu := 0
global WindowModeButton := 0
global PinnedDropButton := 0
global ClipboardPinnedButton := 0
global RefreshButton := 0
global ExpandAllFoldersButton := 0
global CollapseAllFoldersButton := 0
global RemovePinnedButton := 0
global SettingsButton := 0
global ToolbarSeparators := []
global FolderDropAddSourceButton := 0
global FolderDropPinnedZone := 0
global FolderDropUiVisible := false
global FolderDropUiMode := ""
global PanelLayoutWidth := 766
global StatusText := 0
global ItemCountText := 0
global TransferStatusText := 0
global ItemPaths := Map()
global ItemLabels := Map()
global ItemKinds := Map()
global ItemOpenContexts := Map()
global PinnedLinkIconCache := Map()
global TextSourcePinIconCache := Map()
global RecentItemPaths := Map()
global PinnedPaths := []
global TextSourcePinnedPaths := Map()
global FolderSettings := []
global Workspaces := []
global ActiveWorkspaceId := ""
global ActiveWorkspaceName := ""
global WorkspaceTabs := 0
global WorkspaceTabIds := []
global WorkspaceMoreButton := 0
global WorkspaceMoreMenu := 0
global WorkspaceOverflowIds := []
global WORKSPACE_VISIBLE_TAB_LIMIT := 8
global ActiveWorkspaceType := WORKSPACE_TYPE_FILES
global SettingsController := 0
global MaxFilesPerFolder := 8
global IncludeSubfolders := false
global ThumbnailSize := 96
global ThumbnailHorizontalGap := 24
global ThumbnailVerticalGap := 4
global FileViewGroupTopSpacing := 4
global FileViewGroupBottomSpacing := 6
global FileViewGroupMetricBases := Map()
global ThumbnailTextLines := 2
global TextBlockCardWidth := 212
global TextBlockCardHeight := 68
global ThumbnailImageList := 0
global ThumbnailImageListEdge := 0
global ThumbnailIconCache := Map()
global WindowWidth := 766
global WindowHeight := 576
global ViewMode := "Thumbnail"
global ShowRecentSidebar := false
global ContentUpdateMode := CONTENT_UPDATE_FAST
global UiScaleMode := UI_SCALE_100
global UiScalePercent := 100
global UiScaleFactor := 1.0
; Frozen when the main panel is built. Settings continue to apply after a
; restart, so a newly saved scale cannot partially resize an existing panel.
global PanelUiScaleFactor := 1.0
global RecentFileCount := 12
; Native single-line control tuning. Buttons and edits use the full logical
; height. A DropDownList adds its own frame around the selection field, so its
; inner field must be shorter to produce the same outer height.
global UI_SINGLE_LINE_HEIGHT := 26
global UI_DROPDOWN_FIELD_HEIGHT := 22
global PANEL_TOOLBAR_HEIGHT := 42
global PANEL_FOOTER_HEIGHT := 42
; Navigation/rail metrics below are visible-pixel targets. The main panel is
; DPI-aware, so convert them back to Gui units before Add/Move.
global PANEL_TAB_HEIGHT_PX := 54
global PANEL_TAB_FONT_PX := 12
; Native Tab control default padding is approximately 6/3 on this layout.
; Add the requested +4 horizontal and +3 vertical without changing font size.
global PANEL_TAB_PADDING_X_PX := 22
; Legacy layout contract: PANEL_TAB_PADDING_Y_PX := 14. Owner-drawn text
; offsets now provide the vertical alignment, so the runtime value stays zero.
global PANEL_TAB_PADDING_Y_PX := 0 ;无效
global PANEL_TAB_BOTTOM_MARGIN_PX := 8 ; tab菜单距离底部的距离
global PANEL_TAB_TEXT_VERTICAL_EXTRA_PX := 3
global PANEL_TAB_TEXT_Y_OFFSET_PX := 4
global WorkspaceTabPaintSubclassCallback := 0
global PANEL_CONTENT_TOP_OFFSET_PX := 0
global PANEL_SIDE_BUTTON_SIZE := 64
global PANEL_SIDE_TOOLBAR_WIDTH := 64
global PANEL_SIDE_TOOLBAR_GAP := 2
global PANEL_SIDE_TOOLBAR_EDGE_GAP := 2
global PANEL_SIDE_BUTTON_GAP := 2
global PANEL_SIDE_SEPARATOR_GAP := 5
global PANEL_SIDE_SEPARATOR_HEIGHT := 1
global PanelIconButtons := Map()
global PanelIconSubclassCallback := 0
global PanelIconGdipToken := 0
global PanelIconHoverHwnd := 0
global PanelIconTooltipGeneration := 0
global PanelSeparatorControls := Map()
global PanelSeparatorSubclassCallback := 0
global PanelSolidRuleControls := Map()
global PanelSolidRuleSubclassCallback := 0
; Physical-pixel correction applied to every DropDownList after creation.
; Positive values move it down; negative values move it up.
global UI_DROPDOWN_Y_OFFSET_PX := 1
; Text-only physical-pixel corrections. These do not change any control's
; outer size or position. Positive values move text down.
global UI_EDIT_TEXT_Y_OFFSET_PX := 0
global UI_DROPDOWN_TEXT_Y_OFFSET_PX := 0
; Owner-drawn combo boxes keep a copy of their string items as a defensive
; fallback. Some Windows builds report itemID=-1 while painting the closed
; selection field, and native text retrieval can then return no text.
global UiDropDownTextItems := Map()
global UiDropDownScaleFactors := Map()
global UiDropDownParentSubclassCallback := 0
global UiDropDownSubclassedParents := Map()
global ConfiguredHotkey := "F2"
global ActiveHotkey := ""
global ActiveHotkeyRelease := ""
global ActiveWorkspaceHotkeys := Map()
global WorkspaceHotkeyPressed := Map()
global WorkspaceHotkeyLastDispatch := Map()
global PendingPanelWorkspaceId := ""
global PendingPanelWorkspaceOrigin := ""
global PanelWorkspaceSwitchGeneration := 0
global PanelWorkspaceSwitchRunning := false
; Delayed workspace maintenance is generation-gated so a callback queued for
; an older tab cannot touch the newly active workspace.
global WorkspaceActivationMaintenanceGeneration := 0
global WorkspaceActivationMaintenanceWorkspaceId := ""
; Workspace activation is committed to config after the new view has painted.
; Repeated switches share one timer so only the final target reaches disk.
global PendingActiveWorkspacePersistId := ""
global PendingLastFileWorkspacePersistId := ""
global ActiveWorkspacePersistAttempts := 0
global ACTIVE_WORKSPACE_PERSIST_DELAY_MS := 250
global DoubleHotkeyWorkspaceId := ""
global LastFileWorkspaceId := ""
; The main shortcut is parsed as a gesture independently from panel state.
; Keeping input collection separate from UI work prevents a fast second press
; from being dropped while the first press is loading a workspace.
global MainHotkeyFirstPressTick := 0
global MainHotkeyGestureGeneration := 0
global MainHotkeyGestureArmed := false
global MainHotkeySecondPressPending := false
global MainHotkeyRequestedAction := ""
global MainHotkeyActionRunning := false
global MainHotkeyAwaitRelease := false
global MainHotkeyPhysicalKey := ""
global MainHotkeyClosedTick := 0
global PanelShowFinishGeneration := 0
global CudaTextSystemCursorOverridden := false
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
global TextSourceReorderActive := false
global TextSourceReorderPath := ""
global TextSourceReorderSourceId := ""
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
global DropLeaveGeneration := 0
; Incoming OLE drag/drop has a short gap after the mouse button is released
; but before IDropTarget::Drop finishes.  Keep this state separate from the
; generic auto-hide pause counter so native and AHK guards can distinguish a
; real transfer from stale UI bookkeeping.
global IncomingDropGestureActive := false
global IncomingDropCommitActive := false
global IncomingDropLastEventTick := 0
global GroupDropTargets := Map()
global DropFolderValidationCache := Map()
global ActiveDropHighlightedGroup := 0
global ConfigErrors := []
global LastValidFolderSettings := []
global LastValidWorkspaceId := ""
global ConfigErrorsShown := false
global ThumbnailPolicy := "Full"
global CachePathSetting := ""
global CacheDir := ""
global CacheFilePath := ""
global CacheWritable := false
global CacheWriteWarningShown := false
global ScanCacheWritePending := false
global CacheMaintenanceDirectory := ""
global CacheMaintenanceStateLoaded := false
global CacheMaintenanceCompletedDate := ""
global CacheMaintenanceOpportunityDate := ""
global CacheMaintenanceTimer := 0
global CacheMaintenanceGeneration := 0
global CacheMaintenanceRunning := false
global CacheMaintenanceYieldRequested := false
global RuntimeIndexModule := 0
global RuntimeIndexDb := 0
global RuntimeIndexPath := ""
global RuntimeIndexAvailable := false
global CurrentConfigFingerprint := ""
global CurrentScanResult := {
    Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
global CurrentHiddenBySource := Map()
global ScanResultLoaded := false
; Loaded means some usable rows exist; Complete means every configured source
; belongs to one coherent snapshot. Keep these separate so a first partial
; worker result can never masquerade as a complete cache or hot view.
global CurrentScanComplete := false
global ScanContentRevisionSerial := 0
global CurrentScanRevision := 0
global WorkspaceScanSnapshots := Map()
global PanelRenderSignature := ""
global PanelRenderedWorkspaceId := ""
global PanelRenderedScanRevision := 0
global RecentRenderSignature := ""
global WorkerRunning := false
global WorkerFullScan := false
global WorkerPid := 0
global WorkerGeneration := ""
global WorkerWorkspaceId := ""
global WorkerFingerprint := ""
global WorkerStartedTick := 0
global WorkerRecoveryAttempts := 0
global WorkerRequestPath := ""
global WorkerReadyPath := ""
global PendingRefresh := false
global PendingFullRefresh := false
global PendingScanSourceKeys := Map()
global PendingIncludeRecent := false
global WorkerAppliedSourceIndexes := Map()
global WorkerSourceDirtyTokens := Map()
global WorkerRecentDirtyToken := 0
global WorkerRecentApplied := false
global WorkerChanged := false
global InactiveScanJob := 0
global InactiveScanQueue := Map()
global InactiveRecentPending := false
global InactiveScanGeneration := 0
global WorkerStatusToken := 0
global ScanGeneration := 0
global StatusKind := "default"
global StatusTimerToken := 0
global ConsistencyCheckMinutes := 60
global ProcessStartedAt := A_Now
global LastConsistencyBucket := 0
global ConsistencyCheckPending := false
global LastDailyCalibrationDate := ""
global StartupCalibrationPending := true
global WorkspaceCalibrationSeeded := false
global SourceWatchers := Map()
global SourceWatcherDefinitions := Map()
global SourceWatcherSignature := ""
global WorkspaceDirtySourceKeys := Map()
global WorkspaceUnmonitoredSourceKeys := Map()
global WorkspaceSourceHealth := Map()
global SourceWatcherRecentDirty := false
global SourceWatcherRecentGeneration := 0
global SourceWatcherRefreshPending := false
global SourceWatcherReopenDue := false
global ThumbnailEnhanceQueue := []
global ThumbnailEnhanceGeneration := 0
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
global OpenAppActionSerialTasks := Map()
global NextOpenAppActionSerialTaskId := 0
global GlobalOpenFileMode := OPEN_MODE_DOUBLE
global DefaultContextMenu := CONTEXT_MENU_POPDROP
global FileManagerProvider := FILE_MANAGER_WINDOWS_SHELL
global FileManagerExecutable := ""
global PendingContextMenuMouseShift := Map()
global PendingContextMenuKeyboardAlternate := Map()
global ContextMenuDispatchActive := false
global SourceMenuDispatchActive := false
global SourceRemovalDialog := 0
global SettingsDialog := 0
global EscapeHidesPanel := true
global TextBlockSearchEdit := 0
global TextBlockSearchQuery := ""
global TextBlockImeComposing := false
global TextBlockSelectFirstPending := true
global TextBlockSearchIndex := Map()
global TextBlockSearchQueue := []
global TextBlockSearchRefreshPending := false
global TextBlockUsage := Map()
global TextBlockReturnWindow := 0
global TextBlockReturnFocus := 0
global TextBlockSendInProgress := false
global CudaTextDragCapture := 0

#Include ConfigDocument.ahk
#Include FileManager.ahk
#Include SettingsGui.ahk
#Include ExternalDrop.ahk
#Include Preview.ahk
#Include QuickPreview.ahk

; ──── 单击激活手势和重复激活抑制 ────
global FilePointerGesture := 0
global FilePointerGestureSerial := 0
; A source group header owns its left-button gesture independently from file
; rows. This prevents a header press from entering native item selection or
; the single-click file activation state machine.
global FolderGroupHeaderGesture := 0
global LastPointerActivationKey := ""
global LastPointerActivationTick := 0

global SortMode := SORT_MODIFIED_DESC

; ──── 每个行对应的分组文件夹路径（双击分组标题使用） ────
global ItemFolderPaths := Map()
global GroupFolderPaths := Map()
; Session-scoped collapse state keyed by workspace and stable source ID.
; Native hot views keep their own visual state; this map reapplies it when a
; refresh rebuilds groups or a workspace view must be recreated.
global CollapsedFolderGroups := Map()

; ──── 窗口模式 ────
global WINDOW_MODE_ALWAYS_ON_TOP := "always_on_top"
global WINDOW_MODE_TEMPORARY     := "temporary"
global WINDOW_MODE_NORMAL        := "normal"

global WindowMode := WINDOW_MODE_ALWAYS_ON_TOP
global AutoHidePauseDepth := 0
global AutoHidePanelShownTick := 0
global AutoHideForegroundHook := 0
global AutoHideForegroundCallback := 0
global AUTO_HIDE_FOREGROUND_MESSAGE := 0x8031
global AutoHideNativeTimerId := 0
global AutoHideNativeTimerCallback := 0
global AutoHideNativePanelHwnd := 0
global AutoHideNativeTemporaryEnabled := false
global AutoHideNativeShownTick := 0
global AUTO_HIDE_NATIVE_HIDDEN_MESSAGE := 0x8032

EnsureConfig()
EnsureWorkspaceConfig()
LoadSettings()
InitTextBlocks()
OnMessage(0x002B, DrawUiDropDownItem) ; WM_DRAWITEM
OnMessage(0x002C, MeasureUiDropDownItem) ; WM_MEASUREITEM
BuildPanel()
OnMessage(0x0084, SmartDropOverlayHitTest) ; WM_NCHITTEST
OnClipboardChange(UpdateClipboardPinnedButton)
UpdateClipboardPinnedButton()
ApplyWindowIcon()
ApplyWindowMode()
InstallHotkey(ConfiguredHotkey)
InstallWorkspaceHotkeys()
BuildTrayMenu()
InitDropSource()
InitDropTarget()
InitFileOperationProgressSink()
InitExternalDrop()
InstallPanelHotkeys()
InitCudaTextIntegration()
OnMessage(0x004A, QuickPreviewCopyData) ; WM_COPYDATA (Seer)
OnMessage(0x0201, FileViewLeftButtonDown) ; WM_LBUTTONDOWN
OnMessage(0x0200, FileViewMouseMove)      ; WM_MOUSEMOVE
OnMessage(0x0202, FileViewLeftButtonUp)   ; WM_LBUTTONUP
OnMessage(0x0204, FileViewRightButtonDown) ; WM_RBUTTONDOWN
OnMessage(0x0100, FileViewContextMenuKeyDown) ; WM_KEYDOWN
OnMessage(0x0104, FileViewContextMenuKeyDown) ; WM_SYSKEYDOWN
OnMessage(0x0102, TextBlockCharInput)          ; WM_CHAR direct filtering
OnMessage(0x010D, TextBlockImeStart)           ; WM_IME_STARTCOMPOSITION
OnMessage(0x010E, TextBlockImeEnd)             ; WM_IME_ENDCOMPOSITION
OnMessage(0x020A, FileViewCancelInteraction) ; WM_MOUSEWHEEL
OnMessage(0x020E, FileViewCancelInteraction) ; WM_MOUSEHWHEEL
OnMessage(0x0114, FileViewCancelInteraction) ; WM_HSCROLL
OnMessage(0x0115, FileViewCancelInteraction) ; WM_VSCROLL
OnMessage(0x02A3, FileViewMouseLeave)        ; WM_MOUSELEAVE
OnMessage(0x001F, FileViewCancelMode)      ; WM_CANCELMODE
OnMessage(0x0215, FileViewCaptureChanged)  ; WM_CAPTURECHANGED
OnMessage(0x0008, FileViewKillFocus)       ; WM_KILLFOCUS
OnMessage(0x0006, PanelActivationChanged) ; WM_ACTIVATE
OnMessage(0x0218, PanelPowerBroadcast)    ; WM_POWERBROADCAST
InitAutoHideForegroundHook()
InitAutoHideNativeWatchdog()
OnMessage(0x0216, PanelMovingOrSizing)      ; WM_MOVING
OnMessage(0x0214, PanelMovingOrSizing)      ; WM_SIZING
OnMessage(0x0232, PanelExitMoveSize)        ; WM_EXITSIZEMOVE
OnMessage(0x004E, FileViewNotify)         ; WM_NOTIFY (group header click)

; Business implementation modules. #Include is textual, so the existing
; free-function callbacks and shared global state keep their original behavior.
#Include modules\PanelDialogs.ahk
#Include modules\Configuration.ahk
#Include modules\OpenApps.ahk
#Include modules\CoreUtilities.ahk
#Include modules\UiControls.ahk
#Include modules\TerminalTextSend.ahk
#Include modules\TextBlocks.ahk
#Include modules\CudaTextIntegration.ahk
#Include modules\PanelUi.ahk
#Include modules\SourceWatch.ahk
#Include modules\CacheMaintenance.ahk
#Include modules\RuntimeIndex.ahk
#Include modules\ScanCacheIntegrity.inc
#Include modules\ItemActions.ahk
#Include modules\ContextMenus.ahk
#Include modules\PointerInput.ahk
#Include modules\FileOperations.ahk
#Include modules\DropTarget.ahk
#Include modules\ShellDrag.ahk
#Include modules\SelfTests.ahk
#Include modules\Lifecycle.ahk
