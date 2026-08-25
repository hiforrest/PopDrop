; Panel population, directory scanning, cache and worker IPC.

PopulatePanel() {
    global FileView, ItemPaths, ItemLabels, ItemFolderPaths
    global ItemKinds, ItemOpenContexts
    global PinnedPaths, FolderSettings, StatusText
    global IncludeSubfolders, MaxFilesPerFolder, SortMode
    global ThumbnailSize, ThumbnailImageList, ThumbnailImageListEdge
    global ThumbnailIconCache, SelectedFilePaths, LastValidFolderSettings, ConfigErrors
    global CurrentScanResult, ScanResultLoaded, StatusKind
    global ConfigErrorsShown, MODE_FILES, GroupFolderPaths, GroupDropTargets
    global SCOPE_FILES_ONLY, SCOPE_RECURSIVE_FILES, FOLDER_TIME_MODIFIED
    global PendingFileOperationRefresh, PendingRefresh
    global ActiveWorkspaceId, PinnedPaths
    global NOISE_FILTER_INHERIT
    global PanelRenderSignature, PanelRenderedWorkspaceId
    global ThumbnailEnhanceQueue, ThumbnailEnhanceGeneration
    global ItemCountText
    global TextBlockSelectFirstPending, TextBlockSearchQuery
    global PanelRenderInProgress, PanelRenderPending, PanelRenderGeneration
    global CurrentScanComplete, CurrentScanRevision
    global PanelRenderedScanRevision, PanelRenderedScanComplete
    renderStartedTick := A_TickCount

    ; Publish the ListView and all row metadata as one transaction. A timer
    ; interrupt between FileView.Delete() and final map/signature publication
    ; can otherwise save a half-built view under another workspace.
    if PanelRenderInProgress {
        PanelRenderPending := true
        return false
    }
    previousCritical := A_IsCritical
    PanelRenderInProgress := true
    PanelRenderPending := false
    renderWorkspaceId := ActiveWorkspaceId
    renderGeneration := ++PanelRenderGeneration
    Critical("On")
    try {
    stableViewState := PanelRenderedWorkspaceId != ""
        && StrLower(PanelRenderedWorkspaceId) = StrLower(ActiveWorkspaceId)
        && ItemPaths.Count ? CaptureViewState([]) : 0
    CancelFilePointerGesture()
    PreviewInvalidateList("main")
    SetDropGroupHighlight(0)
    SelectedFilePaths := []
    ThumbnailEnhanceQueue := []
    ThumbnailEnhanceGeneration += 1
    FileView.Opt("-Redraw")
    FileView.Delete()
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x10A0,
        "ptr", 0, "ptr", 0, "ptr") ; LVM_REMOVEALLGROUPS
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x109D,
        "ptr", 1, "ptr", 0, "ptr") ; LVM_ENABLEGROUPVIEW
    ApplyFileViewGroupSpacing(FileView.Hwnd)

    ; Tile view reserves the image-list dimensions even when an item has no
    ; icon. Text cards use a deliberately small 8-DIP spacer: enough left
    ; inset for readable card copy without recreating the old 96-DIP phantom
    ; icon column.
    ; ImageList dimensions are raw pixels. ThumbnailSize has always represented
    ; that native pixel edge, even when Windows display scaling is 200%. Apply
    ; only PopDrop's explicit panel scale here; multiplying by window DPI would
    ; turn a configured 110 px thumbnail into 220 px at system 200%.
    imageEdge := IsTextWorkspace()
        ? PanelScale(8)
        : PanelScale(ThumbnailSize)
    imageCapacity := IsTextWorkspace() ? 1 : 24
    if !ThumbnailImageList || ThumbnailImageListEdge != imageEdge
        || ThumbnailIconCache.Count > 2048 {
        newImageList := DllCall("comctl32\ImageList_Create", "int", imageEdge,
            "int", imageEdge, "uint", 0x21, "int", imageCapacity,
            "int", IsTextWorkspace() ? 1 : 12, "ptr")
        if !newImageList
            throw Error("无法创建缩略图列表。")
        oldImageList := FileView.SetImageList(newImageList, 0)
        ThumbnailImageList := newImageList
        ThumbnailImageListEdge := imageEdge
        ThumbnailIconCache := Map()
        if oldImageList && oldImageList != newImageList
            DllCall("comctl32\ImageList_Destroy", "ptr", oldImageList)
    } else
        FileView.SetImageList(ThumbnailImageList, 0)
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

    visiblePinnedPaths := IsTextWorkspace()
        ? PreparePinnedTextBlockPaths(PinnedPaths) : PinnedPaths
    if visiblePinnedPaths.Length {
        InsertListGroup(groupId, "固定项  (" visiblePinnedPaths.Length ")")
        GroupDropTargets[groupId] := {
            Type: IsTextWorkspace() ? "TextPinned" : "Pinned",
            SourceId: "", Name: "固定项",
            Path: "", Mode: "", GroupId: groupId,
            WorkspaceId: ActiveWorkspaceId}
        for path in visiblePinnedPaths {
            exists := FileExist(path)
            isPinnedDirectory := !!exists && InStr(exists, "D")
            if !exists {
                label := GetFileName(path) "  [项目不存在]"
                row := AddFileTile(path, label, "", groupId, "UnknownFile")
            } else if IsTextWorkspace() && HasTextBlockExtension(path)
                row := AddTextBlockTile(path, groupId)
            else {
                label := GetFileName(path)
                row := AddFileTile(
                    path, label, "", groupId, "", isPinnedDirectory)
            }
            ItemPaths[row] := path
            ItemKinds[row] := isPinnedDirectory ? "Folder" : "File"
            ItemOpenContexts[row] := {Area: "Pinned", GroupId: groupId,
                WorkspaceId: ActiveWorkspaceId}
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
        if IsTextWorkspace()
            files := PrepareTextBlockFiles(files, folder,
                folder.MaxFilesPerFolder)
        if ShouldHideTextSourceForSearch(IsTextWorkspace(),
            TextBlockSearchQuery, state, files.Length)
            continue
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
        groupCollapsed := IsFolderGroupCollapseRemembered(
            ActiveWorkspaceId, folder.SourceId, folder.Path)
        InsertListGroup(groupId,
            FormatFolderGroupHeader(groupHeader, groupCollapsed),
            groupCollapsed)
        GroupFolderPaths[groupId] := folder.Path
        GroupDropTargets[groupId] := {
            Type: IsTextWorkspace() ? "TextSource" : folder.Mode,
            SourceId: folder.SourceId,
            Name: folder.Name,
            Path: folder.Path,
            Mode: folder.Mode,
            GroupId: groupId,
            WorkspaceId: ActiveWorkspaceId,
            Available: state != "Unavailable",
            BaseHeader: groupHeader
        }
        if state = "Pending" {
            row := AddPlaceholderTile("正在加载…", groupId)
            ItemPaths[row] := folder.Path
            ItemFolderPaths[row] := folder.Path
            ItemKinds[row] := "Folder"
            ItemOpenContexts[row] := {
                Area: "Source",
                WorkspaceId: ActiveWorkspaceId,
                SourceId: folder.SourceId,
                SourcePath: folder.Path,
                SourceMode: folder.Mode,
                GroupId: groupId
            }
            groupId += 1
            continue
        }
        if state = "Unavailable" {
            row := AddPlaceholderTile("目录不可用", groupId)
            ItemPaths[row] := folder.Path
            ItemFolderPaths[row] := folder.Path
            ItemKinds[row] := "Folder"
            ItemOpenContexts[row] := {
                Area: "Source",
                WorkspaceId: ActiveWorkspaceId,
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
                row := AddPlaceholderTile(
                    "暂无文件", groupId, "EmptyFolder")
            ItemPaths[row] := folder.Path
            ItemFolderPaths[row] := folder.Path
            ItemKinds[row] := "Folder"
            ItemOpenContexts[row] := {
                Area: "Source",
                WorkspaceId: ActiveWorkspaceId,
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
            row := IsTextWorkspace()
                ? AddTextBlockTile(file.Path, groupId)
                : AddFileTile(file.Path, displayName, modifiedText,
                    groupId, "", file.IsDirectory)
            ItemPaths[row] := file.Path
            ItemFolderPaths[row] := folder.Path
            ItemKinds[row] := file.IsDirectory ? "Folder" : "File"
            ItemOpenContexts[row] := {
                Area: "Source",
                WorkspaceId: ActiveWorkspaceId,
                SourceId: folder.SourceId,
                SourcePath: folder.Path,
                SourceMode: folder.Mode,
                GroupId: groupId,
                FolderPinned: IsTextWorkspace()
                    && IsTextSourcePathPinned(folder.SourceId, file.Path)
            }
            displayedCount += 1
        }
        groupId += 1
    }

    if !folderSettings.Length {
        InsertListGroup(groupId, "当前工作区")
        AddPlaceholderTile("当前工作区还没有来源。", groupId)
        AddPlaceholderTile(
            "将文件夹拖到顶部“添加为来源”，或前往设置添加。", groupId)
    }

    if IsTextWorkspace()
        ApplyTextBlockCardView()
    else
        ApplyViewMode()
    ; Apply context-sensitive source task links while redraw is still disabled,
    ; so a scan refresh never flashes stale links from a previous invocation.
    UpdateSaveDialogGroupTaskLinks()
    FileView.Opt("+Redraw")
    UpdateTransferGroupHeaders()
    ; Invalidate the committed rows but let WM_PAINT run after Critical is
    ; released. Synchronous RDW_UPDATENOW would block an already-clicked Tab.
    DllCall("user32\RedrawWindow", "ptr", FileView.Hwnd, "ptr", 0, "ptr", 0,
        "uint", 0x0001 | 0x0080, "int")
    if IsObject(ItemCountText) {
        countText := "共" displayedCount "项"
        if unavailableCount
            countText .= " · " unavailableCount "不可用"
        ItemCountText.Text := countText
    }
    if !ScanResultLoaded || !CurrentScanComplete {
        StatusKind := "background"
        StatusText.Text := "正在加载"
    } else if StatusKind != "background" {
        StatusKind := "default"
        StatusText.Text := "已是最新"
    }
    RedrawFooterTextControls()
    PanelRenderSignature := ComputePanelRenderSignature()
    PanelRenderedWorkspaceId := ActiveWorkspaceId
    PanelRenderedScanRevision := CurrentScanRevision
    PanelRenderedScanComplete := CurrentScanComplete
    if ThumbnailEnhanceQueue.Length
        SetTimer(EnhanceNextThumbnail, -120)

    ; 在 GUI 完全更新后显示错误对话框
    if ConfigErrors.Length
        SetTimer(ShowConfigErrorDialog, -100)

    if PendingFileOperationRefresh && !PendingRefresh
        ApplyPendingViewRestore()
    else if IsObject(stableViewState)
        RestoreStableScanViewState(stableViewState)
    if IsTextWorkspace() {
        SelectDefaultTextBlockSearchResult(TextBlockSelectFirstPending)
        TextBlockSelectFirstPending := false
    }
        ; This should be impossible while Critical is active. Keep the
        ; invariant as a fail-fast guard rather than silently publishing a
        ; cross-workspace native view.
        if StrLower(renderWorkspaceId) != StrLower(ActiveWorkspaceId)
            throw Error("界面提交期间工作区发生变化，已取消本次呈现。")
    } finally {
        rerun := PanelRenderPending
        PanelRenderPending := false
        PanelRenderInProgress := false
        Critical(previousCritical)
        renderElapsedMs := ElapsedTickMilliseconds(
            renderStartedTick, A_TickCount)
        if renderElapsedMs >= 40
            QueueWorkspacePerformanceTrace("populate",
                "workspace=" renderWorkspaceId
                . "`trows=" (IsSet(displayedCount) ? displayedCount : -1)
                . "`tms=" renderElapsedMs)
        if rerun
            SetTimer(PopulatePanel, -1)
    }
    return true
}

RestoreStableScanViewState(restore) {
    global FileView, ItemPaths
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
    if !focusRow && selectedRows.Length
        focusRow := selectedRows[1]
    if focusRow
        FileView.Modify(focusRow, "Focus")
    if ItemPaths.Count {
        topRow := Max(1, Min(restore.TopRow, ItemPaths.Count))
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
            "uint", 0x1013, "ptr", topRow - 1, "ptr", 0, "ptr")
    }
}

InsertListGroup(groupId, header, collapsed := false) {
    global FileView
    groupSize := A_PtrSize = 8 ? 152 : 96
    group := Buffer(groupSize, 0)
    stateMaskOffset := A_PtrSize = 8 ? 40 : 28
    stateOffset := A_PtrSize = 8 ? 44 : 32
    NumPut("uint", groupSize, group, 0)
    NumPut("uint", 0x15, group, 4)
        ; LVGF_HEADER | LVGF_STATE | LVGF_GROUPID
    NumPut("ptr", StrPtr(header), group, 8)
    NumPut("int", groupId, group, A_PtrSize = 8 ? 36 : 24)
    NumPut("uint", 0x1, group, stateMaskOffset) ; LVGS_COLLAPSED
    NumPut("uint", collapsed ? 0x1 : 0, group, stateOffset)
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

SetListItemImageIndex(row, imageIndex) {
    global FileView
    item := Buffer(A_PtrSize = 8 ? 88 : 60, 0)
    NumPut("uint", 0x2, item, 0) ; LVIF_IMAGE
    NumPut("int", row - 1, item, 4)
    NumPut("int", imageIndex, item, A_PtrSize = 8 ? 36 : 28)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x104C,
        "ptr", 0, "ptr", item.Ptr, "ptr") ; LVM_SETITEMW
}

AddFileTile(path, label, modifiedText, groupId, bundledIcon := "",
    isDirectory := -1) {
    global FileView, ItemLabels, ThumbnailPolicy
    cacheKey := PathKey(path) "|" modifiedText "|" bundledIcon
    thumbnail := bundledIcon != ""
        ? AddBundledThumbnailIcon(bundledIcon)
        : AddShellThumbnail(path, cacheKey, isDirectory)
    options := thumbnail.Index ? "Icon" thumbnail.Index : ""
    row := FileView.Add(options, label, modifiedText)
    if bundledIcon != "" && !thumbnail.Index
        SetListItemImageIndex(row, -2) ; I_IMAGENONE: never borrow index zero
    ItemLabels[row] := label
    SetListItemGroup(row, groupId)
    if bundledIcon = "" && ThumbnailPolicy = "Full" && !thumbnail.Cached
        QueueThumbnailEnhancement(path, row, cacheKey)
    return row
}

AddPlaceholderTile(label, groupId, bundledIcon := "") {
    global FileView, ItemLabels
    thumbnail := bundledIcon != ""
        ? AddBundledThumbnailIcon(bundledIcon)
        : {Index: 0, Cached: true}
    options := thumbnail.Index ? "Icon" thumbnail.Index : ""
    row := FileView.Add(options, label, "")
    if !thumbnail.Index
        SetListItemImageIndex(row, -2) ; I_IMAGENONE
    ItemLabels[row] := label
    SetListItemGroup(row, groupId)
    return row
}

AddBundledThumbnailIcon(kind) {
    global ThumbnailImageList, ThumbnailImageListEdge, ThumbnailIconCache

    resourceId := kind = "EmptyFolder" ? 558
        : kind = "UnknownFile" ? 559 : 0
    fileName := kind = "EmptyFolder" ? "empty-folder.ico"
        : kind = "UnknownFile" ? "unknown-file.ico" : ""
    if !resourceId || fileName = ""
        return {Index: 0, Cached: true}

    cacheKey := "__popdrop-bundled__|" kind "|" ThumbnailImageListEdge
    if ThumbnailIconCache.Has(cacheKey)
        return ThumbnailIconCache[cacheKey]

    icon := 0
    if A_IsCompiled {
        module := DllCall("kernel32\GetModuleHandleW", "ptr", 0, "ptr")
        icon := DllCall("user32\LoadImageW", "ptr", module,
            "ptr", resourceId, "uint", 1,
            "int", ThumbnailImageListEdge, "int", ThumbnailImageListEdge,
            "uint", 0, "ptr") ; IMAGE_ICON
    }
    if !icon {
        iconPath := A_ScriptDir "\assets\" fileName
        icon := DllCall("user32\LoadImageW", "ptr", 0,
            "wstr", iconPath, "uint", 1,
            "int", ThumbnailImageListEdge, "int", ThumbnailImageListEdge,
            "uint", 0x10, "ptr") ; IMAGE_ICON | LR_LOADFROMFILE
    }

    imageIndex := -1
    if icon {
        imageIndex := DllCall("comctl32\ImageList_ReplaceIcon",
            "ptr", ThumbnailImageList, "int", -1, "ptr", icon, "int")
        DllCall("user32\DestroyIcon", "ptr", icon)
    }
    result := {Index: (imageIndex >= 0 ? imageIndex + 1 : 0), Cached: true}
    ThumbnailIconCache[cacheKey] := result
    return result
}

AddShellThumbnail(path, cacheKey := "", isDirectory := -1) {
    global ThumbnailSize, ThumbnailImageList, ThumbnailIconCache
    if cacheKey != "" && ThumbnailIconCache.Has(cacheKey)
        return ThumbnailIconCache[cacheKey]
    ; Folders are pinned as single shortcuts. Always use their Shell icon
    ; instead of asking Windows to inspect their contents for a thumbnail.
    if isDirectory < 0
        isDirectory := !!DirExist(path)
    if isDirectory {
        result := {Index: AddShellFileIcon(path, true), Cached: true}
        if cacheKey != "" && result.Index
            ThumbnailIconCache[cacheKey] := result
        return result
    }

    ; The content frame must not perform one COM thumbnail lookup per row,
    ; even with INCACHEONLY: Shell providers may still block while parsing an
    ; item. Show a cached file-type icon now and let the worker import the
    ; thumbnail after the ListView is already interactive.
    result := {Index: AddShellFileIcon(path, false), Cached: false}
    if cacheKey != "" && result.Index
        ThumbnailIconCache[cacheKey] := result
    return result
}

AddShellThumbnailBitmap(path, cacheOnly := true) {
    global ThumbnailSize, ThumbnailImageList

    factory := 0
    bitmap := 0
    try {
        iidImageFactory := GuidBuffer("{BCC18B79-BA16-442F-80C4-8A59C30C463B}")
        if DllCall("shell32\SHCreateItemFromParsingName", "wstr", path, "ptr", 0,
            "ptr", iidImageFactory.Ptr, "ptr*", &factory) = 0 {
            ; IShellItemImageFactory also consumes a raw pixel SIZE. Keep it
            ; identical to the ImageList edge and do not apply system DPI twice.
            scaledThumbnailSize := PanelScale(ThumbnailSize)
            requestedSize := (scaledThumbnailSize & 0xFFFFFFFF)
                | (scaledThumbnailSize << 32)
            ; SIIGBF_INCACHEONLY (0x10) prevents an uncached thumbnail from
            ; triggering synchronous decoding on the UI thread.
            imageFlags := 0x20 | (cacheOnly ? 0x10 : 0)
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
    return 0
}

QueueThumbnailEnhancement(path, row, cacheKey := "") {
    global ThumbnailEnhanceQueue, ThumbnailEnhanceGeneration
    ; All expensive content access happens in the isolated preview helper, so
    ; mapped/UNC sources are safe to queue as well. The previous blanket
    ; DRIVE_REMOTE rejection left an entire mapped workspace permanently on
    ; file-type icons even when its images were already local and responsive.
    ; Keep only URL-like pseudo paths out of the native file protocol.
    if RegExMatch(path, "i)^(?:https?|ftp|webdav)://")
        return
    ThumbnailEnhanceQueue.Push({Path: path, Row: row, CacheKey: cacheKey,
        Generation: ThumbnailEnhanceGeneration})
}

EnhanceNextThumbnail() {
    global ThumbnailEnhanceQueue, ThumbnailEnhanceGeneration
    global ItemPaths, FileView, ThumbnailImageList, ThumbnailImageListEdge
    global ThumbnailNativePreviewJob, ActiveWorkspaceId
    if !ThumbnailEnhanceQueue.Length || IsObject(ThumbnailNativePreviewJob)
        return
    ; Starting a process is the only non-constant part left on the UI side.
    ; Keep it out of the short debounce/commit window of a Tab gesture. Once the
    ; helper is running, polling and importing one <=512 px image are bounded.
    if !ThumbnailBackgroundStartAllowed() {
        SetTimer(EnhanceNextThumbnail, -ThumbnailBackgroundRetryDelay())
        return
    }
    task := ThumbnailEnhanceQueue.RemoveAt(1)
    if task.Generation = ThumbnailEnhanceGeneration
        && ItemPaths.Has(task.Row)
        && PathKey(ItemPaths[task.Row]) = PathKey(task.Path) {
        task.WorkspaceId := ActiveWorkspaceId
        task.ViewHwnd := FileView.Hwnd
        task.ImageList := ThumbnailImageList
        task.ImageEdge := ThumbnailImageListEdge
        task.NativeStage := "Probe"
        started := false
        try started := BeginNativeThumbnailPreview(task, 1)
        catch as err {
            RegisterNativeThumbnailTransportFailure(
                "request-exception:" err.What)
            CleanupNativeThumbnailPreviewHelper(false)
        }
        if started
            return
        RetryNativeThumbnailTransport(task)
        return
    }
    if ThumbnailEnhanceQueue.Length
        SetTimer(EnhanceNextThumbnail, -15)
}

ThumbnailBackgroundStartAllowed() {
    global PanelWorkspaceSwitchRunning, PendingPanelWorkspaceId
    global LastWorkspaceTabQueuedTick, PanelRenderInProgress
    global ThumbnailNativePreviewBackoffTick
    global ThumbnailNativePreviewBackoffMs
    if PanelWorkspaceSwitchRunning || PendingPanelWorkspaceId != ""
        || PanelRenderInProgress
        return false
    if ThumbnailNativePreviewBackoffTick {
        elapsed := ElapsedTickMilliseconds(
            ThumbnailNativePreviewBackoffTick, A_TickCount)
        if elapsed < ThumbnailNativePreviewBackoffMs
            return false
        ThumbnailNativePreviewBackoffTick := 0
        ThumbnailNativePreviewBackoffMs := 0
    }
    return !LastWorkspaceTabQueuedTick
        || ElapsedTickMilliseconds(LastWorkspaceTabQueuedTick, A_TickCount) >= 120
}

ThumbnailBackgroundRetryDelay() {
    global ThumbnailNativePreviewBackoffTick
    global ThumbnailNativePreviewBackoffMs
    if ThumbnailNativePreviewBackoffTick {
        elapsed := ElapsedTickMilliseconds(
            ThumbnailNativePreviewBackoffTick, A_TickCount)
        if elapsed < ThumbnailNativePreviewBackoffMs
            return Max(250, Min(1000,
                ThumbnailNativePreviewBackoffMs - elapsed))
    }
    return 60
}

RegisterNativeThumbnailTransportFailure(reason) {
    global ThumbnailNativePreviewFailureTicks
    global ThumbnailNativePreviewBackoffTick
    global ThumbnailNativePreviewBackoffMs
    now := A_TickCount
    kept := []
    for tick in ThumbnailNativePreviewFailureTicks {
        if ElapsedTickMilliseconds(tick, now) <= 60000
            kept.Push(tick)
    }
    kept.Push(now)
    ThumbnailNativePreviewFailureTicks := kept
    QueueWorkspacePerformanceTrace("thumbnail",
        "transport=" reason "`tfailures60s=" kept.Length)
    ; A missing dependency or blocked helper used to launch once per row. That
    ; process churn can make the whole app appear frozen. Three transport
    ; failures open a one-minute circuit while keeping the remaining queue for
    ; a later recovery attempt.
    if kept.Length >= 3 {
        ThumbnailNativePreviewBackoffTick := now
        ThumbnailNativePreviewBackoffMs := 60000
    }
}

RegisterNativeThumbnailTransportSuccess() {
    global ThumbnailNativePreviewFailureTicks
    global ThumbnailNativePreviewBackoffTick
    global ThumbnailNativePreviewBackoffMs
    ThumbnailNativePreviewFailureTicks := []
    ThumbnailNativePreviewBackoffTick := 0
    ThumbnailNativePreviewBackoffMs := 0
}

BeginNativeThumbnailPreview(task, command := 1) {
    global ThumbnailNativePreviewJob, ThumbnailNativePreviewGeneration
    global ThumbnailNativePreviewRequestSerial
    global ThumbnailNativePreviewMapView, ThumbnailNativePreviewRequestEvent
    global ThumbnailNativePreviewResponseEvent
    global CacheDir, CacheWritable
    global PreviewCacheMaxMB, PreviewCacheMaxItems, PreviewCacheItemMaxKB
    global PreviewCacheUnreferencedDays
    global PreviewDirectImageMaxFileMB, PreviewDirectImageMaxEdge
    global PreviewDirectImageMaxPixelsMP, PreviewDirectImageMaxExpandedMB
    global PreviewDocumentThemeVersion
    if IsObject(ThumbnailNativePreviewJob) || !IsObject(task)
        return false
    if !EnsureNativeThumbnailPreviewHelper() {
        RegisterNativeThumbnailTransportFailure("helper-start")
        return false
    }

    edge := Max(16, Min(512, task.ImageEdge))
    generation := ++ThumbnailNativePreviewGeneration
    requestId := ++ThumbnailNativePreviewRequestSerial
    cacheRoot := CacheDir "\preview-cache-v1"
    cacheEnabled := !!CacheWritable
    dpi := DllCall("user32\GetDpiForWindow", "ptr", task.ViewHwnd, "uint")
    if !dpi
        dpi := 96

    mapView := ThumbnailNativePreviewMapView
    if !mapView || !ThumbnailNativePreviewRequestEvent
        return false
    DllCall("kernel32\ResetEvent", "ptr",
        ThumbnailNativePreviewResponseEvent)
    NumPut("uint", command, mapView, 8)
    NumPut("uint", 0, mapView, 12)
    NumPut("int64", generation, mapView, 16)
    NumPut("int64", task.Generation, mapView, 24)
    NumPut("int64", task.ViewHwnd, mapView, 32)
    NumPut("int64", requestId, mapView, 40)
    NumPut("uint", edge, mapView, 48)
    NumPut("uint", edge, mapView, 52)
    NumPut("uint", PreviewDirectImageMaxFileMB, mapView, 56)
    NumPut("uint", PreviewDirectImageMaxEdge, mapView, 60)
    NumPut("uint", PreviewDirectImageMaxPixelsMP, mapView, 64)
    NumPut("uint", PreviewDirectImageMaxExpandedMB, mapView, 68)
    NumPut("uint", cacheEnabled ? 1 : 0, mapView, 72)
    NumPut("uint", PreviewCacheMaxMB, mapView, 76)
    NumPut("uint", PreviewCacheMaxItems, mapView, 80)
    NumPut("uint", PreviewCacheItemMaxKB, mapView, 84)
    NumPut("uint", PreviewCacheUnreferencedDays, mapView, 88)
    ; Native preview cache keys use a minimum 180 px bucket. The response is
    ; still bounded to the exact ListView ImageList edge above.
    NumPut("uint", Max(180, edge), mapView, 92)
    NumPut("uint", Max(96, Min(480, dpi)), mapView, 96)
    NumPut("uint", PreviewDocumentThemeVersion, mapView, 100)
    StrPut(task.Path, mapView + 256, 32768, "UTF-16")
    StrPut(cacheRoot, mapView + 65792, 4096, "UTF-16")
    ThumbnailNativePreviewJob := {
        Task: task, Command: command, Generation: generation,
        RequestId: requestId, StartedTick: A_TickCount
    }
    DllCall("kernel32\SetEvent", "ptr", ThumbnailNativePreviewRequestEvent)
    SetTimer(PollNativeThumbnailPreview, 30)
    return true
}

EnsureNativeThumbnailPreviewHelper() {
    global ThumbnailNativePreviewMapHandle, ThumbnailNativePreviewMapView
    global ThumbnailNativePreviewRequestEvent
    global ThumbnailNativePreviewResponseEvent
    global ThumbnailNativePreviewShutdownEvent
    global ThumbnailNativePreviewHelperPid, ThumbnailNativePreviewObjectBase
    if ThumbnailNativePreviewHelperPid
        && ProcessExist(ThumbnailNativePreviewHelperPid)
        return true
    CleanupNativeThumbnailPreviewHelper(false)
    token := Format("{:08X}{:08X}{:08X}", A_TickCount,
        DllCall("kernel32\GetCurrentProcessId", "uint"),
        Random(0, 0x7FFFFFFF))
    ThumbnailNativePreviewObjectBase := "Local\PopDropThumbnail-" token
    ThumbnailNativePreviewMapHandle := DllCall(
        "kernel32\CreateFileMappingW", "ptr", -1, "ptr", 0,
        "uint", 0x04, "uint", 0, "uint", 4268288,
        "wstr", ThumbnailNativePreviewObjectBase "-Map", "ptr")
    if ThumbnailNativePreviewMapHandle
        ThumbnailNativePreviewMapView := DllCall(
            "kernel32\MapViewOfFile", "ptr", ThumbnailNativePreviewMapHandle,
            "uint", 0xF001F, "uint", 0, "uint", 0,
            "uptr", 4268288, "ptr")
    ThumbnailNativePreviewRequestEvent := DllCall(
        "kernel32\CreateEventW", "ptr", 0, "int", 0, "int", 0,
        "wstr", ThumbnailNativePreviewObjectBase "-Request", "ptr")
    ThumbnailNativePreviewResponseEvent := DllCall(
        "kernel32\CreateEventW", "ptr", 0, "int", 0, "int", 0,
        "wstr", ThumbnailNativePreviewObjectBase "-Response", "ptr")
    ThumbnailNativePreviewShutdownEvent := DllCall(
        "kernel32\CreateEventW", "ptr", 0, "int", 1, "int", 0,
        "wstr", ThumbnailNativePreviewObjectBase "-Shutdown", "ptr")
    if !ThumbnailNativePreviewMapView || !ThumbnailNativePreviewRequestEvent
        || !ThumbnailNativePreviewResponseEvent
        || !ThumbnailNativePreviewShutdownEvent {
        CleanupNativeThumbnailPreviewHelper(false)
        return false
    }
    NumPut("uint", 0x56504450, ThumbnailNativePreviewMapView, 0)
    NumPut("uint", 5, ThumbnailNativePreviewMapView, 4)
    helperPath := A_ScriptDir "\native\bin\"
        . (A_PtrSize = 8 ? "x64" : "x86") "\PopDropPreview.exe"
    if !FileExist(helperPath) {
        CleanupNativeThumbnailPreviewHelper(false)
        return false
    }
    pid := 0
    try Run('"' helperPath '" --shared "'
        ThumbnailNativePreviewObjectBase '"', A_ScriptDir, "Hide", &pid)
    catch {
        CleanupNativeThumbnailPreviewHelper(false)
        return false
    }
    ThumbnailNativePreviewHelperPid := pid
    AssignNativeThumbnailPreviewJob()
    return true
}

AssignNativeThumbnailPreviewJob() {
    global ThumbnailNativePreviewJobHandle, ThumbnailNativePreviewHelperPid
    ThumbnailNativePreviewJobHandle := DllCall(
        "kernel32\CreateJobObjectW", "ptr", 0, "ptr", 0, "ptr")
    if !ThumbnailNativePreviewJobHandle
        return false
    size := A_PtrSize = 8 ? 144 : 112
    info := Buffer(size, 0)
    NumPut("uint", 0x2100, info, 16)
        ; JOB_OBJECT_LIMIT_PROCESS_MEMORY | KILL_ON_JOB_CLOSE
    NumPut("uptr", 512 * 1024 * 1024, info, A_PtrSize = 8 ? 112 : 96)
    if !DllCall("kernel32\SetInformationJobObject", "ptr",
        ThumbnailNativePreviewJobHandle, "int", 9,
        "ptr", info.Ptr, "uint", size, "int")
        return false
    process := DllCall("kernel32\OpenProcess", "uint", 0x0501,
        "int", 0, "uint", ThumbnailNativePreviewHelperPid, "ptr")
    if !process
        return false
    assigned := DllCall("kernel32\AssignProcessToJobObject", "ptr",
        ThumbnailNativePreviewJobHandle, "ptr", process, "int")
    DllCall("kernel32\CloseHandle", "ptr", process)
    return !!assigned
}

PollNativeThumbnailPreview() {
    global ThumbnailNativePreviewJob, ThumbnailNativePreviewResponseEvent
    global ThumbnailNativePreviewMapView, ThumbnailNativePreviewHelperPid
    if !IsObject(ThumbnailNativePreviewJob) {
        SetTimer(PollNativeThumbnailPreview, 0)
        return
    }
    job := ThumbnailNativePreviewJob
    ready := ThumbnailNativePreviewResponseEvent
        && DllCall("kernel32\WaitForSingleObject", "ptr",
            ThumbnailNativePreviewResponseEvent, "uint", 0, "uint") = 0
    timeoutMs := job.Command = 2 ? 12000 : 5000
    timedOut := ElapsedTickMilliseconds(job.StartedTick, A_TickCount)
        >= timeoutMs
    running := ThumbnailNativePreviewHelperPid
        && ProcessExist(ThumbnailNativePreviewHelperPid)
    if !ready && running && !timedOut
        return
    if !ready {
        if running
            try ProcessClose(ThumbnailNativePreviewHelperPid)
        RegisterNativeThumbnailTransportFailure(
            timedOut ? "timeout" : "helper-exit")
        ThumbnailNativePreviewJob := 0
        CleanupNativeThumbnailPreviewHelper(false)
        if RetryNativeThumbnailTransport(job.Task)
            return
        FinishNativeThumbnailPreview()
        return
    }
    RegisterNativeThumbnailTransportSuccess()
    response := TakeNativeThumbnailResponse(job)
    ThumbnailNativePreviewJob := 0
    if !IsObject(response) {
        FinishNativeThumbnailPreview()
        return
    }
    if job.Command = 1 && response.Status = 2
        && IsObject(response.Pixels) {
        applied := false
        try applied := ApplyNativeThumbnailResponse(job.Task, response)
        catch as err {
            QueueWorkspacePerformanceTrace("thumbnail",
                "apply-exception=" err.What)
        }
        if !applied
            QueueWorkspacePerformanceTrace("thumbnail", "apply=stale-or-failed")
        FinishNativeThumbnailPreview()
        return
    }
    if job.Command = 1 && job.Task.NativeStage = "Probe"
        && NativeThumbnailMayGenerate(response.Status) {
        job.Task.NativeStage := "Generate"
        try started := BeginNativeThumbnailPreview(job.Task, 2)
        catch as err {
            started := false
            RegisterNativeThumbnailTransportFailure(
                "generate-exception:" err.What)
        }
        if started
            return
    } else if job.Command = 2 && response.Status = 2 {
        job.Task.NativeStage := "Cached"
        try started := BeginNativeThumbnailPreview(job.Task, 1)
        catch as err {
            started := false
            RegisterNativeThumbnailTransportFailure(
                "readback-exception:" err.What)
        }
        if started
            return
    } else if response.Status = 2 && !IsObject(response.Pixels) {
        RegisterNativeThumbnailTransportFailure("invalid-pixels")
    }
    FinishNativeThumbnailPreview()
}

NativeThumbnailMayGenerate(status) {
    global CacheWritable
    return CacheWritable && (status = 3 || status = 4 || status = 8)
}

TakeNativeThumbnailResponse(job) {
    global ThumbnailNativePreviewMapView
    mapView := ThumbnailNativePreviewMapView
    if !mapView
        return 0
    if NumGet(mapView, 16, "int64") != job.Generation
        || NumGet(mapView, 40, "int64") != job.RequestId
        return 0
    response := {
        Status: NumGet(mapView, 12, "uint"),
        Width: NumGet(mapView, 128, "uint"),
        Height: NumGet(mapView, 132, "uint"),
        Stride: NumGet(mapView, 136, "uint"),
        Pixels: 0
    }
    if response.Status != 2
        return response
    if !NativeThumbnailPixelLayoutValid(
        response.Width, response.Height, response.Stride)
        return response
    bytes := response.Stride * response.Height
    pixels := Buffer(bytes, 0)
    DllCall("ntdll\RtlMoveMemory", "ptr", pixels.Ptr,
        "ptr", mapView + 73984, "uptr", bytes)
    response.Pixels := pixels
    return response
}

NativeThumbnailPixelLayoutValid(width, height, stride) {
    if !width || !height || !stride || width > 1048576
        return false
    widthBytes := width * 4
    if stride < widthBytes
        return false
    return height <= Floor(4194304 / stride)
}

ApplyNativeThumbnailResponse(task, response) {
    global ActiveWorkspaceId, FileView, ItemPaths, ThumbnailEnhanceGeneration
    global ThumbnailIconCache, WorkspaceFileViewStates
    if StrLower(task.WorkspaceId) = StrLower(ActiveWorkspaceId)
        && IsObject(FileView) && FileView.Hwnd = task.ViewHwnd
        && task.Generation = ThumbnailEnhanceGeneration
        && ItemPaths.Has(task.Row)
        && PathKey(ItemPaths[task.Row]) = PathKey(task.Path) {
        imageIndex := AddNativeThumbnailPixels(response.Pixels,
            response.Width, response.Height, response.Stride,
            task.ImageList, task.ImageEdge)
        if imageIndex {
            FileView.Modify(task.Row, "Icon" imageIndex)
            InvalidateNativeListRow(FileView.Hwnd, task.Row)
            if task.CacheKey != ""
                ThumbnailIconCache[task.CacheKey] := {
                    Index: imageIndex, Cached: true}
            return true
        }
        return false
    }
    key := StrLower(task.WorkspaceId)
    if !WorkspaceFileViewStates.Has(key)
        return false
    state := WorkspaceFileViewStates[key]
    if !IsObject(state.Control) || state.Control.Hwnd != task.ViewHwnd
        || state.EnhanceGeneration != task.Generation
        || !state.ItemPaths.Has(task.Row)
        || PathKey(state.ItemPaths[task.Row]) != PathKey(task.Path)
        return false
    imageIndex := AddNativeThumbnailPixels(response.Pixels,
        response.Width, response.Height, response.Stride,
        state.ImageList, state.ImageListEdge)
    if !imageIndex
        return false
    state.Control.Modify(task.Row, "Icon" imageIndex)
    InvalidateNativeListRow(state.Control.Hwnd, task.Row)
    if task.CacheKey != ""
        state.IconCache[task.CacheKey] := {Index: imageIndex, Cached: true}
    return true
}

InvalidateNativeListRow(hwnd, row) {
    if !hwnd || row < 1 || !DllCall("user32\IsWindow", "ptr", hwnd, "int")
        return false
    rect := Buffer(16, 0)
    NumPut("int", 0, rect, 0) ; LVIR_BOUNDS
    if !DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x100E, "ptr", row - 1, "ptr", rect.Ptr, "ptr")
        return false
    DllCall("user32\InvalidateRect", "ptr", hwnd,
        "ptr", rect.Ptr, "int", 0)
    return true
}

AddNativeThumbnailPixels(pixels, width, height, stride, imageList, edge) {
    if !IsObject(pixels) || !imageList || edge < 1
        || width < 1 || height < 1 || width > edge || height > edge
        return 0
    info := Buffer(40, 0)
    NumPut("uint", 40, info, 0)
    NumPut("int", edge, info, 4)
    NumPut("int", -edge, info, 8)
    NumPut("ushort", 1, info, 12)
    NumPut("ushort", 32, info, 14)
    screenDc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    bits := 0
    bitmap := DllCall("gdi32\CreateDIBSection", "ptr", screenDc,
        "ptr", info.Ptr, "uint", 0, "ptr*", &bits,
        "ptr", 0, "uint", 0, "ptr")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !bitmap || !bits {
        if bitmap
            DllCall("gdi32\DeleteObject", "ptr", bitmap)
        return 0
    }
    targetStride := edge * 4
    DllCall("ntdll\RtlZeroMemory", "ptr", bits,
        "uptr", targetStride * edge)
    offsetX := Floor((edge - width) / 2)
    offsetY := Floor((edge - height) / 2)
    rowBytes := width * 4
    Loop height
        DllCall("ntdll\RtlMoveMemory",
            "ptr", bits + (offsetY + A_Index - 1) * targetStride
                + offsetX * 4,
            "ptr", pixels.Ptr + (A_Index - 1) * stride,
            "uptr", rowBytes)
    imageIndex := DllCall("comctl32\ImageList_Add", "ptr", imageList,
        "ptr", bitmap, "ptr", 0, "int")
    DllCall("gdi32\DeleteObject", "ptr", bitmap)
    return imageIndex >= 0 ? imageIndex + 1 : 0
}

FinishNativeThumbnailPreview() {
    global ThumbnailEnhanceQueue
    if ThumbnailEnhanceQueue.Length
        SetTimer(EnhanceNextThumbnail, -30)
}

RetryNativeThumbnailTransport(task) {
    global ThumbnailEnhanceQueue
    retries := HasProp(task, "NativeTransportRetries")
        ? task.NativeTransportRetries : 0
    if retries >= 1
        return false
    task.NativeTransportRetries := retries + 1
    task.NativeStage := "Probe"
    ThumbnailEnhanceQueue.InsertAt(1, task)
    SetTimer(EnhanceNextThumbnail, -250)
    return true
}

CleanupNativeThumbnailPreviewHelper(signalShutdown := true) {
    global ThumbnailNativePreviewJob, ThumbnailNativePreviewMapHandle
    global ThumbnailNativePreviewMapView, ThumbnailNativePreviewRequestEvent
    global ThumbnailNativePreviewResponseEvent
    global ThumbnailNativePreviewShutdownEvent
    global ThumbnailNativePreviewHelperPid, ThumbnailNativePreviewJobHandle
    SetTimer(PollNativeThumbnailPreview, 0)
    ThumbnailNativePreviewJob := 0
    if signalShutdown && ThumbnailNativePreviewShutdownEvent
        DllCall("kernel32\SetEvent", "ptr",
            ThumbnailNativePreviewShutdownEvent)
    if ThumbnailNativePreviewMapView
        DllCall("kernel32\UnmapViewOfFile", "ptr",
            ThumbnailNativePreviewMapView)
    for handle in [ThumbnailNativePreviewRequestEvent,
        ThumbnailNativePreviewResponseEvent,
        ThumbnailNativePreviewShutdownEvent,
        ThumbnailNativePreviewMapHandle,
        ThumbnailNativePreviewJobHandle] {
        if handle
            DllCall("kernel32\CloseHandle", "ptr", handle)
    }
    ThumbnailNativePreviewMapHandle := 0
    ThumbnailNativePreviewMapView := 0
    ThumbnailNativePreviewRequestEvent := 0
    ThumbnailNativePreviewResponseEvent := 0
    ThumbnailNativePreviewShutdownEvent := 0
    ThumbnailNativePreviewHelperPid := 0
    ThumbnailNativePreviewJobHandle := 0
}

BeginThumbnailCacheWorker(tasks) {
    global ThumbnailCacheWorkerJob, ThumbnailCacheWorkerGeneration
    global CacheDir, CacheWritable, ThumbnailImageListEdge
    if IsObject(ThumbnailCacheWorkerJob)
        return false
    ipcDir := CacheWritable ? CacheDir : A_Temp "\PopDrop"
    try DirCreate(ipcDir)
    generation := "thumbnail-" Format("{:016X}-{:08X}", A_TickCount,
        ++ThumbnailCacheWorkerGeneration)
    requestPath := ipcDir "\" generation ".request.ini"
    readyPath := ipcDir "\" generation ".ready.ini"
    readyWritingPath := readyPath ".writing"
    try {
        try FileDelete(requestPath)
        try FileDelete(readyPath)
        try FileDelete(readyWritingPath)
        IniWrite(tasks.Length, requestPath, "Thumbnail", "Count")
        IniWrite(Max(16, ThumbnailImageListEdge), requestPath,
            "Thumbnail", "Size")
        for index, task in tasks
            IniWrite(task.Path, requestPath, "Thumbnail",
                "Path" Format("{:03}", index))
        pid := StartThumbnailCacheWorkerProcess(requestPath, readyPath)
        ThumbnailCacheWorkerJob := {
            Pid: pid, RequestPath: requestPath, ReadyPath: readyPath,
            ReadyWritingPath: readyWritingPath,
            StartedTick: A_TickCount, Tasks: tasks}
        SetTimer(PollThumbnailCacheWorker, 75)
        return true
    } catch {
        try FileDelete(requestPath)
        try FileDelete(readyPath)
        try FileDelete(readyWritingPath)
        return false
    }
}

StartThumbnailCacheWorkerProcess(requestPath, readyPath) {
    if A_IsCompiled {
        executable := A_ScriptFullPath
        arguments := [A_ScriptFullPath, "--thumbnail-cache-worker",
            requestPath, readyPath]
    } else {
        executable := A_AhkPath
        arguments := [A_AhkPath, A_ScriptFullPath,
            "--thumbnail-cache-worker", requestPath, readyPath]
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
        throw OSError(A_LastError, "无法启动缩略图缓存进程")
    processHandle := NumGet(processInfo, 0, "ptr")
    threadHandle := NumGet(processInfo, A_PtrSize, "ptr")
    pid := NumGet(processInfo, A_PtrSize * 2, "uint")
    if threadHandle
        DllCall("kernel32\CloseHandle", "ptr", threadHandle)
    if processHandle
        DllCall("kernel32\CloseHandle", "ptr", processHandle)
    return pid
}

RunThumbnailCacheWorkerMode(requestPath, readyPath) {
    initialized := DllCall("ole32\CoInitializeEx", "ptr", 0,
        "uint", 0, "int") >= 0
    results := []
    readyWritingPath := readyPath ".writing"
    try {
        count := Max(0, Min(16, Integer(IniRead(
            requestPath, "Thumbnail", "Count", "0"))))
        try size := Integer(IniRead(
            requestPath, "Thumbnail", "Size", "96"))
        catch
            size := 96
        Loop count {
            path := IniRead(requestPath, "Thumbnail",
                "Path" Format("{:03}", A_Index), "")
            results.Push(path != "" && WarmShellThumbnailCache(path,
                Max(16, Min(size, 512))))
        }
    } catch {
        results := []
    } finally {
        try {
            try FileDelete(readyWritingPath)
            IniWrite(results.Length, readyWritingPath, "Result", "Count")
            for index, success in results
                IniWrite(success ? "1" : "0", readyWritingPath,
                    "Result", "Success" Format("{:03}", index))
            FileMove(readyWritingPath, readyPath, 1)
        }
        if initialized
            DllCall("ole32\CoUninitialize")
    }
    return results.Length > 0
}

WarmShellThumbnailCache(path, size) {
    factory := 0
    bitmap := 0
    try {
        iidImageFactory := GuidBuffer(
            "{BCC18B79-BA16-442F-80C4-8A59C30C463B}")
        if DllCall("shell32\SHCreateItemFromParsingName", "wstr", path,
            "ptr", 0, "ptr", iidImageFactory.Ptr,
            "ptr*", &factory, "int") != 0
            return false
        requestedSize := (size & 0xFFFFFFFF) | (size << 32)
        ; SIIGBF_BIGGERSIZEOK. This potentially expensive call is isolated in
        ; the worker process and only warms Windows' thumbnail cache.
        hr := ComCall(3, factory, "int64", requestedSize,
            "uint", 0x20, "ptr*", &bitmap)
        return hr = 0 && bitmap
    } finally {
        if bitmap
            DllCall("gdi32\DeleteObject", "ptr", bitmap)
        if factory
            ObjRelease(factory)
    }
}

PollThumbnailCacheWorker() {
    global ThumbnailCacheWorkerJob, WorkspaceFileViewStates
    global ActiveWorkspaceId, FileView, ItemPaths
    global ThumbnailEnhanceGeneration, ThumbnailEnhanceQueue
    global ThumbnailIconCache, PanelVisible, ThumbnailCacheImportQueue
    if !IsObject(ThumbnailCacheWorkerJob) {
        SetTimer(PollThumbnailCacheWorker, 0)
        return
    }
    job := ThumbnailCacheWorkerJob
    ready := FileExist(job.ReadyPath)
    timedOut := A_TickCount - job.StartedTick > 15000
    running := job.Pid && ProcessExist(job.Pid)
    if !ready && running && !timedOut
        return
    if timedOut && running
        try ProcessClose(job.Pid)
    try FileDelete(job.RequestPath)
    for index, task in job.Tasks {
        success := ready && IniRead(job.ReadyPath, "Result",
            "Success" Format("{:03}", index), "0") = "1"
        if success {
            task.Warmed := true
            ThumbnailCacheImportQueue.Push(task)
        }
    }
    try FileDelete(job.ReadyPath)
    try FileDelete(job.ReadyWritingPath)
    ThumbnailCacheWorkerJob := 0
    SetTimer(PollThumbnailCacheWorker, 0)
    if !PanelVisible && ThumbnailCacheImportQueue.Length
        SetTimer(ImportNextWarmedThumbnail, -1)
    if !PanelVisible && ThumbnailEnhanceQueue.Length
        SetTimer(EnhanceNextThumbnail, -15)
}

ImportNextWarmedThumbnail() {
    global ThumbnailCacheImportQueue, WorkspaceFileViewStates
    global ActiveWorkspaceId, FileView, ItemPaths
    global ThumbnailEnhanceGeneration, ThumbnailIconCache
    global PanelVisible
    if PanelVisible || !ThumbnailCacheImportQueue.Length
        return
    ; Import exactly one cached bitmap per timer turn. Even cache-only Shell
    ; parsing must not form a 16-item uninterruptible burst ahead of Tab input.
    task := ThumbnailCacheImportQueue.RemoveAt(1)
    if StrLower(task.WorkspaceId) = StrLower(ActiveWorkspaceId)
        && IsObject(FileView) && FileView.Hwnd = task.ViewHwnd
        && task.Generation = ThumbnailEnhanceGeneration
        && ItemPaths.Has(task.Row)
        && PathKey(ItemPaths[task.Row]) = PathKey(task.Path) {
        imageIndex := AddShellThumbnailBitmap(task.Path, true)
        if imageIndex {
            FileView.Modify(task.Row, "Icon" imageIndex)
            if task.CacheKey != ""
                ThumbnailIconCache[task.CacheKey] := {
                    Index: imageIndex, Cached: true}
        }
    } else {
        key := StrLower(task.WorkspaceId)
        if WorkspaceFileViewStates.Has(key) {
            state := WorkspaceFileViewStates[key]
            if state.Control.Hwnd = task.ViewHwnd
                state.EnhanceQueue.InsertAt(1, task)
        }
    }
    if ThumbnailCacheImportQueue.Length
        SetTimer(ImportNextWarmedThumbnail, -15)
}

CleanupThumbnailCacheWorker() {
    global ThumbnailCacheWorkerJob, ThumbnailCacheImportQueue
    CleanupNativeThumbnailPreviewHelper()
    SetTimer(PollThumbnailCacheWorker, 0)
    SetTimer(ImportNextWarmedThumbnail, 0)
    ThumbnailCacheImportQueue := []
    if !IsObject(ThumbnailCacheWorkerJob)
        return
    job := ThumbnailCacheWorkerJob
    if job.Pid && ProcessExist(job.Pid)
        try ProcessClose(job.Pid)
    try FileDelete(job.RequestPath)
    try FileDelete(job.ReadyPath)
    try FileDelete(job.ReadyWritingPath)
    ThumbnailCacheWorkerJob := 0
}

AddShellFileIcon(path, isDirectory := -1) {
    global ThumbnailImageList, ThumbnailIconCache
    if isDirectory < 0
        isDirectory := !!DirExist(path)
    SplitPath(path, , , &extension)
    extension := StrLower(extension)
    ; Every file uses a type icon on the synchronous path. Executable,
    ; shortcut and custom file icons are supplied by the thumbnail worker.
    pathSpecific := isDirectory
    iconKey := "__popdrop-shell-icon__|"
        . (isDirectory ? "folder|" PathKey(path)
            : pathSpecific ? "path|" PathKey(path)
            : "type|" extension)
    if ThumbnailIconCache.Has(iconKey) {
        cached := ThumbnailIconCache[iconKey]
        if IsObject(cached) && cached.Index
            return cached.Index
    }
    infoSize := A_PtrSize = 8 ? 696 : 692
    info := Buffer(infoSize, 0)
    lookupPath := path
    attributes := 0
    flags := 0x100 ; SHGFI_ICON | SHGFI_LARGEICON
    if !pathSpecific {
        lookupPath := "PopDrop." (extension != "" ? extension : "file")
        attributes := 0x80 ; FILE_ATTRIBUTE_NORMAL
        flags |= 0x10 ; SHGFI_USEFILEATTRIBUTES
    }
    if !DllCall("shell32\SHGetFileInfoW", "wstr", lookupPath,
        "uint", attributes,
        "ptr", info.Ptr, "uint", infoSize, "uint", flags, "uptr")
        return 0
    icon := NumGet(info, 0, "ptr")
    if !icon
        return 0
    imageIndex := DllCall("comctl32\ImageList_ReplaceIcon", "ptr", ThumbnailImageList,
        "int", -1, "ptr", icon, "int")
    DllCall("user32\DestroyIcon", "ptr", icon)
    result := imageIndex >= 0 ? imageIndex + 1 : 0
    if result
        ThumbnailIconCache[iconKey] := {Index: result, Cached: true}
    return result
}

PopulateRecentSidebar() {
    global RecentView, RecentLabel, RecentItemPaths, ShowRecentSidebar, CurrentScanResult
    global RecentRenderSignature
    PreviewInvalidateList("recent")
    RecentView.Opt("-Redraw")
    RecentView.Delete()
    RecentItemPaths := Map()
    if !ShowRecentSidebar {
        RecentView.Opt("+Redraw")
        RecentRenderSignature := ComputeRecentRenderSignature()
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
    RecentView.ModifyCol(1, PanelScale(230))
    RecentView.Modify(0, "-Select -Focus")
    RecentView.Opt("+Redraw")
    DllCall("user32\RedrawWindow", "ptr", RecentView.Hwnd, "ptr", 0, "ptr", 0,
        "uint", 0x0001 | 0x0080 | 0x0100, "int")
    RecentRenderSignature := ComputeRecentRenderSignature()
}

ComputePanelRenderSignature() {
    global ActiveWorkspaceId, CurrentConfigFingerprint, CurrentScanResult
    global PinnedPaths, ViewMode, ThumbnailSize
    global TextBlockSearchQuery, TextBlockSearchTitleOnly
    titleOnly := IsTextWorkspace() && TextBlockSearchTitleOnly
    return StrLower(ActiveWorkspaceId) "|" CurrentConfigFingerprint
        . "|" ResultSignature({Folders: CurrentScanResult.Folders, Recent: []})
        . "|p=" JoinNormalizedPaths(PinnedPaths)
        . "|v=" ViewMode "|t=" ThumbnailSize
        . "|q=" TextBlockSearchQuery
        . "|titleOnly=" (titleOnly ? 1 : 0)
}

IsPanelRenderCurrent() {
    global PanelRenderSignature
    return PanelRenderSignature != ""
        && PanelRenderSignature = ComputePanelRenderSignature()
}

ComputeRecentRenderSignature() {
    global ActiveWorkspaceId, CurrentScanResult, ShowRecentSidebar
    signature := StrLower(ActiveWorkspaceId) "|" (ShowRecentSidebar ? 1 : 0)
    for item in CurrentScanResult.Recent
        signature .= "|" item.Path "@" item.Modified
    return signature
}

IsRecentRenderCurrent() {
    global RecentRenderSignature
    return RecentRenderSignature != ""
        && RecentRenderSignature = ComputeRecentRenderSignature()
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
        if target = ""
            continue
        ; Never probe an UNC/WebDAV/mapped-network target on the scan critical
        ; path. A disconnected provider can hold FileExist for many seconds.
        ; The shortcut remains useful and is validated only when opened.
        if !IsPotentiallyRemotePath(target) {
            attributes := FileExist(target)
            if !attributes || InStr(attributes, "D")
                continue
        }
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

IsPotentiallyRemotePath(path) {
    if SubStr(path, 1, 2) = "\\"
        return true
    if RegExMatch(path, "i)^[A-Z]:\\") {
        driveType := DllCall("kernel32\GetDriveTypeW", "wstr", SubStr(path, 1, 3),
            "uint")
        return driveType = 4 ; DRIVE_REMOTE
    }
    return RegExMatch(path, "i)^(?:https?|ftp|webdav):") != 0
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
        && IsIncompleteDownloadFileName(fileName)
        return {Include: false, Reason: "IncompleteDownload"}
    if MatchesCompiledIgnorePattern(fileName, noiseFilter.CustomPatterns)
        return {Include: false, Reason: "CustomPattern"}
    if MatchesCompiledIgnorePattern(fileName, noiseFilter.SourceCustomPatterns)
        return {Include: false, Reason: "SourceCustomPattern"}
    return {Include: true, Reason: ""}
}

IsIncompleteDownloadFileName(fileName) {
    ; Deliberately exclude .torrent: it is normal metadata, not an unfinished
    ; payload. These suffixes cover browsers, aria2, Thunder/Xunlei and common
    ; BitTorrent clients without treating every generic .tmp file as a download.
    static suffixes := [
        ".crdownload", ".part", ".download", ".opdownload", ".partial",
        ".aria2", ".td", ".td.cfg", ".xltd", ".bt", ".bc!", ".!ut", ".!qb"
    ]
    folded := StrLower(fileName)
    for suffix in suffixes {
        if StrLen(folded) >= StrLen(suffix)
            && SubStr(folded, StrLen(folded) - StrLen(suffix) + 1) = suffix
            return true
    }
    return false
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

; ──── 后台扫描、缓存与 worker IPC ────

RunScanWorkerMode() {
    if A_Args.Length < 3
        return
    requestPath := A_Args[2]
    readyPath := A_Args[3]
    try {
        request := ReadWorkerRequest(requestPath)
        pinnedSet := BuildPathSet(request.PinnedPaths)
        if !DirExist(readyPath)
            DirCreate(readyPath)
        scannedCount := 0
        scanOrder := []
        for index, folder in request.Folders {
            if folder.Scan && !IsPotentiallyRemotePath(folder.Path)
                scanOrder.Push({Index: index, Folder: folder})
        }
        for index, folder in request.Folders {
            if folder.Scan && IsPotentiallyRemotePath(folder.Path)
                scanOrder.Push({Index: index, Folder: folder})
        }
        for task in scanOrder {
            index := task.Index
            folder := task.Folder
            diagnostics := {Count: 0, Items: [], Seen: Map()}
            state := DirExist(folder.Path) ? "OK" : "Unavailable"
            files := state = "OK" ? GetSortedItems(folder.Path,
                folder.MaxFilesPerFolder, folder.DisplayScope, folder.SortMode,
                folder.Filter, folder.FolderTimeMode,
                request.GlobalExcludedNames, folder.ExcludedPaths,
                folder.AllowedExcludedPaths, folder.NoiseFilter,
                pinnedSet, folder.Name, diagnostics) : []
            partial := {Version: 5, Generation: request.Generation,
                Fingerprint: request.Fingerprint,
                WorkspaceId: request.WorkspaceId, SourceIndex: index,
                Kind: "Source", Folders: [{Name: folder.Name,
                    Path: folder.Path, State: state, Files: files}], Recent: [],
                HiddenCount: diagnostics.Count, HiddenItems: diagnostics.Items}
            WriteScanResultAtomic(partial, readyPath "\source-"
                . Format("{:04}", index) ".ini")
            scannedCount += 1
        }
        if request.IncludeRecent {
            recentResult := {Version: 5, Generation: request.Generation,
                Fingerprint: request.Fingerprint,
                WorkspaceId: request.WorkspaceId, SourceIndex: 0,
                Kind: "Recent", Folders: [],
                Recent: GetWindowsRecentFiles(request.RecentFileCount),
                HiddenCount: 0, HiddenItems: []}
            WriteScanResultAtomic(recentResult, readyPath "\recent.ini")
        }
        WriteWorkerCompletionAtomic(readyPath "\complete.ini", request,
            scannedCount)
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
        try FileDelete(readyPath "\complete.ini.writing")
    }
}

ReadWorkerRequest(path) {
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    version := Integer(IniRead(path, "Meta", "Version", "0"))
    if version != 6
        throw Error("unsupported request version")
    request := {Generation: IniRead(path, "Meta", "Generation", ""),
        Fingerprint: IniRead(path, "Meta", "Fingerprint", ""),
        WorkspaceId: IniRead(path, "Meta", "WorkspaceId", ""), Folders: [],
        RecentFileCount: Integer(IniRead(path, "Meta", "RecentFileCount", "12")),
        IncludeRecent: IniRead(path, "Meta", "IncludeRecent", "0") = "1",
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
            HideTemporary: IniRead(path, section, "HideTemporaryAttribute", "1") = "1",
            HideIncompleteDownloads: IniRead(path, section, "HideIncompleteDownloads", "1") = "1",
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
            AllowedExcludedPaths: allowedPaths,
            Scan: IniRead(path, section, "Scan", "1") = "1"
        })
    }
    return request
}

WriteScanResultAtomic(result, readyPath, includeDiagnostics := true) {
    global CurrentConfigFingerprint, ActiveWorkspaceId
    tempPath := readyPath ".writing"
    try FileDelete(tempPath)
    try FileDelete(readyPath)
    IniWrite("5", tempPath, "Meta", "Version")
    IniWrite(HasProp(result, "Generation") ? result.Generation : "cache",
        tempPath, "Meta", "Generation")
    IniWrite(HasProp(result, "Fingerprint") ? result.Fingerprint
        : CurrentConfigFingerprint, tempPath, "Meta", "Fingerprint")
    IniWrite(HasProp(result, "WorkspaceId") ? result.WorkspaceId
        : ActiveWorkspaceId, tempPath, "Meta", "WorkspaceId")
    IniWrite(HasProp(result, "Kind") ? result.Kind : "Snapshot",
        tempPath, "Meta", "Kind")
    IniWrite(HasProp(result, "SourceIndex") ? result.SourceIndex : 0,
        tempPath, "Meta", "SourceIndex")
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

WriteWorkerCompletionAtomic(path, request, scannedCount) {
    tempPath := path ".writing"
    try FileDelete(tempPath)
    IniWrite("1", tempPath, "Meta", "Version")
    IniWrite(request.Generation, tempPath, "Meta", "Generation")
    IniWrite(request.Fingerprint, tempPath, "Meta", "Fingerprint")
    IniWrite(request.WorkspaceId, tempPath, "Meta", "WorkspaceId")
    IniWrite(scannedCount, tempPath, "Meta", "ScannedCount")
    IniWrite(A_Now, tempPath, "Meta", "CompletedAt")
    FileMove(tempPath, path, 1)
}

ResolveCacheDirectory(setting) {
    global DataRootDir
    setting := NormalizePath(setting)
    candidates := []
    if setting != ""
        candidates.Push(setting)
    else if IsSet(DataRootDir) && DataRootDir != ""
        candidates.Push(DataRootDir "\cache")
    else
        candidates.Push(A_ScriptDir "\cache")
    localAppData := EnvGet("LOCALAPPDATA")
    if localAppData = ""
        localAppData := A_AppData
    fallback := localAppData "\PopDrop\cache"
    if !ArrayContainsPath(candidates, fallback)
        candidates.Push(fallback)
    for candidate in candidates {
        ; Keep the transactional runtime cache off UNC/mapped network drives.
        if !IsPotentiallyRemotePath(candidate) && EnsureCacheDirectory(candidate)
            return candidate
    }
    return fallback
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

ComputeConfigFingerprint(settings, workspaceIdOverride := "",
    workspaceTypeOverride := "", pinnedPathsOverride := 0) {
    global RecentFileCount, GlobalExcludedFolderNames, GlobalNoiseFilter, PinnedPaths
    global ActiveWorkspaceId, ActiveWorkspaceType
    workspaceId := workspaceIdOverride != ""
        ? workspaceIdOverride : ActiveWorkspaceId
    workspaceType := workspaceTypeOverride != ""
        ? workspaceTypeOverride : ActiveWorkspaceType
    pinnedPaths := IsObject(pinnedPathsOverride)
        ? pinnedPathsOverride : PinnedPaths
    raw := "v6|workspace=" workspaceId "|type=" workspaceType
        . "|recent=" RecentFileCount
        . "|excludedNames=" JoinArray(GlobalExcludedFolderNames, ",")
        . "|noiseEnabled=" (GlobalNoiseFilter.Enabled ? 1 : 0)
        . "|hidden=" (GlobalNoiseFilter.HideHidden ? 1 : 0)
        . "|system=" (GlobalNoiseFilter.HideSystem ? 1 : 0)
        . "|temporary=" (GlobalNoiseFilter.HideTemporary ? 1 : 0)
        . "|downloads=" (GlobalNoiseFilter.HideIncompleteDownloads ? 1 : 0)
        . "|patterns=" JoinArray(GlobalNoiseFilter.CustomPatternTexts, Chr(30))
        . "|pinned=" JoinNormalizedPaths(pinnedPaths)
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
    global ActiveWorkspaceId, CacheDir
    global CurrentScanComplete, CurrentScanRevision, LastValidFolderSettings
    indexed := RuntimeIndexLoadSnapshot(ActiveWorkspaceId,
        CurrentConfigFingerprint)
    if IsObject(indexed) {
        CurrentScanResult := indexed
        ScanResultLoaded := true
        CurrentScanComplete := IsScanResultStructurallyComplete(
            CurrentScanResult, LastValidFolderSettings)
        CurrentScanRevision := NextScanContentRevision()
        RememberCurrentWorkspaceSnapshot()
        return true
    }
    candidatePath := CacheFilePath
    if !FileExist(candidatePath) {
        legacyPath := CacheDir "\scan-cache-v4.ini"
        if FileExist(legacyPath)
            candidatePath := legacyPath
        else
            return false
    }
    result := ReadScanResult(candidatePath, "", CurrentConfigFingerprint,
        ActiveWorkspaceId)
    if !IsObject(result)
        return false
    CurrentScanResult := result
    ScanResultLoaded := true
    CurrentScanComplete := IsScanResultStructurallyComplete(
        CurrentScanResult, LastValidFolderSettings)
    CurrentScanRevision := NextScanContentRevision()
    RememberCurrentWorkspaceSnapshot()
    if candidatePath != CacheFilePath && CurrentScanComplete
        WriteCurrentScanCache()
    return true
}

WorkspaceCacheFilePath(workspaceId) {
    global CacheDir
    return CacheDir "\\workspace-"
        . HashString(StrLower(workspaceId)) ".ini"
}

LoadWorkspaceSnapshot(workspaceId, fingerprint) {
    global CacheDir
    indexed := RuntimeIndexLoadSnapshot(workspaceId, fingerprint)
    if IsObject(indexed)
        return indexed
    path := WorkspaceCacheFilePath(workspaceId)
    if !FileExist(path)
        return 0
    return ReadScanResult(path, "", fingerprint, workspaceId)
}

WriteWorkspaceSnapshot(result, workspaceId, fingerprint) {
    global CacheWritable
    if RuntimeIndexSaveSnapshot(result, workspaceId, fingerprint)
        return true
    if !CacheWritable
        return false
    path := WorkspaceCacheFilePath(workspaceId)
    try {
        tempPath := path ".writing"
        WriteScanResultAtomic(result, tempPath, false)
        FileMove(tempPath, path, 1)
        return true
    } catch {
        return false
    }
}

ReadScanResult(path, expectedGeneration := "", expectedFingerprint := "",
    expectedWorkspaceId := "") {
    try {
        version := Integer(IniRead(path, "Meta", "Version", "0"))
        if version != 4 && version != 5
            return 0
        generation := IniRead(path, "Meta", "Generation", "")
        fingerprint := IniRead(path, "Meta", "Fingerprint", "")
        workspaceId := IniRead(path, "Meta", "WorkspaceId", "")
        if expectedGeneration != "" && generation != expectedGeneration
            return 0
        if expectedFingerprint != "" && fingerprint != expectedFingerprint
            return 0
        if expectedWorkspaceId != ""
            && StrLower(workspaceId) != StrLower(expectedWorkspaceId)
            return 0
        result := {Version: version, Generation: generation,
            Fingerprint: fingerprint, WorkspaceId: workspaceId,
            Kind: IniRead(path, "Meta", "Kind", "Snapshot"),
            SourceIndex: Integer(IniRead(path, "Meta", "SourceIndex", "0")),
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
            if folder.Path = "" || (folder.State != "OK"
                && folder.State != "Unavailable" && folder.State != "Pending")
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

WriteScanRequest(path, generation, sourceKeys := 0, includeRecent := false,
    context := 0) {
    global LastValidFolderSettings, CurrentConfigFingerprint, RecentFileCount
    global GlobalExcludedFolderNames, PinnedPaths, ActiveWorkspaceId
    global ActiveWorkspaceType, WORKSPACE_TYPE_TEXT
    folders := IsObject(context) ? context.Folders : LastValidFolderSettings
    workspaceId := IsObject(context) ? context.WorkspaceId : ActiveWorkspaceId
    fingerprint := IsObject(context) ? context.Fingerprint : CurrentConfigFingerprint
    workspaceType := IsObject(context) ? context.WorkspaceType : ActiveWorkspaceType
    pinnedPaths := IsObject(context) ? context.PinnedPaths : PinnedPaths
    try FileDelete(path)
    IniWrite("6", path, "Meta", "Version")
    IniWrite(generation, path, "Meta", "Generation")
    IniWrite(fingerprint, path, "Meta", "Fingerprint")
    IniWrite(workspaceId, path, "Meta", "WorkspaceId")
    IniWrite(folders.Length, path, "Meta", "FolderCount")
    IniWrite(RecentFileCount, path, "Meta", "RecentFileCount")
    IniWrite(includeRecent ? "1" : "0", path, "Meta", "IncludeRecent")
    IniWrite(GlobalExcludedFolderNames.Length, path,
        "Meta", "GlobalExcludedNameCount")
    for index, name in GlobalExcludedFolderNames
        IniWrite(name, path, "Meta",
            "GlobalExcludedName" Format("{:03}", index))
    IniWrite(pinnedPaths.Length, path, "Meta", "PinnedPathCount")
    for index, pinnedPath in pinnedPaths
        IniWrite(pinnedPath, path, "Meta", "PinnedPath" Format("{:03}", index))
    for index, folder in folders {
        section := "Folder" Format("{:03}", index)
        sourceKey := folder.SourceId != "" ? folder.SourceId
            : ResolveFolderSourceId(folder.Name, folder.Path)
        shouldScan := !IsObject(sourceKeys)
            || sourceKeys.Has(StrLower(sourceKey))
        IniWrite(shouldScan ? "1" : "0", path, section, "Scan")
        IniWrite(folder.Name, path, section, "Name")
        IniWrite(folder.Path, path, section, "Path")
        IniWrite(folder.IncludeSubfolders ? "1" : "0", path, section, "IncludeSubfolders")
        IniWrite(folder.DisplayScope, path, section, "DisplayScope")
        IniWrite(folder.FolderTimeMode, path, section, "FolderTimeMode")
        IniWrite(workspaceType = WORKSPACE_TYPE_TEXT
            ? 0 : folder.MaxFilesPerFolder,
            path, section, "MaxFilesPerFolder")
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

ShouldDeferVisibleBackgroundScan(reason) {
    global PanelVisible, CurrentScanComplete
    if !PanelVisible || !CurrentScanComplete
        return false
    ; These operations are direct user actions and retain their existing
    ; immediate consistency contract. All automatic/watch/accuracy scans can
    ; safely use the already complete cached frame until the panel is hidden.
    return reason != "manual" && reason != "file-operation"
}

QueueVisibleBackgroundScan(sourceKeys, includeRecent) {
    global DeferredVisibleScanPending, DeferredVisibleScanFull
    global DeferredVisibleScanSourceKeys, DeferredVisibleScanIncludeRecent
    DeferredVisibleScanPending := true
    if !IsObject(sourceKeys) {
        DeferredVisibleScanFull := true
        DeferredVisibleScanSourceKeys := Map()
    } else if !DeferredVisibleScanFull {
        for key, value in sourceKeys
            DeferredVisibleScanSourceKeys[key] := true
    }
    DeferredVisibleScanIncludeRecent := DeferredVisibleScanIncludeRecent
        || includeRecent
    return true
}

StartDeferredVisibleBackgroundScan() {
    global DeferredVisibleScanPending, DeferredVisibleScanFull
    global DeferredVisibleScanSourceKeys, DeferredVisibleScanIncludeRecent
    if !DeferredVisibleScanPending
        return true
    sourceKeys := DeferredVisibleScanFull
        ? 0 : DeferredVisibleScanSourceKeys
    includeRecent := DeferredVisibleScanIncludeRecent
    DeferredVisibleScanPending := false
    DeferredVisibleScanFull := false
    DeferredVisibleScanSourceKeys := Map()
    DeferredVisibleScanIncludeRecent := false
    return StartBackgroundScan(sourceKeys, "deferred-hidden", includeRecent)
}

StartBackgroundScan(sourceKeys := 0, reason := "auto", includeRecent := -1) {
    global WorkerRunning, PendingRefresh, PendingFullRefresh
    global PendingScanSourceKeys, PendingIncludeRecent
    global ScanGeneration, WorkerGeneration, WorkerWorkspaceId
    global WorkerFingerprint, WorkerStartedTick, WorkerRecoveryAttempts
    global WorkerRequestPath, WorkerReadyPath, WorkerPid, CacheDir, CacheWritable
    global WorkerAppliedSourceIndexes, WorkerRecentApplied, WorkerChanged
    global WorkerFullScan
    global WorkerSourceDirtyTokens, WorkerRecentDirtyToken
    global SourceWatcherRecentDirty, SourceWatcherRecentGeneration
    global WorkerStatusToken, ActiveWorkspaceId, ShowRecentSidebar
    global CurrentConfigFingerprint, CurrentScanResult, CurrentScanComplete
    global CurrentHiddenBySource
    global WorkerPendingScanResult, WorkerPendingHiddenBySource
    global WorkerStartedWithComplete, WorkerMainChanged
    global InactiveScanJob
    if includeRecent = -1
        includeRecent := ShowRecentSidebar
    if ShouldDeferVisibleBackgroundScan(reason)
        return QueueVisibleBackgroundScan(sourceKeys, includeRecent)
    ReconcileSourceWatchers()
    if reason != "recovery"
        WorkerRecoveryAttempts := 0
    if IsObject(InactiveScanJob)
        CancelInactiveWorkspaceScan(false)
    workerStale := WorkerRunning
        && (StrLower(WorkerWorkspaceId) != StrLower(ActiveWorkspaceId)
            || WorkerFingerprint != CurrentConfigFingerprint)
    ; Manual refresh is an explicit recovery command.  It must replace a hung
    ; full worker instead of being discarded by the full-scan coalescer.
    if WorkerRunning && (workerStale || reason = "manual") {
        if WorkerPid && ProcessExist(WorkerPid)
            try ProcessClose(WorkerPid)
        FinishWorker(false)
        PendingRefresh := false
        PendingFullRefresh := false
        PendingScanSourceKeys := Map()
        PendingIncludeRecent := false
    }
    if WorkerRunning {
        if !IsObject(sourceKeys) && WorkerFullScan
            && reason != "file-operation"
            return
        PendingRefresh := true
        if !IsObject(sourceKeys)
            PendingFullRefresh := true
        else {
            for key, value in sourceKeys
                PendingScanSourceKeys[key] := true
        }
        PendingIncludeRecent := PendingIncludeRecent || includeRecent
        return
    }
    if IsObject(sourceKeys) && !sourceKeys.Count && !includeRecent
        return
    EnsureCurrentScanSkeleton()
    ipcDir := CacheWritable ? CacheDir : A_Temp "\PopDrop"
    try DirCreate(ipcDir)
    generation := Format("{:016X}-{:08X}", A_TickCount, ++ScanGeneration)
    requestPath := ipcDir "\request-" generation ".ini"
    readyPath := ipcDir "\ready-" generation
    try FileDelete(requestPath)
    try DirDelete(readyPath, true)
    try {
        DirCreate(readyPath)
        WriteScanRequest(requestPath, generation, sourceKeys, includeRecent)
        WorkerPid := StartScanWorkerProcess(requestPath, readyPath)
    } catch {
        try FileDelete(requestPath)
        try DirDelete(readyPath, true)
        SetBackgroundStatus("更新失败", 1200)
        return
    }
    WorkerRunning := true
    WorkerFullScan := !IsObject(sourceKeys)
    WorkerGeneration := generation
    WorkerWorkspaceId := ActiveWorkspaceId
    WorkerFingerprint := CurrentConfigFingerprint
    WorkerStartedTick := A_TickCount
    WorkerRequestPath := requestPath
    WorkerReadyPath := readyPath
    WorkerPendingScanResult := CloneScanResultForWorker(CurrentScanResult)
    WorkerPendingHiddenBySource := CurrentHiddenBySource.Clone()
    WorkerStartedWithComplete := CurrentScanComplete
    WorkerMainChanged := false
    WorkerAppliedSourceIndexes := Map()
    WorkerSourceDirtyTokens := Map()
    if IsObject(sourceKeys) {
        for sourceKey, value in sourceKeys
            WorkerSourceDirtyTokens[StrLower(sourceKey)] :=
                GetWorkspaceSourceDirtyToken(ActiveWorkspaceId, sourceKey)
    } else {
        for folder in LastValidFolderSettings {
            sourceId := folder.SourceId != "" ? folder.SourceId
                : ResolveFolderSourceId(folder.Name, folder.Path)
            WorkerSourceDirtyTokens[StrLower(sourceId)] :=
                GetWorkspaceSourceDirtyToken(ActiveWorkspaceId, sourceId)
        }
    }
    WorkerRecentDirtyToken := SourceWatcherRecentGeneration
    WorkerRecentApplied := false
    WorkerChanged := false
    token := ++WorkerStatusToken
    SetTimer(() => ShowWorkerBusyStatus(token), -180)
    SetTimer(PollWorkerResult, 75)
}

ShowWorkerBusyStatus(token) {
    global WorkerRunning, WorkerStatusToken, ScanResultLoaded
    global CurrentScanComplete
    if WorkerRunning && token = WorkerStatusToken
        SetBackgroundStatus(ScanResultLoaded && CurrentScanComplete
            ? "更新中" : "正在加载")
}

EnsureCurrentScanSkeleton() {
    global CurrentScanResult, LastValidFolderSettings
    if !IsObject(CurrentScanResult)
        CurrentScanResult := {Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
    for index, folder in LastValidFolderSettings {
        existing := index <= CurrentScanResult.Folders.Length
            ? CurrentScanResult.Folders[index] : 0
        if IsObject(existing)
            && StrLower(RTrim(existing.Path, "\")) = StrLower(RTrim(folder.Path, "\"))
            && StrLower(existing.Name) = StrLower(folder.Name)
            continue
        pending := {Name: folder.Name, Path: folder.Path,
            State: "Pending", Files: []}
        if index <= CurrentScanResult.Folders.Length
            CurrentScanResult.Folders[index] := pending
        else
            CurrentScanResult.Folders.Push(pending)
    }
    while CurrentScanResult.Folders.Length > LastValidFolderSettings.Length
        CurrentScanResult.Folders.Pop()
}

CloneScanResultForWorker(result) {
    if !IsObject(result)
        return {Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
    return {
        Folders: result.Folders.Clone(),
        Recent: result.Recent.Clone(),
        HiddenCount: HasProp(result, "HiddenCount") ? result.HiddenCount : 0,
        HiddenItems: HasProp(result, "HiddenItems")
            ? result.HiddenItems.Clone() : []
    }
}

PollWorkerResult() {
    global WorkerRunning, WorkerPid, WorkerReadyPath, WorkerGeneration
    global WorkerWorkspaceId, WorkerFingerprint, WorkerStartedTick
    global WorkerRecoveryAttempts
    global WorkerAppliedSourceIndexes, WorkerRecentApplied, WorkerChanged
    global WorkerSourceDirtyTokens, WorkerRecentDirtyToken
    global CurrentConfigFingerprint, CurrentScanResult, ScanResultLoaded
    global CurrentScanComplete, CurrentScanRevision
    global CurrentHiddenBySource
    global WorkerPendingScanResult, WorkerPendingHiddenBySource
    global WorkerStartedWithComplete, WorkerMainChanged
    global LastValidFolderSettings
    global PendingFileOperationRefresh, Panel, PanelVisible, ActiveWorkspaceId
    global SourceWatcherRecentDirty, SourceWatcherRecentGeneration
    appliedSource := false
    appliedRecent := false
    if !WorkerRunning {
        SetTimer(PollWorkerResult, 0)
        return
    }
    if WorkerFingerprint != CurrentConfigFingerprint
        || StrLower(WorkerWorkspaceId) != StrLower(ActiveWorkspaceId) {
        if PanelVisible {
            ; Keep the cheap identity poll alive. r33 stopped this timer while
            ; a worker belonged to an inactive workspace, but never restarted
            ; it when the user returned to that workspace. WorkerRunning then
            ; stayed true forever and every source remained "正在加载".
            return
        }
        if WorkerPid && ProcessExist(WorkerPid)
            try ProcessClose(WorkerPid)
        FinishWorker(false)
        return
    }
    Loop Files, WorkerReadyPath "\source-*.ini", "F" {
        if !RegExMatch(A_LoopFileName, "i)^source-(\d+)\.ini$", &match)
            continue
        sourceIndex := Integer(match[1])
        if WorkerAppliedSourceIndexes.Has(sourceIndex)
            continue
        partial := ReadScanResult(A_LoopFileFullPath, WorkerGeneration,
            WorkerFingerprint, WorkerWorkspaceId)
        if sourceIndex < 1 || sourceIndex > LastValidFolderSettings.Length
            continue
        if !IsObject(partial) || partial.Kind != "Source"
            || partial.SourceIndex != sourceIndex
            continue
        WorkerAppliedSourceIndexes[sourceIndex] := true
        if partial.SourceIndex < 1 || !partial.Folders.Length
            continue
        before := sourceIndex <= WorkerPendingScanResult.Folders.Length
            ? ResultSignature({Folders: [WorkerPendingScanResult.Folders[sourceIndex]], Recent: []}) : ""
        while WorkerPendingScanResult.Folders.Length < sourceIndex
            WorkerPendingScanResult.Folders.Push(
                {Name: "", Path: "", State: "Pending", Files: []})
        WorkerPendingScanResult.Folders[sourceIndex] := partial.Folders[1]
        WorkerPendingHiddenBySource[sourceIndex] := {
            Count: partial.HiddenCount, Items: partial.HiddenItems}
        RebuildCurrentHiddenDiagnostics(
            WorkerPendingScanResult, WorkerPendingHiddenBySource)
        after := ResultSignature({Folders: [partial.Folders[1]], Recent: []})
        if before != after {
            WorkerChanged := true
            WorkerMainChanged := true
        }
        appliedSource := true
    }
    recentPath := WorkerReadyPath "\recent.ini"
    if !WorkerRecentApplied && FileExist(recentPath) {
        partial := ReadScanResult(recentPath, WorkerGeneration,
            WorkerFingerprint, WorkerWorkspaceId)
        if IsObject(partial) && partial.Kind = "Recent" {
            WorkerRecentApplied := true
            if ResultSignature(
                {Folders: [], Recent: WorkerPendingScanResult.Recent})
                != ResultSignature({Folders: [], Recent: partial.Recent})
                WorkerChanged := true
            WorkerPendingScanResult.Recent := partial.Recent
            appliedRecent := true
        }
    }
    ; Pending source generations are intentionally invisible. Keeping the
    ; current result object untouched is what makes the retained native frame
    ; and its revision an exact, safely clickable pair.
    completePath := WorkerReadyPath "\complete.ini"
    if FileExist(completePath) {
        validComplete := IniRead(completePath, "Meta", "Generation", "")
            = WorkerGeneration
            && IniRead(completePath, "Meta", "Fingerprint", "")
                = WorkerFingerprint
            && StrLower(IniRead(completePath, "Meta", "WorkspaceId", ""))
                = StrLower(WorkerWorkspaceId)
            && WorkerFingerprint = CurrentConfigFingerprint
            && StrLower(WorkerWorkspaceId) = StrLower(ActiveWorkspaceId)
        if validComplete
            && IsScanResultStructurallyComplete(
                WorkerPendingScanResult, LastValidFolderSettings) {
            WorkerRecoveryAttempts := 0
            CurrentScanResult := WorkerPendingScanResult
            CurrentHiddenBySource := WorkerPendingHiddenBySource
            ScanResultLoaded := true
            CurrentScanComplete := true
            if !WorkerStartedWithComplete || WorkerMainChanged
                CurrentScanRevision := NextScanContentRevision()
            RememberCurrentWorkspaceSnapshot()
            if !WorkerStartedWithComplete || WorkerChanged
                QueueCurrentScanCacheWrite()
            ; Clear watcher dirtiness only after the whole generation commits.
            ; Token checks preserve a newer change that arrived during scan.
            for sourceKey, token in WorkerSourceDirtyTokens
                ClearWorkspaceSourceDirty(
                    ActiveWorkspaceId, sourceKey, token)
            if WorkerRecentApplied
                && WorkerRecentDirtyToken = SourceWatcherRecentGeneration
                SourceWatcherRecentDirty := false
            if IsObject(Panel) && PanelVisible {
                if !WorkerStartedWithComplete || WorkerMainChanged
                    || PendingFileOperationRefresh
                    PopulatePanel()
                if WorkerRecentApplied
                    PopulateRecentSidebar()
                SetTimer(UpdateSelectionStatus, 0)
            }
            SetBackgroundStatus(WorkerChanged ? "已更新" : "已是最新",
                WorkerChanged ? 700 : 250)
            FinishWorker()
        } else
            RecoverFailedWorker(validComplete
                ? "扫描结果不完整" : "扫描结果已过期")
        return
    }
    if WorkerPid && !ProcessExist(WorkerPid) {
        FlushPendingScanCacheWrite()
        RecoverFailedWorker("扫描进程异常退出")
        return
    }
    if WorkerStartedTick && A_TickCount - WorkerStartedTick > 120000 {
        if WorkerPid && ProcessExist(WorkerPid)
            try ProcessClose(WorkerPid)
        RecoverFailedWorker("扫描超时")
    }
}

RecoverFailedWorker(reason) {
    global PendingRefresh, WorkerRecoveryAttempts, ShowRecentSidebar
    hadPending := PendingRefresh
    FinishWorker(false)
    if hadPending {
        PendingRefresh := false
        SetBackgroundStatus("正在重试")
        SetTimer(StartPendingRefresh, -80)
        return
    }
    if WorkerRecoveryAttempts < 1 {
        WorkerRecoveryAttempts += 1
        SetBackgroundStatus("正在重试")
        SetTimer(() => StartBackgroundScan(0, "recovery", ShowRecentSidebar), -250)
        return
    }
    SetBackgroundStatus("加载失败，请点击刷新")
}

RefreshScanAfterPinnedChange() {
    global CurrentConfigFingerprint, CurrentScanResult, LastValidFolderSettings
    global CurrentHiddenBySource, PanelRenderSignature, RecentRenderSignature
    global ScanResultLoaded, ActiveWorkspaceId
    fingerprint := ComputeConfigFingerprint(LastValidFolderSettings)
    if fingerprint = CurrentConfigFingerprint
        return
    ; Keep the already rendered source snapshot available while the changed
    ; pinned override is reconciled.  Fast mode must never turn a warm view
    ; into a pinned-only cold-loading screen merely because its fingerprint
    ; changed.
    CurrentConfigFingerprint := fingerprint
    if IsObject(CurrentScanResult) {
        CurrentScanResult.Fingerprint := fingerprint
        CurrentScanResult.WorkspaceId := ActiveWorkspaceId
    }
    CurrentHiddenBySource := Map()
    PanelRenderSignature := ""
    RecentRenderSignature := ""
    if ScanResultLoaded
        RememberCurrentWorkspaceSnapshot()
    for folder in LastValidFolderSettings {
        sourceId := folder.SourceId != "" ? folder.SourceId
            : ResolveFolderSourceId(folder.Name, folder.Path)
        MarkWorkspaceSourceDirty(ActiveWorkspaceId, sourceId)
    }
    StartBackgroundScan(0, "pinned-change", false)
}

RebuildCurrentHiddenDiagnostics(result := 0, diagnosticsBySource := 0) {
    global CurrentScanResult, CurrentHiddenBySource, NOISE_DIAGNOSTIC_LIMIT
    if !IsObject(result)
        result := CurrentScanResult
    if !IsObject(diagnosticsBySource)
        diagnosticsBySource := CurrentHiddenBySource
    count := 0
    items := []
    for sourceIndex, diagnostics in diagnosticsBySource {
        count += diagnostics.Count
        for item in diagnostics.Items {
            if items.Length >= NOISE_DIAGNOSTIC_LIMIT
                break
            items.Push(item)
        }
    }
    result.HiddenCount := count
    result.HiddenItems := items
}

RememberCurrentWorkspaceSnapshot() {
    global WorkspaceScanSnapshots, ActiveWorkspaceId
    global CurrentConfigFingerprint, CurrentScanResult
    global CurrentScanComplete, CurrentScanRevision
    if ActiveWorkspaceId != ""
        WorkspaceScanSnapshots[StrLower(ActiveWorkspaceId)] := {
            Fingerprint: CurrentConfigFingerprint,
            Result: CurrentScanResult,
            Complete: CurrentScanComplete,
            Revision: CurrentScanRevision}
}

NextScanContentRevision() {
    global ScanContentRevisionSerial
    return ++ScanContentRevisionSerial
}

IsScanResultStructurallyComplete(result, folderSettings) {
    if !IsObject(result) || !HasProp(result, "Folders")
        return false
    if result.Folders.Length != folderSettings.Length
        return false
    for index, folder in folderSettings {
        scan := result.Folders[index]
        if !IsObject(scan) || !HasProp(scan, "State")
            || scan.State = "Pending"
            || !HasProp(scan, "Path") || !HasProp(scan, "Name")
            || StrLower(RTrim(scan.Path, "\"))
                != StrLower(RTrim(folder.Path, "\"))
            || StrLower(scan.Name) != StrLower(folder.Name)
            return false
    }
    return true
}

WriteCurrentScanCache() {
    global CacheWritable, CacheFilePath, CurrentScanResult
    global CurrentScanComplete
    if !CacheWritable || !CurrentScanComplete
        return false
    if RuntimeIndexSaveSnapshot(CurrentScanResult)
        return true
    try {
        cacheTemp := CacheFilePath ".writing"
        WriteScanResultAtomic(CurrentScanResult, cacheTemp, false)
        FileMove(cacheTemp, CacheFilePath, 1)
        return true
    } catch {
        CacheWritable := false
        return false
    }
}

QueueCurrentScanCacheWrite() {
    global ScanCacheWritePending
    ScanCacheWritePending := true
    SetTimer(FlushPendingScanCacheWrite, -250)
}

FlushPendingScanCacheWrite(force := false) {
    global ScanCacheWritePending, PanelVisible
    global CurrentScanResult, ActiveWorkspaceId, CurrentConfigFingerprint
    SetTimer(FlushPendingScanCacheWrite, 0)
    if !ScanCacheWritePending
        return
    ScanCacheWritePending := false
    if PanelVisible && !force
        return QueueDeferredWorkspaceSnapshotWrite(CurrentScanResult,
            ActiveWorkspaceId, CurrentConfigFingerprint)
    WriteCurrentScanCache()
}

MergeInactiveScanQueueTokens(workspaceKey, tokens) {
    global InactiveScanQueue
    if workspaceKey = "" || !IsObject(tokens)
        return false
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if !InactiveScanQueue.Has(workspaceKey)
            InactiveScanQueue[workspaceKey] := Map()
        queued := InactiveScanQueue[workspaceKey]
        for sourceKey, token in tokens
            queued[sourceKey] := token
    } finally {
        Critical(previousCritical)
    }
    return true
}

TakeInactiveScanQueueEntry(workspaceKey) {
    global InactiveScanQueue
    queued := 0
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if InactiveScanQueue.Has(workspaceKey) {
            ; Claim the Map object before releasing Critical. A watcher event
            ; arriving afterwards creates a fresh entry, so new dirty tokens
            ; cannot be erased by completion of the job being started now.
            queued := InactiveScanQueue[workspaceKey]
            InactiveScanQueue.Delete(workspaceKey)
        }
    } finally {
        Critical(previousCritical)
    }
    return queued
}

SnapshotInactiveScanQueueKeys() {
    global InactiveScanQueue
    keys := []
    previousCritical := A_IsCritical
    Critical("On")
    try {
        for workspaceKey, _ in InactiveScanQueue
            keys.Push(workspaceKey)
    } finally {
        Critical(previousCritical)
    }
    return keys
}

ClearInactiveScanQueueSourceToken(workspaceKey, sourceKey, token := 0) {
    global InactiveScanQueue
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if !InactiveScanQueue.Has(workspaceKey)
            return false
        queued := InactiveScanQueue[workspaceKey]
        if queued.Has(sourceKey)
            && (token = 0 || queued[sourceKey] = token)
            queued.Delete(sourceKey)
        if !queued.Count && InactiveScanQueue.Has(workspaceKey)
            InactiveScanQueue.Delete(workspaceKey)
    } finally {
        Critical(previousCritical)
    }
    return true
}

QueueInactiveWorkspaceScans() {
    global WorkspaceDirtySourceKeys, ActiveWorkspaceId, InactiveScanQueue
    global InactiveRecentPending, SourceWatcherRecentDirty, ShowRecentSidebar
    if SourceWatcherRecentDirty && ShowRecentSidebar
        InactiveRecentPending := true
    for workspaceKey, dirty in WorkspaceDirtySourceKeys {
        if workspaceKey = StrLower(ActiveWorkspaceId) || !dirty.Count
            continue
        MergeInactiveScanQueueTokens(workspaceKey, dirty)
    }
    StartNextInactiveWorkspaceScan()
}

StartNextInactiveWorkspaceScan() {
    global InactiveScanJob, InactiveScanQueue, CacheDir, CacheWritable
    global InactiveScanGeneration
    global ActiveWorkspaceId, CurrentConfigFingerprint
    global InactiveRecentPending, SourceWatcherRecentGeneration
    global WorkerRunning, PanelVisible
    if PanelVisible || IsObject(InactiveScanJob) || WorkerRunning
        || !CacheWritable
        return
    for workspaceKey in SnapshotInactiveScanQueueKeys() {
        if workspaceKey = StrLower(ActiveWorkspaceId)
            continue
        queued := TakeInactiveScanQueueEntry(workspaceKey)
        if !IsObject(queued) || !queued.Count
            continue
        found := FindWorkspace(workspaceKey)
        if !IsObject(found) || !found.Value.Sources.Length
            continue
        workspace := found.Value
        if StrLower(workspace.Id) = StrLower(ActiveWorkspaceId) {
            MergeInactiveScanQueueTokens(workspaceKey, queued)
            continue
        }
        generation := "inactive-" Format("{:016X}-{:08X}", A_TickCount,
            ++InactiveScanGeneration)
        requestPath := CacheDir "\\" generation ".request.ini"
        readyPath := CacheDir "\\" generation ".ready"
        pid := 0
        includeRecent := false
        recentToken := SourceWatcherRecentGeneration
        try {
            DirCreate(readyPath)
            settings := workspace.Sources
            fingerprint := ComputeConfigFingerprint(settings, workspace.Id,
                workspace.Type, workspace.PinnedPaths)
            existing := LoadWorkspaceSnapshot(workspace.Id, fingerprint)
            existingComplete := IsObject(existing)
                && IsScanResultStructurallyComplete(existing, settings)
            if !existingComplete
                existing := BuildWorkspaceScanSkeleton(
                    workspace.Id, fingerprint)
            ; A legacy truncated base cannot be repaired by refreshing only
            ; the Dirty subset. Promote it to a full all-source worker.
            scanKeys := existingComplete ? queued : 0
            context := {Folders: settings, WorkspaceId: workspace.Id,
                Fingerprint: fingerprint, WorkspaceType: workspace.Type,
                PinnedPaths: workspace.PinnedPaths}
            ; Consume the shared recent flag before worker setup. A new watcher
            ; event can then set it again without being cleared by this job.
            previousCritical := A_IsCritical
            Critical("On")
            try {
                includeRecent := InactiveRecentPending
                recentToken := SourceWatcherRecentGeneration
                if includeRecent
                    InactiveRecentPending := false
            } finally {
                Critical(previousCritical)
            }
            WriteScanRequest(requestPath, generation, scanKeys,
                includeRecent, context)
            pid := StartScanWorkerProcess(requestPath, readyPath)
            tokens := Map()
            for sourceKey, token in queued
                tokens[sourceKey] := token
            InactiveScanJob := {WorkspaceId: workspace.Id,
                Fingerprint: fingerprint, Generation: generation,
                RequestPath: requestPath, ReadyPath: readyPath, Pid: pid,
                StartedTick: A_TickCount,
                SourceTokens: tokens, IncludeRecent: includeRecent,
                RecentToken: recentToken,
                Applied: Map(), Result: existing}
            SetTimer(PollInactiveWorkspaceScan, 75)
        } catch {
            if pid && ProcessExist(pid)
                try ProcessClose(pid)
            if IsObject(InactiveScanJob)
                && InactiveScanJob.Generation = generation
                InactiveScanJob := 0
            if includeRecent
                InactiveRecentPending := true
            try FileDelete(requestPath)
            try DirDelete(readyPath, true)
        }
        return
    }
}

PollInactiveWorkspaceScan() {
    global InactiveScanJob, InactiveScanQueue
    global SourceWatcherRecentDirty, SourceWatcherRecentGeneration
    if !IsObject(InactiveScanJob) {
        SetTimer(PollInactiveWorkspaceScan, 0)
        return
    }
    job := InactiveScanJob
    if !IsObject(job.Result) {
        job.Result := LoadWorkspaceSnapshot(job.WorkspaceId, job.Fingerprint)
        if !IsObject(job.Result)
            job.Result := BuildWorkspaceScanSkeleton(job.WorkspaceId,
                job.Fingerprint)
    }
    Loop Files, job.ReadyPath "\\source-*.ini", "F" {
        if !RegExMatch(A_LoopFileName, "i)^source-(\d+)\.ini$", &match)
            continue
        sourceIndex := Integer(match[1])
        if job.Applied.Has(sourceIndex)
            continue
        partial := ReadScanResult(A_LoopFileFullPath, job.Generation,
            job.Fingerprint, job.WorkspaceId)
        if !IsObject(partial) || !partial.Folders.Length
            continue
        job.Applied[sourceIndex] := true
        while job.Result.Folders.Length < sourceIndex
            job.Result.Folders.Push({Name: "", Path: "", State: "Pending", Files: []})
        job.Result.Folders[sourceIndex] := partial.Folders[1]
    }
    recentPath := job.ReadyPath "\\recent.ini"
    if job.IncludeRecent && FileExist(recentPath) {
        recent := ReadScanResult(recentPath, job.Generation,
            job.Fingerprint, job.WorkspaceId)
        if IsObject(recent)
            job.Result.Recent := recent.Recent
    }
    completePath := job.ReadyPath "\\complete.ini"
    if FileExist(completePath) {
        if IniRead(completePath, "Meta", "Generation", "") = job.Generation
            && IsWorkspaceScanStructurallyComplete(
                job.Result, job.WorkspaceId) {
            if WriteWorkspaceSnapshot(job.Result, job.WorkspaceId,
                job.Fingerprint) {
                ; Fast workspace switching reads memory before SQLite/INI.  The
                ; durable inactive refresh and its in-memory peer must be
                ; published as one logical commit before Dirty is cleared.
                RememberWorkspaceSnapshot(job.Result, job.WorkspaceId,
                    job.Fingerprint)
                ; Clear Dirty only after the merged snapshot is durable. If a
                ; write fails, the source remains queued for a later retry.
                for sourceKey, token in job.SourceTokens {
                    sourceId := ""
                    found := FindWorkspace(job.WorkspaceId)
                    if IsObject(found) {
                        for folder in found.Value.Sources {
                            candidate := folder.SourceId != "" ? folder.SourceId
                                : ResolveFolderSourceId(folder.Name, folder.Path)
                            if StrLower(candidate) = sourceKey {
                                sourceId := candidate
                                break
                            }
                        }
                    }
                    if sourceId != ""
                        ClearWorkspaceSourceDirty(job.WorkspaceId, sourceId,
                            token)
                }
                if job.IncludeRecent
                    && job.RecentToken = SourceWatcherRecentGeneration
                    SourceWatcherRecentDirty := false
            }
        }
        FinishInactiveWorkspaceScan()
        return
    }
    if job.Pid && !ProcessExist(job.Pid) {
        RequeueInactiveWorkspaceJob(job)
        FinishInactiveWorkspaceScan()
        return
    }
    if HasProp(job, "StartedTick") && job.StartedTick
        && A_TickCount - job.StartedTick > 120000 {
        if job.Pid && ProcessExist(job.Pid)
            try ProcessClose(job.Pid)
        RequeueInactiveWorkspaceJob(job)
        FinishInactiveWorkspaceScan()
    }
}

BuildWorkspaceScanSkeleton(workspaceId, fingerprint) {
    found := FindWorkspace(workspaceId)
    result := {Version: 5, Generation: "index", Fingerprint: fingerprint,
        WorkspaceId: workspaceId, Kind: "Snapshot", SourceIndex: 0,
        Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
    if IsObject(found)
        for folder in found.Value.Sources
            result.Folders.Push({Name: folder.Name, Path: folder.Path,
                State: "Pending", Files: []})
    return result
}

GetWorkspaceSourceIdByIndex(workspaceId, sourceIndex) {
    found := FindWorkspace(workspaceId)
    if !IsObject(found) || sourceIndex < 1
        return ""
    settings := found.Value.Sources
    if sourceIndex > settings.Length
        return ""
    sourceId := settings[sourceIndex].SourceId
    return sourceId != "" ? sourceId : ResolveFolderSourceId(
        settings[sourceIndex].Name, settings[sourceIndex].Path)
}

FinishInactiveWorkspaceScan(startNext := true) {
    global InactiveScanJob
    SetTimer(PollInactiveWorkspaceScan, 0)
    if IsObject(InactiveScanJob) {
        try FileDelete(InactiveScanJob.RequestPath)
        try DirDelete(InactiveScanJob.ReadyPath, true)
    }
    InactiveScanJob := 0
    if startNext
        StartNextInactiveWorkspaceScan()
}

RequeueInactiveWorkspaceJob(job) {
    workspaceKey := StrLower(job.WorkspaceId)
    MergeInactiveScanQueueTokens(workspaceKey, job.SourceTokens)
}

CancelInactiveWorkspaceScan(startNext := true) {
    global InactiveScanJob, InactiveScanQueue
    if !IsObject(InactiveScanJob)
        return
    RequeueInactiveWorkspaceJob(InactiveScanJob)
    if InactiveScanJob.Pid && ProcessExist(InactiveScanJob.Pid)
        try ProcessClose(InactiveScanJob.Pid)
    FinishInactiveWorkspaceScan(startNext)
}

RememberWorkspaceSnapshot(result, workspaceId, fingerprint) {
    global WorkspaceScanSnapshots
    if workspaceId != ""
        WorkspaceScanSnapshots[StrLower(workspaceId)] := {
            Fingerprint: fingerprint,
            Result: result,
            Complete: true,
            Revision: NextScanContentRevision()}
}

IsWorkspaceScanStructurallyComplete(result, workspaceId) {
    found := FindWorkspace(workspaceId)
    return IsObject(found)
        && IsScanResultStructurallyComplete(result, found.Value.Sources)
}

FinishWorker(startPending := true) {
    global WorkerRunning, WorkerPid, WorkerRequestPath, WorkerReadyPath
    global PendingRefresh, WorkerStatusToken, WorkerFullScan
    global WorkerFingerprint, WorkerStartedTick
    global WorkerPendingScanResult, WorkerPendingHiddenBySource
    global WorkerStartedWithComplete, WorkerMainChanged
    SetTimer(PollWorkerResult, 0)
    ++WorkerStatusToken
    try FileDelete(WorkerRequestPath)
    if WorkerReadyPath != ""
        && RegExMatch(WorkerReadyPath, "i)\\ready-[0-9A-F-]+$")
        try DirDelete(WorkerReadyPath, true)
    WorkerRunning := false
    WorkerFullScan := false
    WorkerFingerprint := ""
    WorkerStartedTick := 0
    WorkerPid := 0
    WorkerRequestPath := ""
    WorkerReadyPath := ""
    WorkerPendingScanResult := 0
    WorkerPendingHiddenBySource := Map()
    WorkerStartedWithComplete := false
    WorkerMainChanged := false
    pendingStarted := false
    if startPending && PendingRefresh {
        PendingRefresh := false
        pendingStarted := true
        SetTimer(StartPendingRefresh, -50)
    }
    if !pendingStarted
        StartNextInactiveWorkspaceScan()
}

StartPendingRefresh() {
    global PendingFullRefresh, PendingScanSourceKeys, PendingIncludeRecent
    sourceKeys := PendingFullRefresh ? 0 : PendingScanSourceKeys
    includeRecent := PendingIncludeRecent
    PendingFullRefresh := false
    PendingScanSourceKeys := Map()
    PendingIncludeRecent := false
    StartBackgroundScan(sourceKeys, "pending", includeRecent)
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
            signature .= item.Path "@" item.Modified "@" item.Name "@"
                . (item.IsDirectory ? 1 : 0) "@" item.TimeKind "|"
    }
    for item in result.Recent
        signature .= "R|" item.Path "@" item.Modified "@" item.Name "|"
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
