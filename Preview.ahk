; PopDrop 0.10 file-content preview.
; The UI process owns only hit testing, a generation-checked state machine,
; bounded shared-memory copies and GDI presentation. Shell, WIC, file
; identity, hashing and cache I/O live in PopDropPreview.exe.

global PREVIEW_PROTOCOL_VERSION := 5
global PREVIEW_MAP_BYTES := 4268288
global PREVIEW_PATH_OFFSET := 256
global PREVIEW_PATH_CHARS := 32768
global PREVIEW_CACHE_ROOT_OFFSET := 65792
global PREVIEW_CACHE_ROOT_CHARS := 4096
global PREVIEW_PIXEL_OFFSET := 73984
global PREVIEW_MAX_PIXEL_BYTES := 4194304

global PreviewEnabled := true
global PreviewSide := "Auto"
global PreviewHoverDelayMs := 350
global PreviewSwitchDelayMs := 120
global PreviewLeaveGraceMs := 140
global PreviewPreviousHoldMs := 500
global PreviewBackgroundColor := 0x00000000
global PreviewBackgroundOpacity := 255
global PreviewKeyboardDelayMs := 250
global PreviewWidthDip := 400
global PreviewCacheEnabled := true
global PreviewCacheStartAfterHiddenSeconds := 10
global PreviewCacheMaxMB := 256
global PreviewCacheMaxItems := 1000
global PreviewCacheItemMaxKB := 2048
global PreviewCacheUnreferencedDays := 7
global PreviewDirectImageMaxFileMB := 64
global PreviewDirectImageMaxEdge := 65535
global PreviewDirectImageMaxPixelsMP := 160
global PreviewDirectImageMaxExpandedMB := 256
global PreviewDocumentEnabled := true
global PreviewPdfEnabled := false
global PreviewShowFileInfo := true
global PreviewDocumentStatusDelayMs := 120
global PreviewDocumentLongStatusMs := 5000
global PreviewDocumentHardTimeoutMs := 12000
global PreviewDocumentThemeVersion := 1

global PreviewGeneration := 0
global PreviewListInstance := 0
global PreviewPanelSession := 0
global PreviewRequestSerial := 0
global PreviewInputAuthority := ""
global PreviewSession := {
    State: "Hidden", Path: "", Hwnd: 0, Row: 0,
    Generation: 0, ListInstance: 0, PanelSession: 0,
    RequestId: 0, RequestStarted: 0, VisiblePath: "",
    Side: "", Suppression: "", CacheCommand: false,
    DocumentGeneration: false, StatusKind: "", StatusFrame: 0
}
global PreviewNegativeCache := Map()
global PreviewHoverCacheQueue := []
global PreviewCacheCompletedThisHiddenSession := 0
global PreviewCacheSucceededThisHiddenSession := 0
global PreviewCacheFailedThisHiddenSession := 0
global PreviewCacheActive := false
global PreviewSessionDisabled := false
global PreviewRestartTicks := []

global PreviewMapHandle := 0
global PreviewMapView := 0
global PreviewRequestEvent := 0
global PreviewResponseEvent := 0
global PreviewShutdownEvent := 0
global PreviewHelperPid := 0
global PreviewJobHandle := 0
global PreviewObjectBase := ""
; AutoHotkey low-numbered OnMessage callbacks may re-enter a timer even while
; it is Critical. Keep the mapping alive explicitly while a header/pixel copy
; is in progress; helper shutdown is deferred until the last reader leaves.
global PreviewMapAccessDepth := 0
global PreviewHelperClosePending := 0
global PreviewHelperCloseRunning := false

global PreviewWindow := 0
global PreviewCanvasDc := 0
global PreviewCanvasBitmap := 0
global PreviewCanvasOldBitmap := 0
global PreviewCanvasWidth := 0
global PreviewCanvasHeight := 0
global PreviewStatusRect := 0

PreviewDocumentExtensions() {
    static extensions := Map(
        "md", "markdown", "markdown", "markdown",
        "txt", "text", "log", "text", "ini", "text", "cfg", "text",
        "conf", "text", "json", "code", "jsonc", "code",
        "yaml", "code", "yml", "code", "xml", "code", "ahk", "code",
        "c", "code", "cc", "code", "cpp", "code", "cxx", "code",
        "h", "code", "hh", "code", "hpp", "code", "cs", "code",
        "java", "code", "kt", "code", "kts", "code", "go", "code",
        "rs", "code", "swift", "code", "py", "code", "pyw", "code",
        "js", "code", "jsx", "code", "ts", "code", "tsx", "code",
        "html", "code", "htm", "code", "css", "code", "scss", "code",
        "less", "code", "sql", "code", "ps1", "code", "psm1", "code",
        "bat", "code", "cmd", "code", "sh", "code", "zsh", "code",
        "toml", "code", "properties", "code", "gradle", "code",
        "cmake", "code", "dockerfile", "code", "vue", "code",
        "svelte", "code", "rb", "code", "php", "code", "lua", "code",
        "r", "code", "dart", "code", "ex", "code", "exs", "code",
        "csv", "table", "tsv", "table",
        "pdf", "pdf", "docx", "docx")
    return extensions
}

PreviewDocumentKind(path) {
    global PreviewDocumentEnabled, PreviewPdfEnabled
    if !PreviewDocumentEnabled
        return ""
    SplitPath(path, , , &extension)
    extensions := PreviewDocumentExtensions()
    key := StrLower(extension)
    if !extensions.Has(key)
        return ""
    kind := extensions[key]
    return kind = "pdf" && !PreviewPdfEnabled ? "" : kind
}

PreviewIsSupportedDocumentPath(path) {
    SplitPath(path, , , &extension)
    return PreviewDocumentExtensions().Has(StrLower(extension))
}

PreviewLooksLikeDocument(path) {
    return PreviewDocumentKind(path) != ""
}

LoadPreviewSettings(settingErrors := 0) {
    global ConfigPath
    global PreviewEnabled, PreviewSide, PreviewHoverDelayMs
    global PreviewSwitchDelayMs, PreviewLeaveGraceMs, PreviewPreviousHoldMs
    global PreviewBackgroundColor, PreviewBackgroundOpacity
    global PreviewKeyboardDelayMs
    global PreviewWidthDip, PreviewCacheEnabled
    global PreviewCacheStartAfterHiddenSeconds, PreviewCacheMaxMB
    global PreviewCacheMaxItems, PreviewCacheItemMaxKB
    global PreviewCacheUnreferencedDays, PreviewDirectImageMaxFileMB
    global PreviewDirectImageMaxEdge, PreviewDirectImageMaxPixelsMP
    global PreviewDirectImageMaxExpandedMB, PreviewDocumentEnabled
    global PreviewPdfEnabled, PreviewShowFileInfo

    loadedEnabled := PreviewReadBoolean("Enabled", true, settingErrors)
    previousDocumentEnabled := PreviewDocumentEnabled
    previousPdfEnabled := PreviewPdfEnabled
    previousSide := PreviewSide
    previousCacheEnabled := PreviewCacheEnabled
    previousBackgroundColor := PreviewBackgroundColor
    previousBackgroundOpacity := PreviewBackgroundOpacity
    rawSide := StrLower(Trim(IniRead(ConfigPath, "Preview", "Side",
        ConfigDefaultValue("Preview", "Side", "Auto"))))
    if rawSide = "right"
        PreviewSide := "Right"
    else if rawSide = "left"
        PreviewSide := "Left"
    else {
        PreviewSide := "Auto"
        if rawSide != "" && rawSide != "auto" && IsObject(settingErrors)
            settingErrors.Push("[Preview] Side 无效，已使用 Auto。")
    }
    PreviewHoverDelayMs := PreviewReadInteger(
        "HoverDelayMs", ConfigDefaultInteger("Preview", "HoverDelayMs", 350),
        50, 2000, settingErrors)
    PreviewSwitchDelayMs := PreviewReadInteger(
        "SwitchDelayMs", ConfigDefaultInteger("Preview", "SwitchDelayMs", 120),
        0, 1000, settingErrors)
    PreviewLeaveGraceMs := PreviewReadInteger(
        "LeaveGraceMs", ConfigDefaultInteger("Preview", "LeaveGraceMs", 140),
        0, 1000, settingErrors)
    PreviewPreviousHoldMs := PreviewReadInteger(
        "PreviousPreviewHoldMs",
        ConfigDefaultInteger("Preview", "PreviousPreviewHoldMs", 500),
        0, 3000, settingErrors)
    PreviewBackgroundColor := PreviewReadColor(
        "BackgroundColor",
        ConfigDefaultValue("Preview", "BackgroundColor", "#000000"),
        settingErrors)
    PreviewBackgroundOpacity := PreviewReadInteger(
        "BackgroundOpacity",
        ConfigDefaultInteger("Preview", "BackgroundOpacity", 255),
        0, 255, settingErrors)
    PreviewKeyboardDelayMs := PreviewReadInteger(
        "KeyboardDelayMs", ConfigDefaultInteger("Preview", "KeyboardDelayMs", 250),
        50, 2000, settingErrors)
    PreviewWidthDip := PreviewReadInteger(
        "Width", ConfigDefaultInteger("Preview", "Width", 400),
        180, 640, settingErrors)
    PreviewCacheEnabled := PreviewReadBoolean(
        "CacheEnabled", ConfigDefaultBoolean("Preview", "CacheEnabled", true),
        settingErrors)
    PreviewCacheStartAfterHiddenSeconds := PreviewReadInteger(
        "CacheStartAfterHiddenSeconds",
        ConfigDefaultInteger("Preview", "CacheStartAfterHiddenSeconds", 10),
        3, 300, settingErrors)
    PreviewCacheMaxMB := PreviewReadInteger(
        "CacheMaxMB", ConfigDefaultInteger("Preview", "CacheMaxMB", 256),
        16, 4096, settingErrors)
    PreviewCacheMaxItems := PreviewReadInteger(
        "CacheMaxItems", ConfigDefaultInteger("Preview", "CacheMaxItems", 1000),
        10, 50000, settingErrors)
    PreviewCacheItemMaxKB := PreviewReadInteger(
        "CacheItemMaxKB", ConfigDefaultInteger("Preview", "CacheItemMaxKB", 2048),
        128, 2048, settingErrors)
    PreviewCacheUnreferencedDays := PreviewReadInteger(
        "CacheUnreferencedDays",
        ConfigDefaultInteger("Preview", "CacheUnreferencedDays", 7),
        1, 365, settingErrors)
    PreviewDirectImageMaxFileMB := PreviewReadInteger(
        "DirectImageMaxFileMB",
        ConfigDefaultInteger("Preview", "DirectImageMaxFileMB", 64),
        1, 256, settingErrors)
    PreviewDirectImageMaxEdge := PreviewReadInteger(
        "DirectImageMaxEdge",
        ConfigDefaultInteger("Preview", "DirectImageMaxEdge", 65535),
        1024, 65535, settingErrors)
    PreviewDirectImageMaxPixelsMP := PreviewReadInteger(
        "DirectImageMaxPixelsMP",
        ConfigDefaultInteger("Preview", "DirectImageMaxPixelsMP", 160),
        1, 500, settingErrors)
    PreviewDirectImageMaxExpandedMB := PreviewReadInteger(
        "DirectImageMaxExpandedMB",
        ConfigDefaultInteger("Preview", "DirectImageMaxExpandedMB", 256),
        16, 512, settingErrors)
    PreviewDocumentEnabled := PreviewReadBoolean(
        "DocumentEnabled", ConfigDefaultBoolean("Preview", "DocumentEnabled", true),
        settingErrors)
    PreviewPdfEnabled := PreviewReadBoolean(
        "PdfEnabled", ConfigDefaultBoolean("Preview", "PdfEnabled", false),
        settingErrors)
    PreviewShowFileInfo := PreviewReadBoolean(
        "ShowFileInfo", ConfigDefaultBoolean("Preview", "ShowFileInfo", true),
        settingErrors)
    enabledChanged := SetFilePreviewEnabled(loadedEnabled, false)
    if !enabledChanged
        && (previousSide != PreviewSide
            || previousCacheEnabled != PreviewCacheEnabled
            || previousBackgroundColor != PreviewBackgroundColor
            || previousBackgroundOpacity != PreviewBackgroundOpacity
            || previousDocumentEnabled != PreviewDocumentEnabled
            || previousPdfEnabled != PreviewPdfEnabled)
        PreviewSettingsChanged()
}

PreviewReadBoolean(key, defaultValue, settingErrors := 0) {
    global ConfigPath
    raw := Trim(IniRead(ConfigPath, "Preview", key,
        defaultValue ? "1" : "0"))
    if raw = "0"
        return false
    if raw = "1"
        return true
    if IsObject(settingErrors)
        settingErrors.Push("[Preview] " key " 必须为 0 或 1，已恢复默认值。")
    return defaultValue
}

PreviewReadInteger(key, defaultValue, minimum, maximum, settingErrors := 0) {
    global ConfigPath
    raw := Trim(IniRead(ConfigPath, "Preview", key, defaultValue))
    try value := Integer(raw)
    catch {
        if IsObject(settingErrors)
            settingErrors.Push("[Preview] " key " 不是整数，已恢复默认值。")
        return defaultValue
    }
    if value < minimum || value > maximum {
        if IsObject(settingErrors)
            settingErrors.Push("[Preview] " key " 超出范围，已恢复默认值。")
        return defaultValue
    }
    return value
}

PreviewReadColor(key, defaultValue, settingErrors := 0) {
    global ConfigPath
    raw := Trim(IniRead(ConfigPath, "Preview", key, defaultValue))
    color := PreviewColorRefFromText(raw, -1)
    if color >= 0
        return color
    if IsObject(settingErrors)
        settingErrors.Push("[Preview] " key
            . " 必须为 #RRGGBB 格式，已恢复默认值。")
    return PreviewColorRefFromText(defaultValue, 0x00000000)
}

PreviewColorRefFromText(text, fallback := 0x00000000) {
    if !RegExMatch(Trim(text), "i)^#([0-9a-f]{6})$", &match)
        return fallback
    rgb := Integer("0x" match[1])
    return ((rgb & 0x0000FF) << 16)
        | (rgb & 0x00FF00)
        | ((rgb & 0xFF0000) >> 16)
}

PreviewSettingsChanged() {
    global PreviewEnabled, PreviewCacheEnabled, PreviewDocumentEnabled
    global PreviewPdfEnabled
    global PreviewGeneration
    global PreviewCacheActive, PreviewSession
    PreviewGeneration += 1
    if !PreviewCacheEnabled {
        PreviewCacheActive := false
        SetTimer(PreviewBeginCachePass, 0)
        SetTimer(PreviewSendNextCacheRequest, 0)
        if PreviewSession.CacheCommand
            SetTimer(PreviewCancelCacheHard.Bind(
                PreviewSession.RequestId), -300)
    }
    if !PreviewEnabled
        PreviewHide("disabled", true)
    else {
        if !PreviewDocumentEnabled || (!PreviewPdfEnabled
            && PreviewDocumentKindIgnoringSettings(PreviewSession.Path) = "pdf")
            PreviewCancelDocumentDisplay()
        PreviewHide("settings", true)
        PreviewRecoverAfterInteraction()
    }
}

PreviewDocumentKindIgnoringSettings(path) {
    SplitPath(path, , , &extension)
    extensions := PreviewDocumentExtensions()
    key := StrLower(extension)
    return extensions.Has(key) ? extensions[key] : ""
}

PreviewCancelDocumentDisplay() {
    global PreviewSession, PreviewGeneration
    if PreviewIsSupportedDocumentPath(PreviewSession.Path) {
        if PreviewSession.State = "Loading"
            || PreviewSession.State = "DocumentGenerating"
            PreviewTerminateCacheHelper()
        PreviewHide("documents-disabled", true)
    }
    PreviewGeneration += 1
    SetTimer(PreviewShowDocumentStatus, 0)
    SetTimer(PreviewShowDocumentLongStatus, 0)
    SetTimer(PreviewDocumentAnimationTick, 0)
    SetTimer(PreviewDocumentHardTimeout, 0)
}

PreviewBeginPanelSession() {
    global PreviewPanelSession, PreviewGeneration, PreviewSession
    global PreviewCacheActive
    PreviewPanelSession += 1
    PreviewGeneration += 1
    PreviewSession.Side := ""
    PreviewCacheActive := false
    SetTimer(PreviewBeginCachePass, 0)
    if PreviewSession.CacheCommand {
        cacheRequestId := PreviewSession.RequestId
        SetTimer(PreviewCancelCacheHard.Bind(cacheRequestId), -300)
    }
    PreviewHide("show", true)
}

PreviewPanelHidden() {
    global PreviewCacheStartAfterHiddenSeconds
    global PreviewCacheCompletedThisHiddenSession
    global PreviewCacheSucceededThisHiddenSession
    global PreviewCacheFailedThisHiddenSession
    PreviewHide("panel-hidden", true)
    PreviewCacheCompletedThisHiddenSession := 0
    PreviewCacheSucceededThisHiddenSession := 0
    PreviewCacheFailedThisHiddenSession := 0
    PreviewWriteCacheStatus("Scheduled")
    SetTimer(PreviewBeginCachePass,
        -(PreviewCacheStartAfterHiddenSeconds * 1000))
}

PreviewInvalidateList(reason := "") {
    global PreviewListInstance, PreviewGeneration
    PreviewListInstance += 1
    PreviewGeneration += 1
    CloseExternalQuickPreview()
    PreviewHide("list-" reason, true)
}

PreviewHandleMouseMove(hwnd, lParam) {
    global PreviewEnabled, PreviewSessionDisabled, PreviewInputAuthority
    global PreviewSession
    if !PreviewEnabled || PreviewSessionDisabled || !IsTrackedFileViewHwnd(hwnd)
        return
    PreviewTrackMouseLeave(hwnd)
    if PreviewSession.State = "Suppressed"
        return
    x := SignedMouseCoordinate(lParam & 0xFFFF)
    y := SignedMouseCoordinate((lParam >> 16) & 0xFFFF)
    screen := ClientToScreenPoint(hwnd, x, y)
    if !PreviewScreenPointHitsList(hwnd, screen.X, screen.Y) {
        ; A transient child/overlay hit while crossing card boundaries should
        ; behave like list whitespace, not synchronously blank the preview.
        PreviewScheduleLeave()
        return
    }
    row := HitTestListItemBounds(hwnd, x, y)
    candidate := PreviewCandidateForRow(hwnd, row)
    PreviewInputAuthority := "mouse"
    if !IsObject(candidate) {
        PreviewScheduleLeave()
        return
    }
    PreviewArmCandidate(candidate.Path, hwnd, row, "mouse")
}

PreviewTrackMouseLeave(hwnd) {
    size := A_PtrSize = 8 ? 24 : 16
    track := Buffer(size, 0)
    NumPut("uint", size, track, 0)
    NumPut("uint", 0x00000002, track, 4) ; TME_LEAVE
    NumPut("ptr", hwnd, track, 8)
    DllCall("user32\TrackMouseEvent", "ptr", track.Ptr)
}

FileViewMouseLeave(wParam, lParam, msg, hwnd) {
    if IsTrackedFileViewHwnd(hwnd)
        PreviewScheduleLeave()
}

PreviewScheduleLeave() {
    global PreviewLeaveGraceMs, PreviewPreviousHoldMs, PreviewSession
    delay := PreviewLeaveGraceMs
    if PreviewSession.State = "Visible" || PreviewSession.VisiblePath != ""
        delay := Max(delay, PreviewPreviousHoldMs)
    SetTimer(PreviewLeaveExpired, -Max(1, delay))
}

PreviewLeaveExpired() {
    global PreviewInputAuthority
    if PreviewInputAuthority = "mouse"
        PreviewHide("leave", true)
}

PreviewCandidateForRow(hwnd, row) {
    global FileView, RecentView, ItemPaths, ItemKinds, RecentItemPaths
    if !row
        return 0
    if IsObject(FileView) && hwnd = FileView.Hwnd {
        if !ItemPaths.Has(row) || !ItemKinds.Has(row)
            || ItemKinds[row] != "File"
            return 0
        return {Path: ItemPaths[row], Row: row, Hwnd: hwnd}
    }
    if IsObject(RecentView) && hwnd = RecentView.Hwnd
        && RecentItemPaths.Has(row)
        return {Path: RecentItemPaths[row], Row: row, Hwnd: hwnd}
    return 0
}

PreviewArmCandidate(path, hwnd, row, authority) {
    global PreviewSession, PreviewGeneration, PreviewListInstance
    global PreviewPanelSession, PreviewHoverDelayMs, PreviewSwitchDelayMs
    global PreviewKeyboardDelayMs, PreviewNegativeCache
    global PreviewPreviousHoldMs
    if path = ""
        return
    if PreviewDocumentKindIgnoringSettings(path) != ""
        && PreviewDocumentKind(path) = "" {
        PreviewHide("document-type-disabled", true)
        return
    }
    SetTimer(PreviewLeaveExpired, 0)
    if PreviewSession.Path = path
        && PreviewSession.Hwnd = hwnd
        && PreviewSession.State != "Hidden"
        return
    if PreviewNegativeCache.Has(PathKey(path)) {
        failure := PreviewNegativeCache[PathKey(path)]
        if failure.Stamp != PreviewFileStamp(path)
            PreviewNegativeCache.Delete(PathKey(path))
        else if failure.Permanent {
            PreviewSession.Path := path
            PreviewSession.State := "Error"
            PreviewPresentFallbackCard(path)
            return
        } else if ElapsedTickMilliseconds(
            failure.Tick, A_TickCount) < failure.RetryMs {
            PreviewSession.Path := path
            PreviewSession.State := "Error"
            PreviewPresentFallbackCard(path)
            return
        }
        else
            PreviewNegativeCache.Delete(PathKey(path))
    }
    wasVisible := PreviewSession.State = "Visible"
        || PreviewSession.VisiblePath != ""
    PreviewGeneration += 1
    PreviewSession.State := "Armed"
    PreviewSession.Path := path
    PreviewSession.Hwnd := hwnd
    PreviewSession.Row := row
    PreviewSession.Generation := PreviewGeneration
    PreviewSession.ListInstance := PreviewListInstance
    PreviewSession.PanelSession := PreviewPanelSession
    PreviewSession.CacheCommand := false
    delay := PreviewCandidateDelay(wasVisible, authority)
    SetTimer(PreviewIssueArmedRequest, -Max(1, delay))
    if wasVisible
        ; Keep the old frame until the replacement is ready, with a bounded
        ; maximum so a failed/slow request cannot leave misleading content.
        SetTimer(PreviewExpireStaleContent,
            -Max(1, PreviewPreviousHoldMs))
}

PreviewFileStamp(path) {
    data := Buffer(36, 0)
    if !DllCall("kernel32\GetFileAttributesExW", "wstr", path,
        "int", 0, "ptr", data.Ptr, "int")
        return "missing"
    size := (NumGet(data, 28, "uint") << 32) | NumGet(data, 32, "uint")
    write := (NumGet(data, 24, "uint") << 32) | NumGet(data, 20, "uint")
    return size "|" write
}

PreviewCandidateDelay(wasVisible, authority) {
    global PreviewHoverDelayMs, PreviewSwitchDelayMs, PreviewKeyboardDelayMs
    return authority = "keyboard"
        ? PreviewKeyboardDelayMs
        : (wasVisible ? PreviewSwitchDelayMs : PreviewHoverDelayMs)
}

PreviewGenerationMatches(generation, listInstance, panelSession) {
    global PreviewGeneration, PreviewListInstance, PreviewPanelSession
    return generation = PreviewGeneration
        && listInstance = PreviewListInstance
        && panelSession = PreviewPanelSession
}

PreviewExpireStaleContent() {
    global PreviewSession
    if PreviewSession.State = "Armed" || PreviewSession.State = "Loading"
        PreviewHideWindowOnly()
}

PreviewIssueArmedRequest() {
    global PreviewSession, PreviewEnabled, PreviewSessionDisabled
    if !PreviewEnabled || PreviewSessionDisabled
        return
    if PreviewSession.State != "Armed"
        return
    PreviewSendRequest(1, PreviewSession.Path)
}

PreviewHandleKeyDown(vk, hwnd, lParam := 0) {
    global PreviewInputAuthority, FileView, RecentView
    static navigationKeys := Map(
        0x25, true, 0x26, true, 0x27, true, 0x28, true,
        0x24, true, 0x23, true, 0x21, true, 0x22, true)
    if vk = 0x20 {
        if !IsPanelQuickPreviewAvailable()
            return
        ; Use the hovered row when focus is elsewhere; otherwise retain the
        ; current preview candidate. Auto-repeat must not relaunch the viewer.
        if (lParam && ((lParam >> 30) & 1))
            return
        path := PreviewSession.Path
        if path = "" {
            point := Buffer(8, 0)
            if DllCall("user32\GetCursorPos", "ptr", point.Ptr) {
                sx := NumGet(point, 0, "int"), sy := NumGet(point, 4, "int")
                list := hwnd = FileView.Hwnd ? FileView : RecentView
                if IsObject(list) && ScreenPointInWindow(list.Hwnd, sx, sy) {
                    cp := ScreenToClientPoint(list.Hwnd, sx, sy)
                    row := HitTestListItemBounds(list.Hwnd, cp.X, cp.Y)
                    candidate := PreviewCandidateForRow(list.Hwnd, row)
                    if IsObject(candidate)
                        path := candidate.Path
                }
            }
        }
        if path != ""
            OpenExternalQuickPreview(path)
        return
    }
    if vk = 0x0D || vk = 0x1B {
        PreviewHide("key-action", true)
        return
    }
    if vk = 0x79 || vk = 0x5D {
        PreviewSuppress("context-menu", false)
        return
    }
    if navigationKeys.Has(vk) {
        PreviewInputAuthority := "keyboard"
        SetTimer(PreviewArmFocusedRow.Bind(hwnd), -1)
        QuickPreviewScheduleUpdate()
    }
}

PreviewArmFocusedRow(hwnd) {
    global FileView, RecentView
    if IsObject(FileView) && hwnd = FileView.Hwnd
        row := FileView.GetNext(0, "F")
    else if IsObject(RecentView) && hwnd = RecentView.Hwnd {
        row := RecentView.GetNext(0, "F")
        if !row
            row := RecentView.GetNext(0)
    } else
        return
    candidate := PreviewCandidateForRow(hwnd, row)
    if IsObject(candidate)
        PreviewArmCandidate(candidate.Path, hwnd, row, "keyboard")
    else
        PreviewHide("keyboard-empty", true)
}

PreviewSuppress(reason, recover := false) {
    global PreviewSession, PreviewGeneration
    PreviewGeneration += 1
    PreviewSession.State := "Suppressed"
    PreviewSession.Suppression := reason
    PreviewSession.Generation := PreviewGeneration
    PreviewHideWindowOnly()
    SetTimer(PreviewIssueArmedRequest, 0)
    if recover
        SetTimer(PreviewRecoverFromCursor, -180)
}

PreviewRecoverAfterInteraction() {
    SetTimer(PreviewRecoverFromCursor, -1)
}

PreviewRecoverFromCursor() {
    global PreviewEnabled, PreviewSessionDisabled, PreviewSession
    global PanelVisible, FileView, RecentView, PreviewInputAuthority
    if !PreviewEnabled || PreviewSessionDisabled || !PanelVisible
        return
    point := Buffer(8, 0)
    if !DllCall("user32\GetCursorPos", "ptr", point.Ptr)
        return
    sx := NumGet(point, 0, "int")
    sy := NumGet(point, 4, "int")
    for list in [FileView, RecentView] {
        if !IsObject(list) || !ScreenPointInWindow(list.Hwnd, sx, sy)
            continue
        if !PreviewScreenPointHitsList(list.Hwnd, sx, sy)
            continue
        clientPoint := ScreenToClientPoint(list.Hwnd, sx, sy)
        row := HitTestListItemBounds(
            list.Hwnd, clientPoint.X, clientPoint.Y)
        candidate := PreviewCandidateForRow(list.Hwnd, row)
        PreviewSession.Suppression := ""
        if IsObject(candidate) {
            PreviewInputAuthority := "mouse"
            PreviewSession.State := "Hidden"
            PreviewArmCandidate(candidate.Path, list.Hwnd, row, "mouse")
        } else
            PreviewHide("recover-empty", true)
        return
    }
    PreviewHide("recover-outside", true)
}

PreviewScreenPointHitsList(listHwnd, screenX, screenY) {
    packedPoint := (screenY << 32) | (screenX & 0xFFFFFFFF)
    hit := DllCall("user32\WindowFromPoint", "int64", packedPoint, "ptr")
    return hit = listHwnd
        || (hit && DllCall("user32\IsChild",
            "ptr", listHwnd, "ptr", hit, "int"))
}

PanelMovingOrSizing(wParam, lParam, msg, hwnd) {
    global Panel
    if IsObject(Panel) && hwnd = Panel.Hwnd
        PreviewSuppress("move-size", false)
}

PanelExitMoveSize(wParam, lParam, msg, hwnd) {
    global Panel, PreviewSide, PreviewSession
    if IsObject(Panel) && hwnd = Panel.Hwnd {
        if PreviewSide = "Auto"
            PreviewSession.Side := ""
        PreviewRecoverAfterInteraction()
    }
}

PreviewHide(reason := "", invalidate := false) {
    global PreviewSession, PreviewGeneration
    global PreviewDocumentLongStatusMs
    wasDirectDocument := PreviewSession.State = "Loading"
        && PreviewIsSupportedDocumentPath(PreviewSession.Path)
    wasDocumentGeneration := PreviewSession.DocumentGeneration
    keepDocumentGeneration := wasDocumentGeneration
        && ElapsedTickMilliseconds(
            PreviewSession.RequestStarted, A_TickCount)
            >= PreviewDocumentLongStatusMs
    SetTimer(PreviewIssueArmedRequest, 0)
    SetTimer(PreviewExpireStaleContent, 0)
    SetTimer(PreviewShowDocumentStatus, 0)
    SetTimer(PreviewShowDocumentLongStatus, 0)
    SetTimer(PreviewDocumentAnimationTick, 0)
    if wasDirectDocument
        PreviewTerminateCacheHelper()
    if wasDocumentGeneration && !keepDocumentGeneration {
        SetTimer(PreviewDocumentHardTimeout, 0)
        PreviewTerminateCacheHelper()
    }
    if invalidate
        PreviewGeneration += 1
    PreviewSession.State := "Hidden"
    PreviewSession.Path := keepDocumentGeneration ? PreviewSession.Path : ""
    PreviewSession.VisiblePath := ""
    PreviewSession.Generation := PreviewGeneration
    PreviewSession.CacheCommand := false
    PreviewSession.DocumentGeneration := keepDocumentGeneration
    PreviewSession.StatusKind := ""
    PreviewHideWindowOnly()
}

PreviewEnsureHelper() {
    global PreviewMapHandle, PreviewMapView, PreviewRequestEvent
    global PreviewResponseEvent, PreviewShutdownEvent, PreviewObjectBase
    global PreviewHelperPid, PreviewJobHandle, PREVIEW_MAP_BYTES
    global PREVIEW_PROTOCOL_VERSION, PreviewSessionDisabled
    global PreviewMapAccessDepth, PreviewHelperCloseRunning
    if PreviewSessionDisabled
        return false
    if PreviewHelperPid && ProcessExist(PreviewHelperPid)
        return true
    ; Never replace the global mapping while an interrupted response handler
    ; still owns the previous one. Its deferred retry will start a helper once
    ; that bounded access has completed.
    if PreviewMapAccessDepth > 0 || PreviewHelperCloseRunning
        return false
    PreviewCloseHelperObjects(false)
    token := Format("{:08X}{:08X}", A_TickCount,
        DllCall("kernel32\GetCurrentProcessId", "uint"))
    PreviewObjectBase := "Local\PopDropPreview-" token
    PreviewMapHandle := DllCall("kernel32\CreateFileMappingW",
        "ptr", -1, "ptr", 0, "uint", 0x04, "uint", 0,
        "uint", PREVIEW_MAP_BYTES, "wstr", PreviewObjectBase "-Map", "ptr")
    if !PreviewMapHandle
        return false
    PreviewMapView := DllCall("kernel32\MapViewOfFile",
        "ptr", PreviewMapHandle, "uint", 0xF001F, "uint", 0, "uint", 0,
        "uptr", PREVIEW_MAP_BYTES, "ptr")
    PreviewRequestEvent := DllCall("kernel32\CreateEventW",
        "ptr", 0, "int", 0, "int", 0,
        "wstr", PreviewObjectBase "-Request", "ptr")
    PreviewResponseEvent := DllCall("kernel32\CreateEventW",
        "ptr", 0, "int", 0, "int", 0,
        "wstr", PreviewObjectBase "-Response", "ptr")
    PreviewShutdownEvent := DllCall("kernel32\CreateEventW",
        "ptr", 0, "int", 1, "int", 0,
        "wstr", PreviewObjectBase "-Shutdown", "ptr")
    if !PreviewMapView || !PreviewRequestEvent
        || !PreviewResponseEvent || !PreviewShutdownEvent {
        PreviewCloseHelperObjects(false)
        return false
    }
    access := PreviewBeginMapAccess()
    try {
        if !IsObject(access)
            return false
        mapView := access.View
        if !mapView
            return false
        DllCall("ntdll\RtlZeroMemory", "ptr", mapView,
            "uptr", PREVIEW_MAP_BYTES)
        NumPut("uint", 0x56504450, mapView, 0) ; PDPV
        NumPut("uint", PREVIEW_PROTOCOL_VERSION, mapView, 4)
    } finally PreviewEndMapAccess(access)
    helperPath := A_ScriptDir "\native\bin\"
        . (A_PtrSize = 8 ? "x64" : "x86") "\PopDropPreview.exe"
    if !FileExist(helperPath) {
        PreviewCloseHelperObjects(false)
        return false
    }
    try Run('"' helperPath '" --shared "' PreviewObjectBase '"',
        A_ScriptDir, "Hide", &PreviewHelperPid)
    catch {
        PreviewCloseHelperObjects(false)
        return false
    }
    PreviewAssignHelperJob()
    return true
}

PreviewAssignHelperJob() {
    global PreviewJobHandle, PreviewHelperPid
    PreviewJobHandle := DllCall("kernel32\CreateJobObjectW",
        "ptr", 0, "ptr", 0, "ptr")
    if !PreviewJobHandle
        return
    size := A_PtrSize = 8 ? 144 : 112
    info := Buffer(size, 0)
    NumPut("uint", 0x2100, info, 16) ; PROCESS_MEMORY | KILL_ON_JOB_CLOSE
    NumPut("uptr", 512 * 1024 * 1024, info, A_PtrSize = 8 ? 112 : 96)
    if !DllCall("kernel32\SetInformationJobObject", "ptr", PreviewJobHandle,
        "int", 9, "ptr", info.Ptr, "uint", size, "int")
        return
    process := DllCall("kernel32\OpenProcess", "uint", 0x0501,
        "int", 0, "uint", PreviewHelperPid, "ptr")
    if process {
        DllCall("kernel32\AssignProcessToJobObject",
            "ptr", PreviewJobHandle, "ptr", process)
        DllCall("kernel32\CloseHandle", "ptr", process)
    }
}

PreviewSendRequest(command, path) {
    global PreviewMapView, PreviewResponseEvent, PreviewRequestEvent
    global PreviewRequestSerial, PreviewSession, PreviewGeneration
    global PreviewListInstance, PreviewPanelSession
    global PREVIEW_PATH_OFFSET, PREVIEW_PATH_CHARS
    global PREVIEW_CACHE_ROOT_OFFSET, PREVIEW_CACHE_ROOT_CHARS
    global PreviewWidthDip, Panel, CacheDir
    global PreviewCacheEnabled, PreviewCacheMaxMB, PreviewCacheMaxItems
    global PreviewCacheItemMaxKB, PreviewCacheUnreferencedDays
    global PreviewDirectImageMaxFileMB, PreviewDirectImageMaxEdge
    global PreviewDirectImageMaxPixelsMP, PreviewDirectImageMaxExpandedMB
    global PreviewDocumentThemeVersion
    PreviewSession.Path := path
    if !PreviewEnsureHelper() {
        if command != 2 {
            PreviewRememberFailure(path)
            PreviewSession.State := "Error"
            PreviewPresentFallbackCard(path)
        }
        return false
    }
    requestId := ++PreviewRequestSerial
    dpi := DllCall("user32\GetDpiForWindow", "ptr", Panel.Hwnd, "uint")
    if !dpi
        dpi := 96
    panelRect := Buffer(16, 0)
    DllCall("user32\GetWindowRect", "ptr", Panel.Hwnd, "ptr", panelRect.Ptr)
    panelHeight := Max(180,
        NumGet(panelRect, 12, "int") - NumGet(panelRect, 4, "int"))
    requestedWidth := DllCall("kernel32\MulDiv",
        "int", PreviewWidthDip, "int", dpi, "int", 96, "int")
    cacheEdge := Min(1024, panelHeight)
    access := PreviewBeginMapAccess()
    try {
        if !IsObject(access)
            return false
        mapView := access.View
        if !mapView || !PreviewResponseEvent || !PreviewRequestEvent
            return false
        NumPut("uint", command, mapView, 8)
        NumPut("uint", 0, mapView, 12)
        NumPut("int64", PreviewGeneration, mapView, 16)
        NumPut("int64", PreviewListInstance, mapView, 24)
        NumPut("int64", PreviewPanelSession, mapView, 32)
        NumPut("int64", requestId, mapView, 40)
        NumPut("uint", command != 1 ? cacheEdge : Min(1024, requestedWidth),
            mapView, 48)
        NumPut("uint", command != 1 ? cacheEdge : Min(1024, panelHeight),
            mapView, 52)
        NumPut("uint", PreviewDirectImageMaxFileMB, mapView, 56)
        NumPut("uint", PreviewDirectImageMaxEdge, mapView, 60)
        NumPut("uint", PreviewDirectImageMaxPixelsMP, mapView, 64)
        NumPut("uint", PreviewDirectImageMaxExpandedMB, mapView, 68)
        NumPut("uint", PreviewCacheEnabled ? 1 : 0, mapView, 72)
        NumPut("uint", PreviewCacheMaxMB, mapView, 76)
        NumPut("uint", PreviewCacheMaxItems, mapView, 80)
        NumPut("uint", PreviewCacheItemMaxKB, mapView, 84)
        NumPut("uint", PreviewCacheUnreferencedDays, mapView, 88)
        NumPut("uint", cacheEdge, mapView, 92)
        NumPut("uint", dpi, mapView, 96)
        NumPut("uint", PreviewDocumentThemeVersion, mapView, 100)
        StrPut(path, mapView + PREVIEW_PATH_OFFSET,
            PREVIEW_PATH_CHARS, "UTF-16")
        StrPut(CacheDir "\preview-cache-v1",
            mapView + PREVIEW_CACHE_ROOT_OFFSET,
            PREVIEW_CACHE_ROOT_CHARS, "UTF-16")
        DllCall("kernel32\ResetEvent", "ptr", PreviewResponseEvent)
        PreviewSession.State := command = 3 ? "DocumentGenerating" : "Loading"
        PreviewSession.RequestId := requestId
        PreviewSession.RequestStarted := A_TickCount
        PreviewSession.Generation := PreviewGeneration
        PreviewSession.ListInstance := PreviewListInstance
        PreviewSession.PanelSession := PreviewPanelSession
        PreviewSession.CacheCommand := command = 2
        PreviewSession.DocumentGeneration := command = 3
        DllCall("kernel32\SetEvent", "ptr", PreviewRequestEvent)
    } finally PreviewEndMapAccess(access)
    SetTimer(PreviewPollResponse, 15)
    if command = 1 && PreviewLooksLikeDocument(path) {
        SetTimer(PreviewShowDocumentStatus, -120)
        SetTimer(PreviewShowDocumentLongStatus, -5000)
    }
    return true
}

PreviewPollResponse() {
    global PreviewResponseEvent, PreviewMapView, PreviewSession
    global PreviewGeneration, PreviewListInstance, PreviewPanelSession
    if !PreviewResponseEvent || !PreviewMapView {
        SetTimer(PreviewPollResponse, 0)
        return
    }
    response := PreviewTakeResponseSnapshot()
    if IsObject(response) {
        SetTimer(PreviewPollResponse, 0)
        requestId := response.RequestId
        generation := response.Generation
        listInstance := response.ListInstance
        panelSession := response.PanelSession
        if requestId != PreviewSession.RequestId
            return
        if !PreviewGenerationMatches(
                generation, listInstance, panelSession) {
            if PreviewSession.DocumentGeneration {
                PreviewSession.DocumentGeneration := false
                PreviewStopDocumentStatusTimers()
            }
            return
        }
        status := response.Status
        if PreviewSession.DocumentGeneration {
            PreviewFinishDocumentGeneration(status)
            return
        }
        if PreviewSession.CacheCommand {
            PreviewFinishCacheRequest(status = 2)
            return
        }
        if status != 2 {
            if status = 4 && PreviewLooksLikeDocument(PreviewSession.Path) {
                PreviewBeginDocumentGeneration(PreviewSession.Path)
                return
            }
            if PreviewLooksLikeDocument(PreviewSession.Path)
                PreviewShowDocumentError(status)
            else {
                PreviewRememberFailure(PreviewSession.Path, status)
                PreviewSession.State := "Error"
                PreviewPresentFallbackCard(PreviewSession.Path)
            }
            return
        }
        PreviewStopDocumentStatusTimers()
        width := response.Width
        height := response.Height
        stride := response.Stride
        if !IsObject(response.Pixels) {
            PreviewRememberFailure(PreviewSession.Path)
            PreviewHide("invalid-result", false)
            return
        }
        sourceKind := response.SourceKind
        if PreviewPresentPixels(
            width, height, stride, sourceKind, response.Pixels) {
            PreviewSession.State := "Visible"
            PreviewSession.VisiblePath := PreviewSession.Path
            PreviewQueueHoverCache(PreviewSession.Path, sourceKind)
        } else
            PreviewHide("no-space", false)
        return
    }
    if PreviewSession.State = "Loading"
        && ElapsedTickMilliseconds(
            PreviewSession.RequestStarted, A_TickCount)
            >= (PreviewLooksLikeDocument(PreviewSession.Path)
                ? 12000 : 3000) {
        SetTimer(PreviewPollResponse, 0)
        if PreviewSession.CacheCommand {
            PreviewTerminateCacheHelper()
            PreviewFinishCacheRequest(false)
            return
        }
        failedPath := PreviewSession.Path
        PreviewTerminateHungHelper()
        if PreviewLooksLikeDocument(failedPath) {
            PreviewSession.Path := failedPath
            PreviewShowDocumentError(10)
        } else {
            PreviewRememberFailure(failedPath)
            PreviewSession.Path := failedPath
            PreviewSession.State := "Error"
            PreviewPresentFallbackCard(failedPath)
        }
    }
}

PreviewTakeResponseSnapshot() {
    global PreviewResponseEvent, PREVIEW_MAP_BYTES, PREVIEW_PIXEL_OFFSET
    global PREVIEW_MAX_PIXEL_BYTES
    access := PreviewBeginMapAccess()
    try {
        if !IsObject(access)
            return 0
        mapView := access.View
        if !mapView || !PreviewResponseEvent
            return 0
        if DllCall("kernel32\WaitForSingleObject",
            "ptr", PreviewResponseEvent, "uint", 0, "uint") != 0
            return 0
        response := {
            Status: NumGet(mapView, 12, "uint"),
            Generation: NumGet(mapView, 16, "int64"),
            ListInstance: NumGet(mapView, 24, "int64"),
            PanelSession: NumGet(mapView, 32, "int64"),
            RequestId: NumGet(mapView, 40, "int64"),
            Width: NumGet(mapView, 128, "uint"),
            Height: NumGet(mapView, 132, "uint"),
            Stride: NumGet(mapView, 136, "uint"),
            SourceKind: NumGet(mapView, 140, "uint"),
            Pixels: 0
        }
        if response.Status != 2
            return response
        if !PreviewPixelLayoutIsValid(
            response.Width, response.Height, response.Stride)
            return response
        pixelBytes := response.Stride * response.Height
        pixels := Buffer(pixelBytes, 0)
        DllCall("ntdll\RtlMoveMemory", "ptr", pixels.Ptr,
            "ptr", mapView + PREVIEW_PIXEL_OFFSET, "uptr", pixelBytes)
        response.Pixels := pixels
        return response
    } finally PreviewEndMapAccess(access)
}

PreviewPixelLayoutIsValid(width, height, stride) {
    global PREVIEW_MAX_PIXEL_BYTES, PREVIEW_MAP_BYTES, PREVIEW_PIXEL_OFFSET
    if !width || !height || !stride
        return false
    ; Division-first bounds avoid trusting products derived from helper-owned
    ; metadata, even though AutoHotkey uses signed 64-bit integers here.
    if width > Floor(PREVIEW_MAX_PIXEL_BYTES / 4)
        return false
    widthBytes := width * 4
    if stride < widthBytes
        return false
    available := Min(PREVIEW_MAX_PIXEL_BYTES,
        PREVIEW_MAP_BYTES - PREVIEW_PIXEL_OFFSET)
    return height <= Floor(available / stride)
}

PreviewRememberFailure(path, status := 3) {
    global PreviewNegativeCache
    if path = ""
        return
    permanent := status = 5 || status = 6
    retryMs := status = 9 ? 20000
        : (status = 7 ? 30000 : (status = 10 ? 600000 : 60000))
    PreviewNegativeCache[PathKey(path)] := {
        Tick: A_TickCount, RetryMs: retryMs, Permanent: permanent,
        Status: status, Stamp: PreviewFileStamp(path)
    }
}

PreviewBeginDocumentGeneration(path) {
    global PreviewDocumentStatusDelayMs, PreviewDocumentLongStatusMs
    global PreviewDocumentHardTimeoutMs
    if !PreviewSendRequest(3, path) {
        PreviewShowDocumentError(7)
        return
    }
    SetTimer(PreviewShowDocumentStatus, -PreviewDocumentStatusDelayMs)
    SetTimer(PreviewShowDocumentLongStatus, -PreviewDocumentLongStatusMs)
    SetTimer(PreviewDocumentHardTimeout, -PreviewDocumentHardTimeoutMs)
}

PreviewShowDocumentStatus() {
    global PreviewSession
    if PreviewSession.State != "DocumentGenerating"
        && PreviewSession.State != "Loading"
        return
    PreviewSession.StatusKind := "initial"
    PreviewSession.StatusFrame := 0
    PreviewPresentStatusCard(
        "首次预览正在生成…", "完成后将自动缓存", true)
    SetTimer(PreviewDocumentAnimationTick, 350)
}

PreviewShowDocumentLongStatus() {
    global PreviewSession
    if PreviewSession.State != "DocumentGenerating"
        && PreviewSession.State != "Loading"
        return
    PreviewSession.StatusKind := "long"
    PreviewSession.StatusFrame := 0
    PreviewPresentStatusCard(
        "预览生成时间较长", "正在后台处理，稍后再次悬浮可查看", true)
}

PreviewDocumentAnimationTick() {
    global PreviewSession
    if (PreviewSession.State != "DocumentGenerating"
        && PreviewSession.State != "Loading")
        || PreviewSession.StatusKind = "" {
        SetTimer(PreviewDocumentAnimationTick, 0)
        return
    }
    PreviewSession.StatusFrame := Mod(PreviewSession.StatusFrame + 1, 4)
    if PreviewSession.StatusKind = "long"
        PreviewPresentStatusCard(
            "预览生成时间较长",
            "正在后台处理，稍后再次悬浮可查看", true, true)
    else
        PreviewPresentStatusCard(
            "首次预览正在生成…", "完成后将自动缓存", true, true)
}

PreviewDocumentHardTimeout() {
    global PreviewSession
    if !PreviewSession.DocumentGeneration
        return
    failedPath := PreviewSession.Path
    PreviewTerminateHungHelper()
    PreviewRememberFailure(failedPath, 10)
    wasVisibleRequest := PreviewSession.State = "DocumentGenerating"
    PreviewSession.State := wasVisibleRequest ? "Error" : "Hidden"
    PreviewSession.DocumentGeneration := false
    PreviewStopDocumentStatusTimers()
    if wasVisibleRequest
        PreviewPresentStatusCard(
            "暂时无法生成预览", "处理时间超过限制", false)
}

PreviewFinishDocumentGeneration(status) {
    global PreviewSession
    path := PreviewSession.Path
    PreviewSession.DocumentGeneration := false
    PreviewStopDocumentStatusTimers()
    if status = 2 {
        PreviewSendRequest(1, path)
        return
    }
    PreviewShowDocumentError(status)
}

PreviewStopDocumentStatusTimers() {
    global PreviewSession
    SetTimer(PreviewShowDocumentStatus, 0)
    SetTimer(PreviewShowDocumentLongStatus, 0)
    SetTimer(PreviewDocumentAnimationTick, 0)
    SetTimer(PreviewDocumentHardTimeout, 0)
    PreviewSession.StatusKind := ""
}

PreviewShowDocumentError(status) {
    global PreviewSession
    path := PreviewSession.Path
    PreviewStopDocumentStatusTimers()
    PreviewSession.State := "Error"
    PreviewSession.DocumentGeneration := false
    PreviewRememberFailure(path, status)
    if status = 5
        PreviewPresentFallbackCard(path)
    else if status = 6
        PreviewPresentFallbackCard(path)
    else if status = 7
        PreviewPresentFallbackCard(path)
    else if status = 10
        PreviewPresentFallbackCard(path)
    else
        PreviewPresentFallbackCard(path)
}

PreviewTerminateHungHelper() {
    global PreviewHelperPid, PreviewRestartTicks, PreviewSessionDisabled
    if PreviewHelperPid && ProcessExist(PreviewHelperPid)
        try ProcessClose(PreviewHelperPid)
    now := A_TickCount
    kept := []
    for tick in PreviewRestartTicks {
        if ElapsedTickMilliseconds(tick, now) <= 60000
            kept.Push(tick)
    }
    kept.Push(now)
    PreviewRestartTicks := kept
    PreviewCloseHelperObjects(false)
    if kept.Length > 3
        PreviewSessionDisabled := true
}

PreviewTerminateCacheHelper() {
    global PreviewHelperPid
    if PreviewHelperPid && ProcessExist(PreviewHelperPid)
        try ProcessClose(PreviewHelperPid)
    PreviewCloseHelperObjects(false)
}

PreviewPresentStatusCard(line1, line2 := "", animated := false,
    internalOnly := false) {
    global Panel, PreviewSide, PreviewSession, PreviewWidthDip
    global PreviewWindow, PreviewStatusRect
    placement := PreviewStatusRect
    if !internalOnly || !IsObject(placement) {
        panelRect := Buffer(16, 0)
        if !DllCall("user32\GetWindowRect", "ptr", Panel.Hwnd,
            "ptr", panelRect.Ptr)
            return false
        panelLeft := NumGet(panelRect, 0, "int")
        panelTop := NumGet(panelRect, 4, "int")
        panelRight := NumGet(panelRect, 8, "int")
        panelBottom := NumGet(panelRect, 12, "int")
        monitor := DllCall("user32\MonitorFromWindow", "ptr", Panel.Hwnd,
            "uint", 2, "ptr")
        info := Buffer(40, 0)
        NumPut("uint", 40, info, 0)
        if !DllCall("user32\GetMonitorInfoW", "ptr", monitor,
            "ptr", info.Ptr)
            return false
        workLeft := NumGet(info, 20, "int")
        workTop := NumGet(info, 24, "int")
        workRight := NumGet(info, 28, "int")
        workBottom := NumGet(info, 32, "int")
        dpi := DllCall("user32\GetDpiForWindow",
            "ptr", Panel.Hwnd, "uint")
        if !dpi
            dpi := 96
        gap := DllCall("kernel32\MulDiv",
            "int", 4, "int", dpi, "int", 96, "int")
        minWidth := DllCall("kernel32\MulDiv",
            "int", 180, "int", dpi, "int", 96, "int")
        targetWidth := DllCall("kernel32\MulDiv",
            "int", PreviewWidthDip, "int", dpi, "int", 96, "int")
        rightAvailable := workRight - panelRight - gap
        leftAvailable := panelLeft - workLeft - gap
        side := PreviewSession.Side
        if side = "" {
            if PreviewSide = "Right"
                side := "Right"
            else if PreviewSide = "Left"
                side := "Left"
            ; Auto follows the file list's left edge first, minimizing eye travel.
            else if leftAvailable >= minWidth
                side := "Left"
            else if rightAvailable >= minWidth
                side := "Right"
            else
                return false
            PreviewSession.Side := side
        }
        width := Min(targetWidth,
            side = "Right" ? rightAvailable : leftAvailable)
        if width < minWidth
            return false
        height := PreviewSession.StatusKind = "fallback"
            ? Min(panelBottom - panelTop,
                DllCall("kernel32\MulDiv", "int", 360, "int", dpi, "int", 96))
            : Min(panelBottom - panelTop, workBottom - workTop)
        x := side = "Right" ? panelRight + gap
            : panelLeft - gap - width
        y := Max(workTop, Min(panelTop, workBottom - height))
        placement := {X: x, Y: y, Width: width, Height: height, Dpi: dpi}
        PreviewStatusRect := placement
    }
    if !PreviewBuildStatusCanvas(
        placement.Width, placement.Height, placement.Dpi,
        line1, line2, animated)
        return false
    PreviewEnsureWindow()
    if !internalOnly {
        zorder := PreviewIsTopmostMode() ? -1 : -2
        DllCall("user32\SetWindowPos", "ptr", PreviewWindow.Hwnd,
            "ptr", zorder, "int", placement.X, "int", placement.Y,
            "int", placement.Width, "int", placement.Height,
            "uint", 0x0010 | 0x0040)
    }
    DllCall("user32\InvalidateRect", "ptr", PreviewWindow.Hwnd,
        "ptr", 0, "int", 0)
    DllCall("user32\UpdateWindow", "ptr", PreviewWindow.Hwnd)
    return true
}

PreviewPresentFallbackCard(path) {
    global PreviewSession
    PreviewSession.StatusKind := "fallback"
    SplitPath(path, &name)
    return PreviewPresentStatusCard(name, PreviewFormatFileDetails(path), false)
}

PreviewFormatFileDetails(path) {
    size := 0
    try size := FileGetSize(path)
    catch
        size := 0
    if size >= 1024 * 1024
        sizeText := Format("{:.1f} MB", size / 1024 / 1024)
    else
        sizeText := Format("{:.1f} KB", Max(0.1, size / 1024))
    modified := "修改时间不可用"
    try modified := FormatTime(FileGetTime(path, "M"), "yyyy-MM-dd HH:mm")
    return sizeText "    " modified
}

PreviewBuildStatusCanvas(width, height, dpi, line1, line2, animated) {
    global PreviewCanvasDc, PreviewCanvasBitmap, PreviewCanvasOldBitmap
    global PreviewCanvasWidth, PreviewCanvasHeight, PreviewSession
    global PreviewBackgroundColor
    PreviewReleaseCanvas()
    screenDc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    PreviewCanvasDc := DllCall("gdi32\CreateCompatibleDC",
        "ptr", screenDc, "ptr")
    PreviewCanvasBitmap := DllCall("gdi32\CreateCompatibleBitmap",
        "ptr", screenDc, "int", width, "int", height, "ptr")
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !PreviewCanvasDc || !PreviewCanvasBitmap
        return false
    PreviewCanvasOldBitmap := DllCall("gdi32\SelectObject",
        "ptr", PreviewCanvasDc, "ptr", PreviewCanvasBitmap, "ptr")
    PreviewCanvasWidth := width
    PreviewCanvasHeight := height
    rect := Buffer(16, 0)
    NumPut("int", width, rect, 8)
    NumPut("int", height, rect, 12)
    cardBackground := PreviewSession.StatusKind = "fallback"
        ? PreviewBackgroundColor : 0x00F8F8F8
    background := DllCall("gdi32\CreateSolidBrush",
        "uint", cardBackground, "ptr")
    DllCall("user32\FillRect", "ptr", PreviewCanvasDc,
        "ptr", rect.Ptr, "ptr", background)
    DllCall("gdi32\DeleteObject", "ptr", background)
    DllCall("gdi32\SetBkMode", "ptr", PreviewCanvasDc, "int", 1)
    DllCall("gdi32\SetTextColor", "ptr", PreviewCanvasDc,
        "uint", PreviewSession.StatusKind = "fallback" ? 0x00D5D5D5 : 0x003A342F)
    if PreviewSession.StatusKind = "fallback"
        PreviewDrawFallbackIcon(PreviewCanvasDc, width, dpi)
    titleSize := DllCall("kernel32\MulDiv",
        "int", PreviewSession.StatusKind = "fallback" ? 14 : 15,
        "int", dpi, "int", 96, "int")
    bodySize := DllCall("kernel32\MulDiv",
        "int", PreviewSession.StatusKind = "fallback" ? 14 : 12,
        "int", dpi, "int", 96, "int")
    titleFont := DllCall("gdi32\CreateFontW",
        "int", -titleSize, "int", 0, "int", 0, "int", 0,
        "int", 600, "uint", 0, "uint", 0, "uint", 0,
        "uint", 1, "uint", 0, "uint", 0, "uint", 5,
        "uint", 0, "wstr", "Microsoft YaHei UI", "ptr")
    bodyFont := DllCall("gdi32\CreateFontW",
        "int", -bodySize, "int", 0, "int", 0, "int", 0,
        "int", 400, "uint", 0, "uint", 0, "uint", 0,
        "uint", 1, "uint", 0, "uint", 0, "uint", 5,
        "uint", 0, "wstr", "Microsoft YaHei UI", "ptr")
    oldFont := DllCall("gdi32\SelectObject",
        "ptr", PreviewCanvasDc, "ptr", titleFont, "ptr")
    if animated {
        suffixes := ["", " ·", " ··", " ···"]
        line1 .= suffixes[PreviewSession.StatusFrame + 1]
    }
    centerY := Floor(height / 2)
    titleRect := Buffer(16, 0)
    NumPut("int", 20, titleRect, 0)
    titleTop := PreviewSession.StatusKind = "fallback"
        ? DllCall("kernel32\MulDiv", "int", 293, "int", dpi, "int", 96)
        : centerY - 38
    titleBottom := PreviewSession.StatusKind = "fallback"
        ? DllCall("kernel32\MulDiv", "int", 330, "int", dpi, "int", 96)
        : centerY - 8
    NumPut("int", titleTop, titleRect, 4)
    NumPut("int", width - 20, titleRect, 8)
    NumPut("int", titleBottom, titleRect, 12)
    DllCall("user32\DrawTextW", "ptr", PreviewCanvasDc,
        "wstr", line1, "int", -1, "ptr", titleRect.Ptr,
        "uint", PreviewSession.StatusKind = "fallback"
            ? (0x00000001 | 0x00000010 | 0x00000800)
            : (0x00000001 | 0x00000004 | 0x00000800))
    if line2 != "" {
        DllCall("gdi32\SelectObject",
            "ptr", PreviewCanvasDc, "ptr", bodyFont, "ptr")
        DllCall("gdi32\SetTextColor",
            "ptr", PreviewCanvasDc,
            "uint", PreviewSession.StatusKind = "fallback" ? 0x00B3A79E : 0x00706055)
        bodyRect := Buffer(16, 0)
        NumPut("int", 20, bodyRect, 0)
        bodyTop := PreviewSession.StatusKind = "fallback"
            ? DllCall("kernel32\MulDiv", "int", 270, "int", dpi, "int", 96)
            : centerY + 2
        bodyBottom := PreviewSession.StatusKind = "fallback"
            ? DllCall("kernel32\MulDiv", "int", 290, "int", dpi, "int", 96)
            : centerY + 42
        NumPut("int", bodyTop, bodyRect, 4)
        NumPut("int", width - 20, bodyRect, 8)
        NumPut("int", bodyBottom, bodyRect, 12)
        DllCall("user32\DrawTextW", "ptr", PreviewCanvasDc,
            "wstr", line2, "int", -1, "ptr", bodyRect.Ptr,
            "uint", 0x00000001 | 0x00000004 | 0x00000800)
    }
    DllCall("gdi32\SelectObject",
        "ptr", PreviewCanvasDc, "ptr", oldFont)
    DllCall("gdi32\DeleteObject", "ptr", titleFont)
    DllCall("gdi32\DeleteObject", "ptr", bodyFont)
    border := DllCall("gdi32\CreateSolidBrush",
        "uint", 0x00D7D3CD, "ptr")
    DllCall("user32\FrameRect", "ptr", PreviewCanvasDc,
        "ptr", rect.Ptr, "ptr", border)
    DllCall("gdi32\DeleteObject", "ptr", border)
    return true
}

PreviewDrawFallbackIcon(targetDc, width, dpi) {
    global PreviewSession
    info := Buffer(A_PtrSize = 8 ? 696 : 692, 0)
    icon := 0
    flags := 0x000000100 ; SHGFI_ICON + default large icon
    if DllCall("shell32\SHGetFileInfoW", "wstr", PreviewSession.Path,
        "uint", 0, "ptr", info.Ptr, "uint", info.Size, "uint", flags)
        icon := NumGet(info, 0, "ptr")
    if !icon
        return
    size := Min(196, Max(96, Floor(width * 0.55)))
    iconY := DllCall("kernel32\MulDiv", "int", 82, "int", dpi, "int", 96)
    DllCall("user32\DrawIconEx", "ptr", targetDc,
        "int", Floor((width - size) / 2), "int", iconY,
        "ptr", icon, "int", size, "int", size, "uint", 0,
        "ptr", 0, "uint", 3)
    DllCall("user32\DestroyIcon", "ptr", icon)
}

PreviewPresentPixels(sourceWidth, sourceHeight, sourceStride,
    sourceKind := 0, sourcePixels := 0) {
    global Panel, PreviewSide, PreviewSession, PreviewWidthDip
    global PreviewMapView, PREVIEW_PIXEL_OFFSET, PreviewWindow
    global PreviewStatusRect, PreviewShowFileInfo
    panelRect := Buffer(16, 0)
    if !DllCall("user32\GetWindowRect", "ptr", Panel.Hwnd, "ptr", panelRect.Ptr)
        return false
    panelLeft := NumGet(panelRect, 0, "int")
    panelTop := NumGet(panelRect, 4, "int")
    panelRight := NumGet(panelRect, 8, "int")
    panelBottom := NumGet(panelRect, 12, "int")
    monitor := DllCall("user32\MonitorFromWindow", "ptr", Panel.Hwnd,
        "uint", 2, "ptr")
    info := Buffer(40, 0)
    NumPut("uint", 40, info, 0)
    if !DllCall("user32\GetMonitorInfoW", "ptr", monitor, "ptr", info.Ptr)
        return false
    workLeft := NumGet(info, 20, "int")
    workTop := NumGet(info, 24, "int")
    workRight := NumGet(info, 28, "int")
    workBottom := NumGet(info, 32, "int")
    dpi := DllCall("user32\GetDpiForWindow", "ptr", Panel.Hwnd, "uint")
    if !dpi
        dpi := 96
    gap := DllCall("kernel32\MulDiv", "int", 4, "int", dpi, "int", 96, "int")
    minWidth := DllCall("kernel32\MulDiv",
        "int", 180, "int", dpi, "int", 96, "int")
    targetWidth := DllCall("kernel32\MulDiv",
        "int", PreviewWidthDip, "int", dpi, "int", 96, "int")
    rightAvailable := workRight - panelRight - gap
    leftAvailable := panelLeft - workLeft - gap
    side := PreviewSession.Side
    if side = "" {
        if PreviewSide = "Right"
            side := "Right"
        else if PreviewSide = "Left"
            side := "Left"
        ; Keep Auto's left-first preference consistent for image/document output.
        else if leftAvailable >= minWidth
            side := "Left"
        else if rightAvailable >= minWidth
            side := "Right"
        else
            return false
        PreviewSession.Side := side
    }
    available := side = "Right" ? rightAvailable : leftAvailable
    windowWidth := Min(targetWidth, available)
    if windowWidth < minWidth
        return false
    panelHeight := panelBottom - panelTop
    padding := Max(6, DllCall("kernel32\MulDiv",
        "int", 8, "int", dpi, "int", 96, "int"))
    contentMaxWidth := Max(1, windowWidth - padding * 2)
    ; The text block is 112 DIP high, but its first 36 DIP are intentionally
    ; available to the image. This enlarges the preview without moving text.
    infoHeight := PreviewShowFileInfo
        ? DllCall("kernel32\MulDiv", "int", 76, "int", dpi, "int", 96)
        : 0
    contentMaxHeight := Max(1, panelHeight - padding * 2 - infoHeight)
    ; Shell is the last-resort source. Its cached thumbnail can be much
    ; smaller than the useful preview area, so enlarge that fallback to fit.
    scaleLimit := sourceKind = 2 || sourceKind >= 4 ? 1000.0 : 1.0
    scale := Min(scaleLimit, contentMaxWidth / sourceWidth,
        contentMaxHeight / sourceHeight)
    drawWidth := Max(1, Floor(sourceWidth * scale))
    drawHeight := Max(1, Floor(sourceHeight * scale))
    windowHeight := sourceKind >= 4
        ? panelHeight : Min(panelHeight, drawHeight + padding * 2 + infoHeight)
    x := side = "Right" ? panelRight + gap
        : panelLeft - gap - windowWidth
    y := Max(workTop, Min(panelTop, workBottom - windowHeight))
    if !PreviewBuildCanvas(windowWidth, windowHeight, padding,
        drawWidth, drawHeight, sourceWidth, sourceHeight, sourceStride,
        sourcePixels, x, y, dpi)
        return false
    PreviewStatusRect := {X: x, Y: y, Width: windowWidth,
        Height: windowHeight, Dpi: dpi}
    PreviewEnsureWindow()
    zorder := PreviewIsTopmostMode() ? -1 : -2 ; HWND_TOPMOST / NOTOPMOST
    DllCall("user32\SetWindowPos", "ptr", PreviewWindow.Hwnd,
        "ptr", zorder, "int", x, "int", y, "int", windowWidth,
        "int", windowHeight, "uint", 0x0010 | 0x0040) ; NOACTIVATE|SHOWWINDOW
    DllCall("user32\InvalidateRect", "ptr", PreviewWindow.Hwnd,
        "ptr", 0, "int", 0)
    DllCall("user32\UpdateWindow", "ptr", PreviewWindow.Hwnd)
    return true
}

PreviewBuildCanvas(windowWidth, windowHeight, padding, drawWidth, drawHeight,
    sourceWidth, sourceHeight, sourceStride, sourcePixels, screenX, screenY,
    dpi := 96) {
    global PreviewCanvasDc, PreviewCanvasBitmap, PreviewCanvasOldBitmap
    global PreviewCanvasWidth, PreviewCanvasHeight
    global PreviewBackgroundColor, PreviewBackgroundOpacity
    global PreviewShowFileInfo, PreviewSession
    if !IsObject(sourcePixels)
        return false
    canvasDc := 0
    canvasBitmap := 0
    canvasOldBitmap := 0
    sourceDc := 0
    sourceBitmap := 0
    oldSource := 0
    patternDc := 0
    patternBitmap := 0
    patternOldBitmap := 0
    checkerBrush := 0
    lightBrush := 0
    darkBrush := 0
    border := 0
    try {
        screenDc := DllCall("user32\GetDC", "ptr", 0, "ptr")
        canvasDc := DllCall("gdi32\CreateCompatibleDC",
            "ptr", screenDc, "ptr")
        canvasBitmap := DllCall("gdi32\CreateCompatibleBitmap",
            "ptr", screenDc, "int", windowWidth, "int", windowHeight, "ptr")
        DllCall("user32\ReleaseDC", "ptr", 0, "ptr", screenDc)
        if !canvasDc || !canvasBitmap
            return false
        canvasOldBitmap := DllCall("gdi32\SelectObject",
            "ptr", canvasDc, "ptr", canvasBitmap, "ptr")

        ; Prepare the replacement image completely while the old frame stays
        ; visible. Only the final desktop sample and composition occur during
        ; the bounded hidden interval.
        sourceInfo := Buffer(40, 0)
        NumPut("uint", 40, sourceInfo, 0)
        NumPut("int", sourceWidth, sourceInfo, 4)
        NumPut("int", -sourceHeight, sourceInfo, 8)
        NumPut("ushort", 1, sourceInfo, 12)
        NumPut("ushort", 32, sourceInfo, 14)
        NumPut("uint", 0, sourceInfo, 16)
        sourceDc := DllCall("gdi32\CreateCompatibleDC",
            "ptr", canvasDc, "ptr")
        sourceBits := 0
        sourceBitmap := DllCall("gdi32\CreateDIBSection", "ptr", sourceDc,
            "ptr", sourceInfo.Ptr, "uint", 0, "ptr*", &sourceBits,
            "ptr", 0, "uint", 0, "ptr")
        if !sourceBitmap || !sourceBits
            return false
        oldSource := DllCall("gdi32\SelectObject",
            "ptr", sourceDc, "ptr", sourceBitmap, "ptr")
        destinationStride := sourceWidth * 4
        Loop sourceHeight {
            rowOffset := A_Index - 1
            DllCall("ntdll\RtlMoveMemory",
                "ptr", sourceBits + rowOffset * destinationStride,
                "ptr", sourcePixels.Ptr + rowOffset * sourceStride,
                "uptr", destinationStride)
        }

        ; Build one reusable 2x2 checker tile before hiding the old frame.
        ; Filling the image area with a pattern brush is one GDI operation,
        ; replacing thousands of per-cell FillRect calls in the hidden phase.
        tile := Max(6, Floor(padding))
        patternSize := tile * 2
        patternDc := DllCall("gdi32\CreateCompatibleDC",
            "ptr", canvasDc, "ptr")
        patternBitmap := DllCall("gdi32\CreateCompatibleBitmap",
            "ptr", canvasDc, "int", patternSize, "int", patternSize, "ptr")
        if !patternDc || !patternBitmap
            return false
        patternOldBitmap := DllCall("gdi32\SelectObject",
            "ptr", patternDc, "ptr", patternBitmap, "ptr")
        lightBrush := DllCall("gdi32\CreateSolidBrush",
            "uint", 0x00D8D8D8, "ptr")
        darkBrush := DllCall("gdi32\CreateSolidBrush",
            "uint", 0x00B8B8B8, "ptr")
        patternRect := Buffer(16, 0)
        NumPut("int", patternSize, patternRect, 8)
        NumPut("int", patternSize, patternRect, 12)
        DllCall("user32\FillRect", "ptr", patternDc,
            "ptr", patternRect.Ptr, "ptr", lightBrush)
        for cellOrigin in [{X: tile, Y: 0}, {X: 0, Y: tile}] {
            cell := Buffer(16, 0)
            NumPut("int", cellOrigin.X, cell, 0)
            NumPut("int", cellOrigin.Y, cell, 4)
            NumPut("int", cellOrigin.X + tile, cell, 8)
            NumPut("int", cellOrigin.Y + tile, cell, 12)
            DllCall("user32\FillRect", "ptr", patternDc,
                "ptr", cell.Ptr, "ptr", darkBrush)
        }
        checkerBrush := DllCall("gdi32\CreatePatternBrush",
            "ptr", patternBitmap, "ptr")
        if !checkerBrush
            return false

        ; Opaque mode never samples the desktop and therefore never hides the
        ; old preview during a switch. Translucent compatibility mode must
        ; briefly hide it to avoid recursively capturing the preview itself.
        if PreviewBackgroundOpacity < 255
            PreviewHideWindowOnly()
        PreviewPaintConfiguredBackground(canvasDc,
            windowWidth, windowHeight, screenX, screenY,
            PreviewBackgroundColor, PreviewBackgroundOpacity)
        infoHeight := PreviewShowFileInfo
            ? DllCall("kernel32\MulDiv", "int", 76, "int", dpi, "int", 96)
            : 0
        imageAreaHeight := Max(1, windowHeight - padding * 2 - infoHeight)
        imageX := Floor((windowWidth - drawWidth) / 2)
        imageY := padding + Max(0, Floor((imageAreaHeight - drawHeight) / 2))
        imageRect := Buffer(16, 0)
        NumPut("int", imageX, imageRect, 0)
        NumPut("int", imageY, imageRect, 4)
        NumPut("int", imageX + drawWidth, imageRect, 8)
        NumPut("int", imageY + drawHeight, imageRect, 12)
        DllCall("user32\FillRect", "ptr", canvasDc,
            "ptr", imageRect.Ptr, "ptr", checkerBrush)
        blend := Buffer(4, 0)
        NumPut("uchar", 255, blend, 2)
        NumPut("uchar", 1, blend, 3) ; AC_SRC_ALPHA
        DllCall("msimg32\AlphaBlend", "ptr", canvasDc,
            "int", imageX, "int", imageY, "int", drawWidth, "int", drawHeight,
            "ptr", sourceDc, "int", 0, "int", 0,
            "int", sourceWidth, "int", sourceHeight,
            "uint", NumGet(blend, 0, "uint"))
        if PreviewShowFileInfo
            PreviewDrawFileInfo(canvasDc, windowWidth, windowHeight,
                padding, dpi)
        rect := Buffer(16, 0)
        NumPut("int", windowWidth, rect, 8)
        NumPut("int", windowHeight, rect, 12)
        border := DllCall("gdi32\CreateSolidBrush",
            "uint", 0x00505050, "ptr")
        DllCall("user32\FrameRect", "ptr", canvasDc,
            "ptr", rect.Ptr, "ptr", border)

        ; Atomic canvas swap: WM_PAINT sees either the complete old frame or
        ; the complete new frame, never a partially constructed bitmap.
        previousCanvasDc := PreviewCanvasDc
        previousCanvasBitmap := PreviewCanvasBitmap
        previousCanvasOldBitmap := PreviewCanvasOldBitmap
        PreviewCanvasDc := canvasDc
        PreviewCanvasBitmap := canvasBitmap
        PreviewCanvasOldBitmap := canvasOldBitmap
        PreviewCanvasWidth := windowWidth
        PreviewCanvasHeight := windowHeight
        canvasDc := 0
        canvasBitmap := 0
        canvasOldBitmap := 0
        PreviewReleaseCanvasObjects(previousCanvasDc,
            previousCanvasBitmap, previousCanvasOldBitmap)
        return true
    } finally {
        if sourceDc && oldSource
            DllCall("gdi32\SelectObject", "ptr", sourceDc,
                "ptr", oldSource)
        if sourceBitmap
            DllCall("gdi32\DeleteObject", "ptr", sourceBitmap)
        if sourceDc
            DllCall("gdi32\DeleteDC", "ptr", sourceDc)
        if patternDc && patternOldBitmap
            DllCall("gdi32\SelectObject", "ptr", patternDc,
                "ptr", patternOldBitmap)
        if checkerBrush {
            DllCall("gdi32\DeleteObject", "ptr", checkerBrush)
            checkerBrush := 0
        }
        if patternBitmap
            DllCall("gdi32\DeleteObject", "ptr", patternBitmap)
        if patternDc
            DllCall("gdi32\DeleteDC", "ptr", patternDc)
        for object in [checkerBrush, lightBrush, darkBrush, border] {
            if object
                DllCall("gdi32\DeleteObject", "ptr", object)
        }
        if canvasDc && canvasOldBitmap
            DllCall("gdi32\SelectObject", "ptr", canvasDc,
                "ptr", canvasOldBitmap)
        if canvasBitmap
            DllCall("gdi32\DeleteObject", "ptr", canvasBitmap)
        if canvasDc
            DllCall("gdi32\DeleteDC", "ptr", canvasDc)
    }
}

PreviewDrawFileInfo(targetDc, width, height, padding, dpi := 96) {
    global PreviewSession
    path := PreviewSession.Path
    SplitPath(path, &name)
    details := PreviewFormatFileDetails(path)
    infoHeight := DllCall("kernel32\MulDiv",
        "int", 112, "int", dpi, "int", 96)
    barTop := Max(0, height - infoHeight)
    nameFontHeight := DllCall("kernel32\MulDiv",
        "int", 15, "int", dpi, "int", 96)
    detailsFontHeight := DllCall("kernel32\MulDiv",
        "int", 14, "int", dpi, "int", 96)
    nameFont := DllCall("gdi32\CreateFontW", "int", -nameFontHeight,
        "int", 0, "int", 0, "int", 0, "int", 400, "uint", 0,
        "uint", 0, "uint", 0, "uint", 1, "uint", 0, "uint", 0,
        "uint", 0, "uint", 0, "wstr", "Microsoft YaHei UI", "ptr")
    detailsFont := DllCall("gdi32\CreateFontW", "int", -detailsFontHeight,
        "int", 0, "int", 0, "int", 0, "int", 400, "uint", 0,
        "uint", 0, "uint", 0, "uint", 1, "uint", 0, "uint", 0,
        "uint", 0, "uint", 0, "wstr", "Microsoft YaHei UI", "ptr")
    old := DllCall("gdi32\SelectObject", "ptr", targetDc,
        "ptr", nameFont, "ptr")
    DllCall("gdi32\SetTextColor", "ptr", targetDc, "uint", 0x00D5D5D5)
    DllCall("gdi32\SetBkMode", "ptr", targetDc, "int", 1)
    rect := Buffer(16, 0)
    NumPut("int", padding, rect, 0)
    topInset := DllCall("kernel32\MulDiv", "int", 60, "int", dpi, "int", 96)
    nameBottom := DllCall("kernel32\MulDiv", "int", 112, "int", dpi, "int", 96)
    detailsTop := DllCall("kernel32\MulDiv", "int", 36, "int", dpi, "int", 96)
    detailsBottom := DllCall("kernel32\MulDiv", "int", 58, "int", dpi, "int", 96)
    NumPut("int", barTop + topInset, rect, 4)
    NumPut("int", width - padding, rect, 8)
    NumPut("int", barTop + nameBottom, rect, 12)
    DllCall("user32\DrawTextW", "ptr", targetDc, "wstr", name,
        "int", -1, "ptr", rect.Ptr, "uint", 0x00000001 | 0x00000010 | 0x00000800)
    DllCall("gdi32\SelectObject", "ptr", targetDc,
        "ptr", detailsFont, "ptr")
    DllCall("gdi32\SetTextColor", "ptr", targetDc, "uint", 0x00B3A79E)
    NumPut("int", barTop + detailsTop, rect, 4)
    NumPut("int", barTop + detailsBottom, rect, 12)
    DllCall("user32\DrawTextW", "ptr", targetDc, "wstr", details,
        "int", -1, "ptr", rect.Ptr, "uint", 0x00000001 | 0x00000010 | 0x00000800)
    DllCall("gdi32\SelectObject", "ptr", targetDc, "ptr", old, "ptr")
    DllCall("gdi32\DeleteObject", "ptr", nameFont)
    DllCall("gdi32\DeleteObject", "ptr", detailsFont)
}

PreviewPaintConfiguredBackground(targetDc, width, height,
    screenX, screenY, color, opacity) {
    rect := Buffer(16, 0)
    NumPut("int", width, rect, 8)
    NumPut("int", height, rect, 12)
    fallbackBrush := DllCall("gdi32\CreateSolidBrush",
        "uint", color, "ptr")
    DllCall("user32\FillRect", "ptr", targetDc,
        "ptr", rect.Ptr, "ptr", fallbackBrush)
    DllCall("gdi32\DeleteObject", "ptr", fallbackBrush)
    if opacity >= 255
        return

    screenDc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    if screenDc {
        DllCall("gdi32\BitBlt", "ptr", targetDc,
            "int", 0, "int", 0, "int", width, "int", height,
            "ptr", screenDc, "int", screenX, "int", screenY,
            "uint", 0x40CC0020, "int") ; SRCCOPY | CAPTUREBLT
        DllCall("user32\ReleaseDC", "ptr", 0, "ptr", screenDc)
    }

    shadeDc := DllCall("gdi32\CreateCompatibleDC",
        "ptr", targetDc, "ptr")
    shadeBitmap := shadeDc
        ? DllCall("gdi32\CreateCompatibleBitmap", "ptr", targetDc,
            "int", 1, "int", 1, "ptr") : 0
    if !shadeDc || !shadeBitmap {
        if shadeBitmap
            DllCall("gdi32\DeleteObject", "ptr", shadeBitmap)
        if shadeDc
            DllCall("gdi32\DeleteDC", "ptr", shadeDc)
        return
    }
    oldShade := DllCall("gdi32\SelectObject", "ptr", shadeDc,
        "ptr", shadeBitmap, "ptr")
    pixelRect := Buffer(16, 0)
    NumPut("int", 1, pixelRect, 8)
    NumPut("int", 1, pixelRect, 12)
    shadeBrush := DllCall("gdi32\CreateSolidBrush",
        "uint", color, "ptr")
    DllCall("user32\FillRect", "ptr", shadeDc,
        "ptr", pixelRect.Ptr, "ptr", shadeBrush)
    DllCall("gdi32\DeleteObject", "ptr", shadeBrush)
    blend := Buffer(4, 0)
    NumPut("uchar", Max(0, Min(255, opacity)), blend, 2)
    DllCall("msimg32\AlphaBlend", "ptr", targetDc,
        "int", 0, "int", 0, "int", width, "int", height,
        "ptr", shadeDc, "int", 0, "int", 0, "int", 1, "int", 1,
        "uint", NumGet(blend, 0, "uint"), "int")
    DllCall("gdi32\SelectObject", "ptr", shadeDc,
        "ptr", oldShade, "ptr")
    DllCall("gdi32\DeleteObject", "ptr", shadeBitmap)
    DllCall("gdi32\DeleteDC", "ptr", shadeDc)
}

PreviewEnsureWindow() {
    global PreviewWindow, Panel
    if IsObject(PreviewWindow)
        return
    ; WS_EX_TOOLWINDOW is supplied by +ToolWindow. 0x08000000 is
    ; WS_EX_NOACTIVATE, so the preview cannot take keyboard focus.
    PreviewWindow := Gui("-Caption +ToolWindow +Owner" Panel.Hwnd
        . " +E0x08000000", "PopDrop Preview")
    PreviewWindow.MarginX := 0
    PreviewWindow.MarginY := 0
    OnMessage(0x000F, PreviewWindowPaint) ; WM_PAINT
    PreviewApplyWindowMode()
}

PreviewWindowPaint(wParam, lParam, msg, hwnd) {
    global PreviewWindow, PreviewCanvasDc
    global PreviewCanvasWidth, PreviewCanvasHeight
    if !IsObject(PreviewWindow) || hwnd != PreviewWindow.Hwnd
        return
    paint := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    hdc := DllCall("user32\BeginPaint", "ptr", hwnd,
        "ptr", paint.Ptr, "ptr")
    if hdc && PreviewCanvasDc
        DllCall("gdi32\BitBlt", "ptr", hdc, "int", 0, "int", 0,
            "int", PreviewCanvasWidth, "int", PreviewCanvasHeight,
            "ptr", PreviewCanvasDc, "int", 0, "int", 0, "uint", 0x00CC0020)
    DllCall("user32\EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    return 0
}

PreviewIsTopmostMode() {
    global WindowMode, WINDOW_MODE_NORMAL
    return WindowMode != WINDOW_MODE_NORMAL
}

PreviewApplyWindowMode() {
    global PreviewWindow
    if !IsObject(PreviewWindow)
        return
    zorder := PreviewIsTopmostMode() ? -1 : -2
    ; SWP_NOACTIVATE keeps z-order changes from activating the tool window.
    DllCall("user32\SetWindowPos", "ptr", PreviewWindow.Hwnd,
        "ptr", zorder, "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", 0x0001 | 0x0002 | 0x0010) ; NOSIZE|NOMOVE|NOACTIVATE
}

PreviewHideWindowOnly() {
    global PreviewWindow
    if IsObject(PreviewWindow)
        DllCall("user32\ShowWindow", "ptr", PreviewWindow.Hwnd, "int", 0)
}

PreviewReleaseCanvas() {
    global PreviewCanvasDc, PreviewCanvasBitmap, PreviewCanvasOldBitmap
    global PreviewCanvasWidth, PreviewCanvasHeight
    PreviewReleaseCanvasObjects(PreviewCanvasDc,
        PreviewCanvasBitmap, PreviewCanvasOldBitmap)
    PreviewCanvasDc := 0
    PreviewCanvasBitmap := 0
    PreviewCanvasOldBitmap := 0
    PreviewCanvasWidth := 0
    PreviewCanvasHeight := 0
}

PreviewReleaseCanvasObjects(canvasDc, canvasBitmap, oldBitmap) {
    if canvasDc && oldBitmap
        DllCall("gdi32\SelectObject", "ptr", canvasDc,
            "ptr", oldBitmap)
    if canvasBitmap
        DllCall("gdi32\DeleteObject", "ptr", canvasBitmap)
    if canvasDc
        DllCall("gdi32\DeleteDC", "ptr", canvasDc)
}

PreviewQueueHoverCache(path, sourceKind) {
    global PreviewHoverCacheQueue
    ; 1=image cache, 4=text already cached by the foreground worker,
    ; 6=document cache. Only uncached original/Shell results need the
    ; low-priority hidden-session snapshot pass.
    if sourceKind != 2 && sourceKind != 3 && sourceKind != 5
        return
    if !PreviewLooksLikeImage(path) && !PreviewLooksLikeDocument(path)
        return
    if !ArrayContainsPath(PreviewHoverCacheQueue, path)
        PreviewHoverCacheQueue.Push(path)
}

PreviewLooksLikeImage(path) {
    SplitPath(path, , , &extension)
    return InStr("|jpg|jpeg|jpe|png|gif|bmp|dib|tif|tiff|webp|heic|heif|avif|"
        . "ico|dng|cr2|cr3|nef|arw|rw2|orf|raf|", "|"
        . StrLower(extension) "|")
}

PreviewBeginCachePass() {
    global PanelVisible, PreviewEnabled, PreviewCacheEnabled
    global PreviewCacheActive
    if PanelVisible || !PreviewEnabled || !PreviewCacheEnabled
        return
    ; The helper already runs at IDLE priority and serializes its work. Do not
    ; let a long scan/transfer keep an entire hidden session cache-free.
    PreviewCacheActive := true
    PreviewWriteCacheStatus("Started")
    PreviewSendNextCacheRequest()
}

PreviewHasActiveTransfer() {
    global TransferBatches
    for id, batch in TransferBatches {
        if !batch.Completed
            return true
    }
    return false
}

PreviewSendNextCacheRequest() {
    global PreviewCacheActive, PreviewCacheCompletedThisHiddenSession
    global PreviewCacheSucceededThisHiddenSession
    global PreviewHoverCacheQueue
    global PanelVisible, PreviewGeneration
    if !PreviewCacheActive || PanelVisible
        return
    if PreviewCacheSucceededThisHiddenSession >= 50
        || PreviewCacheCompletedThisHiddenSession >= 100 {
        PreviewCacheActive := false
        PreviewWriteCacheStatus("LimitReached")
        return
    }
    path := ""
    while PreviewHoverCacheQueue.Length && path = ""
        path := PreviewHoverCacheQueue.RemoveAt(1)
    if path = "" {
        PreviewCacheActive := false
        PreviewWriteCacheStatus("Completed")
        return
    }
    PreviewGeneration += 1
    PreviewWriteCacheStatus("Requesting", path)
    if !PreviewSendRequest(2, path)
        PreviewFinishCacheRequest(false)
}

PreviewFinishCacheRequest(success) {
    global PreviewSession, PreviewCacheCompletedThisHiddenSession
    global PreviewCacheSucceededThisHiddenSession
    global PreviewCacheFailedThisHiddenSession
    PreviewSession.CacheCommand := false
    PreviewSession.State := "Hidden"
    PreviewCacheCompletedThisHiddenSession += 1
    if success
        PreviewCacheSucceededThisHiddenSession += 1
    else
        PreviewCacheFailedThisHiddenSession += 1
    PreviewWriteCacheStatus(success ? "ItemSucceeded" : "ItemFailed",
        PreviewSession.Path)
    SetTimer(PreviewSendNextCacheRequest, -200)
}

PreviewWriteCacheStatus(stage, path := "") {
    global CacheDir, PreviewHoverCacheQueue
    global PreviewCacheCompletedThisHiddenSession
    global PreviewCacheSucceededThisHiddenSession
    global PreviewCacheFailedThisHiddenSession
    try {
        root := CacheDir "\preview-cache-v1"
        if !DirExist(root)
            DirCreate(root)
        statusPath := root "\cache-status.ini"
        IniWrite(A_Now, statusPath, "Cache", "Updated")
        IniWrite(stage, statusPath, "Cache", "Stage")
        IniWrite(PreviewHoverCacheQueue.Length, statusPath,
            "Cache", "HoverQueueRemaining")
        IniWrite(0, statusPath, "Cache", "VisibleQueueRemaining")
        IniWrite(PreviewCacheCompletedThisHiddenSession, statusPath,
            "Cache", "Attempted")
        IniWrite(PreviewCacheSucceededThisHiddenSession, statusPath,
            "Cache", "Succeeded")
        IniWrite(PreviewCacheFailedThisHiddenSession, statusPath,
            "Cache", "Failed")
        if path != ""
            IniWrite(path, statusPath, "Cache", "LastPath")
    }
}

PreviewCancelCacheHard(requestId) {
    global PreviewSession
    if PreviewSession.RequestId = requestId
        PreviewTerminateCacheHelper()
}

PreviewCloseHelperObjects(signalShutdown := true) {
    global PreviewMapHandle, PreviewMapView, PreviewRequestEvent
    global PreviewResponseEvent, PreviewShutdownEvent, PreviewHelperPid
    global PreviewJobHandle, PreviewMapAccessDepth
    global PreviewHelperClosePending, PreviewHelperCloseRunning
    if PreviewMapAccessDepth > 0 || PreviewHelperCloseRunning {
        PreviewHelperClosePending := Max(PreviewHelperClosePending,
            signalShutdown ? 2 : 1)
        return
    }
    PreviewHelperCloseRunning := true
    ; Publish the detached state before any Win32 cleanup. Re-entrant mouse
    ; messages can no longer begin an access to handles being destroyed.
    mapView := PreviewMapView
    requestEvent := PreviewRequestEvent
    responseEvent := PreviewResponseEvent
    shutdownEvent := PreviewShutdownEvent
    mapHandle := PreviewMapHandle
    jobHandle := PreviewJobHandle
    helperPid := PreviewHelperPid
    PreviewMapHandle := 0
    PreviewMapView := 0
    PreviewRequestEvent := 0
    PreviewResponseEvent := 0
    PreviewShutdownEvent := 0
    PreviewHelperPid := 0
    PreviewJobHandle := 0
    if signalShutdown && shutdownEvent
        DllCall("kernel32\SetEvent", "ptr", shutdownEvent)
    if signalShutdown && helperPid {
        process := DllCall("kernel32\OpenProcess",
            "uint", 0x00100000, "int", 0, "uint", helperPid, "ptr")
        if process {
            DllCall("kernel32\WaitForSingleObject",
                "ptr", process, "uint", 300, "uint")
            DllCall("kernel32\CloseHandle", "ptr", process)
        }
    }
    if mapView
        DllCall("kernel32\UnmapViewOfFile", "ptr", mapView)
    for handle in [requestEvent, responseEvent,
        shutdownEvent, mapHandle, jobHandle] {
        if handle
            DllCall("kernel32\CloseHandle", "ptr", handle)
    }
    PreviewHelperCloseRunning := false
    pending := PreviewHelperClosePending
    PreviewHelperClosePending := 0
    if pending
        SetTimer(PreviewCloseHelperObjects.Bind(pending = 2), -1)
}

PreviewBeginMapAccess() {
    global PreviewMapAccessDepth, PreviewMapView
    if PreviewMapAccessDepth > 0
        return 0
    previousCritical := A_IsCritical
    Critical("On")
    PreviewMapAccessDepth := 1
    return {View: PreviewMapView,
        PreviousCritical: previousCritical, Active: true}
}

PreviewEndMapAccess(access) {
    global PreviewMapAccessDepth, PreviewHelperClosePending
    if !IsObject(access) || !access.Active
        return
    access.Active := false
    PreviewMapAccessDepth := 0
    previousCritical := access.PreviousCritical
    Critical(previousCritical)
    if PreviewMapAccessDepth || !PreviewHelperClosePending
        return
    pending := PreviewHelperClosePending
    PreviewHelperClosePending := 0
    SetTimer(PreviewCloseHelperObjects.Bind(pending = 2), -1)
}

CleanupPreview() {
    global PreviewWindow
    SetTimer(PreviewPollResponse, 0)
    SetTimer(PreviewBeginCachePass, 0)
    SetTimer(PreviewSendNextCacheRequest, 0)
    PreviewHideWindowOnly()
    PreviewReleaseCanvas()
    if IsObject(PreviewWindow)
        try PreviewWindow.Destroy()
    PreviewWindow := 0
    PreviewCloseHelperObjects(true)
}

RunPreviewSelfTests() {
    global PreviewGeneration, PreviewListInstance, PreviewPanelSession
    AssertSelfTest(PreviewCandidateDelay(false, "mouse") = 350,
        "预览首次悬浮默认 350ms")
    AssertSelfTest(PreviewCandidateDelay(true, "mouse") = 120,
        "预览切换默认 120ms")
    AssertSelfTest(PreviewCandidateDelay(false, "keyboard") = 250,
        "预览键盘默认 250ms")
    AssertSelfTest(PreviewColorRefFromText("#112233", -1) = 0x00332211,
        "预览背景 RGB 正确转换为 GDI COLORREF")
    AssertSelfTest(PreviewColorRefFromText("112233", -1) = -1,
        "预览背景颜色拒绝无 # 的格式")
    AssertSelfTest(PreviewLooksLikeImage("C:\Temp\photo.JPEG"),
        "图片候选扩展名大小写不敏感")
    AssertSelfTest(!PreviewLooksLikeImage("C:\Temp\document.pdf"),
        "非图片不进入原图缓存生成队列")
    AssertSelfTest(PreviewIsSupportedDocumentPath("C:\Temp\readme.MD"),
        "Markdown 文档候选扩展名大小写不敏感")
    AssertSelfTest(PreviewIsSupportedDocumentPath("C:\Temp\report.pdf"),
        "PDF 文档候选被集中扩展名表识别")
    AssertSelfTest(PreviewIsSupportedDocumentPath("C:\Temp\report.docx"),
        "DOCX 文档候选被集中扩展名表识别")
    AssertSelfTest(!PreviewIsSupportedDocumentPath("C:\Temp\sheet.xlsx"),
        "本版本不把 XLSX 交给自研悬浮预览")
    generation := PreviewGeneration
    listInstance := PreviewListInstance
    panelSession := PreviewPanelSession
    AssertSelfTest(PreviewGenerationMatches(
        generation, listInstance, panelSession),
        "预览三重会话身份匹配")
    AssertSelfTest(!PreviewGenerationMatches(
        generation + 1, listInstance, panelSession),
        "旧 Generation 失效")
    AssertSelfTest(!PreviewGenerationMatches(
        generation, listInstance + 1, panelSession),
        "旧列表实例失效")
    AssertSelfTest(!PreviewGenerationMatches(
        generation, listInstance, panelSession + 1),
        "旧面板显示会话失效")
    AssertSelfTest(PreviewPixelLayoutIsValid(320, 200, 1280),
        "紧密 32 位预览像素布局有效")
    AssertSelfTest(PreviewPixelLayoutIsValid(319, 200, 1280),
        "带来源行填充的预览像素布局有效")
    AssertSelfTest(!PreviewPixelLayoutIsValid(320, 200, 1279),
        "短于可见像素宽度的来源行被拒绝")
    AssertSelfTest(!PreviewPixelLayoutIsValid(65535, 65535, 262140),
        "超过共享映射容量的预览布局被拒绝")
}
