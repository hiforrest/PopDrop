; Bounded lifecycle management for PopDrop-owned runtime cache artifacts.
; Only exact, known names directly below CacheDir are eligible for deletion.
; The preview-cache-v1 subtree remains owned by PopDropPreview.exe, which
; validates its SHA-256 names and applies its own size/item/retention limits.

InitializeCacheMaintenance() {
    global CacheCleanupEnabled, CacheDir
    global CacheMaintenanceDirectory, CacheMaintenanceLastTick
    SetTimer(RunScheduledCacheMaintenance, 0)
    if !CacheCleanupEnabled || CacheDir = ""
        return
    directoryChanged := CacheMaintenanceDirectory = ""
        || CacheMaintenancePathKey(CacheMaintenanceDirectory)
            != CacheMaintenancePathKey(CacheDir)
    if directoryChanged || !CacheMaintenanceLastTick
        || A_TickCount - CacheMaintenanceLastTick >= 3600000
        RunCacheMaintenance(false)
    SetTimer(RunScheduledCacheMaintenance, 3600000)
}

RunScheduledCacheMaintenance() {
    global CacheCleanupEnabled
    if CacheCleanupEnabled
        RunCacheMaintenance(false)
    else
        SetTimer(RunScheduledCacheMaintenance, 0)
}

RunCacheMaintenance(force := false) {
    global CacheDir, CacheWritable, CacheCleanupEnabled
    global CacheRetentionDays, CacheMaintenanceDirectory
    global CacheMaintenanceLastTick, CacheMaintenanceLastResult
    result := {RemovedItems: 0, RemovedBytes: 0, FailedItems: 0,
        TotalBytes: 0, TotalItems: 0, RanAt: A_Now}
    if CacheDir = "" || !DirExist(CacheDir)
        return result
    if !force && (!CacheCleanupEnabled || !CacheWritable)
        return result
    validWorkspaceFiles := CacheMaintenanceWorkspaceFiles()
    corruptGroups := Map()
    Loop Files, CacheDir "\*", "FD" {
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
            corruptGroups[stamp].Push({Path: path,
                Bytes: CacheMaintenancePathSize(path), IsDirectory: false})
            continue
        }
        kind := CacheMaintenanceNameKind(name, isDirectory)
        if kind = ""
            continue
        ageSeconds := CacheMaintenanceAgeSeconds(path)
        shouldDelete := CacheMaintenanceShouldDelete(
            kind, name, ageSeconds, CacheRetentionDays,
            force, CacheMaintenancePathIsActive(path), validWorkspaceFiles)
        if shouldDelete
            CacheMaintenanceDelete(path, isDirectory, result)
    }
    CacheMaintenancePruneCorruptGroups(
        corruptGroups, CacheRetentionDays, force, result)
    statistics := CacheDirectoryStatistics(CacheDir)
    result.TotalBytes := statistics.Bytes
    result.TotalItems := statistics.Items
    CacheMaintenanceDirectory := CacheDir
    CacheMaintenanceLastTick := A_TickCount
    CacheMaintenanceLastResult := result
    CacheMaintenanceWriteStatus(result)
    return result
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

CacheMaintenanceShouldDelete(kind, name, ageSeconds, retentionDays,
    force, active, validWorkspaceFiles) {
    if active
        return false
    if kind = "Transient"
        return ageSeconds >= 900
    if kind = "Writing"
        return ageSeconds >= 3600
    if kind = "Legacy"
        return force || ageSeconds >= 86400
    if kind = "Workspace"
        return !validWorkspaceFiles.Has(StrLower(name))
            && (force || ageSeconds >= retentionDays * 86400)
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

CacheMaintenancePathSize(path) {
    attributes := FileExist(path)
    if attributes = ""
        return 0
    if !InStr(attributes, "D") {
        try return FileGetSize(path)
        catch
            return 0
    }
    total := 0
    Loop Files, path "\*", "FR" {
        if InStr(A_LoopFileAttrib, "L")
            continue
        try total += A_LoopFileSize
    }
    return total
}

CacheMaintenanceDelete(path, isDirectory, result) {
    bytes := CacheMaintenancePathSize(path)
    try {
        if isDirectory
            DirDelete(path, true)
        else
            FileDelete(path)
        result.RemovedItems += 1
        result.RemovedBytes += bytes
        return true
    } catch {
        result.FailedItems += 1
        return false
    }
}

CacheMaintenancePruneCorruptGroups(groups, retentionDays, force, result) {
    remaining := []
    for stamp, entries in groups {
        ageSeconds := 0
        try ageSeconds := Max(0, DateDiff(A_Now, stamp, "Seconds"))
        if force || ageSeconds >= retentionDays * 86400 {
            for entry in entries
                CacheMaintenanceDelete(entry.Path, false, result)
        } else
            remaining.Push({Stamp: stamp, Entries: entries})
    }
    while remaining.Length > 3 {
        oldestIndex := 1
        for index, group in remaining
            if group.Stamp < remaining[oldestIndex].Stamp
                oldestIndex := index
        oldest := remaining.RemoveAt(oldestIndex)
        for entry in oldest.Entries
            CacheMaintenanceDelete(entry.Path, false, result)
    }
}

CacheDirectoryStatistics(path) {
    statistics := {Bytes: 0, Items: 0}
    if path = "" || !DirExist(path)
        return statistics
    Loop Files, path "\*", "FR" {
        if InStr(A_LoopFileAttrib, "L")
            continue
        statistics.Bytes += A_LoopFileSize
        statistics.Items += 1
    }
    return statistics
}

CacheMaintenanceWriteStatus(result) {
    global CacheDir, CacheWritable
    if !CacheWritable || CacheDir = ""
        return
    path := CacheDir "\cache-maintenance.ini"
    try {
        IniWrite(result.RanAt, path, "Maintenance", "LastRun")
        IniWrite(result.RemovedItems, path, "Maintenance", "RemovedItems")
        IniWrite(result.RemovedBytes, path, "Maintenance", "RemovedBytes")
        IniWrite(result.FailedItems, path, "Maintenance", "FailedItems")
        IniWrite(result.TotalBytes, path, "Maintenance", "TotalBytes")
        IniWrite(result.TotalItems, path, "Maintenance", "TotalItems")
    }
}

FormatCacheByteCount(bytes) {
    units := ["B", "KB", "MB", "GB", "TB"]
    value := bytes + 0.0
    unitIndex := 1
    while value >= 1024 && unitIndex < units.Length {
        value /= 1024
        unitIndex += 1
    }
    return (unitIndex = 1 ? Format("{:.0f}", value)
        : RegExReplace(Format("{:.1f}", value), "\.0$"))
        . " " units[unitIndex]
}
