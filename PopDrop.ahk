#Requires AutoHotkey v2.0
#SingleInstance Force

;@Ahk2Exe-SetMainIcon assets\app.ico
;@Ahk2Exe-AddResource assets\tray.ico, 555

; PopDrop - a topmost recent-file panel for Windows.
; The program intentionally uses only AutoHotkey v2 and Windows Shell APIs.

Persistent
SetWorkingDir A_ScriptDir
DllCall("ole32\OleInitialize", "ptr", 0)
OnExit(Cleanup)

global ConfigPath := A_ScriptDir "\config.ini"
global Panel := 0
global FileView := 0
global RecentLabel := 0
global RecentView := 0
global ViewButton := 0
global RecentButton := 0
global StatusText := 0
global ItemPaths := Map()
global RecentItemPaths := Map()
global PinnedPaths := []
global FolderSettings := []
global MaxFilesPerFolder := 8
global IncludeSubfolders := false
global ThumbnailSize := 96
global ThumbnailImageList := 0
global WindowWidth := 980
global WindowHeight := 620
global ViewMode := "Thumbnail"
global ShowRecentSidebar := true
global RecentFileCount := 12
global ConfiguredHotkey := "F3"
global ActiveHotkey := ""
global PanelVisible := false
global DragPaths := []
global SelectedFilePaths := []
global DragSourceHwnd := 0
global DragStartX := 0
global DragStartY := 0
global DragStarted := false
global DropVTable := 0
global DropCallbacks := []
global DataVTable := 0
global DataCallbacks := []
global DragDataObjects := Map()

EnsureConfig()
LoadSettings()
BuildPanel()
InstallHotkey(ConfiguredHotkey)
BuildTrayMenu()
InitDropSource()
OnMessage(0x0201, FileViewLeftButtonDown) ; WM_LBUTTONDOWN
OnMessage(0x0200, FileViewMouseMove)      ; WM_MOUSEMOVE

EnsureConfig() {
    global ConfigPath
    if FileExist(ConfigPath) {
        EnsureConfigEncoding()
        return
    }

    defaultConfig :=
    (
    "; PopDrop 配置文件`n"
    "; 修改后，在面板中点“刷新”即可重新读取。`n"
    "`n"
    "[General]`n"
    "Hotkey=F3`n"
    "MaxFilesPerFolder=8`n"
    "IncludeSubfolders=0`n"
    "ThumbnailSize=96`n"
    "WindowWidth=980`n"
    "WindowHeight=620`n"
    "ViewMode=Thumbnail`n"
    "ShowRecentSidebar=1`n"
    "RecentFileCount=12`n"
    "`n"
    "[Folders]`n"
    "文档=%USERPROFILE%\Documents`n"
    "下载=D:\download`n"
    "`n"
    "[PinnedFiles]`n"
    )
    ; IniRead/IniWrite use the Windows profile API, which requires UTF-16 for
    ; reliable Chinese text on every system locale.
    FileAppend(defaultConfig, ConfigPath, "UTF-16")
}

EnsureConfigEncoding() {
    global ConfigPath
    try {
        rawBytes := FileRead(ConfigPath, "RAW")
        if rawBytes.Size >= 2 && NumGet(rawBytes, 0, "ushort") = 0xFEFF
            return
        contents := FileRead(ConfigPath, "UTF-8")
        output := FileOpen(ConfigPath, "w", "UTF-16")
        output.Write(contents)
        output.Close()
    }
}

LoadSettings(*) {
    global ConfigPath, ConfiguredHotkey, MaxFilesPerFolder
    global IncludeSubfolders, ThumbnailSize, FolderSettings, PinnedPaths
    global WindowWidth, WindowHeight, ViewMode, ShowRecentSidebar, RecentFileCount

    ConfiguredHotkey := Trim(IniRead(ConfigPath, "General", "Hotkey", "F3"))
    if ConfiguredHotkey = ""
        ConfiguredHotkey := "F3"

    try MaxFilesPerFolder := Integer(IniRead(ConfigPath, "General", "MaxFilesPerFolder", "8"))
    catch
        MaxFilesPerFolder := 8
    MaxFilesPerFolder := Max(1, Min(MaxFilesPerFolder, 100))
    IncludeSubfolders := IniRead(ConfigPath, "General", "IncludeSubfolders", "0") = "1"
    try ThumbnailSize := Integer(IniRead(ConfigPath, "General", "ThumbnailSize", "96"))
    catch
        ThumbnailSize := 96
    ThumbnailSize := Max(48, Min(ThumbnailSize, 256))

    try WindowWidth := Integer(IniRead(ConfigPath, "General", "WindowWidth", "980"))
    catch
        WindowWidth := 980
    try WindowHeight := Integer(IniRead(ConfigPath, "General", "WindowHeight", "620"))
    catch
        WindowHeight := 620
    WindowWidth := Max(620, Min(WindowWidth, 3000))
    WindowHeight := Max(380, Min(WindowHeight, 2000))

    configuredView := StrLower(Trim(IniRead(ConfigPath, "General", "ViewMode", "Thumbnail")))
    ViewMode := configuredView = "list" ? "List" : "Thumbnail"
    ShowRecentSidebar := IniRead(ConfigPath, "General", "ShowRecentSidebar", "1") = "1"
    try RecentFileCount := Integer(IniRead(ConfigPath, "General", "RecentFileCount", "12"))
    catch
        RecentFileCount := 12
    RecentFileCount := Max(1, Min(RecentFileCount, 100))

    FolderSettings := []
    for entry in ReadIniSection("Folders") {
        if entry.Value != ""
            FolderSettings.Push({Name: entry.Key, Path: NormalizePath(entry.Value)})
    }

    PinnedPaths := []
    for entry in ReadIniSection("PinnedFiles") {
        path := NormalizePath(entry.Value)
        if path != "" && !ArrayContainsPath(PinnedPaths, path)
            PinnedPaths.Push(path)
    }
}

ReadIniSection(sectionName) {
    global ConfigPath
    result := []
    try raw := IniRead(ConfigPath, sectionName)
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

NormalizePath(path) {
    path := Trim(path, " `t`r`n`"")
    if path = ""
        return ""

    required := DllCall("kernel32\ExpandEnvironmentStringsW", "str", path, "ptr", 0, "uint", 0, "uint")
    if required {
        expanded := Buffer(required * 2, 0)
        DllCall("kernel32\ExpandEnvironmentStringsW", "str", path, "ptr", expanded.Ptr, "uint", required)
        path := StrGet(expanded)
    }

    if !RegExMatch(path, "i)^(?:[A-Z]:\\|\\\\)")
        path := A_ScriptDir "\" path
    if RegExMatch(path, "i)^[A-Z]:\\$")
        return path
    return RTrim(path, "\")
}

BuildPanel() {
    global Panel, FileView, RecentLabel, RecentView, ViewButton, RecentButton, StatusText

    Panel := Gui("+AlwaysOnTop +Resize +MinSize620x380", "PopDrop")
    Panel.MarginX := 12
    Panel.MarginY := 10
    Panel.SetFont("s9", "Microsoft YaHei UI")

    Panel.AddButton("xm ym w68 h30", "刷新").OnEvent("Click", RefreshPanel)
    Panel.AddButton("x+6 yp w90 h30", "添加固定文件").OnEvent("Click", AddPinnedFiles)
    Panel.AddButton("x+6 yp w80 h30", "取消固定").OnEvent("Click", RemovePinnedFile)
    ViewButton := Panel.AddButton("x+6 yp w95 h30", "视图")
    ViewButton.OnEvent("Click", ToggleViewMode)
    RecentButton := Panel.AddButton("x+6 yp w90 h30", "近期栏")
    RecentButton.OnEvent("Click", ToggleRecentSidebar)
    Panel.AddButton("x+6 yp w65 h30", "配置").OnEvent("Click", OpenConfig)
    Panel.AddButton("x+6 yp w55 h30", "关闭").OnEvent("Click", HidePanel)

    ; Multi-select is the native ListView default. In icon view this enables
    ; Ctrl-click, Shift range selection and marquee selection on blank space.
    FileView := Panel.AddListView("xm y+10 w716 h468 Icon +0x100", ["文件", "修改时间"])
    FileView.OnEvent("DoubleClick", OpenFileViewItem)
    FileView.OnEvent("ContextMenu", FileViewContextMenu)
    FileView.OnEvent("ItemSelect", FileViewItemSelect)
    ; LVS_EX_DOUBLEBUFFER reduces flicker while rebuilding thumbnail groups.
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1036,
        "ptr", 0x10000, "ptr", 0x10000, "ptr")
    
    RecentLabel := Panel.AddText("x740 y50 w220 h22 +0x200", "最近打开")
    RecentLabel.SetFont("s10 Bold")
    RecentView := Panel.AddListView("x740 y76 w220 h442 Report -Hdr -Multi", ["文件"])
    RecentView.OnEvent("DoubleClick", OpenRecentItem)
    RecentView.OnEvent("ContextMenu", RecentContextMenu)
    RecentView.OnEvent("ItemSelect", RecentItemSelect)

    StatusText := Panel.AddText("xm y+8 w716 h22 +0x200", "就绪")
    Panel.OnEvent("Close", HandlePanelClose)
    Panel.OnEvent("Escape", HandlePanelClose)
    Panel.OnEvent("Size", ResizePanel)
    UpdateViewButtons()
}

BuildTrayMenu() {
    global ActiveHotkey
    if A_IsCompiled {
        TraySetIcon(A_ScriptFullPath, -555, true)
    } else {
        TraySetIcon(A_ScriptDir "\assets\tray.ico", 1, true)
    }
    A_TrayMenu.Delete()
    A_TrayMenu.Add("显示/隐藏面板 (" ActiveHotkey ")", TogglePanel)
    A_TrayMenu.Add("刷新并显示", ShowAndRefresh)
    A_TrayMenu.Add()
    A_TrayMenu.Add("打开配置", OpenConfig)
    A_TrayMenu.Add("退出", (*) => ExitApp())
    A_TrayMenu.Default := "显示/隐藏面板 (" ActiveHotkey ")"
    A_IconTip := "PopDrop"
}

InstallHotkey(newHotkey) {
    global ActiveHotkey, ConfiguredHotkey, ConfigPath
    if newHotkey = ActiveHotkey
        return

    try Hotkey(newHotkey, TogglePanel, "On")
    catch as err {
        MsgBox("快捷键配置无效：" newHotkey "`n已改用 F3。`n`n" err.Message,
            "PopDrop", "Icon!")
        newHotkey := "F3"
        ConfiguredHotkey := newHotkey
        IniWrite(newHotkey, ConfigPath, "General", "Hotkey")
        Hotkey(newHotkey, TogglePanel, "On")
    }

    if ActiveHotkey != ""
        try Hotkey(ActiveHotkey, "Off")
    ActiveHotkey := newHotkey
}

TogglePanel(*) {
    global PanelVisible
    if PanelVisible
        HidePanel()
    else
        ShowAndRefresh()
}

ShowAndRefresh(*) {
    global Panel, PanelVisible, ConfiguredHotkey, ActiveHotkey, WindowWidth, WindowHeight
    LoadSettings()
    if ConfiguredHotkey != ActiveHotkey {
        InstallHotkey(ConfiguredHotkey)
        BuildTrayMenu()
    }
    PopulatePanel()
    PopulateRecentSidebar()
    UpdateViewButtons()
    Panel.Show("w" WindowWidth " h" WindowHeight)
    PanelVisible := true
    ApplyWindowIcon()
    WinActivate("ahk_id " Panel.Hwnd)
}

ApplyWindowIcon() {
    global Panel
    iconPath := A_IsCompiled ? A_ScriptFullPath : A_ScriptDir "\assets\app.ico"
    hIcon := DllCall("LoadImageW", "ptr", 0, "str", iconPath,
        "uint", 1, "int", 0, "int", 0, "uint", 0x10, "ptr") ; IMAGE_ICON, LR_LOADFROMFILE
    if hIcon {
        SendMessage(0x80, 0, hIcon, , "ahk_id " Panel.Hwnd) ; WM_SETICON, ICON_SMALL
        SendMessage(0x80, 1, hIcon, , "ahk_id " Panel.Hwnd) ; WM_SETICON, ICON_BIG
        ; The window takes ownership of the icon handle; do not destroy.
    }
}

RefreshPanel(*) {
    global Panel, ConfiguredHotkey, ActiveHotkey, WindowWidth, WindowHeight
    LoadSettings()
    if ConfiguredHotkey != ActiveHotkey {
        InstallHotkey(ConfiguredHotkey)
        BuildTrayMenu()
    }
    PopulatePanel()
    PopulateRecentSidebar()
    UpdateViewButtons()
    Panel.Show("w" WindowWidth " h" WindowHeight)
}

HidePanel(*) {
    global Panel, PanelVisible
    Panel.Hide()
    PanelVisible := false
}

HandlePanelClose(*) {
    HidePanel()
    return true
}

ResizePanel(guiObj, minMax, width, height) {
    global FileView, RecentLabel, RecentView, StatusText, ShowRecentSidebar
    if minMax = -1
        return
    contentHeight := Max(180, height - 92)
    if ShowRecentSidebar {
        sidebarWidth := Min(280, Max(190, Floor(width * 0.28)))
        mainWidth := Max(280, width - sidebarWidth - 36)
        sidebarX := 24 + mainWidth
        FileView.Move(12, 50, mainWidth, contentHeight)
        RecentLabel.Move(sidebarX, 50, sidebarWidth, 22)
        RecentView.Move(sidebarX, 76, sidebarWidth, Max(154, contentHeight - 26))
        RecentView.ModifyCol(1, Max(120, sidebarWidth - 8))
        RecentLabel.Visible := true
        RecentView.Visible := true
    } else {
        FileView.Move(12, 50, Max(200, width - 24), contentHeight)
        RecentLabel.Visible := false
        RecentView.Visible := false
    }
    StatusText.Move(, height - 27, Max(200, width - 24))
}

RequestNativeLayout() {
    global Panel
    ; Gui.OnEvent("Size") receives DPI-adjusted coordinates only when AHK
    ; dispatches a real WM_SIZE.  Calling ResizePanel directly bypasses that
    ; conversion and makes controls too wide on high-DPI displays.
    clientRect := Buffer(16, 0)
    if !DllCall("user32\GetClientRect", "ptr", Panel.Hwnd, "ptr", clientRect.Ptr)
        return
    clientWidth := NumGet(clientRect, 8, "int") - NumGet(clientRect, 0, "int")
    clientHeight := NumGet(clientRect, 12, "int") - NumGet(clientRect, 4, "int")
    packedSize := (clientWidth & 0xFFFF) | ((clientHeight & 0xFFFF) << 16)
    DllCall("user32\PostMessageW", "ptr", Panel.Hwnd, "uint", 0x0005,
        "uptr", 0, "uptr", packedSize) ; WM_SIZE
}

ToggleViewMode(*) {
    global ViewMode, ConfigPath
    ViewMode := ViewMode = "Thumbnail" ? "List" : "Thumbnail"
    IniWrite(ViewMode, ConfigPath, "General", "ViewMode")
    ApplyViewMode()
    UpdateViewButtons()
}

ToggleRecentSidebar(*) {
    global ShowRecentSidebar, ConfigPath
    ShowRecentSidebar := !ShowRecentSidebar
    IniWrite(ShowRecentSidebar ? "1" : "0", ConfigPath, "General", "ShowRecentSidebar")
    if ShowRecentSidebar
        PopulateRecentSidebar()
    UpdateViewButtons()
    RequestNativeLayout()
}

UpdateViewButtons() {
    global ViewButton, RecentButton, ViewMode, ShowRecentSidebar
    if IsObject(ViewButton)
        ViewButton.Text := ViewMode = "Thumbnail" ? "视图：缩略图" : "视图：列表"
    if IsObject(RecentButton)
        RecentButton.Text := ShowRecentSidebar ? "近期栏：开" : "近期栏：关"
}

ApplyViewMode() {
    global FileView, ViewMode, ThumbnailSize
    if ViewMode = "List" {
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x108E,
            "ptr", 1, "ptr", 0, "ptr") ; LVM_SETVIEW, LV_VIEW_DETAILS
        FileView.ModifyCol(1, 360)
        FileView.ModifyCol(2, 132)
    } else {
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x108E,
            "ptr", 0, "ptr", 0, "ptr") ; LVM_SETVIEW, LV_VIEW_ICON
        FileView.ModifyCol(1, ThumbnailSize + 32)
        spacing := (ThumbnailSize + 32) | ((ThumbnailSize + 18) << 16)
        DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1035,
            "ptr", 0, "ptr", spacing, "ptr")
    }
}

PopulatePanel() {
    global FileView, ItemPaths, PinnedPaths, FolderSettings, StatusText
    global MaxFilesPerFolder, IncludeSubfolders, ThumbnailSize, ThumbnailImageList
    global SelectedFilePaths

    SelectedFilePaths := []
    FileView.Opt("-Redraw")
    FileView.Delete()
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x10A0,
        "ptr", 0, "ptr", 0, "ptr") ; LVM_REMOVEALLGROUPS
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x109D,
        "ptr", 1, "ptr", 0, "ptr") ; LVM_ENABLEGROUPVIEW

    newImageList := DllCall("comctl32\ImageList_Create", "int", ThumbnailSize,
        "int", ThumbnailSize, "uint", 0x21, "int", 24, "int", 12, "ptr")
    if !newImageList
        throw Error("无法创建缩略图列表。")
    oldImageList := FileView.SetImageList(newImageList, 0)
    ThumbnailImageList := newImageList
    if oldImageList && oldImageList != newImageList
        DllCall("comctl32\ImageList_Destroy", "ptr", oldImageList)
    spacing := (ThumbnailSize + 52) | ((ThumbnailSize + 58) << 16)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1035,
        "ptr", 0, "ptr", spacing, "ptr") ; LVM_SETICONSPACING

    ItemPaths := Map()
    displayedCount := 0
    unavailableCount := 0
    groupId := 1

    if PinnedPaths.Length {
        InsertListGroup(groupId, "固定文件  (" PinnedPaths.Length ")")
        for path in PinnedPaths {
            exists := FileExist(path)
            label := GetFileName(path)
            if !exists
                label .= "  [文件不存在]"
            row := AddFileTile(path, label, "", groupId)
            ItemPaths[row] := path
            displayedCount += 1
        }
        groupId += 1
    }

    for folder in FolderSettings {
        exists := DirExist(folder.Path)
        files := exists ? GetLatestFiles(folder.Path, MaxFilesPerFolder, IncludeSubfolders) : []
        suffix := exists ? " (" files.Length ")" : " [目录不可用]"
        InsertListGroup(groupId, folder.Name suffix "  —  " folder.Path)
        if !exists {
            AddPlaceholderTile("目录不可用", groupId)
            unavailableCount += 1
            groupId += 1
            continue
        }
        if !files.Length {
            AddPlaceholderTile("暂无文件", groupId)
            groupId += 1
            continue
        }
        for file in files {
            modifiedText := FormatTime(file.Modified, "yyyy-MM-dd HH:mm")
            row := AddFileTile(file.Path, file.Name, modifiedText, groupId)
            ItemPaths[row] := file.Path
            displayedCount += 1
        }
        groupId += 1
    }

    if !PinnedPaths.Length && !FolderSettings.Length {
        InsertListGroup(groupId, "提示")
        AddPlaceholderTile("请先打开 config.ini 配置文件夹", groupId)
    }

    ApplyViewMode()
    FileView.Opt("+Redraw")
    status := "共显示 " displayedCount " 个文件"
    if unavailableCount
        status .= "；" unavailableCount " 个目录不可用"
    StatusText.Text := status "。缩略图由 Windows Shell 生成；双击打开，拖拽发送。"
}

InsertListGroup(groupId, header) {
    global FileView
    groupSize := A_PtrSize = 8 ? 152 : 96
    group := Buffer(groupSize, 0)
    NumPut("uint", groupSize, group, 0)
    NumPut("uint", 0x11, group, 4) ; LVGF_HEADER | LVGF_GROUPID
    NumPut("ptr", StrPtr(header), group, 8)
    NumPut("int", groupId, group, A_PtrSize = 8 ? 36 : 24)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x1091,
        "ptr", -1, "ptr", group.Ptr, "ptr") ; LVM_INSERTGROUPW
}

SetListItemGroup(row, groupId) {
    global FileView
    item := Buffer(A_PtrSize = 8 ? 88 : 60, 0)
    NumPut("uint", 0x100, item, 0) ; LVIF_GROUPID
    NumPut("int", row - 1, item, 4)
    NumPut("int", groupId, item, A_PtrSize = 8 ? 52 : 40)
    DllCall("user32\SendMessageW", "ptr", FileView.Hwnd, "uint", 0x104C,
        "ptr", 0, "ptr", item.Ptr, "ptr") ; LVM_SETITEMW
}

AddFileTile(path, label, modifiedText, groupId) {
    global FileView
    imageIndex := AddShellThumbnail(path)
    options := imageIndex ? "Icon" imageIndex : ""
    row := FileView.Add(options, label, modifiedText)
    SetListItemGroup(row, groupId)
    return row
}

AddPlaceholderTile(label, groupId) {
    global FileView
    row := FileView.Add("", label, "")
    SetListItemGroup(row, groupId)
    return row
}

AddShellThumbnail(path) {
    global ThumbnailSize, ThumbnailImageList
    factory := 0
    bitmap := 0
    try {
        iidImageFactory := GuidBuffer("{BCC18B79-BA16-442F-80C4-8A59C30C463B}")
        if DllCall("shell32\SHCreateItemFromParsingName", "wstr", path, "ptr", 0,
            "ptr", iidImageFactory.Ptr, "ptr*", &factory) = 0 {
            requestedSize := (ThumbnailSize & 0xFFFFFFFF) | (ThumbnailSize << 32)
            ; SIIGBF_CROPTOSQUARE keeps every bitmap compatible with the
            ; fixed-size image list while preserving Shell thumbnail quality.
            try ComCall(3, factory, "int64", requestedSize, "uint", 0x20,
                "ptr*", &bitmap)
        }
    } finally {
        if factory
            ObjRelease(factory)
    }

    if bitmap {
        imageIndex := DllCall("comctl32\ImageList_Add", "ptr", ThumbnailImageList,
            "ptr", bitmap, "ptr", 0, "int")
        DllCall("gdi32\DeleteObject", "ptr", bitmap)
        if imageIndex >= 0
            return imageIndex + 1
    }
    return AddShellFileIcon(path)
}

AddShellFileIcon(path) {
    global ThumbnailImageList
    infoSize := A_PtrSize = 8 ? 696 : 692
    info := Buffer(infoSize, 0)
    attributes := FileExist(path) ? 0 : 0x80 ; FILE_ATTRIBUTE_NORMAL
    flags := 0x100 ; SHGFI_ICON | SHGFI_LARGEICON
    if !FileExist(path)
        flags |= 0x10 ; SHGFI_USEFILEATTRIBUTES
    if !DllCall("shell32\SHGetFileInfoW", "wstr", path, "uint", attributes,
        "ptr", info.Ptr, "uint", infoSize, "uint", flags, "uptr")
        return 0
    icon := NumGet(info, 0, "ptr")
    if !icon
        return 0
    imageIndex := DllCall("comctl32\ImageList_ReplaceIcon", "ptr", ThumbnailImageList,
        "int", -1, "ptr", icon, "int")
    DllCall("user32\DestroyIcon", "ptr", icon)
    return imageIndex >= 0 ? imageIndex + 1 : 0
}

PopulateRecentSidebar() {
    global RecentView, RecentLabel, RecentItemPaths, ShowRecentSidebar, RecentFileCount
    RecentView.Opt("-Redraw")
    RecentView.Delete()
    RecentItemPaths := Map()
    if !ShowRecentSidebar {
        RecentView.Opt("+Redraw")
        return
    }

    recentFiles := GetWindowsRecentFiles(RecentFileCount)
    for file in recentFiles {
        row := RecentView.Add("", file.Name)
        RecentItemPaths[row] := file.Path
    }
    if !recentFiles.Length
        RecentView.Add("", "暂无系统近期记录")
    RecentLabel.Text := "最近打开  (" recentFiles.Length ")"
    RecentView.ModifyCol(1, 230)
    RecentView.Opt("+Redraw")
}

GetWindowsRecentFiles(limit) {
    recentDir := A_AppData "\Microsoft\Windows\Recent"
    links := []
    if !DirExist(recentDir)
        return links

    ; Keep extra shortcuts before resolving because stale Recent entries are
    ; common and should not consume visible slots.
    candidateLimit := Max(limit * 5, 60)
    try {
        Loop Files, recentDir "\*.lnk", "F" {
            candidate := {Path: A_LoopFileFullPath, Modified: A_LoopFileTimeModified}
            insertAt := 1
            while insertAt <= links.Length && links[insertAt].Modified >= candidate.Modified
                insertAt += 1
            links.InsertAt(insertAt, candidate)
            if links.Length > candidateLimit
                links.Pop()
        }
    }

    results := []
    seen := Map()
    try shell := ComObject("WScript.Shell")
    catch
        return results
    for link in links {
        try target := Trim(shell.CreateShortcut(link.Path).TargetPath)
        catch
            continue
        attributes := target != "" ? FileExist(target) : ""
        if !attributes || InStr(attributes, "D")
            continue
        key := StrLower(target)
        if seen.Has(key)
            continue
        seen[key] := true
        results.Push({Path: target, Name: GetFileName(target), Modified: link.Modified})
        if results.Length >= limit
            break
    }
    return results
}

GetLatestFiles(folderPath, limit, recursive) {
    files := []
    mode := recursive ? "FR" : "F"
    try {
        Loop Files, folderPath "\*", mode {
            candidate := {
                Path: A_LoopFileFullPath,
                Name: A_LoopFileName,
                Modified: A_LoopFileTimeModified
            }
            insertAt := 1
            while insertAt <= files.Length && files[insertAt].Modified >= candidate.Modified
                insertAt += 1
            files.InsertAt(insertAt, candidate)
            if files.Length > limit
                files.Pop()
        }
    }
    return files
}

GetFileName(path) {
    SplitPath(path, &name)
    return name != "" ? name : path
}

OpenFileViewItem(list, row) {
    global ItemPaths
    if !ItemPaths.Has(row)
        return
    OpenFilePath(ItemPaths[row])
}

OpenRecentItem(list, row) {
    global RecentItemPaths
    if RecentItemPaths.Has(row)
        OpenFilePath(RecentItemPaths[row])
}

OpenFilePath(path) {
    if !FileExist(path) {
        MsgBox("文件不存在或当前无法访问：`n" path, "无法打开", "Icon!")
        return
    }
    try Run(path)
    catch as err
        MsgBox("无法打开文件：`n" path "`n`n" err.Message, "打开失败", "Iconx")
}

RecentItemSelect(list, row, selected) {
    global RecentItemPaths, StatusText
    if selected && RecentItemPaths.Has(row)
        StatusText.Text := RecentItemPaths[row]
}

RecentContextMenu(list, row, isRightClick, x, y) {
    global RecentItemPaths
    if !row || !RecentItemPaths.Has(row)
        return
    list.Modify(row, "Select Focus Vis")
    path := RecentItemPaths[row]
    if !FileExist(path) {
        MsgBox("文件不存在或当前无法访问：`n" path, "右键菜单", "Icon!")
        return
    }
    ShowShellContextMenu(path, list.Gui.Hwnd, x, y)
}

FileViewItemSelect(list, row, selected) {
    ; A range or marquee selection emits several ItemSelect events. Defer the
    ; summary until the control has finished updating the full selection.
    SetTimer(UpdateSelectionStatus, -1)
}

UpdateSelectionStatus() {
    global FileView, ItemPaths, StatusText, SelectedFilePaths
    selectedRows := GetSelectedFileRows()
    SelectedFilePaths := []
    for row in selectedRows
        SelectedFilePaths.Push(ItemPaths[row])
    if selectedRows.Length = 1
        StatusText.Text := ItemPaths[selectedRows[1]]
    else if selectedRows.Length > 1
        StatusText.Text := "已选择 " selectedRows.Length " 个文件；可继续 Ctrl/Shift 选择。"
}

GetSelectedFileRows() {
    global FileView, ItemPaths
    rows := []
    row := 0
    while row := FileView.GetNext(row) {
        if ItemPaths.Has(row)
            rows.Push(row)
    }
    return rows
}

AddPinnedFiles(*) {
    global PinnedPaths
    try selected := FileSelect("M3", , "选择要固定显示的文件")
    catch
        return
    if !IsObject(selected)
        return

    added := 0
    for path in selected {
        path := NormalizePath(path)
        if path != "" && !ArrayContainsPath(PinnedPaths, path) {
            PinnedPaths.Push(path)
            added += 1
        }
    }
    if added {
        SavePinnedFiles()
        PopulatePanel()
    }
}

RemovePinnedFile(*) {
    global FileView, ItemPaths, PinnedPaths
    rows := GetSelectedFileRows()
    if !rows.Length {
        MsgBox("请先在“固定文件”分组中选择一个或多个文件。", "取消固定", "Iconi")
        return
    }

    indexes := []
    for row in rows {
        index := FindPathIndex(PinnedPaths, ItemPaths[row])
        if index
            indexes.Push(index)
    }
    if !indexes.Length {
        MsgBox("选择的文件中没有固定文件。", "取消固定", "Iconi")
        return
    }
    ; Remove from the end so earlier array indexes remain valid.
    Loop indexes.Length {
        largestPosition := 1
        for position, index in indexes {
            if index > indexes[largestPosition]
                largestPosition := position
        }
        PinnedPaths.RemoveAt(indexes[largestPosition])
        indexes.RemoveAt(largestPosition)
    }
    SavePinnedFiles()
    PopulatePanel()
}

SavePinnedFiles() {
    global ConfigPath, PinnedPaths
    try IniDelete(ConfigPath, "PinnedFiles")
    for index, path in PinnedPaths
        IniWrite(path, ConfigPath, "PinnedFiles", "File" Format("{:03}", index))
}

ArrayContainsPath(paths, target) {
    return FindPathIndex(paths, target) != 0
}

FindPathIndex(paths, target) {
    target := StrLower(RTrim(target, "\"))
    for index, path in paths {
        if StrLower(RTrim(path, "\")) = target
            return index
    }
    return 0
}

OpenConfig(*) {
    global ConfigPath
    try Run('notepad.exe "' ConfigPath '"')
    catch
        Run(ConfigPath)
}

FileViewContextMenu(list, row, isRightClick, x, y) {
    global ItemPaths
    if !row || !ItemPaths.Has(row)
        return
    list.Modify(row, "Select Focus Vis")
    path := ItemPaths[row]
    if !FileExist(path) {
        MsgBox("文件不存在或当前无法访问：`n" path, "右键菜单", "Icon!")
        return
    }
    ShowShellContextMenu(path, list.Gui.Hwnd, x, y)
}

ShowShellContextMenu(path, ownerHwnd, x, y) {
    pidl := 0
    parentFolder := 0
    contextMenu := 0
    menuHandle := 0
    try {
        if DllCall("shell32\SHParseDisplayName", "wstr", path, "ptr", 0, "ptr*", &pidl,
            "uint", 0, "ptr", 0) != 0
            throw Error("Windows Shell 无法解析此文件。")

        iidShellFolder := GuidBuffer("{000214E6-0000-0000-C000-000000000046}")
        childPidl := 0
        if DllCall("shell32\SHBindToParent", "ptr", pidl, "ptr", iidShellFolder.Ptr,
            "ptr*", &parentFolder, "ptr*", &childPidl) != 0
            throw Error("无法连接文件所在目录。")

        iidContextMenu := GuidBuffer("{000214E4-0000-0000-C000-000000000046}")
        childArray := Buffer(A_PtrSize, 0)
        NumPut("ptr", childPidl, childArray)
        hr := ComCall(10, parentFolder, "ptr", ownerHwnd, "uint", 1, "ptr", childArray.Ptr,
            "ptr", iidContextMenu.Ptr, "ptr", 0, "ptr*", &contextMenu)
        if hr != 0
            throw Error("无法创建系统文件菜单。")

        menuHandle := DllCall("user32\CreatePopupMenu", "ptr")
        ; CMF_EXPLORE | CMF_EXTENDEDVERBS | CMF_SYNCCASCADEMENU exposes the
        ; complete classic menu and asks extensions to build cascades now.
        hr := ComCall(3, contextMenu, "ptr", menuHandle, "uint", 0, "uint", 1,
            "uint", 0x7FFF, "uint", 0x1104)
        if hr < 0
            throw Error("系统文件菜单加载失败。")

        if x = -1 || y = -1 {
            point := Buffer(8, 0)
            DllCall("user32\GetCursorPos", "ptr", point)
            x := NumGet(point, 0, "int")
            y := NumGet(point, 4, "int")
        } else {
            ; AutoHotkey supplies GUI-client coordinates; TrackPopupMenuEx
            ; requires screen coordinates.
            point := Buffer(8, 0)
            NumPut("int", x, point, 0)
            NumPut("int", y, point, 4)
            DllCall("user32\ClientToScreen", "ptr", ownerHwnd, "ptr", point)
            x := NumGet(point, 0, "int")
            y := NumGet(point, 4, "int")
        }
        DllCall("user32\SetForegroundWindow", "ptr", ownerHwnd)
        command := DllCall("user32\TrackPopupMenuEx", "ptr", menuHandle,
            "uint", 0x0102, "int", x, "int", y, "ptr", ownerHwnd, "ptr", 0, "uint")
        if command {
            ciSize := A_PtrSize = 8 ? 56 : 36
            invokeInfo := Buffer(ciSize, 0)
            NumPut("uint", ciSize, invokeInfo, 0)
            NumPut("ptr", ownerHwnd, invokeInfo, 8)
            NumPut("ptr", command - 1, invokeInfo, A_PtrSize = 8 ? 16 : 12)
            NumPut("int", 1, invokeInfo, A_PtrSize = 8 ? 40 : 24) ; SW_SHOWNORMAL
            ComCall(4, contextMenu, "ptr", invokeInfo.Ptr)
        }
        DllCall("user32\PostMessageW", "ptr", ownerHwnd, "uint", 0, "ptr", 0, "ptr", 0)
    } catch as err {
        MsgBox("无法显示系统右键菜单：`n" err.Message, "右键菜单", "Iconx")
    } finally {
        if menuHandle
            DllCall("user32\DestroyMenu", "ptr", menuHandle)
        if contextMenu
            ObjRelease(contextMenu)
        if parentFolder
            ObjRelease(parentFolder)
        if pidl
            DllCall("ole32\CoTaskMemFree", "ptr", pidl)
    }
}

GuidBuffer(text) {
    guid := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", text, "ptr", guid.Ptr) != 0
        throw Error("GUID 解析失败：" text)
    return guid
}

FileViewLeftButtonDown(wParam, lParam, msg, hwnd) {
    global FileView, RecentView, ItemPaths, RecentItemPaths
    global DragPaths, SelectedFilePaths, DragSourceHwnd, DragStartX, DragStartY, DragStarted
    isMainView := IsObject(FileView) && hwnd = FileView.Hwnd
    if isMainView
        pathMap := ItemPaths
    else if IsObject(RecentView) && hwnd = RecentView.Hwnd
        pathMap := RecentItemPaths
    else
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    hitInfo := Buffer(24, 0)
    NumPut("int", x, hitInfo, 0)
    NumPut("int", y, hitInfo, 4)
    zeroBasedRow := DllCall("user32\SendMessageW", "ptr", hwnd,
        "uint", 0x1012, "ptr", 0, "ptr", hitInfo.Ptr, "int") ; LVM_HITTEST
    row := zeroBasedRow >= 0 ? zeroBasedRow + 1 : 0
    DragPaths := []
    if row && pathMap.Has(row) {
        ; WM_LBUTTONDOWN can collapse a multi-selection before a drag reaches
        ; its movement threshold. Use the snapshot saved after the preceding
        ; Ctrl/Shift/marquee selection instead of querying the live control.
        if isMainView && ArrayContainsPath(SelectedFilePaths, pathMap[row]) {
            DragPaths := SelectedFilePaths.Clone()
        } else {
            DragPaths.Push(pathMap[row])
        }
    }
    DragSourceHwnd := hwnd
    DragStartX := x
    DragStartY := y
    DragStarted := false
}

FileViewMouseMove(wParam, lParam, msg, hwnd) {
    global DragPaths, DragSourceHwnd, DragStartX, DragStartY, DragStarted, StatusText
    if !DragPaths.Length || DragStarted || hwnd != DragSourceHwnd || !GetKeyState("LButton", "P")
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    thresholdX := DllCall("user32\GetSystemMetrics", "int", 68, "int") ; SM_CXDRAG
    thresholdY := DllCall("user32\GetSystemMetrics", "int", 69, "int") ; SM_CYDRAG
    if Abs(x - DragStartX) < thresholdX && Abs(y - DragStartY) < thresholdY
        return

    DragStarted := true
    paths := DragPaths
    DragPaths := []
    existingPaths := []
    for path in paths {
        if FileExist(path) && !ArrayContainsPath(existingPaths, path)
            existingPaths.Push(path)
    }
    if existingPaths.Length {
        StatusText.Text := "本次拖拽包含 " existingPaths.Length " 个文件。"
        DllCall("user32\UpdateWindow", "ptr", StatusText.Hwnd)
        BeginShellDrag(existingPaths, DragSourceHwnd)
    }
}

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

BeginShellDrag(paths, ownerHwnd) {
    if paths.Length = 1
        BeginSingleShellDrag(paths[1], ownerHwnd)
    else
        BeginMultiShellDrag(paths, ownerHwnd)
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

Cleanup(*) {
    global DropCallbacks, DataCallbacks, ThumbnailImageList
    for callbackPtr in DropCallbacks
        CallbackFree(callbackPtr)
    for callbackPtr in DataCallbacks
        CallbackFree(callbackPtr)
    if ThumbnailImageList
        DllCall("comctl32\ImageList_Destroy", "ptr", ThumbnailImageList)
    DllCall("ole32\OleUninitialize")
}
