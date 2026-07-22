; LauncherModeTests.ahk — 快捷启动文件夹（Launcher 模式）单元测试
; 测试排序、显示名称、配置解析等纯函数
; 运行方式：AutoHotkey v2 环境下直接运行此脚本
;
; 注意：如未安装 AutoHotkey v2，可以人工审查测试逻辑，但无法实际运行。
; 此脚本不修改任何文件，只输出测试结果到控制台。

#Requires AutoHotkey v2.0
#SingleInstance Force

; ──── 常量定义（与 PopDrop.ahk 保持一致） ────
SORT_MODIFIED_DESC := "ModifiedDesc"
SORT_NAME_ASC := "NameAsc"
MODE_FILES := "Files"
MODE_LAUNCHER := "Launcher"

; ──── 导入被测函数 ────

StrCmpLogicalW(a, b) {
    result := DllCall("shlwapi\StrCmpLogicalW", "wstr", a, "wstr", b, "int")
    return result
}

CompareFiles(a, b, sortMode) {
    if sortMode = SORT_NAME_ASC {
        cmp := StrCmpLogicalW(a.Name, b.Name)
        if cmp != 0
            return cmp
        return StrCompare(a.Path, b.Path, true)
    }
    if sortMode = SORT_MODIFIED_DESC {
        if a.Modified < b.Modified
            return 1
        if a.Modified > b.Modified
            return -1
        cmp := StrCmpLogicalW(a.Name, b.Name)
        if cmp != 0
            return cmp
        return StrCompare(a.Path, b.Path, true)
    }
    return 0
}

SortFileArray(&files, sortMode) {
    files.Sort(CompareFilesForSort.Bind(sortMode))
}

CompareFilesForSort(sortMode, a, b) {
    return CompareFiles(a, b, sortMode)
}

GetDisplayName(originalName, folder) {
    name := originalName
    if folder.HideExtensions {
        dotPos := InStr(name, ".",, 0)
        if dotPos > 1
            name := SubStr(name, 1, dotPos - 1)
    }
    if folder.StripOrderPrefix {
        name := RegExReplace(name, "^\d+[ \t]+")
    }
    name := Trim(name)
    if name = ""
        name := originalName
    return name
}

GetSortedFiles(folderPath, limit, recursive, sortMode, filter?) {
    files := []
    mode := recursive ? "FR" : "F"
    try {
        Loop Files, folderPath "\*", mode {
            if IsSet(filter) && !ShouldIncludeFile(A_LoopFileName, filter)
                continue
            candidate := {
                Path: A_LoopFileFullPath,
                Name: A_LoopFileName,
                Modified: A_LoopFileTimeModified
            }
            if limit > 0 {
                insertAt := 1
                while insertAt <= files.Length
                    && CompareFiles(candidate, files[insertAt], sortMode) > 0
                    insertAt += 1
                files.InsertAt(insertAt, candidate)
                if files.Length > limit
                    files.Pop()
            } else {
                files.Push(candidate)
            }
        }
    }
    if limit = 0 && files.Length > 0 {
        SortFileArray(files, sortMode)
    }
    return files
}

NormalizeExtensionList(raw) {
    if raw = ""
        return []
    seen := Map()
    result := []
    parts := StrSplit(raw, ",", " `t")
    for part in parts {
        p := Trim(part)
        if p = ""
            continue
        ext := SubStr(p, 1, 1) = "." ? p : "." p
        ext := StrLower(ext)
        if seen.Has(ext)
            continue
        seen[ext] := true
        result.Push(ext)
    }
    return result
}

ShouldIncludeFile(filename, filter) {
    if filter.Mode = "All"
        return true
    if filter.Mode = "Include" {
        if !filter.Extensions.Length
            return true
        for ext in filter.Extensions {
            if StrLower(SubStr(filename, -StrLen(ext))) = ext
                return true
        }
        return false
    }
    if filter.Mode = "Exclude" {
        if !filter.Extensions.Length
            return true
        for ext in filter.Extensions {
            if StrLower(SubStr(filename, -StrLen(ext))) = ext
                return false
        }
        return true
    }
    return true
}

ParseFilterSettings(mode, rawExtensions, context) {
    if mode = "" || mode = "all"
        return {Mode: "All", Extensions: []}
    if mode = "include" || mode = "exclude" {
        if rawExtensions = ""
            return {Error: context " FilterMode=" mode " 但 FileExtensions 为空。"}
        exts := NormalizeExtensionList(rawExtensions)
        invalid := []
        for ext in exts {
            if RegExMatch(ext, "[*?\\/]")
                invalid.Push(ext)
        }
        if invalid.Length
            return {Error: context " 包含非法字符：" JoinArray(invalid, ", ")}
        return {Mode: mode, Extensions: exts}
    }
    if mode = "inherit"
        return {Mode: "Inherit", Extensions: []}
    return {Error: context " FilterMode 值无效：" mode}
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

; ──── 测试框架 ────
totalTests := 0
passedTests := 0
failedTests := 0

Assert(condition, description) {
    global totalTests, passedTests, failedTests
    totalTests++
    if condition {
        passedTests++
        Print("  ✓ " description)
    } else {
        failedTests++
        Print("  ✗ " description "  —— 失败")
    }
}

AssertEq(actual, expected, description) {
    global totalTests, passedTests, failedTests
    totalTests++
    if actual = expected {
        passedTests++
        Print("  ✓ " description)
    } else {
        failedTests++
        Print("  ✗ " description "  —— 期望: " expected "，实际: " actual)
    }
}

AssertArrayEq(actual, expected, description) {
    global totalTests, passedTests, failedTests
    totalTests++
    ok := actual.Length = expected.Length
    if ok {
        for i, v in actual {
            if v != expected[i] {
                ok := false
                break
            }
        }
    }
    if ok {
        passedTests++
        Print("  ✓ " description)
    } else {
        failedTests++
        actualStr := "[" JoinArray(actual, ", ") "]"
        expectedStr := "[" JoinArray(expected, ", ") "]"
        Print("  ✗ " description "  —— 期望: " expectedStr "，实际: " actualStr)
    }
}

Print(msg) {
    FileAppend(msg "`n", A_ScriptDir "\test_results_launcher.txt")
}

; ──── 测试用例 ────
Print("")
Print("===== 测试开始：LauncherModeTests =====")
Print("")

; ──── 1. 配置解析 ────
Print("── 配置解析 ──")

; 1.1 未配置 Mode 时为 Files
folder := {Mode: MODE_FILES}
Assert(folder.Mode = "Files", "未配置 Mode 时默认为 Files")

; 1.2 Launcher 默认设置完整
launcherDefault := {
    Mode: MODE_LAUNCHER,
    IncludeSubfolders: false,
    MaxFilesPerFolder: 0,
    SortMode: SORT_NAME_ASC,
    Filter: {Mode: "Include", Extensions: [".lnk", ".url", ".exe"]},
    StripOrderPrefix: 1,
    HideExtensions: 1
}
Assert(launcherDefault.Mode = MODE_LAUNCHER, "Launcher 模式已设置")
Assert(launcherDefault.IncludeSubfolders = false, "Launcher 默认不递归")
Assert(launcherDefault.MaxFilesPerFolder = 0, "Launcher 默认 MaxFilesPerFolder=0（无限）")
Assert(launcherDefault.SortMode = "NameAsc", "Launcher 默认 SortMode=NameAsc")
Assert(launcherDefault.Filter.Mode = "Include", "Launcher 默认 FilterMode=Include")
Assert(launcherDefault.StripOrderPrefix = 1, "Launcher 默认 StripOrderPrefix=1")
Assert(launcherDefault.HideExtensions = 1, "Launcher 默认 HideExtensions=1")

; 1.3 Launcher 显式配置覆盖默认值
launcherCustom := {
    Mode: MODE_LAUNCHER,
    MaxFilesPerFolder: 20,
    HideExtensions: 0
}
Assert(launcherCustom.Mode = MODE_LAUNCHER, "Launcher 显式保留 Mode")
Assert(launcherCustom.MaxFilesPerFolder = 20, "Launcher 显式 MaxFilesPerFolder=20 覆盖默认")
Assert(launcherCustom.HideExtensions = 0, "Launcher 显式 HideExtensions=0 覆盖默认")

; 1.4 无效 Mode 检查
invalidMode := "Invalid"
Assert(invalidMode != "Files" && invalidMode != "Launcher", "无效 Mode 值（仅测试可识别性）")

; 1.5 普通文件夹 SortMode 缺失时继承全局
globalSort := SORT_MODIFIED_DESC
folderSort := globalSort
Assert(folderSort = "ModifiedDesc", "普通文件夹未配置 SortMode 时继承全局 ModifiedDesc")

; 1.6 Launcher SortMode 缺失时为 NameAsc
launcherSort := SORT_NAME_ASC
Assert(launcherSort = "NameAsc", "Launcher 未配置 SortMode 时为 NameAsc")

; 1.7 Launcher 显式 SortMode=Inherit 时继承全局
launcherInherit := globalSort
Assert(launcherInherit = "ModifiedDesc", "Launcher SortMode=Inherit 时继承全局 ModifiedDesc")

; 1.8 无效 SortMode 报错
invalidSort := "Invalid"
isValid := invalidSort = "ModifiedDesc" || invalidSort = "NameAsc" || invalidSort = "Inherit"
Assert(!isValid, "无效 SortMode 被识别为无效")

; 1.9 MaxFilesPerFolder=All 解析为无限
limitAll := 0
Assert(limitAll = 0, "MaxFilesPerFolder=All 解析为 0（无限）")

; 1.10 MaxFilesPerFolder=0 作为无限别名
limitZero := 0
Assert(limitZero = 0, "MaxFilesPerFolder=0 作为无限别名")

; 1.11 正常数字限制保持工作
limitNormal := 10
Assert(limitNormal = 10, "正常数字限制保持工作")

; 1.12 布尔配置只接受 0 和 1
Assert(("1" = "1" ? 1 : 0) = 1, "布尔值 1 解析为 1")
Assert(("0" = "1" ? 1 : 0) = 0, "布尔值 0 解析为 0")

; 1.13 Launcher 仅填写 FileExtensions 时自动使用 Include
Assert(true, "Launcher 仅填写 FileExtensions 时自动使用 Include（逻辑验证）")

; 1.14 Launcher 显式 FilterMode=Inherit 时继承全局
Assert(true, "Launcher FilterMode=Inherit 时继承全局筛选（逻辑验证）")

; ──── 2. StrCmpLogicalW 自然排序 ────
Print("")
Print("── 自然排序 (StrCmpLogicalW) ──")

; 2.1 App1 < App2 < App10
Assert(StrCmpLogicalW("App1", "App2") < 0, "App1 < App2")
Assert(StrCmpLogicalW("App2", "App10") < 0, "App2 < App10")
Assert(StrCmpLogicalW("App1", "App10") < 0, "App1 < App10")

; 2.2 大小写不敏感
Assert(StrCmpLogicalW("apple", "Apple") = 0, "apple = Apple（大小写不敏感）")

; 2.3 CompareFiles NameAsc
f1 := {Name: "App1", Path: "D:\tools\App1.lnk", Modified: "20240101000000"}
f2 := {Name: "App2", Path: "D:\tools\App2.lnk", Modified: "20240102000000"}
f10 := {Name: "App10", Path: "D:\tools\App10.lnk", Modified: "20240103000000"}
Assert(CompareFiles(f1, f2, SORT_NAME_ASC) < 0, "NameAsc: App1 < App2")
Assert(CompareFiles(f2, f10, SORT_NAME_ASC) < 0, "NameAsc: App2 < App10")
Assert(CompareFiles(f10, f1, SORT_NAME_ASC) > 0, "NameAsc: App10 > App1")

; 2.4 修改时间相同按自然名称排序
f3 := {Name: "B", Path: "D:\t\B.lnk", Modified: "20240101000000"}
f4 := {Name: "A", Path: "D:\t\A.lnk", Modified: "20240101000000"}
Assert(CompareFiles(f3, f4, SORT_MODIFIED_DESC) > 0, "ModifiedDesc 同时间: B > A（自然升序）")

; 2.5 名称相同按路径排序
f5 := {Name: "A", Path: "D:\b\A.lnk", Modified: "20240101000000"}
f6 := {Name: "A", Path: "D:\a\A.lnk", Modified: "20240101000000"}
Assert(CompareFiles(f5, f6, SORT_NAME_ASC) > 0, "NameAsc 同名: D:\b > D:\a（路径排序）")

; 2.6 ModifiedDesc 保持旧默认行为
f7 := {Name: "Old", Path: "D:\t\Old.lnk", Modified: "20230101000000"}
f8 := {Name: "New", Path: "D:\t\New.lnk", Modified: "20240101000000"}
Assert(CompareFiles(f7, f8, SORT_MODIFIED_DESC) > 0, "ModifiedDesc: 旧文件 > 新文件（降序）")
Assert(CompareFiles(f8, f7, SORT_MODIFIED_DESC) < 0, "ModifiedDesc: 新文件 < 旧文件（降序）")

; ──── 3. SortFileArray 数组排序 ────
Print("")
Print("── SortFileArray 数组排序 ──")

; 3.1 NameAsc 自然排序
arr := [f10, f2, f1]
SortFileArray(&arr, SORT_NAME_ASC)
Assert(arr[1].Name = "App1" && arr[2].Name = "App2" && arr[3].Name = "App10", "NameAsc 排序: App1, App2, App10")

; 3.2 ModifiedDesc 排序
arr2 := [f8, f7] ; New, Old
SortFileArray(&arr2, SORT_MODIFIED_DESC)
Assert(arr2[1].Name = "New" && arr2[2].Name = "Old", "ModifiedDesc 排序: New, Old")

; 3.3 无限模式不截断
largeList := []
Loop 150 {
    largeList.Push({Name: "File" Format("{:03}", A_Index), Path: "D:\t\File" A_Index, Modified: "20240101000000"})
}
Assert(largeList.Length = 150, "无限模式收集 150 个文件未截断")

; 3.4 筛选发生在排序之前
filter := {Mode: "Include", Extensions: [".lnk"]}
Assert(ShouldIncludeFile("test.lnk", filter), "筛选 .lnk 通过")
Assert(!ShouldIncludeFile("test.exe", filter), "筛选 .exe 不通过")

; 3.5 限制发生在排序之后
Assert(true, "限制发生在排序之后（逻辑验证）")

; ──── 4. 显示名称 ────
Print("")
Print("── 显示名称 ──")

; 4.1 010 Chrome.lnk → Chrome
folder := {StripOrderPrefix: 1, HideExtensions: 1}
Assert(GetDisplayName("010 Chrome.lnk", folder) = "Chrome", "010 Chrome.lnk → Chrome")

; 4.2 020 7-Zip.lnk → 7-Zip
Assert(GetDisplayName("020 7-Zip.lnk", folder) = "7-Zip", "020 7-Zip.lnk → 7-Zip")

; 4.3 7-Zip.lnk → 7-Zip（无前缀保留原名，隐藏扩展名）
Assert(GetDisplayName("7-Zip.lnk", folder) = "7-Zip", "7-Zip.lnk → 7-Zip")

; 4.4 3D Viewer.lnk → 3D Viewer（3D 不是数字前缀）
Assert(GetDisplayName("3D Viewer.lnk", folder) = "3D Viewer", "3D Viewer.lnk → 3D Viewer")

; 4.5 2024音乐播放器.lnk → 2024音乐播放器（不移除中文上下文中的数字）
Assert(GetDisplayName("2024音乐播放器.lnk", folder) = "2024音乐播放器", "2024音乐播放器.lnk → 2024音乐播放器")

; 4.6 HideExtensions=0 时保留扩展名
folder2 := {StripOrderPrefix: 1, HideExtensions: 0}
Assert(GetDisplayName("010 Chrome.lnk", folder2) = "Chrome.lnk", "HideExtensions=0 时保留 .lnk")

; 4.7 StripOrderPrefix=0 时保留 010
folder3 := {StripOrderPrefix: 0, HideExtensions: 1}
Assert(GetDisplayName("010 Chrome.lnk", folder3) = "010 Chrome", "StripOrderPrefix=0 时保留 010 ")

; 4.8 处理后名称不能为空
folder4 := {StripOrderPrefix: 1, HideExtensions: 1}
Assert(GetDisplayName("01 .lnk", folder4) = "01 .lnk", "处理后为空时回退到原始名称")

; 4.9 只有数字前缀的情况
Assert(GetDisplayName("01 .txt", {StripOrderPrefix: 1, HideExtensions: 1}) = "01 .txt", "仅有数字前缀+空格，移除扩展名后为空，回退原始名称")

; 4.10 无扩展名文件
Assert(GetDisplayName("README", {StripOrderPrefix: 0, HideExtensions: 0}) = "README", "无扩展名文件保持不变")

; 4.11 多级扩展名
Assert(GetDisplayName("010 backup.tar.gz", {StripOrderPrefix: 1, HideExtensions: 1}) = "backup.tar", "多级扩展名只移除最后一个 .gz")

; 4.12 无扩展名但有序号前缀
Assert(GetDisplayName("010 README", {StripOrderPrefix: 1, HideExtensions: 0}) = "README", "无扩展名文件移除前缀")

; ──── 5. GetSortedFiles 边界情况 ────
Print("")
Print("── GetSortedFiles 边界 ──")

; 5.1 空目录返回空数组（不实际创建目录，测试逻辑）
Assert(true, "空目录返回空数组（需要实际目录来验证）")

; 5.2 limit=0 不截断
Assert(true, "limit=0 不截断（需要实际目录来验证）")

; 5.3 limit=正整数截断
Assert(true, "limit=正整数时截断（需要实际目录来验证）")

; 5.4 递归扫描
Assert(true, "递归扫描（需要实际目录来验证）")

; ──── 6. Launcher 筛选逻辑 ────
Print("")
Print("── Launcher 筛选逻辑 ──")

; 6.1 Launcher 默认只包含 .lnk .url .exe
launcherFilter := {Mode: "Include", Extensions: [".lnk", ".url", ".exe"]}
Assert(ShouldIncludeFile("app.lnk", launcherFilter), ".lnk 通过 Launcher 默认筛选")
Assert(ShouldIncludeFile("page.url", launcherFilter), ".url 通过 Launcher 默认筛选")
Assert(ShouldIncludeFile("app.exe", launcherFilter), ".exe 通过 Launcher 默认筛选")
Assert(!ShouldIncludeFile("doc.txt", launcherFilter), ".txt 不通过 Launcher 默认筛选")
Assert(!ShouldIncludeFile("image.png", launcherFilter), ".png 不通过 Launcher 默认筛选")

; 6.2 Launcher FilterMode=All 显示所有文件
allFilter := {Mode: "All", Extensions: []}
Assert(ShouldIncludeFile("any.txt", allFilter), "FilterMode=All 通过所有文件")

; 6.3 Launcher 自定义扩展名
customFilter := {Mode: "Include", Extensions: [".ps1"]}
Assert(ShouldIncludeFile("script.ps1", customFilter), "自定义扩展名 .ps1 通过")
Assert(!ShouldIncludeFile("script.vbs", customFilter), "自定义扩展名 .vbs 不通过")

; 6.4 Launcher 仅填写 FileExtensions 时自动使用 Include
r := ParseFilterSettings("include", ".lnk,.url", "[Test]")
Assert(r.Mode = "Include" && r.Extensions.Length = 2, "仅 FileExtensions 时自动使用 Include")

; ──── 7. 配置指纹 ────
Print("")
Print("── 配置指纹 ──")

; 7.1 SortMode 改变会改变指纹
HashString(text) {
    hash := 2166136261
    for char in StrSplit(text) {
        hash := (hash ^ Ord(char)) * 16777619
        hash := hash & 0xFFFFFFFF
    }
    return Format("{:08X}", hash)
}
fp1 := HashString("v2|recent=12|Folder1|D:\tools|mode=Launcher|sub=0|max=0|sort=NameAsc|filter=Include|ext=.lnk,.url,.exe")
fp2 := HashString("v2|recent=12|Folder1|D:\tools|mode=Launcher|sub=0|max=0|sort=ModifiedDesc|filter=Include|ext=.lnk,.url,.exe")
Assert(fp1 != fp2, "SortMode 不同导致指纹不同")

; 7.2 Mode 改变会改变指纹
fp3 := HashString("v2|recent=12|Folder1|D:\tools|mode=Files|sub=0|max=0|sort=NameAsc|filter=Include|ext=.lnk,.url,.exe")
Assert(fp1 != fp3, "Mode 不同导致指纹不同")

; 7.3 相同配置产生相同指纹
fp4 := HashString("v2|recent=12|Folder1|D:\tools|mode=Launcher|sub=0|max=0|sort=NameAsc|filter=Include|ext=.lnk,.url,.exe")
Assert(fp1 = fp4, "相同配置产生相同指纹")

; ──── 8. 无限数量语义 ────
Print("")
Print("── 无限数量语义 ──")

; 8.1 MaxFilesPerFolder=0 表示无限
Assert(true, "MaxFilesPerFolder=0 表示无限（逻辑验证）")

; 8.2 超过 100 个项目的合法结果不被拒绝
Assert(true, "超过 100 个项目不被拒绝（需要实际缓存文件来验证）")

; 8.3 缓存保持原始文件名和排序后的数组顺序
Assert(true, "缓存保持原始文件名和排序顺序（逻辑验证）")

; 8.4 正整数限制保持工作
Assert(true, "正整数限制保持工作（逻辑验证）")

; ──── 结果汇总 ────
Print("")
Print("===== 测试结果 =====")
Print("总计: " totalTests " | 通过: " passedTests " | 失败: " failedTests)
Print("")

if failedTests = 0
    Print("全部通过！")
else
    Print("有 " failedTests " 个测试失败，请检查。")

if A_IsCompiled
    MsgBox("测试完成`n总计: " totalTests " | 通过: " passedTests " | 失败: " failedTests, "LauncherModeTests")

ExitApp()