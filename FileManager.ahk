; File-manager routing for folder navigation and item reveal operations.
; External programs are invoked through ShellExecuteExW with an argv array.
; No adapter builds a cmd.exe command line or relies on UI automation.

ParseFileManagerProvider(raw) {
    global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_DIRECTORY_OPUS
    global FILE_MANAGER_TOTAL_COMMANDER, FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    raw := StrLower(Trim(raw))
    if raw = StrLower(FILE_MANAGER_DIRECTORY_OPUS)
        return FILE_MANAGER_DIRECTORY_OPUS
    if raw = StrLower(FILE_MANAGER_TOTAL_COMMANDER)
        return FILE_MANAGER_TOTAL_COMMANDER
    if raw = StrLower(FILE_MANAGER_XYPLORER)
        return FILE_MANAGER_XYPLORER
    if raw = StrLower(FILE_MANAGER_DOUBLE_COMMANDER)
        return FILE_MANAGER_DOUBLE_COMMANDER
    if raw = StrLower(FILE_MANAGER_FILES)
        return FILE_MANAGER_FILES
    if raw = StrLower(FILE_MANAGER_FREE_COMMANDER)
        return FILE_MANAGER_FREE_COMMANDER
    return FILE_MANAGER_WINDOWS_SHELL
}

IsRecognizedFileManagerProvider(raw) {
    global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_DIRECTORY_OPUS
    global FILE_MANAGER_TOTAL_COMMANDER, FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    raw := StrLower(Trim(raw))
    return raw = StrLower(FILE_MANAGER_WINDOWS_SHELL)
        || raw = StrLower(FILE_MANAGER_DIRECTORY_OPUS)
        || raw = StrLower(FILE_MANAGER_TOTAL_COMMANDER)
        || raw = StrLower(FILE_MANAGER_XYPLORER)
        || raw = StrLower(FILE_MANAGER_DOUBLE_COMMANDER)
        || raw = StrLower(FILE_MANAGER_FILES)
        || raw = StrLower(FILE_MANAGER_FREE_COMMANDER)
}

FileManagerProviderDisplayName(provider) {
    global FILE_MANAGER_DIRECTORY_OPUS, FILE_MANAGER_TOTAL_COMMANDER
    global FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    provider := ParseFileManagerProvider(provider)
    if provider = FILE_MANAGER_DIRECTORY_OPUS
        return "Directory Opus"
    if provider = FILE_MANAGER_TOTAL_COMMANDER
        return "Total Commander"
    if provider = FILE_MANAGER_XYPLORER
        return "XYplorer"
    if provider = FILE_MANAGER_DOUBLE_COMMANDER
        return "Double Commander"
    if provider = FILE_MANAGER_FILES
        return "Files"
    if provider = FILE_MANAGER_FREE_COMMANDER
        return "FreeCommander XE"
    return "Windows 系统文件管理器"
}

GetCurrentFileManagerSettings() {
    global FileManagerProvider, FileManagerExecutable
    return {
        Provider: ParseFileManagerProvider(FileManagerProvider),
        Executable: Trim(FileManagerExecutable)
    }
}

ResolveFileManagerSettings(settings := 0) {
    if !IsObject(settings)
        return GetCurrentFileManagerSettings()
    provider := HasProp(settings, "Provider")
        ? ParseFileManagerProvider(settings.Provider) : ""
    if provider = ""
        provider := ParseFileManagerProvider("")
    executable := HasProp(settings, "Executable")
        ? Trim(settings.Executable) : ""
    return {Provider: provider, Executable: executable}
}

FileManagerOperationSucceeded() {
    return {Success: true, Kind: "", Message: "", Provider: "", Path: ""}
}

FileManagerOperationFailed(kind, message, provider := "", path := "") {
    return {
        Success: false,
        Kind: kind,
        Message: message,
        Provider: provider,
        Path: path
    }
}

class FileManagerRouter {
    static OpenFolder(folderPath, settings := 0) {
        global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_DIRECTORY_OPUS
        global FILE_MANAGER_TOTAL_COMMANDER, FILE_MANAGER_XYPLORER
        global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
        global FILE_MANAGER_FREE_COMMANDER
        folderPath := NormalizePath(folderPath)
        if !DirExist(folderPath)
            return FileManagerOperationFailed(
                "TargetMissing",
                "文件夹不存在或当前无法访问：`n" folderPath,
                "", folderPath)

        resolved := ResolveFileManagerSettings(settings)
        switch resolved.Provider {
            case FILE_MANAGER_DIRECTORY_OPUS:
                return DirectoryOpusFileManagerAdapter.OpenFolder(
                    folderPath, resolved)
            case FILE_MANAGER_TOTAL_COMMANDER:
                return TotalCommanderFileManagerAdapter.OpenFolder(
                    folderPath, resolved)
            case FILE_MANAGER_XYPLORER:
                return XYplorerFileManagerAdapter.OpenFolder(
                    folderPath, resolved)
            case FILE_MANAGER_DOUBLE_COMMANDER:
                return DoubleCommanderFileManagerAdapter.OpenFolder(
                    folderPath, resolved)
            case FILE_MANAGER_FILES:
                return FilesFileManagerAdapter.OpenFolder(
                    folderPath, resolved)
            case FILE_MANAGER_FREE_COMMANDER:
                return FreeCommanderFileManagerAdapter.OpenFolder(
                    folderPath, resolved)
            default:
                return WindowsShellFileManagerAdapter.OpenFolder(
                    folderPath, resolved)
        }
    }

    static RevealItems(itemPaths, settings := 0) {
        global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_DIRECTORY_OPUS
        global FILE_MANAGER_TOTAL_COMMANDER, FILE_MANAGER_XYPLORER
        global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
        global FILE_MANAGER_FREE_COMMANDER
        paths := UniqueExistingFileManagerItems(itemPaths, &missingPath)
        if missingPath != ""
            return FileManagerOperationFailed(
                "TargetMissing",
                "项目不存在或当前无法访问：`n" missingPath,
                "", missingPath)
        if !paths.Length
            return FileManagerOperationFailed(
                "TargetMissing", "没有可定位的文件或文件夹。")

        resolved := ResolveFileManagerSettings(settings)
        switch resolved.Provider {
            case FILE_MANAGER_DIRECTORY_OPUS:
                return DirectoryOpusFileManagerAdapter.RevealItems(
                    paths, resolved)
            case FILE_MANAGER_TOTAL_COMMANDER:
                return TotalCommanderFileManagerAdapter.RevealItems(
                    paths, resolved)
            case FILE_MANAGER_XYPLORER:
                return XYplorerFileManagerAdapter.RevealItems(
                    paths, resolved)
            case FILE_MANAGER_DOUBLE_COMMANDER:
                return DoubleCommanderFileManagerAdapter.RevealItems(
                    paths, resolved)
            case FILE_MANAGER_FILES:
                return FilesFileManagerAdapter.RevealItems(
                    paths, resolved)
            case FILE_MANAGER_FREE_COMMANDER:
                return FreeCommanderFileManagerAdapter.RevealItems(
                    paths, resolved)
            default:
                return WindowsShellFileManagerAdapter.RevealItems(
                    paths, resolved)
        }
    }
}

class WindowsShellFileManagerAdapter {
    static OpenFolder(folderPath, settings) {
        try {
            ; Intentionally preserve PopDrop's original system behavior. Run
            ; delegates folder activation to Windows and therefore also keeps
            ; system-level Explorer Replacement integrations working.
            Run(folderPath)
            return FileManagerOperationSucceeded()
        } catch as err {
            return FileManagerOperationFailed(
                "LaunchFailed",
                "无法使用 Windows 系统方式打开文件夹：`n"
                    . folderPath "`n`n" err.Message,
                settings.Provider, folderPath)
        }
    }

    static RevealItems(paths, settings) {
        if !CanWindowsShellRevealTogether(paths)
            return FileManagerOperationFailed(
                "SelectionLayout",
                "只能同时定位位于同一文件所在文件夹中的项目；"
                    . "请缩小选择范围后重试。",
                settings.Provider)

        parentPath := GetParentPath(paths[1])
        parentPidl := 0
        fullPidls := []
        try {
            if DllCall("shell32\SHParseDisplayName", "wstr", parentPath,
                "ptr", 0, "ptr*", &parentPidl, "uint", 0, "ptr", 0) != 0
                throw Error("Windows Shell 无法解析文件所在文件夹。")
            childArray := Buffer(paths.Length * A_PtrSize, 0)
            for index, path in paths {
                fullPidl := 0
                if DllCall("shell32\SHParseDisplayName", "wstr", path,
                    "ptr", 0, "ptr*", &fullPidl, "uint", 0, "ptr", 0) != 0
                    throw Error("Windows Shell 无法解析所选项目。")
                fullPidls.Push(fullPidl)
                childPidl := DllCall(
                    "shell32\ILFindLastID", "ptr", fullPidl, "ptr")
                NumPut("ptr", childPidl, childArray,
                    (index - 1) * A_PtrSize)
            }
            hr := DllCall(
                "shell32\SHOpenFolderAndSelectItems",
                "ptr", parentPidl, "uint", paths.Length,
                "ptr", childArray.Ptr, "uint", 0, "int")
            if hr != 0
                throw Error("Windows Shell 未接受定位请求（HRESULT "
                    . Format("0x{:08X}", hr & 0xFFFFFFFF) "）。")
            return FileManagerOperationSucceeded()
        } catch as err {
            return FileManagerOperationFailed(
                "LaunchFailed",
                "无法在文件管理器中显示所选项目：`n" err.Message,
                settings.Provider, parentPath)
        } finally {
            for pidl in fullPidls
                DllCall("ole32\CoTaskMemFree", "ptr", pidl)
            if parentPidl
                DllCall("ole32\CoTaskMemFree", "ptr", parentPidl)
        }
    }
}

class DirectoryOpusFileManagerAdapter {
    static OpenFolder(folderPath, settings) {
        executable := ResolveDirectoryOpusRuntimePath(settings.Executable)
        validation := ValidateFileManagerExecutable(
            settings.Provider, executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, executable)
        args := BuildDirectoryOpusOpenFolderArgs(folderPath)
        return LaunchThirdPartyFileManager(
            settings.Provider, validation.Path, args, folderPath)
    }

    static RevealItems(paths, settings) {
        executable := ResolveDirectoryOpusRuntimePath(settings.Executable)
        validation := ValidateFileManagerExecutable(
            settings.Provider, executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, executable)
        if paths.Length = 1 {
            args := BuildDirectoryOpusRevealItemArgs(paths[1])
            return LaunchThirdPartyFileManager(
                settings.Provider, validation.Path, args, paths[1])
        }
        return OpenUniqueContainingFoldersWithAdapter(
            paths, DirectoryOpusFileManagerAdapter, {
                Provider: settings.Provider,
                Executable: validation.Path
            })
    }
}

class TotalCommanderFileManagerAdapter {
    static OpenFolder(folderPath, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        args := BuildTotalCommanderOpenFolderArgs(folderPath)
        return LaunchThirdPartyFileManager(
            settings.Provider, validation.Path, args, folderPath)
    }

    static RevealItems(paths, settings) {
        ; Total Commander's documented command line cannot reliably select an
        ; arbitrary ordinary file. Reveal therefore opens each distinct file
        ; containing folder once, without UI automation or warning dialogs.
        return OpenUniqueContainingFoldersWithAdapter(
            paths, TotalCommanderFileManagerAdapter, settings)
    }
}

class XYplorerFileManagerAdapter {
    static OpenFolder(folderPath, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        args := BuildXYplorerOpenFolderArgs(folderPath)
        return LaunchThirdPartyFileManager(
            settings.Provider, validation.Path, args, folderPath)
    }

    static RevealItems(paths, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        if paths.Length = 1 {
            args := BuildXYplorerRevealItemArgs(paths[1])
            return LaunchThirdPartyFileManager(
                settings.Provider, validation.Path, args, paths[1])
        }
        return OpenUniqueContainingFoldersWithAdapter(
            paths, XYplorerFileManagerAdapter, {
                Provider: settings.Provider,
                Executable: validation.Path
            })
    }
}

class DoubleCommanderFileManagerAdapter {
    static OpenFolder(folderPath, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        return LaunchThirdPartyFileManager(
            settings.Provider, validation.Path,
            BuildDoubleCommanderOpenFolderArgs(folderPath), folderPath)
    }

    static RevealItems(paths, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        if paths.Length = 1
            return LaunchThirdPartyFileManager(
                settings.Provider, validation.Path,
                BuildDoubleCommanderRevealItemArgs(paths[1]), paths[1])
        return OpenUniqueContainingFoldersWithAdapter(
            paths, DoubleCommanderFileManagerAdapter, {
                Provider: settings.Provider,
                Executable: validation.Path
            })
    }
}

class FilesFileManagerAdapter {
    static OpenFolder(folderPath, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        return LaunchThirdPartyFileManager(
            settings.Provider, validation.Path,
            BuildFilesOpenFolderArgs(folderPath), folderPath)
    }

    static RevealItems(paths, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        if paths.Length = 1
            return LaunchThirdPartyFileManager(
                settings.Provider, validation.Path,
                BuildFilesRevealItemArgs(paths[1]), paths[1])
        return OpenUniqueContainingFoldersWithAdapter(
            paths, FilesFileManagerAdapter, {
                Provider: settings.Provider,
                Executable: validation.Path
            })
    }
}

class FreeCommanderFileManagerAdapter {
    static OpenFolder(folderPath, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        return LaunchThirdPartyFileManager(
            settings.Provider, validation.Path,
            BuildFreeCommanderOpenFolderArgs(folderPath), folderPath)
    }

    static RevealItems(paths, settings) {
        validation := ValidateFileManagerExecutable(
            settings.Provider, settings.Executable)
        if !validation.Valid
            return FileManagerExecutableFailure(
                settings.Provider, validation.Message, settings.Executable)
        if paths.Length = 1
            return LaunchThirdPartyFileManager(
                settings.Provider, validation.Path,
                BuildFreeCommanderRevealItemArgs(paths[1]), paths[1])
        return OpenUniqueContainingFoldersWithAdapter(
            paths, FreeCommanderFileManagerAdapter, {
                Provider: settings.Provider,
                Executable: validation.Path
            })
    }
}

BuildDirectoryOpusOpenFolderArgs(folderPath) {
    return ["/acmd", "Go", NormalizePath(folderPath),
        "NEWTAB=deflister,findexisting", "TOFRONT"]
}

BuildDirectoryOpusRevealItemArgs(itemPath) {
    return ["/acmd", "Go", NormalizePath(itemPath),
        "OPENCONTAINER", "NEWTAB=deflister,findexisting", "TOFRONT"]
}

BuildTotalCommanderOpenFolderArgs(folderPath) {
    ; /O reuses a running instance; /S interprets /L as the active source
    ; panel. Quoting is applied later to this complete argv element.
    return ["/O", "/S", "/L=" NormalizePath(folderPath)]
}

BuildXYplorerOpenFolderArgs(folderPath) {
    ; XYplorer distinguishes navigation from selection by the trailing slash:
    ; a folder ending in "\" is opened, while an item path without it is
    ; revealed in its parent folder.
    return [RTrim(NormalizePath(folderPath), "\") "\"]
}

BuildXYplorerRevealItemArgs(itemPath) {
    return [NormalizePath(itemPath)]
}

BuildDoubleCommanderOpenFolderArgs(folderPath) {
    ; -C forwards the request to an existing instance when possible and
    ; otherwise starts Double Commander normally.
    return ["-C", NormalizePath(folderPath)]
}

BuildDoubleCommanderRevealItemArgs(itemPath) {
    ; Double Commander documents that a full file name opens its containing
    ; folder and moves the cursor to that item.
    return ["-C", NormalizePath(itemPath)]
}

BuildFilesOpenFolderArgs(folderPath) {
    return ["-directory", NormalizePath(folderPath)]
}

BuildFilesRevealItemArgs(itemPath) {
    return ["-select", NormalizePath(itemPath)]
}

BuildFreeCommanderOpenFolderArgs(folderPath) {
    return ["/C", NormalizePath(folderPath)]
}

BuildFreeCommanderRevealItemArgs(itemPath) {
    ; FreeCommander XE accepts a full file path and opens the parent folder
    ; with the cursor positioned on that item.
    return ["/C", NormalizePath(itemPath)]
}

LaunchThirdPartyFileManager(provider, executable, args, targetPath) {
    SplitPath(executable, , &workingDirectory)
    try {
        if ShellLaunchExecutableWithArgs(
            executable, args, workingDirectory)
            return FileManagerOperationSucceeded()
    } catch as err {
        return FileManagerOperationFailed(
            "LaunchFailed",
            "无法启动 " FileManagerProviderDisplayName(provider)
                . "，请检查文件管理器程序路径。`n`n" err.Message,
            provider, targetPath)
    }
    return FileManagerOperationFailed(
        "LaunchFailed",
        "无法启动 " FileManagerProviderDisplayName(provider)
            . "，请检查文件管理器程序路径。",
        provider, targetPath)
}

FileManagerExecutableFailure(provider, detail, executable := "") {
    message := "无法启动 " FileManagerProviderDisplayName(provider)
        . "，请检查文件管理器程序路径。"
    if detail != ""
        message .= "`n`n" detail
    return FileManagerOperationFailed(
        "ExecutableInvalid", message, provider, executable)
}

ValidateFileManagerExecutable(provider, executable) {
    global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_DIRECTORY_OPUS
    global FILE_MANAGER_TOTAL_COMMANDER, FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    provider := ParseFileManagerProvider(provider)
    if provider = FILE_MANAGER_WINDOWS_SHELL
        return {Valid: true, Path: "", Message: "跟随 Windows 系统行为"}
    executable := NormalizePath(executable)
    if executable = ""
        return {Valid: false, Path: "", Message: "尚未设置程序路径。"}
    if !IsExistingExecutable(executable)
        return {Valid: false, Path: executable,
            Message: "程序不存在或不是可执行文件：`n" executable}
    SplitPath(executable, &fileName)
    fileName := StrLower(fileName)
    if provider = FILE_MANAGER_DIRECTORY_OPUS
        && fileName != "dopusrt.exe"
        return {Valid: false, Path: executable,
            Message: "Directory Opus 实际执行程序必须是 dopusrt.exe。"}
    if provider = FILE_MANAGER_TOTAL_COMMANDER
        && fileName != "totalcmd64.exe" && fileName != "totalcmd.exe"
        return {Valid: false, Path: executable,
            Message: "请选择 TOTALCMD64.EXE 或 TOTALCMD.EXE。"}
    if provider = FILE_MANAGER_XYPLORER && fileName != "xyplorer.exe"
        return {Valid: false, Path: executable,
            Message: "请选择 XYplorer.exe。"}
    if provider = FILE_MANAGER_DOUBLE_COMMANDER
        && fileName != "doublecmd.exe"
        return {Valid: false, Path: executable,
            Message: "请选择 doublecmd.exe。"}
    if provider = FILE_MANAGER_FILES && !IsFilesExecutableName(fileName)
        return {Valid: false, Path: executable,
            Message: "请选择 Files 的官方启动别名或 Files.exe。"}
    if provider = FILE_MANAGER_FREE_COMMANDER
        && fileName != "freecommander.exe"
        return {Valid: false, Path: executable,
            Message: "请选择 FreeCommander.exe。"}
    return {Valid: true, Path: executable, Message: "程序路径有效。"}
}

IsFilesExecutableName(fileName) {
    fileName := StrLower(Trim(fileName))
    return fileName = "files.exe"
        || fileName = "files-stable.exe"
        || fileName = "files-preview.exe"
        || fileName = "files-dev.exe"
}

ResolveDirectoryOpusRuntimePath(path) {
    path := NormalizePath(path)
    if path = ""
        return ""
    SplitPath(path, &fileName, &directory)
    if StrLower(fileName) = "dopus.exe" {
        runtime := directory "\dopusrt.exe"
        if IsExistingExecutable(runtime)
            return runtime
    }
    return path
}

NormalizeFileManagerExecutableForSave(provider, path) {
    global FILE_MANAGER_DIRECTORY_OPUS
    provider := ParseFileManagerProvider(provider)
    path := NormalizePath(path)
    if provider = FILE_MANAGER_DIRECTORY_OPUS
        path := ResolveDirectoryOpusRuntimePath(path)
    return path
}

CanRevealItemsInFileManager(paths, settings := 0) {
    global FILE_MANAGER_WINDOWS_SHELL
    existing := UniqueExistingFileManagerItems(paths, &missingPath)
    if missingPath != "" || !existing.Length
        return false
    resolved := ResolveFileManagerSettings(settings)
    if resolved.Provider = FILE_MANAGER_WINDOWS_SHELL
        return CanWindowsShellRevealTogether(existing)
    return GetUniqueContainingFolders(existing).Length > 0
}

CanWindowsShellRevealTogether(paths) {
    if !paths.Length
        return false
    parent := GetParentPath(paths[1])
    if !DirExist(parent)
        return false
    for path in paths {
        if !FileExist(path) || !PathsEqual(GetParentPath(path), parent)
            return false
    }
    return true
}

UniqueExistingFileManagerItems(paths, &missingPath) {
    result := []
    missingPath := ""
    if !IsObject(paths)
        return result
    for path in paths {
        normalized := NormalizePath(path)
        if normalized = "" || !FileExist(normalized) {
            missingPath := normalized != "" ? normalized : path
            return []
        }
        if !ArrayContainsPath(result, normalized)
            result.Push(normalized)
    }
    return result
}

GetUniqueContainingFolders(paths) {
    folders := []
    for path in paths {
        folder := GetParentPath(path)
        if folder != "" && DirExist(folder)
            && !ArrayContainsPath(folders, folder)
            folders.Push(folder)
    }
    return folders
}

OpenUniqueContainingFoldersWithAdapter(paths, adapterClass, settings) {
    folders := GetUniqueContainingFolders(paths)
    if !folders.Length
        return FileManagerOperationFailed(
            "TargetMissing", "找不到可打开的文件所在文件夹。")
    for folder in folders {
        result := adapterClass.OpenFolder(folder, settings)
        if !result.Success
            return result
    }
    return FileManagerOperationSucceeded()
}

OpenFolderInFileManager(folderPath, settings := 0, *) {
    resolved := ResolveFileManagerSettings(settings)
    result := FileManagerRouter.OpenFolder(folderPath, resolved)
    if result.Success
        return true
    if HandleFileManagerFailure(result, resolved) = "WindowsFallback" {
        fallback := FileManagerRouter.OpenFolder(folderPath, {
            Provider: "WindowsShell", Executable: ""})
        if fallback.Success
            return true
        ShowPanelMsgBox(fallback.Message, "打开失败", "Iconx")
    }
    return false
}

RevealItemsInFileManager(itemPaths, settings := 0, *) {
    resolved := ResolveFileManagerSettings(settings)
    result := FileManagerRouter.RevealItems(itemPaths, resolved)
    if result.Success
        return true
    if HandleFileManagerFailure(result, resolved) = "WindowsFallback" {
        fallback := FileManagerRouter.RevealItems(itemPaths, {
            Provider: "WindowsShell", Executable: ""})
        if fallback.Success
            return true
        ShowPanelMsgBox(fallback.Message, "定位失败", "Iconx")
    }
    return false
}

HandleFileManagerFailure(result, settings) {
    global FILE_MANAGER_WINDOWS_SHELL
    if result.Kind = "TargetMissing" {
        ShowPanelMsgBox(result.Message, "目标不存在", "Icon!")
        return ""
    }
    if settings.Provider = FILE_MANAGER_WINDOWS_SHELL {
        ShowPanelMsgBox(result.Message,
            result.Kind = "SelectionLayout"
                ? "在文件管理器中显示" : "打开失败",
            result.Kind = "SelectionLayout" ? "Iconi" : "Iconx")
        return ""
    }
    answer := ShowPanelMsgBox(
        result.Message
            . "`n`n“是”：打开文件管理器设置"
            . "`n“否”：本次使用 Windows 系统方式"
            . "`n“取消”：不执行其他操作",
        "文件管理器不可用", "YesNoCancel Iconx")
    if answer = "Yes" {
        OpenFileManagerSettings()
        return "Settings"
    }
    return answer = "No" ? "WindowsFallback" : ""
}

FindFileManagerExecutable(provider) {
    global FILE_MANAGER_DIRECTORY_OPUS, FILE_MANAGER_TOTAL_COMMANDER
    global FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    provider := ParseFileManagerProvider(provider)
    candidates := []
    if provider = FILE_MANAGER_DIRECTORY_OPUS {
        for exeName in ["dopusrt.exe", "dopus.exe"]
            AddAppPathRegistryCandidates(candidates, exeName)
        for root in CommonProgramFilesRoots()
            AddFileManagerCandidate(
                candidates, root "\GPSoftware\Directory Opus\dopusrt.exe")
        for candidate in candidates {
            resolved := ResolveDirectoryOpusRuntimePath(candidate)
            if ValidateFileManagerExecutable(provider, resolved).Valid
                return resolved
        }
        return ""
    }
    if provider = FILE_MANAGER_TOTAL_COMMANDER {
        for exeName in ["TOTALCMD64.EXE", "TOTALCMD.EXE"]
            AddAppPathRegistryCandidates(candidates, exeName)
        commanderPath := Trim(EnvGet("COMMANDER_PATH"))
        if commanderPath != "" {
            AddFileManagerCandidate(
                candidates, commanderPath "\TOTALCMD64.EXE")
            AddFileManagerCandidate(
                candidates, commanderPath "\TOTALCMD.EXE")
        }
        for root in CommonProgramFilesRoots() {
            AddFileManagerCandidate(
                candidates, root "\totalcmd\TOTALCMD64.EXE")
            AddFileManagerCandidate(
                candidates, root "\totalcmd\TOTALCMD.EXE")
            AddFileManagerCandidate(
                candidates, root "\Total Commander\TOTALCMD64.EXE")
            AddFileManagerCandidate(
                candidates, root "\Total Commander\TOTALCMD.EXE")
        }
        for root in ["C:\totalcmd", "C:\totalcmd64"] {
            AddFileManagerCandidate(candidates, root "\TOTALCMD64.EXE")
            AddFileManagerCandidate(candidates, root "\TOTALCMD.EXE")
        }
        for candidate in candidates {
            if ValidateFileManagerExecutable(provider, candidate).Valid
                return NormalizePath(candidate)
        }
        return ""
    }
    if provider = FILE_MANAGER_XYPLORER {
        AddAppPathRegistryCandidates(candidates, "XYplorer.exe")
        for root in CommonProgramFilesRoots()
            AddFileManagerCandidate(
                candidates, root "\XYplorer\XYplorer.exe")
        localAppData := Trim(EnvGet("LOCALAPPDATA"))
        if localAppData != ""
            AddFileManagerCandidate(
                candidates, localAppData "\Programs\XYplorer\XYplorer.exe")
        for candidate in candidates {
            if ValidateFileManagerExecutable(provider, candidate).Valid
                return NormalizePath(candidate)
        }
        return ""
    }
    if provider = FILE_MANAGER_DOUBLE_COMMANDER {
        AddAppPathRegistryCandidates(candidates, "doublecmd.exe")
        for root in CommonProgramFilesRoots() {
            AddFileManagerCandidate(
                candidates, root "\Double Commander\doublecmd.exe")
            AddFileManagerCandidate(
                candidates, root "\doublecmd\doublecmd.exe")
        }
        for candidate in candidates {
            if ValidateFileManagerExecutable(provider, candidate).Valid
                return NormalizePath(candidate)
        }
        return ""
    }
    if provider = FILE_MANAGER_FILES {
        for exeName in ["files-stable.exe", "files-preview.exe",
            "files-dev.exe", "Files.exe"]
            AddAppPathRegistryCandidates(candidates, exeName)
        localAppData := Trim(EnvGet("LOCALAPPDATA"))
        if localAppData != "" {
            windowsApps := localAppData "\Microsoft\WindowsApps"
            for exeName in ["files-stable.exe", "files-preview.exe",
                "files-dev.exe", "Files.exe"]
                AddFileManagerCandidate(
                    candidates, windowsApps "\" exeName)
        }
        for root in CommonProgramFilesRoots()
            AddFileManagerCandidate(candidates, root "\Files\Files.exe")
        for candidate in candidates {
            if ValidateFileManagerExecutable(provider, candidate).Valid
                return NormalizePath(candidate)
        }
        return ""
    }
    if provider = FILE_MANAGER_FREE_COMMANDER {
        AddAppPathRegistryCandidates(candidates, "FreeCommander.exe")
        for root in CommonProgramFilesRoots() {
            AddFileManagerCandidate(
                candidates, root "\FreeCommander XE\FreeCommander.exe")
            AddFileManagerCandidate(
                candidates, root "\FreeCommander\FreeCommander.exe")
        }
        for candidate in candidates {
            if ValidateFileManagerExecutable(provider, candidate).Valid
                return NormalizePath(candidate)
        }
    }
    return ""
}

AddAppPathRegistryCandidates(candidates, executableName) {
    suffix := "\Software\Microsoft\Windows\CurrentVersion\App Paths\"
        . executableName
    for root in ["HKCU", "HKLM", "HKLM\Software\WOW6432Node"] {
        key := root = "HKLM\Software\WOW6432Node"
            ? root "\Microsoft\Windows\CurrentVersion\App Paths\"
                . executableName
            : root suffix
        try AddFileManagerCandidate(candidates, RegRead(key))
    }
}

CommonProgramFilesRoots() {
    roots := []
    for variableName in ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"] {
        value := Trim(EnvGet(variableName))
        if value != "" && !ArrayContainsPath(roots, value)
            roots.Push(value)
    }
    if !roots.Length
        roots.Push("C:\Program Files")
    return roots
}

AddFileManagerCandidate(candidates, path) {
    path := NormalizePath(path)
    if path != "" && !ArrayContainsPath(candidates, path)
        candidates.Push(path)
}

RunFileManagerSelfTests() {
    global FILE_MANAGER_WINDOWS_SHELL, FILE_MANAGER_DIRECTORY_OPUS
    global FILE_MANAGER_TOTAL_COMMANDER, FILE_MANAGER_XYPLORER
    global FILE_MANAGER_DOUBLE_COMMANDER, FILE_MANAGER_FILES
    global FILE_MANAGER_FREE_COMMANDER
    AssertSelfTest(ParseFileManagerProvider("") = FILE_MANAGER_WINDOWS_SHELL,
        "缺失文件管理器配置保持 Windows 系统行为")
    AssertSelfTest(ParseFileManagerProvider("unknown")
        = FILE_MANAGER_WINDOWS_SHELL,
        "未知文件管理器配置安全回退 Windows 系统行为")
    AssertSelfTest(ParseFileManagerProvider("directoryopus")
        = FILE_MANAGER_DIRECTORY_OPUS,
        "Directory Opus 稳定 ID 大小写不敏感")
    AssertSelfTest(ParseFileManagerProvider("totalcommander")
        = FILE_MANAGER_TOTAL_COMMANDER,
        "Total Commander 稳定 ID 大小写不敏感")
    AssertSelfTest(ParseFileManagerProvider("xyplorer")
        = FILE_MANAGER_XYPLORER,
        "XYplorer 稳定 ID 大小写不敏感")
    AssertSelfTest(ParseFileManagerProvider("doublecommander")
        = FILE_MANAGER_DOUBLE_COMMANDER,
        "Double Commander 稳定 ID 大小写不敏感")
    AssertSelfTest(ParseFileManagerProvider("files")
        = FILE_MANAGER_FILES,
        "Files 稳定 ID 大小写不敏感")
    AssertSelfTest(ParseFileManagerProvider("freecommander")
        = FILE_MANAGER_FREE_COMMANDER,
        "FreeCommander XE 稳定 ID 大小写不敏感")

    specialFolder := "C:\空 格\项目 (一)&二"
    specialFile := specialFolder "\报告 " . Chr(34) . "草稿" . Chr(34) . ".txt"
    opusFolderArgs := BuildDirectoryOpusOpenFolderArgs(specialFolder)
    opusRevealArgs := BuildDirectoryOpusRevealItemArgs(specialFile)
    tcArgs := BuildTotalCommanderOpenFolderArgs(specialFolder)
    xyFolderArgs := BuildXYplorerOpenFolderArgs(specialFolder)
    xyRevealArgs := BuildXYplorerRevealItemArgs(specialFile)
    dcFolderArgs := BuildDoubleCommanderOpenFolderArgs(specialFolder)
    dcRevealArgs := BuildDoubleCommanderRevealItemArgs(specialFile)
    filesFolderArgs := BuildFilesOpenFolderArgs(specialFolder)
    filesRevealArgs := BuildFilesRevealItemArgs(specialFile)
    fcFolderArgs := BuildFreeCommanderOpenFolderArgs(specialFolder)
    fcRevealArgs := BuildFreeCommanderRevealItemArgs(specialFile)
    AssertSelfTest(opusFolderArgs.Length = 5
        && opusFolderArgs[1] = "/acmd"
        && opusFolderArgs[3] = specialFolder
        && opusFolderArgs[4] = "NEWTAB=deflister,findexisting"
        && opusFolderArgs[5] = "TOFRONT",
        "Directory Opus 打开文件夹命令参数")
    AssertSelfTest(opusRevealArgs.Length = 6
        && opusRevealArgs[3] = specialFile
        && opusRevealArgs[4] = "OPENCONTAINER",
        "Directory Opus 单文件定位命令参数")
    AssertSelfTest(tcArgs.Length = 3
        && tcArgs[1] = "/O" && tcArgs[2] = "/S"
        && tcArgs[3] = "/L=" specialFolder,
        "Total Commander 当前源面板命令参数")
    AssertSelfTest(xyFolderArgs.Length = 1
        && xyFolderArgs[1] = specialFolder "\",
        "XYplorer 打开文件夹命令参数")
    AssertSelfTest(xyRevealArgs.Length = 1
        && xyRevealArgs[1] = specialFile,
        "XYplorer 单项目定位命令参数")
    AssertSelfTest(dcFolderArgs.Length = 2
        && dcFolderArgs[1] = "-C"
        && dcFolderArgs[2] = specialFolder,
        "Double Commander 打开文件夹命令参数")
    AssertSelfTest(dcRevealArgs.Length = 2
        && dcRevealArgs[1] = "-C"
        && dcRevealArgs[2] = specialFile,
        "Double Commander 单项目定位命令参数")
    AssertSelfTest(filesFolderArgs.Length = 2
        && filesFolderArgs[1] = "-directory"
        && filesFolderArgs[2] = specialFolder,
        "Files 打开文件夹命令参数")
    AssertSelfTest(filesRevealArgs.Length = 2
        && filesRevealArgs[1] = "-select"
        && filesRevealArgs[2] = specialFile,
        "Files 单项目定位命令参数")
    AssertSelfTest(fcFolderArgs.Length = 2
        && fcFolderArgs[1] = "/C"
        && fcFolderArgs[2] = specialFolder,
        "FreeCommander XE 打开文件夹命令参数")
    AssertSelfTest(fcRevealArgs.Length = 2
        && fcRevealArgs[1] = "/C"
        && fcRevealArgs[2] = specialFile,
        "FreeCommander XE 单项目定位命令参数")

    commandLine := BuildWindowsParameterString(
        ["/acmd", "Go", specialFile,
            "OPENCONTAINER", "NEWTAB=deflister,findexisting", "TOFRONT"])
    roundTrip := ParseWindowsCommandLineForSelfTest(commandLine)
    AssertSelfTest(roundTrip.Length = 6
        && roundTrip[3] = specialFile
        && SubStr(commandLine, 1, 9) = "/acmd Go "
        && !InStr(commandLine, '"/acmd"'),
        "文件管理器特殊字符参数可无损还原")
    xyFolderRoundTrip := ParseWindowsCommandLineForSelfTest(
        BuildWindowsParameterString(xyFolderArgs))
    xyRevealRoundTrip := ParseWindowsCommandLineForSelfTest(
        BuildWindowsParameterString(xyRevealArgs))
    AssertSelfTest(xyFolderRoundTrip.Length = 1
        && xyFolderRoundTrip[1] = specialFolder "\"
        && xyRevealRoundTrip.Length = 1
        && xyRevealRoundTrip[1] = specialFile,
        "XYplorer 路径参数可无损还原")
    dcRoundTrip := ParseWindowsCommandLineForSelfTest(
        BuildWindowsParameterString(dcRevealArgs))
    filesRoundTrip := ParseWindowsCommandLineForSelfTest(
        BuildWindowsParameterString(filesRevealArgs))
    fcRoundTrip := ParseWindowsCommandLineForSelfTest(
        BuildWindowsParameterString(fcRevealArgs))
    AssertSelfTest(dcRoundTrip.Length = 2
        && dcRoundTrip[1] = "-C"
        && dcRoundTrip[2] = specialFile
        && filesRoundTrip.Length = 2
        && filesRoundTrip[1] = "-select"
        && filesRoundTrip[2] = specialFile
        && fcRoundTrip.Length = 2
        && fcRoundTrip[1] = "/C"
        && fcRoundTrip[2] = specialFile,
        "Double Commander、Files 与 FreeCommander 路径参数可无损还原")

    testRoot := A_Temp "\PopDrop-file-manager-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount
    try {
        firstFolder := testRoot "\同一文件夹"
        secondFolder := testRoot "\另一文件夹"
        firstFile := firstFolder "\一 & (1).txt"
        secondFile := firstFolder "\二.txt"
        thirdFile := secondFolder "\三.txt"
        DirCreate(firstFolder)
        DirCreate(secondFolder)
        FileAppend("1", firstFile, "UTF-8")
        FileAppend("2", secondFile, "UTF-8")
        FileAppend("3", thirdFile, "UTF-8")
        folders := GetUniqueContainingFolders(
            [firstFile, secondFile, thirdFile, firstFile])
        AssertSelfTest(folders.Length = 2
            && PathsEqual(folders[1], firstFolder)
            && PathsEqual(folders[2], secondFolder),
            "多项目按文件所在文件夹保序去重")
        AssertSelfTest(CanWindowsShellRevealTogether(
            [firstFile, secondFile])
            && !CanWindowsShellRevealTogether(
                [firstFile, thirdFile]),
            "Windows Shell 同文件夹多选兼容边界")
    } finally {
        try DirDelete(testRoot, true)
    }
}
