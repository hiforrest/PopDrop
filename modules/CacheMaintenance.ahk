; Bounded lifecycle management for PopDrop-owned runtime cache artifacts.
; Only exact, known names directly below CacheDir are eligible for deletion.
; preview-cache-v1 remains exclusively owned and bounded by PopDropPreview.exe.

InitializeCacheMaintenance() {
    global CacheDir, CacheMaintenanceDirectory
    global CacheMaintenanceStateLoaded, CacheMaintenanceCompletedDate
    previous := CacheMaintenanceDirectory
    CancelCacheMaintenanceOpportunity()
    CacheMaintenanceDirectory := CacheDir
    if previous = "" || CacheMaintenancePathKey(previous)
        != CacheMaintenancePathKey(CacheDir) {
        CacheMaintenanceStateLoaded := false
        CacheMaintenanceCompletedDate := ""
    }
}

ScheduleCacheMaintenanceAfterHide() {
    global PanelVisible, CacheDir, CacheMaintenanceCompletedDate
    global CacheMaintenanceOpportunityDate, CacheMaintenanceTimer
    global CacheMaintenanceGeneration, CacheMaintenanceYieldRequested
    if PanelVisible || CacheDir = ""
        return false
    CacheMaintenanceLoadDayState()
    today := CacheMaintenanceToday()
    if CacheMaintenanceCompletedDate = today
        return false

    CancelCacheMaintenanceOpportunity()
    CacheMaintenanceYieldRequested := false
    generation := ++CacheMaintenanceGeneration
    CacheMaintenanceOpportunityDate := today
    CacheMaintenanceTimer := RunCacheMaintenanceOpportunity.Bind(
        generation, today)
    SetTimer(CacheMaintenanceTimer, -10000)
    return true
}

CancelCacheMaintenanceOpportunity() {
    global CacheMaintenanceTimer, CacheMaintenanceGeneration
    global CacheMaintenanceYieldRequested
    if IsObject(CacheMaintenanceTimer)
        try SetTimer(CacheMaintenanceTimer, 0)
    CacheMaintenanceTimer := 0
    CacheMaintenanceGeneration += 1
    CacheMaintenanceYieldRequested := true
}

RunCacheMaintenanceOpportunity(generation, opportunityDate) {
    global PanelVisible, CacheMaintenanceGeneration, CacheMaintenanceTimer
    global CacheMaintenanceRunning, CacheMaintenanceYieldRequested
    global CacheMaintenanceCompletedDate
    if generation != CacheMaintenanceGeneration || PanelVisible
        return false
    ; An opportunity never crosses midnight on its own. A new natural day
    ; requires another real show/hide cycle before maintenance is considered.
    if opportunityDate != CacheMaintenanceToday()
        return false
    if CacheMaintenanceHigherPriorityWorkActive() {
        if IsObject(CacheMaintenanceTimer)
            SetTimer(CacheMaintenanceTimer, -2000)
        return false
    }

    CacheMaintenanceRunning := true
    CacheMaintenanceYieldRequested := false
    try result := RunCacheMaintenanceBounded(opportunityDate)
    catch {
        result := {RemovedItems: 0, FailedItems: 1,
            LimitReached: false, Yielded: false}
    } finally CacheMaintenanceRunning := false

    if result.Yielded || PanelVisible
        || generation != CacheMaintenanceGeneration
        || opportunityDate != CacheMaintenanceToday()
        return false

    ; Empty scans, ordinary failures and reaching the work cap all complete
    ; today's opportunity. This prevents repeated work on every later hide.
    CacheMaintenanceCompletedDate := opportunityDate
    CacheMaintenanceTimer := 0
    CacheMaintenanceWriteCompletion(opportunityDate, result)
    return true
}

CacheMaintenanceHigherPriorityWorkActive() {
    global WorkerRunning, InactiveScanJob, ScanCacheWritePending
    global PreviewCacheActive, PreviewHoverCacheQueue
    global PreviewEnabled, PreviewCacheEnabled
    if WorkerRunning || IsObject(InactiveScanJob) || ScanCacheWritePending
        return true
    if PreviewCacheActive
        return true
    if PreviewEnabled && PreviewCacheEnabled
        && IsObject(PreviewHoverCacheQueue)
        && PreviewHoverCacheQueue.Length
        return true
    try return PreviewHasActiveTransfer()
    catch
        return false
}

RunCacheMaintenanceBounded(opportunityDate) {
    global CacheDir, CacheWritable, Workspaces
    result := {RemovedItems: 0, FailedItems: 0,
        LimitReached: false, Yielded: false}
    limits := {StartedTick: A_TickCount, Inspected: 0, Deleted: 0,
        MaxInspected: 256, MaxDeleted: 24, MaxMilliseconds: 150,
        OpportunityDate: opportunityDate}
    if CacheDir = "" || !DirExist(CacheDir)
        return result
    if !CacheWritable {
        result.FailedItems := 1
        return result
    }

    validWorkspaceFiles := CacheMaintenanceWorkspaceFiles()
    corruptGroups := Map()
    Loop Files, CacheDir "\*", "FD" {
        if !CacheMaintenanceCanContinue(limits, result)
            break
        limits.Inspected += 1
        name := A_LoopFileName
        path := A_LoopFileFullPath
        isDirectory := InStr(A_LoopFileAttrib, "D") != 0
        if InStr(A_LoopFileAttrib, "L")
            continue
        if RegExMatch(name,
            "i)^index\.db\.corrupt-(\d{14})(?:-(wal|shm))?$", &match) {
            stamp := match[1]
            if !corruptGroups.Has(stamp)
                corruptGroups[stamp] := []
            corruptGroups[stamp].Push({Path: path, IsDirectory: false})
            continue
        }
        kind := CacheMaintenanceNameKind(name, isDirectory)
        if kind = ""
            continue
        ageSeconds := CacheMaintenanceAgeSeconds(path)
        if CacheMaintenanceShouldDelete(kind, name, ageSeconds,
            CacheMaintenancePathIsActive(path), validWorkspaceFiles)
            CacheMaintenanceDelete(path, isDirectory, result, limits)
    }
    if !result.Yielded
        CacheMaintenancePruneCorruptGroups(corruptGroups, result, limits)
    if !result.Yielded && CacheMaintenanceCanContinue(limits, result)
        try RuntimeIndexPruneWorkspaceSnapshots(Workspaces, 16)
    return result
}

CacheMaintenanceCanContinue(limits, result) {
    global PanelVisible, CacheMaintenanceYieldRequested
    if PanelVisible || CacheMaintenanceYieldRequested
        || limits.OpportunityDate != CacheMaintenanceToday() {
        result.Yielded := true
        return false
    }
    if limits.Inspected >= limits.MaxInspected
        || limits.Deleted >= limits.MaxDeleted
        || ElapsedTickMilliseconds(limits.StartedTick, A_TickCount)
            >= limits.MaxMilliseconds {
        result.LimitReached := true
        return false
    }
    return true
}

CacheMaintenanceNameKind(name, isDirectory) {
    if isDirectory && (RegExMatch(name, "i)^ready-[0-9A-F]+-[0-9A-F]+$")
        || RegExMatch(name,
            "i)^inactive-[0-9A-F]+-[0-9A-F]+\.ready$"))
        return "Transient"
    if !isDirectory && (RegExMatch(name,
            "i)^request-[0-9A-F]+-[0-9A-F]+\.ini$")
        || RegExMatch(name,
            "i)^inactive-[0-9A-F]+-[0-9A-F]+\.request\.ini$"))
        return "Transient"
    if !isDirectory && RegExMatch(name,
        "i)^workspace-[0-9A-F]{8}\.ini\.writing$")
        return "Writing"
    if !isDirectory && RegExMatch(name, "i)^\.write-test-[0-9]+$")
        return "Writing"
    if !isDirectory && RegExMatch(name, "i)^scan-cache-v[1-3]\.ini$")
        return "Legacy"
    if !isDirectory && RegExMatch(name, "i)^workspace-[0-9A-F]{8}\.ini$")
        return "Workspace"
    return ""
}

CacheMaintenanceShouldDelete(kind, name, ageSeconds,
    active, validWorkspaceFiles) {
    if active
        return false
    if kind = "Transient"
        return ageSeconds >= 900
    if kind = "Writing"
        return ageSeconds >= 3600
    if kind = "Legacy"
        return ageSeconds >= 86400
    if kind = "Workspace"
        return !validWorkspaceFiles.Has(StrLower(name))
            && ageSeconds >= 7 * 86400
    return false
}

CacheMaintenanceWorkspaceFiles() {
    global Workspaces
    names := Map()
    for workspace in Workspaces
        names[StrLower("workspace-"
            . HashString(StrLower(workspace.Id)) ".ini")] := true
    return names
}

CacheMaintenancePathIsActive(path) {
    global WorkerRunning, WorkerRequestPath, WorkerReadyPath, InactiveScanJob
    key := CacheMaintenancePathKey(path)
    if WorkerRunning && WorkerRequestPath != ""
        && key = CacheMaintenancePathKey(WorkerRequestPath)
        return true
    if WorkerRunning && WorkerReadyPath != ""
        && key = CacheMaintenancePathKey(WorkerReadyPath)
        return true
    if IsObject(InactiveScanJob) {
        if HasProp(InactiveScanJob, "RequestPath")
            && key = CacheMaintenancePathKey(InactiveScanJob.RequestPath)
            return true
        if HasProp(InactiveScanJob, "ReadyPath")
            && key = CacheMaintenancePathKey(InactiveScanJob.ReadyPath)
            return true
    }
    return false
}

CacheMaintenancePathKey(path) {
    return StrLower(RTrim(StrReplace(path, "/", "\"), "\"))
}

CacheMaintenanceAgeSeconds(path) {
    try modified := FileGetTime(path, "M")
    catch
        return 0
    if modified = ""
        return 0
    try return Max(0, DateDiff(A_Now, modified, "Seconds"))
    catch
        return 0
}

CacheMaintenanceDelete(path, isDirectory, result, limits) {
    if !CacheMaintenanceCanContinue(limits, result)
        return false
    limits.Deleted += 1
    try {
        if isDirectory
            DirDelete(path, true)
        else
            FileDelete(path)
        result.RemovedItems += 1
        return true
    } catch {
        result.FailedItems += 1
        return false
    }
}

CacheMaintenancePruneCorruptGroups(groups, result, limits) {
    remaining := []
    for stamp, entries in groups {
        if !CacheMaintenanceCanContinue(limits, result)
            return
        ageSeconds := 0
        try ageSeconds := Max(0, DateDiff(A_Now, stamp, "Seconds"))
        if ageSeconds >= 7 * 86400 {
            for entry in entries
                if !CacheMaintenanceDelete(
                    entry.Path, false, result, limits)
                    && result.Yielded
                    return
        } else
            remaining.Push({Stamp: stamp, Entries: entries})
    }
    while remaining.Length > 3 {
        if !CacheMaintenanceCanContinue(limits, result)
            return
        oldestIndex := 1
        for index, group in remaining
            if group.Stamp < remaining[oldestIndex].Stamp
                oldestIndex := index
        oldest := remaining.RemoveAt(oldestIndex)
        for entry in oldest.Entries
            if !CacheMaintenanceDelete(entry.Path, false, result, limits)
                && result.Yielded
                return
    }
}

CacheMaintenanceToday() {
    return FormatTime(A_Now, "yyyyMMdd")
}

CacheMaintenanceLoadDayState() {
    global CacheMaintenanceStateLoaded, CacheMaintenanceCompletedDate
    global CacheDir
    if CacheMaintenanceStateLoaded
        return
    CacheMaintenanceStateLoaded := true
    CacheMaintenanceCompletedDate := ""
    statusPath := CacheDir "\cache-maintenance.ini"
    if FileExist(statusPath)
        try CacheMaintenanceCompletedDate := IniRead(
            statusPath, "Maintenance", "CompletedDate", "")
}

CacheMaintenanceWriteCompletion(completedDate, result) {
    global CacheDir, CacheWritable
    if !CacheWritable || CacheDir = ""
        return
    path := CacheDir "\cache-maintenance.ini"
    try {
        IniWrite(completedDate, path, "Maintenance", "CompletedDate")
        IniWrite(A_Now, path, "Maintenance", "CompletedAt")
        IniWrite(result.RemovedItems, path, "Maintenance", "RemovedItems")
        IniWrite(result.FailedItems, path, "Maintenance", "FailedItems")
        IniWrite(result.LimitReached ? "1" : "0",
            path, "Maintenance", "LimitReached")
    }
}
