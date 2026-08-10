; Pointer gestures, selection semantics, drag detection and pinned reordering.

FileViewLeftButtonDown(wParam, lParam, msg, hwnd) {
    global FileView, RecentView, ItemPaths, RecentItemPaths, ItemOpenContexts
    global DragPaths, DragItemContexts, SelectedFilePaths
    global DragSourceHwnd, DragStartX, DragStartY, DragStarted
    global PinnedReorderActive, PinnedReorderPath
    global TextSourceReorderActive, TextSourceReorderPath
    global TextSourceReorderSourceId
    global FilePointerGesture, FilePointerGestureSerial
    global FolderGroupHeaderGesture
    global OPEN_MODE_SINGLE

    isMainView := IsObject(FileView) && hwnd = FileView.Hwnd
    if isMainView
        pathMap := ItemPaths
    else if IsObject(RecentView) && hwnd = RecentView.Hwnd
        pathMap := RecentItemPaths
    else
        return
    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    ; ListView has no LVN_GROUPHEADERCLICK notification. Resolve the native
    ; group-header hit before item hit-testing and consume the whole gesture,
    ; otherwise icon view can treat the same point as an item/selection area.
    CancelFolderGroupHeaderGesture()
    if isMainView {
        descriptor := FindSourceGroupHeaderAtPoint(hwnd, x, y)
        if IsObject(descriptor) && HasProp(descriptor, "GroupId")
            && descriptor.GroupId {
            CancelFilePointerGesture()
            FolderGroupHeaderGesture := {
                Hwnd: hwnd,
                GroupId: descriptor.GroupId
            }
            PreviewSuppress("group-header", false)
            DllCall("user32\SetCapture", "ptr", hwnd, "ptr")
            return 0
        }
    }
    row := HitTestListRow(hwnd, x, y)
    modifiers := GetPointerModifierMask()
    path := row && pathMap.Has(row) ? pathMap[row] : ""
    selectedSnapshot := []
    if isMainView
        selectedSnapshot := SelectedFilePaths.Clone()
    else if row && path != "" && IsListRowSelected(hwnd, row)
        selectedSnapshot.Push(path)

    serial := ++FilePointerGestureSerial
    FilePointerGesture := {
        Serial: serial,
        Active: true,
        Hwnd: hwnd,
        Row: row,
        Path: path,
        Key: path != "" ? GetDisplayedItemActivationKey(hwnd, row, path) : "",
        X: x,
        Y: y,
        DownTick: A_TickCount,
        Selection: selectedSnapshot,
        Modifiers: modifiers,
        OpenRegion: row && path != "",
        ChildControl: false,
        Dragging: false,
        Marquee: !row,
        Cancelled: false
    }
    if !row
        PreviewSuppress("marquee", false)

    DragPaths := []
    DragItemContexts := []
    if row && pathMap.Has(row) {
        ; WM_LBUTTONDOWN can collapse a multi-selection before a drag reaches
        ; its movement threshold. Use the snapshot saved after the preceding
        ; Ctrl/Shift/marquee selection instead of querying the live control.
        if isMainView && ArrayContainsPath(SelectedFilePaths, pathMap[row]) {
            DragPaths := SelectedFilePaths.Clone()
        } else {
            DragPaths.Push(pathMap[row])
        }
        DragItemContexts := BuildDragItemContexts(hwnd, row, DragPaths)
    }
    DragSourceHwnd := hwnd
    DragStartX := x
    DragStartY := y
    DragStarted := false
    PinnedReorderActive := false
    PinnedReorderPath := ""
    TextSourceReorderActive := false
    TextSourceReorderPath := ""
    TextSourceReorderSourceId := ""
    ; 只根据按下行的显示上下文识别排序手势。相同路径也可能同时出现在
    ; Files 来源中，不能仅凭它存在于 PinnedPaths 就把来源项目当成固定项。
    if isMainView && DragPaths.Length = 1 && row
        && ItemOpenContexts.Has(row)
        && ItemOpenContexts[row].Area = "Pinned"
        && PathsEqual(DragPaths[1], path)
        PinnedReorderPath := DragPaths[1]
    if isMainView && DragPaths.Length = 1 && row
        && ItemOpenContexts.Has(row)
        && ItemOpenContexts[row].Area = "Source"
        && HasProp(ItemOpenContexts[row], "FolderPinned")
        && ItemOpenContexts[row].FolderPinned
        && PathsEqual(DragPaths[1], path) {
        TextSourceReorderPath := path
        TextSourceReorderSourceId := ItemOpenContexts[row].SourceId
    }

    ; 原生 ListView 会在按下已选项时先收敛多选。消息返回后恢复快照，
    ; 因而超过阈值的拖拽仍能显示并发送整组选择；未拖拽的释放再收敛。
    if isMainView && modifiers = 0 && path != ""
        && selectedSnapshot.Length > 1
        && ArrayContainsPath(selectedSnapshot, path)
        && !IsListItemFolder(FileView, row, path)
        && GetEffectiveOpenMode(GetListItemOpenContext(FileView, row))
            = OPEN_MODE_SINGLE {
        SetTimer(RestorePointerSelection.Bind(serial), -1)
    }
}

FileViewMouseMove(wParam, lParam, msg, hwnd) {
    global DragPaths, DragItemContexts, DragSourceHwnd
    global DragStartX, DragStartY, DragStarted, StatusText, StatusKind
    global PinnedReorderActive, PinnedReorderPath
    global TextSourceReorderActive, TextSourceReorderPath
    global TextSourceReorderSourceId
    global FilePointerGesture

    PreviewHandleMouseMove(hwnd, lParam)
    if IsObject(FilePointerGesture) && FilePointerGesture.Active
        && hwnd = FilePointerGesture.Hwnd
        && GetKeyState("LButton", "P") {
        pointerX := SignedMouseCoordinate(lParam & 0xFFFF)
        pointerY := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
        thresholdX := DllCall("user32\GetSystemMetrics",
            "int", 68, "int") ; SM_CXDRAG（已按当前 DPI 虚拟化）
        thresholdY := DllCall("user32\GetSystemMetrics",
            "int", 69, "int") ; SM_CYDRAG
        if Abs(pointerX - FilePointerGesture.X) >= thresholdX
            || Abs(pointerY - FilePointerGesture.Y) >= thresholdY
            FilePointerGesture.Dragging := true
    }

    if !DragPaths.Length || DragStarted || hwnd != DragSourceHwnd || !GetKeyState("LButton", "P")
        return
    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    thresholdX := DllCall("user32\GetSystemMetrics", "int", 68, "int") ; SM_CXDRAG
    thresholdY := DllCall("user32\GetSystemMetrics", "int", 69, "int") ; SM_CYDRAG
    if Abs(x - DragStartX) < thresholdX && Abs(y - DragStartY) < thresholdY
        return

    ; 在整个固定项原生分组矩形内保持排序态。只要求命中某个图块会让
    ; 图块间留白、列表行的非标签区域或快速移动意外切进 OLE，排序因而
    ; 几乎无法触发。进入 Files/Launcher 分组或离开面板时才转为 OLE。
    screenPoint := ClientToScreenPoint(hwnd, x, y)
    reorderDropTarget := PinnedReorderPath != ""
        ? ResolveDropTarget(screenPoint.X, screenPoint.Y) : 0
    if TextSourceReorderPath != ""
        reorderDropTarget := ResolveDropTarget(screenPoint.X, screenPoint.Y)
    if TextSourceReorderPath != ""
        && IsObject(reorderDropTarget)
        && reorderDropTarget.Type = "TextSource"
        && StrLower(reorderDropTarget.SourceId)
            = StrLower(TextSourceReorderSourceId) {
        if !TextSourceReorderActive {
            TextSourceReorderActive := true
            PreviewSuppress("text-source-reorder", false)
            DllCall("user32\SetCapture", "ptr", hwnd, "ptr")
            StatusKind := "user"
            StatusText.Text := "在当前文件夹的置顶文本块内可调整顺序。"
        }
        return
    }
    if TextSourceReorderActive {
        TextSourceReorderActive := false
        DllCall("user32\ReleaseCapture")
    }
    TextSourceReorderPath := ""
    TextSourceReorderSourceId := ""
    if PinnedReorderPath != ""
        && ShouldContinuePinnedReorder(reorderDropTarget) {
        if !PinnedReorderActive {
            PinnedReorderActive := true
            PreviewSuppress("pinned-reorder", false)
            DllCall("user32\SetCapture", "ptr", hwnd, "ptr")
            StatusKind := "user"
            StatusText.Text := IsTextWorkspace()
                ? "在固定项内可调整顺序；独立文本块拖到来源会移动，文件链接会复制。"
                : "在固定项内拖到另一个项目可调整顺序；拖到来源可复制。"
        }
        return
    }
    if PinnedReorderActive {
        PinnedReorderActive := false
        DllCall("user32\ReleaseCapture")
    }
    PinnedReorderPath := ""

    DragStarted := true
    PreviewSuppress("drag", false)
    paths := DragPaths
    itemContexts := DragItemContexts
    DragPaths := []
    DragItemContexts := []
    existingPaths := []
    for path in paths {
        if FileExist(path) && !ArrayContainsPath(existingPaths, path)
            existingPaths.Push(path)
    }
    if existingPaths.Length {
        StatusKind := "user"
        StatusText.Text := "本次拖拽包含 " existingPaths.Length " 个项目。"
        DllCall("user32\UpdateWindow", "ptr", StatusText.Hwnd)
        if IsTextWorkspace() && AllTextBlockPaths(existingPaths)
            && !GetKeyState("Alt", "P") {
            try {
                text := JoinTextBlocks(existingPaths)
                BeginTextDrag(text, DragSourceHwnd, existingPaths,
                    NormalizeInternalDragItems(existingPaths, itemContexts))
                for path in existingPaths
                    RecordTextBlockUse(path)
            } catch as err
                ShowPanelMsgBox(err.Message, "无法拖出文本块", "Iconx")
        } else
            BeginShellDrag(existingPaths, DragSourceHwnd,
                NormalizeInternalDragItems(existingPaths, itemContexts))
        PreviewRecoverAfterInteraction()
    }
    ; OLE 拖拽返回时原始按键释放通常已被拖放循环消费。
    CancelFilePointerGesture()
}

FileViewLeftButtonUp(wParam, lParam, msg, hwnd) {
    global FileView, ItemPaths, PinnedReorderActive, PinnedReorderPath
    global TextSourceReorderActive, TextSourceReorderPath
    global TextSourceReorderSourceId
    global DragPaths, DragItemContexts, DragStarted, StatusKind, ViewMode

    if CompleteFolderGroupHeaderClick(hwnd, lParam)
        return 0

    if !PinnedReorderActive && !TextSourceReorderActive {
        ProcessFilePointerUp(hwnd, lParam)
        DragPaths := []
        DragItemContexts := []
        DragStarted := false
        PinnedReorderPath := ""
        TextSourceReorderPath := ""
        TextSourceReorderSourceId := ""
        PreviewRecoverAfterInteraction()
        return
    }

    isSourceReorder := TextSourceReorderActive
    PinnedReorderActive := false
    TextSourceReorderActive := false
    DllCall("user32\ReleaseCapture")
    sourcePath := isSourceReorder
        ? TextSourceReorderPath : PinnedReorderPath
    sourceId := TextSourceReorderSourceId
    CancelFilePointerGesture()
    PinnedReorderPath := ""
    TextSourceReorderPath := ""
    TextSourceReorderSourceId := ""
    DragPaths := []
    DragItemContexts := []
    DragStarted := false
    PreviewRecoverAfterInteraction()
    StatusKind := "default"
    SetBackgroundStatus(isSourceReorder
        ? "文件夹内置顶顺序未更改" : "固定项顺序未更改", 1500)

    if !IsObject(FileView) || hwnd != FileView.Hwnd
        return

    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    targetRow := isSourceReorder
        ? HitTestTextSourceReorderRow(hwnd, x, y, sourceId)
        : HitTestPinnedReorderRow(hwnd, x, y)
    if !targetRow || !ItemPaths.Has(targetRow)
        return

    targetPath := ItemPaths[targetRow]

    placeAfter := false
    itemRect := Buffer(16, 0)
    NumPut("int", 0, itemRect, 0) ; LVIR_BOUNDS
    if DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x100E,
        "ptr", targetRow - 1, "ptr", itemRect.Ptr, "ptr") {
        if isSourceReorder || ViewMode = "Thumbnail" {
            left := NumGet(itemRect, 0, "int")
            right := NumGet(itemRect, 8, "int")
            placeAfter := x >= Floor((left + right) / 2)
        } else {
            top := NumGet(itemRect, 4, "int")
            bottom := NumGet(itemRect, 12, "int")
            placeAfter := y >= Floor((top + bottom) / 2)
        }
    }

    saved := isSourceReorder
        ? ReorderTextSourcePinnedPath(
            sourceId, sourcePath, targetPath, placeAfter)
        : ReorderPinnedPath(sourcePath, targetPath, placeAfter)
    if saved {
        StatusKind := "default"
        SetBackgroundStatus(isSourceReorder
            ? "已保存文件夹内置顶顺序" : "已保存固定项顺序", 3000)
    }
}

CompleteFolderGroupHeaderClick(hwnd, lParam) {
    global FolderGroupHeaderGesture
    if !IsObject(FolderGroupHeaderGesture)
        return false

    gesture := FolderGroupHeaderGesture
    FolderGroupHeaderGesture := 0
    if DllCall("user32\GetCapture", "ptr") = gesture.Hwnd
        DllCall("user32\ReleaseCapture")
    ; End the temporary hover suppression before toggling. A collapse may then
    ; intentionally hide the preview without this cleanup reopening it.
    PreviewRecoverAfterInteraction()

    if hwnd = gesture.Hwnd {
        x := SignedMouseCoordinate(lParam & 0xFFFF)
        y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
        descriptor := FindSourceGroupHeaderAtPoint(hwnd, x, y)
        if IsObject(descriptor) && HasProp(descriptor, "GroupId")
            && descriptor.GroupId = gesture.GroupId
            ToggleFolderGroupCollapsed(gesture.GroupId)
    }
    return true
}

ProcessFilePointerUp(hwnd, lParam) {
    global FilePointerGesture, FileView, RecentView
    if !IsObject(FilePointerGesture) || !FilePointerGesture.Active
        return
    if IsObject(FileView) && hwnd = FileView.Hwnd
        list := FileView
    else if IsObject(RecentView) && hwnd = RecentView.Hwnd
        list := RecentView
    else
        return

    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    row := HitTestListRow(hwnd, x, y)
    ProcessFilePointerRelease(list, row)
}

FileViewClick(list, row, *) {
    ; NM_CLICK 是原生 ListView 在左键释放阶段发出的通知。部分版本会在
    ; WM_LBUTTONUP 回调前先释放捕获，因此这里作为同一状态机的可靠入口。
    ProcessFilePointerRelease(list, row)
}

ProcessFilePointerRelease(list, row) {
    global FilePointerGesture, FileView, RecentView
    global ItemPaths, RecentItemPaths, OPEN_MODE_SINGLE

    if !IsObject(FilePointerGesture) || !FilePointerGesture.Active
        return
    gesture := FilePointerGesture
    ; 先清理，避免打开程序、错误对话框或焦点变化重入本次手势。
    FilePointerGesture := 0

    if gesture.Cancelled || gesture.Dragging || gesture.Marquee
        || gesture.ChildControl || !gesture.OpenRegion
        || list.Hwnd != gesture.Hwnd || gesture.Modifiers != 0
        || GetPointerModifierMask() != 0
        return

    if IsObject(FileView) && list.Hwnd = FileView.Hwnd
        pathMap := ItemPaths
    else if IsObject(RecentView) && list.Hwnd = RecentView.Hwnd
        pathMap := RecentItemPaths
    else
        return
    if !row || !pathMap.Has(row)
        return

    path := pathMap[row]
    releaseKey := GetDisplayedItemActivationKey(list.Hwnd, row, path)
    if releaseKey = "" || releaseKey != gesture.Key
        || !PathsEqual(path, gesture.Path)
        return

    if IsListItemFolder(list, row, path)
        return
    if GetEffectiveOpenMode(GetListItemOpenContext(list, row))
        != OPEN_MODE_SINGLE
        return

    ; 无修饰键释放把此前的多选收敛到当前文件，只激活这一项。
    CollapseListSelectionToRow(list, row)
    if ShouldSuppressRepeatedPointerActivation(releaseKey)
        return
    OpenItemWithDefaultApplication(path)
}

RestorePointerSelection(serial) {
    global FilePointerGesture, FileView, ItemPaths
    if !IsObject(FilePointerGesture) || !FilePointerGesture.Active
        || FilePointerGesture.Serial != serial
        || FilePointerGesture.Hwnd != FileView.Hwnd
        || FilePointerGesture.Modifiers != 0
        || !GetKeyState("LButton", "P")
        return
    snapshot := FilePointerGesture.Selection
    if snapshot.Length <= 1
        return
    FileView.Modify(0, "-Select")
    for row, path in ItemPaths {
        if ArrayContainsPath(snapshot, path)
            FileView.Modify(row, "Select")
    }
    if FilePointerGesture.Row
        FileView.Modify(FilePointerGesture.Row, "Focus Vis")
}

CollapseListSelectionToRow(list, row, updateImmediately := false) {
    list.Modify(0, "-Select -Focus")
    list.Modify(row, "Select Focus Vis")
    if updateImmediately
        UpdateSelectionStatus()
    else
        SetTimer(UpdateSelectionStatus, -1)
}

GetPointerModifierMask() {
    mask := 0
    if GetKeyState("Ctrl", "P")
        mask |= 0x01
    if GetKeyState("Shift", "P")
        mask |= 0x02
    if GetKeyState("Alt", "P")
        mask |= 0x04
    if GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
        mask |= 0x08
    return mask
}

GetDisplayedItemActivationKey(hwnd, row, path) {
    global FileView, RecentView, ItemOpenContexts
    normalizedKey := PathKey(path)
    if normalizedKey = ""
        return ""
    if IsObject(FileView) && hwnd = FileView.Hwnd {
        if ItemOpenContexts.Has(row) {
            context := ItemOpenContexts[row]
            if context.Area = "Source"
                return "source|" StrLower(context.SourceId)
                    . "|" normalizedKey
            if context.Area = "Pinned"
                return "pinned|" normalizedKey
        }
        return "main|" normalizedKey
    }
    if IsObject(RecentView) && hwnd = RecentView.Hwnd
        return "recent|" normalizedKey
    return ""
}

ShouldSuppressRepeatedPointerActivation(key) {
    global LastPointerActivationKey, LastPointerActivationTick
    now := A_TickCount
    doubleClickTime := DllCall("user32\GetDoubleClickTime", "uint")
    elapsed := LastPointerActivationTick = 0
        ? doubleClickTime + 1
        : ElapsedTickMilliseconds(LastPointerActivationTick, now)
    if key = LastPointerActivationKey && elapsed <= doubleClickTime
        return true
    LastPointerActivationKey := key
    LastPointerActivationTick := now
    return false
}

ElapsedTickMilliseconds(earlier, later) {
    if later >= earlier
        return later - earlier
    return (0xFFFFFFFF - earlier) + later + 1
}

CancelFilePointerGesture(*) {
    global FilePointerGesture, DragPaths, DragItemContexts, DragStarted
    if IsObject(FilePointerGesture)
        FilePointerGesture.Cancelled := true
    FilePointerGesture := 0
    DragPaths := []
    DragItemContexts := []
    DragStarted := false
    CancelFolderGroupHeaderGesture()
}

CancelFolderGroupHeaderGesture(*) {
    global FolderGroupHeaderGesture
    if !IsObject(FolderGroupHeaderGesture)
        return false
    gesture := FolderGroupHeaderGesture
    FolderGroupHeaderGesture := 0
    if HasProp(gesture, "Hwnd")
        && DllCall("user32\GetCapture", "ptr") = gesture.Hwnd
        DllCall("user32\ReleaseCapture")
    PreviewRecoverAfterInteraction()
    return true
}

CancelFilePointerGestureForHwnd(hwnd) {
    global FilePointerGesture, FolderGroupHeaderGesture
    if IsObject(FolderGroupHeaderGesture)
        && FolderGroupHeaderGesture.Hwnd = hwnd
        CancelFolderGroupHeaderGesture()
    if IsObject(FilePointerGesture)
        && FilePointerGesture.Active
        && FilePointerGesture.Hwnd = hwnd
        CancelFilePointerGesture()
}

IsTrackedFileViewHwnd(hwnd) {
    global FileView, RecentView
    return (IsObject(FileView) && hwnd = FileView.Hwnd)
        || (IsObject(RecentView) && hwnd = RecentView.Hwnd)
}

FileViewRightButtonDown(wParam, lParam, msg, hwnd) {
    global PendingContextMenuMouseShift, PendingContextMenuKeyboardAlternate
    if IsTrackedFileViewHwnd(hwnd) {
        CancelFilePointerGesture()
        PreviewSuppress("context-menu", false)
        if PendingContextMenuKeyboardAlternate.Has(hwnd)
            PendingContextMenuKeyboardAlternate.Delete(hwnd)
        ; ContextMenu is raised after the button message. Capture Shift now so
        ; a quick key release cannot turn Shift+right-click into a default-menu
        ; invocation.
        PendingContextMenuMouseShift[hwnd] := GetKeyState("Shift", "P")
    }
}

FileViewContextMenuKeyDown(wParam, lParam, msg, hwnd) {
    global PendingContextMenuKeyboardAlternate, PendingContextMenuMouseShift
    if !IsTrackedFileViewHwnd(hwnd)
        return
    PreviewHandleKeyDown(wParam, hwnd, lParam)
    static VK_F10 := 0x79
    static VK_APPS := 0x5D
    if PendingContextMenuMouseShift.Has(hwnd)
        PendingContextMenuMouseShift.Delete(hwnd)
    if wParam = VK_APPS {
        ; AppsKey always opens the configured default, even if Shift happens
        ; to be held for an unrelated selection gesture.
        PendingContextMenuKeyboardAlternate[hwnd] := false
    } else if wParam = VK_F10 && GetKeyState("Shift", "P") {
        PendingContextMenuKeyboardAlternate[hwnd] := true
    }
}

FileViewCancelInteraction(wParam, lParam, msg, hwnd) {
    if IsTrackedFileViewHwnd(hwnd) {
        CancelFilePointerGesture()
        PreviewSuppress("scroll", true)
    }
}

FileViewCancelMode(wParam, lParam, msg, hwnd) {
    if IsTrackedFileViewHwnd(hwnd)
        CancelFilePointerGestureForHwnd(hwnd)
}

FileViewCaptureChanged(wParam, lParam, msg, hwnd) {
    ; 原生 ListView 在正常释放期间也会发 WM_CAPTURECHANGED。此时物理
    ; 左键已抬起，NM_CLICK/WM_LBUTTONUP 仍需消费手势，不能提前清除。
    ; 只有按键仍按住时的捕获转移才是真正的取消/外部抢占。
    if IsTrackedFileViewHwnd(hwnd) && GetKeyState("LButton", "P")
        CancelFilePointerGestureForHwnd(hwnd)
}

FileViewKillFocus(wParam, lParam, msg, hwnd) {
    ResetTextBlockImeCompositionForFocusLoss(hwnd)
    if IsTrackedFileViewHwnd(hwnd) {
        CancelFilePointerGestureForHwnd(hwnd)
        PreviewHide("focus", true)
    }
}

SignedMouseCoordinate(value) {
    return value >= 0x8000 ? value - 0x10000 : value
}

PointInsideControl(hwnd, x, y) {
    if x < 0 || y < 0
        return false
    rect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", hwnd, "ptr", rect.Ptr)
        return false
    return x < NumGet(rect, 8, "int") && y < NumGet(rect, 12, "int")
}

HitTestListRow(hwnd, x, y) {
    hitInfo := Buffer(24, 0)
    NumPut("int", x, hitInfo, 0)
    NumPut("int", y, hitInfo, 4)
    zeroBasedRow := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1012, "ptr", 0, "ptr", hitInfo.Ptr, "int") ; LVM_HITTEST
    return zeroBasedRow >= 0 ? zeroBasedRow + 1 : 0
}

HitTestListItemBounds(hwnd, x, y) {
    row := HitTestListRow(hwnd, x, y)
    if row
        return row
    if !PointInsideControl(hwnd, x, y)
        return 0
    itemCount := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1004, "ptr", 0, "ptr", 0, "int") ; LVM_GETITEMCOUNT
    firstVisible := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1027, "ptr", 0, "ptr", 0, "int") + 1 ; LVM_GETTOPINDEX
    perPage := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1028, "ptr", 0, "ptr", 0, "int") ; LVM_GETCOUNTPERPAGE
    firstCandidate := Max(1, firstVisible - 12)
    lastCandidate := Min(itemCount,
        firstVisible + Max(64, perPage + 48))
    Loop lastCandidate - firstCandidate + 1 {
        candidateRow := firstCandidate + A_Index - 1
        bounds := GetListItemBounds(hwnd, candidateRow)
        if IsObject(bounds)
            && x >= bounds.Left && x < bounds.Right
            && y >= bounds.Top && y < bounds.Bottom
            return candidateRow
    }
    return 0
}

HitTestPinnedReorderRow(hwnd, x, y) {
    global FileView, ItemOpenContexts
    if !IsObject(FileView) || hwnd != FileView.Hwnd
        return 0

    row := HitTestListRow(hwnd, x, y)
    if IsPinnedItemRow(row)
        return row

    ; LVM_HITTEST 在图标/标签之外的可见行区域可能返回 -1。使用原生
    ; LVIR_BOUNDS 补充命中，兼容缩略图、列表视图、DPI、缩放和滚动。
    for candidateRow, context in ItemOpenContexts {
        if context.Area != "Pinned"
            continue
        itemRect := GetListItemBounds(hwnd, candidateRow)
        if IsObject(itemRect)
            && x >= itemRect.Left && x < itemRect.Right
            && y >= itemRect.Top && y < itemRect.Bottom
            return candidateRow
    }
    return 0
}

HitTestTextSourceReorderRow(hwnd, x, y, sourceId) {
    global FileView, ItemOpenContexts
    if !IsObject(FileView) || hwnd != FileView.Hwnd
        return 0
    row := HitTestListRow(hwnd, x, y)
    if IsTextSourcePinnedReorderRow(row, sourceId)
        return row
    for candidateRow, context in ItemOpenContexts {
        if !IsTextSourcePinnedReorderRow(candidateRow, sourceId)
            continue
        itemRect := GetListItemBounds(hwnd, candidateRow)
        if IsObject(itemRect)
            && x >= itemRect.Left && x < itemRect.Right
            && y >= itemRect.Top && y < itemRect.Bottom
            return candidateRow
    }
    return 0
}

IsTextSourcePinnedReorderRow(row, sourceId) {
    global ItemOpenContexts
    if !row || !ItemOpenContexts.Has(row)
        return false
    context := ItemOpenContexts[row]
    return context.Area = "Source"
        && HasProp(context, "FolderPinned") && context.FolderPinned
        && StrLower(context.SourceId) = StrLower(sourceId)
}

IsPinnedItemRow(row) {
    global ItemOpenContexts
    return row && ItemOpenContexts.Has(row)
        && ItemOpenContexts[row].Area = "Pinned"
}

GetListItemBounds(hwnd, row) {
    if !row
        return 0
    itemRect := Buffer(16, 0)
    NumPut("int", 0, itemRect, 0) ; LVIR_BOUNDS
    if !DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x100E,
        "ptr", row - 1, "ptr", itemRect.Ptr, "ptr")
        return 0
    return {
        Left: NumGet(itemRect, 0, "int"),
        Top: NumGet(itemRect, 4, "int"),
        Right: NumGet(itemRect, 8, "int"),
        Bottom: NumGet(itemRect, 12, "int")
    }
}

BuildDragItemContexts(hwnd, clickedRow, paths) {
    global FileView, RecentView, ItemPaths, ItemOpenContexts, RecentItemPaths
    result := []
    if IsObject(FileView) && hwnd = FileView.Hwnd {
        selectedRows := GetSelectedFileRows()
        useSelected := selectedRows.Length > 1
            && clickedRow && IsListRowSelected(hwnd, clickedRow)
        rows := useSelected ? selectedRows : [clickedRow]
        for row in rows {
            if !ItemPaths.Has(row)
                continue
            context := ItemOpenContexts.Has(row)
                ? CloneDropItemContext(ItemOpenContexts[row])
                : {Area: "Unknown"}
            context.Path := ItemPaths[row]
            result.Push(context)
        }
    } else if IsObject(RecentView) && hwnd = RecentView.Hwnd
        && clickedRow && RecentItemPaths.Has(clickedRow) {
        result.Push({Area: "Recent", Path: RecentItemPaths[clickedRow]})
    }
    return result
}

CloneDropItemContext(context) {
    clone := {Area: HasProp(context, "Area") ? context.Area : "Unknown"}
    for property in ["SourceId", "SourcePath", "SourceMode", "GroupId"] {
        if HasProp(context, property)
            clone.%property% := context.%property%
    }
    return clone
}

NormalizeInternalDragItems(paths, contexts) {
    result := []
    for path in paths {
        item := {Path: path, Area: "Unknown"}
        matching := []
        for context in contexts {
            if HasProp(context, "Path") && PathsEqual(context.Path, path)
                matching.Push(context)
        }
        if matching.Length = 1 {
            item := CloneDropItemContext(matching[1])
            item.Path := path
        } else if matching.Length > 1 {
            first := matching[1]
            uniform := true
            for context in matching {
                if context.Area != first.Area {
                    uniform := false
                    break
                }
                if context.Area = "Source"
                    && (!HasProp(context, "SourceId")
                        || !HasProp(first, "SourceId")
                        || StrLower(context.SourceId) != StrLower(first.SourceId)) {
                    uniform := false
                    break
                }
            }
            if uniform {
                item := CloneDropItemContext(first)
                item.Path := path
            } else
                item := {Path: path, Area: "Mixed"}
        }
        result.Push(item)
    }
    return result
}

ReorderPinnedPath(sourcePath, targetPath, placeAfter) {
    global PinnedPaths

    sourceIndex := FindPathIndex(PinnedPaths, sourcePath)
    targetIndex := FindPathIndex(PinnedPaths, targetPath)
    if !sourceIndex || !targetIndex || sourceIndex = targetIndex
        return false

    originalPaths := PinnedPaths.Clone()
    PinnedPaths.RemoveAt(sourceIndex)
    targetIndex := FindPathIndex(PinnedPaths, targetPath)
    insertAt := targetIndex + (placeAfter ? 1 : 0)
    PinnedPaths.InsertAt(insertAt, sourcePath)

    if PathArraysEqual(PinnedPaths, originalPaths)
        return false

    try SavePinnedFiles()
    catch as err {
        RestoreActivePinnedPaths(originalPaths)
        try SavePinnedFiles()
        ShowPanelMsgBox(
            "无法保存固定项顺序：`n" err.Message,
            "固定项排序失败",
            "Iconx"
        )
        return false
    }

    PopulatePanel()
    return true
}

PathArraysEqual(left, right) {
    if left.Length != right.Length
        return false
    for index, path in left {
        if !PathsEqual(path, right[index])
            return false
    }
    return true
}
