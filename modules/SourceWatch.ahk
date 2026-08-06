; Asynchronous source change monitoring and conditional consistency checks.
;
; Directory handles are deliberately limited to local volumes. Opening an
; offline UNC or mapped drive on the UI thread can block for seconds; those
; sources are reconciled by the background worker instead.

SourceWatcherSettingsSignature() {
    global Workspaces, ShowRecentSidebar, CacheDir
    raw := "recent=" (ShowRecentSidebar ? 1 : 0)
        . "|cache=" StrLower(RTrim(CacheDir, "\"))
    for workspace in Workspaces {
        raw .= "|workspace=" StrLower(workspace.Id)
        for folder in GetWorkspaceWatchFolders(workspace) {
            key := folder.SourceId != "" ? folder.SourceId
                : ResolveFolderSourceId(folder.Name, folder.Path)
            subtree := folder.DisplayScope != "FilesOnly"
                || folder.FolderTimeMode = "LatestContent"
            raw .= "|" key "|" StrLower(RTrim(folder.Path, "\"))
                . "|" (subtree ? 1 : 0)
        }
    }
    return HashString(raw)
}

GetWorkspaceWatchFolders(workspace) {
    if IsObject(workspace.Sources) && workspace.Sources.Length
        return workspace.Sources
    ; Invalid configurations still get a conservative watcher definition so
    ; a later repair can mark the source dirty without losing its identity.
    result := []
    for ref in workspace.SourceRefs
        result.Push({Name: ref.Name, Path: ref.Path, SourceId: ref.SourceId,
            DisplayScope: "FilesOnly", FolderTimeMode: "Modified"})
    return result
}

BuildSourceWatcherKey(path, subtree) {
    return PathKey(path) "|" (subtree ? 1 : 0)
}

MarkWorkspaceSourceDirty(workspaceId, sourceId) {
    global WorkspaceDirtySourceKeys
    workspaceKey := StrLower(workspaceId)
    if !WorkspaceDirtySourceKeys.Has(workspaceKey)
        WorkspaceDirtySourceKeys[workspaceKey] := Map()
    dirty := WorkspaceDirtySourceKeys[workspaceKey]
    sourceKey := StrLower(sourceId)
    dirty[sourceKey] := dirty.Has(sourceKey) ? dirty[sourceKey] + 1 : 1
}

MarkWorkspaceSourceUnmonitored(workspaceId, sourceId) {
    global WorkspaceUnmonitoredSourceKeys, WorkspaceSourceHealth
    workspaceKey := StrLower(workspaceId)
    if !WorkspaceUnmonitoredSourceKeys.Has(workspaceKey)
        WorkspaceUnmonitoredSourceKeys[workspaceKey] := Map()
    WorkspaceUnmonitoredSourceKeys[workspaceKey][StrLower(sourceId)] := true
    SetWorkspaceSourceHealth(workspaceId, sourceId, "Unmonitored")
}

SetWorkspaceSourceHealth(workspaceId, sourceId, state) {
    global WorkspaceSourceHealth
    workspaceKey := StrLower(workspaceId)
    if !WorkspaceSourceHealth.Has(workspaceKey)
        WorkspaceSourceHealth[workspaceKey] := Map()
    WorkspaceSourceHealth[workspaceKey][StrLower(sourceId)] := state
}

GetWorkspaceRefreshSourceKeys(workspaceId, includeUnmonitored := true) {
    global WorkspaceDirtySourceKeys, WorkspaceUnmonitoredSourceKeys
    result := Map()
    workspaceKey := StrLower(workspaceId)
    if WorkspaceDirtySourceKeys.Has(workspaceKey)
        for sourceKey, token in WorkspaceDirtySourceKeys[workspaceKey]
            result[sourceKey] := true
    if includeUnmonitored && WorkspaceUnmonitoredSourceKeys.Has(workspaceKey)
        for sourceKey, value in WorkspaceUnmonitoredSourceKeys[workspaceKey]
            result[sourceKey] := true
    return result
}

GetWorkspaceSourceDirtyToken(workspaceId, sourceId) {
    global WorkspaceDirtySourceKeys
    workspaceKey := StrLower(workspaceId)
    sourceKey := StrLower(sourceId)
    return WorkspaceDirtySourceKeys.Has(workspaceKey)
        && WorkspaceDirtySourceKeys[workspaceKey].Has(sourceKey)
        ? WorkspaceDirtySourceKeys[workspaceKey][sourceKey] : 0
}

ClearWorkspaceSourceDirty(workspaceId, sourceId, token := 0) {
    global WorkspaceDirtySourceKeys, InactiveScanQueue
    workspaceKey := StrLower(workspaceId)
    sourceKey := StrLower(sourceId)
    if !WorkspaceDirtySourceKeys.Has(workspaceKey)
        return
    dirty := WorkspaceDirtySourceKeys[workspaceKey]
    if !dirty.Has(sourceKey)
        return
    if token = 0 || dirty[sourceKey] = token {
        dirty.Delete(sourceKey)
        ; A foreground scan may satisfy work that was previously queued while
        ; this workspace was inactive.  Do not let that stale queue later
        ; overwrite the freshly committed snapshot.
        if InactiveScanQueue.Has(workspaceKey) {
            queued := InactiveScanQueue[workspaceKey]
            if queued.Has(sourceKey)
                && (token = 0 || queued[sourceKey] = token)
                queued.Delete(sourceKey)
            if !queued.Count
                InactiveScanQueue.Delete(workspaceKey)
        }
    }
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
    global WorkspaceUnmonitoredSourceKeys, WorkspaceSourceHealth
    global Workspaces, ShowRecentSidebar, CacheDir
    signature := SourceWatcherSettingsSignature()
    if !force && signature = SourceWatcherSignature
        return
    CleanupSourceWatchers()
    SourceWatcherSignature := signature
    SourceWatcherDefinitions := Map()
    WorkspaceUnmonitoredSourceKeys := Map()
    WorkspaceSourceHealth := Map()
    for workspace in Workspaces {
        for index, folder in GetWorkspaceWatchFolders(workspace) {
            sourceId := folder.SourceId != "" ? folder.SourceId
                : ResolveFolderSourceId(folder.Name, folder.Path)
            subtree := folder.DisplayScope != "FilesOnly"
                || folder.FolderTimeMode = "LatestContent"
            watchKey := BuildSourceWatcherKey(folder.Path, subtree)
            if !SourceWatcherDefinitions.Has(watchKey)
                SourceWatcherDefinitions[watchKey] := {Key: watchKey,
                    Path: folder.Path, Subtree: subtree, Kind: "Source",
                    Bindings: []}
            SourceWatcherDefinitions[watchKey].Bindings.Push({
                WorkspaceId: workspace.Id, SourceId: sourceId, Index: index})
        }
    }

    for watchKey, definition in SourceWatcherDefinitions {
        canWatch := IsLocalWatchablePath(definition.Path)
            && DirExist(definition.Path)
        cacheConflicts := false
        if CacheDir != ""
            cacheConflicts := PathsEqual(CacheDir, definition.Path)
                || (definition.Subtree
                    && IsSameOrDescendantPath(CacheDir, definition.Path))
        if canWatch && !cacheConflicts {
            watcher := CreateSourceWatcher(definition)
            if IsObject(watcher) {
                SourceWatchers[watchKey] := watcher
                for binding in definition.Bindings
                    SetWorkspaceSourceHealth(binding.WorkspaceId,
                        binding.SourceId, "Healthy")
            } else
                canWatch := false
        }
        if !canWatch {
            for binding in definition.Bindings
                MarkWorkspaceSourceUnmonitored(binding.WorkspaceId,
                    binding.SourceId)
            if IsLocalWatchablePath(definition.Path)
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
    SchedulePendingSourceWatcherFlush()
}

SchedulePendingSourceWatcherFlush() {
    global ActiveWorkspaceId, SourceWatcherRecentDirty
    global SourceWatcherRefreshPending
    global WorkspaceDirtySourceKeys
    if SourceWatcherRefreshPending
        return
    sourceKeys := GetWorkspaceRefreshSourceKeys(ActiveWorkspaceId, false)
    if !sourceKeys.Count && !SourceWatcherRecentDirty {
        ; Dirty workspaces may all be inactive.  Flush still owns queuing their
        ; disk/memory snapshot refreshes.
        hasDirty := false
        for workspaceKey, dirty in WorkspaceDirtySourceKeys {
            if dirty.Count {
                hasDirty := true
                break
            }
        }
        if !hasDirty
            return
    }
    SourceWatcherRefreshPending := true
    SetTimer(FlushSourceWatcherChanges, -1)
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
        Kind: definition.Kind,
        Bindings: definition.HasProp("Bindings") ? definition.Bindings : [],
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
            QueueSourceWatcherChange(watcher, "Failed")
            continue
        }
        bytesTransferred := 0
        ok := DllCall("kernel32\GetOverlappedResult", "ptr", watcher.Handle,
            "ptr", watcher.Overlapped.Ptr, "uint*", &bytesTransferred,
            "int", false, "int")
        ; A zero-byte successful result is the documented overflow signal.
        QueueSourceWatcherChange(watcher,
            ok && bytesTransferred = 0 ? "Overflowed" : "Dirty")
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

QueueSourceWatcherChange(watcher, state := "Dirty") {
    global SourceWatcherRecentDirty, SourceWatcherRecentGeneration
    global SourceWatcherRefreshPending
    if watcher.Kind = "Recent" {
        SourceWatcherRecentDirty := true
        SourceWatcherRecentGeneration += 1
    } else {
        for binding in watcher.Bindings {
            SetWorkspaceSourceHealth(binding.WorkspaceId, binding.SourceId, state)
            MarkWorkspaceSourceDirty(binding.WorkspaceId, binding.SourceId)
        }
    }
    if !SourceWatcherRefreshPending {
        SourceWatcherRefreshPending := true
        ; Collapse editor-save sequences and bulk copies into one source batch.
        SetTimer(FlushSourceWatcherChanges, -120)
    }
}

FlushSourceWatcherChanges() {
    global ActiveWorkspaceId, SourceWatcherRecentDirty, ShowRecentSidebar
    global SourceWatcherRefreshPending
    sourceKeys := GetWorkspaceRefreshSourceKeys(ActiveWorkspaceId, false)
    includeRecent := SourceWatcherRecentDirty && ShowRecentSidebar
    SourceWatcherRefreshPending := false
    if sourceKeys.Count || includeRecent
        StartBackgroundScan(sourceKeys, "watch", includeRecent)
    QueueInactiveWorkspaceScans()
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
    global SourceWatchers, SourceWatcherRefreshPending
    SetTimer(PollSourceWatchers, 0)
    SetTimer(FlushSourceWatcherChanges, 0)
    ; Cancelling the debounce timer must also release its latch.  Otherwise a
    ; watcher rebuild during the 120-ms window permanently suppresses every
    ; later change notification.
    SourceWatcherRefreshPending := false
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
    global ConsistencyCheckMinutes, ProcessStartedAt, LastConsistencyBucket
    global ConsistencyCheckPending, ShowRecentSidebar
    global ActiveWorkspaceId, Workspaces, WorkspaceCalibrationSeeded
    global SourceWatcherRecentDirty, SourceWatcherRecentGeneration
    global ContentUpdateMode, CONTENT_UPDATE_ACCURACY
    ReconcileSourceWatchers()
    today := SubStr(A_Now, 1, 8)
    calibrated := false
    if StartupCalibrationPending || LastDailyCalibrationDate != today {
        WorkspaceCalibrationSeeded := false
        SeedWorkspaceCalibrationDirty()
        if ShowRecentSidebar {
            SourceWatcherRecentDirty := true
            SourceWatcherRecentGeneration += 1
        }
        StartupCalibrationPending := false
        LastDailyCalibrationDate := today
        StartBackgroundScan(0, "calibration", ShowRecentSidebar)
        QueueInactiveWorkspaceScans()
        calibrated := true
    }
    if !calibrated && ContentUpdateMode = CONTENT_UPDATE_ACCURACY {
        ; Accuracy mode validates the visible workspace every time the panel
        ; is summoned, even when its cached snapshot is already present.
        StartBackgroundScan(0, "accuracy-show", ShowRecentSidebar)
    } else if !calibrated {
        unmonitored := GetWorkspaceRefreshSourceKeys(ActiveWorkspaceId, true)
        if unmonitored.Count
            StartBackgroundScan(unmonitored, "reconnect", false)
    }
    if ConsistencyCheckMinutes <= 0
        return
    elapsedMinutes := DateDiff(A_Now, ProcessStartedAt, "Minutes")
    bucket := Floor(elapsedMinutes / ConsistencyCheckMinutes)
    if bucket > LastConsistencyBucket
        ConsistencyCheckPending := true
}

SeedWorkspaceCalibrationDirty() {
    global Workspaces, WorkspaceCalibrationSeeded
    if WorkspaceCalibrationSeeded
        return
    for workspace in Workspaces
        for folder in GetWorkspaceWatchFolders(workspace) {
            sourceId := folder.SourceId != "" ? folder.SourceId
                : ResolveFolderSourceId(folder.Name, folder.Path)
            MarkWorkspaceSourceDirty(workspace.Id, sourceId)
        }
    WorkspaceCalibrationSeeded := true
}

RunPendingConsistencyCheckAfterHide() {
    global ConsistencyCheckPending, LastConsistencyBucket
    global ConsistencyCheckMinutes, ProcessStartedAt, ActiveWorkspaceId
    if !ConsistencyCheckPending
        return
    ConsistencyCheckPending := false
    sourceKeys := GetWorkspaceRefreshSourceKeys(ActiveWorkspaceId, true)
    if sourceKeys.Count
        StartBackgroundScan(sourceKeys, "consistency", false)
    if ConsistencyCheckMinutes > 0 {
        elapsedMinutes := DateDiff(A_Now, ProcessStartedAt, "Minutes")
        LastConsistencyBucket := Floor(elapsedMinutes / ConsistencyCheckMinutes)
    }
}
