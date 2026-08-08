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
    global TextBlockSelectFirstPending

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
            if !exists {
                label := GetFileName(path) "  [项目不存在]"
                row := AddFileTile(path, label, "", groupId, "UnknownFile")
            } else if IsTextWorkspace() && HasTextBlockExtension(path)
                row := AddTextBlockTile(path, groupId)
            else {
                label := GetFileName(path)
                row := AddFileTile(path, label, "", groupId)
            }
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
        if IsTextWorkspace()
            files := PrepareTextBlockFiles(files, folder,
                folder.MaxFilesPerFolder)
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
                row := AddPlaceholderTile(
                    "暂无文件", groupId, "EmptyFolder")
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
            row := IsTextWorkspace()
                ? AddTextBlockTile(file.Path, groupId)
                : AddFileTile(file.Path, displayName, modifiedText, groupId)
            ItemPaths[row] := file.Path
            ItemFolderPaths[row] := folder.Path
            ItemKinds[row] := file.IsDirectory ? "Folder" : "File"
            ItemOpenContexts[row] := {
                Area: "Source",
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
    FileView.Opt("+Redraw")
    UpdateTransferGroupHeaders()
    ; Paint the committed rows before publishing their count in the footer.
    DllCall("user32\RedrawWindow", "ptr", FileView.Hwnd, "ptr", 0, "ptr", 0,
        "uint", 0x0001 | 0x0080 | 0x0100, "int")
    if IsObject(ItemCountText) {
        countText := "共" displayedCount "项"
        if unavailableCount
            countText .= " · " unavailableCount "不可用"
        ItemCountText.Text := countText
    }
    if !ScanResultLoaded {
        StatusKind := "background"
        StatusText.Text := "正在加载"
    } else if StatusKind != "background" {
        StatusKind := "default"
        StatusText.Text := "已是最新"
    }
    PanelRenderSignature := ComputePanelRenderSignature()
    PanelRenderedWorkspaceId := ActiveWorkspaceId
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

AddFileTile(path, label, modifiedText, groupId, bundledIcon := "") {
    global FileView, ItemLabels, ThumbnailPolicy
    cacheKey := PathKey(path) "|" modifiedText "|" bundledIcon
    thumbnail := bundledIcon != ""
        ? AddBundledThumbnailIcon(bundledIcon)
        : AddShellThumbnail(path, cacheKey)
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

AddShellThumbnail(path, cacheKey := "") {
    global ThumbnailSize, ThumbnailImageList, ThumbnailIconCache
    if cacheKey != "" && ThumbnailIconCache.Has(cacheKey)
        return ThumbnailIconCache[cacheKey]
    ; Folders are pinned as single shortcuts. Always use their Shell icon
    ; instead of asking Windows to inspect their contents for a thumbnail.
    if DirExist(path) {
        result := {Index: AddShellFileIcon(path), Cached: true}
        if cacheKey != "" && result.Index
            ThumbnailIconCache[cacheKey] := result
        return result
    }

    imageIndex := AddShellThumbnailBitmap(path, true)
    if imageIndex
        result := {Index: imageIndex, Cached: true}
    else
        result := {Index: AddShellFileIcon(path), Cached: false}
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
    if IsPotentiallyRemotePath(path)
        return
    ThumbnailEnhanceQueue.Push({Path: path, Row: row, CacheKey: cacheKey,
        Generation: ThumbnailEnhanceGeneration})
}

EnhanceNextThumbnail() {
    global ThumbnailEnhanceQueue, ThumbnailEnhanceGeneration
    global ItemPaths, FileView, PanelVisible, ThumbnailIconCache
    if !PanelVisible || !ThumbnailEnhanceQueue.Length
        return
    task := ThumbnailEnhanceQueue.RemoveAt(1)
    if task.Generation = ThumbnailEnhanceGeneration
        && ItemPaths.Has(task.Row)
        && PathKey(ItemPaths[task.Row]) = PathKey(task.Path) {
        imageIndex := AddShellThumbnailBitmap(task.Path, false)
        if imageIndex {
            FileView.Modify(task.Row, "Icon" imageIndex)
            if task.CacheKey != ""
                ThumbnailIconCache[task.CacheKey] := {
                    Index: imageIndex, Cached: true}
        }
    }
    if ThumbnailEnhanceQueue.Length
        SetTimer(EnhanceNextThumbnail, -15)
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
    global TextBlockSearchQuery
    return StrLower(ActiveWorkspaceId) "|" CurrentConfigFingerprint
        . "|" ResultSignature({Folders: CurrentScanResult.Folders, Recent: []})
        . "|p=" JoinNormalizedPaths(PinnedPaths)
        . "|v=" ViewMode "|t=" ThumbnailSize
        . "|q=" TextBlockSearchQuery
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
    indexed := RuntimeIndexLoadSnapshot(ActiveWorkspaceId,
        CurrentConfigFingerprint)
    if IsObject(indexed) {
        CurrentScanResult := indexed
        ScanResultLoaded := true
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
    RememberCurrentWorkspaceSnapshot()
    if candidatePath != CacheFilePath
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
    global CurrentConfigFingerprint
    global InactiveScanJob
    ReconcileSourceWatchers()
    if includeRecent = -1
        includeRecent := ShowRecentSidebar
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
    if WorkerRunning && token = WorkerStatusToken
        SetBackgroundStatus(ScanResultLoaded ? "更新中" : "正在加载")
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

PollWorkerResult() {
    global WorkerRunning, WorkerPid, WorkerReadyPath, WorkerGeneration
    global WorkerWorkspaceId, WorkerFingerprint, WorkerStartedTick
    global WorkerRecoveryAttempts
    global WorkerAppliedSourceIndexes, WorkerRecentApplied, WorkerChanged
    global WorkerSourceDirtyTokens, WorkerRecentDirtyToken
    global CurrentConfigFingerprint, CurrentScanResult, ScanResultLoaded
    global CurrentHiddenBySource
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
        before := sourceIndex <= CurrentScanResult.Folders.Length
            ? ResultSignature({Folders: [CurrentScanResult.Folders[sourceIndex]], Recent: []}) : ""
        while CurrentScanResult.Folders.Length < sourceIndex
            CurrentScanResult.Folders.Push({Name: "", Path: "", State: "Pending", Files: []})
        CurrentScanResult.Folders[sourceIndex] := partial.Folders[1]
        sourceId := LastValidFolderSettings[sourceIndex].SourceId
        if sourceId = ""
            sourceId := ResolveFolderSourceId(
                LastValidFolderSettings[sourceIndex].Name,
                LastValidFolderSettings[sourceIndex].Path)
        sourceKey := StrLower(sourceId)
        if WorkerSourceDirtyTokens.Has(sourceKey)
            ClearWorkspaceSourceDirty(ActiveWorkspaceId, sourceId,
                WorkerSourceDirtyTokens[sourceKey])
        CurrentHiddenBySource[sourceIndex] := {
            Count: partial.HiddenCount, Items: partial.HiddenItems}
        RebuildCurrentHiddenDiagnostics()
        after := ResultSignature({Folders: [partial.Folders[1]], Recent: []})
        if before != after
            WorkerChanged := true
        ScanResultLoaded := true
        appliedSource := true
    }
    recentPath := WorkerReadyPath "\recent.ini"
    if !WorkerRecentApplied && FileExist(recentPath) {
        partial := ReadScanResult(recentPath, WorkerGeneration,
            WorkerFingerprint, WorkerWorkspaceId)
        if IsObject(partial) && partial.Kind = "Recent" {
            WorkerRecentApplied := true
            if ResultSignature({Folders: [], Recent: CurrentScanResult.Recent})
                != ResultSignature({Folders: [], Recent: partial.Recent})
                WorkerChanged := true
            CurrentScanResult.Recent := partial.Recent
            if WorkerRecentDirtyToken = SourceWatcherRecentGeneration
                SourceWatcherRecentDirty := false
            appliedRecent := true
        }
    }
    if appliedSource || appliedRecent {
        RememberCurrentWorkspaceSnapshot()
        QueueCurrentScanCacheWrite()
        if IsObject(Panel) && PanelVisible {
            if appliedSource || PendingFileOperationRefresh
                PopulatePanel()
            if appliedRecent
                PopulateRecentSidebar()
            SetTimer(UpdateSelectionStatus, 0)
        }
    }
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
        if validComplete {
            WorkerRecoveryAttempts := 0
            ScanResultLoaded := true
            RememberCurrentWorkspaceSnapshot()
            FlushPendingScanCacheWrite()
            SetBackgroundStatus(WorkerChanged ? "已更新" : "已是最新",
                WorkerChanged ? 700 : 250)
            FinishWorker()
        } else
            RecoverFailedWorker("扫描结果已过期")
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

RebuildCurrentHiddenDiagnostics() {
    global CurrentScanResult, CurrentHiddenBySource, NOISE_DIAGNOSTIC_LIMIT
    count := 0
    items := []
    for sourceIndex, diagnostics in CurrentHiddenBySource {
        count += diagnostics.Count
        for item in diagnostics.Items {
            if items.Length >= NOISE_DIAGNOSTIC_LIMIT
                break
            items.Push(item)
        }
    }
    CurrentScanResult.HiddenCount := count
    CurrentScanResult.HiddenItems := items
}

RememberCurrentWorkspaceSnapshot() {
    global WorkspaceScanSnapshots, ActiveWorkspaceId
    global CurrentConfigFingerprint, CurrentScanResult
    if ActiveWorkspaceId != ""
        WorkspaceScanSnapshots[StrLower(ActiveWorkspaceId)] := {
            Fingerprint: CurrentConfigFingerprint, Result: CurrentScanResult}
}

WriteCurrentScanCache() {
    global CacheWritable, CacheFilePath, CurrentScanResult
    if !CacheWritable
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

FlushPendingScanCacheWrite() {
    global ScanCacheWritePending
    SetTimer(FlushPendingScanCacheWrite, 0)
    if !ScanCacheWritePending
        return
    ScanCacheWritePending := false
    WriteCurrentScanCache()
}

QueueInactiveWorkspaceScans() {
    global WorkspaceDirtySourceKeys, ActiveWorkspaceId, InactiveScanQueue
    global InactiveRecentPending, SourceWatcherRecentDirty, ShowRecentSidebar
    if SourceWatcherRecentDirty && ShowRecentSidebar
        InactiveRecentPending := true
    for workspaceKey, dirty in WorkspaceDirtySourceKeys {
        if workspaceKey = StrLower(ActiveWorkspaceId) || !dirty.Count
            continue
        if !InactiveScanQueue.Has(workspaceKey)
            InactiveScanQueue[workspaceKey] := Map()
        queued := InactiveScanQueue[workspaceKey]
        for sourceKey, token in dirty
            queued[sourceKey] := token
    }
    StartNextInactiveWorkspaceScan()
}

StartNextInactiveWorkspaceScan() {
    global InactiveScanJob, InactiveScanQueue, CacheDir, CacheWritable
    global InactiveScanGeneration
    global ActiveWorkspaceId, CurrentConfigFingerprint
    global InactiveRecentPending, SourceWatcherRecentGeneration
    global WorkerRunning
    if IsObject(InactiveScanJob) || WorkerRunning || !CacheWritable
        return
    for workspaceKey, queued in InactiveScanQueue {
        if !queued.Count {
            InactiveScanQueue.Delete(workspaceKey)
            continue
        }
        found := FindWorkspace(workspaceKey)
        if !IsObject(found) || !found.Value.Sources.Length {
            InactiveScanQueue.Delete(workspaceKey)
            continue
        }
        workspace := found.Value
        if StrLower(workspace.Id) = StrLower(ActiveWorkspaceId)
            continue
        generation := "inactive-" Format("{:016X}-{:08X}", A_TickCount,
            ++InactiveScanGeneration)
        requestPath := CacheDir "\\" generation ".request.ini"
        readyPath := CacheDir "\\" generation ".ready"
        try {
            DirCreate(readyPath)
            settings := workspace.Sources
            fingerprint := ComputeConfigFingerprint(settings, workspace.Id,
                workspace.Type, workspace.PinnedPaths)
            existing := LoadWorkspaceSnapshot(workspace.Id, fingerprint)
            scanKeys := IsObject(existing) ? queued : 0
            context := {Folders: settings, WorkspaceId: workspace.Id,
                Fingerprint: fingerprint, WorkspaceType: workspace.Type,
                PinnedPaths: workspace.PinnedPaths}
            includeRecent := InactiveRecentPending
            WriteScanRequest(requestPath, generation, scanKeys,
                includeRecent, context)
            pid := StartScanWorkerProcess(requestPath, readyPath)
            tokens := Map()
            for sourceKey, token in queued
                tokens[sourceKey] := token
            InactiveScanJob := {WorkspaceId: workspace.Id,
                Fingerprint: fingerprint, Generation: generation,
                RequestPath: requestPath, ReadyPath: readyPath, Pid: pid,
                SourceTokens: tokens, IncludeRecent: includeRecent,
                RecentToken: SourceWatcherRecentGeneration,
                Applied: Map(), Result: existing}
            InactiveRecentPending := false
            InactiveScanQueue.Delete(workspaceKey)
            SetTimer(PollInactiveWorkspaceScan, 75)
        } catch {
            try FileDelete(requestPath)
            try DirDelete(readyPath, true)
            InactiveScanQueue.Delete(workspaceKey)
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
        if IniRead(completePath, "Meta", "Generation", "") = job.Generation {
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
    global InactiveScanQueue
    workspaceKey := StrLower(job.WorkspaceId)
    if !InactiveScanQueue.Has(workspaceKey)
        InactiveScanQueue[workspaceKey] := Map()
    for sourceKey, token in job.SourceTokens
        InactiveScanQueue[workspaceKey][sourceKey] := token
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
            Fingerprint: fingerprint, Result: result}
}

FinishWorker(startPending := true) {
    global WorkerRunning, WorkerPid, WorkerRequestPath, WorkerReadyPath
    global PendingRefresh, WorkerStatusToken, WorkerFullScan
    global WorkerFingerprint, WorkerStartedTick
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
