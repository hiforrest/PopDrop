; OLE drop-source initialization, IDropTarget and local drop handling.

InitDropSource() {
    global DropVTable, DropCallbacks, DataVTable, DataCallbacks
    DropCallbacks := [
        CallbackCreate(DropQueryInterface, "Fast", 3),
        CallbackCreate(DropAddRef, "Fast", 1),
        CallbackCreate(DropRelease, "Fast", 1),
        CallbackCreate(DropQueryContinue, "Fast", 3),
        CallbackCreate(DropGiveFeedback, "Fast", 2)
    ]
    DropVTable := Buffer(5 * A_PtrSize, 0)
    for index, callbackPtr in DropCallbacks
        NumPut("ptr", callbackPtr, DropVTable, (index - 1) * A_PtrSize)

    ; Minimal IDataObject used for a multi-file CF_HDROP payload. Unlike an
    ; IShellFolder child array, CF_HDROP can contain paths from any number of
    ; directories and drives.
    DataCallbacks := [
        CallbackCreate(DataQueryInterface, "Fast", 3),
        CallbackCreate(DataAddRef, "Fast", 1),
        CallbackCreate(DataRelease, "Fast", 1),
        CallbackCreate(DataGetData, "Fast", 3),
        CallbackCreate(DataGetDataHere, "Fast", 3),
        CallbackCreate(DataQueryGetData, "Fast", 2),
        CallbackCreate(DataGetCanonicalFormatEtc, "Fast", 3),
        CallbackCreate(DataSetData, "Fast", 4),
        CallbackCreate(DataEnumFormatEtc, "Fast", 3),
        CallbackCreate(DataDAdvise, "Fast", 5),
        CallbackCreate(DataDUnadvise, "Fast", 2),
        CallbackCreate(DataEnumDAdvise, "Fast", 2)
    ]
    DataVTable := Buffer(12 * A_PtrSize, 0)
    for index, callbackPtr in DataCallbacks
        NumPut("ptr", callbackPtr, DataVTable, (index - 1) * A_PtrSize)
}

; ──── OLE IDropTarget ────
; One COM object is registered on the panel and its child HWNDs. Windows routes
; a drag to the deepest registered window under the pointer, so registering
; only the Gui HWND would miss the ListView and toolbar controls.

InitDropTarget() {
    global DropTargetVTable, DropTargetCallbacks, DropTargetObjects
    global Panel
    enterCallback := A_PtrSize = 8
        ? CallbackCreate(DropTargetDragEnter64, "Fast", 5)
        : CallbackCreate(DropTargetDragEnter32, "Fast", 6)
    overCallback := A_PtrSize = 8
        ? CallbackCreate(DropTargetDragOver64, "Fast", 4)
        : CallbackCreate(DropTargetDragOver32, "Fast", 5)
    dropCallback := A_PtrSize = 8
        ? CallbackCreate(DropTargetDrop64, "Fast", 5)
        : CallbackCreate(DropTargetDrop32, "Fast", 6)
    DropTargetCallbacks := [
        CallbackCreate(DropTargetQueryInterface, "Fast", 3),
        CallbackCreate(DropTargetAddRef, "Fast", 1),
        CallbackCreate(DropTargetRelease, "Fast", 1),
        enterCallback,
        overCallback,
        CallbackCreate(DropTargetDragLeave, "Fast", 1),
        dropCallback
    ]
    DropTargetVTable := Buffer(7 * A_PtrSize, 0)
    for index, callbackPtr in DropTargetCallbacks
        NumPut("ptr", callbackPtr, DropTargetVTable, (index - 1) * A_PtrSize)

    target := Buffer(A_PtrSize + 8, 0)
    NumPut("ptr", DropTargetVTable.Ptr, target, 0)
    NumPut("uint", 1, target, A_PtrSize)
    DropTargetObjects[target.Ptr] := {Memory: target}
    RegisterPanelDropTargetWindows(Panel.Hwnd, target.Ptr)
}

RegisterPanelDropTargetWindows(rootHwnd, targetPtr) {
    RegisterDropTargetWindow(rootHwnd, targetPtr)
    RegisterDropTargetChildren(rootHwnd, targetPtr)
}

RegisterDropTargetChildren(parentHwnd, targetPtr) {
    static GW_CHILD := 5
    static GW_HWNDNEXT := 2
    child := DllCall("user32\GetWindow", "ptr", parentHwnd,
        "uint", GW_CHILD, "ptr")
    while child {
        RegisterDropTargetWindow(child, targetPtr)
        RegisterDropTargetChildren(child, targetPtr)
        child := DllCall("user32\GetWindow", "ptr", child,
            "uint", GW_HWNDNEXT, "ptr")
    }
}

RegisterDropTargetWindow(hwnd, targetPtr) {
    global DropTargetRegisteredHwnds, DropTargetRegistrationErrors
    if !hwnd || DropTargetRegisteredHwnds.Has(hwnd)
        return
    hr := DllCall("ole32\RegisterDragDrop", "ptr", hwnd,
        "ptr", targetPtr, "int")
    unsignedHr := hr & 0xFFFFFFFF
    if hr = 0 {
        DropTargetRegisteredHwnds[hwnd] := targetPtr
        return
    }
    if unsignedHr = 0x80040101
        reason := "窗口已由其他 OLE 投放目标注册"
    else
        reason := "RegisterDragDrop HRESULT "
            . Format("0x{:08X}", unsignedHr)
    DropTargetRegistrationErrors.Push({Hwnd: hwnd, Reason: reason})
}

RevokePanelDropTargets() {
    global DropTargetRegisteredHwnds, DropTargetObjects
    for hwnd, targetPtr in DropTargetRegisteredHwnds {
        if DllCall("user32\IsWindow", "ptr", hwnd, "int")
            try DllCall("ole32\RevokeDragDrop", "ptr", hwnd, "int")
    }
    DropTargetRegisteredHwnds := Map()
    baseTargets := []
    for targetPtr, targetState in DropTargetObjects
        baseTargets.Push(targetPtr)
    for targetPtr in baseTargets
        DropTargetRelease(targetPtr)
}

DropTargetQueryInterface(this, iid, objectOut) {
    static iidUnknown := GuidBuffer("{00000000-0000-0000-C000-000000000046}")
    static iidDropTarget := GuidBuffer("{00000122-0000-0000-C000-000000000046}")
    if !GuidPointersEqual(iid, iidUnknown.Ptr)
        && !GuidPointersEqual(iid, iidDropTarget.Ptr) {
        NumPut("ptr", 0, objectOut)
        return 0x80004002
    }
    NumPut("ptr", this, objectOut)
    DropTargetAddRef(this)
    return 0
}

DropTargetAddRef(this) {
    count := NumGet(this + A_PtrSize, "uint") + 1
    NumPut("uint", count, this + A_PtrSize)
    return count
}

DropTargetRelease(this) {
    global DropTargetObjects
    count := NumGet(this + A_PtrSize, "uint")
    if count
        count -= 1
    NumPut("uint", count, this + A_PtrSize)
    if !count && DropTargetObjects.Has(this)
        DropTargetObjects.Delete(this)
    return count
}

DropTargetDragEnter64(this, dataObject, keyState, pointValue, effectPtr) {
    return DropTargetDragEnterCore(dataObject, keyState,
        PointValueX(pointValue), PointValueY(pointValue), effectPtr)
}

DropTargetDragEnter32(this, dataObject, keyState, pointX, pointY, effectPtr) {
    return DropTargetDragEnterCore(dataObject, keyState,
        SignedInt32(pointX), SignedInt32(pointY), effectPtr)
}

DropTargetDragOver64(this, keyState, pointValue, effectPtr) {
    return DropTargetDragOverCore(keyState,
        PointValueX(pointValue), PointValueY(pointValue), effectPtr)
}

DropTargetDragOver32(this, keyState, pointX, pointY, effectPtr) {
    return DropTargetDragOverCore(keyState,
        SignedInt32(pointX), SignedInt32(pointY), effectPtr)
}

DropTargetDrop64(this, dataObject, keyState, pointValue, effectPtr) {
    return DropTargetDropCore(dataObject, keyState,
        PointValueX(pointValue), PointValueY(pointValue), effectPtr)
}

DropTargetDrop32(this, dataObject, keyState, pointX, pointY, effectPtr) {
    return DropTargetDropCore(dataObject, keyState,
        SignedInt32(pointX), SignedInt32(pointY), effectPtr)
}

PointValueX(pointValue) {
    return SignedInt32(pointValue & 0xFFFFFFFF)
}

PointValueY(pointValue) {
    return SignedInt32((pointValue >> 32) & 0xFFFFFFFF)
}

SignedInt32(value) {
    value &= 0xFFFFFFFF
    return value >= 0x80000000 ? value - 0x100000000 : value
}

DropTargetDragEnterCore(dataObject, keyState, screenX, screenY, effectPtr) {
    global ActiveDropSession, ActiveInternalDragContext
    global DropFolderValidationCache
    global DROP_ADAPTER_UNSUPPORTED
    try {
        PreviewSuppress("external-drag", false)
        CancelDeferredDropLeave()
        ; Moving between registered child HWNDs can produce a paired
        ; DragLeave/DragEnter for the same IDataObject. Keep the logical
        ; session so a safe HDROP preview is never read a second time.
        if IsObject(ActiveDropSession)
            && ActiveDropSession.DataObject = dataObject
            && !ActiveDropSession.Completed {
            TouchIncomingDropGesture()
            ActiveDropSession.AllowedEffects :=
                NumGet(effectPtr + 0, "uint") & 0x3
            return UpdateDropFeedback(
                keyState, screenX, screenY, effectPtr)
        }
        ResetActiveDropSession(true)
        TouchIncomingDropGesture()
        DropFolderValidationCache := Map()
        allowedEffects := NumGet(effectPtr + 0, "uint") & 0x3
        session := CreateDropSessionState()
        session.DataObject := dataObject
        ObjAddRef(dataObject)
        session.AllowedEffects := allowedEffects
        session.PreviousStatus := CaptureDropStatus()
        session.Paused := true
        BeginAutoHidePause()
        ActiveDropSession := session
        SetPinnedDropDiscovery(true)

        session.Decision := ClassifyDataObject(dataObject)
        session.AsyncInfo := DataObjectAsyncMode(dataObject)
        if session.Decision.Adapter = DROP_ADAPTER_UNSUPPORTED {
            session.Unsupported := true
            SetDropEffect(effectPtr, 0)
            ShowDropFeedback(InvalidDropTarget(
                session.Decision.Reason), 0, 0)
            return 0
        }
        session.SourceKind := IsObject(ActiveInternalDragContext)
            ? ClassifyDropSource(ActiveInternalDragContext.Items, true)
            : "External"
        ; Internal drags already own a trusted path array. External HDROP is
        ; pre-read only for the narrow stable-local case approved by
        ; CanPreloadHDropForFolderFeedback(). Explorer Shell selections can
        ; be safely recognized by CFSTR_SHELLIDLIST even when they advertise
        ; async capability or auxiliary formats. Unknown async, URL, virtual
        ; and image objects remain zero-extraction until Drop.
        if IsObject(ActiveInternalDragContext) {
            CacheDropSessionPaths(
                session, ActiveInternalDragContext.Paths, false)
        } else if CanPreloadHDropForFolderFeedback(
            session.Decision, session.AsyncInfo, session.SourceKind) {
            ; DragEnter preloading is only a visual optimization. Some Shell
            ; sources (notably Directory Opus address-bar drags) advertise
            ; CF_HDROP before GetData is ready. An empty/failed preload must
            ; remain retryable when Drop is actually committed.
            try PreloadDropSessionHDropPaths(session, dataObject)
        }
        SyncFolderDropModeForSession(session)
        return UpdateDropFeedback(keyState, screenX, screenY, effectPtr)
    } catch {
        SetDropEffect(effectPtr, 0)
        ResetActiveDropSession(true)
        return 0
    }
}

DropTargetDragOverCore(keyState, screenX, screenY, effectPtr) {
    TouchIncomingDropGesture()
    try return UpdateDropFeedback(keyState, screenX, screenY, effectPtr)
    catch {
        SetDropEffect(effectPtr, 0)
        ResetActiveDropSession(true)
        return 0
    }
}

DropTargetDragLeave(this) {
    global DropLeaveGeneration
    DropLeaveGeneration += 1
    token := DropLeaveGeneration
    ; Child HWND transitions re-enter immediately. Deferring cleanup keeps
    ; their shared logical session and still restores real leaves promptly.
    SetTimer(FinalizeDeferredDropLeave.Bind(token), -50)
    return 0
}

CancelDeferredDropLeave() {
    global DropLeaveGeneration
    DropLeaveGeneration += 1
}

FinalizeDeferredDropLeave(token) {
    global DropLeaveGeneration
    if token = DropLeaveGeneration
        ResetActiveDropSession(true)
}

DropTargetDropCore(dataObject, keyState, screenX, screenY, effectPtr) {
    global ActiveDropSession, DROP_ADAPTER_HDROP, DROP_ADAPTER_TEXT
    BeginIncomingDropCommit()
    try {
        CancelDeferredDropLeave()
        if !IsObject(ActiveDropSession) || ActiveDropSession.Unsupported {
            SetDropEffect(effectPtr, 0)
            ResetActiveDropSession(true)
            return 0
        }
        UpdateDropFeedback(keyState, screenX, screenY, effectPtr)
        session := ActiveDropSession
        effect := session.Effect
        target := session.Target
        SetDropEffect(effectPtr, effect)
        if !effect || !IsObject(target) || !target.Available {
            ResetActiveDropSession(true)
            return 0
        }

        ; Detach the state before invoking Shell/UI code to prevent reentrant
        ; DragLeave from clearing the final operation status.
        ActiveDropSession := 0
        ClearDropVisuals()
        try {
            adapter := HasProp(session, "ActiveAdapter")
                ? session.ActiveAdapter : session.Decision.Adapter
            if adapter = DROP_ADAPTER_TEXT {
                text := ReadDataObjectText(dataObject)
                if NormalizeCapturedText(text) = ""
                    throw Error("拖拽数据中没有可保存的文字。")
                SaveCapturedTextBlock(text, target)
            } else if adapter = DROP_ADAPTER_HDROP {
                if target.Type = "AddSource" {
                    session.Paths := GetDropSessionHDropPaths(
                        session, dataObject)
                    session.PathInfo := BuildDropPathInfo(session.Paths)
                    session.PayloadKind := ClassifyDropPaths(
                        session.Paths, session.PathInfo)
                    ExecuteLocalDrop(session.Paths, target, effect,
                        [], session.SourceKind)
                } else if HDropShouldUseDirectAsyncTakeover(
                    session.SourceKind, target, session.AsyncInfo) {
                    ; Do not pre-read delayed-render CF_HDROP here. Chromium
                    ; may start one source download per GetData call.
                    CreateExternalTransfer(dataObject,
                        session.Decision.Adapter, target)
                } else {
                    session.Paths := GetDropSessionHDropPaths(
                        session, dataObject)
                    if !session.Paths.Length
                        throw Error("拖拽数据中没有有效的本地文件系统项目。")
                    if session.SourceKind = "External"
                        && HasProp(session.Decision, "HasExplicitUrl")
                        && session.Decision.HasExplicitUrl
                        session.Paths := DedupeWebHDropPaths(session.Paths)
                    session.InternalItems := GetActiveInternalDropItems(
                        session.Paths)
                    session.PathInfo := BuildDropPathInfo(session.Paths)
                    session.SourceKind := ClassifyDropSource(
                        session.InternalItems,
                        IsObject(ActiveInternalDragContext))
                    ExecuteLocalDrop(session.Paths, target, effect,
                        session.InternalItems, session.SourceKind)
                }
            } else {
                CreateExternalTransfer(dataObject, adapter, target)
            }
        } catch as err {
            SetDropEffect(effectPtr, 0)
            ShowPanelMsgBox("无法完成投放：`n" err.Message,
                "投放失败", "Iconx")
        }
        finally {
            if HasProp(session, "DataObject") && session.DataObject
                try ObjRelease(session.DataObject)
            try KeepTemporaryPanelVisibleAfterDrag()
            if session.Paused
                try EndAutoHidePause()
            MarkDropSessionFinished(session, "drop")
            try PreviewRecoverAfterInteraction()
        }
        return 0
    } catch {
        SetDropEffect(effectPtr, 0)
        ResetActiveDropSession(true)
        return 0
    } finally {
        EndIncomingDropGesture(true)
    }
}

TouchIncomingDropGesture() {
    global IncomingDropGestureActive, IncomingDropLastEventTick
    IncomingDropGestureActive := true
    IncomingDropLastEventTick := A_TickCount
}

BeginIncomingDropCommit() {
    global IncomingDropCommitActive
    TouchIncomingDropGesture()
    IncomingDropCommitActive := true
}

EndIncomingDropGesture(force := false) {
    global IncomingDropGestureActive, IncomingDropCommitActive
    global IncomingDropLastEventTick
    ; ResetActiveDropSession can be reached by defensive cleanup. It must not
    ; drop the guard while a detached Drop callback is still saving data.
    if IncomingDropCommitActive && !force
        return
    IncomingDropGestureActive := false
    IncomingDropCommitActive := false
    IncomingDropLastEventTick := 0
}

IncomingDropProtectsAutoHide(nowTick := unset) {
    global IncomingDropGestureActive, IncomingDropCommitActive
    global IncomingDropLastEventTick
    if IncomingDropCommitActive
        return true
    if !IncomingDropGestureActive || !IncomingDropLastEventTick
        return false
    now := IsSet(nowTick) ? nowTick : A_TickCount
    ; Cover the button-up -> Drop callback dispatch gap. A genuinely lost
    ; DragLeave/Drop cannot poison temporary mode because this lease expires.
    return ElapsedTickMilliseconds(IncomingDropLastEventTick, now) < 1200
}

CreateDropSessionState() {
    return {
        DataObject: 0,
        AllowedEffects: 0,
        Paths: [],
        InternalItems: [],
        SourceKind: "External",
        Target: 0,
        Effect: 0,
        SkipCount: 0,
        PathInfo: Map(),
        PayloadKind: "Unknown",
        PathsCached: false,
        HDropReadAttempted: false,
        HDropReadCount: 0,
        FolderDropUiShown: false,
        Decision: {Adapter: "Unsupported", Formats: [], Reason: ""},
        AsyncInfo: {Supported: false, Enabled: false},
        Unsupported: false,
        Paused: false,
        PreviousStatus: 0,
        Completed: false
    }
}

CacheDropSessionPaths(session, paths, fromDataObject := false) {
    session.Paths := IsObject(paths) ? paths.Clone() : []
    session.PathsCached := true
    if fromDataObject {
        session.HDropReadAttempted := true
        session.HDropReadCount += 1
    }
    session.PathInfo := BuildDropPathInfo(session.Paths)
    session.PayloadKind := ClassifyDropPaths(
        session.Paths, session.PathInfo)
    return session.Paths
}

GetDropSessionHDropPaths(session, dataObject, reader := unset) {
    if session.PathsCached
        return session.Paths
    if session.HDropReadAttempted
        return session.Paths
    session.HDropReadAttempted := true
    session.HDropReadCount += 1
    session.Paths := []
    loaded := IsSet(reader)
        ? reader.Call(dataObject) : ReadHDropPaths(dataObject)
    session.Paths := IsObject(loaded) ? loaded.Clone() : []
    session.PathsCached := true
    session.PathInfo := BuildDropPathInfo(session.Paths)
    session.PayloadKind := ClassifyDropPaths(
        session.Paths, session.PathInfo)
    return session.Paths
}

PreloadDropSessionHDropPaths(session, dataObject, reader := unset) {
    ; Preloading exists solely to show folder-specific targets during hover.
    ; Do not consume the session's one authoritative Drop-time read unless a
    ; complete non-empty path list was actually obtained.
    try {
        if IsSet(reader)
            paths := GetDropSessionHDropPaths(session, dataObject, reader)
        else
            paths := GetDropSessionHDropPaths(session, dataObject)
    } catch {
        session.Paths := []
        session.PathsCached := false
        session.HDropReadAttempted := false
        session.PathInfo := Map()
        session.PayloadKind := "Unknown"
        return session.Paths
    }
    if !paths.Length {
        session.Paths := []
        session.PathsCached := false
        session.HDropReadAttempted := false
        session.PathInfo := Map()
        session.PayloadKind := "Unknown"
    }
    return session.Paths
}

SyncFolderDropModeForSession(session) {
    if IsObject(session) && ShouldShowFolderDropMode(session.PayloadKind) {
        ShowFolderDropMode()
        session.FolderDropUiShown := true
    } else {
        HideFolderDropMode()
        if IsObject(session)
            session.FolderDropUiShown := false
    }
}

ShouldShowFolderDropMode(payloadKind) {
    return payloadKind = "FoldersOnly"
}

MarkDropSessionFinished(session, outcome) {
    session.Completed := true
    session.Outcome := outcome
    session.Paused := false
    session.FolderDropUiShown := false
    return session
}

ResetActiveDropSession(restoreStatus := true) {
    global ActiveDropSession
    CancelDeferredDropLeave()
    if !IsObject(ActiveDropSession) {
        ClearDropVisuals()
        EndIncomingDropGesture()
        return
    }
    session := ActiveDropSession
    ActiveDropSession := 0
    ClearDropVisuals()
    if restoreStatus && IsObject(session.PreviousStatus)
        RestoreDropStatus(session.PreviousStatus)
    if HasProp(session, "DataObject") && session.DataObject
        ObjRelease(session.DataObject)
    if session.Paused
        EndAutoHidePause()
    MarkDropSessionFinished(session, "reset")
    EndIncomingDropGesture()
    PreviewRecoverAfterInteraction()
}

UpdateDropFeedback(keyState, screenX, screenY, effectPtr) {
    global ActiveDropSession, DROP_ADAPTER_HDROP, DROP_ADAPTER_TEXT
    if !IsObject(ActiveDropSession) || ActiveDropSession.Unsupported {
        SetDropEffect(effectPtr, 0)
        return 0
    }
    SyncFolderDropModeForSession(ActiveDropSession)
    target := ResolveDropTarget(screenX, screenY)
    adapter := SelectDropAdapterForTarget(
        ActiveDropSession.Decision, target)
    if ActiveDropSession.SourceKind != "External"
        && ActiveDropSession.Paths.Length
        && (target.Type = "TextSource" || target.Type = "TextPinned")
        adapter := DROP_ADAPTER_HDROP
    ActiveDropSession.ActiveAdapter := adapter
    if !ExternalAdapterAllowedAtTarget(adapter, target) {
        target.Available := false
        target.Reason := ExternalAdapterTargetReason(adapter, target)
    }
    effect := ResolveDropEffect(target, keyState,
        ActiveDropSession.AllowedEffects, ActiveDropSession.SourceKind,
        ActiveDropSession.Paths)
    restriction := TextPinnedDropRestrictionReason(target, keyState,
        ActiveDropSession.SourceKind, ActiveDropSession.Paths)
    if restriction != "" {
        target.Available := false
        target.Reason := restriction
        effect := 0
    }
    if adapter = DROP_ADAPTER_TEXT && target.Available
        effect := (ActiveDropSession.AllowedEffects & 1) ? 1 : 0
    else if adapter != DROP_ADAPTER_HDROP && target.Available
        effect := (ActiveDropSession.AllowedEffects & 1) ? 1 : 0
    else if adapter = DROP_ADAPTER_HDROP
        && ActiveDropSession.AsyncInfo.Supported
        && ActiveDropSession.SourceKind = "External"
        && target.Type = "Files"
        effect := (ActiveDropSession.AllowedEffects & 1) ? 1 : 0
    skipCount := GetDropPreviewSkipCount(target, effect,
        ActiveDropSession.Paths, ActiveDropSession.InternalItems,
        ActiveDropSession.PathInfo)
    if effect && ActiveDropSession.Paths.Length
        && skipCount = ActiveDropSession.Paths.Length {
        target.Available := false
        target.Reason := "所有项目都属于该来源、位于目标位置，"
            . "或文件夹目标是其自身/后代。"
        effect := 0
    }
    ActiveDropSession.Target := target
    ActiveDropSession.Effect := effect
    ActiveDropSession.SkipCount := skipCount
    SetDropEffect(effectPtr, effect)
    itemCount := ActiveDropSession.Paths.Length
        ? ActiveDropSession.Paths.Length : 1
    ShowDropFeedback(target, effect, itemCount,
        skipCount)
    return 0
}

SetDropEffect(effectPtr, effect) {
    if effectPtr
        NumPut("uint", effect, effectPtr + 0)
}

DataObjectSupportsHDrop(dataObject) {
    if !dataObject
        return false
    formatSize := A_PtrSize = 8 ? 32 : 20
    formatEtc := Buffer(formatSize, 0)
    FillHDropFormat(formatEtc.Ptr)
    try return HResultSucceeded(
        ComCall(5, dataObject, "ptr", formatEtc.Ptr, "int"))
    catch
        return false
}

ReadHDropPaths(dataObject) {
    paths := []
    formatSize := A_PtrSize = 8 ? 32 : 20
    mediumSize := A_PtrSize = 8 ? 24 : 12
    formatEtc := Buffer(formatSize, 0)
    medium := Buffer(mediumSize, 0)
    FillHDropFormat(formatEtc.Ptr)
    hr := ComCall(3, dataObject, "ptr", formatEtc.Ptr,
        "ptr", medium.Ptr, "int")
    if !HResultSucceeded(hr)
        return paths
    try {
        unionOffset := A_PtrSize = 8 ? 8 : 4
        hDrop := NumGet(medium, unionOffset, "ptr")
        if !hDrop
            return paths
        count := DllCall("shell32\DragQueryFileW", "ptr", hDrop,
            "uint", 0xFFFFFFFF, "ptr", 0, "uint", 0, "uint")
        Loop count {
            index := A_Index - 1
            length := DllCall("shell32\DragQueryFileW", "ptr", hDrop,
                "uint", index, "ptr", 0, "uint", 0, "uint")
            if !length
                continue
            pathBuffer := Buffer((length + 1) * 2, 0)
            if DllCall("shell32\DragQueryFileW", "ptr", hDrop,
                "uint", index, "ptr", pathBuffer.Ptr,
                "uint", length + 1, "uint") {
                path := NormalizePath(StrGet(pathBuffer))
                if path != "" && !ArrayContainsPath(paths, path)
                    paths.Push(path)
            }
        }
    } finally {
        DllCall("ole32\ReleaseStgMedium", "ptr", medium.Ptr)
    }
    return paths
}

GetActiveInternalDropItems(paths) {
    global ActiveInternalDragContext
    if !IsObject(ActiveInternalDragContext)
        return []
    items := []
    for path in paths {
        found := 0
        for context in ActiveInternalDragContext.Items {
            if HasProp(context, "Path") && PathsEqual(context.Path, path) {
                found := CloneDropItemContext(context)
                found.Path := path
                break
            }
        }
        if !IsObject(found)
            found := {Path: path, Area: "Unknown"}
        items.Push(found)
    }
    return items
}

ClassifyDropSource(items, isInternal) {
    if !isInternal
        return "External"
    if !items.Length
        return "InternalUnknown"
    allSource := true
    allPinned := true
    allRecent := true
    for item in items {
        area := HasProp(item, "Area") ? item.Area : "Unknown"
        if area != "Source"
            allSource := false
        if area != "Pinned"
            allPinned := false
        if area != "Recent"
            allRecent := false
    }
    if allSource
        return "Source"
    if allPinned
        return "Pinned"
    if allRecent
        return "Recent"
    return "Mixed"
}

BuildDropPathInfo(paths) {
    info := Map()
    for path in paths {
        attributes := FileExist(path)
        info[PathKey(path)] := {
            Exists: attributes != "",
            IsDirectory: attributes != "" && InStr(attributes, "D")
        }
    }
    return info
}

ClassifyDropPaths(paths, pathInfo := unset) {
    if !IsObject(paths) || !paths.Length
        return "Unknown"
    info := IsSet(pathInfo) ? pathInfo : BuildDropPathInfo(paths)
    fileCount := 0
    folderCount := 0
    for path in paths {
        key := PathKey(path)
        if !info.Has(key) || !info[key].Exists
            return "Unknown"
        if info[key].IsDirectory
            folderCount += 1
        else
            fileCount += 1
    }
    if folderCount = paths.Length
        return "FoldersOnly"
    if fileCount = paths.Length
        return "FilesOnly"
    return "Mixed"
}

IsPersistableFileSystemFolder(path, pathInfo := unset) {
    normalized := NormalizePath(path)
    if normalized = ""
        return false
    ; Reject parsing names, URI-like values and other Shell namespaces. Only
    ; drive-rooted and UNC file-system paths can be persisted as a source.
    if !RegExMatch(normalized, "i)^(?:[A-Z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))")
        return false
    if IsSet(pathInfo) {
        key := PathKey(normalized)
        return pathInfo.Has(key) && pathInfo[key].Exists
            && pathInfo[key].IsDirectory
    }
    attributes := FileExist(normalized)
    return attributes != "" && InStr(attributes, "D")
}

GetDropPreviewSkipCount(target, effect, paths, internalItems, pathInfo) {
    if !effect || !IsObject(target) || target.Type != "Files"
        return 0
    skipped := 0
    for path in paths {
        key := PathKey(path)
        if !pathInfo.Has(key) || !pathInfo[key].Exists {
            skipped += 1
            continue
        }
        item := FindDropItemForPath(internalItems, path)
        if IsObject(item)
            && DropItemMatchesTargetSource(
                item, target.Path, target.SourceId) {
            skipped += 1
            continue
        }
        if pathInfo[key].IsDirectory
            && IsSameOrDescendantPath(target.Path, path) {
            skipped += 1
            continue
        }
        if effect = 2 && PathsEqual(GetParentPath(path), target.Path)
            skipped += 1
    }
    return skipped
}

ResolveDropEffect(target, keyState, allowedEffects, sourceKind, paths := 0) {
    static DROPEFFECT_NONE := 0
    static DROPEFFECT_COPY := 1
    static DROPEFFECT_MOVE := 2
    if !IsObject(target) || !target.Available
        return DROPEFFECT_NONE
    if target.Type = "Pinned" || target.Type = "TextPinned"
        || target.Type = "Launcher"
        || target.Type = "AddSource"
        return (allowedEffects & DROPEFFECT_COPY)
            ? DROPEFFECT_COPY : DROPEFFECT_NONE
    if target.Type != "Files" && target.Type != "TextSource"
        return DROPEFFECT_NONE

    ctrl := (keyState & 0x0008) != 0
    shift := (keyState & 0x0004) != 0
    if target.Type = "TextSource" && sourceKind = "Pinned" {
        ; App-owned inbox blocks behave like entities: moving classifies them
        ; into the destination. Pinned references never move their originals.
        ; A mixed selection is accepted only as an explicit Ctrl-copy batch.
        allDrafts := AllTextBlockDraftPaths(paths)
        anyDrafts := AnyTextBlockDraftPaths(paths)
        if ctrl
            preferred := DROPEFFECT_COPY
        else if allDrafts
            preferred := DROPEFFECT_MOVE
        else if anyDrafts || shift
            return DROPEFFECT_NONE
        else
            preferred := DROPEFFECT_COPY
        if allowedEffects & preferred
            return preferred
        return DROPEFFECT_NONE
    }
    if ctrl
        preferred := DROPEFFECT_COPY
    else if shift
        preferred := DROPEFFECT_MOVE
    else
        preferred := sourceKind = "Source"
            || (target.Type = "TextSource" && sourceKind = "Pinned"
                && AllTextBlockDraftPaths(paths))
            ? DROPEFFECT_MOVE : DROPEFFECT_COPY

    if allowedEffects & preferred
        return preferred
    ; Falling back from a move request to copy is safe. Falling back from a
    ; copy request to move is not: it would remove source data unexpectedly.
    if preferred = DROPEFFECT_MOVE
        && (allowedEffects & DROPEFFECT_COPY)
        return DROPEFFECT_COPY
    return DROPEFFECT_NONE
}

TextPinnedDropRestrictionReason(target, keyState, sourceKind, paths) {
    if !IsObject(target) || target.Type != "TextSource"
        || sourceKind != "Pinned" || (keyState & 0x0008)
        return ""
    allDrafts := AllTextBlockDraftPaths(paths)
    anyDrafts := AnyTextBlockDraftPaths(paths)
    if anyDrafts && !allDrafts
        return "所选内容同时包含独立文本块和文件链接；请分开移动，或按 Ctrl 统一复制。"
    if !allDrafts && (keyState & 0x0004)
        return "固定项链接不能移动原文件；松开 Shift 或按 Ctrl 可复制。"
    return ""
}

ShouldContinuePinnedReorder(target) {
    ; GroupId=0 表示工具栏上的“＋ 固定项”投放按钮；它接收加入固定项，
    ; 但不是已有固定项的排序区域。
    return IsObject(target)
        && HasProp(target, "Type")
        && (target.Type = "Pinned" || target.Type = "TextPinned")
        && HasProp(target, "Available") && target.Available
        && HasProp(target, "GroupId") && target.GroupId != 0
}

ResolveDropTarget(screenX, screenY) {
    global Panel, FileView, RecentView, PinnedDropButton
    global FolderDropAddSourceButton, FolderDropPinnedButton
    global ActiveDropSession, ActiveWorkspaceName, FolderSettings
    global SettingsController
    global ItemOpenContexts, GroupDropTargets
    if !IsObject(Panel)
        return InvalidDropTarget("PopDrop 面板不可用。")

    if IsObject(FolderDropAddSourceButton)
        && ScreenPointInWindow(
            FolderDropAddSourceButton.Hwnd, screenX, screenY) {
        payloadKind := IsObject(ActiveDropSession)
            ? ActiveDropSession.PayloadKind : "Unknown"
        paths := IsObject(ActiveDropSession)
            ? ActiveDropSession.Paths : []
        return ResolveAddSourceDropTarget(payloadKind,
            ActiveWorkspaceName, paths, FolderSettings,
            IsObject(SettingsController))
    }

    if IsObject(FolderDropPinnedButton)
        && ScreenPointInWindow(
            FolderDropPinnedButton.Hwnd, screenX, screenY)
        return ResolveDropTargetDescriptor({
            Type: IsTextWorkspace() ? "TextPinned" : "Pinned",
            SourceId: "", Name: "固定项",
            Path: "", GroupId: 0
        })

    if IsObject(PinnedDropButton)
        && ScreenPointInWindow(PinnedDropButton.Hwnd, screenX, screenY)
        return ResolveDropTargetDescriptor({
            Type: IsTextWorkspace() ? "TextPinned" : "Pinned",
            SourceId: "", Name: "固定项",
            Path: "", GroupId: 0
        })

    if IsObject(RecentView)
        && ScreenPointInWindow(RecentView.Hwnd, screenX, screenY)
        return InvalidDropTarget("最近文件区域不能接收投放。")

    if IsObject(FileView)
        && ScreenPointInWindow(FileView.Hwnd, screenX, screenY) {
        point := ScreenToClientPoint(FileView.Hwnd, screenX, screenY)
        row := HitTestListRow(FileView.Hwnd, point.X, point.Y)
        if row && ItemOpenContexts.Has(row) {
            context := ItemOpenContexts[row]
            if HasProp(context, "GroupId")
                && GroupDropTargets.Has(context.GroupId)
                return ResolveDropTargetDescriptor(
                    GroupDropTargets[context.GroupId])
        }
        for groupId, descriptor in GroupDropTargets {
            rect := GetListGroupRect(FileView.Hwnd, groupId)
            if IsObject(rect)
                && point.X >= rect.Left && point.X < rect.Right
                && point.Y >= rect.Top && point.Y < rect.Bottom
                return ResolveDropTargetDescriptor(descriptor)
        }
        return InvalidDropTarget("主列表空白区域不能接收投放。")
    }

    if ScreenPointInWindow(Panel.Hwnd, screenX, screenY)
        return InvalidDropTarget("此控件或区域不能接收投放。")
    return InvalidDropTarget("不在 PopDrop 的可投放区域内。")
}

ResolveAddSourceDropTarget(payloadKind, workspaceName, paths,
    currentSources, settingsOpen := false) {
    target := {
        Type: "AddSource",
        SourceId: "",
        Name: workspaceName,
        Path: "",
        Available: false,
        Reason: "",
        GroupId: 0
    }
    if payloadKind != "FoldersOnly" {
        target.Reason := "只有全部为真实文件夹的选择才能添加为来源。"
        return target
    }
    if settingsOpen {
        target.Reason := "请先保存或关闭设置窗口，再添加来源。"
        return target
    }
    existingCount := CountExistingSourcePaths(paths, currentSources)
    if paths.Length && existingCount = paths.Length {
        target.Reason := paths.Length = 1
            ? "该文件夹已经是当前工作区的来源"
            : "这些文件夹已经是当前工作区的来源"
        return target
    }
    target.Available := true
    return target
}

CountExistingSourcePaths(paths, sources) {
    count := 0
    for path in paths {
        for source in sources {
            if HasProp(source, "Path") && PathsEqual(path, source.Path) {
                count += 1
                break
            }
        }
    }
    return count
}

ResolveDropTargetDescriptor(descriptor, folderAvailable := unset,
    folderWritable := unset) {
    type := HasProp(descriptor, "Type") ? descriptor.Type : "Invalid"
    name := HasProp(descriptor, "Name") ? descriptor.Name : ""
    sourceId := HasProp(descriptor, "SourceId") ? descriptor.SourceId : ""
    groupId := HasProp(descriptor, "GroupId") ? descriptor.GroupId : 0
    if type = "Pinned" || type = "TextPinned" {
        return {
            Type: type, SourceId: "", Name: name != "" ? name : "固定项",
            Path: "", Available: true, Reason: "", GroupId: groupId
        }
    }
    if type != "Files" && type != "Launcher" && type != "TextSource"
        return InvalidDropTarget("此区域没有对应的来源文件夹。", groupId)
    path := NormalizePath(HasProp(descriptor, "Path") ? descriptor.Path : "")
    if path = ""
        return InvalidDropTarget("来源路径无法解析。", groupId, type,
            sourceId, name, path)

    if !IsSet(folderAvailable) || !IsSet(folderWritable) {
        availability := ValidateDropFolder(path)
        folderAvailable := availability.Available
        folderWritable := availability.Writable
        reason := availability.Reason
    } else {
        reason := !folderAvailable
            ? "来源不存在、离线或当前无法访问。"
            : (!folderWritable ? "来源当前没有写入权限。" : "")
    }
    return {
        Type: type,
        SourceId: sourceId,
        Name: name != "" ? name : GetFileName(path),
        Path: path,
        Available: !!folderAvailable && !!folderWritable,
        Reason: reason,
        GroupId: groupId
    }
}

InvalidDropTarget(reason, groupId := 0, type := "Invalid",
    sourceId := "", name := "", path := "") {
    return {
        Type: type, SourceId: sourceId, Name: name, Path: path,
        Available: false, Reason: reason, GroupId: groupId
    }
}

ValidateDropFolder(path, force := false) {
    global DropFolderValidationCache
    key := PathKey(path)
    if !force && DropFolderValidationCache.Has(key)
        return DropFolderValidationCache[key]
    if !DirExist(path) {
        result := {Available: false, Writable: false,
            Reason: "来源不存在、离线或当前无法访问。"}
        DropFolderValidationCache[key] := result
        return result
    }
    ; FILE_ADD_FILE on a directory is a non-mutating ACL/share check. Shell
    ; operations revalidate immediately before execution.
    handle := DllCall("kernel32\CreateFileW", "wstr", path,
        "uint", 0x0002, "uint", 0x7, "ptr", 0, "uint", 3,
        "uint", 0x02000000, "ptr", 0, "ptr")
    invalidHandle := -1
    if handle = invalidHandle {
        result := {Available: true, Writable: false,
            Reason: "来源当前没有写入权限，或网络位置拒绝写入。"}
    } else {
        DllCall("kernel32\CloseHandle", "ptr", handle)
        result := {Available: true, Writable: true, Reason: ""}
    }
    DropFolderValidationCache[key] := result
    return result
}

ScreenPointInWindow(hwnd, screenX, screenY) {
    if !hwnd || !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int")
        return false
    rect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
        return false
    return screenX >= NumGet(rect, 0, "int")
        && screenY >= NumGet(rect, 4, "int")
        && screenX < NumGet(rect, 8, "int")
        && screenY < NumGet(rect, 12, "int")
}

ScreenToClientPoint(hwnd, screenX, screenY) {
    point := Buffer(8, 0)
    NumPut("int", screenX, point, 0)
    NumPut("int", screenY, point, 4)
    DllCall("user32\ScreenToClient", "ptr", hwnd, "ptr", point.Ptr)
    return {X: NumGet(point, 0, "int"), Y: NumGet(point, 4, "int")}
}

ClientToScreenPoint(hwnd, clientX, clientY) {
    point := Buffer(8, 0)
    NumPut("int", clientX, point, 0)
    NumPut("int", clientY, point, 4)
    DllCall("user32\ClientToScreen", "ptr", hwnd, "ptr", point.Ptr)
    return {X: NumGet(point, 0, "int"), Y: NumGet(point, 4, "int")}
}

GetListGroupRect(hwnd, groupId, part := 0) {
    rect := Buffer(16, 0)
    NumPut("int", part, rect, 4) ; RECT.top = LVGGR_GROUP / LVGGR_HEADER
    if !DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x1062,
        "ptr", groupId, "ptr", rect.Ptr, "ptr")
        return 0
    return {
        Left: NumGet(rect, 0, "int"),
        Top: NumGet(rect, 4, "int"),
        Right: NumGet(rect, 8, "int"),
        Bottom: NumGet(rect, 12, "int")
    }
}

CaptureDropStatus() {
    global StatusText, StatusKind, CurrentStatusAction
    return {
        Text: IsObject(StatusText) ? StatusText.Text : "",
        Kind: StatusKind,
        Action: CurrentStatusAction
    }
}

RestoreDropStatus(snapshot) {
    global StatusText, StatusKind, CurrentStatusAction
    if !IsObject(snapshot)
        return
    StatusKind := snapshot.Kind
    CurrentStatusAction := snapshot.Action
    if IsObject(StatusText)
        StatusText.Text := snapshot.Text
}

ShowDropFeedback(target, effect, itemCount, skipCount := 0) {
    global StatusText, StatusKind, CurrentStatusAction, ActiveDropSession
    SetDropGroupHighlight(HasProp(target, "GroupId")
        ? target.GroupId : 0)
    SetAddSourceDropHover(target.Type = "AddSource" && target.Available)
    SetPinnedDropHover((target.Type = "Pinned"
        || target.Type = "TextPinned") && target.Available)
    CurrentStatusAction := 0
    StatusKind := "user"
    if !IsObject(StatusText)
        return
    payloadKind := IsObject(ActiveDropSession)
        ? ActiveDropSession.PayloadKind : "Unknown"
    if !target.Available {
        if target.Type = "AddSource" && target.Reason != ""
            StatusText.Text := target.Reason
        else if payloadKind = "FoldersOnly"
            StatusText.Text := "此处不能接收文件夹；拖到上方添加为来源，"
                . "或拖到下方来源分组移动或复制文件夹"
        else if payloadKind = "Mixed"
            StatusText.Text := "混合选择不能添加为来源；"
                . "可拖到分栏进行移动或复制。"
        else if target.Reason != ""
            StatusText.Text := "不能投放：" target.Reason
        else
            StatusText.Text := "此处不能投放。"
        return
    }
    if !effect {
        StatusText.Text := "源程序没有提供可安全执行的复制或移动效果。"
        return
    }
    countText := itemCount " 个"
        . (payloadKind = "FoldersOnly" ? "文件夹" : "项目")
    hasFilePaths := IsObject(ActiveDropSession)
        && ActiveDropSession.Paths.Length > 0
    if target.Type = "AddSource"
        StatusText.Text := "添加 " countText " 为「" target.Name
            . "」的来源；不会移动文件夹"
    else if target.Type = "Pinned" || target.Type = "TextPinned"
        StatusText.Text := payloadKind = "FoldersOnly"
            ? "添加 " countText " 到固定项；不会移动文件夹"
            : (target.Type = "TextPinned"
                ? (hasFilePaths
                    ? "在固定项中创建 " itemCount " 个文件链接；不会移动原文件"
                    : "保存为独立文本块并加入固定项")
                : "添加 " countText " 到固定项")
    else if target.Type = "Launcher"
        StatusText.Text := "在「" target.Name "」中为 "
            . countText " 创建快捷方式"
    else if effect = 2
        StatusText.Text := "移动 " countText " 到「" target.Name "」"
    else
        StatusText.Text := "复制 " countText " 到「" target.Name "」"
    if skipCount
        StatusText.Text .= "；其中 " skipCount " 个项目将跳过"
    DllCall("user32\UpdateWindow", "ptr", StatusText.Hwnd)
}

SetAddSourceDropHover(active) {
    global FolderDropAddSourceButton
    if IsObject(FolderDropAddSourceButton)
        DllCall("user32\SendMessageW",
            "ptr", FolderDropAddSourceButton.Hwnd,
            "uint", 0x00F3, "ptr", active ? 1 : 0, "ptr", 0, "ptr")
}

SetPinnedDropDiscovery(active) {
    global PinnedDropButton, PinnedDropDiscoveryActive
    if !IsObject(PinnedDropButton)
        return
    active := !!active
    if active = PinnedDropDiscoveryActive
        return
    PinnedDropDiscoveryActive := active
    SetPanelIconButtonSelected(PinnedDropButton, active)
}

SetPinnedDropHover(active) {
    global PinnedDropButton, FolderDropPinnedButton
    if IsObject(PinnedDropButton)
        SetPanelIconButtonHovered(PinnedDropButton, active)
    if IsObject(FolderDropPinnedButton)
        DllCall("user32\SendMessageW", "ptr", FolderDropPinnedButton.Hwnd,
            "uint", 0x00F3, "ptr", active ? 1 : 0, "ptr", 0, "ptr")
}

SetDropGroupHighlight(groupId) {
    global ActiveDropHighlightedGroup, FileView
    if groupId = ActiveDropHighlightedGroup
        return
    if IsObject(FileView) && ActiveDropHighlightedGroup
        SetListGroupSelected(FileView.Hwnd,
            ActiveDropHighlightedGroup, false)
    ActiveDropHighlightedGroup := groupId
    if IsObject(FileView) && groupId
        SetListGroupSelected(FileView.Hwnd, groupId, true)
}

SetListGroupSelected(hwnd, groupId, selected) {
    groupSize := A_PtrSize = 8 ? 152 : 96
    group := Buffer(groupSize, 0)
    stateMaskOffset := A_PtrSize = 8 ? 40 : 28
    stateOffset := A_PtrSize = 8 ? 44 : 32
    NumPut("uint", groupSize, group, 0)
    NumPut("uint", 0x4, group, 4) ; LVGF_STATE
    NumPut("uint", 0x20, group, stateMaskOffset) ; LVGS_SELECTED
    NumPut("uint", selected ? 0x20 : 0, group, stateOffset)
    DllCall("user32\SendMessageW", "ptr", hwnd, "uint", 0x1093,
        "ptr", groupId, "ptr", group.Ptr, "ptr")
    rect := GetListGroupRect(hwnd, groupId)
    if IsObject(rect) {
        nativeRect := Buffer(16, 0)
        NumPut("int", rect.Left, nativeRect, 0)
        NumPut("int", rect.Top, nativeRect, 4)
        NumPut("int", rect.Right, nativeRect, 8)
        NumPut("int", rect.Bottom, nativeRect, 12)
        DllCall("user32\InvalidateRect", "ptr", hwnd,
            "ptr", nativeRect.Ptr, "int", 1)
    }
}

ClearDropVisuals() {
    SetDropGroupHighlight(0)
    SetAddSourceDropHover(false)
    SetPinnedDropHover(false)
    SetPinnedDropDiscovery(false)
    HideFolderDropMode()
}

ExecuteLocalDrop(paths, target, effect, internalItems, sourceKind) {
    global ActiveWorkspaceId
    if target.Type = "AddSource"
        return AddFolderSourcesToCurrentWorkspace(paths)
    validation := target.Type = "Pinned" || target.Type = "TextPinned"
        ? {Available: true, Writable: true, Reason: ""}
        : ValidateDropFolder(target.Path, true)
    if !validation.Available || !validation.Writable {
        SetUserStatus("投放失败：「" target.Name "」"
            . (validation.Reason != "" ? validation.Reason : "当前不可用。"))
        return {Success: 0, Failed: paths.Length, Changed: false}
    }
    if target.Type = "Pinned"
        return PinDroppedItems(paths)
    if target.Type = "TextPinned" {
        textPaths := FilterTextBlockPaths(paths)
        if !textPaths.Length
            throw Error("固定项只接收 .md 或 .txt 文本块文件。")
        return PinDroppedItems(textPaths)
    }
    if target.Type = "Launcher"
        return PerformLauncherDrop(paths, target)
    if target.Type != "Files" && target.Type != "TextSource" {
        SetUserStatus("此区域不能接收投放。")
        return {Success: 0, Failed: paths.Length, Changed: false}
    }
    operation := effect = 2 ? "move" : "copy"
    if target.Type = "TextSource" {
        paths := FilterTextBlockPaths(paths)
        if !paths.Length
            throw Error("文本来源只接收 .md 或 .txt 文件。")
    }
    operationContext := {
        TargetName: target.Name,
        TargetSourceId: target.SourceId,
        InternalItems: internalItems,
        SourceKind: sourceKind,
        FromDrop: true
    }
    if operation = "move" && target.Type = "TextSource"
        && sourceKind = "Pinned" && AllTextBlockDraftPaths(paths) {
        operationContext.RemoveMovedPinsWorkspaceId := ActiveWorkspaceId
        operationContext.RemoveMovedPinnedPaths := paths.Clone()
    }
    return PerformShellFileOperation(operation, paths, target.Path,
        operationContext)
}

FilterTextBlockPaths(paths) {
    result := []
    for path in paths {
        if IsTextBlockPath(path) && !ArrayContainsPath(result, path)
            result.Push(path)
    }
    return result
}

GetCurrentSourceDefaults() {
    global MaxFilesPerFolder, ActiveWorkspaceType
    return {
        DefaultDisplayScope: ReadGlobalDisplayScopeForDraft(),
        DefaultFolderTimeMode: ReadGlobalFolderTimeForDraft(),
        MaxFilesPerFolder: MaxFilesPerFolder,
        DefaultFilter: ReadGlobalFilterForDraft(),
        WorkspaceType: ActiveWorkspaceType
    }
}

ReadWorkspaceSourcesFromDocument(doc, workspaceId) {
    result := []
    for sourceId in ParseStableIdOrder(doc.GetValue(
        "Workspace:" workspaceId, "SourceOrder", "")) {
        section := "Source:" sourceId
        name := Trim(doc.GetValue(section, "Name", ""))
        path := NormalizePath(doc.GetValue(section, "Path", ""))
        if name != "" && path != ""
            result.Push({SourceId: sourceId, Name: name, Path: path})
    }
    return result
}

CollectConfiguredSourceIds(doc) {
    result := Map()
    for section in doc.GetSectionNames() {
        if SubStr(StrLower(section), 1, 7) != "source:"
            continue
        id := SubStr(section, 8)
        if IsSafeSourceId(id)
            result[StrLower(id)] := true
    }
    return result
}

NextUniqueDroppedSourceId(usedIds, idFactory := unset) {
    Loop 100 {
        id := IsSet(idFactory)
            ? idFactory.Call() : NewStableId("source")
        if IsSafeSourceId(id) && !usedIds.Has(StrLower(id)) {
            usedIds[StrLower(id)] := true
            return id
        }
    }
    throw Error("无法生成唯一的来源 ID。")
}

PlanFolderSourceAdditions(paths, currentSources, usedSourceIds,
    workspaceId, defaults, pathInfo := unset, idFactory := unset) {
    global WORKSPACE_TYPE_TEXT
    info := IsSet(pathInfo) ? pathInfo : BuildDropPathInfo(paths)
    result := {
        Sources: [],
        Existing: 0,
        Failed: 0,
        FailedDetails: []
    }
    namesAndPaths := []
    for source in currentSources
        namesAndPaths.Push(source)
    pendingPaths := []
    for rawPath in paths {
        path := NormalizePath(rawPath)
        if !IsPersistableFileSystemFolder(path, info) {
            result.Failed += 1
            result.FailedDetails.Push(
                (path != "" ? path : rawPath) . "：不是可访问的真实文件夹")
            continue
        }
        duplicate := ArrayContainsPath(pendingPaths, path)
        if !duplicate {
            for source in currentSources {
                if PathsEqual(source.Path, path) {
                    duplicate := true
                    break
                }
            }
        }
        if duplicate {
            result.Existing += 1
            continue
        }
        id := IsSet(idFactory)
            ? NextUniqueDroppedSourceId(usedSourceIds, idFactory)
            : NextUniqueDroppedSourceId(usedSourceIds)
        name := MakeUniqueSourceName(
            DefaultSourceNameForPath(path), namesAndPaths)
        source := CreateDefaultSourceDraft(
            name, path, id, defaults)
        if HasProp(defaults, "WorkspaceType")
            && ParseWorkspaceType(defaults.WorkspaceType) = WORKSPACE_TYPE_TEXT
            ApplyTextBlockSourceDefaults(source)
        source.WorkspaceId := workspaceId
        result.Sources.Push(source)
        namesAndPaths.Push(source)
        pendingPaths.Push(path)
    }
    return result
}

WriteDroppedFolderSources(workspaceId, paths, defaults, result, tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    workspaceSection := "Workspace:" workspaceId
    workspaceName := Trim(doc.GetValue(workspaceSection, "Name", ""))
    if workspaceName = ""
        throw Error("当前工作区已不存在，无法添加来源。")
    sourceOrder := ParseStableIdOrder(
        doc.GetValue(workspaceSection, "SourceOrder", ""))
    currentSources := ReadWorkspaceSourcesFromDocument(doc, workspaceId)
    pathInfo := BuildDropPathInfo(paths)
    plan := PlanFolderSourceAdditions(paths, currentSources,
        CollectConfiguredSourceIds(doc), workspaceId, defaults, pathInfo)
    for source in plan.Sources {
        doc.ReplaceKnownKeys("Source:" source.SourceId,
            SourceConfigEntries(source, workspaceId),
            SourceConfigKnownKeys(), 3)
        sourceOrder.Push(source.SourceId)
    }
    doc.ReplaceKnownKeys(workspaceSection, [
        {Key: "Name", Value: workspaceName},
        {Key: "Type", Value: doc.GetValue(workspaceSection, "Type", "Files")},
        {Key: "Hotkey", Value: doc.GetValue(workspaceSection, "Hotkey", "")},
        {Key: "SourceOrder", Value: JoinArray(sourceOrder, ",")}
    ], ["Name", "Type", "Hotkey", "SourceOrder"], 3)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
    result.WorkspaceName := workspaceName
    result.Added := plan.Sources.Length
    result.Existing := plan.Existing
    result.Failed := plan.Failed
    result.FailedDetails := plan.FailedDetails
    result.Sources := plan.Sources
}

FormatAddSourceResult(result) {
    if result.Added {
        message := "已添加 " result.Added " 个来源"
        if result.WorkspaceName != ""
            message .= "到「" result.WorkspaceName "」"
    } else
        message := "没有新增来源"
    if result.Existing
        message .= "，" result.Existing " 个已存在"
    if result.Failed
        message .= "，" result.Failed " 个失败"
    return message
}

AddFolderSourcesToCurrentWorkspace(paths) {
    global ActiveWorkspaceId, ActiveWorkspaceName, SettingsController
    if IsObject(SettingsController)
        throw Error("请先保存或关闭设置窗口，再添加来源。")
    workspaceId := ActiveWorkspaceId
    result := {
        WorkspaceName: ActiveWorkspaceName,
        Added: 0, Existing: 0, Failed: 0,
        FailedDetails: [], Sources: []
    }
    defaults := GetCurrentSourceDefaults()
    CreateConfigBackup()
    AtomicConfigEdit(WriteDroppedFolderSources.Bind(
        workspaceId, paths.Clone(), defaults, result))

    if result.Added {
        LoadSettings()
        PopulatePanel()
        PopulateRecentSidebar()
        ; Directory enumeration remains in the existing scan worker.
        StartBackgroundScan()
    }
    message := FormatAddSourceResult(result)
    SetBackgroundStatus(message, 6000)
    if result.Failed {
        details := message
            . "`n`n以下候选未添加："
        for item in result.FailedDetails
            details .= "`n• " item
        ShowPanelMsgBox(details, "添加来源结果", "Icon!")
    }
    return {
        Success: result.Added,
        Failed: result.Failed,
        Skipped: result.Existing,
        Changed: result.Added > 0,
        Details: result.FailedDetails
    }
}

DropItemMatchesTargetSource(item, targetPath, targetSourceId := "") {
    if !IsObject(item) || !HasProp(item, "Area")
        || item.Area != "Source"
        return false
    if HasProp(item, "SourcePath")
        && PathsEqual(item.SourcePath, targetPath)
        return true
    return targetSourceId != "" && HasProp(item, "SourceId")
        && StrLower(item.SourceId) = StrLower(targetSourceId)
}

FindDropItemForPath(items, path) {
    if !IsObject(items)
        return 0
    for item in items {
        if HasProp(item, "Path") && PathsEqual(item.Path, path)
            return item
    }
    return 0
}

PerformLauncherDrop(paths, target) {
    linkSources := []
    copySources := []
    invalid := 0
    for path in paths {
        attributes := FileExist(path)
        if !attributes {
            invalid += 1
            continue
        }
        SplitPath(path, , , &extension)
        extension := StrLower(extension)
        if !InStr(attributes, "D")
            && (extension = "lnk" || extension = "url")
            copySources.Push(path)
        else
            linkSources.Push(path)
    }

    linkResult := CreateLauncherShortcuts(linkSources, target.Path)
    copyResult := {
        Success: 0, Failed: 0, Skipped: 0,
        Aborted: false, Changed: false, RefreshQueued: false
    }
    if copySources.Length
        copyResult := PerformShellFileOperation("copy", copySources,
            target.Path, {
                TargetName: target.Name,
                FromDrop: true,
                SuppressFinalStatus: true
            })
    changed := linkResult.Success > 0 || copyResult.Changed
    if linkResult.Success > 0 && !copyResult.RefreshQueued
        StartBackgroundScan()

    success := linkResult.Success + copyResult.Success
    failed := invalid + linkResult.Failed + copyResult.Failed
        + copyResult.Skipped
    cancelled := copyResult.Aborted ? 1 : 0
    message := "已在「" target.Name "」中创建或复制 "
        . success " 个快捷方式"
    if failed || cancelled
        message .= "；" failed " 个失败或跳过"
            . (cancelled ? "，操作已取消" : "")
    resultPaths := linkResult.ResultPaths.Clone()
    if HasProp(copyResult, "ResultPaths") {
        for path in copyResult.ResultPaths
            resultPaths.Push(path)
    }
    if changed && DropTargetMayHideResults(
        {TargetSourceId: target.SourceId}, target.Path, resultPaths)
        message .= "；文件已保存到目标文件夹；"
            . "部分项目因当前显示或筛选规则未显示。"
    message .= "    打开目标文件夹"
    SetActionStatus(message, OpenFolderInFileManager.Bind(target.Path))
    return {
        Success: success, Failed: failed, Skipped: copyResult.Skipped,
        Aborted: copyResult.Aborted, Changed: changed,
        RefreshQueued: copyResult.RefreshQueued || linkResult.Success > 0
    }
}

CreateLauncherShortcuts(paths, targetPath) {
    success := 0
    failed := 0
    details := []
    resultPaths := []
    try shell := ComObject("WScript.Shell")
    catch as err
        return {Success: 0, Failed: paths.Length,
            Details: ["无法创建 Windows Shell 快捷方式对象：" err.Message],
            ResultPaths: []}
    for index, sourcePath in paths {
        finalPath := ""
        tempPath := targetPath "\.~PopDrop-"
            . DllCall("kernel32\GetCurrentProcessId", "uint")
            . "-" A_TickCount "-" index ".lnk"
        try {
            baseName := LauncherShortcutBaseName(sourcePath)
            tempSuffix := 2
            while FileExist(tempPath) {
                tempPath := targetPath "\.~PopDrop-"
                    . DllCall("kernel32\GetCurrentProcessId", "uint")
                    . "-" A_TickCount "-" index "-" tempSuffix++ ".lnk"
            }
            shortcut := shell.CreateShortcut(tempPath)
            shortcut.TargetPath := sourcePath
            if DirExist(sourcePath)
                shortcut.WorkingDirectory := sourcePath
            else
                shortcut.WorkingDirectory := GetParentPath(sourcePath)
            shortcut.Description := "由 PopDrop 创建"
            shortcut.Save()
            if !FileExist(tempPath)
                throw Error("Windows Shell 未生成快捷方式文件。")
            verified := shell.CreateShortcut(tempPath)
            if !PathsEqual(verified.TargetPath, sourcePath)
                throw Error("快捷方式目标校验失败。")
            Loop 20 {
                finalPath := UniqueLauncherShortcutPath(targetPath, baseName)
                if DllCall("kernel32\MoveFileExW", "wstr", tempPath,
                    "wstr", finalPath, "uint", 0, "int")
                    break
                finalPath := ""
            }
            if finalPath = ""
                throw Error("无法以唯一名称保存快捷方式。")
            success += 1
            resultPaths.Push(finalPath)
        } catch as err {
            failed += 1
            details.Push(sourcePath "：" err.Message)
        } finally {
            if FileExist(tempPath)
                try FileDelete(tempPath)
        }
    }
    return {Success: success, Failed: failed,
        Details: details, ResultPaths: resultPaths}
}

LauncherShortcutBaseName(sourcePath) {
    name := GetFileName(sourcePath)
    if !DirExist(sourcePath) {
        SplitPath(name, &nameWithoutExtension)
        if nameWithoutExtension != ""
            name := nameWithoutExtension
    }
    return SanitizeShortcutBaseName(name)
}

SanitizeShortcutBaseName(name) {
    name := RegExReplace(name, "[<>:`"/\\|?*\x00-\x1F]", "_")
    name := RTrim(Trim(name), ". ")
    if name = ""
        name := "快捷方式"
    if RegExMatch(name, "i)^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)")
        name .= "_"
    return RTrim(SubStr(name, 1, 120), ". ")
}

UniqueLauncherShortcutPath(targetPath, baseName) {
    baseName := SanitizeShortcutBaseName(baseName)
    candidate := targetPath "\" baseName ".lnk"
    suffix := 2
    while FileExist(candidate)
        candidate := targetPath "\" baseName " (" suffix++ ").lnk"
    return candidate
}

MakeUniqueShortcutFileName(baseName, existingNames) {
    baseName := SanitizeShortcutBaseName(baseName)
    candidate := baseName ".lnk"
    suffix := 2
    while existingNames.Has(StrLower(candidate))
        candidate := baseName " (" suffix++ ").lnk"
    return candidate
}
