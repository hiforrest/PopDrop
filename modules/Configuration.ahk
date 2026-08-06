; PopDrop configuration bootstrap, migration, validation and filtering.

ConfigDefaultValue(section, key, fallback := "") {
    global ConfigExamplePath
    if !IsSet(ConfigExamplePath) || !FileExist(ConfigExamplePath)
        return fallback
    try value := IniRead(ConfigExamplePath, section, key, fallback)
    catch
        return fallback
    return value
}

ConfigDefaultBoolean(section, key, fallback := false) {
    raw := Trim(ConfigDefaultValue(section, key, fallback ? "1" : "0"))
    return raw = "1" ? true : raw = "0" ? false : fallback
}

ConfigDefaultInteger(section, key, fallback := 0) {
    try return Integer(Trim(ConfigDefaultValue(section, key, fallback)))
    catch
        return fallback
}

EnsureConfig() {
    global ConfigPath, ConfigExamplePath, CONFIG_VERSION
    ; Keep startup self-contained: compiled and source launches may enter
    ; configuration before the main script has initialized optional globals.
    if !IsSet(ConfigExamplePath) || ConfigExamplePath = ""
        ConfigExamplePath := A_ScriptDir "\config.example.ini"
    if FileExist(ConfigPath) {
        EnsureConfigEncoding()
        if ConfigLayoutNeedsNormalization()
            AtomicConfigEdit(NormalizeConfigDocument)
        return
    }
    if !FileExist(ConfigExamplePath)
        throw Error("缺少默认配置文件 config.example.ini，无法创建 config.ini。")
    ; config.example.ini is the single source of truth for initial defaults.
    FileCopy(ConfigExamplePath, ConfigPath, 1)
    EnsureConfigEncoding()
}

EnsureWorkspaceConfig() {
    global ConfigPath
    doc := OpenPopDropConfig(ConfigPath)
    order := ParseStableIdOrder(doc.GetValue("Workspaces", "Order", ""))
    if order.Length {
        ValidateWorkspaceDocument(doc, order)
        if doc.GetValue("Workspaces", "PinnedScopeVersion", "") != "1" {
            if FileExist(ConfigPath)
                FileCopy(ConfigPath, ConfigPath ".bak", 1)
            AtomicConfigEdit(MigrateSharedPinnedFilesToWorkspaces)
        }
        return
    }
    ; Migration is its own atomic transaction. Keep the same recoverable
    ; backup convention used by the settings window.
    if FileExist(ConfigPath)
        FileCopy(ConfigPath, ConfigPath ".bak", 1)
    AtomicConfigEdit(MigrateLegacyConfigToWorkspaces)
}

MigrateLegacyConfigToWorkspaces(tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    existing := ParseStableIdOrder(doc.GetValue("Workspaces", "Order", ""))
    if existing.Length {
        ValidateWorkspaceDocument(doc, existing)
        return
    }

    workspaceId := NewStableId("workspace")
    sourceIds := []
    seen := Map()
    legacyOrder := ParseSourceIdOrder(doc.GetValue("Sources", "Order", ""))
    for entry in doc.GetEntries("Folders") {
        name := Trim(entry.Key)
        path := entry.Value
        if name = "" || Trim(path) = ""
            continue
        sourceId := Trim(doc.GetValue("Folder:" name, "SourceId", ""))
        if !IsSafeSourceId(sourceId)
            sourceId := FindLegacySourceId(doc, legacyOrder, name, path)
        if !IsSafeSourceId(sourceId)
            sourceId := NewStableId("source")
        sourceId := MakeUniqueSourceId(sourceId, seen)
        sourceIds.Push(sourceId)

        sourceSection := "Source:" sourceId
        doc.SetValue(sourceSection, "WorkspaceId", workspaceId, 3)
        doc.SetValue(sourceSection, "Name", name, 3)
        doc.SetValue(sourceSection, "Path", path, 3)
        for key in ["Mode", "MaxFilesPerFolder", "IncludeSubfolders",
            "DisplayScope", "FolderTimeMode", "SortMode", "FilterMode",
            "FileExtensions", "StripOrderPrefix", "HideExtensions",
            "OpenFileMode", "NoiseFilterMode"] {
            found := GetDocumentEntry(doc, "Folder:" name, key)
            if IsObject(found)
                doc.SetValue(sourceSection, key, found.Value, 3)
        }
    }

    doc.ReplaceSection("Workspaces", [
        {Key: "Order", Value: workspaceId},
        {Key: "Active", Value: workspaceId},
        {Key: "PinnedScopeVersion", Value: "1"}
    ], 3)
    workspaceName := UniqueMigratedWorkspaceName(doc)
    doc.ReplaceKnownKeys("Workspace:" workspaceId, [
        {Key: "Name", Value: workspaceName},
        {Key: "Type", Value: "Files"},
        {Key: "Hotkey", Value: ""},
        {Key: "SourceOrder", Value: JoinArray(sourceIds, ",")}
    ], ["Name", "Type", "Hotkey", "SourceOrder"], 3)
    legacyPinned := ReadPinnedPathsFromDocument(doc, "PinnedFiles")
    WritePinnedPathsToDocument(doc,
        "WorkspacePinned:" workspaceId, legacyPinned, 3)
    WritePinnedPathsToDocument(doc, "PinnedFiles", [], 2)
    doc.SetValue("General", "LastFileWorkspaceId", workspaceId, 1)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

MigrateSharedPinnedFilesToWorkspaces(tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    order := ParseStableIdOrder(doc.GetValue("Workspaces", "Order", ""))
    if !order.Length
        throw Error("固定项迁移前找不到工作区。")
    activeId := Trim(doc.GetValue("Workspaces", "Active", ""))
    if !ArrayContainsTextInsensitive(order, activeId)
        activeId := order[1]
    targetSection := "WorkspacePinned:" activeId
    migrated := ReadPinnedPathsFromDocument(doc, targetSection)
    for path in ReadPinnedPathsFromDocument(doc, "PinnedFiles") {
        if !ArrayContainsPath(migrated, path)
            migrated.Push(path)
    }
    WritePinnedPathsToDocument(doc, targetSection, migrated, 3)
    WritePinnedPathsToDocument(doc, "PinnedFiles", [], 2)
    doc.SetValue("Workspaces", "PinnedScopeVersion", "1", 3)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

ReadPinnedPathsFromDocument(doc, section) {
    result := []
    for entry in doc.GetEntries(section) {
        if !RegExMatch(entry.Key, "i)^File\d+$")
            continue
        path := NormalizePath(entry.Value)
        if path != "" && !ArrayContainsPath(result, path)
            result.Push(path)
    }
    return result
}

WritePinnedPathsToDocument(doc, section, paths, area := 3) {
    knownKeys := []
    knownSet := Map()
    for entry in doc.GetEntries(section) {
        if RegExMatch(entry.Key, "i)^File\d+$") {
            knownKeys.Push(entry.Key)
            knownSet[StrLower(entry.Key)] := true
        }
    }
    entries := ConfigEntriesFromValues(paths, "File")
    for entry in entries {
        if !knownSet.Has(StrLower(entry.Key)) {
            knownKeys.Push(entry.Key)
            knownSet[StrLower(entry.Key)] := true
        }
    }
    doc.ReplaceKnownKeys(section, entries, knownKeys, area)
}

UniqueMigratedWorkspaceName(doc) {
    used := Map()
    for section in doc.GetSectionNames() {
        if SubStr(StrLower(section), 1, 10) != "workspace:"
            continue
        name := Trim(doc.GetValue(section, "Name", ""))
        if name != ""
            used[StrLower(name)] := true
    }
    base := "默认工作区"
    if !used.Has(StrLower(base))
        return base
    suffix := 2
    while used.Has(StrLower(base " " suffix))
        suffix += 1
    return base " " suffix
}

FindLegacySourceId(doc, ids, name, path) {
    for id in ids {
        if StrLower(Trim(doc.GetValue("Source:" id, "Name", "")))
            = StrLower(name)
            return id
    }
    target := PathKey(path)
    for id in ids {
        stored := doc.GetValue("Source:" id, "Path", "")
        if Trim(stored) != "" && PathKey(stored) = target
            return id
    }
    return ""
}

GetDocumentEntry(doc, section, key) {
    for entry in doc.GetEntries(section) {
        if StrLower(entry.Key) = StrLower(key)
            return entry
    }
    return 0
}

ValidateWorkspaceDocument(doc, order) {
    seenNames := Map()
    seenIds := Map()
    for workspaceId in order {
        if !IsSafeStableId(workspaceId)
            throw Error("工作区 ID 无效：" workspaceId)
        foldedId := StrLower(workspaceId)
        if seenIds.Has(foldedId)
            throw Error("工作区 ID 重复：" workspaceId)
        seenIds[foldedId] := true
        section := "Workspace:" workspaceId
        name := Trim(doc.GetValue(section, "Name", ""))
        if !IsSafeWorkspaceName(name)
            throw Error("工作区名称无效：" name)
        foldedName := StrLower(name)
        if seenNames.Has(foldedName)
            throw Error("工作区名称重复：" name)
        seenNames[foldedName] := true
        sourceSeen := Map()
        for sourceId in ParseStableIdOrder(
            doc.GetValue(section, "SourceOrder", "")) {
            if sourceSeen.Has(StrLower(sourceId))
                throw Error("工作区“" name "”包含重复来源 ID：" sourceId)
            sourceSeen[StrLower(sourceId)] := true
            sourceSection := "Source:" sourceId
            owner := Trim(doc.GetValue(sourceSection, "WorkspaceId", ""))
            if owner != "" && StrLower(owner) != foldedId
                throw Error("来源 " sourceId " 属于其他工作区。")
            if Trim(doc.GetValue(sourceSection, "Name", "")) = ""
                throw Error("来源 " sourceId " 缺少名称。")
            if Trim(doc.GetValue(sourceSection, "Path", "")) = ""
                throw Error("来源 " sourceId " 缺少路径。")
        }
    }
    active := Trim(doc.GetValue("Workspaces", "Active", ""))
    if active = "" || !seenIds.Has(StrLower(active))
        throw Error("当前工作区不存在于工作区顺序中。")
}

ParseStableIdOrder(raw) {
    result := []
    seen := Map()
    for part in StrSplit(raw, ",") {
        id := Trim(part)
        key := StrLower(id)
        if !IsSafeStableId(id) || seen.Has(key)
            continue
        seen[key] := true
        result.Push(id)
    }
    return result
}

IsSafeStableId(id) {
    id := Trim(id)
    return id != "" && RegExMatch(id, "i)^[a-z0-9][a-z0-9_-]{0,79}$")
}

IsSafeWorkspaceName(name) {
    name := Trim(name)
    return name != "" && StrLen(name) <= 80
        && !RegExMatch(name, "[\[\]=,`r`n]")
}

NewStableId(prefix) {
    guid := Buffer(16, 0)
    if DllCall("ole32\CoCreateGuid", "ptr", guid.Ptr, "int") = 0 {
        text := Buffer(78, 0)
        DllCall("ole32\StringFromGUID2", "ptr", guid.Ptr,
            "ptr", text.Ptr, "int", 39)
        value := StrLower(StrGet(text))
        value := StrReplace(value, "{")
        value := StrReplace(value, "}")
        return prefix "-" value
    }
    return prefix "-" Format("{:08X}{:08X}", A_TickCount,
        DllCall("kernel32\GetCurrentProcessId", "uint"))
}

NormalizeConfigDocument(tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    originalVersion := doc.GetValue("General", "ConfigVersion", "")
    EnsureKnownFolderDefaults(doc)
    EnsureRefreshConfigDefaults(doc)
    EnsureNoiseFilterConfigComments(doc)
    EnsureFileManagerConfigDefaults(doc)
    EnsureTextBlockConfigDefaults(doc)
    EnsurePreviewConfigDefaults(doc)
    EnsureQuickPreviewConfigDefaults(doc)
    EnsureWorkspaceTypeDefaults(doc, originalVersion)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

ConfigLayoutNeedsNormalization() {
    global ConfigPath, CONFIG_VERSION
    doc := OpenPopDropConfig(ConfigPath)
    EnsureKnownFolderDefaults(doc)
    EnsureRefreshConfigDefaults(doc)
    EnsureNoiseFilterConfigComments(doc)
    EnsureFileManagerConfigDefaults(doc)
    EnsureTextBlockConfigDefaults(doc)
    EnsurePreviewConfigDefaults(doc)
    EnsureQuickPreviewConfigDefaults(doc)
    EnsureWorkspaceTypeDefaults(
        doc, doc.GetValue("General", "ConfigVersion", ""))
    return doc.Dirty
        || doc.GetValue("General", "ConfigVersion", "") != CONFIG_VERSION
}

EnsureWorkspaceTypeDefaults(doc, originalVersion := "") {
    order := ParseStableIdOrder(doc.GetValue("Workspaces", "Order", ""))
    firstFileId := ""
    firstTextId := ""
    for workspaceId in order {
        section := "Workspace:" workspaceId
        if Trim(doc.GetValue(section, "Type", "")) = ""
            doc.SetValue(section, "Type", "Files", 3)
        if !ConfigDocumentContainsKey(doc, section, "Hotkey")
            doc.SetValue(section, "Hotkey", "", 3)
        type := ParseWorkspaceType(doc.GetValue(section, "Type", "Files"))
        if type = "Text" && firstTextId = ""
            firstTextId := workspaceId
        else if type = "Files" && firstFileId = ""
            firstFileId := workspaceId
    }
    try oldVersion := Integer(originalVersion)
    catch
        oldVersion := 0
    doubleTarget := Trim(doc.GetValue(
        "General", "DoubleHotkeyWorkspaceId", ""))
    if !ConfigDocumentContainsKey(doc, "General", "DoubleHotkeyWorkspaceId")
        || (oldVersion < 25 && doubleTarget = "" && firstTextId != "")
        doc.SetValue("General", "DoubleHotkeyWorkspaceId",
            firstTextId, 1)

    lastFileId := Trim(doc.GetValue(
        "General", "LastFileWorkspaceId", ""))
    if !WorkspaceIdHasDocumentType(doc, lastFileId, "Files") {
        activeId := Trim(doc.GetValue("Workspaces", "Active", ""))
        lastFileId := WorkspaceIdHasDocumentType(doc, activeId, "Files")
            ? activeId : firstFileId
        doc.SetValue("General", "LastFileWorkspaceId", lastFileId, 1)
    }
}

WorkspaceIdHasDocumentType(doc, workspaceId, expectedType) {
    if workspaceId = ""
        return false
    order := ParseStableIdOrder(doc.GetValue("Workspaces", "Order", ""))
    if !ArrayContainsTextInsensitive(order, workspaceId)
        return false
    return ParseWorkspaceType(doc.GetValue(
        "Workspace:" workspaceId, "Type", "Files")) = expectedType
}

ConfigDocumentContainsKey(doc, section, key) {
    for entry in doc.GetEntries(section) {
        if StrLower(entry.Key) = StrLower(key)
            return true
    }
    return false
}

EnsureRefreshConfigDefaults(doc) {
    global CONTENT_UPDATE_FAST
    if !ConfigDocumentContainsKey(doc, "General", "ContentUpdateMode")
        doc.SetValue("General", "ContentUpdateMode", CONTENT_UPDATE_FAST, 1)
    if !ConfigDocumentContainsKey(doc, "General", "ConsistencyCheckMinutes") {
        legacyHours := Trim(doc.GetValue("General",
            "ConsistencyCheckHours", ""))
        if legacyHours != "" {
            try minutes := Integer(legacyHours) * 60
            catch
                minutes := 60
        } else
            minutes := ConfigDefaultValue(
                "General", "ConsistencyCheckMinutes", "60")
        doc.SetValue("General", "ConsistencyCheckMinutes", minutes, 1)
    if !ConfigDocumentContainsKey(doc, "General", "UiScale")
        doc.SetValue("General", "UiScale", "100", 1)
    else if StrLower(Trim(doc.GetValue("General", "UiScale", ""))) = "system"
        doc.SetValue("General", "UiScale", "100", 1)
    }
    if !ConfigDocumentContainsKey(doc, "General", "StartupEnabled")
        doc.SetValue("General", "StartupEnabled", "0", 1)
}

EnsureKnownFolderDefaults(doc) {
    ; Only replace paths that exactly match PopDrop's historical defaults.
    ; User-selected paths, including other folders under the profile, remain
    ; untouched. This also repairs config.example.ini copies and old configs
    ; created before redirected Known Folders were respected.
    known := [
        {
            SourceId: "source-documents",
            SourceName: "文档",
            LegacyLeaf: "Documents",
            Guid: "{FDD39AD0-238F-46AF-ADB4-6C85480369C7}"
        },
        {
            SourceId: "source-downloads",
            SourceName: "下载",
            LegacyLeaf: "Downloads",
            Guid: "{374DE290-123F-4565-9164-39C4925E467B}"
        }
    ]
    for item in known {
        resolved := GetKnownFolderPath(item.Guid)
        if resolved = ""
            continue
        section := "Source:" item.SourceId
        raw := doc.GetValue(section, "Path", "")
        name := Trim(doc.GetValue(section, "Name", ""))
        if name = item.SourceName
            && IsLegacyUserProfileDefault(raw, item.LegacyLeaf)
            doc.SetValue(section, "Path", resolved, 3)

        ; v0.8 and earlier stored the same defaults in [Folders].
        legacyRaw := doc.GetValue("Folders", item.SourceName, "")
        if IsLegacyUserProfileDefault(legacyRaw, item.LegacyLeaf)
            doc.SetValue("Folders", item.SourceName, resolved, 2)
    }

    desktop := GetKnownFolderPath(
        "{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}")
    downloads := GetKnownFolderPath(
        "{374DE290-123F-4565-9164-39C4925E467B}")
    if desktop != "" {
        raw := doc.GetValue("TransferFavorites", "Path001", "")
        if IsLegacyUserProfileDefault(raw, "Desktop")
            doc.SetValue("TransferFavorites", "Path001", desktop, 5)
    }
    if downloads != "" {
        raw := doc.GetValue("TransferFavorites", "Path002", "")
        if IsLegacyUserProfileDefault(raw, "Downloads")
            doc.SetValue("TransferFavorites", "Path002", downloads, 5)
    }
}

IsLegacyUserProfileDefault(rawPath, leafName) {
    rawPath := Trim(rawPath, " `t`r`n`"")
    if rawPath = ""
        return false
    portable := "%USERPROFILE%\" leafName
    if StrLower(StrReplace(rawPath, "/", "\")) = StrLower(portable)
        return true
    userProfile := EnvGet("USERPROFILE")
    return userProfile != ""
        && PathsEqual(rawPath, userProfile "\" leafName)
}

EnsureFileManagerConfigDefaults(doc) {
    if Trim(doc.GetValue("FileManager", "Provider", "")) = ""
        doc.SetValue("FileManager", "Provider", "WindowsShell", 1)
    ; Executable is intentionally blank for Windows Shell, but materializing
    ; the key makes upgraded configurations explicit and ready for any
    ; third-party provider selected later in Settings.
    if !IsObject(GetDocumentEntry(doc, "FileManager", "Executable"))
        doc.SetValue("FileManager", "Executable", "", 1)
}

EnsureTextBlockConfigDefaults(doc) {
    defaults := [
        {Key: "TextBlockCardWidth", Value:
            ConfigDefaultValue("General", "TextBlockCardWidth", "212")},
        {Key: "TextBlockCardHeight", Value:
            ConfigDefaultValue("General", "TextBlockCardHeight", "68")}
    ]
    for entry in defaults {
        if !IsObject(GetDocumentEntry(doc, "General", entry.Key))
            doc.SetValue("General", entry.Key, entry.Value, 1)
    }
}

EnsurePreviewConfigDefaults(doc) {
    doc.EnsureCommentBlock("Preview", "; <PopDrop:PreviewHelp>", [
        "; 文件内容预览。高级限制仅建议在排查兼容性问题时修改。",
        "; 图片会尽可能直接生成内容预览；其他文件依赖 Windows 已有真实缩略图。"
    ], 1)
    defaults := [
        {Key: "Enabled", Value: ConfigDefaultValue("Preview", "Enabled", "1")},
        {Key: "Side", Value: ConfigDefaultValue("Preview", "Side", "Auto")},
        {Key: "HoverDelayMs", Value: ConfigDefaultValue("Preview", "HoverDelayMs", "350")},
        {Key: "SwitchDelayMs", Value: ConfigDefaultValue("Preview", "SwitchDelayMs", "120")},
        {Key: "LeaveGraceMs", Value: ConfigDefaultValue("Preview", "LeaveGraceMs", "140")},
        {Key: "PreviousPreviewHoldMs", Value: ConfigDefaultValue("Preview", "PreviousPreviewHoldMs", "500")},
        {Key: "BackgroundColor", Value: ConfigDefaultValue("Preview", "BackgroundColor", "#000000")},
        {Key: "BackgroundOpacity", Value: ConfigDefaultValue("Preview", "BackgroundOpacity", "255")},
        {Key: "KeyboardDelayMs", Value: ConfigDefaultValue("Preview", "KeyboardDelayMs", "250")},
        {Key: "Width", Value: ConfigDefaultValue("Preview", "Width", "400")},
        {Key: "CacheEnabled", Value: ConfigDefaultValue("Preview", "CacheEnabled", "1")},
        {Key: "CacheStartAfterHiddenSeconds", Value: ConfigDefaultValue("Preview", "CacheStartAfterHiddenSeconds", "10")},
        {Key: "CacheMaxMB", Value: ConfigDefaultValue("Preview", "CacheMaxMB", "256")},
        {Key: "CacheMaxItems", Value: ConfigDefaultValue("Preview", "CacheMaxItems", "1000")},
        {Key: "CacheItemMaxKB", Value: ConfigDefaultValue("Preview", "CacheItemMaxKB", "2048")},
        {Key: "CacheUnreferencedDays", Value: ConfigDefaultValue("Preview", "CacheUnreferencedDays", "7")},
        {Key: "DirectImageMaxFileMB", Value: ConfigDefaultValue("Preview", "DirectImageMaxFileMB", "64")},
        {Key: "DirectImageMaxEdge", Value: ConfigDefaultValue("Preview", "DirectImageMaxEdge", "65535")},
        {Key: "DirectImageMaxPixelsMP", Value: ConfigDefaultValue("Preview", "DirectImageMaxPixelsMP", "160")},
        {Key: "DirectImageMaxExpandedMB", Value: ConfigDefaultValue("Preview", "DirectImageMaxExpandedMB", "256")},
        {Key: "DocumentEnabled", Value: ConfigDefaultValue("Preview", "DocumentEnabled", "1")},
        {Key: "PdfEnabled", Value: ConfigDefaultValue("Preview", "PdfEnabled", "0")},
        {Key: "ShowFileInfo", Value: ConfigDefaultValue("Preview", "ShowFileInfo", "1")}
    ]
    for entry in defaults {
        if !IsObject(GetDocumentEntry(doc, "Preview", entry.Key))
            doc.SetValue("Preview", entry.Key, entry.Value, 1)
    }
}

EnsureQuickPreviewConfigDefaults(doc) {
    doc.EnsureCommentBlock("QuickPreview", "; <PopDrop:QuickPreviewHelp>", [
        "; 可选外部空格键预览。默认关闭，不自动安装外部程序。",
        "; QuickLookPath 只接受桌面版或便携版 QuickLook.exe 的绝对路径。"
    ], 1)
    defaults := [
        {Key: "ExternalQuickPreviewProvider", Value: "Off"},
        {Key: "SeerIntegrationEnabled", Value: "0"},
        {Key: "QuickLookPath", Value: ""}
    ]
    for entry in defaults {
        if !IsObject(GetDocumentEntry(doc, "QuickPreview", entry.Key))
            doc.SetValue("QuickPreview", entry.Key, entry.Value, 1)
    }
}

EnsureNoiseFilterConfigComments(doc) {
    doc.EnsureCommentBlock("NoiseFilter", "; <PopDrop:NoiseFilterHelp>", [
        "; Enabled：总开关；1=排除噪音文件，0=全部显示。",
        "; HideHidden：是否排除具有 Hidden 属性的文件。",
        "; HideSystem：是否排除具有 System 属性的文件。",
        "; HideTemporaryAttribute：是否排除具有 Temporary 属性的文件。",
        "; HideIncompleteDownloads：是否排除 *.crdownload、*.part、*.download。",
        "; CustomPatternCount：下方 CustomPatternNNN 自定义文件名规则的数量。",
        "; 以上选项只影响 PopDrop 显示，不会删除、移动或修改真实文件。"
    ], 1)
}

EnsureConfigEncoding() {
    global ConfigPath
    tempPath := ""
    try {
        rawBytes := FileRead(ConfigPath, "RAW")
        if rawBytes.Size >= 2 && NumGet(rawBytes, 0, "ushort") = 0xFEFF
            return
        contents := FileRead(ConfigPath, "UTF-8")
        tempPath := ConfigPath ".encoding-"
            . DllCall("kernel32\GetCurrentProcessId", "uint")
        try FileDelete(tempPath)
        output := FileOpen(tempPath, "w", "UTF-16")
        try output.Write(contents)
        finally output.Close()
        if !DllCall("kernel32\ReplaceFileW", "wstr", ConfigPath,
            "wstr", tempPath, "ptr", 0, "uint", 0x2,
            "ptr", 0, "ptr", 0, "int")
            throw OSError(A_LastError, "无法安全转换配置文件编码")
    } catch {
        if tempPath != ""
            try FileDelete(tempPath)
        throw
    }
}

LoadSettings(*) {
    global ConfigPath, ConfiguredHotkey, DoubleHotkeyWorkspaceId
    global LastFileWorkspaceId
    global MaxFilesPerFolder
    global IncludeSubfolders, ThumbnailSize, ThumbnailHorizontalGap, ThumbnailVerticalGap
    global ThumbnailTextLines, TextBlockCardWidth, TextBlockCardHeight
    global FolderSettings, PinnedPaths, Workspaces, TextSourcePinnedPaths
    global ActiveWorkspaceId, ActiveWorkspaceName, ActiveWorkspaceType
    global LastValidWorkspaceId
    global WindowWidth, WindowHeight, RecentFileCount
    global ThumbnailPolicy, CachePathSetting, CacheDir, CacheFilePath, CacheWritable
    global CurrentConfigFingerprint, CurrentScanResult, ScanResultLoaded
    global CurrentHiddenBySource
    global WorkspaceScanSnapshots, PanelRenderSignature, RecentRenderSignature
    global ConsistencyCheckMinutes, ContentUpdateMode
    global CONTENT_UPDATE_FAST, CONTENT_UPDATE_ACCURACY
    global UiScaleMode, UiScalePercent, UiScaleFactor
    global UI_SCALE_100, UI_SCALE_125
    global UI_SCALE_150, UI_SCALE_175, UI_SCALE_200
    global ConfigErrors, LastValidFolderSettings
    global ConfigErrorsShown
    global WindowMode, WINDOW_MODE_ALWAYS_ON_TOP, WINDOW_MODE_TEMPORARY, WINDOW_MODE_NORMAL
    global SortMode, SORT_MODIFIED_DESC, SORT_NAME_ASC
    global MODE_FILES, MODE_LAUNCHER
    global SCOPE_FILES_ONLY, SCOPE_RECURSIVE_FILES, FOLDER_TIME_MODIFIED
    global OpenApps, TransferFavorites, TransferFavoriteLabels, RecentTargets
    global GlobalExcludedFolderNames, EscapeHidesPanel
    global LastOpenProgramDir, LastTransferTargetDir
    global OpenAppsConfigNeedsMigration
    global GlobalOpenFileMode, OPEN_MODE_DOUBLE
    global DefaultContextMenu, CONTEXT_MENU_POPDROP
    global FileManagerProvider, FileManagerExecutable
    global FILE_MANAGER_WINDOWS_SHELL
    global GlobalNoiseFilter, NOISE_FILTER_INHERIT
    FlushPendingScanCacheWrite()
    previousWorkspaceId := ActiveWorkspaceId
    previousFingerprint := CurrentConfigFingerprint
    previousResult := CurrentScanResult
    previousLoaded := ScanResultLoaded
    settingErrors := []
    LoadPreviewSettings(settingErrors)
    LoadQuickPreviewSettings(settingErrors)

    ConfiguredHotkey := Trim(IniRead(ConfigPath, "General", "Hotkey", "F2"))
    if ConfiguredHotkey = ""
        ConfiguredHotkey := "F2"
    DoubleHotkeyWorkspaceId := Trim(IniRead(
        ConfigPath, "General", "DoubleHotkeyWorkspaceId", ""))
    LastFileWorkspaceId := Trim(IniRead(
        ConfigPath, "General", "LastFileWorkspaceId", ""))

    ; 缺失、空值和未知值都必须保持旧版的双击行为。
    GlobalOpenFileMode := ParseGlobalOpenFileMode(
        IniRead(ConfigPath, "General", "OpenFileMode", OPEN_MODE_DOUBLE))
    rawContextMenu := Trim(IniRead(
        ConfigPath, "General", "DefaultContextMenu", ""))
    DefaultContextMenu := ParseDefaultContextMenu(rawContextMenu)
    if rawContextMenu != ""
        && !IsRecognizedDefaultContextMenu(rawContextMenu) {
        settingErrors.Push("[General] 中 DefaultContextMenu 值无效："
            rawContextMenu "。已使用 PopDrop 快捷菜单。允许的值：PopDrop, System。")
    }
    EscapeHidesPanel := IniRead(
        ConfigPath, "General", "EscapeHidesPanel", "1") = "1"
    GlobalExcludedFolderNames := LoadGlobalExcludedFolderNames()
    GlobalNoiseFilter := LoadNoiseFilterConfig()
    LoadExternalTransferSettings()
    for patternError in GlobalNoiseFilter.PatternErrors
        settingErrors.Push(patternError)

    ; 读取窗口模式
    rawMode := StrLower(Trim(IniRead(ConfigPath, "General", "WindowMode", "temporary")))
    if rawMode = WINDOW_MODE_ALWAYS_ON_TOP || rawMode = WINDOW_MODE_TEMPORARY || rawMode = WINDOW_MODE_NORMAL {
        WindowMode := rawMode
    } else {
        WindowMode := WINDOW_MODE_TEMPORARY
        settingErrors.Push("WindowMode 配置值无效：" rawMode "，已使用默认模式 temporary。")
    }

    try MaxFilesPerFolder := Integer(IniRead(ConfigPath, "General", "MaxFilesPerFolder", "8"))
    catch
        MaxFilesPerFolder := 8
    MaxFilesPerFolder := Max(1, Min(MaxFilesPerFolder, 100))
    IncludeSubfolders := IniRead(ConfigPath, "General", "IncludeSubfolders", "0") = "1"
    try ThumbnailSize := Integer(IniRead(ConfigPath, "General", "ThumbnailSize", "96"))
    catch
        ThumbnailSize := 96
    ThumbnailSize := Max(48, Min(ThumbnailSize, 256))
    try ThumbnailHorizontalGap := Integer(
        IniRead(ConfigPath, "General", "ThumbnailHorizontalGap", "24"))
    catch
        ThumbnailHorizontalGap := 24
    ThumbnailHorizontalGap := Max(0, Min(ThumbnailHorizontalGap, 128))
    try ThumbnailVerticalGap := Integer(
        IniRead(ConfigPath, "General", "ThumbnailVerticalGap", "4"))
    catch
        ThumbnailVerticalGap := 4
    ThumbnailVerticalGap := Max(0, Min(ThumbnailVerticalGap, 128))
    try ThumbnailTextLines := Integer(
        IniRead(ConfigPath, "General", "ThumbnailTextLines", "2"))
    catch
        ThumbnailTextLines := 2
    ThumbnailTextLines := Max(1, Min(ThumbnailTextLines, 2))
    try TextBlockCardWidth := Integer(
        IniRead(ConfigPath, "General", "TextBlockCardWidth", "212"))
    catch
        TextBlockCardWidth := 212
    TextBlockCardWidth := Max(140, Min(TextBlockCardWidth, 640))
    try TextBlockCardHeight := Integer(
        IniRead(ConfigPath, "General", "TextBlockCardHeight", "68"))
    catch
        TextBlockCardHeight := 68
    TextBlockCardHeight := Max(48, Min(TextBlockCardHeight, 320))

    try WindowWidth := Integer(IniRead(ConfigPath, "General", "WindowWidth", "766"))
    catch
        WindowWidth := 766
    try WindowHeight := Integer(IniRead(ConfigPath, "General", "WindowHeight", "576"))
    catch
        WindowHeight := 576
    ; Restore a useful, toolbar-driven width instead of reopening at a
    ; previously maximized desktop width. The window remains freely resizable.
    WindowWidth := Max(760, Min(WindowWidth, 980))
    WindowHeight := Max(380, Min(WindowHeight, 2000))

    configuredView := StrLower(Trim(IniRead(ConfigPath, "General", "ViewMode", "Thumbnail")))
    SetViewMode(configuredView = "list" ? "List" : "Thumbnail", false)
    SetRecentSidebarVisible(
        IniRead(ConfigPath, "General", "ShowRecentSidebar", "0") = "1",
        false)
    rawContentUpdateMode := StrLower(Trim(IniRead(ConfigPath, "General",
        "ContentUpdateMode", CONTENT_UPDATE_FAST)))
    if rawContentUpdateMode = StrLower(CONTENT_UPDATE_ACCURACY)
        ContentUpdateMode := CONTENT_UPDATE_ACCURACY
    else
        ContentUpdateMode := CONTENT_UPDATE_FAST
    rawUiScale := Trim(IniRead(ConfigPath, "General", "UiScale", UI_SCALE_100))
    validUiScale := [UI_SCALE_100, UI_SCALE_125, UI_SCALE_150,
        UI_SCALE_175, UI_SCALE_200]
    if ValueInArray(rawUiScale, validUiScale) {
        UiScaleMode := rawUiScale
        UiScalePercent := Integer(rawUiScale)
    } else {
        UiScaleMode := UI_SCALE_100
        UiScalePercent := 100
    }
    UiScaleFactor := Max(0.75, Min(UiScalePercent / 100, 2.5))
    try RecentFileCount := Integer(IniRead(ConfigPath, "General", "RecentFileCount", "12"))
    catch
        RecentFileCount := 12
    RecentFileCount := Max(1, Min(RecentFileCount, 100))

    ThumbnailPolicy := StrLower(Trim(IniRead(
        ConfigPath, "General", "ThumbnailPolicy", "Full"))) = "full"
        ? "Full" : "Fast"
    CachePathSetting := Trim(IniRead(ConfigPath, "General", "CachePath", ""))
    rawConsistencyMinutes := IniRead(
        ConfigPath, "General", "ConsistencyCheckMinutes", "")
    if rawConsistencyMinutes = "" {
        try ConsistencyCheckMinutes := Integer(IniRead(
            ConfigPath, "General", "ConsistencyCheckHours", "1")) * 60
        catch
            ConsistencyCheckMinutes := 60
    } else {
        try ConsistencyCheckMinutes := Integer(rawConsistencyMinutes)
        catch
            ConsistencyCheckMinutes := 60
    }
    ConsistencyCheckMinutes := Max(0, Min(ConsistencyCheckMinutes, 10080))
    LastOpenProgramDir := NormalizePath(
        IniRead(ConfigPath, "General", "LastOpenProgramDir", ""))
    LastTransferTargetDir := NormalizePath(
        IniRead(ConfigPath, "General", "LastTransferTargetDir", ""))
    rawFileManagerProvider := Trim(IniRead(
        ConfigPath, "FileManager", "Provider", FILE_MANAGER_WINDOWS_SHELL))
    FileManagerProvider := ParseFileManagerProvider(rawFileManagerProvider)
    FileManagerExecutable := Trim(IniRead(
        ConfigPath, "FileManager", "Executable", ""))
    if rawFileManagerProvider != ""
        && !IsRecognizedFileManagerProvider(rawFileManagerProvider) {
        settingErrors.Push("[FileManager] 中 Provider 值无效："
            . rawFileManagerProvider
            . "。已使用 WindowsShell。允许的值：WindowsShell, "
            . "DirectoryOpus, TotalCommander, XYplorer, "
            . "DoubleCommander, Files, FreeCommander。")
    }

    ; 读取全局排序模式
    rawSort := StrLower(Trim(IniRead(ConfigPath, "General", "SortMode", "ModifiedDesc")))
    if rawSort = StrLower(SORT_MODIFIED_DESC)
        SortMode := SORT_MODIFIED_DESC
    else if rawSort = StrLower(SORT_NAME_ASC)
        SortMode := SORT_NAME_ASC
    else
        SortMode := SORT_MODIFIED_DESC

    ; 工作区管理来源和固定项。其他共享设置已经在上方读取一次；
    ; 每个来源仍只继承共享默认值，不增加工作区级默认层。
    Workspaces := LoadWorkspaceDefinitions()
    TextSourcePinnedPaths := LoadTextSourcePinnedState(Workspaces)
    ActiveWorkspaceId := ReadActiveWorkspaceId(Workspaces)
    LastFileWorkspaceId := ResolveFileWorkspaceId(
        LastFileWorkspaceId, Workspaces, ActiveWorkspaceId)
    activeWorkspace := 0
    for workspace in Workspaces {
        FolderSettings := workspace.SourceRefs
        workspaceResult := ValidateConfig(workspace.Type)
        workspace.Sources := workspaceResult.Settings
        workspace.Errors := workspaceResult.Errors
        workspace.Valid := workspaceResult.Valid
        if StrLower(workspace.Id) = StrLower(ActiveWorkspaceId)
            activeWorkspace := workspace
    }
    if !IsObject(activeWorkspace)
        throw Error("找不到当前工作区。")
    ActiveWorkspaceName := activeWorkspace.Name
    ActiveWorkspaceType := activeWorkspace.Type
    FolderSettings := activeWorkspace.SourceRefs
    PinnedPaths := activeWorkspace.PinnedPaths
    result := {
        Valid: activeWorkspace.Valid,
        Settings: activeWorkspace.Sources,
        Errors: activeWorkspace.Errors
    }

    ; 验证并解析当前工作区，错误回退不得跨工作区串用来源。
    ConfigErrorsShown := false
    if result.Valid {
        LastValidFolderSettings := result.Settings
        LastValidWorkspaceId := ActiveWorkspaceId
        ConfigErrors := settingErrors
    } else {
        ConfigErrors := settingErrors.Clone()
        for errorMessage in result.Errors
            ConfigErrors.Push(errorMessage)
        if LastValidFolderSettings.Length
            && StrLower(LastValidWorkspaceId) = StrLower(ActiveWorkspaceId) {
            ; 保留 LastValidFolderSettings
        } else {
            LastValidFolderSettings := result.Settings
            LastValidWorkspaceId := ActiveWorkspaceId
        }
    }

    if previousLoaded && previousWorkspaceId != "" {
        WorkspaceScanSnapshots[StrLower(previousWorkspaceId)] := {
            Fingerprint: previousFingerprint, Result: previousResult}
    }
    CacheDir := ResolveCacheDirectory(CachePathSetting)
    CacheWritable := EnsureCacheDirectory(CacheDir)
    InitializeRuntimeIndex()
    newFingerprint := ComputeConfigFingerprint(LastValidFolderSettings)
    CacheFilePath := CacheDir "\workspace-"
        . HashString(StrLower(ActiveWorkspaceId)) ".ini"
    if CurrentConfigFingerprint != newFingerprint {
        CurrentConfigFingerprint := newFingerprint
        CurrentHiddenBySource := Map()
        snapshotKey := StrLower(ActiveWorkspaceId)
        if WorkspaceScanSnapshots.Has(snapshotKey)
            && WorkspaceScanSnapshots[snapshotKey].Fingerprint = newFingerprint {
            CurrentScanResult := WorkspaceScanSnapshots[snapshotKey].Result
            ScanResultLoaded := true
        } else {
            CurrentScanResult := {
                Folders: [], Recent: [], HiddenCount: 0, HiddenItems: []}
            ScanResultLoaded := false
        }
        PanelRenderSignature := ""
        RecentRenderSignature := ""
    }

    OpenApps := LoadOpenApps()
    for app in OpenApps {
        for action in app.Actions {
            if !action.Valid
                ConfigErrors.Push("工具动作配置无效：[OpenAppAction:"
                    app.Id ":" action.Id "] " action.ValidationError)
        }
    }
    if OpenAppsConfigNeedsMigration {
        try {
            SaveOpenApps()
            OpenAppsConfigNeedsMigration := false
        } catch as err {
            message := "无法把旧版软件列表迁移到简化格式：" err.Message
            ConfigErrors.Push(message)
        }
    }
    TransferFavorites := LoadTransferFavorites(settingErrors)
    TransferFavoriteLabels := LoadTransferFavoriteLabels(TransferFavorites)
    RecentTargets := LoadPathListSection("RecentTargets", 3)
    SyncWorkspaceControls()
}

LoadWorkspaceDefinitions() {
    global ConfigPath, WORKSPACE_TYPE_FILES
    result := []
    ids := ParseStableIdOrder(IniRead(
        ConfigPath, "Workspaces", "Order", ""))
    for id in ids {
        section := "Workspace:" id
        name := Trim(IniRead(ConfigPath, section, "Name", ""))
        type := ParseWorkspaceType(IniRead(
            ConfigPath, section, "Type", WORKSPACE_TYPE_FILES))
        hotkey := Trim(IniRead(ConfigPath, section, "Hotkey", ""))
        refs := []
        for sourceId in ParseStableIdOrder(IniRead(
            ConfigPath, section, "SourceOrder", "")) {
            sourceSection := "Source:" sourceId
            sourceName := Trim(IniRead(
                ConfigPath, sourceSection, "Name", ""))
            sourcePath := NormalizePath(IniRead(
                ConfigPath, sourceSection, "Path", ""))
            if sourceName != "" && sourcePath != ""
                refs.Push({Name: sourceName, Path: sourcePath,
                    SourceId: sourceId, WorkspaceId: id,
                    WorkspaceType: type})
        }
        pinnedPaths := LoadWorkspacePinnedPaths(id)
        result.Push({Id: id, Name: name, Type: type, Hotkey: hotkey,
            SourceRefs: refs,
            PinnedPaths: pinnedPaths,
            Sources: [], Errors: [], Valid: true})
    }
    if !result.Length
        throw Error("配置中至少需要一个工作区。")
    return result
}

LoadWorkspacePinnedPaths(workspaceId) {
    global ConfigPath
    result := []
    section := "WorkspacePinned:" workspaceId
    for entry in ReadIniSection(section) {
        if !RegExMatch(entry.Key, "i)^File\d+$")
            continue
        path := NormalizePath(entry.Value)
        if path != "" && !ArrayContainsPath(result, path)
            result.Push(path)
    }
    return result
}

ReadActiveWorkspaceId(workspaces) {
    global ConfigPath
    active := Trim(IniRead(ConfigPath, "Workspaces", "Active", ""))
    for workspace in workspaces {
        if StrLower(workspace.Id) = StrLower(active)
            return workspace.Id
    }
    return workspaces[1].Id
}

FindWorkspace(workspaceId, workspaceList := 0) {
    global Workspaces
    if !IsObject(workspaceList)
        workspaceList := Workspaces
    for index, workspace in workspaceList {
        if StrLower(workspace.Id) = StrLower(workspaceId)
            return {Index: index, Value: workspace}
    }
    return 0
}

ResolveFileWorkspaceId(preferredId, workspaceList := 0, fallbackId := "") {
    global Workspaces, WORKSPACE_TYPE_FILES
    if !IsObject(workspaceList)
        workspaceList := Workspaces
    preferred := FindWorkspace(preferredId, workspaceList)
    if IsObject(preferred)
        && ParseWorkspaceType(preferred.Value.Type) = WORKSPACE_TYPE_FILES
        return preferred.Value.Id
    fallback := FindWorkspace(fallbackId, workspaceList)
    if IsObject(fallback)
        && ParseWorkspaceType(fallback.Value.Type) = WORKSPACE_TYPE_FILES
        return fallback.Value.Id
    for workspace in workspaceList {
        if ParseWorkspaceType(workspace.Type) = WORKSPACE_TYPE_FILES
            return workspace.Id
    }
    return ""
}

; ──── 配置验证与筛选函数 ────

ParseGlobalOpenFileMode(raw) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE
    value := StrLower(Trim(raw))
    if value = StrLower(OPEN_MODE_SINGLE)
        return OPEN_MODE_SINGLE
    if value = StrLower(OPEN_MODE_DOUBLE)
        return OPEN_MODE_DOUBLE
    return OPEN_MODE_DOUBLE
}

IsRecognizedGlobalOpenFileMode(raw) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE
    value := StrLower(Trim(raw))
    return value = StrLower(OPEN_MODE_DOUBLE)
        || value = StrLower(OPEN_MODE_SINGLE)
}

ParseDefaultContextMenu(raw) {
    global CONTEXT_MENU_POPDROP, CONTEXT_MENU_SYSTEM
    value := StrLower(Trim(raw))
    if value = StrLower(CONTEXT_MENU_SYSTEM)
        return CONTEXT_MENU_SYSTEM
    if value = StrLower(CONTEXT_MENU_POPDROP)
        return CONTEXT_MENU_POPDROP
    return CONTEXT_MENU_POPDROP
}

IsRecognizedDefaultContextMenu(raw) {
    global CONTEXT_MENU_POPDROP, CONTEXT_MENU_SYSTEM
    value := StrLower(Trim(raw))
    return value = StrLower(CONTEXT_MENU_POPDROP)
        || value = StrLower(CONTEXT_MENU_SYSTEM)
}

ResolveContextMenuKind(defaultMenu, alternate) {
    global CONTEXT_MENU_POPDROP, CONTEXT_MENU_SYSTEM
    useSystem := ParseDefaultContextMenu(defaultMenu) = CONTEXT_MENU_SYSTEM
    if alternate
        useSystem := !useSystem
    return useSystem ? CONTEXT_MENU_SYSTEM : CONTEXT_MENU_POPDROP
}

ParseSourceOpenFileMode(raw) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, SOURCE_OPEN_MODE_INHERIT
    value := StrLower(Trim(raw))
    if value = StrLower(OPEN_MODE_SINGLE)
        return OPEN_MODE_SINGLE
    if value = StrLower(OPEN_MODE_DOUBLE)
        return OPEN_MODE_DOUBLE
    if value = StrLower(SOURCE_OPEN_MODE_INHERIT)
        return SOURCE_OPEN_MODE_INHERIT
    return SOURCE_OPEN_MODE_INHERIT
}

IsRecognizedSourceOpenFileMode(raw) {
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, SOURCE_OPEN_MODE_INHERIT
    value := StrLower(Trim(raw))
    return value = StrLower(OPEN_MODE_DOUBLE)
        || value = StrLower(OPEN_MODE_SINGLE)
        || value = StrLower(SOURCE_OPEN_MODE_INHERIT)
}

IsSafeSourceId(id) {
    id := Trim(id)
    return id != "" && !RegExMatch(id, "[,\[\]=`r`n]")
}

IsSafeSourceName(name) {
    name := Trim(name)
    return name != "" && !RegExMatch(name, "[\[\]=`r`n]")
}

SanitizeSourceName(name) {
    name := Trim(RegExReplace(name, "[\[\]=`r`n]", "_"))
    return name != "" ? name : "文件夹"
}

DefaultSourceNameForPath(path) {
    name := GetFileName(path)
    if name = "" {
        trimmed := RTrim(path, "\")
        SplitPath(trimmed, &name)
        if name = ""
            name := trimmed
    }
    return SanitizeSourceName(name)
}

MakeUniqueSourceName(baseName, sources) {
    baseName := SanitizeSourceName(baseName)
    used := Map()
    for source in sources {
        if HasProp(source, "Name")
            used[StrLower(Trim(source.Name))] := true
    }
    if !used.Has(StrLower(baseName))
        return baseName
    suffix := 2
    Loop {
        candidate := baseName " (" suffix++ ")"
        if !used.Has(StrLower(candidate))
            return candidate
    }
}

ParseSourceIdOrder(raw) {
    result := []
    seen := Map()
    for part in StrSplit(raw, ",") {
        id := Trim(part)
        key := StrLower(id)
        if !IsSafeSourceId(id) || seen.Has(key)
            continue
        seen[key] := true
        result.Push(id)
    }
    return result
}

ResolveFolderSourceId(name, path) {
    global ConfigPath, FolderSettings
    for source in FolderSettings {
        if HasProp(source, "SourceId")
            && StrLower(source.Name) = StrLower(name)
            && PathsEqual(source.Path, path)
            return source.SourceId
    }
    folderSection := "Folder:" name
    sourceId := Trim(IniRead(ConfigPath, folderSection, "SourceId", ""))
    if IsSafeSourceId(sourceId)
        return sourceId

    sourceIds := ParseSourceIdOrder(
        IniRead(ConfigPath, "Sources", "Order", ""))
    normalizedKey := PathKey(path)

    ; 显示名未改变时优先保持身份，路径修改不会丢失来源设置。
    for id in sourceIds {
        section := "Source:" id
        storedName := Trim(IniRead(ConfigPath, section, "Name", ""))
        if storedName != "" && StrLower(storedName) = StrLower(name)
            return id
    }
    ; 显示名修改时再用规范化路径恢复身份。
    for id in sourceIds {
        section := "Source:" id
        storedPath := NormalizePath(IniRead(ConfigPath, section, "Path", ""))
        if storedPath != "" && PathKey(storedPath) = normalizedKey
            return id
    }

    ; 旧配置无需立即写回；首次从设置窗口保存时持久化此稳定 ID。
    return "source-" HashString(StrLower(name) "|" normalizedKey)
}

ReadFolderOpenFileMode(name, sourceId) {
    global ConfigPath, SOURCE_OPEN_MODE_INHERIT
    raw := IsSafeSourceId(sourceId)
        ? IniRead(ConfigPath, "Source:" sourceId, "OpenFileMode", "")
        : ""
    if Trim(raw) = ""
        raw := IniRead(ConfigPath, "Folder:" name, "OpenFileMode",
            SOURCE_OPEN_MODE_INHERIT)
    return ParseSourceOpenFileMode(raw)
}

MigrateOpenFileModeConfig(folders) {
    global ConfigPath, OPEN_MODE_DOUBLE

    rawGlobal := IniRead(ConfigPath, "General", "OpenFileMode", "")
    try configVersion := Integer(
        IniRead(ConfigPath, "General", "ConfigVersion", "0"))
    catch
        configVersion := 0
    needsMigration := configVersion < 8
        || !IsRecognizedGlobalOpenFileMode(rawGlobal)
    entries := []
    seen := Map()
    configuredIds := ParseSourceIdOrder(
        IniRead(ConfigPath, "Sources", "Order", ""))

    for folder in folders {
        sourceId := MakeUniqueSourceId(
            ResolveFolderSourceId(folder.Name, folder.Path), seen)
        rawFolderId := Trim(IniRead(ConfigPath,
            "Folder:" folder.Name, "SourceId", ""))
        rawMode := IniRead(ConfigPath, "Folder:" folder.Name,
            "OpenFileMode", "")
        if Trim(rawMode) = ""
            rawMode := IniRead(ConfigPath, "Source:" sourceId,
                "OpenFileMode", "")
        storedName := Trim(IniRead(ConfigPath,
            "Source:" sourceId, "Name", ""))
        storedPath := NormalizePath(IniRead(ConfigPath,
            "Source:" sourceId, "Path", ""))
        if rawFolderId != sourceId
            || !IsRecognizedSourceOpenFileMode(rawMode)
            || !ArrayContainsTextInsensitive(configuredIds, sourceId)
            || storedName != folder.Name
            || !PathsEqual(storedPath, folder.Path)
            needsMigration := true
        entries.Push({
            Id: sourceId,
            Name: folder.Name,
            Path: folder.Path,
            Mode: ParseSourceOpenFileMode(rawMode)
        })
    }
    if needsMigration
        AtomicConfigEdit(WriteOpenFileModeSettings.Bind(
            ParseGlobalOpenFileMode(rawGlobal), entries))
}

ValidateConfig(workspaceType := "Files") {
    global ConfigPath, ConfigErrors, FolderSettings
    global SORT_MODIFIED_DESC, SORT_NAME_ASC, SORT_SMART
    global MODE_FILES, MODE_LAUNCHER
    global SCOPE_FILES_ONLY, SCOPE_FILES_AND_FOLDERS, SCOPE_RECURSIVE_FILES
    global FOLDER_TIME_MODIFIED, FOLDER_TIME_LATEST_CONTENT
    global NOISE_FILTER_INHERIT, WORKSPACE_TYPE_TEXT

    errors := []
    tempGlobalFilter := {Mode: "All", Extensions: []}
    tempGlobalMaxFiles := 8
    tempGlobalIncludeSubfolders := false
    tempGlobalDisplayScope := SCOPE_FILES_ONLY
    tempGlobalFolderTimeMode := FOLDER_TIME_MODIFIED
    tempGlobalSortMode := SORT_MODIFIED_DESC

    ; ── 解析全局排序 ──
    rawSort := StrLower(Trim(IniRead(ConfigPath, "General", "SortMode", "ModifiedDesc")))
    if rawSort = StrLower(SORT_MODIFIED_DESC)
        tempGlobalSortMode := SORT_MODIFIED_DESC
    else if rawSort = StrLower(SORT_NAME_ASC)
        tempGlobalSortMode := SORT_NAME_ASC
    else
        errors.Push("[General] 中 SortMode 值无效：" rawSort "。允许的值：ModifiedDesc, NameAsc。")

    ; ── 解析全局筛选 ──
    rawMode := StrLower(Trim(IniRead(ConfigPath, "General", "FilterMode", "All")))
    rawExt := Trim(IniRead(ConfigPath, "General", "FileExtensions", ""))
    if rawMode = "inherit"
        errors.Push("[General] 中 FilterMode 不能为 Inherit（只有文件夹级才支持 Inherit）。")
    gf := ParseFilterSettings(rawMode, rawExt, "[General]")
    if HasProp(gf, "Error")
        errors.Push(gf.Error)
    else
        tempGlobalFilter := gf

    ; ── 解析全局数值 ──
    try tempGlobalMaxFiles := Integer(IniRead(ConfigPath, "General", "MaxFilesPerFolder", "8"))
    catch
        tempGlobalMaxFiles := 8
    tempGlobalMaxFiles := Max(1, Min(tempGlobalMaxFiles, 100))

    tempGlobalIncludeSubfolders := IniRead(ConfigPath, "General", "IncludeSubfolders", "0") = "1"
    rawScope := StrLower(Trim(IniRead(ConfigPath, "General", "DisplayScope", "")))
    if rawScope = ""
        tempGlobalDisplayScope := tempGlobalIncludeSubfolders
            ? SCOPE_RECURSIVE_FILES : SCOPE_FILES_ONLY
    else if rawScope = StrLower(SCOPE_FILES_ONLY)
        tempGlobalDisplayScope := SCOPE_FILES_ONLY
    else if rawScope = StrLower(SCOPE_FILES_AND_FOLDERS)
        tempGlobalDisplayScope := SCOPE_FILES_AND_FOLDERS
    else if rawScope = StrLower(SCOPE_RECURSIVE_FILES)
        tempGlobalDisplayScope := SCOPE_RECURSIVE_FILES
    else
        errors.Push("[General] 中 DisplayScope 值无效：" rawScope
            "。允许的值：FilesOnly, FilesAndFolders, RecursiveFiles。")
    tempGlobalIncludeSubfolders := tempGlobalDisplayScope = SCOPE_RECURSIVE_FILES

    rawFolderTime := StrLower(Trim(
        IniRead(ConfigPath, "General", "FolderTimeMode", "DirectoryModified")))
    if rawFolderTime = StrLower(FOLDER_TIME_MODIFIED)
        tempGlobalFolderTimeMode := FOLDER_TIME_MODIFIED
    else if rawFolderTime = StrLower(FOLDER_TIME_LATEST_CONTENT)
        tempGlobalFolderTimeMode := FOLDER_TIME_LATEST_CONTENT
    else
        errors.Push("[General] 中 FolderTimeMode 值无效：" rawFolderTime
            "。允许的值：DirectoryModified, LatestContent。")

    ; ── 解析每个文件夹的独立配置 ──
    resolved := []
    sourceIdsSeen := Map()
    for f in FolderSettings {
        sourceId := HasProp(f, "SourceId") ? f.SourceId
            : ResolveFolderSourceId(f.Name, f.Path)
        sourceId := MakeUniqueSourceId(sourceId, sourceIdsSeen)
        sectionName := "Source:" sourceId
        folderOpenFileMode := ReadFolderOpenFileMode(f.Name, sourceId)

        ; 读取该文件夹的独立配置节
        folderMax := tempGlobalMaxFiles
        folderMaxInherited := true
        folderRecursive := tempGlobalIncludeSubfolders
        folderDisplayScope := tempGlobalDisplayScope
        folderTimeMode := tempGlobalFolderTimeMode
        folderFilter := {Mode: tempGlobalFilter.Mode, Extensions: tempGlobalFilter.Extensions}
        folderSortMode := tempGlobalSortMode
        folderMode := MODE_FILES
        folderStripOrderPrefix := 0
        folderHideExtensions := 0
        folderNoiseFilterMode := NOISE_FILTER_INHERIT
        sourcePatternTexts := LoadIgnorePatternTexts("SourceIgnore:" sourceId)
        legacySubfolderOverride := false

        ; 检查是否有独立配置节
        sectionExists := false
        try {
            raw := IniRead(ConfigPath, sectionName)
            if raw != ""
                sectionExists := true
        }
        catch
            sectionExists := false

        if sectionExists {
            ; ── 读取 Mode ──
            rawModeV := StrLower(Trim(IniRead(ConfigPath, sectionName, "Mode", "Files")))
            if rawModeV = "files"
                folderMode := MODE_FILES
            else if rawModeV = "launcher"
                folderMode := MODE_LAUNCHER
            else if rawModeV != ""
                errors.Push("[" sectionName "] 中 Mode 值无效：" rawModeV "。允许的值：Files, Launcher。")

            ; ── 应用 Launcher 默认值 ──
            if folderMode = MODE_LAUNCHER {
                ; 为 Launcher 设置默认值，用户显式配置会覆盖
                folderRecursive := false
                folderDisplayScope := SCOPE_FILES_ONLY
                folderMax := 0  ; 0 = 无限
                folderMaxInherited := false
                folderSortMode := SORT_NAME_ASC
                folderFilter := {Mode: "Include", Extensions: [".lnk", ".url", ".exe"]}
                folderStripOrderPrefix := 1
                folderHideExtensions := 1
            }

            ; ── 读取 MaxFilesPerFolder ──
            rawVal := ""
            try {
                val := Trim(IniRead(ConfigPath, sectionName, "MaxFilesPerFolder", ""))
                if val != "" {
                    rawVal := val
                    if StrLower(val) = "inherit" {
                        folderMax := tempGlobalMaxFiles
                        folderMaxInherited := true
                    } else if StrLower(val) = "all" || val = "0" {
                        folderMax := 0
                        folderMaxInherited := false
                    } else {
                        folderMax := Integer(val)
                        folderMaxInherited := false
                        if folderMax < 1
                            folderMax := 1
                    }
                }
            }
            catch
                errors.Push("[" sectionName "] 中 MaxFilesPerFolder 值无效：" rawVal "。")

            ; ── 读取 IncludeSubfolders ──
            try {
                val := IniRead(ConfigPath, sectionName, "IncludeSubfolders", "")
                if val != "" {
                    legacySubfolderOverride := true
                    if val = "1"
                        folderRecursive := true
                    else if val = "0"
                        folderRecursive := false
                    else
                        errors.Push("[" sectionName "] 中 IncludeSubfolders 只能为 0 或 1，实际值为：" val "。")
                }
            }

            ; DisplayScope 是 v0.7 的权威配置；缺失时迁移旧 IncludeSubfolders 语义。
            try {
                val := StrLower(Trim(IniRead(ConfigPath, sectionName, "DisplayScope", "")))
                if val != "" {
                    if val = StrLower(SCOPE_FILES_ONLY)
                        folderDisplayScope := SCOPE_FILES_ONLY
                    else if val = StrLower(SCOPE_FILES_AND_FOLDERS)
                        folderDisplayScope := SCOPE_FILES_AND_FOLDERS
                    else if val = StrLower(SCOPE_RECURSIVE_FILES)
                        folderDisplayScope := SCOPE_RECURSIVE_FILES
                    else
                        errors.Push("[" sectionName "] 中 DisplayScope 值无效：" val "。")
                } else {
                    if legacySubfolderOverride
                        folderDisplayScope := folderRecursive
                            ? SCOPE_RECURSIVE_FILES : SCOPE_FILES_ONLY
                }
                folderRecursive := folderDisplayScope = SCOPE_RECURSIVE_FILES
            }

            try {
                val := StrLower(Trim(IniRead(ConfigPath, sectionName, "FolderTimeMode", "")))
                if val != "" {
                    if val = StrLower(FOLDER_TIME_MODIFIED)
                        folderTimeMode := FOLDER_TIME_MODIFIED
                    else if val = StrLower(FOLDER_TIME_LATEST_CONTENT)
                        folderTimeMode := FOLDER_TIME_LATEST_CONTENT
                    else if val = "inherit"
                        folderTimeMode := tempGlobalFolderTimeMode
                    else
                        errors.Push("[" sectionName "] 中 FolderTimeMode 值无效：" val "。")
                }
            }

            ; ── 读取 SortMode ──
            try {
                val := Trim(IniRead(ConfigPath, sectionName, "SortMode", ""))
                if val != "" {
                    rawSortV := StrLower(val)
                    if rawSortV = StrLower(SORT_MODIFIED_DESC)
                        folderSortMode := SORT_MODIFIED_DESC
                    else if rawSortV = StrLower(SORT_NAME_ASC)
                        folderSortMode := SORT_NAME_ASC
                    else if rawSortV = StrLower(SORT_SMART)
                        && ParseWorkspaceType(workspaceType) = WORKSPACE_TYPE_TEXT
                        folderSortMode := SORT_SMART
                    else if rawSortV = "inherit"
                        folderSortMode := tempGlobalSortMode
                    else
                        errors.Push("[" sectionName "] 中 SortMode 值无效：" val "。")
                }
            }

            ; ── 读取筛选模式 FileExtensions ──
            rawMode := StrLower(Trim(IniRead(ConfigPath, sectionName, "FilterMode", "")))
            rawExt := Trim(IniRead(ConfigPath, sectionName, "FileExtensions", ""))

            if folderMode = MODE_LAUNCHER {
                ; Launcher 模式特殊筛选逻辑
                if rawMode = "inherit" {
                    ; 继承全局
                    folderFilter := {Mode: tempGlobalFilter.Mode, Extensions: tempGlobalFilter.Extensions}
                } else if rawMode = "all" {
                    folderFilter := {Mode: "All", Extensions: []}
                } else if rawMode = "include" || rawMode = "exclude" {
                    pf := ParseFilterSettings(rawMode, rawExt, "[" sectionName "]")
                    if HasProp(pf, "Error")
                        errors.Push(pf.Error)
                    else
                        folderFilter := pf
                } else if rawMode = "" && rawExt != "" {
                    ; 仅填写 FileExtensions 时自动使用 Include
                    pf := ParseFilterSettings("include", rawExt, "[" sectionName "]")
                    if HasProp(pf, "Error")
                        errors.Push(pf.Error)
                    else
                        folderFilter := pf
                } else {
                    ; 未配置筛选，使用 Launcher 默认（已在上面设置）
                }
            } else {
                ; Files 模式
                if rawMode = "inherit" || rawMode = "" {
                    ; 整体继承全局筛选
                    folderFilter := {Mode: tempGlobalFilter.Mode, Extensions: tempGlobalFilter.Extensions}
                } else {
                    pf := ParseFilterSettings(rawMode, rawExt, "[" sectionName "]")
                    if HasProp(pf, "Error")
                        errors.Push(pf.Error)
                    else
                        folderFilter := pf
                }
            }

            ; ── 读取 StripOrderPrefix ──
            try {
                val := Trim(IniRead(ConfigPath, sectionName, "StripOrderPrefix", ""))
                if val != "" {
                    if val = "1"
                        folderStripOrderPrefix := 1
                    else if val = "0"
                        folderStripOrderPrefix := 0
                    else
                        errors.Push("[" sectionName "] 中 StripOrderPrefix 只能为 0 或 1，实际值为：" val "。")
                }
            }

            ; ── 读取 HideExtensions ──
            try {
                val := Trim(IniRead(ConfigPath, sectionName, "HideExtensions", ""))
                if val != "" {
                    if val = "1"
                        folderHideExtensions := 1
                    else if val = "0"
                        folderHideExtensions := 0
                    else
                        errors.Push("[" sectionName "] 中 HideExtensions 只能为 0 或 1，实际值为：" val "。")
                }
            }
        }

        rawNoiseMode := IniRead(ConfigPath, sectionName, "NoiseFilterMode", "")
        if Trim(rawNoiseMode) = ""
            rawNoiseMode := IniRead(ConfigPath, "Source:" sourceId,
                "NoiseFilterMode", NOISE_FILTER_INHERIT)
        if !IsRecognizedNoiseFilterMode(rawNoiseMode)
            errors.Push("[" sectionName "] 中 NoiseFilterMode 值无效："
                rawNoiseMode "。允许的值：Inherit, Enabled, Disabled。")
        folderNoiseFilterMode := ParseNoiseFilterMode(rawNoiseMode)
        resolvedNoiseFilter := ResolveNoiseFilterForSource(
            folderNoiseFilterMode, sourcePatternTexts)
        for patternError in resolvedNoiseFilter.PatternErrors
            errors.Push("来源“" f.Name "”" patternError)

        if ParseWorkspaceType(workspaceType) = WORKSPACE_TYPE_TEXT {
            folderMode := MODE_FILES
            folderRecursive := true
            folderDisplayScope := SCOPE_RECURSIVE_FILES
            folderFilter := {Mode: "Include", Extensions: [".md", ".txt"]}
            if !ValueInArray(folderSortMode,
                [SORT_SMART, SORT_MODIFIED_DESC, SORT_NAME_ASC])
                folderSortMode := SORT_SMART
            folderStripOrderPrefix := 0
            folderHideExtensions := 1
        }

        resolved.Push({
            Name: f.Name,
            Path: f.Path,
            Mode: folderMode,
            IncludeSubfolders: folderRecursive,
            DisplayScope: folderDisplayScope,
            FolderTimeMode: folderTimeMode,
            MaxFilesPerFolder: folderMax,
            MaxFilesPerFolderInherited: folderMaxInherited,
            SortMode: folderSortMode,
            Filter: folderFilter,
            StripOrderPrefix: folderStripOrderPrefix,
            HideExtensions: folderHideExtensions,
            SourceId: sourceId,
            OpenFileMode: folderOpenFileMode,
            NoiseFilterMode: folderNoiseFilterMode,
            NoiseFilter: resolvedNoiseFilter,
            SourceCustomPatternTexts: sourcePatternTexts,
            ExcludedPaths: LoadConfiguredSourcePaths(
                "SourceExclude:" sourceId, f.Path),
            AllowedExcludedPaths: LoadConfiguredSourcePaths(
                "SourceAllow:" sourceId, f.Path),
            WorkspaceType: ParseWorkspaceType(workspaceType)
        })
    }

    if errors.Length {
        ConfigErrors := errors
        return {Valid: false, Errors: errors, Settings: resolved}
    }

    ; 验证通过，返回设置
    return {Valid: true, Errors: errors, Settings: resolved}
}

MakeUniqueSourceId(sourceId, seen) {
    base := sourceId
    candidate := base
    suffix := 2
    while seen.Has(StrLower(candidate)) {
        candidate := base "-" suffix
        suffix += 1
    }
    seen[StrLower(candidate)] := true
    return candidate
}

ParseFilterSettings(mode, rawExtensions, context) {
    ; mode: 小写，已 trim
    ; 返回 {Mode: "...", Extensions: [...], Error: ""} 或 {Error: "..."}

    if mode = "" || mode = "all"
        return {Mode: "All", Extensions: []}

    if mode = "include" || mode = "exclude" {
        if rawExtensions = "" {
            return {Error: context " 中 FilterMode=" mode " 但 FileExtensions 为空。请提供至少一个扩展名。"}
        }
        exts := NormalizeExtensionList(rawExtensions)
        invalid := []
        for ext in exts {
            if RegExMatch(ext, "[*?\\/]") {
                invalid.Push(ext)
            }
        }
        if invalid.Length {
            return {Error: context " 中 FileExtensions 包含非法字符（* ? \ /）：" JoinArray(invalid, ", ")}
        }
        return {Mode: mode, Extensions: exts}
    }

    if mode = "inherit"
        return {Mode: "Inherit", Extensions: []}

    return {Error: context " 中 FilterMode 值无效：" mode "。允许的值：All, Include, Exclude（文件夹级还支持 Inherit）。"}
}

NormalizeExtensionList(raw) {
    ; 解析逗号分隔的扩展名列表
    ; 返回规范化后的小写扩展名数组（含 . 前缀），去重
    if raw = ""
        return []

    seen := Map()
    result := []
    parts := StrSplit(raw, ",", " `t")

    for part in parts {
        p := Trim(part)
        if p = ""
            continue

        ; 确保以 . 开头
        ext := SubStr(p, 1, 1) = "." ? p : "." p
        ext := StrLower(ext)

        if seen.Has(ext)
            continue
        seen[ext] := true
        result.Push(ext)
    }
    return result
}

LoadNoiseFilterConfig() {
    patternTexts := LoadIgnorePatternTexts("NoiseFilter")
    compiled := CompileIgnorePatterns(patternTexts, "[NoiseFilter]")
    return {
        Enabled: ReadConfigBoolean("NoiseFilter", "Enabled", true),
        HideHidden: ReadConfigBoolean("NoiseFilter", "HideHidden", true),
        HideSystem: ReadConfigBoolean("NoiseFilter", "HideSystem", true),
        HideTemporary: ReadConfigBoolean("NoiseFilter", "HideTemporaryAttribute", false),
        HideIncompleteDownloads: ReadConfigBoolean("NoiseFilter", "HideIncompleteDownloads", false),
        CustomPatterns: compiled.Patterns,
        CustomPatternTexts: compiled.Texts,
        PatternErrors: compiled.Errors
    }
}

ReadConfigBoolean(section, key, defaultValue) {
    global ConfigPath
    raw := Trim(IniRead(ConfigPath, section, key, defaultValue ? "1" : "0"))
    if raw = "1"
        return true
    if raw = "0"
        return false
    return defaultValue
}

LoadIgnorePatternTexts(section) {
    result := []
    for entry in ReadIniSection(section) {
        if RegExMatch(entry.Key, "i)^(?:Custom)?Pattern\d+$")
            result.Push(entry.Value)
    }
    return NormalizeIgnorePatternTexts(result)
}

NormalizeIgnorePatternTextBlock(text) {
    text := StrReplace(text, "`r`n", "`n")
    text := StrReplace(text, "`r", "`n")
    return NormalizeIgnorePatternTexts(StrSplit(text, "`n"))
}

NormalizeIgnorePatternTexts(values) {
    result := []
    seen := Map()
    for value in values {
        pattern := Trim(value)
        folded := StrLower(pattern)
        if pattern = "" || seen.Has(folded)
            continue
        seen[folded] := true
        result.Push(pattern)
    }
    return result
}

CompileIgnorePatterns(patternTexts, context := "") {
    result := []
    texts := []
    errors := []
    for pattern in NormalizeIgnorePatternTexts(patternTexts) {
        regex := WildcardPatternToRegex(pattern)
        if regex = "" {
            errors.Push((context != "" ? context " " : "")
                . "中的忽略规则无法编译，已跳过：" pattern)
            continue
        }
        result.Push({Text: pattern, Regex: regex})
        texts.Push(pattern)
    }
    return {Patterns: result, Texts: texts, Errors: errors}
}

WildcardPatternToRegex(pattern) {
    regex := "i)^"
    special := "\.^$|()[]{}+"
    for char in StrSplit(pattern) {
        if char = "*"
            regex .= ".*"
        else if char = "?"
            regex .= "."
        else {
            if InStr(special, char)
                regex .= "\"
            regex .= char
        }
    }
    regex .= "$"
    try {
        RegExMatch("", regex)
        return regex
    } catch {
        return ""
    }
}

ParseNoiseFilterMode(raw) {
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    folded := StrLower(Trim(raw))
    if folded = StrLower(NOISE_FILTER_ENABLED)
        return NOISE_FILTER_ENABLED
    if folded = StrLower(NOISE_FILTER_DISABLED)
        return NOISE_FILTER_DISABLED
    return NOISE_FILTER_INHERIT
}

IsRecognizedNoiseFilterMode(raw) {
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    folded := StrLower(Trim(raw))
    return folded = StrLower(NOISE_FILTER_INHERIT)
        || folded = StrLower(NOISE_FILTER_ENABLED)
        || folded = StrLower(NOISE_FILTER_DISABLED)
}

ResolveNoiseFilterForSource(mode, sourcePatternTexts) {
    global GlobalNoiseFilter, NOISE_FILTER_DISABLED, NOISE_FILTER_ENABLED
    enabled := mode = NOISE_FILTER_ENABLED
        || (mode != NOISE_FILTER_DISABLED && GlobalNoiseFilter.Enabled)
    sourceCompiled := CompileIgnorePatterns(sourcePatternTexts, "来源附加规则")
    return {
        Enabled: enabled,
        HideHidden: GlobalNoiseFilter.HideHidden,
        HideSystem: GlobalNoiseFilter.HideSystem,
        HideTemporary: GlobalNoiseFilter.HideTemporary,
        HideIncompleteDownloads: GlobalNoiseFilter.HideIncompleteDownloads,
        CustomPatterns: GlobalNoiseFilter.CustomPatterns,
        SourceCustomPatterns: sourceCompiled.Patterns,
        PatternErrors: sourceCompiled.Errors
    }
}

HasDangerousIgnorePattern(patternTexts) {
    for pattern in patternTexts {
        folded := StrLower(Trim(pattern))
        if folded = "*" || folded = "*.*"
            return true
    }
    return false
}

GetFileExtensionType(path) {
    global NO_EXTENSION_TOKEN
    SplitPath(path, &name, , &extension)
    if extension = ""
        return NO_EXTENSION_TOKEN
    return "." StrLower(extension)
}
