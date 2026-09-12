#Requires AutoHotkey v2.0
; Foreground-document resolver for the "固定前台文件" toolbar action.
;
; This file is deliberately self-contained: it references no PopDrop panel,
; configuration or workspace function, so it can be included by PopDrop.ahk
; and by tools\ForegroundFileProbe.ahk alike. AutoHotkey v2 syntax only.
;
; Why not a resident ETW consumer or minifilter: both can log which process
; opened which path, but neither can tell which document the frontmost app is
; editing right now, and both need elevation or a driver. PopDrop runs without
; elevation, so the document is resolved on demand, at click time, from the
; target application's own state, strongest evidence first:
;
;   1. Office / WPS automation object model, cross-checked with the title.
;   2. A rooted path shown in the window title (Notepad++, Sublime, ...).
;   3. The target process command line whose file name matches the title.
;      This is especially useful for WPS, which commonly releases the source
;      file handle after loading the document and does not always publish its
;      automation object in the Running Object Table.
;   4. Open file handles of the target process whose name matches the title.
;      Enumerated in a separate child process so a handle that blocks inside
;      a kernel query can only stall that child, never this resolver.
;   5. WPS's per-user recent-document registry, with a unique title match.
;   6. A Windows Recent shortcut whose target name matches the title.
;   7. UI Automation: edit fields holding a file path or file:// URL
;      (browser/viewer address fields). Bounded by a time and element budget.
;   8. Only when the title names no file at all: the process's open
;      document handle, and only if exactly one qualifies.

; ──── Child-process entry points ────

RunForegroundFileWorkerMode(targetHwndText, resultPath) {
    payload := ""
    initialized := DllCall("ole32\CoInitializeEx", "ptr", 0,
        "uint", 0x2, "int") >= 0 ; COINIT_APARTMENTTHREADED
    try {
        targetHwnd := 0
        try targetHwnd := Integer(targetHwndText)
        payload := SerializeForegroundFileResult(
            ResolveForegroundEditingFile(targetHwnd))
    } catch as err {
        payload := SerializeForegroundFileResult(ForegroundFileResultRecord(
            "error", "", "", "", "", ForegroundFileShortError(err), ""))
    } finally {
        ForegroundWriteTextAtomically(resultPath, payload)
        if initialized
            DllCall("ole32\CoUninitialize")
    }
    return payload != ""
}

; Writes one path per line as soon as it is found. If a later handle blocks
; and the parent terminates this process, every earlier line is preserved.
RunForegroundHandleWorkerMode(processIdText, outputPath) {
    processId := 0
    try processId := Integer(processIdText)
    try FileDelete(outputPath)
    try FileAppend("", outputPath, "UTF-8-RAW")
    if processId {
        try ForegroundEnumerateProcessFilePaths(processId,
            ForegroundAppendHandlePath.Bind(outputPath))
    }
    try FileAppend("#done`n", outputPath, "UTF-8-RAW")
}

ForegroundAppendHandlePath(outputPath, path) {
    FileAppend(path "`n", outputPath, "UTF-8-RAW")
}

ForegroundWriteTextAtomically(targetPath, text) {
    writingPath := targetPath ".writing"
    try {
        try FileDelete(writingPath)
        outputFile := FileOpen(writingPath, "w", "UTF-8-RAW")
        if !IsObject(outputFile)
            return false
        outputFile.Write(text)
        outputFile.Close()
        FileMove(writingPath, targetPath, 1)
        return true
    } catch {
        try FileDelete(writingPath)
        return false
    }
}

; ──── Result record (line-oriented, no JSON dependency) ────

ForegroundFileResultRecord(status, path, method, processName, title,
    message, trace) {
    return {Status: status, Path: path, Method: method,
        Process: processName, Title: title, Message: message, Trace: trace}
}

SerializeForegroundFileResult(result) {
    text := ""
    for fieldName in ["Status", "Path", "Method", "Process", "Title",
        "Message", "Trace"] {
        fieldValue := result.HasProp(fieldName) ? result.%fieldName% : ""
        text .= fieldName "=" ForegroundFileEscapeField(fieldValue) "`n"
    }
    return text
}

ForegroundFileEscapeField(fieldValue) {
    fieldValue := fieldValue ""
    fieldValue := StrReplace(fieldValue, "`r", " ")
    return StrReplace(fieldValue, "`n", " ")
}

ParseForegroundFileResult(text) {
    result := ForegroundFileResultRecord("", "", "", "", "", "", "")
    for line in StrSplit(text, "`n", "`r") {
        separator := InStr(line, "=")
        if !separator
            continue
        fieldName := SubStr(line, 1, separator - 1)
        if result.HasProp(fieldName)
            result.%fieldName% := SubStr(line, separator + 1)
    }
    return result
}

ForegroundFileShortError(err) {
    try {
        message := err.Message ""
        return StrLen(message) > 200 ? SubStr(message, 1, 200) : message
    } catch {
        return "未知错误"
    }
}

; ──── Resolver ────

ResolveForegroundEditingFile(targetHwnd) {
    trace := []
    hwnd := ForegroundResolveTopLevelWindow(targetHwnd)
    if !hwnd {
        return ForegroundFileResultRecord("no-window", "", "", "", "",
            "未能确定前台窗口。", "")
    }

    title := ForegroundWindowTitle(hwnd)
    processId := ForegroundWindowProcessId(hwnd)
    processName := ForegroundWindowProcessName(hwnd)
    ; UWP apps are framed by ApplicationFrameHost; the document belongs to
    ; the hosted CoreWindow process.
    if processName = "applicationframehost.exe" {
        hostedHwnd := ForegroundFindHostedAppWindow(hwnd, processId)
        if hostedHwnd {
            processId := ForegroundWindowProcessId(hostedHwnd)
            processName := ForegroundWindowProcessName(hostedHwnd)
            trace.Push("uwp-host=" processName)
        }
    }

    if ForegroundProcessIsIneligible(processName) {
        return ForegroundFileResultRecord("unsupported", "", "",
            processName, title, "前台窗口不是可识别的文档编辑器。",
            ForegroundJoinTrace(trace))
    }

    segments := ForegroundTitleSegments(title)

    ; 1) Office / WPS object model.
    office := ForegroundResolveViaOffice(processName, segments)
    trace.Push("office=" (office.Path != "" ? "hit"
        : office.Unsaved ? "unsaved" : office.Tried ? "miss" : "skip"))
    if ForegroundPathIsUsable(office.Path) {
        return ForegroundFileResultRecord("ok", office.Path, office.Method,
            processName, title, "", ForegroundJoinTrace(trace))
    }
    ; The title's document is a new, never-saved one. Any other strategy
    ; could only find a different open file, so stop here.
    if office.Unsaved {
        return ForegroundFileResultRecord("unsaved", "", office.Method,
            processName, title, "前台文档尚未保存到磁盘，没有可固定的路径。",
            ForegroundJoinTrace(trace))
    }
    ; A cloud document (OneDrive/SharePoint URL) still tells us its name.
    if office.HintName != "" && !ForegroundArrayHasText(segments,
        office.HintName)
        segments.InsertAt(1, office.HintName)

    ; 2) Rooted path shown in the title.
    titlePath := ForegroundFindRootedPathInTitle(title)
    trace.Push("title-path=" (titlePath != "" ? "hit" : "miss"))
    if titlePath != "" {
        return ForegroundFileResultRecord("ok", titlePath, "window-title",
            processName, title, "", ForegroundJoinTrace(trace))
    }

    ; 3) File arguments retained in the process command line. WPS frequently
    ;    keeps this evidence after it has released the source file handle.
    commandPaths := ForegroundCommandLineFilePaths(processId)
    trace.Push("command-line=" commandPaths.Length)
    commandPath := ForegroundUniqueTitleMatch(commandPaths, segments)
    if commandPath != "" {
        return ForegroundFileResultRecord("ok", commandPath,
            "process-command-line", processName, title, "",
            ForegroundJoinTrace(trace))
    }

    ; 4) Open handles whose file name matches the title.
    handlePaths := ForegroundCollectHandlePaths(processId, 3000)
    trace.Push("handles=" handlePaths.Length)
    matchedHandle := ForegroundBestTitleMatch(handlePaths, segments)
    if matchedHandle != "" {
        return ForegroundFileResultRecord("ok", matchedHandle,
            "open-handle", processName, title, "",
            ForegroundJoinTrace(trace))
    }

    ; 5) WPS keeps a per-user MRU even on installations where its automation
    ;    object is unavailable and Windows Recent is updated only on close.
    ;    Accept only one distinct matching path: two same-named documents in
    ;    different folders are deliberately treated as ambiguous.
    if ForegroundProcessIsWps(processName) {
        wpsRecentPath := ForegroundResolveViaWpsRecent(
            segments, A_TickCount + 1200)
        trace.Push("wps-recent=" (wpsRecentPath != "" ? "hit" : "miss"))
        if wpsRecentPath != "" {
            return ForegroundFileResultRecord("ok", wpsRecentPath,
                "wps-recent", processName, title, "",
                ForegroundJoinTrace(trace))
        }
    }

    ; 6) Recent shortcut with the same file name.
    recentPath := ForegroundResolveViaRecent(segments)
    trace.Push("recent=" (recentPath != "" ? "hit" : "miss"))
    if recentPath != "" {
        return ForegroundFileResultRecord("ok", recentPath, "recent-match",
            processName, title, "", ForegroundJoinTrace(trace))
    }

    ; 7) UI Automation edit fields.
    uiaPath := ForegroundResolveViaUia(hwnd, A_TickCount + 2500)
    trace.Push("uia=" (uiaPath != "" ? "hit" : "miss"))
    if uiaPath != "" {
        return ForegroundFileResultRecord("ok", uiaPath, "uia-value",
            processName, title, "", ForegroundJoinTrace(trace))
    }

    ; 8) Only when the title names no file: accept the process's open
    ;    document handle if exactly one qualifies. With several candidates,
    ;    or when the title names a file we could not match, any choice
    ;    would be a guess and could pin the wrong document.
    if !ForegroundSegmentsNameAFile(segments) {
        candidates := ForegroundDocumentHandleCandidates(handlePaths)
        trace.Push("unique-handle=" candidates.Length)
        if candidates.Length = 1 {
            return ForegroundFileResultRecord("ok", candidates[1],
                "open-handle-unique", processName, title, "",
                ForegroundJoinTrace(trace))
        }
    }

    return ForegroundFileResultRecord("not-found", "", "", processName,
        title, "未能可靠识别前台程序正在编辑的文件。",
        ForegroundJoinTrace(trace))
}

ForegroundJoinTrace(trace) {
    text := ""
    for entry in trace
        text .= (text = "" ? "" : "; ") entry
    return text
}

ForegroundArrayHasText(values, needle) {
    for candidate in values {
        if StrLower(candidate) = StrLower(needle)
            return true
    }
    return false
}

; ──── Window helpers ────

ForegroundResolveTopLevelWindow(targetHwnd) {
    hwnd := 0
    if targetHwnd && DllCall("user32\IsWindow", "ptr", targetHwnd, "int")
        hwnd := targetHwnd
    else
        hwnd := DllCall("user32\GetForegroundWindow", "ptr")
    if !hwnd
        return 0
    root := DllCall("user32\GetAncestor", "ptr", hwnd, "uint", 2, "ptr")
    return root ? root : hwnd ; GA_ROOT
}

ForegroundWindowTitle(hwnd) {
    try return WinGetTitle("ahk_id " hwnd)
    catch
        return ""
}

ForegroundWindowProcessId(hwnd) {
    processId := 0
    DllCall("user32\GetWindowThreadProcessId", "ptr", hwnd,
        "uint*", &processId, "uint")
    return processId
}

ForegroundWindowProcessName(hwnd) {
    try return StrLower(WinGetProcessName("ahk_id " hwnd))
    catch
        return ""
}

ForegroundFindHostedAppWindow(frameHwnd, frameProcessId) {
    childWindows := []
    try childWindows := WinGetControlsHwnd("ahk_id " frameHwnd)
    catch
        return 0
    for childHwnd in childWindows {
        childProcessId := ForegroundWindowProcessId(childHwnd)
        if childProcessId && childProcessId != frameProcessId
            return childHwnd
    }
    return 0
}

ForegroundProcessIsIneligible(processName) {
    static blocked := Map(
        "explorer.exe", true, "searchhost.exe", true,
        "searchapp.exe", true, "shellexperiencehost.exe", true,
        "startmenuexperiencehost.exe", true, "dwm.exe", true,
        "sihost.exe", true, "textinputhost.exe", true, "lockapp.exe", true,
        "applicationframehost.exe", true)
    if processName = ""
        return false
    ; PopDrop's own windows and workers must never become the target.
    if InStr(processName, "popdrop")
        return true
    if A_IsCompiled {
        SplitPath(A_ScriptFullPath, &ownFileName)
        if ownFileName != "" && processName = StrLower(ownFileName)
            return true
    }
    return blocked.Has(processName)
}

; ──── Path helpers ────

; Usable: an existing local file (not a directory), or a UNC / mapped network
; path that the evidence source reported directly. Network paths are not
; probed because an offline share can block for many seconds.
ForegroundPathIsUsable(path) {
    path := Trim(path "")
    if path = "" || StrLen(path) > 32767
        return false
    if !RegExMatch(path, "i)^(?:[A-Z]:\\|\\\\[^\\?.])")
        return false
    attributes := ""
    try attributes := FileExist(path)
    catch
        return false
    return attributes != "" && !InStr(attributes, "D")
}

ForegroundIsRemotePath(path) {
    if SubStr(path, 1, 2) = "\\"
        return true
    if RegExMatch(path, "i)^[A-Z]:\\") {
        driveRoot := SubStr(path, 1, 3) ; e.g. C:\  (single backslash in v2)
        driveKind := DllCall("kernel32\GetDriveTypeW", "wstr", driveRoot,
            "uint")
        return driveKind = 4 ; DRIVE_REMOTE
    }
    return false
}

; Accept a rooted Windows path (with \ or /) or a file:// URL, and return a
; conventional backslash path. Anything else, or anything implausibly long
; (for example an edit control's whole document text), yields "".
ForegroundNormalizeCandidatePath(candidate) {
    candidate := Trim(candidate "", " `t`r`n`"")
    if candidate = "" || StrLen(candidate) > 1024
        return ""
    if InStr(candidate, "`n")
        return ""
    if RegExMatch(candidate, "i)^file:")
        return ForegroundDecodeFileUrl(candidate)
    if RegExMatch(candidate, "i)^[A-Z]:[\\/]")
        return StrReplace(candidate, "/", "\")
    if RegExMatch(candidate, "^\\\\[^\\?.]")
        return candidate
    return ""
}

; file:///C:/dir/a%20b.docx  ->  C:\dir\a b.docx
; file://server/share/x.pdf  ->  \\server\share\x.pdf
ForegroundDecodeFileUrl(url) {
    if !RegExMatch(url, "i)^file:(/*)(.*)$", &urlMatch)
        return ""
    slashCount := StrLen(urlMatch[1])
    body := StrReplace(ForegroundPercentDecode(urlMatch[2]), "/", "\")
    if RegExMatch(body, "i)^[A-Z]:\\")
        return body
    if RegExMatch(body, "i)^[A-Z]\|\\") ; legacy file:///C|/path form
        return SubStr(body, 1, 1) ":" SubStr(body, 3)
    if slashCount = 2 && body != ""
        return "\\" body
    return ""
}

; Percent-decoding must treat consecutive %XX escapes as UTF-8 bytes;
; decoding them one character at a time corrupts every non-ASCII name.
ForegroundPercentDecode(text) {
    if !InStr(text, "%")
        return text
    length := StrLen(text)
    byteBuffer := Buffer(length + 1, 0)
    result := ""
    index := 1
    while index <= length {
        byteCount := 0
        while index + 2 <= length && SubStr(text, index, 1) = "%"
            && RegExMatch(SubStr(text, index + 1, 2), "^[0-9A-Fa-f]{2}$") {
            NumPut("uchar", Integer("0x" SubStr(text, index + 1, 2)),
                byteBuffer, byteCount)
            byteCount += 1
            index += 3
        }
        if byteCount {
            result .= StrGet(byteBuffer, byteCount, "UTF-8")
            continue
        }
        result .= SubStr(text, index, 1)
        index += 1
    }
    return result
}

ForegroundStripExtendedPrefix(path) {
    if SubStr(path, 1, 8) = "\\?\UNC\"
        return "\\" SubStr(path, 9)
    if SubStr(path, 1, 4) = "\\?\"
        return SubStr(path, 5)
    return path
}

ForegroundPathLeaf(path) {
    SplitPath(path, &leafName)
    return leafName
}

ForegroundPathStem(path) {
    SplitPath(path, , , , &stemName)
    return stemName
}

ForegroundPathExtension(path) {
    SplitPath(path, , , &extensionName)
    return StrLower(extensionName)
}

; ──── Title parsing ────

; Split a caption into cleaned candidate tokens. Handles, for example:
;   "● notes.md - project - Visual Studio Code"
;   "report.docx [只读] - Word"
;   "photo.psd @ 66.7% (RGB/8#)"
;   "AutoCAD 2024 - [drawing1.dwg]"
ForegroundTitleSegments(title) {
    segments := []
    title := Trim(title "")
    if title = ""
        return segments
    for rawSegment in StrSplit(title, [" - ", " — ", " – ", " | ", " • "]) {
        segment := ForegroundCleanTitleSegment(rawSegment)
        if segment = "" || ForegroundArrayHasText(segments, segment)
            continue
        segments.Push(segment)
    }
    return segments
}

ForegroundCleanTitleSegment(segment) {
    segment := Trim(segment "")
    ; Leading "modified" markers: ● • ○ * and whitespace.
    segment := RegExReplace(segment, "^[\x{25CF}\x{2022}\x{25CB}*\s]+", "")
    ; A whole segment wrapped in brackets, e.g. "[drawing1.dwg]".
    if RegExMatch(segment, "^\[(.+)\]$", &wrapped)
        segment := Trim(wrapped[1])
    ; Photoshop / Illustrator zoom and colour-mode suffix.
    segment := RegExReplace(segment, "\s+@\s+\d.*$", "")
    ; Trailing decorations: [只读]  (兼容模式)  （已修改）  【受保护的视图】
    Loop 4 {
        cleaned := RegExReplace(segment,
            "\s*(?:\[[^\]]*\]|\([^)]*\)|（[^）]*）|【[^】]*】)\s*$", "")
        if cleaned = segment
            break
        segment := cleaned
    }
    segment := RegExReplace(segment, "[\s*\x{25CF}\x{2022}]+$", "")
    return Trim(segment)
}

ForegroundSegmentLooksLikeFileName(segment) {
    if StrLen(segment) > 255
        return false
    return RegExMatch(segment,
        'i)^[^\\/:*?"<>|\r\n]+\.(?=[a-z0-9]{1,16}$)[a-z0-9]*[a-z][a-z0-9]*$')
}

ForegroundSegmentsNameAFile(segments) {
    for segment in segments {
        if ForegroundSegmentLooksLikeFileName(segment)
            && ForegroundExtensionIsDocumentLike(segment)
            return true
    }
    return false
}

; First document-like "name.ext" token in a title, else the first "name.ext".
ForegroundExtractTitleFileName(title) {
    fallback := ""
    for segment in ForegroundTitleSegments(title) {
        if !ForegroundSegmentLooksLikeFileName(segment)
            continue
        if ForegroundExtensionIsDocumentLike(segment)
            return segment
        if fallback = ""
            fallback := segment
    }
    return fallback
}

; Find a rooted path embedded in the title. A path may itself contain " - ",
; so from each drive/UNC start the tail is shortened at separators from the
; right until an existing file is found. Remote paths have the same existence
; and non-directory requirement as local paths; the resolver itself is already
; isolated in a bounded worker process if the network provider stalls.
ForegroundFindRootedPathInTitle(title) {
    title := Trim(title "")
    position := 1
    while (position := RegExMatch(title, "i)(?:[A-Z]:[\\/]|\\\\[^\\])", ,
        position)) {
        attempt := SubStr(title, position)
        Loop 8 {
            cleaned := ForegroundCleanTitleSegment(attempt)
            path := ForegroundNormalizeCandidatePath(cleaned)
            if path != "" && ForegroundPathIsUsable(path)
                return path
            cut := ForegroundLastTitleSeparator(attempt)
            if !cut
                break
            attempt := SubStr(attempt, 1, cut - 1)
        }
        position += 2
    }
    return ""
}

ForegroundLastTitleSeparator(text) {
    best := 0
    for separator in [" - ", " — ", " – ", " | ", " • "] {
        found := InStr(text, separator, true, -1)
        if found > best
            best := found
    }
    return best
}

; Score how well a path's name matches the title: exact file name 100,
; name without extension 80, otherwise 0. The last of several segments is
; usually the application name ("... - Word"), so it may only match exactly.
ForegroundTitleMatchScore(path, segments) {
    leafLower := StrLower(ForegroundPathLeaf(path))
    stemLower := StrLower(ForegroundPathStem(path))
    score := 0
    for segment in segments {
        segmentLower := StrLower(segment)
        if segmentLower = leafLower
            return 100
        if stemLower != "" && segmentLower = stemLower
            && (segments.Length = 1 || A_Index < segments.Length)
            score := 80
    }
    return score
}

ForegroundBestTitleMatch(paths, segments) {
    if !segments.Length
        return ""
    best := ""
    bestScore := 0
    bestSeen := Map()
    for path in paths {
        score := ForegroundTitleMatchScore(path, segments)
        if score < 80 || !ForegroundPathIsUsable(path)
            continue
        ; An exact name is strong evidence even in a temp folder (mail
        ; attachments); a name-without-extension match is not.
        if score < 100 && ForegroundPathIsAppNoise(path)
            continue
        key := StrLower(path)
        if score > bestScore {
            best := path
            bestScore := score
            bestSeen := Map(key, true)
        } else if score = bestScore && !bestSeen.Has(key) {
            ; Two distinct files fit the title equally well. Modification time
            ; is not proof of which document owns the foreground window.
            bestSeen[key] := true
            best := ""
        }
    }
    return best
}

; Command-line and persisted-history evidence must not choose between two
; same-named documents. Return a path only when one distinct usable candidate
; matches the title.
ForegroundUniqueTitleMatch(paths, segments) {
    matches := []
    seen := Map()
    for path in paths {
        if ForegroundTitleMatchScore(path, segments) < 80
            || !ForegroundPathIsUsable(path)
            continue
        key := StrLower(path)
        if seen.Has(key)
            continue
        seen[key] := true
        matches.Push(path)
        if matches.Length > 1
            return ""
    }
    return matches.Length = 1 ? matches[1] : ""
}

ForegroundFileModifiedTime(path) {
    if ForegroundIsRemotePath(path)
        return ""
    try return FileGetTime(path, "M")
    catch
        return ""
}

; ──── Strategy 1: Office / WPS object model ────

ForegroundResolveViaOffice(processName, segments) {
    result := {Path: "", Method: "office-com", HintName: "", Tried: false,
        Unsaved: false}
    for spec in ForegroundOfficeSpecs(processName) {
        result.Tried := true
        found := ForegroundOfficeDocumentPath(spec[1], spec[2], spec[3],
            segments)
        if found.Path != "" {
            result.Path := found.Path
            result.Method := found.Method
            return result
        }
        if found.Unsaved {
            result.Unsaved := true
            return result
        }
        if found.HintName != "" && result.HintName = ""
            result.HintName := found.HintName
    }
    return result
}

; [ProgID, collection property, active-item property]
ForegroundOfficeSpecs(processName) {
    switch processName {
        case "winword.exe":
            return [["Word.Application", "Documents", "ActiveDocument"]]
        case "excel.exe":
            return [["Excel.Application", "Workbooks", "ActiveWorkbook"]]
        case "powerpnt.exe":
            return [["PowerPoint.Application", "Presentations",
                "ActivePresentation"]]
        case "wps.exe", "wpsoffice.exe":
            ; Integrated WPS hosts all three editors in wps.exe; current
            ; WPS 365 uses wpsoffice.exe. MS Office
            ; ProgIDs are intentionally NOT queried here: when Word is also
            ; running they would return Word's document instead of WPS's.
            return [["KWPS.Application", "Documents", "ActiveDocument"],
                ["KET.Application", "Workbooks", "ActiveWorkbook"],
                ["KWPP.Application", "Presentations", "ActivePresentation"]]
        case "et.exe":
            return [["KET.Application", "Workbooks", "ActiveWorkbook"]]
        case "wpp.exe":
            return [["KWPP.Application", "Presentations",
                "ActivePresentation"]]
    }
    return []
}

ForegroundProcessIsWps(processName) {
    processName := StrLower(processName "")
    return processName = "wps.exe" || processName = "et.exe"
        || processName = "wpp.exe" || processName = "wpsoffice.exe"
}

ForegroundOfficeDocumentPath(progId, collectionProperty, activeProperty,
    segments) {
    found := {Path: "", Method: "office-com", HintName: "", Unsaved: false}
    app := 0
    try app := ComObjActive(progId)
    catch
        return found
    if !IsObject(app)
        return found

    ; The active item is right only if it is the document shown in the
    ; target window's title; ComObjActive may bind to a different instance.
    try {
        activeItem := app.%activeProperty%
        if ForegroundOfficeItemMatches(activeItem, segments)
            ForegroundOfficeAdoptItem(activeItem, found)
    }
    if found.Path != "" || found.Unsaved || found.HintName != ""
        return found

    if segments.Length {
        try {
            for documentItem in app.%collectionProperty% {
                if A_Index > 64
                    break
                if ForegroundOfficeItemMatches(documentItem, segments) {
                    ForegroundOfficeAdoptItem(documentItem, found)
                    if found.Path != "" || found.Unsaved
                        || found.HintName != ""
                        break
                }
            }
        }
    }
    return found
}

ForegroundOfficeItemMatches(documentItem, segments) {
    if !IsObject(documentItem)
        return false
    if !segments.Length
        return true
    itemName := ""
    try itemName := documentItem.Name ""
    if itemName = ""
        return false
    return ForegroundTitleMatchScore(itemName, segments) >= 80
}

ForegroundOfficeAdoptItem(documentItem, found) {
    fullName := ""
    try fullName := Trim(documentItem.FullName "")
    if fullName = ""
        return
    if RegExMatch(fullName, "i)^https?://") {
        ; Cloud document: try the local sync folder, else keep its name as a
        ; hint for the handle / Recent strategies.
        localPath := ForegroundMapCloudUrlToLocal(fullName)
        if localPath != "" {
            found.Path := localPath
            found.Method := "office-com-cloud-sync"
        } else {
            found.HintName := ForegroundPercentDecode(
                RegExReplace(fullName, "^.*/", ""))
        }
        return
    }
    if ForegroundPathIsUsable(fullName) {
        found.Path := fullName
        return
    }
    ; A never-saved document reports only a caption such as "文档1".
    if !RegExMatch(fullName, "[\\/]")
        found.Unsaved := true
}

; OneDrive personal:  https://d.docs.live.net/<cid>/Folder/file.docx
; OneDrive business:  https://<tenant>-my.sharepoint.com/personal/<user>/
;                     Documents/Folder/file.docx
; The mapped file is accepted only if it exists locally.
ForegroundMapCloudUrlToLocal(url) {
    relative := ""
    roots := []
    if RegExMatch(url, "i)^https?://d\.docs\.live\.net/[^/]+/(.+)$",
        &personalMatch) {
        relative := personalMatch[1]
        roots := ["OneDriveConsumer", "OneDrive"]
    } else if RegExMatch(url,
        "i)^https?://[^/]+-my\.sharepoint\.com/personal/[^/]+/Documents/(.+)$",
        &businessMatch) {
        relative := businessMatch[1]
        roots := ["OneDriveCommercial", "OneDrive"]
    } else {
        return ""
    }
    relative := StrReplace(ForegroundPercentDecode(relative), "/", "\")
    for variableName in roots {
        root := ""
        try root := EnvGet(variableName)
        if root = ""
            continue
        candidate := RTrim(root, "\") "\" relative
        if !ForegroundIsRemotePath(candidate)
            && ForegroundPathIsUsable(candidate)
            return candidate
    }
    return ""
}

; ──── Strategy 3: process command line ────

ForegroundProcessCommandLine(processId) {
    static PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
    static ProcessCommandLineInformation := 60
    static STATUS_INFO_LENGTH_MISMATCH := 0xC0000004
    if !processId
        return ""
    processHandle := DllCall("kernel32\OpenProcess",
        "uint", PROCESS_QUERY_LIMITED_INFORMATION,
        "int", 0, "uint", processId, "ptr")
    if !processHandle
        return ""
    try {
        required := 0
        status := DllCall("ntdll\NtQueryInformationProcess",
            "ptr", processHandle, "uint", ProcessCommandLineInformation,
            "ptr", 0, "uint", 0, "uint*", &required, "uint")
        if status != STATUS_INFO_LENGTH_MISMATCH || required < A_PtrSize + 4
            return ""
        if required > 0x20000
            return ""
        commandBuffer := Buffer(required + 2, 0)
        status := DllCall("ntdll\NtQueryInformationProcess",
            "ptr", processHandle, "uint", ProcessCommandLineInformation,
            "ptr", commandBuffer.Ptr, "uint", commandBuffer.Size,
            "uint*", &required, "uint")
        if status != 0
            return ""
        byteLength := NumGet(commandBuffer, 0, "ushort")
        stringPtr := NumGet(commandBuffer, A_PtrSize = 8 ? 8 : 4, "ptr")
        if !stringPtr || !byteLength || byteLength > 0x1FFFE
            return ""
        bufferEnd := commandBuffer.Ptr + commandBuffer.Size
        if stringPtr < commandBuffer.Ptr || stringPtr + byteLength > bufferEnd
            return ""
        return StrGet(stringPtr, byteLength // 2, "UTF-16")
    } catch {
        return ""
    } finally {
        DllCall("kernel32\CloseHandle", "ptr", processHandle)
    }
}

ForegroundCommandLineFilePaths(processId) {
    return ForegroundFilePathsFromCommandLine(
        ForegroundProcessCommandLine(processId))
}

ForegroundFilePathsFromCommandLine(commandLine) {
    paths := []
    commandLine := Trim(commandLine "")
    if commandLine = ""
        return paths
    argumentCount := 0
    argumentVector := DllCall("shell32\CommandLineToArgvW",
        "wstr", commandLine, "int*", &argumentCount, "ptr")
    if !argumentVector
        return paths
    seen := Map()
    try {
        Loop argumentCount {
            argumentPtr := NumGet(argumentVector,
                (A_Index - 1) * A_PtrSize, "ptr")
            if !argumentPtr
                continue
            argument := StrGet(argumentPtr, "UTF-16")
            candidate := ForegroundNormalizeCandidatePath(argument)
            if candidate = "" {
                ; Some launchers use /file:C:\path or --file=C:\path.
                rootAt := RegExMatch(argument,
                    "i)(?:file:(?:/{2,3})?|[A-Z]:[\\/]|\\\\[^\\?.])")
                if rootAt
                    candidate := ForegroundNormalizeCandidatePath(
                        SubStr(argument, rootAt))
            }
            if candidate = "" || !ForegroundPathIsUsable(candidate)
                continue
            key := StrLower(candidate)
            if seen.Has(key)
                continue
            seen[key] := true
            paths.Push(candidate)
        }
    } finally {
        DllCall("kernel32\LocalFree", "ptr", argumentVector, "ptr")
    }
    return paths
}

; ──── Strategy 4: open handles (collected through a child process) ────

ForegroundCollectHandlePaths(processId, timeoutMs) {
    paths := []
    if !processId
        return paths
    outputPath := A_Temp "\PopDrop-fg-handles-" DllCall(
        "kernel32\GetCurrentProcessId", "uint") "-" A_TickCount ".txt"
    child := 0
    try {
        child := ForegroundLaunchSelf(
            ["--foreground-handle-worker", processId, outputPath], true)
    } catch {
        child := 0
    }
    if IsObject(child) && child.Handle {
        waitResult := DllCall("kernel32\WaitForSingleObject",
            "ptr", child.Handle, "uint", timeoutMs, "uint")
        if waitResult != 0 ; WAIT_OBJECT_0
            DllCall("kernel32\TerminateProcess", "ptr", child.Handle,
                "uint", 1, "int")
        DllCall("kernel32\CloseHandle", "ptr", child.Handle)
    } else {
        ; Could not isolate the enumeration; run it in-process instead.
        try ForegroundEnumerateProcessFilePaths(processId,
            ForegroundCollectPathInto.Bind(paths))
        return paths
    }
    text := ""
    try text := FileRead(outputPath, "UTF-8")
    try FileDelete(outputPath)
    seen := Map()
    for line in StrSplit(text, "`n", "`r") {
        if line = "" || SubStr(line, 1, 1) = "#"
            continue
        lineKey := StrLower(line)
        if seen.Has(lineKey)
            continue
        seen[lineKey] := true
        paths.Push(line)
    }
    return paths
}

ForegroundCollectPathInto(paths, path) {
    paths.Push(path)
}

; Enumerate the disk files a process holds open and call onPath(path) for
; each distinct one. Prefers the per-process handle snapshot (Windows 8+),
; falling back to the system-wide extended handle table filtered by PID.
ForegroundEnumerateProcessFilePaths(processId, onPath) {
    static PROCESS_DUP_HANDLE := 0x0040
    static PROCESS_QUERY_INFORMATION := 0x0400
    static PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
    processHandle := DllCall("kernel32\OpenProcess",
        "uint", PROCESS_DUP_HANDLE | PROCESS_QUERY_INFORMATION,
        "int", 0, "uint", processId, "ptr")
    if !processHandle
        processHandle := DllCall("kernel32\OpenProcess",
            "uint", PROCESS_DUP_HANDLE | PROCESS_QUERY_LIMITED_INFORMATION,
            "int", 0, "uint", processId, "ptr")
    if !processHandle
        return 0

    reported := 0
    try {
        fileTypeIndex := ForegroundFileObjectTypeIndex()
        entries := ForegroundQueryProcessHandles(processHandle, processId)
        currentProcess := DllCall("kernel32\GetCurrentProcess", "ptr")
        seen := Map()
        for entry in entries {
            if fileTypeIndex >= 0 && entry.TypeIndex != fileTypeIndex
                continue
            path := ForegroundTranslateRemoteHandle(processHandle,
                entry.Handle, currentProcess)
            if path = "" || ForegroundPathIsSystemNoise(path)
                continue
            pathKey := StrLower(path)
            if seen.Has(pathKey)
                continue
            seen[pathKey] := true
            onPath.Call(path)
            reported += 1
            if reported >= 1024
                break
        }
    } finally {
        DllCall("kernel32\CloseHandle", "ptr", processHandle)
    }
    return reported
}

; Returns an array of {Handle, TypeIndex}.
ForegroundQueryProcessHandles(processHandle, processId) {
    entries := ForegroundQueryHandleSnapshot(processHandle)
    if IsObject(entries)
        return entries
    entries := ForegroundQuerySystemHandleTable(processId)
    return IsObject(entries) ? entries : []
}

; NtQueryInformationProcess(ProcessHandleSnapshotInformation = 51)
; PROCESS_HANDLE_SNAPSHOT_INFORMATION: NumberOfHandles, Reserved (ULONG_PTR),
; then PROCESS_HANDLE_TABLE_ENTRY_INFO { HANDLE HandleValue; ULONG_PTR
; HandleCount; ULONG_PTR PointerCount; ULONG GrantedAccess; ULONG
; ObjectTypeIndex; ULONG HandleAttributes; ULONG Reserved; }
ForegroundQueryHandleSnapshot(processHandle) {
    size := 0x10000
    Loop 8 {
        snapshotBuffer := Buffer(size, 0)
        returnLength := 0
        status := DllCall("ntdll\NtQueryInformationProcess",
            "ptr", processHandle, "uint", 51, "ptr", snapshotBuffer.Ptr,
            "uint", size, "uint*", &returnLength, "uint")
        if status = 0 {
            headerSize := A_PtrSize * 2
            entrySize := A_PtrSize * 3 + 16
            count := NumGet(snapshotBuffer, 0, "uptr")
            if headerSize + count * entrySize > size
                return 0
            entries := []
            Loop count {
                entryOffset := headerSize + (A_Index - 1) * entrySize
                entries.Push({
                    Handle: NumGet(snapshotBuffer, entryOffset, "uptr"),
                    TypeIndex: NumGet(snapshotBuffer,
                        entryOffset + A_PtrSize * 3 + 4, "uint")})
            }
            return entries
        }
        ; STATUS_INFO_LENGTH_MISMATCH / STATUS_BUFFER_TOO_SMALL
        if status = 0xC0000004 || status = 0xC0000023 {
            size := Max(size * 2, returnLength + 0x1000)
            continue
        }
        return 0
    }
    return 0
}

; NtQuerySystemInformation(SystemExtendedHandleInformation = 64)
; SYSTEM_HANDLE_INFORMATION_EX: NumberOfHandles, Reserved (ULONG_PTR), then
; SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX { PVOID Object; ULONG_PTR
; UniqueProcessId; ULONG_PTR HandleValue; ULONG GrantedAccess; USHORT
; CreatorBackTraceIndex; USHORT ObjectTypeIndex; ULONG HandleAttributes;
; ULONG Reserved; }
ForegroundQuerySystemHandleTable(processId) {
    size := 0x400000
    Loop 6 {
        tableBuffer := Buffer(size, 0)
        returnLength := 0
        status := DllCall("ntdll\NtQuerySystemInformation",
            "uint", 64, "ptr", tableBuffer.Ptr, "uint", size,
            "uint*", &returnLength, "uint")
        if status = 0 {
            headerSize := A_PtrSize * 2
            entrySize := A_PtrSize * 3 + 16
            count := NumGet(tableBuffer, 0, "uptr")
            if headerSize + count * entrySize > size
                return 0
            entries := []
            Loop count {
                entryOffset := headerSize + (A_Index - 1) * entrySize
                if NumGet(tableBuffer, entryOffset + A_PtrSize, "uptr")
                    != processId
                    continue
                entries.Push({
                    Handle: NumGet(tableBuffer,
                        entryOffset + A_PtrSize * 2, "uptr"),
                    TypeIndex: NumGet(tableBuffer,
                        entryOffset + A_PtrSize * 3 + 6, "ushort")})
            }
            return entries
        }
        if status = 0xC0000004 { ; STATUS_INFO_LENGTH_MISMATCH
            size := Max(size * 2, returnLength + 0x100000)
            continue
        }
        return 0
    }
    return 0
}

; Object type indexes differ between Windows builds. Learn the "File" index
; from a handle this process opens itself (the NUL device is a File object).
ForegroundFileObjectTypeIndex() {
    static cachedIndex := ""
    if cachedIndex != ""
        return cachedIndex
    cachedIndex := -1
    nulHandle := DllCall("kernel32\CreateFileW", "wstr", "NUL",
        "uint", 0x80000000, "uint", 3, "ptr", 0, "uint", 3, "uint", 0,
        "ptr", 0, "ptr") ; GENERIC_READ, share R|W, OPEN_EXISTING
    if !nulHandle || nulHandle = -1
        return cachedIndex
    try {
        ownProcess := DllCall("kernel32\GetCurrentProcess", "ptr")
        entries := ForegroundQueryHandleSnapshot(ownProcess)
        if !IsObject(entries)
            entries := ForegroundQuerySystemHandleTable(
                DllCall("kernel32\GetCurrentProcessId", "uint"))
        if IsObject(entries) {
            for entry in entries {
                if entry.Handle = nulHandle {
                    cachedIndex := entry.TypeIndex
                    break
                }
            }
        }
    } finally {
        DllCall("kernel32\CloseHandle", "ptr", nulHandle)
    }
    return cachedIndex
}

ForegroundTranslateRemoteHandle(processHandle, remoteHandle, currentProcess) {
    duplicated := 0
    if !DllCall("kernel32\DuplicateHandle",
        "ptr", processHandle, "ptr", remoteHandle,
        "ptr", currentProcess, "ptr*", &duplicated,
        "uint", 0, "int", 0, "uint", 0x2, "int") ; DUPLICATE_SAME_ACCESS
        return ""
    path := ""
    try {
        ; FILE_TYPE_DISK = 1. Pipes and devices are skipped here.
        if DllCall("kernel32\GetFileType", "ptr", duplicated, "uint") = 1
            path := ForegroundFinalPathFromHandle(duplicated)
    } finally {
        DllCall("kernel32\CloseHandle", "ptr", duplicated)
    }
    return path
}

ForegroundFinalPathFromHandle(handle) {
    needed := DllCall("kernel32\GetFinalPathNameByHandleW",
        "ptr", handle, "ptr", 0, "uint", 0, "uint", 0, "uint")
    if !needed || needed > 0x8000
        return ""
    pathBuffer := Buffer((needed + 1) * 2, 0)
    written := DllCall("kernel32\GetFinalPathNameByHandleW",
        "ptr", handle, "ptr", pathBuffer.Ptr, "uint", needed + 1,
        "uint", 0, "uint") ; VOLUME_NAME_DOS
    if !written || written > needed
        return ""
    return ForegroundStripExtendedPrefix(StrGet(pathBuffer))
}

; Operating-system and application-install locations never hold the user's
; document. Compared as prefixes, so a user folder named "windows" is kept.
ForegroundPathIsSystemNoise(path) {
    static prefixes := 0
    if !IsObject(prefixes) {
        prefixes := []
        for variableName in ["SystemRoot", "ProgramFiles",
            "ProgramFiles(x86)", "ProgramW6432", "ProgramData"] {
            root := ""
            try root := EnvGet(variableName)
            if root != ""
                prefixes.Push(StrLower(RTrim(root, "\")) "\")
        }
    }
    pathLower := StrLower(path)
    for prefix in prefixes {
        if SubStr(pathLower, 1, StrLen(prefix)) = prefix
            return true
    }
    return false
}

; ──── Strategy 5: WPS per-user recent-document registry ────

ForegroundResolveViaWpsRecent(segments, deadlineTick) {
    if !ForegroundSegmentsNameAFile(segments)
        return ""
    candidates := []
    seen := Map()
    valueCount := 0
    ; Product versions use different subkeys below this stable vendor root.
    ; A deadline and value cap prevent a damaged profile from delaying the
    ; worker. Only strings are read; binary preferences are never decoded.
    registryRoot := "HKEY_CURRENT_USER\Software\Kingsoft\Office"
    try {
        Loop Reg, registryRoot, "VR" {
            valueCount += 1
            if valueCount > 5000 || A_TickCount >= deadlineTick
                break
            if A_LoopRegType != "REG_SZ"
                && A_LoopRegType != "REG_EXPAND_SZ"
                && A_LoopRegType != "REG_MULTI_SZ"
                continue
            value := ""
            try value := RegRead(A_LoopRegKey, A_LoopRegName)
            catch
                continue
            if value = ""
                continue
            ForegroundCollectWpsRecentValuePaths(
                value "", segments, candidates, seen)
            if candidates.Length > 1
                break
        }
    } catch {
        return ""
    }
    return candidates.Length = 1 ? candidates[1] : ""
}

ForegroundCollectWpsRecentValuePaths(value, segments, candidates, seen) {
    ; Most WPS MRU values are a plain path or a REG_MULTI_SZ list.
    for piece in StrSplit(value, ["`r", "`n"]) {
        candidate := ForegroundNormalizeCandidatePath(piece)
        if candidate != ""
            ForegroundAdoptUniqueTitlePath(
                candidate, segments, candidates, seen)
    }

    ; Some editions store flags or timestamps around the path. Locate each
    ; exact title filename and rebuild the rooted prefix ending at that name.
    for segment in segments {
        if !ForegroundSegmentLooksLikeFileName(segment)
            continue
        searchAt := 1
        while (nameAt := InStr(value, segment, false, searchAt)) {
            rootAt := ForegroundLastRootBefore(value, nameAt)
            if rootAt {
                candidate := SubStr(value, rootAt,
                    nameAt + StrLen(segment) - rootAt)
                candidate := ForegroundNormalizeCandidatePath(candidate)
                if candidate != ""
                    ForegroundAdoptUniqueTitlePath(
                        candidate, segments, candidates, seen)
            }
            searchAt := nameAt + Max(1, StrLen(segment))
        }
    }
}

ForegroundLastRootBefore(text, beforePosition) {
    best := 0
    searchAt := 1
    while searchAt < beforePosition {
        rootAt := RegExMatch(text,
            "i)(?:[A-Z]:[\\/]|\\\\[^\\?.])", , searchAt)
        if !rootAt || rootAt >= beforePosition
            break
        best := rootAt
        searchAt := rootAt + 2
    }
    return best
}

ForegroundAdoptUniqueTitlePath(path, segments, candidates, seen) {
    if ForegroundTitleMatchScore(path, segments) < 100
        || !ForegroundPathIsUsable(path)
        return
    key := StrLower(path)
    if seen.Has(key)
        return
    seen[key] := true
    candidates.Push(path)
}

; ──── Strategy 6: Windows Recent shortcuts ────

ForegroundResolveViaRecent(segments) {
    recentDir := A_AppData "\Microsoft\Windows\Recent"
    if !segments.Length || !InStr(FileExist(recentDir), "D")
        return ""
    ; Exact "name.ext.lnk" first.
    for segment in segments {
        if !ForegroundSegmentLooksLikeFileName(segment)
            continue
        linkPath := recentDir "\" segment ".lnk"
        target := ForegroundShortcutTarget(linkPath)
        if target != ""
            && StrLower(ForegroundPathLeaf(target)) = StrLower(segment)
            && ForegroundPathIsUsable(target)
            return target
    }
    ; Then titles that hide the extension: "name.*.lnk", newest shortcut wins,
    ; document-like targets only.
    best := ""
    bestModified := ""
    for segment in segments {
        if segments.Length > 1 && A_Index = segments.Length
            break ; the application name
        if ForegroundSegmentLooksLikeFileName(segment)
            || RegExMatch(segment, '[\\/:*?"<>|]') || StrLen(segment) > 200
            continue
        Loop Files recentDir "\" segment ".*.lnk" {
            target := ForegroundShortcutTarget(A_LoopFileFullPath)
            if target = ""
                || StrLower(ForegroundPathStem(target)) != StrLower(segment)
                || !ForegroundExtensionIsDocumentLike(target)
                || !ForegroundPathIsUsable(target)
                continue
            if A_LoopFileTimeModified > bestModified {
                best := target
                bestModified := A_LoopFileTimeModified
            }
        }
    }
    return best
}

ForegroundShortcutTarget(linkPath) {
    if !FileExist(linkPath)
        return ""
    target := ""
    try FileGetShortcut(linkPath, &target)
    catch
        return ""
    return Trim(target "")
}

; ──── Strategy 7: UI Automation edit fields ────
;
; IUIAutomation is not IDispatch: ComObject(CLSID, IID) returns a raw
; interface wrapper, so every call goes through ComCall with vtable indexes.
;   IUIAutomation:              6 ElementFromHandle, 21 CreateTrueCondition
;   IUIAutomationElement:       6 FindAll, 10 GetCurrentPropertyValue,
;                               21 get_CurrentControlType
;   IUIAutomationElementArray:  3 get_Length, 4 GetElement

ForegroundResolveViaUia(hwnd, deadlineTick) {
    automation := 0
    try automation := ComObject("{ff48dba4-60ef-4201-aa87-54103eef594e}",
        "{30cbe57d-d9d0-452a-ab13-7ac5ac4825ee}")
    catch
        return ""
    rootPtr := 0
    conditionPtr := 0
    try {
        ComCall(6, automation, "ptr", hwnd, "ptr*", &rootPtr)
        ComCall(21, automation, "ptr*", &conditionPtr)
        if !rootPtr || !conditionPtr
            return ""
        return ForegroundUiaSearchEditFields(rootPtr, conditionPtr,
            deadlineTick)
    } catch {
        return ""
    } finally {
        if conditionPtr
            ObjRelease(conditionPtr)
        if rootPtr
            ObjRelease(rootPtr)
    }
}

ForegroundUiaSearchEditFields(rootPtr, conditionPtr, deadlineTick) {
    static UIA_EditControlTypeId := 50004
    static UIA_ValueValuePropertyId := 30045
    static TreeScope_Children := 2
    ObjAddRef(rootPtr)
    queue := [{Ptr: rootPtr, Depth: 0}]
    head := 1
    found := ""
    try {
        while head <= queue.Length && head <= 500
            && A_TickCount < deadlineTick {
            node := queue[head]
            head += 1
            controlType := 0
            try ComCall(21, node.Ptr, "int*", &controlType)
            if controlType = UIA_EditControlTypeId {
                candidate := ForegroundNormalizeCandidatePath(
                    ForegroundUiaReadString(node.Ptr,
                        UIA_ValueValuePropertyId))
                if candidate != "" && ForegroundPathIsUsable(candidate) {
                    found := candidate
                    break
                }
            }
            if node.Depth >= 12 || queue.Length >= 2000
                continue
            arrayPtr := 0
            try ComCall(6, node.Ptr, "int", TreeScope_Children,
                "ptr", conditionPtr, "ptr*", &arrayPtr)
            if !arrayPtr
                continue
            try {
                childCount := 0
                ComCall(3, arrayPtr, "int*", &childCount)
                Loop Min(childCount, 64) {
                    childPtr := 0
                    try ComCall(4, arrayPtr, "int", A_Index - 1,
                        "ptr*", &childPtr)
                    if childPtr
                        queue.Push({Ptr: childPtr, Depth: node.Depth + 1})
                }
            } finally {
                ObjRelease(arrayPtr)
            }
        }
    } finally {
        for node in queue
            ObjRelease(node.Ptr)
    }
    return found
}

ForegroundUiaReadString(elementPtr, propertyId) {
    variantBuffer := Buffer(24, 0)
    text := ""
    try {
        ComCall(10, elementPtr, "int", propertyId, "ptr", variantBuffer.Ptr)
        if NumGet(variantBuffer, 0, "ushort") = 8 { ; VT_BSTR
            bstr := NumGet(variantBuffer, 8, "ptr")
            ; Skip whole-document values (e.g. a plain Edit control's text).
            if bstr && DllCall("oleaut32\SysStringLen", "ptr", bstr,
                "uint") <= 1024
                text := StrGet(bstr, "UTF-16")
        }
    }
    DllCall("oleaut32\VariantClear", "ptr", variantBuffer.Ptr)
    return text
}

; ──── Strategy 8: unique document handle ────

ForegroundDocumentHandleCandidates(paths) {
    candidates := []
    for path in paths {
        if !ForegroundExtensionIsDocumentLike(path)
            || ForegroundExtensionIsConfigLike(path)
            || ForegroundPathIsAppNoise(path)
            || !ForegroundPathIsUsable(path)
            continue
        candidates.Push(path)
        if candidates.Length > 8
            break
    }
    return candidates
}

ForegroundPathIsAppNoise(path) {
    leafLower := StrLower(ForegroundPathLeaf(path))
    ; Office/WPS owner-lock stubs, temp scratch files and autosave shadows.
    if SubStr(leafLower, 1, 1) = "~" || InStr(leafLower, ".tmp")
        return true
    pathLower := StrLower(path)
    for variableName in ["APPDATA", "LOCALAPPDATA", "TEMP"] {
        root := ""
        try root := EnvGet(variableName)
        if root = ""
            continue
        rootLower := StrLower(RTrim(root, "\")) "\"
        if SubStr(pathLower, 1, StrLen(rootLower)) = rootLower
            return true
    }
    return InStr(pathLower, "\$recycle.bin\")
}

ForegroundExtensionIsConfigLike(path) {
    static configExtensions := Map("ini", true, "log", true, "json", true,
        "xml", true, "yaml", true, "yml", true, "db", true, "dat", true)
    return configExtensions.Has(ForegroundPathExtension(path))
}

ForegroundExtensionIsDocumentLike(path) {
    static documentExtensions := Map(
        "doc", true, "docx", true, "docm", true, "dot", true, "dotx", true,
        "rtf", true, "odt", true, "wps", true, "wpt", true,
        "xls", true, "xlsx", true, "xlsm", true, "xlsb", true, "csv", true,
        "tsv", true, "ods", true, "et", true, "ett", true,
        "ppt", true, "pptx", true, "pptm", true, "pps", true, "ppsx", true,
        "odp", true, "dps", true, "dpt", true, "pdf", true, "ofd", true,
        "txt", true, "md", true, "markdown", true, "log", true, "ini", true,
        "json", true, "xml", true, "yaml", true, "yml", true,
        "psd", true, "psb", true, "ai", true, "indd", true, "xd", true,
        "sketch", true, "fig", true, "afphoto", true, "afdesign", true,
        "cdr", true, "eps", true, "svg", true, "kra", true, "clip", true,
        "blend", true, "c4d", true, "max", true, "ma", true, "mb", true,
        "dwg", true, "dxf", true, "skp", true, "3dm", true, "step", true,
        "stp", true, "igs", true, "iges", true, "sldprt", true,
        "sldasm", true, "epub", true, "tex", true, "pages", true,
        "numbers", true, "key", true, "xmind", true, "mm", true,
        "c", true, "h", true, "cpp", true, "hpp", true, "cc", true,
        "cs", true, "java", true, "js", true, "ts", true, "jsx", true,
        "tsx", true, "py", true, "rb", true, "go", true, "rs", true,
        "php", true, "swift", true, "kt", true, "sql", true, "sh", true,
        "ps1", true, "bat", true, "cmd", true, "ahk", true, "ahk2", true,
        "html", true, "htm", true, "css", true, "scss", true, "less", true,
        "vue", true, "lua", true, "r", true, "dart", true)
    return documentExtensions.Has(ForegroundPathExtension(path))
}

; ──── Launch this same script / executable as a child process ────

ForegroundLaunchSelf(workerArguments, keepProcessHandle := false) {
    if A_IsCompiled {
        executable := A_ScriptFullPath
        arguments := [A_ScriptFullPath]
    } else {
        executable := A_AhkPath
        arguments := [A_AhkPath, A_ScriptFullPath]
    }
    for argument in workerArguments
        arguments.Push(argument "")
    commandLine := ""
    for argument in arguments
        commandLine .= (commandLine = "" ? "" : " ")
            . ForegroundQuoteArgument(argument)
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
        throw OSError(A_LastError, "ForegroundLaunchSelf")
    processHandle := NumGet(processInfo, 0, "ptr")
    threadHandle := NumGet(processInfo, A_PtrSize, "ptr")
    processId := NumGet(processInfo, A_PtrSize * 2, "uint")
    if threadHandle
        DllCall("kernel32\CloseHandle", "ptr", threadHandle)
    if !keepProcessHandle && processHandle {
        DllCall("kernel32\CloseHandle", "ptr", processHandle)
        processHandle := 0
    }
    return {Pid: processId, Handle: processHandle}
}

; Quote one argument for CommandLineToArgvW / the MSVC runtime.
ForegroundQuoteArgument(argument) {
    argument := argument ""
    if argument != "" && !RegExMatch(argument, '[\s"]')
        return argument
    quoted := '"'
    backslashes := 0
    Loop Parse argument {
        character := A_LoopField
        if character = "\" {
            backslashes += 1
            continue
        }
        if character = '"' {
            Loop backslashes * 2 + 1
                quoted .= "\"
            quoted .= '"'
        } else {
            Loop backslashes
                quoted .= "\"
            quoted .= character
        }
        backslashes := 0
    }
    Loop backslashes * 2
        quoted .= "\"
    return quoted '"'
}
