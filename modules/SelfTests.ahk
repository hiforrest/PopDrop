; Windows runtime self-tests invoked by PopDrop.ahk --self-test.

RunSelfTests() {
    global NO_EXTENSION_TOKEN
    global MODE_FILES, MODE_LAUNCHER, SCOPE_FILES_ONLY, SORT_NAME_ASC
    global OPEN_MODE_DOUBLE, OPEN_MODE_SINGLE, SOURCE_OPEN_MODE_INHERIT
    global CONTEXT_MENU_POPDROP, CONTEXT_MENU_SYSTEM
    global DROP_ADAPTER_HDROP, DROP_ADAPTER_VIRTUAL, DROP_ADAPTER_PNG
    global DROP_ADAPTER_URL, DROP_ADAPTER_TEXT, DROP_ADAPTER_UNSUPPORTED
    global WORKSPACE_TYPE_FILES, WORKSPACE_TYPE_TEXT
    global APP_VERSION
    try {
        RunConfigDocumentSelfTests()
        RunPreviewSelfTests()
        RunFileManagerSelfTests()
        RunFolderDropSelfTests()
        RunFolderSourceConfigSelfTests()
        RunSourceManagementSelfTests()
        RunSourceRemovalConfigSelfTests()
        RunNoiseFilterSelfTests()
        RunWorkspaceSelfTests()
        RunCacheMaintenanceSelfTests()
        RunOpenAppActionSelfTests()
        AssertSelfTest(ShouldCaptureTextBlockPaste(
            true, true, "Cards", true),
            "文本卡片区 Ctrl+V 创建固定文本块")
        AssertSelfTest(ShouldCaptureTextBlockPaste(
            true, true, "Container", true),
            "文本工作区容器 Ctrl+V 创建固定文本块")
        AssertSelfTest(!ShouldCaptureTextBlockPaste(
            true, true, "Control", true),
            "输入控件 Ctrl+V 保持普通粘贴")
        AssertSelfTest(!ShouldCaptureTextBlockPaste(
            true, false, "Cards", true),
            "文件工作区 Ctrl+V 不创建文本块")
        AssertSelfTest(!ShouldCaptureTextBlockPaste(
            true, true, "Cards", false),
            "无文本剪贴板不创建文本块")
        AssertSelfTest(!ShouldCaptureTextBlockPaste(
            false, true, "Cards", true),
            "非活动面板不接管 Ctrl+V")
        tabIndexes := ResolveWorkspaceTabIndexes(12, 10, 8)
        AssertSelfTest(tabIndexes.Length = 8
            && tabIndexes[1] = 1 && tabIndexes[7] = 7
            && tabIndexes[8] = 10,
            "顶部最多显示八个工作区并保留当前工作区")
        tabIndexes := ResolveWorkspaceTabIndexes(4, 3, 8)
        AssertSelfTest(tabIndexes.Length = 4 && tabIndexes[3] = 3,
            "八个以内的工作区全部显示为 Tab")
        searchTerms := TextBlockSearchTerms(
            " Alpha   beta　GAMMA alpha ")
        AssertSelfTest(searchTerms.Length = 3
            && searchTerms[1] = "alpha"
            && searchTerms[2] = "beta"
            && searchTerms[3] = "gamma",
            "文本块搜索按半角或全角空格拆分并去重")
        AssertSelfTest(TextBlockHaystacksMatchTerms(
            "alpha title", "contains beta", ["alpha", "beta"]),
            "文本块多关键字可分别命中文件信息与正文")
        AssertSelfTest(!TextBlockHaystacksMatchTerms(
            "alpha title", "other body", ["alpha", "beta"]),
            "文本块多关键字使用 AND 语义")
        AssertSelfTest(TextBlockSearchScopeMatches(
            "alpha beta", "alpha source", "body", ["alpha", "beta"], true),
            "仅标题模式在可见标题内保持 AND 语义")
        AssertSelfTest(!TextBlockSearchScopeMatches(
            "alpha", "alpha source beta", "contains beta",
            ["alpha", "beta"], true),
            "仅标题模式排除正文、来源和路径命中")
        AssertSelfTest(TextBlockSearchScopeMatches(
            "alpha", "alpha source beta", "body", ["alpha", "beta"], false),
            "全文模式保持现有跨字段匹配")
        AssertSelfTest(TextBlockTitleFromPath(
            "C:\\Blocks\\Visible title.md") = "Visible title",
            "仅标题口径与卡片显示一致且不包含扩展名")
        ; --self-test runs before the normal UI globals are initialized.
        ; Supply the scale explicitly so this regression test is startup-safe.
        searchScopeWidth := TextBlockSearchScopeWidth(1920.0, 1.0)
        AssertSelfTest(Type(searchScopeWidth) = "Integer"
            && searchScopeWidth >= 78
            && searchScopeWidth <= 88,
            "文本搜索组合控件兼容 DPI 换算后的浮点 GUI 宽度")
        AssertSelfTest(ShouldHideTextSourceForSearch(
            true, "query", "Ready", 0),
            "文本搜索隐藏零命中的来源分栏")
        AssertSelfTest(!ShouldHideTextSourceForSearch(
            true, "", "Ready", 0),
            "无查询时保留原有空来源提示")
        AssertSelfTest(!ShouldHideTextSourceForSearch(
            true, "query", "Unavailable", 0),
            "搜索时仍保留目录不可用状态")
        AssertSelfTest(!ShouldHideTextSourceForSearch(
            false, "query", "Ready", 0),
            "文件工作区不受文本搜索分栏规则影响")
        AssertSelfTest(ShouldActivateTextBlockSearchResult(
            true, true, false),
            "文本搜索框空闲且结果就绪时 Enter 快速发送")
        AssertSelfTest(!ShouldActivateTextBlockSearchResult(
            true, true, true),
            "IME 组合输入期间 Enter 保留给输入法")
        AssertSelfTest(!ShouldActivateTextBlockSearchResult(
            false, true, false),
            "搜索框未聚焦时不接管 Enter")
        AssertSelfTest(!ShouldActivateTextBlockSearchResult(
            true, false, false),
            "没有搜索结果时不接管 Enter")
        AssertSelfTest(FormatFolderGroupHeader("下载", false) = "⋁ 下载"
            && FormatFolderGroupHeader("下载", true) = "⋀ 下载",
            "来源分栏标题使用展开与收起符号")
        AssertSelfTest(FolderGroupCollapseKey(
            "Workspace-A", "Source-A", "C:\One")
            != FolderGroupCollapseKey(
                "Workspace-B", "Source-A", "C:\One"),
            "来源折叠状态按工作区隔离")
        sourceGroupIds := SourceFolderGroupIds(Map(
            1, {Type: "Pinned", GroupId: 1},
            2, {Type: "Files", SourceId: "source-a", GroupId: 2},
            3, {Type: "Launcher", SourceId: "source-b", GroupId: 3},
            4, {Type: "TextPinned", GroupId: 4},
            5, {Type: "TextSource", SourceId: "source-c", GroupId: 5}))
        AssertSelfTest(sourceGroupIds.Length = 3
            && sourceGroupIds[1] = 2
            && sourceGroupIds[2] = 3
            && sourceGroupIds[3] = 5,
            "全部展开收起只包含来源分栏并排除固定项")
        AssertSelfTest(NormalizeEditedTextBlock(
            "`r`n正文`r`n`r`n") = "`n正文`n`n",
            "编辑文本块保留首尾空行")
        AssertSelfTest(NormalizeTerminalSendText(
            "`r`n`n  正文`r内部`n正文  `r`n")
            = "  正文`r内部`n正文  ",
            "终端正文只清理绝对首尾的混合换行")
        AssertSelfTest(NormalizeTerminalSendText(
            "  `r`n正文`r`n  ") = "  `r`n正文`r`n  ",
            "终端正文不跨越普通空格清理换行")
        AssertSelfTest(!TerminalTextHasMeaningfulContent(" `t　`r`n"),
            "终端空白正文停止发送")
        AssertSelfTest(TerminalTextHasLineBreak("第一行`r第二行"),
            "CR 也属于终端真实换行")
        safeChinese := "请分析以下内容，并给出清晰的修改建议：`r`n`r`n"
            . "## Windows Terminal compatibility`n"
            . "- 请保留 README.md、AutoHotkey v2 和 C++ 术语。`n"
            . "> 说明应使用 **中文自然语言**，不要改变原文。"
        AssertSelfTest(IsHighConfidenceChineseNaturalLanguage(safeChinese),
            "高置信度中文 Markdown 多行正文可以免二次确认")
        AssertSelfTest(!IsHighConfidenceChineseNaturalLanguage(
            "请执行以下命令：`n`ngit status`ngit push origin main"),
            "独立英文命令行使中文正文退出规则白名单")
        codeFence := Chr(96) Chr(96) Chr(96)
        AssertSelfTest(!IsHighConfidenceChineseNaturalLanguage(
            "请检查下面的脚本：`n" codeFence "powershell`nGet-Process`n"
            . codeFence),
            "代码围栏使中文正文退出规则白名单")
        AssertSelfTest(!IsHighConfidenceChineseNaturalLanguage(
            "请检查仓库状态：`ngit status | findstr modified"),
            "管道结构使中文正文退出规则白名单")
        AssertSelfTest(ParseGlobalOpenFileMode("") = OPEN_MODE_DOUBLE,
            "缺失全局打开方式回退为双击")
        AssertSelfTest(ParseGlobalOpenFileMode("broken") = OPEN_MODE_DOUBLE,
            "损坏全局打开方式回退为双击")
        AssertSelfTest(ParseGlobalOpenFileMode("singleclick") = OPEN_MODE_SINGLE,
            "全局单击方式大小写不敏感")
        AssertSelfTest(ParseSourceOpenFileMode("") = SOURCE_OPEN_MODE_INHERIT,
            "缺失来源打开方式继承全局")
        AssertSelfTest(ParseSourceOpenFileMode("unknown")
            = SOURCE_OPEN_MODE_INHERIT,
            "损坏来源打开方式继承全局")
        AssertSelfTest(ParseDefaultContextMenu("") = CONTEXT_MENU_POPDROP,
            "缺失默认右键菜单回退为 PopDrop")
        AssertSelfTest(ParseDefaultContextMenu("unknown") = CONTEXT_MENU_POPDROP,
            "损坏默认右键菜单回退为 PopDrop")
        AssertSelfTest(ParseDefaultContextMenu("system") = CONTEXT_MENU_SYSTEM,
            "默认右键菜单大小写不敏感")
        AssertSelfTest(ResolveContextMenuKind(
            CONTEXT_MENU_POPDROP, false) = CONTEXT_MENU_POPDROP,
            "PopDrop 默认普通操作")
        AssertSelfTest(ResolveContextMenuKind(
            CONTEXT_MENU_POPDROP, true) = CONTEXT_MENU_SYSTEM,
            "PopDrop 默认 Shift 反转")
        AssertSelfTest(ResolveContextMenuKind(
            CONTEXT_MENU_SYSTEM, false) = CONTEXT_MENU_SYSTEM,
            "系统菜单默认普通操作")
        AssertSelfTest(ResolveContextMenuKind(
            CONTEXT_MENU_SYSTEM, true) = CONTEXT_MENU_POPDROP,
            "系统菜单默认 Shift 反转")
        extensions := NormalizeOpenAppExtensions("PDF, .pdf, txt, <none>, none")
        AssertSelfTest(extensions.Length = 3, "扩展名去重")
        AssertSelfTest(extensions[1] = ".pdf", "扩展名小写及点号")
        AssertSelfTest(extensions[3] = NO_EXTENSION_TOKEN, "无扩展名类型")
        AssertSelfTest(GetFileExtensionType("C:\a\README") = NO_EXTENSION_TOKEN,
            "无扩展名识别")
        AssertSelfTest(GetFileExtensionType("C:\a\archive.tar.gz") = ".gz",
            "只取最后扩展名")
        actionExtensions := NormalizeActionExtensions(
            ".GZ, tar.gz, <none>, .tar.gz")
        AssertSelfTest(actionExtensions.Length = 3
            && actionExtensions[1] = ".tar.gz",
            "工具动作扩展名去重并优先最长后缀")
        AssertSelfTest(ActionExtensionMatchesPath(
            "C:\a\ARCHIVE.TAR.GZ", actionExtensions),
            "工具动作最长后缀匹配大小写不敏感")
        variables := {
            Item: "C:\空 格\右击 (1)&.tar.gz",
            Folder: "C:\空 格",
            Parent: "C:\",
            Name: "右击 (1)&.tar.gz",
            Stem: "右击 (1)&.tar",
            Ext: "gz",
            Date: "20260726", Time: "153045",
            DateTime: "20260726_153045",
            Index: 1, Count: 5, Size: "15KB"
        }
        renderedArg := ReplaceOpenAppActionVariables(
            "-o{folder}\{stem}-{index}of{count}-{date}", variables)
        AssertSelfTest(renderedArg =
            "-oC:\空 格\右击 (1)&.tar-1of5-20260726",
            "标量变量在单个参数内替换")
        specialArgs := ["x", variables.Item,
            renderedArg, "C:\第二个\中文 & (2).zip",
            "尾部\" . Chr(34)]
        commandLine := QuoteWindowsArgument("C:\Tools\7z.exe")
            . " " BuildWindowsParameterString(specialArgs)
        roundTrip := ParseWindowsCommandLineForSelfTest(commandLine)
        AssertSelfTest(roundTrip.Length = specialArgs.Length + 1
            && roundTrip[2] = specialArgs[1]
            && roundTrip[3] = specialArgs[2]
            && roundTrip[6] = specialArgs[5],
            "Windows 参数逐项转义可无损还原")
        invalidAction := {
            Name: "错误动作", Executable: "",
            TargetTypes: "Files", ExecutionMode: "Batch",
            Extensions: [], RequireCommonFolder: false,
            WorkingDirectoryMode: "Folder", WorkingDirectory: "",
            Confirm: false, Enabled: true,
            Args: ["--bad={unknown}", "prefix{items}"],
            Valid: true, ValidationError: ""
        }
        validation := ValidateOpenAppAction(invalidAction,
            {Path: "C:\Tools\tool.exe"}, false)
        AssertSelfTest(validation.Errors.Length >= 2,
            "未知变量和嵌入式 {items} 阻止保存")
        AssertSelfTest(IsExecutablePath("C:\Program Files\7-Zip\7z.exe"),
            "EXE 扩展名识别")
        AssertSelfTest(IsExecutablePath("C:\Tools\APP.EXE"),
            "EXE 扩展名大小写不敏感")
        AssertSelfTest(!IsExecutablePath("C:\Tools\script.cmd"),
            "拒绝脚本型程序")
        appIds := ParseOpenAppOrder("7z, everedit,7Z, guoheview")
        AssertSelfTest(appIds.Length = 3 && appIds[1] = "7z"
            && appIds[3] = "guoheview", "软件顺序解析及 ID 去重")
        AssertSelfTest(OpenAppIdBase(
            "C:\Program Files\7-Zip\7zG.exe") = "7zg",
            "从 EXE 文件名生成可读软件 ID")
        AssertSelfTest(OpenAppIdBase(
            "C:\Tools\My App!.exe") = "my-app",
            "可读软件 ID 字符规范化")
        AssertSelfTest(IsGuidOpenAppId(
            "16e792f3-dc35-422a-b61f-4fb325a2616b"),
            "识别旧版 UUID 软件 ID")
        AssertSelfTest(PathsEqual('"C:/Temp/Folder/"', "c:\temp\folder"),
            "Windows 路径规范比较")
        AssertSelfTest(IsSameOrDescendantPath(
            "C:\Temp\Folder\Child", "c:\temp\folder"),
            "后代路径识别")
        AssertSelfTest(IsSameOrDescendantPath(
            "C:\Temp\Folder", "c:\temp\folder"),
            "文件夹到自身目标识别")
        AssertSelfTest(!IsSameOrDescendantPath(
            "C:\Temp\Folder2", "c:\temp\folder"),
            "路径边界识别")
        dropFilesTarget := {
            Type: "Files", SourceId: "source-target", Name: "目标",
            Path: "C:\Target", Available: true, Reason: "", GroupId: 2}
        dropLauncherTarget := {
            Type: "Launcher", SourceId: "source-tools", Name: "工具",
            Path: "C:\Tools", Available: true, Reason: "", GroupId: 3}
        dropPinnedTarget := {
            Type: "Pinned", SourceId: "", Name: "固定项",
            Path: "", Available: true, Reason: "", GroupId: 1}
        addSourceTarget := {
            Type: "AddSource", SourceId: "", Name: "测试工作区",
            Path: "", Available: true, Reason: "", GroupId: 0}
        AssertSelfTest(ClassifyDropSource(
            [{Area: "Source"}], true) = "Source"
            && ClassifyDropSource([{Area: "Pinned"}], true) = "Pinned"
            && ClassifyDropSource([{Area: "Recent"}], true) = "Recent"
            && ClassifyDropSource([
                {Area: "Source"}, {Area: "Pinned"}], true) = "Mixed"
            && ClassifyDropSource([], false) = "External",
            "内部与外部来源上下文分类")
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0, 3, "Source") = 2,
            "内部普通来源默认移动")
        for safeKind in ["Pinned", "Recent", "External", "Mixed"] {
            AssertSelfTest(ResolveDropEffect(
                dropFilesTarget, 0, 3, safeKind) = 1,
                safeKind " 默认安全复制")
        }
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0x0008, 3, "Source") = 1,
            "Ctrl 请求复制")
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0x0004, 3, "External") = 2,
            "Shift 请求移动")
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0x0004, 1, "External") = 1,
            "不允许移动时安全回退复制")
        AssertSelfTest(ResolveDropEffect(
            dropFilesTarget, 0x0008, 2, "Source") = 0,
            "不允许复制时不能危险回退移动")
        AssertSelfTest(ResolveDropEffect(
            dropLauncherTarget, 0x0004, 3, "Source") = 1,
            "Launcher 始终使用复制效果")
        AssertSelfTest(ResolveDropEffect(
            dropPinnedTarget, 0x0004, 3, "Source") = 1,
            "固定项语义不受 Shift 改变")
        AssertSelfTest(ResolveDropEffect(
            addSourceTarget, 0, 3, "Source") = 1
            && ResolveDropEffect(
                addSourceTarget, 0x0008, 3, "Source") = 1
            && ResolveDropEffect(
                addSourceTarget, 0x0004, 3, "Source") = 1,
            "添加来源始终只返回 COPY")
        AssertSelfTest(ResolveDropEffect(
            addSourceTarget, 0, 2, "Source") = 0,
            "添加来源在 COPY 不可用时返回 NONE")
        AssertSelfTest(HDropShouldUseDirectAsyncTakeover(
            "External", dropFilesTarget, {Supported: true}),
            "外部异步 HDROP 不依赖 URL 直接接管")
        AssertSelfTest(!HDropShouldUseDirectAsyncTakeover(
            "External", dropFilesTarget, {Supported: false}),
            "同步外部 HDROP 保留本地路径链路")
        AssertSelfTest(!HDropShouldUseDirectAsyncTakeover(
            "Source", dropFilesTarget, {Supported: true}),
            "PopDrop 内部 HDROP 不交给外部 helper")
        AssertSelfTest(ShouldContinuePinnedReorder(dropPinnedTarget),
            "固定项原生分组内保持排序手势")
        AssertSelfTest(ShouldContinuePinnedReorder({
            Type: "TextPinned", Available: true, GroupId: 8}),
            "文本块固定项保持手动排序")
        AssertSelfTest(!ShouldContinuePinnedReorder({
            Type: "Pinned", Available: true, GroupId: 0}),
            "固定项工具栏按钮不进入内部排序")
        AssertSelfTest(!ShouldContinuePinnedReorder(dropFilesTarget),
            "固定项进入 Files 分组时切换为 OLE 拖放")
        AssertSelfTest(DropItemMatchesTargetSource({
            Area: "Source", SourceId: "source-target",
            SourcePath: "C:\Target"}, "c:\target", "source-other"),
            "同一来源路径识别为无操作")
        AssertSelfTest(DropItemMatchesTargetSource({
            Area: "Source", SourceId: "source-a",
            SourcePath: "C:\Shared"}, "c:\shared", "source-b"),
            "不同来源名称指向同一真实路径仍为无操作")
        AssertSelfTest(!DropItemMatchesTargetSource({
            Area: "Pinned"}, "C:\Target", "source-target"),
            "固定项拖到 Files 不误判为同来源")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Files", SourceId: "s1", Name: "项目",
            Path: "C:\Project", GroupId: 4}, true, true)
        AssertSelfTest(descriptor.Type = "Files" && descriptor.Available
            && descriptor.SourceId = "s1", "Files 目标纯数据解析")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Launcher", SourceId: "s2", Name: "工具",
            Path: "C:\Tools", GroupId: 5}, true, true)
        AssertSelfTest(descriptor.Type = "Launcher" && descriptor.Available,
            "Launcher 目标纯数据解析")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Pinned", Name: "固定项", GroupId: 1})
        AssertSelfTest(descriptor.Type = "Pinned" && descriptor.Available,
            "Pinned 目标纯数据解析")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Files", SourceId: "s3", Name: "离线",
            Path: "C:\Offline", GroupId: 6}, false, false)
        AssertSelfTest(!descriptor.Available && descriptor.Reason != "",
            "不可用来源解析为 Invalid 效果")
        descriptor := ResolveDropTargetDescriptor({
            Type: "Invalid", Name: "状态栏", GroupId: 0})
        AssertSelfTest(descriptor.Type = "Invalid" && !descriptor.Available,
            "Invalid 目标纯数据解析")
        AssertSelfTest(ResolveDropEffect(descriptor, 0, 3, "External") = 0,
            "Invalid 目标返回 DROPEFFECT_NONE")
        badFormat := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
        FillHDropFormat(badFormat.Ptr)
        NumPut("ushort", 13, badFormat, 0)
        AssertSelfTest(!IsHDropFormat(badFormat.Ptr),
            "不支持的数据格式返回 DROPEFFECT_NONE 的前置判断")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "HDrop", true, "Url", true)).Adapter = DROP_ADAPTER_HDROP,
            "格式分类：本地文件优先于 URL")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "FileDescriptor", true, "FileContents", true,
            "Png", true, "Url", true)).Adapter = DROP_ADAPTER_VIRTUAL,
            "格式分类：虚拟文件优先于图片和 URL")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "Png", true, "Url", true)).Adapter = DROP_ADAPTER_PNG,
            "格式分类：图片优先于 URL")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "Url", true)).Adapter = DROP_ADAPTER_URL,
            "格式分类：明确 URL 最后兜底")
        AssertSelfTest(ClassifyAvailableDropFormats(Map(
            "UnicodeText", true)).Adapter = DROP_ADAPTER_TEXT,
            "纯 Unicode 文本进入文本适配器")
        textTarget := {Type: "TextSource", Available: true,
            Name: "话术", Path: "C:\Text", GroupId: 7}
        mixedDecision := {Adapter: DROP_ADAPTER_HDROP,
            HasUnicodeText: true, HasAnsiText: false}
        AssertSelfTest(SelectDropAdapterForTarget(
            mixedDecision, textTarget) = DROP_ADAPTER_TEXT,
            "文本目标优先使用 Unicode 正文")
        AssertSelfTest(SelectDropAdapterForTarget(
            mixedDecision, dropFilesTarget) = DROP_ADAPTER_HDROP,
            "文件目标保持 HDROP 语义")
        AssertSelfTest(ResolveDropEffect(textTarget, 0, 3, "External") = 1,
            "文本来源允许复制投放")
        draftPath := TextBlockInboxDirectory() "\draft.md"
        AssertSelfTest(ResolveDropEffect(
            textTarget, 0, 3, "Pinned", [draftPath]) = 2,
            "独立固定文本块默认移动到文本来源")
        AssertSelfTest(ResolveDropEffect(
            textTarget, 0x0008, 3, "Pinned", [draftPath]) = 1,
            "Ctrl 可显式复制独立文本块")
        AssertSelfTest(ResolveDropEffect(
            textTarget, 0, 3, "Pinned", ["C:\Text\reference.md"]) = 1,
            "普通固定文本块仍保持复制语义")
        AssertSelfTest(ResolveDropEffect(
            textTarget, 0x0004, 3, "Pinned",
            ["C:\Text\reference.md"]) = 0,
            "Shift 不能从固定链接移动原文件")
        mixedPinnedTextPaths := [draftPath, "C:\Text\reference.md"]
        AssertSelfTest(ResolveDropEffect(
            textTarget, 0, 3, "Pinned", mixedPinnedTextPaths) = 0,
            "独立文本块与链接混选时默认拒绝投放")
        AssertSelfTest(ResolveDropEffect(
            textTarget, 0x0008, 3, "Pinned", mixedPinnedTextPaths) = 1,
            "Ctrl 可统一复制独立文本块与链接混合选区")
        movedDraftMappings := Map()
        movedDraftMappings[PathKey(draftPath)] := {
            OldPath: draftPath, NewPath: "C:\Text\draft.md"}
        removeMovedContext := {
            RemoveMovedPinsWorkspaceId: "workspace-text-default",
            RemoveMovedPinnedPaths: [draftPath]}
        AssertSelfTest(ShouldRemoveMovedPinnedPath(
            "workspace-text-default", draftPath, movedDraftMappings,
            removeMovedContext),
            "成功分类的独立文本块从当前工作区固定项移除")
        AssertSelfTest(!ShouldRemoveMovedPinnedPath(
            "workspace-other", draftPath, movedDraftMappings,
            removeMovedContext),
            "其他工作区对同一文本块的链接继续保留")
        AssertSelfTest(ParseWorkspaceType("text") = WORKSPACE_TYPE_TEXT
            && ParseWorkspaceType("") = WORKSPACE_TYPE_FILES,
            "工作区类型解析兼容旧配置")
        ansiFormat := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
        FillAnsiTextFormat(ansiFormat.Ptr)
        AssertSelfTest(IsAnsiTextFormat(ansiFormat.Ptr)
            && !IsUnicodeTextFormat(ansiFormat.Ptr),
            "文本拖出同时提供独立的 ANSI 格式")
        AssertSelfTest(MakeTextBlockTitle("# 角色`n`n你是产品专家")
            = "你是产品专家", "文本块标题跳过通用结构标题")
        AssertSelfTest(IsDuplicatePinnedCandidate(
            ["C:\A.txt"], [], "c:\a.txt"),
            "重复固定项按规范路径跳过")
        names := Map("tool.lnk", true, "tool (2).lnk", true)
        AssertSelfTest(MakeUniqueShortcutFileName("tool", names)
            = "tool (3).lnk", "Launcher 快捷方式唯一名称")
        AssertSelfTest(SanitizeShortcutBaseName("CON") = "CON_"
            && SanitizeShortcutBaseName("bad:name. ") = "bad_name",
            "Launcher 快捷方式名称清理")
        AssertSelfTest(ValidateRenameName("报告 2026.txt").Valid,
            "普通重命名名称有效")
        AssertSelfTest(!ValidateRenameName("").Valid
            && !ValidateRenameName("bad:name.txt").Valid
            && !ValidateRenameName("report.").Valid
            && !ValidateRenameName("CON.txt").Valid,
            "重命名拒绝空名称、非法字符、尾随句点和保留设备名")
        renameMappings := Map()
        renameMappings[PathKey("C:\Work\Old")] := {
            OldPath: "C:\Work\Old", NewPath: "C:\Work\New"}
        AssertSelfTest(ResolveMovedPathMapping(
            "C:\Work\Old\child.txt", renameMappings)
            = "C:\Work\New\child.txt",
            "重命名或移动文件夹时同步固定的后代路径")
        crossVolumeSnapshot := {Folders: [
            {Files: [
                {Path: "W:\Dump\2026\moved.webp"},
                {Path: "W:\Dump\2026\keep.webp"}]},
            {Files: [
                {Path: "D:\Download\moved.webp"}]}
        ]}
        removedCrossVolumeItems := RemoveMovedPathsFromScanResult(
            crossVolumeSnapshot, ["W:\Dump\2026\moved.webp"])
        AssertSelfTest(removedCrossVolumeItems = 1
            && crossVolumeSnapshot.Folders[1].Files.Length = 1
            && PathsEqual(
                crossVolumeSnapshot.Folders[1].Files[1].Path,
                "W:\Dump\2026\keep.webp")
            && crossVolumeSnapshot.Folders[2].Files.Length = 1,
            "跨磁盘移动后立即移除源卡片并保留目标卡片")
        movedFolderSnapshot := {Folders: [{Files: [
            {Path: "W:\Root\MovedFolder"},
            {Path: "W:\Root\MovedFolder\child.txt"},
            {Path: "W:\Root\keep.txt"}
        ]}]}
        removedMovedFolderItems := RemoveMovedPathsFromScanResult(
            movedFolderSnapshot, ["W:\Root\MovedFolder"])
        AssertSelfTest(removedMovedFolderItems = 2
            && movedFolderSnapshot.Folders[1].Files.Length = 1
            && PathsEqual(
                movedFolderSnapshot.Folders[1].Files[1].Path,
                "W:\Root\keep.txt"),
            "跨磁盘移动文件夹后同时移除缓存中的后代卡片")
        session := CreateDropSessionState()
        session.Paused := true
        MarkDropSessionFinished(session, "success")
        AssertSelfTest(session.Completed && !session.Paused
            && session.Outcome = "success", "拖拽成功状态清理")
        for outcome in ["failure", "cancel", "leave"] {
            state := CreateDropSessionState()
            state.Paused := true
            MarkDropSessionFinished(state, outcome)
            AssertSelfTest(state.Completed && !state.Paused,
                "拖拽" outcome "状态清理")
        }
        AssertSelfTest(ShouldSkipScannedFolder(
            "C:\Work\.git", ".git", [".git"], [], []),
            "全局排除名称进入扫描判断")
        AssertSelfTest(!ShouldSkipScannedFolder(
            "C:\Work\.git", ".git", [".git"], [],
            ["C:\Work\.git"]),
            "来源允许路径覆盖全局排除")
        AssertSelfTest(ShouldSkipScannedFolder(
            "C:\Work\build\bin", "bin", [],
            ["C:\Work\build"], []),
            "来源排除路径覆盖其后代")
        launcherSource := {
            Mode: MODE_FILES, IncludeSubfolders: true,
            DisplayScope: "RecursiveFiles", SortMode: "ModifiedDesc",
            Filter: {Mode: "All", Extensions: []},
            StripOrderPrefix: 0, HideExtensions: 0
        }
        ApplyLauncherSourceDefaults(launcherSource)
        AssertSelfTest(!launcherSource.IncludeSubfolders
            && launcherSource.DisplayScope = SCOPE_FILES_ONLY
            && launcherSource.SortMode = SORT_NAME_ASC
            && launcherSource.Filter.Mode = "Include"
            && JoinArray(launcherSource.Filter.Extensions, ",") = ".lnk,.url,.exe"
            && launcherSource.StripOrderPrefix
            && launcherSource.HideExtensions,
            "Launcher 文件夹类型应用完整默认特性")
        FileAppend("PopDrop v" APP_VERSION " self-test: PASS`n", "*")
    } catch as err {
        FileAppend("PopDrop v" APP_VERSION
            " self-test: FAIL - " err.Message "`n", "*")
        ExitApp(1)
    }
}

RunWorkspaceSelfTests() {
    ids := ParseStableIdOrder(
        "workspace-a, workspace-b,WORKSPACE-A,broken id")
    AssertSelfTest(ids.Length = 2
        && ids[1] = "workspace-a" && ids[2] = "workspace-b",
        "工作区 ID 顺序去重并拒绝不安全值")
    AssertSelfTest(IsSafeWorkspaceName("设计项目")
        && !IsSafeWorkspaceName("")
        && !IsSafeWorkspaceName("错误,名称"),
        "工作区名称安全校验")
    AssertSelfTest(IsSafeStableId("workspace-123")
        && !IsSafeStableId("workspace:123"),
        "稳定工作区 ID 格式")
    workspaces := [
        {Id: "files-a", Type: "Files"},
        {Id: "text-a", Type: "Text"},
        {Id: "files-b", Type: "Files"}]
    AssertSelfTest(ResolveFileWorkspaceId(
        "files-b", workspaces, "text-a") = "files-b",
        "主快捷键优先返回最近文件工作区")
    AssertSelfTest(ResolveFileWorkspaceId(
        "missing", workspaces, "text-a") = "files-a",
        "最近文件工作区失效时回退到首个文件工作区")
    AssertSelfTest(MoveWorkspaceOrderItem(workspaces, 2, -1) = 1
        && workspaces[1].Id = "text-a"
        && workspaces[2].Id = "files-a",
        "工作区上移保持对象及相对顺序")
    AssertSelfTest(MoveWorkspaceOrderItem(workspaces, 1, -1) = 0
        && MoveWorkspaceOrderItem(workspaces, workspaces.Length, 1) = 0,
        "工作区排序拒绝越界移动")
    AssertSelfTest(MoveWorkspaceOrderItem(workspaces, 1, 1) = 2
        && workspaces[1].Id = "files-a"
        && workspaces[2].Id = "text-a",
        "工作区下移恢复原顺序")
}

RunCacheMaintenanceSelfTests() {
    AssertSelfTest(CacheMaintenanceNameKind(
        "request-00000000000000AA-00000001.ini", false) = "Transient",
        "主扫描请求属于受管临时缓存")
    AssertSelfTest(CacheMaintenanceNameKind(
        "inactive-00000000000000AA-00000001.ready", true) = "Transient",
        "非当前工作区结果目录属于受管临时缓存")
    AssertSelfTest(CacheMaintenanceNameKind(
        "preview-cache-v1", true) = "",
        "AHK 维护器不越权删除原生预览缓存目录")
    valid := Map("workspace-1234abcd.ini", true)
    AssertSelfTest(!CacheMaintenanceShouldDelete(
        "Transient", "request-x.ini", 899, false, valid)
        && CacheMaintenanceShouldDelete(
        "Transient", "request-x.ini", 900, false, valid),
        "扫描临时缓存保留十五分钟安全窗口")
    AssertSelfTest(!CacheMaintenanceShouldDelete(
        "Transient", "request-x.ini", 999999, true, valid),
        "正在使用的扫描缓存永不清理")
    AssertSelfTest(!CacheMaintenanceShouldDelete(
        "Workspace", "workspace-1234abcd.ini", 999999, false, valid)
        && CacheMaintenanceShouldDelete(
            "Workspace", "workspace-deadbeef.ini", 999999, false, valid),
        "只清理已删除工作区的孤立快照")
    AssertSelfTest(RegExMatch(CacheMaintenanceToday(), "^\d{8}$"),
        "每日维护日期使用本地自然日")
}

RunFolderDropSelfTests() {
    global DROP_ADAPTER_HDROP
    testRoot := A_Temp "\PopDrop-folder-drop-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount
    try {
        firstFolder := testRoot "\文件夹一"
        secondFolder := testRoot "\文件夹二"
        filePath := testRoot "\普通文件.txt"
        missingPath := testRoot "\不存在"
        DirCreate(firstFolder)
        DirCreate(secondFolder)
        FileAppend("test", filePath, "UTF-8")
        AssertSelfTest(ClassifyDropPaths([]) = "Unknown",
            "拖拽载荷分类：空路径为 Unknown")
        AssertSelfTest(ClassifyDropPaths([filePath]) = "FilesOnly",
            "拖拽载荷分类：全文件")
        AssertSelfTest(ClassifyDropPaths(
            [firstFolder, secondFolder]) = "FoldersOnly",
            "拖拽载荷分类：全文件夹")
        AssertSelfTest(ClassifyDropPaths(
            [filePath, firstFolder]) = "Mixed",
            "拖拽载荷分类：文件和文件夹混合")
        AssertSelfTest(ClassifyDropPaths([missingPath]) = "Unknown"
            && !IsPersistableFileSystemFolder(missingPath),
            "不存在路径不能添加为来源")
        smartSession := CreateDropSessionState()
        smartSession.PathsCached := true
        smartSession.Paths := [firstFolder]
        smartSession.PayloadKind := "FoldersOnly"
        AssertSelfTest(ResolveSmartDropMode(smartSession) = "Folders",
            "外部纯文件夹显示顶部来源入口")
        smartSession.IsInternal := true
        AssertSelfTest(ResolveSmartDropMode(smartSession) = "",
            "内部文件夹不显示顶部来源入口")
        smartSession.Paths := [filePath]
        smartSession.PayloadKind := "FilesOnly"
        AssertSelfTest(ResolveSmartDropMode(smartSession, false) = "Files"
            && ResolveSmartDropMode(smartSession, true) = "",
            "内部纯文件仅在没有可命中固定项分组时显示顶部入口")
        smartSession.IsInternal := false
        AssertSelfTest(ResolveSmartDropMode(smartSession, false) = "Files"
            && ResolveSmartDropMode(smartSession, true) = "",
            "外部纯文件仅在没有可命中固定项分组时显示顶部入口")
        smartSession.PayloadKind := "Mixed"
        AssertSelfTest(ResolveSmartDropMode(smartSession) = "",
            "混合选择不显示顶部入口")

        stableDecision := {
            Adapter: DROP_ADAPTER_HDROP,
            HasExplicitUrl: false,
            HasVirtualFiles: false,
            HasImagePayload: false,
            HasShellIdList: false
        }
        AssertSelfTest(CanPreloadHDropForFolderFeedback(
            stableDecision, {Supported: true}, "Source"),
            "内部拖拽可以立即分类且不读取 IDataObject")
        internalSession := CreateDropSessionState()
        CacheDropSessionPaths(internalSession, [firstFolder], false)
        AssertSelfTest(internalSession.PayloadKind = "FoldersOnly"
            && internalSession.HDropReadCount = 0,
            "内部拖拽直接使用上下文路径分类")
        AssertSelfTest(!CanPreloadHDropForFolderFeedback(
            stableDecision, {Supported: true}, "External"),
            "未知外部异步 HDROP 不允许预读")
        explorerDecision := {
            Adapter: DROP_ADAPTER_HDROP,
            HasExplicitUrl: false,
            HasVirtualFiles: true,
            HasImagePayload: false,
            HasShellIdList: true
        }
        AssertSelfTest(CanPreloadHDropForFolderFeedback(
            explorerDecision, {Supported: true}, "External"),
            "Explorer Shell 文件夹即使异步并带辅助格式也允许预读")
        urlDecision := {
            Adapter: DROP_ADAPTER_HDROP,
            HasExplicitUrl: true,
            HasVirtualFiles: false,
            HasImagePayload: false,
            HasShellIdList: false
        }
        virtualDecision := {
            Adapter: DROP_ADAPTER_HDROP,
            HasExplicitUrl: false,
            HasVirtualFiles: true,
            HasImagePayload: false,
            HasShellIdList: false
        }
        imageDecision := {
            Adapter: DROP_ADAPTER_HDROP,
            HasExplicitUrl: false,
            HasVirtualFiles: false,
            HasImagePayload: true,
            HasShellIdList: false
        }
        AssertSelfTest(!CanPreloadHDropForFolderFeedback(
            urlDecision, {Supported: false}, "External")
            && !CanPreloadHDropForFolderFeedback(
                virtualDecision, {Supported: false}, "External")
            && !CanPreloadHDropForFolderFeedback(
                imageDecision, {Supported: false}, "External"),
            "URL、虚拟文件和图片载荷不允许预读")
        AssertSelfTest(CanPreloadHDropForFolderFeedback(
            stableDecision, {Supported: false}, "External"),
            "稳定本地 HDROP 允许一次预读")

        readState := {Count: 0, Paths: [firstFolder, secondFolder]}
        session := CreateDropSessionState()
        firstRead := GetDropSessionHDropPaths(session, 0,
            SelfTestHDropReader.Bind(readState))
        secondRead := GetDropSessionHDropPaths(session, 0,
            SelfTestHDropReader.Bind(readState))
        AssertSelfTest(readState.Count = 1
            && session.HDropReadCount = 1
            && firstRead.Length = 2 && secondRead.Length = 2,
            "稳定本地 HDROP 和 Drop 复用同一次读取")

        retryState := {Count: 0, Paths: [firstFolder]}
        retrySession := CreateDropSessionState()
        preloadRead := PreloadDropSessionHDropPaths(retrySession, 0,
            SelfTestDelayedHDropReader.Bind(retryState))
        dropRead := GetDropSessionHDropPaths(retrySession, 0,
            SelfTestDelayedHDropReader.Bind(retryState))
        AssertSelfTest(preloadRead.Length = 0
            && retryState.Count = 2
            && retrySession.HDropReadCount = 2
            && dropRead.Length = 1
            && PathsEqual(dropRead[1], firstFolder),
            "悬停阶段尚未就绪的 HDROP 在实际 Drop 时重试")

        addTarget := ResolveAddSourceDropTarget(
            "FoldersOnly", "测试", [firstFolder], [], false)
        mixedTarget := ResolveAddSourceDropTarget(
            "Mixed", "测试", [filePath, firstFolder], [], false)
        duplicateTarget := ResolveAddSourceDropTarget(
            "FoldersOnly", "测试", [firstFolder],
            [{Name: "已有", Path: firstFolder}], false)
        AssertSelfTest(addTarget.Available
            && !mixedTarget.Available
            && !duplicateTarget.Available,
            "AddSource 只接受纯文件夹并识别当前工作区重复路径")

        defaults := {
            DefaultDisplayScope: "FilesOnly",
            DefaultFolderTimeMode: "DirectoryModified",
            MaxFilesPerFolder: 8,
            DefaultFilter: {Mode: "All", Extensions: []}
        }
        idState := {Next: 0}
        singlePlan := PlanFolderSourceAdditions(
            [firstFolder], [], Map(), "workspace-test", defaults,
            BuildDropPathInfo([firstFolder]),
            SelfTestSourceIdFactory.Bind(idState))
        AssertSelfTest(singlePlan.Sources.Length = 1
            && singlePlan.Sources[1].Mode = "Files",
            "单个文件夹生成默认 Files 来源")
        plan := PlanFolderSourceAdditions(
            [firstFolder, secondFolder, missingPath],
            [], Map(), "workspace-test", defaults,
            BuildDropPathInfo([firstFolder, secondFolder, missingPath]),
            SelfTestSourceIdFactory.Bind(idState))
        AssertSelfTest(plan.Sources.Length = 2
            && PathsEqual(plan.Sources[1].Path, firstFolder)
            && PathsEqual(plan.Sources[2].Path, secondFolder)
            && plan.Failed = 1,
            "来源计划保持顺序并逐项记录无效候选")

        session.FolderDropUiShown := true
        MarkDropSessionFinished(session, "leave")
        AssertSelfTest(!session.FolderDropUiShown
            && session.Completed && !session.Paused,
            "拖拽结束状态恢复顶部工具栏")
    } finally {
        try DirDelete(testRoot, true)
    }
}

SelfTestHDropReader(state, dataObject) {
    state.Count += 1
    return state.Paths
}

SelfTestDelayedHDropReader(state, dataObject) {
    state.Count += 1
    return state.Count = 1 ? [] : state.Paths
}

SelfTestSourceIdFactory(state) {
    state.Next += 1
    return "source-self-test-" state.Next
}

RunFolderSourceConfigSelfTests() {
    global ConfigPath, ConfigReentrySelfTestRejected
    testRoot := A_Temp "\PopDrop-source-config-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount
    testPath := testRoot "\config.ini"
    hadConfigPath := IsSet(ConfigPath)
    previousConfigPath := hadConfigPath ? ConfigPath : ""
    try {
        existingPath := testRoot "\existing"
        projectPath := testRoot "\项目"
        secondPath := testRoot "\第二"
        crossPath := testRoot "\跨区"
        missingPath := testRoot "\missing"
        for path in [existingPath, projectPath, secondPath, crossPath]
            DirCreate(path)
        testConfig := "; 保留的人工注释`n"
            . "; <PopDrop:area 1>`n"
            . "[General]`n"
            . "ConfigVersion=16`n"
            . "UnknownGeneral=保留`n`n"
            . "; <PopDrop:area 2>`n"
            . "[Folders]`n`n"
            . "; <PopDrop:area 3>`n"
            . "[Workspaces]`n"
            . "Order=workspace-a,workspace-b`n"
            . "Active=workspace-a`n"
            . "PinnedScopeVersion=1`n`n"
            . "[Workspace:workspace-a]`n"
            . "Name=测试工作区`n"
            . "SourceOrder=source-existing`n"
            . "UnknownWorkspace=保留`n`n"
            . "[Workspace:workspace-b]`n"
            . "Name=其他工作区`n"
            . "SourceOrder=source-cross`n`n"
            . "[WorkspacePinned:workspace-a]`n`n"
            . "[WorkspacePinned:workspace-b]`n`n"
            . "[Sources]`n"
            . "Order=`n`n"
            . "[Source:source-existing]`n"
            . "WorkspaceId=workspace-a`n"
            . "Name=项目`n"
            . "Path=" existingPath "`n"
            . "Mode=Files`n"
            . "UnknownSource=保留`n`n"
            . "[Source:source-cross]`n"
            . "WorkspaceId=workspace-b`n"
            . "Name=跨区`n"
            . "Path=" crossPath "`n"
            . "Mode=Files`n`n"
            . "; <PopDrop:area 4>`n"
            . "[OpenApps]`n"
            . "Order=`n`n"
            . "; <PopDrop:area 5>`n"
            . "[TransferFavorites]`n`n"
            . "[TransferFavoriteLabels]`n`n"
            . "[RecentTargets]`n`n"
            . "; <PopDrop:area 6>`n"
            . "[ExcludedFolderNames]`n"
        DirCreate(testRoot)
        FileAppend(testConfig, testPath, "UTF-16")
        ConfigPath := testPath
        defaults := {
            DefaultDisplayScope: "FilesOnly",
            DefaultFolderTimeMode: "DirectoryModified",
            MaxFilesPerFolder: 8,
            DefaultFilter: {Mode: "All", Extensions: []}
        }
        result := {
            WorkspaceName: "", Added: 0, Existing: 0, Failed: 0,
            FailedDetails: [], Sources: []
        }
        AtomicConfigEdit(WriteDroppedFolderSources.Bind(
            "workspace-a",
            [projectPath, secondPath, crossPath,
                existingPath, missingPath],
            defaults, result))
        AssertSelfTest(result.Added = 3
            && result.Existing = 1 && result.Failed = 1,
            "来源配置事务支持多项、去重、跨工作区路径和部分无效")
        doc := OpenPopDropConfig(testPath)
        sources := ReadWorkspaceSourcesFromDocument(doc, "workspace-a")
        AssertSelfTest(sources.Length = 4
            && PathsEqual(sources[1].Path, existingPath)
            && PathsEqual(sources[2].Path, projectPath)
            && PathsEqual(sources[3].Path, secondPath)
            && PathsEqual(sources[4].Path, crossPath),
            "新来源按原始拖拽顺序追加到 SourceOrder")
        AssertSelfTest(sources[2].Name = "项目 (2)",
            "同名不同路径生成唯一来源名称")
        otherSources := ReadWorkspaceSourcesFromDocument(
            doc, "workspace-b")
        AssertSelfTest(otherSources.Length = 1
            && PathsEqual(otherSources[1].Path, crossPath),
            "跨工作区允许保存相同来源路径")

        raw := FileRead(testPath, "RAW")
        text := FileRead(testPath, "UTF-16")
        AssertSelfTest(NumGet(raw, 0, "UShort") = 0xFEFF
            && InStr(text, "`r`n")
            && !RegExMatch(text, "(?<!\r)\n"),
            "添加来源保持 UTF-16LE BOM 和 CRLF")
        AssertSelfTest(InStr(text, "; 保留的人工注释")
            && InStr(text, "UnknownGeneral=保留")
            && InStr(text, "UnknownWorkspace=保留")
            && InStr(text, "UnknownSource=保留"),
            "添加来源保留注释和未知键")
        Loop 6
            AssertSelfTest(InStr(text,
                "; <PopDrop:area " A_Index ">"),
                "添加来源保留布局锚点 " A_Index)

        beforeFailure := FileRead(testPath, "RAW")
        failed := false
        try AtomicConfigEdit(FailFolderSourceTransaction)
        catch
            failed := true
        afterFailure := FileRead(testPath, "RAW")
        AssertSelfTest(failed
            && BuffersEqual(beforeFailure, afterFailure),
            "原子保存失败不留下部分来源")

        ConfigReentrySelfTestRejected := false
        AtomicConfigEdit(TestConfigTransactionReentry)
        AssertSelfTest(ConfigReentrySelfTestRejected
            && IniRead(testPath, "General", "ConfigReentryProbe", "") = "1",
            "配置事务拒绝同进程重入且外层写入仍可提交")
    } finally {
        ConfigPath := hadConfigPath ? previousConfigPath : ""
        try DirDelete(testRoot, true)
    }
}

TestConfigTransactionReentry(tempPath) {
    global ConfigReentrySelfTestRejected
    try AtomicConfigEdit(UnexpectedNestedConfigWrite)
    catch as err
        ConfigReentrySelfTestRejected := InStr(
            err.Message, "配置写入事务正在进行") > 0
    doc := OpenPopDropConfig(tempPath)
    doc.SetValue("General", "ConfigReentryProbe", "1", 1)
    doc.Save()
}

UnexpectedNestedConfigWrite(tempPath) {
    throw Error("嵌套配置写入不应被执行：" tempPath)
}

FailFolderSourceTransaction(tempPath) {
    doc := OpenPopDropConfig(tempPath)
    doc.SetValue("Workspace:workspace-a",
        "SourceOrder", "source-partial", 3)
    doc.Save()
    throw Error("self-test injected save failure")
}

RunSourceManagementSelfTests() {
    descriptors := Map(
        1, {Type: "Pinned", SourceId: "", Name: "固定项",
            Path: "", Mode: "", GroupId: 1, WorkspaceId: "workspace-a"},
        2, {Type: "Files", SourceId: "source-files", Name: "资料",
            Path: "C:\资料", Mode: "Files", GroupId: 2,
            WorkspaceId: "workspace-a"},
        3, {Type: "Launcher", SourceId: "source-launcher", Name: "工具",
            Path: "C:\工具", Mode: "Launcher", GroupId: 3,
            WorkspaceId: "workspace-a"})
    thumbnailRects := Map(
        1, {Left: 0, Top: 0, Right: 640, Bottom: 28},
        2, {Left: 0, Top: 84, Right: 640, Bottom: 116},
        3, {Left: 0, Top: 252, Right: 640, Bottom: 284})
    hit := FindSourceGroupHeaderInRects(
        20, 96, descriptors, thumbnailRects)
    AssertSelfTest(IsObject(hit)
        && hit.GroupId = 2 && hit.SourceId = "source-files",
        "缩略图视图按来源标题矩形命中 GroupId")

    listRects := Map(
        2, {Left: 0, Top: 10, Right: 900, Bottom: 36},
        3, {Left: 0, Top: 96, Right: 900, Bottom: 122})
    hit := FindSourceGroupHeaderInRects(
        450, 110, descriptors, listRects)
    AssertSelfTest(IsObject(hit)
        && hit.GroupId = 3 && hit.Type = "Launcher",
        "列表视图和滚动后命中正确来源标题")

    scaledRects := Map(
        2, {Left: 0, Top: 160, Right: 1440, Bottom: 224})
    hit := FindSourceGroupHeaderInRects(
        1200, 200, descriptors, scaledRects)
    AssertSelfTest(IsObject(hit) && hit.GroupId = 2,
        "DPI 缩放命中只使用系统返回矩形")
    AssertSelfTest(!IsObject(FindSourceGroupHeaderInRects(
        640, 100, descriptors, thumbnailRects)),
        "来源标题右边界外不误触")
    AssertSelfTest(!IsObject(FindSourceGroupHeaderInRects(
        10, 10, descriptors, thumbnailRects)),
        "固定项标题不解析为来源管理目标")
    pinnedHit := FindPinnedGroupHeaderInRects(
        10, 10, descriptors, thumbnailRects)
    AssertSelfTest(IsObject(pinnedHit)
        && pinnedHit.GroupId = 1 && pinnedHit.Type = "Pinned",
        "固定项标题解析为独立固定项菜单目标")
    AssertSelfTest(!IsObject(FindPinnedGroupHeaderInRects(
        20, 96, descriptors, thumbnailRects)),
        "来源标题不误解析为固定项菜单目标")
    AssertSelfTest(!IsObject(FindSourceGroupHeaderInRects(
        10, 10, Map(), Map())),
        "空工作区占位不解析为来源管理目标")
    missingPinnedPath := A_Temp "\PopDrop-missing-pinned-self-test"
        . A_TickCount
    partition := PartitionPinnedPathsByAvailability(
        [A_ScriptFullPath, missingPinnedPath])
    AssertSelfTest(partition.Remaining.Length = 1
        && partition.Invalid.Length = 1
        && PathsEqual(partition.Invalid[1], missingPinnedPath),
        "固定项清理只筛选失效路径")
    offline := {
        Type: "Files", SourceId: "source-offline", Name: "离线",
        Path: A_Temp "\PopDrop-offline-source-self-test", Mode: "Files",
        GroupId: 4, WorkspaceId: "workspace-a", Available: false}
    AssertSelfTest(IsSourceManagementDescriptor(offline)
        && !CanOpenSourceFolder(offline),
        "离线来源保留管理身份但不能打开文件夹")

    draft := {Workspaces: [
        {Id: "workspace-a", Name: "同名",
            Sources: [
                {SourceId: "source-a", Name: "资料",
                    Path: "C:\已修改路径"}]},
        {Id: "workspace-b", Name: "同名",
            Sources: [
                {SourceId: "source-b", Name: "资料",
                    Path: "C:\已修改路径"}]}
    ]}
    navigation := ResolveDraftSourceNavigation(
        draft, "workspace-b", "source-b")
    AssertSelfTest(navigation.WorkspaceIndex = 2
        && navigation.SourceIndex = 1,
        "设置导航只按 WorkspaceId 和 SourceId 定位")
    missing := ResolveDraftSourceNavigation(
        draft, "workspace-b", "source-missing")
    AssertSelfTest(missing.WorkspaceFound && !missing.SourceFound,
        "目标来源不存在时不选择同名或同路径来源")
    AssertSelfTest(ResolveSettingsConflictAction("Yes") = "Save"
        && ResolveSettingsConflictAction("No") = "Discard"
        && ResolveSettingsConflictAction("Cancel") = "Cancel",
        "设置导航复用保存、放弃、取消三路径保护")

    batches := Map(
        "active", {Completed: false,
            TargetSourceId: "source-files", TargetPath: "C:\资料"},
        "other", {Completed: false,
            TargetSourceId: "source-other", TargetPath: "C:\资料"},
        "done", {Completed: true,
            TargetSourceId: "source-files", TargetPath: "C:\资料"})
    AssertSelfTest(SourceRemovalTransferBlockReason(
        "source-files", "C:\资料", batches) != "",
        "活动外部传输按 TargetSourceId 阻止移除")
    safeBatches := Map(
        "other", {Completed: false,
            TargetSourceId: "source-other", TargetPath: "C:\资料"})
    AssertSelfTest(SourceRemovalTransferBlockReason(
        "source-files", "C:\资料", safeBatches) = "",
        "可靠的其他 SourceId 不因同路径误判")
    legacyBatches := Map(
        "legacy", {Completed: false,
            TargetSourceId: "", TargetPath: "C:\资料"})
    AssertSelfTest(SourceRemovalTransferBlockReason(
        "source-files", "C:\资料", legacyBatches) != "",
        "缺少稳定身份的同路径活动传输按安全策略阻止移除")

    removal := RemoveTextInsensitive(
        ["source-a", "SOURCE-B", "source-c"], "source-b")
    AssertSelfTest(removal.Removed
        && JoinArray(removal.Values, ",") = "source-a,source-c",
        "SourceOrder 按稳定 ID 删除且保持其余顺序")
    sections := SourceOwnedConfigSections("source-a")
    AssertSelfTest(sections.Length = 5
        && sections[1] = "Source:source-a"
        && sections[4] = "SourceAllow:source-a"
        && sections[5] = "TextSourcePinned:source-a",
        "来源专属配置清理范围完整")
}

RunSourceRemovalConfigSelfTests() {
    global ConfigPath
    testRoot := A_Temp "\PopDrop-source-removal-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount
    testPath := testRoot "\config.ini"
    hadConfigPath := IsSet(ConfigPath)
    previousConfigPath := hadConfigPath ? ConfigPath : ""
    try {
        sharedPath := testRoot "\共享目录"
        DirCreate(sharedPath)
        testConfig := "; 来源管理保留注释`n"
            . "; <PopDrop:area 1>`n"
            . "[General]`n"
            . "ConfigVersion=16`n"
            . "UnknownGeneral=保留`n`n"
            . "; <PopDrop:area 2>`n"
            . "[Folders]`n"
            . "兼容快照=" sharedPath "`n`n"
            . "; <PopDrop:area 3>`n"
            . "[Workspaces]`n"
            . "Order=workspace-a,workspace-b`n"
            . "Active=workspace-a`n"
            . "PinnedScopeVersion=1`n`n"
            . "[Workspace:workspace-a]`n"
            . "Name=当前工作区`n"
            . "SourceOrder=source-files,source-launcher,source-offline`n"
            . "UnknownWorkspace=保留`n`n"
            . "[Workspace:workspace-b]`n"
            . "Name=其他工作区`n"
            . "SourceOrder=source-other`n`n"
            . "[WorkspacePinned:workspace-a]`n"
            . "Path001=" sharedPath "\固定.txt`n`n"
            . "[WorkspacePinned:workspace-b]`n`n"
            . "[Sources]`n"
            . "Order=`n`n"
            . "[Source:source-files]`n"
            . "WorkspaceId=workspace-a`n"
            . "Name=资料`n"
            . "Path=" sharedPath "`n"
            . "Mode=Files`n"
            . "UnknownSource=随来源删除`n`n"
            . "[SourceMetadata:source-files]`n"
            . "ProviderNote=随来源删除`n`n"
            . "[Source:source-launcher]`n"
            . "WorkspaceId=workspace-a`n"
            . "Name=启动器`n"
            . "Path=Z:\离线启动器`n"
            . "Mode=Launcher`n`n"
            . "[Source:source-offline]`n"
            . "WorkspaceId=workspace-a`n"
            . "Name=离线`n"
            . "Path=Z:\离线来源`n"
            . "Mode=Files`n`n"
            . "[Source:source-other]`n"
            . "WorkspaceId=workspace-b`n"
            . "Name=其他资料`n"
            . "Path=" sharedPath "`n"
            . "Mode=Files`n`n"
            . "; <PopDrop:area 4>`n"
            . "[OpenApps]`n"
            . "Order=`n`n"
            . "; <PopDrop:area 5>`n"
            . "[TransferFavorites]`n"
            . "Path001=" sharedPath "`n`n"
            . "[RecentTargets]`n"
            . "Path001=" sharedPath "`n`n"
            . "; <PopDrop:area 6>`n"
            . "[ExcludedFolderNames]`n"
            . "Name001=.git`n`n"
            . "[SourceIgnore:source-files]`n"
            . "PatternCount=1`n"
            . "Pattern001=*.tmp`n`n"
            . "[SourceExclude:source-files]`n"
            . "Path001=build`n`n"
            . "[SourceAllow:source-files]`n"
            . "Path001=.git`n`n"
            . "[TextSourcePinned:source-files]`n"
            . "File001=" sharedPath "\常用.md`n"
        DirCreate(testRoot)
        FileAppend(testConfig, testPath, "UTF-16")
        ConfigPath := testPath

        result := {Removed: false}
        AtomicConfigEdit(WriteSourceRemovalConfig.Bind(
            "workspace-a", "source-files", result))
        AssertSelfTest(result.Removed
            && result.SourceName = "资料"
            && PathsEqual(result.SourcePath, sharedPath),
            "原子移除普通 Files 来源")
        doc := OpenPopDropConfig(testPath)
        AssertSelfTest(doc.GetValue(
            "Workspace:workspace-a", "SourceOrder", "")
            = "source-launcher,source-offline",
            "移除后 SourceOrder 保持正确顺序")
        for section in SourceOwnedConfigSections("source-files")
            AssertSelfTest(!ValueInArray(
                section, doc.GetSectionNames()),
                "删除来源专属配置节 " section)
        AssertSelfTest(!ValueInArray(
            "SourceMetadata:source-files", doc.GetSectionNames()),
            "删除明确归属于 SourceId 的扩展配置节")
        AssertSelfTest(doc.GetValue(
            "Workspace:workspace-b", "SourceOrder", "")
            = "source-other"
            && doc.GetValue("Source:source-other", "Path", "")
                = sharedPath,
            "其他工作区同路径来源不受影响")
        AssertSelfTest(doc.GetValue(
            "WorkspacePinned:workspace-a", "Path001", "") != ""
            && doc.GetValue("RecentTargets", "Path001", "") = sharedPath
            && doc.GetValue("TransferFavorites", "Path001", "")
                = sharedPath,
            "固定项、最近记录和复制移动目标保持不变")
        AssertSelfTest(doc.GetValue(
            "Folders", "兼容快照", "") = sharedPath,
            "v0.8 兼容快照保持不变")

        beforeFailure := FileRead(testPath, "RAW")
        failed := false
        try AtomicConfigEdit(FailSourceRemovalTransaction)
        catch
            failed := true
        afterFailure := FileRead(testPath, "RAW")
        AssertSelfTest(failed
            && BuffersEqual(beforeFailure, afterFailure),
            "移除事务失败时活动配置字节级不变")

        launcherResult := {Removed: false}
        AtomicConfigEdit(WriteSourceRemovalConfig.Bind(
            "workspace-a", "source-launcher", launcherResult))
        offlineResult := {Removed: false}
        AtomicConfigEdit(WriteSourceRemovalConfig.Bind(
            "workspace-a", "source-offline", offlineResult))
        doc := OpenPopDropConfig(testPath)
        AssertSelfTest(launcherResult.Removed
            && offlineResult.Removed
            && doc.GetValue(
                "Workspace:workspace-a", "SourceOrder", "") = "",
            "Launcher、离线来源和最后一个来源均可安全移除")

        raw := FileRead(testPath, "RAW")
        text := FileRead(testPath, "UTF-16")
        AssertSelfTest(NumGet(raw, 0, "UShort") = 0xFEFF
            && InStr(text, "`r`n")
            && !RegExMatch(text, "(?<!\r)\n"),
            "移除来源保持 UTF-16LE BOM 和 CRLF")
        AssertSelfTest(InStr(text, "; 来源管理保留注释")
            && InStr(text, "UnknownGeneral=保留")
            && InStr(text, "UnknownWorkspace=保留"),
            "移除来源保留人工注释和无关未知键")
        Loop 6
            AssertSelfTest(InStr(text,
                "; <PopDrop:area " A_Index ">"),
                "移除来源保留布局锚点 " A_Index)
    } finally {
        ConfigPath := hadConfigPath ? previousConfigPath : ""
        try DirDelete(testRoot, true)
    }
}

FailSourceRemovalTransaction(tempPath) {
    doc := OpenPopDropConfig(tempPath)
    doc.SetValue("Workspace:workspace-a",
        "SourceOrder", "source-partial", 3)
    doc.DeleteSection("Source:source-launcher")
    doc.Save()
    throw Error("self-test injected source removal failure")
}

RunOpenAppActionSelfTests() {
    global ACTION_COMMAND_LINE_LIMIT
    testRoot := A_Temp "\PopDrop-action-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount
    try {
        firstDir := testRoot "\空 格 & (一)"
        secondDir := testRoot "\第二处"
        DirCreate(firstDir)
        DirCreate(secondDir)
        first := firstDir "\右击项.TAR.GZ"
        second := firstDir "\另一个 资料.tar.gz"
        mismatch := firstDir "\不匹配.txt"
        cross := secondDir "\跨目录.tar.gz"
        folder := firstDir "\文件夹"
        executable := testRoot "\tool.exe"
        for path in [first, second, mismatch, cross, executable]
            FileAppend("test", path, "UTF-8")
        DirCreate(folder)
        action := {
            Id: "archive", Name: "压缩测试",
            Executable: executable,
            TargetTypes: "Files", ExecutionMode: "Batch",
            Extensions: [".tar.gz"], RequireCommonFolder: false,
            WorkingDirectoryMode: "ProgramDirectory",
            WorkingDirectory: "", Confirm: false, Enabled: true,
            Args: ["a", "{items}", "-o{folder}\{stem}"],
            Valid: true, ValidationError: ""
        }
        app := {
            Id: "tool", Path: executable, Name: "工具",
            Icon: executable, Extensions: [], Enabled: true,
            ShowInOpenMenu: false, Actions: [action]
        }
        AssertSelfTest(IsOpenAppActionApplicable(
            app, action, [first, second], first),
            "工具动作同目录多文件全部匹配")
        AssertSelfTest(!IsOpenAppActionApplicable(
            app, action, [first, mismatch], first),
            "工具动作任一文件扩展名不匹配即隐藏")
        action.RequireCommonFolder := true
        AssertSelfTest(!IsOpenAppActionApplicable(
            app, action, [first, cross], first),
            "工具动作跨目录共同文件夹限制")
        action.RequireCommonFolder := false
        action.TargetTypes := "Both"
        action.Extensions := []
        AssertSelfTest(IsOpenAppActionApplicable(
            app, action, [first, folder], first),
            "工具动作文件与文件夹混合选择")
        action.TargetTypes := "Files"
        action.Extensions := [".tar.gz"]
        rendered := RenderOpenAppAction(
            app, action, [first, second], first)
        AssertSelfTest(rendered.Valid && rendered.Args.Length = 4
            && rendered.Args[2] = first && rendered.Args[3] = second
            && rendered.Args[4] = "-o" firstDir "\右击项.TAR",
            "{items} 多参数展开和右击项标量变量")
        variables := BuildOpenAppActionVariables(
            first, 2, 5, "20260726153045")
        AssertSelfTest(variables.Folder = firstDir
            && variables.Parent = testRoot
            && variables.Ext = "gz"
            && variables.Date = "20260726"
            && variables.Time = "153045"
            && variables.DateTime = "20260726_153045"
            && variables.Index = 2 && variables.Count = 5
            && variables.Size != "",
            "folder、parent、日期时间、序号、总数和大小变量")
        action.ExecutionMode := "PerItem"
        action.Args := ["{item}", "{index}", "{count}",
            "{folder}", "{parent}", "{ext}"]
        rendered := RenderOpenAppAction(
            app, action, [first, cross], first)
        AssertSelfTest(rendered.Valid && rendered.Commands.Length = 2
            && rendered.Commands[1].Args[1] = first
            && rendered.Commands[2].Args[1] = cross
            && rendered.Commands[2].Args[2] = "2"
            && rendered.Commands[2].Args[3] = "2"
            && rendered.Commands[2].Args[4] = secondDir
            && rendered.Commands[2].Args[5] = testRoot,
            "逐个模式跨目录生成独立命令并使用当前项目变量")
        action.ExecutionMode := "Batch"
        action.Args := [RepeatText("长", ACTION_COMMAND_LINE_LIMIT)]
        rendered := RenderOpenAppAction(app, action, [first], first)
        AssertSelfTest(!rendered.Valid
            && InStr(rendered.Error, "命令行"),
            "工具动作超长命令行拒绝执行")
    } finally {
        try DirDelete(testRoot, true)
    }
}

RunNoiseFilterSelfTests() {
    global GlobalNoiseFilter
    global NOISE_FILTER_INHERIT, NOISE_FILTER_ENABLED, NOISE_FILTER_DISABLED
    global SCOPE_FILES_ONLY, SORT_NAME_ASC, FOLDER_TIME_MODIFIED
    compiled := CompileIgnorePatterns(["*.myapp-lock", "__temp__?",
        "*.MYAPP-LOCK", "file[1].*", ""], "self-test")
    AssertSelfTest(compiled.Texts.Length = 3, "忽略规则去空行和去重")
    AssertSelfTest(MatchesCompiledIgnorePattern("STATE.MYAPP-LOCK", compiled.Patterns),
        "星号规则大小写不敏感")
    AssertSelfTest(MatchesCompiledIgnorePattern("__temp__中", compiled.Patterns)
        && !MatchesCompiledIgnorePattern("__temp__两个", compiled.Patterns),
        "问号规则匹配一个 Unicode 字符")
    AssertSelfTest(MatchesCompiledIgnorePattern("file[1].txt", compiled.Patterns),
        "正则特殊字符先转义")
    AssertSelfTest(HasDangerousIgnorePattern(["*"])
        && HasDangerousIgnorePattern(["*.*"]), "过宽规则警告")

    noise := {Enabled: true, HideHidden: true, HideSystem: true,
        HideTemporary: false, HideIncompleteDownloads: false,
        CustomPatterns: [], SourceCustomPatterns: []}
    names := Map()
    for name in ["客户.accdb", "客户.laccdb", "孤立.laccdb",
        "旧库.mdb", "旧库.ldb", "设计图.dwg", "设计图.dwl",
        "设计图.dwl2", "孤立.dwl"]
        names[StrLower(name)] := true
    AssertSelfTest(!ShouldIncludeEntry("C:\x\~$报告.docx", "~$报告.docx",
        "A", noise, names).Include, "Office/WPS 锁定文件隐藏")
    AssertSelfTest(ShouldIncludeEntry("C:\x\~说明.txt", "~说明.txt",
        "A", noise, names).Include, "普通波浪号文件显示")
    AssertSelfTest(!ShouldIncludeEntry("C:\x\.~lock.报告.odt#",
        ".~lock.报告.odt#", "A", noise, names).Include,
        "LibreOffice 锁定文件隐藏")
    for metadata in ["desktop.ini", "Thumbs.db", "ehthumbs.db", ".DS_Store"]
        AssertSelfTest(!ShouldIncludeEntry("C:\x\" metadata, metadata,
            "A", noise, names).Include, "目录元数据隐藏：" metadata)
    AssertSelfTest(!ShouldIncludeEntry("C:\x\客户.laccdb", "客户.laccdb",
        "A", noise, names).Include, "Access 关联文件隐藏")
    AssertSelfTest(ShouldIncludeEntry("C:\x\孤立.laccdb", "孤立.laccdb",
        "A", noise, names).Include, "孤立 Access 文件显示")
    AssertSelfTest(!ShouldIncludeEntry("C:\x\旧库.ldb", "旧库.ldb",
        "A", noise, names).Include, "MDB 关联 LDB 隐藏")
    AssertSelfTest(!ShouldIncludeEntry("C:\x\设计图.dwl2", "设计图.dwl2",
        "A", noise, names).Include, "AutoCAD 关联文件隐藏")
    AssertSelfTest(ShouldIncludeEntry("C:\x\孤立.dwl", "孤立.dwl",
        "A", noise, names).Include, "孤立 AutoCAD 文件显示")
    for recovery in ["设计图.bak", "设计图.sv$", "设计图.ac$", "任意.tmp"]
        AssertSelfTest(ShouldIncludeEntry("C:\x\" recovery, recovery,
            "A", noise, names).Include, "恢复文件默认显示：" recovery)
    AssertSelfTest(!ShouldIncludeEntry("C:\x\隐藏.txt", "隐藏.txt",
        "HA", noise, names).Include, "Hidden 属性过滤")
    AssertSelfTest(!ShouldIncludeEntry("C:\x\系统.txt", "系统.txt",
        "SA", noise, names).Include, "System 属性过滤")
    AssertSelfTest(ShouldIncludeEntry("C:\x\临时.txt", "临时.txt",
        "TA", noise, names).Include, "Temporary 属性默认显示")
    AssertSelfTest(ShouldIncludeEntry("C:\x\属性未知.txt", "属性未知.txt",
        "", noise, names).Include, "属性失败时显示")
    for download in ["a.crdownload", "a.part", "a.download"]
        AssertSelfTest(ShouldIncludeEntry("C:\x\" download, download,
            "A", noise, names).Include, "未完成下载默认显示")
    pinned := BuildPathSet(["C:\x\~$固定.docx"])
    AssertSelfTest(ShouldIncludeEntry("C:\x\~$固定.docx", "~$固定.docx",
        "HS", noise, names, pinned).Include, "固定项目优先")

    GlobalNoiseFilter := {Enabled: true, HideHidden: true, HideSystem: true,
        HideTemporary: false, HideIncompleteDownloads: false,
        CustomPatterns: [], CustomPatternTexts: [], PatternErrors: []}
    AssertSelfTest(ResolveNoiseFilterForSource(NOISE_FILTER_INHERIT, []).Enabled,
        "全局开启加来源继承")
    GlobalNoiseFilter.Enabled := false
    AssertSelfTest(ResolveNoiseFilterForSource(NOISE_FILTER_ENABLED, []).Enabled,
        "全局关闭加来源启用")
    GlobalNoiseFilter.Enabled := true
    AssertSelfTest(!ResolveNoiseFilterForSource(NOISE_FILTER_DISABLED, []).Enabled,
        "全局开启加来源禁用")

    testDir := A_Temp "\PopDrop-noise-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint") . "-" A_TickCount
    try {
        DirCreate(testDir)
        for fileName in ["~$报告.docx", "报告.docx", ".~lock.报告.odt#",
            "desktop.ini", "Thumbs.db", ".DS_Store", "客户.accdb",
            "客户.laccdb", "孤立.laccdb", "设计图.dwg", "设计图.dwl",
            "设计图.dwl2", "孤立.dwl", "设计图.bak", "设计图.sv$"]
            FileAppend("test", testDir "\" fileName, "UTF-8")
        childDir := testDir "\子目录"
        DirCreate(childDir)
        normalPath := childDir "\正常.txt"
        noisePath := childDir "\~$较新.docx"
        FileAppend("normal", normalPath, "UTF-8")
        FileAppend("noise", noisePath, "UTF-8")
        FileSetTime("20240101000000", normalPath, "M")
        FileSetTime("20250101000000", noisePath, "M")
        latestDiag := {Count: 0, Items: [], Seen: Map()}
        latest := GetLatestDescendantFileTime(childDir,
            {Mode: "All", Extensions: []}, [], [], [], noise, Map(),
            "中文测试来源", latestDiag)
        AssertSelfTest(latest = FileGetTime(normalPath, "M"),
            "隐藏文件不参与文件夹最新内容时间")
        diagnostics := {Count: 0, Items: [], Seen: Map()}
        files := GetSortedItems(testDir, 0, SCOPE_FILES_ONLY, SORT_NAME_ASC,
            {Mode: "All", Extensions: []}, FOLDER_TIME_MODIFIED,
            [], [], [], noise, Map(), "中文测试来源", diagnostics)
        for hiddenName in ["~$报告.docx", ".~lock.报告.odt#", "desktop.ini",
            "Thumbs.db", ".DS_Store", "客户.laccdb", "设计图.dwl", "设计图.dwl2"]
            AssertSelfTest(!ScanResultHasName(files, hiddenName), "扫描隐藏：" hiddenName)
        for visibleName in ["报告.docx", "孤立.laccdb", "孤立.dwl",
            "设计图.bak", "设计图.sv$"]
            AssertSelfTest(ScanResultHasName(files, visibleName), "扫描保留：" visibleName)
        AssertSelfTest(diagnostics.Count = 8, "隐藏诊断计数")
    } finally {
        try DirDelete(testDir, true)
    }
}

ScanResultHasName(files, targetName) {
    for file in files {
        if StrLower(file.Name) = StrLower(targetName)
            return true
    }
    return false
}

RunConfigDocumentSelfTests() {
    testPath := A_Temp "\PopDrop-config-self-test-"
        . DllCall("kernel32\GetCurrentProcessId", "uint")
        . "-" A_TickCount ".ini"
    try FileDelete(testPath)
    testConfig :=
    (
    "; <PopDrop:area 1>`n"
    "[General]`n"
    "ConfigVersion=11`n"
    "; 人工注释必须保留`n"
    "CustomValue=a=b`n"
    "; <PopDrop:area 2>`n"
    "; [Folder:这里只是注释示例]`n"
    "; <PopDrop:area 3>`n"
    "[Sources]`n"
    "Order=`n"
    "; <PopDrop:area 4>`n"
    "[OpenApps]`n"
    "Order=`n"
    "; <PopDrop:area 5>`n"
    "[TransferFavorites]`n"
    "; <PopDrop:area 6>`n"
    "[ExcludedFolderNames]`n"
    "Name001=.git`n"
    "[PinnedFiles]`n"
    "File001=旧值`n"
    )
    FileAppend(testConfig, testPath, "UTF-16")
    try {
        doc := OpenPopDropConfig(testPath)
        AssertSelfTest(doc.Dirty, "错位配置节应触发布局修复")
        WritePinnedPathsToDocument(doc, "PinnedFiles", [
            "C:\Temp\$1=a.txt",
            "D:\中文\文件.txt"
        ], 2)
        doc.SetValue("NoiseFilter", "Enabled", "1", 1)
        doc.SetValue("NoiseFilter", "UnknownNoiseOption", "保留", 1)
        EnsureNoiseFilterConfigComments(doc)
        doc.ReplaceSection("SourceIgnore:test", [
            {Key: "PatternCount", Value: "1"},
            {Key: "Pattern001", Value: "*.lock-marker"}
        ], 6)
        doc.ReplaceKnownKeys("Workspaces", [
            {Key: "Order", Value: "workspace-test"},
            {Key: "Active", Value: "workspace-test"},
            {Key: "PinnedScopeVersion", Value: "1"}
        ], ["Order", "Active", "PinnedScopeVersion"], 3)
        doc.ReplaceKnownKeys("Workspace:workspace-test", [
            {Key: "Name", Value: "测试工作区"},
            {Key: "SourceOrder", Value: "source-test"}
        ], ["Name", "SourceOrder"], 3)
        WritePinnedPathsToDocument(doc,
            "WorkspacePinned:workspace-test",
            ["C:\Temp\固定.txt"], 3)
        doc.ReplaceKnownKeys("Source:source-test", [
            {Key: "WorkspaceId", Value: "workspace-test"},
            {Key: "Name", Value: "测试来源"},
            {Key: "Path", Value: "C:\Temp"}
        ], ["WorkspaceId", "Name", "Path"], 3)
        testAction := {
            Id: "extract", Name: "解压测试",
            Executable: "C:\Tools\7z.exe",
            TargetTypes: "Files", ExecutionMode: "PerItem",
            Extensions: [".tar.gz", ".zip"],
            RequireCommonFolder: true,
            WorkingDirectoryMode: "Folder",
            WorkingDirectory: "", Confirm: false, Enabled: true,
            Args: ["x", "{item}", "-o{folder}\{stem}"],
            Valid: true, ValidationError: ""
        }
        testApp := {
            Id: "7z", Path: "C:\Tools\7zFM.exe",
            Name: "7-Zip", Icon: "C:\Tools\7zFM.exe",
            Extensions: [".zip"], Enabled: true,
            ShowInOpenMenu: true, Actions: [testAction]
        }
        doc.SetValue("OpenAppAction:7z:extract",
            "UnknownActionOption", "保留", 4)
        WriteOpenAppsToDocument(doc, [testApp])
        doc.Save()

        raw := FileRead(testPath, "RAW")
        AssertSelfTest(NumGet(raw, 0, "UShort") = 0xFEFF
            && NumGet(raw, 2, "UShort") != 0xFEFF,
            "UTF-16LE 只能有一个 BOM")
        text := FileRead(testPath, "UTF-16")
        AssertSelfTest(InStr(text, "; 人工注释必须保留"),
            "保留人工注释")
        AssertSelfTest(InStr(text, "; [Folder:这里只是注释示例]"),
            "注释节头不能被当成真实配置节")
        AssertSelfTest(InStr(text, "File001=C:\Temp\$1=a.txt"),
            "配置值中的美元符号和等号必须原样保留")
        AssertSelfTest(InStr(text, "`r`n") && !RegExMatch(text, "(?<!\r)\n"),
            "写回统一使用 CRLF")
        area2 := InStr(text, "; <PopDrop:area 2>")
        pinned := InStr(text, "[PinnedFiles]")
        area3 := InStr(text, "; <PopDrop:area 3>")
        AssertSelfTest(area2 < pinned && pinned < area3,
            "错位节必须回到指定区域")
        area1 := InStr(text, "; <PopDrop:area 1>")
        noiseSection := InStr(text, "[NoiseFilter]")
        AssertSelfTest(area1 < noiseSection && noiseSection < area2,
            "NoiseFilter 配置节位于全局区域")
        area6 := InStr(text, "; <PopDrop:area 6>")
        sourceIgnore := InStr(text, "[SourceIgnore:test]")
        AssertSelfTest(area6 < sourceIgnore,
            "来源附加规则配置节位于扫描规则区域")
        workspaces := InStr(text, "[Workspaces]")
        workspace := InStr(text, "[Workspace:workspace-test]")
        workspacePinned := InStr(text,
            "[WorkspacePinned:workspace-test]")
        source := InStr(text, "[Source:source-test]")
        sources := InStr(text, "[Sources]")
        AssertSelfTest(area3 < workspaces && workspaces < workspace
            && workspace < workspacePinned
            && workspacePinned < sources && sources < source,
            "工作区、固定项和来源稳定 ID 节位于第三区并按固定顺序排列")
        AssertSelfTest(InStr(text, "PinnedScopeVersion=1")
            && InStr(text, "File001=C:\Temp\固定.txt",
                false, workspacePinned),
            "工作区固定项和迁移标记写入")
        AssertSelfTest(InStr(text, "UnknownNoiseOption=保留"),
            "噪音过滤节未知配置项保留")
        actionSection := InStr(text, "[OpenAppAction:7z:extract]")
        openAppSection := InStr(text, "[OpenApp:7z]")
        area4 := InStr(text, "; <PopDrop:area 4>")
        area5 := InStr(text, "; <PopDrop:area 5>")
        AssertSelfTest(area4 < openAppSection
            && openAppSection < actionSection && actionSection < area5,
            "应用动作位于第四区且排在所属应用之后")
        AssertSelfTest(InStr(text, "ArgCount=3", false, actionSection)
            && InStr(text, "Arg002={item}", false, actionSection)
            && InStr(text, "ExecutionMode=PerItem", false, actionSection)
            && InStr(text, "RequireCommonFolder=1", false, actionSection)
            && InStr(text, "WorkingDirectoryMode=Folder",
                false, actionSection)
            && !InStr(text, "SelectionMode=", false, actionSection)
            && !InStr(text, "RequireCommonParent=", false, actionSection),
            "动作参数按 ArgCount 与 ArgNNN 有序写入")
        AssertSelfTest(InStr(text, "UnknownActionOption=保留"),
            "动作节未知配置项保留")
        AssertSelfTest(InStr(text, "; HideHidden：是否排除具有 Hidden 属性的文件。")
            && InStr(text, "; CustomPatternCount：下方 CustomPatternNNN"),
            "噪音过滤配置项说明写入且可诊断")
    } finally {
        try FileDelete(testPath)
    }
}

AssertSelfTest(condition, name) {
    if !condition
        throw Error("测试失败：" name)
}
