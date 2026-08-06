; Asynchronous source change monitoring and conditional consistency checks.
;
; Directory handles are deliberately limited to local volumes. Opening an
; offline UNC or mapped drive on the UI thread can block for seconds; those
; sources are reconciled by the background worker instead.

SourceWatcherSettingsSignature() {
    global LastValidFolderSettings, ShowRecentSidebar
    raw := "recent=" (ShowRecentSidebar ? 1 : 0)
    for folder in LastValidFolderSettings {
        key := folder.SourceId != "" ? folder.SourceId
            : ResolveFolderSourceId(folder.Name, folder.Path)
        subtree := folder.DisplayScope != "FilesOnly"
            || folder.FolderTimeMode = "LatestContent"
        raw .= "|" key "|" StrLower(RTrim(folder.Path, "\"))
            . "|" (subtree ? 1 : 0)
    }
    return HashString(raw)
}

IsLocalWatchablePath(path) {
    path := NormalizePath(path)
    if path = "" || SubStr(path, 1, 2) = "\\"
        return false
    if !RegExMatch(path, "i)^[A-Z]:\\")
        return false
    driveRoot := SubStr(path, 1, 3)
    driveType := DllCall("kernel32\GetDriveTypeW", "wstr", driveRoot, "uint")
    ; DRIVE_REMOVABLE / DRIVE_FIXED / DRIVE_CDROM / DRIVE_RAMDISK. CD-ROM is
    ; immutable and does not need a watcher.
    return driveType = 2 || driveType = 3 || driveType = 6
}

ReconcileSourceWatchers(force := false) {
    global SourceWatcherSignature, SourceWatcherDefinitions, SourceWatchers
    global LastValidFolderSettings, ShowRecentSidebar, CacheDir
    signature := SourceWatcherSettingsSignature()
    if !force && signature = SourceWatcherSignature
        return
    CleanupSourceWatchers()
    SourceWatcherSignature := signature
    SourceWatcherDefinitions := Map()
    for index, folder in LastValidFolderSettings {
        key := folder.SourceId != "" ? folder.SourceId
            : ResolveFolderSourceId(folder.Name, folder.Path)
        definition := {Key: key, Path: folder.Path,
            Subtree: folder.DisplayScope != "FilesOnly"
                || folder.FolderTimeMode = "LatestContent",
            Kind: "Source", Index: index}
        SourceWatcherDefinitions[key] := definition
        cacheConflicts := CacheDir != "" && (PathsEqual(CacheDir, folder.Path)
            || (definition.Subtree
                && IsSameOrDescendantPath(CacheDir, folder.Path)))
        if !cacheConflicts && IsLocalWatchablePath(folder.Path)
            && DirExist(folder.Path) {
            watcher := CreateSourceWatcher(definition)
            if IsObject(watcher)
                SourceWatchers[key] := watcher
            else
                ScheduleSourceWatcherReopen()
        }
    }
    if ShowRecentSidebar {
        recentPath := A_AppData "\Microsoft\Windows\Recent"
        definition := {Key: "__recent", Path: recentPath,
            Subtree: false, Kind: "Recent", Index: 0}
        SourceWatcherDefinitions[definition.Key] := definition
        if DirExist(recentPath) {
            watcher := CreateSourceWatcher(definition)
            if IsObject(watcher)
                SourceWatchers[definition.Key] := watcher
            else
                ScheduleSourceWatcherReopen()
        }
    }
    if SourceWatchers.Count
        SetTimer(PollSourceWatchers, 150)
}

CreateSourceWatcher(definition) {
    ; FILE_LIST_DIRECTORY, full sharing, OPEN_EXISTING,
    ; FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED.
    handle := DllCall("kernel32\CreateFileW", "wstr", definition.Path,
        "uint", 0x0001, "uint", 0x7, "ptr", 0, "uint", 3,
        "uint", 0x42000000, "ptr", 0, "ptr")
    if handle = -1
        return 0
    eventHandle := DllCall("kernel32\CreateEventW", "ptr", 0,
        "int", true, "int", false, "ptr", 0, "ptr")
    if !eventHandle {
        DllCall("kernel32\CloseHandle", "ptr", handle)
        return 0
    }
    overlappedSize := A_PtrSize = 8 ? 32 : 20
    eventOffset := A_PtrSize * 2 + 8
    watcher := {Key: definition.Key, Path: definition.Path,
        Kind: definition.Kind, Index: definition.Index,
        Subtree: definition.Subtree, Handle: handle, Event: eventHandle,
        Buffer: Buffer(65536, 0), Overlapped: Buffer(overlappedSize, 0)}
    NumPut("ptr", eventHandle, watcher.Overlapped, eventOffset)
    if !IssueSourceWatchRead(watcher) {
        CloseSourceWatcher(watcher)
        return 0
    }
    return watcher
}

IssueSourceWatchRead(watcher) {
    ; FILE/DIR_NAME | ATTRIBUTES | SIZE | LAST_WRITE | CREATION.
    return DllCall("kernel32\ReadDirectoryChangesW",
        "ptr", watcher.Handle, "ptr", watcher.Buffer.Ptr,
        "uint", watcher.Buffer.Size, "int", watcher.Subtree,
        "uint", 0x5F, "ptr", 0, "ptr", watcher.Overlapped.Ptr,
        "ptr", 0, "int")
}

PollSourceWatchers() {
    global SourceWatchers
    failedKeys := []
    for key, watcher in SourceWatchers {
        waitResult := DllCall("kernel32\WaitForSingleObject",
            "ptr", watcher.Event, "uint", 0, "uint")
        if waitResult = 0x102
            continue
        if waitResult != 0 {
            failedKeys.Push(key)
            QueueSourceWatcherChange(watcher)
            continue
        }
        bytesTransferred := 0
        ok := DllCall("kernel32\GetOverlappedResult", "ptr", watcher.Handle,
            "ptr", watcher.Overlapped.Ptr, "uint*", &bytesTransferred,
            "int", false, "int")
        ; A zero-byte successful result is the documented overflow signal.
        QueueSourceWatcherChange(watcher)
        DllCall("kernel32\ResetEvent", "ptr", watcher.Event)
        if !ok || !IssueSourceWatchRead(watcher)
            failedKeys.Push(key)
    }
    for key in failedKeys {
        if SourceWatchers.Has(key) {
            CloseSourceWatcher(SourceWatchers[key])
            SourceWatchers.Delete(key)
        }
    }
    if failedKeys.Length
        ScheduleSourceWatcherReopen()
    if !SourceWatchers.Count
        SetTimer(PollSourceWatchers, 0)
}

QueueSourceWatcherChange(watcher) {
    global SourceWatcherDirtyKeys, SourceWatcherRecentDirty
    global SourceWatcherRefreshPending
    if watcher.Kind = "Recent"
        SourceWatcherRecentDirty := true
    else
        SourceWatcherDirtyKeys[watcher.Key] := true
    if !SourceWatcherRefreshPending {
        SourceWatcherRefreshPending := true
        ; Collapse editor-save sequences and bulk copies into one source batch.
        SetTimer(FlushSourceWatcherChanges, -120)
    }
}

FlushSourceWatcherChanges() {
    global SourceWatcherDirtyKeys, SourceWatcherRecentDirty
    global SourceWatcherRefreshPending
    sourceKeys := SourceWatcherDirtyKeys
    includeRecent := SourceWatcherRecentDirty
    SourceWatcherDirtyKeys := Map()
    SourceWatcherRecentDirty := false
    SourceWatcherRefreshPending := false
    if sourceKeys.Count || includeRecent
        StartBackgroundScan(sourceKeys, "watch", includeRecent)
}

ScheduleSourceWatcherReopen() {
    global SourceWatcherReopenDue
    if SourceWatcherReopenDue
        return
    SourceWatcherReopenDue := true
    SetTimer(ReopenSourceWatchers, -2000)
}

ReopenSourceWatchers() {
    global SourceWatcherReopenDue
    SourceWatcherReopenDue := false
    ReconcileSourceWatchers(true)
}

CloseSourceWatcher(watcher) {
    if watcher.Handle && watcher.Handle != -1 {
        try DllCall("kernel32\CancelIoEx", "ptr", watcher.Handle,
            "ptr", watcher.Overlapped.Ptr)
        DllCall("kernel32\CloseHandle", "ptr", watcher.Handle)
        watcher.Handle := 0
    }
    if watcher.Event {
        DllCall("kernel32\CloseHandle", "ptr", watcher.Event)
        watcher.Event := 0
    }
}

CleanupSourceWatchers() {
    global SourceWatchers
    SetTimer(PollSourceWatchers, 0)
    SetTimer(FlushSourceWatcherChanges, 0)
    for key, watcher in SourceWatchers
        CloseSourceWatcher(watcher)
    SourceWatchers := Map()
}

PanelPowerBroadcast(wParam, lParam, msg, hwnd) {
    ; PBT_APMRESUMEAUTOMATIC / PBT_APMRESUMESUSPEND / legacy resume.
    if wParam = 18 || wParam = 7 || wParam = 6 {
        CleanupSourceWatchers()
        SetTimer(ResumeSourceMonitoring, -800)
    }
    return true
}

ResumeSourceMonitoring() {
    ReconcileSourceWatchers(true)
    StartBackgroundScan(0, "resume")
}

CheckRefreshPolicyOnShow() {
    global StartupCalibrationPending, LastDailyCalibrationDate
    global ConsistencyCheckHours, ProcessStartedAt, LastConsistencyBucket
    global ConsistencyCheckPending, ShowRecentSidebar
    global SourceWatcherDefinitions, SourceWatchers
    ReconcileSourceWatchers()
    today := SubStr(A_Now, 1, 8)
    calibrated := false
    if StartupCalibrationPending || LastDailyCalibrationDate != today {
        StartupCalibrationPending := false
        LastDailyCalibrationDate := today
        StartBackgroundScan(0, "calibration", ShowRecentSidebar)
        calibrated := true
    }
    if !calibrated {
        unmonitored := Map()
        for key, definition in SourceWatcherDefinitions {
            if definition.Kind = "Source" && !SourceWatchers.Has(key)
                unmonitored[key] := true
        }
        if unmonitored.Count
            StartBackgroundScan(unmonitored, "reconnect", false)
    }
    if ConsistencyCheckHours <= 0
        return
    elapsedHours := DateDiff(A_Now, ProcessStartedAt, "Hours")
    bucket := Floor(elapsedHours / ConsistencyCheckHours)
    if bucket > LastConsistencyBucket
        ConsistencyCheckPending := true
}

RunPendingConsistencyCheckAfterHide() {
    global ConsistencyCheckPending, LastConsistencyBucket
    global ConsistencyCheckHours, ProcessStartedAt
    global SourceWatcherDefinitions, SourceWatchers
    if !ConsistencyCheckPending
        return
    ConsistencyCheckPending := false
    sourceKeys := Map()
    ; Healthy local handles already provide continuity. Reconcile only sources
    ; whose handles are absent/failed (network, removable or error recovery).
    for key, definition in SourceWatcherDefinitions {
        if definition.Kind = "Source" && !SourceWatchers.Has(key)
            sourceKeys[key] := true
    }
    if sourceKeys.Count
        StartBackgroundScan(sourceKeys, "consistency", false)
    if ConsistencyCheckHours > 0 {
        elapsedHours := DateDiff(A_Now, ProcessStartedAt, "Hours")
        LastConsistencyBucket := Floor(elapsedHours / ConsistencyCheckHours)
    }
}
