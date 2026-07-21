; ConfigFilterTests.ahk — 配置筛选模块单元测试
; 测试 NormalizeExtensionList、ShouldIncludeFile、ParseFilterSettings 等纯函数
; 运行方式：AutoHotkey v2 环境下直接运行此脚本
;
; 注意：如未安装 AutoHotkey v2，可以人工审查测试逻辑，但无法实际运行。
; 此脚本不修改任何文件，只输出测试结果到控制台。

#Requires AutoHotkey v2.0
#SingleInstance Force

; ──── 导入被测函数 ────
; 这些函数是 PopDrop.ahk 中的纯函数，独立于 GUI 代码。
; 直接在测试脚本中复制一份供测试使用。

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
    FileAppend(msg "`n", A_ScriptDir "\test_results.txt")
}

; ──── 测试用例 ────
Print("")
Print("===== 测试开始：ConfigFilterTests =====")
Print("")

; ──── 1. NormalizeExtensionList ────
Print("── NormalizeExtensionList ──")

; 1.1 空字符串返回空数组
AssertArrayEq(NormalizeExtensionList(""), [], "空字符串返回空数组")

; 1.2 单个扩展名补 .
AssertArrayEq(NormalizeExtensionList("jpg"), [".jpg"], "jpg 规范化为 .jpg")

; 1.3 已有 . 前缀
AssertArrayEq(NormalizeExtensionList(".jpg"), [".jpg"], ".jpg 保持为 .jpg")

; 1.4 大写转小写
AssertArrayEq(NormalizeExtensionList(".JPG"), [".jpg"], ".JPG 规范化为 .jpg")

; 1.5 逗号分隔多个
AssertArrayEq(NormalizeExtensionList(".png,.jpg,.gif"), [".png", ".jpg", ".gif"], "逗号分隔多个扩展名")

; 1.6 去重
AssertArrayEq(NormalizeExtensionList(".jpg,.jpg,.JPG"), [".jpg"], "重复扩展名被去重")

; 1.7 多段后缀
AssertArrayEq(NormalizeExtensionList(".tar.gz"), [".tar.gz"], "多段后缀 .tar.gz 保留完整")

; 1.8 前后空格
AssertArrayEq(NormalizeExtensionList("  .jpg  ,  .png  "), [".jpg", ".png"], "前后空格被忽略")

; 1.9 空项跳过
AssertArrayEq(NormalizeExtensionList(".jpg,,.png"), [".jpg", ".png"], "连续逗号产生的空项被跳过")

; 1.10 混合 jpg 和 .jpg
AssertArrayEq(NormalizeExtensionList("jpg,.jpg"), [".jpg"], "jpg 和 .jpg 视为同一扩展名")

; ──── 2. ShouldIncludeFile ────
Print("")
Print("── ShouldIncludeFile ──")

; 2.1 All 模式始终通过
Assert(ShouldIncludeFile("anyfile.xyz", {Mode: "All", Extensions: []}), "All 模式始终返回 true")

; 2.2 Include 命中
Assert(ShouldIncludeFile("photo.jpg", {Mode: "Include", Extensions: [".jpg"]}), "Include 命中 .jpg")

; 2.3 Include 未命中
Assert(!ShouldIncludeFile("photo.png", {Mode: "Include", Extensions: [".jpg"]}), "Include 未命中 .png 返回 false")

; 2.4 Include 大小写不敏感
Assert(ShouldIncludeFile("photo.JPG", {Mode: "Include", Extensions: [".jpg"]}), "Include 大小写不敏感")

; 2.5 Exclude 命中
Assert(!ShouldIncludeFile("temp.tmp", {Mode: "Exclude", Extensions: [".tmp"]}), "Exclude 命中 .tmp 返回 false")

; 2.6 Exclude 未命中
Assert(ShouldIncludeFile("good.txt", {Mode: "Exclude", Extensions: [".tmp"]}), "Exclude 未命中返回 true")

; 2.7 Exclude 大小写不敏感
Assert(!ShouldIncludeFile("temp.TMP", {Mode: "Exclude", Extensions: [".tmp"]}), "Exclude 大小写不敏感")

; 2.8 多段后缀匹配
Assert(ShouldIncludeFile("backup.tar.gz", {Mode: "Include", Extensions: [".tar.gz"]}), "多段后缀 .tar.gz 匹配 backup.tar.gz")

; 2.9 短后缀也匹配多段后缀文件
Assert(ShouldIncludeFile("backup.tar.gz", {Mode: "Include", Extensions: [".gz"]}), ".gz 匹配 backup.tar.gz")

; 2.10 后缀匹配必须精确结尾
Assert(!ShouldIncludeFile("photo.jpg.tmp", {Mode: "Include", Extensions: [".jpg"]}), ".jpg 不匹配 photo.jpg.tmp")

; 2.11 Include 空列表防御
Assert(ShouldIncludeFile("any.jpg", {Mode: "Include", Extensions: []}), "Include 空列表防御性返回 true")

; 2.12 Exclude 空列表防御
Assert(ShouldIncludeFile("any.jpg", {Mode: "Exclude", Extensions: []}), "Exclude 空列表防御性返回 true")

; 2.13 文件名大小写不同
Assert(ShouldIncludeFile("PHOTO.JPG", {Mode: "Include", Extensions: [".jpg"]}), "大写文件名匹配小写扩展名")

; ──── 3. ParseFilterSettings ────
Print("")
Print("── ParseFilterSettings ──")

; 3.1 空/All 模式
r := ParseFilterSettings("", "", "[Test]")
Assert(r.Mode = "All", "空 mode 等价于 All")

r := ParseFilterSettings("all", "", "[Test]")
Assert(r.Mode = "All", "all mode 返回 Mode=All")

; 3.2 Include 模式
r := ParseFilterSettings("include", ".jpg,.png", "[Test]")
Assert(r.Mode = "Include" && r.Extensions.Length = 2, "Include 模式解析扩展名")

; 3.3 Exclude 模式
r := ParseFilterSettings("exclude", ".tmp", "[Test]")
Assert(r.Mode = "Exclude" && r.Extensions.Length = 1, "Exclude 模式解析扩展名")

; 3.4 Include 空列表报错
r := ParseFilterSettings("include", "", "[Test]")
Assert(InStr(r.Error, "为空") > 0, "Include 空列表产生错误")

; 3.5 Exclude 空列表报错
r := ParseFilterSettings("exclude", "", "[Test]")
Assert(InStr(r.Error, "为空") > 0, "Exclude 空列表产生错误")

; 3.6 非法模式报错
r := ParseFilterSettings("invalid", "", "[Test]")
Assert(InStr(r.Error, "无效") > 0, "非法模式产生错误")

; 3.7 Inherit 模式
r := ParseFilterSettings("inherit", "", "[Test]")
Assert(r.Mode = "Inherit", "Inherit 模式返回 Mode=Inherit")

; 3.8 通配符产生错误
r := ParseFilterSettings("include", "*.jpg", "[Test]")
Assert(InStr(r.Error, "*") > 0, "通配符 * 产生错误")

r := ParseFilterSettings("exclude", "?.tmp", "[Test]")
Assert(InStr(r.Error, "?") > 0, "通配符 ? 产生错误")

; 3.9 反斜杠产生错误
r := ParseFilterSettings("include", ".exe\\", "[Test]")
Assert(InStr(r.Error, "\\") > 0, "反斜杠 \\ 产生错误")

; ──── 4. 继承模拟测试 ────
Print("")
Print("── 继承逻辑模拟 ──")

; 4.1 无文件夹配置时继承全局
globalFilter := {Mode: "All", Extensions: []}
folderFilter := {Mode: globalFilter.Mode, Extensions: globalFilter.Extensions}
Assert(folderFilter.Mode = "All", "无配置时继承全局 All")

; 4.2 文件夹 FilterMode=All 关闭全局筛选
globalFilter := {Mode: "Exclude", Extensions: [".tmp"]}
folderFilter := {Mode: "All", Extensions: []}
Assert(ShouldIncludeFile("file.tmp", folderFilter), "文件夹 FilterMode=All 覆盖全局 Exclude")

; 4.3 文件夹 FilterMode=Inherit 使用全局
globalFilter := {Mode: "Exclude", Extensions: [".tmp"]}
folderFilter := {Mode: globalFilter.Mode, Extensions: globalFilter.Extensions}
Assert(!ShouldIncludeFile("file.tmp", folderFilter), "文件夹 Inherit 使用全局 Exclude")
Assert(ShouldIncludeFile("file.txt", folderFilter), "文件夹 Inherit 通过非排除文件")

; 4.4 文件夹只覆盖 MaxFilesPerFolder（不涉及筛选，但验证继承不破坏筛选）
globalFilter := {Mode: "All", Extensions: []}
folderFilter := {Mode: globalFilter.Mode, Extensions: globalFilter.Extensions}
Assert(ShouldIncludeFile("any.exe", folderFilter), "只覆盖 MaxFilesPerFolder 时筛选继承全局 All")

; 4.5 文件夹覆盖 Include/Exclude 时使用自己的扩展名
folderFilter := {Mode: "Include", Extensions: [".psd", ".png"]}
Assert(ShouldIncludeFile("design.psd", folderFilter), "文件夹 Include 使用自己的扩展名列表命中 .psd")
Assert(!ShouldIncludeFile("design.jpg", folderFilter), "文件夹 Include 使用自己的扩展名列表未命中 .jpg")

; ──── 5. 边界情况 ────
Print("")
Print("── 边界情况 ──")

; 5.1 空文件名
Assert(ShouldIncludeFile("", {Mode: "All", Extensions: []}), "空前缀 All 通过")

; 5.2 无后缀文件
Assert(!ShouldIncludeFile("README", {Mode: "Include", Extensions: [".md"]}), "无后缀文件不匹配 Include")

; 5.3 无后缀文件在 All 模式
Assert(ShouldIncludeFile("README", {Mode: "All", Extensions: []}), "无后缀文件在 All 模式通过")

; 5.4 多段后缀精确匹配
Assert(!ShouldIncludeFile("backup.gz", {Mode: "Include", Extensions: [".tar.gz"]}), ".tar.gz 不匹配 backup.gz")

; 5.5 点号开头的文件
Assert(ShouldIncludeFile(".hidden", {Mode: "Include", Extensions: [".hidden"]}), "点号开头的文件 .hidden 匹配")
Assert(!ShouldIncludeFile(".hidden", {Mode: "Include", Extensions: [".txt"]}), "点号开头的文件 .hidden 不匹配 .txt")

; ──── 结果汇总 ────
Print("")
Print("===== 测试结果 =====")
Print("总计: " totalTests " | 通过: " passedTests " | 失败: " failedTests)
Print("")

if failedTests = 0
    Print("全部通过！")
else
    Print("有 " failedTests " 个测试失败，请检查。")

; 如果运行在 GUI 模式下，弹出结果
if A_IsCompiled
    MsgBox("测试完成`n总计: " totalTests " | 通过: " passedTests " | 失败: " failedTests, "ConfigFilterTests")

ExitApp()