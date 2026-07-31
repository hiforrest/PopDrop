; Configured applications, action templates and process execution.

LoadOpenApps() {
    global ConfigPath, OpenAppsConfigNeedsMigration, ConfigErrors
    apps := []
    seenIds := Map()
    seenPaths := Map()
    actionDocument := PopDropConfigDocument(ConfigPath)
    legacyFormat := OpenAppsConfigUsesLegacyFormat(ConfigPath)
    if legacyFormat
        OpenAppsConfigNeedsMigration := true
    sourceIds := ReadOpenAppIdsFrom(ConfigPath)
    reservedIds := Map()
    for sourceId in sourceIds {
        if !IsGuidOpenAppId(sourceId)
            reservedIds[StrLower(sourceId)] := true
    }
    for sourceId in sourceIds {
        section := "OpenApp:" sourceId
        programPath := NormalizePath(IniRead(ConfigPath, section, "Path", ""))
        if programPath = "" || !IsExecutablePath(programPath)
            continue
        id := sourceId
        if legacyFormat && IsGuidOpenAppId(id) {
            id := NewOpenAppIdForApps(programPath, apps, reservedIds)
            OpenAppsConfigNeedsMigration := true
        }
        if seenIds.Has(StrLower(id))
            continue
        programPathKey := PathKey(programPath)
        if seenPaths.Has(programPathKey)
            continue
        seenIds[StrLower(id)] := true
        seenPaths[programPathKey] := true
        name := Trim(IniRead(ConfigPath, section, "Name", ""))
        if name = ""
            name := GetExecutableDisplayName(programPath)
        extensions := NormalizeOpenAppExtensions(
            IniRead(ConfigPath, section, "Extensions", ""))
        enabled := IniRead(ConfigPath, section, "Enabled", "1") != "0"
        rawShowInOpenMenu := Trim(IniRead(
            ConfigPath, section, "ShowInOpenMenu", "1"))
        showInOpenMenu := rawShowInOpenMenu != "0"
        if rawShowInOpenMenu != "0" && rawShowInOpenMenu != "1" {
            showInOpenMenu := true
            ConfigErrors.Push("[" section "] ShowInOpenMenu 值无效："
                rawShowInOpenMenu "。已按 1 处理。")
        }
        icon := NormalizePath(IniRead(ConfigPath, section, "Icon", programPath))
        if icon = ""
            icon := programPath
        app := {
            Id: id,
            Path: programPath,
            Name: name,
            Icon: icon,
            Extensions: extensions,
            Enabled: enabled,
            ShowInOpenMenu: showInOpenMenu,
            Actions: []
        }
        app.Actions := LoadOpenAppActions(app, actionDocument)
        apps.Push(app)
    }
    return apps
}

LoadOpenAppActions(app, actionDocument) {
    global ConfigPath, ConfigErrors, OpenAppsConfigNeedsMigration
    global ACTION_EXECUTION_PER_ITEM, ACTION_EXECUTION_BATCH
    global ACTION_WORKDIR_FOLDER
    result := []
    appSection := "OpenApp:" app.Id
    rawOrder := IniRead(ConfigPath, appSection, "ActionOrder", "")
    ids := ParseOpenAppActionOrder(rawOrder)
    orderSeen := Map()
    for part in StrSplit(rawOrder, ",") {
        candidate := Trim(part)
        if candidate != "" && !IsSafeOpenAppActionId(candidate)
            ConfigErrors.Push("[" appSection "] ActionOrder 包含无效动作 ID："
                candidate)
        else if candidate != "" {
            foldedCandidate := StrLower(candidate)
            if orderSeen.Has(foldedCandidate)
                ConfigErrors.Push("[" appSection "] ActionOrder 动作 ID 重复："
                    candidate)
            else
                orderSeen[foldedCandidate] := true
        }
    }
    seen := Map()
    for id in ids {
        folded := StrLower(id)
        if seen.Has(folded)
            continue
        seen[folded] := true
        section := "OpenAppAction:" app.Id ":" id
        argResult := ReadOpenAppActionArgs(actionDocument, section)
        boolErrors := []
        missing := Chr(30) "missing" Chr(30)
        rawExecutionMode := actionDocument.GetValue(
            section, "ExecutionMode", missing)
        legacySchema := rawExecutionMode = missing
        if legacySchema {
            legacySelectionMode := Trim(actionDocument.GetValue(
                section, "SelectionMode", "Single"))
            executionMode := StrLower(legacySelectionMode) = "any"
                ? ACTION_EXECUTION_BATCH : ACTION_EXECUTION_PER_ITEM
            if !ValueInArray(StrLower(legacySelectionMode),
                ["single", "any"])
                executionMode := legacySelectionMode
            OpenAppsConfigNeedsMigration := true
        } else
            executionMode := Trim(rawExecutionMode)
        rawRequireCommonFolder := actionDocument.GetValue(
            section, "RequireCommonFolder", missing)
        if rawRequireCommonFolder = missing {
            rawRequireCommonFolder := actionDocument.GetValue(
                section, "RequireCommonParent", "0")
            OpenAppsConfigNeedsMigration := true
        }
        requireCommonFolder := ParseOpenAppActionBoolean(
            rawRequireCommonFolder, false,
            "RequireCommonFolder", boolErrors)
        confirm := ParseOpenAppActionBoolean(
            IniRead(ConfigPath, section, "Confirm", "0"),
            false, "Confirm", boolErrors)
        enabled := ParseOpenAppActionBoolean(
            IniRead(ConfigPath, section, "Enabled", "1"),
            true, "Enabled", boolErrors)
        rawExtensions := IniRead(
            ConfigPath, section, "Extensions", "")
        extensionErrors := ValidateActionExtensionInput(rawExtensions)
        workingDirectoryMode := Trim(actionDocument.GetValue(
            section, "WorkingDirectoryMode", ACTION_WORKDIR_FOLDER))
        if StrLower(workingDirectoryMode) = "parent" {
            workingDirectoryMode := ACTION_WORKDIR_FOLDER
            OpenAppsConfigNeedsMigration := true
        }
        workingDirectory := Trim(actionDocument.GetValue(
            section, "WorkingDirectory", ""))
        if legacySchema {
            for index, arg in argResult.Args
                argResult.Args[index] := StrReplace(
                    arg, "{parent}", "{folder}", false)
            workingDirectory := StrReplace(
                workingDirectory, "{parent}", "{folder}", false)
        }
        action := {
            Id: id,
            Name: Trim(IniRead(ConfigPath, section, "Name", "")),
            Executable: NormalizePath(
                IniRead(ConfigPath, section, "Executable", "")),
            TargetTypes: Trim(IniRead(
                ConfigPath, section, "TargetTypes", "Files")),
            ExecutionMode: executionMode,
            Extensions: NormalizeActionExtensions(rawExtensions),
            RequireCommonFolder: requireCommonFolder,
            WorkingDirectoryMode: workingDirectoryMode,
            WorkingDirectory: workingDirectory,
            Confirm: confirm,
            Enabled: enabled,
            Args: argResult.Args,
            Valid: argResult.Valid,
            ValidationError: argResult.Error
        }
        validation := ValidateOpenAppAction(action, app, false)
        for item in boolErrors
            validation.Errors.Push(item)
        for item in extensionErrors
            validation.Errors.Push(item)
        if validation.Errors.Length {
            action.Valid := false
            action.ValidationError := JoinArray(validation.Errors, "；")
        }
        result.Push(action)
    }
    return result
}

ParseOpenAppActionBoolean(raw, defaultValue, key, errors) {
    raw := Trim(raw)
    if raw = "1"
        return true
    if raw = "0"
        return false
    errors.Push(key " 必须是 0 或 1")
    return defaultValue
}

ParseOpenAppActionOrder(raw) {
    ids := []
    seen := Map()
    for part in StrSplit(raw, ",") {
        id := Trim(part)
        folded := StrLower(id)
        if !IsSafeOpenAppActionId(id) || seen.Has(folded)
            continue
        seen[folded] := true
        ids.Push(id)
    }
    return ids
}

IsSafeOpenAppActionId(id) {
    return RegExMatch(Trim(id), "i)^[a-z0-9][a-z0-9_-]*$")
}

ReadOpenAppActionArgs(document, section) {
    rawCount := Trim(document.GetValue(section, "ArgCount", ""))
    if !RegExMatch(rawCount, "^\d+$")
        return {Args: [], Valid: false, Error: "ArgCount 必须是非负整数"}
    count := Integer(rawCount)
    if count > 999
        return {Args: [], Valid: false, Error: "ArgCount 不能超过 999"}
    indexed := Map()
    for entry in document.GetEntries(section) {
        if RegExMatch(entry.Key, "i)^Arg(\d{3})$", &match)
            indexed[Integer(match[1])] := entry.Value
    }
    if indexed.Count != count
        return {Args: [], Valid: false,
            Error: "ArgCount 与 ArgNNN 参数项数量不一致"}
    args := []
    Loop count {
        key := "Arg" Format("{:03}", A_Index)
        if !indexed.Has(A_Index)
            return {Args: args, Valid: false, Error: "缺少 " key}
        args.Push(indexed[A_Index])
    }
    return {Args: args, Valid: true, Error: ""}
}

OpenAppsConfigUsesLegacyFormat(path) {
    legacyEntryFound := false
    for entry in ReadIniSectionFrom(path, "OpenApps") {
        if StrLower(entry.Key) = "order"
            return false
        if RegExMatch(entry.Key, "i)^App\d+$")
            legacyEntryFound := true
    }
    return legacyEntryFound
}

ReadOpenAppIdsFrom(path) {
    legacyIds := []
    orderFound := false
    orderValue := ""
    for entry in ReadIniSectionFrom(path, "OpenApps") {
        if StrLower(entry.Key) = "order" {
            orderFound := true
            orderValue := entry.Value
            continue
        }
        ; v0.7 早期格式：App001=<UUID 或自定义 ID>。
        if RegExMatch(entry.Key, "i)^App\d+$") {
            id := Trim(entry.Value)
            if (IsSafeOpenAppId(id)
                && !ArrayContainsTextInsensitive(legacyIds, id))
                legacyIds.Push(id)
        }
    }
    ; 只要存在 Order 键（即使为空），它就是唯一排序来源。
    return orderFound ? ParseOpenAppOrder(orderValue) : legacyIds
}

ParseOpenAppOrder(raw) {
    ids := []
    seen := Map()
    for part in StrSplit(raw, ",") {
        id := Trim(part)
        key := StrLower(id)
        if !IsSafeOpenAppId(id) || seen.Has(key)
            continue
        seen[key] := true
        ids.Push(id)
    }
    return ids
}

IsSafeOpenAppId(id) {
    id := Trim(id)
    return id != "" && !RegExMatch(id, "[,\[\]=`r`n]")
}

IsGuidOpenAppId(id) {
    return RegExMatch(id,
        "i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
}

NormalizeOpenAppExtensions(raw) {
    global NO_EXTENSION_TOKEN
    result := []
    seen := Map()
    for part in StrSplit(raw, ",", " `t") {
        value := StrLower(Trim(part))
        if value = ""
            continue
        if value = StrLower(NO_EXTENSION_TOKEN) || value = "none"
            value := NO_EXTENSION_TOKEN
        else
            value := SubStr(value, 1, 1) = "." ? value : "." value
        if !seen.Has(value) {
            seen[value] := true
            result.Push(value)
        }
    }
    return result
}

NormalizeActionExtensions(raw) {
    global NO_EXTENSION_TOKEN
    result := []
    seen := Map()
    raw := RegExReplace(raw, "[;\s]+", ",")
    for part in StrSplit(raw, ",") {
        value := StrLower(Trim(part))
        if value = ""
            continue
        if value = StrLower(NO_EXTENSION_TOKEN) || value = "none"
            value := NO_EXTENSION_TOKEN
        else {
            value := SubStr(value, 1, 1) = "." ? value : "." value
            if value = "." || RegExMatch(value, "[\\/:*?`"<>|{}]")
                continue
        }
        if !seen.Has(value) {
            seen[value] := true
            result.Push(value)
        }
    }
    ; Longest suffix first makes the intended .tar.gz semantics explicit.
    Loop result.Length {
        left := A_Index
        right := left + 1
        while right <= result.Length {
            if StrLen(result[right]) > StrLen(result[left]) {
                swap := result[left]
                result[left] := result[right]
                result[right] := swap
            }
            right += 1
        }
    }
    return result
}

ValidateActionExtensionInput(raw) {
    errors := []
    raw := RegExReplace(raw, "[;\s]+", ",")
    for part in StrSplit(raw, ",") {
        value := StrLower(Trim(part))
        if value = "" || value = "<none>" || value = "none"
            continue
        if SubStr(value, 1, 1) = "."
            value := SubStr(value, 2)
        if value = "" || RegExMatch(value, "[\\/:*?`"<>|{}]")
            errors.Push("无效扩展名：" part)
    }
    return errors
}

GetApplicableOpenApps(filePath) {
    global OpenApps
    extensionType := GetFileExtensionType(filePath)
    exact := []
    generic := []
    for app in OpenApps {
        if !app.Enabled || !app.ShowInOpenMenu
            continue
        if !app.Extensions.Length {
            generic.Push(app)
            continue
        }
        for extension in app.Extensions {
            if StrLower(extension) = StrLower(extensionType) {
                exact.Push(app)
                break
            }
        }
    }
    for app in generic
        exact.Push(app)
    return exact
}

CloneOpenAppAction(action) {
    return {
        Id: action.Id,
        Name: action.Name,
        Executable: action.Executable,
        TargetTypes: action.TargetTypes,
        ExecutionMode: action.ExecutionMode,
        Extensions: action.Extensions.Clone(),
        RequireCommonFolder: action.RequireCommonFolder,
        WorkingDirectoryMode: action.WorkingDirectoryMode,
        WorkingDirectory: action.WorkingDirectory,
        Confirm: action.Confirm,
        Enabled: action.Enabled,
        Args: action.Args.Clone(),
        Valid: action.Valid,
        ValidationError: action.ValidationError
    }
}

ValidateOpenAppAction(action, app, requireExisting := true) {
    global ACTION_TARGET_FILES, ACTION_TARGET_FOLDERS, ACTION_TARGET_BOTH
    global ACTION_EXECUTION_PER_ITEM, ACTION_EXECUTION_BATCH
    global ACTION_WORKDIR_FOLDER, ACTION_WORKDIR_PROGRAM
    global ACTION_WORKDIR_CUSTOM
    errors := []
    warnings := []
    if Trim(action.Name) = ""
        errors.Push("动作名称不能为空")
    executable := action.Executable != "" ? action.Executable : app.Path
    if !IsExecutablePath(executable)
        errors.Push("执行程序必须是 .exe")
    else if requireExisting && !IsExistingExecutable(executable)
        warnings.Push("执行程序不存在：" executable)
    if !ValueInArray(action.TargetTypes,
        [ACTION_TARGET_FILES, ACTION_TARGET_FOLDERS, ACTION_TARGET_BOTH])
        errors.Push("适用对象无效")
    if !ValueInArray(action.ExecutionMode,
        [ACTION_EXECUTION_PER_ITEM, ACTION_EXECUTION_BATCH])
        errors.Push("执行模式无效")
    if !ValueInArray(action.WorkingDirectoryMode,
        [ACTION_WORKDIR_FOLDER, ACTION_WORKDIR_PROGRAM,
         ACTION_WORKDIR_CUSTOM])
        errors.Push("工作目录模式无效")
    if action.WorkingDirectoryMode = ACTION_WORKDIR_CUSTOM
        && Trim(action.WorkingDirectory) = ""
        errors.Push("自定义工作目录不能为空")
    allowItems := action.ExecutionMode = ACTION_EXECUTION_BATCH
    for arg in action.Args
        ValidateActionTemplateText(arg, allowItems, errors)
    if action.WorkingDirectoryMode = ACTION_WORKDIR_CUSTOM
        ValidateActionTemplateText(action.WorkingDirectory, false, errors)
    return {Errors: errors, Warnings: warnings}
}

ValidateActionTemplateText(text, allowItems, errors) {
    position := 1
    while (foundAt := RegExMatch(
        text, "\{([^{}]+)\}", &match, position
    )) {
        variable := StrLower(match[1])
        if !ValueInArray(variable,
            ["item", "items", "folder", "parent", "name", "stem",
             "ext", "date", "time", "datetime", "index", "count",
             "size"])
            errors.Push("未知参数变量：{" match[1] "}")
        if variable = "items" && (!allowItems || StrLower(text) != "{items}")
            errors.Push(allowItems
                ? "{items} 必须单独占一个参数"
                : "逐个执行模式不能使用 {items}")
        position := foundAt + StrLen(match[0])
    }
    cleaned := text
    for variable in ["item", "items", "folder", "parent", "name",
        "stem", "ext", "date", "time", "datetime", "index",
        "count", "size"]
        cleaned := StrReplace(
            cleaned, "{" variable "}", "", false)
    if RegExMatch(cleaned, "[{}]")
        errors.Push("参数变量的大括号不完整或名称未知")
}

GetApplicableOpenAppActions(paths, clickedPath) {
    global OpenApps
    result := []
    for app in OpenApps {
        if !app.Enabled
            continue
        for action in app.Actions {
            if IsOpenAppActionApplicable(app, action, paths, clickedPath)
                result.Push({App: app, Action: action})
        }
    }
    return result
}

IsOpenAppActionApplicable(app, action, paths, clickedPath,
    requireExecutable := true
) {
    global ACTION_TARGET_FILES, ACTION_TARGET_FOLDERS
    global ACTION_EXECUTION_BATCH, ACTION_WORKDIR_FOLDER
    if !app.Enabled || !action.Enabled || !action.Valid || !paths.Length
        return false
    if !FileExist(clickedPath) || !ArrayContainsPath(paths, clickedPath)
        return false
    executable := action.Executable != "" ? action.Executable : app.Path
    if requireExecutable && !IsExistingExecutable(executable)
        return false
    hasFile := false
    hasFolder := false
    for path in paths {
        attributes := FileExist(path)
        if attributes = ""
            return false
        if InStr(attributes, "D")
            hasFolder := true
        else {
            hasFile := true
            if action.Extensions.Length
                && !ActionExtensionMatchesPath(path, action.Extensions)
                return false
        }
    }
    if action.TargetTypes = ACTION_TARGET_FILES && hasFolder
        return false
    if action.TargetTypes = ACTION_TARGET_FOLDERS && hasFile
        return false
    if action.RequireCommonFolder && GetCommonFolderPath(paths) = ""
        return false
    if action.ExecutionMode = ACTION_EXECUTION_BATCH {
        needsFolder := action.WorkingDirectoryMode = ACTION_WORKDIR_FOLDER
            || OpenAppActionUsesVariable(action, "folder")
        if needsFolder && GetCommonFolderPath(paths) = ""
            return false
        if OpenAppActionUsesVariable(action, "parent")
            && GetCommonParentFolderPath(paths) = ""
            return false
    }
    return true
}

ActionExtensionMatchesPath(path, extensions) {
    global NO_EXTENSION_TOKEN
    name := StrLower(GetFileName(path))
    for extension in extensions {
        if extension = NO_EXTENSION_TOKEN {
            if GetFileExtensionType(path) = NO_EXTENSION_TOKEN
                return true
            continue
        }
        if StrLen(name) >= StrLen(extension)
            && SubStr(name, -StrLen(extension) + 1) = StrLower(extension)
            return true
    }
    return false
}

GetCommonFolderPath(paths) {
    if !paths.Length
        return ""
    folder := GetParentPath(paths[1])
    for path in paths {
        if !PathsEqual(GetParentPath(path), folder)
            return ""
    }
    return folder
}

GetCommonParentFolderPath(paths) {
    if !paths.Length
        return ""
    parent := GetParentPath(GetParentPath(paths[1]))
    if parent = ""
        return ""
    for path in paths {
        if !PathsEqual(GetParentPath(GetParentPath(path)), parent)
            return ""
    }
    return parent
}

OpenAppActionUsesVariable(action, variable) {
    needle := "{" StrLower(variable) "}"
    for arg in action.Args {
        if InStr(StrLower(arg), needle)
            return true
    }
    return InStr(StrLower(action.WorkingDirectory), needle) > 0
}

RenderOpenAppAction(app, action, paths, clickedPath) {
    global ACTION_EXECUTION_BATCH
    validation := ValidateOpenAppAction(action, app, true)
    if validation.Errors.Length
        return {Valid: false, Error: JoinArray(validation.Errors, "；")}
    if !IsOpenAppActionApplicable(app, action, paths, clickedPath, false)
        return {Valid: false, Error: "当前选择不再符合此动作的执行条件"}
    executable := NormalizePath(
        action.Executable != "" ? action.Executable : app.Path)
    if !IsExistingExecutable(executable)
        return {Valid: false, Error: "找不到执行程序：" executable}
    stamp := A_Now
    commands := []
    if action.ExecutionMode = ACTION_EXECUTION_BATCH {
        clickedIndex := FindPathIndex(paths, clickedPath)
        rendered := RenderOpenAppActionCommand(
            action, executable, paths, clickedPath,
            clickedIndex, paths.Length, stamp)
        if !rendered.Valid
            return rendered
        commands.Push(rendered)
    } else {
        for index, path in paths {
            rendered := RenderOpenAppActionCommand(
                action, executable, [path], path,
                index, paths.Length, stamp)
            if !rendered.Valid
                return {Valid: false, Error: "第 " index " 个项目（"
                    GetFileName(path) "）：" rendered.Error}
            commands.Push(rendered)
        }
    }
    result := {
        Valid: true,
        ExecutionMode: action.ExecutionMode,
        Commands: commands
    }
    if commands.Length = 1 {
        result.Executable := commands[1].Executable
        result.Args := commands[1].Args
        result.Parameters := commands[1].Parameters
        result.WorkingDirectory := commands[1].WorkingDirectory
        result.Preview := commands[1].Preview
    }
    return result
}

RenderOpenAppActionCommand(action, executable, paths, scalarPath,
    index, count, stamp
) {
    global ACTION_WORKDIR_FOLDER, ACTION_WORKDIR_PROGRAM
    global ACTION_COMMAND_LINE_LIMIT
    variables := BuildOpenAppActionVariables(
        scalarPath, index, count, stamp)
    args := []
    for template in action.Args {
        if StrLower(template) = "{items}" {
            for path in paths
                args.Push(path)
        } else
            args.Push(ReplaceOpenAppActionVariables(template, variables))
    }
    if action.WorkingDirectoryMode = ACTION_WORKDIR_FOLDER
        workingDirectory := variables.Folder
    else if action.WorkingDirectoryMode = ACTION_WORKDIR_PROGRAM {
        SplitPath(executable, , &workingDirectory)
    } else {
        workingDirectory := ReplaceOpenAppActionVariables(
            action.WorkingDirectory, variables)
    }
    workingDirectory := NormalizePath(workingDirectory)
    if workingDirectory = "" || !DirExist(workingDirectory)
        return {Valid: false, Error: "工作目录不存在：" workingDirectory}
    parameterText := BuildWindowsParameterString(args)
    commandPreview := QuoteWindowsArgument(executable)
    if parameterText != ""
        commandPreview .= " " parameterText
    if StrLen(commandPreview) > ACTION_COMMAND_LINE_LIMIT
        return {Valid: false, Error: "最终命令行超过 Windows 安全长度限制"}
    return {
        Valid: true,
        Executable: executable,
        ItemPath: scalarPath,
        Args: args,
        Parameters: parameterText,
        WorkingDirectory: workingDirectory,
        Preview: commandPreview
    }
}

BuildOpenAppActionVariables(itemPath, index, count, stamp := "") {
    if stamp = ""
        stamp := A_Now
    SplitPath(itemPath, &name, , &extension, &stem)
    folder := GetParentPath(itemPath)
    return {
        Item: itemPath,
        Folder: folder,
        Parent: GetParentPath(folder),
        Name: name,
        Stem: stem,
        Ext: StrLower(extension),
        Date: FormatTime(stamp, "yyyyMMdd"),
        Time: FormatTime(stamp, "HHmmss"),
        DateTime: FormatTime(stamp, "yyyyMMdd_HHmmss"),
        Index: index,
        Count: count,
        Size: FormatOpenAppActionSize(itemPath)
    }
}

ReplaceOpenAppActionVariables(template, variables) {
    result := template
    result := StrReplace(result, "{item}", variables.Item, false)
    result := StrReplace(result, "{folder}", variables.Folder, false)
    result := StrReplace(result, "{parent}", variables.Parent, false)
    result := StrReplace(result, "{name}", variables.Name, false)
    result := StrReplace(result, "{stem}", variables.Stem, false)
    result := StrReplace(result, "{ext}", variables.Ext, false)
    result := StrReplace(result, "{date}", variables.Date, false)
    result := StrReplace(result, "{time}", variables.Time, false)
    result := StrReplace(result, "{datetime}", variables.DateTime, false)
    result := StrReplace(result, "{index}", variables.Index, false)
    result := StrReplace(result, "{count}", variables.Count, false)
    result := StrReplace(result, "{size}", variables.Size, false)
    return result
}

FormatOpenAppActionSize(path) {
    attributes := FileExist(path)
    if attributes = "" || InStr(attributes, "D")
        return ""
    try bytes := FileGetSize(path)
    catch
        return ""
    units := ["B", "KB", "MB", "GB", "TB"]
    value := bytes + 0.0
    unitIndex := 1
    while value >= 1024 && unitIndex < units.Length {
        value /= 1024
        unitIndex += 1
    }
    if unitIndex = 1
        number := Format("{:.0f}", value)
    else {
        number := Format("{:.1f}", value)
        number := RegExReplace(number, "\.0$")
    }
    return number units[unitIndex]
}

BuildWindowsParameterString(args) {
    quoted := []
    for arg in args
        quoted.Push(QuoteWindowsArgument(arg))
    return JoinArray(quoted, " ")
}

ParseWindowsCommandLineForSelfTest(commandLine) {
    count := 0
    argv := DllCall("shell32\CommandLineToArgvW",
        "wstr", commandLine, "int*", &count, "ptr")
    if !argv
        throw Error("CommandLineToArgvW 自检调用失败")
    result := []
    try {
        Loop count
            result.Push(StrGet(NumGet(argv, (A_Index - 1) * A_PtrSize, "ptr")))
    } finally {
        DllCall("kernel32\LocalFree", "ptr", argv)
    }
    return result
}

FindOpenAppById(id) {
    global OpenApps
    for app in OpenApps {
        if StrLower(app.Id) = StrLower(id)
            return app
    }
    return 0
}

FindOpenAppByPath(path) {
    global OpenApps
    for app in OpenApps {
        if PathsEqual(app.Path, path)
            return app
    }
    return 0
}

OpenWithConfiguredApp(appId, filePath, *) {
    app := FindOpenAppById(appId)
    if !IsObject(app)
        return
    if !IsExistingExecutable(app.Path) {
        HandleMissingOpenApp(app)
        return
    }
    if !ShellLaunchExecutable(app.Path, filePath) {
        ShowPanelMsgBox("无法使用 " app.Name " 打开文件。",
            "打开失败", "Iconx")
        return
    }
    SetUserStatus("已用 " app.Name " 打开")
}

AddConfiguredOpenApp(*) {
    global LastOpenProgramDir, OpenApps
    initialDir := DirExist(LastOpenProgramDir)
        ? LastOpenProgramDir : GetProgramFilesDirectory()
    selected := SelectPanelFile("3", initialDir,
        "添加用于打开文件的软件", "应用程序 (*.exe)")
    if selected = ""
        return
    selected := NormalizePath(selected)
    if !IsExistingExecutable(selected) {
        ShowPanelMsgBox("v0.7 仅支持选择现有的 .exe 应用程序。",
            "添加软件", "Icon!")
        return
    }
    existing := FindOpenAppByPath(selected)
    if IsObject(existing) {
        SetUserStatus(existing.Name " 已在软件列表中")
        return
    }
    app := {
        Id: NewOpenAppId(selected),
        Path: selected,
        Name: GetExecutableDisplayName(selected),
        Icon: selected,
        Extensions: [],
        Enabled: true,
        ShowInOpenMenu: true,
        Actions: []
    }
    OpenApps.Push(app)
    SplitPath(selected, , &LastOpenProgramDir)
    try {
        SaveOpenApps()
        SetUserStatus("已添加 " app.Name "；扩展名留空，适用于所有普通文件")
        OpenConfigFile()
    } catch as err {
        OpenApps.Pop()
        ShowPanelMsgBox("无法保存软件配置：`n" err.Message,
            "添加软件失败", "Iconx")
    }
}

ChooseOtherProgramForFile(filePath, *) {
    global LastOpenProgramDir, OpenApps, LastOpenAppUndoState
    extensionType := GetFileExtensionType(filePath)
    extensionLabel := extensionType = "<none>" ? "无扩展名" : extensionType
    initialDir := DirExist(LastOpenProgramDir)
        ? LastOpenProgramDir : GetProgramFilesDirectory()

    selected := SelectPanelFile("3", initialDir,
        "选择用于打开 " extensionLabel " 文件的程序", "应用程序 (*.exe)")
    if selected = ""
        return
    selected := NormalizePath(selected)
    if !IsExistingExecutable(selected) {
        ShowPanelMsgBox("v0.7 仅支持选择现有的 .exe 应用程序。",
            "无法添加程序", "Icon!")
        return
    }
    if !ShellLaunchExecutable(selected, filePath) {
        ShowPanelMsgBox("无法使用该程序打开文件，未保存到软件列表",
            "打开失败", "Iconx")
        return
    }

    previousState := CloneOpenApps(OpenApps)
    app := FindOpenAppByPath(selected)
    changed := false
    if !IsObject(app) {
        app := {
            Id: NewOpenAppId(selected),
            Path: selected,
            Name: GetExecutableDisplayName(selected),
            Icon: selected,
            Extensions: [extensionType],
            Enabled: true,
            ShowInOpenMenu: true,
            Actions: []
        }
        OpenApps.Push(app)
        changed := true
    } else if app.Extensions.Length {
        if !ArrayContainsTextInsensitive(app.Extensions, extensionType) {
            app.Extensions.Push(extensionType)
            changed := true
        }
    }
    SplitPath(selected, , &selectedDir)
    LastOpenProgramDir := NormalizePath(selectedDir)
    if changed {
        try SaveOpenApps()
        catch as err {
            OpenApps := previousState
            ShowPanelMsgBox("程序已启动，但无法安全保存软件列表：`n"
                err.Message, "配置保存失败", "Iconx")
            return
        }
        LastOpenAppUndoState := previousState
        SetOpenAppUndoStatus("已用 " app.Name " 打开，并添加为 " extensionLabel
            " 文件的可用程序    撤销")
    } else {
        try SaveOpenApps()
        SetUserStatus("已用 " app.Name " 打开")
    }
}

HandleMissingOpenApp(app) {
    answer := ShowPanelMsgBox("找不到 " app.Name
        "`n`n“是”：重新选择程序`n“否”：从软件列表移除",
        "程序不可用", "YesNoCancel Icon!")
    if answer = "Yes"
        ReselectMissingOpenApp(app)
    else if answer = "No"
        RemoveOpenAppById(app.Id)
}

ReselectMissingOpenApp(app) {
    global LastOpenProgramDir
    initialDir := DirExist(LastOpenProgramDir)
        ? LastOpenProgramDir : GetProgramFilesDirectory()
    selected := SelectPanelFile("3", initialDir,
        "重新选择 " app.Name, "应用程序 (*.exe)")
    if selected = ""
        return
    selected := NormalizePath(selected)
    if !IsExistingExecutable(selected) {
        ShowPanelMsgBox("请选择现有的 .exe 应用程序。",
            "重新选择程序", "Icon!")
        return
    }
    duplicate := FindOpenAppByPath(selected)
    if IsObject(duplicate) && StrLower(duplicate.Id) != StrLower(app.Id) {
        if !app.Extensions.Length
            duplicate.Extensions := []
        else {
            for extension in app.Extensions {
                if duplicate.Extensions.Length
                    && !ArrayContainsTextInsensitive(duplicate.Extensions, extension)
                    duplicate.Extensions.Push(extension)
            }
        }
        if app.ShowInOpenMenu
            duplicate.ShowInOpenMenu := true
        for sourceAction in app.Actions {
            copiedAction := CloneOpenAppAction(sourceAction)
            if IsObject(FindOpenAppActionById(
                duplicate, copiedAction.Id))
                copiedAction.Id := NewOpenAppActionIdForActions(
                    duplicate.Actions, copiedAction.Id)
            duplicate.Actions.Push(copiedAction)
        }
        RemoveOpenAppById(app.Id, false)
    } else {
        app.Path := selected
        app.Icon := selected
        if app.Name = ""
            app.Name := GetExecutableDisplayName(selected)
    }
    SplitPath(selected, , &LastOpenProgramDir)
    SaveOpenApps()
    SetUserStatus("已更新 " app.Name " 的程序路径")
}

NewOpenAppActionIdForActions(actions, seed) {
    base := StrLower(Trim(seed))
    base := RegExReplace(base, "[^a-z0-9_-]+", "-")
    base := Trim(base, "-_")
    if base = ""
        base := "action"
    candidate := base
    suffix := 2
    Loop {
        found := false
        for action in actions {
            if StrLower(action.Id) = StrLower(candidate) {
                found := true
                break
            }
        }
        if !found
            return candidate
        candidate := base "-" suffix++
    }
}

RemoveOpenAppById(id, save := true) {
    global OpenApps
    for index, app in OpenApps {
        if StrLower(app.Id) = StrLower(id) {
            OpenApps.RemoveAt(index)
            if save
                SaveOpenApps()
            SetUserStatus("已从软件列表移除 " app.Name)
            return true
        }
    }
    return false
}

CloneOpenApps(apps) {
    result := []
    for app in apps {
        actions := []
        for action in app.Actions
            actions.Push(CloneOpenAppAction(action))
        result.Push({
            Id: app.Id, Path: app.Path, Name: app.Name, Icon: app.Icon,
            Extensions: app.Extensions.Clone(), Enabled: app.Enabled,
            ShowInOpenMenu: app.ShowInOpenMenu, Actions: actions
        })
    }
    return result
}

ArrayContainsTextInsensitive(values, target) {
    for value in values {
        if StrLower(value) = StrLower(target)
            return true
    }
    return false
}

HandleStatusAction(*) {
    global LastOpenAppUndoState, OpenApps, CurrentStatusAction
    if IsObject(CurrentStatusAction) {
        action := CurrentStatusAction
        CurrentStatusAction := 0
        action.Call()
        return
    }
    if !IsObject(LastOpenAppUndoState)
        return
    OpenApps := CloneOpenApps(LastOpenAppUndoState)
    LastOpenAppUndoState := 0
    try {
        SaveOpenApps()
        SetUserStatus("已撤销软件列表更改")
    } catch as err {
        ShowPanelMsgBox("无法撤销软件列表更改：`n" err.Message,
            "撤销失败", "Iconx")
    }
}

SetOpenAppUndoStatus(text) {
    global StatusText, StatusKind, CurrentStatusAction
    CurrentStatusAction := 0
    if IsObject(StatusText) {
        StatusKind := "user"
        StatusText.Text := text
    }
}

GetProgramFilesDirectory() {
    path := EnvGet("ProgramFiles")
    return DirExist(path) ? path : "C:\Program Files"
}

NewOpenAppId(executablePath) {
    global OpenApps
    return NewOpenAppIdForApps(executablePath, OpenApps)
}

NewOpenAppIdForApps(executablePath, apps, reservedIds := 0) {
    base := OpenAppIdBase(executablePath)
    candidate := base
    suffix := 2
    while (OpenAppArrayHasId(apps, candidate)
        || (IsObject(reservedIds) && reservedIds.Has(StrLower(candidate)))) {
        candidate := base "-" suffix
        suffix += 1
    }
    return candidate
}

OpenAppArrayHasId(apps, id) {
    for app in apps {
        if StrLower(app.Id) = StrLower(id)
            return true
    }
    return false
}

OpenAppIdBase(executablePath) {
    SplitPath(executablePath, , , , &nameNoExt)
    base := StrLower(Trim(nameNoExt))
    base := RegExReplace(base, "[^a-z0-9_-]+", "-")
    base := Trim(base, "-_")
    return base != "" ? base : "app"
}

GetExecutableDisplayName(path) {
    name := GetExecutableProductName(path)
    if name != ""
        return name
    SplitPath(path, &fileName, , , &nameNoExt)
    return nameNoExt != "" ? nameNoExt : fileName
}

GetExecutableProductName(path) {
    ignored := 0
    size := DllCall("version\GetFileVersionInfoSizeW", "wstr", path,
        "uint*", &ignored, "uint")
    if !size
        return ""
    data := Buffer(size, 0)
    if !DllCall("version\GetFileVersionInfoW", "wstr", path,
        "uint", 0, "uint", size, "ptr", data.Ptr, "int")
        return ""
    translation := 0
    translationLength := 0
    queries := []
    if DllCall("version\VerQueryValueW", "ptr", data.Ptr,
        "wstr", "\VarFileInfo\Translation", "ptr*", &translation,
        "uint*", &translationLength, "int") && translationLength >= 4 {
        language := NumGet(translation, 0, "ushort")
        codePage := NumGet(translation, 2, "ushort")
        queries.Push(Format("\StringFileInfo\{:04X}{:04X}\ProductName",
            language, codePage))
    }
    queries.Push("\StringFileInfo\040904B0\ProductName")
    for query in queries {
        valuePtr := 0
        valueLength := 0
        if DllCall("version\VerQueryValueW", "ptr", data.Ptr,
            "wstr", query, "ptr*", &valuePtr, "uint*", &valueLength, "int")
            && valuePtr && valueLength {
            value := Trim(StrGet(valuePtr))
            if value != ""
                return value
        }
    }
    return ""
}

ShellLaunchExecutable(executablePath, targetPath) {
    return ShellLaunchExecutableWithArgs(
        executablePath, [NormalizePath(targetPath)], "")
}

ShellLaunchExecutableWithArgs(executablePath, args, workingDirectory := "") {
    launched := ShellLaunchExecutableWithProcess(
        executablePath, args, workingDirectory)
    if launched.ProcessHandle
        DllCall("kernel32\CloseHandle", "ptr", launched.ProcessHandle)
    return launched.Success
}

ShellLaunchExecutableWithProcess(executablePath, args,
    workingDirectory := ""
) {
    global Panel
    executablePath := NormalizePath(executablePath)
    if !IsExistingExecutable(executablePath)
        return {Success: false, ProcessHandle: 0}
    parameters := BuildWindowsParameterString(args)
    workingDirectory := workingDirectory = ""
        ? "" : NormalizePath(workingDirectory)
    infoSize := A_PtrSize = 8 ? 112 : 60
    info := Buffer(infoSize, 0)
    NumPut("uint", infoSize, info, 0)
    NumPut("uint", 0x440, info, 4) ; SEE_MASK_NOCLOSEPROCESS | FLAG_NO_UI
    NumPut("ptr", IsObject(Panel) ? Panel.Hwnd : 0, info, 8)
    NumPut("ptr", StrPtr(executablePath), info, A_PtrSize = 8 ? 24 : 16)
    NumPut("ptr", StrPtr(parameters), info, A_PtrSize = 8 ? 32 : 20)
    if workingDirectory != ""
        NumPut("ptr", StrPtr(workingDirectory), info,
            A_PtrSize = 8 ? 40 : 24)
    NumPut("int", 1, info, A_PtrSize = 8 ? 48 : 28)
    if !DllCall("shell32\ShellExecuteExW", "ptr", info.Ptr, "int")
        return {Success: false, ProcessHandle: 0}
    processHandle := NumGet(info, A_PtrSize = 8 ? 104 : 56, "ptr")
    return {Success: true, ProcessHandle: processHandle}
}

ExecuteOpenAppAction(appId, actionId, paths, clickedPath, *) {
    global ACTION_EXECUTION_PER_ITEM
    app := FindOpenAppById(appId)
    if !IsObject(app)
        return
    action := FindOpenAppActionById(app, actionId)
    if !IsObject(action)
        return
    paths := paths.Clone()
    rendered := RenderOpenAppAction(app, action, paths, clickedPath)
    if !rendered.Valid {
        if InStr(rendered.Error, "找不到执行程序")
            HandleMissingOpenAppActionExecutable(app, action)
        else
            ShowPanelMsgBox("无法执行“" action.Name "”：`n"
                rendered.Error, app.Name " · 动作失败", "Iconx")
        return
    }
    if action.Confirm {
        hasFolder := false
        for path in paths {
            if InStr(FileExist(path), "D") {
                hasFolder := true
                break
            }
        }
        message := "动作：" action.Name
            . "`n应用：" app.Name
            . "`n所选项目：" paths.Length " 个"
            . "`n包含文件夹：" (hasFolder ? "是" : "否")
            . "`n执行模式："
            . (action.ExecutionMode = ACTION_EXECUTION_PER_ITEM
                ? "逐个项目串行执行" : "一次传入全部项目")
            . "`n`n要继续启动吗？"
        if ShowPanelMsgBox(message, "确认工具动作",
            "YesNo Icon?") != "Yes"
            return
    }
    if action.ExecutionMode = ACTION_EXECUTION_PER_ITEM {
        StartOpenAppActionSerialTask(app, action, rendered.Commands)
        return
    }
    command := rendered.Commands[1]
    if !ShellLaunchExecutableWithArgs(
        command.Executable, command.Args, command.WorkingDirectory) {
        ShowPanelMsgBox("Windows 未能启动工具动作。`n`n应用："
            app.Name "`n动作：" action.Name "`n程序："
            command.Executable, "动作启动失败", "Iconx")
        return
    }
    SetUserStatus("已启动：" action.Name)
}

StartOpenAppActionSerialTask(app, action, commands) {
    global OpenAppActionSerialTasks, NextOpenAppActionSerialTaskId
    NextOpenAppActionSerialTaskId += 1
    taskId := NextOpenAppActionSerialTaskId
    task := {
        Id: taskId,
        AppName: app.Name,
        ActionName: action.Name,
        Commands: commands,
        NextIndex: 1,
        ProcessHandle: 0,
        NextCallback: 0,
        PollCallback: 0
    }
    task.NextCallback := RunNextOpenAppActionSerialItem.Bind(task)
    task.PollCallback := PollOpenAppActionSerialProcess.Bind(task)
    OpenAppActionSerialTasks[taskId] := task
    SetUserStatus("已加入串行队列：" action.Name
        "（" commands.Length " 个项目）")
    SetTimer(task.NextCallback, -1)
}

RunNextOpenAppActionSerialItem(task, *) {
    global OpenAppActionSerialTasks
    if !OpenAppActionSerialTasks.Has(task.Id)
        return
    if task.NextIndex > task.Commands.Length {
        FinishOpenAppActionSerialTask(task)
        return
    }
    command := task.Commands[task.NextIndex]
    if !FileExist(command.ItemPath) {
        FailOpenAppActionSerialTask(task, "第 " task.NextIndex
            " 个项目已不存在：`n" command.ItemPath)
        return
    }
    launched := ShellLaunchExecutableWithProcess(
        command.Executable, command.Args, command.WorkingDirectory)
    if !launched.Success {
        FailOpenAppActionSerialTask(task, "Windows 未能启动第 "
            task.NextIndex " 个项目。`n程序：" command.Executable)
        return
    }
    if !launched.ProcessHandle {
        FailOpenAppActionSerialTask(task,
            "Windows 已接受启动请求，但没有返回可等待的进程句柄，"
            "无法保证后续项目真正串行执行。")
        return
    }
    task.ProcessHandle := launched.ProcessHandle
    SetUserStatus("正在执行：" task.ActionName "（"
        task.NextIndex "/" task.Commands.Length "）")
    SetTimer(task.PollCallback, 250)
}

PollOpenAppActionSerialProcess(task, *) {
    global OpenAppActionSerialTasks
    if !OpenAppActionSerialTasks.Has(task.Id)
        return
    waitResult := DllCall("kernel32\WaitForSingleObject",
        "ptr", task.ProcessHandle, "uint", 0, "uint")
    if waitResult = 258
        return
    SetTimer(task.PollCallback, 0)
    if task.ProcessHandle {
        DllCall("kernel32\CloseHandle", "ptr", task.ProcessHandle)
        task.ProcessHandle := 0
    }
    if waitResult = 0xFFFFFFFF {
        FailOpenAppActionSerialTask(task,
            "等待外部程序结束时发生 Windows 错误。")
        return
    }
    task.NextIndex += 1
    SetTimer(task.NextCallback, -1)
}

FinishOpenAppActionSerialTask(task) {
    global OpenAppActionSerialTasks
    SetTimer(task.PollCallback, 0)
    if task.ProcessHandle {
        DllCall("kernel32\CloseHandle", "ptr", task.ProcessHandle)
        task.ProcessHandle := 0
    }
    if OpenAppActionSerialTasks.Has(task.Id)
        OpenAppActionSerialTasks.Delete(task.Id)
    SetUserStatus("串行启动队列已结束：" task.ActionName)
}

FailOpenAppActionSerialTask(task, reason) {
    global OpenAppActionSerialTasks
    SetTimer(task.PollCallback, 0)
    if task.ProcessHandle {
        DllCall("kernel32\CloseHandle", "ptr", task.ProcessHandle)
        task.ProcessHandle := 0
    }
    if OpenAppActionSerialTasks.Has(task.Id)
        OpenAppActionSerialTasks.Delete(task.Id)
    ShowPanelMsgBox("无法继续执行“" task.ActionName "”：`n"
        reason "`n`n应用：" task.AppName,
        task.AppName " · 串行动作失败", "Iconx")
}

FindOpenAppActionById(app, id) {
    for action in app.Actions {
        if StrLower(action.Id) = StrLower(id)
            return action
    }
    return 0
}

HandleMissingOpenAppActionExecutable(app, action) {
    if action.Executable = "" {
        HandleMissingOpenApp(app)
        return
    }
    answer := ShowPanelMsgBox("找不到动作“" action.Name
        "”的执行程序：`n" action.Executable
        "`n`n是否立即重新选择 .exe？",
        app.Name " · 程序不可用", "YesNo Icon!")
    if answer != "Yes"
        return
    selected := SelectPanelFile("3", GetParentPath(action.Executable),
        "重新选择 " action.Name " 的执行程序", "应用程序 (*.exe)")
    if selected = ""
        return
    selected := NormalizePath(selected)
    if !IsExistingExecutable(selected) {
        ShowPanelMsgBox("请选择现有的 .exe 应用程序。",
            "重新选择程序", "Icon!")
        return
    }
    previous := action.Executable
    action.Executable := selected
    try {
        SaveOpenApps()
        SetUserStatus("已更新动作“" action.Name "”的执行程序")
    } catch as err {
        action.Executable := previous
        ShowPanelMsgBox("无法保存新的执行程序：`n" err.Message,
            "配置保存失败", "Iconx")
    }
}

IsExecutablePath(path) {
    SplitPath(path, , , &extension)
    return StrLower(extension) = "exe"
}

IsExistingExecutable(path) {
    path := NormalizePath(path)
    attributes := FileExist(path)
    return path != "" && attributes != "" && !InStr(attributes, "D")
        && IsExecutablePath(path)
}

QuoteWindowsArgument(value) {
    ; Keep simple arguments unquoted. This remains CommandLineToArgvW
    ; compatible and also supports programs such as dopusrt.exe which inspect
    ; raw command-line switches instead of relying on the CRT argv parser.
    ; Empty values and values containing a delimiter or quote still use the
    ; standard backslash/double-quote escaping rules.
    value := value ""
    if value != "" && !InStr(value, " ") && !InStr(value, "`t")
        && !InStr(value, '"')
        return value
    result := '"'
    backslashes := 0
    for char in StrSplit(value) {
        if char = "\" {
            backslashes += 1
            continue
        }
        if char = '"' {
            result .= RepeatText("\", backslashes * 2 + 1) '"'
            backslashes := 0
            continue
        }
        result .= RepeatText("\", backslashes) char
        backslashes := 0
    }
    result .= RepeatText("\", backslashes * 2) '"'
    return result
}

RepeatText(text, count) {
    result := ""
    Loop count
        result .= text
    return result
}

SaveOpenApps() {
    AtomicConfigEdit(WriteOpenAppsConfig)
}

WriteOpenAppsConfig(tempPath) {
    global OpenApps, LastOpenProgramDir, CONFIG_VERSION
    doc := OpenPopDropConfig(tempPath)
    WriteOpenAppsToDocument(doc, OpenApps)
    doc.SetValue("General", "LastOpenProgramDir", LastOpenProgramDir, 1)
    doc.SetValue("General", "ConfigVersion", CONFIG_VERSION, 1)
    doc.Save()
}

WriteOpenAppsToDocument(doc, apps) {
    activeIds := Map()
    for app in apps
        activeIds[StrLower(app.Id)] := true
    oldIds := ParseOpenAppOrder(doc.GetValue("OpenApps", "Order", ""))
    for entry in doc.GetEntries("OpenApps") {
        if RegExMatch(entry.Key, "i)^App\d+$")
            && !ArrayContainsTextInsensitive(oldIds, entry.Value)
            oldIds.Push(entry.Value)
    }
    for id in oldIds {
        if !activeIds.Has(StrLower(id)) {
            doc.DeleteSection("OpenApp:" id)
            DeleteOpenAppActionSections(doc, id)
        }
    }
    ids := []
    for app in apps {
        ids.Push(app.Id)
    }
    doc.ReplaceSection("OpenApps",
        [{Key: "Order", Value: JoinArray(ids, ",")}], 4)

    for app in apps {
        section := "OpenApp:" app.Id
        oldActionIds := ParseOpenAppActionOrder(
            doc.GetValue(section, "ActionOrder", ""))
        activeActionIds := Map()
        for action in app.Actions
            activeActionIds[StrLower(action.Id)] := true
        for oldActionId in oldActionIds {
            if !activeActionIds.Has(StrLower(oldActionId))
                doc.DeleteSection(
                    "OpenAppAction:" app.Id ":" oldActionId)
        }
        entries := [{Key: "Path", Value: app.Path}]
        if app.Name != GetExecutableDisplayName(app.Path)
            entries.Push({Key: "Name", Value: app.Name})
        if !PathsEqual(app.Icon, app.Path)
            entries.Push({Key: "Icon", Value: app.Icon})
        if app.Extensions.Length
            entries.Push({Key: "Extensions",
                Value: JoinArray(app.Extensions, ",")})
        if !app.Enabled
            entries.Push({Key: "Enabled", Value: "0"})
        if !app.ShowInOpenMenu
            entries.Push({Key: "ShowInOpenMenu", Value: "0"})
        if app.Actions.Length {
            actionIds := []
            for action in app.Actions
                actionIds.Push(action.Id)
            entries.Push({Key: "ActionOrder",
                Value: JoinArray(actionIds, ",")})
        }
        doc.ReplaceKnownKeys(section, entries,
            ["Path", "Name", "Icon", "Extensions", "Enabled",
             "ShowInOpenMenu", "ActionOrder"], 4)
        for action in app.Actions
            WriteOpenAppActionToDocument(doc, app, action)
    }
}

DeleteOpenAppActionSections(doc, appId) {
    prefix := StrLower("OpenAppAction:" appId ":")
    for sectionName in doc.GetSectionNames() {
        if SubStr(StrLower(sectionName), 1, StrLen(prefix)) = prefix
            doc.DeleteSection(sectionName)
    }
}

WriteOpenAppActionToDocument(doc, app, action) {
    section := "OpenAppAction:" app.Id ":" action.Id
    entries := [
        {Key: "Name", Value: action.Name},
        {Key: "Executable", Value: action.Executable},
        {Key: "TargetTypes", Value: action.TargetTypes},
        {Key: "ExecutionMode", Value: action.ExecutionMode},
        {Key: "Extensions", Value: JoinArray(action.Extensions, ",")},
        {Key: "RequireCommonFolder",
            Value: action.RequireCommonFolder ? "1" : "0"},
        {Key: "WorkingDirectoryMode",
            Value: action.WorkingDirectoryMode},
        {Key: "WorkingDirectory", Value: action.WorkingDirectory},
        {Key: "Confirm", Value: action.Confirm ? "1" : "0"},
        {Key: "Enabled", Value: action.Enabled ? "1" : "0"},
        {Key: "ArgCount", Value: action.Args.Length}
    ]
    known := ["Name", "Executable", "TargetTypes",
        "ExecutionMode", "SelectionMode", "Extensions",
        "RequireCommonFolder", "RequireCommonParent",
        "WorkingDirectoryMode", "WorkingDirectory", "Confirm",
        "Enabled", "ArgCount"]
    for oldEntry in doc.GetEntries(section) {
        if RegExMatch(oldEntry.Key, "i)^Arg\d{3}$")
            && !ValueInArray(oldEntry.Key, known)
            known.Push(oldEntry.Key)
    }
    for index, arg in action.Args {
        key := "Arg" Format("{:03}", index)
        entries.Push({Key: key, Value: arg})
        if !ValueInArray(key, known)
            known.Push(key)
    }
    doc.ReplaceKnownKeys(section, entries, known, 4)
}
