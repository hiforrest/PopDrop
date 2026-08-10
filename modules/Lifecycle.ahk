; Process cleanup and native resource release.

Cleanup(*) {
    global DropCallbacks, DataCallbacks, ThumbnailImageList, MainInstanceMutex
    global WorkerRunning, WorkerPid, WorkerRequestPath, WorkerReadyPath, PanelIconHandle
    global FileOperationSinkCallbacks, DropTargetCallbacks
    global OpenAppActionSerialTasks
    global SourceRemovalDialog
    StopAutoHideWatchdog()
    CancelAutoHideCheck()
    SetTimer(WorkspaceHotkeyReleasePoll, 0)
    SetTimer(InstallWorkspaceHotkeysAfterRelease, 0)
    CleanupAutoHideNativeWatchdog()
    CleanupAutoHideForegroundHook()
    SetTimer(PollWorkerResult, 0)
    SetTimer(EnhanceNextThumbnail, 0)
    CancelCacheMaintenanceOpportunity()
    FlushPendingActiveWorkspacePersistence()
    FlushPendingScanCacheWrite()
    CleanupSourceWatchers()
    CancelInactiveWorkspaceScan(false)
    ShutdownRuntimeIndex()
    FinishCudaTextDragCapture(false)
    RestoreCudaTextNoDropCursor()
    CleanupQuickPreview()
    CleanupPreview()
    CleanupPinnedLinkIcons()
    CleanupTextSourcePinIcons()
    CleanupPanelIconButtons()
    CleanupPanelDashedSeparators()
    CleanupPanelSolidRules()
    CleanupWorkspaceTabItemPadding()
    for taskId, task in OpenAppActionSerialTasks {
        try SetTimer(task.PollCallback, 0)
        if task.ProcessHandle
            try DllCall("kernel32\CloseHandle", "ptr", task.ProcessHandle)
    }
    OpenAppActionSerialTasks.Clear()
    if IsObject(SourceRemovalDialog)
        try SourceRemovalDialog.Destroy()
    SourceRemovalDialog := 0
    CleanupExternalTransfers()
    if WorkerRunning && WorkerPid && ProcessExist(WorkerPid)
        try ProcessClose(WorkerPid)
    try FileDelete(WorkerRequestPath)
    if WorkerReadyPath != ""
        && RegExMatch(WorkerReadyPath, "i)\\ready-[0-9A-F-]+$")
        try DirDelete(WorkerReadyPath, true)
    ResetActiveDropSession(false)
    EndIncomingDropGesture(true)
    RevokePanelDropTargets()
    for callbackPtr in DropCallbacks
        CallbackFree(callbackPtr)
    for callbackPtr in DataCallbacks
        CallbackFree(callbackPtr)
    for callbackPtr in FileOperationSinkCallbacks
        CallbackFree(callbackPtr)
    for callbackPtr in DropTargetCallbacks
        CallbackFree(callbackPtr)
    CleanupWorkspaceFileViews()
    if PanelIconHandle
        DllCall("user32\DestroyIcon", "ptr", PanelIconHandle)
    if MainInstanceMutex
        DllCall("kernel32\CloseHandle", "ptr", MainInstanceMutex)
    DllCall("ole32\OleUninitialize")
}

CleanupWorkspaceFileViews() {
    global WorkspaceFileViewStates, ThumbnailImageList
    global FileViewGroupMetricBases
    imageLists := Map()
    if ThumbnailImageList
        imageLists[ThumbnailImageList] := true
    for _, state in WorkspaceFileViewStates {
        if state.ImageList
            imageLists[state.ImageList] := true
    }
    for imageList, _ in imageLists
        DllCall("comctl32\ImageList_Destroy", "ptr", imageList)
    WorkspaceFileViewStates.Clear()
    FileViewGroupMetricBases.Clear()
    ThumbnailImageList := 0
}
