; Shell drag data object and IDropSource implementation.

BeginShellDrag(paths, ownerHwnd, itemContexts := 0) {
    global ActiveInternalDragContext
    BeginAutoHidePause()

    try {
        ActiveInternalDragContext := {
            Token: A_TickCount "-" DllCall("kernel32\GetCurrentProcessId", "uint"),
            Items: IsObject(itemContexts) ? itemContexts : [],
            Paths: paths.Clone()
        }
        if paths.Length = 1
            BeginSingleShellDrag(paths[1], ownerHwnd)
        else
            BeginMultiShellDrag(paths, ownerHwnd)
    } finally {
        ActiveInternalDragContext := 0
        try {
            ; Completing an outbound drop can transfer focus to the target
            ; application. In temporary mode the user may still want another
            ; item, so restore PopDrop before resuming automatic hiding. The
            ; next explicit click or Alt+Tab away will hide it normally.
            KeepTemporaryPanelVisibleAfterDrag()
        } finally {
            EndAutoHidePause()
        }
    }
}

BeginSingleShellDrag(path, ownerHwnd) {
    global DropVTable
    fullPidl := 0
    parentFolder := 0
    dataObject := 0
    try {
        if DllCall("shell32\SHParseDisplayName", "wstr", path, "ptr", 0, "ptr*", &fullPidl,
            "uint", 0, "ptr", 0) != 0
            return

        ; ILCloneFull is an SDK macro rather than a reliably exported DLL
        ; function. Bind to the parent Shell folder and ask it directly for
        ; the file's IDataObject instead; this works across Windows 10/11.
        iidShellFolder := GuidBuffer("{000214E6-0000-0000-C000-000000000046}")
        childPidl := 0
        if DllCall("shell32\SHBindToParent", "ptr", fullPidl, "ptr", iidShellFolder.Ptr,
            "ptr*", &parentFolder, "ptr*", &childPidl) != 0
            return

        children := Buffer(A_PtrSize, 0)
        NumPut("ptr", childPidl, children)
        iidDataObject := GuidBuffer("{0000010E-0000-0000-C000-000000000046}")
        hr := ComCall(10, parentFolder, "ptr", ownerHwnd, "uint", 1,
            "ptr", children.Ptr, "ptr", iidDataObject.Ptr, "ptr", 0,
            "ptr*", &dataObject)
        if hr != 0 || !dataObject
            return

        dropSource := Buffer(A_PtrSize + 8, 0)
        NumPut("ptr", DropVTable.Ptr, dropSource, 0)
        NumPut("uint", 1, dropSource, A_PtrSize)
        effect := 0
        ; COPY | MOVE | LINK. The target application chooses the actual effect.
        DllCall("ole32\DoDragDrop", "ptr", dataObject, "ptr", dropSource.Ptr,
            "uint", 0x7, "uint*", &effect)
    } finally {
        if dataObject
            ObjRelease(dataObject)
        if parentFolder
            ObjRelease(parentFolder)
        if fullPidl
            DllCall("ole32\CoTaskMemFree", "ptr", fullPidl)
    }
}

BeginMultiShellDrag(paths, ownerHwnd) {
    global DropVTable, DataVTable, DragDataObjects
    dataObject := Buffer(A_PtrSize + 8, 0)
    NumPut("ptr", DataVTable.Ptr, dataObject, 0)
    NumPut("uint", 1, dataObject, A_PtrSize)
    ; Keep the backing Buffer alive for as long as any drop target retains an
    ; IDataObject reference (some targets finish transfer asynchronously).
    DragDataObjects[dataObject.Ptr] := {Memory: dataObject, Paths: paths}

    dropSource := Buffer(A_PtrSize + 8, 0)
    NumPut("ptr", DropVTable.Ptr, dropSource, 0)
    NumPut("uint", 1, dropSource, A_PtrSize)
    effect := 0
    try {
        ; COPY | MOVE | LINK. The target chooses the effect exactly as it does
        ; for a multi-file drag initiated by Explorer.
        DllCall("ole32\DoDragDrop", "ptr", dataObject.Ptr, "ptr", dropSource.Ptr,
            "uint", 0x7, "uint*", &effect)
    } finally {
        DataRelease(dataObject.Ptr)
    }
}

DataQueryInterface(this, iid, objectOut) {
    static iidUnknown := GuidBuffer("{00000000-0000-0000-C000-000000000046}")
    static iidDataObject := GuidBuffer("{0000010E-0000-0000-C000-000000000046}")
    if !GuidPointersEqual(iid, iidUnknown.Ptr) && !GuidPointersEqual(iid, iidDataObject.Ptr) {
        NumPut("ptr", 0, objectOut)
        return 0x80004002 ; E_NOINTERFACE
    }
    NumPut("ptr", this, objectOut)
    DataAddRef(this)
    return 0 ; S_OK
}

DataAddRef(this) {
    count := NumGet(this + A_PtrSize, "uint") + 1
    NumPut("uint", count, this + A_PtrSize)
    return count
}

DataRelease(this) {
    global DragDataObjects
    count := NumGet(this + A_PtrSize, "uint")
    if count
        count -= 1
    NumPut("uint", count, this + A_PtrSize)
    if !count && DragDataObjects.Has(this)
        DragDataObjects.Delete(this)
    return count
}

DataGetData(this, formatEtc, medium) {
    global DragDataObjects
    if !DragDataObjects.Has(this) || !IsHDropFormat(formatEtc)
        return 0x80040064 ; DV_E_FORMATETC

    hDrop := CreateHDrop(DragDataObjects[this].Paths)
    if !hDrop
        return 0x8007000E ; E_OUTOFMEMORY
    NumPut("uint", 1, medium, 0) ; TYMED_HGLOBAL
    unionOffset := A_PtrSize = 8 ? 8 : 4
    releaseOffset := A_PtrSize = 8 ? 16 : 8
    NumPut("ptr", hDrop, medium, unionOffset)
    NumPut("ptr", 0, medium, releaseOffset)
    return 0 ; S_OK; the recipient owns hDrop via ReleaseStgMedium
}

DataGetDataHere(this, formatEtc, medium) {
    return 0x80004001 ; E_NOTIMPL
}

DataQueryGetData(this, formatEtc) {
    return IsHDropFormat(formatEtc) ? 0 : 0x80040064 ; S_OK / DV_E_FORMATETC
}

DataGetCanonicalFormatEtc(this, formatIn, formatOut) {
    ptdOffset := A_PtrSize = 8 ? 8 : 4
    NumPut("ptr", 0, formatOut, ptdOffset)
    return 0x00040130 ; DATA_S_SAMEFORMATETC
}

DataSetData(this, formatEtc, medium, release) {
    return 0x80004001 ; E_NOTIMPL
}

DataEnumFormatEtc(this, direction, enumOut) {
    if direction != 1 { ; DATADIR_GET
        NumPut("ptr", 0, enumOut)
        return 0x80004001 ; E_NOTIMPL
    }
    formatSize := A_PtrSize = 8 ? 32 : 20
    formatEtc := Buffer(formatSize, 0)
    FillHDropFormat(formatEtc.Ptr)
    enumerator := 0
    hr := DllCall("shell32\SHCreateStdEnumFmtEtc", "uint", 1,
        "ptr", formatEtc.Ptr, "ptr*", &enumerator, "int")
    NumPut("ptr", enumerator, enumOut)
    return hr
}

DataDAdvise(this, formatEtc, flags, adviseSink, connectionOut) {
    if connectionOut
        NumPut("uint", 0, connectionOut)
    return 0x80040003 ; OLE_E_ADVISENOTSUPPORTED
}

DataDUnadvise(this, connection) {
    return 0x80040003 ; OLE_E_ADVISENOTSUPPORTED
}

DataEnumDAdvise(this, enumOut) {
    NumPut("ptr", 0, enumOut)
    return 0x80040003 ; OLE_E_ADVISENOTSUPPORTED
}

IsHDropFormat(formatEtc) {
    if !formatEtc
        return false
    aspectOffset := A_PtrSize = 8 ? 16 : 8
    indexOffset := A_PtrSize = 8 ? 20 : 12
    tymedOffset := A_PtrSize = 8 ? 24 : 16
    clipFormat := NumGet(formatEtc + 0, "ushort")
    aspect := NumGet(formatEtc + aspectOffset, "uint")
    itemIndex := NumGet(formatEtc + indexOffset, "int")
    supportedMediums := NumGet(formatEtc + tymedOffset, "uint")
    return clipFormat = 15 && aspect = 1 && itemIndex = -1
        && (supportedMediums & 1)
}

FillHDropFormat(formatEtc) {
    aspectOffset := A_PtrSize = 8 ? 16 : 8
    indexOffset := A_PtrSize = 8 ? 20 : 12
    tymedOffset := A_PtrSize = 8 ? 24 : 16
    NumPut("ushort", 15, formatEtc, 0) ; CF_HDROP
    NumPut("uint", 1, formatEtc, aspectOffset) ; DVASPECT_CONTENT
    NumPut("int", -1, formatEtc, indexOffset)
    NumPut("uint", 1, formatEtc, tymedOffset) ; TYMED_HGLOBAL
}

CreateHDrop(paths) {
    characterCount := 1 ; final extra NUL terminator
    for path in paths
        characterCount += StrLen(path) + 1
    byteCount := 20 + characterCount * 2 ; DROPFILES + UTF-16 path list
    hGlobal := DllCall("kernel32\GlobalAlloc", "uint", 0x0042,
        "uptr", byteCount, "ptr") ; GMEM_MOVEABLE | GMEM_ZEROINIT
    if !hGlobal
        return 0
    memory := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
    if !memory {
        DllCall("kernel32\GlobalFree", "ptr", hGlobal)
        return 0
    }

    NumPut("uint", 20, memory, 0) ; DROPFILES.pFiles
    NumPut("int", 1, memory, 16) ; DROPFILES.fWide
    cursor := memory + 20
    for path in paths {
        DllCall("kernel32\lstrcpyW", "ptr", cursor, "wstr", path)
        cursor += (StrLen(path) + 1) * 2
    }
    ; GMEM_ZEROINIT already supplies the second terminating NUL.
    DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
    ; Validate the packed list with the same Shell API used by drop targets.
    packedCount := DllCall("shell32\DragQueryFileW", "ptr", hGlobal,
        "uint", 0xFFFFFFFF, "ptr", 0, "uint", 0, "uint")
    if packedCount != paths.Length {
        DllCall("kernel32\GlobalFree", "ptr", hGlobal)
        return 0
    }
    return hGlobal
}

DropQueryInterface(this, iid, objectOut) {
    static iidUnknown := GuidBuffer("{00000000-0000-0000-C000-000000000046}")
    static iidDropSource := GuidBuffer("{00000121-0000-0000-C000-000000000046}")
    if !GuidPointersEqual(iid, iidUnknown.Ptr) && !GuidPointersEqual(iid, iidDropSource.Ptr) {
        NumPut("ptr", 0, objectOut)
        return 0x80004002 ; E_NOINTERFACE
    }
    NumPut("ptr", this, objectOut)
    DropAddRef(this)
    return 0 ; S_OK
}

GuidPointersEqual(left, right) {
    Loop 4 {
        offset := (A_Index - 1) * 4
        if NumGet(left + offset, "uint") != NumGet(right + offset, "uint")
            return false
    }
    return true
}

DropAddRef(this) {
    count := NumGet(this + A_PtrSize, "uint") + 1
    NumPut("uint", count, this + A_PtrSize)
    return count
}

DropRelease(this) {
    count := Max(0, NumGet(this + A_PtrSize, "uint") - 1)
    NumPut("uint", count, this + A_PtrSize)
    return count
}

DropQueryContinue(this, escapePressed, keyState) {
    if escapePressed
        return 0x00040101 ; DRAGDROP_S_CANCEL
    if !(keyState & 0x0001) ; MK_LBUTTON
        return 0x00040100 ; DRAGDROP_S_DROP
    return 0 ; S_OK
}

DropGiveFeedback(this, effect) {
    return 0x00040102 ; DRAGDROP_S_USEDEFAULTCURSORS
}
