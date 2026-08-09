; List notifications, source management and selection context menus.

FileViewNotify(wParam, lParam, msg, hwnd) {
    global FileView
    ; NMHDR structure: hwndFrom, idFrom, code
    if !IsSet(FileView) || !IsObject(FileView)
        return
    hwndFrom := NumGet(lParam + 0, "ptr")
    if hwndFrom != FileView.Hwnd
        return

    ; NMHDR structure: hwndFrom, idFrom, code
    code := NumGet(lParam + 0, A_PtrSize * 2, "int")
    if code = -12
        return IsTextWorkspace()
            ? DrawTextBlockCard(lParam)
            : DrawPinnedFileLinkIcon(lParam)
}

FolderGroupCollapseKey(workspaceId, sourceId, path) {
    workspaceKey := StrLower(Trim(workspaceId))
    sourceKey := StrLower(Trim(sourceId))
    if sourceKey = "" && path != ""
        sourceKey := PathKey(path)
    return workspaceKey != "" && sourceKey != ""
        ? workspaceKey "|" sourceKey : ""
}

IsFolderGroupCollapseRemembered(workspaceId, sourceId, path) {
    global CollapsedFolderGroups
    key := FolderGroupCollapseKey(workspaceId, sourceId, path)
    return key != "" && CollapsedFolderGroups.Has(key)
}

RememberFolderGroupCollapse(descriptor, collapsed) {
    global CollapsedFolderGroups
    key := FolderGroupCollapseKey(
        HasProp(descriptor, "WorkspaceId") ? descriptor.WorkspaceId : "",
        HasProp(descriptor, "SourceId") ? descriptor.SourceId : "",
        HasProp(descriptor, "Path") ? descriptor.Path : "")
    if key = ""
        return false
    if collapsed
        CollapsedFolderGroups[key] := true
    else if CollapsedFolderGroups.Has(key)
        CollapsedFolderGroups.Delete(key)
    return true
}

FormatFolderGroupHeader(header, collapsed) {
    return (collapsed ? "⋀ " : "⋁ ") header
}

IsListGroupCollapsed(hwnd, groupId) {
    return (DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x105C, "ptr", groupId, "ptr", 0x1,
        "uint") & 0x1) != 0 ; LVM_GETGROUPSTATE / LVGS_COLLAPSED
}

SetListGroupCollapsed(hwnd, groupId, collapsed) {
    groupSize := A_PtrSize = 8 ? 152 : 96
    stateMaskOffset := A_PtrSize = 8 ? 40 : 28
    stateOffset := A_PtrSize = 8 ? 44 : 32
    group := Buffer(groupSize, 0)
    NumPut("uint", groupSize, group, 0)
    NumPut("uint", 0x4, group, 4) ; LVGF_STATE
    NumPut("uint", 0x1, group, stateMaskOffset) ; LVGS_COLLAPSED
    NumPut("uint", collapsed ? 0x1 : 0, group, stateOffset)
    return DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1093, "ptr", groupId, "ptr", group.Ptr,
        "int") != -1 ; LVM_SETGROUPINFOW
}

ClearCollapsedGroupSelection(groupId) {
    global FileView, ItemOpenContexts
    changed := false
    for row, context in ItemOpenContexts {
        if !HasProp(context, "GroupId") || context.GroupId != groupId
            continue
        if IsListRowSelected(FileView.Hwnd, row) {
            FileView.Modify(row, "-Select -Focus")
            changed := true
        }
    }
    if changed
        UpdateSelectionStatus()
    return changed
}

ToggleFolderGroupCollapsed(groupId) {
    global FileView, GroupDropTargets
    if !IsObject(FileView) || !GroupDropTargets.Has(groupId)
        return false
    descriptor := GroupDropTargets[groupId]
    if !IsSourceManagementDescriptor(descriptor)
        return false
    collapsed := !IsListGroupCollapsed(FileView.Hwnd, groupId)
    if !SetListGroupCollapsed(FileView.Hwnd, groupId, collapsed)
        return false
    RememberFolderGroupCollapse(descriptor, collapsed)
    CancelFilePointerGesture()
    if collapsed {
        ClearCollapsedGroupSelection(groupId)
        PreviewHide("group-collapse", true)
    }
    header := HasProp(descriptor, "BaseHeader")
        ? descriptor.BaseHeader : descriptor.Name
    SetListGroupHeader(FileView.Hwnd, groupId,
        FormatFolderGroupHeader(header, collapsed))
    ; Files groups may currently include live transfer progress. Reapply it
    ; after changing the prefix so neither state indicator nor progress is lost.
    UpdateTransferGroupHeaders()
    DllCall("user32\RedrawWindow", "ptr", FileView.Hwnd,
        "ptr", 0, "ptr", 0, "uint", 0x0001 | 0x0080 | 0x0100, "int")
    return true
}

SetAllFolderGroupsCollapsed(collapsed) {
    global FileView, GroupDropTargets
    if !IsObject(FileView)
        return 0
    sourceGroups := SourceFolderGroupIds(GroupDropTargets)
    if !sourceGroups.Length
        return 0
    CancelFilePointerGesture()
    changed := 0
    for groupId in sourceGroups {
        descriptor := GroupDropTargets[groupId]
        if IsListGroupCollapsed(FileView.Hwnd, groupId) != collapsed {
            if !SetListGroupCollapsed(FileView.Hwnd, groupId, collapsed)
                continue
            changed += 1
        }
        RememberFolderGroupCollapse(descriptor, collapsed)
        if collapsed
            ClearCollapsedGroupSelection(groupId)
        header := HasProp(descriptor, "BaseHeader")
            ? descriptor.BaseHeader : descriptor.Name
        SetListGroupHeader(FileView.Hwnd, groupId,
            FormatFolderGroupHeader(header, collapsed))
    }
    if collapsed {
        PreviewHide("group-collapse-all", true)
        UpdateSelectionStatus()
    }
    UpdateTransferGroupHeaders()
    DllCall("user32\RedrawWindow", "ptr", FileView.Hwnd,
        "ptr", 0, "ptr", 0, "uint", 0x0001 | 0x0080 | 0x0100, "int")
    SetUserStatus(collapsed
        ? "已收起当前工作区的全部文件夹"
        : "已展开当前工作区的全部文件夹")
    return changed
}

SourceFolderGroupIds(descriptors) {
    result := []
    for groupId, descriptor in descriptors
        if IsSourceManagementDescriptor(descriptor)
            result.Push(groupId)
    return result
}

ExpandAllFolderGroups(*) {
    return SetAllFolderGroupsCollapsed(false)
}

CollapseAllFolderGroups(*) {
    return SetAllFolderGroupsCollapsed(true)
}

DrawTextBlockCard(customDraw) {
    global FileView, ItemLabels
    ; Native tile text consumes the full right edge and offers no independent
    ; right-padding control. Draw the complete card so both inner edges and
    ; the requested logical outer margins remain deterministic at every DPI.
    drawStageOffset := A_PtrSize = 8 ? 24 : 12
    hdcOffset := A_PtrSize = 8 ? 32 : 16
    rectOffset := A_PtrSize = 8 ? 40 : 20
    itemOffset := A_PtrSize = 8 ? 56 : 36
    stateOffset := A_PtrSize = 8 ? 64 : 40
    stage := NumGet(customDraw + drawStageOffset, "uint")
    if stage = 1 ; CDDS_PREPAINT
        return 0x20 ; CDRF_NOTIFYITEMDRAW
    if stage != 0x10001 ; CDDS_ITEMPREPAINT
        return 0

    hdc := NumGet(customDraw + hdcOffset, "ptr")
    row := NumGet(customDraw + itemOffset, "uptr") + 1
    title := ItemLabels.Has(row) ? ItemLabels[row] : ""
    dpi := DllCall("user32\GetDpiForWindow", "ptr", FileView.Hwnd, "uint")
    if !dpi
        dpi := 96
    marginX := Max(1, DllCall("kernel32\MulDiv",
        "int", PanelScale(2), "int", dpi, "int", 96, "int"))
    paddingX := Max(4, DllCall("kernel32\MulDiv",
        "int", PanelScale(8), "int", dpi, "int", 96, "int"))
    paddingY := Max(3, DllCall("kernel32\MulDiv",
        "int", PanelScale(5), "int", dpi, "int", 96, "int"))
    radius := Max(4, DllCall("kernel32\MulDiv",
        "int", PanelScale(7), "int", dpi, "int", 96, "int"))

    insetTop := PanelPhysicalScale(4, FileView.Hwnd)
    insetBottom := PanelPhysicalScale(5, FileView.Hwnd)
    left := NumGet(customDraw + rectOffset, "int") + marginX
    top := NumGet(customDraw + rectOffset + 4, "int") + insetTop
    right := NumGet(customDraw + rectOffset + 8, "int") - marginX
    bottom := NumGet(customDraw + rectOffset + 12, "int") - insetBottom
    if right <= left || bottom <= top
        return 0x4 ; CDRF_SKIPDEFAULT
    state := NumGet(customDraw + stateOffset, "uint")
    ; Some ListView builds omit CDIS_SELECTED while a marquee is changing
    ; multiple rows. Query the authoritative LVIS_SELECTED bit instead so
    ; every selected card is painted during and after box selection.
    selectedState := DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
        "uint", 0x102C, "ptr", row - 1, "ptr", 0x2,
        "uint") ; LVM_GETITEMSTATE / LVIS_SELECTED
    selected := !!(selectedState & 0x2)
    showLinkIcon := IsPinnedLinkRow(row)
    showPinIcon := IsTextSourcePinnedRow(row)
    ; COLORREF is BGR: all text blocks share #E6E6E6; selected #E5F1FB.
    ; Location is expressed only by the pinned reference icon.
    backgroundColor := selected ? 0x00FBF1E5 : 0x00E6E6E6
    textIndex := 8 ; COLOR_WINDOWTEXT
    ; Selected border #0078D7 becomes BGR 0x00D77800.
    borderColor := selected ? 0x00D77800
        : DllCall("user32\GetSysColor", "int", 16, "uint")
    pen := DllCall("gdi32\CreatePen", "int", 0,
        "int", selected ? Max(2, PanelPhysicalScale(2, FileView.Hwnd))
            : Max(1, PanelPhysicalScale(1, FileView.Hwnd)),
        "uint", borderColor, "ptr")
    if !pen
        return 0x4
    brush := DllCall("gdi32\CreateSolidBrush",
        "uint", backgroundColor, "ptr")
    if !brush {
        DllCall("gdi32\DeleteObject", "ptr", pen)
        return 0x4
    }
    oldPen := DllCall("gdi32\SelectObject", "ptr", hdc,
        "ptr", pen, "ptr")
    oldBrush := DllCall("gdi32\SelectObject", "ptr", hdc,
        "ptr", brush, "ptr")
    DllCall("gdi32\RoundRect", "ptr", hdc, "int", left, "int", top,
        "int", right, "int", bottom, "int", radius, "int", radius)

    textRect := Buffer(16, 0)
    NumPut("int", left + paddingX, textRect, 0)
    NumPut("int", top + paddingY, textRect, 4)
    badgeIconSize := (showLinkIcon || showPinIcon)
        ? TextBlockBadgeIconSize(dpi) : 0
    NumPut("int", right - paddingX
        - ((showLinkIcon || showPinIcon)
            ? badgeIconSize + paddingX : 0), textRect, 8)
    NumPut("int", bottom - paddingY, textRect, 12)
    oldTextColor := DllCall("gdi32\SetTextColor", "ptr", hdc,
        "uint", DllCall("user32\GetSysColor", "int", textIndex, "uint"),
        "uint")
    oldBkMode := DllCall("gdi32\SetBkMode", "ptr", hdc,
        "int", 1, "int") ; TRANSPARENT
    font := DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
        "uint", 0x0031, "ptr", 0, "ptr", 0, "ptr") ; WM_GETFONT
    oldFont := font
        ? DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", font, "ptr") : 0
    DllCall("user32\DrawTextW", "ptr", hdc, "wstr", title, "int", -1,
        "ptr", textRect.Ptr,
        "uint", 0x0010 | 0x0800 | 0x40000, "int")
        ; DT_WORDBREAK | DT_NOPREFIX | DT_WORD_ELLIPSIS
    if showLinkIcon || showPinIcon {
        ; The badge is positioned independently from the text padding. Keep
        ; it close to the card edge, especially horizontally, while retaining
        ; a small DPI-scaled safety gap from the rounded border.
        badgeInsetX := Max(1, DllCall("kernel32\MulDiv",
            "int", PanelScale(2), "int", dpi, "int", 96, "int"))
        badgeInsetY := Max(1, DllCall("kernel32\MulDiv",
            "int", PanelScale(2), "int", dpi, "int", 96, "int"))
        if showLinkIcon
            DrawPinnedLinkIcon(hdc, right, bottom, dpi,
                badgeInsetX, badgeInsetY)
        else
            DrawTextSourcePinIcon(hdc, right, bottom, dpi,
                badgeInsetX, badgeInsetY)
    }
    if state & 0x10 { ; CDIS_FOCUS
        focusRect := Buffer(16, 0)
        focusInset := PanelPhysicalScale(2, FileView.Hwnd)
        NumPut("int", left + focusInset, focusRect, 0)
        NumPut("int", top + focusInset, focusRect, 4)
        NumPut("int", right - focusInset, focusRect, 8)
        NumPut("int", bottom - focusInset, focusRect, 12)
        DllCall("user32\DrawFocusRect", "ptr", hdc, "ptr", focusRect.Ptr)
    }
    if oldFont
        DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldFont, "ptr")
    DllCall("gdi32\SetBkMode", "ptr", hdc, "int", oldBkMode)
    DllCall("gdi32\SetTextColor", "ptr", hdc, "uint", oldTextColor)
    DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldBrush, "ptr")
    DllCall("gdi32\SelectObject", "ptr", hdc, "ptr", oldPen, "ptr")
    DllCall("gdi32\DeleteObject", "ptr", brush)
    DllCall("gdi32\DeleteObject", "ptr", pen)
    return 0x4 ; CDRF_SKIPDEFAULT
}

DrawPinnedFileLinkIcon(customDraw) {
    global FileView
    drawStageOffset := A_PtrSize = 8 ? 24 : 12
    hdcOffset := A_PtrSize = 8 ? 32 : 16
    rectOffset := A_PtrSize = 8 ? 40 : 20
    itemOffset := A_PtrSize = 8 ? 56 : 36
    stage := NumGet(customDraw + drawStageOffset, "uint")
    if stage = 1 ; CDDS_PREPAINT
        return 0x20 ; CDRF_NOTIFYITEMDRAW
    if stage = 0x10001 { ; CDDS_ITEMPREPAINT
        row := NumGet(customDraw + itemOffset, "uptr") + 1
        return IsPinnedLinkRow(row) ? 0x10 : 0 ; CDRF_NOTIFYPOSTPAINT
    }
    if stage != 0x10002 ; CDDS_ITEMPOSTPAINT
        return 0

    row := NumGet(customDraw + itemOffset, "uptr") + 1
    if !IsPinnedLinkRow(row)
        return 0
    hdc := NumGet(customDraw + hdcOffset, "ptr")
    iconBounds := GetFileViewIconBounds(row)
    ; NMCUSTOMDRAW's item rectangle includes the wrapped file name. LVIR_ICON
    ; isolates the thumbnail/file-icon rectangle, so the badge cannot drift
    ; down onto label text when a name wraps to two lines.
    right := IsObject(iconBounds)
        ? iconBounds.Right : NumGet(customDraw + rectOffset + 8, "int")
    bottom := IsObject(iconBounds)
        ? iconBounds.Bottom : NumGet(customDraw + rectOffset + 12, "int")
    dpi := DllCall("user32\GetDpiForWindow", "ptr", FileView.Hwnd, "uint")
    if !dpi
        dpi := 96
    DrawPinnedLinkIcon(hdc, right, bottom, dpi, 0, 0)
    return 0
}

GetFileViewIconBounds(row) {
    global FileView
    rect := Buffer(16, 0)
    NumPut("int", 1, rect, 0) ; LVIR_ICON
    if !DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
        "uint", 0x100E, "ptr", row - 1, "ptr", rect.Ptr,
        "ptr") ; LVM_GETITEMRECT
        return 0
    left := NumGet(rect, 0, "int")
    top := NumGet(rect, 4, "int")
    right := NumGet(rect, 8, "int")
    bottom := NumGet(rect, 12, "int")
    if right <= left || bottom <= top
        return 0
    return {Left: left, Top: top, Right: right, Bottom: bottom}
}

IsPinnedLinkRow(row) {
    global ItemOpenContexts, ItemPaths
    if !ItemOpenContexts.Has(row)
        || ItemOpenContexts[row].Area != "Pinned"
        || !ItemPaths.Has(row)
        return false
    ; Every file-workspace pin is a reference. In a text workspace only the
    ; app-owned inbox item is an entity; all other pinned paths are links.
    return !IsTextWorkspace() || !IsTextBlockDraftPath(ItemPaths[row])
}

PinnedLinkIconSize(dpi) {
    return TextBlockBadgeIconSize(dpi)
}

TextBlockBadgeIconSize(dpi) {
    return Max(12, DllCall("kernel32\MulDiv",
        "int", PanelScale(14), "int", dpi, "int", 96, "int"))
}

IsTextSourcePinnedRow(row) {
    global ItemOpenContexts
    return ItemOpenContexts.Has(row)
        && ItemOpenContexts[row].Area = "Source"
        && HasProp(ItemOpenContexts[row], "FolderPinned")
        && ItemOpenContexts[row].FolderPinned
}

GetPinnedLinkIcon(dpi) {
    global PinnedLinkIconCache
    size := PinnedLinkIconSize(dpi)
    if PinnedLinkIconCache.Has(size)
        return PinnedLinkIconCache[size]

    icon := 0
    if A_IsCompiled {
        module := DllCall("kernel32\GetModuleHandleW", "ptr", 0, "ptr")
        icon := DllCall("user32\LoadImageW", "ptr", module, "ptr", 556,
            "uint", 1, "int", size, "int", size, "uint", 0, "ptr")
    }
    if !icon {
        path := A_ScriptDir "\assets\icon-lnk.ico"
        icon := DllCall("user32\LoadImageW", "ptr", 0, "wstr", path,
            "uint", 1, "int", size, "int", size,
            "uint", 0x10, "ptr") ; IMAGE_ICON | LR_LOADFROMFILE
    }
    if icon
        PinnedLinkIconCache[size] := icon
    return icon
}

DrawPinnedLinkIcon(hdc, right, bottom, dpi, insetX, insetY) {
    size := PinnedLinkIconSize(dpi)
    icon := GetPinnedLinkIcon(dpi)
    if !icon
        return false
    x := right - insetX - size
    y := bottom - insetY - size
    return DllCall("user32\DrawIconEx", "ptr", hdc,
        "int", x, "int", y, "ptr", icon,
        "int", size, "int", size, "uint", 0,
        "ptr", 0, "uint", 0x3, "int") ; DI_NORMAL
}

CleanupPinnedLinkIcons() {
    global PinnedLinkIconCache
    for _, icon in PinnedLinkIconCache
        if icon
            DllCall("user32\DestroyIcon", "ptr", icon)
    PinnedLinkIconCache.Clear()
}

GetTextSourcePinIcon(dpi) {
    global TextSourcePinIconCache
    size := TextBlockBadgeIconSize(dpi)
    if TextSourcePinIconCache.Has(size)
        return TextSourcePinIconCache[size]
    icon := 0
    if A_IsCompiled {
        module := DllCall("kernel32\GetModuleHandleW", "ptr", 0, "ptr")
        icon := DllCall("user32\LoadImageW", "ptr", module, "ptr", 557,
            "uint", 1, "int", size, "int", size, "uint", 0, "ptr")
    }
    if !icon {
        path := A_ScriptDir "\assets\pin.ico"
        icon := DllCall("user32\LoadImageW", "ptr", 0, "wstr", path,
            "uint", 1, "int", size, "int", size,
            "uint", 0x10, "ptr")
    }
    if icon
        TextSourcePinIconCache[size] := icon
    return icon
}

DrawTextSourcePinIcon(hdc, right, bottom, dpi, insetX, insetY) {
    size := TextBlockBadgeIconSize(dpi)
    icon := GetTextSourcePinIcon(dpi)
    if !icon
        return false
    return DllCall("user32\DrawIconEx", "ptr", hdc,
        "int", right - insetX - size,
        "int", bottom - insetY - size,
        "ptr", icon, "int", size, "int", size, "uint", 0,
        "ptr", 0, "uint", 0x3, "int")
}

CleanupTextSourcePinIcons() {
    global TextSourcePinIconCache
    for _, icon in TextSourcePinIconCache
        if icon
            DllCall("user32\DestroyIcon", "ptr", icon)
    TextSourcePinIconCache.Clear()
}

FileViewContextMenu(list, row, isRightClick, x, y) {
    global ItemPaths
    CancelFilePointerGesture()
    PreviewSuppress("context-menu", false)
    ; Resolve group headers before trusting the event's row. In icon view a
    ; header point can also be reported as the nearby item, which must not turn
    ; a title-bar right click into an item menu.
    if isRightClick {
        point := GuiClientPointToControlClient(
            list.Gui.Hwnd, list.Hwnd, x, y)
        if IsObject(point) {
            descriptor := FindSourceGroupHeaderAtPoint(
                list.Hwnd, point.X, point.Y)
            if IsObject(descriptor) {
                ContextMenuGestureIsAlternate(list.Hwnd, true)
                ShowSourceGroupContextMenu(
                    descriptor, list.Gui.Hwnd, x, y)
                PreviewRecoverAfterInteraction()
                return
            }
            descriptor := FindPinnedGroupHeaderAtPoint(
                list.Hwnd, point.X, point.Y)
            if IsObject(descriptor) {
                ContextMenuGestureIsAlternate(list.Hwnd, true)
                ShowPinnedGroupContextMenu(
                    descriptor, list.Gui.Hwnd, x, y)
                PreviewRecoverAfterInteraction()
                return
            }
        }
    }
    if !row && !isRightClick {
        row := list.GetNext(0, "F")
        if !row
            row := list.GetNext(0)
    }
    if !row || !ItemPaths.Has(row) {
        if isRightClick
            ContextMenuGestureIsAlternate(list.Hwnd, true)
        PreviewRecoverAfterInteraction()
        return
    }
    if !IsListRowSelected(list.Hwnd, row) {
        list.Modify(0, "-Select -Focus")
        list.Modify(row, "Select Focus Vis")
    } else {
        list.Modify(row, "Focus Vis")
    }
    UpdateSelectionStatus()
    path := ItemPaths[row]
    if !FileExist(path) {
        ShowPanelMsgBox("项目不存在或当前无法访问：`n" path, "右键菜单", "Icon!")
        PreviewRecoverAfterInteraction()
        return
    }
    paths := GetSelectedExistingPaths()
    if !paths.Length
        paths := [path]
    alternate := ContextMenuGestureIsAlternate(list.Hwnd, isRightClick)
    ShowConfiguredContextMenu(
        paths, path, list.Gui.Hwnd, x, y, alternate)
    PreviewRecoverAfterInteraction()
}

GuiClientPointToControlClient(guiHwnd, controlHwnd, x, y) {
    if x < 0 || y < 0
        return 0
    screen := ClientToScreenPoint(guiHwnd, x, y)
    return ScreenToClientPoint(controlHwnd, screen.X, screen.Y)
}

IsSourceManagementDescriptor(descriptor) {
    return IsObject(descriptor)
        && HasProp(descriptor, "SourceId")
        && IsSafeSourceId(descriptor.SourceId)
        && HasProp(descriptor, "Type")
        && (descriptor.Type = "Files"
            || descriptor.Type = "Launcher"
            || descriptor.Type = "TextSource")
}

IsPinnedGroupDescriptor(descriptor) {
    return IsObject(descriptor)
        && HasProp(descriptor, "Type")
        && (descriptor.Type = "Pinned" || descriptor.Type = "TextPinned")
        && HasProp(descriptor, "GroupId") && descriptor.GroupId > 0
}

CloneSourceManagementDescriptor(descriptor) {
    return {
        Type: descriptor.Type,
        SourceId: descriptor.SourceId,
        WorkspaceId: HasProp(descriptor, "WorkspaceId")
            ? descriptor.WorkspaceId : "",
        Name: descriptor.Name,
        Path: descriptor.Path,
        Mode: HasProp(descriptor, "Mode")
            ? descriptor.Mode : descriptor.Type,
        GroupId: descriptor.GroupId,
        Available: HasProp(descriptor, "Available")
            ? descriptor.Available : true
    }
}

PointInListRect(x, y, rect) {
    return IsObject(rect)
        && rect.Right > rect.Left && rect.Bottom > rect.Top
        && x >= rect.Left && x < rect.Right
        && y >= rect.Top && y < rect.Bottom
}

FindSourceGroupHeaderInRects(x, y, descriptors, headerRects) {
    for groupId, descriptor in descriptors {
        if !IsSourceManagementDescriptor(descriptor)
            continue
        if headerRects.Has(groupId)
            && PointInListRect(x, y, headerRects[groupId])
            return CloneSourceManagementDescriptor(descriptor)
    }
    return 0
}

FindPinnedGroupHeaderInRects(x, y, descriptors, headerRects) {
    for groupId, descriptor in descriptors {
        if !IsPinnedGroupDescriptor(descriptor)
            continue
        if headerRects.Has(groupId)
            && PointInListRect(x, y, headerRects[groupId])
            return CloneSourceManagementDescriptor(descriptor)
    }
    return 0
}

HitTestListGroupHeader(hwnd, x, y) {
    static LVHT_EX_GROUP_HEADER := 0x10000000
    hit := Buffer(24, 0)
    NumPut("int", x, hit, 0)
    NumPut("int", y, hit, 4)
    DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1012, "ptr", 0, "ptr", hit.Ptr, "int") ; LVM_HITTEST
    flags := NumGet(hit, 8, "uint")
    return flags & LVHT_EX_GROUP_HEADER
        ? NumGet(hit, 20, "int") : 0
}

GetListItemRect(hwnd, row) {
    if row < 1
        return 0
    rect := Buffer(16, 0)
    NumPut("int", 0, rect, 0) ; LVIR_BOUNDS
    if !DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x100E, "ptr", row - 1, "ptr", rect.Ptr, "ptr")
        return 0
    return {
        Left: NumGet(rect, 0, "int"),
        Top: NumGet(rect, 4, "int"),
        Right: NumGet(rect, 8, "int"),
        Bottom: NumGet(rect, 12, "int")
    }
}

GetFallbackListGroupHeaderRect(hwnd, groupId) {
    global ItemOpenContexts
    groupRect := GetListGroupRect(hwnd, groupId, 0)
    if !IsObject(groupRect)
        return 0
    firstTop := ""
    for row, context in ItemOpenContexts {
        if HasProp(context, "GroupId") && context.GroupId = groupId {
            itemRect := GetListItemRect(hwnd, row)
            if IsObject(itemRect)
                && (firstTop = "" || itemRect.Top < firstTop)
                firstTop := itemRect.Top
        }
    }
    if firstTop = "" || firstTop <= groupRect.Top
        return 0
    return {
        Left: groupRect.Left,
        Top: groupRect.Top,
        Right: groupRect.Right,
        Bottom: Min(firstTop, groupRect.Bottom)
    }
}

GetListGroupHeaderRectRobust(hwnd, groupId) {
    header := GetListGroupRect(hwnd, groupId, 1) ; LVGGR_HEADER
    if IsObject(header)
        && header.Right > header.Left && header.Bottom > header.Top
        return header
    return GetFallbackListGroupHeaderRect(hwnd, groupId)
}

FindSourceGroupHeaderAtPoint(hwnd, x, y) {
    global GroupDropTargets
    groupId := HitTestListGroupHeader(hwnd, x, y)
    if groupId {
        if GroupDropTargets.Has(groupId)
            && IsSourceManagementDescriptor(GroupDropTargets[groupId])
            return CloneSourceManagementDescriptor(
                GroupDropTargets[groupId])
        return 0
    }
    headerRects := Map()
    for candidateId, descriptor in GroupDropTargets {
        if !IsSourceManagementDescriptor(descriptor)
            continue
        rect := GetListGroupHeaderRectRobust(hwnd, candidateId)
        if IsObject(rect)
            headerRects[candidateId] := rect
    }
    return FindSourceGroupHeaderInRects(
        x, y, GroupDropTargets, headerRects)
}

FindPinnedGroupHeaderAtPoint(hwnd, x, y) {
    global GroupDropTargets
    groupId := HitTestListGroupHeader(hwnd, x, y)
    if groupId {
        if GroupDropTargets.Has(groupId)
            && IsPinnedGroupDescriptor(GroupDropTargets[groupId])
            return CloneSourceManagementDescriptor(
                GroupDropTargets[groupId])
        return 0
    }
    headerRects := Map()
    for candidateId, descriptor in GroupDropTargets {
        if !IsPinnedGroupDescriptor(descriptor)
            continue
        rect := GetListGroupHeaderRectRobust(hwnd, candidateId)
        if IsObject(rect)
            headerRects[candidateId] := rect
    }
    return FindPinnedGroupHeaderInRects(
        x, y, GroupDropTargets, headerRects)
}

IsListRowSelected(hwnd, row) {
    state := DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x102C,
        "ptr", row - 1, "ptr", 0x2, "uint") ; LVM_GETITEMSTATE / LVIS_SELECTED
    return (state & 0x2) != 0
}

GetSelectedExistingPaths() {
    global ItemPaths
    paths := []
    for row in GetSelectedFileRows() {
        path := ItemPaths[row]
        if FileExist(path) && !ArrayContainsPath(paths, path)
            paths.Push(path)
    }
    return paths
}

GetShellMenuPaths(paths, clickedPath) {
    if paths.Length <= 1
        return [clickedPath]
    parent := GetParentPath(paths[1])
    for path in paths {
        if !PathsEqual(GetParentPath(path), parent)
            return [clickedPath]
    }
    return paths.Clone()
}

ContextMenuGestureIsAlternate(hwnd, isRightClick) {
    global PendingContextMenuMouseShift, PendingContextMenuKeyboardAlternate
    if !isRightClick {
        alternate := PendingContextMenuKeyboardAlternate.Has(hwnd)
            ? PendingContextMenuKeyboardAlternate[hwnd] : false
        if PendingContextMenuKeyboardAlternate.Has(hwnd)
            PendingContextMenuKeyboardAlternate.Delete(hwnd)
        return alternate
    }
    alternate := PendingContextMenuMouseShift.Has(hwnd)
        ? PendingContextMenuMouseShift[hwnd]
        : GetKeyState("Shift", "P")
    if PendingContextMenuMouseShift.Has(hwnd)
        PendingContextMenuMouseShift.Delete(hwnd)
    return alternate
}

FindRuntimeSourceDescriptor(workspaceId, sourceId) {
    global Workspaces
    workspace := FindWorkspace(workspaceId, Workspaces)
    if !IsObject(workspace)
        return 0
    for source in workspace.Value.Sources {
        if StrLower(source.SourceId) = StrLower(sourceId) {
            return {
                Type: source.Mode,
                Mode: source.Mode,
                SourceId: source.SourceId,
                WorkspaceId: workspace.Value.Id,
                WorkspaceName: workspace.Value.Name,
                Name: source.Name,
                Path: source.Path,
                GroupId: 0
            }
        }
    }
    return 0
}

CanOpenSourceFolder(descriptor) {
    return IsSourceManagementDescriptor(descriptor)
        && (HasProp(descriptor, "Available")
            ? descriptor.Available : DirExist(descriptor.Path))
}

ShowSourceGroupContextMenu(
    sourceDescriptor, ownerHwnd, x, y
) {
    global SourceMenuDispatchActive
    if SourceMenuDispatchActive
        return
    descriptor := CloneSourceManagementDescriptor(sourceDescriptor)
    ; AHK identifiers are case-insensitive.  A local named "menu" would
    ; shadow the built-in Menu class even on the right-hand side.
    sourceMenu := Menu()
    openText := "打开来源文件夹"
    sourceMenu.Add(openText, OpenSourceFolderFromPanel.Bind(descriptor))
    if !CanOpenSourceFolder(descriptor)
        sourceMenu.Disable(openText)
    sourceMenu.Add("刷新此来源", RefreshSourceFromPanel.Bind(descriptor))
    sourceMenu.Add("设置此来源…", OpenSourceSettingsFromPanel.Bind(descriptor))
    sourceMenu.Add()
    sourceMenu.Add("从当前工作区移除…",
        RequestRemoveSourceFromPanel.Bind(descriptor))

    point := MenuScreenPoint(ownerHwnd, x, y)
    SourceMenuDispatchActive := true
    BeginAutoHidePause()
    try {
        CoordMode("Menu", "Screen")
        sourceMenu.Show(point.X, point.Y)
    } finally {
        EndAutoHidePause()
        SourceMenuDispatchActive := false
    }
}

ShowPinnedGroupContextMenu(pinnedDescriptor, ownerHwnd, x, y) {
    global SourceMenuDispatchActive, PinnedPaths
    if SourceMenuDispatchActive || !IsPinnedGroupDescriptor(pinnedDescriptor)
        return
    descriptor := CloneSourceManagementDescriptor(pinnedDescriptor)
    pinnedMenu := Menu()
    clearText := "清除全部失效项目"
    pinnedMenu.Add(clearText,
        ClearInvalidPinnedItems.Bind(descriptor))
    if !PartitionPinnedPathsByAvailability(PinnedPaths).Invalid.Length
        pinnedMenu.Disable(clearText)

    point := MenuScreenPoint(ownerHwnd, x, y)
    SourceMenuDispatchActive := true
    BeginAutoHidePause()
    try {
        CoordMode("Menu", "Screen")
        pinnedMenu.Show(point.X, point.Y)
    } finally {
        EndAutoHidePause()
        SourceMenuDispatchActive := false
    }
}

OpenSourceFolderFromPanel(descriptor, *) {
    live := FindRuntimeSourceDescriptor(
        descriptor.WorkspaceId, descriptor.SourceId)
    if !IsObject(live) {
        SetUserStatus("该来源已经不存在")
        return
    }
    OpenFolderInFileManager(live.Path)
}

RefreshSourceFromPanel(descriptor, *) {
    global ActiveWorkspaceId
    live := FindRuntimeSourceDescriptor(
        descriptor.WorkspaceId, descriptor.SourceId)
    if !IsObject(live)
        return SetUserStatus("该来源已经不存在，无法刷新")
    if StrLower(live.WorkspaceId) != StrLower(ActiveWorkspaceId)
        return SetUserStatus("当前工作区已经改变，未刷新该来源")
    ; The worker request is workspace-scoped. Reuse it rather than adding a
    ; second scan protocol; generation, fingerprint and WorkspaceId validation
    ; continue to reject stale results.
    SetUserStatus("正在刷新来源「" live.Name "」")
    StartBackgroundScan()
}

OpenSourceSettingsFromPanel(descriptor, *) {
    OpenSourceSettings(descriptor.WorkspaceId, descriptor.SourceId)
}

SourceRemovalTransferBlockReason(sourceId, path, batches) {
    for id, batch in batches {
        if HasProp(batch, "Completed") && batch.Completed
            continue
        targetSourceId := HasProp(batch, "TargetSourceId")
            ? Trim(batch.TargetSourceId) : ""
        if targetSourceId != "" {
            if StrLower(targetSourceId) = StrLower(sourceId)
                return "该来源正在接收内容，请等待传输完成后再移除。"
            continue
        }
        ; Old/incomplete batch metadata has no stable identity. A matching
        ; path is enough to block, never enough to guess that removal is safe.
        if HasProp(batch, "TargetPath")
            && PathsEqual(batch.TargetPath, path)
            return "该来源正在接收内容，请等待传输完成后再移除。"
    }
    return ""
}

RequestRemoveSourceFromPanel(descriptor, *) {
    global ActiveWorkspaceId, TransferBatches
    try {
        if StrLower(descriptor.WorkspaceId)
            != StrLower(ActiveWorkspaceId) {
            SetUserStatus("当前工作区已经改变，未移除来源")
            return
        }
        live := FindRuntimeSourceDescriptor(
            descriptor.WorkspaceId, descriptor.SourceId)
        if !IsObject(live) {
            SetUserStatus("该来源已经不存在")
            return
        }
        blocked := SourceRemovalTransferBlockReason(
            live.SourceId, live.Path, TransferBatches)
        if blocked != "" {
            ShowPanelMsgBox(blocked, "无法移除来源", "Icon!")
            return
        }
        preparation := PrepareSettingsForExternalSourceRemoval(
            live.WorkspaceId, live.SourceId)
        if !preparation.Allowed
            return

        ; Saving or discarding a settings draft may have changed the source.
        ; Resolve the stable identities again before asking for confirmation.
        live := FindRuntimeSourceDescriptor(
            descriptor.WorkspaceId, descriptor.SourceId)
        if !IsObject(live) {
            SetUserStatus("该来源已经不存在")
            return
        }
        blocked := SourceRemovalTransferBlockReason(
            live.SourceId, live.Path, TransferBatches)
        if blocked != "" {
            ShowPanelMsgBox(blocked, "无法移除来源", "Icon!")
            return
        }
        ShowSourceRemovalConfirmation(
            live, preparation.SyncState)
    } catch as err {
        ShowPanelMsgBox("无法准备移除来源：`n" err.Message,
            "移除来源失败", "Iconx")
    }
}

ShowSourceRemovalConfirmation(descriptor, settingsSyncState) {
    global Panel, SourceRemovalDialog
    if IsObject(SourceRemovalDialog) {
        try WinActivate("ahk_id " SourceRemovalDialog.Hwnd)
        return
    }
    dialog := Gui("+Owner" Panel.Hwnd
        . " -MaximizeBox -MinimizeBox", "移除来源")
    dialog.SetFont("s9", "Microsoft YaHei UI")
    dialog.MarginX := 16
    dialog.MarginY := 14
    state := {
        Dialog: dialog,
        Closed: false,
        Descriptor: descriptor,
        SettingsSyncState: settingsSyncState
    }
    SourceRemovalDialog := dialog
    dialog.AddText("xm ym w590",
        "要从工作区「" descriptor.WorkspaceName
        . "」移除来源「" descriptor.Name "」吗？")
    dialog.AddText("xm y+12 w590", "完整路径：")
    pathText := dialog.AddEdit(
        "xm y+5 w590 h46 ReadOnly -Tabstop Multi -Wrap",
        descriptor.Path)
    dialog.AddText("xm y+12 w590 h58",
        "这只会移除 PopDrop 中的来源及其专属设置，不会删除、移动或修改"
        . "该文件夹及其中的文件。属于该文件夹的固定项仍会保留。")
    removeButton := AddUiButton(dialog,
        "x430 y188 w88", "移除来源")
    cancelButton := AddUiButton(dialog,
        "x+8 yp w78 Default", "取消")
    removeButton.OnEvent("Click",
        CloseSourceRemovalConfirmation.Bind(state, true))
    cancelButton.OnEvent("Click",
        CloseSourceRemovalConfirmation.Bind(state, false))
    dialog.OnEvent("Close",
        CloseSourceRemovalConfirmation.Bind(state, false))
    dialog.OnEvent("Escape",
        CloseSourceRemovalConfirmation.Bind(state, false))
    BeginAutoHidePause()
    try {
        Panel.Opt("+Disabled")
        dialog.Show("w622 h232")
        try cancelButton.Focus()
    } catch {
        SourceRemovalDialog := 0
        try Panel.Opt("-Disabled")
        try dialog.Destroy()
        EndAutoHidePause()
        throw
    }
}

CloseSourceRemovalConfirmation(state, confirmed, *) {
    global Panel, SourceRemovalDialog
    if state.Closed
        return
    state.Closed := true
    SourceRemovalDialog := 0
    try Panel.Opt("-Disabled")
    try state.Dialog.Destroy()
    EndAutoHidePause()
    try WinActivate("ahk_id " Panel.Hwnd)
    if confirmed {
        SetTimer(ExecuteSourceRemoval.Bind(
            state.Descriptor.WorkspaceId,
            state.Descriptor.SourceId,
            state.SettingsSyncState), -10)
    }
}

RemoveTextInsensitive(values, target) {
    result := []
    removed := false
    for value in values {
        if StrLower(value) = StrLower(target)
            removed := true
        else
            result.Push(value)
    }
    return {Values: result, Removed: removed}
}

SourceOwnedConfigSections(sourceId) {
    return [
        "Source:" sourceId,
        "SourceIgnore:" sourceId,
        "SourceExclude:" sourceId,
        "SourceAllow:" sourceId,
        "TextSourcePinned:" sourceId
    ]
}

IsClearlySourceOwnedConfigSection(sectionName, sourceId) {
    colon := InStr(sectionName, ":")
    if !colon || InStr(sectionName, ":",, colon + 1)
        return false
    prefix := StrLower(SubStr(sectionName, 1, colon - 1))
    owner := SubStr(sectionName, colon + 1)
    return SubStr(prefix, 1, 6) = "source"
        && StrLower(owner) = StrLower(sourceId)
}

CollectSourceOwnedConfigSections(doc, sourceId) {
    result := SourceOwnedConfigSections(sourceId)
    seen := Map()
    for section in result
        seen[StrLower(section)] := true
    for section in doc.GetSectionNames() {
        folded := StrLower(section)
        if !seen.Has(folded)
            && IsClearlySourceOwnedConfigSection(section, sourceId) {
            seen[folded] := true
            result.Push(section)
        }
    }
    return result
}

WriteSourceRemovalConfig(workspaceId, sourceId, result, tempPath) {
    doc := OpenPopDropConfig(tempPath)
    workspaceOrder := ParseStableIdOrder(
        doc.GetValue("Workspaces", "Order", ""))
    if !ArrayContainsTextInsensitive(workspaceOrder, workspaceId)
        throw Error("目标工作区已经不存在。")
    activeId := Trim(doc.GetValue("Workspaces", "Active", ""))
    if StrLower(activeId) != StrLower(workspaceId)
        throw Error("当前工作区已经改变，已取消移除。")

    workspaceSection := "Workspace:" workspaceId
    workspaceName := Trim(doc.GetValue(
        workspaceSection, "Name", ""))
    sourceOrder := ParseStableIdOrder(doc.GetValue(
        workspaceSection, "SourceOrder", ""))
    removal := RemoveTextInsensitive(sourceOrder, sourceId)
    if !removal.Removed
        throw Error("目标来源已经不在当前工作区。")

    for otherWorkspaceId in workspaceOrder {
        if StrLower(otherWorkspaceId) = StrLower(workspaceId)
            continue
        otherOrder := ParseStableIdOrder(doc.GetValue(
            "Workspace:" otherWorkspaceId, "SourceOrder", ""))
        if ArrayContainsTextInsensitive(otherOrder, sourceId)
            throw Error("目标来源 ID 仍被其他工作区引用，无法安全移除。")
    }

    sourceSection := "Source:" sourceId
    ownerId := Trim(doc.GetValue(
        sourceSection, "WorkspaceId", ""))
    if ownerId != ""
        && StrLower(ownerId) != StrLower(workspaceId)
        throw Error("目标来源属于其他工作区，已取消移除。")
    sourceName := Trim(doc.GetValue(sourceSection, "Name", ""))
    sourcePath := NormalizePath(
        doc.GetValue(sourceSection, "Path", ""))
    if sourceName = "" || sourcePath = ""
        throw Error("目标来源配置不完整，无法安全移除。")

    doc.SetValue(workspaceSection, "SourceOrder",
        JoinArray(removal.Values, ","), 3)
    for section in CollectSourceOwnedConfigSections(doc, sourceId)
        doc.DeleteSection(section)
    ValidateWorkspaceDocument(doc, workspaceOrder)
    doc.Save()

    result.WorkspaceName := workspaceName
    result.SourceName := sourceName
    result.SourcePath := sourcePath
    result.Removed := true
}

ExecuteSourceRemoval(workspaceId, sourceId, settingsSyncState := 0) {
    global ActiveWorkspaceId, TransferBatches
    live := FindRuntimeSourceDescriptor(workspaceId, sourceId)
    if !IsObject(live) {
        SetUserStatus("该来源已经不存在")
        return false
    }
    blocked := SourceRemovalTransferBlockReason(
        sourceId, live.Path, TransferBatches)
    if blocked != "" {
        ShowPanelMsgBox(blocked, "无法移除来源", "Icon!")
        return false
    }
    if StrLower(workspaceId) != StrLower(ActiveWorkspaceId) {
        SetUserStatus("当前工作区已经改变，未移除来源")
        return false
    }

    result := {
        Removed: false,
        WorkspaceName: live.WorkspaceName,
        SourceName: live.Name,
        SourcePath: live.Path
    }
    wroteConfig := false
    try {
        CreateConfigBackup()
        AtomicConfigEdit(WriteSourceRemovalConfig.Bind(
            workspaceId, sourceId, result))
        wroteConfig := true
        LoadSettings()
        PopulatePanel()
        PopulateRecentSidebar()
    } catch as err {
        if wroteConfig {
            try {
                AtomicConfigEdit(RestoreConfigBackupToTemp)
                LoadSettings()
                PopulatePanel()
                PopulateRecentSidebar()
            }
        }
        ShowPanelMsgBox("无法移除来源：`n" err.Message
            . "`n`n本地文件夹未作任何更改。",
            "移除来源失败", "Iconx")
        return false
    }
    try SyncSettingsAfterExternalSourceRemoval(settingsSyncState)
    catch as err {
        ShowPanelMsgBox(
            "来源已安全移除，但设置窗口刷新失败：`n" err.Message,
            "设置窗口需要刷新", "Icon!")
    }
    StartBackgroundScan()
    SetUserStatus("已从「" result.WorkspaceName
        . "」移除来源「" result.SourceName
        . "」；本地文件夹未更改。")
    return true
}

ShowConfiguredContextMenu(
    paths, clickedPath, ownerHwnd, x, y, alternate := false
) {
    global DefaultContextMenu, CONTEXT_MENU_SYSTEM
    global ContextMenuDispatchActive
    if ContextMenuDispatchActive
        return
    ContextMenuDispatchActive := true
    try {
        kind := ResolveContextMenuKind(DefaultContextMenu, alternate)
        if kind = CONTEXT_MENU_SYSTEM
            ShowSystemContextMenuForSelection(
                paths, clickedPath, ownerHwnd, x, y)
        else
            ShowPopDropContextMenu(
                paths, clickedPath, ownerHwnd, x, y)
    } finally {
        ContextMenuDispatchActive := false
    }
}

ShowSystemContextMenuForSelection(
    paths, clickedPath, ownerHwnd, x, y
) {
    shellPaths := GetShellMenuPaths(paths, clickedPath)
    if paths.Length > 1 && shellPaths.Length = 1
        SetUserStatus("所选项目来自不同位置；系统菜单仅作用于当前项目。")
    ShowShellContextMenu(shellPaths, ownerHwnd, x, y)
}

RevealItemsFromPopDropMenu(itemPaths, itemName, itemPos, menuObject) {
    ; AutoHotkey Menu callbacks always append ItemName, ItemPos and MenuObj.
    ; Keep those event arguments out of the semantic file-manager API.
    return RevealItemsInFileManager(itemPaths)
}

ShowPopDropContextMenu(paths, clickedPath, ownerHwnd, x, y) {
    global PinnedPaths, DefaultContextMenu, CONTEXT_MENU_POPDROP

    if IsTextWorkspace()
        return ShowTextBlockContextMenu(
            paths, clickedPath, ownerHwnd, x, y)

    contextMenu := Menu()
    openText := "打开`tEnter"
    contextMenu.Add(openText, OpenSelectedItems.Bind(paths.Clone()))
    usedMenuLabels := Map()
    usedMenuLabels[StrLower("打开")] := true
    usedMenuLabels[StrLower("选择其他程序…")] := true
    usedMenuLabels[StrLower("更多已配置应用…")] := true
    usedMenuLabels[StrLower("更多工具操作…")] := true
    usedMenuLabels[StrLower("在文件管理器中显示")] := true
    usedMenuLabels[StrLower("复制到…")] := true
    usedMenuLabels[StrLower("移动到…")] := true
    usedMenuLabels[StrLower("复制文件")] := true
    usedMenuLabels[StrLower("复制路径")] := true
    usedMenuLabels[StrLower("添加到固定项")] := true
    usedMenuLabels[StrLower("从固定项移除")] := true
    usedMenuLabels[StrLower("重命名…")] := true
    usedMenuLabels[StrLower("删除")] := true
    usedMenuLabels[StrLower("更多系统操作…")] := true

    singleFile := paths.Length = 1 && FileExist(paths[1])
        && !InStr(FileExist(paths[1]), "D")
    if singleFile {
        apps := GetApplicableOpenApps(paths[1])
        directCount := Min(5, apps.Length)
        usedLabels := Map()
        Loop directCount {
            app := apps[A_Index]
            label := UniqueOpenAppMenuLabel(app.Name, usedLabels)
            contextMenu.Add(label, OpenWithConfiguredApp.Bind(app.Id, paths[1]))
            usedMenuLabels[StrLower(RegExReplace(label, "`t.*$"))] := true
            try contextMenu.SetIcon(label, app.Icon)
        }
        if apps.Length > 5 {
            moreApps := Menu()
            Loop apps.Length - 5 {
                app := apps[A_Index + 5]
                label := UniqueOpenAppMenuLabel(app.Name, usedLabels)
                moreApps.Add(label, OpenWithConfiguredApp.Bind(app.Id, paths[1]))
                usedMenuLabels[StrLower(RegExReplace(label, "`t.*$"))] := true
                try moreApps.SetIcon(label, app.Icon)
            }
            contextMenu.Add("更多已配置应用…", moreApps)
        }
        contextMenu.Add("选择其他程序…", ChooseOtherProgramForFile.Bind(paths[1]))
    }

    actionPairs := GetApplicableOpenAppActions(paths, clickedPath)
    contextMenu.Add()
    if actionPairs.Length {
        actionLabels := BuildOpenAppActionMenuLabels(
            actionPairs, usedMenuLabels)
        directActionCount := Min(5, actionPairs.Length)
        Loop directActionCount {
            pair := actionPairs[A_Index]
            label := actionLabels[A_Index]
            contextMenu.Add(label, ExecuteOpenAppAction.Bind(
                pair.App.Id, pair.Action.Id, paths.Clone(), clickedPath))
            try contextMenu.SetIcon(label, pair.App.Icon)
        }
        if actionPairs.Length > 5 {
            moreActions := Menu()
            Loop actionPairs.Length - 5 {
                index := A_Index + 5
                pair := actionPairs[index]
                label := actionLabels[index]
                moreActions.Add(label, ExecuteOpenAppAction.Bind(
                    pair.App.Id, pair.Action.Id,
                    paths.Clone(), clickedPath))
                try moreActions.SetIcon(label, pair.App.Icon)
            }
            contextMenu.Add("更多工具操作…", moreActions)
        }
        contextMenu.Add()
    }
    revealText := "在文件管理器中显示`tCtrl+Enter"
    contextMenu.Add(revealText,
        RevealItemsFromPopDropMenu.Bind(paths.Clone()))
    if !CanRevealItemsInFileManager(paths)
        contextMenu.Disable(revealText)

    contextMenu.Add()
    copyMenu := BuildTransferTargetMenu("copy", paths)
    moveMenu := BuildTransferTargetMenu("move", paths)
    contextMenu.Add("复制到…", copyMenu)
    contextMenu.Add("移动到…", moveMenu)

    contextMenu.Add()
    copyFilesText := "复制文件`tCtrl+C"
    copyPathsText := "复制路径`tCtrl+Shift+C"
    contextMenu.Add(copyFilesText, CopyFileObjectsToClipboard.Bind(paths.Clone()))
    contextMenu.Add(copyPathsText, CopyPathTextToClipboard.Bind(paths.Clone()))

    contextMenu.Add()
    addCount := 0
    removeCount := 0
    for path in paths {
        if FindPathIndex(PinnedPaths, path)
            removeCount += 1
        else
            addCount += 1
    }
    addText := paths.Length > 1 ? "添加到固定项（" addCount " 项）" : "添加到固定项"
    removeText := paths.Length > 1 ? "从固定项移除（" removeCount " 项）" : "从固定项移除"
    contextMenu.Add(addText, AddSelectionToPinned.Bind(paths.Clone()))
    contextMenu.Add(removeText, RemoveSelectionFromPinned.Bind(paths.Clone()))
    if !addCount
        contextMenu.Disable(addText)
    if !removeCount
        contextMenu.Disable(removeText)

    contextMenu.Add()
    renameText := "重命名…"
    contextMenu.Add(renameText,
        RequestRenamePath.Bind(paths.Length = 1 ? paths[1] : ""))
    if paths.Length != 1 || !CanRenamePath(paths[1])
        contextMenu.Disable(renameText)
    deleteText := "删除`tDelete"
    contextMenu.Add(deleteText,
        DeletePathsToRecycleBin.Bind(paths.Clone()))

    if ParseDefaultContextMenu(DefaultContextMenu) = CONTEXT_MENU_POPDROP {
        contextMenu.Add()
        systemText := "更多系统操作…`tShift+F10"
        contextMenu.Add(systemText, ShowSystemMenuForSelection.Bind(
            paths.Clone(), clickedPath, ownerHwnd, x, y))
    }

    point := MenuScreenPoint(ownerHwnd, x, y)
    BeginAutoHidePause()
    try {
        ; Menu.Show follows CoordMode("Menu"). The ListView event supplies
        ; client coordinates, which MenuScreenPoint converted to screen pixels.
        CoordMode("Menu", "Screen")
        contextMenu.Show(point.X, point.Y)
    } finally {
        EndAutoHidePause()
    }
}

BuildOpenAppActionMenuLabels(actionPairs, usedLabels) {
    nameCounts := Map()
    for pair in actionPairs {
        key := StrLower(Trim(pair.Action.Name))
        nameCounts[key] := nameCounts.Has(key) ? nameCounts[key] + 1 : 1
    }
    labels := []
    for pair in actionPairs {
        base := Trim(pair.Action.Name)
        if nameCounts[StrLower(base)] > 1
            || usedLabels.Has(StrLower(base))
            base .= "（" pair.App.Name "）"
        label := base
        suffix := 2
        while usedLabels.Has(StrLower(label)) {
            label := base "（" suffix "）"
            suffix += 1
        }
        usedLabels[StrLower(label)] := true
        labels.Push(label)
    }
    return labels
}

UniqueOpenAppMenuLabel(name, usedLabels) {
    base := "用 " name " 打开"
    count := usedLabels.Has(base) ? usedLabels[base] + 1 : 1
    usedLabels[base] := count
    return count = 1 ? base : base " (" count ")"
}

MenuScreenPoint(ownerHwnd, x, y) {
    point := Buffer(8, 0)
    if x = -1 || y = -1 {
        DllCall("user32\GetCursorPos", "ptr", point)
    } else {
        NumPut("int", x, point, 0)
        NumPut("int", y, point, 4)
        DllCall("user32\ClientToScreen", "ptr", ownerHwnd, "ptr", point)
    }
    return {X: NumGet(point, 0, "int"), Y: NumGet(point, 4, "int")}
}

ShowSystemMenuForSelection(paths, clickedPath, ownerHwnd, x, y, *) {
    ShowSystemContextMenuForSelection(
        paths, clickedPath, ownerHwnd, x, y)
}

BuildTransferTargetMenu(operation, paths) {
    global TransferFavorites, RecentTargets
    targetMenu := Menu()
    seen := Map()

    favorites := GetEffectiveTransferFavorites()
    heading := "常用位置"
    targetMenu.Add(heading, NoopMenuAction)
    targetMenu.Disable(heading)
    for target in favorites {
        key := PathKey(target.Path)
        if seen.Has(key)
            continue
        seen[key] := true
        text := target.Label
        targetMenu.Add(text, RunTransferToTarget.Bind(
            operation, paths.Clone(), target.Path))
        if !DirExist(target.Path) {
            targetMenu.Rename(text, text "（不可用）")
            targetMenu.Disable(text "（不可用）")
        }
    }

    recentAdded := 0
    for targetPath in RecentTargets {
        key := PathKey(targetPath)
        if seen.Has(key)
            continue
        if !recentAdded {
            recentHeading := "最近目标"
            targetMenu.Add(recentHeading, NoopMenuAction)
            targetMenu.Disable(recentHeading)
        }
        recentAdded += 1
        seen[key] := true
        text := GetDistinctTargetLabel(targetPath, favorites, RecentTargets)
        targetMenu.Add(text, RunTransferToTarget.Bind(
            operation, paths.Clone(), targetPath))
        if !DirExist(targetPath) {
            targetMenu.Rename(text, text "（不可用）")
            targetMenu.Disable(text "（不可用）")
        }
        if recentAdded >= 3
            break
    }

    targetMenu.Add()
    targetMenu.Add("选择其他文件夹…",
        ChooseTransferFolder.Bind(operation, paths.Clone()))
    targetMenu.Add("管理常用位置…", OpenConfigAtTransferFavorites)
    if HasInvalidTransferTargets()
        targetMenu.Add("移除无效位置…", RemoveInvalidTransferTargets)
    return targetMenu
}

NoopMenuAction(*) {
}

GetEffectiveTransferFavorites() {
    global TransferFavorites, TransferFavoriteLabels
    result := []
    desktop := GetKnownFolderPath("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}")
    downloads := GetKnownFolderPath("{374DE290-123F-4565-9164-39C4925E467B}")
    for path in TransferFavorites {
        if result.Length >= 5
            break
        if ArrayContainsObjectPath(result, path)
            continue
        if TransferFavoriteLabels.Has(PathKey(path))
            && Trim(TransferFavoriteLabels[PathKey(path)]) != ""
            label := TransferFavoriteLabels[PathKey(path)]
        else if desktop != "" && PathsEqual(path, desktop)
            label := "桌面"
        else if downloads != "" && PathsEqual(path, downloads)
            label := "下载"
        else
            label := GetDistinctTargetLabel(path, TransferFavorites, [])
        result.Push({Path: path, Label: label})
    }
    return result
}

ArrayContainsObjectPath(objects, target) {
    for item in objects {
        if PathsEqual(item.Path, target)
            return true
    }
    return false
}

GetDistinctTargetLabel(path, firstList, secondList) {
    name := GetFileName(path)
    duplicate := false
    for list in [firstList, secondList] {
        for other in list {
            otherPath := IsObject(other) ? other.Path : other
            if !PathsEqual(otherPath, path) && GetFileName(otherPath) = name {
                duplicate := true
                break
            }
        }
    }
    return duplicate ? name " — " GetParentPath(path) : name
}

GetKnownFolderPath(guidText) {
    guid := GuidBuffer(guidText)
    resultPath := 0
    hr := DllCall("shell32\SHGetKnownFolderPath", "ptr", guid.Ptr,
        "uint", 0, "ptr", 0, "ptr*", &resultPath, "int")
    if hr != 0 || !resultPath
        return ""
    try return NormalizePath(StrGet(resultPath))
    finally DllCall("ole32\CoTaskMemFree", "ptr", resultPath)
}

HasInvalidTransferTargets() {
    global TransferFavorites, RecentTargets
    for path in TransferFavorites {
        if !DirExist(path)
            return true
    }
    for path in RecentTargets {
        if !DirExist(path)
            return true
    }
    return false
}

ShowShellContextMenu(paths, ownerHwnd, x, y) {
    if !IsObject(paths)
        paths := [paths]
    fullPidls := []
    parentFolder := 0
    contextMenu := 0
    menuHandle := 0

    BeginAutoHidePause()

    try {
        iidShellFolder := GuidBuffer("{000214E6-0000-0000-C000-000000000046}")
        childPidls := []
        for index, path in paths {
            pidl := 0
            if DllCall("shell32\SHParseDisplayName", "wstr", path, "ptr", 0,
                "ptr*", &pidl, "uint", 0, "ptr", 0) != 0
                throw Error("Windows Shell 无法解析此项目。")
            fullPidls.Push(pidl)
            currentParent := 0
            childPidl := 0
            if DllCall("shell32\SHBindToParent", "ptr", pidl,
                "ptr", iidShellFolder.Ptr, "ptr*", &currentParent,
                "ptr*", &childPidl) != 0
                throw Error("无法连接项目所在目录。")
            if index = 1
                parentFolder := currentParent
            else
                ObjRelease(currentParent)
            childPidls.Push(childPidl)
        }

        iidContextMenu := GuidBuffer("{000214E4-0000-0000-C000-000000000046}")
        childArray := Buffer(A_PtrSize * childPidls.Length, 0)
        for index, childPidl in childPidls
            NumPut("ptr", childPidl, childArray, (index - 1) * A_PtrSize)
        hr := ComCall(10, parentFolder, "ptr", ownerHwnd,
            "uint", childPidls.Length, "ptr", childArray.Ptr,
            "ptr", iidContextMenu.Ptr, "ptr", 0, "ptr*", &contextMenu)
        if hr != 0
            throw Error("无法创建系统文件菜单。")

        menuHandle := DllCall("user32\CreatePopupMenu", "ptr")
        ; CMF_EXPLORE | CMF_EXTENDEDVERBS | CMF_SYNCCASCADEMENU exposes the
        ; complete classic menu and asks extensions to build cascades now.
        hr := ComCall(3, contextMenu, "ptr", menuHandle, "uint", 0, "uint", 1,
            "uint", 0x7FFF, "uint", 0x1104)
        if hr < 0
            throw Error("系统文件菜单加载失败。")

        if x = -1 || y = -1 {
            point := Buffer(8, 0)
            DllCall("user32\GetCursorPos", "ptr", point)
            x := NumGet(point, 0, "int")
            y := NumGet(point, 4, "int")
        } else {
            ; AutoHotkey supplies GUI-client coordinates; TrackPopupMenuEx
            ; requires screen coordinates.
            point := Buffer(8, 0)
            NumPut("int", x, point, 0)
            NumPut("int", y, point, 4)
            DllCall("user32\ClientToScreen", "ptr", ownerHwnd, "ptr", point)
            x := NumGet(point, 0, "int")
            y := NumGet(point, 4, "int")
        }
        DllCall("user32\SetForegroundWindow", "ptr", ownerHwnd)
        command := DllCall("user32\TrackPopupMenuEx", "ptr", menuHandle,
            "uint", 0x0102, "int", x, "int", y, "ptr", ownerHwnd, "ptr", 0, "uint")
        if command {
            ciSize := A_PtrSize = 8 ? 56 : 36
            invokeInfo := Buffer(ciSize, 0)
            NumPut("uint", ciSize, invokeInfo, 0)
            NumPut("ptr", ownerHwnd, invokeInfo, 8)
            NumPut("ptr", command - 1, invokeInfo, A_PtrSize = 8 ? 16 : 12)
            NumPut("int", 1, invokeInfo, A_PtrSize = 8 ? 40 : 24) ; SW_SHOWNORMAL
            ComCall(4, contextMenu, "ptr", invokeInfo.Ptr)
        }
        DllCall("user32\PostMessageW", "ptr", ownerHwnd, "uint", 0, "ptr", 0, "ptr", 0)
    } catch as err {
        ShowPanelMsgBox("无法显示系统右键菜单：`n" err.Message, "右键菜单", "Iconx")
    } finally {
        EndAutoHidePause()
        if menuHandle
            DllCall("user32\DestroyMenu", "ptr", menuHandle)
        if contextMenu
            ObjRelease(contextMenu)
        if parentFolder
            ObjRelease(parentFolder)
        for pidl in fullPidls
            DllCall("ole32\CoTaskMemFree", "ptr", pidl)
    }
}

GuidBuffer(text) {
    guid := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", text, "ptr", guid.Ptr) != 0
        throw Error("GUID 解析失败：" text)
    return guid
}
