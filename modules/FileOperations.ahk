; Copy, move, delete and IFileOperation progress-sink integration.

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

CanRenamePath(path) {
    path := NormalizePath(path)
    return path != "" && !!FileExist(path) && !IsPathRoot(path)
        && !!DirExist(GetParentPath(path))
}

RenameWouldAffectConfiguredSource(path) {
    global LastValidFolderSettings
    for folder in LastValidFolderSettings {
        if IsSameOrDescendantPath(folder.Path, path)
            return true
    }
    return false
}

ValidateRenameName(name) {
    if name = ""
        return {Valid: false, Error: "名称不能为空。"}
    if name != Trim(name)
        return {Valid: false, Error: "名称不能以空格开头或结尾。"}
    if name = "." || name = ".."
        return {Valid: false, Error: "不能使用“.”或“..”作为名称。"}
    if StrLen(name) > 255
        return {Valid: false, Error: "名称不能超过 255 个字符。"}
    if RegExMatch(name, "[<>:\x22/\\|?*\x00-\x1F]")
        return {Valid: false,
            Error: "名称不能包含 < > : 双引号 / \ | ? * 或控制字符。"}
    if SubStr(name, -1) = "."
        return {Valid: false, Error: "名称不能以句点结尾。"}
    baseName := StrSplit(name, ".")[1]
    if RegExMatch(baseName,
        "i)^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$") {
        return {Valid: false, Error: "该名称是 Windows 保留设备名。"}
    }
    return {Valid: true, Error: ""}
}

RequestRenamePath(path, *) {
    path := NormalizePath(path)
    if !CanRenamePath(path) {
        ShowPanelMsgBox(
            "该项目不存在、无法访问或属于不能重命名的根目录。",
            "无法重命名", "Icon!")
        return false
    }
    if RenameWouldAffectConfiguredSource(path) {
        ShowPanelMsgBox(
            "该文件夹是已配置来源，或包含已配置来源。`n`n"
            . "为避免来源配置失效，请先在设置中移除或调整相关来源。",
            "无法重命名来源路径", "Icon!")
        return false
    }

    SplitPath(path, &oldName)
    Loop {
        result := PromptPanelInput(
            "请输入新名称（文件请保留所需扩展名）：",
            "重命名", oldName)
        if result.Result != "OK"
            return false
        newName := result.Value
        validation := ValidateRenameName(newName)
        if !validation.Valid {
            ShowPanelMsgBox(validation.Error, "名称无效", "Icon!")
            continue
        }
        if oldName == newName {
            SetUserStatus("名称未改变")
            return false
        }
        targetPath := GetParentPath(path) "\" newName
        if FileExist(targetPath) && !PathsEqual(path, targetPath) {
            ShowPanelMsgBox(
                "同一位置已经存在名为“" newName "”的项目。",
                "名称已存在", "Icon!")
            continue
        }
        return PerformShellRename(path, newName)
    }
}

PerformShellRename(path, newName) {
    ; Use IFileOperation so rename follows the same elevation, undo, progress
    ; callback, pinned-path synchronization and view restoration path as move.
    global Panel
    path := NormalizePath(path)
    validation := ValidateRenameName(newName)
    if !CanRenamePath(path) || !validation.Valid
        return {Success: 0, Failed: 1, Skipped: 0,
            Aborted: false, Changed: false, RefreshQueued: false}

    parentPath := GetParentPath(path)
    targetPath := NormalizePath(parentPath "\" newName)
    viewState := CaptureViewState([path])
    state := {
        Operation: "rename",
        Target: parentPath,
        OriginalPath: path,
        ExpectedPath: targetPath,
        Success: 0,
        Failed: 0,
        Changed: false,
        Mappings: Map(),
        ResultPaths: [],
        PinnedMappingFailures: [],
        Details: []
    }
    sink := CreateFileOperationProgressSink(state)
    fileOperation := 0
    sourceItem := 0
    cookie := 0
    queued := false
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
            throw Error("无法创建 Windows Shell 文件操作。")

        ; FOF_ALLOWUNDO | FOF_NOCONFIRMMKDIR | FOFX_SHOWELEVATIONPROMPT.
        ComCall(5, fileOperation, "uint", 0x40240)
        ComCall(9, fileOperation, "ptr", Panel.Hwnd)
        hr := ComCall(3, fileOperation, "ptr", sink.Ptr, "uint*", &cookie)
        if hr != 0
            throw Error("无法订阅重命名结果。")

        sourceItem := CreateShellItem(path)
        if !sourceItem
            throw Error("Windows Shell 无法解析该项目。")
        hr := ComCall(12, fileOperation, "ptr", sourceItem,
            "wstr", newName, "ptr", 0)
        if !HResultSucceeded(hr)
            throw Error("无法将重命名加入操作队列。")
        queued := true

        BeginAutoHidePause()
        try performHr := ComCall(21, fileOperation)
        finally EndAutoHidePause()
        ComCall(22, fileOperation, "int*", &aborted)
    } catch as err {
        ShowPanelMsgBox("重命名失败：`n" err.Message,
            "重命名", "Iconx")
    } finally {
        if fileOperation && cookie
            try ComCall(4, fileOperation, "uint", cookie)
        if sourceItem
            ObjRelease(sourceItem)
        if fileOperation
            ObjRelease(fileOperation)
        ReleaseFileOperationSink(sink)
    }

    refreshQueued := false
    if state.Changed {
        oldKey := PathKey(path)
        if !state.Mappings.Has(oldKey)
            && FileExist(targetPath) && !FileExist(path) {
            state.Mappings[oldKey] := {
                OldPath: path, NewPath: targetPath}
            if !state.ResultPaths.Length
                state.ResultPaths.Push(targetPath)
        }
        pinnedUpdateFailed := false
        if state.Mappings.Count {
            try UpdatePinnedPathsAfterMove(state.Mappings)
            catch as err {
                pinnedUpdateFailed := true
                ShowPanelMsgBox(
                    "项目已重命名，但固定项路径保存失败：`n"
                    . err.Message "`n`n请立即检查 config.ini。",
                    "固定项更新失败", "Iconx")
            }
        } else if IsPathPinnedInAnyWorkspace(path) {
            pinnedUpdateFailed := true
            ShowPanelMsgBox(
                "项目已重命名，但 Windows Shell 未返回可验证的新路径。`n`n"
                . "请检查并修正固定项配置。",
                "固定项路径需要检查", "Icon!")
        }
        QueueSingleRefreshAfterFileOperation(viewState, state.Mappings)
        refreshQueued := true
        message := "已重命名为“" newName "”"
        if pinnedUpdateFailed
            message .= "；固定项需要检查"
        SetUserStatus(message)
    } else if queued && (aborted || HResultSucceeded(performHr)) {
        SetUserStatus("重命名已取消，名称未改变")
    }
    return {
        Success: state.Success,
        Failed: state.Failed,
        Skipped: 0,
        Aborted: !!aborted,
        Changed: state.Changed,
        RefreshQueued: refreshQueued,
        Details: state.Details
    }
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
        try RemoveDeletedTextSourcePinnedPaths(state.DeletedPaths)
        catch as err
            ShowPanelMsgBox(
                "项目已移入回收站，但文件夹内置顶配置更新失败：`n"
                . err.Message "`n`n请检查 config.ini。",
                "置顶配置更新失败", "Icon!")
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
    global Workspaces, ActiveWorkspaceId, PinnedPaths
    if !deletedPaths.Length
        return
    snapshots := []
    changed := false
    for workspace in Workspaces {
        snapshots.Push({
            Workspace: workspace,
            Paths: workspace.PinnedPaths.Clone()
        })
        remaining := []
        for pinnedPath in workspace.PinnedPaths {
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
        if !PathArraysEqual(workspace.PinnedPaths, remaining) {
            workspace.PinnedPaths := remaining
            changed := true
        }
    }
    if !changed
        return
    active := FindWorkspace(ActiveWorkspaceId, Workspaces)
    if IsObject(active)
        PinnedPaths := active.Value.PinnedPaths
    try SaveAllWorkspacePinnedFiles()
    catch as err {
        for snapshot in snapshots
            snapshot.Workspace.PinnedPaths := snapshot.Paths
        active := FindWorkspace(ActiveWorkspaceId, Workspaces)
        if IsObject(active)
            PinnedPaths := active.Value.PinnedPaths
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
                    OpenFolderInFileManager.Bind(targetPath))
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
                OpenFolderInFileManager.Bind(targetPath))
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
            try UpdatePinnedPathsAfterMove(state.Mappings, operationContext)
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
                SetActionStatus(message,
                    OpenFolderInFileManager.Bind(targetPath))
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
        OpenFolderInFileManager(targetPath)
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

UpdatePinnedPathsAfterMove(mappings, operationContext := 0) {
    global Workspaces, ActiveWorkspaceId, PinnedPaths
    try UpdateTextBlockUsagePaths(mappings)
    UpdateTextSourcePinnedPathsAfterMove(mappings)
    snapshots := []
    changed := false
    for workspace in Workspaces {
        snapshots.Push({
            Workspace: workspace,
            Paths: workspace.PinnedPaths.Clone()
        })
        updatedPaths := []
        for pinnedPath in workspace.PinnedPaths {
            if ShouldRemoveMovedPinnedPath(
                workspace.Id, pinnedPath, mappings, operationContext) {
                changed := true
                continue
            }
            mappedPath := ResolveMovedPathMapping(pinnedPath, mappings)
            if mappedPath != "" && !(pinnedPath == mappedPath) {
                updatedPaths.Push(mappedPath)
                changed := true
            } else
                updatedPaths.Push(pinnedPath)
        }
        if !PathArraysEqual(workspace.PinnedPaths, updatedPaths)
            workspace.PinnedPaths := updatedPaths
    }
    if !changed
        return
    active := FindWorkspace(ActiveWorkspaceId, Workspaces)
    if IsObject(active)
        PinnedPaths := active.Value.PinnedPaths
    try SaveAllWorkspacePinnedFiles()
    catch as err {
        for snapshot in snapshots
            snapshot.Workspace.PinnedPaths := snapshot.Paths
        active := FindWorkspace(ActiveWorkspaceId, Workspaces)
        if IsObject(active)
            PinnedPaths := active.Value.PinnedPaths
        throw err
    }
}

ShouldRemoveMovedPinnedPath(workspaceId, pinnedPath, mappings,
    operationContext) {
    if !IsObject(operationContext)
        || !HasProp(operationContext, "RemoveMovedPinsWorkspaceId")
        || !HasProp(operationContext, "RemoveMovedPinnedPaths")
        || StrLower(workspaceId)
            != StrLower(operationContext.RemoveMovedPinsWorkspaceId)
        || !ArrayContainsPath(operationContext.RemoveMovedPinnedPaths,
            pinnedPath)
        return false
    ; Only successful Shell mappings are removed. Cancelled or failed items
    ; remain pinned and visible for retry.
    return mappings.Has(PathKey(pinnedPath))
}

ResolveMovedPathMapping(path, mappings) {
    key := PathKey(path)
    if mappings.Has(key)
        return mappings[key].NewPath

    bestMapping := 0
    bestLength := 0
    for _, mapping in mappings {
        oldRoot := RTrim(NormalizePath(mapping.OldPath), "\")
        if oldRoot = "" || PathsEqual(path, oldRoot)
            continue
        if IsSameOrDescendantPath(path, oldRoot)
            && StrLen(oldRoot) > bestLength {
            bestMapping := mapping
            bestLength := StrLen(oldRoot)
        }
    }
    if !IsObject(bestMapping)
        return ""
    suffix := SubStr(NormalizePath(path), bestLength + 1)
    return NormalizePath(RTrim(bestMapping.NewPath, "\") suffix)
}

SaveAllWorkspacePinnedFiles() {
    SyncActiveWorkspacePinnedState()
    AtomicConfigEdit(WriteAllWorkspacePinnedFilesConfig)
}

WriteAllWorkspacePinnedFilesConfig(tempPath) {
    global Workspaces, CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    for workspace in Workspaces
        WritePinnedPathsToDocument(doc,
            "WorkspacePinned:" workspace.Id, workspace.PinnedPaths, 3)
    doc.SetValue("Workspaces", "PinnedScopeVersion", "1", 3)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

IsPathPinnedInAnyWorkspace(path) {
    global Workspaces
    for workspace in Workspaces {
        if FindPathIndex(workspace.PinnedPaths, path)
            return true
    }
    return false
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
    RecordFileOperationResult(this, item, hr, created)
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
    global FileOperationSinks
    if !FileOperationSinks.Has(this)
        return
    state := FileOperationSinks[this].State
    originalPath := GetShellItemPath(originalItem)
    if state.Operation = "rename"
        && HasProp(state, "OriginalPath")
        && state.OriginalPath != ""
        originalPath := state.OriginalPath
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
        if (state.Operation = "move" || state.Operation = "rename")
            && originalPath != "" {
            if newPath != ""
                state.Mappings[PathKey(originalPath)] := {
                    OldPath: originalPath, NewPath: newPath}
            else if IsPathPinnedInAnyWorkspace(originalPath) {
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
