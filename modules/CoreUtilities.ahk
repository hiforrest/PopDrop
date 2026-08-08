; Shared filters, persistence helpers and path utilities.

ShouldIncludeFile(filename, filter) {
    ; filter: {Mode: "All"|"Include"|"Exclude", Extensions: [...]}
    if filter.Mode = "All"
        return true

    if filter.Mode = "Include" {
        if !filter.Extensions.Length
            return true ; 无扩展名列表则通过（防御性）
        for ext in filter.Extensions {
            if StrLower(SubStr(filename, -StrLen(ext))) = ext
                return true
        }
        return false
    }

    if filter.Mode = "Exclude" {
        if !filter.Extensions.Length
            return true ; 无扩展名列表则不排除
        for ext in filter.Extensions {
            if StrLower(SubStr(filename, -StrLen(ext))) = ext
                return false
        }
        return true
    }

    return true ; 未知模式，安全通过
}

JoinArray(arr, sep) {
    s := ""
    for i, v in arr {
        if i > 1
            s .= sep
        s .= v
    }
    return s
}

ShowConfigErrorDialog() {
    global ConfigErrors, ConfigErrorsShown
    if ConfigErrors.Length && !ConfigErrorsShown {
        msg := "配置有 " ConfigErrors.Length " 处问题，已继续使用上一次有效设置。`n`n"
        msg .= "详细错误信息：`n"
        for i, err in ConfigErrors
            msg .= "  " i ". " err "`n"
        ShowPanelMsgBox(msg, "PopDrop 配置错误", "Icon!")
        ConfigErrorsShown := true
    }
}

ReadIniSection(sectionName) {
    global ConfigPath
    return ReadIniSectionFrom(ConfigPath, sectionName)
}

ReadIniSectionFrom(path, sectionName) {
    result := []
    try raw := IniRead(path, sectionName)
    catch
        return result

    for line in StrSplit(raw, "`n", "`r") {
        equalPos := InStr(line, "=")
        if !equalPos
            continue
        key := Trim(SubStr(line, 1, equalPos - 1))
        value := Trim(SubStr(line, equalPos + 1))
        if key != ""
            result.Push({Key: key, Value: value})
    }
    return result
}

LoadPathListSection(sectionName, limit := 0) {
    result := []
    for entry in ReadIniSection(sectionName) {
        if !RegExMatch(entry.Key, "i)^Path\d+$")
            continue
        path := NormalizePath(entry.Value)
        if path != "" && !ArrayContainsPath(result, path) {
            result.Push(path)
            if limit > 0 && result.Length >= limit
                break
        }
    }
    return result
}

LoadTransferFavorites(settingErrors) {
    global ConfigPath

    configured := LoadPathListSection("TransferFavorites", 5)
    initialized := IniRead(ConfigPath, "General",
        "TransferFavoritesInitialized", "0") = "1"
    if initialized
        return configured

    ; One-time migration for v0.7 configs that injected Desktop/Downloads at
    ; menu-build time. Persist them now, while preserving existing custom paths.
    migrated := GetDefaultTransferFavoritePaths()
    for path in configured {
        if migrated.Length >= 5
            break
        if !ArrayContainsPath(migrated, path)
            migrated.Push(path)
    }
    try AtomicConfigEdit(WriteInitialTransferFavoritesConfig.Bind(migrated))
    catch as err
        settingErrors.Push("无法迁移常用位置配置：" err.Message)
    return migrated
}

GetDefaultTransferFavoritePaths() {
    result := []
    desktop := GetKnownFolderPath("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}")
    downloads := GetKnownFolderPath("{374DE290-123F-4565-9164-39C4925E467B}")
    if desktop != ""
        result.Push(desktop)
    if downloads != "" && !ArrayContainsPath(result, downloads)
        result.Push(downloads)
    return result
}

WriteInitialTransferFavoritesConfig(favorites, tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    doc.ReplaceSection("TransferFavorites",
        ConfigEntriesFromValues(favorites, "Path"), 5)
    doc.SetValue("General", "TransferFavoritesInitialized", "1", 1)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

AtomicConfigEdit(editor) {
    global ConfigPath, ConfigEditInProgress, ConfigEditSerial
    global LoadedConfigStamp
    previousCritical := A_IsCritical
    Critical("On")
    if ConfigEditInProgress {
        Critical(previousCritical)
        throw Error("配置写入事务正在进行，不能重复进入。")
    }
    ConfigEditInProgress := true
    ConfigEditSerial += 1
    tempPath := ConfigPath ".tmp-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount "-" ConfigEditSerial
    try FileDelete(tempPath)
    try {
        configExisted := FileExist(ConfigPath) != ""
        baseline := configExisted ? FileRead(ConfigPath, "RAW") : 0
        if configExisted
            FileCopy(ConfigPath, tempPath, 1)
        else
            FileAppend("", tempPath, "UTF-16")
        editor.Call(tempPath)
        ; The callback edits only the private temporary copy. Re-open it before
        ; replacement so malformed/duplicate sections, wrong layout or BOM
        ; corruption can never reach the live config.
        verified := OpenPopDropConfig(tempPath)
        verified.Save()
        ; Do not silently overwrite a manual edit or another writer that
        ; completed after this transaction copied its baseline.
        if configExisted {
            if !FileExist(ConfigPath)
                throw Error("配置文件在保存期间被删除；已取消本次写入。")
            current := FileRead(ConfigPath, "RAW")
            if !BuffersEqual(baseline, current)
                throw Error("配置文件在保存期间被其他程序修改；"
                    "已保留外部修改并取消本次写入，请刷新后重试。")
        } else if FileExist(ConfigPath) {
            throw Error("配置文件在保存期间由其他程序创建；已取消本次写入。")
        }
        ; ReplaceFileW is atomic on the same volume and preserves metadata.
        replaced := DllCall("kernel32\ReplaceFileW", "wstr", ConfigPath,
            "wstr", tempPath, "ptr", 0, "uint", 0x2,
            "ptr", 0, "ptr", 0, "int")
        if !replaced {
            ; New configurations may not have a destination yet. MoveFileExW
            ; remains a same-volume replace and requests write-through.
            if !DllCall("kernel32\MoveFileExW", "wstr", tempPath,
                "wstr", ConfigPath, "uint", 0x9, "int")
                throw OSError(A_LastError, "无法原子替换配置文件")
        }
        ; Runtime writers already applied the same change to memory. Record
        ; the new disk identity so the next F2 show does not reload and repaint
        ; an unchanged configuration.
        LoadedConfigStamp := GetConfigFileStamp()
    } catch {
        try FileDelete(tempPath)
        throw
    } finally {
        ConfigEditInProgress := false
        Critical(previousCritical)
    }
}

GetConfigFileStamp() {
    global ConfigPath
    if !FileExist(ConfigPath)
        return ""
    try return FileGetSize(ConfigPath) "|" FileGetTime(ConfigPath, "M")
    catch
        return ""
}

ConfigFileChangedSinceLoad() {
    global LoadedConfigStamp
    current := GetConfigFileStamp()
    return current = "" || current != LoadedConfigStamp
}

BuffersEqual(left, right) {
    if left.Size != right.Size
        return false
    Loop left.Size {
        offset := A_Index - 1
        if NumGet(left, offset, "UChar") != NumGet(right, offset, "UChar")
            return false
    }
    return true
}

AtomicConfigSetValue(section, key, value, area := 1) {
    AtomicConfigEdit(WriteSingleConfigValue.Bind(
        section, key, value, area))
}

WriteSingleConfigValue(section, key, value, area, tempPath) {
    global CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    doc.SetValue(section, key, value, area)
    if StrLower(section) != "general" || StrLower(key) != "configversion"
        doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

NormalizePath(path) {
    path := Trim(path, " `t`r`n`"")
    if path = ""
        return ""
    path := StrReplace(path, "/", "\")

    required := DllCall("kernel32\ExpandEnvironmentStringsW", "str", path, "ptr", 0, "uint", 0, "uint")
    if required {
        expanded := Buffer(required * 2, 0)
        DllCall("kernel32\ExpandEnvironmentStringsW", "str", path, "ptr", expanded.Ptr, "uint", required)
        path := StrGet(expanded)
    }

    if !RegExMatch(path, "i)^(?:[A-Z]:\\|\\\\)")
        path := A_ScriptDir "\" path
    required := DllCall("kernel32\GetFullPathNameW", "wstr", path,
        "uint", 0, "ptr", 0, "ptr", 0, "uint")
    if required {
        full := Buffer((required + 1) * 2, 0)
        if DllCall("kernel32\GetFullPathNameW", "wstr", path,
            "uint", required + 1, "ptr", full.Ptr, "ptr", 0, "uint")
            path := StrGet(full)
    }
    if IsPathRoot(path)
        return path
    return RTrim(path, "\")
}

IsPathRoot(path) {
    return RegExMatch(path, "i)^(?:[A-Z]:\\|\\\\[^\\]+\\[^\\]+\\?)$")
}

PathKey(path) {
    path := NormalizePath(path)
    if SubStr(path, 1, 8) = "\\?\UNC\"
        path := "\\" SubStr(path, 9)
    else if SubStr(path, 1, 4) = "\\?\"
        path := SubStr(path, 5)
    if !IsPathRoot(path)
        path := RTrim(path, "\")
    return StrLower(path)
}

PathsEqual(left, right) {
    return PathKey(left) = PathKey(right)
}

GetParentPath(path) {
    path := NormalizePath(path)
    SplitPath(path, , &parent)
    return NormalizePath(parent)
}

IsSameOrDescendantPath(candidate, ancestor) {
    candidateKey := PathKey(candidate)
    ancestorKey := RTrim(PathKey(ancestor), "\")
    return candidateKey = ancestorKey
        || SubStr(candidateKey, 1, StrLen(ancestorKey) + 1) = ancestorKey "\"
}
ResolvePopDropDataRoot() {
    scriptDir := A_ScriptDir
    startup := EnvGet("APPDATA") "\Microsoft\Windows\Start Menu\Programs\Startup"
    if startup != "" && StrLower(RTrim(scriptDir, "\"))
        = StrLower(RTrim(startup, "\")) {
        localAppData := EnvGet("LOCALAPPDATA")
        if localAppData = ""
            localAppData := A_AppData
        root := localAppData "\PopDrop"
        try DirCreate(root)
        ; Preserve configurations created by the affected startup-folder
        ; builds when switching to the isolated data root.
        if !FileExist(root "\config.ini") && FileExist(scriptDir "\config.ini") {
            try FileCopy(scriptDir "\config.ini", root "\config.ini")
        }
        return root
    }
    return scriptDir
}

ReadStartupEnabled() {
    global ConfigPath
    return IniRead(ConfigPath, "General", "StartupEnabled", "0") = "1"
}

GetPopDropStartupShortcutPath() {
    startup := EnvGet("APPDATA") "\Microsoft\Windows\Start Menu\Programs\Startup"
    return startup "\PopDrop.lnk"
}

ApplyStartupShortcut(enabled) {
    shortcut := GetPopDropStartupShortcutPath()
    if !enabled {
        try FileDelete(shortcut)
        return
    }
    try {
        shell := ComObject("WScript.Shell")
        link := shell.CreateShortcut(shortcut)
        if A_IsCompiled {
            link.TargetPath := A_ScriptFullPath
            link.Arguments := ""
            link.WorkingDirectory := A_ScriptDir
            link.IconLocation := A_ScriptFullPath ",0"
        } else {
            link.TargetPath := A_AhkPath
            link.Arguments := '"' A_ScriptFullPath '"'
            link.WorkingDirectory := A_ScriptDir
            link.IconLocation := A_ScriptDir "\assets\app.ico"
        }
        link.Description := "PopDrop"
        link.Save()
    } catch as err {
        throw Error("无法更新开机启动快捷方式：" err.Message)
    }
}
