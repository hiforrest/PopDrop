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
        ; Smart overlays are display-only siblings. Registering them as OLE
        ; targets makes showing one under a stationary drag replace the native
        ; target HWND, producing a DragLeave/DragEnter visibility loop.
        if !IsSmartDropOverlayWindow(child)
            RegisterDropTargetWindow(child, targetPtr)
        RegisterDropTargetChildren(child, targetPtr)
        child := DllCall("user32\GetWindow", "ptr", child,
            "uint", GW_HWNDNEXT, "ptr")
    }
}

IsSmartDropOverlayWindow(hwnd) {
    global FolderDropAddSourceButton, FolderDropPinnedZone
    return (IsObject(FolderDropAddSourceButton)
            && hwnd = FolderDropAddSourceButton.Hwnd)
        || (IsObject(FolderDropPinnedZone)
            && hwnd = FolderDropPinnedZone.Hwnd)
}

SmartDropOverlayHitTest(wParam, lParam, msg, hwnd) {
    ; HTTRANSPARENT keeps OLE routing on the already registered native control
    ; below the overlay. ResolveDropTarget still uses the overlay rectangles,
    ; so the visible 70/30 zones retain their distinct drop semantics without
    ; becoming a new drag window mid-session.
    if IsSmartDropOverlayWindow(hwnd)
        return -1 ; HTTRANSPARENT
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
    global ActiveWorkspaceId, ActiveWorkspaceName, ActiveWorkspaceType
    global FolderSettings
    global DROP_ADAPTER_HDROP, DROP_ADAPTER_UNSUPPORTED
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
        session.LockedWorkspaceId := ActiveWorkspaceId
        session.LockedWorkspaceName := ActiveWorkspaceName
        session.LockedWorkspaceType := ActiveWorkspaceType
        session.LockedSources := FolderSettings.Clone()
        session.LockedSourceDefaults := GetCurrentSourceDefaults()
        BeginAutoHidePause()
        ActiveDropSession := session
        session.Decision := ClassifyDataObject(dataObject)
        session.AsyncInfo := DataObjectAsyncMode(dataObject)
        ; QueryGetData for PopDrop's private format is only a capability hint.
        ; Treat a drag as genuinely internal only while PopDrop itself owns the
        ; live outbound DoDragDrop context. This prevents Explorer Shell data
        ; objects from being falsely classified as PopDrop-internal drags.
        session.IsInternal := IsObject(ActiveInternalDragContext)
            && DataObjectSupportsFormat(dataObject,
                GetPopDropInternalDragFormat(), 1, -1)
        session.SourceKind := session.IsInternal
            ? ClassifyDropSource(ActiveInternalDragContext.Items, true)
            : "External"
        ; Internal drags already own a trusted path array. External HDROP is
        ; pre-read only for the narrow stable-local case approved by
        ; CanPreloadHDropForFolderFeedback(). Explorer Shell selections can
        ; be safely recognized by CFSTR_SHELLIDLIST even when they advertise
        ; async capability or auxiliary formats. Unknown async, URL, virtual
        ; and image objects remain zero-extraction until Drop.
        if session.IsInternal && IsObject(ActiveInternalDragContext) {
            CacheDropSessionPaths(
                session, ActiveInternalDragContext.Paths, false)
        } else {
            if CanPreloadHDropForFolderFeedback(
                session.Decision, session.AsyncInfo, session.SourceKind) {
                ; Keep the established CF_HDROP path first. Ordinary Explorer
                ; file drags already work correctly through this route.
                try PreloadDropSessionHDropPaths(session, dataObject)
            }
            if !session.PathsCached
                && CanReadShellIdListForFolderFeedback(
                    session.Decision, session.SourceKind) {
                ; Explorer can make the Shell selection available before a
                ; hover-time CF_HDROP read yields paths for a folder. Read the
                ; Shell ID list once and resolve only real file-system paths.
                try {
                    shellPaths := ReadShellIdListPaths(dataObject)
                    if shellPaths.Length {
                        ; Successfully resolved PIDLs are authoritative local
                        ; filesystem paths, regardless of the initial adapter.
                        session.Decision.Adapter := DROP_ADAPTER_HDROP
                        session.Decision.Reason := ""
                        session.Decision.HasShellIdList := true
                        CacheDropSessionPaths(session, shellPaths, false)
                    }
                }
            }
        }
        if session.Decision.Adapter = DROP_ADAPTER_UNSUPPORTED {
            session.Unsupported := true
            SetDropEffect(effectPtr, 0)
            ShowDropFeedback(InvalidDropTarget(
                session.Decision.Reason), 0, 0)
            return 0
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
        IsInternal: false,
        LockedWorkspaceId: "",
        LockedWorkspaceName: "",
        LockedWorkspaceType: "Files",
        LockedSources: [],
        LockedSourceDefaults: 0,
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
        LastFeedbackSignature: "",
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
    global WORKSPACE_TYPE_TEXT
    mode := IsObject(session) ? ResolveSmartDropMode(session) : ""
    if mode = "Folders"
        && ParseWorkspaceType(session.LockedWorkspaceType) != WORKSPACE_TYPE_TEXT
        && !HasVisibleHittablePinnedDropTarget(session.LockedWorkspaceId)
        mode := "FoldersSplit"
    if mode != "" {
        ShowFolderDropMode(mode, session.Paths.Length,
            session.LockedWorkspaceName)
        session.FolderDropUiShown := true
    } else {
        HideFolderDropMode()
        if IsObject(session)
            session.FolderDropUiShown := false
    }
}

ResolveSmartDropMode(session, pinnedDropAvailable := unset) {
    global WORKSPACE_TYPE_TEXT
    if !IsObject(session) || !session.PathsCached
        return ""
    if session.PayloadKind = "FoldersOnly"
        return session.IsInternal ? "" : "Folders"
    if session.PayloadKind != "FilesOnly"
        return ""
    if ParseWorkspaceType(session.LockedWorkspaceType) = WORKSPACE_TYPE_TEXT {
        for path in session.Paths {
            if !IsTextBlockPath(path)
                return ""
        }
    }
    if !IsSet(pinnedDropAvailable)
        pinnedDropAvailable := HasVisibleHittablePinnedDropTarget(
            session.LockedWorkspaceId)
    return pinnedDropAvailable ? "" : "Files"
}

HasVisibleHittablePinnedDropTarget(workspaceId) {
    global FileView, GroupDropTargets
    if !IsObject(FileView) || !FileView.Hwnd
        return false
    if !DllCall("user32\IsWindowVisible", "ptr", FileView.Hwnd, "int")
        || !DllCall("user32\IsWindowEnabled", "ptr", FileView.Hwnd, "int")
        return false
    client := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", FileView.Hwnd,
        "ptr", client.Ptr)
        return false
    clientRight := NumGet(client, 8, "int")
    clientBottom := NumGet(client, 12, "int")
    for groupId, descriptor in GroupDropTargets {
        if !HasProp(descriptor, "Type")
            || (descriptor.Type != "Pinned"
                && descriptor.Type != "TextPinned")
            continue
        if HasProp(descriptor, "WorkspaceId")
            && StrLower(descriptor.WorkspaceId) != StrLower(workspaceId)
            continue
        rect := GetListGroupRect(FileView.Hwnd, groupId)
        if IsObject(rect) && rect.Right > 0 && rect.Bottom > 0
            && rect.Left < clientRight && rect.Top < clientBottom
            return true
    }
    return false
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
    if ActiveDropSession.IsInternal
        && IsObject(target)
        && HasProp(target, "WorkspaceId")
        && target.WorkspaceId != ""
        && StrLower(target.WorkspaceId)
            != StrLower(ActiveDropSession.LockedWorkspaceId) {
        target := InvalidDropTarget(
            "当前投放目标属于另一个工作区；已取消本次内部移动。")
    }
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

CanReadShellIdListForFolderFeedback(decision, sourceKind) {
    global DROP_ADAPTER_HDROP, DROP_ADAPTER_VIRTUAL
    global DROP_ADAPTER_UNSUPPORTED
    if sourceKind != "External" || !IsObject(decision)
        return false
    adapter := decision.Adapter
    if adapter != DROP_ADAPTER_HDROP
        && adapter != DROP_ADAPTER_VIRTUAL
        && adapter != DROP_ADAPTER_UNSUPPORTED
        return false
    ; This asks only for CFSTR_SHELLIDLIST, never CF_HDROP. A browser/virtual
    ; source that does not implement the Shell format simply returns failure;
    ; a real Explorer selection can resolve to stable filesystem PIDLs.
    if HasProp(decision, "HasExplicitUrl") && decision.HasExplicitUrl
        return false
    if HasProp(decision, "HasImagePayload") && decision.HasImagePayload
        return false
    return true
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

ReadShellIdListPaths(dataObject) {
    ; CFSTR_SHELLIDLIST is a CIDA structure: an absolute parent PIDL followed
    ; by one relative PIDL per selected item. Explorer commonly exposes this
    ; for ordinary file-system folders even when hover-time CF_HDROP has not
    ; yielded the path list yet.
    paths := []
    if !dataObject
        return paths
    formats := GetDropClipboardFormats()
    if !formats.ShellIdList
        return paths

    formatSize := A_PtrSize = 8 ? 32 : 20
    mediumSize := A_PtrSize = 8 ? 24 : 12
    formatEtc := Buffer(formatSize, 0)
    medium := Buffer(mediumSize, 0)
    FillFormatEtc(formatEtc.Ptr, formats.ShellIdList, 1, -1)
    hr := ComCall(3, dataObject, "ptr", formatEtc.Ptr,
        "ptr", medium.Ptr, "int")
    if !HResultSucceeded(hr)
        return paths

    hGlobal := 0
    locked := 0
    try {
        unionOffset := A_PtrSize = 8 ? 8 : 4
        hGlobal := NumGet(medium, unionOffset, "ptr")
        if !hGlobal
            return paths
        byteCount := DllCall("kernel32\GlobalSize",
            "ptr", hGlobal, "uptr")
        if byteCount < 12
            return paths
        locked := DllCall("kernel32\GlobalLock",
            "ptr", hGlobal, "ptr")
        if !locked
            return paths

        childCount := NumGet(locked, 0, "uint")
        if !childCount || childCount > 4096
            return paths
        headerBytes := 4 + (childCount + 1) * 4
        if headerBytes > byteCount
            return paths

        endPtr := locked + byteCount
        parentOffset := NumGet(locked, 4, "uint")
        if parentOffset >= byteCount
            return paths
        parentPidl := locked + parentOffset
        if !PidlFitsMemoryRange(parentPidl, endPtr)
            return paths

        Loop childCount {
            childOffset := NumGet(
                locked, 4 + A_Index * 4, "uint")
            if childOffset >= byteCount
                continue
            childPidl := locked + childOffset
            if !PidlFitsMemoryRange(childPidl, endPtr)
                continue

            absolutePidl := 0
            try {
                absolutePidl := DllCall("shell32\ILCombine",
                    "ptr", parentPidl, "ptr", childPidl, "ptr")
                if !absolutePidl
                    continue
                path := FileSystemPathFromPidl(absolutePidl)
                if path != "" && !ArrayContainsPath(paths, path)
                    paths.Push(path)
            } finally {
                if absolutePidl
                    DllCall("shell32\ILFree", "ptr", absolutePidl)
            }
        }
    } finally {
        if locked && hGlobal
            DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
        DllCall("ole32\ReleaseStgMedium", "ptr", medium.Ptr)
    }
    return paths
}

PidlFitsMemoryRange(pidl, endPtr) {
    if !pidl || pidl >= endPtr
        return false
    Loop 4096 {
        if pidl + 2 > endPtr
            return false
        itemBytes := NumGet(pidl, 0, "ushort")
        if itemBytes = 0
            return true
        if itemBytes < 2 || pidl + itemBytes > endPtr
            return false
        pidl += itemBytes
    }
    return false
}

FileSystemPathFromPidl(pidl) {
    if !pidl
        return ""
    pathPtr := 0
    try {
        ; SIGDN_FILESYSPATH returns a normal path only for file-system items.
        hr := DllCall("shell32\SHGetNameFromIDList",
            "ptr", pidl, "uint", 0x80058000,
            "ptr*", &pathPtr, "int")
        if HResultSucceeded(hr) && pathPtr
            return NormalizePath(StrGet(pathPtr))
    } catch {
    } finally {
        if pathPtr
            DllCall("ole32\CoTaskMemFree", "ptr", pathPtr)
    }

    legacy := Buffer(32768 * 2, 0)
    try {
        if DllCall("shell32\SHGetPathFromIDListW",
            "ptr", pidl, "ptr", legacy.Ptr, "int")
            return NormalizePath(StrGet(legacy))
    }
    return ""
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
    ; GroupId=0 is the top smart entry, not an existing pinned reorder area.
    return IsObject(target)
        && HasProp(target, "Type")
        && (target.Type = "Pinned" || target.Type = "TextPinned")
        && HasProp(target, "Available") && target.Available
        && HasProp(target, "GroupId") && target.GroupId != 0
}

ResolveDropTarget(screenX, screenY) {
    global Panel, FileView, RecentView
    global FolderDropAddSourceButton, FolderDropPinnedZone, FolderDropUiMode
    global ActiveDropSession, ActiveWorkspaceName, FolderSettings
    global SettingsController
    global WORKSPACE_TYPE_TEXT
    global ItemOpenContexts, GroupDropTargets
    if !IsObject(Panel)
        return InvalidDropTarget("PopDrop 面板不可用。")

    if FolderDropUiMode = "FoldersSplit"
        && IsObject(FolderDropPinnedZone)
        && ScreenPointInWindow(
            FolderDropPinnedZone.Hwnd, screenX, screenY) {
        if !IsObject(ActiveDropSession)
            return InvalidDropTarget("拖拽会话已经结束。")
        return ResolveDropTargetDescriptor({
            Type: "Pinned", SourceId: "", Name: "固定项", Path: "",
            GroupId: 0,
            WorkspaceId: ActiveDropSession.LockedWorkspaceId
        })
    }

    if IsObject(FolderDropAddSourceButton)
        && ScreenPointInWindow(
            FolderDropAddSourceButton.Hwnd, screenX, screenY) {
        if !IsObject(ActiveDropSession)
            return InvalidDropTarget("拖拽会话已经结束。")
        if ResolveSmartDropMode(ActiveDropSession) = "Files"
            return ResolveDropTargetDescriptor({
                Type: ParseWorkspaceType(
                    ActiveDropSession.LockedWorkspaceType) = WORKSPACE_TYPE_TEXT
                    ? "TextPinned" : "Pinned",
                SourceId: "", Name: "固定项", Path: "", GroupId: 0,
                WorkspaceId: ActiveDropSession.LockedWorkspaceId
            })
        return ResolveAddSourceDropTarget(
            ActiveDropSession.PayloadKind,
            ActiveDropSession.LockedWorkspaceName,
            ActiveDropSession.Paths,
            ActiveDropSession.LockedSources,
            IsObject(SettingsController),
            ActiveDropSession.LockedWorkspaceId,
            ActiveDropSession.LockedSourceDefaults)
    }

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
    currentSources, settingsOpen := false, workspaceId := "",
    sourceDefaults := 0) {
    target := {
        Type: "AddSource",
        SourceId: "",
        Name: workspaceName,
        Path: "",
        Available: false,
        Reason: "",
        GroupId: 0,
        WorkspaceId: workspaceId,
        SourceDefaults: sourceDefaults
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
    workspaceId := HasProp(descriptor, "WorkspaceId")
        ? descriptor.WorkspaceId : ""
    if type = "Pinned" || type = "TextPinned" {
        return {
            Type: type, SourceId: "", Name: name != "" ? name : "固定项",
            Path: "", Available: true, Reason: "", GroupId: groupId,
            WorkspaceId: workspaceId
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
        GroupId: groupId,
        WorkspaceId: workspaceId
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
    signature := target.Type "|" target.Available "|" effect "|"
        . itemCount "|" skipCount "|" payloadKind "|"
        . (HasProp(target, "Name") ? target.Name : "") "|"
        . (HasProp(target, "Reason") ? target.Reason : "")
    if IsObject(ActiveDropSession)
        && ActiveDropSession.LastFeedbackSignature = signature
        return
    if IsObject(ActiveDropSession)
        ActiveDropSession.LastFeedbackSignature := signature
    if !target.Available {
        if target.Type = "AddSource" && target.Reason != ""
            StatusText.Text := target.Reason
        else if payloadKind = "FoldersOnly"
            StatusText.Text := "此处不能接收文件夹；拖到上方添加为来源，"
                . "或拖到下方来源分组移动或复制文件夹"
        else if payloadKind = "Mixed"
            StatusText.Text := "文件和文件夹请分别拖入；"
                . "下方已有区域仍按原规则接收。"
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
    ; Let the normal paint cycle coalesce rapid DragOver events. Forcing a
    ; synchronous repaint here makes the footer and native Tab text flicker.
}

SetAddSourceDropHover(active) {
    global FolderDropAddSourceButton
    if IsObject(FolderDropAddSourceButton)
        DllCall("user32\SendMessageW",
            "ptr", FolderDropAddSourceButton.Hwnd,
            "uint", 0x00F3, "ptr", active ? 1 : 0, "ptr", 0, "ptr")
}

SetPinnedDropHover(active) {
    global FolderDropAddSourceButton, FolderDropPinnedZone, FolderDropUiMode
    control := FolderDropUiMode = "FoldersSplit"
        ? FolderDropPinnedZone : FolderDropAddSourceButton
    if (FolderDropUiMode = "Files" || FolderDropUiMode = "FoldersSplit")
        && IsObject(control)
        DllCall("user32\SendMessageW", "ptr",
            control.Hwnd,
            "uint", 0x00F3, "ptr", active ? 1 : 0, "ptr", 0, "ptr")
}

CaptureDropGroupUserSelection() {
    global FileView, ItemPaths
    paths := []
    focusPath := ""
    if !IsObject(FileView)
        return {Paths: paths, FocusPath: focusPath}
    for row in GetSelectedFileRows() {
        if ItemPaths.Has(row)
            paths.Push(ItemPaths[row])
    }
    focusRow := FileView.GetNext(0, "F")
    if focusRow && ItemPaths.Has(focusRow)
        focusPath := ItemPaths[focusRow]
    return {Paths: paths, FocusPath: focusPath}
}

RestoreDropGroupUserSelection(snapshot) {
    global FileView, ItemPaths, SelectedFilePaths
    global DropGroupSelectionRestoreInProgress
    if !IsObject(snapshot) || !IsObject(FileView)
        return false

    current := []
    for row in GetSelectedFileRows() {
        if ItemPaths.Has(row)
            current.Push(ItemPaths[row])
    }
    focusRow := FileView.GetNext(0, "F")
    focusPath := focusRow && ItemPaths.Has(focusRow)
        ? ItemPaths[focusRow] : ""

    needsRestore := !PathArraysEqual(current, snapshot.Paths)
        || !PathsEqual(focusPath, snapshot.FocusPath)
    if needsRestore {
        DropGroupSelectionRestoreInProgress := true
        try {
            FileView.Modify(0, "-Select -Focus")
            restoreFocusRow := 0
            for row, path in ItemPaths {
                if ArrayContainsPath(snapshot.Paths, path)
                    FileView.Modify(row, "Select")
                if snapshot.FocusPath != ""
                    && PathsEqual(path, snapshot.FocusPath)
                    restoreFocusRow := row
            }
            if restoreFocusRow
                FileView.Modify(restoreFocusRow, "Focus Vis")
        } finally {
            DropGroupSelectionRestoreInProgress := false
        }
    }
    SelectedFilePaths := snapshot.Paths.Clone()
    return true
}

SetDropGroupHighlight(groupId) {
    global ActiveDropHighlightedGroup, FileView
    global DropGroupSelectionSnapshot
    if groupId = ActiveDropHighlightedGroup
        return

    if IsObject(FileView) && !ActiveDropHighlightedGroup && groupId {
        ; Preserve the real selection before LVGS_SELECTED is used to paint the
        ; whole source group as a drop target.
        SetTimer(UpdateSelectionStatus, 0)
        DropGroupSelectionSnapshot := CaptureDropGroupUserSelection()
    }

    if IsObject(FileView) && ActiveDropHighlightedGroup
        SetListGroupSelected(FileView.Hwnd,
            ActiveDropHighlightedGroup, false)

    ActiveDropHighlightedGroup := groupId

    if IsObject(FileView) && groupId {
        SetListGroupSelected(FileView.Hwnd, groupId, true)
    } else if IsObject(DropGroupSelectionSnapshot) {
        ; ItemSelect generated by the visual group state is never allowed to
        ; become the user's persistent selection/cache.
        SetTimer(UpdateSelectionStatus, 0)
        RestoreDropGroupUserSelection(DropGroupSelectionSnapshot)
        DropGroupSelectionSnapshot := 0
    }
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
    HideFolderDropMode()
}

ExecuteLocalDrop(paths, target, effect, internalItems, sourceKind) {
    global ActiveWorkspaceId
    targetWorkspaceId := HasProp(target, "WorkspaceId")
        && target.WorkspaceId != "" ? target.WorkspaceId : ActiveWorkspaceId
    if target.Type = "AddSource"
        return AddFolderSourcesToWorkspace(paths, targetWorkspaceId,
            target.Name, HasProp(target, "SourceDefaults")
                ? target.SourceDefaults : 0)
    validation := target.Type = "Pinned" || target.Type = "TextPinned"
        ? {Available: true, Writable: true, Reason: ""}
        : ValidateDropFolder(target.Path, true)
    if !validation.Available || !validation.Writable {
        SetUserStatus("投放失败：「" target.Name "」"
            . (validation.Reason != "" ? validation.Reason : "当前不可用。"))
        return {Success: 0, Failed: paths.Length, Changed: false}
    }
    if target.Type = "Pinned"
        return PinDroppedItemsToWorkspace(paths, targetWorkspaceId, "Files")
    if target.Type = "TextPinned" {
        textPaths := FilterTextBlockPaths(paths)
        if !textPaths.Length
            throw Error("固定项只接收 .md 或 .txt 文本块文件。")
        return PinDroppedItemsToWorkspace(
            textPaths, targetWorkspaceId, "TextBlocks")
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
        WorkspaceId: targetWorkspaceId,
        TargetName: target.Name,
        TargetSourceId: target.SourceId,
        InternalItems: internalItems,
        SourceKind: sourceKind,
        FromDrop: true
    }
    if operation = "move" && target.Type = "TextSource"
        && sourceKind = "Pinned" && AllTextBlockDraftPaths(paths) {
        operationContext.RemoveMovedPinsWorkspaceId := targetWorkspaceId
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
    global ActiveWorkspaceId, ActiveWorkspaceName
    return AddFolderSourcesToWorkspace(
        paths, ActiveWorkspaceId, ActiveWorkspaceName)
}

AddFolderSourcesToWorkspace(paths, workspaceId, workspaceName := "",
    defaults := 0) {
    global ActiveWorkspaceId, SettingsController
    if IsObject(SettingsController)
        throw Error("请先保存或关闭设置窗口，再添加来源。")
    result := {
        WorkspaceName: workspaceName,
        Added: 0, Existing: 0, Failed: 0,
        FailedDetails: [], Sources: []
    }
    if !IsObject(defaults)
        defaults := GetCurrentSourceDefaults()
    CreateConfigBackup()
    try AtomicConfigEdit(WriteDroppedFolderSources.Bind(
        workspaceId, paths.Clone(), defaults, result))
    catch as err {
        SetBackgroundStatus(
            "添加失败：无法保存配置，原配置未改变", 6000)
        throw err
    }

    if result.Added {
        LoadSettings()
        if StrLower(ActiveWorkspaceId) = StrLower(workspaceId) {
            PopulatePanel()
            PopulateRecentSidebar()
        }
        ; Directory enumeration remains in the existing scan worker.
        if StrLower(ActiveWorkspaceId) = StrLower(workspaceId)
            StartBackgroundScan(0, "drop-source")
        else
            QueueInactiveWorkspaceScans()
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

WriteDroppedPinnedPaths(workspaceId, workspaceType, paths, result,
    tempPath) {
    global CONFIG_VERSION, WORKSPACE_TYPE_TEXT
    doc := OpenPopDropConfig(tempPath)
    workspaceSection := "Workspace:" workspaceId
    workspaceName := Trim(doc.GetValue(workspaceSection, "Name", ""))
    if workspaceName = ""
        throw Error("目标工作区已不存在。")
    pinnedSection := "WorkspacePinned:" workspaceId
    existing := ReadPinnedPathsFromDocument(doc, pinnedSection)
    additions := []
    for rawPath in paths {
        path := NormalizePath(rawPath)
        if path = "" || !FileExist(path) {
            result.Unavailable += 1
            continue
        }
        if ParseWorkspaceType(workspaceType) = WORKSPACE_TYPE_TEXT
            && !IsTextBlockPath(path) {
            result.Unsupported += 1
            continue
        }
        if ArrayContainsPath(existing, path)
            || ArrayContainsPath(additions, path) {
            result.Existing += 1
            continue
        }
        additions.Push(path)
    }
    merged := additions.Clone()
    for path in existing
        merged.Push(path)
    WritePinnedPathsToDocument(doc, pinnedSection, merged, 3)
    doc.SetValue("Workspaces", "PinnedScopeVersion", "1", 3)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
    result.WorkspaceName := workspaceName
    result.Added := additions.Length
    result.Paths := additions
    result.AllPaths := merged
}

FormatDroppedPinnedResult(result) {
    if result.Added
        message := "已加入 " result.Added " 个固定项"
    else if result.Unavailable
        message := "添加失败：文件已经不存在"
    else
        message := "没有变化"
    if result.Existing
        message .= (result.Added ? "；" : "：")
            . result.Existing " 个已存在"
    if result.Unsupported
        message .= (result.Added || result.Existing ? "；" : "：")
            . result.Unsupported " 个文件类型不受支持"
    if result.Unavailable && result.Added
        message .= "；" result.Unavailable " 个文件已经不存在"
    return message
}

PinDroppedItemsToWorkspace(paths, workspaceId, workspaceType := "Files") {
    global ActiveWorkspaceId, PinnedPaths, Workspaces
    result := {WorkspaceName: "", Added: 0, Existing: 0,
        Unavailable: 0, Unsupported: 0, Paths: [], AllPaths: []}
    try AtomicConfigEdit(WriteDroppedPinnedPaths.Bind(
        workspaceId, workspaceType, paths.Clone(), result))
    catch as err {
        SetBackgroundStatus(
            "添加失败：无法保存配置，原配置未改变", 6000)
        throw err
    }
    if result.Added {
        found := FindWorkspace(workspaceId, Workspaces)
        if IsObject(found)
            found.Value.PinnedPaths := result.AllPaths.Clone()
        if StrLower(ActiveWorkspaceId) = StrLower(workspaceId) {
            PinnedPaths := result.AllPaths.Clone()
            if IsObject(found)
                found.Value.PinnedPaths := PinnedPaths
            ; Keep the current source snapshot/view alive. Reloading all
            ; settings here can invalidate its scan fingerprint and briefly
            ; replace otherwise healthy source groups with loading rows.
            RefreshScanAfterPinnedChange()
            PopulatePanel()
        }
    }
    SetBackgroundStatus(FormatDroppedPinnedResult(result), 6000)
    return {Success: result.Added, Failed: result.Unavailable
        + result.Unsupported, Skipped: result.Existing,
        Changed: result.Added > 0}
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
