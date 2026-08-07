; Item activation, selection, pinning and legacy configuration dialogs.

GetFileName(path) {
    SplitPath(path, &name)
    return name != "" ? name : path
}

OpenFileViewItem(list, row) {
    global ItemPaths, OPEN_MODE_SINGLE
    if !ItemPaths.Has(row)
        return
    PreviewHide("open", true)
    path := ItemPaths[row]
    if GetPointerModifierMask() != 0
        return
    if IsTextWorkspace() && IsTextBlockPath(path) {
        QuickSendTextBlocks([path])
        return
    }
    ; 文件夹始终保持双击激活，不受单击模式影响。
    if IsListItemFolder(list, row, path) {
        OpenFolderInFileManager(path)
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
    PreviewHide("open", true)
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

OpenItemWithDefaultApplication(path, *) {
    CloseExternalQuickPreview()
    if DirExist(path) {
        OpenFolderInFileManager(path)
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
    Hotkey("+Delete", PanelPermanentDeleteSelection)
    ; Do not register Shift+F10 separately. The native ListView ContextMenu
    ; event handles both Shift+F10 and AppsKey, preventing one gesture from
    ; opening a hotkey menu and then a second native-control menu.
    Hotkey("^Enter", PanelRevealSelection)
    Hotkey("^c", PanelCopyFileObjects)
    Hotkey("^+c", PanelCopyPaths)
    Hotkey("F4", PanelEditTextBlock)
    HotIf(IsPopDropPanelActive)
    Hotkey("^f", FocusTextBlockSearch)
    Loop 9
        Hotkey("^" A_Index, SwitchWorkspaceByPosition.Bind(A_Index))
    Hotkey("^Tab", CycleWorkspace.Bind(1))
    Hotkey("^+Tab", CycleWorkspace.Bind(-1))
    HotIf(CanFocusTextBlockSearch)
    Hotkey("/", FocusTextBlockSearch)
    HotIf(IsTextBlockSearchActive)
    Hotkey("Down", FocusTextBlockResults)
    Hotkey("Tab", FocusTextBlockResults)
    HotIf(IsTextBlockSearchResultReady)
    Hotkey("Enter", ActivateTextBlockSearchResult)
    ; Ctrl+V is intentionally registered only for the text-card surface and
    ; the panel container. Editable controls keep the native paste behavior.
    HotIf(CanPasteClipboardAsPinnedTextBlock)
    Hotkey("^v", PasteClipboardAsPinnedTextBlock)
    HotIf(IsPanelQuickPreviewAvailable)
    Hotkey("Space", HandlePanelQuickPreviewSpace)
    HotIf(IsPanelQuickPreviewActive)
    Hotkey("Esc", QuickPreviewEscape)
    ; QuickLook keeps full ownership of its keyboard. Seer's main preview does
    ; not reliably toggle closed after a 5000 invocation, so handle Space only
    ; on that exact top-level window. Menus, popups and dialogs are excluded by
    ; IsSeerMainPreviewFocused and keep their native keyboard behavior.
    HotIf(IsSeerMainPreviewFocused)
    Hotkey("Space", CloseSeerQuickPreviewFromSpace)
    HotIf()
}

IsPopDropPanelActive(*) {
    global Panel, PanelVisible
    return PanelVisible && IsObject(Panel)
        && WinActive("ahk_id " Panel.Hwnd)
}

SwitchWorkspaceByPosition(position, *) {
    global Workspaces
    if position >= 1 && position <= Workspaces.Length
        QueuePanelWorkspaceSwitch(Workspaces[position].Id)
}

CycleWorkspace(direction, *) {
    QueuePanelWorkspaceCycle(direction)
}

QueuePanelWorkspaceSwitch(workspaceId) {
    global PendingPanelWorkspaceId, PanelWorkspaceSwitchGeneration
    found := FindWorkspace(workspaceId)
    if !IsObject(found)
        return false
    previousCritical := A_IsCritical
    Critical("On")
    try {
        PendingPanelWorkspaceId := found.Value.Id
        generation := ++PanelWorkspaceSwitchGeneration
        SetTimer(CommitPanelWorkspaceSwitch.Bind(generation), -25)
    } finally {
        Critical(previousCritical)
    }
    return true
}

QueuePanelWorkspaceCycle(direction) {
    global Workspaces, ActiveWorkspaceId, PendingPanelWorkspaceId
    global PanelWorkspaceSwitchGeneration
    if Workspaces.Length < 2
        return false
    previousCritical := A_IsCritical
    Critical("On")
    try {
        baseId := PendingPanelWorkspaceId != ""
            ? PendingPanelWorkspaceId : ActiveWorkspaceId
        found := FindWorkspace(baseId)
        current := IsObject(found) ? found.Index : 1
        next := Mod(current - 1 + direction + Workspaces.Length,
            Workspaces.Length) + 1
        PendingPanelWorkspaceId := Workspaces[next].Id
        generation := ++PanelWorkspaceSwitchGeneration
        SetTimer(CommitPanelWorkspaceSwitch.Bind(generation), -25)
    } finally {
        Critical(previousCritical)
    }
    return true
}

CommitPanelWorkspaceSwitch(generation) {
    global PendingPanelWorkspaceId, PanelWorkspaceSwitchGeneration
    global PanelWorkspaceSwitchRunning
    previousCritical := A_IsCritical
    Critical("On")
    try {
        if generation != PanelWorkspaceSwitchGeneration
            return
        ; The active dispatcher owns the current switch. Leave the newest
        ; target pending; its finally block schedules exactly one successor.
        if PanelWorkspaceSwitchRunning
            return
        workspaceId := PendingPanelWorkspaceId
        if workspaceId = ""
            return
        PendingPanelWorkspaceId := ""
        PanelWorkspaceSwitchRunning := true
    } finally {
        Critical(previousCritical)
    }
    try ActivateWorkspace(workspaceId)
    finally {
        previousCritical := A_IsCritical
        Critical("On")
        try {
            PanelWorkspaceSwitchRunning := false
            if PendingPanelWorkspaceId != "" {
                generation := PanelWorkspaceSwitchGeneration
                SetTimer(CommitPanelWorkspaceSwitch.Bind(generation), -1)
            }
        } finally {
            Critical(previousCritical)
        }
    }
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
    PreviewHide("open", true)
    context := GetActiveSelectionContext()
    if context.Paths.Length {
        if IsTextWorkspace()
            QuickSendTextBlocks(context.Paths)
        else
            OpenSelectedItems(context.Paths)
    }
}

PanelDeleteSelection(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length
        DeletePathsToRecycleBin(context.Paths)
}

PanelPermanentDeleteSelection(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length
        DeletePathsPermanently(context.Paths)
}

PanelRevealSelection(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length
        RevealItemsInFileManager(context.Paths)
}

PanelCopyFileObjects(*) {
    context := GetActiveSelectionContext()
    if context.Paths.Length {
        if IsTextWorkspace()
            CopyTextBlocks(context.Paths)
        else
            CopyFileObjectsToClipboard(context.Paths)
    }
}

PanelEditTextBlock(*) {
    if !IsTextWorkspace()
        return
    context := GetActiveSelectionContext()
    if context.Paths.Length = 1
        OpenTextBlockEditor(context.Paths[1])
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
        QuickPreviewScheduleUpdate()
    }
}

RecentContextMenu(list, row, isRightClick, x, y) {
    global RecentItemPaths
    CancelFilePointerGesture()
    PreviewSuppress("context-menu", false)
    if !row && !isRightClick {
        row := list.GetNext(0, "F")
        if !row
            row := list.GetNext(0)
    }
    if !row || !RecentItemPaths.Has(row) {
        PreviewRecoverAfterInteraction()
        return
    }
    if !IsListRowSelected(list.Hwnd, row) {
        list.Modify(0, "-Select -Focus")
        list.Modify(row, "Select Focus Vis")
    }
    path := RecentItemPaths[row]
    if !FileExist(path) {
        ShowPanelMsgBox("文件不存在或当前无法访问：`n" path, "右键菜单", "Icon!")
        PreviewRecoverAfterInteraction()
        return
    }
    alternate := ContextMenuGestureIsAlternate(list.Hwnd, isRightClick)
    ShowConfiguredContextMenu(
        [path], path, list.Gui.Hwnd, x, y, alternate)
    PreviewRecoverAfterInteraction()
}

FileViewItemSelect(list, row, selected) {
    ; A range or marquee selection emits several ItemSelect events. Defer the
    ; summary until the control has finished updating the full selection.
    ; Owner-drawn text cards need an explicit row invalidation because native
    ; icon-view marquee updates do not consistently repaint custom draw items.
    rect := GetListItemRect(list.Hwnd, row)
    if IsObject(rect) {
        nativeRect := Buffer(16, 0)
        NumPut("int", rect.Left, nativeRect, 0)
        NumPut("int", rect.Top, nativeRect, 4)
        NumPut("int", rect.Right, nativeRect, 8)
        NumPut("int", rect.Bottom, nativeRect, 12)
        DllCall("user32\InvalidateRect", "ptr", list.Hwnd,
            "ptr", nativeRect.Ptr, "int", 0)
    }
    SetTimer(UpdateSelectionStatus, -1)
    QuickPreviewScheduleUpdate()
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

    filter := IsTextWorkspace() ? "文本块 (*.md; *.txt)" : ""
    try selected := SelectPanelFile("M3", , "选择要加入固定项的文件", filter)
    catch
        return
    if !IsObject(selected)
        return

    newPaths := []
    for path in selected {
        path := NormalizePath(path)
        if path != ""
            && (!IsTextWorkspace() || IsTextBlockPath(path))
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
        RestoreActivePinnedPaths(original)
        ShowPanelMsgBox("无法保存固定项：`n" err.Message,
            "添加固定项失败", "Iconx")
    }
}

RemoveSelectionFromPinned(paths, *) {
    if IsTextWorkspace()
        return RemovePinnedTextBlocks(paths)
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
        RestoreActivePinnedPaths(original)
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
    global AutoHidePanelShownTick, AutoHideNativeShownTick

    if WindowMode != WINDOW_MODE_TEMPORARY || !IsObject(Panel)
        return

    if !DllCall("user32\IsWindowVisible", "ptr", Panel.Hwnd, "int")
        try Panel.Show("NA")

    PanelVisible := DllCall(
        "user32\IsWindowVisible",
        "ptr", Panel.Hwnd,
        "int"
    )
    if PanelVisible {
        ; A queued auto-hide can win while DoDragDrop is unwinding, which
        ; stops the repeating watchdog. Restoring the panel must restore the
        ; complete temporary-mode lifecycle, not merely make the HWND visible.
        AutoHidePanelShownTick := A_TickCount
        AutoHideNativeShownTick := A_TickCount
        StartAutoHideWatchdog()
        try WinActivate("ahk_id " Panel.Hwnd)
    }
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
            RestoreActivePinnedPaths(originalPinnedPaths)
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
    if IsTextWorkspace() {
        paths := []
        for row in rows {
            if FindPathIndex(PinnedPaths, ItemPaths[row])
                paths.Push(ItemPaths[row])
        }
        return RemovePinnedTextBlocks(paths)
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
    SyncActiveWorkspacePinnedState()
    AtomicConfigEdit(WritePinnedFilesConfig)
    RefreshScanAfterPinnedChange()
}

WritePinnedFilesConfig(tempPath) {
    global PinnedPaths, ActiveWorkspaceId, CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    WritePinnedPathsToDocument(doc,
        "WorkspacePinned:" ActiveWorkspaceId, PinnedPaths, 3)
    doc.SetValue("Workspaces", "PinnedScopeVersion", "1", 3)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

SyncActiveWorkspacePinnedState() {
    global Workspaces, ActiveWorkspaceId, PinnedPaths
    found := FindWorkspace(ActiveWorkspaceId, Workspaces)
    if !IsObject(found)
        throw Error("保存固定项时找不到当前工作区。")
    found.Value.PinnedPaths := PinnedPaths
}

RestoreActivePinnedPaths(paths) {
    global PinnedPaths
    PinnedPaths := paths
    SyncActiveWorkspacePinnedState()
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

    saveButton := AddUiButton(settingsGui, "xm y+20 w90 Default", "保存")
    cancelButton := AddUiButton(settingsGui, "x+8 yp w90", "取消")
    advancedButton := AddUiButton(settingsGui, "x+8 yp w150",
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
