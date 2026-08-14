; Text-block workspace storage, ranking, search, editing and delivery.

ParseWorkspaceType(raw) {
    global WORKSPACE_TYPE_FILES, WORKSPACE_TYPE_TEXT
    return StrLower(Trim(raw)) = StrLower(WORKSPACE_TYPE_TEXT)
        ? WORKSPACE_TYPE_TEXT : WORKSPACE_TYPE_FILES
}

IsTextWorkspace(workspaceId := "") {
    global Workspaces, ActiveWorkspaceId, WORKSPACE_TYPE_TEXT
    if workspaceId = ""
        workspaceId := ActiveWorkspaceId
    found := FindWorkspace(workspaceId, Workspaces)
    return IsObject(found)
        && ParseWorkspaceType(found.Value.Type) = WORKSPACE_TYPE_TEXT
}

IsTextBlockPath(path) {
    if !FileExist(path) || InStr(FileExist(path), "D")
        return false
    return HasTextBlockExtension(path)
}

HasTextBlockExtension(path) {
    SplitPath(path, , , &extension)
    extension := StrLower(extension)
    return extension = "md" || extension = "txt"
}

AllTextBlockPaths(paths) {
    if !IsObject(paths) || !paths.Length
        return false
    for path in paths {
        if !IsTextBlockPath(path)
            return false
    }
    return true
}

TextBlockDataDirectory() {
    return A_ScriptDir "\data\text-blocks"
}

TextBlockInboxDirectory(workspaceId := "") {
    global ActiveWorkspaceId
    if workspaceId = ""
        workspaceId := ActiveWorkspaceId
    return TextBlockDataDirectory() "\inbox\" workspaceId
}

IsTextBlockDraftPath(path, workspaceId := "") {
    root := TextBlockInboxDirectory(workspaceId)
    return PathsEqual(path, root) || IsSameOrDescendantPath(path, root)
}

AllTextBlockDraftPaths(paths, workspaceId := "") {
    if !IsObject(paths) || !paths.Length
        return false
    for path in paths {
        if !IsTextBlockDraftPath(path, workspaceId)
            return false
    }
    return true
}

AnyTextBlockDraftPaths(paths, workspaceId := "") {
    if !IsObject(paths) || !paths.Length
        return false
    for path in paths {
        if IsTextBlockDraftPath(path, workspaceId)
            return true
    }
    return false
}

InitTextBlocks() {
    global TextBlockUsage, TextBlockSearchIndex, TextBlockSearchQueue
    global TextBlockSearchRefreshPending
    TextBlockUsage := Map()
    TextBlockSearchIndex := Map()
    TextBlockSearchQueue := []
    TextBlockSearchRefreshPending := false
    LoadTextBlockUsage()
}

TextBlockUsagePath() {
    return TextBlockDataDirectory() "\usage.ini"
}

LoadTextBlockUsage() {
    global TextBlockUsage
    TextBlockUsage := Map()
    path := TextBlockUsagePath()
    if !FileExist(path)
        return
    try {
        count := Integer(IniRead(path, "Meta", "Count", "0"))
        count := Max(0, Min(count, 100000))
        Loop count {
            section := "Item" Format("{:06}", A_Index)
            itemPath := NormalizePath(IniRead(path, section, "Path", ""))
            if itemPath = ""
                continue
            TextBlockUsage[PathKey(itemPath)] := {
                Path: itemPath,
                LastUsed: IniRead(path, section, "LastUsed", ""),
                Total: Integer(IniRead(path, section, "Total", "0")),
                WindowStart: IniRead(path, section, "WindowStart", ""),
                WindowCount: Integer(IniRead(path, section, "WindowCount", "0")),
                NewUntil: IniRead(path, section, "NewUntil", "")
            }
        }
    }
}

SaveTextBlockUsage() {
    global TextBlockUsage
    dataDir := TextBlockDataDirectory()
    DirCreate(dataDir)
    finalPath := TextBlockUsagePath()
    tempPath := finalPath ".writing-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
    try FileDelete(tempPath)
    IniWrite(TextBlockUsage.Count, tempPath, "Meta", "Count")
    index := 0
    for key, item in TextBlockUsage {
        if ++index > 100000
            break
        section := "Item" Format("{:06}", index)
        IniWrite(item.Path, tempPath, section, "Path")
        IniWrite(item.LastUsed, tempPath, section, "LastUsed")
        IniWrite(item.Total, tempPath, section, "Total")
        IniWrite(item.WindowStart, tempPath, section, "WindowStart")
        IniWrite(item.WindowCount, tempPath, section, "WindowCount")
        IniWrite(item.NewUntil, tempPath, section, "NewUntil")
    }
    IniWrite(index, tempPath, "Meta", "Count")
    if !DllCall("kernel32\MoveFileExW", "wstr", tempPath,
        "wstr", finalPath, "uint", 0x9, "int")
        throw OSError(A_LastError, "无法保存文本块使用状态")
}

UpdateTextBlockUsagePaths(mappings) {
    global TextBlockUsage, TextBlockSearchIndex
    updates := []
    for key, item in TextBlockUsage {
        mapped := ResolveMovedPathMapping(item.Path, mappings)
        if mapped != "" && !PathsEqual(mapped, item.Path)
            updates.Push({OldKey: key, NewPath: mapped, Item: item})
    }
    if !updates.Length
        return false
    for update in updates {
        TextBlockUsage.Delete(update.OldKey)
        if TextBlockSearchIndex.Has(update.OldKey)
            TextBlockSearchIndex.Delete(update.OldKey)
        update.Item.Path := update.NewPath
        TextBlockUsage[PathKey(update.NewPath)] := update.Item
    }
    SaveTextBlockUsage()
    return true
}

EnsureTextBlockUsage(path) {
    global TextBlockUsage
    key := PathKey(path)
    if !TextBlockUsage.Has(key)
        TextBlockUsage[key] := {Path: NormalizePath(path), LastUsed: "",
            Total: 0, WindowStart: "", WindowCount: 0, NewUntil: ""}
    return TextBlockUsage[key]
}

MarkTextBlockNew(path) {
    item := EnsureTextBlockUsage(path)
    item.NewUntil := DateAdd(A_Now, 24, "Hours")
    try SaveTextBlockUsage()
}

RecordTextBlockUse(path) {
    static lastPath := "", lastTick := 0
    if !IsTextBlockPath(path)
        return
    key := PathKey(path)
    if key = lastPath && A_TickCount - lastTick < 10000
        return
    lastPath := key
    lastTick := A_TickCount
    item := EnsureTextBlockUsage(path)
    if item.WindowStart = ""
        || Abs(DateDiff(A_Now, item.WindowStart, "Days")) >= 30 {
        item.WindowStart := A_Now
        item.WindowCount := 0
    }
    item.LastUsed := A_Now
    item.Total += 1
    item.WindowCount += 1
    item.NewUntil := ""
    try SaveTextBlockUsage()
}

TextBlockSmartScore(path) {
    global TextBlockUsage
    key := PathKey(path)
    if !TextBlockUsage.Has(key)
        return 0
    item := TextBlockUsage[key]
    score := 0.0
    if item.NewUntil != "" && item.NewUntil > A_Now
        score += 250
    if item.LastUsed != "" {
        days := Max(0, Abs(DateDiff(A_Now, item.LastUsed, "Seconds")) / 86400)
        score += 100 * (0.5 ** (days / 14))
    }
    score += 15 * Ln(1 + Max(0, item.WindowCount))
    score += 5 * Ln(1 + Max(0, item.Total))
    return score
}

CompareTextBlockFiles(a, b, sortMode := "Smart") {
    global SORT_MODIFIED_DESC, SORT_NAME_ASC
    if sortMode = SORT_NAME_ASC
        return StrCmpLogicalW(a.Name, b.Name)
    if sortMode = SORT_MODIFIED_DESC {
        if a.Modified > b.Modified
            return -1
        if a.Modified < b.Modified
            return 1
        return StrCmpLogicalW(a.Name, b.Name)
    }
    scoreA := TextBlockSmartScore(a.Path)
    scoreB := TextBlockSmartScore(b.Path)
    if scoreA > scoreB
        return -1
    if scoreA < scoreB
        return 1
    if a.Modified > b.Modified
        return -1
    if a.Modified < b.Modified
        return 1
    return StrCmpLogicalW(a.Name, b.Name)
}

SortTextBlockFiles(&files, sortMode := "Smart") {
    if files.Length <= 1
        return
    width := 1
    while width < files.Length {
        merged := []
        left := 1
        while left <= files.Length {
            middle := Min(left + width, files.Length + 1)
            rightEnd := Min(left + width * 2, files.Length + 1)
            li := left
            ri := middle
            while li < middle || ri < rightEnd {
                if ri >= rightEnd
                    || (li < middle
                        && CompareTextBlockFiles(
                            files[li], files[ri], sortMode) <= 0) {
                    merged.Push(files[li++])
                } else
                    merged.Push(files[ri++])
            }
            left := rightEnd
        }
        files := merged
        width *= 2
    }
}

TextBlockTitleFromPath(path) {
    SplitPath(path, &name, , &extension, &stem)
    return stem != "" ? stem : name
}

ReadTextBlock(path, maxBytes := 2097152) {
    if !IsTextBlockPath(path)
        throw Error("不是可用的文本块文件：" path)
    size := FileGetSize(path)
    if size > maxBytes
        throw Error("文本块超过 " Round(maxBytes / 1048576, 1) " MiB 上限。")
    raw := FileRead(path, "RAW")
    if raw.Size >= 2 && NumGet(raw, 0, "ushort") = 0xFEFF {
        RejectEmbeddedUtf16Null(raw, 2)
        return StrGet(raw.Ptr + 2, (raw.Size - 2) // 2, "UTF-16")
    }
    if raw.Size >= 2 && NumGet(raw, 0, "ushort") = 0xFFFE {
        RejectEmbeddedUtf16Null(raw, 2, true)
        ; UTF-16BE is rare; convert pairs in-place before decoding.
        converted := Buffer(raw.Size - 2, 0)
        Loop (raw.Size - 2) // 2 {
            offset := 2 + (A_Index - 1) * 2
            value := (NumGet(raw, offset, "uchar") << 8)
                | NumGet(raw, offset + 1, "uchar")
            NumPut("ushort", value, converted, (A_Index - 1) * 2)
        }
        return StrGet(converted.Ptr, converted.Size // 2, "UTF-16")
    }
    offset := raw.Size >= 3 && NumGet(raw, 0, "uchar") = 0xEF
        && NumGet(raw, 1, "uchar") = 0xBB
        && NumGet(raw, 2, "uchar") = 0xBF ? 3 : 0
    Loop raw.Size - offset {
        if NumGet(raw, offset + A_Index - 1, "uchar") = 0
            throw Error("文本块含有 NUL，可能不是纯文本文件。")
    }
    return DecodeTextBlockBytes(raw.Ptr + offset, raw.Size - offset)
}

RejectEmbeddedUtf16Null(raw, offset, bigEndian := false) {
    count := (raw.Size - offset) // 2
    Loop count {
        value := NumGet(raw, offset + (A_Index - 1) * 2, "ushort")
        if bigEndian
            value := ((value & 0xFF) << 8) | (value >> 8)
        if value = 0
            throw Error("文本块含有 NUL，可能不是纯文本文件。")
    }
}

DecodeTextBlockBytes(pointer, byteCount) {
    if byteCount <= 0
        return ""
    charCount := DllCall("kernel32\MultiByteToWideChar",
        "uint", 65001, "uint", 0x8, "ptr", pointer, "int", byteCount,
        "ptr", 0, "int", 0, "int") ; MB_ERR_INVALID_CHARS
    if !charCount
        return StrGet(pointer, byteCount, "CP0")
    converted := Buffer(charCount * 2, 0)
    if !DllCall("kernel32\MultiByteToWideChar",
        "uint", 65001, "uint", 0x8, "ptr", pointer, "int", byteCount,
        "ptr", converted.Ptr, "int", charCount, "int")
        throw OSError(A_LastError, "无法解码文本块")
    return StrGet(converted.Ptr, charCount, "UTF-16")
}

NormalizeCapturedText(text) {
    text := StrReplace(text, Chr(0), "")
    text := StrReplace(text, "`r`n", "`n")
    text := StrReplace(text, "`r", "`n")
    return Trim(text, " `t`n")
}

NormalizeEditedTextBlock(text) {
    ; Existing files may intentionally begin or end with blank lines so that
    ; pasting inserts separation at the original caret position. Normalize
    ; only representation details; never trim user-authored outer whitespace.
    text := StrReplace(text, Chr(0), "")
    text := StrReplace(text, "`r`n", "`n")
    return StrReplace(text, "`r", "`n")
}

IsGenericTextBlockHeading(text) {
    static generic := Map(
        "角色", true, "任务", true, "目标", true, "背景", true,
        "上下文", true, "要求", true, "规则", true, "限制", true,
        "说明", true, "示例", true, "输入", true, "输出", true,
        "格式", true, "role", true, "task", true, "goal", true,
        "context", true, "requirements", true, "instructions", true,
        "input", true, "output", true)
    folded := StrLower(Trim(text, " `t：:"))
    return generic.Has(folded)
}

CleanTextBlockTitleCandidate(line) {
    line := Trim(line)
    line := RegExReplace(line, "^\s{0,3}(?:#{1,6}|>|[-*+]\s+|\d+[.)]\s+)", "")
    line := RegExReplace(line, "^[`*_~]+|[`*_~]+$", "")
    line := Trim(RegExReplace(line, "\s+", " "))
    if RegExMatch(line, "^([^：:]{1,20})[：:]\s*(.+)$", &match)
        && IsGenericTextBlockHeading(match[1])
        line := Trim(match[2])
    if IsGenericTextBlockHeading(line)
        return ""
    return line
}

MakeTextBlockTitle(text) {
    normalized := NormalizeCapturedText(text)
    frontMatterTitle := TextBlockFrontMatterTitle(normalized)
    if frontMatterTitle != ""
        return TruncateTextBlockTitle(
            SanitizeTextBlockFileName(frontMatterTitle))
    lines := StrSplit(normalized, "`n")
    checked := 0
    for rawLine in lines {
        if Trim(rawLine) = ""
            continue
        if ++checked > 12
            break
        candidate := CleanTextBlockTitleCandidate(rawLine)
        if candidate = "" || RegExMatch(candidate, "^[-=*_~]{3,}$")
            continue
        return TruncateTextBlockTitle(SanitizeTextBlockFileName(candidate))
    }
    return "文本块 " FormatTime(, "yyyy-MM-dd HHmmss")
}

TextBlockFrontMatterTitle(text) {
    lines := StrSplit(text, "`n")
    if lines.Length < 3 || Trim(lines[1]) != "---"
        return ""
    limit := Min(lines.Length, 80)
    index := 2
    while index <= limit {
        line := Trim(lines[index])
        if line = "---" || line = "..."
            return ""
        if RegExMatch(line, "i)^title\s*:\s*(.+)$", &match) {
            title := Trim(match[1])
            if (SubStr(title, 1, 1) = Chr(34)
                && SubStr(title, -1) = Chr(34))
                || (SubStr(title, 1, 1) = "'" && SubStr(title, -1) = "'")
                title := SubStr(title, 2, -1)
            return Trim(title)
        }
        index += 1
    }
    return ""
}

SanitizeTextBlockFileName(name) {
    name := RegExReplace(name, "[<>:`"/\\|?*]", " ")
    name := Trim(RegExReplace(name, "\s+", " "), " .。`t")
    if name = ""
        return "文本块 " FormatTime(, "yyyy-MM-dd HHmmss")
    if RegExMatch(name, "i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$")
        name := "_" name
    return name
}

TruncateTextBlockTitle(text, maxUnits := 48) {
    result := ""
    units := 0
    for char in StrSplit(text) {
        cost := Ord(char) > 127 ? 2 : 1
        if units + cost > maxUnits
            break
        result .= char
        units += cost
    }
    result := Trim(result, " ,，;；:：。.!！?？-")
    return result != "" ? result : "文本块 " FormatTime(, "yyyy-MM-dd HHmmss")
}

WriteNewTextBlock(text, directory) {
    text := NormalizeCapturedText(text)
    if text = ""
        throw Error("拖入的文字为空。")
    if StrPut(text, "UTF-8") - 1 > 2097152
        throw Error("拖入文字超过 2 MiB 上限。")
    DirCreate(directory)
    base := MakeTextBlockTitle(text)
    Loop 1019 {
        if A_Index <= 999 {
            suffix := A_Index = 1 ? "" : " (" A_Index ")"
            path := directory "\" base suffix ".md"
        } else {
            fallback := "文本块 " FormatTime(, "yyyy-MM-dd HHmmss")
                . "-" Format("{:03}", A_MSec)
                . "-" Format("{:04X}", Random(0, 65535))
            path := directory "\" fallback ".md"
        }
        handle := DllCall("kernel32\CreateFileW", "wstr", path,
            "uint", 0x40000000, "uint", 1, "ptr", 0, "uint", 1,
            "uint", 0x80, "ptr", 0, "ptr")
        if handle = -1 {
            if A_LastError = 80 || A_LastError = 183
                continue
            throw OSError(A_LastError, "无法创建文本块")
        }
        try {
            file := FileOpen(handle, "h", "UTF-8-RAW")
            if !IsObject(file)
                throw Error("无法打开新文本块。")
            file.Write(StrReplace(text, "`r`n", "`n"))
            ; FileOpen(handle, "h") only wraps the caller-owned Win32
            ; handle. File.Close() deliberately does not close that handle,
            ; so CloseHandle must still run below on every successful write.
            file.Close()
        } finally {
            if handle
                DllCall("kernel32\CloseHandle", "ptr", handle)
        }
        MarkTextBlockNew(path)
        return path
    }
    throw Error("无法生成不重复的文本块名称。")
}

SaveCapturedTextBlock(text, target) {
    global PinnedPaths
    pin := target.Type = "TextPinned"
    directory := pin ? TextBlockInboxDirectory() : target.Path
    path := WriteNewTextBlock(text, directory)
    if pin {
        original := PinnedPaths.Clone()
        try {
            PinnedPaths.InsertAt(1, path)
            SavePinnedFiles()
        } catch {
            PinnedPaths := original
            try FileDelete(path)
            throw
        }
    }
    InjectCapturedTextBlock(path, target)
    SetUserStatus((pin ? "已保存独立文本块到固定项：" : "已保存文本块到「"
        . target.Name . "」：") TextBlockTitleFromPath(path))
    StartBackgroundScan()
    return path
}

ClipboardTextForPinnedBlock() {
    ; Accept either Unicode or legacy text, but never treat file-only or image
    ; clipboard payloads as text blocks.
    if !DllCall("user32\IsClipboardFormatAvailable", "uint", 13, "int")
        && !DllCall("user32\IsClipboardFormatAvailable", "uint", 1, "int")
        return ""
    try return NormalizeCapturedText(A_Clipboard)
    catch
        return ""
}

UpdateClipboardPinnedButton(dataType := -1) {
    global ClipboardPinnedButton
    if !IsObject(ClipboardPinnedButton)
        return
    hasText := (dataType = -1 || dataType = 1)
        && ClipboardTextForPinnedBlock() != ""
    SetPanelIconButtonEnabled(ClipboardPinnedButton,
        IsTextWorkspace() && hasText)
    ; Some producers briefly retain the clipboard lock while broadcasting the
    ; change. Retry once after the notification instead of leaving a valid
    ; text clipboard disabled until the next workspace switch.
    if dataType = 1 && !hasText
        SetTimer(UpdateClipboardPinnedButton, -80)
}

TextBlockPasteFocusKind() {
    global Panel, FileView
    focused := DllCall("user32\GetFocus", "ptr")
    if !focused
        return "Container"
    if IsObject(FileView) && focused = FileView.Hwnd
        return "Cards"
    if IsObject(Panel) && focused = Panel.Hwnd
        return "Container"
    return "Control"
}

ShouldCaptureTextBlockPaste(panelActive, textWorkspace, focusKind, hasText) {
    return panelActive && textWorkspace && hasText
        && (focusKind = "Cards" || focusKind = "Container")
}

CanPasteClipboardAsPinnedTextBlock(*) {
    return ShouldCaptureTextBlockPaste(
        IsPopDropPanelActive(),
        IsTextWorkspace(),
        TextBlockPasteFocusKind(),
        ClipboardTextForPinnedBlock() != ""
    )
}

AddClipboardTextToPinned(*) {
    text := ClipboardTextForPinnedBlock()
    UpdateClipboardPinnedButton()
    if text = ""
        return false
    target := {Type: "TextPinned", SourceId: "", Name: "固定项",
        Path: "", Available: true, GroupId: 0}
    try {
        SaveCapturedTextBlock(text, target)
        return true
    } catch as err {
        ShowPanelMsgBox("无法保存剪贴板文本：`n" err.Message,
            "添加固定文本块失败", "Iconx")
        return false
    }
}

PasteClipboardAsPinnedTextBlock(*) {
    AddClipboardTextToPinned()
}

InjectCapturedTextBlock(path, target) {
    global CurrentScanResult
    if target.Type = "TextPinned" {
        PopulatePanel()
        return
    }
    for folder in CurrentScanResult.Folders {
        if PathsEqual(folder.Path, target.Path) {
            folder.Files.InsertAt(1, {Path: path, Name: GetFileName(path),
                Modified: FileGetTime(path, "M"), IsDirectory: false,
                TimeKind: "File"})
            break
        }
    }
    PopulatePanel()
}

QueueTextBlockSearchIndex(paths) {
    global TextBlockSearchQueue, TextBlockSearchIndex
    pending := Map()
    for path in TextBlockSearchQueue
        pending[PathKey(path)] := true
    for path in paths {
        key := PathKey(path)
        stamp := TextBlockSearchStamp(path)
        fresh := TextBlockSearchIndex.Has(key)
            && IsObject(TextBlockSearchIndex[key])
            && TextBlockSearchIndex[key].Stamp = stamp
        if !fresh && !pending.Has(key) {
            if TextBlockSearchIndex.Has(key)
                TextBlockSearchIndex.Delete(key)
            TextBlockSearchQueue.Push(path)
            pending[key] := true
        }
    }
    if TextBlockSearchQueue.Length
        SetTimer(BuildNextTextBlockSearchIndex, 10)
}

TextBlockSearchStamp(path) {
    try return FileGetSize(path) "|" FileGetTime(path, "M")
    catch
        return "missing"
}

BuildNextTextBlockSearchIndex() {
    global TextBlockSearchQueue, TextBlockSearchIndex, TextBlockSearchQuery
    global TextBlockSearchTitleOnly
    if !TextBlockSearchQueue.Length {
        SetTimer(BuildNextTextBlockSearchIndex, 0)
        return
    }
    path := TextBlockSearchQueue.RemoveAt(1)
    key := PathKey(path)
    try {
        body := ReadTextBlock(path, 2097152)
        TextBlockSearchIndex[key] := {
            Body: StrLower(body), Stamp: TextBlockSearchStamp(path)}
    } catch {
        TextBlockSearchIndex[key] := {
            Body: "", Stamp: TextBlockSearchStamp(path)}
    }
    if TextBlockSearchQuery != "" && !TextBlockSearchTitleOnly
        ScheduleTextBlockSearchRefresh()
}

ScheduleTextBlockSearchRefresh() {
    global TextBlockSearchRefreshPending
    if TextBlockSearchRefreshPending
        return
    TextBlockSearchRefreshPending := true
    SetTimer(ApplyTextBlockSearchRefresh, -80)
}

ApplyTextBlockSearchRefresh() {
    global TextBlockSearchRefreshPending, TextBlockSearchQuery
    TextBlockSearchRefreshPending := false
    if TextBlockSearchQuery != ""
        PopulatePanel()
}

TextBlockMatchesQuery(file, folder, query) {
    global TextBlockSearchIndex, TextBlockSearchTitleOnly
    terms := TextBlockSearchTerms(query)
    if !terms.Length
        return true
    title := StrLower(TextBlockTitleFromPath(file.Path))
    metadata := StrLower(title . " " folder.Name . " " file.Path)
    key := PathKey(file.Path)
    body := TextBlockSearchIndex.Has(key)
        && IsObject(TextBlockSearchIndex[key])
        ? TextBlockSearchIndex[key].Body : ""
    return TextBlockSearchScopeMatches(
        title, metadata, body, terms, TextBlockSearchTitleOnly)
}

TextBlockSearchScopeMatches(title, metadata, body, terms, titleOnly) {
    ; Title is exactly TextBlockTitleFromPath(), the same extension-free value
    ; rendered by AddTextBlockTile(). Hidden extensions, source names and full
    ; paths must never create a hit in the constrained scope.
    return TextBlockHaystacksMatchTerms(
        titleOnly ? title : metadata,
        titleOnly ? "" : body,
        terms)
}

TextBlockHaystacksMatchTerms(metadata, body, terms) {
    for term in terms {
        if !InStr(metadata, term) && !InStr(body, term)
            return false
    }
    return true
}

TextBlockSearchTerms(query) {
    query := StrReplace(query, "　", " ")
    query := RegExReplace(Trim(query), "\s+", " ")
    if query = ""
        return []
    terms := []
    seen := Map()
    for term in StrSplit(StrLower(query), " ") {
        if term != "" && !seen.Has(term) {
            terms.Push(term)
            seen[term] := true
        }
    }
    return terms
}

ShouldHideTextSourceForSearch(textWorkspace, query, state, fileCount) {
    ; Pending and unavailable sources communicate state rather than a search
    ; miss. Ready sources with zero matches add only noise while a query is
    ; active, so omit the entire native group and its placeholder tile.
    return textWorkspace && Trim(query) != "" && fileCount = 0
        && state != "Pending" && state != "Unavailable"
}

PrepareTextBlockFiles(files, folder, maxCount := 0) {
    global TextBlockSearchQuery
    pinned := []
    ordinary := []
    paths := []
    matchedByKey := Map()
    for file in files {
        if file.IsDirectory || !IsTextBlockPath(file.Path)
            continue
        paths.Push(file.Path)
        if TextBlockMatchesQuery(file, folder, TextBlockSearchQuery)
            matchedByKey[PathKey(file.Path)] := file
    }
    QueueTextBlockSearchIndex(paths)

    ; The persisted list is authoritative for the pinned prefix. Missing or
    ; filtered files remain persisted but are simply absent from this render.
    for path in GetTextSourcePinnedPaths(folder.SourceId) {
        key := PathKey(path)
        if matchedByKey.Has(key) {
            pinned.Push(matchedByKey[key])
            matchedByKey.Delete(key)
        }
    }
    for _, file in matchedByKey
        ordinary.Push(file)
    SortTextBlockFiles(&ordinary, folder.SortMode)
    if TextBlockSearchQuery = "" && maxCount > 0
        while ordinary.Length > maxCount
            ordinary.Pop()
    result := pinned.Clone()
    for file in ordinary
        result.Push(file)
    return result
}

LoadTextSourcePinnedState(workspaces) {
    global ConfigPath
    result := Map()
    for workspace in workspaces {
        for source in workspace.SourceRefs {
            key := StrLower(source.SourceId)
            if result.Has(key)
                continue
            paths := []
            for entry in ReadIniSection("TextSourcePinned:" source.SourceId) {
                if !RegExMatch(entry.Key, "i)^File\d+$")
                    continue
                path := NormalizePath(entry.Value)
                if path != "" && !ArrayContainsPath(paths, path)
                    paths.Push(path)
            }
            result[key] := paths
        }
    }
    return result
}

GetTextSourcePinnedPaths(sourceId) {
    global TextSourcePinnedPaths
    key := StrLower(sourceId)
    return TextSourcePinnedPaths.Has(key) ? TextSourcePinnedPaths[key] : []
}

IsTextSourcePathPinned(sourceId, path) {
    return FindPathIndex(GetTextSourcePinnedPaths(sourceId), path) > 0
}

SaveTextSourcePinnedState() {
    AtomicConfigEdit(WriteTextSourcePinnedState)
}

WriteTextSourcePinnedState(tempPath) {
    global TextSourcePinnedPaths, Workspaces, CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    seen := Map()
    for workspace in Workspaces {
        for source in workspace.SourceRefs {
            key := StrLower(source.SourceId)
            if seen.Has(key)
                continue
            seen[key] := true
            paths := TextSourcePinnedPaths.Has(key)
                ? TextSourcePinnedPaths[key] : []
            WritePinnedPathsToDocument(doc,
                "TextSourcePinned:" source.SourceId, paths, 3)
        }
    }
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

GetSelectedTextSourceItems() {
    global ItemOpenContexts, ItemPaths
    result := []
    for row in GetSelectedFileRows() {
        if !ItemOpenContexts.Has(row) || !ItemPaths.Has(row)
            continue
        context := ItemOpenContexts[row]
        if context.Area != "Source" || !HasProp(context, "SourceId")
            continue
        path := ItemPaths[row]
        if IsTextBlockPath(path)
            result.Push({Path: path, SourceId: context.SourceId})
    }
    return result
}

SetTextSourcePinned(items, shouldPin, *) {
    global TextSourcePinnedPaths
    if !IsObject(items) || !items.Length
        return false
    snapshot := Map()
    changed := 0
    for item in items {
        key := StrLower(item.SourceId)
        if !TextSourcePinnedPaths.Has(key)
            TextSourcePinnedPaths[key] := []
        if !snapshot.Has(key)
            snapshot[key] := TextSourcePinnedPaths[key].Clone()
        paths := TextSourcePinnedPaths[key]
        index := FindPathIndex(paths, item.Path)
        if shouldPin && !index {
            ; Append within the pinned prefix so existing spatial order stays
            ; stable and a native multi-selection keeps its visible order.
            paths.Push(NormalizePath(item.Path))
            changed += 1
        } else if !shouldPin && index {
            paths.RemoveAt(index)
            changed += 1
        }
    }
    if !changed
        return false
    try SaveTextSourcePinnedState()
    catch {
        for key, paths in snapshot
            TextSourcePinnedPaths[key] := paths
        throw
    }
    PopulatePanel()
    SetUserStatus(shouldPin
        ? "已在所属文件夹置顶 " changed " 个文本块"
        : "已取消 " changed " 个文本块的文件夹内置顶")
    return true
}

ReorderTextSourcePinnedPath(sourceId, sourcePath, targetPath, placeAfter) {
    global TextSourcePinnedPaths
    key := StrLower(sourceId)
    if !TextSourcePinnedPaths.Has(key)
        return false
    paths := TextSourcePinnedPaths[key]
    sourceIndex := FindPathIndex(paths, sourcePath)
    targetIndex := FindPathIndex(paths, targetPath)
    if !sourceIndex || !targetIndex || sourceIndex = targetIndex
        return false
    original := paths.Clone()
    moved := paths.RemoveAt(sourceIndex)
    targetIndex := FindPathIndex(paths, targetPath)
    insertIndex := targetIndex + (placeAfter ? 1 : 0)
    paths.InsertAt(insertIndex, moved)
    if PathArraysEqual(original, paths)
        return false
    try SaveTextSourcePinnedState()
    catch {
        TextSourcePinnedPaths[key] := original
        throw
    }
    PopulatePanel()
    return true
}

FindTextSourceRoot(sourceId) {
    global Workspaces
    for workspace in Workspaces
        for source in workspace.SourceRefs
            if StrLower(source.SourceId) = StrLower(sourceId)
                return source.Path
    return ""
}

UpdateTextSourcePinnedPathsAfterMove(mappings) {
    global TextSourcePinnedPaths
    snapshot := Map()
    changed := false
    for sourceKey, paths in TextSourcePinnedPaths {
        snapshot[sourceKey] := paths.Clone()
        sourceRoot := FindTextSourceRoot(sourceKey)
        updated := []
        for path in paths {
            mapped := ResolveMovedPathMapping(path, mappings)
            if mapped = "" {
                updated.Push(path)
                continue
            }
            ; Moving a pinned file out of this source cancels this source's
            ; pin. Moving/renaming inside it keeps the pin and its order.
            if sourceRoot != ""
                && IsSameOrDescendantPath(mapped, sourceRoot)
                updated.Push(mapped)
            changed := true
        }
        TextSourcePinnedPaths[sourceKey] := updated
    }
    if !changed
        return false
    try SaveTextSourcePinnedState()
    catch {
        for key, paths in snapshot
            TextSourcePinnedPaths[key] := paths
        throw
    }
    return true
}

RemoveDeletedTextSourcePinnedPaths(deletedPaths) {
    global TextSourcePinnedPaths
    snapshot := Map()
    changed := false
    for sourceKey, paths in TextSourcePinnedPaths {
        snapshot[sourceKey] := paths.Clone()
        remaining := []
        for path in paths {
            deleted := false
            for deletedPath in deletedPaths {
                if IsSameOrDescendantPath(path, deletedPath) {
                    deleted := true
                    break
                }
            }
            if deleted
                changed := true
            else
                remaining.Push(path)
        }
        TextSourcePinnedPaths[sourceKey] := remaining
    }
    if !changed
        return false
    try SaveTextSourcePinnedState()
    catch {
        for key, paths in snapshot
            TextSourcePinnedPaths[key] := paths
        throw
    }
    return true
}

PreparePinnedTextBlockPaths(paths) {
    global TextBlockSearchQuery
    result := []
    indexPaths := []
    folder := {Name: "固定项", Path: ""}
    for path in paths {
        ; Persisted references stay visible while their target is temporarily
        ; unavailable. Activation reports the failure and the user can still
        ; remove the reference instead of having it disappear silently.
        if !HasTextBlockExtension(path)
            continue
        indexPaths.Push(path)
        file := {Path: path, Name: GetFileName(path), IsDirectory: false}
        if TextBlockMatchesQuery(file, folder, TextBlockSearchQuery)
            result.Push(path)
    }
    QueueTextBlockSearchIndex(indexPaths)
    return result
}

TextBlockCardExcerpt(path) {
    try text := ReadTextBlock(path, 2097152)
    catch
        return ""
    for line in StrSplit(text, "`n") {
        line := CleanTextBlockTitleCandidate(line)
        if line != "" && line != TextBlockTitleFromPath(path)
            return TruncateTextBlockTitle(line, 72)
    }
    return ""
}

AddTextBlockTile(path, groupId) {
    global FileView, ItemLabels
    title := TextBlockTitleFromPath(path)
    row := FileView.Add("", title, TextBlockCardExcerpt(path))
    ItemLabels[row] := title
    SetListItemGroup(row, groupId)
    return row
}

ApplyTextBlockCardView() {
    global FileView, TextBlockCardWidth, TextBlockCardHeight
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
        "uint", 0x108E, "ptr", 4, "ptr", 0, "ptr") ; LV_VIEW_TILE
    info := Buffer(40, 0)
    NumPut("uint", 40, info, 0)
    NumPut("uint", 3, info, 4) ; LVTVIM_TILESIZE | LVTVIM_COLUMNS
    ; Both dimensions are explicit. Native tile text wrapping then consumes
    ; the additional width/height automatically instead of staying at the
    ; previous fixed two-line visual size.
    dpi := DllCall("user32\GetDpiForWindow", "ptr", FileView.Hwnd, "uint")
    if !dpi
        dpi := 96
    cardWidthPx := DllCall("kernel32\MulDiv",
        "int", PanelScale(TextBlockCardWidth),
        "int", dpi, "int", 96, "int")
    cardHeightPx := DllCall("kernel32\MulDiv",
        "int", PanelScale(TextBlockCardHeight),
        "int", dpi, "int", 96, "int")
    NumPut("uint", 3, info, 8) ; LVTVIF_FIXEDWIDTH | LVTVIF_FIXEDHEIGHT
    NumPut("int", cardWidthPx, info, 12)
    NumPut("int", cardHeightPx, info, 16)
    NumPut("int", 3, info, 20)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
        "uint", 0x10A2, "ptr", 0, "ptr", info.Ptr, "ptr")
}

EnsureActiveTextBlockCardView(force := false, *) {
    global FileView
    if !IsTextWorkspace() || !IsObject(FileView) || !FileView.Hwnd
        return false
    currentView := DllCall("user32\SendMessageW", "ptr", FileView.Hwnd,
        "uint", 0x108F, "ptr", 0, "ptr", 0, "ptr") ; LVM_GETVIEW
    if force || currentView != 4
        ApplyTextBlockCardView()
    return true
}

TextBlockSearchChanged(control, *) {
    global TextBlockSearchQuery, TextBlockSelectFirstPending
    query := Trim(control.Value)
    if query != TextBlockSearchQuery
        TextBlockSelectFirstPending := true
    TextBlockSearchQuery := query
    PopulatePanel()
}

TextBlockSearchTitleOnlyChanged(control, *) {
    SetTextBlockSearchTitleOnly(control.Value = 1, true)
}

SetTextBlockSearchTitleOnly(titleOnly, restoreSearchFocus := true) {
    global TextBlockSearchTitleOnly, TextBlockSearchEdit
    global TextBlockSearchTitleOnlyCheck, TextBlockSelectFirstPending
    titleOnly := !!titleOnly
    if IsObject(TextBlockSearchTitleOnlyCheck)
        TextBlockSearchTitleOnlyCheck.Value := titleOnly ? 1 : 0
    if titleOnly != TextBlockSearchTitleOnly {
        TextBlockSearchTitleOnly := titleOnly
        TextBlockSelectFirstPending := true
        InvalidateCachedTextBlockSearchViews()
        PopulatePanel()
    }
    ; The checkbox is a temporary modifier for the Edit. Return the caret and
    ; any existing selection immediately so typing can continue uninterrupted.
    if restoreSearchFocus && IsTextWorkspace()
        && IsObject(TextBlockSearchEdit) {
        selectionStart := 0
        selectionEnd := 0
        DllCall("user32\SendMessageW", "ptr", TextBlockSearchEdit.Hwnd,
            "uint", 0x00B0, "uint*", &selectionStart,
            "uint*", &selectionEnd, "ptr") ; EM_GETSEL
        TextBlockSearchEdit.Focus()
        DllCall("user32\SendMessageW", "ptr", TextBlockSearchEdit.Hwnd,
            "uint", 0x00B1, "ptr", selectionStart,
            "ptr", selectionEnd, "ptr") ; EM_SETSEL
    }
    return true
}

CanToggleTextBlockTitleOnly(*) {
    return IsPopDropPanelActive() && IsTextWorkspace()
}

ToggleTextBlockTitleOnly(*) {
    global Panel, TextBlockSearchEdit, TextBlockSearchTitleOnly
    focused := DllCall("user32\GetFocus", "ptr")
    searchFocused := IsObject(TextBlockSearchEdit)
        && focused = TextBlockSearchEdit.Hwnd
    SetTextBlockSearchTitleOnly(!TextBlockSearchTitleOnly, searchFocused)
    ; Alt+T also works while navigating cards; retain that control focus.
    if !searchFocused && focused && IsObject(Panel)
        && DllCall("user32\IsWindow", "ptr", focused, "int")
        && (focused = Panel.Hwnd || DllCall("user32\IsChild",
            "ptr", Panel.Hwnd, "ptr", focused, "int"))
        DllCall("user32\SetFocus", "ptr", focused, "ptr")
    return true
}

InvalidateCachedTextBlockSearchViews() {
    global WorkspaceFileViewStates
    ; “仅标题” belongs to the current visible panel session, not to an
    ; individual workspace. Cached inactive views may have been rendered with
    ; the previous scope, so mark them stale without restoring scope from them.
    for _, state in WorkspaceFileViewStates {
        if HasProp(state, "RenderSignature")
            state.RenderSignature := ""
        if HasProp(state, "SelectFirstPending")
            state.SelectFirstPending := true
    }
}

ClearTextBlockSearch(refresh := true, *) {
    global TextBlockSearchEdit, TextBlockSearchQuery
    global TextBlockSelectFirstPending
    ResetTextBlockImeComposition()
    if TextBlockSearchQuery = ""
        return false
    TextBlockSearchQuery := ""
    TextBlockSelectFirstPending := true
    if IsObject(TextBlockSearchEdit)
        TextBlockSearchEdit.Value := ""
    if refresh
        PopulatePanel()
    return true
}

ResetTextBlockSearchSession(refresh := true, *) {
    global TextBlockSearchTitleOnly, TextBlockSearchTitleOnlyCheck
    global TextBlockSelectFirstPending, WorkspaceFileViewStates
    queryChanged := ClearTextBlockSearch(false)
    scopeChanged := TextBlockSearchTitleOnly
    TextBlockSearchTitleOnly := false
    TextBlockSelectFirstPending := true
    if IsObject(TextBlockSearchTitleOnlyCheck)
        TextBlockSearchTitleOnlyCheck.Value := 0
    ; Inactive hot views belong to the same visible session. Invalidate every
    ; cached query so reopening cannot resurrect a search from another text
    ; workspace that happened not to be active when the panel was hidden.
    for _, state in WorkspaceFileViewStates {
        if HasProp(state, "SearchQuery") && state.SearchQuery != "" {
            state.SearchQuery := ""
            state.SelectFirstPending := true
            state.RenderSignature := ""
        }
    }
    if refresh && (queryChanged || scopeChanged)
        PopulatePanel()
    return queryChanged || scopeChanged
}

FocusTextBlockSearch(*) {
    global TextBlockSearchEdit
    if IsTextWorkspace() && IsObject(TextBlockSearchEdit) {
        TextBlockSearchEdit.Visible := true
        TextBlockSearchEdit.Focus()
        DllCall("user32\SendMessageW", "ptr", TextBlockSearchEdit.Hwnd,
            "uint", 0x00B1, "ptr", 0, "ptr", -1, "ptr") ; EM_SETSEL all
    }
}

RestoreTextBlockSearchFocus(*) {
    ; AHK keeps the last focused child control when a hidden Gui is shown
    ; again. Re-establish the text workspace's input contract on every summon
    ; or workspace activation, even if a toolbar button owned focus before.
    if IsPopDropPanelActive() && IsTextWorkspace()
        FocusTextBlockSearch()
}

SelectDefaultTextBlockSearchResult(forceFirst := false, *) {
    global FileView, ItemPaths
    if !IsObject(FileView)
        return 0
    if !forceFirst {
        selected := FileView.GetNext(0)
        if selected && ItemPaths.Has(selected)
            && HasTextBlockExtension(ItemPaths[selected])
            return selected
    }
    FileView.Modify(0, "-Select -Focus")
    Loop FileView.GetCount() {
        if !ItemPaths.Has(A_Index)
            || !HasTextBlockExtension(ItemPaths[A_Index])
            continue
        ; Select for visible feedback but deliberately leave keyboard focus in
        ; the Edit control so subsequent characters continue the query.
        FileView.Modify(A_Index, "Select Vis")
        return A_Index
    }
    return 0
}

IsTextBlockSearchResultReady(*) {
    global FileView, ItemPaths
    searchActive := IsTextBlockSearchActive()
    row := IsObject(FileView) ? FileView.GetNext(0) : 0
    resultReady := row && ItemPaths.Has(row)
    imeComposing := searchActive && IsTextBlockSearchImeComposing()
    return ShouldActivateTextBlockSearchResult(
        searchActive, resultReady, imeComposing)
}

ShouldActivateTextBlockSearchResult(searchActive, resultReady,
    imeComposing) {
    return searchActive && resultReady && !imeComposing
}

ActivateTextBlockSearchResult(*) {
    global FileView, ItemPaths
    row := IsObject(FileView) ? FileView.GetNext(0) : 0
    if row && ItemPaths.Has(row)
        QuickSendTextBlocks([ItemPaths[row]])
}

ActivateTextBlockSearchResultPrepend(*) {
    global FileView, ItemPaths
    row := IsObject(FileView) ? FileView.GetNext(0) : 0
    if row && ItemPaths.Has(row)
        PrependTextBlocks([ItemPaths[row]])
}

IsTextBlockSearchActive(*) {
    global TextBlockSearchEdit, PanelVisible
    return PanelVisible && IsTextWorkspace()
        && IsObject(TextBlockSearchEdit)
        && DllCall("user32\GetFocus", "ptr") = TextBlockSearchEdit.Hwnd
}

CanFocusTextBlockSearch(*) {
    return IsPopDropPanelActive() && IsTextWorkspace()
        && !IsTextBlockSearchActive()
}

FocusTextBlockResults(*) {
    global FileView, ItemPaths
    if IsObject(FileView) {
        FileView.Focus()
        row := FileView.GetNext(0)
        if !row {
            Loop FileView.GetCount() {
                if ItemPaths.Has(A_Index) {
                    row := A_Index
                    break
                }
            }
        }
        if row
            FileView.Modify(row, "Select Focus Vis")
    }
}

TextBlockCharInput(wParam, lParam, msg, hwnd) {
    global FileView, TextBlockSearchEdit, TextBlockSearchQuery, PanelVisible
    global TextBlockSelectFirstPending
    if !PanelVisible || !IsTextWorkspace() || !IsObject(FileView)
        || hwnd != FileView.Hwnd || !IsObject(TextBlockSearchEdit)
        return
    if wParam = 8 {
        if StrLen(TextBlockSearchQuery) {
            TextBlockSearchEdit.Value := SubStr(TextBlockSearchQuery, 1, -1)
            TextBlockSearchQuery := TextBlockSearchEdit.Value
            TextBlockSelectFirstPending := true
            PopulatePanel()
        }
        return 0
    }
    if wParam < 32
        return
    TextBlockSearchEdit.Visible := true
    TextBlockSearchEdit.Focus()
    TextBlockSearchEdit.Value .= Chr(wParam)
    DllCall("user32\SendMessageW", "ptr", TextBlockSearchEdit.Hwnd,
        "uint", 0x00B1, "ptr", -1, "ptr", -1, "ptr") ; select end
    return 0
}

TextBlockImeStart(wParam, lParam, msg, hwnd) {
    global FileView, TextBlockSearchEdit, PanelVisible
    global TextBlockImeComposing
    if PanelVisible && IsTextWorkspace() && IsObject(FileView)
        && IsObject(TextBlockSearchEdit)
        && (hwnd = FileView.Hwnd || hwnd = TextBlockSearchEdit.Hwnd) {
        TextBlockImeComposing := true
        if hwnd = FileView.Hwnd
            TextBlockSearchEdit.Focus()
    }
}

TextBlockImeEnd(wParam, lParam, msg, hwnd) {
    global FileView, TextBlockSearchEdit, TextBlockImeComposing
    if (IsObject(TextBlockSearchEdit) && hwnd = TextBlockSearchEdit.Hwnd)
        || (IsObject(FileView) && hwnd = FileView.Hwnd)
        TextBlockImeComposing := false
}

ResetTextBlockImeComposition(*) {
    global TextBlockImeComposing
    TextBlockImeComposing := false
}

ResetTextBlockImeCompositionForFocusLoss(hwnd) {
    global TextBlockSearchEdit
    if IsObject(TextBlockSearchEdit) && hwnd = TextBlockSearchEdit.Hwnd
        ResetTextBlockImeComposition()
}

IsTextBlockSearchImeComposing(*) {
    global TextBlockSearchEdit, TextBlockImeComposing
    if !IsTextBlockSearchActive() || !IsObject(TextBlockSearchEdit)
        return false

    ; Standard Win32 Edit controls expose the live composition through IMM32,
    ; including modern IMEs using the Windows compatibility bridge.  Message
    ; state remains a fallback for providers which do not expose composition
    ; bytes through that bridge.
    context := DllCall("imm32\ImmGetContext",
        "ptr", TextBlockSearchEdit.Hwnd, "ptr")
    if !context
        return TextBlockImeComposing
    try {
        compositionBytes := DllCall("imm32\ImmGetCompositionStringW",
            "ptr", context, "uint", 0x0008,
            "ptr", 0, "uint", 0, "int") ; GCS_COMPSTR
        readingBytes := DllCall("imm32\ImmGetCompositionStringW",
            "ptr", context, "uint", 0x0001,
            "ptr", 0, "uint", 0, "int") ; GCS_COMPREADSTR
        return compositionBytes > 0 || readingBytes > 0
            || TextBlockImeComposing
    } finally {
        DllCall("imm32\ImmReleaseContext",
            "ptr", TextBlockSearchEdit.Hwnd, "ptr", context, "int")
    }
}

JoinTextBlocks(paths) {
    parts := []
    for path in paths {
        if IsTextBlockPath(path)
            parts.Push(ReadTextBlock(path))
    }
    return JoinArray(parts, "`r`n`r`n")
}

CopyTextBlocks(paths, *) {
    try text := JoinTextBlocks(paths)
    catch as err {
        ShowPanelMsgBox(err.Message, "复制文本块失败", "Iconx")
        return false
    }
    if text = ""
        return false
    return PutTextBlocksOnClipboard(paths, text, "已复制")
}

PutTextBlocksOnClipboard(paths, text, statusPrefix := "已复制") {
    A_Clipboard := text
    if !ClipWait(1)
        return false
    for path in paths
        RecordTextBlockUse(path)
    SetUserStatus(statusPrefix " " paths.Length " 个文本块")
    return true
}

CaptureTextBlockReturnTarget() {
    global TextBlockReturnWindow, TextBlockReturnFocus
    try {
        TextBlockReturnWindow := WinGetID("A")
        TextBlockReturnFocus := GetGuiThreadFocus(TextBlockReturnWindow)
    } catch {
        TextBlockReturnWindow := 0
        TextBlockReturnFocus := 0
    }
}

QuickSendTextBlocks(paths, *) {
    return SendTextBlocksToReturnTarget(paths, false)
}

PrependTextBlocks(paths, *) {
    return SendTextBlocksToReturnTarget(paths, true)
}

SendTextBlocksToReturnTarget(paths, prepend := false) {
    global TextBlockSendInProgress
    if TextBlockSendInProgress {
        TrayTip("上一笔文本块发送尚未结束，请稍后重试。",
            "PopDrop", 0x2)
        return false
    }
    TextBlockSendInProgress := true
    try {
        return SendTextBlocksToReturnTargetUnlocked(paths, prepend)
    } finally {
        TextBlockSendInProgress := false
    }
}

SendTextBlocksToReturnTargetUnlocked(paths, prepend := false) {
    global TextBlockReturnWindow, TextBlockReturnFocus, Panel
    try originalText := JoinTextBlocks(paths)
    catch as err {
        ShowPanelMsgBox(err.Message, "发送文本块失败", "Iconx")
        return false
    }
    if originalText = ""
        return false
    target := TextBlockReturnWindow
    terminalHost := false
    if target && (!IsObject(Panel) || target != Panel.Hwnd)
        terminalHost := DetectSupportedTerminalHost(target)
    sendText := IsObject(terminalHost)
        ? NormalizeTerminalSendText(originalText) : originalText

    if IsObject(terminalHost) && !TerminalTextHasMeaningfulContent(sendText) {
        ; The cleaned terminal value is the only fallback value. Empty text
        ; cannot satisfy ClipWait, so assign it directly and stop.
        A_Clipboard := sendText
        SetUserStatus("终端正文清理后为空，已停止发送")
        return false
    }
    if !PutTextBlocksOnClipboard(paths, sendText,
        IsObject(terminalHost) ? "已准备终端发送" : "已复制")
        return false

    if !target || (IsObject(Panel) && target = Panel.Hwnd) {
        if prepend
            TrayTip("无法确定原输入窗口；正文已保留在剪贴板。",
                "PopDrop", 0x2)
        return !prepend
    }
    if !DllCall("user32\IsWindow", "ptr", target, "int") {
        TrayTip("原输入窗口已关闭；正文已保留在剪贴板。",
            "PopDrop", 0x2)
        return false
    }
    if prepend && !IsObject(terminalHost) && (!TextBlockReturnFocus
        || !DllCall("user32\IsWindow",
            "ptr", TextBlockReturnFocus, "int")) {
        TrayTip("无法可靠定位原输入位置；正文已保留在剪贴板。",
            "PopDrop", 0x2)
        return false
    }
    if IsObject(terminalHost) && TerminalTextHasLineBreak(sendText)
        && !IsHighConfidenceChineseNaturalLanguage(sendText) {
        answer := ShowPanelMsgBox(
            "正文包含内部换行。粘贴到终端可能立即提交或执行一条或多条命令。"
            . "`n`nPopDrop 的判断不是命令安全审查。确认仍要粘贴吗？"
            . "`n`n选择“否”后，已清理的正文仍保留在剪贴板。",
            "确认向终端粘贴多行文本", "YesNo Default2 Icon!")
        if answer != "Yes" {
            SetUserStatus("已取消终端多行发送；正文保留在剪贴板")
            return false
        }
    }
    if IsPasswordEditControl(TextBlockReturnFocus) {
        TrayTip("安全输入框不执行自动粘贴；正文已保留在剪贴板。",
            "PopDrop", 0x2)
        return false
    }
    if IsObject(terminalHost) && A_Clipboard != sendText {
        ; A modal confirmation can keep this transaction alive longer than a
        ; normal send. Re-assert exactly this transaction's cleaned body before
        ; activating the terminal; never paste unrelated clipboard contents.
        A_Clipboard := sendText
        if !ClipWait(1) {
            TrayTip("无法恢复待发送正文；已停止终端投送。",
                "PopDrop", 0x2)
            return false
        }
    }
    HidePanel()
    try {
        WinActivate("ahk_id " target)
        if !WinWaitActive("ahk_id " target, , 0.8)
            throw Error("无法恢复原窗口。")
        focusRestored := RestoreTextBlockReturnFocus(
            target, TextBlockReturnFocus)
        if prepend && !IsObject(terminalHost) && !focusRestored
            throw Error("无法可靠恢复原输入位置。")
        activeFocus := GetGuiThreadFocus(target)
        if prepend && !IsObject(terminalHost)
            && activeFocus != TextBlockReturnFocus
            throw Error("原输入位置已改变。")
        if IsPasswordEditControl(activeFocus)
            throw Error("安全输入框不执行自动粘贴。")
        if IsObject(terminalHost) {
            ; A terminal has no host-independent editable "start" position.
            ; Prepend send therefore uses the same safe current-pane paste and
            ; never emits Ctrl+Home, which could scroll or alter an app.
            PasteTextToSupportedTerminal(terminalHost)
        } else if prepend {
            MoveTextBlockCaretToStart(activeFocus)
            Send("^v")
        } else
            Send("^v")
        return true
    } catch as err {
        TrayTip("正文已保留在剪贴板，请手动粘贴。`n" err.Message,
            "PopDrop", 0x2)
        return false
    }
}

MoveTextBlockCaretToStart(focusHwnd) {
    try className := WinGetClass("ahk_id " focusHwnd)
    catch
        className := ""
    if RegExMatch(className, "i)(?:^Edit$|RichEdit)") {
        ; Native Edit/RichEdit controls support an exact, verifiable caret
        ; move without changing their text. This avoids depending on an
        ; application's keyboard accelerator handling.
        DllCall("user32\SendMessageW", "ptr", focusHwnd,
            "uint", 0x00B1, "ptr", 0, "ptr", 0, "ptr") ; EM_SETSEL
        selectionStart := 0
        selectionEnd := 0
        DllCall("user32\SendMessageW", "ptr", focusHwnd,
            "uint", 0x00B0, "uint*", &selectionStart,
            "uint*", &selectionEnd, "ptr") ; EM_GETSEL
        if selectionStart != 0 || selectionEnd != 0
            throw Error("目标输入框未接受前置定位。")
        DllCall("user32\SendMessageW", "ptr", focusHwnd,
            "uint", 0x00B7, "ptr", 0, "ptr", 0, "ptr") ; EM_SCROLLCARET
        return true
    }
    ; Browser, Electron and other custom editors generally expose only a
    ; focused rendering HWND. Ctrl+Home is their shared keyboard contract.
    Send("^{Home}")
    return true
}

GetGuiThreadFocus(windowHwnd) {
    if !windowHwnd
        return 0
    threadId := DllCall("user32\GetWindowThreadProcessId",
        "ptr", windowHwnd, "ptr", 0, "uint")
    size := A_PtrSize = 8 ? 72 : 48
    info := Buffer(size, 0)
    NumPut("uint", size, info, 0)
    if !DllCall("user32\GetGUIThreadInfo", "uint", threadId,
        "ptr", info.Ptr, "int")
        return 0
    return NumGet(info, 8 + A_PtrSize, "ptr")
}

IsPasswordEditControl(hwnd) {
    if !hwnd || !DllCall("user32\IsWindow", "ptr", hwnd, "int")
        return false
    try className := WinGetClass("ahk_id " hwnd)
    catch
        return false
    if !RegExMatch(className, "i)(?:^Edit$|RichEdit)")
        return false
    style := A_PtrSize = 8
        ? DllCall("user32\GetWindowLongPtrW", "ptr", hwnd,
            "int", -16, "ptr")
        : DllCall("user32\GetWindowLongW", "ptr", hwnd,
            "int", -16, "uint")
    return (style & 0x20) != 0 ; ES_PASSWORD
}

RestoreTextBlockReturnFocus(windowHwnd, focusHwnd) {
    if !focusHwnd || !DllCall("user32\IsWindow", "ptr", focusHwnd, "int")
        return false
    targetThread := DllCall("user32\GetWindowThreadProcessId",
        "ptr", windowHwnd, "ptr", 0, "uint")
    currentThread := DllCall("kernel32\GetCurrentThreadId", "uint")
    attached := targetThread != currentThread
        && DllCall("user32\AttachThreadInput", "uint", currentThread,
            "uint", targetThread, "int", 1, "int")
    try {
        DllCall("user32\SetFocus", "ptr", focusHwnd, "ptr")
        return DllCall("user32\GetFocus", "ptr") = focusHwnd
    }
    finally {
        if attached
            DllCall("user32\AttachThreadInput", "uint", currentThread,
                "uint", targetThread, "int", 0)
    }
}

OpenTextBlockEditor(path, *) {
    if !IsTextBlockPath(path)
        return
    try text := ReadTextBlock(path)
    catch as err {
        ShowPanelMsgBox(err.Message, "无法编辑文本块", "Iconx")
        return
    }
    editor := Gui("+Resize +MinSize520x360", "编辑文本块 · " TextBlockTitleFromPath(path))
    editor.SetFont("s10", "Microsoft YaHei UI")
    body := editor.AddEdit("xm ym w680 h430 Multi WantTab", text)
    save := editor.AddButton("xm y+10 w88 Default", "保存")
    saveCopy := editor.AddButton("x+8 yp w108", "另存为副本")
    external := editor.AddButton("x+8 yp w130", "默认编辑器打开")
    close := editor.AddButton("x+8 yp w88", "关闭")
    state := {Gui: editor, Body: body, Path: path,
        OriginalModified: FileGetTime(path, "M"), OriginalText: text,
        HotkeyCriterion: "ahk_id " editor.Hwnd}
    save.OnEvent("Click", SaveTextBlockEditor.Bind(state))
    saveCopy.OnEvent("Click", SaveTextBlockCopy.Bind(state))
    external.OnEvent("Click", OpenItemWithDefaultApplication.Bind(path))
    close.OnEvent("Click", RequestCloseTextBlockEditor.Bind(state))
    editor.OnEvent("Size", ResizeTextBlockEditor.Bind(state))
    editor.OnEvent("Close", RequestCloseTextBlockEditor.Bind(state))
    editor.OnEvent("Escape", RequestCloseTextBlockEditor.Bind(state))
    HotIfWinActive(state.HotkeyCriterion)
    Hotkey("^s", SaveTextBlockEditor.Bind(state), "On")
    HotIf()
    editor.Show("w710 h500")
}

ResizeTextBlockEditor(state, guiObj, minMax, width, height) {
    if minMax = -1
        return
    state.Body.Move(12, 12, Max(200, width - 24), Max(200, height - 70))
}

SaveTextBlockEditor(state, *) {
    global TextBlockSearchIndex
    if !FileExist(state.Path)
        return ShowPanelMsgBox("源文件已不存在。", "保存失败", "Iconx")
    if FileGetTime(state.Path, "M") != state.OriginalModified
        && ShowPanelMsgBox("文件已被其他程序修改，仍要覆盖吗？",
            "外部修改", "YesNo Default2 Icon!") != "Yes"
        return
    text := NormalizeEditedTextBlock(state.Body.Value)
    temp := state.Path ".popdrop-writing"
    try {
        try FileDelete(temp)
        FileAppend(text, temp, "UTF-8-RAW")
        if !DllCall("kernel32\ReplaceFileW", "wstr", state.Path,
            "wstr", temp, "ptr", 0, "uint", 0x2,
            "ptr", 0, "ptr", 0, "int")
            throw OSError(A_LastError, "无法原子保存文本块")
        state.OriginalModified := FileGetTime(state.Path, "M")
        state.OriginalText := state.Body.Value
        key := PathKey(state.Path)
        if TextBlockSearchIndex.Has(key)
            TextBlockSearchIndex.Delete(key)
        SetUserStatus("文本块已保存")
        StartBackgroundScan()
        return true
    } catch as err {
        try FileDelete(temp)
        ShowPanelMsgBox(err.Message, "保存失败", "Iconx")
        return false
    }
}

SaveTextBlockCopy(state, *) {
    SplitPath(state.Path, , &directory)
    selected := SelectPanelFile("S16", directory,
        "另存文本块副本", "Markdown / 文本 (*.md; *.txt)")
    if selected = ""
        return false
    SplitPath(selected, , , &extension)
    if extension = ""
        selected .= ".md"
    if FileExist(selected) {
        ShowPanelMsgBox("目标文件已存在；为避免覆盖，请选择其他名称。",
            "另存为副本", "Icon!")
        return false
    }
    try {
        text := NormalizeEditedTextBlock(state.Body.Value)
        handle := DllCall("kernel32\CreateFileW", "wstr", selected,
            "uint", 0x40000000, "uint", 1, "ptr", 0, "uint", 1,
            "uint", 0x80, "ptr", 0, "ptr")
        if handle = -1
            throw OSError(A_LastError, "无法创建文本块副本")
        try {
            file := FileOpen(handle, "h", "UTF-8-RAW")
            if !IsObject(file)
                throw Error("无法写入文本块副本。")
            file.Write(text)
            ; "h" mode does not transfer ownership of the native handle.
            file.Close()
        } finally {
            if handle
                DllCall("kernel32\CloseHandle", "ptr", handle)
        }
        MarkTextBlockNew(selected)
        SetUserStatus("已另存文本块副本：" GetFileName(selected))
        StartBackgroundScan()
        return true
    } catch as err {
        ShowPanelMsgBox(err.Message, "另存为副本失败", "Iconx")
        return false
    }
}

RequestCloseTextBlockEditor(state, *) {
    if state.Body.Value != state.OriginalText
        && ShowPanelMsgBox("文本块有尚未保存的修改。仍要关闭吗？",
            "关闭编辑器", "YesNo Default2 Icon!") != "Yes"
        return true
    HotIfWinActive(state.HotkeyCriterion)
    try Hotkey("^s", "Off")
    HotIf()
    state.Gui.Destroy()
    return true
}

RemovePinnedTextBlocks(paths) {
    global PinnedPaths
    drafts := []
    references := []
    for path in paths {
        if IsTextBlockDraftPath(path) && FileExist(path)
            drafts.Push(path)
        else
            references.Push(path)
    }
    if drafts.Length {
        text := drafts.Length = 1 ? "这个独立文本块" : drafts.Length " 个独立文本块"
        if ShowPanelMsgBox("从固定项移除 " text
            . " 会同时把源文件移入回收站。是否继续？",
            "删除独立文本块", "YesNo Default2 Icon!") != "Yes"
            return false
        ; Remove the card and stop preview work before asking the Shell to
        ; recycle its backing file. This prevents the UI process from
        ; re-reading the draft while IFileOperation is acquiring it.
        originalBeforeDelete := PinnedPaths.Clone()
        PreviewSuppress("delete-text-block", false)
        CloseExternalQuickPreview()
        for path in drafts {
            index := FindPathIndex(PinnedPaths, path)
            if index
                PinnedPaths.RemoveAt(index)
        }
        try {
            SavePinnedFiles()
            PopulatePanel()
        } catch as err {
            PinnedPaths := originalBeforeDelete
            throw err
        }
        result := PerformRecycleDelete(drafts)
        if !result.Changed {
            PinnedPaths := originalBeforeDelete
            try SavePinnedFiles()
            PopulatePanel()
            return false
        }
    }
    original := PinnedPaths.Clone()
    for path in paths {
        index := FindPathIndex(PinnedPaths, path)
        if index
            PinnedPaths.RemoveAt(index)
    }
    try SavePinnedFiles()
    catch {
        PinnedPaths := original
        throw
    }
    PopulatePanel()
    SetUserStatus("已从固定项移除 " paths.Length " 个文本块")
    return true
}

ShowTextBlockContextMenu(paths, clickedPath, ownerHwnd, x, y) {
    global PinnedPaths
    contextMenu := Menu()
    contextMenu.Add("快速发送`tEnter", QuickSendTextBlocks.Bind(paths.Clone()))
    contextMenu.Add("前置发送`tCtrl+Enter",
        PrependTextBlocks.Bind(paths.Clone()))
    contextMenu.Add("复制正文`tCtrl+C", CopyTextBlocks.Bind(paths.Clone()))
    if paths.Length = 1 {
        contextMenu.Add("编辑文本块`tF4", OpenTextBlockEditor.Bind(paths[1]))
        contextMenu.Add("使用默认编辑器打开",
            OpenItemWithDefaultApplication.Bind(paths[1]))
    }
    contextMenu.Add()
    if paths.Length = 1 {
        contextMenu.Add("在文件管理器中显示",
            RevealItemsFromPopDropMenu.Bind(paths.Clone()))
    }
    addCount := 0
    removeCount := 0
    for path in paths {
        if FindPathIndex(PinnedPaths, path)
            removeCount += 1
        else
            addCount += 1
    }
    addText := "添加到固定项"
    removeText := "从固定项移除"
    contextMenu.Add(addText, AddSelectionToPinned.Bind(paths.Clone()))
    contextMenu.Add(removeText, RemoveSelectionFromPinned.Bind(paths.Clone()))
    if !addCount
        contextMenu.Disable(addText)
    if !removeCount
        contextMenu.Disable(removeText)
    sourceItems := GetSelectedTextSourceItems()
    pinCount := 0
    unpinCount := 0
    for item in sourceItems {
        if IsTextSourcePathPinned(item.SourceId, item.Path)
            unpinCount += 1
        else
            pinCount += 1
    }
    pinText := "在当前文件夹置顶"
    unpinText := "取消置顶"
    contextMenu.Add(pinText,
        SetTextSourcePinned.Bind(sourceItems, true))
    contextMenu.Add(unpinText,
        SetTextSourcePinned.Bind(sourceItems, false))
    if !pinCount
        contextMenu.Disable(pinText)
    if !unpinCount
        contextMenu.Disable(unpinText)
    contextMenu.Add()
    renameText := "重命名…"
    contextMenu.Add(renameText,
        RequestRenamePath.Bind(paths.Length = 1 ? paths[1] : ""))
    if paths.Length != 1
        contextMenu.Disable(renameText)
    contextMenu.Add("删除`tDelete",
        DeletePathsToRecycleBin.Bind(paths.Clone()))
    point := MenuScreenPoint(ownerHwnd, x, y)
    BeginAutoHidePause()
    try {
        CoordMode("Menu", "Screen")
        contextMenu.Show(point.X, point.Y)
    } finally EndAutoHidePause()
}
